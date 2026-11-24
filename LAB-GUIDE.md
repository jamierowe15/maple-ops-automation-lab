# Lab guide: Maple Ops Automation Lab (5 days)

You can do every step with the menu in `RUN-MAPLE-LABS.cmd`, or by hand in VS Code with Zowe Explorer. Do at least Days 2 and 3 **by hand once**, even if you use the menu afterwards. Interviewers ask what you did, and "I submitted it, read the job log and saw IEF212I" is a much better answer than "a script did it".

Wherever you see `Z12345`, use your own Z Xplore user ID.

---

## Day 1: Setup and allocation

**Goal:** get the libraries onto z/OS.

1. If you've already set up Z Xplore for the Maple Host Release Lab, you're connected. If not, complete the Z Xplore VS Code / Zowe setup challenge first.
2. Menu option **1** creates this repo in `Documents\MapleLabs\maple-ops-automation-lab`.
3. Menu option **2** runs the offline rehearsal on your PC, if you have a REXX interpreter. Otherwise skip it: GitHub Actions runs the same 30 tests on every push.
4. **By hand:** in VS Code, open `src/jcl/OPSALLOC.jcl` -> right-click -> **Submit as JCL**. You need `CC 0000`. (Rerunning it fails with duplicate names; that's expected.)
5. Upload the members. In Zowe Explorer's Data Sets view:
   - `src/rexx/*.rexx` -> `Z12345.MAPLE.OPS.REXX` (names `MSGMON`, `DRSWITCH`)
   - `src/jcl/*.jcl` -> `Z12345.MAPLE.OPS.JCL` (drop the `.jcl`)
   - `src/cntl/*.txt` -> `Z12345.MAPLE.OPS.CNTL` (`MSGTABLE`, `RUNBOOK`, `RUNBACK`)

   Or let menu option **3** do the allocation and uploads.
6. In ISPF `=3.4`, list `Z12345.MAPLE.OPS` and check RECFM/LRECL on each data set.

> [Screenshot] **Evidence:** OPSALLOC output (CC 0000) and the 3.4 listing.

---

## Day 2: Message monitor and automatic recovery

**Goal:** see automation detect failures and act on them.

1. **Make some failures.** Submit `OPSRESET`, then `OPSJOB1` to `OPSJOB5`. Open each job's output and find the message that tells you what happened:

   | Job | What you should find | Meaning |
   |---|---|---|
   | OPSJOB1 | `IEF212I ... DATA SET NOT FOUND`, job ends JCL ERROR | Missing input |
   | OPSJOB2 | `IEF142I ... COND CODE 0008` | Step failed (RC 8) |
   | OPSJOB3 | `CSV003I`, `IEF450I ... ABEND=S806` | Program not found |
   | OPSJOB4 | `COND CODE 0000` twice | Clean |
   | OPSJOB5 | `COND CODE 0004` | Warning |

2. **Collect the logs.** The monitor reads `Z12345.MAPLE.OPS.JOBLOG`. Each job's spool goes in, starting with a header line `>>> JOB name jobid`. Menu option **3** does this for you. By hand, in PowerShell:
   ```powershell
   zowe zos-jobs view all-spool-content JOB01234 > OPSJOB1.txt
   ```
   Join the files with the header lines, then upload: `zowe zos-files upload file-to-data-set joblog.txt "Z12345.MAPLE.OPS.JOBLOG"`.
3. **Dry run.** Submit `OPSMOND`. Read SYSTSPRT: one line per job with severity, action and result. The step ends **CC 0008** because escalations were found. Then browse `Z12345.MAPLE.OPS.ALERTS`.
4. **Live run.** Submit `OPSMON`. This time the RECOVER rule for OPSJOB1 really submits `OPSFIX1`.
   - OPSFIX1 STEP1 creates the missing data set.
   - STEP2 resubmits OPSJOB1 through the internal reader (`SYSOUT=(A,INTRDR)`), but only if STEP1 ended RC 0.
   - Find the new OPSJOB1 in the Jobs view. It should end `CC 0000`.
5. **Prove it's clean.** Put the new OPSJOB1 log into JOBLOG and run `OPSMON` again. OPSJOB1 is now `CLEAN` and its retry counter in `MAPLE.OPS.STATE` goes back to 0.
6. **Prove the loop guard.** Open `MSGTABLE` and read the MAX column for OPSJOB1. Explain in your notes what happens on the third failure (the rule stops and escalates).
7. **Change a rule.** Add a line to `MSGTABLE` (for example, make `RC=4` jobs `ESCALATE`), rerun `OPSMOND` and see the result change with no code change. Put it back afterwards.

> [Screenshot] **Evidence:** the five job outputs, OPSMOND and OPSMON SYSTSPRT, the OPSFIX1 output, the rerun OPSJOB1 at CC 0000, and the ALERTS data set.

---

## Day 3: DR runbook and DR test drill

**Goal:** run a site switch the way a GDPS planned action works, including a failed test.

1. Read `CNTL(RUNBOOK)`. Every line is one step: checks first, then stop, switch, start, verify.
2. Submit `OPSDRRST` (resets the two sites), then **`OPSDRDRY`** (dry run). All 14 steps OK, RC 0, and `MAPLE.OPS.SITECFG` is unchanged.
3. **DR drill.** Submit `OPSDRFLT`: it runs for real with a fault injected at step 7 (the mirror switch). It halts with RC 8. Browse SITECFG: `LASTSTEP=6`, workloads stopped at SITEA, mirror not yet switched. That's a half-finished DR, the situation the checkpoint exists for.
4. Submit `OPSDREXE`. It's **refused**, because a run is incomplete. Write down why that's the right behaviour.
5. Submit `OPSDRRES`. It resumes at step 7 and completes. SITECFG now shows `ACTIVE=SITEB`, `MIRROR.PRIMARY=SITEB`.
6. Submit `OPSDRBAK` to switch back to SITEA.
7. **Safety check.** Edit SITECFG, set `MIRROR.STATE=SUSPENDED`, and run `OPSDRDRY`. Step 7 refuses: data at SITEB may not be consistent. Run `OPSDRRST` afterwards.
8. Browse `MAPLE.OPS.DRLOG`: every run, step and result is there with a run ID.

> [Screenshot] **Evidence:** DRYRUN, FAULT, refused EXECUTE, RESUME and RUNBACK outputs, plus SITECFG before and after.

---

## Day 4: Link to the Maple Host Release Lab

**Goal:** use your automation on your other lab's production incident.

1. Do Day 5 step 1 of the Host Release Lab: `MPSTREAM` with `ENV=PROD DATA=PROD` abends S0C7.
2. Menu option **4** lists your recent `MP*` jobs. Pick the failed MPSTREAM. It collects the log, runs the monitor and writes an incident draft to `evidence\reports\INC-drafts.md` (and a copy into the release lab's `change\` folder).
3. Use the draft's text in the release lab's INC0001 record in ServiceNow. Your PIR can now say: *"Detected by automation (MSGMON rule CEE3207S -> ESCALATE) at hh:mm."*

> [Screenshot] **Evidence:** the MPSTREAM alert lines and the INC draft.

---

## Day 5: Report, diagram and publish

1. Menu option **3** (or **7**) builds `evidence\reports\ops-report.xlsx` (if Excel is installed) and `ops-report.html` from ALERTS.
2. Draw the flow in **Visio** or the free **draw.io**: job -> job log -> MSGMON -> MSGTABLE lookup -> action (LOG / NOTIFY / ESCALATE / RECOVER -> OPSFIX1 -> rerun) -> ALERTS -> report. Save it in `evidence\`.
3. Fill in the Results section of README.md.
4. Menu option **5** publishes this repo to GitHub (and offers to publish the release lab too).

---

## Resume line

*Built a REXX automation toolkit on IBM z/OS (IBM Z Xplore) that detects job failures from message IDs, applies table-driven recovery with retry limits, and runs a checkpointed DR site-switch runbook modelled on GDPS planned actions, including fault-injection drills and resume; automated Excel alert reporting with PowerShell and Zowe CLI.*
