//OPSJOB2  JOB 1,NOTIFY=&SYSUID,MSGLEVEL=(1,1)
//*-------------------------------------------------------------------
//* TEST JOB 2 - ENDS WITH CONDITION CODE 8 (A BUSINESS FAILURE THAT
//* A RETRY WILL NOT FIX).  EXPECTED MONITOR ACTION: ESCALATE.
//*-------------------------------------------------------------------
//STEP1    EXEC PGM=IDCAMS
//SYSPRINT DD SYSOUT=*
//SYSIN    DD *
  SET MAXCC=8
/*
