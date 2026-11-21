-- MySQL 8.4 · 学生综合测评数据库
-- 3NF 优化：删除为"复合外键钉住 rule_id"引入的冗余属性，全部表至少满足 3NF
-- 与原版的差异：
--   application_form  删除 rule_id（year_id → rule_id 违反 2NF）
--   application_item  删除 rule_id（form_id/project_id → rule_id 传递依赖违反 3NF）
--   assessment_result 删除 rule_id（2NF）、grade（(rule_id,total_score) → grade 违反 3NF）
--   project_score     删除 rule_id（2NF）、weighted_score（(project_id,approved_score) → weighted_score 违反 3NF）
--   privacy_access_log 删除 login_account（reviewer_id → login_account 违反 3NF）
--   evidence.sha256  STORED → VIRTUAL（file_body → sha256 为派生冗余，不再落盘）
--   academic_year / assessment_project 删除冗余 UNIQUE 复合键（原仅为复合外键提供索引）
--   新增 application_item 触发器，替代原复合外键对"条目项目与表单学年规则一致"的声明式约束
--   等级 grade 与加权分 weighted_score 改为在视图/存储过程中按规则实时计算
-- 设计优化 v2（2026-11-16）：
--   student_year_assessment 删除 status 列（与 application_form.status 双份冗余状态，
--     相应同步 UPDATE 一并移除，申报状态一律以 application_form 为准）
--   student / reviewer 新增跨表登录名互斥触发器（防止同一数据库账号既申报又审核）
--   review_item 终审核定分增加 score_cap 封顶校验（不再由 publish 静默截断）
--   withdraw_item 同时将条目证明材料置为 inactive（避免撤回后材料滞留）
--   privacy_access_log 增加 (reviewer_id, accessed_at) 审计索引
--   assessment_rule 增加 parent_rule_id 自引用外键（规则版本链追溯）
-- 特色功能 v3（2026-11-16）：
--   新增过程 review_item_diff：驳回重提对比，把最近一次驳回快照与当前条目并排输出，
--     字段级标出改动（项目、细节、申报分、发生日期、附件数量），审核人一眼定位改动
--   新增视图 student_progress（跨学年个人进展，LAG 窗口函数）与聚合视图
--     class_progress_stats（班级进步统计，不含个人标识），过程 my_progress（学生自查）
--   新增事件 open_due_years / review_due_years：由 MySQL 事件调度器自动推进学年状态
--     （到开放时刻自动开启、过截止时刻自动转入审核），应用层不再手工切换
-- 补齐原始需求缺口 v4（2026-11-19）：
--   新增提交记录表 submission_log：submit_form 每次提交留痕（轮次、时间、条目数、快照）
--   新增公示视图 public_notice：仅学年 published（全部审核完成、统计结束）后可见，
--     含学号姓名供全体学生查看；原 published_results 匿名口径仍供分析员使用
--   新增过程 my_evidence（学生查看本人证明材料清单，仅元数据不含文件内容）、
--     my_submission_history（学生查看本人各轮提交记录）
--   新增角色 sa_admin：主数据可读写（触发器继续守住不变量），业务数据只读监控；
--     证明材料仅授权元数据列（不含 file_body），隐私访问日志可查
--   新增过程 abandon_form：申报截止后管理员可作废未完成表单（status → void），
--     避免个别学生卡死整学年公示；是否公示一律以 deadline 为依据
-- 实现细节风险点加固 v5（2026-11-19）：
--   review_item 终审通过时校验"同表单同项目已通过条目核定分合计 + 本次核定分 ≤ 封顶分"，
--     并锁定同表单全部条目串行化终审，从源头消除 calculation_input 的 LEAST 静默截断
--   application_item 触发器新增硬性校验：申报分不得超过项目封顶分（减轻人工审核负担）
--   keep_year_rule 新增：学年启用后不可修改起止日期与开放时刻；同状态下截止时间
--     只许后延（open→review 的同一句 UPDATE 允许把截止时间提前到当前时刻，
--     即 02 演示数据所用的"手工提前关闭申报"快进模式）
--   student_progress 增加 rule_id/version_no 列，提示跨学年分数差的可比性
--   排名改用 DENSE_RANK：同分并列且名次连续（1,1,2），避免 RANK 的名次空洞（1,1,3）
-- 基础问题收尾 v6（2026-11-20）：
--   完整性：academic_year 防日期区间重叠触发器；assessment_project 权重合计≤1 编辑期校验
--   审计闭环：access_denied_log（越权尝试失败也留痕，审核过程在回滚后补记，SIGNAL 消息不变）；
--     admin_operation_log（abandon_form/publish_year 过程内记录 + 6 张主数据表 18 个 AFTER 触发器，
--     学年状态变更 old→new 全程留痕；EVENT 自动推进时操作者记为事件定义者账号）
--   运维：event_scheduler 改 SET PERSIST（重启不丢）；admin_stalled_forms 视图定位卡公示的表单
--   配套（仓库同步目录）：demo.py 增 sa_demo_admin 账号与 --event-scheduler=ON 启动参数；
--     02 追加新功能展示查询；tests/test_constraints.py 约束负例套件；使用说明.md 全面同步
CREATE DATABASE student_assessment CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;
USE student_assessment;

CREATE TABLE class_group (
    class_id VARCHAR(24) PRIMARY KEY,
    class_name VARCHAR(100) NOT NULL
) COMMENT='班级';

CREATE TABLE student (
    student_id VARCHAR(24) PRIMARY KEY,
    student_name VARCHAR(80) NOT NULL,
    class_id VARCHAR(24) NOT NULL,
    login_name VARCHAR(32) CHARACTER SET ascii COLLATE ascii_bin NOT NULL UNIQUE,
    CHECK (login_name REGEXP '^[A-Za-z0-9_]+$'),
    FOREIGN KEY (class_id) REFERENCES class_group(class_id)
) COMMENT='学生';

CREATE TABLE assessment_rule (
    rule_id INT UNSIGNED PRIMARY KEY,
    rule_name VARCHAR(100) NOT NULL,
    version_no VARCHAR(30) NOT NULL,
    formula_note TEXT NOT NULL,
    effective_on DATE NOT NULL,
    excellent_min DECIMAL(5,2) NOT NULL DEFAULT 90,
    good_min DECIMAL(5,2) NOT NULL DEFAULT 80,
    pass_min DECIMAL(5,2) NOT NULL DEFAULT 60,
    parent_rule_id INT UNSIGNED NULL COMMENT '上一版本规则，NULL 表示该规则的第一个版本',
    UNIQUE (rule_name, version_no),
    CHECK (excellent_min <= 100 AND excellent_min > good_min
           AND good_min > pass_min AND pass_min >= 0),
    FOREIGN KEY (parent_rule_id) REFERENCES assessment_rule(rule_id)
) COMMENT='测评规则';

CREATE TABLE academic_year (
    year_id VARCHAR(24) PRIMARY KEY,
    year_name VARCHAR(100) NOT NULL,
    starts_on DATE NOT NULL,
    ends_on DATE NOT NULL,
    opens_at DATETIME NOT NULL COMMENT 'UTC',
    deadline_at DATETIME NOT NULL COMMENT 'UTC，不含此刻',
    status ENUM('draft','open','review','published') NOT NULL DEFAULT 'draft',
    rule_id INT UNSIGNED NOT NULL,
    published_at DATETIME(6) NULL COMMENT 'UTC',
    CHECK (starts_on <= ends_on AND opens_at < deadline_at),
    FOREIGN KEY (rule_id) REFERENCES assessment_rule(rule_id)
) COMMENT='学年';

CREATE TABLE assessment_project (
    project_id INT UNSIGNED PRIMARY KEY,
    rule_id INT UNSIGNED NOT NULL,
    project_name VARCHAR(100) NOT NULL,
    category VARCHAR(80) NOT NULL,
    weight DECIMAL(7,6) NOT NULL,
    score_cap DECIMAL(10,2) NOT NULL,
    evidence_required BOOLEAN NOT NULL DEFAULT FALSE,
    evidence_requirement VARCHAR(255) NULL,
    CHECK (weight > 0 AND weight <= 1 AND score_cap > 0 AND evidence_required IN (0,1)),
    UNIQUE (rule_id, project_name),
    FOREIGN KEY (rule_id) REFERENCES assessment_rule(rule_id)
) COMMENT='测评项目';

CREATE TABLE student_year_assessment (
    student_id VARCHAR(24) NOT NULL,
    year_id VARCHAR(24) NOT NULL,
    class_id VARCHAR(24) NOT NULL COMMENT '建档时的班级快照',
    created_at DATETIME(6) NOT NULL DEFAULT (UTC_TIMESTAMP(6)),
    PRIMARY KEY (student_id, year_id),
    KEY (year_id, class_id),
    FOREIGN KEY (student_id) REFERENCES student(student_id),
    FOREIGN KEY (year_id) REFERENCES academic_year(year_id),
    FOREIGN KEY (class_id) REFERENCES class_group(class_id)
) COMMENT='学生学年测评（建档锚点与班级快照；申报状态一律见 application_form）';

CREATE TABLE application_form (
    form_id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    student_id VARCHAR(24) NOT NULL,
    year_id VARCHAR(24) NOT NULL,
    notes TEXT NULL,
    submitted_at DATETIME(6) NULL,
    status ENUM('draft','submitted','completed','void') NOT NULL DEFAULT 'draft',
    modified_at DATETIME(6) NOT NULL DEFAULT (UTC_TIMESTAMP(6)),
    round_no INT UNSIGNED NOT NULL DEFAULT 0,
    UNIQUE (student_id, year_id),
    FOREIGN KEY (student_id, year_id) REFERENCES student_year_assessment(student_id, year_id),
    FOREIGN KEY (year_id) REFERENCES academic_year(year_id)
) COMMENT='填报表';

-- 提交记录：学生每学年每一次提交的留痕（轮次、时间、条目数、提交时的申报快照），
-- 仅由 submit_form 写入，此后不可修改，供追溯与审计。
CREATE TABLE submission_log (
    submission_id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    form_id BIGINT UNSIGNED NOT NULL,
    round_no INT UNSIGNED NOT NULL,
    submitted_at DATETIME(6) NOT NULL,
    item_count INT UNSIGNED NOT NULL,
    snapshot JSON NOT NULL COMMENT '提交时各条目的申报快照',
    UNIQUE (form_id, round_no),
    FOREIGN KEY (form_id) REFERENCES application_form(form_id)
) COMMENT='提交记录';

CREATE TABLE application_item (
    item_id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    form_id BIGINT UNSIGNED NOT NULL,
    project_id INT UNSIGNED NOT NULL,
    details TEXT NOT NULL,
    claimed_score DECIMAL(10,2) NOT NULL,
    occurred_on DATE NOT NULL,
    status ENUM('draft','initial_pending','counselor_pending','final_pending',
                'returned','approved','withdrawn') NOT NULL DEFAULT 'draft',
    final_score DECIMAL(10,2) NULL,
    CHECK (claimed_score >= 0 AND (final_score IS NULL OR final_score >= 0)),
    KEY (form_id, status),
    KEY (project_id, status),
    FOREIGN KEY (form_id) REFERENCES application_form(form_id),
    FOREIGN KEY (project_id) REFERENCES assessment_project(project_id)
) COMMENT='填报内容';

CREATE TABLE evidence (
    evidence_id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    item_id BIGINT UNSIGNED NOT NULL,
    file_name VARCHAR(255) NOT NULL,
    storage_location VARCHAR(120) NOT NULL UNIQUE COMMENT '库内对象标识',
    file_body MEDIUMBLOB NOT NULL,
    sha256 CHAR(64) CHARACTER SET ascii GENERATED ALWAYS AS (SHA2(file_body, 256)) VIRTUAL,
    uploaded_at DATETIME(6) NOT NULL DEFAULT (UTC_TIMESTAMP(6)),
    active BOOLEAN NOT NULL DEFAULT TRUE,
    CHECK (OCTET_LENGTH(file_body) BETWEEN 1 AND 5242880 AND active IN (0,1)),
    KEY (item_id, active),
    FOREIGN KEY (item_id) REFERENCES application_item(item_id)
) COMMENT='证明材料';

CREATE TABLE reviewer (
    reviewer_id INT UNSIGNED PRIMARY KEY,
    reviewer_name VARCHAR(80) NOT NULL,
    review_role ENUM('initial','counselor','final') NOT NULL,
    class_id VARCHAR(24) NULL COMMENT '初审必填，其他角色可选；空表示院系范围',
    login_name VARCHAR(32) CHARACTER SET ascii COLLATE ascii_bin NOT NULL UNIQUE,
    CHECK (login_name REGEXP '^[A-Za-z0-9_]+$' AND (review_role <> 'initial' OR class_id IS NOT NULL)),
    FOREIGN KEY (class_id) REFERENCES class_group(class_id)
) COMMENT='审核人员';

CREATE TABLE review_record (
    review_id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    item_id BIGINT UNSIGNED NOT NULL,
    reviewer_id INT UNSIGNED NOT NULL,
    stage ENUM('initial','counselor','final') NOT NULL,
    round_no INT UNSIGNED NOT NULL,
    reviewed_at DATETIME(6) NOT NULL DEFAULT (UTC_TIMESTAMP(6)),
    decision ENUM('pass','return') NOT NULL,
    opinion TEXT NULL,
    approved_score DECIMAL(10,2) NULL,
    reviewed_item JSON NOT NULL COMMENT '该次审核看到的申报及附件编号快照',
    UNIQUE (item_id, round_no, stage),
    CHECK (round_no > 0 AND
      ((stage = 'final' AND decision = 'pass' AND approved_score IS NOT NULL AND approved_score >= 0)
       OR ((stage <> 'final' OR decision <> 'pass') AND approved_score IS NULL))),
    KEY (reviewer_id, reviewed_at),
    FOREIGN KEY (item_id) REFERENCES application_item(item_id),
    FOREIGN KEY (reviewer_id) REFERENCES reviewer(reviewer_id)
) COMMENT='审核记录';

CREATE TABLE assessment_result (
    result_id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    student_id VARCHAR(24) NOT NULL,
    year_id VARCHAR(24) NOT NULL,
    total_score DECIMAL(5,2) NOT NULL,
    rank_no INT UNSIGNED NOT NULL,
    generated_at DATETIME(6) NOT NULL,
    UNIQUE (student_id, year_id),
    KEY (year_id, rank_no),
    CHECK (total_score BETWEEN 0 AND 100 AND rank_no > 0),
    FOREIGN KEY (student_id, year_id) REFERENCES student_year_assessment(student_id, year_id),
    FOREIGN KEY (year_id) REFERENCES academic_year(year_id)
) COMMENT='测评总结果（等级 grade 由总分与规则阈值实时计算，见视图）';

CREATE TABLE project_score (
    result_id BIGINT UNSIGNED NOT NULL,
    project_id INT UNSIGNED NOT NULL,
    raw_score DECIMAL(18,2) NOT NULL,
    approved_score DECIMAL(10,2) NOT NULL,
    PRIMARY KEY (result_id, project_id),
    CHECK (raw_score >= 0 AND approved_score >= 0),
    FOREIGN KEY (result_id) REFERENCES assessment_result(result_id),
    FOREIGN KEY (project_id) REFERENCES assessment_project(project_id)
) COMMENT='项目得分（加权分 weighted_score 查询时按项目权重实时计算）';

CREATE TABLE privacy_access_log (
    access_id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    reviewer_id INT UNSIGNED NOT NULL,
    item_id BIGINT UNSIGNED NOT NULL,
    evidence_id BIGINT UNSIGNED NULL,
    accessed_at DATETIME(6) NOT NULL DEFAULT (UTC_TIMESTAMP(6)),
    KEY (reviewer_id, accessed_at),
    FOREIGN KEY (reviewer_id) REFERENCES reviewer(reviewer_id),
    FOREIGN KEY (item_id) REFERENCES application_item(item_id),
    FOREIGN KEY (evidence_id) REFERENCES evidence(evidence_id)
) COMMENT='成功读取申报详情或附件的访问日志';

-- 越权访问尝试日志：失败也留痕。故意不设外键——审计写入绝不能因目标不存在而失败。
-- 由审核类过程的 EXIT HANDLER 在 ROLLBACK 之后补记（否则日志会随事务一起回滚）。
CREATE TABLE access_denied_log (
    denied_id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    login_name VARCHAR(32) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    item_id BIGINT UNSIGNED NULL,
    evidence_id BIGINT UNSIGNED NULL,
    reason VARCHAR(100) NOT NULL,
    denied_at DATETIME(6) NOT NULL DEFAULT (UTC_TIMESTAMP(6)),
    KEY (login_name, denied_at)
) COMMENT='越权访问尝试日志';

-- 管理员操作与主数据变更审计：abandon_form/publish_year 过程内记录，
-- 6 张主数据表的 AFTER INSERT/UPDATE/DELETE 触发器记录数据变更（含学年状态 old→new）。
-- 故意不设外键，审计写入永不失败；被删除对象的历史记录仍可追溯。
CREATE TABLE admin_operation_log (
    op_id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    operator_login VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    action VARCHAR(40) NOT NULL,
    target_id VARCHAR(64) NULL,
    detail VARCHAR(500) NULL,
    operated_at DATETIME(6) NOT NULL DEFAULT (UTC_TIMESTAMP(6)),
    KEY (operator_login, operated_at),
    KEY (action, operated_at)
) COMMENT='管理员操作与主数据变更审计';

DELIMITER $$

-- 内部过程。角色没有调用权限。每个写操作按学年串行，避免提交、审核、公示交叉。
CREATE PROCEDURE lock_assessment_year(
    IN p_year VARCHAR(24), OUT p_rule INT UNSIGNED, OUT p_status VARCHAR(16),
    OUT p_opens DATETIME, OUT p_deadline DATETIME
)
BEGIN
    SET p_rule = NULL;
    SELECT rule_id, status, opens_at, deadline_at INTO p_rule, p_status, p_opens, p_deadline
    FROM academic_year WHERE year_id = p_year FOR UPDATE;
    IF p_rule IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '学年不存在';
    END IF;
END$$

CREATE PROCEDURE lock_student_form(
    IN p_year VARCHAR(24), OUT p_student VARCHAR(24), OUT p_rule INT UNSIGNED,
    OUT p_form BIGINT UNSIGNED, OUT p_form_status VARCHAR(16)
)
BEGIN
    DECLARE v_status VARCHAR(16);
    DECLARE v_opens, v_deadline DATETIME;
    SET p_student = NULL, p_form = NULL, p_form_status = NULL;
    SELECT student_id INTO p_student FROM student WHERE login_name = SUBSTRING_INDEX(USER(), '@', 1);
    IF p_student IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '当前数据库账号未绑定学生';
    END IF;
    CALL lock_assessment_year(p_year, p_rule, v_status, v_opens, v_deadline);
    IF v_status <> 'open' OR UTC_TIMESTAMP() < v_opens OR UTC_TIMESTAMP() >= v_deadline THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '当前不在申报时间内';
    END IF;
    SELECT form_id, status INTO p_form, p_form_status
    FROM application_form WHERE student_id = p_student AND year_id = p_year FOR UPDATE;
END$$

CREATE PROCEDURE save_form(IN p_year VARCHAR(24), IN p_notes TEXT)
BEGIN
    DECLARE v_student VARCHAR(24);
    DECLARE v_rule INT UNSIGNED;
    DECLARE v_form BIGINT UNSIGNED;
    DECLARE v_status VARCHAR(16);
    DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;
    SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
    START TRANSACTION;
    CALL lock_student_form(p_year, v_student, v_rule, v_form, v_status);
    IF v_form IS NULL THEN
        INSERT INTO student_year_assessment(student_id, year_id, class_id)
        SELECT student_id, p_year, class_id FROM student WHERE student_id = v_student;
        INSERT INTO application_form(student_id, year_id, notes)
        VALUES(v_student, p_year, p_notes);
        SET v_form = LAST_INSERT_ID();
    ELSEIF v_status = 'draft' THEN
        UPDATE application_form SET notes = p_notes, modified_at = UTC_TIMESTAMP(6) WHERE form_id = v_form;
    ELSE
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '请先撤回至草稿再修改表单';
    END IF;
    COMMIT;
    SELECT v_form AS form_id;
END$$

CREATE PROCEDURE reopen_form(IN p_year VARCHAR(24))
BEGIN
    DECLARE v_student VARCHAR(24);
    DECLARE v_rule INT UNSIGNED;
    DECLARE v_form BIGINT UNSIGNED;
    DECLARE v_status VARCHAR(16);
    DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;
    SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
    START TRANSACTION;
    CALL lock_student_form(p_year, v_student, v_rule, v_form, v_status);
    IF v_form IS NULL OR v_status <> 'submitted' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '只有已提交表单可撤回';
    END IF;
    UPDATE application_item SET status = 'draft', final_score = NULL
    WHERE form_id = v_form AND status <> 'withdrawn';
    UPDATE application_form SET status = 'draft', modified_at = UTC_TIMESTAMP(6) WHERE form_id = v_form;
    COMMIT;
END$$

CREATE PROCEDURE save_item(
    IN p_year VARCHAR(24), IN p_item BIGINT UNSIGNED, IN p_project INT UNSIGNED,
    IN p_details TEXT, IN p_claim DECIMAL(10,2), IN p_date DATE
)
BEGIN
    DECLARE v_student VARCHAR(24);
    DECLARE v_rule INT UNSIGNED;
    DECLARE v_form, v_item BIGINT UNSIGNED;
    DECLARE v_status VARCHAR(16);
    DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;
    SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
    START TRANSACTION;
    CALL lock_student_form(p_year, v_student, v_rule, v_form, v_status);
    IF v_form IS NULL OR v_status <> 'draft' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '请先建立或撤回本学年的草稿表单';
    END IF;
    IF p_details IS NULL OR CHAR_LENGTH(TRIM(p_details)) = 0 OR p_claim IS NULL OR p_claim < 0
       OR p_date IS NULL OR NOT EXISTS (
           SELECT 1 FROM academic_year WHERE year_id = p_year AND p_date BETWEEN starts_on AND ends_on
       ) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '细节、申报分值或发生日期无效';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM assessment_project WHERE project_id = p_project AND rule_id = v_rule) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '项目不属于本学年规则';
    END IF;
    IF p_item IS NULL THEN
        INSERT INTO application_item(form_id, project_id, details, claimed_score, occurred_on)
        VALUES(v_form, p_project, p_details, p_claim, p_date);
        SET v_item = LAST_INSERT_ID();
    ELSE
        IF NOT EXISTS (SELECT 1 FROM application_item
                       WHERE item_id = p_item AND form_id = v_form AND status = 'draft') THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '条目不在本人当前草稿内';
        END IF;
        UPDATE application_item
        SET project_id = p_project, details = p_details, claimed_score = p_claim, occurred_on = p_date
        WHERE item_id = p_item;
        SET v_item = p_item;
    END IF;
    UPDATE application_form SET modified_at = UTC_TIMESTAMP(6) WHERE form_id = v_form;
    COMMIT;
    SELECT v_item AS item_id;
END$$

CREATE PROCEDURE withdraw_item(IN p_year VARCHAR(24), IN p_item BIGINT UNSIGNED)
BEGIN
    DECLARE v_student VARCHAR(24);
    DECLARE v_rule INT UNSIGNED;
    DECLARE v_form BIGINT UNSIGNED;
    DECLARE v_status VARCHAR(16);
    DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;
    SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
    START TRANSACTION;
    CALL lock_student_form(p_year, v_student, v_rule, v_form, v_status);
    IF v_form IS NULL OR v_status <> 'draft' OR NOT EXISTS (
        SELECT 1 FROM application_item WHERE item_id = p_item AND form_id = v_form AND status = 'draft'
    ) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '只能移除本人草稿内的条目';
    END IF;
    UPDATE application_item SET status = 'withdrawn' WHERE item_id = p_item;
    UPDATE evidence SET active = FALSE WHERE item_id = p_item;
    UPDATE application_form SET modified_at = UTC_TIMESTAMP(6) WHERE form_id = v_form;
    COMMIT;
END$$

CREATE PROCEDURE add_evidence(
    IN p_year VARCHAR(24), IN p_item BIGINT UNSIGNED, IN p_name VARCHAR(255), IN p_data MEDIUMBLOB
)
BEGIN
    DECLARE v_student VARCHAR(24);
    DECLARE v_rule INT UNSIGNED;
    DECLARE v_form, v_evidence BIGINT UNSIGNED;
    DECLARE v_status VARCHAR(16);
    DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;
    SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
    START TRANSACTION;
    CALL lock_student_form(p_year, v_student, v_rule, v_form, v_status);
    IF v_form IS NULL OR v_status <> 'draft' OR NOT EXISTS (
        SELECT 1 FROM application_item WHERE item_id = p_item AND form_id = v_form AND status = 'draft'
    ) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '只能为本人草稿内的条目上传材料';
    END IF;
    IF p_name IS NULL OR CHAR_LENGTH(TRIM(p_name)) = 0 OR p_data IS NULL
       OR OCTET_LENGTH(p_data) NOT BETWEEN 1 AND 5242880 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '材料须有名称且大小介于 1 字节与 5 MiB';
    END IF;
    INSERT INTO evidence(item_id, file_name, storage_location, file_body)
    VALUES(p_item, p_name, CONCAT('db://evidence/', UUID()), p_data);
    SET v_evidence = LAST_INSERT_ID();
    UPDATE application_form SET modified_at = UTC_TIMESTAMP(6) WHERE form_id = v_form;
    COMMIT;
    SELECT v_evidence AS evidence_id;
END$$

CREATE PROCEDURE remove_evidence(IN p_year VARCHAR(24), IN p_evidence BIGINT UNSIGNED)
BEGIN
    DECLARE v_student VARCHAR(24);
    DECLARE v_rule INT UNSIGNED;
    DECLARE v_form BIGINT UNSIGNED;
    DECLARE v_status VARCHAR(16);
    DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;
    SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
    START TRANSACTION;
    CALL lock_student_form(p_year, v_student, v_rule, v_form, v_status);
    IF v_form IS NULL OR v_status <> 'draft' OR NOT EXISTS (
        SELECT 1 FROM evidence e JOIN application_item i USING (item_id)
        WHERE e.evidence_id = p_evidence AND e.active AND i.form_id = v_form AND i.status = 'draft'
    ) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '只能移除本人草稿内的有效材料';
    END IF;
    UPDATE evidence SET active = FALSE WHERE evidence_id = p_evidence;
    UPDATE application_form SET modified_at = UTC_TIMESTAMP(6) WHERE form_id = v_form;
    COMMIT;
END$$

CREATE PROCEDURE submit_form(IN p_year VARCHAR(24))
BEGIN
    DECLARE v_student VARCHAR(24);
    DECLARE v_rule INT UNSIGNED;
    DECLARE v_form BIGINT UNSIGNED;
    DECLARE v_status VARCHAR(16);
    DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;
    SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
    START TRANSACTION;
    CALL lock_student_form(p_year, v_student, v_rule, v_form, v_status);
    IF v_form IS NULL OR v_status <> 'draft' OR NOT EXISTS (
        SELECT 1 FROM application_item WHERE form_id = v_form AND status = 'draft'
    ) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '只能提交至少有一条申报内容的草稿';
    END IF;
    IF EXISTS (
        SELECT 1 FROM application_item i JOIN assessment_project p USING (project_id)
        WHERE i.form_id = v_form AND i.status = 'draft' AND p.evidence_required
        AND NOT EXISTS (SELECT 1 FROM evidence e WHERE e.item_id = i.item_id AND e.active)
    ) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '请补齐必需的证明材料';
    END IF;
    UPDATE application_item SET status = 'initial_pending' WHERE form_id = v_form AND status = 'draft';
    UPDATE application_form SET status = 'submitted', round_no = round_no + 1,
        submitted_at = UTC_TIMESTAMP(6), modified_at = UTC_TIMESTAMP(6)
    WHERE form_id = v_form;
    INSERT INTO submission_log(form_id, round_no, submitted_at, item_count, snapshot)
    SELECT form_id, round_no, submitted_at,
           (SELECT COUNT(*) FROM application_item i
            WHERE i.form_id = v_form AND i.status = 'initial_pending'),
           COALESCE((SELECT JSON_ARRAYAGG(JSON_OBJECT('item_id', i.item_id,
                       'project_id', i.project_id, 'details', i.details,
                       'claimed_score', i.claimed_score, 'occurred_on', i.occurred_on))
                     FROM application_item i
                     WHERE i.form_id = v_form AND i.status = 'initial_pending'),
                    JSON_ARRAY())
    FROM application_form WHERE form_id = v_form;
    COMMIT;
END$$


-- 审核账号只能处理自己负责的班级和阶段。会话身份从 MySQL 登录获取。
CREATE PROCEDURE lock_review_item(
    IN p_item BIGINT UNSIGNED, OUT p_reviewer INT UNSIGNED, OUT p_stage VARCHAR(16),
    OUT p_item_status VARCHAR(24), OUT p_round INT UNSIGNED, OUT p_year_status VARCHAR(16)
)
BEGIN
    DECLARE v_year, v_class, v_scope VARCHAR(24);
    DECLARE v_rule INT UNSIGNED;
    DECLARE v_opens, v_deadline DATETIME;
    SET p_reviewer = NULL, v_year = NULL;
    SET @sa_denial_item = NULL, @sa_denial_evidence = NULL, @sa_denial_reason = NULL;
    SELECT reviewer_id, review_role, class_id INTO p_reviewer, p_stage, v_scope
    FROM reviewer WHERE login_name = SUBSTRING_INDEX(USER(), '@', 1);
    SELECT f.year_id INTO v_year
    FROM application_item i JOIN application_form f USING (form_id) WHERE i.item_id = p_item;
    IF p_reviewer IS NULL OR v_year IS NULL THEN
        SET @sa_denial_item = p_item, @sa_denial_reason = '账号未绑定审核人或条目不存在';
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '无权访问此申报条目';
    END IF;
    CALL lock_assessment_year(v_year, v_rule, p_year_status, v_opens, v_deadline);
    SELECT a.class_id, i.status, f.round_no INTO v_class, p_item_status, p_round
    FROM application_item i JOIN application_form f USING (form_id)
    JOIN student_year_assessment a ON a.student_id = f.student_id AND a.year_id = f.year_id
    WHERE i.item_id = p_item FOR UPDATE;
    IF (v_scope IS NOT NULL AND v_scope <> v_class) OR p_round = 0 OR p_item_status = 'draft'
       OR (p_item_status = 'withdrawn' AND NOT EXISTS (
           SELECT 1 FROM review_record WHERE item_id = p_item
       )) THEN
        SET @sa_denial_item = p_item, @sa_denial_reason = '班级范围或条目状态不符';
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '无权访问此申报条目';
    END IF;
END$$

CREATE PROCEDURE review_item(
    IN p_item BIGINT UNSIGNED, IN p_decision VARCHAR(12), IN p_opinion TEXT,
    IN p_final_score DECIMAL(10,2)
)
BEGIN
    DECLARE v_reviewer, v_round INT UNSIGNED;
    DECLARE v_stage, v_year_status VARCHAR(16);
    DECLARE v_item_status VARCHAR(24);
    DECLARE v_claim DECIMAL(10,2);
    DECLARE v_cap DECIMAL(10,2);
    DECLARE v_sum DECIMAL(10,2);
    DECLARE v_locked BIGINT UNSIGNED;
    DECLARE v_evidence_ids JSON;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        IF @sa_denial_reason IS NOT NULL THEN
            INSERT INTO access_denied_log(login_name, item_id, evidence_id, reason)
            VALUES (SUBSTRING_INDEX(USER(), '@', 1), @sa_denial_item, @sa_denial_evidence, @sa_denial_reason);
            SET @sa_denial_item = NULL, @sa_denial_evidence = NULL, @sa_denial_reason = NULL;
        END IF;
        RESIGNAL;
    END;
    SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
    START TRANSACTION;
    CALL lock_review_item(p_item, v_reviewer, v_stage, v_item_status, v_round, v_year_status);
    IF v_year_status NOT IN ('open','review') OR v_item_status <> CONCAT(v_stage, '_pending') THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '当前状态不能由该角色审核';
    END IF;
    IF p_decision IS NULL OR p_decision NOT IN ('pass','return')
       OR (p_decision = 'return' AND (p_opinion IS NULL OR CHAR_LENGTH(TRIM(p_opinion)) = 0)) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '请选择通过或驳回，驳回须填写意见';
    END IF;
    SELECT claimed_score INTO v_claim FROM application_item WHERE item_id = p_item;
    SELECT p.score_cap INTO v_cap
    FROM application_item i JOIN assessment_project p USING (project_id)
    WHERE i.item_id = p_item;
    IF v_stage = 'final' AND p_decision = 'pass' THEN
        IF p_final_score IS NULL OR p_final_score < 0 OR p_final_score > v_claim THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '终审核定分须介于零与申报分之间';
        END IF;
        IF p_final_score > v_cap THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '终审核定分不能超过项目封顶分';
        END IF;
        -- 锁定同表单全部条目，串行化终审核定，防止并发终审绕过下面的项目合计封顶校验
        SELECT MIN(item_id) INTO v_locked FROM application_item
        WHERE form_id = (SELECT form_id FROM application_item WHERE item_id = p_item)
        FOR UPDATE;
        -- 同表单同项目已通过条目的核定分合计 + 本次核定分不得超过项目封顶分，
        -- 从源头消除公示阶段 calculation_input 里 LEAST 的静默截断
        SELECT COALESCE(SUM(oi.final_score), 0) INTO v_sum
        FROM application_item oi
        WHERE oi.form_id = (SELECT form_id FROM application_item WHERE item_id = p_item)
          AND oi.project_id = (SELECT project_id FROM application_item WHERE item_id = p_item)
          AND oi.item_id <> p_item AND oi.status = 'approved';
        IF v_sum + p_final_score > v_cap THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '该项目核定分合计将超过封顶分';
        END IF;
    ELSEIF p_final_score IS NOT NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '只有终审通过时填写核定分';
    END IF;
    SELECT COALESCE(JSON_ARRAYAGG(evidence_id), JSON_ARRAY()) INTO v_evidence_ids
    FROM evidence WHERE item_id = p_item AND active;
    INSERT INTO review_record(item_id, reviewer_id, stage, round_no, decision, opinion,
                              approved_score, reviewed_item)
    SELECT item_id, v_reviewer, v_stage, v_round, p_decision, p_opinion, p_final_score,
           JSON_OBJECT('project_id', project_id, 'details', details, 'claimed_score', claimed_score,
                       'occurred_on', occurred_on, 'evidence_ids', v_evidence_ids)
    FROM application_item WHERE item_id = p_item;
    UPDATE application_item SET
        status = CASE WHEN p_decision = 'return' THEN 'returned'
                      WHEN v_stage = 'initial' THEN 'counselor_pending'
                      WHEN v_stage = 'counselor' THEN 'final_pending'
                      ELSE 'approved' END,
        final_score = p_final_score
    WHERE item_id = p_item;
    COMMIT;
END$$

CREATE PROCEDURE read_review_item(IN p_item BIGINT UNSIGNED)
BEGIN
    DECLARE v_reviewer, v_round INT UNSIGNED;
    DECLARE v_stage, v_year_status VARCHAR(16);
    DECLARE v_item_status VARCHAR(24);
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        IF @sa_denial_reason IS NOT NULL THEN
            INSERT INTO access_denied_log(login_name, item_id, evidence_id, reason)
            VALUES (SUBSTRING_INDEX(USER(), '@', 1), @sa_denial_item, @sa_denial_evidence, @sa_denial_reason);
            SET @sa_denial_item = NULL, @sa_denial_evidence = NULL, @sa_denial_reason = NULL;
        END IF;
        RESIGNAL;
    END;
    SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
    START TRANSACTION;
    CALL lock_review_item(p_item, v_reviewer, v_stage, v_item_status, v_round, v_year_status);
    INSERT INTO privacy_access_log(reviewer_id, item_id) VALUES(v_reviewer, p_item);
    SELECT i.item_id, f.year_id, f.student_id, s.student_name, f.notes, p.project_name,
           i.details, i.claimed_score, i.occurred_on, i.status, f.round_no, i.final_score
    FROM application_item i JOIN application_form f USING (form_id)
    JOIN student s USING (student_id) JOIN assessment_project p USING (project_id)
    WHERE i.item_id = p_item;
    SELECT evidence_id, file_name, sha256, uploaded_at, active FROM evidence
    WHERE item_id = p_item AND (active OR EXISTS (
        SELECT 1 FROM review_record r WHERE r.item_id = p_item
        AND JSON_CONTAINS(r.reviewed_item, CAST(evidence.evidence_id AS JSON), '$.evidence_ids')
    )) ORDER BY evidence_id;
    SELECT review_id, reviewer_id, stage, round_no, reviewed_at, decision, opinion, approved_score, reviewed_item
    FROM review_record WHERE item_id = p_item ORDER BY review_id;
    COMMIT;
END$$

CREATE PROCEDURE read_evidence(IN p_evidence BIGINT UNSIGNED)
BEGIN
    DECLARE v_item BIGINT UNSIGNED DEFAULT NULL;
    DECLARE v_reviewer, v_round INT UNSIGNED;
    DECLARE v_stage, v_year_status VARCHAR(16);
    DECLARE v_item_status VARCHAR(24);
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        IF @sa_denial_reason IS NOT NULL THEN
            INSERT INTO access_denied_log(login_name, item_id, evidence_id, reason)
            VALUES (SUBSTRING_INDEX(USER(), '@', 1), @sa_denial_item, @sa_denial_evidence, @sa_denial_reason);
            SET @sa_denial_item = NULL, @sa_denial_evidence = NULL, @sa_denial_reason = NULL;
        END IF;
        RESIGNAL;
    END;
    SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
    START TRANSACTION;
    SELECT item_id INTO v_item FROM evidence WHERE evidence_id = p_evidence;
    CALL lock_review_item(v_item, v_reviewer, v_stage, v_item_status, v_round, v_year_status);
    IF NOT EXISTS (
        SELECT 1 FROM evidence e WHERE e.evidence_id = p_evidence AND (e.active OR EXISTS (
            SELECT 1 FROM review_record r WHERE r.item_id = v_item
            AND JSON_CONTAINS(r.reviewed_item, CAST(p_evidence AS JSON), '$.evidence_ids')
        ))
    ) THEN
        SET @sa_denial_item = v_item, @sa_denial_evidence = p_evidence, @sa_denial_reason = '无权访问此材料';
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '无权访问此材料';
    END IF;
    INSERT INTO privacy_access_log(reviewer_id, item_id, evidence_id) VALUES(v_reviewer, v_item, p_evidence);
    SELECT evidence_id, file_name, sha256, file_body FROM evidence WHERE evidence_id = p_evidence;
    COMMIT;
END$$

-- 驳回重提对比：把最近一次驳回时审核人看到的申报快照与学生修改后的当前条目
-- 并排返回，字段级标出是否变化，审核人无需重读全文即可定位改动。
CREATE PROCEDURE review_item_diff(IN p_item BIGINT UNSIGNED)
BEGIN
    DECLARE v_reviewer, v_round INT UNSIGNED;
    DECLARE v_stage, v_year_status VARCHAR(16);
    DECLARE v_item_status VARCHAR(24);
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        IF @sa_denial_reason IS NOT NULL THEN
            INSERT INTO access_denied_log(login_name, item_id, evidence_id, reason)
            VALUES (SUBSTRING_INDEX(USER(), '@', 1), @sa_denial_item, @sa_denial_evidence, @sa_denial_reason);
            SET @sa_denial_item = NULL, @sa_denial_evidence = NULL, @sa_denial_reason = NULL;
        END IF;
        RESIGNAL;
    END;
    SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
    START TRANSACTION;
    CALL lock_review_item(p_item, v_reviewer, v_stage, v_item_status, v_round, v_year_status);
    INSERT INTO privacy_access_log(reviewer_id, item_id) VALUES(v_reviewer, p_item);
    SELECT
        rr.review_id, rr.round_no, rr.reviewed_at, rr.opinion,
        CAST(JSON_EXTRACT(rr.reviewed_item, '$.project_id') AS UNSIGNED) AS project_then,
        i.project_id AS project_now,
        CAST(JSON_EXTRACT(rr.reviewed_item, '$.project_id') AS UNSIGNED) <> i.project_id AS project_changed,
        JSON_UNQUOTE(JSON_EXTRACT(rr.reviewed_item, '$.details')) AS details_then,
        i.details AS details_now,
        JSON_UNQUOTE(JSON_EXTRACT(rr.reviewed_item, '$.details')) <> i.details AS details_changed,
        CAST(JSON_EXTRACT(rr.reviewed_item, '$.claimed_score') AS DECIMAL(10,2)) AS claimed_then,
        i.claimed_score AS claimed_now,
        CAST(JSON_EXTRACT(rr.reviewed_item, '$.claimed_score') AS DECIMAL(10,2)) <> i.claimed_score AS claimed_changed,
        CAST(JSON_EXTRACT(rr.reviewed_item, '$.occurred_on') AS CHAR) AS occurred_then,
        CAST(i.occurred_on AS CHAR) AS occurred_now,
        CAST(JSON_EXTRACT(rr.reviewed_item, '$.occurred_on') AS CHAR) <> CAST(i.occurred_on AS CHAR) AS occurred_changed,
        JSON_LENGTH(rr.reviewed_item->'$.evidence_ids') AS evidence_count_then,
        (SELECT COUNT(*) FROM evidence e WHERE e.item_id = i.item_id AND e.active) AS evidence_count_now,
        rr.reviewed_item AS snapshot_json
    FROM review_record rr
    JOIN application_item i ON i.item_id = rr.item_id
    WHERE rr.item_id = p_item AND rr.decision = 'return'
    ORDER BY rr.review_id DESC
    LIMIT 1;
    COMMIT;
END$$

-- 学生自查本人在各学年的成绩、排名及与上一学年的变化。
CREATE PROCEDURE my_progress()
READS SQL DATA
BEGIN
    SELECT p.year_id, p.year_name, p.total_score, p.rank_no, p.grade,
           p.prev_year_id, p.prev_total_score, p.prev_rank_no,
           p.score_delta, p.rank_improvement
    FROM student s JOIN student_progress p USING (student_id)
    WHERE s.login_name = SUBSTRING_INDEX(USER(), '@', 1)
    ORDER BY p.starts_on;
END$$

CREATE PROCEDURE review_queue(IN p_year VARCHAR(24), IN p_filter VARCHAR(16))
READS SQL DATA
BEGIN
    IF p_filter IS NULL OR p_filter NOT IN ('pending','returned','completed','all') THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '筛选值为 pending、returned、completed 或 all';
    END IF;
    SELECT i.item_id, f.form_id, a.class_id, f.student_id, p.project_name,
           i.status, f.round_no, f.submitted_at
    FROM reviewer r JOIN student_year_assessment a ON r.class_id IS NULL OR r.class_id = a.class_id
    JOIN application_form f ON f.student_id = a.student_id AND f.year_id = a.year_id
    JOIN application_item i USING (form_id)
    JOIN assessment_project p USING (project_id)
    WHERE r.login_name = SUBSTRING_INDEX(USER(), '@', 1) AND f.year_id = p_year
    AND f.status <> 'void'
    AND i.status NOT IN ('draft','withdrawn')
    AND (p_filter = 'all' OR (p_filter = 'pending' AND i.status = CONCAT(r.review_role, '_pending'))
         OR (p_filter = 'returned' AND i.status = 'returned')
         OR (p_filter = 'completed' AND i.status = 'approved'))
    ORDER BY f.submitted_at, i.item_id;
END$$

CREATE PROCEDURE my_form_status(IN p_year VARCHAR(24))
READS SQL DATA
BEGIN
    SELECT f.form_id, f.status, f.round_no, f.submitted_at, f.modified_at
    FROM student s JOIN application_form f USING (student_id)
    WHERE s.login_name = SUBSTRING_INDEX(USER(), '@', 1) AND f.year_id = p_year;
    SELECT i.item_id, i.project_id, i.status, i.final_score,
           r.round_no AS returned_in_round, r.opinion AS return_reason
    FROM student s JOIN application_form f USING (student_id)
    JOIN application_item i USING (form_id)
    LEFT JOIN review_record r ON r.review_id = (
        SELECT MAX(rr.review_id) FROM review_record rr
        WHERE rr.item_id = i.item_id AND rr.decision = 'return'
    )
    WHERE s.login_name = SUBSTRING_INDEX(USER(), '@', 1) AND f.year_id = p_year
    ORDER BY i.item_id;
END$$

-- 学生查看本人上传的证明材料清单（仅元数据，不含文件内容）。
CREATE PROCEDURE my_evidence(IN p_year VARCHAR(24))
READS SQL DATA
BEGIN
    SELECT i.item_id, i.project_id, e.evidence_id, e.file_name, e.sha256,
           e.uploaded_at, e.active
    FROM student s JOIN application_form f USING (student_id)
    JOIN application_item i USING (form_id)
    JOIN evidence e USING (item_id)
    WHERE s.login_name = SUBSTRING_INDEX(USER(), '@', 1) AND f.year_id = p_year
    ORDER BY i.item_id, e.evidence_id;
END$$

-- 学生查看本人各轮提交记录。
CREATE PROCEDURE my_submission_history(IN p_year VARCHAR(24))
READS SQL DATA
BEGIN
    SELECT sl.submission_id, sl.round_no, sl.submitted_at, sl.item_count, sl.snapshot
    FROM student s JOIN application_form f USING (student_id)
    JOIN submission_log sl USING (form_id)
    WHERE s.login_name = SUBSTRING_INDEX(USER(), '@', 1) AND f.year_id = p_year
    ORDER BY sl.submission_id;
END$$

DELIMITER ;

-- 内部计算视图。每个学生保留规则下的全部项目，缺报项目记零。
-- 规则版本改由学年表获得（原版直接存于表单，构成 2NF 违例）。
CREATE VIEW calculation_input AS
SELECT f.student_id, f.year_id, y.rule_id, p.project_id, p.weight, p.score_cap,
       COALESCE(SUM(i.claimed_score), 0) AS raw_score,
       LEAST(COALESCE(SUM(i.final_score), 0), p.score_cap) AS approved_score
FROM application_form f
JOIN academic_year y ON y.year_id = f.year_id
JOIN assessment_project p ON p.rule_id = y.rule_id
LEFT JOIN application_item i ON i.form_id = f.form_id AND i.project_id = p.project_id
                             AND i.status = 'approved'
WHERE f.status = 'submitted'
GROUP BY f.student_id, f.year_id, y.rule_id, p.project_id, p.weight, p.score_cap;

DELIMITER $$

CREATE PROCEDURE publish_year(IN p_year VARCHAR(24))
BEGIN
    DECLARE v_rule INT UNSIGNED;
    DECLARE v_status VARCHAR(16);
    DECLARE v_opens, v_deadline DATETIME;
    DECLARE v_batch DATETIME(6);
    DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;
    SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
    START TRANSACTION;
    CALL lock_assessment_year(p_year, v_rule, v_status, v_opens, v_deadline);
    IF v_status NOT IN ('open','review') OR UTC_TIMESTAMP() < v_deadline THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '仅在申报截止后且学年尚未公示时发布';
    END IF;
    IF COALESCE((SELECT SUM(weight) FROM assessment_project WHERE rule_id = v_rule), 0) <> 1 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '该版本的项目权重合计必须等于 1';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM application_form WHERE year_id = p_year AND status = 'submitted') THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '没有可发布的已提交表单';
    END IF;
    IF EXISTS (
        SELECT 1 FROM application_form f JOIN application_item i USING (form_id)
        WHERE f.year_id = p_year AND f.status = 'submitted'
        AND i.status NOT IN ('approved','withdrawn')
    ) OR EXISTS (
        SELECT 1 FROM application_form f WHERE f.year_id = p_year AND f.status = 'submitted'
        AND NOT EXISTS (SELECT 1 FROM application_item i WHERE i.form_id = f.form_id AND i.status = 'approved')
    ) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '存在尚未通过终审的已提交表单';
    END IF;
    SET v_batch = UTC_TIMESTAMP(6);
    INSERT INTO assessment_result(student_id, year_id, total_score, rank_no, generated_at)
    WITH totals AS (
        SELECT c.student_id, c.year_id, c.rule_id,
               ROUND(SUM(c.approved_score * c.weight * 100 / c.score_cap), 2) AS total_score
        FROM calculation_input c WHERE c.year_id = p_year
        GROUP BY c.student_id, c.year_id, c.rule_id
    )
    -- 同分并列取相同名次且名次连续（1,1,2），避免 RANK 产生名次空洞（1,1,3）
    SELECT t.student_id, t.year_id, t.total_score,
           DENSE_RANK() OVER (ORDER BY t.total_score DESC), v_batch
    FROM totals t;
    INSERT INTO project_score(result_id, project_id, raw_score, approved_score)
    SELECT r.result_id, c.project_id, c.raw_score, c.approved_score
    FROM calculation_input c JOIN assessment_result r USING (student_id, year_id)
    WHERE c.year_id = p_year;
    UPDATE application_form SET status = 'completed' WHERE year_id = p_year AND status = 'submitted';
    UPDATE academic_year SET status = 'published', published_at = v_batch WHERE year_id = p_year;
    INSERT INTO admin_operation_log(operator_login, action, target_id, detail)
    VALUES (SUBSTRING_INDEX(USER(), '@', 1), 'publish_year', p_year, CONCAT('batch=', v_batch));
    COMMIT;
END$$

-- 管理员兜底：申报截止后（UTC_TIMESTAMP() >= deadline_at）且学年尚未公示时，
-- 可把未完成的表单作废（status → void，未通过条目撤回），避免个别学生卡死整学年公示。
-- 是否作废、是否公示一律以截止时间为依据：截止前学生仍有申报机会，不可提前作废。
CREATE PROCEDURE abandon_form(IN p_year VARCHAR(24), IN p_student VARCHAR(24))
BEGIN
    DECLARE v_rule INT UNSIGNED;
    DECLARE v_status VARCHAR(16);
    DECLARE v_opens, v_deadline DATETIME;
    DECLARE v_form BIGINT UNSIGNED DEFAULT NULL;
    DECLARE v_form_status VARCHAR(16);
    DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;
    SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
    START TRANSACTION;
    CALL lock_assessment_year(p_year, v_rule, v_status, v_opens, v_deadline);
    IF v_status IN ('draft','published') THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '草稿或已公示学年不可作废表单';
    END IF;
    IF UTC_TIMESTAMP() < v_deadline THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '申报截止前不可作废表单';
    END IF;
    SELECT form_id, status INTO v_form, v_form_status
    FROM application_form WHERE student_id = p_student AND year_id = p_year FOR UPDATE;
    IF v_form IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '该学生本学年没有表单';
    END IF;
    IF v_form_status IN ('void','completed') THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '表单已作废或已随学年公示';
    END IF;
    UPDATE application_item SET status = 'withdrawn'
    WHERE form_id = v_form AND status NOT IN ('approved','withdrawn');
    UPDATE application_form SET status = 'void', modified_at = UTC_TIMESTAMP(6)
    WHERE form_id = v_form;
    INSERT INTO admin_operation_log(operator_login, action, target_id, detail)
    VALUES (SUBSTRING_INDEX(USER(), '@', 1), 'abandon_form', p_year,
            CONCAT('student=', p_student, ', form=', v_form));
    COMMIT;
    SELECT v_form AS form_id, 'void' AS new_status;
END$$

CREATE PROCEDURE my_result(IN p_year VARCHAR(24))
READS SQL DATA
BEGIN
    SELECT r.result_id, y.year_name, a.class_id, r.total_score,
           CASE WHEN r.total_score >= ar.excellent_min THEN '优秀'
                WHEN r.total_score >= ar.good_min THEN '良好'
                WHEN r.total_score >= ar.pass_min THEN '合格'
                ELSE '不合格' END AS grade,
           r.rank_no, r.generated_at
    FROM student s JOIN assessment_result r USING (student_id)
    JOIN student_year_assessment a ON a.student_id = r.student_id AND a.year_id = r.year_id
    JOIN academic_year y ON y.year_id = r.year_id
    JOIN assessment_rule ar ON ar.rule_id = y.rule_id
    WHERE s.login_name = SUBSTRING_INDEX(USER(), '@', 1) AND y.year_id = p_year AND y.status = 'published';
    SELECT p.project_name, ps.raw_score, ps.approved_score,
           ROUND(ps.approved_score * p.weight * 100 / p.score_cap, 4) AS weighted_score
    FROM student s JOIN assessment_result r USING (student_id)
    JOIN academic_year y USING (year_id)
    JOIN project_score ps USING (result_id) JOIN assessment_project p USING (project_id)
    WHERE s.login_name = SUBSTRING_INDEX(USER(), '@', 1) AND y.year_id = p_year AND y.status = 'published'
    ORDER BY ps.project_id;
END$$

DELIMITER ;

CREATE VIEW available_projects AS
SELECT y.year_id, y.year_name, y.starts_on, y.ends_on, y.opens_at, y.deadline_at, y.status,
       p.project_id, p.project_name, p.category, p.weight, p.score_cap,
       p.evidence_required, p.evidence_requirement
FROM academic_year y JOIN assessment_project p USING (rule_id)
WHERE y.status <> 'draft';

CREATE VIEW published_results AS
SELECT r.result_id, r.year_id, y.year_name, a.class_id, r.total_score,
       CASE WHEN r.total_score >= ar.excellent_min THEN '优秀'
            WHEN r.total_score >= ar.good_min THEN '良好'
            WHEN r.total_score >= ar.pass_min THEN '合格'
            ELSE '不合格' END AS grade,
       r.rank_no, r.generated_at
FROM assessment_result r JOIN academic_year y USING (year_id)
JOIN assessment_rule ar ON ar.rule_id = y.rule_id
JOIN student_year_assessment a ON a.student_id = r.student_id AND a.year_id = r.year_id
WHERE y.status = 'published';

-- 结果公示视图：仅学年状态为 published（全部审核完成、统计结束）后可见，
-- 面向学生公开成绩排名（含学号姓名，仅限登录学生角色查看），补齐"结果公示"环节。
CREATE VIEW public_notice AS
SELECT y.year_id, y.year_name, a.class_id, c.class_name, s.student_id, s.student_name,
       r.total_score,
       CASE WHEN r.total_score >= ar.excellent_min THEN '优秀'
            WHEN r.total_score >= ar.good_min THEN '良好'
            WHEN r.total_score >= ar.pass_min THEN '合格'
            ELSE '不合格' END AS grade,
       r.rank_no, r.generated_at
FROM assessment_result r
JOIN academic_year y ON y.year_id = r.year_id AND y.status = 'published'
JOIN assessment_rule ar ON ar.rule_id = y.rule_id
JOIN student s ON s.student_id = r.student_id
JOIN student_year_assessment a ON a.student_id = r.student_id AND a.year_id = r.year_id
JOIN class_group c ON c.class_id = a.class_id;

-- 隐私口径说明：小班级的 MIN/MAX/AVG 在人数极少时可反推个人分数。
-- 本视图仅授予受信内部角色 sa_analyst（不对外）；面向学生的公示走 public_notice。
-- 如需彻底防反推可加 HAVING COUNT(*) >= k，但会改变演示数据的输出口径，故未启用。
CREATE VIEW class_result_distribution AS
SELECT r.year_id, r.class_id, c.class_name, r.grade, COUNT(*) AS student_count,
       MIN(r.total_score) AS minimum_score, MAX(r.total_score) AS maximum_score,
       ROUND(AVG(r.total_score), 2) AS average_score
FROM published_results r JOIN class_group c USING (class_id)
GROUP BY r.year_id, r.class_id, c.class_name, r.grade;

CREATE VIEW project_submission_statistics AS
SELECT f.year_id, p.project_id, p.project_name, COUNT(*) AS submitted_items,
       SUM(i.status = 'approved') AS approved_items, SUM(i.status = 'returned') AS returned_items
FROM application_form f JOIN application_item i USING (form_id)
JOIN assessment_project p USING (project_id)
WHERE f.status IN ('submitted','completed') AND i.status <> 'withdrawn'
GROUP BY f.year_id, p.project_id, p.project_name;

-- 跨学年个人进展：用 LAG 窗口函数取学生上一次参加测评的学年、总分与名次，
-- 计算分数变化（score_delta）与名次进步（rank_improvement，正数表示名次上升）。
-- 含规则版本提示（rule_id/version_no）：规则版本不同的学年分数可比性有限，读数据时自行判断。
-- 含个人标识，仅作内部视图（SQL SECURITY DEFINER），不直接授予任何角色。
CREATE VIEW student_progress AS
SELECT r.student_id, r.year_id, y.year_name, y.starts_on, a.class_id,
       ar.rule_id, ar.version_no,
       r.total_score, r.rank_no,
       CASE WHEN r.total_score >= ar.excellent_min THEN '优秀'
            WHEN r.total_score >= ar.good_min THEN '良好'
            WHEN r.total_score >= ar.pass_min THEN '合格'
            ELSE '不合格' END AS grade,
       LAG(r.year_id) OVER w AS prev_year_id,
       LAG(r.total_score) OVER w AS prev_total_score,
       LAG(r.rank_no) OVER w AS prev_rank_no,
       ROUND(r.total_score - LAG(r.total_score) OVER w, 2) AS score_delta,
       CAST(LAG(r.rank_no) OVER w AS SIGNED) - CAST(r.rank_no AS SIGNED) AS rank_improvement
FROM assessment_result r
JOIN academic_year y USING (year_id)
JOIN assessment_rule ar ON ar.rule_id = y.rule_id
JOIN student_year_assessment a ON a.student_id = r.student_id AND a.year_id = r.year_id
WINDOW w AS (PARTITION BY r.student_id ORDER BY y.starts_on);

-- 班级层面的跨学年进步统计（仅聚合值，不含个人标识），供统计分析员使用。
CREATE VIEW class_progress_stats AS
SELECT year_id, year_name, class_id, COUNT(*) AS student_count,
       SUM(rank_improvement > 0) AS improved_count,
       SUM(rank_improvement < 0) AS declined_count,
       SUM(rank_improvement = 0) AS unchanged_count,
       ROUND(AVG(score_delta), 2) AS avg_score_delta
FROM student_progress
WHERE prev_year_id IS NOT NULL
GROUP BY year_id, year_name, class_id;

-- 运维监控视图：截止后仍卡住的已提交表单（存在未终审条目，或没有任何条目通过终审），
-- 供管理员定位需要 abandon_form 处理的学生，避免个别表单卡死整学年公示。
CREATE VIEW admin_stalled_forms AS
SELECT f.year_id, f.student_id, s.student_name, a.class_id, f.form_id, f.round_no, f.submitted_at,
       SUM(i.status NOT IN ('approved','withdrawn')) AS blocking_items,
       SUM(i.status = 'approved') AS approved_items
FROM application_form f
JOIN academic_year y ON y.year_id = f.year_id
JOIN student s ON s.student_id = f.student_id
JOIN student_year_assessment a ON a.student_id = f.student_id AND a.year_id = f.year_id
JOIN application_item i ON i.form_id = f.form_id
WHERE f.status = 'submitted' AND y.status IN ('open','review')
  AND UTC_TIMESTAMP() >= y.deadline_at
GROUP BY f.year_id, f.student_id, s.student_name, a.class_id, f.form_id, f.round_no, f.submitted_at
HAVING blocking_items > 0 OR approved_items = 0;

CREATE ROLE IF NOT EXISTS 'sa_student', 'sa_reviewer', 'sa_analyst', 'sa_publisher', 'sa_admin';
GRANT SELECT ON student_assessment.available_projects TO 'sa_student', 'sa_reviewer';
GRANT SELECT ON student_assessment.published_results TO 'sa_analyst';
GRANT SELECT ON student_assessment.class_result_distribution TO 'sa_analyst';
GRANT SELECT ON student_assessment.project_submission_statistics TO 'sa_analyst';
GRANT SELECT ON student_assessment.class_progress_stats TO 'sa_analyst';
GRANT EXECUTE ON PROCEDURE student_assessment.save_form TO 'sa_student';
GRANT EXECUTE ON PROCEDURE student_assessment.reopen_form TO 'sa_student';
GRANT EXECUTE ON PROCEDURE student_assessment.save_item TO 'sa_student';
GRANT EXECUTE ON PROCEDURE student_assessment.withdraw_item TO 'sa_student';
GRANT EXECUTE ON PROCEDURE student_assessment.add_evidence TO 'sa_student';
GRANT EXECUTE ON PROCEDURE student_assessment.remove_evidence TO 'sa_student';
GRANT EXECUTE ON PROCEDURE student_assessment.submit_form TO 'sa_student';
GRANT EXECUTE ON PROCEDURE student_assessment.my_form_status TO 'sa_student';
GRANT EXECUTE ON PROCEDURE student_assessment.my_result TO 'sa_student';
GRANT EXECUTE ON PROCEDURE student_assessment.my_progress TO 'sa_student';
GRANT EXECUTE ON PROCEDURE student_assessment.review_queue TO 'sa_reviewer';
GRANT EXECUTE ON PROCEDURE student_assessment.review_item TO 'sa_reviewer';
GRANT EXECUTE ON PROCEDURE student_assessment.read_review_item TO 'sa_reviewer';
GRANT EXECUTE ON PROCEDURE student_assessment.read_evidence TO 'sa_reviewer';
GRANT EXECUTE ON PROCEDURE student_assessment.review_item_diff TO 'sa_reviewer';
GRANT EXECUTE ON PROCEDURE student_assessment.publish_year TO 'sa_publisher';
GRANT SELECT ON student_assessment.public_notice TO 'sa_student', 'sa_analyst';
GRANT EXECUTE ON PROCEDURE student_assessment.my_evidence TO 'sa_student';
GRANT EXECUTE ON PROCEDURE student_assessment.my_submission_history TO 'sa_student';

-- 管理员：主数据可写（触发器继续守住规则版本、学年状态机、登录名互斥等不变量），
-- 业务数据只读监控；证明材料仅授权元数据列（不含 file_body），隐私访问日志可查。
GRANT SELECT, INSERT, UPDATE, DELETE ON student_assessment.class_group TO 'sa_admin';
GRANT SELECT, INSERT, UPDATE, DELETE ON student_assessment.student TO 'sa_admin';
GRANT SELECT, INSERT, UPDATE, DELETE ON student_assessment.reviewer TO 'sa_admin';
GRANT SELECT, INSERT, UPDATE, DELETE ON student_assessment.assessment_rule TO 'sa_admin';
GRANT SELECT, INSERT, UPDATE, DELETE ON student_assessment.assessment_project TO 'sa_admin';
GRANT SELECT, INSERT, UPDATE, DELETE ON student_assessment.academic_year TO 'sa_admin';
GRANT SELECT ON student_assessment.student_year_assessment TO 'sa_admin';
GRANT SELECT ON student_assessment.application_form TO 'sa_admin';
GRANT SELECT ON student_assessment.application_item TO 'sa_admin';
GRANT SELECT (evidence_id, item_id, file_name, storage_location, sha256, uploaded_at, active)
    ON student_assessment.evidence TO 'sa_admin';
GRANT SELECT ON student_assessment.review_record TO 'sa_admin';
GRANT SELECT ON student_assessment.submission_log TO 'sa_admin';
GRANT SELECT ON student_assessment.assessment_result TO 'sa_admin';
GRANT SELECT ON student_assessment.project_score TO 'sa_admin';
GRANT SELECT ON student_assessment.privacy_access_log TO 'sa_admin';
GRANT EXECUTE ON PROCEDURE student_assessment.abandon_form TO 'sa_admin';
GRANT EXECUTE ON PROCEDURE student_assessment.publish_year TO 'sa_admin';
GRANT SELECT ON student_assessment.access_denied_log TO 'sa_admin';
GRANT SELECT ON student_assessment.admin_operation_log TO 'sa_admin';
GRANT SELECT ON student_assessment.admin_stalled_forms TO 'sa_admin';


-- 已启用学年引用的评分口径保留原版本。变更评分请建立新版本。
DELIMITER $$
CREATE TRIGGER keep_year_rule BEFORE UPDATE ON academic_year FOR EACH ROW
BEGIN
    IF OLD.status <> 'draft' AND OLD.rule_id <> NEW.rule_id THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '已启用学年不能更换规则版本';
    END IF;
    IF OLD.status <> 'draft' AND (NEW.starts_on <> OLD.starts_on OR NEW.ends_on <> OLD.ends_on
                                  OR NEW.opens_at <> OLD.opens_at) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '学年启用后不可修改起止日期与开放时刻';
    END IF;
    -- 截止时间只许后延；open→review 的同一句 UPDATE 允许把截止时间提前到当前时刻
    -- （即"手工提前关闭申报"，02 演示数据所用的快进模式）
    IF NEW.status = OLD.status AND OLD.status IN ('open','review','published')
       AND NEW.deadline_at < OLD.deadline_at THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '截止时间只能向后延';
    END IF;
    IF OLD.status = 'published' AND NEW.status <> 'published' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '已公示学年不能退回';
    END IF;
    IF OLD.status <> 'draft' AND NEW.status = 'draft' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '已启用学年不能退回草稿';
    END IF;
END$$

-- 学年日期区间互不重叠（MySQL 无跨行约束，用触发器保证）。
-- 更新仅在日期区间实际变化时检查，并按主键排除自身。
CREATE TRIGGER check_year_overlap_ins BEFORE INSERT ON academic_year FOR EACH ROW
BEGIN
    IF EXISTS (
        SELECT 1 FROM academic_year
        WHERE NEW.starts_on <= ends_on AND starts_on <= NEW.ends_on
    ) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '学年日期区间不能与已有学年重叠';
    END IF;
END$$

CREATE TRIGGER check_year_overlap_upd BEFORE UPDATE ON academic_year FOR EACH ROW
BEGIN
    IF (NEW.starts_on <> OLD.starts_on OR NEW.ends_on <> OLD.ends_on) AND EXISTS (
        SELECT 1 FROM academic_year
        WHERE year_id <> NEW.year_id
          AND NEW.starts_on <= ends_on AND starts_on <= NEW.ends_on
    ) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '学年日期区间不能与已有学年重叠';
    END IF;
END$$

-- 学生与审核人的登录名互斥：同一数据库账号不能同时绑定两种身份，
-- 防止一人既申报又审核（甚至审核自己）。MySQL 无跨表 UNIQUE/断言，故用触发器。
CREATE TRIGGER student_login_not_reviewer_ins BEFORE INSERT ON student FOR EACH ROW
BEGIN
    IF EXISTS (SELECT 1 FROM reviewer WHERE login_name = NEW.login_name) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '该登录名已绑定审核人员';
    END IF;
END$$

CREATE TRIGGER student_login_not_reviewer_upd BEFORE UPDATE ON student FOR EACH ROW
BEGIN
    IF NEW.login_name <> OLD.login_name AND EXISTS (
        SELECT 1 FROM reviewer WHERE login_name = NEW.login_name
    ) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '该登录名已绑定审核人员';
    END IF;
END$$

CREATE TRIGGER reviewer_login_not_student_ins BEFORE INSERT ON reviewer FOR EACH ROW
BEGIN
    IF EXISTS (SELECT 1 FROM student WHERE login_name = NEW.login_name) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '该登录名已绑定学生';
    END IF;
END$$

CREATE TRIGGER reviewer_login_not_student_upd BEFORE UPDATE ON reviewer FOR EACH ROW
BEGIN
    IF NEW.login_name <> OLD.login_name AND EXISTS (
        SELECT 1 FROM student WHERE login_name = NEW.login_name
    ) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '该登录名已绑定学生';
    END IF;
END$$

-- 3NF 化后，原复合外键 (form_id, rule_id) 与 (rule_id, project_id) 提供的
-- "条目项目必须属于表单学年的规则版本"这一跨表约束改由此处触发器保证。
CREATE TRIGGER check_item_project_rule_ins BEFORE INSERT ON application_item FOR EACH ROW
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM application_form f
        JOIN academic_year y USING (year_id)
        JOIN assessment_project p ON p.project_id = NEW.project_id
        WHERE f.form_id = NEW.form_id AND p.rule_id = y.rule_id
    ) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '项目不属于表单学年的规则';
    END IF;
    IF NEW.claimed_score > (SELECT score_cap FROM assessment_project
                            WHERE project_id = NEW.project_id) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '申报分不能超过项目封顶分';
    END IF;
END$$

CREATE TRIGGER check_item_project_rule_upd BEFORE UPDATE ON application_item FOR EACH ROW
BEGIN
    IF (NEW.form_id <> OLD.form_id OR NEW.project_id <> OLD.project_id) AND NOT EXISTS (
        SELECT 1 FROM application_form f
        JOIN academic_year y USING (year_id)
        JOIN assessment_project p ON p.project_id = NEW.project_id
        WHERE f.form_id = NEW.form_id AND p.rule_id = y.rule_id
    ) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '项目不属于表单学年的规则';
    END IF;
    IF NEW.claimed_score > (SELECT score_cap FROM assessment_project
                            WHERE project_id = NEW.project_id) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '申报分不能超过项目封顶分';
    END IF;
END$$

CREATE PROCEDURE require_unused_rule(IN p_rule INT UNSIGNED)
READS SQL DATA
BEGIN
    IF EXISTS (SELECT 1 FROM academic_year WHERE rule_id = p_rule AND status <> 'draft') THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '已启用的规则版本及其项目不可修改';
    END IF;
END$$

CREATE TRIGGER keep_rule_version BEFORE UPDATE ON assessment_rule FOR EACH ROW
BEGIN
    CALL require_unused_rule(OLD.rule_id);
END$$

CREATE TRIGGER keep_project_insert BEFORE INSERT ON assessment_project FOR EACH ROW
BEGIN
    CALL require_unused_rule(NEW.rule_id);
    -- 编辑期即校验权重合计，避免把"权重和≠1"的问题拖到公示时才暴露
    IF (SELECT COALESCE(SUM(weight), 0) FROM assessment_project
        WHERE rule_id = NEW.rule_id) + NEW.weight > 1 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '同一规则的项目权重合计不能超过 1';
    END IF;
END$$

CREATE TRIGGER keep_project_update BEFORE UPDATE ON assessment_project FOR EACH ROW
BEGIN
    CALL require_unused_rule(OLD.rule_id);
    IF OLD.rule_id <> NEW.rule_id THEN
        CALL require_unused_rule(NEW.rule_id);
    END IF;
    IF (SELECT COALESCE(SUM(weight), 0) FROM assessment_project
        WHERE rule_id = NEW.rule_id AND project_id <> OLD.project_id) + NEW.weight > 1 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '同一规则的项目权重合计不能超过 1';
    END IF;
END$$

CREATE TRIGGER keep_project_delete BEFORE DELETE ON assessment_project FOR EACH ROW
BEGIN
    CALL require_unused_rule(OLD.rule_id);
END$$
DELIMITER ;

-- 主数据与学年状态变更审计（AFTER 单语句触发器，无需切换 DELIMITER）。
-- operator_login 取执行 SQL 的数据库账号；EVENT 自动推进的学年状态变更
-- 归属于事件定义者账号（安装账号），见使用说明。审计表刻意不设外键：
-- 审计写入永远不应因业务数据问题而失败。
CREATE TRIGGER audit_class_group_ins AFTER INSERT ON class_group FOR EACH ROW
INSERT INTO admin_operation_log(operator_login, action, target_id, detail)
VALUES (SUBSTRING_INDEX(USER(), '@', 1), 'class_group:insert', NEW.class_id, NEW.class_name);

CREATE TRIGGER audit_class_group_upd AFTER UPDATE ON class_group FOR EACH ROW
INSERT INTO admin_operation_log(operator_login, action, target_id, detail)
VALUES (SUBSTRING_INDEX(USER(), '@', 1), 'class_group:update', NEW.class_id,
        CONCAT(OLD.class_name, ' -> ', NEW.class_name));

CREATE TRIGGER audit_class_group_del AFTER DELETE ON class_group FOR EACH ROW
INSERT INTO admin_operation_log(operator_login, action, target_id, detail)
VALUES (SUBSTRING_INDEX(USER(), '@', 1), 'class_group:delete', OLD.class_id, OLD.class_name);

CREATE TRIGGER audit_student_ins AFTER INSERT ON student FOR EACH ROW
INSERT INTO admin_operation_log(operator_login, action, target_id, detail)
VALUES (SUBSTRING_INDEX(USER(), '@', 1), 'student:insert', NEW.student_id,
        CONCAT('name=', NEW.student_name, ', class=', NEW.class_id, ', login=', NEW.login_name));

CREATE TRIGGER audit_student_upd AFTER UPDATE ON student FOR EACH ROW
INSERT INTO admin_operation_log(operator_login, action, target_id, detail)
VALUES (SUBSTRING_INDEX(USER(), '@', 1), 'student:update', NEW.student_id,
        CONCAT('name:', OLD.student_name, '->', NEW.student_name,
               ', class:', OLD.class_id, '->', NEW.class_id,
               ', login:', OLD.login_name, '->', NEW.login_name));

CREATE TRIGGER audit_student_del AFTER DELETE ON student FOR EACH ROW
INSERT INTO admin_operation_log(operator_login, action, target_id, detail)
VALUES (SUBSTRING_INDEX(USER(), '@', 1), 'student:delete', OLD.student_id,
        CONCAT('name=', OLD.student_name, ', login=', OLD.login_name));

CREATE TRIGGER audit_reviewer_ins AFTER INSERT ON reviewer FOR EACH ROW
INSERT INTO admin_operation_log(operator_login, action, target_id, detail)
VALUES (SUBSTRING_INDEX(USER(), '@', 1), 'reviewer:insert', NEW.reviewer_id,
        CONCAT('name=', NEW.reviewer_name, ', role=', NEW.review_role,
               ', class=', COALESCE(NEW.class_id, 'NULL'), ', login=', NEW.login_name));

CREATE TRIGGER audit_reviewer_upd AFTER UPDATE ON reviewer FOR EACH ROW
INSERT INTO admin_operation_log(operator_login, action, target_id, detail)
VALUES (SUBSTRING_INDEX(USER(), '@', 1), 'reviewer:update', NEW.reviewer_id,
        CONCAT('name:', OLD.reviewer_name, '->', NEW.reviewer_name,
               ', role:', OLD.review_role, '->', NEW.review_role,
               ', class:', COALESCE(OLD.class_id, 'NULL'), '->', COALESCE(NEW.class_id, 'NULL'),
               ', login:', OLD.login_name, '->', NEW.login_name));

CREATE TRIGGER audit_reviewer_del AFTER DELETE ON reviewer FOR EACH ROW
INSERT INTO admin_operation_log(operator_login, action, target_id, detail)
VALUES (SUBSTRING_INDEX(USER(), '@', 1), 'reviewer:delete', OLD.reviewer_id,
        CONCAT('name=', OLD.reviewer_name, ', login=', OLD.login_name));

CREATE TRIGGER audit_rule_ins AFTER INSERT ON assessment_rule FOR EACH ROW
INSERT INTO admin_operation_log(operator_login, action, target_id, detail)
VALUES (SUBSTRING_INDEX(USER(), '@', 1), 'assessment_rule:insert', NEW.rule_id,
        CONCAT(NEW.rule_name, ' ', NEW.version_no));

CREATE TRIGGER audit_rule_upd AFTER UPDATE ON assessment_rule FOR EACH ROW
INSERT INTO admin_operation_log(operator_login, action, target_id, detail)
VALUES (SUBSTRING_INDEX(USER(), '@', 1), 'assessment_rule:update', NEW.rule_id,
        CONCAT(OLD.rule_name, ' ', OLD.version_no, ' -> ', NEW.rule_name, ' ', NEW.version_no));

CREATE TRIGGER audit_rule_del AFTER DELETE ON assessment_rule FOR EACH ROW
INSERT INTO admin_operation_log(operator_login, action, target_id, detail)
VALUES (SUBSTRING_INDEX(USER(), '@', 1), 'assessment_rule:delete', OLD.rule_id,
        CONCAT(OLD.rule_name, ' ', OLD.version_no));

CREATE TRIGGER audit_project_ins AFTER INSERT ON assessment_project FOR EACH ROW
INSERT INTO admin_operation_log(operator_login, action, target_id, detail)
VALUES (SUBSTRING_INDEX(USER(), '@', 1), 'assessment_project:insert', NEW.project_id,
        CONCAT('rule=', NEW.rule_id, ', name=', NEW.project_name,
               ', weight=', NEW.weight, ', cap=', NEW.score_cap));

CREATE TRIGGER audit_project_upd AFTER UPDATE ON assessment_project FOR EACH ROW
INSERT INTO admin_operation_log(operator_login, action, target_id, detail)
VALUES (SUBSTRING_INDEX(USER(), '@', 1), 'assessment_project:update', NEW.project_id,
        CONCAT('rule:', OLD.rule_id, '->', NEW.rule_id,
               ', name:', OLD.project_name, '->', NEW.project_name,
               ', weight:', OLD.weight, '->', NEW.weight,
               ', cap:', OLD.score_cap, '->', NEW.score_cap));

CREATE TRIGGER audit_project_del AFTER DELETE ON assessment_project FOR EACH ROW
INSERT INTO admin_operation_log(operator_login, action, target_id, detail)
VALUES (SUBSTRING_INDEX(USER(), '@', 1), 'assessment_project:delete', OLD.project_id,
        CONCAT('rule=', OLD.rule_id, ', name=', OLD.project_name));

CREATE TRIGGER audit_year_ins AFTER INSERT ON academic_year FOR EACH ROW
INSERT INTO admin_operation_log(operator_login, action, target_id, detail)
VALUES (SUBSTRING_INDEX(USER(), '@', 1), 'academic_year:insert', NEW.year_id,
        CONCAT('status=', NEW.status, ', rule=', NEW.rule_id,
               ', window=', NEW.starts_on, '..', NEW.ends_on));

CREATE TRIGGER audit_year_upd AFTER UPDATE ON academic_year FOR EACH ROW
INSERT INTO admin_operation_log(operator_login, action, target_id, detail)
VALUES (SUBSTRING_INDEX(USER(), '@', 1), 'academic_year:update', NEW.year_id,
        CONCAT('status:', OLD.status, '->', NEW.status,
               ', deadline:', OLD.deadline_at, '->', NEW.deadline_at,
               ', rule:', OLD.rule_id, '->', NEW.rule_id));

CREATE TRIGGER audit_year_del AFTER DELETE ON academic_year FOR EACH ROW
INSERT INTO admin_operation_log(operator_login, action, target_id, detail)
VALUES (SUBSTRING_INDEX(USER(), '@', 1), 'academic_year:delete', OLD.year_id,
        CONCAT('status=', OLD.status));

-- 学年状态自动推进（事件调度器）：到开放时刻自动开启，过截止时刻自动转入审核，
-- 状态机由数据库自己推进，应用层与人工只需负责建学年与公示两个端点。
-- 事件调度器默认关闭，此处持久化开启（写入 mysqld-auto.cnf，重启后仍然生效），
-- 需 SYSTEM_VARIABLES_ADMIN 权限（安装账号具备）；demo.py 另以 --event-scheduler=ON 启动兜底。
-- 若事件被关闭，学年不会自动切换，可用 03_网页接口.sql 的 web_close_submissions 手工兜底。
SET PERSIST event_scheduler = ON;

CREATE EVENT open_due_years
ON SCHEDULE EVERY 1 MINUTE
DO UPDATE academic_year SET status = 'open'
   WHERE status = 'draft' AND UTC_TIMESTAMP() >= opens_at;

CREATE EVENT review_due_years
ON SCHEDULE EVERY 1 MINUTE
DO UPDATE academic_year SET status = 'review'
   WHERE status = 'open' AND UTC_TIMESTAMP() >= deadline_at;
