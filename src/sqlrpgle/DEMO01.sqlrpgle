**free
// =====================================================================
//  DEMO01  -  Feature flag demonstration, with a 5250 screen.
//
//  Shows the SAME program behaving two different ways depending on one
//  row in FLAGDEF. Nothing is recompiled and the job is never restarted:
//  press F5 and the behaviour changes.
//
//  To flip the flag from another session (or from VS Code / ACS SQL):
//      CALL FLGDEV.FLAG_SET('NEW_PRICING', 'Y');     -- turn on
//      CALL FLGDEV.FLAG_SET('NEW_PRICING', 'N');     -- turn off
//
//  Build:
//      CRTSQLRPGI OBJ(FLGDEV/DEMO01) SRCSTMF('src/sqlrpgle/DEMO01.sqlrpgle')
//                 OBJTYPE(*PGM) COMMIT(*NONE) CVTCCSID(*JOB) DBGVIEW(*SOURCE)
//  Run:
//      CALL FLGDEV/DEMO01
//
//  Uses the real FLAGSRV service program: flag_isOn() evaluates for the job
//  user, honours per-user overrides in FLAGUSR, and uses the in-job cache.
//  Requires FLGDEV/FLAGSRV and the FLAGBND binding directory.
// =====================================================================
ctl-opt dftactgrp(*no) actgrp(*new) option(*srcstmt : *nodebugio)
        bnddir('FLAGBND');

/copy 'src/copy/FLAGSRV_H.rpgleinc'

// Resolved through *LIBL at both compile and run time, so the
// environment-per-library-list design holds. BUILDDEMO does the ADDLIBLE.
dcl-f DEMO01D workstn indds(dspInds);

dcl-ds dspInds qualified;
  exitKey    ind pos(3);
  refreshKey ind pos(5);
end-ds;

dcl-s flagOn    ind;
dcl-s basePrice packed(9 : 2) inz(249.99);

// ---------------------------------------------------------------------
//  Main
// ---------------------------------------------------------------------
dow *on;

  // The real public contract: one call, evaluated for the job user,
  // honouring per-user overrides in FLAGUSR and the in-job cache.
  flagOn = flag_isOn('NEW_PRICING');

  if flagOn;
    FLAGTXT = 'ON';
    MODETXT = 'New pricing engine (v2)';
    LISTPRC = basePrice;
    PAYPRC  = basePrice * 0.85;
    MSGTXT  = 'Loyalty discount for our fav customer applied: 15% off';
  else;
    FLAGTXT = 'OFF';
    MODETXT = 'Classic pricing (v1)';
    LISTPRC = basePrice;
    PAYPRC  = basePrice;
    MSGTXT  = 'Standard list price';
  endif;

  EVALTS = %char(%timestamp());

  exfmt DEMOFMT;

  if dspInds.exitKey;
    leave;
  endif;

  // F5 = re-evaluate. FLAGSRV keeps an in-job cache and will serve a warm
  // hit with no I/O until its TTL expires (default 60s), so without this
  // call a flag flipped seconds ago would not be visible yet. This is the
  // service program working as designed - flag_refresh() is exported for
  // exactly this case.
  if dspInds.refreshKey;
    flag_refresh();
  endif;

enddo;

*inlr = *on;
return;
