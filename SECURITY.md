# Security Model

## Overview

OrganizeApp is a **local-only macOS desktop application** designed to organize files on the user's filesystem. It operates entirely offline with no network communication.

---

## Trust Model

### Trusted Inputs
| Input | Source | Validation |
|-------|--------|------------|
| Project settings | User-defined JSON | Schema validation |
| Source folder paths | User selection via Open Panel | macOS sandbox bookmarks |
| Destination folder | User selection | Bookmark resolution |
| Extension rules | User-defined | Validated at plan time |

### Untrusted Inputs (Sanitized)
| Input | Risk | Mitigation |
|-------|------|------------|
| Filenames from filesystem | Path traversal, special chars | `PathSecurity.sanitizeFilename()` |
| Relative paths | `..` traversal | `PathSecurity.isRelativePathSafe()` |
| Symlink targets | Escape source tree | Symlinks excluded, not followed |

---

## Prevented Attacks

### Path Traversal
- `PathSecurity.isPathSafe()` rejects paths containing `..`
- Destination paths are validated before any file operation
- All relative paths are validated with `isRelativePathSafe()`

### Symlink Escape
- Scanner excludes symlinks (never follows them)
- Symlinks are logged as excluded items
- Packages containing symlinks skip internal traversal

### Accidental Overwrites
- **Never-overwrite guarantee**: ApplyEngine checks destination before every write
- Collisions are handled with timestamped suffixes or skipped
- No file is deleted before copy verification succeeds

### Data Loss Prevention
- **Journal-first design**: Every operation is journaled before execution
- Delete-originals requires successful copy verification
- Rollback can restore files from archive location

---

## Out of Scope

| Threat | Reason |
|--------|--------|
| Network attacks | No network communication |
| Authentication bypass | No authentication (local-only) |
| SQL injection | All queries use parameterized statements |
| XSS/CSRF | No web interface |

---

## Sandbox & Entitlements

The app runs in macOS App Sandbox with:
- `com.apple.security.files.user-selected.read-write` - User-selected folders only
- Security-scoped bookmarks for persistent access
- Bookmark staleness enforcement for source/destination paths

---

## Dependencies

| Dependency | Purpose | Risk Mitigation |
|------------|---------|-----------------|
| GRDB | SQLite access | Widely used, maintained |
| Swift Argument Parser | CLI parsing | Apple-maintained |
| CryptoKit | Hashing | Apple system framework |

No third-party network libraries. No dynamic dependency loading.

---

## Security Checklist

- [x] Input sanitization (filenames, paths)
- [x] Parameterized SQL queries
- [x] No hardcoded secrets
- [x] Symlinks excluded
- [x] Never-overwrite policy
- [x] Journal-first execution
- [x] Sandbox-enforced file access
