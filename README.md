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
  bnd/FLAGSRV.bnd             binder source (frozen signature FLAGSRV_V1)
  ddl/01_tables.sql           tables, version-bump triggers, flagview
  ddl/02_procedures.sql       admin stored procedures
  README.md                   component build reference
build/
  BUILDALL.clle               one CL program that builds everything
test/
  FLAGSRVT.sqlrpgle           RPGUnit test suite
docs/
  feature-flags-design.md     full design document
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

/* Enable journaling for audit */
STRJRNPF FILE(FLGDEV/FLAGDEF FLGDEV/FLAGUSR) JRN(FLGDEV/QSQJRN) IMAGES(*BOTH)
```

**2. Build the service program**

```cl
CRTSQLRPGI OBJ(yourlib/FLAGSRV) SRCSTMF('src/sqlrpgle/FLAGSRV.sqlrpgle')
           OBJTYPE(*MODULE) DBGVIEW(*SOURCE) COMMIT(*NONE)

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

Deferred (not in v1, but the data model leaves room): percentage rollouts/segments,
flag scheduling, multivariate values, per-flag fail-open, and a web admin UI over
the stored procedures via IBM i Integrated Web Services. See §14 of the design doc.
