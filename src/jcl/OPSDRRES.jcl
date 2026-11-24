//OPSDRRES JOB 1,NOTIFY=&SYSUID,MSGLEVEL=(1,1)
//*-------------------------------------------------------------------
//* DR RUNBOOK - RESUME A HALTED RUN FROM THE FAILED STEP.
//* RC 0 = COMPLETE, 4 = NOTHING TO DO, 8 = HALTED, 12 = SETUP ERROR.
//*-------------------------------------------------------------------
//RUN      EXEC PGM=IKJEFT1B,DYNAMNBR=30
//SYSEXEC  DD DISP=SHR,DSN=&SYSUID..MAPLE.OPS.REXX
//SYSTSPRT DD SYSOUT=*
//SYSTSIN  DD *
 %DRSWITCH * RESUME
/*
