# email2codex

Use your system-installed [Codex CLI](https://github.com/openai/codex) over email, via an [AgentMail](https://agentmail.to) inbox.

Each AgentMail thread maps to one Codex session (stored in `.sessions.json`):

| Situation | Codex command |
| --- | --- |
| New email thread | `codex exec` |
| Reply in known thread, Codex idle | `codex exec resume <session>` |
| Reply while Codex is still running | `codex queue --thread <session>`; queued messages are picked up by one `resume` right after the current turn ends |

When a run finishes, Codex's final message is sent back as a reply in the same thread.

- Only senders in `ALLOWED_EMAILS` (comma-separated) are handled.
- Optional first line: native `codex exec` options, e.g. `codex -m gpt-6-luna -c model_reasoning_effort="max" -s workspace-write`. The line is removed from the prompt and its options are added after `CODEX_ARGS`.
- Send `/stop` to interrupt the running task in a thread. The session is kept, so replying in the thread continues it.
- Attachments are downloaded to `attachments/<thread>/<message>/` and their paths are appended to the prompt.
- Different email threads run in parallel.

## Run

```bash
cp env.example .env   # fill in values
uv run email2codex
```
