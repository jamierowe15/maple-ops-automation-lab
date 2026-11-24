#!/usr/bin/env bash
# Offline regression tests for the Maple Ops Automation Lab.
# Runs the same REXX that runs on z/OS, using Regina REXX on Linux.
# Used by GitHub Actions on every push, and safe to run in WSL.
set -u
cd "$(dirname "$0")/.."
REXX=${REXX:-regina}
SRC="$PWD/src/rexx"
W=$(mktemp -d)
pass=0; fail=0

check() { # name expected actual
  if [ "$2" = "$3" ]; then echo "PASS  $1"; pass=$((pass+1))
  else echo "FAIL  $1 (expected $2, got $3)"; fail=$((fail+1)); fi
}
has() { # name file text
  if grep -q -- "$3" "$2"; then echo "PASS  $1"; pass=$((pass+1))
  else echo "FAIL  $1 (no '$3' in $(basename "$2"))"; fail=$((fail+1)); fi
}
mon() { "$REXX" "$SRC/MSGMON.rexx" "$W/m" "$@" > "$W/out.txt"; echo $?; }
dr()  { "$REXX" "$SRC/DRSWITCH.rexx" "$W/d" "$@" > "$W/out.txt"; echo $?; }

echo "== Message monitor"
mkdir -p "$W/m"
cp src/cntl/MSGTABLE.txt samples/JOBLOG.txt "$W/m/"
echo "* state" > "$W/m/STATE.txt"
check "dry run returns 8 (escalations present)" 8 "$(mon DRYRUN)"
check "one alert per hit (9 hits)" 9 "$(wc -l < "$W/m/ALERTS.txt" | tr -d ' ')"
has   "OPSJOB1 missing data set -> recovery planned" "$W/m/ALERTS.txt" "OPSJOB1,JOB04101,STEP1,IEF212I,HIGH,RECOVER,WOULD SUBMIT OPSFIX1"
has   "newer z/OS IEFA107I -> recovery planned" "$W/m/ALERTS.txt" "OPSJOB1,JOB04130,STEP1,IEFA107I,HIGH,RECOVER,WOULD SUBMIT OPSFIX1"
has   "OPSJOB2 CC 8 -> escalate" "$W/m/ALERTS.txt" "OPSJOB2,JOB04102,STEP1,RC>4,HIGH,ESCALATE,INCIDENT REQUIRED"
has   "OPSJOB3 S806 abend -> escalate" "$W/m/ALERTS.txt" "IEF450I,CRIT,ESCALATE,INCIDENT REQUIRED"
has   "OPSJOB4 clean -> logged" "$W/m/ALERTS.txt" "OPSJOB4,JOB04104,STEP1,CLEAN,INFO,LOG,LOGGED"
has   "OPSJOB5 CC 4 -> notify" "$W/m/ALERTS.txt" "OPSJOB5,JOB04105,STEP1,RC=4,WARN,NOTIFY"
has   "MPSTREAM S0C7 (release lab) -> escalate" "$W/m/ALERTS.txt" "MPSTREAM,JOB04110,-,CEE3207S,CRIT,ESCALATE,INCIDENT REQUIRED"
has   "dry run leaves retry state alone" "$W/m/STATE.txt" "^\* state"

mon LIVE > /dev/null; has "live try 1 of 2" "$W/out.txt" "TRY 1/2"
mon LIVE > /dev/null; has "live try 2 of 2" "$W/out.txt" "TRY 2/2"
mon LIVE > /dev/null; has "retry limit stops a loop" "$W/out.txt" "RETRY LIMIT 2 REACHED"
has "retry state saved" "$W/m/STATE.txt" "OPSJOB1.IEF212I 2"
printf '>>> JOB OPSJOB1 JOB04120\nIEF142I OPSJOB1 STEP1 - STEP WAS EXECUTED - COND CODE 0000\n' > "$W/m/JOBLOG.txt"
check "clean rerun returns 0" 0 "$(mon LIVE)"
has "clean rerun resets the retry counter" "$W/m/STATE.txt" "OPSJOB1.IEF212I 0"

echo "== DR runbook"
mkdir -p "$W/d"
cp src/cntl/RUNBOOK.txt src/cntl/RUNBACK.txt "$W/d/"
check "reset" 0 "$(dr RESET)"
check "dry run passes" 0 "$(dr DRYRUN)"
has   "dry run changes nothing" "$W/d/SITECFG.txt" "ACTIVE=SITEA"
check "fault drill halts with 8" 8 "$(dr EXECUTE FAULT=7)"
has   "checkpoint kept at step 6" "$W/d/SITECFG.txt" "LASTSTEP=6"
check "new EXECUTE refused while incomplete" 8 "$(dr EXECUTE)"
check "resume completes" 0 "$(dr RESUME)"
has   "SITEB now active" "$W/d/SITECFG.txt" "ACTIVE=SITEB"
has   "mirror reversed" "$W/d/SITECFG.txt" "MIRROR.PRIMARY=SITEB"
check "second resume has nothing to do" 4 "$(dr RESUME)"
check "switch back to SITEA" 0 "$(dr EXECUTE RUNBOOK=RUNBACK)"
has   "DRLOG kept every run" "$W/d/DRLOG.txt" "INJECTED FAULT"

printf 'CHECK ACTIVE=SITEA\nSWITCH MIRROR TO SITEB\n' > "$W/d/BADBOOK.txt"
check "switch refused while work is still up" 8 "$(dr DRYRUN RUNBOOK=BADBOOK)"
has   "reason names the running workload" "$W/out.txt" "STILL UP AT SITEA"
dr RESET > /dev/null
sed -i 's/MIRROR.STATE=DUPLEX/MIRROR.STATE=SUSPENDED/' "$W/d/SITECFG.txt"
check "switch refused when mirror not duplex" 8 "$(dr DRYRUN)"

rm -rf "$W"
echo "== $pass passed, $fail failed"
[ "$fail" -eq 0 ]
