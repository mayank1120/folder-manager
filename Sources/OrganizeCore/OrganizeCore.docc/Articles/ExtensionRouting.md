# Extension Routing

Extension routing lets users send certain file types (by extension) into custom folders, either under the main organized destination or to an absolute custom destination (App sandbox uses security-scoped bookmarks).

## Rules

Rules are evaluated in descending `priority`, then by `createdAt` and `id` for determinism.

Each ``ExtensionRule`` defines:
- A list of extensions (e.g. `pdf`, `docx`, `jpg`)
- A destination type (e.g. a custom folder)
- A destination path (relative, or absolute if `destinationIsAbsolute`)
- An owner scope (per-owner by default)

## Exclusions

``ExtensionExclusions`` supports:
- Exclude only these extensions (default)
- Exclude all except these extensions
- No extension-based exclusions

## Security

Custom destination paths are validated and sanitized:
- Relative destinations are rejected if they contain path traversal (`..`) segments.
- Absolute custom destinations are resolved through bookmarks in the App and validated before use.

