#!/usr/bin/env python3
"""yt2abs-web — a one-page front door for the yt2abs audiobook pipeline.

Paste a link, optionally a title and a playlist mode, and the job is queued for
yt2abs. Jobs run one at a time; the page polls /api/jobs for live status.

Everything is Python 3 standard library — no venv, no pip.

Auth
----
Two modes, matching what Sonarr/Radarr users expect:

  * Username + password (recommended): set YT2ABS_WEB_USERNAME and
    YT2ABS_WEB_PASSWORD. The page shows a normal login form; the session is a
    random HttpOnly cookie. YT2ABS_WEB_TOKEN still works for API/automation.
  * Token only (legacy): set just YT2ABS_WEB_TOKEN. The login form accepts the
    token itself, and ?t=<token> on a GET exchanges it for a session cookie and
    redirects, so the token does not stay in the address bar.

Either mode can be disabled with YT2ABS_ALLOW_UNAUTHENTICATED=1 (only behind a
proxy that already authenticates, e.g. Authelia or Cloudflare Access).

  * Authorization: Bearer <token> always works for curl / scripts.
  * the yt2abs_session cookie is a random id (HttpOnly, SameSite=Lax).

Sessions live in memory and expire after YT2ABS_SESSION_TTL seconds (default
30 days); restarting the service logs everyone out. Failed logins are rate
limited to 8 per IP per 5 minutes.

Environment:
  YT2ABS_WEB_USERNAME          login username (optional)
  YT2ABS_WEB_PASSWORD          login password (optional; needs a username)
  YT2ABS_WEB_TOKEN             API bearer token / token-only login
  YT2ABS_ALLOW_UNAUTHENTICATED 1 = no auth (default 0)
  YT2ABS_COOKIE_SECURE         1 = add Secure to the session cookie (default 0)
  YT2ABS_SESSION_TTL           session lifetime seconds (default 2592000)
  YT2ABS_WEB_HOST              default 0.0.0.0
  YT2ABS_WEB_PORT              default 8087
  YT2ABS_DB                    default /var/lib/yt2abs/queue.db
  YT2ABS_JOB_LOG_DIR           per-job logs, default /var/lib/yt2abs/logs
  YT2ABS_BIN                   default /usr/local/bin/yt2abs
  YT2ABS_TIMEOUT               per-job seconds, default 21600 (6 h)
"""

import json
import os
import secrets
import sqlite3
import subprocess
import sys
import threading
import time
import uuid
from http.cookies import SimpleCookie
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from queue import Queue
from urllib.parse import parse_qs, urlparse

TOKEN = os.environ.get("YT2ABS_WEB_TOKEN", "").strip()
WEB_USER = os.environ.get("YT2ABS_WEB_USERNAME", "").strip()
WEB_PASS = os.environ.get("YT2ABS_WEB_PASSWORD", "")
FORM_AUTH = bool(WEB_USER and WEB_PASS)
ALLOW_ANON = os.environ.get("YT2ABS_ALLOW_UNAUTHENTICATED", "0") == "1"
COOKIE_SECURE = os.environ.get("YT2ABS_COOKIE_SECURE", "0") == "1"
SESSION_TTL = int(os.environ.get("YT2ABS_SESSION_TTL", str(30 * 86400)))
HOST = os.environ.get("YT2ABS_WEB_HOST", "0.0.0.0")
PORT = int(os.environ.get("YT2ABS_WEB_PORT", "8087"))
DB_PATH = os.environ.get("YT2ABS_DB", "/var/lib/yt2abs/queue.db")
LOG_DIR = os.environ.get("YT2ABS_JOB_LOG_DIR", "/var/lib/yt2abs/logs")
BIN = os.environ.get("YT2ABS_BIN", "/usr/local/bin/yt2abs")
TIMEOUT = int(os.environ.get("YT2ABS_TIMEOUT", "21600"))
COOKIE = "yt2abs_session"
MAX_LOG_BYTES = 256 * 1024
KEEP_JOBS = 200
MAX_FAILED_LOGINS = 8
LOGIN_WINDOW = 300

DB_LOCK = threading.Lock()
JOB_Q: "Queue[str]" = Queue()

SESSIONS = {}
SESSIONS_LOCK = threading.Lock()
LOGIN_FAILS = {}
LOGIN_LOCK = threading.Lock()


# ── auth helpers ────────────────────────────────────────────────────────────

def token_ok(supplied):
    # Compare as bytes: compare_digest(str, str) raises on non-ASCII input.
    if not supplied:
        return False
    try:
        return secrets.compare_digest(supplied.encode("utf-8"), TOKEN.encode("utf-8"))
    except (UnicodeError, TypeError):
        return False


def credentials_ok(username, password):
    """Username+password when configured; otherwise the password is the token."""
    if FORM_AUTH:
        u = username.encode("utf-8", "replace")
        p = password.encode("utf-8", "replace")
        return (secrets.compare_digest(u, WEB_USER.encode())
                and secrets.compare_digest(p, WEB_PASS.encode()))
    if TOKEN:
        return token_ok(password)
    return False


def new_session():
    sid = secrets.token_urlsafe(32)
    with SESSIONS_LOCK:
        now = time.time()
        # opportunistic cleanup
        for key in [k for k, exp in SESSIONS.items() if exp < now]:
            del SESSIONS[key]
        SESSIONS[sid] = now + SESSION_TTL
    return sid


def session_ok(sid):
    if not sid:
        return False
    with SESSIONS_LOCK:
        exp = SESSIONS.get(sid)
        if exp is None:
            return False
        if exp < time.time():
            del SESSIONS[sid]
            return False
        return True


def drop_session(sid):
    with SESSIONS_LOCK:
        SESSIONS.pop(sid, None)


def login_blocked(ip):
    now = time.time()
    with LOGIN_LOCK:
        count, first = LOGIN_FAILS.get(ip, (0, now))
        if now - first > LOGIN_WINDOW:
            LOGIN_FAILS[ip] = (0, now)
            return False
        return count >= MAX_FAILED_LOGINS


def note_login_failure(ip):
    now = time.time()
    with LOGIN_LOCK:
        count, first = LOGIN_FAILS.get(ip, (0, now))
        if now - first > LOGIN_WINDOW:
            count, first = 0, now
        LOGIN_FAILS[ip] = (count + 1, first)


def clear_login_failures(ip):
    with LOGIN_LOCK:
        LOGIN_FAILS.pop(ip, None)


# ── database ────────────────────────────────────────────────────────────────

def db():
    conn = sqlite3.connect(DB_PATH, timeout=10)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=DELETE")
    return conn


def init_db():
    os.makedirs(os.path.dirname(DB_PATH), exist_ok=True)
    os.makedirs(LOG_DIR, exist_ok=True)
    with DB_LOCK, db() as conn:
        conn.execute(
            """CREATE TABLE IF NOT EXISTS jobs (
                   id          TEXT PRIMARY KEY,
                   url         TEXT NOT NULL,
                   title       TEXT,
                   book        TEXT,
                   mode        TEXT NOT NULL,
                   status      TEXT NOT NULL,
                   created_at  REAL NOT NULL,
                   started_at  REAL,
                   finished_at REAL,
                   exit_code   INTEGER,
                   message     TEXT
               )"""
        )
        conn.execute("CREATE INDEX IF NOT EXISTS jobs_created ON jobs(created_at)")
        cols = {row[1] for row in conn.execute("PRAGMA table_info(jobs)")}
        if "book" not in cols:
            conn.execute("ALTER TABLE jobs ADD COLUMN book TEXT")


def recover_jobs():
    with DB_LOCK, db() as conn:
        conn.execute(
            "UPDATE jobs SET status='failed', finished_at=?, message=? "
            "WHERE status='running'",
            (time.time(), "interrupted by a service restart"),
        )
        ids = [r["id"] for r in conn.execute(
            "SELECT id FROM jobs WHERE status='queued' ORDER BY created_at")]
    for jid in ids:
        JOB_Q.put(jid)


def get_job(jid):
    with DB_LOCK, db() as conn:
        return conn.execute("SELECT * FROM jobs WHERE id=?", (jid,)).fetchone()


def list_jobs(limit=25):
    with DB_LOCK, db() as conn:
        rows = conn.execute(
            "SELECT * FROM jobs ORDER BY created_at DESC LIMIT ?", (limit,)
        ).fetchall()
    return [dict(r) for r in rows]


def update_job(jid, **fields):
    if not fields:
        return
    cols = ", ".join(f"{k}=?" for k in fields)
    with DB_LOCK, db() as conn:
        conn.execute(f"UPDATE jobs SET {cols} WHERE id=?", (*fields.values(), jid))


def prune_jobs():
    with DB_LOCK, db() as conn:
        stale = [r["id"] for r in conn.execute(
            "SELECT id FROM jobs ORDER BY created_at DESC LIMIT -1 OFFSET ?",
            (KEEP_JOBS,))]
        for jid in stale:
            conn.execute("DELETE FROM jobs WHERE id=?", (jid,))
    for jid in stale:
        try:
            os.unlink(os.path.join(LOG_DIR, f"{jid}.log"))
        except OSError:
            pass


# ── worker ──────────────────────────────────────────────────────────────────

def summarize(log_path):
    """Return (book_name|None, human message) from the tail of a job log."""
    try:
        with open(log_path, "r", errors="replace") as fh:
            lines = fh.read()[-20000:].splitlines()
    except OSError:
        return None, ""
    for line in reversed(lines):
        if "✓ wrote:" in line or "✓ dropped:" in line:
            path = line.split(":", 1)[1].strip()
            return os.path.basename(os.path.dirname(path)), path[:300]
        if "SKIP:" in line:
            return None, ("Skipped: " + line.split("SKIP:", 1)[1].strip())[:300]
        if "ERROR:" in line:
            return None, line.split("ERROR:", 1)[1].strip()[:300]
    return None, (lines[-1][:300] if lines else "")


def run_job(jid):
    row = get_job(jid)
    if row is None or row["status"] != "queued":
        return
    update_job(jid, status="running", started_at=time.time(), message="")

    cmd = [BIN, row["url"]]
    if row["title"]:
        cmd += ["--title", row["title"]]
    if row["mode"] in ("merge", "split"):
        cmd += [f"--{row['mode']}"]

    env = dict(os.environ)
    log_path = os.path.join(LOG_DIR, f"{jid}.log")
    code = None
    try:
        with open(log_path, "wb") as log:
            proc = subprocess.run(
                cmd, stdout=log, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL,
                cwd="/tmp", env=env, timeout=TIMEOUT,
            )
        code = proc.returncode
    except subprocess.TimeoutExpired:
        update_job(jid, status="failed", finished_at=time.time(),
                   message=f"timed out after {TIMEOUT // 3600} h")
        return
    except Exception as exc:  # noqa: BLE001 — the UI must show *something*
        update_job(jid, status="failed", finished_at=time.time(),
                   message=f"could not start job: {exc}")
        return

    book, message = summarize(log_path)
    fields = dict(status="done" if code == 0 else "failed", finished_at=time.time(),
                  exit_code=code, message=message)
    if book:
        fields["book"] = book
    update_job(jid, **fields)
    prune_jobs()


def worker():
    while True:
        jid = JOB_Q.get()
        try:
            run_job(jid)
        except Exception as exc:  # noqa: BLE001
            update_job(jid, status="failed", finished_at=time.time(),
                       message=f"worker error: {exc}")
        finally:
            JOB_Q.task_done()


# ── pages ───────────────────────────────────────────────────────────────────

LOGIN_PAGE = """<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>yt2abs — unlock</title>
<style>
  :root {{ color-scheme: light dark; }}
  body {{ margin:0; min-height:100vh; display:grid; place-items:center;
         font:16px/1.5 system-ui,-apple-system,"Segoe UI",sans-serif;
         background:#0f1115; color:#e7e9ee; }}
  form {{ width:min(92vw,360px); padding:28px; border-radius:18px;
         background:#171a21; border:1px solid #262b36; }}
  h1 {{ font-size:18px; margin:0 0 6px; }}
  p {{ margin:0 0 18px; color:#9aa3b2; font-size:14px; }}
  input,button {{ width:100%; box-sizing:border-box; font:inherit; border-radius:10px; }}
  input {{ padding:12px; background:#0f1115; border:1px solid #2c3341; color:#e7e9ee; }}
  button {{ margin-top:12px; padding:12px; border:0; background:#9a5c0c; color:#fff;
            font-weight:650; cursor:pointer; }}
  .err {{ color:#ff8a8a; font-size:14px; margin-top:12px; }}
</style></head><body>
<form method="post" action="/login">
  <h1>YouTube → Audiobookshelf</h1>
  <p>{hint}</p>
  {user_field}
  <input name="password" type="password" autocomplete="current-password"
         placeholder="{pw_placeholder}"{pw_autofocus} required>
  <button>Sign in</button>{error}
</form></body></html>"""

PAGE = """<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>YouTube → Audiobookshelf</title>
<style>
  :root {
    color-scheme: light dark;
    --bg:#0f1115; --card:#171a21; --line:#262b36; --text:#e7e9ee;
    --muted:#9aa3b2; --accent:#f0b35a; --btn:#9a5c0c; --btn-hover:#b06a0e;
    --ok:#63d29a; --bad:#ff8a8a; --run:#7cc4ff;
  }
  @media (prefers-color-scheme: light) {
    :root { --bg:#f5f6f8; --card:#ffffff; --line:#e3e6ec; --text:#171a21;
            --muted:#667085; --accent:#a86510; --ok:#178a55; --bad:#c0392b;
            --run:#1a6fc4; }
  }
  * { box-sizing:border-box; }
  body { margin:0; background:var(--bg); color:var(--text);
         font:16px/1.55 system-ui,-apple-system,"Segoe UI",Roboto,sans-serif; }
  main { width:min(100% - 32px, 720px); margin:0 auto; padding:32px 0 64px; }
  h1 { font-size:clamp(22px,5vw,30px); letter-spacing:-.02em; margin:0 0 4px; }
  .topbar { display:flex; align-items:baseline; justify-content:space-between;
            gap:16px; }
  .logout { color:var(--muted); font-size:14px; text-decoration:none;
            white-space:nowrap; }
  .logout:hover { color:var(--text); text-decoration:underline; }
  .sub { color:var(--muted); margin:0 0 28px; font-size:15px; }
  form, .panel { background:var(--card); border:1px solid var(--line);
                 border-radius:18px; padding:20px; }
  label { display:block; font-size:13px; color:var(--muted); margin-bottom:6px;
          text-transform:uppercase; letter-spacing:.06em; }
  input, select, button { font:inherit; }
  input, select { width:100%; padding:12px 13px; border-radius:11px;
                  background:var(--bg); border:1px solid var(--line); color:var(--text); }
  .grid { display:grid; gap:16px; }
  .row { display:grid; gap:16px; grid-template-columns:1fr; }
  @media (min-width:620px) { .row { grid-template-columns:1.6fr 1fr; } }
  button { margin-top:18px; width:100%; padding:13px; border:0; border-radius:11px;
           background:var(--btn); color:#fff; font-weight:700; cursor:pointer; }
  button:hover { background:var(--btn-hover); }
  button:focus-visible { outline:3px solid var(--accent); outline-offset:2px; }
  button:disabled { opacity:.6; cursor:progress; }
  #msg { min-height:1.2em; margin:12px 0 0; font-size:14px; color:var(--muted); }
  #msg.bad { color:var(--bad); }
  h2 { font-size:14px; text-transform:uppercase; letter-spacing:.08em;
       color:var(--muted); margin:34px 0 12px; }
  ul { list-style:none; margin:0; padding:0; display:grid; gap:10px; }
  li { background:var(--card); border:1px solid var(--line); border-radius:14px;
       padding:14px 16px; }
  li.empty { padding:16px 22px; }
  .top { display:flex; gap:10px; align-items:baseline; justify-content:space-between; }
  .name { font-weight:600; overflow-wrap:anywhere; }
  .pill { flex:none; font-size:12px; font-weight:700; letter-spacing:.04em;
          text-transform:uppercase; padding:3px 9px; border-radius:999px;
          border:1px solid currentColor; }
  .queued { color:var(--muted); } .running { color:var(--run); }
  .done { color:var(--ok); } .failed { color:var(--bad); }
  .meta { color:var(--muted); font-size:13px; margin-top:4px; overflow-wrap:anywhere; }
  .meta a { color:inherit; text-decoration:underline; text-underline-offset:2px; }
  .meta a:hover { color:var(--text); }
  .empty { color:var(--muted); font-size:14px; }
</style></head><body>
<main>
  <div class="topbar">
    <h1>YouTube → Audiobookshelf</h1>
    <!--LOGOUT-->
  </div>
  <p class="sub">Paste a link. It comes out as a chaptered audiobook in your library.</p>

  <form id="add">
    <div class="grid">
      <div>
        <label for="url">YouTube URL</label>
        <input id="url" name="url" type="url" required
               placeholder="https://www.youtube.com/watch?v=…">
      </div>
      <div class="row">
        <div>
          <label for="title">Title (optional)</label>
          <input id="title" name="title" maxlength="200"
                 placeholder="Leave blank to use the video title">
        </div>
        <div>
          <label for="mode">Mode</label>
          <select id="mode" name="mode">
            <option value="auto">Auto</option>
            <option value="merge">Playlist → one book</option>
            <option value="split">Playlist → one book each</option>
          </select>
        </div>
      </div>
    </div>
    <button id="submit" type="submit">Add audiobook</button>
    <p id="msg" role="status"></p>
  </form>

  <h2>Queue</h2>
  <ul id="jobs"><li class="empty">Loading…</li></ul>
</main>
<script>
const $ = (id) => document.getElementById(id);
const jobsEl = $("jobs"), msgEl = $("msg"), form = $("add"), btn = $("submit");
let known = "";

function when(ts) {
  if (!ts) return "";
  const d = new Date(ts * 1000);
  return d.toLocaleString([], { month: "short", day: "numeric",
                                hour: "2-digit", minute: "2-digit" });
}

function card(j) {
  const li = document.createElement("li");
  const top = document.createElement("div");
  top.className = "top";
  const name = document.createElement("div");
  name.className = "name";
  name.textContent = j.title || j.book || "YouTube video";
  const pill = document.createElement("span");
  pill.className = "pill " + j.status;
  pill.textContent = j.status;
  top.append(name, pill);

  const meta = document.createElement("div");
  meta.className = "meta";
  const src = document.createElement("a");
  src.href = j.url;
  src.textContent = j.url;
  src.target = "_blank";
  src.rel = "noopener noreferrer";
  src.referrerPolicy = "no-referrer";
  src.title = "Open the original video";
  meta.append(src);

  const bits = ["queued " + when(j.created_at)];
  if (j.started_at) bits.push("started " + when(j.started_at));
  meta.append(document.createTextNode(" · " + bits.join(" · ")));

  li.append(top, meta);
  if (j.message) {
    const m = document.createElement("div");
    m.className = "meta";
    m.textContent = j.message;
    li.append(m);
  }
  if (j.status === "failed") {
    const a = document.createElement("a");
    a.className = "meta";
    a.href = "/api/jobs/" + j.id + "/log";
    a.textContent = "View log →";
    a.target = "_blank";
    li.append(a);
  }
  return li;
}

async function refresh() {
  try {
    const r = await fetch("/api/jobs", { headers: { "Accept": "application/json" } });
    if (r.status === 401) { location.reload(); return; }
    const data = await r.json();
    const sig = JSON.stringify(data.jobs);
    if (sig === known) return;
    known = sig;
    jobsEl.replaceChildren();
    if (!data.jobs.length) {
      const li = document.createElement("li");
      li.className = "empty";
      li.textContent = "Nothing yet. Paste a link above.";
      jobsEl.append(li);
      return;
    }
    data.jobs.forEach(j => jobsEl.append(card(j)));
  } catch (e) { /* keep the last good render */ }
}

form.addEventListener("submit", async (ev) => {
  ev.preventDefault();
  btn.disabled = true;
  msgEl.className = "";
  msgEl.textContent = "Queueing…";
  try {
    const r = await fetch("/api/jobs", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ url: $("url").value.trim(),
                             title: $("title").value.trim(),
                             mode: $("mode").value })
    });
    const data = await r.json().catch(() => ({}));
    if (!r.ok) throw new Error(data.error || ("HTTP " + r.status));
    msgEl.textContent = "Queued. It will start as soon as the current job finishes.";
    form.reset();
    known = "";
    refresh();
  } catch (e) {
    msgEl.className = "bad";
    msgEl.textContent = e.message;
  } finally {
    btn.disabled = false;
  }
});

refresh();
setInterval(refresh, 3000);
</script></body></html>"""


# ── http ────────────────────────────────────────────────────────────────────

def cookie_value(handler, name):
    cookie = SimpleCookie()
    try:
        cookie.load(handler.headers.get("Cookie", ""))
    except Exception:  # noqa: BLE001
        return ""
    return cookie[name].value if name in cookie else ""


class Handler(BaseHTTPRequestHandler):
    server_version = "yt2abs-web/2.0"

    def log_request(self, code="-", size="-"):
        # Never log the query string: ?t=<token> would land in journald.
        sys.stderr.write('%s "%s %s" %s\n' % (
            self.address_string(), self.command, urlparse(self.path).path, code))

    def client_ip(self):
        return self.client_address[0] if self.client_address else "?"

    # ── helpers ──
    def send(self, code, body=b"", ctype="text/plain; charset=utf-8", headers=None):
        if isinstance(body, str):
            body = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Referrer-Policy", "same-origin")
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def json(self, code, payload):
        self.send(code, json.dumps(payload), "application/json; charset=utf-8")

    def authed(self):
        if ALLOW_ANON:
            return True
        auth = self.headers.get("Authorization", "")
        if auth.startswith("Bearer ") and token_ok(auth[7:].strip()):
            return True
        return session_ok(cookie_value(self, COOKIE))

    def session_cookie(self, sid):
        parts = [f"{COOKIE}={sid}", "Path=/", f"Max-Age={SESSION_TTL}",
                 "HttpOnly", "SameSite=Lax"]
        if COOKIE_SECURE:
            parts.append("Secure")
        return {"Set-Cookie": "; ".join(parts)}

    def login_page(self, error=""):
        if FORM_AUTH:
            user_field = ('<input name="username" type="text" autocomplete="username" '
                          'placeholder="username" autofocus required>')
            hint = "Sign in to the audiobook queue."
            pw_placeholder = "password"
            pw_autofocus = ""
        else:
            user_field = ""
            hint = "Enter the access token from the service configuration."
            pw_placeholder = "access token"
            pw_autofocus = " autofocus"
        return self.send(200, LOGIN_PAGE.format(
            error=error, hint=hint, user_field=user_field,
            pw_placeholder=pw_placeholder, pw_autofocus=pw_autofocus),
            "text/html; charset=utf-8", {"Cache-Control": "no-store"})

    # ── GET ──
    def do_GET(self):
        parsed = urlparse(self.path)
        query = parse_qs(parsed.query)
        path = parsed.path.rstrip("/") or "/"

        if path == "/healthz":
            return self.send(200, "ok")

        if not TOKEN and not FORM_AUTH and not ALLOW_ANON:
            return self.send(500, "No credentials configured")

        # ?t=<token> is an exchange, not a session: swap it for a cookie and
        # redirect, so the token never stays in the URL or the browser history.
        supplied = (query.get("t") or [""])[0]
        if supplied and TOKEN:
            if token_ok(supplied):
                return self.send(303, "", headers={
                    "Location": path if path != "/" else "/",
                    **self.session_cookie(new_session()),
                })
            return self.login_page("<p class='err'>Incorrect credentials.</p>")

        # Logout must work even with a dead/absent session.
        if path == "/logout":
            drop_session(cookie_value(self, COOKIE))
            return self.send(303, "", headers={
                "Location": "/",
                "Set-Cookie": f"{COOKIE}=; Path=/; Max-Age=0; HttpOnly; SameSite=Lax",
            })

        if not self.authed():
            if path.startswith("/api/"):
                return self.json(401, {"error": "unauthorized"})
            return self.login_page()

        if path == "/":
            headers = {"Cache-Control": "no-store",
                       "Content-Security-Policy":
                           "default-src 'none'; style-src 'unsafe-inline'; "
                           "script-src 'unsafe-inline'; connect-src 'self'; "
                           "img-src 'self' data:; form-action 'self'; base-uri 'none'"}
            logout = ('<a class="logout" href="/logout">Log out</a>'
                      if (FORM_AUTH or TOKEN) and not ALLOW_ANON else "")
            return self.send(200, PAGE.replace("<!--LOGOUT-->", logout),
                             "text/html; charset=utf-8", headers)

        if path == "/api/jobs":
            return self.json(200, {"jobs": list_jobs()})

        if path.startswith("/api/jobs/") and path.endswith("/log"):
            jid = path.split("/")[3]
            if not jid.isalnum():
                return self.json(400, {"error": "bad id"})
            log_path = os.path.join(LOG_DIR, f"{jid}.log")
            try:
                size = os.path.getsize(log_path)
                with open(log_path, "rb") as fh:
                    fh.seek(max(0, size - MAX_LOG_BYTES))
                    body = fh.read()
            except OSError:
                return self.json(404, {"error": "no log"})
            return self.send(200, body, "text/plain; charset=utf-8")

        if path == "/favicon.ico":
            return self.send(204)

        return self.json(404, {"error": "not found"})

    # ── POST ──
    def do_POST(self):
        parsed = urlparse(self.path)
        path = parsed.path.rstrip("/") or "/"
        ip = self.client_ip()

        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            return self.json(400, {"error": "bad Content-Length"})
        if length > 64 * 1024:
            return self.json(413, {"error": "body too large"})
        raw = self.rfile.read(length) if length else b""

        if path == "/login":
            if login_blocked(ip):
                return self.send(429, "Too many failed attempts. Try again later.")
            form = parse_qs(raw.decode("utf-8", "replace"))
            username = (form.get("username") or [""])[0]
            supplied = (form.get("password") or form.get("token") or [""])[0]
            if credentials_ok(username, supplied):
                clear_login_failures(ip)
                return self.send(303, "", headers={
                    "Location": "/", **self.session_cookie(new_session())})
            note_login_failure(ip)
            return self.login_page("<p class='err'>Incorrect credentials.</p>")

        if not self.authed():
            return self.json(401, {"error": "unauthorized"})

        if path != "/api/jobs":
            return self.json(404, {"error": "not found"})

        try:
            if (self.headers.get("Content-Type") or "").startswith("application/json"):
                data = json.loads(raw.decode("utf-8") or "{}")
            else:
                form = parse_qs(raw.decode("utf-8", "replace"))
                data = {k: (v[0] if v else "") for k, v in form.items()}
        except (ValueError, UnicodeDecodeError):
            return self.json(400, {"error": "invalid body"})

        url = str(data.get("url", "")).strip()
        title = str(data.get("title", "")).strip()[:200]
        mode = str(data.get("mode", "auto")).strip().lower()

        if not (1 <= len(url) <= 2048):
            return self.json(400, {"error": "URL is required"})
        parsed_url = urlparse(url)
        if parsed_url.scheme.lower() not in ("http", "https") or not parsed_url.netloc:
            return self.json(400, {"error": "only http(s) links are accepted"})
        if mode not in ("auto", "merge", "split"):
            return self.json(400, {"error": "bad mode"})

        jid = uuid.uuid4().hex[:12]
        with DB_LOCK, db() as conn:
            conn.execute(
                "INSERT INTO jobs (id,url,title,mode,status,created_at) "
                "VALUES (?,?,?,?, 'queued', ?)",
                (jid, url, title, mode, time.time()),
            )
        JOB_Q.put(jid)
        return self.json(201, {"id": jid})


def main():
    if not TOKEN and not FORM_AUTH and not ALLOW_ANON:
        sys.exit("No credentials configured — set YT2ABS_WEB_USERNAME and "
                 "YT2ABS_WEB_PASSWORD, or YT2ABS_WEB_TOKEN, or explicitly set "
                 "YT2ABS_ALLOW_UNAUTHENTICATED=1 behind an authenticating proxy")
    init_db()
    recover_jobs()
    threading.Thread(target=worker, daemon=True).start()
    httpd = ThreadingHTTPServer((HOST, PORT), Handler)
    httpd.daemon_threads = True
    mode = "anonymous" if ALLOW_ANON else ("username/password" if FORM_AUTH else "token")
    print(f"yt2abs-web listening on http://{HOST}:{PORT} (auth: {mode})", flush=True)
    if FORM_AUTH and WEB_PASS.lower() in ("change-me", "changeme", "password", "admin"):
        print("WARNING: YT2ABS_WEB_PASSWORD is a placeholder — change it before "
              "exposing this service", flush=True)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
