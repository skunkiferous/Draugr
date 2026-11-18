# daemon.ps1: the life cycle of AppSandbox, as one command.
#
# ==> bin/dr-forge daemon RUNS IT. You can run it yourself, but rarely. <==
#
# WHY IT EXISTS. Each dr-layer verb that rewrites vms.cfg (adopt, freeze, thaw,
# drop, new) refuses while the daemon runs. The daemon has no window, so nobody
# can follow "close AppSandbox". Before, layer.ps1 printed six lines to paste
# into an elevated PowerShell, and a seventh to start it again. The user asked
# for one command.
#
# ONLY `start` NEEDS ELEVATION, and the old instructions were wrong about that.
# The README of the headless API says clearly that the gate is on the RUN of the
# daemon, not on a call to it. HCS and the http.sys bind both need it. A
# request has the bearer token and nothing else. A TEST from an ordinary shell
# showed this: POST /vms/<n>/stop worked. Thus the shutdowns need no elevation,
# and only the --headless restart does. Start-Process -Verb RunAs shows exactly
# one question for it.
#
# WE CANNOT CHOOSE THE ORDER. POST /shutdown is refused with 409 while a VM
# runs, unless {"force":true}, and that TERMINATES the guests. A terminated
# guest is a dirty disk, and these commands exist to freeze disks. Thus this
# script does not offer force. The VMs shut down gracefully, the script waits
# for each one, and then the daemon stops. See headless-api\asb.py,
# shutdown_daemon().
#
#   powershell -ExecutionPolicy Bypass -File .\daemon.ps1 -Mode status
#   powershell -ExecutionPolicy Bypass -File .\daemon.ps1 -Mode stop
#   powershell -ExecutionPolicy Bypass -File .\daemon.ps1 -Mode start
#
# EXIT CODES, because a front end must know a refusal from a failure:
#   0   done. For `status`, the daemon runs
#   2   the arguments are wrong
#   3   only for `status`: the daemon is down. Not a failure, a fact
#   4   only for `status`: the daemon answers, and did not list its VMs. Thus
#       this cannot say which run, and an empty list would be a guess
#   20  nothing was confirmed down, so the daemon did not change: a VM that did
#       not stop, or a list of VMs that could not be read
#   21  the daemon did not stop
#   22  the script did not find AppSandbox.exe to start it
#   24  elevation was refused
param(
    [string]$Mode = 'status',
    [int]   $TimeoutSec = 180
)

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'

function Say([string]$m)  { Write-Host $m }
function Note([string]$m) { Write-Host "  $m" }
function Warn([string]$m) { Write-Host "  $m" -ForegroundColor Yellow }
function Fail([int]$code, [string]$m) { Write-Host "  $m" -ForegroundColor Red; exit $code }

$validModes = @('status', 'stop', 'start', 'restart')
if ($validModes -notcontains $Mode) {
    Fail 2 "unknown -Mode '$Mode'. Use one of: $($validModes -join ', ')"
}

$asbDir   = Join-Path $env:ProgramData 'AppSandbox'
$hostJson = Join-Path $asbDir 'host.json'
# WHERE THE SCRIPT LAST SAW THE EXE. `start` runs at a time with no process to
# ask. Thus the status and stop paths of this script record the path while the
# daemon IS up, and `start` reads it later. A list of probable directories is a
# guess. This is an observation.
$exeNote  = Join-Path $asbDir 'draugr-daemon-path.txt'

# --- is it there, and what does it say? ---------------------------------------------------
# By EFFECT, never by the existence of the file. A host.json with nothing behind
# it means that the last daemon DIED, and did not exit. The file alone reports a
# healthy daemon.
function Get-Daemon {
    if (-not (Test-Path $hostJson)) { return $null }
    try {
        $h = Get-Content $hostJson -Raw | ConvertFrom-Json
        $hdr = @{ Authorization = "Bearer $($h.token)" }
        $v = Invoke-RestMethod -Uri "$($h.endpoint)/v1/version" -TimeoutSec 5 -Headers $hdr
        return @{ Endpoint = $h.endpoint; Header = $hdr; Version = "$($v.product) $($v.version)" }
    } catch { return $null }
}

# $null means "I could not ask". THE CALLERS ARE WHAT MAKES THAT TRUE, and this
# function cannot do it alone: PowerShell unrolls an array on the way out of a
# function, so `return @()` and `return $null` arrive at `$v = Get-Vms $d` as
# exactly the same $null. A mutation run proved it - putting `return @()` back
# changed no behaviour at all. The defect was never the value here; it was that
# nobody tested it.
#
# Both callers read the failure as "nothing runs": the status line said "no VM
# runs, so the daemon can stop directly", and the wait below treated a VM
# missing from a failed listing as one that had shut down - after which this
# script asks the daemon to stop while a guest is still writing to its disk.
# Each caller now has its own test for $null, and each of those is mutated in
# tmp/run-mut-a6.sh.
function Get-Vms($d) {
    try { return @((Invoke-RestMethod -Uri "$($d.Endpoint)/v1/vms" -Headers $d.Header -TimeoutSec 15).vms) }
    catch { return $null }
}

# The image path of the daemon, from the process that runs now. For a process
# that this account cannot open, .Path is empty. That is the normal case,
# because the daemon is elevated. Thus an empty answer is not an error, and the
# default install path is the fallback.
function Save-ExePath {
    $p = @(Get-Process -Name 'AppSandbox' -ErrorAction SilentlyContinue)
    if (-not $p) { return }
    $path = $p[0].Path
    if ($path -and (Test-Path $path)) {
        try { Set-Content -Path $exeNote -Value $path -Encoding ASCII -ErrorAction Stop } catch { }
    }
}

function Find-Exe {
    foreach ($c in @($(if (Test-Path $exeNote) { (Get-Content $exeNote -Raw).Trim() } else { '' }),
                     'C:\AppSandbox\AppSandbox.exe')) {
        if ($c -and (Test-Path $c)) { return $c }
    }
    return ''
}

# ============================================================================= status
if ($Mode -eq 'status') {
    $d = Get-Daemon
    if (-not $d) {
        Say 'AppSandbox is DOWN.'
        if (Test-Path $hostJson) {
            Note 'host.json is there, and nothing answers. Thus the last daemon died, and did not exit.'
        }
        $exe = Find-Exe
        if ($exe) { Note "start it:  dr-forge daemon start   ($exe)" }
        else { Warn 'also, the script cannot find AppSandbox.exe, so it cannot start it.' }
        exit 3
    }
    Save-ExePath
    Say "AppSandbox is UP: $($d.Version) on $($d.Endpoint)"
    $vms = Get-Vms $d
    if ($null -eq $vms) {
        Warn 'the daemon answers, but it did not list its VMs. Thus this cannot say which run.'
        exit 4
    }
    $running = @($vms | Where-Object { $_.running } | ForEach-Object { $_.name })
    if ($running.Count) {
        Note "running: $($running -join ', ')"
        Note 'these shut down first. The API refuses a daemon shutdown while a VM runs'
    } else {
        Note 'no VM runs, so the daemon can stop directly'
    }
    Note "registered: $(($vms | ForEach-Object { $_.name }) -join ', ')"
    exit 0
}

# ============================================================================= stop
if ($Mode -eq 'stop' -or $Mode -eq 'restart') {
    $d = Get-Daemon
    if (-not $d) {
        Say 'AppSandbox is already down.'
    } else {
        Save-ExePath
        Say "stopping AppSandbox: $($d.Version)"
        $all = Get-Vms $d
        if ($null -eq $all) {
            # 20, the same code as a VM that did not stop: it is the refusal
            # that happens BEFORE anything changed, which is what a front end
            # branches on.
            Fail 20 ('the daemon answers, but it did not list its VMs. Nothing was stopped: a ' +
                     'list this script could not read is not an empty one, and a daemon stopped ' +
                     'under a running guest leaves a dirty disk.')
        }
        $running = @($all | Where-Object { $_.running } | ForEach-Object { $_.name })

        # GRACEFULLY, ONE AT A TIME, AND THE SCRIPT WAITS FOR EACH. /shutdown is
        # the ACPI power-off. /stop is the plug. A guest that loses power under
        # its own file system is a dirty disk. This script serves the verbs that
        # freeze disks.
        foreach ($v in $running) {
            Note "shutting down '$v' gracefully..."
            try {
                $null = Invoke-RestMethod -Method Post -Uri "$($d.Endpoint)/v1/vms/$v/shutdown" `
                            -Headers $d.Header -Body '{}' -ContentType 'application/json' -TimeoutSec 30
            } catch {
                Warn "  the shutdown call for '$v' failed: $($_.Exception.Message)"
            }
            $sw = [Diagnostics.Stopwatch]::StartNew()
            $down = $false
            while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
                # A listing this script could not read says nothing about this
                # guest, so the wait goes on. Before, `-not $st` covered both
                # "it is no longer listed" and "there was no list", and the
                # second one ended the wait with $down = $true.
                $now = Get-Vms $d
                if ($null -ne $now) {
                    $st = @($now | Where-Object { $_.name -eq $v })
                    if (-not $st -or -not $st[0].running) { $down = $true; break }
                }
                Start-Sleep -Seconds 3
            }
            if (-not $down) {
                Fail 20 ("'$v' still ran after $TimeoutSec s, so the daemon did not change. " +
                         'Nothing changed. Force terminates the guest, and that leaves a dirty ' +
                         'disk, so this script does not offer it. Stop it from inside, or ' +
                         'use dr-forge down for that one VM.')
            }
            Note "  '$v' is down after $([int]$sw.Elapsed.TotalSeconds)s"
        }

        try {
            $null = Invoke-RestMethod -Method Post -Uri "$($d.Endpoint)/v1/shutdown" `
                        -Headers $d.Header -Body '{}' -ContentType 'application/json' -TimeoutSec 30
        } catch {
            # A daemon that stops during the request cannot answer it. Thus a
            # broken connection here is the usual form of success. Only the
            # EFFECT below decides.
            Note "the shutdown request did not return correctly ($($_.Exception.Message))"
        }
        $sw = [Diagnostics.Stopwatch]::StartNew()
        while ($sw.Elapsed.TotalSeconds -lt 60) {
            if (-not (Get-Daemon)) { break }
            Start-Sleep -Seconds 2
        }
        if (Get-Daemon) { Fail 21 'the daemon still answers. Nothing else changed.' }
        Note "the daemon is down after $([int]$sw.Elapsed.TotalSeconds)s"
    }
    if ($Mode -eq 'stop') {
        Say 'you can edit vms.cfg now:  dr-layer adopt <name>'
        exit 0
    }
}

# ============================================================================= start
if ($Mode -eq 'start' -or $Mode -eq 'restart') {
    if (Get-Daemon) { Say 'AppSandbox is already up.'; exit 0 }
    $exe = Find-Exe
    if (-not $exe) {
        Fail 22 ('this script cannot see AppSandbox.exe. Nothing recorded it while the ' +
                 "daemon was up (no $exeNote), and it is not at the default install path. Start " +
                 'it yourself with --headless, as an administrator.')
    }
    Say "starting $exe --headless"
    # THE ONE PLACE THAT NEEDS ELEVATION. -Verb RunAs shows one UAC question
    # from an ordinary shell. Thus the rest of this script does not need
    # elevation. A refusal throws, and does not return a code. The plain
    # exception looks like a script fault, not like a decision of a person.
    try {
        Start-Process -FilePath $exe -ArgumentList '--headless' -Verb RunAs | Out-Null
    } catch {
        Fail 24 'elevation was refused, so AppSandbox did not start.'
    }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
        Start-Sleep -Seconds 2
        $d = Get-Daemon
        if ($d) {
            Note "up after $([int]$sw.Elapsed.TotalSeconds)s: $($d.Version)"
            Save-ExePath
            exit 0
        }
    }
    Fail 21 "AppSandbox started, but nothing answered within $TimeoutSec s."
}
