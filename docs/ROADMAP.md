# Patch Courier Roadmap

Patch Courier's product direction is: coding should be able to continue from anywhere, while execution, credentials, and policy stay on the operator's own Mac.

This roadmap keeps the project practical. The immediate goal is not to support every messaging channel or every agent runtime; it is to make the email-to-local-Codex loop reliable, understandable, and safe enough that other developers can run and improve it.

## Guiding principles

- Local-first execution: repositories, credentials, Codex profile state, and approvals stay on the Mac that owns the work.
- Email as a control plane: inbound mail starts and continues tasks; outbound mail reports status, asks for approval, or requests missing information.
- Policy outside the prompt: sender trust, workspace scope, and dangerous-action gates should be enforced by code, not just natural language instructions.
- Durable by default: daemon restarts should not lose thread state, approval requests, mailbox cursors, or notification decisions.
- Observable operations: users need to understand what is running, what is queued, and why a message was ignored or rejected.

## v0.2 Reliability and recovery

Goal: make the core loop boringly reliable across restarts, duplicate mail, and transport failures.

- Tighten duplicate-notification suppression around crash-at-send and retry-after-send cases.
- Add regression tests for reply token extraction, subject normalization, and quoted-history stripping.
- Add end-to-end fixture tests for receipt, project selection, approval request, completion, failure, and saved-for-later messages.
- Track mailbox poll incidents with timestamps, last successful UID, last failure, and retry schedule.
- Define a small migration strategy for SQLite schema changes before adding more stored state.

Exit criteria:

- Restarting the daemon during pending approval does not duplicate the approval email.
- Replaying a mailbox sync does not enqueue the same inbound message twice.
- A transport failure is visible in the app with enough detail to diagnose it.

## v0.3 Onboarding and contributor setup

Goal: make a new user able to build, configure, and test the loop without reading the implementation.

- Replace placeholder README sections with a guided first-run setup path.
- Add screenshots or a short walkthrough for mailbox account setup, sender policies, and managed projects.
- Add sample `.env` profiles for local-only probing and mailbox-enabled operation.
- Add a troubleshooting page for Codex discovery, `CODEX_HOME` mirroring, Keychain storage, and IMAP/SMTP errors.
- Create a lightweight architecture diagram that shows Mail.app/inbox -> `mailroomd` -> `codex app-server` -> reply email.

Exit criteria:

- A contributor can run `xcodegen generate`, build, run daemon probes, and render mail fixtures from the README alone.
- Common setup failures have explicit error messages and troubleshooting entries.

## v0.4 Operator console depth

Goal: turn the macOS app from a status viewer into a useful operations console.

- Add per-thread timelines: inbound message, queued work, Codex turn, approval, result email.
- Add operator actions for replaying final outcomes, retrying failed sends, and copying thread/debug metadata.
- Add artifact inspection for Codex outputs where available.
- Add searchable filters for active workers, pending approvals, rejected mail, and failed transport events.
- Add stronger UI state for daemon lifecycle: not installed, starting, running, degraded, stopped.

Exit criteria:

- An operator can answer: what is running, what is blocked, what failed, and what can I safely do next?

## v0.5 Safety and policy model

Goal: make policy explicit enough for real-world remote coding workflows.

- Separate sender roles for admin, operator, read-only reviewer, and blocked sender.
- Add workspace capability profiles: read-only, write workspace, run tests, execute shell, destructive-action approval required.
- Add policy previews so a user can see why an inbound email will be accepted, paused, rejected, or saved.
- Add audit records for approval decisions and policy mutations.
- Document threat model and safe deployment assumptions in `SECURITY.md`.

Exit criteria:

- A dangerous request from an approved sender pauses for approval instead of relying on prompt wording.
- Policy decisions are inspectable from persisted records.

## v0.6 Distribution and release quality

Goal: make Patch Courier installable by people who are not developing it.

- Add signed/notarized macOS app release workflow.
- Package `mailroomd` and runtime helper scripts consistently inside the app bundle.
- Add a first-run checklist for Codex CLI path, Codex profile mirroring, mailbox credentials, and managed projects.
- Add version/build metadata in the app's About or settings view.
- Publish release artifacts and checksums on GitHub Releases.

Exit criteria:

- A user can download a release, launch the app, configure one mailbox, and run a smoke-test thread without opening Xcode.

## v1.0 Definition

Patch Courier should reach v1.0 only when these are true:

- The mail-to-Codex-to-mail loop survives daemon restarts and common mailbox failures.
- Onboarding and troubleshooting are documented enough for external users.
- Policy and approval behavior is explicit, tested, and auditable.
- The app can be distributed as a signed macOS release.
- The public storage schema and thread token format have a documented compatibility policy.

## Later directions

These are intentionally after the local email loop is stable:

- Additional ingress channels such as Matrix, Slack, or a local web inbox.
- Multi-Mac routing and handoff between machines.
- Web dashboard for remote status viewing while preserving local execution.
- Pluggable agent runtimes beyond Codex.
- Team mode with shared policies and per-user audit trails.
