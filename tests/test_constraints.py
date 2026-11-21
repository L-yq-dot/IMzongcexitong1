"""约束负例与审计闭环测试。启动一次性 MySQL 8.4 演示库，直接用各角色账号连接。

覆盖：申报分/终审核定分硬封顶、学年时间锁与防重叠、权重合计、登录名互斥、
学生自查接口、公示视图、越权留痕、驳回重提 diff、截止作废兜底、事件调度器、
管理员主数据审计与列级权限。与 test_workflow 共用 demo_database，互不干扰。

运行：python -m unittest discover -s tests -v
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
        """调用过程并取回全部结果集，返回 [(列名列表, 行列表), ...]。"""
        with conn.cursor() as cur:
            cur.callproc(name, args)
            return [([d[0] for d in rs.description], rs.fetchall()) for rs in cur.stored_results()]

    def query(self, conn, sql, args=None):
        with conn.cursor() as cur:
            cur.execute(sql, args or ())
            return cur.fetchall()

    # 以下按编号顺序执行：01 建草稿，02 提交并终审，08/12 依赖其结果。

    def test_01_claimed_score_hard_cap(self):
        self.call(self.student, "save_form", YEAR, "约束测试：甲的表单")
        with self.assertRaises(connector.Error) as ctx:
            self.call(self.student, "save_item", YEAR, None, 202, "超过封顶分的申报", 25, "2026-10-10")
        self.assertIn("申报分不能超过项目封顶分", str(ctx.exception))

    def test_02_final_score_sum_hard_cap(self):
        self.call(self.student, "save_form", YEAR, "约束测试：项目核定分合计封顶")
        i1 = self.call(self.student, "save_item", YEAR, None, 202, "社会实践甲", 15, "2026-10-10")[0][1][0][0]
        i2 = self.call(self.student, "save_item", YEAR, None, 202, "社会实践乙", 15, "2026-10-11")[0][1][0][0]
        self.call(self.student, "add_evidence", YEAR, i1, "证明甲.txt", b"proof-a")
        self.call(self.student, "add_evidence", YEAR, i2, "证明乙.txt", b"proof-b")
        self.call(self.student, "submit_form", YEAR)
        for item in (i1, i2):
            self.call(self.initial, "review_item", item, "pass", None, None)
        for item in (i1, i2):
            self.call(self.counselor, "review_item", item, "pass", None, None)
        self.call(self.final, "review_item", i1, "pass", None, 15)
        # 同表单同项目已通过 15 分，再核定 15 分将超过项目封顶 20 分
        with self.assertRaises(connector.Error) as ctx:
            self.call(self.final, "review_item", i2, "pass", None, 15)
        self.assertIn("该项目核定分合计将超过封顶分", str(ctx.exception))
        # 核定分也不得超过该条目自己的申报分
        with self.assertRaises(connector.Error) as ctx:
            self.call(self.final, "review_item", i2, "pass", None, 16)
        self.assertIn("终审核定分须介于零与申报分之间", str(ctx.exception))
        self.call(self.final, "review_item", i2, "pass", None, 5)
        rows = self.query(self.root, "SELECT final_score FROM application_item WHERE item_id IN (%s, %s)", (i1, i2))
        self.assertEqual(sorted(r[0] for r in rows), [5, 15])

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
                       "INSERT INTO academic_year(year_id, year_name, starts_on, ends_on, opens_at, deadline_at, status, rule_id) "
                       "VALUES ('2026-2028', '重叠测试学年', '2026-10-01', '2027-09-30', "
                       "UTC_TIMESTAMP() - INTERVAL 1 DAY, UTC_TIMESTAMP() + INTERVAL 1 DAY, 'draft', 2)")
        self.assertIn("学年日期区间不能与已有学年重叠", str(ctx.exception))

    def test_06_weight_sum(self):
        # 规则 1/2 已被学年引用，须用全新草稿规则 3 验证编辑期权重校验
        self.query(self.root, "INSERT INTO assessment_rule(rule_id, rule_name, version_no, formula_note, effective_on) "
                              "VALUES (3, '信息管理系学生综合测评', '3.0-test', '权重校验测试', '2027-09-01')")
        self.query(self.root, "INSERT INTO assessment_project VALUES (301, 3, '测试项目甲', '学业', 0.8, 100, FALSE, NULL)")
        with self.assertRaises(connector.Error) as ctx:
            self.query(self.root, "INSERT INTO assessment_project VALUES (302, 3, '测试项目乙', '实践', 0.3, 20, FALSE, NULL)")
        self.assertIn("同一规则的项目权重合计不能超过 1", str(ctx.exception))
        self.query(self.root, "INSERT INTO assessment_project VALUES (302, 3, '测试项目乙', '实践', 0.2, 20, FALSE, NULL)")
        with self.assertRaises(connector.Error) as ctx:
            self.query(self.root, "UPDATE assessment_project SET weight = 0.3 WHERE project_id = 302")
        self.assertIn("同一规则的项目权重合计不能超过 1", str(ctx.exception))
        self.query(self.root, "DELETE FROM assessment_project WHERE project_id IN (301, 302)")
        self.query(self.root, "DELETE FROM assessment_rule WHERE rule_id = 3")

    def test_07_login_exclusivity(self):
        with self.assertRaises(connector.Error) as ctx:
            self.query(self.root, "INSERT INTO reviewer VALUES (91, '测试审核员', 'initial', 'IM01', 'sa_demo_s001')")
        self.assertIn("该登录名已绑定学生", str(ctx.exception))
        with self.assertRaises(connector.Error) as ctx:
            self.query(self.root, "INSERT INTO student VALUES ('S901', '测试学生', 'IM01', 'sa_demo_initial1')")
        self.assertIn("该登录名已绑定审核人员", str(ctx.exception))

    def test_08_student_self_service(self):
        history = self.call(self.student, "my_submission_history", HISTORY)[0][1]
        self.assertEqual([r[1] for r in history], [1, 2])  # 首轮 + 驳回重提轮
        cols, rows = self.call(self.student, "my_evidence", HISTORY)[0]
        self.assertNotIn("file_body", cols)  # 学生只见元数据，不见文件内容
        self.assertGreaterEqual(len(rows), 1)
        status = self.call(self.student, "my_form_status", YEAR)[0][1]
        self.assertEqual(status[0][1], "submitted")
        queue = self.call(self.initial, "review_queue", HISTORY, "completed")[0][1]
        self.assertEqual(len(queue), 3)  # 甲两条 + 乙一条（均属 IM01）
        progress = self.call(self.student, "my_progress")[0][1]
        self.assertEqual(len(progress), 1)  # 仅 2025-2026 已公示

    def test_09_public_notice(self):
        notice = self.query(self.student,
                            "SELECT student_id, total_score, rank_no FROM public_notice "
                            "WHERE year_id = %s ORDER BY rank_no, student_id", (HISTORY,))
        self.assertEqual(len(notice), 3)
        self.assertEqual([r[2] for r in notice], [1, 2, 2])  # DENSE_RANK：同分并列且名次连续
        self.assertEqual(self.query(self.student, "SELECT COUNT(*) FROM public_notice WHERE year_id = %s", (YEAR,))[0][0], 0)
        ranks = self.query(self.analyst, "SELECT rank_no FROM published_results WHERE year_id = %s ORDER BY rank_no", (HISTORY,))
        self.assertEqual([r[0] for r in ranks], [1, 2, 2])
        with self.assertRaises(connector.Error):  # 学生无公示权限
            self.call(self.student, "publish_year", YEAR)

    def test_10_denial_log(self):
        item = self.query(self.root,
                          "SELECT i.item_id FROM application_item i JOIN application_form f USING (form_id) "
                          "WHERE f.student_id = 'S001' AND f.year_id = %s ORDER BY i.item_id LIMIT 1", (HISTORY,))[0][0]
        with self.assertRaises(connector.Error) as ctx:
            self.call(self.initial_other, "read_review_item", item)  # 二班初审读一班条目
        self.assertIn("无权访问此申报条目", str(ctx.exception))
        with self.assertRaises(connector.Error) as ctx:
            self.call(self.student_other, "read_review_item", item)  # 学生账号未绑定审核人
        self.assertIn("无权访问此申报条目", str(ctx.exception))
        # 越权失败在 ROLLBACK 之后补记，仍然留痕
        rows = self.query(self.admin,
                          "SELECT login_name, reason FROM access_denied_log WHERE item_id = %s ORDER BY denied_id", (item,))
        self.assertEqual(rows, [("sa_demo_initial2", "班级范围或条目状态不符"),
                                ("sa_demo_s002", "账号未绑定审核人或条目不存在")])

    def test_11_review_item_diff(self):
        item = self.query(self.root,
                          "SELECT i.item_id FROM application_item i JOIN application_form f USING (form_id) "
                          "WHERE f.student_id = 'S001' AND f.year_id = %s AND i.project_id = 102", (HISTORY,))[0][0]
        cols, rows = self.call(self.initial, "review_item_diff", item)[0]
        self.assertEqual(len(rows), 1)
        row = dict(zip(cols, rows[0]))
        self.assertEqual(row["details_changed"], 1)   # 02 数据重提时改过细节
        self.assertEqual(row["claimed_changed"], 0)   # 申报分未变
        self.assertEqual(row["evidence_count_then"], row["evidence_count_now"])

    def test_12_abandon_flow(self):
        self.call(self.student_other, "save_form", YEAR, "约束测试：待作废表单")
        item = self.call(self.student_other, "save_item", YEAR, None, 201, "学业成绩申报", 50, "2026-10-10")[0][1][0][0]
        self.call(self.student_other, "submit_form", YEAR)
        with self.assertRaises(connector.Error) as ctx:
            self.call(self.admin, "abandon_form", YEAR, "S002")
        self.assertIn("申报截止前不可作废表单", str(ctx.exception))
        # 快进：同一句 UPDATE 把 open→review 并把截止时间提前到当前（02 演示同款口径）
        self.query(self.root, "UPDATE academic_year SET status = 'review', deadline_at = UTC_TIMESTAMP() WHERE year_id = %s", (YEAR,))
        stalled = self.query(self.admin, "SELECT student_id, blocking_items FROM admin_stalled_forms WHERE year_id = %s", (YEAR,))
        self.assertEqual(stalled, [("S002", 1)])  # 甲的表单已全部终审通过，不在卡死清单
        result = self.call(self.admin, "abandon_form", YEAR, "S002")[0][1]
        self.assertEqual(result[0][1], "void")
        self.assertEqual(self.query(self.root, "SELECT status FROM application_item WHERE item_id = %s", (item,))[0][0], "withdrawn")
        # 恢复学年开放并延后截止；已作废表单不因此复活
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
        with self.assertRaises(connector.Error):  # 管理员只见材料元数据列，不见 file_body
            self.query(self.admin, "SELECT file_body FROM evidence LIMIT 1")
        with self.assertRaises(connector.Error):  # 管理员对业务数据只读
            self.query(self.admin, "INSERT INTO application_form(student_id, year_id) VALUES ('S001', %s)", (YEAR,))


if __name__ == "__main__":
    unittest.main()