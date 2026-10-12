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
//  NOTE: this reads FLAGDEF directly with embedded SQL rather than binding
//  to FLAGSRV, so it stands alone. Swap checkFlag() for flag_isOn() once the
//  service program is available.
// =====================================================================
ctl-opt dftactgrp(*no) actgrp(*new) option(*srcstmt : *nodebugio);

// Resolved through *LIBL at both compile and run time, so the
// environment-per-library-list design holds. BUILDDEMO does the ADDLIBLE.
dcl-f DEMO01D workstn indds(dspInds);

dcl-ds dspInds qualified;
  exitKey    ind pos(3);
  refreshKey ind pos(5);
end-ds;

dcl-pr checkFlag ind;
  flagName varchar(50) const;
end-pr;

dcl-s flagOn    ind;
dcl-s basePrice packed(9 : 2) inz(249.99);

// ---------------------------------------------------------------------
//  Main
// ---------------------------------------------------------------------
dow *on;

  flagOn = checkFlag('NEW_PRICING');

  if flagOn;
    FLAGTXT = 'ON';
    MODETXT = 'New pricing engine (v2)';
    LISTPRC = basePrice;
    PAYPRC  = basePrice * 0.85;
    MSGTXT  = 'Loyalty discount applied: 15% off';
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

enddo;

*inlr = *on;
return;

// ---------------------------------------------------------------------
//  checkFlag  -  read one flag from FLAGDEF. Fails closed: any error,
//                missing flag, or retired flag resolves to OFF.
// ---------------------------------------------------------------------
dcl-proc checkFlag;

  dcl-pi *n ind;
    flagName varchar(50) const;
  end-pi;

  dcl-s enabled char(1) inz('N');

  exec sql
    select enabled
      into :enabled
      from flagdef
     where flag_name = :flagName
       and status    = 'A';

  if sqlcode <> 0;
    enabled = 'N';
  endif;

  return (enabled = 'Y');

end-proc;
