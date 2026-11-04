# Contributing to PlanOpsis Mobile

Thank you for helping. This page covers how to build, test and submit a change.

## Set up

1. Install Xcode 26 or later (for the app) or a Swift 6 toolchain (for the core only).
2. Clone the repository and open `PlanOpsisMobile.xcodeproj`. In **Signing & Capabilities**, pick
   your own team. Don't commit your team ID or a personal bundle identifier: keep them in a local
   `*.local.xcconfig`, which git ignores.
3. Read [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for how the code fits together.

## Build and test

```sh
swift build --build-tests      # the PlanOpsisCore library and its tests (macOS or Linux)
swift test --parallel
xcodebuild build -project PlanOpsisMobile.xcodeproj -scheme PlanOpsisMobile \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO
```

CI runs the same three checks on every push and pull request. A change is ready when all three
pass.

## Making a change

- **Put logic in the core.** Code that can run without UIKit or SwiftUI belongs in `PlanOpsisCore`,
  with tests. Views and the store should only hold state and call engines.
- **Register new files.** A new core file goes in `Package.swift` (`sources`) and in the Xcode
  project. An iOS-only file goes in the Xcode project only, inside `#if os(iOS)`.
- **Test every behaviour change.** Add the test to the feature suite it belongs to, or a new
  `PlanOpsisV<version>…Tests.swift` for a new feature.
- **Keep older projects opening.** New persisted fields decode with `decodeIfPresent` and a default.
- **Update the changelog.** Add a section to [CHANGELOG.md](CHANGELOG.md) that says what changed for
  the user and why.
- **Match the surrounding code.** Follow its naming, comment density and idiom. Use millimetres and
  y-up plan coordinates throughout.

## Data and secrets

- **No secrets, ever.** No passwords, API keys, tokens, certificates, provisioning profiles or
  private keys in code, tests, sample files or commit history. Configuration goes in a local `.env`
  (git-ignored), with placeholders in `.env.example`. See [SECURITY.md](SECURITY.md).
- **No real personal or customer data.** Test fixtures and samples must be made up: generated
  geometry, invented names ("J. Doe") and addresses ("1 Example Street"), mock captures. Never commit
  a client's scan, plan, photo or project file. Never commit anything with names, addresses,
  locations or images of real people or places.

## Submitting

1. Branch from `main`.
2. Make focused commits with clear messages: what changed and why.
3. Open a pull request describing the change, how it was tested, and anything a reviewer should look
   at closely.

By contributing, you agree that your contribution is licensed under the
[Apache License, Version 2.0](LICENSE), the licence of this project (see section 5 of the licence).
