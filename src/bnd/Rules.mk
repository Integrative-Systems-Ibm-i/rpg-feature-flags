# The service program. Binder source + the module it exports from.
FLAGSRV.SRVPGM: private ACTGRP := FLAGS
FLAGSRV.SRVPGM: private USRPRF := *OWNER
FLAGSRV.SRVPGM: FLAGSRV.bnd FLAGSRV.MODULE
