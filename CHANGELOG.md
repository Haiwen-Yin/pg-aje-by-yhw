# Changelog

All notable changes to pg-aje are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [0.1.0] - 2026-05-25

First alpha release. Implements A JSON Extension Views on PostgreSQL 18.

### Added

- **Catalog schema** (`aje_catalog`) with 4 metadata tables: `aje_views`, `aje_view_tables`, `aje_view_columns`, `aje_view_links`
- **Core schema** (`aje`) with 7 functions:
  - `aje.create_view()` — Create an AJE view with automatic INSTEAD OF triggers
  - `aje.drop_view()` — Drop an AJE view and all associated objects
  - `aje.list_views()` — List all registered AJE views
  - `aje.describe_view()` — Return JSONB description of a view's structure
  - `aje.validate_view()` — Validate view definition against actual table schema
  - `aje.compute_etag()` — Compute MD5 ETAG from column values
  - `aje.jsonb_deep_merge()` — Recursive deep merge (RFC 7396 JSON Merge Patch)
- **VIEW generation** — Automatically generates a VIEW with `jsonb_build_object()` producing a single `data` JSONB column including `_id`, `_metadata` (etag + xmin), and nested arrays via correlated subqueries
- **INSTEAD OF INSERT trigger** — Decomposes JSON document into INSERT on root table + child tables with FK resolution
- **INSTEAD OF UPDATE trigger** — ETAG-based optimistic concurrency check + delete-and-reinsert strategy for nested arrays
- **INSTEAD OF DELETE trigger** — ETAG check + cascade delete or NULL-out FK per annotation flags
- **Composite PK support** — Multi-column primary keys produce `_id` as a JSON object; composite FKs are fully mapped in nested inserts
- **Non-IDENTITY PK support** — TEXT, BIGINT NOT NULL, and other non-auto-generated PKs: values extracted from `_id` in the document
- **JSONB column support** — Native JSONB columns are preserved as-is in the document
- **Multiple nested arrays** — A view can have multiple nested_array children
- **Annotation enforcement** — `insert:false` / `update:false` / `delete:false` raise explicit exceptions (`aje_insert_blocked`, `aje_update_blocked`, `aje_delete_blocked`)
- **nodelete annotation** — When a child has `delete:false`, parent DELETE sets child FK to NULL (orphan) instead of cascade-deleting
- **Annotation system** — `{insert, update, delete, check}` with negation variants (`noinsert`, `noupdate`, `nodelete`, `nocheck`)
- **Auto-detect columns** — When `p_fields` is empty, automatically detects all columns from the table schema
- **ETAG optimistic concurrency** — MD5 hash of check-annotated column values + xmin, raises `aje_etag_mismatch` on conflict
- **FK-based nesting** — 1:N nested arrays via correlated subqueries
- **Pure PL/pgSQL** — No C compilation required; uses INSTEAD OF triggers for view updatability

### Limitations (v0.1.0)

- Only 1:N nesting (nested_array) supported; N:1 and N:N deferred to v0.2.0
- Only single-level nesting (root + one child level)
- No GraphQL syntax parser; function-based API only
- No flex columns support
- No `@generated` computed fields
- No `@where` filter predicates in view definitions
- No REST/document API integration
- Update trigger uses delete-and-reinsert strategy for nested arrays (no incremental diff)