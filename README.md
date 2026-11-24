# Maple Ops Automation Lab

![rexx-tests](../../actions/workflows/ci.yml/badge.svg)

A small mainframe automation toolkit written in **REXX on IBM z/OS** (IBM Z Xplore). It copies, at lab scale, the work of a mainframe automation team:

| Team function | What this lab does |
|---|---|
| Message and system alerting | `MSGMON` scans job logs for message IDs (`IEF212I`, `IEF450I`, `CEE3207S` ...) and condition codes, and writes one alert per hit |
| Operational automation | Rules live in a **table** (`MSGTABLE`), not in code, the same way NetView / System Automation automation tables work. A `RECOVER` rule submits a recovery job, with a retry limit so a broken job can't loop forever |
| GDPS DR scripting and testing | `DRSWITCH` runs an ordered site-switch runbook (checks -> stop work -> switch disk mirror -> move active site -> restart -> verify), with dry run, fault-injection drills, checkpoints and resume |
| Monitoring and reporting | A PowerShell step turns the alerts into an Excel/HTML report and drafts incident records for escalations |
| Coding standards | [STANDARDS.md](STANDARDS.md): headers, return codes 0/4/8/12, table-driven design, dry-run first |

It links to my **[Maple Host Release Lab](https://github.com/jamierowe15/maple-host-release-lab)**: the monitor detects the S0C7 abend in that lab's production batch run (`MPSTREAM` STEP030) and drafts the incident.

> **Honesty note.** GDPS, NetView and System Automation for z/OS are licensed IBM products that aren't available in a free sandbox. This lab is **modelled on** how they work, using standard z/OS features (REXX, TSO, JES2, JCL). The z/OS parts run on a real IBM z/OS system through IBM Z Xplore.

## Quick start

Double-click **`RUN-MAPLE-LABS.cmd`** on Windows. Its menu creates this repo, runs an offline rehearsal, runs everything on Z Xplore through Zowe CLI, builds the report and publishes to GitHub.

Doing it by hand instead? Follow **[LAB-GUIDE.md](LAB-GUIDE.md)**.

## Layout

```
src/rexx     MSGMON (message monitor), DRSWITCH (DR runbook engine)
src/jcl      OPSALLOC, test jobs OPSJOB1-5, recovery OPSFIX1, run jobs
src/cntl     MSGTABLE (automation rules), RUNBOOK / RUNBACK (DR scripts)
samples      a sample job log for offline rehearsal and tests
tests        30 regression tests (Regina REXX), run by GitHub Actions
evidence     job logs, reports and screenshots from the real runs
```

## Results (fill in after the lab)

- Monitor live run: OPSJOB1 recovered automatically, try __ of 2; OPSJOB2/3 escalated; OPSJOB5 notified
- DR drill: fault at step 7 halted the run (RC 8), RESUME completed it (RC 0), switch-back RC 0
- Release-lab link: MPSTREAM S0C7 detected, INC draft created: INC________
