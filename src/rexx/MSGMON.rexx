/* REXX ****************************************************************
* MSGMON   Maple Ops message monitor                         v1.0
*
* Purpose  Scan collected job logs for message IDs, match each one
*          against the table-driven rules in MSGTABLE, write one
*          alert per hit and take the job's highest-severity action.
*          The rules live in a table, not in this code, the same way
*          NetView / System Automation automation tables work.
*
* Syntax   MSGMON base mode
*          base  z/OS: data set prefix, or * for userid.MAPLE.OPS
*                PC:   a folder that holds the .txt files
*          mode  DRYRUN (default) decide but do not submit anything
*                LIVE   submit recovery jobs for RECOVER rules
*
* Inputs   JOBLOG    job logs, each starting ">>> JOB name jobid"
*          MSGTABLE  the rules (member of base.CNTL on z/OS)
*          STATE     retry counts kept between runs
* Outputs  ALERTS    one CSV record per hit (appended)
*          STATE     updated retry counts (LIVE only)
*
* Returns  0 all clean   4 warnings or recoveries
*          8 escalation needed   12 setup error
***********************************************************************/
parse arg base mode .
mode = translate(mode)
if mode = '' then mode = 'DRYRUN'
if base = '' | wordpos(mode, 'DRYRUN LIVE') = 0 then do
  say 'MSGMON: usage is MSGMON base DRYRUN|LIVE'
  exit 12
end
parse source env .
tso = (env = 'TSO')
if tso & base = '*' then base = userid()'.MAPLE.OPS'
runid = date('S')'-'space(translate(time('N'), ' ', ':'), 0)
sevrank. = 0
sevrank.INFO = 1; sevrank.WARN = 2; sevrank.HIGH = 3; sevrank.CRIT = 4

say 'MSGMON v1.0  run' runid ' mode' mode ' base' base

/* ---- 1. Load the rules ------------------------------------------- */
if ReadRes(Res('MSGTABLE')) <> 0 then do
  say 'MSGMON: cannot read MSGTABLE' Res('MSGTABLE')
  exit 12
end
nr = 0
do i = 1 to io.0
  ln = strip(io.i)
  if ln = '' | left(ln, 1) = '*' then iterate
  parse upper var ln k j s a m rc1 rr .
  if sevrank.s = 0 | wordpos(a, 'LOG NOTIFY ESCALATE RECOVER') = 0,
     | \datatype(m, 'W') then do
    say 'MSGMON: bad rule ignored:' ln
    iterate
  end
  nr = nr + 1
  rKey.nr = k; rJob.nr = j; rSev.nr = s; rAct.nr = a
  rMax.nr = m; rRec.nr = rc1; rRun.nr = rr
end
say 'MSGMON:' nr 'rules loaded'
if nr = 0 then exit 12

/* ---- 2. Load retry state ----------------------------------------- */
state. = 0
stkeys = ''
if ReadRes(Res('STATE')) = 0 then do i = 1 to io.0
  parse upper var io.i k c .
  if k = '' | left(k, 1) = '*' | \datatype(c, 'W') then iterate
  state.k = c
  stkeys = stkeys k
end

/* ---- 3. Scan the job logs ---------------------------------------- */
if ReadRes(Res('JOBLOG')) <> 0 then do
  say 'MSGMON: cannot read JOBLOG' Res('JOBLOG')
  exit 12
end
nj = 0
do i = 1 to io.0
  ln = io.i
  if left(ln, 8) = '>>> JOB ' then do
    parse var ln '>>> JOB ' jn jid .
    nj = nj + 1
    job.nj = translate(jn); jobid.nj = jid
    maxrc.nj = -1; nhit.nj = 0; seen.nj = ''
    iterate
  end
  if nj = 0 then iterate
  /* condition codes, from IEF142I step-end messages */
  p = pos('IEF142I', ln)
  if p > 0 then do
    q = pos('COND CODE', ln)
    if q > 0 then do
      cc = substr(ln, q + 10, 4)
      if datatype(cc, 'W') then do
        if cc + 0 > maxrc.nj then do
          maxrc.nj = cc + 0
          rcstep.nj = word(substr(ln, p), 3)
        end
      end
    end
    iterate
  end
  /* message rules: first rule whose key and job both match wins */
  do r = 1 to nr
    if left(rKey.r, 2) = 'RC' | rKey.r = 'CLEAN' then iterate
    p = pos(rKey.r, ln)
    if p = 0 then iterate
    if \JobMatch(job.nj, rJob.r) then iterate
    if wordpos(rKey.r, seen.nj) = 0 then do
      seen.nj = seen.nj rKey.r
      call AddHit nj, r, StepOf(ln, p, job.nj), Detail(ln, p)
    end
    leave
  end
end
say 'MSGMON:' io.0 'log lines,' nj 'jobs scanned'

/* ---- 4. Pseudo rules from the condition codes -------------------- */
do n = 1 to nj
  if maxrc.n > 4 then key = 'RC>4'
  else if maxrc.n = 4 then key = 'RC=4'
  else if maxrc.n = 0 & nhit.n = 0 then key = 'CLEAN'
  else iterate
  if key = 'CLEAN' then do w = 1 to words(stkeys)
    k = word(stkeys, w)                /* job ran clean: reset its */
    if left(k, length(job.n) + 1) == job.n'.' then state.k = 0
  end                                  /* retry counters           */
  do r = 1 to nr
    if rKey.r = key & JobMatch(job.n, rJob.r) then do
      st = '-'
      if maxrc.n >= 0 then st = rcstep.n
      call AddHit n, r, st, 'MAXCC=' || right(maxrc.n, 4, '0')
      leave
    end
  end
end

/* ---- 5. One action per job, then write the alerts ---------------- */
worst = 0
out.0 = 0
do n = 1 to nj
  if nhit.n = 0 then iterate
  best = 1
  do h = 2 to nhit.n
    s1 = hSev.n.h
    s2 = hSev.n.best
    if sevrank.s1 > sevrank.s2 then best = h
  end
  do h = 1 to nhit.n
    result = '-'
    if h = best then result = Act(n, h)
    call AddOut n, h, result
  end
end
if out.0 > 0 then if WriteRes(Res('ALERTS'), 'APPEND') <> 0 then do
  say 'MSGMON: cannot write ALERTS' Res('ALERTS')
  exit 12
end

/* ---- 6. Save retry state (LIVE only) ----------------------------- */
if mode = 'LIVE' then do
  out.0 = 1
  out.1 = '* MSGMON retry state  job.msgid count'
  do w = 1 to words(stkeys)
    k = word(stkeys, w)
    t = out.0 + 1
    out.t = k state.k
    out.0 = t
  end
  call WriteRes Res('STATE'), 'REPLACE'
end

say 'MSGMON: finished, return code' worst
exit worst

/* ================================================================== */
AddHit: /* job n, rule r, step, detail */
  parse arg _n, _r, _st, _dt
  _h = nhit._n + 1
  nhit._n = _h
  hRule._n._h = _r
  hSev._n._h = rSev._r
  hStep._n._h = _st
  hDet._n._h = _dt
  return

Act: /* decide and run the action for hit h of job n */
  parse arg _n, _h
  _r = hRule._n._h
  _a = rAct._r
  select
    when _a = 'LOG' then _res = 'LOGGED'
    when _a = 'NOTIFY' then do
      _res = 'OPS NOTIFIED'
      worst = max(worst, 4)
    end
    when _a = 'ESCALATE' then do
      _res = 'INCIDENT REQUIRED'
      worst = max(worst, 8)
    end
    when _a = 'RECOVER' then _res = Recover(_n, _r)
  end
  say left(job._n, 9) left(rKey._r, 9) left(hSev._n._h, 5),
      left(_a, 9) _res
  return _res

Recover: /* table-driven recovery with a retry limit */
  parse arg _n, _r
  _k = job._n'.'rKey._r
  if state._k >= rMax._r then do
    hSev._n._h = 'CRIT'
    worst = max(worst, 8)
    return 'RETRY LIMIT' rMax._r 'REACHED - ESCALATE'
  end
  worst = max(worst, 4)
  if mode = 'DRYRUN' then do
    if rRun._r = '-' then return 'WOULD SUBMIT' rRec._r
    return 'WOULD SUBMIT' rRec._r 'THEN' rRun._r
  end
  if wordpos(_k, stkeys) = 0 then stkeys = stkeys _k
  state._k = state._k + 1
  _res = 'SUBMITTED' rRec._r'='Submit(rRec._r)
  if rRun._r \= '-' then _res = _res rRun._r'='Submit(rRun._r)
  return _res 'TRY' state._k'/'rMax._r

Submit: /* submit a member of base.JCL, return the job id */
  parse arg _m
  if \tso then return 'SIMULATED'
  call outtrap 'sub.'
  "SUBMIT '"base".JCL("_m")'"
  _src = rc
  call outtrap 'OFF'
  _jid = '?'
  do _i = 1 to sub.0
    if pos('SUBMITTED', sub._i) > 0 then,
      parse var sub._i 'JOB ' . '(' _jid ')' .
  end
  if _src <> 0 then return 'FAILED-RC' || _src
  return _jid

AddOut: /* build one CSV alert record */
  parse arg _n, _h, _res
  _r = hRule._n._h
  _t = out.0 + 1
  out._t = runid','job._n','jobid._n','hStep._n._h','rKey._r',',
        || hSev._n._h','rAct._r','_res','hDet._n._h
  out.0 = _t
  return

StepOf: procedure /* IEFnnnI jobname stepname ... -> stepname */
  parse arg _l, _p, _j
  parse upper value substr(_l, _p) with . _w2 _w3 .
  if _w2 \== _j | _w3 = '' | _w3 = '-' then return '-'
  return _w3

Detail: procedure /* message text, made safe for CSV */
  parse arg _l, _p
  return space(translate(left(substr(_l, _p), 90), ';', ','))

JobMatch: procedure /* * , *SUFFIX , PREFIX* or an exact name */
  parse upper arg _j, _p
  if _p = '*' then return 1
  if left(_p, 1) = '*' then do
    _s = substr(_p, 2)
    return right(_j, length(_s)) == _s
  end
  if right(_p, 1) = '*' then do
    _s = left(_p, length(_p) - 1)
    return left(_j, length(_s)) == _s
  end
  return _j == _p

Res: procedure expose tso base /* resource name for a kind */
  parse arg _k
  if \tso then return base'/'_k'.txt'
  if wordpos(_k, 'MSGTABLE RUNBOOK RUNBACK') > 0 then,
    return base'.CNTL('_k')'
  return base'.'_k

ReadRes: /* read a data set or file into io. ; 0 = ok */
  parse arg _res
  drop io.
  io.0 = 0
  if tso then do
    "ALLOC FI(MPIO) DA('"_res"') SHR REUSE"
    if rc <> 0 then return 8
    "EXECIO * DISKR MPIO (STEM io. FINIS"
    _rc = rc
    "FREE FI(MPIO)"
    if _rc <> 0 then return 8
    return 0
  end
  if stream(_res, 'C', 'QUERY EXISTS') = '' then return 8
  _c = 0
  do while lines(_res) > 0
    _c = _c + 1
    io._c = strip(linein(_res), 'T', '0D'x)
  end
  io.0 = _c
  call stream _res, 'C', 'CLOSE'
  return 0

WriteRes: /* write out. to a data set or file; APPEND|REPLACE */
  parse arg _res, _how
  if tso then do
    _disp = 'OLD'
    if _how = 'APPEND' then _disp = 'MOD'
    "ALLOC FI(MPIO) DA('"_res"')" _disp "REUSE"
    if rc <> 0 then return 8
    "EXECIO" out.0 "DISKW MPIO (STEM out. FINIS"
    _rc = rc
    "FREE FI(MPIO)"
    if _rc <> 0 then return 8
    return 0
  end
  if _how = 'APPEND' then call stream _res, 'C', 'OPEN WRITE APPEND'
  else call stream _res, 'C', 'OPEN WRITE REPLACE'
  do _i = 1 to out.0
    call lineout _res, out._i
  end
  call stream _res, 'C', 'CLOSE'
  return 0
