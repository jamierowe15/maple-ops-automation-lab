//OPSRESET JOB 1,NOTIFY=&SYSUID,MSGLEVEL=(1,1)
//*-------------------------------------------------------------------
//* RESET THE MONITOR DEMO SO IT CAN BE RUN AGAIN: DELETES THE INPUT
//* DATA SET THAT OPSFIX1 CREATES.  ENDS CC 0000 EVEN IF IT IS GONE.
//*-------------------------------------------------------------------
//STEP1    EXEC PGM=IEFBR14
//DELIN    DD DSN=&SYSUID..MAPLE.OPS.INPUT,DISP=(MOD,DELETE),
//            SPACE=(TRK,(1,1))
