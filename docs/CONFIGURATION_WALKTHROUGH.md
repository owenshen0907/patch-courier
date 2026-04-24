# Configuration Walkthrough

This walkthrough covers the three setup areas that make the mailbox loop work: Mailboxes, Sender policies, and Projects. Run the README local probe path first; this page assumes `mailroomd --probe-codex` and `mailroomd --probe-turn` already work.

## Before You Start

Prepare these values:

- Relay mailbox address, for example `codex-relay@example.com`.
- Mail provider app password. Do not use your normal account password if the provider supports app-specific passwords.
- IMAP host, port, and security mode.
- SMTP host, port, and security mode.
- Local workspace root that Patch Courier is allowed to use, for example `/Users/alice/MyCodeSpace`.
- At least one trusted sender address.
- At least one managed local project path.

Start the app from a mailbox-capable environment:

```bash
cp .env.mailbox.example .env.local
set -a; source .env.local; set +a
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$PWD/build/DerivedData}"
xcodebuild -project PatchCourier.xcodeproj \
  -scheme PatchCourierMac \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  CODE_SIGNING_ALLOWED=NO \
  build
open "$DERIVED_DATA_PATH/Build/Products/Debug/Patch Courier.app"
```

## 1. Mailboxes

Open **Setup -> Mailboxes** and create or edit the relay mailbox.

| Field | Example | Notes |
| --- | --- | --- |
| Display label | `Tokyo Operator` | Human-readable name shown in the app. If blank, Patch Courier derives it from the mailbox address. |
| Mailbox address | `codex-relay@example.com` | Address Patch Courier polls and sends replies from. |
| Role | `Operator` | Default role for work originating from this mailbox. Sender policy still controls individual senders. |
| Workspace root | `/Users/alice/MyCodeSpace` | Broad local root used for mailbox-originated work. Keep it narrow enough to be safe. |
| IMAP host | `imap.example.com` | Incoming mail server. |
| IMAP port | `993` | Typical SSL/TLS IMAP port. |
| IMAP security | `SSL/TLS` | Use provider-recommended security. |
| SMTP host | `smtp.example.com` | Outgoing mail server. |
| SMTP port | `465` | Typical SSL/TLS SMTP port; `587` is common for STARTTLS. |
| SMTP security | `SSL/TLS` | Match the provider's SMTP setting. |
| Polling interval | `60 seconds` | Use a conservative value while testing. |
| App password | provider app password | Stored through Keychain-backed secret storage; do not commit it or put it in `.env.local`. |

Save behavior:

- New mailbox accounts require an app password before saving.
- Edited accounts can leave the password blank to keep the existing saved password.
- The app probes connectivity before accepting a mailbox configuration.
- Mailbox health should move from missing/paused to waiting/polling once the daemon can see a saved password.

Provider hints:

- Gmail usually requires IMAP to be enabled and an app password for accounts with 2FA.
- iCloud Mail usually requires an app-specific password.
- Microsoft 365 may require tenant policy support for IMAP/SMTP AUTH.

## 2. Sender Policies

Open **Setup -> Sender policies** and add the humans allowed to drive Codex work through email.

| Field | Example | Notes |
| --- | --- | --- |
| Display name | `Alice Admin` | Human-readable label. If blank, Patch Courier derives it from the address. |
| Sender address | `alice@example.com` | Normalized to lowercase. This is the address Patch Courier matches on inbound mail. |
| Role | `Admin`, `Operator`, or `Observer` | Controls default policy posture. Prefer `Operator` unless this sender must approve risky work. |
| Workspace roots | `/Users/alice/MyCodeSpace` | Comma- or newline-separated allowlist. Inbound requests outside these roots are rejected or paused. |
| Require first-mail confirmation | enabled | Recommended. First contact requires a reply token before the sender is trusted in that thread. |
| Accept commands from this sender | enabled | Disable to keep the policy record but stop accepting new commands. |

Role guidance:

- `Admin`: can approve risky actions and manage policy-level work.
- `Operator`: can run bounded workflows inside approved workspaces.
- `Observer`: should be used for read-only summaries and audit-style requests.

Safe defaults:

- Start with one `Operator` sender and one workspace root.
- Keep `Require first-mail confirmation` enabled for external mailboxes.
- Add more roots only after confirming the first test thread behaves as expected.

## 3. Projects

Open **Setup -> Projects** and add each local repository that users can select from email.

| Field | Example | Notes |
| --- | --- | --- |
| Display name | `Patch Courier` | Human-readable project name used in project selection emails. |
| Slug | `patch-courier` | Short stable token users reply with as `PROJECT: patch-courier`. |
| Root path | `/Users/alice/MyCodeSpace/patch-courier` | Must exist locally and be a directory. |
| Summary | `Native macOS relay app and daemon.` | Helps the sender choose the right project from email. |
| Default capability | `Execute shell` | Current supported options: read-only, write workspace, execute shell, networked access. |
| Enabled | enabled | Disabled projects stay stored but are not offered as active choices. |

Project selection email behavior:

- If a trusted sender sends a command without an explicit project, Patch Courier can send a project selection email.
- The reply format is:

```text
PROJECT: patch-courier
COMMAND: Inspect failing tests and propose the smallest safe fix.
```

Keep slugs stable. Changing a slug changes what users need to type in replies.

## 4. Smoke Test The Configuration

Start the daemon:

```bash
MAILROOMD="$DERIVED_DATA_PATH/Build/Products/Debug/mailroomd"
"$MAILROOMD" --run-mail-loop
```

From a trusted sender, send a short email to the relay mailbox:

```text
Subject: Patch Courier smoke test

Please inspect the Patch Courier project and reply with a short status summary.
```

Expected outcomes:

- If the sender is new and confirmation is required, Patch Courier replies with a sender confirmation token.
- If multiple managed projects are possible, Patch Courier replies with a project selection email.
- If the request is accepted, Patch Courier sends a receipt and later a completion/failure email.
- If Codex needs approval, Patch Courier sends a structured approval email.

For one polling pass instead of the long-running loop:

```bash
"$MAILROOMD" --sync-mailboxes
```

## 5. Inspect State

Use these commands while debugging:

```bash
"$MAILROOMD" --list-threads
"$MAILROOMD" --list-turns
"$MAILROOMD" --list-approvals
"$MAILROOMD" --list-events
```

Use the macOS app dashboard for mailbox health, worker lanes, recent mailbox messages, and poll incidents.

## Common Misconfigurations

- Mailbox saves but polling is paused: password was not saved or is tied to a different account id.
- Sender email is ignored: sender policy address does not match the inbound From address after normalization.
- Project is never offered: project is disabled, root path is missing, or sender policy workspace roots do not include the project path.
- Reply cannot be matched: the sender removed the `THREAD:` token or changed `REQUEST:` in an approval reply.
- SMTP sends fail: SMTP security/port combination is wrong, or the provider blocks password-based SMTP.

See `docs/TROUBLESHOOTING.md` for recovery steps.
