"""Run a persistent, loopback-only demo against a separate MySQL instance."""
from contextlib import contextmanager
import json
import os
from pathlib import Path
import secrets
import shutil
import socket
import subprocess
import tempfile
from threading import Timer
import time
import webbrowser

from mysql import connector

from app import create_app

PROJECT = Path(__file__).resolve().parent
DEMO_USERS = {
    "student": ("sa_demo_s001", "sa_student"),
    "initial": ("sa_demo_initial1", "sa_reviewer"),
    "counselor": ("sa_demo_counselor", "sa_reviewer"),
    "final": ("sa_demo_final", "sa_reviewer"),
    "publisher": ("sa_demo_publisher", "sa_publisher"),
    "analyst": ("sa_demo_analyst", "sa_analyst"),
    # 管理员仅供 SQL 客户端与测试直连：web_profile 没有管理员绑定，
    # 故不进入下方网页演示账号列表（DEMO_ACCOUNTS）。
    "admin": ("sa_demo_admin", "sa_admin"),
    "initial_other": ("sa_demo_initial2", "sa_reviewer"),
    "student_other": ("sa_demo_s002", "sa_student"),
}
INSTALL_FILES = ("01_创建数据库.sql", "02_演示数据.sql", "03_网页接口.sql")


def mysql_tools():
    configured = os.getenv("SA_MYSQL_BIN")
    candidates = [Path(configured)] if configured else []
    if not configured:
        if os.name == "nt":
            candidates.append(Path(os.getenv("ProgramFiles", "C:/Program Files"))
                              / "MySQL" / "MySQL Server 8.4" / "bin")
        discovered = shutil.which("mysqld")
        if discovered:
            candidates.append(Path(discovered).parent)
    suffix = ".exe" if os.name == "nt" else ""
    for directory in candidates:
        server, client = directory / f"mysqld{suffix}", directory / f"mysql{suffix}"
        if server.is_file() and client.is_file():
            result = subprocess.run([server, "--no-defaults", "--version"], capture_output=True, check=True)
            if b"Ver 8.4." in result.stdout:
                return server.resolve(), client.resolve()
    raise RuntimeError("找不到 MySQL Server 8.4。请安装它，或将 SA_MYSQL_BIN 指向它的 bin 目录。")


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def root_connection(port, password):
    return connector.connect(host="127.0.0.1", port=port, user="root", password=password,
                             autocommit=True, connection_timeout=2)


def install_demo(client, port, state):
    with root_connection(port, "") as connection, connection.cursor() as cursor:
        cursor.execute("ALTER USER 'root'@'localhost' IDENTIFIED BY %s", (state["root_password"],))
    env = {**os.environ, "MYSQL_PWD": state["root_password"]}
    for name in INSTALL_FILES:
        result = subprocess.run(
            [client, "--no-defaults", "--protocol=TCP", "-h", "127.0.0.1", "-P", str(port),
             "-u", "root", "--default-character-set=utf8mb4"],
            input=(PROJECT / name).read_bytes(), env=env, capture_output=True,
        )
        if result.returncode:
            raise RuntimeError(f"{name} 导入失败。\n{result.stderr.decode('utf-8', errors='replace')}")
    with root_connection(port, state["root_password"]) as connection, connection.cursor() as cursor:
        for actor, (username, role) in DEMO_USERS.items():
            password = state["passwords"][actor]
            cursor.execute(f"CREATE USER '{username}'@'localhost' IDENTIFIED BY %s", (password,))
            cursor.execute(f"GRANT '{role}' TO '{username}'@'localhost'")
            cursor.execute(f"SET DEFAULT ROLE '{role}' TO '{username}'@'localhost'")


@contextmanager
def demo_database(runtime):
    server_bin, client_bin = mysql_tools()
    runtime = Path(runtime).resolve()
    runtime.mkdir(parents=True, exist_ok=True)
    lock_file = runtime / "running.lock"
    try:
        with lock_file.open("x", encoding="utf-8") as lock:
            lock.write(str(os.getpid()))
    except FileExistsError:
        raise RuntimeError(f"演示可能已经运行。若上次进程已退出，请删除锁文件 {lock_file} 再重试。") from None
    try:
        with start_mysql(runtime, server_bin, client_bin) as config:
            yield config
    finally:
        lock_file.unlink(missing_ok=True)


@contextmanager
def start_mysql(runtime, server_bin, client_bin):
    state_file = runtime / "local-state.json"
    new = not state_file.exists()
    if new:
        data_dir = Path(tempfile.mkdtemp(prefix="mysql-data-", dir=runtime)).resolve()
        state = {
            "data_dir": data_dir.name,
            "root_password": secrets.token_urlsafe(32),
            "passwords": {actor: secrets.token_urlsafe(32) for actor in DEMO_USERS},
        }
    else:
        state = json.loads(state_file.read_text(encoding="utf-8"))
        data_dir = (runtime / state["data_dir"]).resolve()
        if data_dir.parent != runtime or not data_dir.name.startswith("mysql-data-") or not data_dir.is_dir():
            raise RuntimeError("演示数据库路径无效，请指定一个新的 SA_DEMO_DIR。")

    # MySQL on Windows can open its data directory relative to the child working directory.
    # Forward slashes and explicit undo scanning keep initialization and restart consistent.
    data_path = data_dir.as_posix() if data_dir.as_posix().isascii() else "."
    flags = [server_bin, "--no-defaults", f"--datadir={data_path}",
             f"--innodb-undo-directory={data_path}", f"--innodb-directories={data_path}",
             "--innodb-undo-log-truncate=OFF", "--skip-log-bin", "--console"]
    if new:
        print("正在初始化独立的 MySQL 演示数据库…", flush=True)
        result = subprocess.run([*flags, "--initialize-insecure"], cwd=data_dir, capture_output=True)
        if result.returncode:
            raise RuntimeError(result.stderr.decode(errors="replace"))

    port = free_port()
    log_path = runtime / "mysql.log"
    with log_path.open("wb") as log:
        mysql = subprocess.Popen(
            [*flags, "--bind-address=127.0.0.1", f"--port={port}", "--mysqlx=OFF",
             "--max-allowed-packet=32M", "--innodb-buffer-pool-size=64M",
             # 学年状态自动推进依赖事件调度器；与 01 的 SET PERSIST 互为兜底
             "--event-scheduler=ON"],
            cwd=data_dir, stdout=log, stderr=subprocess.STDOUT,
        )
        try:
            for _ in range(60):
                if mysql.poll() is not None:
                    raise RuntimeError(f"独立 MySQL 启动失败，请查看 {log_path}")
                try:
                    with root_connection(port, "" if new else state["root_password"]):
                        break
                except connector.Error:
                    time.sleep(.25)
            else:
                raise RuntimeError(f"无法连接演示 MySQL，请查看 {log_path}")
            if new:
                install_demo(client_bin, port, state)
                pending = state_file.with_suffix(".tmp")
                pending.write_text(json.dumps(state), encoding="utf-8")
                pending.replace(state_file)

            yield {
                "MYSQL_HOST": "127.0.0.1",
                "MYSQL_PORT": port,
                "MYSQL_TLS_CA": None,
                "SESSION_COOKIE_SECURE": False,
                "DEMO_ACCOUNTS": {
                    actor: (username, state["passwords"][actor])
                    for actor, (username, _) in DEMO_USERS.items()
                    if not actor.endswith("_other") and actor != "admin"
                },
            }
        finally:
            if mysql.poll() is None:
                for password in (state["root_password"], ""):
                    try:
                        with root_connection(port, password) as connection, connection.cursor() as cursor:
                            cursor.execute("SHUTDOWN")
                        break
                    except connector.Error:
                        continue
                try:
                    mysql.wait(timeout=12)
                except subprocess.TimeoutExpired:
                    mysql.terminate()
                    mysql.wait(timeout=5)


def main():
    default_dir = Path(os.environ["LOCALAPPDATA"]) / "StudentAssessmentDemo" if os.name == "nt" else PROJECT / ".demo"
    runtime = Path(os.getenv("SA_DEMO_DIR", str(default_dir)))
    web_port = int(os.getenv("SA_WEB_PORT", "8000"))
    with demo_database(runtime) as config:
        app = create_app(config)
        address = f"http://127.0.0.1:{web_port}"
        print(f"网页地址 {address} · 按 Ctrl+C 停止。", flush=True)
        if os.getenv("SA_NO_BROWSER") != "1":
            opener = Timer(1, webbrowser.open, args=(address,))
            opener.daemon = True
            opener.start()
        app.run(host="127.0.0.1", port=web_port, debug=False, use_reloader=False)


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, OSError, connector.Error) as error:
        raise SystemExit(str(error)) from None

