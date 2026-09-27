# email2codex

Use your system-installed [Codex CLI](https://github.com/openai/codex) over email, via an [AgentMail](https://agentmail.to) inbox.

Each AgentMail thread maps to one Codex session (stored in `.sessions.json`):

| Situation | Codex command |
| --- | --- |
| New email thread | `codex exec` |
| Reply in known thread, Codex idle | `codex exec resume <session>` |
| Reply while Codex is still running | `codex queue --thread <session>`; queued messages are picked up by one `resume` right after the current turn ends |

When a run finishes, Codex's final message is sent back as a reply in the same thread.

- Default options for every run come from `CODEX_ARGS`. `env.example` runs Codex fully autonomously (`--dangerously-bypass-approvals-and-sandbox`: no approvals, no sandbox).
- Optional first line: native `codex exec` options, e.g. `codex -m gpt-6-luna -c model_reasoning_effort="max" -s workspace-write`. The line is removed from the prompt and its options are added after `CODEX_ARGS`.
- Send `/stop` to interrupt the running task in a thread. The session is kept, so replying in the thread continues it.
- Attachments are downloaded to `attachments/<thread>/<message>/` and their paths are appended to the prompt.
- Different email threads run in parallel.

## Security

An email is only acted on if all of these hold:

1. AgentMail accepted it: it drops mail whose SPF, DKIM or DMARC explicitly fails, and with allowlists set up (`uv run email2codex setup-allowlists`) it only accepts new emails and replies from `ALLOWED_EMAILS`.
2. The sender is in `ALLOWED_EMAILS` and AgentMail didn't label it `unauthenticated`, `spam` or `blocked`.
3. It is addressed to this inbox in `To` or `Cc` (not Bcc), and its `Message-ID` was never processed before (`.seen.json`, kept permanently).

Why 3: nobody can forge your From, but anyone holding a copy of a real email of yours can re-send it unchanged, and its DKIM signature still verifies (a "DKIM replay"). The signature also covers `To`/`Cc`, so an email you sent to someone else can't be redirected to the bot, and one you sent to the bot can't run twice.

This relies on the sender's domain publishing SPF/DKIM and a DMARC policy other than `none`. With the bypass flag Codex can do anything your user can, and it can still be misled by content it reads (prompt injection), so run it on a dedicated machine or user without credentials it doesn't need.

## Run

```bash
cp env.example .env                   # fill in values
codex login                           # once (`codex login --device-auth` over SSH)
uv run email2codex setup-allowlists   # once, and after changing ALLOWED_EMAILS
uv run email2codex                    # or install it as a service:
./install-service.sh                  # start at boot/login, restart on failure
```

`install-service.sh` sets up a launchd agent on macOS (logs in `logs/email2codex.log`) or a systemd user service on Linux (`journalctl --user -u email2codex -f`, and lingering is enabled so it starts at boot without a login). It captures your current `PATH` so the service finds `uv` and `codex`; rerun it after moving either. `./install-service.sh uninstall` removes it.
