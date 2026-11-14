"""Integration tests. Start a disposable MySQL 8.4 instance with fictitious data."""
from hashlib import sha256
from io import BytesIO
import json
import os
from pathlib import Path
import re
import tempfile
import unittest

from app import create_app
from demo import demo_database


def csrf(client):
    with client.session_transaction() as session:
        return session["csrf"]


def post(client, path, data=None):
    return client.post(path, data={"csrf": csrf(client), **(data or {})}, follow_redirects=True)


def login(app, actor=None, credentials=None):
    client = app.test_client()
    client.get("/login")
    result = post(client, "/login", {"demo_actor": actor} if actor else credentials)
    if result.request.path == "/login":
        raise AssertionError(result.get_data(as_text=True))
    return client


class AssessmentWorkflow(unittest.TestCase):
    def test_full_workflow(self):
        parent = os.getenv("SA_TEST_DIR")
        with tempfile.TemporaryDirectory(prefix="sa-test-", dir=parent) as directory:
            with demo_database(directory) as config:
                app = create_app({**config, "TESTING": True})
                self.exercise(app, Path(directory))

            # Restart from the same directory and check that publication is persistent.
            with demo_database(directory) as config:
                student = login(create_app(config), "student")
                result = student.get("/student/results?year=2026-2027")
                self.assertIn("92.00", result.get_data(as_text=True))

    def exercise(self, app, directory):
        year = "2026-2027"
        student = login(app, "student")
        initial = login(app, "initial")
        counselor = login(app, "counselor")
        final = login(app, "final")
        publisher = login(app, "publisher")
        analyst = login(app, "analyst")
        secrets = json.loads((directory / "local-state.json").read_text())["passwords"]
        other = login(app, credentials={"username": "sa_demo_initial2", "password": secrets["initial_other"]})

        def text(response):
            self.assertEqual(response.status_code, 200)
            return response.get_data(as_text=True)

        self.assertIn("85.60", text(student.get("/student/results?year=2025-2026")))
        self.assertIn("66.50", text(analyst.get("/analytics?year=2025-2026&class_id=IM02")))
        self.assertEqual(student.post("/student/action/form", data={"year": year}).status_code, 400)
        self.assertEqual(student.get("/publication").status_code, 403)
        self.assertIn("已保存填报表", text(post(student, "/student/action/form", {"year": year, "notes": "核验网页填报"})))

        def save(project, detail, score, item=None):
            data = {"year": year, "project_id": project, "claimed_score": score,
                    "details": detail, "occurred_on": "2026-10-10"}
            if item:
                data["item_id"] = item
            response = post(student, "/student/action/item", data)
            self.assertIn("条目已保存", text(response))
            return int(re.search(r"[?&]edit=(\d+)", response.request.url)[1])

        study = save(201, "学业成绩", "100")
        practice = save(202, "社会实践", "15")
        self.assertIn("请补齐必需的证明材料", text(post(student, "/student/action/submit", {"year": year})))
        file_bytes = b"\x00\x11\xff\x80\xfe\x00 proof"
        result = post(student, "/student/action/upload", {
            "year": year, "item_id": practice, "evidence": (BytesIO(file_bytes), "实践证明.bin"),
        })
        self.assertIn("证明材料已上传", text(result))
        self.assertIn("提交成功", text(post(student, "/student/action/submit", {"year": year})))
        self.assertIn(f"/review/{practice}", text(initial.get(f"/review?year={year}")))
        self.assertEqual(other.get(f"/review/{practice}").status_code, 404)
        review_page = text(initial.get(f"/review/{practice}"))
        evidence_path = re.search(r'href="(/evidence/\d+)"', review_page)[1]
        self.assertEqual(other.get(evidence_path).status_code, 404)
        self.assertEqual(student.get(evidence_path).status_code, 403)
        download = initial.get(evidence_path)
        self.assertEqual(download.data, file_bytes)
        self.assertEqual(download.headers["X-File-SHA256"], sha256(file_bytes).hexdigest())

        self.assertIn("当前状态不能由该角色审核", text(post(final, f"/review/{study}", {"decision": "pass", "score": "100"})))
        self.assertIn("审核决定已保存", text(post(initial, f"/review/{practice}", {"decision": "return", "opinion": "请补充时长"})))
        self.assertIn("请补充时长", text(student.get(f"/student?year={year}")))
        self.assertIn("原表已撤回", text(post(student, "/student/action/reopen", {"year": year})))
        self.assertEqual(save(202, "社会实践，已补充时长", "15", practice), practice)
        volunteering = save(203, "志愿服务", "7")
        self.assertIn("证明材料已上传", text(post(student, "/student/action/upload", {
            "year": year, "item_id": volunteering, "evidence": (BytesIO(b"Volunteer"), "志愿证明.txt"),
        })))
        self.assertIn("提交成功", text(post(student, "/student/action/submit", {"year": year})))

        self.assertIn("已结束该学年", text(post(publisher, "/publication/close", {"year": year, "confirm": "yes"})))
        self.assertIn("尚未通过终审", text(post(publisher, "/publication/publish", {"year": year, "confirm": "yes"})))

        for item, score in [(study, "100"), (practice, "15"), (volunteering, "7")]:
            self.assertIn("审核决定已保存", text(post(initial, f"/review/{item}", {"decision": "pass"})))
            self.assertIn("审核决定已保存", text(post(counselor, f"/review/{item}", {"decision": "pass"})))
            self.assertIn("审核决定已保存", text(post(final, f"/review/{item}", {"decision": "pass", "score": score})))

        history = text(initial.get(f"/review/{practice}"))
        self.assertIn("请补充时长", history)
        self.assertIn("第 2 轮", history)
        self.assertIn("结果已公示", text(post(publisher, "/publication/publish", {"year": year, "confirm": "yes"})))
        self.assertIn("92.00", text(student.get(f"/student/results?year={year}")))
        self.assertIn("92.00", text(analyst.get(f"/analytics?year={year}")))


if __name__ == "__main__":
    unittest.main()

