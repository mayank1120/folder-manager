# ``OrganizeCore``
`OrganizeCore` is a local-first engine for safely organizing files on macOS.
It powers both the sandboxed SwiftUI app and the CLI, using deterministic planning, crash-safe journaling, verification, and rollback.

## Overview
The workflow is designed to be conservative:

1. **Scan** selected source roots into a SQLite inventory (read-only).
2. **Plan** a deterministic set of operations (dry-run), including collisions and “needs review”.
3. **Preview** the proposed changes (App) or export CSVs (CLI).
4. **Apply** the plan with journaling and resume support.
5. **Verify** results before any destructive steps.
6. **Delete originals** (copy-first only) and **rollback** (best-effort) using the journal.

## Topics

### Guides
- <doc:Architecture>
- <doc:DatabaseAndMigrations>
- <doc:Examples>
- <doc:ExtensionRouting>
- <doc:Security>
- <doc:AdvancedFeatures>

### Core Workflow
- ``Scanner``
- ``Planner``
- ``ApplyEngine``
- ``VerifyEngine``
- ``DeleteOriginalsEngine``
- ``RollbackManager``

### Storage
- ``DatabaseManager``
- ``InventoryStore``
- ``PlanStore``
- ``JournalStore``
- ``ExecutionJournalStore``
- ``ExportManager``

### Models
- ``Project``
- ``ProjectSettings``
- ``Plan``
- ``PlanOperation``
- ``JournalEntry``
