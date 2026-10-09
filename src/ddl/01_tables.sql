-- =====================================================================
--  Feature flag data model  (Db2 for i)
--  Run into the environment's flag data library, e.g.:
--    RUNSQLSTM SRCSTMF('src/ddl/01_tables.sql') COMMIT(*NONE) DFTRDBCOL(FLGDEV)
--  Repeat per environment library (FLGDEV / FLGTST / FLGPRD). Same names in each;
--  jobs pick the right one via their library list.
-- =====================================================================

-- Single-row control table: one timestamp that moves on ANY flag data change.
CREATE TABLE flagctl (
  singleton  CHAR(1)   NOT NULL DEFAULT '1',
  version_ts TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (singleton),
  CONSTRAINT flagctl_one CHECK (singleton = '1')
);
INSERT INTO flagctl (singleton) VALUES ('1');

-- Flag definitions (global defaults).
CREATE TABLE flagdef (
  flag_name   VARCHAR(50)  NOT NULL,
  description VARCHAR(256) NOT NULL DEFAULT '',
  enabled     CHAR(1)      NOT NULL DEFAULT 'N',   -- 'Y' / 'N' global default
  status      CHAR(1)      NOT NULL DEFAULT 'A',   -- 'A' active / 'R' retired
  created_by  VARCHAR(10)  NOT NULL DEFAULT USER,
  created_ts  TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
  changed_by  VARCHAR(10)  NOT NULL DEFAULT USER,
  changed_ts  TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (flag_name),
  CONSTRAINT flagdef_enabled CHECK (enabled IN ('Y','N')),
  CONSTRAINT flagdef_status  CHECK (status  IN ('A','R'))
);

LABEL ON TABLE flagdef IS 'Feature flag definitions';

-- Per user-profile overrides.
CREATE TABLE flagusr (
  flag_name    VARCHAR(50) NOT NULL,
  user_profile VARCHAR(10) NOT NULL,
  enabled      CHAR(1)     NOT NULL,             -- 'Y' / 'N' override
  changed_by   VARCHAR(10) NOT NULL DEFAULT USER,
  changed_ts   TIMESTAMP   NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (flag_name, user_profile),
  CONSTRAINT flagusr_enabled CHECK (enabled IN ('Y','N')),
  CONSTRAINT flagusr_fk FOREIGN KEY (flag_name)
    REFERENCES flagdef (flag_name) ON DELETE CASCADE
);

LABEL ON TABLE flagusr IS 'Feature flag per-user overrides';

-- Version-bump triggers: any change to flag data moves FLAGCTL.version_ts so the
-- in-job cache can detect change by reading a single row.
CREATE TRIGGER flagdef_ver AFTER INSERT OR UPDATE OR DELETE ON flagdef
  FOR EACH STATEMENT
  UPDATE flagctl SET version_ts = CURRENT_TIMESTAMP WHERE singleton = '1';

CREATE TRIGGER flagusr_ver AFTER INSERT OR UPDATE OR DELETE ON flagusr
  FOR EACH STATEMENT
  UPDATE flagctl SET version_ts = CURRENT_TIMESTAMP WHERE singleton = '1';

-- Convenience view: "what is this flag, and who is it overridden for."
CREATE VIEW flagview AS
  SELECT d.flag_name, d.enabled AS global_default, d.status, d.description,
         u.user_profile, u.enabled AS user_override
    FROM flagdef d
    LEFT JOIN flagusr u ON u.flag_name = d.flag_name;

-- Recommended after creation (captures who/when/before/after for audit):
--   STRJRNPF FILE(FLGxxx/FLAGDEF FLGxxx/FLAGUSR) JRN(FLGxxx/QSQJRN) IMAGES(*BOTH)
