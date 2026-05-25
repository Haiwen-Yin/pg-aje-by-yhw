-- ============================================================================
-- pg-aje: Test Suite v0.1.0
-- ============================================================================

-- Clean up
SELECT aje.drop_view('dept_dv');
SELECT aje.drop_view('item_dv');
SELECT aje.drop_view('cfg_dv');
DROP SCHEMA IF EXISTS aje_test CASCADE;

-- ============================================================================
-- PHASE 1: Basic CRUD (IDENTITY PK + 1 nested array)
-- ============================================================================

\echo '========================================'
\echo 'PHASE 1: Basic CRUD'
\echo '========================================'

CREATE SCHEMA aje_test;

CREATE TABLE aje_test.departments (
    dept_id   BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    dept_name TEXT NOT NULL,
    location  TEXT,
    budget    NUMERIC DEFAULT 0
);

CREATE TABLE aje_test.employees (
    emp_id   BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    dept_id  BIGINT NOT NULL REFERENCES aje_test.departments(dept_id) ON DELETE CASCADE,
    emp_name TEXT NOT NULL,
    job      TEXT,
    salary   NUMERIC DEFAULT 0
);

INSERT INTO aje_test.departments (dept_name, location, budget) VALUES
    ('Engineering', 'Building A', 500000),
    ('Marketing', 'Building B', 200000);

INSERT INTO aje_test.employees (dept_id, emp_name, job, salary) VALUES
    (1, 'Alice', 'Engineer', 120000),
    (1, 'Bob', 'Engineer', 80000),
    (2, 'Carol', 'Manager', 95000);

SELECT aje.create_view(
    'dept_dv', 'departments', 'aje_test', 'd',
    '{"insert":true,"update":true,"delete":true}'::jsonb,
    '[{"path":"dept_name","column":"dept_name","updatable":true,"check":true},
      {"path":"location","column":"location","updatable":true,"check":true},
      {"path":"budget","column":"budget","updatable":true,"check":true},
      {"path":"staff","type":"nested_array","table":"employees","schema":"aje_test","alias":"e",
       "annotations":{"insert":true,"update":true,"delete":true},
       "link":{"fk_columns":["dept_id"],"pk_columns":["dept_id"]},
       "fields":[
        {"path":"emp_name","column":"emp_name","updatable":true,"check":true},
        {"path":"job","column":"job","updatable":true,"check":true},
        {"path":"salary","column":"salary","updatable":true,"check":true}
       ]}]'::jsonb
);

-- 1.1 SELECT
\echo '--- 1.1 SELECT ---'
SELECT (data->>'_id')::bigint AS id, data->>'dept_name' AS name,
       jsonb_array_length(data->'staff') AS staff_count
FROM dept_dv ORDER BY (data->>'_id')::bigint;

-- 1.2 SELECT single (verify _metadata)
\echo '--- 1.2 SELECT single ---'
SELECT data->'_metadata'->>'etag' IS NOT NULL AS has_etag,
       data->'_metadata'->>'xmin' IS NOT NULL AS has_xmin
FROM dept_dv WHERE (data->>'_id')::bigint = 1;

-- 1.3 INSERT with nested
\echo '--- 1.3 INSERT with nested ---'
INSERT INTO dept_dv (data) VALUES (
    '{"dept_name":"Research","location":"Building C","budget":400000,
      "staff":[
        {"emp_name":"Dave","job":"Researcher","salary":110000},
        {"emp_name":"Eve","job":"Researcher","salary":105000}
      ]}'::jsonb
);
SELECT data->>'dept_name' AS name FROM dept_dv WHERE (data->>'_id')::bigint = 3;
SELECT count(*) AS staff_count FROM aje_test.employees WHERE dept_id = 3;

-- 1.4 INSERT without nested
\echo '--- 1.4 INSERT without nested ---'
INSERT INTO dept_dv (data) VALUES ('{"dept_name":"HR","budget":150000}'::jsonb);
SELECT data->>'dept_name' AS name, jsonb_array_length(data->'staff') AS staff_count
FROM dept_dv WHERE (data->>'_id')::bigint = 4;

-- 1.5 UPDATE root
\echo '--- 1.5 UPDATE root ---'
UPDATE dept_dv SET data = jsonb_set(jsonb_set(data, '{budget}', '450000'), '{location}', '"Building C2"')
WHERE (data->>'_id')::bigint = 3;
SELECT data->>'budget' AS budget, data->>'location' AS location
FROM dept_dv WHERE (data->>'_id')::bigint = 3;

-- 1.6 UPDATE nested (replace entire array)
\echo '--- 1.6 UPDATE nested ---'
UPDATE dept_dv SET data = jsonb_set(data, '{staff}',
    '[{"emp_name":"Dave","job":"Lead Researcher","salary":130000},
      {"emp_name":"Eve","job":"Senior Researcher","salary":125000}]'::jsonb
) WHERE (data->>'_id')::bigint = 3;
SELECT jsonb_array_length(data->'staff') AS view_count FROM dept_dv WHERE (data->>'_id')::bigint = 3;
SELECT count(*) AS table_count FROM aje_test.employees WHERE dept_id = 3;

-- 1.7 UPDATE clear nested
\echo '--- 1.7 UPDATE clear nested ---'
UPDATE dept_dv SET data = jsonb_set(data, '{staff}', '[]'::jsonb)
WHERE (data->>'_id')::bigint = 4;
SELECT jsonb_array_length(data->'staff') AS staff_count FROM dept_dv WHERE (data->>'_id')::bigint = 4;

-- 1.8 DELETE cascade
\echo '--- 1.8 DELETE cascade ---'
DELETE FROM dept_dv WHERE (data->>'_id')::bigint = 3;
SELECT count(*) AS dept_count FROM aje_test.departments WHERE dept_id = 3;
SELECT count(*) AS staff_count FROM aje_test.employees WHERE dept_id = 3;

-- 1.9 DELETE no children
\echo '--- 1.9 DELETE no children ---'
DELETE FROM dept_dv WHERE (data->>'_id')::bigint = 4;
SELECT count(*) AS total_depts FROM aje_test.departments;

SELECT aje.drop_view('dept_dv');

-- ============================================================================
-- PHASE 2: Composite PK + 2 nested arrays + JSONB + nodelete + readonly
-- ============================================================================

\echo '========================================'
\echo 'PHASE 2: Composite PK + Annotations'
\echo '========================================'

CREATE TABLE aje_test.items (
    item_id   BIGINT NOT NULL,
    item_type TEXT NOT NULL DEFAULT 'PRODUCT',
    title     TEXT NOT NULL,
    status    TEXT DEFAULT 'ACTIVE',
    tags      JSONB DEFAULT '{}',
    PRIMARY KEY (item_id, item_type)
);

CREATE TABLE aje_test.item_edges (
    edge_id   BIGINT NOT NULL,
    item_id   BIGINT NOT NULL,
    item_type TEXT NOT NULL,
    edge_type TEXT NOT NULL,
    strength  NUMERIC(5,4) DEFAULT 0.5,
    PRIMARY KEY (edge_id, item_id, item_type),
    FOREIGN KEY (item_id, item_type)
        REFERENCES aje_test.items(item_id, item_type) ON DELETE CASCADE
);

CREATE TABLE aje_test.item_notes (
    note_id   BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    item_id   BIGINT,
    item_type TEXT,
    note_text TEXT NOT NULL,
    FOREIGN KEY (item_id, item_type)
        REFERENCES aje_test.items(item_id, item_type)
);

INSERT INTO aje_test.items (item_id, item_type, title, status, tags) VALUES
    (1, 'PRODUCT', 'Widget', 'ACTIVE', '{"color":"red"}'),
    (2, 'PRODUCT', 'Gadget', 'ACTIVE', '{"color":"blue"}');

INSERT INTO aje_test.item_edges (edge_id, item_id, item_type, edge_type, strength) VALUES
    (1, 1, 'PRODUCT', 'SIMILAR_TO', 0.85);

INSERT INTO aje_test.item_notes (item_id, item_type, note_text) VALUES
    (1, 'PRODUCT', 'Popular item'), (1, 'PRODUCT', 'Best seller');

SELECT aje.create_view(
    'item_dv', 'items', 'aje_test', 'i',
    '{"insert":true,"update":true,"delete":true}'::jsonb,
    '[{"path":"title","column":"title","updatable":true,"check":true},
      {"path":"status","column":"status","updatable":true,"check":true},
      {"path":"tags","column":"tags","updatable":true,"check":true},
      {"path":"edges","type":"nested_array","table":"item_edges","schema":"aje_test","alias":"ie",
       "annotations":{"insert":true,"update":true,"delete":true},
       "link":{"fk_columns":["item_id","item_type"],"pk_columns":["item_id","item_type"]},
       "fields":[
        {"path":"edge_type","column":"edge_type","updatable":true,"check":true},
        {"path":"strength","column":"strength","updatable":true,"check":true}
       ]},
      {"path":"notes","type":"nested_array","table":"item_notes","schema":"aje_test","alias":"n",
       "annotations":{"insert":true,"update":true,"delete":false},
       "link":{"fk_columns":["item_id","item_type"],"pk_columns":["item_id","item_type"]},
       "fields":[
        {"path":"note_text","column":"note_text","updatable":true,"check":true}
       ]}]'::jsonb
);

-- 2.1 SELECT composite _id + JSONB
\echo '--- 2.1 SELECT ---'
SELECT (data->'_id'->>'item_id')::bigint AS id,
       data->>'title' AS title,
       data->>'tags' AS tags,
       jsonb_array_length(data->'edges') AS edges,
       jsonb_array_length(data->'notes') AS notes
FROM item_dv ORDER BY (data->'_id'->>'item_id')::bigint;

-- 2.2 INSERT composite PK
\echo '--- 2.2 INSERT ---'
INSERT INTO item_dv (data) VALUES (
    '{"_id":{"item_id":3,"item_type":"PRODUCT"},"title":"New Item","status":"PENDING",
      "tags":{"color":"green"},
      "edges":[{"edge_id":2,"edge_type":"RELATED_TO","strength":0.7}],
      "notes":[{"note_text":"Test note"}]}'::jsonb
);
SELECT data->>'title' AS title FROM item_dv WHERE (data->'_id'->>'item_id')::bigint = 3;

-- 2.3 UPDATE JSONB field
\echo '--- 2.3 UPDATE JSONB ---'
UPDATE item_dv SET data = jsonb_set(data, '{tags}', '{"color":"green","size":"large"}'::jsonb)
WHERE (data->'_id'->>'item_id')::bigint = 3;
SELECT data->>'tags' AS tags FROM item_dv WHERE (data->'_id'->>'item_id')::bigint = 3;

-- 2.4 DELETE — notes orphaned (nodelete), edges cascade
\echo '--- 2.4 DELETE (nodelete) ---'
DELETE FROM item_dv WHERE (data->'_id'->>'item_id')::bigint = 3;
SELECT count(*) AS items FROM aje_test.items WHERE item_id = 3;
SELECT count(*) AS edges FROM aje_test.item_edges WHERE item_id = 3;
SELECT count(*) AS orphan_notes FROM aje_test.item_notes WHERE item_id IS NULL;

SELECT aje.drop_view('item_dv');

-- ============================================================================
-- PHASE 3: Read-only view + Introspection
-- ============================================================================

\echo '========================================'
\echo 'PHASE 3: Read-only + Introspection'
\echo '========================================'

CREATE TABLE aje_test.config (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
);
INSERT INTO aje_test.config VALUES ('max_items', '100'), ('timeout', '30');

SELECT aje.create_view(
    'cfg_dv', 'config', 'aje_test', 'c',
    '{"insert":false,"update":false,"delete":false}'::jsonb,
    '[{"path":"key","column":"key","updatable":false,"check":true},
      {"path":"value","column":"value","updatable":false,"check":true}]'::jsonb
);

-- 3.1 Read-only: SELECT works, INSERT/UPDATE/DELETE blocked
\echo '--- 3.1 Read-only ---'
SELECT data->>'key' AS key, data->>'value' AS value FROM cfg_dv ORDER BY data->>'_id';

DO $$ BEGIN
    INSERT INTO cfg_dv (data) VALUES ('{"key":"x","value":"y"}'::jsonb);
    RAISE EXCEPTION 'FAIL: insert should have been blocked';
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'OK: insert blocked';
END $$;

DO $$ BEGIN
    UPDATE cfg_dv SET data = jsonb_set(data, '{value}', '"200"') WHERE data->>'_id' = 'max_items';
    RAISE EXCEPTION 'FAIL: update should have been blocked';
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'OK: update blocked';
END $$;

DO $$ BEGIN
    DELETE FROM cfg_dv WHERE data->>'_id' = 'max_items';
    RAISE EXCEPTION 'FAIL: delete should have been blocked';
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'OK: delete blocked';
END $$;

-- 3.2 Introspection
\echo '--- 3.2 Introspection ---'
SELECT view_name, root_table FROM aje.list_views();
SELECT status, message FROM aje.validate_view('cfg_dv');

SELECT aje.drop_view('cfg_dv');

-- ============================================================================
-- Cleanup
-- ============================================================================

DROP SCHEMA IF EXISTS aje_test CASCADE;
SELECT count(*) AS remaining_views FROM aje.list_views();

\echo '========================================'
\echo 'ALL TESTS COMPLETED'
\echo '========================================'