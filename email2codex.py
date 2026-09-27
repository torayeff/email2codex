"""Route AgentMail emails to the system-installed Codex CLI, one Codex session per email thread."""

import json
import logging
import os
import shlex
import signal
import subprocess
import tempfile
import threading
import time
import urllib.request
from email.utils import parseaddr
from pathlib import Path

from agentmail import AgentMail, Subscribe
from agentmail.events.types.message_received_event import MessageReceivedEvent
from agentmail.messages.types.message import Message
from dotenv import load_dotenv

ROOT = Path(__file__).resolve().parent
load_dotenv(ROOT / ".env", override=True)

INBOX = os.environ["AGENTMAIL_INBOX"]
ALLOWED_EMAILS = {e.strip().lower() for e in os.environ["ALLOWED_EMAILS"].split(",") if e.strip()}
CODEX = os.environ.get("CODEX_BIN", "codex")
CODEX_ARGS = shlex.split(os.environ.get("CODEX_ARGS", "--skip-git-repo-check"))
WORKDIR = Path(os.environ.get("CODEX_WORKDIR") or Path.cwd()).expanduser().resolve()
SESSIONS_FILE = ROOT / ".sessions.json"
ATTACHMENTS_DIR = ROOT / "attachments"

DRAIN_PROMPT = "Continue: handle the follow-up message(s) queued above."

log = logging.getLogger("email2codex")
client = AgentMail(api_key=os.environ["AGENTMAIL_API_KEY"])
lock = threading.Lock()
busy: dict[str, list[tuple[str, list[str]]]] = {}  # agentmail thread id -> (email id, codex args) queued meanwhile
procs: dict[str, subprocess.Popen] = {}  # agentmail thread id -> running codex process


def load_sessions() -> dict[str, str]:
    text = SESSIONS_FILE.read_text() if SESSIONS_FILE.exists() else ""
    return json.loads(text) if text.strip() else {}


def save_session(thread_id: str, codex_id: str) -> None:
    with lock:
        SESSIONS_FILE.write_text(json.dumps(load_sessions() | {thread_id: codex_id}, indent=2) + "\n")


def reply(message_id: str, text: str) -> None:
    client.inboxes.messages.reply(INBOX, message_id, text=text)
    log.info("replied to %s", message_id)


def parse(msg: Message) -> tuple[str, list[str]]:
    """Return the prompt (with attachment paths appended) and the codex args from a leading `codex ...` line."""
    first, _, rest = (msg.extracted_text or msg.text or "").strip().partition("\n")
    args = []
    if first.split(maxsplit=1)[:1] == ["codex"]:
        first, args = "", shlex.split(first)[1:]
    prompt = f"{first}\n{rest}".strip()

    target = ATTACHMENTS_DIR / msg.thread_id / msg.message_id
    for att in msg.attachments or []:
        url = client.inboxes.messages.get_attachment(INBOX, msg.message_id, att.attachment_id).download_url
        path = target / Path(att.filename or att.attachment_id).name
        target.mkdir(parents=True, exist_ok=True)
        with urllib.request.urlopen(url) as resp:
            path.write_bytes(resp.read())
        prompt += f"\n\nAttached file: {path}"
    return prompt, args


def run_codex(thread_id: str, prompt: str, args: list[str]) -> str | None:
    """Run codex and return its final message, or None if the run was stopped."""
    codex_id = load_sessions().get(thread_id)
    out = Path(tempfile.mkstemp(suffix=".txt")[1])
    resume = ["resume", codex_id] if codex_id else []
    cmd = [CODEX, "exec", "-C", str(WORKDIR), *CODEX_ARGS, *args, "--json", "-o", str(out), *resume, "-"]
    log.info("run: %s", shlex.join(cmd))

    proc = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    procs[thread_id] = proc
    proc.stdin.write(prompt)
    proc.stdin.close()
    for line in proc.stdout:
        event = json.loads(line) if line.startswith("{") else {}
        if event.get("type") == "thread.started" and not codex_id:
            codex_id = event["thread_id"]
            save_session(thread_id, codex_id)
            log.info("thread %s -> codex %s", thread_id, codex_id)
    stderr = proc.stderr.read()
    result = out.read_text().strip()
    out.unlink()
    if procs.pop(thread_id, None) is None:
        return None
    if proc.wait() != 0:
        return f"Codex exited with code {proc.returncode}.\n\n{result}\n\n{stderr[-2000:]}".strip()
    return result or "(Codex finished without a final message.)"


def claim_or_queue(thread_id: str, message_id: str, prompt: str, args: list[str]) -> str | None:
    """Mark the thread busy and return None, or queue the prompt into its running codex session and return a status."""
    while True:
        with lock:
            if thread_id not in busy:
                busy[thread_id] = []
                return None
            if codex_id := load_sessions().get(thread_id):
                cmd = [CODEX, "queue", "--thread", codex_id, "--message", prompt]
                res = subprocess.run(cmd, cwd=WORKDIR, capture_output=True, text=True, check=False)
                if res.returncode != 0:
                    return f"Could not queue your message into Codex:\n{res.stderr}"
                busy[thread_id].append((message_id, args))
                return "Codex is busy; your message was queued into the running session."
        time.sleep(1)  # new session hasn't reported its codex id yet


def stop(thread_id: str) -> str:
    """Interrupt the thread's running codex (the session stays resumable) and drop its queued follow-ups."""
    with lock:
        proc = procs.pop(thread_id, None)
        if thread_id in busy:
            busy[thread_id].clear()
    if proc is None:
        return "Nothing is running in this thread."
    proc.send_signal(signal.SIGINT)
    return "Stopped. Reply in this thread to continue the session."


def handle(msg: Message) -> None:
    if parseaddr(msg.from_)[1].lower() not in ALLOWED_EMAILS:
        log.info("ignoring %s from %s", msg.message_id, msg.from_)
        return
    thread_id, message_id = msg.thread_id, msg.message_id
    prompt, args = parse(msg)
    if prompt.lower() == "/stop":
        reply(message_id, stop(thread_id))
        return
    if status := claim_or_queue(thread_id, message_id, prompt, args):
        reply(message_id, status)
        return

    # Run, then drain whatever was queued meanwhile (`codex exec` reads the queue at the start of a turn).
    while True:
        try:
            if (result := run_codex(thread_id, prompt, args)) is not None:
                reply(message_id, result)
        except Exception as exc:
            log.exception("codex run failed")
            reply(message_id, f"email2codex error: {exc}")
        with lock:
            queued = busy.pop(thread_id)
            if not queued:
                return
            busy[thread_id] = []
        (message_id, args), prompt = queued[-1], DRAIN_PROMPT


def main() -> None:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    while True:
        try:
            with client.websockets.connect() as socket:
                socket.send_subscribe(Subscribe(inbox_ids=[INBOX], event_types=["message.received"]))
                log.info("listening on %s, codex workdir %s", INBOX, WORKDIR)
                for event in socket:
                    if isinstance(event, MessageReceivedEvent):
                        threading.Thread(target=handle, args=(event.message,), daemon=True).start()
        except KeyboardInterrupt:
            return
        except Exception:
            log.exception("websocket disconnected; reconnecting in 5s")
            time.sleep(5)


if __name__ == "__main__":
    main()
