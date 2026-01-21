# Architecture

`OrganizeCore` is split into a few small subsystems with explicit boundaries:

- **Scanner**: Enumerates files/packages under selected source roots and stores an immutable inventory snapshot in SQLite.
- **Planner**: Converts an inventory snapshot into a deterministic plan (operations + “needs review” + exclusions), including collision resolution.
- **Executor (ApplyEngine)**: Applies the plan in stable order using crash-safe journaling and resume support.
- **Verifier**: Validates applied results (count/bytes, optional hashing for small files).
- **DeleteOriginals / Rollback**: Executes post-apply lifecycle steps using the journal.

## Data Flow

```
Sources (folders) ──scan──▶ inventory_items (SQLite) ──plan──▶ plan_items + plan_operations (SQLite)
                                           │                         │
                                           │                         └─export──▶ CSV/JSONL
                                           │
                                           └─apply──▶ move_log_<planId>.jsonl + journal_state (SQLite)
                                                         │
                                                         ├─verify──▶ VerificationResult
                                                         ├─delete originals──▶ execution_journal
                                                         └─rollback──▶ execution_journal
```

## Determinism

Planning is deterministic when:

- Input inventory snapshot is the same.
- Settings are the same.
- Destination filesystem state is unchanged for collision checks (planner is read-only; uses `fileExists` only).

Collision groups are ordered by `sourcePath`, and output operations are ordered by `(resolvedDestPath, sourcePath)` to ensure stable results.

## Safety Model

- **Never overwrite** at apply time. If `resolvedDestPath` already exists unexpectedly, the operation is skipped with `ApplyTimeCollision`.
- **Journaling** is append-only JSONL (source of truth) with a SQLite index for resume/UI.
- **Copy-first delete originals** is gated on successful verification and performs a pre-delete recheck.
