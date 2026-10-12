-- =====================================================================
--  Feature flag administration  -  SQL stored procedures.
--  All writes go through here so they are callable from RPG, SQL, CL, or a
--  future REST layer, and so authority can be adopted at one choke point.
--    RUNSQLSTM SRCSTMF('src/ddl/02_procedures.sql') COMMIT(*NONE) DFTRDBCOL(FLGxxx)
-- =====================================================================

-- Create a flag (or update its description); leaves state untouched if it exists.
CREATE OR REPLACE PROCEDURE flag_create (
    IN p_name        VARCHAR(50),
    IN p_description VARCHAR(256)
)
LANGUAGE SQL
MODIFIES SQL DATA
BEGIN
  MERGE INTO flagdef AS t
  USING (VALUES (UPPER(p_name), p_description)) AS s(nm, ds)
     ON t.flag_name = s.nm
  WHEN MATCHED THEN
     UPDATE SET description = s.ds, changed_by = USER, changed_ts = CURRENT_TIMESTAMP
  WHEN NOT MATCHED THEN
     INSERT (flag_name, description, enabled, status)
     VALUES (s.nm, s.ds, 'N', 'A');
END;

-- Set a flag's global default on/off. Creates the flag if missing.
CREATE OR REPLACE PROCEDURE flag_set (
    IN p_name    VARCHAR(50),
    IN p_enabled CHAR(1)
)
LANGUAGE SQL
MODIFIES SQL DATA
BEGIN
  IF p_enabled NOT IN ('Y','N') THEN
     SIGNAL SQLSTATE '42611' SET MESSAGE_TEXT = 'enabled must be Y or N';
  END IF;
  MERGE INTO flagdef AS t
  USING (VALUES (UPPER(p_name), p_enabled)) AS s(nm, en)
     ON t.flag_name = s.nm
  WHEN MATCHED THEN
     UPDATE SET enabled = s.en, status = 'A',
                changed_by = USER, changed_ts = CURRENT_TIMESTAMP
  WHEN NOT MATCHED THEN
     INSERT (flag_name, enabled, status) VALUES (s.nm, s.en, 'A');
END;

-- Retire a flag (hidden from evaluation; overrides cascade-deleted).
CREATE OR REPLACE PROCEDURE flag_retire ( IN p_name VARCHAR(50) )
LANGUAGE SQL
MODIFIES SQL DATA
BEGIN
  DELETE FROM flagusr WHERE flag_name = UPPER(p_name);
  UPDATE flagdef
     SET status = 'R', changed_by = USER, changed_ts = CURRENT_TIMESTAMP
   WHERE flag_name = UPPER(p_name);
END;

-- Set / update a per-user override.
CREATE OR REPLACE PROCEDURE flag_setuser (
    IN p_name    VARCHAR(50),
    IN p_user    VARCHAR(10),
    IN p_enabled CHAR(1)
)
LANGUAGE SQL
MODIFIES SQL DATA
BEGIN
  IF p_enabled NOT IN ('Y','N') THEN
     SIGNAL SQLSTATE '42611' SET MESSAGE_TEXT = 'enabled must be Y or N';
  END IF;
  MERGE INTO flagusr AS t
  USING (VALUES (UPPER(p_name), UPPER(p_user), p_enabled)) AS s(nm, us, en)
     ON t.flag_name = s.nm AND t.user_profile = s.us
  WHEN MATCHED THEN
     UPDATE SET enabled = s.en, changed_by = USER, changed_ts = CURRENT_TIMESTAMP
  WHEN NOT MATCHED THEN
     INSERT (flag_name, user_profile, enabled) VALUES (s.nm, s.us, s.en);
END;

-- Clear a per-user override (falls back to the global default).
CREATE OR REPLACE PROCEDURE flag_clearuser (
    IN p_name VARCHAR(50),
    IN p_user VARCHAR(10)
)
LANGUAGE SQL
MODIFIES SQL DATA
BEGIN
  DELETE FROM flagusr
   WHERE flag_name = UPPER(p_name) AND user_profile = UPPER(p_user);
  -- FLAGUSR has no DELETE trigger (see 01_tables.sql), so bump the version
  -- stamp here or running jobs would keep serving the cleared override.
  UPDATE flagctl SET version_ts = CURRENT_TIMESTAMP WHERE singleton = '1';
END;
