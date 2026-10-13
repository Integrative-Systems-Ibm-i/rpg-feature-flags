# RPG Feature Flags

A lightweight **feature flag system for applications written in ILE RPG on IBM i**.
Wrap new or risky behavior behind named flags that can be flipped **on/off at
runtime — no recompile, no job restart** — and optionally scope a flag to specific
IBM i user profiles.

It is deliberately small: a **Db2 for i** data model plus a single ILE **service
program** (`FLAGSRV`) that your RPG programs bind to and call. The entire public
contract for the common case is one procedure call:

```rpgle
if flag_isOn('NEW_PRICING_ENGINE');
  price = calcPrice_v2(order);
else;
  price = calcPrice_v1(order);
endif;
```

> **Platform:** IBM i 7.4+, fully-free ILE RPG, Db2 for i, embedded SQL.
> See [`docs/feature-flags-design.md`](docs/feature-flags-design.md) for the full
> design rationale, and [`src/README.md`](src/README.md) for the component-level
> build reference.

---

## How it works

- **One service program, statically bound.** No server jobs, data queues, or
  subsystems — evaluation is a plain ILE procedure call.
- **In-job cache.** `FLAGSRV` is built into a named activation group (`FLAGS`), so
  its flag cache persists for the life of the job. Steady-state evaluation touches
  no I/O.
- **Cheap invalidation.** All flag data sits behind a single `FLAGCTL.version_ts`
  timestamp that triggers bump on any change. The cache only re-reads flag data
  when the TTL (default 60s) has elapsed **and** the version stamp has actually
  moved — so changes propagate within the TTL window without per-call SQL.
- **Environment = library list.** `FLAGDEF`/`FLAGUSR`/`FLAGCTL` live in an
  environment-specific data library (e.g. `FLGDEV`, `FLGTST`, `FLGPRD`) with
  **identical object names**. Jobs pick the environment via their `*LIBL`; the code
  never hard-codes a library.
- **Fail-safe.** Unknown/retired flags, or any data error, resolve to **OFF**
  ("fail closed") — a data outage leaves everyone on the proven code path.
- **Job user, not `CURRENT_USER`.** `FLAGSRV` adopts owner authority so consumers
  need no rights to the flag tables; evaluation therefore targets the **job user**
  (`SESSION_USER`), which is the identity `flag_isOn()` resolves against.

```
  Consumer RPG programs  ──bound call (BNDDIR: FLAGBND)──▶  FLAGSRV (*SRVPGM)
                                                               │  in-job cache
                                                               │  embedded SQL
                                                               ▼
                                            Db2 for i (via *LIBL): FLAGCTL · FLAGDEF · FLAGUSR
```

---

## Repository layout

```
src/
  copy/FLAGSRV_H.rpgleinc     prototype copybook consumers /copy
  sqlrpgle/FLAGSRV.sqlrpgle   service program (embedded SQL, NOMAIN)
  sqlrpgle/DEMO01.sqlrpgle    worked example: a 5250 screen driven by a flag
  dspf/DEMO01D.dspf           display file for the example
  bnd/FLAGSRV.bnd             binder source (frozen signature FLAGSRV_V1)
  ddl/01_tables.sql           tables, version-bump triggers, flagview
  ddl/02_procedures.sql       admin stored procedures
  README.md                   component build reference
build/
  BUILDALL.clle               builds the system from IFS stream files
  BUILDLIB.clle               builds the system from INTGRTV source members
  BUILDDEMO.clle              builds the whole stack + the DEMO01 example
test/
  FLAGSRVT.sqlrpgle           RPGUnit test suite
docs/
  feature-flags-design.md     full design document
.github/workflows/
  build.yml                   CI: push or PR builds on a real IBM i
  README.md                   CI setup and the traps worth knowing
```

---

## Building the system

### Option A — build everything at once (recommended)

Compile the build driver once, then run it against the libraries you want. It
creates the libraries, runs the DDL + admin procedures, journals the tables,
builds the `FLAGSRV` module and `*SRVPGM`, creates the `FLAGBND` binding
directory, and (unless `TSTLIB` is `*NONE`) builds the RPGUnit test program.

```cl
CRTBNDCL PGM(yourlib/BUILDALL) SRCSTMF('build/BUILDALL.clle')

/* CALL params: repo root (IFS), data lib, object lib, test lib (*NONE to skip) */
CALL yourlib/BUILDALL ('/home/dev/rpg-feature-flags' 'FLGDEV' 'FLGDEV' 'FLGUT')
```

| Param    | Meaning                                              |
|----------|-----------------------------------------------------|
| `ROOT`   | IFS path to the repo root (holds `src/`, `test/`)   |
| `DATLIB` | Library for the flag **data** objects (per-env)     |
| `OBJLIB` | Library for the **code** objects (`FLAGSRV`, `FLAGBND`) |
| `TSTLIB` | Library for the RPGUnit test program (`*NONE` to skip) |

### Option B — manual steps (finer control)

The steps below are the same work broken out. Run them per environment data
library (`FLGDEV`, `FLGTST`, `FLGPRD`) — same object names in every one.

**1. Create the data objects**

```cl
RUNSQLSTM SRCSTMF('src/ddl/01_tables.sql')     COMMIT(*NONE) DFTRDBCOL(FLGDEV)
RUNSQLSTM SRCSTMF('src/ddl/02_procedures.sql') COMMIT(*NONE) DFTRDBCOL(FLGDEV)

/* Journaling is REQUIRED, not just for audit: without it the admin
   procedures fail with SQL7008 when they try to write.                  */
CRTJRNRCV JRNRCV(FLGDEV/FLAGRCV0)
CRTJRN    JRN(FLGDEV/QSQJRN) JRNRCV(FLGDEV/FLAGRCV0)
STRJRNPF  FILE(FLGDEV/FLAGDEF FLGDEV/FLAGUSR) JRN(FLGDEV/QSQJRN) IMAGES(*BOTH)
```

**2. Build the service program**

```cl
CRTSQLRPGI OBJ(yourlib/FLAGSRV) SRCSTMF('src/sqlrpgle/FLAGSRV.sqlrpgle')
           OBJTYPE(*MODULE) DBGVIEW(*SOURCE) COMMIT(*NONE)
           CVTCCSID(*JOB)     /* required: IFS source is UTF-8 (CCSID 1208)  */

CRTSRVPGM  SRVPGM(yourlib/FLAGSRV) MODULE(yourlib/FLAGSRV)
           SRCSTMF('src/bnd/FLAGSRV.bnd')
           ACTGRP(FLAGS)      /* named group: cache persists per job   */
           USRPRF(*OWNER)     /* adopt authority to the flag tables    */

/* Binding directory so consumers just need bnddir('FLAGBND') */
CRTBNDDIR  BNDDIR(yourlib/FLAGBND)
ADDBNDDIRE BNDDIR(yourlib/FLAGBND) OBJ((yourlib/FLAGSRV *SRVPGM))
```

> **Why `USRPRF(*OWNER)`:** consumers then need no authority to
> `FLAGDEF`/`FLAGUSR`/`FLAGCTL`. Because authority is adopted, SQL `CURRENT_USER`
> would return the *owner* — so evaluation reads the **job user** (`SESSION_USER`)
> instead. That is the identity `flag_isOn()` targets.

### Option C — store source in library source files and build from there

The default layout above keeps source as **IFS stream files** and builds with
`SRCSTMF(...)`. If your shop prefers the traditional model — source as **members in
source physical files** inside a library — use this path instead.

#### Store the source as members

IFS filenames don't all translate to valid member names (a member name can't start
with a digit), so two files are renamed on the way in:

| IFS source file | Target member | `SRCTYPE` |
|---|---|---|
| `src/sqlrpgle/FLAGSRV.sqlrpgle` | `QRPGLESRC(FLAGSRV)` | `SQLRPGLE` |
| `src/copy/FLAGSRV_H.rpgleinc` | `QRPGLESRC(FLAGSRV_H)` | `RPGLE` |
| `src/bnd/FLAGSRV.bnd` | `QSRVSRC(FLAGSRV)` | `BND` |
| `src/ddl/01_tables.sql` | `QSQLSRC(FLAGTABLES)` | `SQL` |
| `src/ddl/02_procedures.sql` | `QSQLSRC(FLAGPROCS)` | `SQL` |

Create the source files and members once, then copy the stream files in. Use
`CPYFRMSTMF` rather than a plain file copy — it converts the IFS text (UTF-8/ASCII)
to the member's EBCDIC CCSID; a raw byte copy would corrupt the source.

```cl
/* 1. Source physical files (112-byte records is the common default) */
CRTSRCPF FILE(INTGRTV/QRPGLESRC) RCDLEN(112) TEXT('RPG source')
CRTSRCPF FILE(INTGRTV/QSQLSRC)   RCDLEN(112) TEXT('SQL source')
CRTSRCPF FILE(INTGRTV/QSRVSRC)   RCDLEN(112) TEXT('Binder source')

/* 2. Members, each with its source type */
ADDPFM FILE(INTGRTV/QRPGLESRC) MBR(FLAGSRV)    SRCTYPE(SQLRPGLE)
ADDPFM FILE(INTGRTV/QRPGLESRC) MBR(FLAGSRV_H)  SRCTYPE(RPGLE)
ADDPFM FILE(INTGRTV/QSRVSRC)   MBR(FLAGSRV)    SRCTYPE(BND)
ADDPFM FILE(INTGRTV/QSQLSRC)   MBR(FLAGTABLES) SRCTYPE(SQL)
ADDPFM FILE(INTGRTV/QSQLSRC)   MBR(FLAGPROCS)  SRCTYPE(SQL)

/* 3. Populate members from the IFS stream files (converts CCSID) */
CPYFRMSTMF FROMSTMF('src/sqlrpgle/FLAGSRV.sqlrpgle')
           TOMBR('/QSYS.LIB/INTGRTV.LIB/QRPGLESRC.FILE/FLAGSRV.MBR')
           MBROPT(*REPLACE) STMFCCSID(*STMF) DBFCCSID(*FILE)
CPYFRMSTMF FROMSTMF('src/copy/FLAGSRV_H.rpgleinc')
           TOMBR('/QSYS.LIB/INTGRTV.LIB/QRPGLESRC.FILE/FLAGSRV_H.MBR')
           MBROPT(*REPLACE) STMFCCSID(*STMF) DBFCCSID(*FILE)
CPYFRMSTMF FROMSTMF('src/bnd/FLAGSRV.bnd')
           TOMBR('/QSYS.LIB/INTGRTV.LIB/QSRVSRC.FILE/FLAGSRV.MBR')
           MBROPT(*REPLACE) STMFCCSID(*STMF) DBFCCSID(*FILE)
CPYFRMSTMF FROMSTMF('src/ddl/01_tables.sql')
           TOMBR('/QSYS.LIB/INTGRTV.LIB/QSQLSRC.FILE/FLAGTABLES.MBR')
           MBROPT(*REPLACE) STMFCCSID(*STMF) DBFCCSID(*FILE)
CPYFRMSTMF FROMSTMF('src/ddl/02_procedures.sql')
           TOMBR('/QSYS.LIB/INTGRTV.LIB/QSQLSRC.FILE/FLAGPROCS.MBR')
           MBROPT(*REPLACE) STMFCCSID(*STMF) DBFCCSID(*FILE)
```

> **One source edit is required.** `FLAGSRV.sqlrpgle` includes the copybook by IFS
> path — `/copy 'src/copy/FLAGSRV_H.rpgleinc'`. That directive only resolves against
> the IFS, so in the `FLAGSRV` *member* change it to reference the member instead:
> ```rpgle
> /copy QRPGLESRC,FLAGSRV_H
> ```
> With `INTGRTV` on the job's library list the compiler finds `FLAGSRV_H` there.
> (Keep the stream-file source as the canonical copy; this swap is only in the member
> used for the library build.)

#### Build from the members

`build/BUILDLIB.clle` does all of this in one shot (the member-source counterpart to
`BUILDALL`), assuming the source lives in `INTGRTV`:

```cl
CRTBNDCL PGM(INTGRTV/BUILDLIB) SRCSTMF('build/BUILDLIB.clle')

/* CALL param: test lib for the RPGUnit program (*NONE to skip) */
CALL INTGRTV/BUILDLIB ('*NONE')
```

It adds `INTGRTV` to `*LIBL`, runs the SQL members, journals the tables, builds the
module + `*SRVPGM`, and creates the `FLAGBND` binding directory. The manual steps
below are the same work broken out — same objects as Option B, but every step reads
`SRCFILE`/`SRCMBR` instead of `SRCSTMF`.

```cl
/* 1. Data objects + admin procedures (run the SQL members) */
RUNSQLSTM SRCFILE(INTGRTV/QSQLSRC) SRCMBR(FLAGTABLES) COMMIT(*NONE) DFTRDBCOL(INTGRTV)
RUNSQLSTM SRCFILE(INTGRTV/QSQLSRC) SRCMBR(FLAGPROCS)  COMMIT(*NONE) DFTRDBCOL(INTGRTV)

STRJRNPF FILE(INTGRTV/FLAGDEF INTGRTV/FLAGUSR) JRN(INTGRTV/QSQJRN) IMAGES(*BOTH)

/* 2. Service program (ensure INTGRTV is on *LIBL so the /copy member resolves) */
ADDLIBLE   LIB(INTGRTV)
CRTSQLRPGI OBJ(INTGRTV/FLAGSRV) SRCFILE(INTGRTV/QRPGLESRC) SRCMBR(FLAGSRV)
           OBJTYPE(*MODULE) DBGVIEW(*SOURCE) COMMIT(*NONE)
CRTSRVPGM  SRVPGM(INTGRTV/FLAGSRV) MODULE(INTGRTV/FLAGSRV)
           SRCFILE(INTGRTV/QSRVSRC) SRCMBR(FLAGSRV)
           ACTGRP(FLAGS) USRPRF(*OWNER)

/* 3. Binding directory for consumers */
CRTBNDDIR  BNDDIR(INTGRTV/FLAGBND)
ADDBNDDIRE BNDDIR(INTGRTV/FLAGBND) OBJ((INTGRTV/FLAGSRV *SRVPGM))
```

To build the RPGUnit test the same way, copy `test/FLAGSRVT.sqlrpgle` into a member
(e.g. `QRPGLESRC(FLAGSRVT)`, type `SQLRPGLE`), apply the same `/copy QRPGLESRC,FLAGSRV_H`
edit, and build with `RUCRTTST TSTPGM(INTGRTV/FLAGSRVT) SRCFILE(INTGRTV/QRPGLESRC)
SRCMBR(FLAGSRVT) BNDDIR(INTGRTV/FLAGBND)`.

---

## Using the system

### From a consumer RPG program

Add one `/copy` and one binding-directory reference, then call the API:

```rpgle
**free
ctl-opt bnddir('FLAGBND');
/copy 'src/copy/FLAGSRV_H.rpgleinc'    // or a QRPGLESRC member

// Resolve for the current job user
if flag_isOn('NEW_PRICING_ENGINE');
  // new path
endif;

// Resolve as if a specific user were current
if flag_isOnFor('NEW_PRICING_ENGINE' : 'DEVUSER1');
  // ...
endif;
```

#### Public API (`FLAGSRV_H`)

| Procedure | Signature | Returns / effect |
|-----------|-----------|------------------|
| `flag_isOn` | `(name varchar(50))` | `*ON`/`*OFF` for the current job user. Unknown/retired/error → OFF. |
| `flag_isOnFor` | `(name varchar(50) : user char(10))` | `*ON`/`*OFF` as if `user` were current. |
| `flag_refresh` | `()` | Force the in-job cache to reload on the next evaluation. |
| `flag_setTtl` | `(seconds int(10))` | Override the cache TTL for this job (0 = always check version). |
| `flag_cachedCount` | `()` | Diagnostics: number of flag definitions currently cached. |

**Evaluation precedence** for a `(flag, user)`:

1. **User override** — a `FLAGUSR` row for `(flag, user)`, if present.
2. **Global default** — else `FLAGDEF.enabled` (active flags only).
3. **Fail-safe default** — else (missing/retired/error) → **OFF**.

### Administering flags

All writes go through stored procedures, callable from SQL, RPG, CL, or a future
REST layer. Flag names and user profiles are upper-cased automatically.

```sql
-- Define a flag (or update its description); state untouched if it already exists
CALL flag_create('NEW_PRICING_ENGINE', 'Route pricing through v2 engine');

-- Set the global default on/off (creates the flag if missing)
CALL flag_set('NEW_PRICING_ENGINE', 'N');

-- Per-user overrides
CALL flag_setuser('NEW_PRICING_ENGINE', 'DEVUSER1', 'Y');   -- on for one user
CALL flag_clearuser('NEW_PRICING_ENGINE', 'DEVUSER1');      -- back to default

-- Retire an obsolete flag (hidden from evaluation; its overrides are deleted)
CALL flag_retire('OLD_EXPERIMENT');

-- Inspect state
SELECT * FROM flagview WHERE flag_name = 'NEW_PRICING_ENGINE';
```

Changes propagate to running jobs within the cache TTL (default 60s). Call
`flag_refresh()` in a job to pick them up immediately, or `flag_setTtl(5)` to
shorten the window for interactive/QA jobs.

---

## The worked example — `DEMO01`

`DEMO01` is a small 5250 program that exists to make the point visible: **one program,
two behaviours, no recompile and no job restart.**

```
ADDLIBLE LIB(FLGDEV)
CALL FLGDEV/DEMO01
```

The screen shows a list price and what you actually pay. With `NEW_PRICING` on it
applies a 15% loyalty discount; with it off you get the classic price. Flip the flag
from anywhere — another 5250 session, Run SQL Scripts, VS Code — and press **F5**:

```sql
CALL FLGDEV.FLAG_SET('NEW_PRICING','N');
```

It binds to `FLAGSRV` the same way any consumer would: `ctl-opt bnddir('FLAGBND')`,
`/copy` the prototypes, then `flag_isOn('NEW_PRICING')`. Nothing special.

> **Why F5 calls `flag_refresh()` first.** Without it the screen would not change,
> because `FLAGSRV` is serving a warm cache hit — no I/O at all until the TTL expires
> (default 60s). That is the service program working correctly, not a bug. `F5` forces
> the reload, which is exactly what `flag_refresh()` is exported for.

Build it with `build/BUILDDEMO.clle`, which builds the whole stack — data model,
journal, service program, display file, program — into one library:

```cl
CRTBNDCL PGM(FLGDEV/BUILDDEMO) SRCSTMF('build/BUILDDEMO.clle')
CALL FLGDEV/BUILDDEMO ('/home/you/rpg-feature-flags' 'FLGDEV')
```

> **Pad the parameters.** `ROOT` is `CHAR(256)` and `LIB` is `CHAR(10)`. Passing a
> shorter literal leaves the program reading past the end of the value, which shows up
> as a confusing `CPFA0A9` on the first `CHGCURDIR`.

> **Exit the program before rebuilding.** A running `DEMO01` holds a lock on the
> display file and the build cannot replace it. `BUILDDEMO` says so in plain words
> rather than failing with a bare `CPF0610`.

---

## Continuous integration

`.github/workflows/build.yml` builds this repo on a real IBM i on every push to `main`
and every pull request.

```
   GitHub  ──(runner polls outbound)──►  runner machine  ──(SSH, local)──►  IBM i
   source + workflow                     runs the job                       compiles
```

**GitHub never reaches the IBM i**, and **no IBM i credential is stored in GitHub**. The
runner is self-hosted inside your network and reads its SSH key off local disk at run
time. See [`.github/workflows/README.md`](.github/workflows/README.md) for setup.

**A branch gets its own library.** `main` builds into `FLGDEV`; any other branch builds
into a library named after it (`feature/pricing` → `FLGFEATURE`). `BUILDDEMO` builds the
*entire* stack, so a branch library starts empty and ends with a complete, working copy
of the system — which is how you get branch isolation on a platform with one set of
objects per library.

```
DSPOBJD OBJ(FLGDEV/DEMO01) OBJTYPE(*PGM)
DSPOBJD OBJ(FLGFEATURE/DEMO01) OBJTYPE(*PGM)
```

The pipeline uses [`ibmi-ci`](https://github.com/IBM/ibmi-ci) (`ici`): `--push` uploads
the working tree while skipping `.git` and dotfiles, and `--cl` runs CL directly with no
`system "..."` quoting to fight.

> **Each `--cl` still gets its own job**, so a library list set in one does not carry to
> the next — verified directly. That is why the real build lives in a CL program, which
> does its own `ADDLIBLE` and runs everything in one job.

---

## Running the tests

Point the test job's library list at a throwaway data library (e.g. `FLGUT`) that
has the tables + admin procedures, then:

```cl
RUCALLTST TSTPGM(FLGUT/FLAGSRVT)                        /* all tests */
RUCALLTST TSTPGM(FLGUT/FLAGSRVT) TSTPRC(testUserOverrideWins)
```

The suite ([`test/FLAGSRVT.sqlrpgle`](test/FLAGSRVT.sqlrpgle)) covers global-default
on/off, unknown-flag fail-safe, user-override precedence (both directions), default
fallback for an unlisted user, case-insensitive flag names, and cache reload via the
version stamp. Each test seeds `UT_`-prefixed flags in `setUp` and retires them in
`tearDown`, so it is safe to run repeatedly against the test library.

---

## Extending it later

When adding a new procedure to `FLAGSRV`, append its `EXPORT SYMBOL(...)` at the
**end** of the `*CURRENT` block in [`src/bnd/FLAGSRV.bnd`](src/bnd/FLAGSRV.bnd) — do
not reorder existing entries — so the `FLAGSRV_V1` signature stays compatible and
existing consumers need no recompile.

> **Use double quotes around the symbol.** The prototypes use `extproc(*dclcase)`, so
> the module exports mixed-case names (`flag_isOn`). Binder language folds a
> *single*-quoted symbol to upper case, and the bind then fails with `CPF5D05` —
> an error that says nothing about letter case. Write `EXPORT SYMBOL("flag_newThing")`.

Deferred (not in v1, but the data model leaves room): percentage rollouts/segments,
flag scheduling, multivariate values, per-flag fail-open, and a web admin UI over
the stored procedures via IBM i Integrated Web Services. See §14 of the design doc.

## License

MIT — see [LICENSE](LICENSE). Copyright (c) 2026 Integrative Systems.
