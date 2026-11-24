/* REXX ****************************************************************
* DRSWITCH  Maple Ops DR site-switch runbook engine          v1.0
*
* Purpose  Run an ordered DR runbook (modelled on the way GDPS
*          scripts are lists of high-level statements) against a
*          simulated two-site configuration. Every step is checked,
*          logged and checkpointed, so a failed run can be resumed
*          from the failed step instead of starting again.
*
* Syntax   DRSWITCH base mode [RUNBOOK=name] [FAULT=n]
*          mode  RESET    write the starting two-site configuration
*                DRYRUN   validate the whole runbook, change nothing
*                EXECUTE  run it (refused if a run is incomplete)
*                RESUME   continue from the step after LASTSTEP
*          RUNBOOK=  CNTL member to run (default RUNBOOK)
*          FAULT=n   inject a failure at step n (DR test drill)
*
* Files    SITECFG (KEY=VALUE), RUNBOOK/RUNBACK (CNTL), DRLOG
* Returns  0 complete   4 nothing to do   8 halted   12 setup error
*
* Statements
*   CHECK  key=value     stop unless the configuration matches
*   VERIFY key=value     same as CHECK, used after the changes
*   MSG    text          operator message
*   STOP   wkld AT site  stop a workload at a site
*   START  wkld AT site [JOB=member]   start it (LIVE: submit job)
*   SWITCH MIRROR TO site  reverse disk mirroring; refused unless
*                        the mirror is DUPLEX and no workload is
*                        still UP at the current primary site
*   SET    key=value     change a configuration value
***********************************************************************/
parse arg base mode rest
mode = translate(mode)
parse source env .
tso = (env = 'TSO')
if tso & base = '*' then base = userid()'.MAPLE.OPS'
if base = '' | wordpos(mode, 'RESET DRYRUN EXECUTE RESUME') = 0,
then do
  say 'DRSWITCH: usage is DRSWITCH base RESET|DRYRUN|EXECUTE|RESUME'
  exit 12
end
book = 'RUNBOOK'; fault = 0
do w = 1 to words(rest)
  parse upper value word(rest, w) with k '=' v
  if k = 'RUNBOOK' then book = v
  if k = 'FAULT' & datatype(v, 'W') then fault = v
end
runid = date('S')'-'space(translate(time('N'), ' ', ':'), 0)
logn = 0
say 'DRSWITCH v1.0  run' runid ' mode' mode ' runbook' book
call Log '*** DRSWITCH' mode 'RUNBOOK='book 'FAULT='fault

/* ---- RESET: write the starting configuration --------------------- */
if mode = 'RESET' then do
  ncfg = 0
  call CfgSet 'ACTIVE', 'SITEA'
  call CfgSet 'SITEA.STATUS', 'READY'
  call CfgSet 'SITEB.STATUS', 'READY'
  call CfgSet 'MIRROR.STATE', 'DUPLEX'
  call CfgSet 'MIRROR.PRIMARY', 'SITEA'
  call CfgSet 'MAPLEBATCH.SITEA', 'UP'
  call CfgSet 'MAPLEBATCH.SITEB', 'DOWN'
  call CfgSet 'MAPLEONLINE.SITEA', 'UP'
  call CfgSet 'MAPLEONLINE.SITEB', 'DOWN'
  call CfgSet 'LASTSTEP', '0'
  call SaveCfg
  call Log 'RESET complete: SITEA active, mirror DUPLEX'
  call Finish 0
end

/* ---- Load configuration and runbook ------------------------------ */
if LoadCfg() <> 0 then do
  say 'DRSWITCH: cannot read SITECFG - run RESET first'
  exit 12
end
if ReadRes(Res(book)) <> 0 then do
  say 'DRSWITCH: cannot read runbook' Res(book)
  exit 12
end
ns = 0
do i = 1 to io.0
  ln = strip(io.i)
  if ln = '' | left(ln, 1) = '*' then iterate
  ns = ns + 1
  parse var ln sv.ns sa.ns
  sv.ns = translate(sv.ns)
  sa.ns = strip(sa.ns)
end
call Log 'Runbook' book 'has' ns 'steps'

last = Cfg('LASTSTEP')
if \datatype(last, 'W') then last = 0
first = 1
if mode = 'EXECUTE' & last > 0 then do
  call Log 'REFUSED: previous run stopped after step' last'.',
           'Use RESUME, or RESET to start over'
  call Finish 8
end
if mode = 'RESUME' then do
  if last = 0 then do
    call Log 'Nothing to resume: last run completed'
    call Finish 4
  end
  first = last + 1
  call Log 'Resuming at step' first
end

/* ---- Run the steps ----------------------------------------------- */
do s = first to ns
  why = ''
  if s = fault then why = 'INJECTED FAULT (DR drill)'
  else why = DoStep(sv.s, sa.s)
  tag = right(s, 2, '0')'/'right(ns, 2, '0')
  if why <> '' then do
    call Log 'STEP' tag sv.s sa.s '-> FAILED:' why
    call Log 'HALTED at step' s'. Fix the cause, then run RESUME'
    if mode <> 'DRYRUN' then call SaveCfg
    call Finish 8
  end
  call Log 'STEP' tag sv.s sa.s '-> OK' note
  if mode <> 'DRYRUN' then do
    call CfgSet 'LASTSTEP', s
    call SaveCfg                       /* checkpoint after each step */
  end
end
if mode <> 'DRYRUN' then do
  call CfgSet 'LASTSTEP', '0'
  call SaveCfg
end
call Log 'RUNBOOK COMPLETE. ACTIVE='Cfg('ACTIVE'),
         'MIRROR.PRIMARY='Cfg('MIRROR.PRIMARY')
if mode = 'DRYRUN' then call Log 'DRYRUN: no changes were saved'
call Finish 0

/* ================================================================== */
DoStep: /* run one statement; return '' if ok, else the reason */
  parse arg _v, _a
  note = ''
  select
    when _v = 'MSG' then do
      note = '(operator notified)'
      return ''
    end
    when _v = 'CHECK' | _v = 'VERIFY' | _v = 'SET' then do
      parse var _a _k '=' _x
      _k = translate(strip(_k)); _x = translate(strip(_x))
      if _k = '' | _x = '' then return 'BAD SYNTAX, use key=value'
      if _v = 'SET' then do
        note = '('_k' now '_x')'
        call CfgSet _k, _x
        return ''
      end
      if Cfg(_k) \== _x then,
        return _k 'IS' Cfg(_k)', EXPECTED' _x
      return ''
    end
    when _v = 'STOP' | _v = 'START' then do
      parse upper var _a _w ' AT ' _s .
      _w = strip(_w); _s = strip(_s)
      if _w = '' | _s = '' then return 'BAD SYNTAX, use wkld AT site'
      if Cfg(_s'.STATUS') \== 'READY' then,
        return 'SITE' _s 'IS NOT READY'
      if _v = 'STOP' then call CfgSet _w'.'_s, 'DOWN'
      else call CfgSet _w'.'_s, 'UP'
      if _v = 'START' & pos('JOB=', translate(_a)) > 0 then do
        parse upper var _a 'JOB=' _m .
        if mode = 'DRYRUN' then note = '(would submit' _m')'
        else note = '(submitted' _m '=' Submit(_m)')'
      end
      return ''
    end
    when _v = 'SWITCH' then do
      parse upper var _a . ' TO ' _t .
      _t = strip(_t)
      if Cfg(_t'.STATUS') \== 'READY' then,
        return 'TARGET SITE' _t 'IS NOT READY'
      if Cfg('MIRROR.STATE') \== 'DUPLEX' then,
        return 'MIRROR IS' Cfg('MIRROR.STATE')', NOT DUPLEX -',
               'DATA MAY NOT BE CONSISTENT'
      _p = Cfg('MIRROR.PRIMARY')
      do _i = 1 to ncfg
        _k = ckey._i
        if right(_k, length(_p) + 1) == '.'_p & cval._i = 'UP' then,
          return _k 'IS STILL UP AT' _p '- STOP IT FIRST'
      end
      call CfgSet 'MIRROR.PRIMARY', _t
      note = '(mirror now' _t '->' _p')'
      return ''
    end
    otherwise return 'UNKNOWN STATEMENT' _v
  end

Cfg: /* value of a configuration key, or '?' */
  parse upper arg _k
  do _i = 1 to ncfg
    if ckey._i == _k then return cval._i
  end
  return '?'

CfgSet: /* set or add a configuration key, keeping file order */
  parse upper arg _k, _x
  do _i = 1 to ncfg
    if ckey._i == _k then do
      cval._i = _x
      return
    end
  end
  ncfg = ncfg + 1
  ckey.ncfg = _k
  cval.ncfg = _x
  return

LoadCfg:
  ncfg = 0
  if ReadRes(Res('SITECFG')) <> 0 then return 8
  do _j = 1 to io.0
    _l = strip(io._j)
    if _l = '' | left(_l, 1) = '*' then iterate
    parse var _l _k '=' _x
    call CfgSet strip(_k), strip(_x)
  end
  if ncfg = 0 then return 8
  return 0

SaveCfg:
  out.0 = 1
  out.1 = '* Maple Ops DR lab - simulated two-site configuration'
  do _j = 1 to ncfg
    _t = _j + 1
    out._t = ckey._j'='cval._j
  end
  out.0 = ncfg + 1
  if WriteRes(Res('SITECFG'), 'REPLACE') <> 0 then do
    say 'DRSWITCH: cannot write SITECFG'
    exit 12
  end
  return

Log: /* say a line and keep it for DRLOG */
  parse arg _m
  say _m
  logn = logn + 1
  logl.logn = runid _m
  return

Finish: /* write DRLOG and end with a return code */
  parse arg finrc                  /* not _rc: WriteRes sets _rc */
  call Log 'END RC='finrc
  out.0 = logn
  do _j = 1 to logn
    out._j = logl._j
  end
  call WriteRes Res('DRLOG'), 'APPEND'
  exit finrc

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
