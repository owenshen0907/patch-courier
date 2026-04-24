# Patch Courier Design

## System summary

Patch Courier is a local controller that receives inbound email, authenticates the sender against a local policy, translates the message into a structured task, sends the task into Codex, and returns a policy-safe reply email with the result.

## Architecture slices

### 1. Mail gateway

Responsibilities:

- connect to IMAP for inbox polling or incremental sync
- connect to SMTP for outbound replies
- normalize sender, subject, body, thread ids, and attachments
- mark or label processed messages to avoid duplicate execution

Notes:

- use a mailbox per machine to isolate blast radius
- keep mailbox credentials in Keychain rather than plain text
- prefer idempotent message ingestion keyed by message id and mailbox id

### 2. Identity and policy engine

Responsibilities:

- map sender addresses to mailbox roles
- map roles to allowed command categories
- enforce extra approval requirements for risky actions
- decide whether a message is executable, needs review, or must be rejected

Suggested starter roles:

- `admin`: can approve or initiate high-trust automation and config changes
- `operator`: can request bounded workflows inside allowed workspaces
- `observer`: can request read-only status and summaries

### 3. Job router

Responsibilities:

- convert normalized email into a structured job
- generate a stable `job_id`
- attach execution context such as workspace, role, and requested capability
- maintain job lifecycle states: received, accepted, running, waiting, succeeded, failed, rejected

### 4. Codex bridge

Responsibilities:

- launch or message the local Codex runtime
- pass a compact prompt plus trusted context
- collect the final answer, changed files, and diagnostics
- redact or summarize sensitive output before reply

Decision note:

The first implementation should treat Codex as a constrained worker and keep approval logic outside the Codex prompt so policy cannot be bypassed by prompt injection.

### 5. Reply composer

Responsibilities:

- generate a structured reply email with status, job id, timing, and result summary
- include machine name, mailbox identity, and policy decision
- optionally attach logs or artifacts when policy allows

### 6. Audit and storage

Suggested local records:

- mailbox account
- sender policy
- execution job
- execution event
- reply envelope
- secret reference

A lightweight SQLite store is enough for the MVP.

## Mail command model

A safe first command envelope could look like this:

```text
ROLE: operator
WORKSPACE: /path/to/workspace
ACTION: summarize
INPUT:
Please inspect the latest logs and tell me what failed.
```

Parsing rules:

- ignore unsupported fields
- reject requests with missing required fields
- strip quoted reply chains before execution
- keep the original raw body for audit

## Guardrails

- never trust sender address alone; combine allowlist, mailbox binding, and reply token checks
- classify tasks into read-only, write-local, execute-shell, and networked actions
- require admin approval for config changes, secret changes, or destructive actions
- keep a maximum execution budget per job
- store a hash of the prompt envelope for reproducibility and audit

## UX direction

### macOS app

Primary role:

- configure accounts
- inspect inbox and queue
- review rejected or risky tasks
- view detailed logs and changed files

## Open technical decisions

1. Use a native Swift IMAP and SMTP stack, a thin Rust bridge, or a local helper service.
2. Decide whether mailbox sync is push-like idle or timed polling.
3. Decide whether Codex runs as a subprocess, a local service, or an app-integrated broker.
4. Choose the persistence boundary between UI state and execution history.
5. Decide whether future remote review flows belong in a second app or stay inside the macOS console.
