# Troubleshooting

Start with the README local probe path. Do not configure a real mailbox until `--probe-codex`, `--probe-turn`, and mail preview rendering work locally.

## Codex CLI Not Found

Symptom:

```text
Could not find the Codex CLI executable
mailroomd failed: ...
```

Checks:

```bash
which codex
codex --version
codex app-server --help
```

Fixes:

- Install Codex CLI locally.
- Set `CODEX_CLI_PATH=/absolute/path/to/codex` in `.env.local` if Codex is not in a default location.
- Re-source the environment: `set -a; source .env.local; set +a`.

## Codex Profile Mirroring Fails

Symptoms:

- `--probe-codex` starts but thread creation fails.
- `--probe-turn` cannot authenticate or cannot find provider configuration.
- The app-scoped `CodexHome` exists but does not contain the expected profile material.

Checks:

```bash
echo "$MAILROOM_CODEX_HOME"
echo "$MAILROOM_CODEX_PROFILE_HOME"
ls -la "$MAILROOM_CODEX_PROFILE_HOME"
```

Fixes:

- Point `MAILROOM_CODEX_PROFILE_HOME` at the Codex profile that already works outside Patch Courier, usually `~/.codex`.
- Keep `MAILROOM_CODEX_HOME` writable and separate from the source profile.
- Delete the app-scoped probe home only if you want a clean bootstrap: `rm -rf "$MAILROOM_CODEX_HOME"`.

## Probe Turn Hangs Or Needs Approval

Symptoms:

- `--probe-turn` does not complete quickly.
- The returned JSON indicates approval-needed or user-input-needed.

Checks:

```bash
"$MAILROOMD" --list-turns
"$MAILROOMD" --list-approvals
"$MAILROOMD" --list-events
```

Fixes:

- Confirm the prompt is safe and simple for the configured Codex sandbox.
- Use the macOS app or approval reply flow for approval-required turns.
- For stale active turns after restart, inspect timeout events with `--list-events`.

## Mail Preview Rendering Fails

Symptoms:

- `./scripts/render_mail_previews.sh` cannot build `mailroomd`.
- The script completes but `.preview/mailroom-emails/index.html` is missing.

Checks:

```bash
xcodegen generate
xcodebuild -project PatchCourier.xcodeproj -scheme MailroomDaemon -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
```

Fixes:

- Regenerate the Xcode project after changing `project.yml`.
- Remove stale derived data for preview builds: `rm -rf build/MailPreviewDerivedData`.

## Mailbox Password Or Keychain Problems

Symptoms:

- Mailbox health shows password missing.
- Polling is paused even though a mailbox account exists.
- Saving a mailbox reports that an app password is required.

Fixes:

- Re-enter the mailbox app password from the macOS app Mailboxes setup screen.
- Do not store mailbox passwords in `.env.local`.
- Keep mailbox account ids stable; password lookup is keyed by account id.
- If using a clean support root, configure the mailbox password again.

## IMAP Or SMTP Errors

Symptoms:

- `--sync-mailboxes` fails.
- Mailbox health shows recent poll, sync, or history incidents.
- Messages fetch but replies are not sent.

Checks:

```bash
"$MAILROOMD" --sync-mailboxes
"$MAILROOMD" --list-events
```

Fixes:

- Verify IMAP host, port, and security mode.
- Verify SMTP host, port, and security mode.
- Use an app password if the mail provider requires one.
- Confirm `MAILROOM_TRANSPORT_SCRIPT_PATH` points at the installed transport helper used by the app/runtime.
- Inspect mailbox poll incidents in the app; they include phase, message, last UID, retry time, and recovery time when available.

## Daemon Control File Missing

Symptoms:

- The app says the daemon is unavailable.
- `daemon-control.json` is missing under the support root.

Checks:

```bash
echo "$MAILROOM_SUPPORT_ROOT"
ls -la "$MAILROOM_SUPPORT_ROOT"
"$MAILROOMD" --run-mail-loop
```

Fixes:

- Start or restart the daemon from the app.
- Run `--run-mail-loop` directly and watch for the printed control endpoint.
- Ensure the app and daemon use the same `MAILROOM_SUPPORT_ROOT`.

## SQLite Schema Version Error

Symptom:

```text
Mailroom SQLite schema version N is newer than supported version M.
```

Fixes:

- Run a newer Patch Courier binary that supports that schema.
- Do not downgrade and write into the same database.
- For local experiments only, switch to a separate support root in `.env.local`.

## Clean Local Probe State

For local-only experiments using `.env.local-probe.example`:

```bash
rm -rf .local/support
set -a; source .env.local; set +a
"$MAILROOMD" --probe-codex
```

Do not remove `~/Library/Application Support/PatchCourier` unless you intentionally want to reset real app state.
