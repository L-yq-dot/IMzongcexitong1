"""网页集成测试：真实口径 A/B1/B2/C、基础分录入、三级审核、公示与重启持久。"""
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

            with demo_database(directory) as config:
                student = login(create_app(config), "student")
                result = student.get("/student/results?year=2026-2027")
                self.assertIn("106.40", result.get_data(as_text=True))

    def exercise(self, app, directory):
        year = "2026-2027"
        student = login(app, "student")
        initial = login(app, "initial")
        counselor = login(app, "counselor")
        final = login(app, "final")
        publisher = login(app, "publisher")
        analyst = login(app, "analyst")
        secrets = json.loads((directory / "local-state.json").read_text())["passwords"]
        initial_other = login(app, credentials={
            "username": "sa_demo_initial2", "password": secrets["initial_other"]})

        def text(response):
            self.assertEqual(response.status_code, 200)
            return response.get_data(as_text=True)

        # 基础分：两个班的班级工作组分别录入 A/B1。
        result = post(initial, "/review/base", {
            "year": year, "a_S001": "18", "b1_S001": "3.9",
            "a_S002": "17", "b1_S002": "3.2", "a_S005": "17", "b1_S005": "3.3",
        })
        self.assertIn("已保存", text(result))
        result = post(initial_other, "/review/base", {
            "year": year, "a_S003": "16", "b1_S003": "3.0", "a_S004": "16", "b1_S004": "3.1",
        })
        self.assertIn("已保存", text(result))

        self.assertIn("98.90", text(student.get("/student/results?year=2025-2026")))
        self.assertIn("优秀", text(student.get("/student/results?year=2025-2026")))
        self.assertIn("基础分录入", text(initial.get("/review/base")))

        self.assertIn("已保存填报表", text(post(student, "/student/action/form", {"year": year, "notes": "真实口径填报"})))

        def save(project, detail, score):
            response = post(student, "/student/action/item", {
                "year": year, "project_id": project, "claimed_score": score,
                "details": detail, "occurred_on": "2026-10-10",
            })
            self.assertIn("条目已保存", text(response))
            return int(re.search(r"[?&]edit=(\d+)", response.request.url)[1])

        paper = save(101, "JCR 一区论文，第一作者", "2.4")
        book = save(102, "学术专著，第一作者", "5")
        project = save(103, "独立完成校级课题", "3")
        for item, name in ((paper, "论文证明.txt"), (book, "著作证明.txt"), (project, "课题证明.txt")):
            self.assertIn("证明材料已上传", text(post(student, "/student/action/upload", {
                "year": year, "item_id": item, "evidence": (BytesIO(b"proof-" + name.encode()), name),
            })))
        self.assertIn("提交成功", text(post(student, "/student/action/submit", {"year": year})))

        queue = text(initial.get(f"/review?year={year}"))
        for item in (paper, book, project):
            self.assertIn(f"/review/{item}", queue)
        for item, score in ((paper, "2.4"), (book, "5"), (project, "3")):
            self.assertIn("审核决定已保存", text(post(initial, f"/review/{item}", {"decision": "pass"})))
            self.assertIn("审核决定已保存", text(post(counselor, f"/review/{item}", {"decision": "pass"})))
            self.assertIn("审核决定已保存", text(post(final, f"/review/{item}", {"decision": "pass", "score": score})))

        self.assertIn("已结束该学年", text(post(publisher, "/publication/close", {"year": year, "confirm": "yes"})))
        self.assertIn("结果已公示", text(post(publisher, "/publication/publish", {"year": year, "confirm": "yes"})))

        page = text(student.get(f"/student/results?year={year}"))
        self.assertIn("106.40", page)
        self.assertIn("优秀", page)
        self.assertIn("年级第 1 名", page)
        self.assertIn("10.40", page)  # B2 = 2.4 + 5 + 3
        self.assertIn("106.40", text(analyst.get(f"/analytics?year={year}")))


if __name__ == "__main__":
    unittest.main()
