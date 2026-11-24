//OPSJOB5  JOB 1,NOTIFY=&SYSUID,MSGLEVEL=(1,1)
//*-------------------------------------------------------------------
//* TEST JOB 5 - ENDS WITH CONDITION CODE 4 (A WARNING).
//* EXPECTED MONITOR ACTION: NOTIFY OPERATIONS, NO INCIDENT.
//*-------------------------------------------------------------------
//STEP1    EXEC PGM=IDCAMS
//SYSPRINT DD SYSOUT=*
//SYSIN    DD *
  SET MAXCC=4
/*
