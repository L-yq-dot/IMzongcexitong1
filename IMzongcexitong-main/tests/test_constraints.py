"""真实口径下的约束负例与审计闭环测试。

覆盖：单项封顶/条数上限、学年时间锁与防重叠、规则匹配、A/B1 公式、
学生自查、公示与年级 20% 配额、越权留痕、驳回重提 diff、作废兜底、
事件调度器、管理员审计、公示校验码、材料查重、规则版本链、状态变更日志。
"""
import contextlib
import json
import os
from pathlib import Path
import tempfile
import unittest

from mysql import connector

from demo import demo_database

YEAR = "2026-2027"
HISTORY = "2025-2026"


class ConstraintAuditTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory(prefix="sa-constraints-", dir=os.getenv("SA_TEST_DIR"))
        cls.stack = contextlib.ExitStack()
        cls.config = cls.stack.enter_context(demo_database(cls.tmp.name))
        state = json.loads((Path(cls.tmp.name) / "local-state.json").read_text(encoding="utf-8"))

        def connect(user, password):
            return connector.connect(host=cls.config["MYSQL_HOST"], port=cls.config["MYSQL_PORT"],
                                     user=user, password=password, database="student_assessment",
                                     autocommit=True, connection_timeout=5)

        try:
            cls.root = connect("root", state["root_password"])
            cls.admin = connect("sa_demo_admin", state["passwords"]["admin"])
            cls.student = connect("sa_demo_s001", state["passwords"]["student"])
            cls.student_other = connect("sa_demo_s002", state["passwords"]["student_other"])
            cls.initial = connect("sa_demo_initial1", state["passwords"]["initial"])
            cls.initial_other = connect("sa_demo_initial2", state["passwords"]["initial_other"])
            cls.counselor = connect("sa_demo_counselor", state["passwords"]["counselor"])
            cls.final = connect("sa_demo_final", state["passwords"]["final"])
            cls.analyst = connect("sa_demo_analyst", state["passwords"]["analyst"])
        except BaseException:
            cls.stack.close()
            cls.tmp.cleanup()
            raise

    @classmethod
    def tearDownClass(cls):
        for name in ("root", "admin", "student", "student_other", "initial",
                     "initial_other", "counselor", "final", "analyst"):
            getattr(cls, name).close()
        cls.stack.close()
        cls.tmp.cleanup()

    def call(self, conn, name, *args):
        with conn.cursor() as cur:
            cur.callproc(name, args)
            return [([d[0] for d in rs.description], rs.fetchall()) for rs in cur.stored_results()]

    def query(self, conn, sql, args=None):
        with conn.cursor() as cur:
            cur.execute(sql, args or ())
            return cur.fetchall()

    # 以下按编号顺序执行：01 建草稿，02 提交并终审，08/12 依赖其结果。

    def test_01_item_cap(self):
        self.call(self.student, "save_form", YEAR, "约束测试：甲的表单")
        with self.assertRaises(connector.Error) as ctx:
            self.call(self.student, "save_item", YEAR, None, 101, "超过单项上限的论文", 7, "2026-10-10")
        self.assertIn("申报分不能超过单项封顶分", str(ctx.exception))

    def test_02_item_cap_and_max_items(self):
        self.call(self.student, "save_form", YEAR, "约束测试：条数与核定分")
        i1 = self.call(self.student, "save_item", YEAR, None, 104, "竞赛甲", 3.5, "2026-10-10")[0][1][0][0]
        i2 = self.call(self.student, "save_item", YEAR, None, 104, "竞赛乙", 3, "2026-10-11")[0][1][0][0]
        self.call(self.student, "add_evidence", YEAR, i1, "竞赛甲.txt", b"proof-a")
        self.call(self.student, "add_evidence", YEAR, i2, "竞赛乙.txt", b"proof-b")
        with self.assertRaises(connector.Error) as ctx:
            self.call(self.student, "save_item", YEAR, None, 104, "竞赛丙", 2, "2026-10-12")
        self.assertIn("申报条数已达上限", str(ctx.exception))
        self.call(self.student, "submit_form", YEAR)
        for item in (i1, i2):
            self.call(self.initial, "review_item", item, "pass", None, None)
            self.call(self.counselor, "review_item", item, "pass", None, None)
        with self.assertRaises(connector.Error) as ctx:
            self.call(self.final, "review_item", i1, "pass", None, 4)
        self.assertIn("终审核定分须介于零与申报分之间", str(ctx.exception))
        self.call(self.final, "review_item", i1, "pass", None, 3.5)
        self.call(self.final, "review_item", i2, "pass", None, 3)
        rows = self.query(self.root, "SELECT final_score FROM application_item WHERE item_id IN (%s, %s)", (i1, i2))
        self.assertEqual(sorted(r[0] for r in rows), [3, 3.5])

    def test_03_year_time_lock(self):
        with self.assertRaises(connector.Error) as ctx:
            self.query(self.root, "UPDATE academic_year SET opens_at = opens_at + INTERVAL 1 HOUR WHERE year_id = %s", (YEAR,))
        self.assertIn("学年启用后不可修改起止日期与开放时刻", str(ctx.exception))

    def test_04_deadline_only_extends(self):
        with self.assertRaises(connector.Error) as ctx:
            self.query(self.root, "UPDATE academic_year SET deadline_at = deadline_at - INTERVAL 1 DAY WHERE year_id = %s", (YEAR,))
        self.assertIn("截止时间只能向后延", str(ctx.exception))

    def test_05_year_overlap(self):
        with self.assertRaises(connector.Error) as ctx:
            self.query(self.root,
                       "INSERT INTO academic_year(year_id, year_name, starts_on, ends_on, opens_at, deadline_at, status) "
                       "VALUES ('2026-2028', '重叠测试学年', '2026-10-01', '2027-09-30', "
                       "UTC_TIMESTAMP() - INTERVAL 1 DAY, UTC_TIMESTAMP() + INTERVAL 1 DAY, 'draft')")
        self.assertIn("学年日期区间不能与已有学年重叠", str(ctx.exception))

    def test_06_rule_matching_and_b1_formula(self):
        # 24级学生不能用25级规则的项目
        form = self.query(self.root, "SELECT form_id FROM application_form WHERE student_id = 'S001' AND year_id = %s", (YEAR,))[0][0]
        with self.assertRaises(connector.Error) as ctx:
            self.query(self.root, "INSERT INTO application_item(form_id, project_id, details, claimed_score, occurred_on) "
                                  "VALUES (%s, 201, '规则不匹配', 1, '2026-10-10')", (form,))
        self.assertIn("项目不属于该学生本年度的规则", str(ctx.exception))
        # B1：24级绩点×20，25级加权平均分×0.8
        rows = self.query(self.root,
                          "SELECT r.student_id, cs.component, cs.score FROM assessment_result r "
                          "JOIN component_score cs USING (result_id) "
                          "WHERE r.year_id = %s AND r.student_id IN ('S001','S006') AND cs.component = 'B1'", (HISTORY,))
        values = {row[0]: float(row[2]) for row in rows}
        self.assertEqual(values, {"S001": 78.0, "S006": 73.6})

    def test_07_login_exclusivity(self):
        with self.assertRaises(connector.Error) as ctx:
            self.query(self.root, "INSERT INTO reviewer(reviewer_id, reviewer_name, review_role, class_id, login_name) "
                                  "VALUES (91, '测试审核员', 'initial', 'IM01', 'sa_demo_s001')")
        self.assertIn("该登录名已绑定学生", str(ctx.exception))
        with self.assertRaises(connector.Error) as ctx:
            self.query(self.root, "INSERT INTO student(student_id, student_name, class_id, grade_year, login_name) "
                                  "VALUES ('S901', '测试学生', 'IM01', 2024, 'sa_demo_initial1')")
        self.assertIn("该登录名已绑定审核人员", str(ctx.exception))

    def test_08_student_self_service(self):
        history = self.call(self.student, "my_submission_history", HISTORY)[0][1]
        self.assertEqual([r[1] for r in history], [1])
        cols, rows = self.call(self.student, "my_evidence", HISTORY)[0]
        self.assertNotIn("file_body", cols)
        self.assertGreaterEqual(len(rows), 1)
        status = self.call(self.student, "my_form_status", YEAR)[0][1]
        self.assertEqual(status[0][1], "submitted")
        queue = self.call(self.initial, "review_queue", HISTORY, "completed")[0][1]
        self.assertEqual(len(queue), 2)  # 甲论文 + 己竞赛，均属 IM01
        progress = self.call(self.student, "my_progress")[0][1]
        self.assertEqual(len(progress), 1)

    def test_09_public_notice_and_quota(self):
        notice = self.query(self.student,
                            "SELECT student_id, grade_year, total_score, grade, rank_no FROM public_notice "
                            "WHERE year_id = %s ORDER BY grade_year, rank_no", (HISTORY,))
        self.assertEqual(len(notice), 10)
        by_grade = {}
        for row in notice:
            by_grade.setdefault(row[1], []).append(row)
        self.assertEqual([r[4] for r in by_grade[2024]], [1, 2, 3, 4, 5])
        self.assertEqual([r[4] for r in by_grade[2025]], [1, 2, 3, 4, 5])
        grades = {row[0]: row[3] for row in notice}
        self.assertEqual(grades["S001"], "优秀")
        self.assertEqual(grades["S006"], "优秀")
        self.assertEqual(grades["S003"], "不合格")
        self.assertEqual(grades["S008"], "不合格")
        self.assertEqual(sum(1 for value in grades.values() if value == "优秀"), 2)
        self.assertEqual(self.query(self.student, "SELECT COUNT(*) FROM public_notice WHERE year_id = %s", (YEAR,))[0][0], 0)
        with self.assertRaises(connector.Error):
            self.call(self.student, "publish_year", YEAR)

    def test_10_denial_log(self):
        item = self.query(self.root,
                          "SELECT i.item_id FROM application_item i JOIN application_form f USING (form_id) "
                          "WHERE f.student_id = 'S001' AND f.year_id = %s ORDER BY i.item_id LIMIT 1", (HISTORY,))[0][0]
        with self.assertRaises(connector.Error) as ctx:
            self.call(self.initial_other, "read_review_item", item)
        self.assertIn("无权访问此申报条目", str(ctx.exception))
        with self.assertRaises(connector.Error) as ctx:
            self.call(self.student_other, "read_review_item", item)
        self.assertIn("无权访问此申报条目", str(ctx.exception))
        rows = self.query(self.admin,
                          "SELECT login_name, reason FROM access_denied_log WHERE item_id = %s ORDER BY denied_id", (item,))
        self.assertEqual(rows, [("sa_demo_initial2", "班级范围或条目状态不符"),
                                ("sa_demo_s002", "账号未绑定审核人或条目不存在")])

    def test_11_review_item_diff(self):
        self.call(self.student_other, "save_form", YEAR, "约束测试：驳回重提")
        item = self.call(self.student_other, "save_item", YEAR, None, 101, "初稿", 2, "2026-10-10")[0][1][0][0]
        self.call(self.student_other, "add_evidence", YEAR, item, "证明.txt", b"diff-proof")
        self.call(self.student_other, "submit_form", YEAR)
        self.call(self.initial, "review_item", item, "return", "请补充说明", None)
        self.call(self.student_other, "reopen_form", YEAR)
        self.call(self.student_other, "save_item", YEAR, item, 101, "补充后的说明", 3, "2026-10-10")
        self.call(self.student_other, "submit_form", YEAR)
        cols, rows = self.call(self.initial, "review_item_diff", item)[0]
        self.assertEqual(len(rows), 1)
        row = dict(zip(cols, rows[0]))
        self.assertEqual(row["details_changed"], 1)
        self.assertEqual(row["claimed_changed"], 1)
        self.assertEqual(row["evidence_count_then"], row["evidence_count_now"])

    def test_12_abandon_flow(self):
        with self.assertRaises(connector.Error) as ctx:
            self.call(self.admin, "abandon_form", YEAR, "S002")
        self.assertIn("申报截止前不可作废表单", str(ctx.exception))
        self.query(self.root, "UPDATE academic_year SET status = 'review', deadline_at = UTC_TIMESTAMP() WHERE year_id = %s", (YEAR,))
        stalled = self.query(self.admin, "SELECT student_id FROM admin_stalled_forms WHERE year_id = %s", (YEAR,))
        self.assertIn(("S002",), stalled)
        result = self.call(self.admin, "abandon_form", YEAR, "S002")[0][1]
        self.assertEqual(result[0][1], "void")
        self.assertEqual(self.query(self.root, "SELECT status FROM application_item WHERE item_id = "
                                  "(SELECT MAX(item_id) FROM application_item WHERE form_id = "
                                  " (SELECT form_id FROM application_form WHERE student_id='S002' AND year_id=%s))", (YEAR,))[0][0], "withdrawn")
        self.query(self.root, "UPDATE academic_year SET status = 'open', deadline_at = UTC_TIMESTAMP() + INTERVAL 30 DAY WHERE year_id = %s", (YEAR,))
        self.assertEqual(self.query(self.root, "SELECT status FROM application_form WHERE student_id = 'S002' AND year_id = %s", (YEAR,))[0][0], "void")

    def test_13_events(self):
        self.assertEqual(self.query(self.root, "SELECT @@event_scheduler")[0][0], "ON")
        with self.root.cursor() as cur:
            cur.execute("SHOW EVENTS FROM student_assessment")
            events = cur.fetchall()
        self.assertEqual(sorted(r[1] for r in events), ["open_due_years", "review_due_years"])
        self.assertTrue(all(r[10] == "ENABLED" for r in events))

    def test_14_admin_audit(self):
        self.query(self.admin, "INSERT INTO class_group VALUES ('IM99', '审计测试班级')")
        self.query(self.admin, "UPDATE class_group SET class_name = '审计测试班级（改）' WHERE class_id = 'IM99'")
        self.query(self.admin, "DELETE FROM class_group WHERE class_id = 'IM99'")
        actions = self.query(self.admin, "SELECT action FROM admin_operation_log WHERE target_id = 'IM99' ORDER BY op_id")
        self.assertEqual([r[0] for r in actions], ["class_group:insert", "class_group:update", "class_group:delete"])
        self.assertGreaterEqual(self.query(self.admin, "SELECT COUNT(*) FROM admin_operation_log WHERE action = 'publish_year'")[0][0], 1)
        self.assertGreaterEqual(self.query(self.admin, "SELECT COUNT(*) FROM admin_operation_log WHERE action = 'abandon_form'")[0][0], 1)
        with self.assertRaises(connector.Error):
            self.query(self.admin, "SELECT file_body FROM evidence LIMIT 1")
        with self.assertRaises(connector.Error):
            self.query(self.admin, "INSERT INTO application_form(student_id, year_id) VALUES ('S001', %s)", (YEAR,))

    def test_15_publication_checksum(self):
        cols, rows = self.call(self.student, "verify_publication", HISTORY)[0]
        self.assertEqual(rows[0][4], 1)
        stored = rows[0][2]
        self.query(self.root, "UPDATE assessment_result SET total_score = total_score + 1 "
                              "WHERE student_id = 'S001' AND year_id = %s", (HISTORY,))
        self.assertEqual(self.call(self.student, "verify_publication", HISTORY)[0][1][0][4], 0)
        self.query(self.root, "UPDATE assessment_result SET total_score = total_score - 1 "
                              "WHERE student_id = 'S001' AND year_id = %s", (HISTORY,))
        rows = self.call(self.student, "verify_publication", HISTORY)[0][1]
        self.assertEqual(rows[0][4], 1)
        self.assertEqual(rows[0][2], stored)
        with self.assertRaises(connector.Error) as ctx:
            self.call(self.student, "verify_publication", YEAR)
        self.assertIn("该学年尚未公示", str(ctx.exception))
        with self.assertRaises(connector.Error) as ctx:
            self.call(self.student, "verify_publication", "9999-9999")
        self.assertIn("学年不存在", str(ctx.exception))

    def test_16_evidence_duplicates(self):
        item = self.query(self.root,
                          "SELECT i.item_id FROM application_item i JOIN application_form f USING (form_id) "
                          "WHERE f.student_id = 'S001' AND f.year_id = %s AND i.project_id = 101", (HISTORY,))[0][0]
        self.query(self.root, "INSERT INTO evidence(item_id, file_name, storage_location, file_body, active) "
                              "VALUES (%s, '重复证明.txt', 'dup-test-1', _binary 'Synthetic paper proof', TRUE)", (item,))
        cols, rows = self.call(self.initial, "check_evidence_duplicates", item)[0]
        self.assertNotIn("student_id", cols)
        for row in rows:
            self.assertEqual(int(row[cols.index("active_copies")]), 2)
        dup = self.query(self.admin, "SELECT total_copies, active_copies, distinct_items FROM evidence_duplicates")
        self.assertEqual(len(dup), 1)
        self.assertEqual([int(v) for v in dup[0]], [2, 2, 1])
        with self.assertRaises(connector.Error):
            self.call(self.student, "check_evidence_duplicates", item)

    def test_17_rule_version_chain(self):
        chain = self.query(self.admin, "SELECT rule_id, root_rule_id, depth, version_path "
                                       "FROM rule_version_chain ORDER BY rule_id")
        self.assertEqual(chain, [(1, 1, 1, "1"), (2, 2, 1, "2")])
        self.query(self.root, "INSERT INTO assessment_rule(rule_id, rule_name, version_no, cohort, b1_formula, "
                              "excellent_ratio, a_cap, b1_cap, formula_note, effective_on, parent_rule_id) "
                              "VALUES (3, '信息管理系学生素质综合测评（25级测试版）', '3.0-test', 'ge2025', "
                              "'weighted_x08', 0.2, 20, 80, '版本链测试', '2027-09-01', 2)")
        chain = self.query(self.admin, "SELECT rule_id, root_rule_id, depth, version_path "
                                       "FROM rule_version_chain ORDER BY rule_id")
        self.assertEqual(chain, [(1, 1, 1, "1"), (2, 2, 1, "2"), (3, 2, 2, "2->3")])
        with self.assertRaises(connector.Error) as ctx:
            self.query(self.root, "INSERT INTO assessment_rule(rule_id, rule_name, version_no, cohort, b1_formula, "
                                  "excellent_ratio, a_cap, b1_cap, formula_note, effective_on, parent_rule_id) "
                                  "VALUES (5, '自环规则', '5.0-test', 'ge2025', 'weighted_x08', 0.2, 20, 80, '自环', '2027-09-01', 5)")
        self.assertIn("Check constraint", str(ctx.exception))
        self.query(self.root, "DELETE FROM assessment_rule WHERE rule_id = 3")

    def test_18_status_change_log(self):
        def seq(etype, eid):
            return self.query(self.admin,
                              "SELECT old_status, new_status FROM status_change_log "
                              "WHERE entity_type = %s AND entity_id = %s ORDER BY change_id", (etype, str(eid)))
        s1form = self.query(self.root, "SELECT form_id FROM application_form WHERE student_id='S001' AND year_id=%s", (YEAR,))[0][0]
        s2form = self.query(self.root, "SELECT form_id FROM application_form WHERE student_id='S002' AND year_id=%s", (YEAR,))[0][0]
        self.assertEqual(seq("application_form", s1form), [("draft", "submitted")])
        self.assertEqual(seq("application_form", s2form),
                         [("draft", "submitted"), ("submitted", "draft"),
                          ("draft", "submitted"), ("submitted", "void")])
        self.assertEqual(seq("academic_year", YEAR), [("open", "review"), ("review", "open")])
        self.assertEqual(seq("academic_year", HISTORY), [("open", "review"), ("review", "published")])
        self.assertTrue(all(r[0] for r in self.query(self.admin, "SELECT changed_by FROM status_change_log")))
        before = self.query(self.admin, "SELECT COUNT(*) FROM status_change_log")[0][0]
        self.query(self.root, "UPDATE application_form SET modified_at = UTC_TIMESTAMP(6) WHERE form_id = %s", (s1form,))
        self.assertEqual(self.query(self.admin, "SELECT COUNT(*) FROM status_change_log")[0][0], before)


if __name__ == "__main__":
    unittest.main()
