# rm.ps1 - delete a forge VM, after showing exactly what goes with it.
#
# ==> RUN BY bin/dr-forge, ON THE WINDOWS SIDE. Not meant to be typed. <==
#
# THE HAZARD THIS EXISTS FOR. `asb_vm_delete` calls `remove_dir_recursive` on the folder
# DERIVED from the VM's disk path - strip the filename, and strip a trailing `\snapshots` when
# the file is named `branch_*` or `snapshot_*` - and that recursion is guarded only against a
# drive root (docs/FORGE-DISKS.md, "The VM's folder is derived from the disk path"). A VM
# pointed at `D:\Archive\base.vhdx` therefore has `D:\Archive\` in its blast radius, and the
# layer store is exactly the kind of folder people point a VM near: MEASURED, every
# VM on this machine reports `diskDirectory: C:\ForgeLayers`, which is the store holding every
# frozen layer. It is safe there only because each VM gets a subfolder of its own.
#
# So this does not ask the daemon to delete and hope. It works out the folder that will be
# removed, refuses outright when that folder holds something no VM should take with it, and
# otherwise reports the contents and the size so the caller can show them before asking.
#
# TWO MODES, because the inspection has to happen BEFORE the confirmation and the deletion
# after it:
#   inspect   read-only. key=value lines, the shape bin/dr-forge can read without a parser.
#   delete    stop the VM if it is running, then delete it.
#
# EXIT CODES:
#   0 fine   2 misuse   10 no daemon   11 no such VM   12 the folder is not safe to remove
#   13 the delete failed
param(
    [string]$Mode = 'inspect',
    [string]$Vm   = ''
)

if (-not $Vm)   { Write-Host 'rm.ps1: -Vm is required' -ForegroundColor Red; exit 2 }
if ($Mode -notin @('inspect', 'delete')) {
    Write-Host "rm.ps1: -Mode must be inspect or delete, not '$Mode'" -ForegroundColor Red; exit 2
}

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'

# The host key a deleted VM leaves behind, shared with layer.ps1 because `drop` and `adopt`
# strand exactly the same entry.
. (Join-Path $PSScriptRoot 'hostkey.ps1')

function Fail([int]$code, [string]$m) {
    Write-Host "dr-forge rm: $m" -ForegroundColor Red
    exit $code
}

# --- the daemon, by effect ----------------------------------------------------------------
$hostJson = Join-Path $env:ProgramData 'AppSandbox\host.json'
if (-not (Test-Path $hostJson)) { Fail 10 'the AppSandbox daemon is not running.' }
$h = Get-Content $hostJson -Raw | ConvertFrom-Json
function Asb([string]$Method, [string]$Path) {
    $a = @{ Uri = "$($h.endpoint)/v1$Path"; TimeoutSec = 60; Method = $Method
            Headers = @{ Authorization = "Bearer $($h.token)" } }
    if ($Method -eq 'POST') { $a.Body = '{}'; $a.ContentType = 'application/json' }
    Invoke-RestMethod @a
}
try { $null = Asb GET '/version' } catch {
    Fail 10 'host.json is there but nothing answers - the last daemon died rather than exited.'
}

try { $st = Asb GET "/vms/$Vm" } catch { Fail 11 "the daemon knows no VM called '$Vm'." }

# --- which folder would be removed --------------------------------------------------------
# The API reports `diskDirectory` rather than the disk's full path, so the folder is derived
# and then CONFIRMED by finding a disk in it - never assumed from the name alone. If the
# expected subfolder holds no disk but the store itself does, the VM is pointed straight at
# the store and deleting it would take everything in there.
$store = "$($st.diskDirectory)"
$folder = ''
$why = ''
if ($store -and (Test-Path (Join-Path (Join-Path $store $Vm) 'disk.vhdx'))) {
    $folder = Join-Path $store $Vm
} elseif ($store -and (Test-Path (Join-Path $store 'disk.vhdx'))) {
    $folder = $store
    $why = 'the VM is pointed at the disk directory itself, not at a subfolder of it'
} else {
    $folder = Join-Path $store $Vm
    $why = 'no disk.vhdx was found where one was expected'
}

# --- is that folder safe to remove? -------------------------------------------------------
# A FROZEN LAYER IN THE BLAST RADIUS IS AN OUTRIGHT REFUSAL. Frozen means the disk file is
# read-only, which is how the layer mechanism marks a parent that children depend on; any
# change to it invalidates every child, and removal is the largest change there is. Siblings
# are fine - the store holding layers BESIDE this VM's folder is the normal arrangement.
$unsafe = @()
if ($why) { $unsafe += $why }

if (Test-Path $folder) {
    # -Force so hidden entries count: something that would be removed and not reported is the
    # one thing this inspection must not do.
    $all = @(Get-ChildItem -LiteralPath $folder -Force -Recurse -ErrorAction SilentlyContinue)
    $bytes = 0
    $all | Where-Object { -not $_.PSIsContainer } | ForEach-Object { $bytes += $_.Length }

    # A read-only .vhdx anywhere under here is a frozen layer, and this VM's own disk is not
    # one: a registered VM's disk is writable by definition.
    $frozen = @($all | Where-Object {
        -not $_.PSIsContainer -and $_.Extension -eq '.vhdx' -and $_.IsReadOnly
    })
    foreach ($f in $frozen) { $unsafe += "a frozen layer is inside it: $($f.FullName)" }

    # Another VM's folder under this one would go too. layer.json beside a disk is how both
    # layers and VMs are marked, so a subfolder carrying one is somebody else's home.
    $nested = @(Get-ChildItem -LiteralPath $folder -Directory -Force -ErrorAction SilentlyContinue |
        Where-Object { Test-Path (Join-Path $_.FullName 'disk.vhdx') })
    foreach ($n in $nested) { $unsafe += "another disk lives under it: $($n.FullName)" }

    Write-Output "folder=$folder"
    Write-Output "exists=yes"
    Write-Output ("bytes=" + $bytes)
    foreach ($e in (Get-ChildItem -LiteralPath $folder -Force -ErrorAction SilentlyContinue)) {
        Write-Output ("entry=" + $e.Name + $(if ($e.PSIsContainer) { '\' } else { '' }))
    }
} else {
    Write-Output "folder=$folder"
    Write-Output "exists=no"
    Write-Output "bytes=0"
}

Write-Output "running=$(if ($st.running) { 'yes' } else { 'no' })"
foreach ($u in $unsafe) { Write-Output "unsafe=$u" }

if ($Mode -eq 'inspect') {
    Write-Output "safe=$(if ($unsafe.Count -eq 0) { 'yes' } else { 'no' })"
    exit 0
}

# --- delete -------------------------------------------------------------------------------
# The refusal is repeated on this side rather than trusted to the caller: inspect and delete
# are two crossings of the boundary, and anything could have changed in between. This is the
# check that actually governs, and it is the one the exit code comes from.
if ($unsafe.Count -gt 0) {
    Fail 12 "refusing to delete '$Vm': $($unsafe -join '; ')"
}

# Stopped first, and through the API because the guest is going away anyway: a graceful
# shutdown is what `dr-forge down` is for, and waiting for one here would only delay a disk
# that is about to be removed. The daemon refuses to delete a running VM.
if ($st.running) {
    Write-Output 'phase=stopping'
    try { $null = Asb POST "/vms/$Vm/stop" } catch { }
    $t0 = Get-Date
    do {
        Start-Sleep -Seconds 3
        try { $st = Asb GET "/vms/$Vm" } catch { break }
    } while ($st.running -and ((Get-Date) - $t0).TotalSeconds -lt 120)
    if ($st.running) { Fail 13 "'$Vm' would not stop, so it was not deleted." }
}

# POST /vms/<name>/delete, which is the same shape as /start and /stop.
#
# IT IS NOT `DELETE /vms/<name>`. That was this script's first guess and the daemon answered
# **405 Method Not Allowed** - the route exists, the verb does not - with no Allow header to say
# which verb would work, and a 404 for every probe of a /delete sub-route, because this server
# answers method mismatches on sub-routes with 404 rather than 405. So probing cannot find it.
#
# The authority is the client AppSandbox ships, at C:\AppSandbox\headless-api\asb.py:
#
#     def delete_vm(self, name): return self._req("POST", "/vms/%s/delete" % name)
#
# with the README beside it documenting `delete_vm(name)` as "remove the VM and its disk
# (refused 409 while building)". Read it before adding another call rather than guessing from
# the shape of the ones already here.
Write-Output 'phase=deleting'
try {
    $null = Invoke-RestMethod -Uri "$($h.endpoint)/v1/vms/$Vm/delete" -Method POST `
        -Body '{}' -ContentType 'application/json' -TimeoutSec 300 `
        -Headers @{ Authorization = "Bearer $($h.token)" }
} catch {
    # 409 is a STATE conflict rather than a refusal of the request, and the one that happens is
    # a VM still building - which is worth saying, because the answer is to wait rather than to
    # go looking for what is wrong.
    $code = 0
    if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
    if ($code -eq 409) {
        Fail 13 "'$Vm' cannot be deleted yet: the daemon reports a state conflict (409), which for a delete means it is still building. Wait for it to finish, then re-run."
    }
    Fail 13 "the daemon refused to delete '$Vm': $($_.Exception.Message)"
}

# Verified by effect: a 200 from a young API is not the same as a VM that is gone.
Start-Sleep -Seconds 2
$still = $true
try { $null = Asb GET "/vms/$Vm" } catch { $still = $false }
if ($still) { Fail 13 "the daemon still reports '$Vm' after the delete." }
Write-Output 'phase=gone'

# THE HOST KEY GOES WITH THE VM. It is filed under the VM's NAME, so it outlives the machine
# and poisons the next VM given that name - see hostkey.ps1. Last, and never fatal: the VM is
# already gone by here, and a leftover line in known_hosts is not a reason to report a delete
# as failed. Said only when there was one, because "hostkey=" alone says nothing.
$cleared = Clear-ForgeHostKey $Vm
if ($cleared) { Write-Output "hostkey=$cleared" }
exit 0
