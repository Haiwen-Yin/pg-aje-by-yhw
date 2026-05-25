-- ============================================================================
-- pg-aje: A JSON Extension for PostgreSQL 18
-- Version: v0.1.0
-- Author: Haiwen Yin
--
-- Implements A JSON Extension (AJE) Views on PostgreSQL 18.
-- Provides bidirectional mapping between relational tables and JSON documents
-- with ETAG-based optimistic concurrency control.
-- ============================================================================

-- ============================================================================
-- Schema: aje_catalog — stores AJE view metadata
-- ============================================================================

CREATE SCHEMA IF NOT EXISTS aje_catalog;

CREATE TABLE IF NOT EXISTS aje_catalog.aje_views (
    view_id         BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    view_name       TEXT NOT NULL UNIQUE,
    root_table      TEXT NOT NULL,
    root_schema     TEXT NOT NULL DEFAULT 'public',
    root_alias      TEXT NOT NULL DEFAULT 'r',
    root_annotations JSONB NOT NULL DEFAULT '{"insert":true,"update":true,"delete":true}',
    created_at      TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE IF NOT EXISTS aje_catalog.aje_view_tables (
    table_id        BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    view_id         BIGINT NOT NULL REFERENCES aje_catalog.aje_views(view_id) ON DELETE CASCADE,
    table_name      TEXT NOT NULL,
    table_schema    TEXT NOT NULL DEFAULT 'public',
    table_alias     TEXT NOT NULL,
    parent_table_id BIGINT REFERENCES aje_catalog.aje_view_tables(table_id) ON DELETE CASCADE,
    nesting_type    TEXT NOT NULL DEFAULT 'nested_array' CHECK (nesting_type IN ('root','nested_array','nested_object')),
    nesting_depth   INT NOT NULL DEFAULT 0,
    json_path       TEXT NOT NULL,
    annotations     JSONB NOT NULL DEFAULT '{"insert":true,"update":true,"delete":true}',
    UNIQUE(view_id, table_alias)
);

CREATE TABLE IF NOT EXISTS aje_catalog.aje_view_columns (
    column_id       BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    table_id        BIGINT NOT NULL REFERENCES aje_catalog.aje_view_tables(table_id) ON DELETE CASCADE,
    json_path       TEXT NOT NULL,
    column_name     TEXT NOT NULL,
    updatable       BOOLEAN NOT NULL DEFAULT true,
    check_etag      BOOLEAN NOT NULL DEFAULT true,
    is_identifying  BOOLEAN NOT NULL DEFAULT false,
    column_order    INT NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS aje_catalog.aje_view_links (
    link_id         BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    view_id         BIGINT NOT NULL REFERENCES aje_catalog.aje_views(view_id) ON DELETE CASCADE,
    child_table_id  BIGINT NOT NULL REFERENCES aje_catalog.aje_view_tables(table_id) ON DELETE CASCADE,
    parent_table_id BIGINT NOT NULL REFERENCES aje_catalog.aje_view_tables(table_id) ON DELETE CASCADE,
    fk_columns      TEXT[] NOT NULL,
    pk_columns      TEXT[] NOT NULL
);

COMMENT ON TABLE aje_catalog.aje_views IS 'Registered AJE view definitions';
COMMENT ON TABLE aje_catalog.aje_view_tables IS 'Tables participating in each AJE view';
COMMENT ON TABLE aje_catalog.aje_view_columns IS 'Column-to-JSON-path mappings with annotation flags';
COMMENT ON TABLE aje_catalog.aje_view_links IS 'FK-based nesting links between tables in a view';

-- ============================================================================
-- Schema: aje — core functions
-- ============================================================================

CREATE SCHEMA IF NOT EXISTS aje;

-- ============================================================================
-- Helper: aje_jsonb_deep_merge
-- ============================================================================

CREATE OR REPLACE FUNCTION aje.jsonb_deep_merge(
    target jsonb,
    patch jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE
AS $func$
DECLARE
    key text;
    val jsonb;
    result jsonb;
BEGIN
    IF patch IS NULL THEN RETURN target; END IF;
    IF jsonb_typeof(patch) <> 'object' THEN RETURN patch; END IF;
    IF target IS NULL OR jsonb_typeof(target) <> 'object' THEN RETURN patch; END IF;
    result := target;
    FOR key, val IN SELECT * FROM jsonb_each(patch)
    LOOP
        IF val = 'null'::jsonb THEN
            result := result - key;
        ELSIF jsonb_typeof(val) = 'object' AND jsonb_typeof(result -> key) = 'object' THEN
            result := jsonb_set(result, ARRAY[key], aje.jsonb_deep_merge(result -> key, val));
        ELSE
            result := jsonb_set(result, ARRAY[key], val);
        END IF;
    END LOOP;
    RETURN result;
END;
$func$;

COMMENT ON FUNCTION aje.jsonb_deep_merge(jsonb, jsonb) IS 'Recursive deep merge of two JSONB objects (RFC 7396 JSON Merge Patch)';

-- ============================================================================
-- Helper: aje_compute_etag
-- ============================================================================

CREATE OR REPLACE FUNCTION aje.compute_etag(
    p_values text[]
)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $func$
    SELECT md5(array_to_string(p_values, '|'));
$func$;

COMMENT ON FUNCTION aje.compute_etag(text[]) IS 'Compute MD5 ETAG from an array of text column values';

-- ============================================================================
-- Helper: aje_validate_annotations
-- ============================================================================

CREATE OR REPLACE FUNCTION aje.validate_annotations(
    ann jsonb
)
RETURNS boolean
LANGUAGE plpgsql
IMMUTABLE
AS $func$
DECLARE
    valid_keys text[] := ARRAY['insert','update','delete','check','noinsert','noupdate','nodelete','nocheck'];
    key text;
BEGIN
    IF ann IS NULL THEN RETURN true; END IF;
    FOR key IN SELECT jsonb_object_keys(ann)
    LOOP
        IF NOT (key = ANY(valid_keys)) THEN
            RAISE EXCEPTION 'Invalid annotation key: %', key;
        END IF;
    END LOOP;
    RETURN true;
END;
$func$;

-- ============================================================================
-- Helper: aje_parse_annotations
-- ============================================================================

CREATE OR REPLACE FUNCTION aje.parse_annotations(
    ann jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE
AS $func$
BEGIN
    IF ann IS NULL THEN
        RETURN '{"insert":false,"update":false,"delete":false,"check":true}'::jsonb;
    END IF;
    RETURN jsonb_build_object(
        'insert', COALESCE(ann->>'insert', 'false')::boolean
               AND NOT COALESCE(ann->>'noinsert', 'false')::boolean,
        'update', COALESCE(ann->>'update', 'false')::boolean
               AND NOT COALESCE(ann->>'noupdate', 'false')::boolean,
        'delete', COALESCE(ann->>'delete', 'false')::boolean
               AND NOT COALESCE(ann->>'nodelete', 'false')::boolean,
        'check', COALESCE(ann->>'check', 'true')::boolean
             AND NOT COALESCE(ann->>'nocheck', 'false')::boolean
    );
END;
$func$;

-- ============================================================================
-- Helper: aje_get_col_type — get the PostgreSQL type name for a column
-- ============================================================================

CREATE OR REPLACE FUNCTION aje.get_col_type(
    p_schema TEXT,
    p_table  TEXT,
    p_column TEXT
)
RETURNS TEXT
LANGUAGE sql
STABLE
AS $func$
    SELECT data_type
    FROM information_schema.columns
    WHERE table_schema = p_schema
      AND table_name = p_table
      AND column_name = p_column
    LIMIT 1;
$func$;

-- ============================================================================
-- aje_create_view — Create an AJE view
--
-- Registers view metadata, generates the VIEW with JSONB document output,
-- and creates INSTEAD OF INSERT/UPDATE/DELETE triggers.
-- ============================================================================

CREATE OR REPLACE FUNCTION aje.create_view(
    p_view_name        TEXT,
    p_root_table       TEXT,
    p_root_schema      TEXT DEFAULT 'public',
    p_root_alias       TEXT DEFAULT 'r',
    p_root_annotations JSONB DEFAULT '{"insert":true,"update":true,"delete":true}'::jsonb,
    p_fields           JSONB DEFAULT '[]'::jsonb
)
RETURNS TEXT
LANGUAGE plpgsql
VOLATILE
AS $func$
DECLARE
    v_view_id BIGINT;
    v_root_table_id BIGINT;
    v_field JSONB;
    v_nest RECORD;
    v_child_table_id BIGINT;
    v_col JSONB;
    v_rc RECORD;
    v_col_order INT;
    v_i INT;
    v_link_fk TEXT[];
    v_link_pk TEXT[];
    v_root_pk_cols TEXT[];
    v_child_pk_cols TEXT[];
    v_view_sql TEXT;
    v_select_parts TEXT;
    v_nested_select TEXT;
    v_etag_expr TEXT;
    v_pk_expr TEXT;
    v_nested_col_defs TEXT;
    v_nested_fk_where TEXT;
    v_first boolean;
    v_root_ann JSONB;
    v_child_ann JSONB;
    v_trig_func TEXT;
    v_root_ins_cols TEXT;
    v_root_ins_vals TEXT;
    v_root_upd_sets TEXT;
    v_nested_ins_cols TEXT;
    v_nested_ins_vals TEXT;
    v_nested_fk_assign TEXT;
BEGIN
    IF p_view_name IS NULL OR p_root_table IS NULL THEN
        RAISE EXCEPTION 'aje_create_view: view_name and root_table are required';
    END IF;

    IF EXISTS (SELECT 1 FROM aje_catalog.aje_views WHERE view_name = p_view_name) THEN
        RAISE EXCEPTION 'aje_create_view: view "%" already exists', p_view_name;
    END IF;

    PERFORM aje.validate_annotations(p_root_annotations);

    IF NOT EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = p_root_schema AND table_name = p_root_table
    ) THEN
        RAISE EXCEPTION 'aje_create_view: root table "%.%" does not exist', p_root_schema, p_root_table;
    END IF;

    SELECT array_agg(kcu.column_name ORDER BY kcu.ordinal_position)
    INTO v_root_pk_cols
    FROM information_schema.table_constraints tc
    JOIN information_schema.key_column_usage kcu
        ON tc.constraint_name = kcu.constraint_name
        AND tc.table_schema = kcu.table_schema
    WHERE tc.table_schema = p_root_schema
      AND tc.table_name = p_root_table
      AND tc.constraint_type = 'PRIMARY KEY';

    IF v_root_pk_cols IS NULL OR array_length(v_root_pk_cols, 1) = 0 THEN
        RAISE EXCEPTION 'aje_create_view: root table "%.%" must have a primary key', p_root_schema, p_root_table;
    END IF;

    v_root_ann := aje.parse_annotations(p_root_annotations);

    INSERT INTO aje_catalog.aje_views (view_name, root_table, root_schema, root_alias, root_annotations)
    VALUES (p_view_name, p_root_table, p_root_schema, p_root_alias, v_root_ann)
    RETURNING view_id INTO v_view_id;

    INSERT INTO aje_catalog.aje_view_tables (
        view_id, table_name, table_schema, table_alias,
        parent_table_id, nesting_type, nesting_depth, json_path, annotations
    ) VALUES (
        v_view_id, p_root_table, p_root_schema, p_root_alias,
        NULL, 'root', 0, '$', v_root_ann
    ) RETURNING table_id INTO v_root_table_id;

    -- Auto-detect root columns if p_fields is empty
    IF p_fields = '[]'::jsonb OR p_fields IS NULL THEN
        SELECT jsonb_agg(jsonb_build_object(
            'path', c.column_name,
            'column', c.column_name,
            'updatable', CASE WHEN c.column_name = ANY(v_root_pk_cols) THEN false ELSE true END,
            'check', true,
            'identifying', c.column_name = ANY(v_root_pk_cols)
        ) ORDER BY c.ordinal_position)
        INTO p_fields
        FROM information_schema.columns c
        WHERE c.table_schema = p_root_schema
          AND c.table_name = p_root_table
          AND c.is_updatable = 'YES';
    END IF;

    -- Process fields
    v_col_order := 0;
    FOR v_field IN SELECT * FROM jsonb_array_elements(p_fields)
    LOOP
        v_col_order := v_col_order + 1;

        IF v_field->>'type' IN ('nested_array', 'nested_object') THEN
            -- Nested table processing
            IF v_field->>'table' IS NULL THEN
                RAISE EXCEPTION 'aje_create_view: nested field "%" missing "table"', v_field->>'path';
            END IF;

            v_link_fk := ARRAY(SELECT jsonb_array_elements_text(v_field->'link'->'fk_columns'));
            v_link_pk := ARRAY(SELECT jsonb_array_elements_text(v_field->'link'->'pk_columns'));

            IF array_length(v_link_fk, 1) IS NULL OR array_length(v_link_fk, 1) <> array_length(v_link_pk, 1) THEN
                RAISE EXCEPTION 'aje_create_view: nested field "%" requires matching fk_columns and pk_columns', v_field->>'path';
            END IF;

            v_child_ann := aje.parse_annotations(
                COALESCE(v_field->'annotations', '{"insert":true,"update":true,"delete":true}'::jsonb)
            );

            INSERT INTO aje_catalog.aje_view_tables (
                view_id, table_name, table_schema, table_alias,
                parent_table_id, nesting_type, nesting_depth, json_path, annotations
            ) VALUES (
                v_view_id,
                v_field->>'table',
                COALESCE(v_field->>'schema', 'public'),
                COALESCE(v_field->>'alias', v_field->>'table'),
                v_root_table_id,
                COALESCE(v_field->>'type', 'nested_array'),
                1,
                v_field->>'path',
                v_child_ann
            ) RETURNING table_id INTO v_child_table_id;

            INSERT INTO aje_catalog.aje_view_links (view_id, child_table_id, parent_table_id, fk_columns, pk_columns)
            VALUES (v_view_id, v_child_table_id, v_root_table_id, v_link_fk, v_link_pk);

            -- Get child PK columns
            SELECT array_agg(kcu.column_name ORDER BY kcu.ordinal_position)
            INTO v_child_pk_cols
            FROM information_schema.table_constraints tc
            JOIN information_schema.key_column_usage kcu
                ON tc.constraint_name = kcu.constraint_name
                AND tc.table_schema = kcu.table_schema
            WHERE tc.table_schema = COALESCE(v_field->>'schema', 'public')
              AND tc.table_name = v_field->>'table'
              AND tc.constraint_type = 'PRIMARY KEY';

            IF v_child_pk_cols IS NULL OR array_length(v_child_pk_cols, 1) = 0 THEN
                RAISE EXCEPTION 'aje_create_view: nested table "%.%" must have a primary key',
                    COALESCE(v_field->>'schema', 'public'), v_field->>'table';
            END IF;

            -- Register nested columns
            IF v_field->'fields' IS NOT NULL THEN
                FOR v_col IN SELECT * FROM jsonb_array_elements(v_field->'fields')
                LOOP
                    INSERT INTO aje_catalog.aje_view_columns (
                        table_id, json_path, column_name, updatable, check_etag, is_identifying, column_order
                    ) VALUES (
                        v_child_table_id,
                        v_col->>'path',
                        COALESCE(v_col->>'column', v_col->>'path'),
                        COALESCE((v_col->>'updatable')::boolean, true),
                        COALESCE((v_col->>'check')::boolean, true),
                        COALESCE((v_col->>'identifying')::boolean,
                                 COALESCE(v_col->>'column', v_col->>'path') = ANY(v_child_pk_cols)),
                        0
                    );
                END LOOP;
            ELSE
                -- Auto-detect nested columns (exclude FK columns)
                FOR v_rc IN
                    SELECT jsonb_build_object(
                        'path', c.column_name,
                        'column', c.column_name,
                        'updatable', CASE WHEN c.column_name = ANY(v_child_pk_cols) THEN false ELSE true END,
                        'check', true,
                        'identifying', c.column_name = ANY(v_child_pk_cols)
                    ) AS col_def
                    FROM information_schema.columns c
                    WHERE c.table_schema = COALESCE(v_field->>'schema', 'public')
                      AND c.table_name = v_field->>'table'
                      AND c.is_updatable = 'YES'
                      AND c.column_name <> ALL(v_link_fk)
                LOOP
                    INSERT INTO aje_catalog.aje_view_columns (
                        table_id, json_path, column_name, updatable, check_etag, is_identifying, column_order
                    ) VALUES (
                        v_child_table_id,
                        v_col->>'path',
                        v_col->>'column',
                        COALESCE((v_col->>'updatable')::boolean, true),
                        COALESCE((v_col->>'check')::boolean, true),
                        COALESCE((v_col->>'identifying')::boolean, false),
                        0
                    );
                END LOOP;
            END IF;

            -- Register FK link columns as identifying (hidden, for triggers)
            FOR v_i IN 1..array_length(v_link_fk, 1)
            LOOP
                INSERT INTO aje_catalog.aje_view_columns (
                    table_id, json_path, column_name, updatable, check_etag, is_identifying, column_order
                ) VALUES (v_child_table_id, '_link_' || v_link_fk[v_i], v_link_fk[v_i], false, false, true, 0);
            END LOOP;

            -- Register child PK columns that are NOT FK columns AND NOT IDENTITY
            FOR v_i IN 1..array_length(v_child_pk_cols, 1)
            LOOP
                IF NOT (v_child_pk_cols[v_i] = ANY(v_link_fk)) THEN
                    IF NOT EXISTS (
                        SELECT 1 FROM information_schema.columns
                        WHERE table_schema = COALESCE(v_field->>'schema', 'public')
                          AND table_name = v_field->>'table'
                          AND column_name = v_child_pk_cols[v_i]
                          AND is_identity = 'YES'
                    ) THEN
                        INSERT INTO aje_catalog.aje_view_columns (
                            table_id, json_path, column_name, updatable, check_etag, is_identifying, column_order
                        ) VALUES (v_child_table_id, '_cpk_' || v_child_pk_cols[v_i], v_child_pk_cols[v_i], false, false, true, 0);
                    END IF;
                END IF;
            END LOOP;
        ELSE
            -- Root-level scalar field
            INSERT INTO aje_catalog.aje_view_columns (
                table_id, json_path, column_name, updatable, check_etag, is_identifying, column_order
            ) VALUES (
                v_root_table_id,
                v_field->>'path',
                COALESCE(v_field->>'column', v_field->>'path'),
                COALESCE((v_field->>'updatable')::boolean, true),
                COALESCE((v_field->>'check')::boolean, true),
                COALESCE((v_field->>'identifying')::boolean,
                         COALESCE(v_field->>'column', v_field->>'path') = ANY(v_root_pk_cols)),
                v_col_order
            );
        END IF;
    END LOOP;

    -- ========================================================================
    -- Generate the VIEW SQL
    -- ========================================================================

    v_select_parts := '';
    v_first := true;
    FOR v_rc IN
        SELECT vc.json_path, vc.column_name, vt.table_alias
        FROM aje_catalog.aje_view_columns vc
        JOIN aje_catalog.aje_view_tables vt ON vc.table_id = vt.table_id
        WHERE vt.view_id = v_view_id
          AND vt.nesting_type = 'root'
          AND vc.json_path NOT LIKE '_link_%'
        ORDER BY vc.column_order
    LOOP
        IF v_first THEN v_first := false; ELSE v_select_parts := v_select_parts || ', '; END IF;
        v_select_parts := v_select_parts || format('%L, %I.%I', v_rc.json_path, v_rc.table_alias, v_rc.column_name);
    END LOOP;

    -- ETAG expression: hash of check-annotated columns + xmin
    SELECT string_agg(format('%I.%I::text', p_root_alias, vc.column_name), ', ')
    INTO v_etag_expr
    FROM aje_catalog.aje_view_columns vc
    JOIN aje_catalog.aje_view_tables vt ON vc.table_id = vt.table_id
    WHERE vt.view_id = v_view_id
      AND vt.nesting_type = 'root'
      AND vc.check_etag = true
      AND vc.json_path NOT LIKE '_link_%';

    v_etag_expr := COALESCE(v_etag_expr || ', ', '') || format('%I.xmin::text', p_root_alias);

    -- Build _id expression
    IF array_length(v_root_pk_cols, 1) = 1 THEN
        v_pk_expr := format('%L, %I.%I', '_id', p_root_alias, v_root_pk_cols[1]);
    ELSE
        v_pk_expr := '';
        v_first := true;
        FOR v_i IN 1..array_length(v_root_pk_cols, 1)
        LOOP
            IF v_first THEN v_first := false; ELSE v_pk_expr := v_pk_expr || ', '; END IF;
            v_pk_expr := v_pk_expr || format('%L, %I.%I', v_root_pk_cols[v_i], p_root_alias, v_root_pk_cols[v_i]);
        END LOOP;
        v_pk_expr := format('%L, jsonb_build_object(%s)', '_id', v_pk_expr);
    END IF;

    v_view_sql := format('CREATE OR REPLACE VIEW %I AS SELECT jsonb_build_object(', p_view_name);
    v_view_sql := v_view_sql || v_pk_expr || ', ' || v_select_parts || ', ';
    v_view_sql := v_view_sql || format(
        '%L, jsonb_build_object(%L, aje.compute_etag(ARRAY[%s]), %L, %I.xmin)',
        '_metadata', 'etag', v_etag_expr, 'xmin', p_root_alias
    );

    -- Add nested subqueries
    FOR v_nest IN
        SELECT vt.table_id, vt.table_name, vt.table_schema, vt.table_alias,
               vt.json_path AS nest_path, vt.nesting_type,
               vl.fk_columns, vl.pk_columns
        FROM aje_catalog.aje_view_tables vt
        JOIN aje_catalog.aje_view_links vl ON vl.child_table_id = vt.table_id
        WHERE vt.view_id = v_view_id
          AND vt.nesting_type IN ('nested_array', 'nested_object')
    LOOP
        SELECT array_agg(kcu.column_name ORDER BY kcu.ordinal_position)
        INTO v_child_pk_cols
        FROM information_schema.table_constraints tc
        JOIN information_schema.key_column_usage kcu
            ON tc.constraint_name = kcu.constraint_name
            AND tc.table_schema = kcu.table_schema
        WHERE tc.table_schema = v_nest.table_schema
          AND tc.table_name = v_nest.table_name
          AND tc.constraint_type = 'PRIMARY KEY';

        v_nested_col_defs := '';
        v_first := true;
        FOR v_rc IN
             SELECT vc.json_path, vc.column_name,
                   CASE WHEN vc.json_path LIKE '_cpk_%' THEN vc.column_name ELSE vc.json_path END AS output_path
            FROM aje_catalog.aje_view_columns vc
            WHERE vc.table_id = v_nest.table_id
              AND vc.json_path NOT LIKE '_link_%'
            ORDER BY vc.column_order
        LOOP
            IF v_first THEN v_first := false; ELSE v_nested_col_defs := v_nested_col_defs || ', '; END IF;
            v_nested_col_defs := v_nested_col_defs || format('%L, %I.%I', v_rc.output_path, v_nest.table_alias, v_rc.column_name);
        END LOOP;

        v_nested_fk_where := '';
        FOR v_i IN 1..array_length(v_nest.fk_columns, 1)
        LOOP
            IF v_i > 1 THEN v_nested_fk_where := v_nested_fk_where || ' AND '; END IF;
            v_nested_fk_where := v_nested_fk_where || format('%I.%I = %I.%I',
                v_nest.table_alias, v_nest.fk_columns[v_i],
                p_root_alias, v_nest.pk_columns[v_i]);
        END LOOP;

        IF v_nest.nesting_type = 'nested_array' THEN
            v_nested_select := format(
                '%L, COALESCE((SELECT jsonb_agg(jsonb_build_object(%s) ORDER BY %I.%I) FROM %I.%I %I WHERE %s), ''[]''::jsonb)',
                v_nest.nest_path,
                v_nested_col_defs,
                v_nest.table_alias, v_child_pk_cols[1],
                v_nest.table_schema, v_nest.table_name, v_nest.table_alias,
                v_nested_fk_where
            );
        ELSE
            v_nested_select := format(
                '%L, (SELECT jsonb_build_object(%s) FROM %I.%I %I WHERE %s LIMIT 1)',
                v_nest.nest_path,
                v_nested_col_defs,
                v_nest.table_schema, v_nest.table_name, v_nest.table_alias,
                v_nested_fk_where
            );
        END IF;

        v_view_sql := v_view_sql || ', ' || v_nested_select;
    END LOOP;

    v_view_sql := v_view_sql || format(') AS data FROM %I.%I %I',
        p_root_schema, p_root_table, p_root_alias);

    EXECUTE v_view_sql;

    -- ========================================================================
    -- Generate INSTEAD OF INSERT trigger function
    -- ========================================================================

    v_root_ins_cols := '';
    v_root_ins_vals := '';
    v_first := true;

    -- Add PK columns first for non-IDENTITY PKs (extract from _id)
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = p_root_schema AND table_name = p_root_table
          AND column_name = v_root_pk_cols[1] AND is_identity = 'YES'
    ) THEN
        IF array_length(v_root_pk_cols, 1) = 1 THEN
            v_root_ins_cols := format('%I', v_root_pk_cols[1]);
            v_root_ins_vals := format('(NEW.data->>''_id'')::%s',
                aje.get_col_type(p_root_schema, p_root_table, v_root_pk_cols[1]));
        ELSE
            FOR v_i IN 1..array_length(v_root_pk_cols, 1)
            LOOP
                IF v_i > 1 THEN
                    v_root_ins_cols := v_root_ins_cols || ', ';
                    v_root_ins_vals := v_root_ins_vals || ', ';
                END IF;
                v_root_ins_cols := v_root_ins_cols || format('%I', v_root_pk_cols[v_i]);
                v_root_ins_vals := v_root_ins_vals || format('(NEW.data->''_id''->>%L)::%s',
                    v_root_pk_cols[v_i], aje.get_col_type(p_root_schema, p_root_table, v_root_pk_cols[v_i]));
            END LOOP;
        END IF;
        v_first := false;
    END IF;

    FOR v_rc IN
        SELECT vc.json_path, vc.column_name, vc.is_identifying, vc.check_etag,
               EXISTS(SELECT 1 FROM information_schema.columns c
                      WHERE c.table_schema = p_root_schema AND c.table_name = p_root_table
                        AND c.column_name = vc.column_name AND c.is_identity = 'YES') AS is_identity_col
        FROM aje_catalog.aje_view_columns vc
        JOIN aje_catalog.aje_view_tables vt ON vc.table_id = vt.table_id
        WHERE vt.view_id = v_view_id
          AND vt.nesting_type = 'root'
          AND vc.json_path NOT LIKE '_link_%'
        ORDER BY vc.column_order
    LOOP
        IF v_rc.is_identity_col THEN
            CONTINUE;
        END IF;
        IF v_first THEN v_first := false; ELSE
            v_root_ins_cols := v_root_ins_cols || ', ';
            v_root_ins_vals := v_root_ins_vals || ', ';
        END IF;
        v_root_ins_cols := v_root_ins_cols || format('%I', v_rc.column_name);
        IF v_rc.is_identifying THEN
            IF array_length(v_root_pk_cols, 1) = 1 THEN
                v_root_ins_vals := v_root_ins_vals || format('(NEW.data->>''_id'')::%s',
                    aje.get_col_type(p_root_schema, p_root_table, v_rc.column_name));
            ELSE
                v_root_ins_vals := v_root_ins_vals || format('(NEW.data->''_id''->>%L)::%s',
                    v_rc.column_name, aje.get_col_type(p_root_schema, p_root_table, v_rc.column_name));
            END IF;
        ELSE
            v_root_ins_vals := v_root_ins_vals || format('(NEW.data->>%L)::%s',
                v_rc.json_path, aje.get_col_type(p_root_schema, p_root_table, v_rc.column_name));
        END IF;
    END LOOP;

    v_trig_func := format(
        'CREATE OR REPLACE FUNCTION _aje_%s_insert() RETURNS trigger LANGUAGE plpgsql AS $trig$ DECLARE v_root_id ' || CASE WHEN array_length(v_root_pk_cols, 1) > 1 THEN 'text' WHEN (SELECT data_type FROM information_schema.columns WHERE table_schema = p_root_schema AND table_name = p_root_table AND column_name = v_root_pk_cols[1]) = 'bigint' THEN 'bigint' ELSE 'text' END || '; v_elem jsonb; BEGIN ',
        p_view_name
    );

    IF (v_root_ann->>'insert')::boolean THEN
        IF EXISTS (
            SELECT 1 FROM information_schema.columns
            WHERE table_schema = p_root_schema AND table_name = p_root_table
              AND column_name = v_root_pk_cols[1] AND is_identity = 'YES'
        ) THEN
            v_trig_func := v_trig_func || format(
                'INSERT INTO %I.%I (%s) VALUES (%s) RETURNING %I INTO v_root_id; ',
                p_root_schema, p_root_table, v_root_ins_cols, v_root_ins_vals, v_root_pk_cols[1]
            );
        ELSE
            v_trig_func := v_trig_func || format(
                'INSERT INTO %I.%I (%s) VALUES (%s); ',
                p_root_schema, p_root_table, v_root_ins_cols, v_root_ins_vals
            );
            IF array_length(v_root_pk_cols, 1) = 1 THEN
                v_trig_func := v_trig_func || 'v_root_id := NEW.data->>''_id''; ';
            ELSE
                v_trig_func := v_trig_func || 'v_root_id := NEW.data->>''_id''; ';
            END IF;
        END IF;
    ELSE
        v_trig_func := v_trig_func || 'RAISE EXCEPTION ''aje_insert_blocked: insert is not allowed on this view''; ';
    END IF;

    -- Nested inserts
    FOR v_nest IN
        SELECT vt.table_id, vt.table_name, vt.table_schema, vt.table_alias,
               vt.json_path AS nest_path, vt.annotations AS nest_ann,
               vl.fk_columns, vl.pk_columns
        FROM aje_catalog.aje_view_tables vt
        JOIN aje_catalog.aje_view_links vl ON vl.child_table_id = vt.table_id
        WHERE vt.view_id = v_view_id
          AND vt.nesting_type IN ('nested_array', 'nested_object')
    LOOP
        IF (v_nest.nest_ann->>'insert')::boolean THEN
            v_nested_ins_cols := '';
            v_nested_ins_vals := '';
            v_nested_fk_assign := '';
            v_first := true;

             FOR v_rc IN
                SELECT vc.json_path, vc.column_name, vc.is_identifying
                FROM aje_catalog.aje_view_columns vc
                WHERE vc.table_id = v_nest.table_id
                  AND vc.json_path NOT LIKE '_link_%'
                ORDER BY vc.column_order
            LOOP
                IF v_first THEN v_first := false; ELSE
                    v_nested_ins_cols := v_nested_ins_cols || ', ';
                    v_nested_ins_vals := v_nested_ins_vals || ', ';
                END IF;
                v_nested_ins_cols := v_nested_ins_cols || format('%I', v_rc.column_name);
                IF v_rc.json_path LIKE '_cpk_%' THEN
                    v_nested_ins_vals := v_nested_ins_vals || format('(v_elem->>%L)::%s',
                        v_rc.column_name, aje.get_col_type(v_nest.table_schema, v_nest.table_name, v_rc.column_name));
                ELSE
                    v_nested_ins_vals := v_nested_ins_vals || format('(v_elem->>%L)::%s',
                        v_rc.json_path, aje.get_col_type(v_nest.table_schema, v_nest.table_name, v_rc.column_name));
                END IF;
            END LOOP;

            -- Add FK columns with values from root PK
            FOR v_i IN 1..array_length(v_nest.fk_columns, 1)
            LOOP
                IF v_first THEN v_first := false; ELSE
                    v_nested_ins_cols := v_nested_ins_cols || ', ';
                    v_nested_ins_vals := v_nested_ins_vals || ', ';
                END IF;
                v_nested_ins_cols := v_nested_ins_cols || format('%I', v_nest.fk_columns[v_i]);
                IF array_length(v_root_pk_cols, 1) = 1 THEN
                    v_nested_ins_vals := v_nested_ins_vals || 'v_root_id';
                ELSE
                    v_nested_ins_vals := v_nested_ins_vals || format('(NEW.data->''_id''->>%L)::%s',
                        v_nest.pk_columns[v_i], aje.get_col_type(v_nest.table_schema, v_nest.table_name, v_nest.fk_columns[v_i]));
                END IF;
            END LOOP;

            v_trig_func := v_trig_func || format(
                'FOR v_elem IN SELECT jsonb_array_elements(COALESCE(NEW.data->%L, ''[]''::jsonb)) LOOP ' ||
                'INSERT INTO %I.%I (%s) VALUES (%s); END LOOP; ',
                v_nest.nest_path,
                v_nest.table_schema, v_nest.table_name,
                v_nested_ins_cols, v_nested_ins_vals
            );
        END IF;
    END LOOP;

    v_trig_func := v_trig_func || 'RETURN NEW; END; $trig$;';
    EXECUTE v_trig_func;

    -- Create the INSERT trigger
    EXECUTE format(
        'CREATE TRIGGER _aje_%s_insert INSTEAD OF INSERT ON %I FOR EACH ROW EXECUTE FUNCTION _aje_%s_insert()',
        p_view_name, p_view_name, p_view_name
    );

    -- ========================================================================
    -- Generate INSTEAD OF UPDATE trigger function
    -- ========================================================================

    v_root_upd_sets := '';
    v_first := true;

    FOR v_rc IN
        SELECT vc.json_path, vc.column_name, vc.updatable, vc.is_identifying
        FROM aje_catalog.aje_view_columns vc
        JOIN aje_catalog.aje_view_tables vt ON vc.table_id = vt.table_id
        WHERE vt.view_id = v_view_id
          AND vt.nesting_type = 'root'
          AND vc.json_path NOT LIKE '_link_%'
          AND vc.updatable = true
          AND NOT vc.is_identifying
        ORDER BY vc.column_order
    LOOP
        IF v_first THEN v_first := false; ELSE v_root_upd_sets := v_root_upd_sets || ', '; END IF;
        v_root_upd_sets := v_root_upd_sets || format('%I = (NEW.data->>%L)::%s',
            v_rc.column_name, v_rc.json_path,
            aje.get_col_type(p_root_schema, p_root_table, v_rc.column_name));
    END LOOP;

    v_trig_func := format(
        'CREATE OR REPLACE FUNCTION _aje_%s_update() RETURNS trigger LANGUAGE plpgsql AS $trig$ DECLARE v_expected_etag text; v_current_etag text; v_root_id ' || CASE WHEN array_length(v_root_pk_cols, 1) > 1 THEN 'text' WHEN (SELECT data_type FROM information_schema.columns WHERE table_schema = p_root_schema AND table_name = p_root_table AND column_name = v_root_pk_cols[1]) = 'bigint' THEN 'bigint' ELSE 'text' END || '; v_elem jsonb; BEGIN ',
        p_view_name
    );

    -- Annotation check (must be before ETAG check to avoid type cast errors on readonly views)
    IF NOT (v_root_ann->>'update')::boolean THEN
        v_trig_func := v_trig_func || 'RAISE EXCEPTION ''aje_update_blocked: update is not allowed on this view''; ';
    ELSE
        -- ETAG check + root ID extraction
        IF array_length(v_root_pk_cols, 1) = 1 THEN
            v_trig_func := v_trig_func || format(
                'v_root_id := (OLD.data->>''_id'')::%s; ' ||
                'v_expected_etag := OLD.data->''_metadata''->>''etag''; ' ||
                'SELECT aje.compute_etag(ARRAY[%s, (SELECT xmin::text FROM %I.%I WHERE %I = v_root_id)]) INTO v_current_etag FROM %I.%I WHERE %I = v_root_id; ' ||
                'IF v_expected_etag IS NOT NULL AND v_current_etag <> v_expected_etag THEN ' ||
                'RAISE EXCEPTION ''aje_etag_mismatch: document %% has been modified'', v_root_id; END IF; ',
                CASE WHEN (SELECT data_type FROM information_schema.columns WHERE table_schema = p_root_schema AND table_name = p_root_table AND column_name = v_root_pk_cols[1]) = 'bigint' THEN 'bigint' ELSE 'text' END,
                (SELECT string_agg(format('%I::text', vc.column_name), ', ')
                 FROM aje_catalog.aje_view_columns vc
                 JOIN aje_catalog.aje_view_tables vt ON vc.table_id = vt.table_id
                 WHERE vt.view_id = v_view_id AND vt.nesting_type = 'root'
                   AND vc.check_etag = true AND vc.json_path NOT LIKE '_link_%' AND vc.json_path NOT LIKE '_cpk_%'),
                p_root_schema, p_root_table, v_root_pk_cols[1],
                p_root_schema, p_root_table, v_root_pk_cols[1]
            );
        ELSE
            v_trig_func := v_trig_func || format(
                'v_root_id := OLD.data->>''_id''; ' ||
                'v_expected_etag := OLD.data->''_metadata''->>''etag''; ' ||
                'SELECT aje.compute_etag(ARRAY[%s, (SELECT xmin::text FROM %I.%I WHERE %s)]) INTO v_current_etag FROM %I.%I WHERE %s; ' ||
                'IF v_expected_etag IS NOT NULL AND v_current_etag <> v_expected_etag THEN ' ||
                'RAISE EXCEPTION ''aje_etag_mismatch: document %% has been modified'', v_root_id; END IF; ',
                (SELECT string_agg(format('%I::text', vc.column_name), ', ')
                 FROM aje_catalog.aje_view_columns vc
                 JOIN aje_catalog.aje_view_tables vt ON vc.table_id = vt.table_id
                 WHERE vt.view_id = v_view_id AND vt.nesting_type = 'root'
                   AND vc.check_etag = true AND vc.json_path NOT LIKE '_link_%' AND vc.json_path NOT LIKE '_cpk_%'),
                p_root_schema, p_root_table,
                (SELECT string_agg(format('%I = (OLD.data->''_id''->>%L)::%s', kcu.column_name, kcu.column_name,
                    aje.get_col_type(p_root_schema, p_root_table, kcu.column_name)), ' AND ')
                 FROM information_schema.table_constraints tc
                 JOIN information_schema.key_column_usage kcu
                     ON tc.constraint_name = kcu.constraint_name AND tc.table_schema = kcu.table_schema
                 WHERE tc.table_schema = p_root_schema AND tc.table_name = p_root_table
                   AND tc.constraint_type = 'PRIMARY KEY'),
                p_root_schema, p_root_table,
                (SELECT string_agg(format('%I = (OLD.data->''_id''->>%L)::%s', kcu.column_name, kcu.column_name,
                    aje.get_col_type(p_root_schema, p_root_table, kcu.column_name)), ' AND ')
                 FROM information_schema.table_constraints tc
                 JOIN information_schema.key_column_usage kcu
                     ON tc.constraint_name = kcu.constraint_name AND tc.table_schema = kcu.table_schema
                 WHERE tc.table_schema = p_root_schema AND tc.table_name = p_root_table
                   AND tc.constraint_type = 'PRIMARY KEY')
            );
        END IF;

        IF v_root_upd_sets <> '' THEN
            IF array_length(v_root_pk_cols, 1) = 1 THEN
                v_trig_func := v_trig_func || format(
                    'UPDATE %I.%I SET %s WHERE %I = v_root_id; ',
                    p_root_schema, p_root_table, v_root_upd_sets, v_root_pk_cols[1]
                );
            ELSE
                v_trig_func := v_trig_func || format(
                    'UPDATE %I.%I SET %s WHERE %s; ',
                    p_root_schema, p_root_table, v_root_upd_sets,
                    (SELECT string_agg(format('%I = (OLD.data->''_id''->>%L)::%s', kcu.column_name, kcu.column_name,
                        aje.get_col_type(p_root_schema, p_root_table, kcu.column_name)), ' AND ')
                     FROM information_schema.table_constraints tc
                     JOIN information_schema.key_column_usage kcu
                         ON tc.constraint_name = kcu.constraint_name AND tc.table_schema = kcu.table_schema
                     WHERE tc.table_schema = p_root_schema AND tc.table_name = p_root_table
                       AND tc.constraint_type = 'PRIMARY KEY')
                );
            END IF;
        END IF;
    END IF;

    -- Nested updates: delete-and-reinsert strategy
    FOR v_nest IN
        SELECT vt.table_id, vt.table_name, vt.table_schema, vt.table_alias,
               vt.json_path AS nest_path, vt.annotations AS nest_ann,
               vl.fk_columns, vl.pk_columns
        FROM aje_catalog.aje_view_tables vt
        JOIN aje_catalog.aje_view_links vl ON vl.child_table_id = vt.table_id
        WHERE vt.view_id = v_view_id
          AND vt.nesting_type IN ('nested_array', 'nested_object')
    LOOP
        IF (v_nest.nest_ann->>'update')::boolean THEN
            v_nested_ins_cols := '';
            v_nested_ins_vals := '';
            v_first := true;

             FOR v_rc IN
                SELECT vc.json_path, vc.column_name, vc.is_identifying
                FROM aje_catalog.aje_view_columns vc
                WHERE vc.table_id = v_nest.table_id
                  AND vc.json_path NOT LIKE '_link_%'
                ORDER BY vc.column_order
            LOOP
                IF v_first THEN v_first := false; ELSE
                    v_nested_ins_cols := v_nested_ins_cols || ', ';
                    v_nested_ins_vals := v_nested_ins_vals || ', ';
                END IF;
                v_nested_ins_cols := v_nested_ins_cols || format('%I', v_rc.column_name);
                IF v_rc.json_path LIKE '_cpk_%' THEN
                    v_nested_ins_vals := v_nested_ins_vals || format('(v_elem->>%L)::%s',
                        v_rc.column_name, aje.get_col_type(v_nest.table_schema, v_nest.table_name, v_rc.column_name));
                ELSE
                    v_nested_ins_vals := v_nested_ins_vals || format('(v_elem->>%L)::%s',
                        v_rc.json_path, aje.get_col_type(v_nest.table_schema, v_nest.table_name, v_rc.column_name));
                END IF;
            END LOOP;

            -- Add FK columns with values from root PK
            FOR v_i IN 1..array_length(v_nest.fk_columns, 1)
            LOOP
                IF v_first THEN v_first := false; ELSE
                    v_nested_ins_cols := v_nested_ins_cols || ', ';
                    v_nested_ins_vals := v_nested_ins_vals || ', ';
                END IF;
                v_nested_ins_cols := v_nested_ins_cols || format('%I', v_nest.fk_columns[v_i]);
                IF array_length(v_root_pk_cols, 1) = 1 THEN
                    v_nested_ins_vals := v_nested_ins_vals || 'v_root_id';
                ELSE
                    v_nested_ins_vals := v_nested_ins_vals || format('(NEW.data->''_id''->>%L)::%s',
                        v_nest.pk_columns[v_i], aje.get_col_type(v_nest.table_schema, v_nest.table_name, v_nest.fk_columns[v_i]));
                END IF;
            END LOOP;

            v_trig_func := v_trig_func || format(
                'DELETE FROM %I.%I WHERE %s; ' ||
                'FOR v_elem IN SELECT jsonb_array_elements(COALESCE(NEW.data->%L, ''[]''::jsonb)) LOOP ' ||
                'INSERT INTO %I.%I (%s) VALUES (%s); END LOOP; ',
                v_nest.table_schema, v_nest.table_name,
                CASE WHEN array_length(v_nest.fk_columns, 1) = 1 THEN
                    format('%I = v_root_id', v_nest.fk_columns[1])
                ELSE
                    (SELECT string_agg(format('%I = (NEW.data->''_id''->>%L)::%s',
                        v_nest.fk_columns[g], v_nest.pk_columns[g],
                        aje.get_col_type(v_nest.table_schema, v_nest.table_name, v_nest.fk_columns[g])), ' AND ')
                     FROM generate_series(1, array_length(v_nest.fk_columns, 1)) g)
                END,
                v_nest.nest_path,
                v_nest.table_schema, v_nest.table_name,
                v_nested_ins_cols, v_nested_ins_vals
            );
        END IF;
    END LOOP;

    v_trig_func := v_trig_func || 'RETURN NEW; END; $trig$;';
    EXECUTE v_trig_func;

    EXECUTE format(
        'CREATE TRIGGER _aje_%s_update INSTEAD OF UPDATE ON %I FOR EACH ROW EXECUTE FUNCTION _aje_%s_update()',
        p_view_name, p_view_name, p_view_name
    );

    -- ========================================================================
    -- Generate INSTEAD OF DELETE trigger function
    -- ========================================================================

    v_trig_func := format(
        'CREATE OR REPLACE FUNCTION _aje_%s_delete() RETURNS trigger LANGUAGE plpgsql AS $trig$ DECLARE v_root_id ' || CASE WHEN array_length(v_root_pk_cols, 1) > 1 THEN 'text' WHEN (SELECT data_type FROM information_schema.columns WHERE table_schema = p_root_schema AND table_name = p_root_table AND column_name = v_root_pk_cols[1]) = 'bigint' THEN 'bigint' ELSE 'text' END || '; v_expected_etag text; v_current_etag text; BEGIN ',
        p_view_name
    );

    IF NOT (v_root_ann->>'delete')::boolean THEN
        v_trig_func := v_trig_func || 'RAISE EXCEPTION ''aje_delete_blocked: delete is not allowed on this view''; ';
    ELSE
        -- ETAG check + root ID extraction
        IF array_length(v_root_pk_cols, 1) = 1 THEN
            v_trig_func := v_trig_func || format(
                'v_root_id := (OLD.data->>''_id'')::%s; ' ||
                'v_expected_etag := OLD.data->''_metadata''->>''etag''; ' ||
                'SELECT aje.compute_etag(ARRAY[%s, (SELECT xmin::text FROM %I.%I WHERE %I = v_root_id)]) INTO v_current_etag FROM %I.%I WHERE %I = v_root_id; ' ||
                'IF v_expected_etag IS NOT NULL AND v_current_etag <> v_expected_etag THEN ' ||
                'RAISE EXCEPTION ''aje_etag_mismatch: document %% has been modified'', v_root_id; END IF; ',
                CASE WHEN (SELECT data_type FROM information_schema.columns WHERE table_schema = p_root_schema AND table_name = p_root_table AND column_name = v_root_pk_cols[1]) = 'bigint' THEN 'bigint' ELSE 'text' END,
                (SELECT string_agg(format('%I::text', vc.column_name), ', ')
                 FROM aje_catalog.aje_view_columns vc
                 JOIN aje_catalog.aje_view_tables vt ON vc.table_id = vt.table_id
                 WHERE vt.view_id = v_view_id AND vt.nesting_type = 'root'
                   AND vc.check_etag = true AND vc.json_path NOT LIKE '_link_%' AND vc.json_path NOT LIKE '_cpk_%'),
                p_root_schema, p_root_table, v_root_pk_cols[1],
                p_root_schema, p_root_table, v_root_pk_cols[1]
            );
        ELSE
            v_trig_func := v_trig_func || format(
                'v_root_id := OLD.data->>''_id''; ' ||
                'v_expected_etag := OLD.data->''_metadata''->>''etag''; ' ||
                'SELECT aje.compute_etag(ARRAY[%s, (SELECT xmin::text FROM %I.%I WHERE %s)]) INTO v_current_etag FROM %I.%I WHERE %s; ' ||
                'IF v_expected_etag IS NOT NULL AND v_current_etag <> v_expected_etag THEN ' ||
                'RAISE EXCEPTION ''aje_etag_mismatch: document %% has been modified'', v_root_id; END IF; ',
                (SELECT string_agg(format('%I::text', vc.column_name), ', ')
                 FROM aje_catalog.aje_view_columns vc
                 JOIN aje_catalog.aje_view_tables vt ON vc.table_id = vt.table_id
                 WHERE vt.view_id = v_view_id AND vt.nesting_type = 'root'
                   AND vc.check_etag = true AND vc.json_path NOT LIKE '_link_%' AND vc.json_path NOT LIKE '_cpk_%'),
                p_root_schema, p_root_table,
                (SELECT string_agg(format('%I = (OLD.data->''_id''->>%L)::%s', kcu.column_name, kcu.column_name,
                    aje.get_col_type(p_root_schema, p_root_table, kcu.column_name)), ' AND ')
                 FROM information_schema.table_constraints tc
                 JOIN information_schema.key_column_usage kcu
                     ON tc.constraint_name = kcu.constraint_name AND tc.table_schema = kcu.table_schema
                 WHERE tc.table_schema = p_root_schema AND tc.table_name = p_root_table
                   AND tc.constraint_type = 'PRIMARY KEY'),
                p_root_schema, p_root_table,
                (SELECT string_agg(format('%I = (OLD.data->''_id''->>%L)::%s', kcu.column_name, kcu.column_name,
                    aje.get_col_type(p_root_schema, p_root_table, kcu.column_name)), ' AND ')
                 FROM information_schema.table_constraints tc
                 JOIN information_schema.key_column_usage kcu
                     ON tc.constraint_name = kcu.constraint_name AND tc.table_schema = kcu.table_schema
                 WHERE tc.table_schema = p_root_schema AND tc.table_name = p_root_table
                   AND tc.constraint_type = 'PRIMARY KEY')
            );
        END IF;

         -- Handle nested children BEFORE root delete (FK constraint order)
         FOR v_nest IN
             SELECT vt.table_id, vt.table_name, vt.table_schema, vt.table_alias,
                    vt.json_path AS nest_path, vt.annotations AS nest_ann,
                    vl.fk_columns, vl.pk_columns
             FROM aje_catalog.aje_view_tables vt
             JOIN aje_catalog.aje_view_links vl ON vl.child_table_id = vt.table_id
             WHERE vt.view_id = v_view_id
               AND vt.nesting_type IN ('nested_array', 'nested_object')
         LOOP
             IF (v_nest.nest_ann->>'delete')::boolean THEN
                 IF array_length(v_nest.fk_columns, 1) = 1 THEN
                     v_trig_func := v_trig_func || format(
                         'DELETE FROM %I.%I WHERE %I = v_root_id; ',
                         v_nest.table_schema, v_nest.table_name, v_nest.fk_columns[1]
                     );
                 ELSE
                     v_trig_func := v_trig_func || format(
                         'DELETE FROM %I.%I WHERE %s; ',
                         v_nest.table_schema, v_nest.table_name,
                         (SELECT string_agg(format('%I = (OLD.data->''_id''->>%L)::%s',
                             v_nest.fk_columns[g], v_nest.pk_columns[g],
                             aje.get_col_type(v_nest.table_schema, v_nest.table_name, v_nest.fk_columns[g])), ' AND ')
                          FROM generate_series(1, array_length(v_nest.fk_columns, 1)) g)
                     );
                 END IF;
ELSE
                  -- nodelete: set FK to NULL (orphan children)
                  IF array_length(v_nest.fk_columns, 1) = 1 THEN
                      v_trig_func := v_trig_func || format(
                          'UPDATE %I.%I SET %I = NULL WHERE %I = v_root_id; ',
                          v_nest.table_schema, v_nest.table_name,
                          v_nest.fk_columns[1], v_nest.fk_columns[1]
                      );
                  ELSE
                      FOR v_i IN 1..array_length(v_nest.fk_columns, 1)
                      LOOP
                          v_trig_func := v_trig_func || format(
                              'UPDATE %I.%I SET %I = NULL WHERE %s; ',
                              v_nest.table_schema, v_nest.table_name,
                              v_nest.fk_columns[v_i],
                              (SELECT string_agg(format('%I = (OLD.data->''_id''->>%L)::%s',
                                  v_nest.fk_columns[g], v_nest.pk_columns[g],
                                  aje.get_col_type(v_nest.table_schema, v_nest.table_name, v_nest.fk_columns[g])), ' AND ')
                               FROM generate_series(1, array_length(v_nest.fk_columns, 1)) g)
                          );
                      END LOOP;
                  END IF;
             END IF;
         END LOOP;

         -- Root delete
         IF array_length(v_root_pk_cols, 1) = 1 THEN
            v_trig_func := v_trig_func || format(
                'DELETE FROM %I.%I WHERE %I = v_root_id; ',
                p_root_schema, p_root_table, v_root_pk_cols[1]
            );
        ELSE
            v_trig_func := v_trig_func || format(
                'DELETE FROM %I.%I WHERE %s; ',
                p_root_schema, p_root_table,
                (SELECT string_agg(format('%I = (OLD.data->''_id''->>%L)::%s', kcu.column_name, kcu.column_name,
                    aje.get_col_type(p_root_schema, p_root_table, kcu.column_name)), ' AND ')
                 FROM information_schema.table_constraints tc
                 JOIN information_schema.key_column_usage kcu
                     ON tc.constraint_name = kcu.constraint_name AND tc.table_schema = kcu.table_schema
                 WHERE tc.table_schema = p_root_schema AND tc.table_name = p_root_table
                   AND tc.constraint_type = 'PRIMARY KEY')
            );
         END IF;
     END IF;

    v_trig_func := v_trig_func || 'RETURN OLD; END; $trig$;';
    EXECUTE v_trig_func;

    EXECUTE format(
        'CREATE TRIGGER _aje_%s_delete INSTEAD OF DELETE ON %I FOR EACH ROW EXECUTE FUNCTION _aje_%s_delete()',
        p_view_name, p_view_name, p_view_name
    );

    RETURN p_view_name;
END;
$func$;

COMMENT ON FUNCTION aje.create_view(TEXT,TEXT,TEXT,TEXT,JSONB,JSONB) IS 'Create an AJE view with automatic INSTEAD OF triggers';

-- ============================================================================
-- aje_drop_view — Drop an AJE view
-- ============================================================================

CREATE OR REPLACE FUNCTION aje.drop_view(
    p_view_name TEXT
)
RETURNS boolean
LANGUAGE plpgsql
VOLATILE
AS $func$
DECLARE
    v_view_id BIGINT;
BEGIN
    SELECT view_id INTO v_view_id FROM aje_catalog.aje_views WHERE view_name = p_view_name;

    IF v_view_id IS NULL THEN
        RAISE NOTICE 'aje_drop_view: view "%" not found', p_view_name;
        RETURN false;
    END IF;

    EXECUTE format('DROP TRIGGER IF EXISTS _aje_%s_insert ON %I', p_view_name, p_view_name);
    EXECUTE format('DROP TRIGGER IF EXISTS _aje_%s_update ON %I', p_view_name, p_view_name);
    EXECUTE format('DROP TRIGGER IF EXISTS _aje_%s_delete ON %I', p_view_name, p_view_name);
    EXECUTE format('DROP FUNCTION IF EXISTS _aje_%s_insert()', p_view_name);
    EXECUTE format('DROP FUNCTION IF EXISTS _aje_%s_update()', p_view_name);
    EXECUTE format('DROP FUNCTION IF EXISTS _aje_%s_delete()', p_view_name);
    EXECUTE format('DROP VIEW IF EXISTS %I', p_view_name);

    DELETE FROM aje_catalog.aje_views WHERE view_id = v_view_id;

    RETURN true;
END;
$func$;

COMMENT ON FUNCTION aje.drop_view(TEXT) IS 'Drop an AJE view and all associated objects';

-- ============================================================================
-- aje_list_views — List all registered AJE views
-- ============================================================================

CREATE OR REPLACE FUNCTION aje.list_views()
RETURNS TABLE (
    view_name    TEXT,
    root_table   TEXT,
    root_schema  TEXT,
    annotations  JSONB,
    table_count  BIGINT,
    created_at   TIMESTAMPTZ
)
LANGUAGE sql
STABLE
AS $func$
    SELECT v.view_name, v.root_table, v.root_schema, v.root_annotations,
           (SELECT count(*) FROM aje_catalog.aje_view_tables vt WHERE vt.view_id = v.view_id),
           v.created_at
    FROM aje_catalog.aje_views v
    ORDER BY v.created_at;
$func$;

COMMENT ON FUNCTION aje.list_views() IS 'List all registered AJE views';

-- ============================================================================
-- aje_describe_view — Return JSONB description of a view
-- ============================================================================

CREATE OR REPLACE FUNCTION aje.describe_view(
    p_view_name TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
AS $func$
DECLARE
    v_view RECORD;
    v_tables JSONB;
    v_columns JSONB;
    v_links JSONB;
BEGIN
    SELECT * INTO v_view FROM aje_catalog.aje_views WHERE view_name = p_view_name;

    IF NOT FOUND THEN
        RETURN NULL;
    END IF;

    SELECT jsonb_agg(jsonb_build_object(
        'table_name', vt.table_name,
        'table_schema', vt.table_schema,
        'table_alias', vt.table_alias,
        'nesting_type', vt.nesting_type,
        'nesting_depth', vt.nesting_depth,
        'json_path', vt.json_path,
        'annotations', vt.annotations
    )) INTO v_tables
    FROM aje_catalog.aje_view_tables vt
    WHERE vt.view_id = v_view.view_id;

    SELECT jsonb_agg(jsonb_build_object(
        'table_name', vt.table_name,
        'json_path', vc.json_path,
        'column_name', vc.column_name,
        'updatable', vc.updatable,
        'check_etag', vc.check_etag,
        'is_identifying', vc.is_identifying
    )) INTO v_columns
    FROM aje_catalog.aje_view_columns vc
    JOIN aje_catalog.aje_view_tables vt ON vc.table_id = vt.table_id
    WHERE vt.view_id = v_view.view_id
      AND vc.json_path NOT LIKE '_link_%';

    SELECT jsonb_agg(jsonb_build_object(
        'child_table', ct.table_name,
        'parent_table', pt.table_name,
        'fk_columns', vl.fk_columns,
        'pk_columns', vl.pk_columns
    )) INTO v_links
    FROM aje_catalog.aje_view_links vl
    JOIN aje_catalog.aje_view_tables ct ON vl.child_table_id = ct.table_id
    JOIN aje_catalog.aje_view_tables pt ON vl.parent_table_id = pt.table_id
    WHERE vl.view_id = v_view.view_id;

    RETURN jsonb_build_object(
        'view_name', v_view.view_name,
        'root_table', v_view.root_table,
        'root_schema', v_view.root_schema,
        'root_alias', v_view.root_alias,
        'root_annotations', v_view.root_annotations,
        'tables', COALESCE(v_tables, '[]'::jsonb),
        'columns', COALESCE(v_columns, '[]'::jsonb),
        'links', COALESCE(v_links, '[]'::jsonb),
        'created_at', v_view.created_at
    );
END;
$func$;

COMMENT ON FUNCTION aje.describe_view(TEXT) IS 'Return JSONB description of a AJE view structure';

-- ============================================================================
-- aje_validate_view — Validate view definition against actual table schema
-- ============================================================================

CREATE OR REPLACE FUNCTION aje.validate_view(
    p_view_name TEXT
)
RETURNS TABLE (
    status      TEXT,
    message     TEXT
)
LANGUAGE plpgsql
STABLE
AS $func$
DECLARE
    v_view_id BIGINT;
    v_col RECORD;
    v_tbl RECORD;
    v_errors INT := 0;
BEGIN
    SELECT view_id INTO v_view_id FROM aje_catalog.aje_views WHERE view_name = p_view_name;

    IF v_view_id IS NULL THEN
        RETURN QUERY SELECT 'ERROR'::TEXT, 'View not found: ' || p_view_name;
        RETURN;
    END IF;

    -- Check tables exist
    FOR v_tbl IN
        SELECT table_name, table_schema FROM aje_catalog.aje_view_tables WHERE view_id = v_view_id
    LOOP
        IF NOT EXISTS (
            SELECT 1 FROM information_schema.tables
            WHERE table_schema = v_tbl.table_schema AND table_name = v_tbl.table_name
        ) THEN
            v_errors := v_errors + 1;
            RETURN QUERY SELECT 'ERROR'::TEXT, format('Table %.% does not exist', v_tbl.table_schema, v_tbl.table_name);
        END IF;
    END LOOP;

    -- Check columns exist
    FOR v_col IN
        SELECT vt.table_schema, vt.table_name, vc.column_name
        FROM aje_catalog.aje_view_columns vc
        JOIN aje_catalog.aje_view_tables vt ON vc.table_id = vt.table_id
        WHERE vt.view_id = v_view_id
    LOOP
        IF NOT EXISTS (
            SELECT 1 FROM information_schema.columns
            WHERE table_schema = v_col.table_schema
              AND table_name = v_col.table_name
              AND column_name = v_col.column_name
        ) THEN
            v_errors := v_errors + 1;
            RETURN QUERY SELECT 'ERROR'::TEXT, format('Column %.%.% does not exist',
                v_col.table_schema, v_col.table_name, v_col.column_name);
        END IF;
    END LOOP;

    IF v_errors = 0 THEN
        RETURN QUERY SELECT 'OK'::TEXT, 'View definition is valid';
    END IF;

    RETURN;
END;
$func$;

COMMENT ON FUNCTION aje.validate_view(TEXT) IS 'Validate a AJE view definition against actual table schema';

-- ============================================================================
-- Installation complete
-- ============================================================================

DO $$
BEGIN
    RAISE NOTICE 'pg-aje v0.1.0 installed successfully!';
    RAISE NOTICE 'A JSON Extension for PostgreSQL 18';
    RAISE NOTICE 'Try: SELECT aje.create_view(''my_dv'', ''my_table'');';
    RAISE NOTICE 'List: SELECT * FROM aje.list_views();';
    RAISE NOTICE 'Describe: SELECT aje.describe_view(''my_dv'');';
END $$;
