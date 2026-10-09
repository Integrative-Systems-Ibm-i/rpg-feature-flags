# Feature Flag System for IBM i (RPG) — Design Document

- **Status:** Draft
- **Author:** _TBD_
- **Date:** 2026-09-04
- **Platform:** IBM i (7.4+), ILE RPG (fully-free), Db2 for i, embedded SQL
- **Reviewers:** _TBD_

---

## 1. Overview

This document describes the design of a lightweight **feature flag** system for
applications written in **ILE RPG on IBM i**. The goal is to let developers wrap
new or risky behavior behind named flags that can be turned **on/off at runtime —
without recompiling programs or restarting jobs/subsystems** — and to optionally
scope a flag to specific **IBM i user profiles**.

The system is deliberately small: it is a Db2 for i data model plus a single ILE
**service program** (`FLAGSRV`) that RPG programs bind to and call. It is **not** a
general-purpose experimentation/analytics platform.

### The core developer experience

```rpgle
**free
ctl-opt bnddir('FLAGBND');
/copy QRPGLESRC,FLAGSRV_H

if flag_isOn('NEW_PRICING_ENGINE');
  price = calcPrice_v2(order);
else;
  price = calcPrice_v1(order);
endif;
```

That single `flag_isOn(...)` call is the entire public contract for the common case.

---

## 2. Goals and non-goals

### Goals
1. **Runtime toggling** — a flag can be flipped on/off with no program recompile,
   no job restart, effective within a bounded, configurable delay (default ≤ 60s).
2. **Simple on/off flags** with a global default.
3. **Per-user-profile targeting** — override a flag on/off for named IBM i user
   profiles (e.g., enable for `DEVUSER1`, `QA_TEAM` members before general rollout).
4. **Fast evaluation** — safe to call on hot paths; sub-microsecond amortized cost
   via in-job caching, not a Db2 read per call.
5. **Environment isolation** — dev / test / prod share identical code and object
   names; the environment is selected by the job's **library list**, not by code.
6. **Fail-safe defaults** — unknown flag or data error resolves to a predictable,
   configurable outcome (default **OFF**).
7. **Auditability** — every flag change records who/what/when.
8. **Bind-and-go** — consuming programs add one `/copy` and one binding directory
   entry; no framework, no new subsystem.

### Non-goals (for v1)
- Percentage rollouts, cohort/segment rules, geo/region targeting.
- Multivariate values or A/B experiments with metric collection.
- Non-engineer self-serve GUI (a 5250 maintenance program is optional; a web UI is
  a future extension via IBM i Integrated Web Services).
- Client-side / off-platform evaluation (mobile, browser, non-IBM i services).
- Scheduling (auto-enable at a future timestamp) — deferred.

These are called out as **future extensions** in §13 so the v1 data model does not
paint us into a corner.

---

## 3. Terminology

| Term | Meaning |
|------|---------|
| **Flag** | A named boolean toggle, e.g. `NEW_PRICING_ENGINE`. |
| **Global default** | The flag's on/off value when no user-specific rule applies. |
| **User override** | An on/off value for a specific IBM i user profile. |
| **Evaluation** | Resolving a flag to `*ON`/`*OFF` for a given user at a given time. |
| **Consumer** | An RPG program/service program that calls `FLAGSRV` to read flags. |
| **Config version** | A single timestamp that changes whenever any flag data changes; used for cheap cache invalidation. |

---

## 4. Requirements

### Functional
- FR1: Evaluate a flag for the **current job's user** — `flag_isOn(name)`.
- FR2: Evaluate a flag for an **explicit user profile** — `flag_isOnFor(name, user)`.
- FR3: Create, update (enable/disable), and retire flags.
- FR4: Set/clear per-user overrides.
- FR5: Changes take effect in all running jobs within the TTL window without restart.
- FR6: A consumer can force an immediate cache refresh — `flag_refresh()`.
- FR7: Unknown flags resolve to a safe default and are recorded for cleanup.

### Non-functional
- NFR1: Amortized evaluation cost ≈ in-memory lookup (no per-call SQL after warm-up).
- NFR2: Environment selected by library list; identical object names across envs.
- NFR3: All writes journaled/audited (who, when, before/after).
- NFR4: Read access broad; write access restricted by object authority.
- NFR5: No dependency on a running server job or subsystem; pure ILE call stack.
- NFR6: Threadsafe enough for the intended activation-group model (see §8).

---

## 5. Architecture

```
        ┌──────────────────────────────────────────────────────────────┐
        │                     Consumer RPG programs                     │
        │   flag_isOn('X')   flag_isOnFor('X', user)   flag_refresh()   │
        └───────────────────────────────┬──────────────────────────────┘
                                         │ bound call (BNDDIR: FLAGBND)
                                         ▼
        ┌──────────────────────────────────────────────────────────────┐
        │                  FLAGSRV  (*SRVPGM, ILE RPG)                   │
        │  ┌────────────────────────────────────────────────────────┐  │
        │  │  In-job cache (static storage, named activation group)  │  │
        │  │   - flag array (name, global default)                   │  │
        │  │   - user-override array (name, user, value)             │  │
        │  │   - cachedVersionTs, lastCheckTs                        │  │
        │  └───────────────────────────┬────────────────────────────┘  │
        │           on TTL expiry, compare version → reload             │
        └───────────────────────────────┼──────────────────────────────┘
                                         │ embedded SQL (adopts authority)
                                         ▼
        ┌──────────────────────────────────────────────────────────────┐
        │                Db2 for i  (resolved via *LIBL)                 │
        │   FLAGCTL (1 row, version_ts)   FLAGDEF        FLAGUSR         │
        │   ── journaled ──               ── journaled ──                │
        └──────────────────────────────────────────────────────────────┘

        Administration (out of the hot path):
          Stored procedures  FLAG_SET / FLAG_SETUSER / FLAG_CREATE / FLAG_RETIRE
          Optional 5250 maintenance program  (WRKFLAG)  — future
```

**Key ideas**

- **One service program, statically bound.** No message queues, no data queues, no
  server jobs. Evaluation is an ILE procedure call.
- **Current user = job user, not `CURRENT_USER`.** Because `FLAGSRV` adopts owner
  authority (so consumers need no rights to the flag tables), SQL `CURRENT_USER`
  returns the *owner*. Evaluation therefore targets the **job user** read from the
  PSDS (SQL equivalent: `SESSION_USER`).
- **Cache lives in the job.** Static storage in a **named activation group** persists
  across calls for the life of the job, so steady-state evaluation touches no I/O.
- **Cheap invalidation via a version stamp.** All flag data lives behind a single
  `FLAGCTL.version_ts`. Triggers bump it on any change. The cache only re-reads flag
  data when (a) the TTL since last check has elapsed **and** (b) the version stamp
  actually moved. This keeps hot paths free of SQL while propagating changes within
  the TTL window.
- **Environment = library list.** `FLAGDEF`/`FLAGUSR`/`FLAGCTL` live in an
  environment-specific data library (e.g. `FLGPRD`, `FLGTST`, `FLGDEV`) placed on the
  job's `*LIBL`. Same names everywhere; the code never references a hard-coded library.

---

## 6. Data model (Db2 for i, SQL DDL)

Modern SQL DDL tables (not DDS physical files). Objects live in the environment's
flag data library.

```sql
-- Single-row control table: one timestamp that changes on ANY flag data change.
CREATE TABLE flagctl (
  singleton  CHAR(1)    NOT NULL DEFAULT '1',
  version_ts TIMESTAMP  NOT NULL DEFAULT CURRENT_TIMESTAMP,
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

-- Per user-profile overrides.
CREATE TABLE flagusr (
  flag_name    VARCHAR(50) NOT NULL,
  user_profile VARCHAR(10) NOT NULL,             -- IBM i user profile
  enabled      CHAR(1)     NOT NULL,             -- 'Y' / 'N' override
  changed_by   VARCHAR(10) NOT NULL DEFAULT USER,
  changed_ts   TIMESTAMP   NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (flag_name, user_profile),
  CONSTRAINT flagusr_enabled CHECK (enabled IN ('Y','N')),
  CONSTRAINT flagusr_fk FOREIGN KEY (flag_name)
    REFERENCES flagdef (flag_name) ON DELETE CASCADE
);
```

**Version-bump triggers** (so the cache can detect change by reading one row):

```sql
CREATE TRIGGER flagdef_ver AFTER INSERT OR UPDATE OR DELETE ON flagdef
  FOR EACH STATEMENT
  UPDATE flagctl SET version_ts = CURRENT_TIMESTAMP WHERE singleton = '1';

CREATE TRIGGER flagusr_ver AFTER INSERT OR UPDATE OR DELETE ON flagusr
  FOR EACH STATEMENT
  UPDATE flagctl SET version_ts = CURRENT_TIMESTAMP WHERE singleton = '1';
```

**Auditing:** enable native journaling on `FLAGDEF` and `FLAGUSR`
(`STRJRNPF`), which captures before/after images with user and timestamp for free.
The `changed_by`/`changed_ts` columns give a quick "latest change" view without
reading the journal.

---

## 7. Public API (service program `FLAGSRV`)

Prototype copybook `FLAGSRV_H` (fully-free RPG):

```rpgle
**free
/// FLAGSRV_H — Feature flag service program prototypes.

/// Evaluate a flag for the CURRENT job user. Returns *ON/*OFF.
dcl-pr flag_isOn ind extproc(*dclcase);
  name varchar(50) const;
end-pr;

/// Evaluate a flag for an explicit user profile. Returns *ON/*OFF.
dcl-pr flag_isOnFor ind extproc(*dclcase);
  name varchar(50) const;
  user char(10)     const;
end-pr;

/// Force the in-job cache to reload on the next evaluation.
dcl-pr flag_refresh extproc(*dclcase);
end-pr;

/// Optional: override the default cache TTL (seconds) for this job.
dcl-pr flag_setTtl extproc(*dclcase);
  seconds int(10) const;
end-pr;
```

**Contract**
- `flag_isOn('X')` resolves `X` for the job's current user (PSDS job user /
  `SESSION_USER`; **not** `CURRENT_USER`, which is the adopted owner — see §5).
- `flag_isOnFor('X', 'DEVUSER1')` resolves as if that user were current.
- Unknown/retired flag → **fail-safe default** (OFF by default; see §9), and the
  name is recorded once per job to a diagnostic log for cleanup.
- All procedures are safe to call before/without any explicit init call; the cache
  self-initializes on first use.

---

## 8. Evaluation and caching

### Evaluation precedence
For a `(flag, user)`:
1. **User override** — if a `FLAGUSR` row exists for `(flag, user)`, use it.
2. **Global default** — else use `FLAGDEF.enabled` (active flags only).
3. **Fail-safe default** — else (flag missing/retired/error) return the configured
   default (OFF).

### Caching model
- The service program holds two arrays in **static storage** (flag defaults; user
  overrides) plus `cachedVersionTs` and `lastCheckTs`.
- **Warm read path (the common case):** `now - lastCheckTs <= TTL` → answer straight
  from the arrays. **No SQL.**
- **TTL elapsed:** read the single `FLAGCTL.version_ts` row.
  - Unchanged → update `lastCheckTs`, keep cache. (One tiny keyed read.)
  - Changed → reload `FLAGDEF` + `FLAGUSR` into the arrays, store new version.
- `flag_refresh()` forces a reload on next call; `flag_setTtl()` tunes the window.

**Why the version stamp:** it decouples "how often we check" (cheap, one row) from
"how often we reload everything" (only on real change). Default TTL 60s balances
propagation latency against DB traffic; interactive/QA jobs can set a shorter TTL.

### Activation group / persistence
- Build `FLAGSRV` into a **named activation group** (e.g. `ACTGRP('FLAGS')`) so its
  static cache persists for the life of the job across many consumer calls.
- Consumers can run in `*CALLER` or their own groups; that does not affect the cache,
  which is scoped to `FLAGSRV`'s activation group within the job.
- **Threading note:** the cache uses simple static storage and is designed for the
  standard one-job-one-thread IBM i model. If a consumer runs multi-threaded, either
  serialize access or run `FLAGSRV` per-thread; v1 documents the single-threaded
  assumption rather than paying for locking on the hot path. (Revisit in §12.)

---

## 9. Fail-safe behavior and error handling

- **Default on error/unknown = OFF** ("fail closed"), the safe choice for gating
  *new* behavior: a data outage leaves everyone on the proven code path.
- The default is configurable at build time via a compile constant, and a flag can
  opt into "fail open" later if needed (future; see §13). v1 ships fail-closed.
- SQL errors during (re)load are trapped; the service program keeps serving the
  **last good cache** if it has one, and only falls back to the default when it has
  no cache at all. Errors are logged to the job log / a diagnostic message.
- Unknown flag names are collected per job and emitted once to aid dead-flag cleanup.

---

## 10. Environments

- Three (or more) flag **data libraries**, one per environment, all with identical
  object names: e.g. `FLGDEV`, `FLGTST`, `FLGPRD`.
- Jobs get the correct one via their **library list** (job description / initial
  library list). The code never qualifies the library — `*LIBL` resolves it.
- Promotion of a *flag definition* (its existence/description) can follow normal
  change management; the *enabled state* is environment-local and set per env.
- This gives clean isolation with zero code branching per environment.

---

## 11. Administration

Writes go through **stored procedures** (so they can be called from RPG, SQL, CL, or
a future web service), each running with the necessary adopted authority:

```sql
-- Create or update a flag's global default.
CALL flag_set('NEW_PRICING_ENGINE', 'Y');
-- Set / clear a per-user override.
CALL flag_setuser('NEW_PRICING_ENGINE', 'DEVUSER1', 'Y');
CALL flag_clearuser('NEW_PRICING_ENGINE', 'DEVUSER1');
-- Define a new flag with description; retire an obsolete one.
CALL flag_create('NEW_PRICING_ENGINE', 'Route pricing through v2 engine');
CALL flag_retire('OLD_EXPERIMENT');
```

- **Read-only helpers / views** for dashboards and ops: `FLAGDEF`, `FLAGUSR`, plus a
  convenience view joining them for "who is this flag on for."
- **Optional 5250 maintenance program (`WRKFLAG`)** — a subfile to list/toggle flags
  and manage overrides for admins who prefer green-screen. Marked optional for v1.
- **Future web UI** — expose the stored procedures via IBM i **Integrated Web
  Services (IWS)** as REST, front it with a small SPA. Deferred (§13).

---

## 12. Security and authority

- Flag data library owned by a dedicated group profile (e.g. `FLAGOWN`).
- **Read:** granted broadly to application groups (needed by every consumer job).
  `FLAGSRV` adopts authority (`USRPRF(*OWNER)`) so consumers need no direct authority
  to the files.
- **Write:** `*EXCLUDE`/`*USE` for general users; the admin stored procedures adopt
  owner authority so only authorized callers of those procedures can change flags.
- Journaling provides a tamper-evident record of all data changes.

---

## 13. Testing

- **Unit:** RPGUnit test service program covering evaluation precedence, fail-safe
  defaults, TTL/version reload logic, and case handling of flag names/user profiles.
- **Isolation:** tests run against a dedicated test flag library placed on the test
  job's library list, so they never touch prod data.
- **Cache tests:** simulate version bumps and TTL expiry to assert reload happens
  exactly when expected and not more often.
- **Concurrency smoke test:** many jobs reading while an admin toggles, asserting
  propagation within TTL and no errors on reload.

---

## 14. Future extensions (explicitly out of v1, but the model allows them)

- **Percentage rollouts / segments:** add a `FLAGRULE` table (rule type, params,
  priority) evaluated before the global default; hash on user profile for stable
  bucketing.
- **Scheduling:** `effective_from` / `effective_to` timestamps on `FLAGDEF`.
- **Multivariate / string values:** widen `enabled` to a `value` column + type.
- **Fail-open per flag:** a `fail_mode` column consulted on error.
- **Web admin UI** via IWS REST over the existing stored procedures.
- **Cross-partition sync:** replicate the flag library (or a shared IASP) if multiple
  LPARs must share flag state.

---

## 15. Open questions

1. **Which user identity targets?** The IBM i job user (PSDS / `SESSION_USER`) vs. an
   *application* user your programs carry separately. The design assumes the job
   user; confirm, or add a `flag_isOnFor(name, user)` call at the app-user boundary.
2. **TTL default** — is ≤ 60s propagation acceptable for prod, or do some flags
   (kill switches) need near-immediate effect (→ shorter TTL or a push mechanism)?
3. **IBM i / RPG level** — confirm 7.4+ and fully-free RPG so we can use the SQL DDL,
   triggers, and modern language features above.
4. **Naming/registry** — do we want flags declared in source (a checked-in registry)
   and reconciled to the DB, or is the DB the sole source of truth?
5. **Green-screen admin in v1?** Is `WRKFLAG` needed at launch, or are stored
   procedures + SQL enough initially?
6. **Multi-LPAR** — is flag state ever shared across partitions, or strictly per-LPAR?

---

## 16. Proposed delivery phases

1. **Phase 1 — Core:** data model + triggers + `FLAGSRV` (`flag_isOn`,
   `flag_isOnFor`, `flag_refresh`) + fail-safe defaults + journaling. Stored
   procedures for admin. RPGUnit tests.
2. **Phase 2 — Targeting polish & ops:** convenience views, `flag_setTtl`, dead-flag
   reporting, optional `WRKFLAG` 5250 program.
3. **Phase 3 — Reach (as needed):** IWS REST + web UI, percentage rollouts,
   scheduling.
