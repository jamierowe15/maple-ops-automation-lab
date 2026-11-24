//OPSJOB4  JOB 1,NOTIFY=&SYSUID,MSGLEVEL=(1,1)
//*-------------------------------------------------------------------
//* TEST JOB 4 - TWO STEPS THAT BOTH END CC 0000.
//* EXPECTED MONITOR ACTION: LOG AS CLEAN.
//*-------------------------------------------------------------------
//STEP1    EXEC PGM=IEFBR14
//STEP2    EXEC PGM=IEFBR14
