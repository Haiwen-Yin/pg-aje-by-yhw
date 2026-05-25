-- ============================================================================
-- pg-aje: Uninstall Script
-- Version: v0.1.0
-- Author: Haiwen Yin
--
-- Drops all views, triggers, functions, and catalog tables created by pg-aje.
-- WARNING: This is destructive — all AJE views and metadata will be lost.
-- ============================================================================

DO $$
DECLARE
    v_view_name TEXT;
    v_func_name TEXT;
BEGIN
    -- Drop all AJE views, triggers, and trigger functions
    FOR v_view_name IN SELECT view_name FROM aje_catalog.aje_views
    LOOP
        EXECUTE format('DROP TRIGGER IF EXISTS _aje_%s_insert ON %I', v_view_name, v_view_name);
        EXECUTE format('DROP TRIGGER IF EXISTS _aje_%s_update ON %I', v_view_name, v_view_name);
        EXECUTE format('DROP TRIGGER IF EXISTS _aje_%s_delete ON %I', v_view_name, v_view_name);
        EXECUTE format('DROP FUNCTION IF EXISTS _aje_%s_insert()', v_view_name);
        EXECUTE format('DROP FUNCTION IF EXISTS _aje_%s_update()', v_view_name);
        EXECUTE format('DROP FUNCTION IF EXISTS _aje_%s_delete()', v_view_name);
        EXECUTE format('DROP VIEW IF EXISTS %I', v_view_name);
        RAISE NOTICE 'Dropped AJE view: %', v_view_name;
    END LOOP;

    -- Drop aje functions
    FOR v_func_name IN
        SELECT proname FROM pg_proc p
        JOIN pg_namespace n ON p.pronamespace = n.oid
        WHERE n.nspname = 'aje'
    LOOP
        EXECUTE format('DROP FUNCTION IF EXISTS aje.%I', v_func_name);
    END LOOP;

    -- Drop aje_catalog tables and schema
    DROP TABLE IF EXISTS aje_catalog.aje_view_columns;
    DROP TABLE IF EXISTS aje_catalog.aje_view_links;
    DROP TABLE IF EXISTS aje_catalog.aje_view_tables;
    DROP TABLE IF EXISTS aje_catalog.aje_views;
    DROP SCHEMA IF EXISTS aje_catalog;

    -- Drop aje schema
    DROP SCHEMA IF EXISTS aje;

    RAISE NOTICE 'pg-aje v0.1.0 uninstalled successfully!';
END $$;
