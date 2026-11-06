# snap.ps1 - the forge's one baseline: take it, or go back to it.
#
# ==> RUN BY bin/dr-forge, ON THE WINDOWS SIDE. Not meant to be typed. <==
#
# ONE BASELINE, AND THAT IS A BUG'S DOING rather than a preference. `snapshot_take` builds
# every snapshot as a differencing child of the disk recorded at the FIRST snapshot, never of
# the disk the VM is running on (read: src\backend_win\snapshot.c, still present in 0.1.8), so
# a SECOND snapshot silently preserves the old baseline and strands the work since then on a
# branch nobody is told about. The first one is correct. So this takes exactly one and refuses
# a second; moving the baseline forward waits on upstream PR #199 (issue #152).
# docs/FORGE.md, "Backup and rollback".
#
# THE CALL SEQUENCE WAS READ, NOT INFERRED - from the client and the worked example AppSandbox
# ships at C:\AppSandbox\headless-api\ (asb.py, examples\full_lifecycle.py), because the last
# call guessed from the shape of its neighbours cost a failed `dr-forge rm` and a 405:
#
#   GET    /vms/<n>/snapshots                  {snapshots:[{index,name,branchCount,branches}],
#                                               baseBranches, current:{snapIndex,branchIndex}}
#   POST   /vms/<n>/snapshots  {"name":"..."}  take one - the VM must be STOPPED, else 409
#   POST   /vms/<n>/start      {"snapIndex":i, THE ONLY WAY TO MAKE A BRANCH is to BOOT from a
#                               "branchName":n} snapshot onto it; the GUI has no other way
#   DELETE /vms/<n>/snapshots/<i>/branches/<b> drop one branch - the VM must be stopped
#
# Two of those decide the shape of everything below:
#
#   A branch is created by STARTING, so `rollback` cannot leave the VM stopped. It ends up
#   running, and that is the API's doing rather than a choice made here.
#
#   A branch is deleted only while the VM is stopped, so the old branch must go BEFORE the new
#   one is started. full_lifecycle.py does exactly that - it shuts the VM down and then drops
#   the branch it had just been running on - which is also the proof that the CURRENT branch is
#   a legal thing to delete.
#
# WHY `base` REFUSES THE PLUG AND `rollback` DOES NOT. Both stop the VM first, because a
# snapshot needs it stopped. But a baseline taken from a guest whose power was cut is a
# crash-consistent image of the one disk you least want to be guessing about, so `base` gives
# up rather than force one. What `rollback` force-stops is the working branch it is about to
# delete, where nothing is lost that was not already being discarded.
#
# THREE MODES, because the description has to be available without the action:
#   status     read-only. key=value lines, the shape bin/dr-forge reads without a parser.
#   base       take the baseline. Refuses if there already is one.
#   rollback   discard the working branch, then boot a fresh one off the baseline.
#
# EXIT CODES:
#   0 fine   2 misuse   10 no daemon   11 no such VM   20 a baseline already exists
#   21 there is no baseline yet   22 the VM would not stop   23 the daemon refused a call
#   24 this host does not do snapshots
param(
    [string]$Mode       = 'status',
    [string]$Vm         = '',
    # The baseline's name. Defaulted rather than demanded, and stamped, because the API
    # reports no creation time for a snapshot - so the name is the only place a date can live.
    [string]$Name       = '',
    [int]   $GraceSec   = 180,
    [int]   $TimeoutSec = 300
)

# Not [Parameter(Mandatory)]: a [Parameter()] attribute anywhere in a param block makes the
# script cmdlet-bound, and $PSScriptRoot is then empty while the defaults above are evaluated.
# Validated by hand instead, the way vm.ps1 does.
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'

function Fail([int]$Code, [string]$Msg) {
    [Console]::Error.WriteLine("forge-snap: $Msg")
    exit $Code
}
function Say([string]$Msg) { Write-Host $Msg }

if (-not $Vm) { Fail 2 '-Vm is required' }
if ($Mode -notin @('status', 'base', 'rollback')) {
    Fail 2 "-Mode must be status, base or rollback, not '$Mode'"
}
# A name crosses into a URL and a disk path, so it is kept to what is safe in both rather than
# passed through and hoped for.
if ($Name -and ($Name -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$')) {
    Fail 2 "-Name '$Name' is not usable: letters, digits, dot, dash and underscore, up to 63."
}

# --- the daemon, by effect ----------------------------------------------------------------
# A host.json with nothing behind it is the signature of a daemon that died rather than
# exited, and the file alone would have us dial a port no one holds.
$hostJson = Join-Path $env:ProgramData 'AppSandbox\host.json'
if (-not (Test-Path $hostJson)) { Fail 10 'the AppSandbox daemon is not running (no host.json).' }
$h = Get-Content $hostJson -Raw | ConvertFrom-Json

function Asb([string]$Method, [string]$Path, $Body = $null) {
    $a = @{ Uri = "$($h.endpoint)/v1$Path"; TimeoutSec = 120; Method = $Method
            Headers = @{ Authorization = "Bearer $($h.token)" } }
    if ($Method -eq 'POST' -or $Method -eq 'PUT') {
        if ($null -ne $Body) { $a.Body = ($Body | ConvertTo-Json -Compress) } else { $a.Body = '{}' }
        $a.ContentType = 'application/json'
    }
    Invoke-RestMethod @a
}

# The status code, which is what the interesting failures are told apart by: 409 is a state
# conflict rather than a refusal, and 501 means this host does not have the feature at all.
function Code($err) {
    if ($err.Exception.Response) { return [int]$err.Exception.Response.StatusCode }
    return 0
}

try { $null = Asb GET '/version' } catch {
    Fail 10 'host.json is there but nothing answers - the last daemon died rather than exited.'
}
try { $st = Asb GET "/vms/$Vm" } catch { Fail 11 "the daemon knows no VM called '$Vm'." }

# --- reading the snapshot tree ------------------------------------------------------------
# @($x.snapshots) IS NOT A COUNT YOU CAN TRUST. ConvertFrom-Json leaves a missing key as
# $null, and @($null).Count is 1 - so an empty tree would read as one snapshot and `base`
# would refuse to take the baseline that is not there. Filtering $null is what makes the
# count mean what it says.
function Get-Tree {
    try { return Asb GET "/vms/$Vm/snapshots" } catch {
        if ((Code $_) -eq 501) {
            Fail 24 'this host does not do snapshots (501). Snapshots and branches are Windows-only.'
        }
        Fail 23 "the daemon would not list the snapshots of '$Vm': $($_.Exception.Message)"
    }
}
# AND @() INSIDE A FUNCTION DOES NOT SURVIVE THE RETURN. PowerShell unrolls a single-element
# array on the way out, so `return @($x)` hands back the bare element and its `.Count` is
# EMPTY - not 1. MEASURED against the first live baseline: `branches=` and
# `snapshots=` both printed blank, because one snapshot with one branch is exactly the case
# that unrolls. Two or more stay an Object[] and count correctly, which is why this hid.
#
# So every caller re-wraps: @(Real ...). That looks redundant and is not - removing either
# @() brings the blank counts back.
function Real($list) { return @($list | Where-Object { $null -ne $_ }) }

function Test-Running {
    try { return [bool](Asb GET "/vms/$Vm").running } catch { return $false }
}
function Wait-Stopped([int]$Seconds) {
    $t0 = Get-Date
    do {
        if (-not (Test-Running)) { return $true }
        Start-Sleep -Seconds 5
    } while (((Get-Date) - $t0).TotalSeconds -lt $Seconds)
    return $false
}
function Wait-Running([int]$Seconds) {
    $t0 = Get-Date
    do {
        if (Test-Running) { return $true }
        Start-Sleep -Seconds 5
    } while (((Get-Date) - $t0).TotalSeconds -lt $Seconds)
    return $false
}

# The graceful stop, which both acting modes need and only one of them may force. `/shutdown`
# is a graceful ACPI power-off and `/stop` is the plug - the API README's own words - and the
# VM passes through a `stopping` state on the way, which is why this waits for `running` to go
# false rather than for a named state. See vm.ps1's stop mode, which does the same for
# `dr-forge down`.
function Stop-Vm([bool]$MayForce) {
    if (-not (Test-Running)) { return $true }
    Say 'asking the daemon for a graceful shutdown'
    try { $null = Asb POST "/vms/$Vm/shutdown" } catch {
        Say "the graceful shutdown was refused: $($_.Exception.Message)"
    }
    Say "waiting up to $GraceSec s for it to power off"
    if (Wait-Stopped $GraceSec) { Say 'stopped'; return $true }
    if (-not $MayForce) { return $false }
    Say 'it outlasted the grace period - pulling the plug through the daemon'
    try { $null = Asb POST "/vms/$Vm/stop" } catch { }
    return (Wait-Stopped 120)
}

$tree = Get-Tree
$snaps = @(Real $tree.snapshots)
$baseline = $snaps | Sort-Object index | Select-Object -First 1
$curSnap = -1
$curBranch = -1
if ($tree.current) {
    if ($null -ne $tree.current.snapIndex)   { $curSnap   = [int]$tree.current.snapIndex }
    if ($null -ne $tree.current.branchIndex) { $curBranch = [int]$tree.current.branchIndex }
}

# --- what it is, before anything moves ----------------------------------------------------
# Printed in every mode, so the record of what was done starts with what it was done to.
Write-Output "running=$(if ($st.running) { 'yes' } else { 'no' })"
Write-Output "baseline=$(if ($baseline) { 'yes' } else { 'no' })"
if ($baseline) {
    Write-Output "baseline_index=$($baseline.index)"
    Write-Output "baseline_name=$($baseline.name)"
    Write-Output "branches=$(@(Real $baseline.branches).Count)"
    foreach ($b in @(Real $baseline.branches)) {
        Write-Output "branch=$($b.index) $($b.name)"
    }
}
Write-Output "snapshots=$($snaps.Count)"
Write-Output "current_snap=$curSnap"
Write-Output "current_branch=$curBranch"
# MORE THAN ONE IS REPORTED, NOT REFUSED, here. The second snapshot is the one the bug
# mishandles, so a tree holding two was either made outside dr-forge or made before this
# refusal existed - and either way it is the caller's business to say so, not this script's
# to decide what to do about it.
if ($snaps.Count -gt 1) { Write-Output 'extra_snapshots=yes' }

if ($Mode -eq 'status') { exit 0 }

# --- base ---------------------------------------------------------------------------------
if ($Mode -eq 'base') {
    # The refusal comes before the stop: there is no point shutting a guest down to find out
    # the answer was no.
    if ($baseline) {
        Fail 20 ("'$Vm' already has a baseline: #$($baseline.index) '$($baseline.name)'. " +
                 'Only the first snapshot captures current state, so a second is refused.')
    }
    if (-not $Name) { $Name = "draugr-base-$(Get-Date -Format 'yyyyMMdd-HHmm')" }

    if (-not (Stop-Vm $false)) {
        Fail 22 ("'$Vm' did not shut down within $GraceSec s, and a baseline is not taken " +
                 'from a guest whose power was cut. Shut it down by hand, then re-run.')
    }

    Write-Output 'phase=taking'
    Say "taking the baseline '$Name'"
    try { $null = Asb POST "/vms/$Vm/snapshots" @{ name = $Name } } catch {
        if ((Code $_) -eq 409) {
            Fail 23 "the daemon reports '$Vm' as still running (409), so the snapshot was refused."
        }
        Fail 23 "the daemon refused to snapshot '$Vm': $($_.Exception.Message)"
    }

    # VERIFIED BY EFFECT. An async action is accepted with 202, so a success code is not the
    # same as a snapshot on disk.
    $made = $null
    $t0 = Get-Date
    do {
        Start-Sleep -Seconds 3
        $made = @(Real (Get-Tree).snapshots) | Sort-Object index | Select-Object -First 1
        if ($made) { break }
    } while (((Get-Date) - $t0).TotalSeconds -lt 120)
    if (-not $made) { Fail 23 "the daemon accepted the snapshot but none appeared for '$Vm'." }

    Write-Output 'phase=based'
    Write-Output "baseline_index=$($made.index)"
    Write-Output "baseline_name=$($made.name)"
    exit 0
}

# --- rollback -----------------------------------------------------------------------------
if (-not $baseline) {
    Fail 21 ("'$Vm' has no baseline to go back to. Take one with 'dr-forge base' - once per " +
             'VM, because only the first snapshot captures current state.')
}

if (-not (Stop-Vm $true)) { Fail 22 "'$Vm' would not stop, so nothing was changed." }

# THE OLD BRANCH GOES FIRST, and it has to: a branch is created by starting the VM, so the new
# one cannot exist while the VM is stopped, and the old one cannot be deleted while it runs.
# If the delete lands and the start then fails, the baseline is untouched and re-running this
# makes the fresh branch - so discarding first is safe as well as forced.
if ($curBranch -ge 0) {
    Write-Output 'phase=discarding'
    Say "discarding branch $curBranch of snapshot $curSnap"
    try {
        $null = Asb DELETE "/vms/$Vm/snapshots/$curSnap/branches/$curBranch"
    } catch {
        Fail 23 ("the daemon would not discard branch $curBranch of snapshot $curSnap" +
                 ": $($_.Exception.Message). Nothing was lost - the baseline still stands.")
    }
} else {
    Say "the VM is on no branch (current branch $curBranch), so there is nothing to discard"
}

$branch = "work-$(Get-Date -Format 'yyyyMMdd-HHmm')"
Write-Output 'phase=branching'
Say "booting '$Vm' from baseline #$($baseline.index) onto a fresh branch '$branch'"
try {
    $null = Asb POST "/vms/$Vm/start" @{ snapIndex = [int]$baseline.index; branchName = $branch }
} catch {
    Fail 23 ("the daemon would not start '$Vm' from the baseline: $($_.Exception.Message). " +
             'The baseline is intact - re-run to try the branch again.')
}
if (-not (Wait-Running $TimeoutSec)) {
    Fail 23 "'$Vm' was started from the baseline but has not come up within $TimeoutSec s."
}

Write-Output 'phase=rolled'
Write-Output "branch_name=$branch"
exit 0
