from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from decimal import Decimal, InvalidOperation
from functools import wraps
from io import BytesIO
import os
import re
import secrets
from threading import Lock
from time import monotonic

from flask import (Flask, abort, flash, g, redirect, render_template, request,
                   send_file, session, url_for)
from mysql import connector

import scoring


ROLE_NAMES = {
    "student": "学生", "initial": "班级初审", "counselor": "辅导员复审",
    "final": "院系终审", "analyst": "统计分析员", "publisher": "公示管理员",
}
REVIEWERS = {"initial", "counselor", "final"}
STATUSES = {
    "open": "开放申报", "review": "审核中", "published": "已公示",
    "draft": "草稿", "submitted": "已提交", "completed": "已完成",
    "initial_pending": "待初审", "counselor_pending": "待复审",
    "final_pending": "待终审", "returned": "已驳回", "approved": "终审通过",
    "withdrawn": "已撤销", "pass": "通过", "return": "驳回", "empty": "未建档",
}
OPERATIONS = {
    "save_form", "reopen_form", "save_item", "withdraw_item", "add_evidence", "remove_evidence",
    "submit_form", "my_form_status", "my_result", "review_queue", "read_review_item",
    "read_evidence", "review_item", "publish_year", "web_profile", "web_draft",
    "web_close_submissions", "web_projects", "web_base_scores", "set_base_assessment",
    "web_ai_context", "web_ai_draft", "web_save_ai_draft",
}
SESSION_SECONDS = 8 * 60 * 60
MAX_EVIDENCE = 5 * 1024 * 1024


@dataclass(frozen=True)
class Account:
    username: str
    password: str
    actor: str
    name: str
    person_id: str
    class_id: str | None
    expires: float


def create_app(config=None):
    app = Flask(__name__)
    app.config.update(
        SECRET_KEY=secrets.token_hex(32),
        MYSQL_HOST=os.getenv("SA_MYSQL_HOST", "127.0.0.1"),
        MYSQL_PORT=int(os.getenv("SA_MYSQL_PORT", "3306")),
        MYSQL_TLS_CA=os.getenv("SA_MYSQL_TLS_CA"),
        SESSION_COOKIE_SECURE=os.getenv("SA_HTTPS") == "1",
        SESSION_COOKIE_HTTPONLY=True,
        SESSION_COOKIE_SAMESITE="Lax",
        MAX_CONTENT_LENGTH=MAX_EVIDENCE + 128 * 1024,
        MAX_FORM_MEMORY_SIZE=96 * 1024,
        DEMO_ACCOUNTS={},
    )
    app.config.update(config or {})
    accounts = {}
    account_lock = Lock()
    app.jinja_env.globals.update(role_names=ROLE_NAMES, statuses=STATUSES, review_roles=REVIEWERS)

    def connect(username, password):
        options = {}
        if app.config["MYSQL_TLS_CA"]:
            options.update(ssl_ca=app.config["MYSQL_TLS_CA"], ssl_verify_cert=True, ssl_verify_identity=True)
        return connector.connect(
            host=app.config["MYSQL_HOST"], port=app.config["MYSQL_PORT"],
            database="student_assessment", user=username, password=password,
            charset="utf8mb4", autocommit=True, connection_timeout=5, **options,
        )

    def execute(connection, sql, params=()):
        result = []
        with connection.cursor(dictionary=True) as cursor:
            cursor.execute(sql, params)
            while True:
                if cursor.description is not None:
                    result.append(cursor.fetchall())
                if not cursor.nextset():
                    return result

    def call(name, *args, connection=None):
        if name not in OPERATIONS:
            raise ValueError("Unknown database procedure")
        placeholders = ", ".join(["%s"] * len(args))
        return execute(connection if connection is not None else db(), f"CALL {name}({placeholders})", args)

    def query(sql, *args):
        return execute(db(), sql, args)[0]

    def db():
        if "db" not in g:
            g.db = connect(g.account.username, g.account.password)
        return g.db

    def forget_account():
        with account_lock:
            accounts.pop(session.get("token"), None)
        session.clear()

    @app.before_request
    def identify():
        if request.endpoint == "static":
            return
        with account_lock:
            g.account = accounts.get(session.get("token"))
        if g.account and g.account.expires <= monotonic():
            forget_account()
            g.account = None
        if request.method == "POST":
            supplied = request.form.get("csrf", "")
            expected = session.get("csrf")
            if not expected or not secrets.compare_digest(supplied.encode(), expected.encode()):
                abort(400, "页面已过期，请刷新后重试。")

    @app.after_request
    def headers(response):
        response.headers["X-Content-Type-Options"] = "nosniff"
        response.headers["Referrer-Policy"] = "same-origin"
        response.headers["Content-Security-Policy"] = (
            "default-src 'self'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'; form-action 'self'"
        )
        if request.endpoint != "static":
            response.headers["Cache-Control"] = "no-store"
        return response

    @app.teardown_appcontext
    def close_db(_error):
        connection = g.pop("db", None)
        if connection is not None:
            connection.close()

    @app.context_processor
    def shared_context():
        if "csrf" not in session:
            session["csrf"] = secrets.token_urlsafe(24)
        return {"account": g.get("account"), "csrf": session["csrf"],
                "demo": bool(app.config["DEMO_ACCOUNTS"])}

    @app.template_filter("date_cn")
    def date_cn(value):
        if not value:
            return "—"
        if isinstance(value, datetime):
            return value.replace(tzinfo=timezone.utc).astimezone(
                timezone.utc if os.getenv("SA_DISPLAY_UTC") == "1" else CHINA_TZ
            ).strftime("%Y-%m-%d %H:%M")
        return str(value)

    @app.template_filter("number")
    def number(value):
        return "—" if value is None else format(value, ".2f")

    def require(*roles):
        def decorator(view):
            @wraps(view)
            def guarded(*args, **kwargs):
                if g.account is None:
                    return redirect(url_for("login"))
                if roles and g.account.actor not in roles:
                    abort(403)
                return view(*args, **kwargs)
            return guarded
        return decorator

    def handle_db_error(error):
        if error.errno == 1644:
            return error.msg
        if error.errno in (1044, 1045, 1142, 1370):
            return "当前账号没有执行该操作的权限。"
        if error.errno in (1213, 1205):
            return "数据正在处理，请稍后重试。"
        if error.errno in (1264, 1292, 1406):
            return "输入格式或长度超出允许范围。"
        app.logger.warning("MySQL operation failed with error %s", error.errno)
        return "数据库操作未完成，请检查连接或稍后重试。"

    @app.errorhandler(connector.Error)
    def database_error(error):
        if error.errno in (1044, 1045):
            forget_account()
            flash("账号连接已失效，请重新登录。", "error")
            return redirect(url_for("login"))
        status = 404 if error.errno == 1644 else 503
        return render_template("error.html", title="暂时无法打开", message=handle_db_error(error)), status

    @app.errorhandler(400)
    @app.errorhandler(403)
    @app.errorhandler(404)
    @app.errorhandler(413)
    def request_error(error):
        messages = {
            400: "请检查输入，或刷新页面后重试。", 403: "当前账号没有此页面的访问权限。",
            404: "未找到该页面或记录。", 413: "文件过大，单份材料最多 5 MiB。",
        }
        return render_template("error.html", title="暂时无法打开", message=messages[error.code]), error.code

    def verify_login(username, password):
        with connect(username, password) as connection:
            active = execute(connection, "SELECT CURRENT_ROLE() AS active")[0][0]["active"]
            roles = set(re.findall(r"`(sa_[a-z]+)`@", active))
            profile = []
            if roles & {"sa_student", "sa_reviewer"}:
                profile = call("web_profile", connection=connection)[0]
            for person in profile:
                actor = person["actor"]
                if (actor == "student" and "sa_student" in roles) or (
                    actor in REVIEWERS and "sa_reviewer" in roles
                ):
                    return Account(username, password, actor, person["name"], person["person_id"],
                                   person["class_id"], monotonic() + SESSION_SECONDS)
            for actor in ("publisher", "analyst"):
                if f"sa_{actor}" in roles:
                    return Account(username, password, actor, ROLE_NAMES[actor], username,
                                   None, monotonic() + SESSION_SECONDS)
        return None

    @app.route("/login", methods=["GET", "POST"])
    def login():
        if request.method == "GET":
            if g.account:
                return redirect(url_for("home"))
            return render_template("login.html", demo_accounts=app.config["DEMO_ACCOUNTS"])
        demo_actor = request.form.get("demo_actor")
        if demo_actor:
            demo_account = app.config["DEMO_ACCOUNTS"].get(demo_actor)
            if not demo_account:
                abort(403)
            username, password = demo_account
        else:
            username = request.form.get("username", "").strip()
            password = request.form.get("password", "")
        if not re.fullmatch(r"[A-Za-z0-9_]{1,32}", username) or not password or len(password) > 256:
            flash("请输入有效的账号和密码。", "error")
            return redirect(url_for("login"))
        try:
            account = verify_login(username, password)
        except connector.Error as error:
            message = "账号或密码有误。" if error.errno in (1044, 1045) else handle_db_error(error)
            flash(message, "error")
            return redirect(url_for("login"))
        if not account:
            flash("账号尚未绑定业务身份或未启用综测角色。", "error")
            return redirect(url_for("login"))
        forget_account()
        token = secrets.token_urlsafe(32)
        with account_lock:
            expired = [key for key, value in accounts.items() if value.expires <= monotonic()]
            for key in expired:
                del accounts[key]
            accounts[token] = account
        session["token"] = token
        return redirect(url_for("home"))

    @app.post("/logout")
    def logout():
        forget_account()
        return redirect(url_for("login"))

    @app.get("/")
    @require()
    def home():
        destinations = {"student": "student_workspace", "publisher": "publication", "analyst": "analytics"}
        return redirect(url_for(destinations.get(g.account.actor, "review")))

    def choose_year(prefer_published=False):
        years = query("SELECT * FROM web_years ORDER BY starts_on DESC, year_id DESC")
        requested = request.args.get("year")
        if requested:
            selected = next((row for row in years if row["year_id"] == requested), None)
            if selected is None:
                abort(404)
        else:
            selected = next((row for row in years if row["status"] == "published"), None) if prefer_published else None
            if selected is None and years:
                selected = years[0]
        return years, selected

    def accepting(year):
        now = datetime.now(timezone.utc).replace(tzinfo=None)
        return year["status"] == "open" and year["opens_at"] <= now < year["deadline_at"]

    @app.get("/student")
    @require("student")
    def student_workspace():
        years, year = choose_year()
        form, items, projects, draft, attachments = None, [], [], {}, {}
        if year:
            form_rows, items = call("my_form_status", year["year_id"])
            form = form_rows[0] if form_rows else None
            projects = call("web_projects", year["year_id"])[0]
            if form and form["status"] == "draft":
                notes, draft_items, materials = call("web_draft", year["year_id"])
                form["notes"] = notes[0]["notes"] if notes else ""
                draft = {row["item_id"]: row for row in draft_items}
                for material in materials:
                    attachments.setdefault(material["item_id"], []).append(material)
        names = {p["project_id"]: p["project_name"] for p in projects}
        return render_template("student.html", title="我的申报", years=years, year=year, form=form,
                               items=items, projects=projects, draft=draft, attachments=attachments,
                               project_names=names, can_edit=bool(year and accepting(year)),
                               editing=request.args.get("edit", type=int))

    def form_int(name):
        value = request.form.get(name, "")
        if not re.fullmatch(r"[0-9]{1,19}", value) or int(value) == 0:
            raise ValueError("编号无效。")
        return int(value)

    def form_score(name, optional=False):
        value = request.form.get(name, "").strip()
        if optional and not value:
            return None
        try:
            score = Decimal(value)
        except InvalidOperation:
            raise ValueError("请输入有效分值。") from None
        if not re.fullmatch(r"[0-9]{1,8}(?:\.[0-9]{1,2})?", value):
            raise ValueError("分值最多保留两位小数。")
        return score

    def form_year():
        value = request.form.get("year", "")
        if not value or len(value) > 24:
            abort(400)
        return value

    @app.post("/student/action/<action>")
    @require("student")
    def student_action(action):
        year = form_year()
        edit = None
        try:
            if action == "form":
                notes = request.form.get("notes", "").strip()
                call("save_form", year, notes)
                message = "已保存填报表。"
            elif action == "item":
                edit = form_int("item_id") if request.form.get("item_id") else None
                date = request.form.get("occurred_on", "")
                if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", date):
                    raise ValueError("请选择发生日期。")
                result = call("save_item", year, edit, form_int("project_id"),
                              request.form.get("details", "").strip(), form_score("claimed_score"), date)
                edit = result[0][0]["item_id"]
                message = "条目已保存，可在下方添加证明材料。"
            elif action == "upload":
                edit = form_int("item_id")
                attachment = request.files.get("evidence")
                if not attachment or not attachment.filename:
                    raise ValueError("请选择要上传的文件。")
                filename = attachment.filename.replace("\\", "/").rsplit("/", 1)[-1]
                call("add_evidence", year, edit, filename, attachment.stream.read(MAX_EVIDENCE + 1))
                message = "证明材料已上传。"
            elif action in {"withdraw", "remove", "submit", "reopen"}:
                procedure, field, message = {
                    "withdraw": ("withdraw_item", "item_id", "条目已撤销。"),
                    "remove": ("remove_evidence", "evidence_id", "材料已移除。"),
                    "submit": ("submit_form", None, "提交成功，等待班级初审。"),
                    "reopen": ("reopen_form", None, "原表已撤回为草稿。"),
                }[action]
                if field:
                    call(procedure, year, form_int(field))
                    if action == "remove":
                        edit = form_int("item_id")
                else:
                    call(procedure, year)
            else:
                abort(404)
            flash(message, "success")
        except ValueError as error:
            flash(str(error), "error")
        except connector.Error as error:
            flash(handle_db_error(error), "error")
        return redirect(url_for("student_workspace", year=year, edit=edit, _anchor="items"), code=303)

    @app.get("/student/results")
    @require("student")
    def student_results():
        years, year = choose_year(prefer_published=True)
        results, scores = call("my_result", year["year_id"]) if year else ([], [])
        return render_template("results.html", title="测评结果", years=years, year=year,
                               result=results[0] if results else None, scores=scores)

    @app.get("/review")
    @require(*REVIEWERS)
    def review():
        years, year = choose_year()
        selected = request.args.get("filter", "pending")
        if selected not in {"pending", "returned", "completed", "all"}:
            abort(400)
        items = call("review_queue", year["year_id"], "all")[0] if year else []
        buckets = {
            "pending": [row for row in items if row["status"] == g.account.actor + "_pending"],
            "returned": [row for row in items if row["status"] == "returned"],
            "completed": [row for row in items if row["status"] == "approved"],
            "all": items,
        }
        return render_template("review.html", title="审核工作台", years=years, year=year,
                               buckets=buckets, selected=selected)

    @app.get("/review/<int:item_id>")
    @require(*REVIEWERS)
    def review_detail(item_id):
        rows, files, history = call("read_review_item", item_id)
        if not rows:
            abort(404)
        item = rows[0]
        ai_rows = call("web_ai_draft", item_id)[0]
        return render_template("review_detail.html", title="申报审核", item=item, files=files, history=history,
                               ai=ai_rows[0] if ai_rows else None,
                               actionable=item["status"] == g.account.actor + "_pending")

    @app.post("/review/<int:item_id>")
    @require(*REVIEWERS)
    def review_decision(item_id):
        try:
            decision = request.form.get("decision", "")
            if decision not in {"pass", "return"}:
                raise ValueError("请选择审核结论。")
            score = form_score("score", optional=True) if decision == "pass" and g.account.actor == "final" else None
            call("review_item", item_id, decision, request.form.get("opinion", "").strip(), score)
            flash("审核决定已保存。", "success")
        except ValueError as error:
            flash(str(error), "error")
        except connector.Error as error:
            flash(handle_db_error(error), "error")
        return redirect(url_for("review_detail", item_id=item_id), code=303)

    @app.get("/evidence/<int:evidence_id>")
    @require(*REVIEWERS)
    def evidence(evidence_id):
        rows = call("read_evidence", evidence_id)[0]
        if not rows:
            abort(404)
        row = rows[0]
        response = send_file(BytesIO(row["file_body"]), mimetype="application/octet-stream",
                             as_attachment=True, download_name=row["file_name"])
        response.headers["X-File-SHA256"] = row["sha256"]
        return response

    @app.get("/publication")
    @require("publisher")
    def publication():
        years, year = choose_year()
        stats = query("SELECT * FROM project_submission_statistics WHERE year_id = %s ORDER BY project_id",
                      year["year_id"]) if year else []
        return render_template("publication.html", title="结果公示", years=years, year=year, stats=stats,
                               before_deadline=bool(year and datetime.now(timezone.utc).replace(tzinfo=None)
                                                    < year["deadline_at"]))

    @app.post("/publication/<action>")
    @require("publisher")
    def publication_action(action):
        year = form_year()
        procedures = {"close": ("web_close_submissions", "已结束该学年的申报。"),
                      "publish": ("publish_year", "计分与排名已生成，结果已公示。")}
        if action not in procedures:
            abort(404)
        procedure, message = procedures[action]
        if request.form.get("confirm") != "yes":
            flash("请勾选确认后继续。", "error")
        else:
            try:
                call(procedure, year)
                flash(message, "success")
            except connector.Error as error:
                flash(handle_db_error(error), "error")
        return redirect(url_for("publication", year=year), code=303)

    @app.get("/analytics")
    @require("analyst")
    def analytics():
        years, year = choose_year(prefer_published=True)
        class_id = request.args.get("class_id", "")
        ranking, distribution, stats, classes = [], [], [], {}
        if year:
            key = year["year_id"]
            distribution = query("SELECT * FROM class_result_distribution WHERE year_id = %s ORDER BY class_id, grade", key)
            classes = {row["class_id"]: row["class_name"] for row in distribution}
            ranking = query("SELECT * FROM published_results WHERE year_id = %s AND (%s = '' OR class_id = %s) ORDER BY rank_no, result_id",
                            key, class_id, class_id)
            distribution = [row for row in distribution if not class_id or row["class_id"] == class_id]
            stats = query("SELECT * FROM project_submission_statistics WHERE year_id = %s ORDER BY project_id", key)
        return render_template("analytics.html", title="测评统计", years=years, year=year, ranking=ranking,
                               distribution=distribution, stats=stats, classes=classes, class_id=class_id)

    @app.post("/review/<int:item_id>/ai")
    @require(*REVIEWERS)
    def review_ai(item_id):
        try:
            context_rows = call("web_ai_context", item_id)[0]
            if not context_rows:
                abort(404)
            draft = scoring.generate(context_rows[0])
            extracted = draft.get("extracted", {})
            call("web_save_ai_draft", item_id, draft["source"], draft["model"], draft["prompt_version"],
                 draft.get("rule_key"), extracted.get("subtype"), extracted.get("author_rank"),
                 extracted.get("author_count"), extracted.get("team_size"), extracted.get("award_level"),
                 extracted.get("award_rank"), extracted.get("hours"), draft["suggested_score"],
                 draft["confidence"], draft["rationale"], draft.get("raw"))
            flash("AI 初审草稿已生成，仅供审核参考。", "success")
        except scoring.AIError as error:
            flash(f"AI 初审暂不可用：{error}", "error")
        except ValueError as error:
            flash(str(error), "error")
        except connector.Error as error:
            flash(handle_db_error(error), "error")
        return redirect(url_for("review_detail", item_id=item_id), code=303)

    @app.get("/review/base")
    @require("initial")
    def base_scores():
        years, year = choose_year()
        rows = call("web_base_scores", year["year_id"])[0] if year else []
        return render_template("base_scores.html", title="基础分录入", years=years, year=year, rows=rows)

    @app.post("/review/base")
    @require("initial")
    def base_scores_save():
        year = form_year()
        rows = call("web_base_scores", year)[0]
        saved = 0
        try:
            for row in rows:
                student_id = row["student_id"]
                a = request.form.get(f"a_{student_id}", "").strip()
                b1 = request.form.get(f"b1_{student_id}", "").strip()
                if not a or not b1:
                    continue
                call("set_base_assessment", year, student_id, a, b1,
                     request.form.get(f"a_failed_{student_id}") == "yes",
                     request.form.get(f"academic_failed_{student_id}") == "yes")
                saved += 1
            flash(f"已保存 {saved} 名学生的 A/B1 基础分。", "success")
        except ValueError as error:
            flash(str(error), "error")
        except connector.Error as error:
            flash(handle_db_error(error), "error")
        return redirect(url_for("base_scores", year=year), code=303)

    return app


CHINA_TZ = timezone(timedelta(hours=8))

if __name__ == "__main__":
    create_app().run(host="127.0.0.1", port=int(os.getenv("SA_WEB_PORT", "8000")))


