"""Odysseus AppImage launcher.

Runs inside the AppImage with the bundled Python. Keeps every writable file
outside the (read-only) AppImage:

  config:  $XDG_CONFIG_HOME/odysseus/.env        (default ~/.config/odysseus/.env)
  data:    $XDG_DATA_HOME/odysseus/data          (default ~/.local/share/odysseus/data)

Usage:
  Odysseus.AppImage                start the server (or open the browser if it already runs)
  Odysseus.AppImage --no-browser   start without opening a browser
  Odysseus.AppImage --stop         stop a running instance
  Odysseus.AppImage --status       show whether it is running
  Odysseus.AppImage --config       open the .env file in your editor
  Odysseus.AppImage --paths        print config/data locations
  Odysseus.AppImage --version      print bundled Odysseus version
"""

import os
import shutil
import signal
import socket
import subprocess
import sys
import threading
import time

APP_ROOT = os.environ["ODYSSEUS_APP_ROOT"]

XDG_CONFIG = os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config")
XDG_DATA = os.environ.get("XDG_DATA_HOME") or os.path.expanduser("~/.local/share")
CONFIG_DIR = os.path.join(XDG_CONFIG, "odysseus")
STATE_DIR = os.path.join(XDG_DATA, "odysseus")
ENV_FILE = os.path.join(CONFIG_DIR, ".env")
PID_FILE = os.path.join(STATE_DIR, "odysseus.pid")


def _read(path, default=""):
    try:
        with open(path, encoding="utf-8") as fh:
            return fh.read().strip()
    except OSError:
        return default


def _notify(msg):
    if shutil.which("notify-send"):
        subprocess.Popen(["notify-send", "-a", "Odysseus", "-i", "odysseus", "Odysseus", msg],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def _open_browser(url):
    opener = shutil.which("xdg-open")
    if opener:
        # Clean environment so the host browser doesn't inherit AppImage vars.
        env = {k: v for k, v in os.environ.items()
               if not k.startswith(("APPIMAGE", "APPDIR", "ODYSSEUS_APP", "PYTHON"))}
        subprocess.Popen([opener, url], env=env, stdout=subprocess.DEVNULL,
                         stderr=subprocess.DEVNULL, start_new_session=True)
    else:
        import webbrowser
        webbrowser.open(url)


def _port_open(host, port):
    probe = "127.0.0.1" if host in ("0.0.0.0", "") else ("::1" if host == "::" else host)
    try:
        with socket.create_connection((probe, port), timeout=0.5):
            return True
    except OSError:
        return False


def _running_pid():
    pid = _read(PID_FILE)
    if not pid.isdigit():
        return None
    try:
        os.kill(int(pid), 0)
        return int(pid)
    except OSError:
        return None


def _bootstrap_config():
    os.makedirs(CONFIG_DIR, exist_ok=True)
    os.makedirs(STATE_DIR, exist_ok=True)
    if not os.path.exists(ENV_FILE):
        example = os.path.join(APP_ROOT, ".env.example")
        if os.path.exists(example):
            shutil.copyfile(example, ENV_FILE)
        else:
            open(ENV_FILE, "w").close()
        os.chmod(ENV_FILE, 0o600)
        print(f"[odysseus] Created {ENV_FILE} — edit it to set your LLM host / API keys.")


def main(argv):
    _bootstrap_config()

    from dotenv import load_dotenv
    # Exported shell vars win over .env (same precedence as upstream).
    load_dotenv(ENV_FILE, encoding="utf-8-sig")

    os.environ.setdefault("ODYSSEUS_DATA_DIR", os.path.join(STATE_DIR, "data"))
    data_dir = os.environ["ODYSSEUS_DATA_DIR"]
    os.makedirs(data_dir, exist_ok=True)
    # Upstream defaults this cache to <app root>/data/..., which is read-only here.
    os.environ.setdefault("ODYSSEUS_BROWSER_MCP_CACHE",
                          os.path.join(data_dir, "local", "playwright-mcp-cache"))

    host = os.environ.get("APP_BIND", "127.0.0.1")
    port = int(os.environ.get("APP_PORT", "7000"))
    browse_host = "localhost" if host in ("127.0.0.1", "0.0.0.0", "::") else host
    url = f"http://{browse_host}:{port}"

    if "--paths" in argv:
        print(f"config: {ENV_FILE}\ndata:   {data_dir}\nurl:    {url}")
        return 0
    if "--version" in argv:
        print(f"Odysseus {_read(os.path.join(APP_ROOT, 'HARNESS_VERSION'), 'unknown')} "
              f"({_read(os.path.join(APP_ROOT, 'SOURCE_COMMIT'), 'unknown')[:10]})")
        return 0
    if "--config" in argv:
        editor = os.environ.get("VISUAL") or os.environ.get("EDITOR")
        if editor and sys.stdin.isatty():
            return subprocess.call([editor, ENV_FILE])
        _open_browser(ENV_FILE)  # xdg-open picks the default text editor
        return 0
    if "--status" in argv:
        pid = _running_pid()
        print(f"running (pid {pid}) at {url}" if pid else "not running")
        return 0 if pid else 1
    if "--stop" in argv:
        pid = _running_pid()
        if not pid:
            print("Odysseus is not running.")
            return 0
        os.kill(pid, signal.SIGTERM)
        for _ in range(50):
            if _running_pid() is None:
                break
            time.sleep(0.2)
        else:
            os.kill(pid, signal.SIGKILL)
        print("Odysseus stopped.")
        _notify("Stopped")
        return 0

    want_browser = "--no-browser" not in argv

    # Already running (this launcher or something else on the port): just open it.
    if _running_pid() or _port_open(host, port):
        print(f"Odysseus already running at {url}")
        if want_browser:
            _open_browser(url)
        return 0

    with open(PID_FILE, "w") as fh:
        fh.write(str(os.getpid()))

    def _wait_then_open():
        for _ in range(600):  # first start can be slow (model/index warm-up)
            if _port_open(host, port):
                _notify(f"Running at {url}")
                if want_browser:
                    _open_browser(url)
                return
            time.sleep(0.5)

    threading.Thread(target=_wait_then_open, daemon=True).start()

    # Run from the writable state dir so any stray relative writes land there.
    os.chdir(STATE_DIR)
    sys.path.insert(0, APP_ROOT)
    try:
        import uvicorn
        uvicorn.run("app:app", host=host, port=port, log_level="info", app_dir=APP_ROOT)
    finally:
        if _read(PID_FILE) == str(os.getpid()):
            try:
                os.remove(PID_FILE)
            except OSError:
                pass
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
