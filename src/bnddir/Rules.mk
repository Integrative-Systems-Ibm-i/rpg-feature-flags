# The binding directory consumers bind through. It must exist before any
# program with ctl-opt bnddir('FLAGBND') compiles, hence the dependency
# on the service program it points at.
FLAGBND.BNDDIR: FLAGBND.bnddir FLAGSRV.SRVPGM
