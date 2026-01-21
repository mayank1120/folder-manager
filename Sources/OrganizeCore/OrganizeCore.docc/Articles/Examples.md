# Examples

## CLI: Scan → Plan → Apply → Verify

```sh
organize scan --project /tmp/org/project.json --source /tmp/org/src --dest /tmp/org/dest
organize plan --project /tmp/org/project.json
organize apply --project /tmp/org/project.json
organize verify --project /tmp/org/project.json
```

## Engine: Scan And Plan

```swift
let db = try DatabaseManager(path: dbPath)
let inventoryStore = InventoryStore(dbManager: db)
let planStore = PlanStore(dbManager: db)

let scanner = Scanner(inventoryStore: inventoryStore)
let scan = try await scanner.scan(project: project)

let planner = Planner(inventoryStore: inventoryStore, planStore: planStore)
let summary = try await planner.createPlan(project: project, scanId: scan.scan.id)
```

## Notes

- In the sandboxed app, folder access is managed via security-scoped bookmarks.
- For destructive operations, prefer `copyFirst` + `verify` before deleting originals.
