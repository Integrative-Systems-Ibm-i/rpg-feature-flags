# FLAGSRV — build & use

Source tree:

```
src/
  copy/FLAGSRV_H.rpgleinc    prototype copybook consumers /copy
  sqlrpgle/FLAGSRV.sqlrpgle   service program (embedded SQL, NOMAIN)
  bnd/FLAGSRV.bnd             binder source (frozen signature FLAGSRV_V1)
  ddl/01_tables.sql           tables, triggers, view
  ddl/02_procedures.sql       admin stored procedures
build/
  BUILDALL.clle              one CL program that builds everything
test/
  FLAGSRVT.sqlrpgle          RPGUnit test suite
```

## Quick start: build everything at once

Compile the build driver once, then run it against your libraries:

```
CRTBNDCL PGM(yourlib/BUILDALL) SRCSTMF('build/BUILDALL.clle')

/* CALL with: repo root, data lib, object lib, test lib (*NONE to skip) */
CALL yourlib/BUILDALL ('/home/dev/rpg-feature-flags' 'FLGDEV' 'FLGDEV' 'FLGUT')
```

`BUILDALL` runs the DDL + procedures, journals the tables, builds the module and
`*SRVPGM`, creates the `FLAGBND` binding directory, and (unless `TSTLIB` is
`*NONE`) builds the RPGUnit test program. The manual steps below are the same
work broken out, for when you want finer control.

## 1. Create the data objects (per environment)

Run the DDL into each environment's flag data library (`FLGDEV`, `FLGTST`,
`FLGPRD`). Same object names in every library — jobs select the environment
through their **library list**, not code.

```
RUNSQLSTM SRCSTMF('src/ddl/01_tables.sql')     COMMIT(*NONE) DFTRDBCOL(FLGDEV)
RUNSQLSTM SRCSTMF('src/ddl/02_procedures.sql') COMMIT(*NONE) DFTRDBCOL(FLGDEV)
```

Enable journaling for audit:

```
STRJRNPF FILE(FLGDEV/FLAGDEF FLGDEV/FLAGUSR) JRN(FLGDEV/QSQJRN) IMAGES(*BOTH)
```

## 2. Build the service program

```
CRTSQLRPGI OBJ(yourlib/FLAGSRV) SRCSTMF('src/sqlrpgle/FLAGSRV.sqlrpgle')
           OBJTYPE(*MODULE) DBGVIEW(*SOURCE) COMMIT(*NONE)

CRTSRVPGM  SRVPGM(yourlib/FLAGSRV) MODULE(yourlib/FLAGSRV)
           SRCSTMF('src/bnd/FLAGSRV.bnd')
           ACTGRP(FLAGS)          /* named group: cache persists per job   */
           USRPRF(*OWNER)         /* adopt authority to the flag tables    */

/* Binding directory so consumers just need bnddir('FLAGBND') */
CRTBNDDIR  BNDDIR(yourlib/FLAGBND)
ADDBNDDIRE BNDDIR(yourlib/FLAGBND) OBJ((yourlib/FLAGSRV *SRVPGM))
```

> **Why USRPRF(*OWNER):** consumers then need no authority to `FLAGDEF/FLAGUSR/
> FLAGCTL`. Because authority is adopted, SQL `CURRENT_USER` would return the
> *owner* — so evaluation reads the **job user** from the PSDS (SQL equivalent:
> `SESSION_USER`) instead. That is the identity `flag_isOn()` targets.

## 3. Use it from a consumer program

```rpgle
**free
ctl-opt bnddir('FLAGBND');
/copy 'src/copy/FLAGSRV_H.rpgleinc'

if flag_isOn('NEW_PRICING_ENGINE');
  // new path
endif;
```

## 4. Administer flags

```sql
CALL flag_create('NEW_PRICING_ENGINE', 'Route pricing through v2 engine');
CALL flag_set('NEW_PRICING_ENGINE', 'N');            -- global default off
CALL flag_setuser('NEW_PRICING_ENGINE', 'DEVUSER1', 'Y');  -- on for one user
CALL flag_clearuser('NEW_PRICING_ENGINE', 'DEVUSER1');
CALL flag_retire('OLD_EXPERIMENT');
SELECT * FROM flagview WHERE flag_name = 'NEW_PRICING_ENGINE';
```

Changes propagate to running jobs within the cache TTL (default 60s). Call
`flag_refresh()` in a job to pick them up immediately, or `flag_setTtl(5)` to
shorten the window for interactive/QA jobs.

## 5. Run the tests

Point the test job's library list at a throwaway data library (e.g. `FLGUT`)
that has the tables + admin procedures, then:

```
RUCALLTST TSTPGM(FLGUT/FLAGSRVT)                        /* all tests   */
RUCALLTST TSTPGM(FLGUT/FLAGSRVT) TSTPRC(testUserOverrideWins)
```

The suite (`test/FLAGSRVT.sqlrpgle`) covers global-default on/off, unknown-flag
fail-safe, user-override precedence (both directions), default fallback for an
unlisted user, case-insensitive flag names, and cache reload via the version
stamp. Each test seeds `UT_`-prefixed flags in `setUp` and retires them in
`tearDown`, so it is safe to run repeatedly against the test library.

## Adding a new procedure later

Append the new `EXPORT SYMBOL(...)` at the **end** of the `*CURRENT` block in
`FLAGSRV.bnd` (do not reorder existing ones) so the signature stays compatible
and existing consumers need no recompile.
