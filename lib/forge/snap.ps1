# snap.ps1: the one baseline of the forge. Take it, or go back to it.
#
# ==> bin/dr-forge RUNS THIS, ON THE WINDOWS SIDE. Do not type it. <==
#
# ONE BASELINE, BECAUSE OF A BUG, not a preference. `snapshot_take` builds each
# snapshot as a differencing child of the disk recorded at the FIRST snapshot.
# It never uses the disk that the VM runs on (read: src\backend_win\snapshot.c,
# still in 0.1.8). Thus a SECOND snapshot silently keeps the old baseline. The
# work since then goes to a branch that nobody knows about. The first one is
# correct. Thus this takes exactly one, and refuses a second. A move of the
# baseline waits for upstream PR #199 (issue #152). docs/FORGE.md, "Backup and
# rollback".
#
# THE CALL SEQUENCE COMES FROM THE SOURCE, NOT A GUESS. It comes from the client
# and the example that AppSandbox ships at C:\AppSandbox\headless-api\ (asb.py,
# examples\full_lifecycle.py). The last call that was a guess from its neighbors
# cost a failed `dr-forge rm` and a 405:
#
#   GET    /vms/<n>/snapshots                  {snapshots:[{index,name,branchCount,branches}],
#                                               baseBranches, current:{snapIndex,branchIndex}}
#   POST   /vms/<n>/snapshots  {"name":"..."}  take one. The VM must be STOPPED, else 409
#   POST   /vms/<n>/start      {"snapIndex":i, THE ONLY WAY TO MAKE A BRANCH is to BOOT from a
#                               "branchName":n} snapshot onto it. The GUI has no other way
#   DELETE /vms/<n>/snapshots/<i>/branches/<b> drop one branch. The VM must be stopped
#
# Two of those decide the shape of all below:
#
#   A START creates a branch, so `rollback` cannot leave the VM stopped. The VM runs at the
#   end. The API causes that. It is not a choice of this script.
#
#   A branch can be deleted only while the VM is stopped. Thus the old branch must go BEFORE
#   the new one starts. full_lifecycle.py does exactly that. It shuts the VM down, then drops
#   the branch that it ran on. That also proves that a delete of the CURRENT branch is legal.
#
# WHY `base` REFUSES THE PLUG AND `rollback` DOES NOT. Both stop the VM first,
# because a snapshot needs a stopped VM. But a baseline from a guest that lost
# power is a crash-consistent image of the most important disk. Thus `base`
# stops, and does not force one. `rollback` forces a stop of the working branch
# that it then deletes. That loses nothing that was not already for the discard.
#
# THREE MODES, because the description must be available without the action:
#   status     read-only. key=value lines, the shape bin/dr-forge reads without a parser.
#   base       take the baseline. If one already exists, refuses.
#   rollback   discard the working branch, then boot a fresh one off the baseline.
#
# EXIT CODES:
#   0 fine   2 misuse   10 no daemon   11 no such VM   20 a baseline already exists
#   21 there is no baseline yet   22 the VM did not stop   23 the daemon refused a call
#   24 this host does not do snapshots
param(
    [string]$Mode       = 'status',
    [string]$Vm         = '',
    # The name of the baseline. It has a default, and a date, because the API
    # reports no creation time for a snapshot. Thus the name is the only place
    # for a date.
    [string]$Name       = '',
    [int]   $GraceSec   = 180,
    [int]   $TimeoutSec = 300
)

# Not [Parameter(Mandatory)]. A [Parameter()] attribute in a param block makes
# the script cmdlet-bound, and then $PSScriptRoot is empty while PowerShell
# evaluates the defaults above. Thus this script tests the values itself, as
# vm.ps1 does.
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
# A name goes into a URL and a disk path. Thus it can use only what is safe in
# both. It is not passed through on hope.
if ($Name -and ($Name -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$')) {
    Fail 2 "-Name '$Name' is not usable: letters, digits, dot, dash and underscore, up to 63."
}

# --- the daemon, by effect ----------------------------------------------------------------
# A host.json with nothing behind it is the sign of a daemon that died and did
# not exit. With only the file, this script connects to a port that nobody
# holds.
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

# The status code tells the important failures apart. 409 is a state conflict,
# not a refusal. 501 means that this host does not have the feature.
function Code($err) {
    if ($err.Exception.Response) { return [int]$err.Exception.Response.StatusCode }
    return 0
}

try { $null = Asb GET '/version' } catch {
    Fail 10 'host.json exists, but nothing answers. The last daemon died, and did not exit.'
}
try { $st = Asb GET "/vms/$Vm" } catch { Fail 11 "the daemon knows no VM called '$Vm'." }

# --- reading the snapshot tree ------------------------------------------------------------
# YOU CANNOT TRUST THE COUNT OF @($x.snapshots). ConvertFrom-Json makes a
# missing key $null, and @($null).Count is 1. Thus an empty tree reads as one
# snapshot, and `base` refuses to take the missing baseline. A filter for $null
# makes the count correct.
function Get-Tree {
    try { return Asb GET "/vms/$Vm/snapshots" } catch {
        if ((Code $_) -eq 501) {
            Fail 24 'this host does not do snapshots (501). Snapshots and branches are Windows-only.'
        }
        Fail 23 "the daemon did not list the snapshots of '$Vm': $($_.Exception.Message)"
    }
}
# AND @() IN A FUNCTION IS LOST AT THE RETURN. PowerShell unrolls an array with
# one element on the way out. Thus `return @($x)` gives back the bare element,
# and its `.Count` is EMPTY, not 1. A test on the first live baseline showed
# this. `branches=` and `snapshots=` both printed blank, because one snapshot
# with one branch is the case that unrolls. Two or more stay an Object[] and
# count correctly. That is why the bug was hidden.
#
# Thus each caller wraps again: @(Real ...). That looks unnecessary, but it is
# not. If you remove one of the two @(), the blank counts come back.
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

# The clean stop. Both acting modes need it, and only one can force it.
# `/shutdown` is a clean ACPI power-off, and `/stop` is the plug (the words of
# the API README). The VM goes through a `stopping` state on the way. Thus this
# waits until `running` is false, not for a named state. The stop mode of vm.ps1
# does the same for `dr-forge down`.
function Stop-Vm([bool]$MayForce) {
    if (-not (Test-Running)) { return $true }
    Say 'asking the daemon for a clean shutdown'
    try { $null = Asb POST "/vms/$Vm/shutdown" } catch {
        Say "the daemon refused the clean shutdown: $($_.Exception.Message)"
    }
    Say "waiting up to $GraceSec s for it to power off"
    if (Wait-Stopped $GraceSec) { Say 'stopped'; return $true }
    if (-not $MayForce) { return $false }
    Say 'it did not stop in the grace period. Pulling the plug through the daemon'
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
# Printed in each mode, so that the record of the action starts with its target.
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
# HERE, MORE THAN ONE IS REPORTED, NOT REFUSED. The bug affects the second
# snapshot. Thus a tree with two was made outside dr-forge, or before this
# refusal existed. In both cases, the caller says so. This script does not
# decide what to do about it.
if ($snaps.Count -gt 1) { Write-Output 'extra_snapshots=yes' }

if ($Mode -eq 'status') { exit 0 }

# --- base ---------------------------------------------------------------------------------
if ($Mode -eq 'base') {
    # The refusal comes before the stop. A shutdown of a guest for the answer
    # "no" is a waste.
    if ($baseline) {
        Fail 20 ("'$Vm' already has a baseline: #$($baseline.index) '$($baseline.name)'. " +
                 'Only the first snapshot records the current state, so a second is refused.')
    }
    if (-not $Name) { $Name = "draugr-base-$(Get-Date -Format 'yyyyMMdd-HHmm')" }

    if (-not (Stop-Vm $false)) {
        Fail 22 ("'$Vm' did not shut down in $GraceSec s. A baseline from a guest that " +
                 'lost power is not allowed. Shut it down by hand, then run again.')
    }

    Write-Output 'phase=taking'
    Say "taking the baseline '$Name'"
    try { $null = Asb POST "/vms/$Vm/snapshots" @{ name = $Name } } catch {
        if ((Code $_) -eq 409) {
            Fail 23 "the daemon says that '$Vm' still runs (409), so it refused the snapshot."
        }
        Fail 23 "the daemon refused to snapshot '$Vm': $($_.Exception.Message)"
    }

    # PROVED BY EFFECT. The daemon accepts an async action with 202. Thus a
    # success code is not the same as a snapshot on disk.
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
    Fail 21 ("'$Vm' has no baseline to go back to. Take one with 'dr-forge base', once for " +
             'each VM, because only the first snapshot records the current state.')
}

if (-not (Stop-Vm $true)) { Fail 22 "'$Vm' did not stop, so nothing changed." }

# THE OLD BRANCH GOES FIRST, and it must. A start of the VM creates a branch.
# Thus the new one cannot exist while the VM is stopped, and the old one cannot
# be deleted while it runs. If the delete works and then the start fails, the
# baseline does not change. Another run then makes the new branch. Thus a
# discard first is safe, and also necessary.
if ($curBranch -ge 0) {
    Write-Output 'phase=discarding'
    Say "discarding branch $curBranch of snapshot $curSnap"
    try {
        $null = Asb DELETE "/vms/$Vm/snapshots/$curSnap/branches/$curBranch"
    } catch {
        Fail 23 ("the daemon did not discard branch $curBranch of snapshot $curSnap" +
                 ": $($_.Exception.Message). Nothing was lost. The baseline is still there.")
    }
} else {
    Say "the VM is on no branch (current branch $curBranch), so nothing needs a discard"
}

$branch = "work-$(Get-Date -Format 'yyyyMMdd-HHmm')"
Write-Output 'phase=branching'
Say "booting '$Vm' from baseline #$($baseline.index) onto a new branch '$branch'"
try {
    $null = Asb POST "/vms/$Vm/start" @{ snapIndex = [int]$baseline.index; branchName = $branch }
} catch {
    Fail 23 ("the daemon did not start '$Vm' from the baseline: $($_.Exception.Message). " +
             'The baseline did not change. Run again to try the branch again.')
}
if (-not (Wait-Running $TimeoutSec)) {
    Fail 23 "'$Vm' started from the baseline, but it did not come up in $TimeoutSec s."
}

Write-Output 'phase=rolled'
Write-Output "branch_name=$branch"
exit 0
