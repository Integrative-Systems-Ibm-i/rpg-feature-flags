**free
// =====================================================================
//  FLAGSRVT  -  RPGUnit tests for the FLAGSRV feature flag service.
//
//  Build (RPGUnit's test-case builder; precompiles the embedded SQL):
//    RUCRTTST TSTPGM(yourlib/FLAGSRVT)
//             SRCSTMF('test/FLAGSRVT.sqlrpgle')
//             BNDDIR(yourlib/FLAGBND)          // to bind FLAGSRV
//             COMMIT(*NONE)
//  Run:
//    RUCALLTST TSTPGM(yourlib/FLAGSRVT)         // all test* procedures
//    RUCALLTST TSTPGM(yourlib/FLAGSRVT) TSTPRC(testUserOverrideWins)
//
//  Requires the flag tables + admin procedures to exist on the *LIBL of the
//  job that runs the tests (point it at a throwaway TEST library, e.g. FLGUT).
//  Every seeded flag is prefixed UT_ and retired in tearDown.
// =====================================================================
ctl-opt nomain option(*srcstmt : *nodebugio);

/include qinclude,TESTCASE          // RPGUnit assertions: assert / aEqual / iEqual
/copy 'src/copy/FLAGSRV_H.rpgleinc'

dcl-s gJobUser char(10);

// ---------------------------------------------------------------------
//  setUp  -  runs before EACH test.  Seed a clean, known flag set and
//  force the service cache to reload immediately (TTL 0 = always check).
// ---------------------------------------------------------------------
dcl-proc setUp export;
  dcl-pi *n end-pi;

  exec sql values session_user into :gJobUser;   // the job user flag_isOn targets

  cleanup();

  exec sql call flag_set('UT_ON'   , 'Y');       // global default ON
  exec sql call flag_set('UT_OFF'  , 'N');       // global default OFF
  exec sql call flag_set('UT_CASE' , 'Y');       // for case-folding test

  // Override precedence fixtures (override opposes the global default).
  exec sql call flag_set('UT_OVR_ON' , 'N');
  exec sql call flag_setuser('UT_OVR_ON' , :gJobUser, 'Y');
  exec sql call flag_set('UT_OVR_OFF', 'Y');
  exec sql call flag_setuser('UT_OVR_OFF', :gJobUser, 'N');

  flag_setTtl(0);
  flag_refresh();
end-proc;

// ---------------------------------------------------------------------
//  tearDown  -  runs after EACH test.
// ---------------------------------------------------------------------
dcl-proc tearDown export;
  dcl-pi *n end-pi;
  cleanup();
  flag_refresh();
end-proc;

dcl-proc cleanup;
  exec sql call flag_retire('UT_ON');
  exec sql call flag_retire('UT_OFF');
  exec sql call flag_retire('UT_CASE');
  exec sql call flag_retire('UT_OVR_ON');
  exec sql call flag_retire('UT_OVR_OFF');
  exec sql call flag_retire('UT_RELOAD');
end-proc;

// =====================================================================
//  Tests
// =====================================================================

/// Global default ON resolves to *ON.
dcl-proc testGlobalDefaultOn export;
  dcl-pi *n end-pi;
  assert(flag_isOn('UT_ON') = *on : 'UT_ON should be on');
end-proc;

/// Global default OFF resolves to *OFF.
dcl-proc testGlobalDefaultOff export;
  dcl-pi *n end-pi;
  assert(flag_isOn('UT_OFF') = *off : 'UT_OFF should be off');
end-proc;

/// Unknown flag fails safe (OFF), never errors the caller.
dcl-proc testUnknownFlagFailsSafeOff export;
  dcl-pi *n end-pi;
  assert(flag_isOn('UT_DOES_NOT_EXIST') = *off :
         'unknown flag must fail safe to off');
end-proc;

/// A user override beats the global default in BOTH directions.
dcl-proc testUserOverrideWins export;
  dcl-pi *n end-pi;
  assert(flag_isOnFor('UT_OVR_ON'  : gJobUser) = *on :
         'override Y must beat default N');
  assert(flag_isOnFor('UT_OVR_OFF' : gJobUser) = *off :
         'override N must beat default Y');
end-proc;

/// A user with no override falls back to the global default.
dcl-proc testNoOverrideUsesDefault export;
  dcl-pi *n end-pi;
  // UT_OVR_ON default is N; a different user has no override -> default N.
  assert(flag_isOnFor('UT_OVR_ON' : 'QSECOFR') = *off :
         'unlisted user should get the global default');
end-proc;

/// Flag-name lookup is case-insensitive.
dcl-proc testFlagNameCaseInsensitive export;
  dcl-pi *n end-pi;
  assert(flag_isOn('ut_case') = *on : 'lowercase name should match UT_CASE');
end-proc;

/// A change made after the cache warmed is picked up via the version stamp.
/// TTL is 0 in setUp, so the next call re-reads FLAGCTL and reloads on change.
dcl-proc testReloadOnVersionChange export;
  dcl-pi *n end-pi;
  exec sql call flag_set('UT_RELOAD', 'N');
  flag_refresh();
  assert(flag_isOn('UT_RELOAD') = *off : 'baseline should be off');

  exec sql call flag_set('UT_RELOAD', 'Y');    // bumps FLAGCTL.version_ts
  // No flag_refresh() here: rely on TTL-0 version check to detect the change.
  assert(flag_isOn('UT_RELOAD') = *on :
         'change must propagate via version stamp without explicit refresh');
end-proc;
