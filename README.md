# folder_manager (Organize)

Local-first macOS app + CLI to safely reorganize files into a clean destination structure.

## Features
- Deterministic **Scan → Plan → Preview → Apply → Verify** workflow
- Crash-safe journaling (JSONL) with resume support
- Copy-first + gated delete-originals, and rollback
- Owner matching (people keywords) + conservative defaults (Needs Review)
- Extension routing rules (custom folders, per-owner, absolute destinations via bookmarks in the App)

## Requirements
- macOS 14+
- Xcode (for the SwiftUI app) and Swift toolchain (for CLI/tests)

## CLI (SwiftPM)
From the repo root:

```sh
swift run organize --help
```

Example workflow:

```sh
swift run organize scan --project /tmp/org/project.json --source /tmp/org/src --dest /tmp/org/dest
swift run organize plan --project /tmp/org/project.json
swift run organize apply --project /tmp/org/project.json
swift run organize verify --project /tmp/org/project.json
```

## App (Xcode)
Open `OrganizeApp/OrganizeApp.xcodeproj` and run the `OrganizeApp` scheme.

## Tests
```sh
swift test
```

## Documentation (DocC)
DocC sources live under `Sources/OrganizeCore/OrganizeCore.docc/`.
You can browse them in Xcode (Product → Build Documentation).

