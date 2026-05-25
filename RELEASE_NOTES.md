# pg-aje v0.1.0 Release Notes

**Release Date:** 2026-05-25

## Overview

First alpha release of pg-aje — a PostgreSQL 18 extension that implements A JSON Extension Views. Create updatable views that expose relational data as hierarchical JSON documents with ETAG-based optimistic concurrency control.

## What is A JSON Extension?

AJE provides a **bidirectional mapping** between relational tables and JSON documents:

- **Read**: Data from one or more relational tables is presented as a JSON document
- **Write**: INSERT/UPDATE/DELETE on the JSON document automatically propagates to underlying tables
- **Consistency**: ETAG-based optimistic concurrency prevents lost updates
- **No duplication**: Data is stored once in relational tables; JSON documents are generated on read

## Highlights

### Function-Based DDL

```sql
SELECT aje.create_view(
    'dept_dv',
    'departments',
    'public',
    'd',
    '{"insert":true,"update":true,"delete":true}'::jsonb,
    '[
        {"path": "dept_name", "column": "dept_name", "updatable": true},
        {"path": "location", "column": "location", "updatable": true},
        {"path": "staff", "type": "nested_array",
         "table": "employees", "alias": "e",
         "annotations": {"insert": true, "update": true, "delete": true},
         "link": {"fk_columns": ["dept_id"], "pk_columns": ["dept_id"]},
         "fields": [
            {"path": "emp_name", "column": "emp_name", "updatable": true},
            {"path": "job", "column": "job", "updatable": true}
         ]}
    ]'::jsonb
);
```

### Composite PK & JSONB

```sql
-- Composite PK produces _id as a JSON object
SELECT data FROM item_dv WHERE (data->'_id'->>'item_id')::bigint = 1;
-- Result: {"_id": {"item_id": 1, "item_type": "PRODUCT"}, "title": "Widget", "tags": {"color": "red"}}

-- Update JSONB column directly
UPDATE item_dv SET data = jsonb_set(data, '{tags}', '{"color":"green"}'::jsonb)
WHERE (data->'_id'->>'item_id')::bigint = 1;
```

### Annotation Enforcement

- **Read-only views**: `insert:false, update:false, delete:false` — raises `aje_insert_blocked`, `aje_update_blocked`, `aje_delete_blocked`
- **nodelete children**: When a child has `delete:false`, parent DELETE orphans children (FK set to NULL) instead of cascade-deleting

### ETAG Optimistic Concurrency

Every document includes `_metadata.etag` — an MD5 hash of annotated column values. On UPDATE/DELETE, the trigger verifies the ETAG matches the current state. If another transaction modified the row, the operation fails with `aje_etag_mismatch`.

### Primary Key Handling

| PK Type | `_id` Format | INSERT Behavior |
|---|---|---|
| IDENTITY (auto-generated) | Integer | Auto-assigned; omit `_id` |
| Non-IDENTITY integer | Integer | Must provide `_id` |
| TEXT | String | Must provide `_id` |
| Composite (multi-column) | JSON object | Must provide `_id` as `{"col1": val1, "col2": val2}` |

## Requirements

- PostgreSQL 18+
- No additional extensions required

## Installation

```bash
psql -d your_database -f sql/install.sql
```

## Testing

```bash
psql -d your_database -f scripts/test/test_aje.sql
```

## Architecture

| Component | Mechanism |
|---|---|
| View generation | `jsonb_build_object()` with correlated subqueries |
| Updatability | `INSTEAD OF` triggers (views with subqueries are not auto-updatable) |
| ETAG | `md5()` of check-annotated column values + `xmin` |
| Nested arrays | `jsonb_agg()` correlated subquery, FK-based |
| Update strategy | Delete-and-reinsert for nested arrays |
| Delete strategy | Cascade or NULL-out FK per annotations |
| Composite PK | `_id` as JSON object, inline `OLD.data->'_id'->>'col'` for WHERE clauses |
| Dynamic types | `v_root_id` type (bigint/text) determined from column data_type |

## Limitations

- Only 1:N nested arrays (no N:1, N:N)
- Single-level nesting only
- No GraphQL syntax
- No flex columns
- No computed fields