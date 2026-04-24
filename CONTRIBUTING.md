# Contributing

## Development workflow

- Keep changes scoped and explain user-visible behavior in the pull request.
- Regenerate the Xcode project with `xcodegen generate` after editing `project.yml`.
- Before opening a pull request, run the daemon tests and build both shipped targets:

```bash
xcodebuild -project PatchCourier.xcodeproj -scheme MailroomDaemon -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test
xcodebuild -project PatchCourier.xcodeproj -scheme MailroomDaemon -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project PatchCourier.xcodeproj -scheme PatchCourierMac -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
```

## Repo hygiene

- Do not commit local secrets, mailbox passwords, or copied Codex profiles.
- Keep machine-specific paths out of docs, fixtures, and screenshots where possible.
- Derived build output belongs in ignored paths such as `.derived/`, `DerivedData/`, and `build/`.

## Pull requests

- Include a short verification note that lists the commands you ran.
- If a change affects outbound mail rendering, include updated fixture output or screenshots.
- If a change updates daemon/runtime configuration, document any new environment variables in `README.md` and `.env.example`.
