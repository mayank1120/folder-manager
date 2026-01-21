# Security

`OrganizeCore` is designed to be conservative and local-only:

- No network access is required.
- Planning is a dry-run; apply never overwrites existing files.
- Paths are validated to prevent traversal and symlink escapes.

## Key Protections

- Destination-in-source guard (prevents recursive moves).
- Path traversal checks for user-supplied custom destinations.
- Bookmark staleness enforcement in the App (forces relink).
- Temp files use per-volume replacement directories where possible.

