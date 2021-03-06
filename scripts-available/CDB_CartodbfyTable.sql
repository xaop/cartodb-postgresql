-- Depends on:
--   * CDB_ExtensionUtils.sql
--   * CDB_TransformToWebmercator.sql
--   * CDB_TableMetadata.sql
--   * CDB_Quota.sql
--   * _CDB_UserQuotaInBytes() function, installed by rails
--     (user.rebuild_quota_trigger, called by rake task cartodb:db:update_test_quota_trigger)

-- 1) Required checks before running cartodbfication
-- Either will pass silenty or raise an exception
CREATE OR REPLACE FUNCTION _CDB_check_prerequisites(schema_name TEXT, reloid REGCLASS)
RETURNS void
AS $$
DECLARE
  sql TEXT;
BEGIN
  IF cartodb.schema_exists(schema_name) = false THEN
    RAISE EXCEPTION 'Invalid schema name "%"', schema_name;
  END IF;

  -- TODO: Check that user quota is set ?
  BEGIN
    EXECUTE FORMAT('SELECT %I._CDB_UserQuotaInBytes();', schema_name::text) INTO sql;
    EXCEPTION WHEN undefined_function THEN
      RAISE EXCEPTION 'Please set user quota before cartodbfying tables.';
  END;
END;
$$ LANGUAGE PLPGSQL;


-- 2) Drop cartodb triggers (might prevent changing columns)
CREATE OR REPLACE FUNCTION _CDB_drop_triggers(reloid REGCLASS)
  RETURNS void
AS $$
DECLARE
  sql TEXT;
BEGIN
  -- "track_updates"
  sql := 'DROP TRIGGER IF EXISTS track_updates ON ' || reloid::text;
  EXECUTE sql;

  -- "update_the_geom_webmercator"
  sql := 'DROP TRIGGER IF EXISTS update_the_geom_webmercator_trigger ON ' || reloid::text;
  EXECUTE sql;

  -- "update_updated_at"
  sql := 'DROP TRIGGER IF EXISTS update_updated_at_trigger ON ' || reloid::text;
  EXECUTE sql;

  -- "test_quota" and "test_quota_per_row"
  sql := 'DROP TRIGGER IF EXISTS test_quota ON ' || reloid::text;
  EXECUTE sql;
  sql := 'DROP TRIGGER IF EXISTS test_quota_per_row ON ' || reloid::text;
  EXECUTE sql;
END;
$$ LANGUAGE PLPGSQL;


-- 3) Cartodb_id creation & validation or renaming if invalid
CREATE OR REPLACE FUNCTION _CDB_create_cartodb_id_column(reloid REGCLASS)
  RETURNS void
AS $$
DECLARE
  sql TEXT;
  rec RECORD;
  rec2 RECORD;
  had_column BOOLEAN;
  i INTEGER;
  new_name TEXT;
  cartodb_id_name TEXT;
BEGIN
  << cartodb_id_setup >>
  LOOP --{
    had_column := FALSE;
    BEGIN
      sql := 'ALTER TABLE ' || reloid::text || ' ADD cartodb_id SERIAL NOT NULL UNIQUE';
      RAISE DEBUG 'Running %', sql;
      EXECUTE sql;
      cartodb_id_name := 'cartodb_id';
      EXIT cartodb_id_setup;
      EXCEPTION
      WHEN duplicate_column THEN
        RAISE NOTICE 'Column cartodb_id already exists';
        had_column := TRUE;
      WHEN others THEN
        RAISE EXCEPTION 'Cartodbfying % (cartodb_id): % (%)', reloid, SQLERRM, SQLSTATE;
    END;

    IF had_column THEN
      SELECT pg_catalog.pg_get_serial_sequence(reloid::text, 'cartodb_id')
        AS seq INTO rec2;

      -- Check data type is an integer
      SELECT
        pg_catalog.pg_get_serial_sequence(reloid::text, 'cartodb_id') as seq,
        t.typname, t.oid, a.attnotnull FROM pg_type t, pg_attribute a
      WHERE a.atttypid = t.oid AND a.attrelid = reloid AND NOT a.attisdropped AND a.attname = 'cartodb_id'
      INTO STRICT rec;

      -- 20=int2, 21=int4, 23=int8
      IF rec.oid NOT IN (20,21,23) THEN -- {
        RAISE NOTICE 'Existing cartodb_id field is of invalid type % (need int2, int4 or int8), renaming', rec.typname;
      ELSIF rec.seq IS NULL THEN -- }{
        RAISE NOTICE 'Existing cartodb_id field does not have an associated sequence, renaming';
      ELSE -- }{
        sql := 'ALTER TABLE ' || reloid::text || ' ALTER COLUMN cartodb_id SET NOT NULL';
        IF NOT EXISTS ( SELECT c.conname FROM pg_constraint c, pg_attribute a
        WHERE c.conkey = ARRAY[a.attnum] AND c.conrelid = reloid
              AND a.attrelid = reloid
              AND NOT a.attisdropped
              AND a.attname = 'cartodb_id'
              AND c.contype IN ( 'u', 'p' ) ) -- unique or pkey
        THEN
          sql := sql || ', ADD unique(cartodb_id)';
        END IF;
        BEGIN
          RAISE DEBUG 'Running %', sql;
          EXECUTE sql;
          cartodb_id_name := 'cartodb_id';
          EXIT cartodb_id_setup;
          EXCEPTION
          WHEN unique_violation OR not_null_violation THEN
            RAISE NOTICE '%, renaming', SQLERRM;
          WHEN others THEN
            RAISE EXCEPTION 'Cartodbfying % (cartodb_id): % (%)', reloid, SQLERRM, SQLSTATE;
        END;
      END IF; -- }

      -- invalid column, need rename and re-create it
      i := 0;
      << rename_column >>
      LOOP --{
        new_name := '_cartodb_id' || i;
        BEGIN
          sql := 'ALTER TABLE ' || reloid::text || ' RENAME COLUMN cartodb_id TO ' || new_name;
          RAISE DEBUG 'Running %', sql;
          EXECUTE sql;
          EXCEPTION
          WHEN duplicate_column THEN
            i := i+1;
            CONTINUE rename_column;
          WHEN others THEN
            RAISE EXCEPTION 'Cartodbfying % (renaming cartodb_id): % (%)', reloid, SQLERRM, SQLSTATE;
        END;
        cartodb_id_name := new_name;
        EXIT rename_column;
      END LOOP; --}
      CONTINUE cartodb_id_setup;
    END IF;
  END LOOP; -- }

  -- Try to copy data from new name if possible
  IF new_name IS NOT NULL THEN
    RAISE NOTICE 'Trying to recover data from % column', new_name;
    BEGIN
      -- Copy existing values to new field
      -- NOTE: using ALTER is a workaround to a PostgreSQL bug and is also known to be faster for tables with many rows
      -- See http://www.postgresql.org/message-id/20140530143150.GA11051@localhost
      sql := 'ALTER TABLE ' || reloid::text
             || ' ALTER cartodb_id TYPE int USING '
             || new_name || '::int4';
      RAISE DEBUG 'Running %', sql;
      EXECUTE sql;

      -- Find max value
      sql := 'SELECT max(cartodb_id) FROM ' || reloid::text;
      RAISE DEBUG 'Running %', sql;
      EXECUTE sql INTO rec;

      -- Find sequence name
      SELECT pg_catalog.pg_get_serial_sequence(reloid::text, 'cartodb_id')
        AS seq INTO rec2;

      -- Reset sequence name
      sql := 'ALTER SEQUENCE ' || rec2.seq::text
             || ' RESTART WITH ' || rec.max + 1;
      RAISE DEBUG 'Running %', sql;
      EXECUTE sql;

      -- Drop old column (all went fine if we got here)
      sql := 'ALTER TABLE ' || reloid::text || ' DROP ' || new_name;
      RAISE DEBUG 'Running %', sql;
      EXECUTE sql;

      EXCEPTION
      WHEN others THEN
        RAISE NOTICE 'Could not initialize cartodb_id with existing values: % (%)',
        SQLERRM, SQLSTATE;
    END;
  END IF;

  -- Set primary key of the table if not already present (e.g. tables created from SQL API)
  IF cartodb_id_name IS NULL THEN
    RAISE EXCEPTION 'Cartodbfying % (Didnt get cartodb_id field name)', reloid;
  END IF;
  BEGIN
    sql := 'ALTER TABLE ' || reloid::text || ' ADD PRIMARY KEY (cartodb_id)';
    EXECUTE sql;
    EXCEPTION
    WHEN others THEN
      RAISE DEBUG 'Table % Already had PRIMARY KEY', reloid;
  END;

END;
$$ LANGUAGE PLPGSQL;


-- 4) created_at and updated_at creation & validation or renaming if invalid
CREATE OR REPLACE FUNCTION _CDB_create_timestamp_columns(reloid REGCLASS)
  RETURNS void
AS $$
DECLARE
  sql TEXT;
  rec RECORD;
  rec2 RECORD;
  had_column BOOLEAN;
  i INTEGER;
  new_name TEXT;
BEGIN

  FOR rec IN SELECT * FROM ( VALUES ('created_at'), ('updated_at') ) t(cname)
  LOOP --{
    new_name := null;
    << column_setup >>
    LOOP --{
      had_column := FALSE;
      BEGIN
        sql := 'ALTER TABLE ' || reloid::text || ' ADD ' || rec.cname
               || ' TIMESTAMPTZ NOT NULL DEFAULT now()';
        RAISE DEBUG 'Running %', sql;
        EXECUTE sql;
        EXIT column_setup;
        EXCEPTION
        WHEN duplicate_column THEN
          RAISE NOTICE 'Column % already exists', rec.cname;
          had_column := TRUE;
        WHEN others THEN
          RAISE EXCEPTION 'Cartodbfying % (%): % (%)', reloid, rec.cname, SQLERRM, SQLSTATE;
      END;

      IF had_column THEN
        -- Check data type is a TIMESTAMP WITH TIMEZONE
        SELECT t.typname, t.oid, a.attnotnull FROM pg_type t, pg_attribute a
        WHERE a.atttypid = t.oid AND a.attrelid = reloid AND NOT a.attisdropped AND a.attname = rec.cname
        INTO STRICT rec2;
        IF rec2.oid NOT IN (1184) THEN -- timestamptz {
          RAISE NOTICE 'Existing % field is of invalid type % (need timestamptz), renaming', rec.cname, rec2.typname;
        ELSE -- }{
          -- Ensure data type is a TIMESTAMP WITH TIMEZONE
          sql := 'ALTER TABLE ' || reloid::text
                 || ' ALTER ' || rec.cname
                 || ' SET NOT NULL,'
                 || ' ALTER ' || rec.cname
                 || ' SET DEFAULT now()';
          BEGIN
            RAISE DEBUG 'Running %', sql;
            EXECUTE sql;
            EXIT column_setup;
            EXCEPTION
            WHEN not_null_violation THEN -- failed not-null
              RAISE NOTICE '%, renaming', SQLERRM;
            WHEN cannot_coerce THEN -- failed cast
              RAISE NOTICE '%, renaming', SQLERRM;
            WHEN others THEN
              RAISE EXCEPTION 'Cartodbfying % (%): % (%)', reloid, rec.cname, SQLERRM, SQLSTATE;
          END;
        END IF; -- }

        -- invalid column, need rename and re-create it
        i := 0;
        << rename_column >>
        LOOP --{
          new_name := '_' || rec.cname || i;
          BEGIN
            sql := 'ALTER TABLE ' || reloid::text || ' RENAME COLUMN ' || rec.cname || ' TO ' || new_name;
            RAISE DEBUG 'Running %', sql;
            EXECUTE sql;
            EXCEPTION
            WHEN duplicate_column THEN
              i := i+1;
              CONTINUE rename_column;
            WHEN others THEN
              RAISE EXCEPTION 'Cartodbfying % (renaming %): % (%)',
              reloid, rec.cname, SQLERRM, SQLSTATE;
          END;
          EXIT rename_column;
        END LOOP; --}
        CONTINUE column_setup;
      END IF;
    END LOOP; -- }

    -- Try to copy data from new name if possible
    IF new_name IS NOT NULL THEN -- {
      RAISE NOTICE 'Trying to recover data from % coumn', new_name;
      BEGIN
        -- Copy existing values to new field
        -- NOTE: using ALTER is a workaround to a PostgreSQL bug and is also known to be faster for tables with many rows
        -- See http://www.postgresql.org/message-id/20140530143150.GA11051@localhost
        sql := 'ALTER TABLE ' || reloid::text || ' ALTER ' || rec.cname
               || ' TYPE TIMESTAMPTZ USING '
               || new_name || '::timestamptz';
        RAISE DEBUG 'Running %', sql;
        EXECUTE sql;

        -- Drop old column (all went find if we got here)
        sql := 'ALTER TABLE ' || reloid::text || ' DROP ' || new_name;
        RAISE DEBUG 'Running %', sql;
        EXECUTE sql;

        EXCEPTION
        WHEN others THEN
          RAISE NOTICE 'Could not initialize % with existing values: % (%)', rec.cname, SQLERRM, SQLSTATE;
      END;
    END IF; -- }
  END LOOP; -- }

END;
$$ LANGUAGE PLPGSQL;


-- 5) the_geom and the_geom_webmercator creation & validation or renaming if invalid
CREATE OR REPLACE FUNCTION _CDB_create_the_geom_columns(reloid REGCLASS)
  RETURNS BOOLEAN[]
AS $$
DECLARE
  sql TEXT;
  rec RECORD;
  rec2 RECORD;
  had_column BOOLEAN;
  i INTEGER;
  new_name TEXT;
  exists_geom_cols BOOLEAN[];
BEGIN
  -- We need the_geom and the_geom_webmercator
  FOR rec IN SELECT * FROM ( VALUES ('the_geom',4326), ('the_geom_webmercator',3857) ) t(cname,csrid) LOOP --{
    << column_setup >> LOOP --{
      BEGIN
        sql := 'ALTER TABLE ' || reloid::text || ' ADD ' || rec.cname
               || ' GEOMETRY(geometry,' || rec.csrid || ')';
        RAISE DEBUG 'Running %', sql;
        EXECUTE sql;
        sql := 'CREATE INDEX ON ' || reloid::text || ' USING GIST ( ' || rec.cname || ')';
        RAISE DEBUG 'Running %', sql;
        EXECUTE sql;
        exists_geom_cols := array_append(exists_geom_cols, false);
        EXIT column_setup;
        EXCEPTION
        WHEN duplicate_column THEN
          exists_geom_cols := array_append(exists_geom_cols, true);
          RAISE NOTICE 'Column % already exists', rec.cname;
        WHEN others THEN
          RAISE EXCEPTION 'Cartodbfying % (%): % (%)', reloid, rec.cname, SQLERRM, SQLSTATE;
      END;

      << column_fixup >>
      LOOP --{
        -- Check data type is a GEOMETRY
        SELECT t.typname, t.oid, a.attnotnull,
          postgis_typmod_srid(a.atttypmod) as srid,
          postgis_typmod_type(a.atttypmod) as gtype
        FROM pg_type t, pg_attribute a
        WHERE a.atttypid = t.oid AND a.attrelid = reloid AND NOT a.attisdropped AND a.attname = rec.cname
        INTO STRICT rec2;

        IF rec2.typname NOT IN ('geometry') THEN -- {
          RAISE NOTICE 'Existing % field is of invalid type % (need geometry), renaming', rec.cname, rec2.typname;
          EXIT column_fixup; -- cannot fix
        END IF; -- }

        IF rec2.srid != rec.csrid THEN -- {
          BEGIN
            sql := 'ALTER TABLE ' || reloid::text || ' ALTER ' || rec.cname
                   || ' TYPE geometry(' || rec2.gtype || ',' || rec.csrid || ') USING ST_Transform('
                   || rec.cname || ',' || rec.csrid || ')';
            RAISE DEBUG 'Running %', sql;
            EXECUTE sql;
            EXCEPTION
            WHEN others THEN
              RAISE NOTICE 'Could not enforce SRID % to column %: %, renaming', rec.csrid, rec.cname, SQLERRM;
              EXIT column_fixup; -- cannot fix, will rename
          END;
        END IF; -- }

        -- add gist indices if not there already
        IF NOT EXISTS ( SELECT ir.relname
                        FROM pg_am am, pg_class ir,
                          pg_class c, pg_index i,
                          pg_attribute a
                        WHERE c.oid  = reloid AND i.indrelid = c.oid
                              AND a.attname = rec.cname
                              AND i.indexrelid = ir.oid AND i.indnatts = 1
                              AND i.indkey[0] = a.attnum AND a.attrelid = c.oid
                              AND NOT a.attisdropped AND am.oid = ir.relam
                              AND am.amname = 'gist' )
        THEN -- {
          BEGIN
            sql := 'CREATE INDEX ON ' || reloid::text || ' USING GIST ( ' || rec.cname || ')';
            RAISE DEBUG 'Running %', sql;
            EXECUTE sql;
            EXCEPTION
            WHEN others THEN
              RAISE EXCEPTION 'Cartodbfying % (% index): % (%)', reloid, rec.cname, SQLERRM, SQLSTATE;
          END;
        END IF; -- }

        -- if we reached this line, all went good
        EXIT column_setup;
      END LOOP; -- } column_fixup

      -- invalid column, need rename and re-create it
      i := 0;
      << rename_column >>
      LOOP --{
        new_name := '_' || rec.cname || i;
        BEGIN
          sql := 'ALTER TABLE ' || reloid::text || ' RENAME COLUMN ' || rec.cname || ' TO ' || new_name;
          RAISE DEBUG 'Running %', sql;
          EXECUTE sql;
          EXCEPTION
          WHEN duplicate_column THEN
            i := i+1;
            CONTINUE rename_column;
          WHEN others THEN
            RAISE EXCEPTION 'Cartodbfying % (rename %): % (%)', reloid, rec.cname, SQLERRM, SQLSTATE;
        END;
        EXIT rename_column;
      END LOOP; --}
      CONTINUE column_setup;
    END LOOP; -- } column_setup
  END LOOP; -- } on expected geometry columns

  RETURN exists_geom_cols;
END;
$$ LANGUAGE PLPGSQL;


-- 6) Initialize the_geom with values from the_geom_webmercator
-- do this only if the_geom_webmercator was found (not created) and the_geom was NOT found.
CREATE OR REPLACE FUNCTION _CDB_populate_the_geom_from_the_geom_webmercator(reloid REGCLASS, geom_columns_exist BOOLEAN[])
  RETURNS void
AS $$
DECLARE
  sql TEXT;
BEGIN
  IF geom_columns_exist[2] AND NOT geom_columns_exist[1] THEN
    sql := 'UPDATE ' || reloid::text || ' SET the_geom = ST_Transform(the_geom_webmercator, 4326) ';
    EXECUTE sql;
  END IF;
END;
$$ LANGUAGE PLPGSQL;


-- 7) Initialize the_geom_webmercator with values from the_geom
-- do this only if the_geom was found (not created) and the_geom_webmercator was NOT found.
CREATE OR REPLACE FUNCTION _CDB_populate_the_geom_webmercator_from_the_geom(reloid REGCLASS, geom_columns_exist BOOLEAN[])
  RETURNS void
AS $$
DECLARE
  sql TEXT;
BEGIN
  IF geom_columns_exist[1] AND NOT geom_columns_exist[2] THEN
    sql := 'UPDATE ' || reloid::text || ' SET the_geom_webmercator = public.CDB_TransformToWebmercator(the_geom) ';
    EXECUTE sql;
  END IF;
END;
$$ LANGUAGE PLPGSQL;


-- 8.a) Create all triggers
-- NOTE: drop/create has the side-effect of re-enabling disabled triggers
CREATE OR REPLACE FUNCTION _CDB_create_triggers(schema_name TEXT, reloid REGCLASS)
RETURNS void
AS $$
DECLARE
  sql TEXT;
BEGIN
-- "track_updates"
  sql := 'CREATE trigger track_updates AFTER INSERT OR UPDATE OR DELETE OR TRUNCATE ON '
         || reloid::text
         || ' FOR EACH STATEMENT EXECUTE PROCEDURE public.cdb_tablemetadata_trigger()';
  EXECUTE sql;

-- "update_the_geom_webmercator"
-- TODO: why _before_ and not after ?
  sql := 'CREATE trigger update_the_geom_webmercator_trigger BEFORE INSERT OR UPDATE OF the_geom ON '
         || reloid::text
         || ' FOR EACH ROW EXECUTE PROCEDURE public._CDB_update_the_geom_webmercator()';
  EXECUTE sql;

-- "update_updated_at"
-- TODO: why _before_ and not after ?
  sql := 'CREATE trigger update_updated_at_trigger BEFORE UPDATE ON '
         || reloid::text
         || ' FOR EACH ROW EXECUTE PROCEDURE public._CDB_update_updated_at()';
  EXECUTE sql;

-- "test_quota" and "test_quota_per_row"

  sql := 'CREATE TRIGGER test_quota BEFORE UPDATE OR INSERT ON '
         || reloid::text
         || ' EXECUTE PROCEDURE public.CDB_CheckQuota(1, ''-1'', '''
         || schema_name::text
         || ''')';
  EXECUTE sql;

  sql := 'CREATE TRIGGER test_quota_per_row BEFORE UPDATE OR INSERT ON '
         || reloid::text
         || ' FOR EACH ROW EXECUTE PROCEDURE public.CDB_CheckQuota(0.001, ''-1'', '''
         || schema_name::text
         || ''')';
  EXECUTE sql;
END;
$$ LANGUAGE PLPGSQL;

-- 8.b) Create all raster triggers
-- NOTE: drop/create has the side-effect of re-enabling disabled triggers
CREATE OR REPLACE FUNCTION _CDB_create_raster_triggers(schema_name TEXT, reloid REGCLASS)
  RETURNS void
AS $$
DECLARE
  sql TEXT;
BEGIN
-- "track_updates"
  sql := 'CREATE trigger track_updates AFTER INSERT OR UPDATE OR DELETE OR TRUNCATE ON '
         || reloid::text
         || ' FOR EACH STATEMENT EXECUTE PROCEDURE public.cdb_tablemetadata_trigger()';
  EXECUTE sql;

-- "update_updated_at"
-- TODO: why _before_ and not after ?
  sql := 'CREATE trigger update_updated_at_trigger BEFORE UPDATE ON '
         || reloid::text
         || ' FOR EACH ROW EXECUTE PROCEDURE public._CDB_update_updated_at()';
  EXECUTE sql;

-- "test_quota" and "test_quota_per_row"

  sql := 'CREATE TRIGGER test_quota BEFORE UPDATE OR INSERT ON '
         || reloid::text
         || ' EXECUTE PROCEDURE public.CDB_CheckQuota(1, ''-1'', '''
         || schema_name::text
         || ''')';
  EXECUTE sql;

  sql := 'CREATE TRIGGER test_quota_per_row BEFORE UPDATE OR INSERT ON '
         || reloid::text
         || ' FOR EACH ROW EXECUTE PROCEDURE public.CDB_CheckQuota(0.001, ''-1'', '''
         || schema_name::text
         || ''')';
  EXECUTE sql;
END;
$$ LANGUAGE PLPGSQL;



-- Update the_geom_webmercator
CREATE OR REPLACE FUNCTION _CDB_update_the_geom_webmercator()
  RETURNS trigger
AS $$
BEGIN
  NEW.the_geom_webmercator := public.CDB_TransformToWebmercator(NEW.the_geom);
  RETURN NEW;
END;
$$ LANGUAGE plpgsql VOLATILE;

CREATE OR REPLACE FUNCTION _CDB_update_updated_at()
  RETURNS TRIGGER AS $$
BEGIN
   NEW.updated_at := now();
   RETURN NEW;
END;
$$ LANGUAGE plpgsql VOLATILE;


-- Auxiliary function
CREATE OR REPLACE FUNCTION cartodb._CDB_is_raster_table(schema_name TEXT, reloid REGCLASS)
  RETURNS BOOLEAN
AS $$
DECLARE
  sql TEXT;
  is_raster BOOLEAN;
  rel_name TEXT;
BEGIN
  IF cartodb.schema_exists(schema_name) = FALSE THEN
    RAISE EXCEPTION 'Invalid schema name "%"', schema_name;
  END IF;

  SELECT relname FROM pg_class WHERE oid=reloid INTO rel_name;

  BEGIN
    sql := 'SELECT the_raster_webmercator FROM '
          || quote_ident(schema_name::TEXT)
          || '.'
          || quote_ident(rel_name::TEXT)
          || ' LIMIT 1';
    is_raster = TRUE;
    EXECUTE sql;

    EXCEPTION WHEN undefined_column THEN
      is_raster = FALSE;
  END;

  RETURN is_raster;
END;
$$ LANGUAGE PLPGSQL;



-- ////////////////////////////////////////////////////

-- Ensure a table is a "cartodb" table (See https://github.com/CartoDB/cartodb/wiki/CartoDB-user-table)
-- Rails code replicates this call at User.cartodbfy()
CREATE OR REPLACE FUNCTION CDB_CartodbfyTable(schema_name TEXT, reloid REGCLASS)
RETURNS void 
AS $$
DECLARE
  exists_geom_cols BOOLEAN[];
  is_raster BOOLEAN;
BEGIN

  PERFORM cartodb._CDB_check_prerequisites(schema_name, reloid);

  PERFORM cartodb._CDB_drop_triggers(reloid);

  -- Ensure required fields exist
  PERFORM cartodb._CDB_create_cartodb_id_column(reloid);
  PERFORM cartodb._CDB_create_timestamp_columns(reloid);

  SELECT cartodb._CDB_is_raster_table(schema_name, reloid) INTO is_raster;
  IF is_raster THEN
    PERFORM cartodb._CDB_create_raster_triggers(schema_name, reloid);
  ELSE
    SELECT cartodb._CDB_create_the_geom_columns(reloid) INTO exists_geom_cols;

    -- Both only populate if proceeds
    PERFORM cartodb._CDB_populate_the_geom_from_the_geom_webmercator(reloid, exists_geom_cols);
    PERFORM cartodb._CDB_populate_the_geom_webmercator_from_the_geom(reloid, exists_geom_cols);

    PERFORM cartodb._CDB_create_triggers(schema_name, reloid);
  END IF;

END;
$$ LANGUAGE PLPGSQL;

CREATE OR REPLACE FUNCTION CDB_CartodbfyTable(reloid REGCLASS)
RETURNS void
AS $$
BEGIN
  PERFORM cartodb.CDB_CartodbfyTable('public', reloid);
END;
$$ LANGUAGE PLPGSQL;
