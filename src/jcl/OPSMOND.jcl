//OPSMOND  JOB 1,NOTIFY=&SYSUID,MSGLEVEL=(1,1)
//*-------------------------------------------------------------------
//* MESSAGE MONITOR - DRY RUN.  DECIDES WHAT IT WOULD DO FOR EVERY
//* JOB IN MAPLE.OPS.JOBLOG BUT SUBMITS NOTHING.  RC 8 = ESCALATIONS.
//*-------------------------------------------------------------------
//RUN      EXEC PGM=IKJEFT1B,DYNAMNBR=30
//SYSEXEC  DD DISP=SHR,DSN=&SYSUID..MAPLE.OPS.REXX
//SYSTSPRT DD SYSOUT=*
//SYSTSIN  DD *
 %MSGMON * DRYRUN
/*
