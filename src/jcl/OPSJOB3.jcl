//OPSJOB3  JOB 1,NOTIFY=&SYSUID,MSGLEVEL=(1,1)
//*-------------------------------------------------------------------
//* TEST JOB 3 - CALLS A PROGRAM THAT DOES NOT EXIST, SO THE STEP
//* ABENDS (SYSTEM COMPLETION CODE 806).  EXPECTED ACTION: ESCALATE.
//*-------------------------------------------------------------------
//STEP1    EXEC PGM=MAPLENOP
