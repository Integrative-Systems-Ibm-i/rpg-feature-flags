**free
// =====================================================================
//  FLAGSRV  -  Feature flag service program (*SRVPGM).
//
//  Build:   CRTSQLRPGI OBJ(FLAGSRV) SRCSTMF('src/sqlrpgle/FLAGSRV.sqlrpgle')
//                       OBJTYPE(*MODULE) DBGVIEW(*SOURCE) COMMIT(*NONE)
//           CRTSRVPGM  SRVPGM(FLAGSRV) MODULE(FLAGSRV)
//                       SRCSTMF('src/bnd/FLAGSRV.bnd')
//                       ACTGRP(*CALLER)          // see activation-group note
//                       USRPRF(*OWNER)           // adopt authority to flag tables
//
//  Data objects (FLAGDEF / FLAGUSR / FLAGCTL) are resolved via the job's
//  library list (*LIBL) -> environment is selected by the library list.
//
//  NOTE on activation group: the in-job cache lives in module-global (static)
//  storage, which persists for the life of the *activation group*. Bind with a
//  NAMED activation group (e.g. ACTGRP('FLAGS')) so the cache survives across
//  many consumer calls in a job. *CALLER also works but ties cache lifetime to
//  the caller's group. Single-threaded IBM i job model is assumed (see design).
//
//  See docs/feature-flags-design.md.
// =====================================================================
ctl-opt nomain option(*srcstmt : *nodebugio) datfmt(*iso) timfmt(*iso);
ctl-opt copyright('Feature flag service - see docs/feature-flags-design.md');

/copy 'src/copy/FLAGSRV_H.rpgleinc'

// ---------------------------------------------------------------------
//  Tunables / constants
// ---------------------------------------------------------------------
dcl-c MAX_FLAGS   5000;    // hard cap on cached flag definitions
dcl-c MAX_OVR    20000;    // hard cap on cached user overrides
dcl-c DFT_TTL       60;    // default seconds between version checks
dcl-c FAILSAFE  *off;      // fail-closed: unknown/error -> OFF
dcl-c LOWER 'abcdefghijklmnopqrstuvwxyz';
dcl-c UPPER 'ABCDEFGHIJKLMNOPQRSTUVWXYZ';

// ---------------------------------------------------------------------
//  Module-global (static) cache state  -  persists per activation group
// ---------------------------------------------------------------------
dcl-ds flagCache qualified dim(MAX_FLAGS);
  name    varchar(50);
  enabled char(1);                       // 'Y' / 'N'
end-ds;

dcl-ds ovrCache qualified dim(MAX_OVR);
  name    varchar(50);
  user    char(10);
  enabled char(1);                       // 'Y' / 'N'
end-ds;

dcl-s flagCount   int(10) inz(0);
dcl-s ovrCount    int(10) inz(0);
dcl-s cacheLoaded ind     inz(*off);
dcl-s forceReload ind     inz(*off);
dcl-s ttlSecs     int(10) inz(DFT_TTL);
dcl-s cachedVer   timestamp inz(*loval);
dcl-s lastCheck   timestamp inz(*loval);

// Program status DS: position 254 (len 10) = job user profile, unaffected by
// adopted authority (unlike SQL CURRENT_USER, which returns the owner here).
dcl-ds psds psds qualified;
  jobUser char(10) pos(254);
end-ds;

// ---------------------------------------------------------------------
//  Internal prototypes
// ---------------------------------------------------------------------
dcl-pr ensureFresh    ind;
end-pr;
dcl-pr loadCache      ind;
end-pr;
dcl-pr readVersion    ind;
  ver timestamp;
end-pr;
dcl-pr toUpper        varchar(50);
  inText varchar(50) const;
end-pr;

// =====================================================================
//  PUBLIC: flag_isOn  -  evaluate for the current job user.
// =====================================================================
dcl-proc flag_isOn export;
  dcl-pi *n ind;
    name varchar(50) const;
  end-pi;
  return flag_isOnFor(name : psds.jobUser);
end-proc;

// =====================================================================
//  PUBLIC: flag_isOnFor  -  evaluate for an explicit user profile.
//  Precedence:  user override  ->  global default  ->  fail-safe (OFF).
// =====================================================================
dcl-proc flag_isOnFor export;
  dcl-pi *n ind;
    name varchar(50) const;
    user char(10)    const;
  end-pi;
  dcl-s key    varchar(50);
  dcl-s uUser  char(10);
  dcl-s i      int(10);

  // If the cache cannot be made valid, fail safe rather than error the caller.
  if not ensureFresh();
    return FAILSAFE;
  endif;

  key   = toUpper(name);
  uUser = %xlate(LOWER : UPPER : user);

  // 1) User override wins.
  for i = 1 to ovrCount;
    if ovrCache(i).name = key and ovrCache(i).user = uUser;
      return (ovrCache(i).enabled = 'Y');
    endif;
  endfor;

  // 2) Global default for an active flag.
  for i = 1 to flagCount;
    if flagCache(i).name = key;
      return (flagCache(i).enabled = 'Y');
    endif;
  endfor;

  // 3) Unknown / retired flag -> fail safe. (Caller-side dead-flag logging can
  //    hook here; kept quiet on the hot path in v1.)
  return FAILSAFE;
end-proc;

// =====================================================================
//  PUBLIC: flag_refresh  -  force reload on next evaluation.
// =====================================================================
dcl-proc flag_refresh export;
  dcl-pi *n end-pi;
  forceReload = *on;
end-proc;

// =====================================================================
//  PUBLIC: flag_setTtl
// =====================================================================
dcl-proc flag_setTtl export;
  dcl-pi *n;
    seconds int(10) const;
  end-pi;
  if seconds >= 0;
    ttlSecs = seconds;
  endif;
end-proc;

// =====================================================================
//  PUBLIC: flag_cachedCount
// =====================================================================
dcl-proc flag_cachedCount export;
  dcl-pi *n int(10) end-pi;
  return flagCount;
end-proc;

// =====================================================================
//  INTERNAL: ensureFresh
//  - Warm path (within TTL): no I/O, return current cache.
//  - TTL elapsed: read one FLAGCTL row; reload only if the version moved.
//  - On SQL error: keep last-good cache if we have one; else fail.
//  Returns *ON when the cache is usable.
// =====================================================================
dcl-proc ensureFresh;
  dcl-pi *n ind end-pi;
  dcl-s now      timestamp;
  dcl-s liveVer  timestamp;

  now = %timestamp();

  if not forceReload
     and cacheLoaded
     and %diff(now : lastCheck : *seconds) < ttlSecs;
    return *on;                             // warm hit, no I/O
  endif;

  // Time to check the version stamp.
  if readVersion(liveVer);
    lastCheck = now;
    if cacheLoaded and not forceReload and liveVer = cachedVer;
      return *on;                           // nothing changed
    endif;
    if loadCache();
      cachedVer   = liveVer;
      cacheLoaded = *on;
      forceReload = *off;
      return *on;
    endif;
  endif;

  // Version read or reload failed: serve last-good cache if we have one.
  return cacheLoaded;
end-proc;

// =====================================================================
//  INTERNAL: readVersion  -  read the singleton FLAGCTL.version_ts.
// =====================================================================
dcl-proc readVersion;
  dcl-pi *n ind;
    ver timestamp;
  end-pi;

  exec sql
    select version_ts into :ver
      from flagctl
     where singleton = '1'
      with nc;

  return (sqlcode = 0);
end-proc;

// =====================================================================
//  INTERNAL: loadCache  -  bulk-load active flags and all overrides.
//  Uses multi-row FETCH into the global DS arrays; row counts via
//  GET DIAGNOSTICS. COMMIT(*NONE) / isolation NC keeps reads cheap.
// =====================================================================
dcl-proc loadCache;
  dcl-pi *n ind end-pi;

  // --- flag definitions (active only) ---
  exec sql
    declare curDef cursor for
      select flag_name, enabled
        from flagdef
       where status = 'A'
       order by flag_name
        with nc;
  exec sql open curDef;
  if sqlcode <> 0;
    return *off;
  endif;

  exec sql fetch curDef for :MAX_FLAGS rows into :flagCache;
  if sqlcode < 0;
    exec sql close curDef;
    return *off;
  endif;
  exec sql get diagnostics :flagCount = ROW_COUNT;
  exec sql close curDef;

  // --- user overrides ---
  exec sql
    declare curOvr cursor for
      select flag_name, user_profile, enabled
        from flagusr
       order by flag_name, user_profile
        with nc;
  exec sql open curOvr;
  if sqlcode <> 0;
    return *off;
  endif;

  exec sql fetch curOvr for :MAX_OVR rows into :ovrCache;
  if sqlcode < 0;
    exec sql close curOvr;
    return *off;
  endif;
  exec sql get diagnostics :ovrCount = ROW_COUNT;
  exec sql close curOvr;

  return *on;
end-proc;

// =====================================================================
//  INTERNAL: toUpper  -  case-fold flag names for lookup.
// =====================================================================
dcl-proc toUpper;
  dcl-pi *n varchar(50);
    inText varchar(50) const;
  end-pi;
  return %xlate(LOWER : UPPER : inText);
end-proc;
