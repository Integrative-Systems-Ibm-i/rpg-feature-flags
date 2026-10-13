# The module behind the service program.
FLAGSRV.MODULE: private COMMIT := *NONE
FLAGSRV.MODULE: private DBGVIEW := *SOURCE
FLAGSRV.MODULE: FLAGSRV.sqlrpgle

# The demo program. Declaring BOTH dependencies is the point of this file:
# change the binder source and TOBi rebuilds the service program AND DEMO01,
# because DEMO01 binds to it. Change the DDS and DEMO01 rebuilds too.
DEMO01.PGM: private COMMIT := *NONE
DEMO01.PGM: private DBGVIEW := *SOURCE
DEMO01.PGM: DEMO01.sqlrpgle FLAGBND.BNDDIR DEMO01D.FILE
