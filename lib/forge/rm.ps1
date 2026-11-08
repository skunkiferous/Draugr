# rm.ps1: delete a forge VM, after it shows all that goes with it.
#
# ==> bin/dr-forge RUNS THIS, ON THE WINDOWS SIDE. Do not type it. <==
#
# THE HAZARD. `asb_vm_delete` calls `remove_dir_recursive` on the folder that it
# DERIVES from the disk path of the VM. It removes the filename. If the file is
# named `branch_*` or `snapshot_*`, it also removes a trailing `\snapshots`. The
# only guard on that recursion is against a drive root (docs/FORGE-DISKS.md,
# "The VM's folder is derived from the disk path"). Thus, for a VM on
# `D:\Archive\base.vhdx`, a delete can remove `D:\Archive\`. People often put a
# VM near the layer store. A test showed that each VM on this machine reports
# `diskDirectory: C:\ForgeLayers`, the store of all frozen layers. It is safe
# only because each VM gets its own subfolder.
#
# Thus this script does not tell the daemon to delete and then hope. It finds
# the folder that the delete removes. If that folder holds something that no VM
# must take with it, it refuses. If not, it reports the contents and the size,
# so that the caller can show them before it asks.
#
# TWO MODES, because the inspection must happen BEFORE the confirmation, and the
# delete after it:
#   inspect   read-only. key=value lines, the shape bin/dr-forge can read without a parser.
#   delete    stop the VM if it runs, then delete it.
#
# EXIT CODES:
#   0 fine   2 misuse   10 no daemon   11 no such VM   12 a removal of the folder is not safe
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

# The host key that a deleted VM leaves behind. layer.ps1 shares this, because
# `drop` and `adopt` leave the same entry.
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
    Fail 10 'host.json exists, but nothing answers. The last daemon died, and did not exit.'
}

try { $st = Asb GET "/vms/$Vm" } catch { Fail 11 "the daemon knows no VM called '$Vm'." }

# --- which folder would be removed --------------------------------------------------------
# The API reports `diskDirectory`, not the full path of the disk. Thus this
# script derives the folder, and then PROVES it with a disk in it. It never
# trusts only the name. If the expected subfolder holds no disk, but the store
# does, the VM points directly at the store. Then a delete takes all that is in
# it.
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
# A FROZEN LAYER IN THE AREA OF THE DELETE IS A REFUSAL. Frozen means that the
# disk file is read-only. That is how the layer mechanism marks a parent that
# children need. Each change to it breaks each child, and a removal is the
# largest change. Siblings are fine. Layers BESIDE the folder of this VM in the
# store are the normal layout.
$unsafe = @()
if ($why) { $unsafe += $why }

if (Test-Path $folder) {
    # -Force, so that hidden entries count. This inspection must never remove
    # something and not report it.
    $all = @(Get-ChildItem -LiteralPath $folder -Force -Recurse -ErrorAction SilentlyContinue)
    $bytes = 0
    $all | Where-Object { -not $_.PSIsContainer } | ForEach-Object { $bytes += $_.Length }

    # A read-only .vhdx below here is a frozen layer. The disk of this VM is not
    # one, because the disk of a registered VM is always writable.
    $frozen = @($all | Where-Object {
        -not $_.PSIsContainer -and $_.Extension -eq '.vhdx' -and $_.IsReadOnly
    })
    foreach ($f in $frozen) { $unsafe += "a frozen layer is inside it: $($f.FullName)" }

    # The folder of another VM below this one goes too. A layer.json beside a
    # disk marks both layers and VMs. Thus a subfolder with one belongs to
    # something else.
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
# This side repeats the refusal, and does not trust the caller. Inspect and
# delete are two crossings of the boundary, and all can change between them.
# This test is the one that decides, and the exit code comes from it.
if ($unsafe.Count -gt 0) {
    Fail 12 "refusing to delete '$Vm': $($unsafe -join '; ')"
}

# Stop first, through the API, because the guest goes away anyway. `dr-forge
# down` does a clean shutdown. Here, a wait for one only delays the removal of
# the disk. The daemon refuses to delete a VM that runs.
if ($st.running) {
    Write-Output 'phase=stopping'
    try { $null = Asb POST "/vms/$Vm/stop" } catch { }
    $t0 = Get-Date
    do {
        Start-Sleep -Seconds 3
        try { $st = Asb GET "/vms/$Vm" } catch { break }
    } while ($st.running -and ((Get-Date) - $t0).TotalSeconds -lt 120)
    if ($st.running) { Fail 13 "'$Vm' did not stop, so it was not deleted." }
}

# POST /vms/<name>/delete, which is the same shape as /start and /stop.
#
# IT IS NOT `DELETE /vms/<name>`. That was the first guess of this script. The
# daemon answered **405 Method Not Allowed**: the route exists, but the verb
# does not. No Allow header told which verb works. Each probe of a /delete
# sub-route got a 404, because this server answers a wrong method on a sub-route
# with 404, not 405. Thus a probe cannot find it.
#
# The authority is the client that AppSandbox ships, at
# C:\AppSandbox\headless-api\asb.py:
#
#     def delete_vm(self, name): return self._req("POST", "/vms/%s/delete" % name)
#
# The README beside it documents `delete_vm(name)` as "remove the VM and its
# disk (refused 409 while building)". Before you add another call, read it. Do
# not guess from the shape of the calls here.
Write-Output 'phase=deleting'
try {
    $null = Invoke-RestMethod -Uri "$($h.endpoint)/v1/vms/$Vm/delete" -Method POST `
        -Body '{}' -ContentType 'application/json' -TimeoutSec 300 `
        -Headers @{ Authorization = "Bearer $($h.token)" }
} catch {
    # 409 is a STATE conflict, not a refusal of the request. The usual one is a
    # VM that is still building. Say so, because the fix is to wait, not to look
    # for a fault.
    $code = 0
    if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
    if ($code -eq 409) {
        Fail 13 "'$Vm' cannot be deleted yet. The daemon reports a state conflict (409). For a delete, that means that it is still building. Wait until it is complete, then run again."
    }
    Fail 13 "the daemon refused to delete '$Vm': $($_.Exception.Message)"
}

# Proved by effect. A 200 from a young API is not the same as a VM that is gone.
Start-Sleep -Seconds 2
$still = $true
try { $null = Asb GET "/vms/$Vm" } catch { $still = $false }
if ($still) { Fail 13 "the daemon still reports '$Vm' after the delete." }
Write-Output 'phase=gone'

# THE HOST KEY GOES WITH THE VM. It is filed under the NAME of the VM. Thus it
# stays after the machine, and breaks the next VM with that name (see
# hostkey.ps1). Last, and never fatal. The VM is already gone here, and an old
# line in known_hosts does not make the delete a failure. With no key, it says
# nothing, because "hostkey=" alone tells nothing.
$cleared = Clear-ForgeHostKey $Vm
if ($cleared) { Write-Output "hostkey=$cleared" }
exit 0
