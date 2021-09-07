-- @see https://github.com/graphile/graphile-engine/blob/v4/packages/graphile-build-pg/res/watch-fixtures.sql
-- Adds the functionality for PostGraphile to watch the database for schema
-- changes. This script is idempotent, you can run it as many times as you
-- would like.
-- Drop the `postgraphile_watch` schema and all of its dependant objects
-- including the event trigger function and the event trigger itself. We will
-- recreate those objects in this script.
DROP SCHEMA IF EXISTS postgraphile_watch CASCADE;

-- Create a schema for the PostGraphile watch functionality. This schema will
-- hold things like trigger functions that are used to implement schema
-- watching.
CREATE SCHEMA postgraphile_watch;

CREATE FUNCTION postgraphile_watch.notify_watchers_ddl ()
  RETURNS event_trigger
  AS $$
BEGIN
  PERFORM
    pg_notify('postgraphile_watch', json_build_object('type', 'ddl', 'payload', (
          SELECT
            json_agg(json_build_object('schema', schema_name, 'command', command_tag))
          FROM pg_event_trigger_ddl_commands () AS x))::text);
END;
$$
LANGUAGE plpgsql;

CREATE FUNCTION postgraphile_watch.notify_watchers_drop ()
  RETURNS event_trigger
  AS $$
BEGIN
  PERFORM
    pg_notify('postgraphile_watch', json_build_object('type', 'drop', 'payload', (
          SELECT
            json_agg(DISTINCT x.schema_name)
          FROM pg_event_trigger_dropped_objects () AS x))::text);
END;
$$
LANGUAGE plpgsql;

-- Create an event trigger which will listen for the completion of all DDL
-- events and report that they happened to PostGraphile. Events are selected by
-- whether or not they modify the static definition of `pg_catalog` that
-- `introspection-query.sql` queries.
CREATE EVENT TRIGGER postgraphile_watch_ddl ON ddl_command_end
  WHEN tag IN (
  -- Ref: https://www.postgresql.org/docs/10/static/event-trigger-matrix.html
  'ALTER AGGREGATE', 'ALTER DOMAIN', 'ALTER EXTENSION', 'ALTER FOREIGN TABLE', 'ALTER FUNCTION', 'ALTER POLICY',
    'ALTER SCHEMA', 'ALTER TABLE', 'ALTER TYPE', 'ALTER VIEW', 'COMMENT',
    'CREATE AGGREGATE', 'CREATE DOMAIN', 'CREATE EXTENSION', 'CREATE FOREIGN TABLE', 'CREATE FUNCTION',
    'CREATE INDEX', 'CREATE POLICY', 'CREATE RULE', 'CREATE SCHEMA', 'CREATE TABLE',
    'CREATE TABLE AS', 'CREATE VIEW', 'DROP AGGREGATE', 'DROP DOMAIN', 'DROP EXTENSION',
    'DROP FOREIGN TABLE', 'DROP FUNCTION', 'DROP INDEX', 'DROP OWNED', 'DROP POLICY',
    'DROP RULE', 'DROP SCHEMA', 'DROP TABLE', 'DROP TYPE', 'DROP VIEW',
    'GRANT', 'REVOKE', 'SELECT INTO')
    EXECUTE PROCEDURE postgraphile_watch.notify_watchers_ddl ();

-- Create an event trigger which will listen for drop events because on drops
-- the DDL method seems to get nothing returned from
-- pg_event_trigger_ddl_commands()
CREATE EVENT TRIGGER postgraphile_watch_drop ON sql_drop
  EXECUTE PROCEDURE postgraphile_watch.notify_watchers_drop ();
