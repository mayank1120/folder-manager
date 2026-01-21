# Advanced Features

## Duplicate Detection

When enabled, scans compute content hashes to group potential duplicates.
Duplicate handling policy is configurable (e.g. keep newest, skip duplicates).

## User Overrides

Users can override classification per file:
- Force owner bucket
- Force category/subcategory
- Force a specific extension rule
- Exclude an item from planning

## Incremental Scans

Incremental scans can reuse a previous snapshot to reduce work on large trees.
They fall back to a full scan when required for correctness.

## Tagging

Tags can be applied per plan operation (optionally):
- Global tags
- Per-category tags
- Per-owner tags

