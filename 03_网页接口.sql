-- 给现有学生综测库安装网页所需的最小权限接口。
USE student_assessment;

CREATE OR REPLACE VIEW web_years AS
SELECT year_id, year_name, starts_on, ends_on, opens_at, deadline_at, status, published_at
FROM academic_year WHERE status <> 'draft';

DELIMITER $$
CREATE PROCEDURE web_profile()
READS SQL DATA
BEGIN
    SELECT student_id AS person_id, student_name AS name, 'student' AS actor, class_id
    FROM student WHERE login_name = SUBSTRING_INDEX(USER(), '@', 1)
    UNION ALL
    SELECT CAST(reviewer_id AS CHAR), reviewer_name, review_role, class_id
    FROM reviewer WHERE login_name = SUBSTRING_INDEX(USER(), '@', 1);
END$$

-- 提交后的私密资料沿用原有访问约束。作者在本人草稿中可回读编辑字段和附件名称。
CREATE PROCEDURE web_draft(IN p_year VARCHAR(24))
READS SQL DATA
BEGIN
    SELECT f.notes
    FROM application_form f JOIN student s USING (student_id)
    WHERE s.login_name = SUBSTRING_INDEX(USER(), '@', 1) AND f.year_id = p_year AND f.status = 'draft';
    SELECT i.item_id, i.project_id, i.details, i.claimed_score, i.occurred_on
    FROM application_form f JOIN student s USING (student_id) JOIN application_item i USING (form_id)
    WHERE s.login_name = SUBSTRING_INDEX(USER(), '@', 1) AND f.year_id = p_year
      AND f.status = 'draft' AND i.status = 'draft'
    ORDER BY i.item_id;
    SELECT e.evidence_id, e.item_id, e.file_name
    FROM application_form f JOIN student s USING (student_id) JOIN application_item i USING (form_id)
    JOIN evidence e USING (item_id)
    WHERE s.login_name = SUBSTRING_INDEX(USER(), '@', 1) AND f.year_id = p_year
      AND f.status = 'draft' AND i.status = 'draft' AND e.active
    ORDER BY e.evidence_id;
END$$

CREATE PROCEDURE web_close_submissions(IN p_year VARCHAR(24))
BEGIN
    DECLARE v_rule INT UNSIGNED;
    DECLARE v_status VARCHAR(16);
    DECLARE v_opens, v_deadline DATETIME;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;
    START TRANSACTION;
    CALL lock_assessment_year(p_year, v_rule, v_status, v_opens, v_deadline);
    IF v_status <> 'open' OR UTC_TIMESTAMP() <= v_opens THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '只有已经开放的学年可结束申报';
    END IF;
    UPDATE academic_year SET status = 'review', deadline_at = LEAST(deadline_at, UTC_TIMESTAMP())
    WHERE year_id = p_year;
    COMMIT;
END$$
DELIMITER ;

GRANT SELECT ON student_assessment.web_years TO 'sa_student', 'sa_reviewer', 'sa_analyst', 'sa_publisher';
GRANT SELECT ON student_assessment.project_submission_statistics TO 'sa_publisher';
GRANT EXECUTE ON PROCEDURE student_assessment.web_profile TO 'sa_student', 'sa_reviewer';
GRANT EXECUTE ON PROCEDURE student_assessment.web_draft TO 'sa_student';
GRANT EXECUTE ON PROCEDURE student_assessment.web_close_submissions TO 'sa_publisher';

