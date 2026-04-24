# Patch Courier Plan

## Product intent

Build a local-first email agent that turns approved inbound emails into Codex tasks and returns structured results by email.
The product should let one person operate multiple machines through mailbox identities without losing control over permissions, audit history, or dangerous execution paths.

## MVP scope

### In scope

- local mailbox account setup for IMAP and SMTP
- sender identity mapping to roles such as admin, operator, and observer
- a rule engine that decides whether a request can be executed automatically
- a Codex execution adapter for safe local task runs
- structured reply emails with status, summary, job id, and timestamps
- local audit log and simple task history UI

### Out of scope for the first cut

- attachment-heavy workflows
- multi-machine fleet coordination
- HTML email rendering beyond basic formatting
- autonomous self-escalating tool use without explicit guardrails
- arbitrary shell execution for low-trust mailboxes

## Workstreams

1. Mail transport foundation
   - add mailbox configuration storage and secret handling
   - poll IMAP or support manual refresh
   - parse plain-text commands and reply threading headers
2. Trust and policy layer
   - define sender allowlists and mailbox roles
   - map roles to allowed task categories
   - require approval or challenge tokens for risky actions
3. Codex runtime bridge
   - translate approved mail into structured jobs
   - capture stdout, stderr, changed files, and final response
   - persist status transitions and retry state
4. Operator experience
   - build macOS inbox, queue, and audit screens
   - expose health, last sync, and failed jobs

## Milestones

### Milestone 1: Clickable product skeleton

- repo scaffolded
- macOS target running
- dashboard explains roles, guardrails, and first implementation slices

### Milestone 2: Static workflow prototype

- local config model defined
- sample mail request parsed into internal job data
- simulated Codex execution shown in UI timeline

### Milestone 3: Real mailbox loop

- IMAP fetch and SMTP reply working against a test account
- sender allowlist and role checks enforced
- job history persisted locally

### Milestone 4: Safe operator beta

- admin override flow defined
- dangerous action gating enforced
- error handling, retries, and audit exports available

## Immediate next actions

1. Choose the mailbox transport library strategy for Apple platforms.
2. Define the exact permission matrix for admin, operator, and observer mailboxes.
3. Decide whether Codex is launched through CLI, local daemon, or a broker process.
4. Add the first real domain models for mailbox config, inbox item, and execution record.
5. Replace the static dashboard with a real task queue once the data model is settled.
