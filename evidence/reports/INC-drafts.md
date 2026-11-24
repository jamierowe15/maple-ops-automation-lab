# Incident drafts from MSGMON (z/OS, release lab production run)

Created by the Maple Ops Automation Lab. Paste into ServiceNow and fill in the blanks.

## OPSJOB2 (JOB06198) - RC>4 detected by automation

| Field | Value |
|---|---|
| Short description | OPSJOB2 step STEP1 failed: RC>4 |
| Priority | 3 - Moderate |
| Assignment group | Mainframe Automation (MMA) |
| Detected by | MSGMON run 20261123-195622, rule RC>4 -> ESCALATE |
| Number | INC________ |

**Messages found:**
- `MAXCC=0008`

## OPSJOB3 (JOB06199) - IEF450I detected by automation

| Field | Value |
|---|---|
| Short description | OPSJOB3 step STEP1 failed: IEF450I |
| Priority | 2 - High |
| Assignment group | Mainframe Automation (MMA) |
| Detected by | MSGMON run 20261123-195622, rule IEF450I -> ESCALATE |
| Number | INC________ |

**Messages found:**
- `CSV003I REQUESTED MODULE MAPLENOP NOT FOUND`
- `IEF450I OPSJOB3 STEP1 - ABEND=S806 U0000 REASON=00000004`
