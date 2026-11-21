-- 可选，只在刚创建的空库中运行一次。用有建档权限的安装账号执行。
-- 全部姓名、学号和材料均为虚构。账号名仅写入业务绑定表。
USE student_assessment;
SET @demo_operator = SUBSTRING_INDEX(USER(), '@', 1);

INSERT INTO class_group VALUES ('IM01','信息管理一班'), ('IM02','信息管理二班');
INSERT INTO student(student_id, student_name, class_id, login_name) VALUES
    ('S001','演示学生甲','IM01','sa_demo_s001'),
    ('S002','演示学生乙','IM01','sa_demo_s002'),
    ('S003','演示学生丙','IM02','sa_demo_s003');
INSERT INTO reviewer(reviewer_id, reviewer_name, review_role, class_id, login_name) VALUES
    (1,'一班初审员','initial','IM01','sa_demo_initial1'),
    (2,'二班初审员','initial','IM02','sa_demo_initial2'),
    (3,'院系辅导员','counselor',NULL,'sa_demo_counselor'),
    (4,'院系终审员','final',NULL,'sa_demo_final');

INSERT INTO assessment_rule(rule_id, rule_name, version_no, formula_note, effective_on) VALUES
    (1,'信息管理系学生综合测评','1.0','各项目核定分除以项目上限，乘权重并折为百分制，求和','2025-09-01'),
    (2,'信息管理系学生综合测评','2.0','各项目核定分除以项目上限，乘权重并折为百分制，求和','2026-09-01');
INSERT INTO assessment_project
    (project_id, rule_id, project_name, category, weight, score_cap, evidence_required, evidence_requirement)
VALUES
    (101,1,'学业表现','学业',0.70,100,FALSE,NULL),
    (102,1,'社会实践','实践',0.30,20,TRUE,'提交实践证明'),
    (201,2,'学业表现','学业',0.70,100,FALSE,NULL),
    (202,2,'社会实践','实践',0.20,20,TRUE,'提交实践证明'),
    (203,2,'志愿服务','实践',0.10,10,TRUE,'提交服务时长证明');
INSERT INTO academic_year(year_id, year_name, starts_on, ends_on, opens_at, deadline_at, status, rule_id) VALUES
    ('2025-2026','2025–2026 学年','2025-09-01','2026-08-31',
     UTC_TIMESTAMP() - INTERVAL 1 DAY, UTC_TIMESTAMP() + INTERVAL 1 DAY,'open',1),
    ('2026-2027','2026–2027 学年','2026-09-01','2027-08-31',
     UTC_TIMESTAMP() - INTERVAL 1 DAY, UTC_TIMESTAMP() + INTERVAL 30 DAY,'open',2);

-- 演示中，安装账号依次绑定虚构学生和审核人员，以实际调用业务过程。
UPDATE student SET login_name = @demo_operator WHERE student_id = 'S001';
CALL save_form('2025-2026','甲的综测表');
CALL save_item('2025-2026',NULL,101,'学业成绩申报',88,'2026-06-20');
SET @a_study = LAST_INSERT_ID();
CALL save_item('2025-2026',NULL,102,'社会实践申报，初次提交',16,'2026-07-10');
SET @a_practice = LAST_INSERT_ID();
CALL add_evidence('2025-2026',@a_practice,'实践证明.txt',_binary 'Synthetic proof');
SET @proof = LAST_INSERT_ID();
CALL submit_form('2025-2026');
UPDATE student SET login_name = 'sa_demo_s001' WHERE student_id = 'S001';

UPDATE reviewer SET login_name = @demo_operator WHERE reviewer_id = 1;
CALL read_evidence(@proof);
CALL review_item(@a_practice,'return','请补充实践时长。',NULL);
UPDATE reviewer SET login_name = 'sa_demo_initial1' WHERE reviewer_id = 1;

UPDATE student SET login_name = @demo_operator WHERE student_id = 'S001';
CALL reopen_form('2025-2026');
CALL save_item('2025-2026',@a_practice,102,'社会实践 16 小时，已补充说明',16,'2026-07-10');
CALL submit_form('2025-2026');
UPDATE student SET login_name = 'sa_demo_s001' WHERE student_id = 'S001';

UPDATE student SET login_name = @demo_operator WHERE student_id = 'S002';
CALL save_form('2025-2026','乙的综测表');
CALL save_item('2025-2026',NULL,101,'学业成绩申报',95,'2026-06-20');
SET @b_study = LAST_INSERT_ID();
CALL submit_form('2025-2026');
UPDATE student SET login_name = 'sa_demo_s002' WHERE student_id = 'S002';

UPDATE student SET login_name = @demo_operator WHERE student_id = 'S003';
CALL save_form('2025-2026','丙的综测表');
CALL save_item('2025-2026',NULL,101,'学业成绩申报',95,'2026-06-20');
SET @c_study = LAST_INSERT_ID();
CALL submit_form('2025-2026');
UPDATE student SET login_name = 'sa_demo_s003' WHERE student_id = 'S003';

UPDATE reviewer SET login_name = @demo_operator WHERE reviewer_id = 1;
CALL review_item(@a_study,'pass',NULL,NULL);
CALL review_item(@a_practice,'pass',NULL,NULL);
CALL review_item(@b_study,'pass',NULL,NULL);
UPDATE reviewer SET login_name = 'sa_demo_initial1' WHERE reviewer_id = 1;
UPDATE reviewer SET login_name = @demo_operator WHERE reviewer_id = 2;
CALL review_item(@c_study,'pass',NULL,NULL);
UPDATE reviewer SET login_name = 'sa_demo_initial2' WHERE reviewer_id = 2;

UPDATE reviewer SET login_name = @demo_operator WHERE reviewer_id = 3;
CALL review_item(@a_study,'pass',NULL,NULL);
CALL review_item(@a_practice,'pass',NULL,NULL);
CALL review_item(@b_study,'pass',NULL,NULL);
CALL review_item(@c_study,'pass',NULL,NULL);
UPDATE reviewer SET login_name = 'sa_demo_counselor' WHERE reviewer_id = 3;

UPDATE reviewer SET login_name = @demo_operator WHERE reviewer_id = 4;
CALL review_item(@a_study,'pass',NULL,88);
CALL review_item(@a_practice,'pass',NULL,16);
CALL review_item(@b_study,'pass',NULL,95);
CALL review_item(@c_study,'pass',NULL,95);
UPDATE reviewer SET login_name = 'sa_demo_final' WHERE reviewer_id = 4;

UPDATE academic_year SET status = 'review', deadline_at = UTC_TIMESTAMP() WHERE year_id = '2025-2026';
CALL publish_year('2025-2026');

SELECT year_id, class_id, total_score, grade, rank_no
FROM published_results WHERE year_id = '2025-2026' ORDER BY rank_no, result_id;
SELECT * FROM class_result_distribution WHERE year_id = '2025-2026' ORDER BY class_id, grade;
SELECT * FROM project_submission_statistics WHERE year_id = '2025-2026' ORDER BY project_id;

-- v6 新增展示：提交留痕、学生视角公示、管理审计。
-- 提交记录：甲的表单有两条（首轮 + 驳回重提后的第 2 轮），乙丙各一条。
SELECT submission_id, form_id, round_no, submitted_at, item_count
FROM submission_log ORDER BY submission_id;
-- 学生可见的公示（含姓名学号，仅授权 sa_student / sa_analyst）。
SELECT student_id, student_name, class_id, total_score, grade, rank_no
FROM public_notice WHERE year_id = '2025-2026' ORDER BY rank_no, student_id;
-- 管理审计：主数据录入、学年状态推进与公示操作均留痕（展示最近 8 条）。
SELECT op_id, operator_login, action, target_id, detail, operated_at
FROM admin_operation_log ORDER BY op_id DESC LIMIT 8;
