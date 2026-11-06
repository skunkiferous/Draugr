# daemon.ps1 - AppSandbox's lifecycle, as one thing to run.
#
# ==> RUN BY bin/dr-forge daemon. Usable by hand; not meant to be typed twice. <==
#
# WHY IT EXISTS. Every dr-layer verb that rewrites vms.cfg - adopt, freeze, thaw, drop, new -
# refuses while the daemon is up, and the daemon has no window, so "close AppSandbox" is not
# an instruction anyone can follow. layer.ps1 used to print six lines to paste into an elevated
# PowerShell, and a seventh to bring it back. Asked to be made one command.
#
# ONLY `start` NEEDS ELEVATION, and the instructions it replaces were wrong about that. The
# headless API's README is explicit that the gate is on RUNNING the daemon - HCS and the
# http.sys bind both require it - not on calling it: a request carries the bearer token and
# nothing else. MEASURED from an ordinary shell: POST /vms/<n>/stop succeeded. So
# the shutdowns need no elevation and only the --headless relaunch does, which
# Start-Process -Verb RunAs raises exactly one prompt for.
#
# ORDER IS NOT OURS TO CHOOSE: POST /shutdown is refused with 409 while any VM runs unless
# {"force":true}, which TERMINATES the guests. A terminated guest is a dirty disk and these
# commands exist to freeze disks, so force is not offered here at all - the VMs go down
# gracefully, each one waited for, and the daemon follows. See headless-api\asb.py,
# shutdown_daemon().
#
#   powershell -ExecutionPolicy Bypass -File .\daemon.ps1 -Mode status
#   powershell -ExecutionPolicy Bypass -File .\daemon.ps1 -Mode stop
#   powershell -ExecutionPolicy Bypass -File .\daemon.ps1 -Mode start
#
# EXIT CODES, because a front end has to tell a refusal from a failure:
#   0   done - and for `status`, the daemon is up
#   2   the arguments are wrong
#   3   `status` only: the daemon is down. Not a failure, a fact
#   20  a VM would not stop, so the daemon was left alone
#   21  the daemon would not stop
#   22  AppSandbox.exe could not be found to start it
#   24  elevation was declined
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
    Fail 2 "unknown -Mode '$Mode': one of $($validModes -join ', ')"
}

$asbDir   = Join-Path $env:ProgramData 'AppSandbox'
$hostJson = Join-Path $asbDir 'host.json'
# WHERE THE EXE WAS LAST SEEN. `start` runs when there is no process left to ask, so the path
# is recorded while the daemon IS up - by this script's own status and stop paths - and read
# back later. A list of likely directories would be a guess; this is an observation.
$exeNote  = Join-Path $asbDir 'draugr-daemon-path.txt'

# --- is it there, and what does it say? ---------------------------------------------------
# By EFFECT, never by the file's existence: a host.json with nothing behind it means the last
# daemon DIED rather than exited, and the file alone would report a healthy daemon.
function Get-Daemon {
    if (-not (Test-Path $hostJson)) { return $null }
    try {
        $h = Get-Content $hostJson -Raw | ConvertFrom-Json
        $hdr = @{ Authorization = "Bearer $($h.token)" }
        $v = Invoke-RestMethod -Uri "$($h.endpoint)/v1/version" -TimeoutSec 5 -Headers $hdr
        return @{ Endpoint = $h.endpoint; Header = $hdr; Version = "$($v.product) $($v.version)" }
    } catch { return $null }
}

function Get-Vms($d) {
    try { return @((Invoke-RestMethod -Uri "$($d.Endpoint)/v1/vms" -Headers $d.Header -TimeoutSec 15).vms) }
    catch { return @() }
}

# The daemon's own image path, asked of the process that is running right now. .Path comes back
# empty for a process this account cannot open - which is the normal case, since the daemon is
# elevated - so an empty answer is not an error and the default install is the fallback.
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
            Note 'host.json is there and nothing answers, so the last daemon died rather than exited.'
        }
        $exe = Find-Exe
        if ($exe) { Note "start it:  dr-forge daemon start   ($exe)" }
        else { Warn 'and AppSandbox.exe cannot be found, so this cannot start it either.' }
        exit 3
    }
    Save-ExePath
    Say "AppSandbox is UP - $($d.Version) on $($d.Endpoint)"
    $vms = Get-Vms $d
    $running = @($vms | Where-Object { $_.running } | ForEach-Object { $_.name })
    if ($running.Count) {
        Note "running: $($running -join ', ')"
        Note 'these go down first - the API refuses a daemon shutdown while any VM runs'
    } else {
        Note 'no VM is running, so the daemon can go straight down'
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
        Say "stopping AppSandbox - $($d.Version)"
        $running = @(Get-Vms $d | Where-Object { $_.running } | ForEach-Object { $_.name })

        # GRACEFULLY, AND WAITED FOR, one at a time. /shutdown is the ACPI power-off;
        # /stop is the plug. A guest pulled out from under its own filesystem is a dirty
        # disk, and the verbs this exists to serve are the ones that freeze disks.
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
                $st = @(Get-Vms $d | Where-Object { $_.name -eq $v })
                if (-not $st -or -not $st[0].running) { $down = $true; break }
                Start-Sleep -Seconds 3
            }
            if (-not $down) {
                Fail 20 ("'$v' was still running after $TimeoutSec s, so the daemon has been left " +
                         'alone. Nothing has been changed. Force would terminate the guest, which ' +
                         'leaves a dirty disk, so it is not offered here: stop it from inside, or ' +
                         'use dr-forge down for that one VM.')
            }
            Note "  '$v' is down after $([int]$sw.Elapsed.TotalSeconds)s"
        }

        try {
            $null = Invoke-RestMethod -Method Post -Uri "$($d.Endpoint)/v1/shutdown" `
                        -Headers $d.Header -Body '{}' -ContentType 'application/json' -TimeoutSec 30
        } catch {
            # A daemon that goes away mid-request cannot answer it, so a broken connection here
            # is the expected shape of success. Only the EFFECT below decides.
            Note "the shutdown request did not return cleanly ($($_.Exception.Message))"
        }
        $sw = [Diagnostics.Stopwatch]::StartNew()
        while ($sw.Elapsed.TotalSeconds -lt 60) {
            if (-not (Get-Daemon)) { break }
            Start-Sleep -Seconds 2
        }
        if (Get-Daemon) { Fail 21 'the daemon is still answering; nothing else was changed.' }
        Note "the daemon is down after $([int]$sw.Elapsed.TotalSeconds)s"
    }
    if ($Mode -eq 'stop') {
        Say 'vms.cfg is yours to edit now:  dr-layer adopt <name>'
        exit 0
    }
}

# ============================================================================= start
if ($Mode -eq 'start' -or $Mode -eq 'restart') {
    if (Get-Daemon) { Say 'AppSandbox is already up.'; exit 0 }
    $exe = Find-Exe
    if (-not $exe) {
        Fail 22 ('AppSandbox.exe is not where this can see it. It was not recorded while the ' +
                 "daemon was up (no $exeNote) and it is not at the default install path. Start " +
                 'it by hand with --headless, as an administrator.')
    }
    Say "starting $exe --headless"
    # THE ONE PLACE ELEVATION IS NEEDED. -Verb RunAs raises a single UAC prompt from an
    # ordinary shell, which is why none of the rest of this script has to be elevated.
    # Declining throws rather than returning a code, and the bare exception reads like a
    # scripting fault instead of a decision somebody made.
    try {
        Start-Process -FilePath $exe -ArgumentList '--headless' -Verb RunAs | Out-Null
    } catch {
        Fail 24 'elevation was declined, so AppSandbox was not started.'
    }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
        Start-Sleep -Seconds 2
        $d = Get-Daemon
        if ($d) {
            Note "up after $([int]$sw.Elapsed.TotalSeconds)s - $($d.Version)"
            Save-ExePath
            exit 0
        }
    }
    Fail 21 "AppSandbox was launched but nothing answered within $TimeoutSec s."
}
