//OPSMON   JOB 1,NOTIFY=&SYSUID,MSGLEVEL=(1,1)
//*-------------------------------------------------------------------
//* MESSAGE MONITOR - LIVE.  SAME AS OPSMOND BUT RECOVER RULES
//* REALLY SUBMIT THEIR RECOVERY JOBS (RETRY LIMIT IN MAPLE.OPS.STATE).
//*-------------------------------------------------------------------
//RUN      EXEC PGM=IKJEFT1B,DYNAMNBR=30
//SYSEXEC  DD DISP=SHR,DSN=&SYSUID..MAPLE.OPS.REXX
//SYSTSPRT DD SYSOUT=*
//SYSTSIN  DD *
 %MSGMON * LIVE
/*
