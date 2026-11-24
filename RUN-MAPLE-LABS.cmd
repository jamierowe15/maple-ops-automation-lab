<# : batch portion
@echo off
setlocal
title Maple Labs runner
set "MAPLE_SELF=%~f0"
powershell -NoProfile -ExecutionPolicy Bypass -Command "iex ([IO.File]::ReadAllText($env:MAPLE_SELF))"
if errorlevel 1 pause
exit /b
: end of batch part, PowerShell starts below #>
# =====================================================================
#  RUN-MAPLE-LABS  -  Maple Ops Automation Lab + Maple Host Release Lab
#  Double-click the .cmd file. Everything below is PowerShell.
# =====================================================================
$ErrorActionPreference = 'Continue'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }
$Version  = '1.0'
$Self     = $env:MAPLE_SELF
$Docs     = [Environment]::GetFolderPath('MyDocuments')
$Root     = Join-Path $Docs 'MapleLabs'
$Repo     = Join-Path $Root 'maple-ops-automation-lab'
$Work     = Join-Path $Repo 'build'
$Evid     = Join-Path $Repo 'evidence'
$Reports  = Join-Path $Evid 'reports'
$Logs     = Join-Path $Evid 'joblogs'
$Settings = Join-Path $Root 'maple-settings.json'
$Cfg      = $null

# ---------------------------------------------------------------- UI
function Say($t, $c = 'Gray') { Write-Host $t -ForegroundColor $c }
function Head($t) { Write-Host ''; Write-Host ('=== ' + $t + ' ') -ForegroundColor Cyan }
function Ok($t)   { Write-Host ('  [OK]   ' + $t) -ForegroundColor Green }
function Warn($t) { Write-Host ('  [!]    ' + $t) -ForegroundColor Yellow }
function Bad($t)  { Write-Host ('  [FAIL] ' + $t) -ForegroundColor Red }
$script:Auto = $false
function Ask($q, $def = '') {
  if ($script:Auto -and $def) { Say ("  " + $q + ': ' + $def + '  (auto)'); return $def }
  if ($def) { $a = Read-Host ($q + ' [' + $def + ']') } else { $a = Read-Host $q }
  if ([string]::IsNullOrWhiteSpace($a)) { return $def }
  return $a.Trim()
}
function YesNo($q, $def = 'Y') {
  if ($script:Auto) { Say ("  " + $q + ' -> ' + $def + '  (auto)'); return ($def -match '^[Yy]') }
  $a = Ask ($q + ' (Y/N)') $def
  return ($a -match '^[Yy]')
}
function New-Dir($p) {
  if (-not (Test-Path $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null }
}
function Refresh-Path {
  $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
              [Environment]::GetEnvironmentVariable('Path', 'User')
}
function Has($cmd) { return [bool](Get-Command $cmd -ErrorAction SilentlyContinue) }

# ---------------------------------------------------------- settings
function Load-Settings {
  if (Test-Path $Settings) {
    try { return (Get-Content $Settings -Raw | ConvertFrom-Json) } catch { }
  }
  return [pscustomobject]@{ UserId = ''; Host = '204.90.115.200'; Port = '10443' }
}
function Save-Settings {
  New-Dir $Root
  $Cfg | ConvertTo-Json | Set-Content -Path $Settings -Encoding ASCII
}
function Get-UserId {
  if (-not $Cfg.UserId) {
    $u = Ask 'Your IBM Z Xplore user ID (for example Z12345)'
    $Cfg.UserId = $u.ToUpper()
    Save-Settings
  }
  return $Cfg.UserId
}

# ------------------------------------------------------ 1. repo files
function Write-Repo {
  Head 'Creating / updating the Maple Ops Automation Lab repo'
  $files = Get-EmbeddedFiles
  $keep  = @('README.md')
  $n = 0; $kept = 0
  foreach ($k in $files.Keys) {
    $p = Join-Path $Repo ($k -replace '/', '\')
    if (($keep -contains $k) -and (Test-Path $p)) { $kept++; continue }
    New-Dir (Split-Path $p -Parent)
    $text = ($files[$k] -replace "`r`n", "`n") + "`n"
    if ($k -match '\.(cmd|ps1|md)$') { $text = $text -replace "`n", "`r`n" }
    [IO.File]::WriteAllText($p, $text)
    $n++
  }
  foreach ($d in @($Evid, $Reports, $Logs)) { New-Dir $d }
  if ($Self -and (Test-Path $Self)) {
    $dest = Join-Path $Repo 'RUN-MAPLE-LABS.cmd'
    if ((Resolve-Path $Self).Path -ne $dest) { Copy-Item $Self $dest -Force }
  }
  Ok ("$n files written to $Repo")
  if ($kept) { Ok 'README.md already existed, so your edits to it were kept' }
}
function Ensure-Repo { if (-not (Test-Path (Join-Path $Repo 'src\rexx\MSGMON.rexx'))) { Write-Repo } }

# ------------------------------------------- 2. offline rehearsal
function Find-Rexx {
  foreach ($c in @('regina', 'rexx')) {
    $g = Get-Command $c -ErrorAction SilentlyContinue
    if ($g) { return $g.Source }
  }
  return $null
}
function Run-Offline {
  Ensure-Repo
  Head 'Offline rehearsal (runs the same REXX on your PC)'
  $rx = Find-Rexx
  if (-not $rx) {
    Warn 'No REXX interpreter found on this PC (Regina REXX or ooRexx).'
    Say  '  That is fine: GitHub Actions runs the same 30 tests on every push,'
    Say  '  and option 3 runs the real thing on z/OS. To rehearse offline,'
    Say  '  install Regina REXX for Windows, then run this option again.'
    return
  }
  $w = Join-Path $Work 'offline'
  if (Test-Path $w) { Remove-Item $w -Recurse -Force }
  New-Dir $w
  Copy-Item (Join-Path $Repo 'src\cntl\*.txt') $w
  Copy-Item (Join-Path $Repo 'samples\JOBLOG.txt') $w
  Set-Content (Join-Path $w 'STATE.txt') '* state' -Encoding ASCII
  $mon = Join-Path $Repo 'src\rexx\MSGMON.rexx'
  $drs = Join-Path $Repo 'src\rexx\DRSWITCH.rexx'
  Push-Location $w            # base '.' keeps paths with spaces safe
  try {
    Say '  -- Message monitor, dry run on the sample job log' White
    & $rx $mon '.' DRYRUN | ForEach-Object { Say ('  ' + $_) }
    Say ('  MSGMON RC=' + $LASTEXITCODE + '  (8 expected: escalations found)')
    Say '  -- DR runbook: reset, dry run, fault drill, resume' White
    foreach ($m in @('RESET', 'DRYRUN', 'EXECUTE FAULT=7', 'RESUME')) {
      $a = @($drs, '.') + ($m -split ' ')
      $out = & $rx @a
      $out | Where-Object { $_ -match 'FAILED|HALTED|COMPLETE|Resuming|END RC' } |
        ForEach-Object { Say ('  ' + $_) }
    }
  } finally { Pop-Location }
  Build-Report (Join-Path $w 'ALERTS.txt') 'offline'
}

# ------------------------------------------------------ Zowe helpers
function Ensure-Zowe {
  if (Has 'zowe') { return $true }
  Warn 'Zowe CLI is not installed.'
  if (-not (Has 'npm')) {
    if (-not (Has 'winget')) { Bad 'Install Node.js LTS from nodejs.org, then run this again.'; return $false }
    if (-not (YesNo 'Install Node.js LTS with winget now?')) { return $false }
    winget install --id OpenJS.NodeJS.LTS -e --source winget --accept-package-agreements --accept-source-agreements
    Refresh-Path
    if (-not (Has 'npm')) { Bad 'Node.js installed, but close this window and run the file again so Windows picks it up.'; return $false }
  }
  if (-not (YesNo 'Install Zowe CLI (npm install -g @zowe/cli@zowe-v3-lts)?')) { return $false }
  npm install -g '@zowe/cli@zowe-v3-lts'
  Refresh-Path
  if (Has 'zowe') { Ok 'Zowe CLI installed'; return $true }
  Bad 'Zowe CLI did not install. Run the npm command above in a new window and read the error.'
  return $false
}
function ZJ {   # run zowe with JSON output, return the parsed object
  $raw = & zowe @args --rfj 2>$null | Out-String
  try { return ($raw | ConvertFrom-Json) } catch { return $null }
}
function ZT {   # run zowe, return plain text
  return (& zowe @args 2>$null | Out-String)
}
$script:ZoweReady = $false
$script:ShownWhy = $false
function Connect-Zowe {
  if ($script:ZoweReady) { return $true }
  if (-not (Ensure-Zowe)) { return $false }
  $uid = Get-UserId
  Head 'Connecting to IBM Z Xplore'
  $r = ZJ zosmf check status
  if ($r -and $r.success) { Ok 'Using your existing Zowe profile (the one VS Code uses)'; $script:ZoweReady = $true; return $true }
  Warn 'No working Zowe profile found. Enter the z/OSMF details from your Z Xplore setup.'
  $Cfg.Host = Ask '  z/OSMF host' $Cfg.Host
  $Cfg.Port = Ask '  z/OSMF port' $Cfg.Port
  Save-Settings
  $sec = Read-Host ('  Password for ' + $uid) -AsSecureString
  $pw  = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
           [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
  $env:ZOWE_OPT_HOST = $Cfg.Host
  $env:ZOWE_OPT_PORT = $Cfg.Port
  $env:ZOWE_OPT_USER = $uid
  $env:ZOWE_OPT_PASSWORD = $pw
  $env:ZOWE_OPT_REJECT_UNAUTHORIZED = 'false'
  $r = ZJ zosmf check status
  if ($r -and $r.success) { Ok 'Connected (password kept only in this window, never saved)'; $script:ZoweReady = $true; return $true }
  Bad 'Could not connect. Check the host, port, user ID and password, and that Z Xplore is up.'
  return $false
}
function DS-Exists($dsn) {
  $r = ZJ zos-files list data-set $dsn
  if (-not $r -or -not $r.success) { return $false }
  return (@($r.data.apiResponse.items).Count -gt 0 -and $r.data.apiResponse.items)
}
function Zowe-Why($r) {   # the reason Zowe gives for a failed command
  if (-not $r) { return 'no reply from Zowe' }
  $m = @($r.message, $r.stderr, $r.error.msg) | Where-Object { $_ } | Select-Object -First 1
  if (-not $m) { return 'unknown' }
  return (([string]$m) -replace '\s+', ' ').Trim()
}
function Submit-Wait($what, $src, [switch]$Local) {
  if ($Local) { $r = ZJ zos-jobs submit local-file $src --wait-for-output }
  else        { $r = ZJ zos-jobs submit data-set $src --wait-for-output }
  if ((-not $r -or -not $r.success) -and -not $Local -and $src -match '\.JCL\((\w+)\)$') {
    # fall back to the same JCL from this PC, which submits the identical job
    $why = Zowe-Why $r
    $lf = Join-Path $Repo ('src\jcl\' + $Matches[1] + '.jcl')
    if (Test-Path $lf) {
      if (-not $script:ShownWhy) { Warn ('Submit from the library failed: ' + $why); Warn 'Submitting the same JCL from this PC instead.'; $script:ShownWhy = $true }
      $r = ZJ zos-jobs submit local-file $lf --wait-for-output
    }
  }
  if (-not $r -or -not $r.success) { Bad ("$what could not be submitted: " + (Zowe-Why $r)); return $null }
  $d = $r.data
  $rc = [string]$d.retcode
  Say ('  ' + $what.PadRight(10) + ' ' + $d.jobid + '  ' + $rc)
  return $d
}
function Wait-Job($jobid, $secs = 120) {
  $t = 0
  while ($t -lt $secs) {
    $r = ZJ zos-jobs view job-status-by-jobid $jobid
    if ($r -and $r.data.status -eq 'OUTPUT') { return $r.data }
    Start-Sleep -Seconds 3; $t += 3
  }
  return $null
}
function Get-Spool($job) {
  $text = ZT zos-jobs view all-spool-content $job.jobid
  New-Dir $Logs
  $f = Join-Path $Logs ($job.jobname + '-' + $job.jobid + '.txt')
  Set-Content -Path $f -Value $text -Encoding ASCII
  return $text
}
function Show-Tso($text) {   # print the REXX output (SYSTSPRT) part of a spool
  $on = $false; $shown = 0
  $lines = $text -split "`r?`n"
  foreach ($l in $lines) {
    if ($l -match '^\s*1?READY\s*$') { $on = $true; continue }
    if ($on -and $l -match '^\s*1?END\s*$') { break }
    if ($on -and $l.Trim()) { Say ('    ' + $l.TrimEnd()); $shown++ }
  }
  if (-not $shown) {
    $lines | Where-Object { $_ -match '^\s*(MSGMON|DRSWITCH|OPSJOB|MPSTREAM|STEP |HALTED|RUNBOOK)' } |
      ForEach-Object { Say ('    ' + $_.TrimEnd()) }
  }
}
function Put-JobLog($jobs, $uid) {   # spool of each job -> MAPLE.OPS.JOBLOG
  $sb = New-Object System.Text.StringBuilder
  foreach ($j in $jobs) {
    [void]$sb.AppendLine('>>> JOB ' + $j.jobname + ' ' + $j.jobid)
    foreach ($l in ((Get-Spool $j) -split "`r?`n")) {
      $l = $l.TrimEnd()
      if ($l.Length -gt 250) { $l = $l.Substring(0, 250) }
      [void]$sb.AppendLine($l)
    }
  }
  New-Dir $Work
  $f = Join-Path $Work 'joblog.txt'
  [IO.File]::WriteAllText($f, $sb.ToString())
  $r = ZJ zos-files upload file-to-data-set $f "$uid.MAPLE.OPS.JOBLOG"
  if ($r -and $r.success) { Ok ("$($jobs.Count) job log(s) loaded into $uid.MAPLE.OPS.JOBLOG") }
  else { Bad 'Upload of JOBLOG failed' }
}


function DS-Org($dsn) {   # PO / PO-E for libraries, PS for sequential, '' if missing
  $r = ZJ zos-files list data-set $dsn --attributes
  if (-not $r -or -not $r.success) { return '' }
  $it = @($r.data.apiResponse.items) | Where-Object { $_.dsname -eq $dsn } | Select-Object -First 1
  if (-not $it) { return '' }
  return [string]$it.dsorg
}
function Fix-Libraries($libs) {   # $libs = list of @(dsn, recfm, lrecl-or-blksize)
  # Z Xplore's SMS rules accept libraries made by a JCL job, not by a z/OSMF create call,
  # so sequential look-alikes are deleted and the missing ones allocated with IEFBR14.
  $need = @()
  foreach ($l in $libs) {
    $org = DS-Org $l[0]
    if ($org -like 'PO*') { continue }
    if ($org) {
      Warn ($l[0] + " is a sequential data set ($org), not a library. Deleting it so it can be recreated.")
      ZJ zos-files delete data-set $l[0] --for-sure | Out-Null
    }
    $need += ,$l
  }
  if (-not $need.Count) { return $true }
  $j = @('//LIBALLOC JOB 1,NOTIFY=&SYSUID,MSGLEVEL=(1,1)', '//* RECREATE LIBRARIES AS REAL PDSES (DIRECTORY SPACE + DSORG=PO)', '//ALLOC    EXEC PGM=IEFBR14')
  $i = 0
  foreach ($l in $need) {
    $i++
    $j += ('//L' + $i.ToString().PadRight(7) + 'DD DSN=' + $l[0] + ',DISP=(NEW,CATLG),')
    if ($l[1] -eq 'U') { $j += '//            SPACE=(TRK,(5,5,10)),DSNTYPE=LIBRARY,DSORG=PO,'; $j += '//            RECFM=U,BLKSIZE=32760' }
    else { $j += '//            SPACE=(TRK,(5,5,10)),DSNTYPE=LIBRARY,DSORG=PO,'; $j += ('//            RECFM=' + $l[1] + ',LRECL=' + $l[2]) }
  }
  New-Dir (Join-Path $Work 'jcl')
  $f = Join-Path $Work 'jcl\LIBALLOC.jcl'
  [IO.File]::WriteAllText($f, (($j -join "`n") + "`n"))
  $d = Submit-Wait 'LIBALLOC' $f -Local
  if ($d) { Get-Spool $d | Out-Null }
  $ok = $true
  foreach ($l in $need) {
    if ((DS-Org $l[0]) -like 'PO*') { Ok ($l[0] + ' is now a library') }
    else { Bad ($l[0] + ' is still not a library. Open the LIBALLOC job output in VS Code and send it to Claude.'); $ok = $false }
  }
  return $ok
}

# ------------------------------------------------- 3. live on Z Xplore
function Setup-Ops($uid) {
  Head 'Allocating and uploading the Ops lab libraries'
  if (DS-Exists "$uid.MAPLE.OPS.JOBLOG") { Ok 'Ops data sets already exist' }
  else {
    $d = Submit-Wait 'OPSALLOC' (Join-Path $Repo 'src\jcl\OPSALLOC.jcl') -Local
    if (-not $d -or $d.retcode -ne 'CC 0000') { Bad 'OPSALLOC did not end CC 0000. Open its output in VS Code.'; return $false }
  }
  if (-not (Fix-Libraries @(@("$uid.MAPLE.OPS.REXX", 'FB', '80'), @("$uid.MAPLE.OPS.JCL", 'FB', '80'), @("$uid.MAPLE.OPS.CNTL", 'FB', '80')))) { return $false }
  $sets = @(@('src\rexx', '*.rexx', 'REXX'), @('src\jcl', '*.jcl', 'JCL'), @('src\cntl', '*.txt', 'CNTL'))
  foreach ($s in $sets) {
    $n = 0
    foreach ($f in (Get-ChildItem (Join-Path $Repo $s[0]) -Filter $s[1])) {
      $mem = $f.BaseName.ToUpper()
      $r = ZJ zos-files upload file-to-data-set $f.FullName "$uid.MAPLE.OPS.$($s[2])($mem)"
      if ($r -and $r.success) { $n++ } else { Bad "Upload failed: $mem" }
    }
    Ok ("$n members uploaded to $uid.MAPLE.OPS." + $s[2])
  }
  return $true
}
function Run-Monitor($uid) {
  Head 'Day 2: message monitor and automatic recovery'
  $jcl = "$uid.MAPLE.OPS.JCL"
  Submit-Wait 'OPSRESET' "$jcl(OPSRESET)" | Out-Null
  New-Dir $Work
  $st = Join-Path $Work 'state.txt'
  Set-Content $st '* MSGMON retry state  job.msgid count' -Encoding ASCII
  ZJ zos-files upload file-to-data-set $st "$uid.MAPLE.OPS.STATE" | Out-Null
  Ok 'Retry counters reset for a fresh demo'
  $jobs = @()
  foreach ($m in 'OPSJOB1', 'OPSJOB2', 'OPSJOB3', 'OPSJOB4', 'OPSJOB5') {
    $d = Submit-Wait $m "$jcl($m)"
    if ($d) { $jobs += $d }
  }
  $first1 = ($jobs | Where-Object { $_.jobname -eq 'OPSJOB1' }).jobid
  Put-JobLog $jobs $uid
  Say '  -- Dry run (decides, submits nothing):' White
  $d = Submit-Wait 'OPSMOND' "$jcl(OPSMOND)"
  if ($d) { Show-Tso (Get-Spool $d) }
  Say '  -- Live run (RECOVER rules really submit):' White
  $d = Submit-Wait 'OPSMON' "$jcl(OPSMON)"
  if (-not $d) { return }
  $t = Get-Spool $d
  Show-Tso $t
  if ($t -match 'OPSFIX1=(JOB\d+)') {
    $fix = $Matches[1]
    Say ("  Waiting for recovery job OPSFIX1 $fix ...")
    $f = Wait-Job $fix
    if ($f) { Say ('  OPSFIX1    ' + $fix + '  ' + $f.retcode); Get-Spool $f | Out-Null }
    Say '  Waiting for the resubmitted OPSJOB1 ...'
    $re = $null; $t2 = 0
    while (-not $re -and $t2 -lt 120) {
      $l = ZJ zos-jobs list jobs --owner $uid --prefix OPSJOB1
      if ($l -and $l.data) {
        $n1 = [long]($first1 -replace '\D', '')
        $re = $l.data | Where-Object { [long]($_.jobid -replace '\D', '') -gt $n1 -and $_.status -eq 'OUTPUT' } |
              Sort-Object { [long]($_.jobid -replace '\D', '') } -Descending | Select-Object -First 1
      }
      if (-not $re) { Start-Sleep -Seconds 4; $t2 += 4 }
    }
    if ($re) {
      Say ('  OPSJOB1    ' + $re.jobid + '  ' + $re.retcode + '  (rerun)')
      Put-JobLog @($re) $uid
      Say '  -- Second pass on the rerun:' White
      $d = Submit-Wait 'OPSMON' "$jcl(OPSMON)"
      if ($d) { Show-Tso (Get-Spool $d) }
    } else { Warn 'The rerun of OPSJOB1 was not found within 2 minutes. Check the Jobs view.' }
  } else { Warn 'No OPSFIX1 submission seen (retry limit reached?). See STATE and STANDARDS.md rule 5.' }
}
function Run-DR($uid) {
  Head 'Day 3: DR runbook and DR test drill'
  $jcl = "$uid.MAPLE.OPS.JCL"
  $plan = @(
    @('OPSDRRST', 'reset both sites'),
    @('OPSDRDRY', 'dry run of the switch'),
    @('OPSDRFLT', 'DR drill: fault at step 7 (RC 8 expected)'),
    @('OPSDREXE', 'new run while incomplete (refused, RC 8 expected)'),
    @('OPSDRRES', 'resume from the failed step'),
    @('OPSDRBAK', 'switch back to SITEA'))
  foreach ($p in $plan) {
    Say ('  -- ' + $p[1]) White
    $d = Submit-Wait $p[0] "$jcl($($p[0]))"
    if ($d) {
      $t = Get-Spool $d
      foreach ($l in ($t -split "`r?`n")) {
        if ($l -notmatch '^\s*//' -and $l -match 'FAILED|HALTED|REFUSED|COMPLETE|Resuming|Nothing to|END RC|DRSWITCH:|Exec member|NOT FOUND') { Say ('    ' + $l.Trim()) }
      }
    }
  }
  foreach ($ds in 'DRLOG', 'SITECFG') {
    $f = Join-Path $Evid ($ds + '.txt')
    ZJ zos-files download data-set "$uid.MAPLE.OPS.$ds" -f $f | Out-Null
    if (Test-Path $f) { Ok "$ds saved to evidence\$ds.txt" }
  }
}
function Get-Alerts($uid) {
  New-Dir $Work
  $f = Join-Path $Work 'ALERTS.txt'
  if (Test-Path $f) { Remove-Item $f -Force }
  ZJ zos-files download data-set "$uid.MAPLE.OPS.ALERTS" -f $f | Out-Null
  if (Test-Path $f) { return $f }
  Bad 'Could not download ALERTS'
  return $null
}
function Run-Live {
  Ensure-Repo
  if (-not (Connect-Zowe)) { return }
  $uid = Get-UserId
  if (-not (Setup-Ops $uid)) { return }
  Run-Monitor $uid
  Run-DR $uid
  $f = Get-Alerts $uid
  if ($f) { Build-Report $f 'z/OS' }
}

# ------------------------------------------------------- report
function Read-Alerts($file) {
  $rows = @()
  foreach ($l in (Get-Content $file)) {
    $l = $l.TrimEnd()
    if (-not $l -or $l.StartsWith('*')) { continue }
    $p = $l -split ',', 9
    if ($p.Count -lt 9) { continue }
    $rows += [pscustomobject]@{ Run = $p[0]; Job = $p[1]; JobId = $p[2]; Step = $p[3]
      Key = $p[4]; Severity = $p[5]; Action = $p[6]; Result = $p[7]; Detail = $p[8] }
  }
  return $rows
}
function Save-Xlsx($csv, $xlsx) {
  try { $xl = New-Object -ComObject Excel.Application } catch { return $false }
  try {
    $xl.DisplayAlerts = $false
    $wb = $xl.Workbooks.Open($csv)
    $ws = $wb.Worksheets.Item(1)
    $ws.Name = 'Alerts'
    $ws.Rows.Item(1).Font.Bold = $true
    [void]$ws.UsedRange.Columns.AutoFit()
    $s = $wb.Worksheets.Add()
    $s.Name = 'Summary'
    $s.Cells.Item(1, 1).Value2 = 'Maple Ops Automation Lab - alert summary'
    $s.Cells.Item(1, 1).Font.Bold = $true
    $s.Cells.Item(3, 1).Value2 = 'Severity'; $s.Cells.Item(3, 2).Value2 = 'Alerts'
    $s.Cells.Item(3, 4).Value2 = 'Action';   $s.Cells.Item(3, 5).Value2 = 'Alerts'
    $r = 4
    foreach ($v in 'CRIT', 'HIGH', 'WARN', 'INFO') {
      $s.Cells.Item($r, 1).Value2 = $v
      $s.Cells.Item($r, 2).Formula = "=COUNTIF(Alerts!F:F,""$v"")"; $r++
    }
    $r = 4
    foreach ($v in 'ESCALATE', 'RECOVER', 'NOTIFY', 'LOG') {
      $s.Cells.Item($r, 4).Value2 = $v
      $s.Cells.Item($r, 5).Formula = "=COUNTIF(Alerts!G:G,""$v"")"; $r++
    }
    $s.Cells.Item(9, 1).Value2 = 'Recovered automatically'
    $s.Cells.Item(9, 2).Formula = '=COUNTIF(Alerts!H:H,"SUBMITTED*")'
    $s.Range('A3:E3').Font.Bold = $true
    [void]$s.UsedRange.Columns.AutoFit()
    $wb.SaveAs($xlsx, 51)
    $wb.Close($false)
    return $true
  } catch { return $false }
  finally { $xl.Quit(); [void][Runtime.InteropServices.Marshal]::ReleaseComObject($xl) }
}
function Build-Report($alertFile, $where) {
  Head 'Building the alert report'
  if (-not (Test-Path $alertFile)) { Bad 'No ALERTS file to report on'; return }
  $rows = @(Read-Alerts $alertFile)
  if (-not $rows.Count) { Warn 'ALERTS is empty'; return }
  New-Dir $Reports
  $csv = Join-Path $Reports 'alerts.csv'
  $rows | Export-Csv -Path $csv -NoTypeInformation -Encoding ASCII
  Ok ("$($rows.Count) alerts -> evidence\reports\alerts.csv")
  $xlsx = Join-Path $Reports 'ops-report.xlsx'
  if (Save-Xlsx $csv $xlsx) { Ok 'Excel report -> evidence\reports\ops-report.xlsx' }
  else { Warn 'Excel not found, so no .xlsx (the CSV opens in Excel later)' }
  # incident drafts for the latest decision per escalated job
  $esc = @($rows | Where-Object { $_.Result -match 'INCIDENT REQUIRED|RETRY LIMIT' })
  $md = New-Object System.Text.StringBuilder
  [void]$md.AppendLine('# Incident drafts from MSGMON (' + $where + ')')
  [void]$md.AppendLine('')
  [void]$md.AppendLine('Created by the Maple Ops Automation Lab. Paste into ServiceNow and fill in the blanks.')
  foreach ($g in ($esc | Group-Object Job)) {
    $last = $g.Group | Sort-Object Run | Select-Object -Last 1
    $hits = @($rows | Where-Object { $_.Job -eq $last.Job -and $_.Run -eq $last.Run })
    $pri = '3 - Moderate'; if ($last.Severity -eq 'CRIT') { $pri = '2 - High' }
    [void]$md.AppendLine('')
    [void]$md.AppendLine('## ' + $last.Job + ' (' + $last.JobId + ') - ' + $last.Key + ' detected by automation')
    [void]$md.AppendLine('')
    [void]$md.AppendLine('| Field | Value |')
    [void]$md.AppendLine('|---|---|')
    [void]$md.AppendLine('| Short description | ' + $last.Job + ' step ' + $last.Step + ' failed: ' + $last.Key + ' |')
    [void]$md.AppendLine('| Priority | ' + $pri + ' |')
    [void]$md.AppendLine('| Assignment group | Mainframe Automation (MMA) |')
    [void]$md.AppendLine('| Detected by | MSGMON run ' + $last.Run + ', rule ' + $last.Key + ' -> ' + $last.Action + ' |')
    [void]$md.AppendLine('| Number | INC________ |')
    [void]$md.AppendLine('')
    [void]$md.AppendLine('**Messages found:**')
    foreach ($h in $hits) { [void]$md.AppendLine('- `' + $h.Detail + '`') }
    if ($last.Job -like 'MP*') {
      [void]$md.AppendLine('')
      [void]$md.AppendLine('Release lab: use with `change/INC0001-s0c7-abend.md` (Caused by Change: CHG0001).')
    }
  }
  $mdf = Join-Path $Reports 'INC-drafts.md'
  [IO.File]::WriteAllText($mdf, $md.ToString())
  Ok ("$(@($esc | Group-Object Job).Count) incident draft(s) -> evidence\reports\INC-drafts.md")
  # html
  $enc = { param($s) [System.Net.WebUtility]::HtmlEncode([string]$s) }
  $col = @{ CRIT = '#b42318'; HIGH = '#c4320a'; WARN = '#b54708'; INFO = '#027a48' }
  $h = New-Object System.Text.StringBuilder
  [void]$h.Append('<!DOCTYPE html><html><head><meta charset="utf-8"><title>Maple Ops alert report</title>')
  [void]$h.Append('<style>body{font-family:Segoe UI,Arial,sans-serif;margin:32px;color:#1d2939}h1{color:#1F3864}')
  [void]$h.Append('table{border-collapse:collapse;width:100%;font-size:13px}th{background:#1F3864;color:#fff;text-align:left}')
  [void]$h.Append('th,td{padding:6px 8px;border-bottom:1px solid #e4e7ec}.k{display:inline-block;margin:0 16px 16px 0;padding:12px 16px;border:1px solid #e4e7ec;border-radius:8px}')
  [void]$h.Append('.k b{display:block;font-size:24px}code{font-size:12px}</style></head><body>')
  [void]$h.Append('<h1>Maple Ops Automation Lab: alert report</h1><p>Source: ' + $where + ', ' + (Get-Date -Format 'yyyy-MM-dd HH:mm') + '</p>')
  foreach ($v in 'CRIT', 'HIGH', 'WARN', 'INFO') {
    $c = @($rows | Where-Object { $_.Severity -eq $v }).Count
    [void]$h.Append('<span class="k" style="color:' + $col[$v] + '"><b>' + $c + '</b>' + $v + '</span>')
  }
  [void]$h.Append('<table><tr><th>Run</th><th>Job</th><th>Job ID</th><th>Step</th><th>Rule</th><th>Severity</th><th>Action</th><th>Result</th><th>Message</th></tr>')
  foreach ($r in $rows) {
    [void]$h.Append('<tr><td>' + (& $enc $r.Run) + '</td><td>' + (& $enc $r.Job) + '</td><td>' + (& $enc $r.JobId) +
      '</td><td>' + (& $enc $r.Step) + '</td><td>' + (& $enc $r.Key) + '</td><td style="color:' + $col[$r.Severity] + '"><b>' +
      (& $enc $r.Severity) + '</b></td><td>' + (& $enc $r.Action) + '</td><td>' + (& $enc $r.Result) +
      '</td><td><code>' + (& $enc $r.Detail) + '</code></td></tr>')
  }
  [void]$h.Append('</table></body></html>')
  $html = Join-Path $Reports 'ops-report.html'
  [IO.File]::WriteAllText($html, $h.ToString())
  Ok 'HTML report -> evidence\reports\ops-report.html'
  if (YesNo 'Open the HTML report now?' 'Y') { Start-Process $html }
}

# --------------------------------------------- release lab helpers
function Find-ReleaseLab {
  $dl = Join-Path $env:USERPROFILE 'Downloads'
  $desk = [Environment]::GetFolderPath('Desktop')
  $cands = @((Join-Path $Root 'maple-host-release-lab'), (Join-Path $dl 'maple-host-release-lab'),
             (Join-Path $dl 'maple-host-release-lab\maple-host-release-lab'), (Join-Path $desk 'maple-host-release-lab'),
             (Join-Path $Docs 'maple-host-release-lab'))
  if ($Self) {
    $here = Split-Path $Self -Parent
    $cands += @((Join-Path $here 'maple-host-release-lab'), $here, (Split-Path $here -Parent))
  }
  foreach ($c in $cands) {
    if ($c -and (Test-Path (Join-Path $c 'LAB-GUIDE.md')) -and (Test-Path (Join-Path $c 'src\jcl\MPSTREAM.jcl'))) { return $c }
  }
  $p = Ask 'Maple Host Release Lab folder not found. Paste its folder path (or Enter to skip)'
  if ($p -and (Test-Path (Join-Path $p 'src\jcl\MPSTREAM.jcl'))) { return $p }
  return $null
}
function Release-Watch {
  Ensure-Repo
  if (-not (Connect-Zowe)) { return }
  $uid = Get-UserId
  if (-not (DS-Exists "$uid.MAPLE.OPS.REXX")) { if (-not (Setup-Ops $uid)) { return } }
  Head 'Day 4: scan Maple Host Release Lab jobs with the monitor'
  $l = ZJ zos-jobs list jobs --owner $uid --prefix 'MP*'
  $list = @()
  if ($l -and $l.data) { $list = @($l.data | Where-Object { $_.status -eq 'OUTPUT' } | Sort-Object jobid -Descending | Select-Object -First 15) }
  if (-not $list.Count) { Warn 'No finished MP* jobs found. Run MPSTREAM (release lab Day 5) first.'; return }
  for ($i = 0; $i -lt $list.Count; $i++) {
    Say ('  ' + ($i + 1).ToString().PadLeft(2) + '. ' + $list[$i].jobname.PadRight(9) + $list[$i].jobid.PadRight(10) + $list[$i].retcode)
  }
  $pick = Ask 'Numbers to scan, comma separated' '1'
  $jobs = @()
  foreach ($n in ($pick -split ',')) { $k = [int]($n.Trim()) - 1; if ($k -ge 0 -and $k -lt $list.Count) { $jobs += $list[$k] } }
  if (-not $jobs.Count) { return }
  Put-JobLog $jobs $uid
  $d = Submit-Wait 'OPSMOND' "$uid.MAPLE.OPS.JCL(OPSMOND)"
  if ($d) { Show-Tso (Get-Spool $d) }
  $f = Get-Alerts $uid
  if ($f) { Build-Report $f 'z/OS, release lab jobs' }
  $rl = Find-ReleaseLab
  $inc = Join-Path $Reports 'INC-drafts.md'
  if ($rl -and (Test-Path $inc)) {
    New-Dir (Join-Path $rl 'change')
    Copy-Item $inc (Join-Path $rl 'change\INC-detected-by-MSGMON.md') -Force
    Ok 'Copy saved in the release lab: change\INC-detected-by-MSGMON.md'
  }
}
function Release-Day1 {
  $rl = Find-ReleaseLab
  if (-not $rl) { Warn 'Unzip maple-host-release-lab.zip first (Documents\MapleLabs is a good place).'; return }
  if (-not (Connect-Zowe)) { return }
  $uid = Get-UserId
  Head 'Maple Host Release Lab: Day 1 allocation, load and uploads'
  Say  '  (Days 2-5 stay hands-on on purpose: ISPF edits, PAT, ServiceNow, the incident.)'
  $ma = Join-Path $rl 'src\jcl\MPALLOC.jcl'
  if (Test-Path $ma) {   # the kit's MPALLOC gave no directory space, which makes sequential data sets
    $t = [IO.File]::ReadAllText($ma)
    $t2 = [regex]::Replace($t, 'SPACE=\(TRK,\((\d+),(\d+)\)\),DSNTYPE=LIBRARY', 'SPACE=(TRK,($1,$2,10)),DSNTYPE=LIBRARY')
    if ($t2 -ne $t) { [IO.File]::WriteAllText($ma, $t2); Ok 'MPALLOC.jcl fixed: libraries now get directory space (real PDSEs)' }
  }
  if (DS-Exists "$uid.MPL.JCL") {
    Ok "$uid.MPL libraries already exist, skipping MPALLOC"
    $ls = @()
    foreach ($q in 'JCL', 'DEV.SRC', 'QA.SRC', 'PROD.SRC', 'BKUPQA.SRC', 'BKUPPROD.SRC') { $ls += ,@("$uid.MPL.$q", 'FB', '80') }
    foreach ($q in 'DEV.LOAD', 'QA.LOAD', 'PROD.LOAD', 'BKUPQA.LOAD', 'BKUPPROD.LOAD') { $ls += ,@("$uid.MPL.$q", 'U', '0') }
    if (-not (Fix-Libraries $ls)) { return }
  }
  else {
    $d = Submit-Wait 'MPALLOC' $ma -Local
    if (-not $d -or $d.retcode -ne 'CC 0000') { Bad 'MPALLOC did not end CC 0000. Open its output in VS Code.'; return }
    $load = Join-Path $rl 'src\jcl\MPLOAD.jcl'
    if (Test-Path $load) { Submit-Wait 'MPLOAD' $load -Local | Out-Null }
  }
  $cbl = Join-Path $rl 'src\cobol\MPINTCLC.cbl'
  if (Test-Path $cbl) {
    $r = ZJ zos-files upload file-to-data-set $cbl "$uid.MPL.DEV.SRC(MPINTCLC)"
    if ($r -and $r.success) { Ok "MPINTCLC uploaded to $uid.MPL.DEV.SRC" } else { Bad 'COBOL upload failed' }
  }
  $n = 0
  foreach ($f in (Get-ChildItem (Join-Path $rl 'src\jcl') -Filter '*.jcl')) {
    $r = ZJ zos-files upload file-to-data-set $f.FullName "$uid.MPL.JCL($($f.BaseName.ToUpper()))"
    if ($r -and $r.success) { $n++ }
  }
  Ok "$n JCL members uploaded to $uid.MPL.JCL"
  Say  '  Next: release lab LAB-GUIDE.md, Day 1 step 6 (ISPF practice).' White
}


# ------------------------------------------- release lab, Days 1-5
$script:RLLog = @()
function Set-JclParms($src, $parms) {   # copy of a JCL member with its SET values changed
  $lines = @(Get-Content $src)
  foreach ($k in $parms.Keys) {
    $found = $false
    for ($i = 0; $i -lt $lines.Count; $i++) {
      if ($lines[$i] -match '^//\s+SET\s' -and $lines[$i] -match ('\b' + $k + '=')) {
        $lines[$i] = $lines[$i] -replace ('\b' + $k + '=[^,\s]*'), ($k + '=' + $parms[$k])
        $found = $true
      }
    }
    if (-not $found) { Bad ("SET $k= not found in " + (Split-Path $src -Leaf)); return $null }
  }
  New-Dir (Join-Path $Work 'jcl')
  $name = [IO.Path]::GetFileNameWithoutExtension($src) + '-' + (@($parms.Values) -join '-') + '.jcl'
  $out = Join-Path $Work ('jcl\' + $name)
  [IO.File]::WriteAllText($out, (($lines -join "`n") + "`n"))
  return $out
}
function RL-Run($rl, $member, $parms, $okList, $what) {
  $src = Join-Path $rl ("src\jcl\$member.jcl")
  if (-not (Test-Path $src)) { Bad "$member.jcl not found in the release lab"; return $null }
  $f = $src
  if ($parms) { $f = Set-JclParms $src $parms; if (-not $f) { return $null } }
  $d = Submit-Wait $member $f -Local
  if (-not $d) { return $null }
  $text = Get-Spool $d
  $ev = Join-Path $rl 'evidence\auto-run'
  New-Dir $ev
  Set-Content -Path (Join-Path $ev ($d.jobname + '-' + $d.jobid + '.txt')) -Value $text -Encoding ASCII
  $rc = [string]$d.retcode
  $ok = $false
  foreach ($o in $okList) { if ($rc -like $o) { $ok = $true } }
  if ($ok) { Ok ($what + ' -> ' + $rc) } else { Bad ($what + ' -> ' + $rc + '  (expected ' + ($okList -join ' or ') + ')') }
  $script:RLLog += [pscustomobject]@{ Time = (Get-Date -Format 'HH:mm:ss'); Step = $what; Job = $member; JobId = $d.jobid; Result = $rc; Pass = $ok }
  $d | Add-Member -NotePropertyName ok -NotePropertyValue $ok -Force
  return $d
}
function Make-V10($rl, $uid) {   # the Day 2 ISPF edit: comment out the CHG0002 PERFORM
  $cbl = Join-Path $rl 'src\cobol\MPINTCLC.cbl'
  $lines = @(Get-Content $cbl)
  $n = 0
  for ($i = 0; $i -lt $lines.Count; $i++) {
    $l = $lines[$i]
    if ($l.Length -ge 79 -and $l.Substring(72).Trim() -eq 'CHG0002' -and $l -match 'PERFORM 2200-NUMERIC-EDITS') {
      $lines[$i] = $l.Substring(0, 6) + '*' + $l.Substring(7); $n++
    }
  }
  if ($n -ne 1) { Bad "Expected one CHG0002 PERFORM line in MPINTCLC.cbl, found $n"; return $false }
  New-Dir $Work
  $v10 = Join-Path $Work 'MPINTCLC-v10.cbl'
  [IO.File]::WriteAllText($v10, (($lines -join "`n") + "`n"))
  $r = ZJ zos-files upload file-to-data-set $v10 "$uid.MPL.DEV.SRC(MPINTCLC)"
  if ($r -and $r.success) { Ok 'v1.0 made (CHG0002 PERFORM commented out in column 7) and uploaded to DEV'; return $true }
  Bad 'Upload of v1.0 failed'; return $false
}
function SN-Connect {
  if (-not (YesNo 'Create the ServiceNow records too (needs your free developer instance)?' 'N')) { return $null }
  $inst = Ask '  Instance name (the dev12345 part of dev12345.service-now.com)'
  $user = Ask '  ServiceNow user name' 'admin'
  $sec  = Read-Host ('  Password for ' + $user) -AsSecureString
  $pw   = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
  $pair = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($user + ':' + $pw))
  $sn = [pscustomobject]@{ Base = "https://$inst.service-now.com/api/now/table"; Head = @{ Authorization = "Basic $pair"; Accept = 'application/json' } }
  try { Invoke-RestMethod -Uri ($sn.Base + '/sys_user?sysparm_limit=1') -Headers $sn.Head -Method Get | Out-Null; Ok 'ServiceNow connected'; return $sn }
  catch { Bad ('ServiceNow sign-in failed: ' + $_.Exception.Message + ' (is the instance awake?)'); return $null }
}
function SN-Post($sn, $table, $fields) {
  if (-not $sn) { return $null }
  try {
    $r = Invoke-RestMethod -Uri ($sn.Base + '/' + $table) -Headers $sn.Head -Method Post -ContentType 'application/json' -Body ($fields | ConvertTo-Json)
    Ok ("ServiceNow $table " + $r.result.number + ' created'); return $r.result
  } catch { Bad ("ServiceNow $table not created: " + $_.Exception.Message); return $null }
}
function SN-Note($sn, $table, $rec, $note) {
  if (-not $sn -or -not $rec) { return }
  try { Invoke-RestMethod -Uri ($sn.Base + '/' + $table + '/' + $rec.sys_id) -Headers $sn.Head -Method Patch -ContentType 'application/json' -Body (@{ work_notes = $note } | ConvertTo-Json) | Out-Null } catch { }
}
function RL-Notes($from) { # job results since index $from, for work notes
  return (($script:RLLog | Select-Object -Skip $from | ForEach-Object { $_.Time + '  ' + $_.Step + '  ' + $_.JobId + '  ' + $_.Result }) -join "`n")
}
function Release-Full {
  Ensure-Repo
  $rl = Find-ReleaseLab
  if (-not $rl) { Warn 'Unzip maple-host-release-lab.zip into Documents\MapleLabs first, then run this again.'; return }
  if (-not (Connect-Zowe)) { return }
  $uid = Get-UserId
  $script:RLLog = @()
  $sn = SN-Connect
  Release-Day1
  Head 'Release lab Day 2: build v1.0 and PAT in QA'
  if (-not (Make-V10 $rl $uid)) { return }
  $d = RL-Run $rl 'MPCOMPL' $null @('CC 0000', 'CC 0004') 'Compile v1.0 in DEV'; if (-not $d -or -not $d.ok) { return }
  RL-Run $rl 'MPSTREAM' ([ordered]@{ ENV = 'DEV'; DATA = 'TEST' }) @('CC 000*') 'Unit run in DEV' | Out-Null
  $d = RL-Run $rl 'MPPROMOT' ([ordered]@{ FROM = 'DEV'; TO = 'QA' }) @('CC 0000', 'CC 0004') 'Promote DEV -> QA'; if (-not $d -or -not $d.ok) { return }
  RL-Run $rl 'MPSTREAM' ([ordered]@{ ENV = 'QA'; DATA = 'TEST' }) @('CC 000*') 'QA run, test data' | Out-Null
  $d = RL-Run $rl 'MPPATCMP' ([ordered]@{ ACTUAL = 'TEST'; EXPECT = 'V10TEST' }) @('CC 0000') 'PAT v1.0 vs V10TEST'; if (-not $d -or -not $d.ok) { Bad 'PAT failed: stopping before production, as a real change would.'; return }
  Head 'Release lab Day 4: CHG0001, deploy v1.0 to PROD'
  $mark = $script:RLLog.Count
  $chg1 = SN-Post $sn 'change_request' @{ type = 'normal'; short_description = 'CHG0001 Deploy MPINTCLC v1.0 - MPL Interest Accrual Batch'
    description = 'New nightly interest accrual program MPINTCLC v1.0 into PROD (Maple Host Release Lab).'
    implementation_plan = 'Hold stream; MPPROMOT FROM=QA TO=PROD; verify with MPSTREAM ENV=PROD DATA=TEST and MPPATCMP EXPECT=V10TEST (RC 0); release stream.'
    backout_plan = 'MPBACKOT TO=PROD restores MPL.BKUPPROD.*, rerun verification. Decision point: verification not RC 0 by 02:30.'
    test_plan = 'QA PAT pass: MPPATCMP RC 0 against signed-off baseline V10TEST.' }
  if ($chg1) { Warn ('Approve ' + $chg1.number + ' in ServiceNow as a different user (cab.approver) before PROD - that is the segregation-of-duties evidence.') }
  $d = RL-Run $rl 'MPPROMOT' ([ordered]@{ FROM = 'QA'; TO = 'PROD' }) @('CC 0000', 'CC 0004') 'Promote QA -> PROD (CHG0001)'; if (-not $d -or -not $d.ok) { return }
  RL-Run $rl 'MPSTREAM' ([ordered]@{ ENV = 'PROD'; DATA = 'TEST' }) @('CC 000*') 'PROD verification run' | Out-Null
  RL-Run $rl 'MPPATCMP' ([ordered]@{ ACTUAL = 'TEST'; EXPECT = 'V10TEST' }) @('CC 0000') 'PROD verification PAT' | Out-Null
  SN-Note $sn 'change_request' $chg1 ("Implementation log (automated run):`n" + (RL-Notes $mark))
  Head 'Release lab Day 5: first production night'
  $prod = RL-Run $rl 'MPSTREAM' ([ordered]@{ ENV = 'PROD'; DATA = 'PROD' }) @('ABEND*', 'CC *') 'First PROD run, PROD data'
  if (-not $prod) { return }
  $abended = ([string]$prod.retcode -like 'ABEND*')
  if ($abended) { Warn ('Production abend: ' + $prod.retcode + '. Handing the job log to the Ops monitor.') }
  else { Warn 'No abend on this compiler setting: the defect shows as a wrong balance instead. Treating it as the incident anyway.' }
  if (-not (DS-Exists "$uid.MAPLE.OPS.REXX")) { if (-not (Setup-Ops $uid)) { return } }
  Put-JobLog @($prod) $uid
  $m = Submit-Wait 'OPSMOND' "$uid.MAPLE.OPS.JCL(OPSMOND)"
  if ($m) { Show-Tso (Get-Spool $m) }
  $f = Get-Alerts $uid
  if ($f) { Build-Report $f 'z/OS, release lab production run' }
  $incDraft = Join-Path $Reports 'INC-drafts.md'
  if (Test-Path $incDraft) { New-Dir (Join-Path $rl 'change'); Copy-Item $incDraft (Join-Path $rl 'change\INC-detected-by-MSGMON.md') -Force }
  $inc = SN-Post $sn 'incident' @{ short_description = ('MPSTREAM STEP030 failed in PROD: ' + $prod.retcode); urgency = '2'; impact = '2'
    description = ('Detected by MSGMON (Maple Ops Automation Lab). Job ' + $prod.jobid + '. Nightly interest accrual report not produced.'); caused_by = $(if ($chg1) { $chg1.sys_id } else { '' }) }
  Head 'Release lab Day 5: emergency change CHG0002 (v1.1 numeric edits)'
  $mark = $script:RLLog.Count
  $chg2 = SN-Post $sn 'change_request' @{ type = 'emergency'; short_description = 'CHG0002 Emergency: MPINTCLC v1.1 numeric edits (fix for the S0C7 incident)'
    description = 'Activate PERFORM 2200-NUMERIC-EDITS (lines tagged CHG0002). Non-numeric balances are rejected with a reason instead of abending.'
    implementation_plan = 'MPCOMPL, MPPROMOT DEV->QA, MPSTREAM QA/PROD, MPPATCMP PROD V11PROD (RC 0), MPPROMOT QA->PROD, MPRESTRT PROD/PROD, MPPATCMP (RC 0).'
    backout_plan = 'MPBACKOT TO=PROD restores v1.0 (brings back the abend; only if v1.1 itself fails).' }
  if ($inc -and $chg2) { try { Invoke-RestMethod -Uri ($sn.Base + '/incident/' + $inc.sys_id) -Headers $sn.Head -Method Patch -ContentType 'application/json' -Body (@{ rfc = $chg2.sys_id } | ConvertTo-Json) | Out-Null } catch { } }
  $cbl = Join-Path $rl 'src\cobol\MPINTCLC.cbl'
  $r = ZJ zos-files upload file-to-data-set $cbl "$uid.MPL.DEV.SRC(MPINTCLC)"
  if ($r -and $r.success) { Ok 'Original v1.1 source re-uploaded to DEV' } else { Bad 'v1.1 upload failed'; return }
  $d = RL-Run $rl 'MPCOMPL' $null @('CC 0000', 'CC 0004') 'Compile v1.1 in DEV'; if (-not $d -or -not $d.ok) { return }
  RL-Run $rl 'MPPROMOT' ([ordered]@{ FROM = 'DEV'; TO = 'QA' }) @('CC 0000', 'CC 0004') 'Promote DEV -> QA' | Out-Null
  RL-Run $rl 'MPSTREAM' ([ordered]@{ ENV = 'QA'; DATA = 'PROD' }) @('CC 000*') 'QA run on a copy of the failing PROD input' | Out-Null
  $d = RL-Run $rl 'MPPATCMP' ([ordered]@{ ACTUAL = 'PROD'; EXPECT = 'V11PROD' }) @('CC 0000') 'Emergency PAT vs V11PROD'; if (-not $d -or -not $d.ok) { Bad 'Emergency PAT failed: not deploying.'; return }
  RL-Run $rl 'MPPROMOT' ([ordered]@{ FROM = 'QA'; TO = 'PROD' }) @('CC 0000', 'CC 0004') 'Promote QA -> PROD (CHG0002)' | Out-Null
  if ($abended) {
    # The QA run on PROD data above created MPL.PROD.RPT / .REJ. A restart skips the
    # STEP010 cleanup, so clear them first or STEP030 fails on duplicate names.
    New-Dir (Join-Path $Work 'jcl')
    $cl = Join-Path $Work 'jcl\MPCLNRPT.jcl'
    $jt = @('//MPCLNRPT JOB 1,NOTIFY=&SYSUID',
      '//* BEFORE A RESTART AT STEP030: DELETE THE OUTPUTS STEP030 CREATES',
      '//DEL      EXEC PGM=IEFBR14',
      '//RPT      DD DSN=&SYSUID..MPL.PROD.RPT,DISP=(MOD,DELETE),',
      '//            SPACE=(TRK,(1,1))',
      '//REJ      DD DSN=&SYSUID..MPL.PROD.REJ,DISP=(MOD,DELETE),',
      '//            SPACE=(TRK,(1,1))')
    [IO.File]::WriteAllText($cl, (($jt -join "`n") + "`n"))
    $c = Submit-Wait 'MPCLNRPT' $cl -Local
    if ($c) { Get-Spool $c | Out-Null }
  }
  if ($abended) { $re = RL-Run $rl 'MPRESTRT' ([ordered]@{ ENV = 'PROD'; DATA = 'PROD' }) @('CC 0004') 'Restart PROD from STEP030 (2 rejects expected)' }
  else { $re = RL-Run $rl 'MPSTREAM' ([ordered]@{ ENV = 'PROD'; DATA = 'PROD' }) @('CC 0004') 'Rerun PROD stream (2 rejects expected)' }
  RL-Run $rl 'MPPATCMP' ([ordered]@{ ACTUAL = 'PROD'; EXPECT = 'V11PROD' }) @('CC 0000') 'PROD PAT vs V11PROD = resolved' | Out-Null
  if ($re) {
    Put-JobLog @($re) $uid
    $m = Submit-Wait 'OPSMOND' "$uid.MAPLE.OPS.JCL(OPSMOND)"
    if ($m) { Say '  Monitor on the restarted job (expect RC=4 NOTIFY: rejects are business as usual):' White; Show-Tso (Get-Spool $m) }
  }
  SN-Note $sn 'change_request' $chg2 ("Implementation log (automated run):`n" + (RL-Notes $mark))
  SN-Note $sn 'incident' $inc 'Resolved by emergency change CHG0002 (v1.1). Restarted from STEP030, PAT vs V11PROD RC 0. Bad record rejected: BALANCE NOT NUMERIC.'
  Head 'Release lab Day 5: backout drill in QA'
  RL-Run $rl 'MPBACKOT' ([ordered]@{ TO = 'QA' }) @('CC 0000', 'CC 0004') 'Back out QA to v1.0' | Out-Null
  RL-Run $rl 'MPSTREAM' ([ordered]@{ ENV = 'QA'; DATA = 'TEST' }) @('CC 000*') 'QA run after backout' | Out-Null
  RL-Run $rl 'MPPATCMP' ([ordered]@{ ACTUAL = 'TEST'; EXPECT = 'V10TEST' }) @('CC 0000') 'PAT proves the restore' | Out-Null
  RL-Run $rl 'MPPROMOT' ([ordered]@{ FROM = 'DEV'; TO = 'QA' }) @('CC 0000', 'CC 0004') 'Re-promote v1.1 to QA' | Out-Null
  # evidence summary
  $ev = Join-Path $rl 'evidence\auto-run'
  New-Dir $ev
  $sb = New-Object System.Text.StringBuilder
  [void]$sb.AppendLine('# Automated run of the Maple Host Release Lab, ' + (Get-Date -Format 'yyyy-MM-dd HH:mm'))
  [void]$sb.AppendLine('')
  [void]$sb.AppendLine('Every job ran on IBM Z Xplore under user ' + $uid + '. Full job logs are in this folder.')
  [void]$sb.AppendLine('')
  [void]$sb.AppendLine('| Time | Step | Job | Job ID | Result | As expected |')
  [void]$sb.AppendLine('|---|---|---|---|---|---|')
  foreach ($x in $script:RLLog) { [void]$sb.AppendLine('| ' + $x.Time + ' | ' + $x.Step + ' | ' + $x.Job + ' | ' + $x.JobId + ' | ' + $x.Result + ' | ' + $(if ($x.Pass) { 'yes' } else { 'NO' }) + ' |') }
  if ($sn) { [void]$sb.AppendLine(''); [void]$sb.AppendLine('ServiceNow: ' + $(if ($chg1) { $chg1.number } else { '-' }) + ' (normal), ' + $(if ($inc) { $inc.number } else { '-' }) + ' (incident), ' + $(if ($chg2) { $chg2.number } else { '-' }) + ' (emergency). Approvals, state changes and closure are done by hand.') }
  [void]$sb.AppendLine('')
  [void]$sb.AppendLine('Still to do by hand: ISPF HEX ON screenshot of the bad record, ServiceNow approvals (as a different user) and closure, the PIR, Wireshark/Test-NetConnection evidence.')
  $sum = Join-Path $ev 'AUTO-RUN-SUMMARY.md'
  [IO.File]::WriteAllText($sum, $sb.ToString())
  $bad = @($script:RLLog | Where-Object { -not $_.Pass }).Count
  Head 'Release lab automated run finished'
  if ($bad) { Warn "$bad step(s) did not end as expected. Open evidence\auto-run in the release lab and send the job log to Claude." }
  else { Ok 'Every step ended as expected' }
  Ok ('Summary: ' + $sum)
}

# ------------------------------------------------------- 5. GitHub
function Ensure-Tool($cmd, $id, $name) {
  if (Has $cmd) { return $true }
  if (-not (Has 'winget')) { Bad "$name is missing. Install it, then run this again."; return $false }
  if (-not (YesNo "Install $name with winget now?")) { return $false }
  winget install --id $id -e --source winget --accept-package-agreements --accept-source-agreements
  Refresh-Path
  if (Has $cmd) { return $true }
  Bad "$name installed. Close this window and run the file again."
  return $false
}
function Publish {
  Ensure-Repo
  Head 'Publishing to GitHub'
  if (-not (Ensure-Tool 'git' 'Git.Git' 'Git')) { return }
  if (-not (Ensure-Tool 'gh' 'GitHub.cli' 'GitHub CLI')) { return }
  gh auth status 2>$null | Out-Null
  if ($LASTEXITCODE -ne 0) {
    Say '  A browser will open. Enter the code shown here to sign in to GitHub.' White
    gh auth login --web -h github.com --git-protocol https
    if ($LASTEXITCODE -ne 0) { Bad 'GitHub sign-in did not finish'; return }
  }
  $login = (gh api user --jq .login).Trim()
  if (-not (git config --global user.name)) { git config --global user.name (Ask 'Your name for commits' 'Jamie Rowe') }
  if (-not (git config --global user.email)) {
    $id = (gh api user --jq .id).Trim()
    git config --global user.email "$id+$login@users.noreply.github.com"
    Ok 'Commit email set to your private GitHub noreply address'
  }
  Push-Location $Repo
  try {
    if (-not (Test-Path '.git')) { git init -b main | Out-Null }
    git add -A
    git diff --cached --quiet
    if ($LASTEXITCODE -ne 0) {
      $msg = Ask 'Commit message' ('Maple Ops Automation Lab update ' + (Get-Date -Format 'yyyy-MM-dd'))
      git commit -m $msg | Out-Null
      Ok 'Committed'
    } else { Ok 'Nothing new to commit' }
    git remote get-url origin 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
      gh repo create maple-ops-automation-lab --public --source . --remote origin --push `
        --description 'REXX mainframe automation on z/OS: table-driven message monitor, auto-recovery, GDPS-style DR runbook'
    } else { git push -u origin main }
    if ($LASTEXITCODE -eq 0) {
      Ok "https://github.com/$login/maple-ops-automation-lab"
      Start-Process "https://github.com/$login/maple-ops-automation-lab/actions"
    } else { Bad 'Push failed. Read the message above.' }
  } finally { Pop-Location }
  $rl = Find-ReleaseLab
  if ($rl -and (Test-Path (Join-Path $rl 'PUBLISH-TO-GITHUB.cmd'))) {
    if (YesNo 'Also publish or update the Maple Host Release Lab repo?' 'Y') {
      Start-Process -FilePath (Join-Path $rl 'PUBLISH-TO-GITHUB.cmd') -WorkingDirectory $rl -Wait
    }
  }
}

# ------------------------------------------------------------ menu
function Open-Stuff {
  Ensure-Repo
  Start-Process (Join-Path $Repo 'LAB-GUIDE.md') -ErrorAction SilentlyContinue
  Start-Process explorer.exe $Repo
}
function Rebuild-Report {
  Ensure-Repo
  if (-not (Connect-Zowe)) { return }
  $f = Get-Alerts (Get-UserId)
  if ($f) { Build-Report $f 'z/OS' }
}
function Main {
  $script:Cfg = Load-Settings
  $Host.UI.RawUI.WindowTitle = 'Maple Labs runner v' + $Version
  while ($true) {
    Write-Host ''
    Write-Host '  MAPLE LABS RUNNER  v1.0' -ForegroundColor Cyan
    Write-Host '  Ops Automation Lab + Host Release Lab' -ForegroundColor DarkCyan
    Write-Host '  -----------------------------------------------'
    Write-Host '   1  Create / update the Ops Automation Lab repo'
    Write-Host '   2  Offline rehearsal on this PC'
    Write-Host '   3  Run the Ops lab on IBM Z Xplore (monitor + DR + report)'
    Write-Host '   4  Scan release-lab jobs (MPSTREAM S0C7) and draft the incident'
    Write-Host '   5  Publish to GitHub (both labs)'
    Write-Host '   6  Release lab Day 1 on Z Xplore (allocate, load, upload)'
    Write-Host '   R  Release lab Days 1-5, automatic (build, PAT, deploy, abend, fix, backout)'
    Write-Host '   7  Rebuild the report from ALERTS'
    Write-Host '   8  Open the lab guide and repo folder'
    Write-Host '   A  Do EVERYTHING automatically: both labs, report, GitHub'
    Write-Host '   Q  Quit'
    $c = (Read-Host '  Choose').Trim().ToUpper()
    switch ($c) {
      '1' { Write-Repo }
      '2' { Run-Offline }
      '3' { Run-Live }
      '4' { Release-Watch }
      '5' { Publish }
      '6' { Release-Day1 }
      'R' { Release-Full }
      '7' { Rebuild-Report }
      '8' { Open-Stuff }
      'A' {
        Write-Repo
        if (-not (Connect-Zowe)) { Warn 'Get your Z Xplore user ID first (VSC1 challenge), then choose A again.'; continue }
        $script:Auto = $true
        try {
          Run-Live
          if ($script:ZoweReady) { Release-Full }
          Publish
        } finally { $script:Auto = $false }
        Head 'All done'
        Ok 'Ops lab evidence: Documents\MapleLabs\maple-ops-automation-lab\evidence'
        Ok 'Release lab evidence: its evidence\auto-run folder'
      }
      'Q' { return }
      default { Warn 'Pick one of the options above' }
    }
  }
}

# ------------------------------------------- embedded repo files
# Every file of the repo, written out by option 1. Readable on purpose.
function Get-EmbeddedFiles {
  $f = [ordered]@{}
  $f['.gitattributes'] = @'
* text=auto
*.sh text eol=lf
*.rexx text eol=lf
*.jcl text eol=lf
*.txt text eol=lf
*.cmd text eol=crlf
*.ps1 text eol=crlf
'@
  $f['.gitignore'] = @'
build/
*.xlsx~
~$*
'@
  $f['LAB-GUIDE.md'] = @'
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
'@
  $f['README.md'] = @'
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

Double-click **`RUN-MAPLE-LABS.cmd`** on Windows. Option **A** does everything automatically: creates this repo, runs this lab on Z Xplore through Zowe CLI, runs the Maple Host Release Lab Days 1-5 (build, PAT, deploy, production abend, emergency fix, restart, backout drill), builds the report and publishes both repos to GitHub. The only thing it needs from you first is a Z Xplore user ID.

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
'@
  $f['STANDARDS.md'] = @'
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
'@
  $f['.github/workflows/ci.yml'] = @'
name: rexx-tests
on: [push, pull_request]
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Install Regina REXX
        run: sudo apt-get update && sudo apt-get install -y regina-rexx
      - name: Run offline regression tests
        run: bash tests/run-tests.sh
'@
  $f['evidence/README.md'] = @'
# Evidence

Screenshots and outputs from the real runs on IBM Z Xplore go here.
The runner saves job logs to `joblogs/`, reports to `reports/` and the DR files (`DRLOG.txt`, `SITECFG.txt`) here.

| Day | What to save |
|---|---|
| 1 | OPSALLOC output, ISPF 3.4 listing of MAPLE.OPS |
| 2 | OPSJOB1-5 outputs, OPSMOND / OPSMON SYSTSPRT, OPSFIX1, the rerun OPSJOB1 at CC 0000, ALERTS |
| 3 | DRYRUN, FAULT drill, refused EXECUTE, RESUME and RUNBACK outputs, SITECFG before and after |
| 4 | MPSTREAM alert lines and the INC draft |
| 5 | ops-report.xlsx / .html and the flow diagram |
'@
  $f['samples/JOBLOG.txt'] = @'
>>> JOB OPSJOB1 JOB04101
                    J E S 2  J O B  L O G  --  S Y S T E M  S 0 W 1
15.02.11 JOB04101 ---- WEDNESDAY, 18 NOV 2026 ----
15.02.11 JOB04101  IRR010I  USERID Z12345   IS ASSIGNED TO THIS JOB.
15.02.11 JOB04101  IEF212I OPSJOB1 STEP1 SYSUT1 - DATA SET NOT FOUND
15.02.11 JOB04101  IEF272I OPSJOB1 STEP1 - STEP WAS NOT EXECUTED.
15.02.11 JOB04101  $HASP395 OPSJOB1 ENDED - JCL ERROR
>>> JOB OPSJOB2 JOB04102
15.02.14 JOB04102  IRR010I  USERID Z12345   IS ASSIGNED TO THIS JOB.
IDC0002I IDCAMS PROCESSING COMPLETE. MAXIMUM CONDITION CODE WAS 8
IEF142I OPSJOB2 STEP1 - STEP WAS EXECUTED - COND CODE 0008
15.02.14 JOB04102  $HASP395 OPSJOB2 ENDED - RC=0008
>>> JOB OPSJOB3 JOB04103
15.02.16 JOB04103  CSV003I REQUESTED MODULE MAPLENOP NOT FOUND
15.02.16 JOB04103  IEA995I SYMPTOM DUMP OUTPUT  047
   SYSTEM COMPLETION CODE=806  REASON CODE=00000004
IEF450I OPSJOB3 STEP1 - ABEND=S806 U0000 REASON=00000004
15.02.16 JOB04103  $HASP395 OPSJOB3 ENDED - ABEND=S806
>>> JOB OPSJOB4 JOB04104
IEF142I OPSJOB4 STEP1 - STEP WAS EXECUTED - COND CODE 0000
IEF142I OPSJOB4 STEP2 - STEP WAS EXECUTED - COND CODE 0000
15.02.18 JOB04104  $HASP395 OPSJOB4 ENDED - RC=0000
>>> JOB OPSJOB5 JOB04105
IDC0002I IDCAMS PROCESSING COMPLETE. MAXIMUM CONDITION CODE WAS 4
IEF142I OPSJOB5 STEP1 - STEP WAS EXECUTED - COND CODE 0004
15.02.20 JOB04105  $HASP395 OPSJOB5 ENDED - RC=0004
>>> JOB MPSTREAM JOB04110
IEF142I MPSTREAM STEP010 - STEP WAS EXECUTED - COND CODE 0000
IEF142I MPSTREAM STEP020 - STEP WAS EXECUTED - COND CODE 0000
CEE3207S The system detected a data exception (System Completion Code=0C7).
IEF450I MPSTREAM STEP030 - ABEND=S0C7 U0000 REASON=00000007
IEF272I MPSTREAM STEP040 - STEP WAS NOT EXECUTED.
IEF272I MPSTREAM STEP045 - STEP WAS NOT EXECUTED.
15.03.02 JOB04110  $HASP395 MPSTREAM ENDED - ABEND=S0C7
>>> JOB OPSJOB1 JOB04130
15.10.01 JOB04130  IEFA107I OPSJOB1 STEP1 SYSUT1 - DATA SET Z12345.MAPLE.OPS.INPUT NOT FOUND
15.10.01 JOB04130  $HASP395 OPSJOB1 ENDED - JCL ERROR
'@
  $f['src/cntl/MSGTABLE.txt'] = @'
* MAPLE OPS AUTOMATION TABLE                                    v1.0
* One rule per line. For each log line the FIRST rule whose KEY is
* in the line and whose JOB pattern matches the job name wins.
* KEY  message ID, or a pseudo key worked out from IEF142I codes:
*      RC>4 (worst step CC above 4), RC=4, CLEAN (CC 0, no hits)
* JOB  *  or *SUFFIX  or PREFIX*  or an exact job name
* SEV  INFO WARN HIGH CRIT      ACTION  LOG NOTIFY ESCALATE RECOVER
* MAX  retry limit for RECOVER
* RECOVERY  JCL member to submit   RERUN  member to submit after
*      it, or - when the recovery job resubmits the failed job
*      itself (OPSFIX1 does, so the rerun can't start too early)
*
* IEF212I and IEFA107I both mean DATA SET NOT FOUND (older / newer z/OS)
* KEY      JOB       SEV   ACTION    MAX  RECOVERY  RERUN
IEF212I    OPSJOB1   HIGH  RECOVER   2    OPSFIX1   -
IEFA107I   OPSJOB1   HIGH  RECOVER   2    OPSFIX1   -
IEF212I    *         HIGH  ESCALATE  0    -         -
IEFA107I   *         HIGH  ESCALATE  0    -         -
IEF450I    *         CRIT  ESCALATE  0    -         -
CEE3207S   *         CRIT  ESCALATE  0    -         -
CSV003I    *         HIGH  ESCALATE  0    -         -
IEC141I    *         HIGH  ESCALATE  0    -         -
RC>4       *         HIGH  ESCALATE  0    -         -
RC=4       *         WARN  NOTIFY    0    -         -
CLEAN      *         INFO  LOG       0    -         -
'@
  $f['src/cntl/RUNBACK.txt'] = @'
* RUNBACK  Planned return SITEB -> SITEA                    v1.0
CHECK   ACTIVE=SITEB
CHECK   SITEA.STATUS=READY
CHECK   MIRROR.STATE=DUPLEX
MSG     Planned return to SITEA is starting
STOP    MAPLEONLINE AT SITEB
STOP    MAPLEBATCH AT SITEB
SWITCH  MIRROR TO SITEA
SET     ACTIVE=SITEA
START   MAPLEBATCH AT SITEA JOB=OPSDRJ
START   MAPLEONLINE AT SITEA
VERIFY  MAPLEBATCH.SITEA=UP
VERIFY  MAPLEONLINE.SITEA=UP
VERIFY  MIRROR.PRIMARY=SITEA
MSG     Return complete, SITEA is the active site again
'@
  $f['src/cntl/RUNBOOK.txt'] = @'
* RUNBOOK  Planned site switch SITEA -> SITEB              v1.0
* Modelled on a GDPS planned-action script: checks first, then
* stop work, switch the disk mirror, move the active site, restart.
CHECK   ACTIVE=SITEA
CHECK   SITEB.STATUS=READY
CHECK   MIRROR.STATE=DUPLEX
MSG     Planned site switch SITEA to SITEB is starting
STOP    MAPLEONLINE AT SITEA
STOP    MAPLEBATCH AT SITEA
SWITCH  MIRROR TO SITEB
SET     ACTIVE=SITEB
START   MAPLEBATCH AT SITEB JOB=OPSDRJ
START   MAPLEONLINE AT SITEB
VERIFY  MAPLEBATCH.SITEB=UP
VERIFY  MAPLEONLINE.SITEB=UP
VERIFY  MIRROR.PRIMARY=SITEB
MSG     Site switch complete, SITEB is now the active site
'@
  $f['src/jcl/OPSALLOC.jcl'] = @'
//OPSALLOC JOB 1,NOTIFY=&SYSUID,MSGLEVEL=(1,1)
//*-------------------------------------------------------------------
//* MAPLE OPS AUTOMATION LAB - ONE-TIME ALLOCATION (DAY 1)
//* CREATES THE REXX, JCL AND CNTL LIBRARIES AND THE WORK DATA SETS.
//* RUN ONCE.  A RERUN FAILS WITH DUPLICATE NAMES - THAT IS EXPECTED.
//*-------------------------------------------------------------------
//ALLOC    EXEC PGM=IEFBR14
//REXX     DD DSN=&SYSUID..MAPLE.OPS.REXX,DISP=(NEW,CATLG),
//            SPACE=(TRK,(5,5,10)),DSNTYPE=LIBRARY,DSORG=PO,
//            RECFM=FB,LRECL=80
//JCL      DD DSN=&SYSUID..MAPLE.OPS.JCL,DISP=(NEW,CATLG),
//            SPACE=(TRK,(5,5,10)),DSNTYPE=LIBRARY,DSORG=PO,
//            RECFM=FB,LRECL=80
//CNTL     DD DSN=&SYSUID..MAPLE.OPS.CNTL,DISP=(NEW,CATLG),
//            SPACE=(TRK,(5,5,10)),DSNTYPE=LIBRARY,DSORG=PO,
//            RECFM=FB,LRECL=80
//JOBLOG   DD DSN=&SYSUID..MAPLE.OPS.JOBLOG,DISP=(NEW,CATLG),
//            SPACE=(TRK,(15,15)),RECFM=FB,LRECL=255
//ALERTS   DD DSN=&SYSUID..MAPLE.OPS.ALERTS,DISP=(NEW,CATLG),
//            SPACE=(TRK,(5,5)),RECFM=FB,LRECL=255
//DRLOG    DD DSN=&SYSUID..MAPLE.OPS.DRLOG,DISP=(NEW,CATLG),
//            SPACE=(TRK,(5,5)),RECFM=FB,LRECL=255
//STATE    DD DSN=&SYSUID..MAPLE.OPS.STATE,DISP=(NEW,CATLG),
//            SPACE=(TRK,(1,1)),RECFM=FB,LRECL=80
//SITECFG  DD DSN=&SYSUID..MAPLE.OPS.SITECFG,DISP=(NEW,CATLG),
//            SPACE=(TRK,(1,1)),RECFM=FB,LRECL=80
'@
  $f['src/jcl/OPSDRBAK.jcl'] = @'
//OPSDRBAK JOB 1,NOTIFY=&SYSUID,MSGLEVEL=(1,1)
//*-------------------------------------------------------------------
//* DR RUNBOOK - RETURN FROM SITEB TO SITEA (RUNBACK MEMBER).
//* RC 0 = COMPLETE, 4 = NOTHING TO DO, 8 = HALTED, 12 = SETUP ERROR.
//*-------------------------------------------------------------------
//RUN      EXEC PGM=IKJEFT1B,DYNAMNBR=30
//SYSEXEC  DD DISP=SHR,DSN=&SYSUID..MAPLE.OPS.REXX
//SYSTSPRT DD SYSOUT=*
//SYSTSIN  DD *
 %DRSWITCH * EXECUTE RUNBOOK=RUNBACK
/*
'@
  $f['src/jcl/OPSDRDRY.jcl'] = @'
//OPSDRDRY JOB 1,NOTIFY=&SYSUID,MSGLEVEL=(1,1)
//*-------------------------------------------------------------------
//* DR RUNBOOK - DRY RUN OF THE SITEA TO SITEB SWITCH. CHANGES NOTHING.
//* RC 0 = COMPLETE, 4 = NOTHING TO DO, 8 = HALTED, 12 = SETUP ERROR.
//*-------------------------------------------------------------------
//RUN      EXEC PGM=IKJEFT1B,DYNAMNBR=30
//SYSEXEC  DD DISP=SHR,DSN=&SYSUID..MAPLE.OPS.REXX
//SYSTSPRT DD SYSOUT=*
//SYSTSIN  DD *
 %DRSWITCH * DRYRUN
/*
'@
  $f['src/jcl/OPSDREXE.jcl'] = @'
//OPSDREXE JOB 1,NOTIFY=&SYSUID,MSGLEVEL=(1,1)
//*-------------------------------------------------------------------
//* DR RUNBOOK - RUN THE SITEA TO SITEB SWITCH FROM THE START.
//* RC 0 = COMPLETE, 4 = NOTHING TO DO, 8 = HALTED, 12 = SETUP ERROR.
//*-------------------------------------------------------------------
//RUN      EXEC PGM=IKJEFT1B,DYNAMNBR=30
//SYSEXEC  DD DISP=SHR,DSN=&SYSUID..MAPLE.OPS.REXX
//SYSTSPRT DD SYSOUT=*
//SYSTSIN  DD *
 %DRSWITCH * EXECUTE
/*
'@
  $f['src/jcl/OPSDRFLT.jcl'] = @'
//OPSDRFLT JOB 1,NOTIFY=&SYSUID,MSGLEVEL=(1,1)
//*-------------------------------------------------------------------
//* DR TEST DRILL - RUN THE SWITCH WITH A FAULT INJECTED AT STEP 7.
//* RC 0 = COMPLETE, 4 = NOTHING TO DO, 8 = HALTED, 12 = SETUP ERROR.
//*-------------------------------------------------------------------
//RUN      EXEC PGM=IKJEFT1B,DYNAMNBR=30
//SYSEXEC  DD DISP=SHR,DSN=&SYSUID..MAPLE.OPS.REXX
//SYSTSPRT DD SYSOUT=*
//SYSTSIN  DD *
 %DRSWITCH * EXECUTE FAULT=7
/*
'@
  $f['src/jcl/OPSDRJ.jcl'] = @'
//OPSDRJ   JOB 1,NOTIFY=&SYSUID,MSGLEVEL=(1,1)
//*-------------------------------------------------------------------
//* WORKLOAD START JOB - SUBMITTED BY THE DR RUNBOOK WHEN IT STARTS
//* MAPLEBATCH AT THE NEW SITE (STANDS IN FOR A REAL STARTUP).
//*-------------------------------------------------------------------
//STEP1    EXEC PGM=IEFBR14
'@
  $f['src/jcl/OPSDRRES.jcl'] = @'
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
'@
  $f['src/jcl/OPSDRRST.jcl'] = @'
//OPSDRRST JOB 1,NOTIFY=&SYSUID,MSGLEVEL=(1,1)
//*-------------------------------------------------------------------
//* DR RUNBOOK - RESET THE SIMULATED TWO-SITE CONFIGURATION.
//* RC 0 = COMPLETE, 4 = NOTHING TO DO, 8 = HALTED, 12 = SETUP ERROR.
//*-------------------------------------------------------------------
//RUN      EXEC PGM=IKJEFT1B,DYNAMNBR=30
//SYSEXEC  DD DISP=SHR,DSN=&SYSUID..MAPLE.OPS.REXX
//SYSTSPRT DD SYSOUT=*
//SYSTSIN  DD *
 %DRSWITCH * RESET
/*
'@
  $f['src/jcl/OPSFIX1.jcl'] = @'
//OPSFIX1  JOB 1,NOTIFY=&SYSUID,MSGLEVEL=(1,1)
//*-------------------------------------------------------------------
//* RECOVERY PROCEDURE FOR OPSJOB1 (SUBMITTED BY THE MONITOR).
//* STEP1 CREATES THE MISSING INPUT.  STEP2 RESUBMITS OPSJOB1 THROUGH
//* THE INTERNAL READER ONLY IF STEP1 WORKED, SO THE RERUN CAN NEVER
//* START BEFORE THE FIX IS IN PLACE.
//*-------------------------------------------------------------------
//STEP1    EXEC PGM=IEBGENER
//SYSPRINT DD SYSOUT=*
//SYSIN    DD DUMMY
//SYSUT1   DD *
MAPLE OPS INPUT RECORD 0001 - CREATED BY RECOVERY PROCEDURE OPSFIX1
/*
//SYSUT2   DD DSN=&SYSUID..MAPLE.OPS.INPUT,DISP=(NEW,CATLG,DELETE),
//            SPACE=(TRK,(1,1)),RECFM=FB,LRECL=80
//         IF (STEP1.RC = 0) THEN
//STEP2    EXEC PGM=IEBGENER
//SYSPRINT DD SYSOUT=*
//SYSIN    DD DUMMY
//SYSUT1   DD DISP=SHR,DSN=&SYSUID..MAPLE.OPS.JCL(OPSJOB1)
//SYSUT2   DD SYSOUT=(A,INTRDR)
//         ENDIF
'@
  $f['src/jcl/OPSJOB1.jcl'] = @'
//OPSJOB1  JOB 1,NOTIFY=&SYSUID,MSGLEVEL=(1,1)
//*-------------------------------------------------------------------
//* TEST JOB 1 - READS A DATA SET THAT DOES NOT EXIST YET, SO THE
//* FIRST RUN ENDS IN A JCL ERROR.  THE MONITOR'S RECOVER RULE RUNS
//* OPSFIX1, WHICH CREATES THE DATA SET AND RESUBMITS THIS JOB.
//*-------------------------------------------------------------------
//STEP1    EXEC PGM=IEBGENER
//SYSPRINT DD SYSOUT=*
//SYSIN    DD DUMMY
//SYSUT1   DD DISP=SHR,DSN=&SYSUID..MAPLE.OPS.INPUT
//SYSUT2   DD SYSOUT=*
'@
  $f['src/jcl/OPSJOB2.jcl'] = @'
//OPSJOB2  JOB 1,NOTIFY=&SYSUID,MSGLEVEL=(1,1)
//*-------------------------------------------------------------------
//* TEST JOB 2 - ENDS WITH CONDITION CODE 8 (A BUSINESS FAILURE THAT
//* A RETRY WILL NOT FIX).  EXPECTED MONITOR ACTION: ESCALATE.
//*-------------------------------------------------------------------
//STEP1    EXEC PGM=IDCAMS
//SYSPRINT DD SYSOUT=*
//SYSIN    DD *
  SET MAXCC=8
/*
'@
  $f['src/jcl/OPSJOB3.jcl'] = @'
//OPSJOB3  JOB 1,NOTIFY=&SYSUID,MSGLEVEL=(1,1)
//*-------------------------------------------------------------------
//* TEST JOB 3 - CALLS A PROGRAM THAT DOES NOT EXIST, SO THE STEP
//* ABENDS (SYSTEM COMPLETION CODE 806).  EXPECTED ACTION: ESCALATE.
//*-------------------------------------------------------------------
//STEP1    EXEC PGM=MAPLENOP
'@
  $f['src/jcl/OPSJOB4.jcl'] = @'
//OPSJOB4  JOB 1,NOTIFY=&SYSUID,MSGLEVEL=(1,1)
//*-------------------------------------------------------------------
//* TEST JOB 4 - TWO STEPS THAT BOTH END CC 0000.
//* EXPECTED MONITOR ACTION: LOG AS CLEAN.
//*-------------------------------------------------------------------
//STEP1    EXEC PGM=IEFBR14
//STEP2    EXEC PGM=IEFBR14
'@
  $f['src/jcl/OPSJOB5.jcl'] = @'
//OPSJOB5  JOB 1,NOTIFY=&SYSUID,MSGLEVEL=(1,1)
//*-------------------------------------------------------------------
//* TEST JOB 5 - ENDS WITH CONDITION CODE 4 (A WARNING).
//* EXPECTED MONITOR ACTION: NOTIFY OPERATIONS, NO INCIDENT.
//*-------------------------------------------------------------------
//STEP1    EXEC PGM=IDCAMS
//SYSPRINT DD SYSOUT=*
//SYSIN    DD *
  SET MAXCC=4
/*
'@
  $f['src/jcl/OPSMON.jcl'] = @'
//OPSMON   JOB 1,NOTIFY=&SYSUID,MSGLEVEL=(1,1)
//*-------------------------------------------------------------------
//* MESSAGE MONITOR - LIVE.  SAME AS OPSMOND BUT RECOVER RULES
//* REALLY SUBMIT THEIR RECOVERY JOBS (RETRY LIMIT IN MAPLE.OPS.STATE).
//*-------------------------------------------------------------------
//RUN      EXEC PGM=IKJEFT1B,DYNAMNBR=30
//SYSEXEC  DD DISP=SHR,DSN=&SYSUID..MAPLE.OPS.REXX
//SYSTSPRT DD SYSOUT=*
//SYSTSIN  DD *
 %MSGMON * LIVE
/*
'@
  $f['src/jcl/OPSMOND.jcl'] = @'
//OPSMOND  JOB 1,NOTIFY=&SYSUID,MSGLEVEL=(1,1)
//*-------------------------------------------------------------------
//* MESSAGE MONITOR - DRY RUN.  DECIDES WHAT IT WOULD DO FOR EVERY
//* JOB IN MAPLE.OPS.JOBLOG BUT SUBMITS NOTHING.  RC 8 = ESCALATIONS.
//*-------------------------------------------------------------------
//RUN      EXEC PGM=IKJEFT1B,DYNAMNBR=30
//SYSEXEC  DD DISP=SHR,DSN=&SYSUID..MAPLE.OPS.REXX
//SYSTSPRT DD SYSOUT=*
//SYSTSIN  DD *
 %MSGMON * DRYRUN
/*
'@
  $f['src/jcl/OPSRESET.jcl'] = @'
//OPSRESET JOB 1,NOTIFY=&SYSUID,MSGLEVEL=(1,1)
//*-------------------------------------------------------------------
//* RESET THE MONITOR DEMO SO IT CAN BE RUN AGAIN: DELETES THE INPUT
//* DATA SET THAT OPSFIX1 CREATES.  ENDS CC 0000 EVEN IF IT IS GONE.
//*-------------------------------------------------------------------
//STEP1    EXEC PGM=IEFBR14
//DELIN    DD DSN=&SYSUID..MAPLE.OPS.INPUT,DISP=(MOD,DELETE),
//            SPACE=(TRK,(1,1))
'@
  $f['src/rexx/DRSWITCH.rexx'] = @'
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
'@
  $f['src/rexx/MSGMON.rexx'] = @'
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
'@
  $f['tests/run-tests.sh'] = @'
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
'@
  return $f
}

Main
