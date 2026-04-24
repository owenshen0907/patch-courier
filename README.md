![Patch Courier banner](docs/assets/patch-courier-hero.svg)

# Patch Courier

[![Build](https://github.com/owenshen0907/patch-courier/actions/workflows/build.yml/badge.svg)](https://github.com/owenshen0907/patch-courier/actions/workflows/build.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-E9A23B.svg)](LICENSE)

Patch Courier lets you keep coding from wherever you are by turning trusted email threads into local Codex work.
Email is the human-facing ingress, approval, and notification channel; execution stays on your Mac through `codex app-server`, so repository access, credentials, and policy decisions remain local.

## Project status

Patch Courier is an early, daemon-first macOS prototype. It is useful for experimentation and local operator workflows, but the public API, storage schema, and onboarding flow should still be treated as pre-1.0.

## What exists now

- `MailroomDaemon` / `mailroomd` boots native `codex app-server` over stdio JSON-RPC.
- Patch Courier provisions an app-scoped `CODEX_HOME` and seeds the minimal Codex profile artifacts it needs from the operator profile so native turns still use the same provider/auth setup.
- thread records, approval requests, and raw event logs are persisted in SQLite at `~/Library/Application Support/PatchCourier/mailroom.sqlite3` by default.
- turn records are now persisted in the same SQLite store, including origin, latest lifecycle state, and the last mail outcome already notified.
- mailbox sync cursors, mailbox accounts, and sender policies now live in the same SQLite store, while mailbox passwords remain in Keychain.
- SQLite schema compatibility is tracked with `PRAGMA user_version`; see `docs/STORAGE_MIGRATIONS.md` for the migration policy.
- `mailroomd` can now run one-shot mailbox syncs or a long-lived mail loop that polls mailboxes quickly, fans work out to per-thread background workers, and sends completion / approval emails back out.
- the long-lived daemon now performs startup recovery for durable mail turns, suppresses already-sent approval reminders, and marks unrecoverable active turns as timed-out system errors instead of waiting forever.
- the long-lived daemon now exposes a localhost JSON control plane, publishes a control file under the support root, and can answer live `state/read`, `approval/resolve`, and daemon-owned config mutation requests.
- the macOS app now polls that daemon control plane to show live threads / turns / approvals, and saves mailbox / sender-policy changes against the same running daemon session.
- the daemon control snapshot now includes per-lane worker summaries, so the macOS console can show which mailbox worker is running, what message it is handling, and whether backlog is building up behind it.
- the daemon control snapshot now also includes per-mailbox poll health, so operators can see password readiness, next poll timing, sync cursor progress, and recent transport failures separately from downstream worker execution state.

## Current architecture split

- `Runtime/` typed Codex App Server transport and Mailroom domain models
- `Daemon/` daemon bootstrap, SQLite store, approval email codec, and CLI probes
- `Shared/` existing macOS console and mailbox workflow prototype
- `docs/TARGET_ARCHITECTURE.md` target blueprint for the daemon-first design

## Why this direction

The target product is a native macOS mail operator that can:

- receive approved inbound email requests
- map one mail thread to one Codex thread when possible
- survive UI restarts because mailbox state and approvals live in a daemon
- send approval requests or completion summaries back over email

The critical runtime detail discovered during probing is that `codex app-server` needs a writable `CODEX_HOME` to create threads reliably, but real turns also need the operator's Codex provider/auth profile. Patch Courier therefore owns its runtime directory while mirroring a small set of profile files such as `config.toml`, `.env`, and auth metadata from the selected source Codex home.

## Prerequisites

- macOS with Xcode command line tools installed
- `xcodegen` available on `PATH`
- Codex CLI installed locally, with `codex app-server` available

## Quick start

```bash
cd /path/to/patch-courier
xcodegen generate
xcodebuild -project PatchCourier.xcodeproj -scheme MailroomDaemon -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
```

## Daemon probe commands

Once built, `mailroomd` exposes both native app-server probes and mailbox-facing sync commands:

```bash
./mailroomd --probe-codex
./mailroomd --probe-turn --prompt "Reply with exactly hello and nothing else."
./mailroomd --list-threads
./mailroomd --list-turns
./mailroomd --list-approvals
./mailroomd --list-events
./mailroomd --render-mail-fixtures --output-dir /tmp/mailroom-email-fixtures
./mailroomd --sync-mailboxes
./mailroomd --run-mail-loop
./mailroomd --start-thread --sender you@example.com --subject "Repo check" --workspace /path/to/workspace --prompt "Inspect the workspace and tell me what changed." --wait
./mailroomd --continue-thread --token MRM-1234ABCD --prompt "Continue with the next step." --wait
```

`--probe-turn` is the native app-server smoke test: it starts a real thread, executes a real turn, and waits for completion. `--wait` does the same for stored Mailroom threads, resolving to completion, approval-needed, user-input-needed, or system-error states. `--list-turns` exposes the durable turn ledger used for restart recovery. `--sync-mailboxes` performs one polling pass over configured accounts, while `--run-mail-loop` keeps the daemon alive, advances mailbox cursors after enqueue, reconciles durable mail turns on startup, serves the local JSON control plane, persists mailbox config in SQLite, and lets unrelated mail threads execute concurrently inside the same live app-server session. IMAP / SMTP helper invocations are detached from the daemon actor so live `state/read` snapshots and approval actions stay responsive while transport work is in flight.

When `--run-mail-loop` starts, it now prints the loopback endpoint and writes `<support-root>/daemon-control.json`. The native macOS app reads that control file and talks to the daemon over newline-delimited JSON so approvals stay attached to the live app-server thread instead of spawning fresh CLI processes.

## Email preview fixtures

Render representative outbound emails locally to inspect subject lines, inbox preview text, HTML layout, and plain-text fallbacks:

```bash
cd /path/to/patch-courier
./scripts/render_mail_previews.sh
```

The script builds `mailroomd`, renders a set of sample daemon emails, and writes an `index.html` plus per-message `.html` / `.txt` files under `.preview/mailroom-emails` by default. Open the generated `index.html` in a browser to jump into the HTML or plain-text version of each fixture. The current fixture set covers the immediate receipt email, first-contact decision prompt, managed-project selection, approval request, successful completion, and failure notification.

## Environment overrides

- `CODEX_CLI_PATH`: explicit path to the Codex CLI bundle executable
- `MAILROOM_SUPPORT_ROOT`: base directory for Mailroom support files
- `MAILROOM_DATABASE_PATH`: SQLite file for thread / approval / event persistence
- `MAILROOM_CODEX_HOME`: app-owned Codex runtime directory
- `MAILROOM_CODEX_PROFILE_HOME`: source Codex profile to mirror into the app-owned runtime home, defaults to `~/.codex`
- `MAILROOM_ACCOUNTS_PATH`: legacy mailbox account JSON import path, defaults to `<support-root>/mailbox-accounts.json`
- `MAILROOM_POLICIES_PATH`: legacy sender policy JSON import path, defaults to `<support-root>/sender-policies.json`
- `MAILROOM_TRANSPORT_SCRIPT_PATH`: installed IMAP/SMTP helper script path, defaults to `<support-root>/runtime-tools/mail_transport.py`
- `MAILROOM_WORKDIR`: process working directory used when spawning Codex
- `MAILROOM_WORKSPACE_ROOT`: default workspace root for probes and bootstrap commands
- `MAILROOM_ACTIVE_TURN_RECOVERY_POLL_SECONDS`: polling interval for restarted active turns, defaults to `30`
- `MAILROOM_ACTIVE_TURN_RECOVERY_TIMEOUT_SECONDS`: maximum active-turn age before recovery records a system-error timeout, defaults to `21600`

## Verification

```bash
cd /path/to/patch-courier
xcodegen generate
xcodebuild -project PatchCourier.xcodeproj -scheme MailroomDaemon -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test
xcodebuild -project PatchCourier.xcodeproj -scheme MailroomDaemon -destination 'platform=macOS' -derivedDataPath /tmp/PatchCourierDerived CODE_SIGNING_ALLOWED=NO build
xcodebuild -project PatchCourier.xcodeproj -scheme PatchCourierMac -destination 'platform=macOS' -derivedDataPath /tmp/PatchCourierDerived CODE_SIGNING_ALLOWED=NO build
```

## Roadmap

The next iteration plan lives in `docs/ROADMAP.md`. The short version is:

1. Make daemon recovery and duplicate-notification behavior boringly reliable.
2. Make first-run setup understandable enough for external contributors to reproduce.
3. Expand operator controls for approvals, replay, artifacts, and mailbox health.
4. Package signed releases once the core loop is stable.

## Docs

- `docs/ROADMAP.md`
- `docs/BRAND.md`
- `docs/TARGET_ARCHITECTURE.md`
- `docs/PLAN.md`
- `docs/DESIGN.md`
- `docs/releases/v0.1.0.md`
