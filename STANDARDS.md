# Automation coding standards

These are the rules every exec, table and job in this repo follows. Automation teams keep standards like these so that anyone on call can read, trust and change any piece of automation at 3 a.m.

## 1. Every exec starts with a header
Line 1 is a comment containing `REXX` (z/OS needs it to know the language). The header says: name and version, purpose, syntax, inputs, outputs and return codes. A change to the exec updates the version.

## 2. Return codes mean the same thing everywhere
| RC | Meaning |
|---|---|
| 0 | Worked, nothing to report |
| 4 | Worked, with a warning or an automatic action taken |
| 8 | Stopped or needs a person (escalation, halted runbook) |
| 12 | Setup error: missing data set, bad arguments, bad table |

The JCL runs REXX with `IKJEFT1B` so the exec's exit code becomes the step's condition code, and a scheduler can act on it.

## 3. Rules go in tables, not in code
Message IDs, job patterns, severities, actions and retry limits live in `MSGTABLE`. Adding a new alert is a table change, reviewed like any other change, with no code change. Bad table lines are reported and skipped, never guessed at.

## 4. Dry run first
Anything that changes the system has a mode that decides and logs without acting (`MSGMON ... DRYRUN`, `DRSWITCH ... DRYRUN`). Run it before the real thing, and keep its output as evidence.

## 5. Automation must not loop
Every automatic recovery has a retry limit kept in a state data set. When the limit is reached the automation stops and escalates. A clean run resets the counter.

## 6. Order is guaranteed, not hoped for
A recovery job resubmits the failed job itself, through the internal reader, only after its fix step ends RC 0 (`OPSFIX1`). Two jobs submitted back to back are not assumed to run in order.

## 7. Destructive steps check first, and checkpoint
The DR runbook checks the configuration before it changes it, refuses an unsafe switch (mirror not `DUPLEX`, workload still running at the old primary), saves a checkpoint after every step and resumes from the failed step.

## 8. Everything is logged
Alerts and DR runs are appended to `ALERTS` and `DRLOG` with a run ID, so each action can be traced afterwards.

## 9. Layout
- Lines <= 72 columns in REXX and JCL. No tabs. ASCII only.
- JCL comments don't quote message IDs, because job logs (including the JCL listing) are what the monitor scans.
- Data sets are named `&SYSUID..MAPLE.OPS.*`; members are 8 characters or fewer.
