# Patch Courier Target Architecture

## Product definition

Patch Courier is a daemon-backed operator system where:

- email is an asynchronous ingress, approval, and notification channel
- `codex app-server` is the primary execution protocol
- a native macOS app is the local review and audit console
- SQLite and Keychain define the durable trust boundary on each machine

## Core principles

1. Daemon first: mailbox polling, Codex threads, and approval state must outlive the UI.
2. First-party Codex protocol: use `codex app-server` instead of one-shot `codex exec` for long-lived work.
3. Thread fidelity: one mail thread maps to one Codex thread whenever possible.
4. Approval round-trips: command, file-change, and user-input requests are durable records that can be answered by email or by the local console.
5. App-owned Codex home: `mailroomd` launches Codex with a writable, app-scoped `CODEX_HOME`, while mirroring the minimum provider/auth profile artifacts it needs from the operator's Codex profile.
6. Policy outside the prompt: sender trust, workspace scope, and dangerous-action gates live in Mailroom, not in natural-language guardrails alone.

## Process model

### Mailroom.app

Responsibilities:

- account setup and secret entry
- sender identity and policy management
- live queue, thread, and approval review
- event timeline, artifacts, and recovery tools

### mailroomd

Responsibilities:

- IMAP polling / webhook ingestion
- mailbox work scheduling with one background worker per Mailroom thread
- SMTP reply dispatch
- sender verification and policy enforcement
- Codex App Server lifecycle management
- thread/turn orchestration
- persistence and audit logging

### codex app-server

Responsibilities:

- maintain Codex thread state
- execute turns against the configured model/runtime
- stream item notifications and turn lifecycle events
- request command, file, permissions, or user-input approvals

## Why app-scoped CODEX_HOME matters

During local protocol probing, `thread/start` failed when the process could not write to the default `~/.codex` session database and shell snapshot directories. Launching Codex with a writable custom `CODEX_HOME` under `/tmp` fixed the problem immediately.

That changes the target design:

- `mailroomd` should always provision and own its own Codex home root
- `mailroomd` should seed that runtime home from an operator-selected Codex profile so native turns inherit the right provider, auth mode, and `.env` values
- Codex runtime state should be isolated per Mailroom installation or per operator profile
- session recovery should not depend on whatever the user is doing in the interactive Codex desktop app

Recommended root on macOS:

- `~/Library/Application Support/PatchCourier/CodexHome`

## Durable data model

### `mail_threads`

- `mail_thread_token`
- `mailbox_id`
- `sender_address`
- `subject`
- `codex_thread_id`
- `workspace_root`
- `capability`
- `status`
- `last_inbound_message_id`
- `last_outbound_message_id`
- `created_at`
- `updated_at`

### `codex_turns`

- `mail_thread_token`
- `codex_thread_id`
- `codex_turn_id`
- `origin` (`newMail`, `reply`, `localConsole`)
- `status`
- `last_notified_state`
- `last_notification_message_id`
- `started_at`
- `completed_at`

### `approval_requests`

- `request_id` (JSON-RPC request id)
- `kind` (`commandExecution`, `fileChange`, `userInput`, `permissions`)
- `codex_thread_id`
- `codex_turn_id`
- `item_id`
- `mail_thread_token`
- `summary`
- `detail`
- `available_decisions`
- `raw_payload`
- `status`
- `created_at`
- `resolved_at`

### `event_log`

- `event_id`
- `source` (`app_server_notification`, `app_server_request`, `mailroom_internal`, `transport_log`)
- `method`
- `codex_thread_id`
- `codex_turn_id`
- `payload_json`
- `created_at`

### `mailbox_sync_state`

- `account_id`
- `last_seen_uid`
- `last_processed_at`

### `mailbox_accounts`

- `id`
- `label`
- `email_address`
- `role`
- `workspace_root`
- `imap_host`
- `imap_port`
- `imap_security`
- `smtp_host`
- `smtp_port`
- `smtp_security`
- `polling_interval_seconds`
- `created_at`
- `updated_at`

### `sender_policies`

- `id`
- `display_name`
- `sender_address`
- `assigned_role`
- `allowed_workspace_roots_json`
- `requires_reply_token`
- `is_enabled`
- `created_at`
- `updated_at`

## Execution flow

### New mail -> new task

1. `mailroomd` receives a new inbound email.
2. Sender identity and workspace policy are resolved before Codex sees the request.
3. Mailroom enqueues the mail onto a worker lane keyed by the Mailroom thread token when available, or by a per-message fallback key for brand-new requests.
4. The worker creates a `mail_thread_token` and starts a Codex thread with working directory, approval policy, sandbox policy, and model selection.
5. Mailroom submits `turn/start` with structured input text.
6. Notifications are streamed into the event log.
7. On `turn/completed`, Mailroom sends a result email.

### Reply mail -> continue task

1. Mailroom matches the thread token or `In-Reply-To` chain.
2. The reply is enqueued onto the same worker lane as the existing Mailroom thread so only one turn runs at a time for that conversation.
3. The existing `codex_thread_id` is loaded.
4. Mailroom submits another `turn/start` on the same thread.
5. Result or further approval is returned by email.

### Approval request -> email round-trip

1. Codex sends a server request such as:
   - `item/commandExecution/requestApproval`
   - `item/fileChange/requestApproval`
   - `item/tool/requestUserInput`
2. Mailroom persists the approval request and sends a structured email.
3. The operator replies with a concise approval envelope.
4. Mailroom parses the reply and sends the matching JSON-RPC response back to Codex.
5. The original turn continues.

### Daemon restart -> turn recovery

1. On daemon boot, Mailroom loads durable `codex_turns` records.
2. Mail-driven turns are reconciled against `thread/read` plus any persisted pending approval records.
3. If an approval or final outcome was not notified yet, Mailroom emits the missing email.
4. Still-active mail turns are re-armed with background waiters so completion can be delivered after restart.

## Email protocol envelope

### Approval email body

```text
THREAD: [patch-courier:MRM-7F3A9C1E]
REQUEST: req_01JXYZ...
TYPE: commandExecution
SUMMARY: Codex wants to run a command outside the current default policy.

Reply with:
DECISION: accept | acceptForSession | decline | cancel
```

### Approval reply body

```text
THREAD: [patch-courier:MRM-7F3A9C1E]
REQUEST: req_01JXYZ...
DECISION: accept

NOTE:
Continue execution.
```

### request_user_input reply body

```text
THREAD: [patch-courier:MRM-7F3A9C1E]
REQUEST: req_01JXYZ...

ANSWER_release_scope:
macOS first

ANSWER_shipping_priority:
stability
```

## Implementation phases

### Phase 1

- `mailroomd` boots and initializes `codex app-server`
- app-scoped `CODEX_HOME` is provisioned automatically
- minimal Codex profile files are mirrored into that runtime home before launch
- thread creation and turn submission work from a local bootstrap path
- raw events and approval requests are stored durably

### Phase 2

- IMAP fetch + SMTP send are attached to the daemon
- mailbox sync cursors live in SQLite instead of the old JSON runtime state
- email approval envelopes are end-to-end
- reply parsing routes back to JSON-RPC responses
- durable turn records support best-effort restart recovery for pending approvals and in-flight mail turns

### Phase 3

- the daemon exposes a localhost control plane and advertises it through a support-root control file
- the macOS app switches from a static dashboard to a real daemon-backed console
- live thread, turn, approval, and sync-cursor views are wired to that control plane
- local UI can answer the same approval objects that email can answer against the same running app-server session

### Phase 4

- approval, replay, and artifact views are richer and more operator-friendly
- daemon-owned config replaces the old UI-local JSON authority for mailbox accounts and sender policy data
- legacy mailbox account / sender policy JSON files are treated as one-time import seeds when the SQLite config tables are empty
- mailbox passwords remain in Keychain, keyed by durable account id, instead of moving into SQLite
- mailbox-health snapshots surface per-account polling cadence, next wake, password readiness, sync cursor progress, and recent transport failures separately from worker-lane execution
- worker-lane snapshots surface running mail workers, current message context, queue depth, and recent failures directly in the operator console
- blocking IMAP / SMTP helper invocations are detached from the daemon actor so control-plane reads and approval actions remain responsive during transport work
