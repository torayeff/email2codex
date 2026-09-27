# email2codex

Control the [Codex CLI](https://github.com/openai/codex) on a machine by email, via an [AgentMail](https://agentmail.to) inbox. Codex runs fully autonomously and replies with its final message.

## Setup

```bash
cp env.example .env                   # fill in your values
codex login                           # once; use `codex login --device-auth` over SSH
uv run email2codex setup-allowlists   # once, and again after changing ALLOWED_EMAILS
```

## Run as a service

The service starts at boot (Linux) or login (macOS) and restarts if it crashes.

```bash
./service.sh install     # install and start
./service.sh stop        # stop
./service.sh start       # start again
./service.sh restart     # restart, e.g. after editing .env or pulling updates
./service.sh status      # is it running?
./service.sh logs        # follow the log
./service.sh uninstall   # stop and remove
```

A stopped service starts again at the next boot or login; use `uninstall` to remove it for good. Rerun `install` if you move this folder or reinstall `uv` or `codex`.

To run it in the foreground instead: `uv run email2codex`.

## Usage

| You send | What happens |
| --- | --- |
| A new email | Starts a new Codex session (`codex exec`) |
| A reply in the thread | Continues that session (`codex exec resume`) |
| A reply while Codex is working | Queued and handled right after the current run |
| `/stop` | Interrupts the run; replying later continues the session |

- Put the inbox in **To or Cc**, never Bcc, or the email is ignored.
- Optional first line with `codex exec` options, e.g. `codex -m gpt-6-sol -s workspace-write`. They're added after `CODEX_ARGS`.
- Attachments are saved to `attachments/` and their paths are given to Codex.
- Separate threads run in parallel.

## Configuration (`.env`)

| Variable | Meaning |
| --- | --- |
| `AGENTMAIL_API_KEY`, `AGENTMAIL_INBOX` | Your AgentMail key and inbox |
| `ALLOWED_EMAILS` | Comma-separated senders allowed to control Codex |
| `CODEX_ARGS` | Options for every run; the default `--dangerously-bypass-approvals-and-sandbox` means no approvals and no sandbox |
| `CODEX_WORKDIR` | Folder Codex works in (default: this folder) |
| `CODEX_BIN` | Path to `codex` (default: `codex` on `PATH`) |

## Security

An email is acted on only if all of these hold:

1. AgentMail accepted it. It drops mail that fails SPF, DKIM or DMARC, and the allowlists only let in `ALLOWED_EMAILS`.
2. The sender is in `ALLOWED_EMAILS` and AgentMail didn't label it `unauthenticated`, `spam` or `blocked`.
3. The inbox is in `To` or `Cc`, and the email's `Message-ID` was never processed before (`.seen.json`).

Nobody can forge your address, but anyone with a copy of a real email of yours can re-send it unchanged (a "DKIM replay"). Rule 3 blocks that: an email you sent to someone else isn't addressed to the inbox, and one you sent to the inbox can't run twice.

Codex has full access to the machine and can be misled by content it reads (prompt injection), so run it on a dedicated machine or user without credentials it doesn't need.
