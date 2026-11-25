-- 可选，只在刚创建的空库中运行一次。用有建档权限的安装账号执行。
-- 全部姓名、学号和材料均为虚构。账号名仅写入业务绑定表。
-- 真实口径演示：S = A(20) + B1(80) + B2(加分) + C(加分)；
-- 24级及以前 B1=平均绩点×20，25级及以后 B1=加权平均分×0.8；
-- 优秀比例按年级 20%，结果只有优秀/合格/不合格。
USE student_assessment;
SET @demo_operator = SUBSTRING_INDEX(USER(), '@', 1);

INSERT INTO class_group VALUES ('IM01','信息管理一班'), ('IM02','信息管理二班');
INSERT INTO student(student_id, student_name, class_id, grade_year, login_name) VALUES
    ('S001','演示学生甲','IM01',2024,'sa_demo_s001'),
    ('S002','演示学生乙','IM01',2024,'sa_demo_s002'),
    ('S003','演示学生丙','IM02',2024,'sa_demo_s003'),
    ('S004','演示学生丁','IM02',2024,'sa_demo_s004'),
    ('S005','演示学生戊','IM01',2024,'sa_demo_s005'),
    ('S006','演示学生己','IM01',2025,'sa_demo_s006'),
    ('S007','演示学生庚','IM01',2025,'sa_demo_s007'),
    ('S008','演示学生辛','IM02',2025,'sa_demo_s008'),
    ('S009','演示学生壬','IM02',2025,'sa_demo_s009'),
    ('S010','演示学生癸','IM01',2025,'sa_demo_s010');
INSERT INTO reviewer(reviewer_id, reviewer_name, review_role, class_id, login_name) VALUES
    (1,'一班初审员','initial','IM01','sa_demo_initial1'),
    (2,'二班初审员','initial','IM02','sa_demo_initial2'),
    (3,'院系辅导员','counselor',NULL,'sa_demo_counselor'),
    (4,'院系终审员','final',NULL,'sa_demo_final');

INSERT INTO assessment_rule
    (rule_id, rule_name, version_no, cohort, b1_formula, excellent_ratio, a_cap, b1_cap, formula_note, effective_on)
VALUES
    (1,'信息管理系学生素质综合测评（24级及以前）','2026.1','le2024','gpa_x20',0.20,20,80,
     'S=A+B1+B2+C；B1=测评学年课程平均绩点×20；优秀不超过年级20%','2026-05-29'),
    (2,'信息管理系学生素质综合测评（25级及以后）','2026.1','ge2025','weighted_x08',0.20,20,80,
     'S=A+B1+B2+C；B1=测评学年课程加权平均分×0.8；优秀不超过年级20%','2026-05-29');

INSERT INTO assessment_project
    (project_id, rule_id, component, rule_key, project_name, category, score_cap, total_cap, max_items, evidence_required, evidence_requirement)
VALUES
    (101,1,'B2','paper','学术论文','学术科研',6,NULL,NULL,TRUE,'论文全文或录用证明'),
    (102,1,'B2','book','学术著作','学术科研',10,NULL,NULL,TRUE,'著作封面/出版证明'),
    (103,1,'B2','project','科研课题','学术科研',3,NULL,NULL,TRUE,'立项/结项证明'),
    (104,1,'B2','competition','学术竞赛','学术科研',3.5,NULL,2,TRUE,'获奖证书'),
    (105,1,'B2','ip','知识产权','学术科研',2,NULL,2,TRUE,'授权证书'),
    (111,1,'C','social_work','社会工作','实践能力',4,NULL,1,TRUE,'任职证明'),
    (112,1,'C','volunteer','志愿服务','实践能力',1,NULL,1,TRUE,'志愿时长证明'),
    (113,1,'C','practice','实践活动','实践能力',1,NULL,7,TRUE,'获奖/参与证明'),
    (201,2,'B2','paper','学术论文','学术科研',6,NULL,NULL,TRUE,'论文全文或录用证明'),
    (202,2,'B2','book','学术著作','学术科研',10,NULL,NULL,TRUE,'著作封面/出版证明'),
    (203,2,'B2','project','科研课题','学术科研',3,NULL,NULL,TRUE,'立项/结项证明'),
    (204,2,'B2','competition','学术竞赛','学术科研',3.5,NULL,2,TRUE,'获奖证书'),
    (205,2,'B2','ip','知识产权','学术科研',2,NULL,2,TRUE,'授权证书'),
    (211,2,'C','social_work','社会工作','实践能力',4,NULL,1,TRUE,'任职证明'),
    (212,2,'C','volunteer','志愿服务','实践能力',1,NULL,1,TRUE,'志愿时长证明'),
    (213,2,'C','practice','实践活动','实践能力',1,NULL,7,TRUE,'获奖/参与证明');

INSERT INTO academic_year(year_id, year_name, starts_on, ends_on, opens_at, deadline_at, status) VALUES
    ('2025-2026','2025–2026 学年','2025-09-01','2026-08-31',
     UTC_TIMESTAMP() - INTERVAL 1 DAY, UTC_TIMESTAMP() + INTERVAL 1 DAY,'open'),
    ('2026-2027','2026–2027 学年','2026-09-01','2027-08-31',
     UTC_TIMESTAMP() - INTERVAL 1 DAY, UTC_TIMESTAMP() + INTERVAL 30 DAY,'open');

-- A/B1 基础分：24级用绩点，25级用加权平均分；丙、辛分别标记为不合格。
INSERT INTO student_year_assessment
    (student_id, year_id, class_id, rule_id, a_score, b1_input, a_failed, academic_failed)
VALUES
    ('S001','2025-2026','IM01',1,18.5,3.90,FALSE,FALSE),
    ('S002','2025-2026','IM01',1,18.0,3.70,FALSE,FALSE),
    ('S003','2025-2026','IM02',1,15.0,2.50,TRUE,FALSE),
    ('S004','2025-2026','IM02',1,17.0,3.40,FALSE,FALSE),
    ('S005','2025-2026','IM01',1,17.5,3.60,FALSE,FALSE),
    ('S006','2025-2026','IM01',2,18.5,92.0,FALSE,FALSE),
    ('S007','2025-2026','IM01',2,18.0,88.0,FALSE,FALSE),
    ('S008','2025-2026','IM02',2,14.0,55.0,FALSE,TRUE),
    ('S009','2025-2026','IM02',2,17.0,90.0,FALSE,FALSE),
    ('S010','2025-2026','IM01',2,17.5,85.0,FALSE,FALSE);

-- 两条 B2 加分演示：甲的论文、己的竞赛。
UPDATE student SET login_name = @demo_operator WHERE student_id = 'S001';
CALL save_form('2025-2026','甲的综测表');
CALL save_item('2025-2026',NULL,101,'SCI 论文一篇，第一作者，已录用',2.4,'2026-03-01');
SET @s001_item = LAST_INSERT_ID();
CALL add_evidence('2025-2026',@s001_item,'论文录用证明.txt',_binary 'Synthetic paper proof');
CALL submit_form('2025-2026');
UPDATE student SET login_name = 'sa_demo_s001' WHERE student_id = 'S001';

UPDATE student SET login_name = @demo_operator WHERE student_id = 'S006';
CALL save_form('2025-2026','己的综测表');
CALL save_item('2025-2026',NULL,204,'校级竞赛一等奖，团队3人',0.67,'2026-04-10');
SET @s006_item = LAST_INSERT_ID();
CALL add_evidence('2025-2026',@s006_item,'竞赛获奖证书.txt',_binary 'Synthetic award proof');
CALL submit_form('2025-2026');
UPDATE student SET login_name = 'sa_demo_s006' WHERE student_id = 'S006';

-- 三级审核：班级初审 → 辅导员复审 → 院系终审。
UPDATE reviewer SET login_name = @demo_operator WHERE reviewer_id = 1;
CALL review_item(@s001_item,'pass',NULL,NULL);
CALL review_item(@s006_item,'pass',NULL,NULL);
UPDATE reviewer SET login_name = 'sa_demo_initial1' WHERE reviewer_id = 1;

UPDATE reviewer SET login_name = @demo_operator WHERE reviewer_id = 3;
CALL review_item(@s001_item,'pass',NULL,NULL);
CALL review_item(@s006_item,'pass',NULL,NULL);
UPDATE reviewer SET login_name = 'sa_demo_counselor' WHERE reviewer_id = 3;

UPDATE reviewer SET login_name = @demo_operator WHERE reviewer_id = 4;
CALL review_item(@s001_item,'pass',NULL,2.4);
CALL review_item(@s006_item,'pass',NULL,0.67);
UPDATE reviewer SET login_name = 'sa_demo_final' WHERE reviewer_id = 4;

UPDATE academic_year SET status = 'review', deadline_at = UTC_TIMESTAMP() WHERE year_id = '2025-2026';
CALL publish_year('2025-2026');

SELECT year_id, student_id, grade_year, total_score, grade, rank_no
FROM published_results WHERE year_id = '2025-2026'
ORDER BY grade_year DESC, rank_no;

SELECT r.student_id, cs.component, cs.score
FROM assessment_result r JOIN component_score cs USING (result_id)
JOIN academic_year y USING (year_id)
WHERE y.year_id = '2025-2026'
ORDER BY r.student_id, FIELD(cs.component, 'A','B1','B2','C');

SELECT student_id, student_name, class_id, total_score, grade, rank_no
FROM public_notice WHERE year_id = '2025-2026' ORDER BY rank_no, student_id;

SELECT sl.submission_id, sl.form_id, sl.round_no, sl.submitted_at,
       (SELECT COUNT(*) FROM submission_snapshot_item si
        WHERE si.submission_id = sl.submission_id) AS item_count
FROM submission_log sl ORDER BY sl.submission_id;

CALL verify_publication('2025-2026');
SELECT rule_id, rule_name, version_no, root_rule_id, depth, version_path
FROM rule_version_chain ORDER BY rule_id;
SELECT * FROM evidence_duplicates;
SELECT entity_type, entity_id, old_status, new_status, changed_by
FROM status_change_log ORDER BY change_id DESC LIMIT 8;
