# Database And Migrations

`OrganizeCore` uses SQLite (via GRDB) to store scan snapshots, plans, and journal indexes.

## Storage Layout

At a high level:

- `scans`, `scan_source_roots`, `inventory_items`, `scan_excluded_items`
- `plans`, `plan_items`, `plan_operations`
- `journal_state` (index for apply resume)
- `execution_journal` (delete-originals + rollback)
- Optional feature tables (e.g. `user_overrides`, `file_snapshots`)

## Migrations

The schema is created with “create-if-missing” DDL, then selectively upgraded with additive migrations.
On startup, ``DatabaseManager`` ensures required tables/columns exist:

- Creates tables if they don’t exist.
- Adds missing columns with `ALTER TABLE`.

This approach is intentionally conservative and keeps existing project databases usable across versions.

## Project Files

Projects are stored as JSON (see ``ProjectStore``) and reference the SQLite database stored alongside the project directory.

## Operational Journals

Apply and lifecycle steps are recorded to a per-plan JSONL file:

- `journals/move_log_<planId>.jsonl`

The JSONL file is the primary audit trail; SQLite tables provide indexes for fast resume and UI queries.
