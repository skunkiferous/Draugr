# reduce-churn.ps1: stop the writes of Windows into a differencing disk that
# give nothing.
#
# ==> RUN THIS IN THE GUEST, elevated. An ssh session already is elevated. <==
#
# WHY WRITES COST SO MUCH IN A LAYERED VM. A differencing child grows by each
# block that was ever WRITTEN, and never gives one back. If you delete a 10 GB
# file in the guest, the child keeps its size. The block is **2 MB**. Thus a
# change of 4 KB to a file in the parent costs 2 MB. Thus small scattered writes
# become very much larger.
#
# A TEST INSIDE `ue-427-test` showed this, and proved the obvious theory wrong.
# Its child was 31.0 GiB over a parent of 21.6 GiB. But all that was written
# since the creation of the VM was only **6.63 GiB in 3,907 files**. The missing
# ~24 GiB was amplification: a few thousand scattered file writes, and the own
# metadata of NTFS ($MFT, $LogFile, $Bitmap), rewritten all the time in places
# far apart.
#
# THUS THE TARGET IS SCATTERED FREQUENT WRITES, NOT LARGE FILES. The same test
# found no hiberfil.sys (an AppSandbox guest never creates one), and
# pagefile.sys at 512 MB, with a peak use of 71 MB. The first version of this
# script was for those two files, and neither was a problem. The order below
# follows what the test really showed.
#
#   hiberfil.sys   40-75% of RAM, written at each hibernate, and a VM never hibernates.
#                  Pure waste: nothing ever reads this file.
#   pagefile.sys   paging rewrites it all the time. Thus its blocks go into the child early,
#                  and stay there forever.
#
# WHAT SYSTEM MANAGEMENT REALLY DOES. The obvious claim is wrong, and this
# comment had it until a correction. Microsoft documents no single formula. The
# minimum follows the crash-dump configuration, and the growth after that
# follows the commit charge. After the commit charge passes about 90% of the
# commit limit, the file grows. With the default automatic dump, it starts
# SMALL, and grows to min(RAM, 32 GB) only after a second crash within four
# weeks. "1.5x RAM" and "3x RAM" are troubleshooting guesses that became
# folklore. A TEST on the host: 127.9 GiB of RAM, system-managed, 8192 MB
# allocated, peak use 0 MB. That is about a sixteenth of RAM.
#
# THUS THE REASON FOR A FIXED RANGE IS NOT THAT SYSTEM MANAGEMENT WASTES SPACE.
# The reason is that the growth has no limit in principle, and each block that
# it touches is permanent in a differencing child. A floor keeps a small guest
# working. A ceiling limits the worst case. The same value for initial and
# maximum is worse than both. It makes the whole file exist, also for a guest
# that never needs it.
#
# WHAT THIS CANNOT DO. It stops the growth, but cannot undo it. Blocks already
# in a differencing child stay there until the chain is flattened, or the VM is
# built again. Thus a run on a VM that already grew is useful, because it stops
# the growth. But it frees nothing.
#
# IT IS IDEMPOTENT. Each step reads the current state first, and says so.
#
#   -PageFileInitialMb <n>  the floor. 0 does not touch the pagefile.
#   -PageFileMaxMb <n>      the ceiling. Must be at least the floor.
param(
    [int]$PageFileInitialMb = 0,
    [int]$PageFileMaxMb     = 0,
    [string]$NoScanFile     = ''
)
if ($PageFileInitialMb -gt 0 -and $PageFileMaxMb -lt $PageFileInitialMb) {
    Write-Host 'reduce-churn.ps1: -PageFileMaxMb is below -PageFileInitialMb' -ForegroundColor Red
    exit 2
}

$ErrorActionPreference = 'Continue'
$changed = $false
# SEPARATE from $changed, because the two halves differ. Hibernation off deletes
# hiberfil.sys at once, but a pagefile resize does nothing until the guest
# restarts. One marker for both advises a reboot for a change that already
# happened.
$rebootNeeded = $false

function Say([string]$m) { Write-Host "  $m" }

# --- scheduled defrag ----------------------------------------------------------------------
# THE WORST THING THAT CAN RUN ON A DIFFERENCING DISK. Defrag rewrites large
# parts of the volume to make files contiguous. Each block that it touches goes
# into the child, for an order that the guest cannot change. The real layout is
# the VHDX chain of the host. Pure cost, and it is scheduled by default.
$defragPath = '\Microsoft\Windows\Defrag\'
$defrag = Get-ScheduledTask -TaskName 'ScheduledDefrag' -TaskPath $defragPath -ErrorAction SilentlyContinue
if (-not $defrag) {
    Say 'scheduled defrag: no such task'
} elseif ($defrag.State -eq 'Disabled') {
    Say 'scheduled defrag: already disabled'
} else {
    $null = Disable-ScheduledTask -TaskName 'ScheduledDefrag' -TaskPath $defragPath -ErrorAction SilentlyContinue
    $now = Get-ScheduledTask -TaskName 'ScheduledDefrag' -TaskPath $defragPath -ErrorAction SilentlyContinue
    if ($now -and $now.State -eq 'Disabled') {
        $changed = $true
        Say 'scheduled defrag: disabled'
    } else {
        Say "scheduled defrag: NOT disabled (state $($now.State))"
    }
}

# --- SysMain -------------------------------------------------------------------------------
# Superfetch writes prefetch and trace data all the time, in small scattered
# pieces, to predict program starts that a build VM does not make. The 2 MB
# block punishes exactly that pattern.
$sm = Get-Service -Name SysMain -ErrorAction SilentlyContinue
if (-not $sm) {
    Say 'SysMain: not present'
} else {
    $mode = (Get-WmiObject Win32_Service -Filter "Name='SysMain'").StartMode
    if ($mode -eq 'Disabled' -and $sm.Status -eq 'Stopped') {
        Say 'SysMain: already stopped and disabled'
    } else {
        # Disabled FIRST, so that the service control manager cannot restart it
        # before the next line runs.
        Set-Service -Name SysMain -StartupType Disabled -ErrorAction SilentlyContinue
        Stop-Service -Name SysMain -Force -ErrorAction SilentlyContinue
        $sm = Get-Service -Name SysMain -ErrorAction SilentlyContinue
        $changed = $true
        Say "SysMain: disabled, now $($sm.Status)"
    }
}

# --- System Restore ------------------------------------------------------------------------
# Shadow copies are churn at the block level, and a rollback mechanism INSIDE a
# VM that already has one. The own baseline and rollback of the forge work on
# the whole machine, from outside it (docs/FORGE.md, "Backup and rollback").
# ue-427-test had two shadow copies, and about 1 GiB written into System Volume
# Information since the creation of the VM.
$shadows = @(Get-WmiObject Win32_ShadowCopy -ErrorAction SilentlyContinue)
$srKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
$srInterval = $null
try { $srInterval = (Get-ItemProperty -Path $srKey -Name RPSessionInterval -ErrorAction Stop).RPSessionInterval }
catch { $srInterval = $null }

if ($shadows.Count -eq 0 -and $srInterval -eq 0) {
    Say 'system restore: already off. No shadow copies'
} else {
    # Disable-ComputerRestore removes the restore points of the drive. The code
    # removes each shadow copy that stays, because a disabled feature that holds
    # a GiB still holds it.
    try { Disable-ComputerRestore -Drive 'C:\' -ErrorAction Stop } catch { Say "system restore: $($_.Exception.Message)" }
    foreach ($s in $shadows) {
        try { $s.Delete() } catch { }
    }
    $left = @(Get-WmiObject Win32_ShadowCopy -ErrorAction SilentlyContinue)
    $changed = $true
    Say ("system restore: disabled. Shadow copies {0} -> {1}" -f $shadows.Count, $left.Count)
}

# --- hibernation ---------------------------------------------------------------------------
# Kept, although the test found no hiberfil.sys on an AppSandbox guest. It costs
# one registry read. A guest that creates one pays 40-75% of RAM for a file that
# nobody reads. Insurance, not a fix for a seen problem. Read from the registry,
# not parsed from `powercfg /a`. The words of that output depend on the
# language, and changed between releases. This value is the switch itself.
$powerKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Power'
$hib = $null
try { $hib = (Get-ItemProperty -Path $powerKey -Name HibernateEnabled -ErrorAction Stop).HibernateEnabled }
catch { $hib = $null }

if ($hib -eq 0) {
    Say 'hibernation: already off'
} else {
    # powercfg, not the registry value, because powercfg off DELETES
    # hiberfil.sys. The flag alone leaves the file there, and the file is the
    # whole cost.
    $out = & powercfg.exe /hibernate off 2>&1
    $after = $null
    try { $after = (Get-ItemProperty -Path $powerKey -Name HibernateEnabled -ErrorAction Stop).HibernateEnabled }
    catch { $after = $null }
    if ($after -eq 0) {
        $changed = $true
        Say 'hibernation: turned off, and hiberfil.sys goes with it'
    } else {
        Say "hibernation: NOT turned off. $(($out | Out-String).Trim())"
    }
}

# Always reported, because "is it gone?" is the question for the disk, and the
# registry flag is only the intent.
$hf = 'C:\hiberfil.sys'
if (Test-Path -LiteralPath $hf) {
    $sz = (Get-Item -LiteralPath $hf -Force).Length / 1GB
    Say ("hiberfil.sys: still present, {0:N1} GiB" -f $sz)
} else {
    Say 'hiberfil.sys: not present'
}

# --- the pagefile --------------------------------------------------------------------------
# WMI, not CIM, for the write. A set of AutomaticManagedPagefile and a new
# Win32_PageFileSetting have decades of documented behavior. The guest runs
# Windows PowerShell 5.1, where Get-WmiObject is present and supported.
if ($PageFileInitialMb -le 0) {
    Say 'pagefile: not changed'
} else {
    $cs = Get-WmiObject -Class Win32_ComputerSystem
    $cur = @(Get-WmiObject -Class Win32_PageFileSetting)
    $want = "C:\pagefile.sys"

    # Already exactly as asked? Then nothing changes. "Already" must mean all
    # three things. Otherwise a second run reports a change that it did not
    # make.
    $match = $cur | Where-Object {
        $_.Name -ieq $want -and $_.InitialSize -eq $PageFileInitialMb `
            -and $_.MaximumSize -eq $PageFileMaxMb
    }
    if ((-not $cs.AutomaticManagedPagefile) -and $match -and $cur.Count -eq 1) {
        Say "pagefile: already $PageFileInitialMb-$PageFileMaxMb MB"
    } else {
        if ($cs.AutomaticManagedPagefile) {
            $cs.AutomaticManagedPagefile = $false
            $null = $cs.Put()
            Say 'pagefile: system management turned off'
        }
        # Each value for another volume goes. A second pagefile on a disk that
        # this VM does not have does nothing. A second one on C: next to ours
        # doubles the cost.
        foreach ($p in $cur) {
            if ($p.Name -ine $want) { Say "pagefile: removing a setting for $($p.Name)"; $p.Delete() }
        }
        $existing = @(Get-WmiObject -Class Win32_PageFileSetting | Where-Object { $_.Name -ieq $want })
        if ($existing.Count -gt 0) {
            $existing[0].InitialSize = $PageFileInitialMb
            $existing[0].MaximumSize = $PageFileMaxMb
            $null = $existing[0].Put()
        } else {
            $null = Set-WmiInstance -Class Win32_PageFileSetting -Arguments @{
                Name = $want; InitialSize = $PageFileInitialMb; MaximumSize = $PageFileMaxMb }
        }
        $changed = $true
        $rebootNeeded = $true
        Say "pagefile: $PageFileInitialMb-$PageFileMaxMb MB. It applies at the next boot"
    }

    # The size of the file NOW, so that you see the difference between intent
    # and effect. The running pagefile keeps its old size until the guest
    # restarts.
    $pf = 'C:\pagefile.sys'
    if (Test-Path -LiteralPath $pf) {
        try {
            $sz = (Get-Item -LiteralPath $pf -Force).Length / 1GB
            Say ("pagefile.sys: {0:N1} GiB on disk right now" -f $sz)
        } catch { Say 'pagefile.sys: present (in use, size not readable)' }
    }
}

# --- Defender exclusions -------------------------------------------------------------------
# This script does NOT decide this. Real-time protection reads each file that a
# build writes and reads back. That is the scattered-write pattern that a 2 MB
# differencing block punishes most. But only the project knows which trees are
# build output, and which need a scan. Thus the paths come from
# DRAUGR_FORGE_NOSCAN, and an empty list does not change Defender.
#
# IT ONLY ADDS. It does not touch exclusions that it did not create. A setup
# script must not remove an exclusion that somebody added, only because a
# configuration file does not have it.
if (-not $NoScanFile) {
    Say 'defender exclusions: none requested'
} elseif (-not (Test-Path -LiteralPath $NoScanFile)) {
    Say "defender exclusions: no list at $NoScanFile"
} else {
    # Filtered, because in PowerShell @($null).Count is 1. Thus an EMPTY
    # exclusion list looks like one blank entry. A test showed this: a probe
    # reported "1 exclusion" for a guest with none. Without the filter, the code
    # compares with that false entry, and a missing real path can look
    # present.
    $wanted = @(Get-Content -LiteralPath $NoScanFile | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $have = @((Get-MpPreference).ExclusionPath | Where-Object { $_ })
    if ($wanted.Count -eq 0) {
        Say 'defender exclusions: the list is empty'
    } elseif ($wanted -contains '*') {
        # OFF, not narrower. The list is also the switch. One key with a special
        # value is easier to keep correct than two keys that can disagree, and
        # "*" cannot be a path.
        if ($wanted.Count -gt 1) {
            Say 'defender: the list contains "*", so the other entries have nothing more to exclude'
        }
        $st = Get-MpComputerStatus
        if (-not $st.RealTimeProtectionEnabled) {
            Say 'defender: real-time protection already off'
        } else {
            try { Set-MpPreference -DisableRealtimeMonitoring $true -ErrorAction Stop }
            catch { Say "defender: the call failed. $($_.Exception.Message)" }
            # BY EFFECT, and that is important. On Windows 11, Tamper Protection
            # is ON by default and refuses this change, but the cmdlet can
            # return with no error. A report of "disabled" only because the call
            # returned is exactly the false green that this family of scripts
            # often has.
            $st = Get-MpComputerStatus
            if ($st.RealTimeProtectionEnabled) {
                Say 'defender: STILL ON. The call had no effect'
                Say "defender: IsTamperProtected=$($st.IsTamperProtected). If true, that is the reason"
                Say '  turn off Tamper Protection inside the guest, then run dr-forge init again'
            } else {
                $changed = $true
                Say 'defender: real-time protection DISABLED for the whole guest'
                # Said once, here, because later this looks like a bug.
                Say '  Windows can turn it on again after an update. Run init again to turn it off'
            }
        }
    } else {
        $added = 0
        foreach ($p in $wanted) {
            if ($have -contains $p) { Say "defender: already excluded $p"; continue }
            try {
                Add-MpPreference -ExclusionPath $p -ErrorAction Stop
                $added++
                Say "defender: excluded $p"
            } catch {
                Say "defender: could NOT exclude $p. $($_.Exception.Message)"
            }
        }
        if ($added -gt 0) { $changed = $true }
        Say "defender exclusions: $added added, $($wanted.Count - $added) already there"
    }
}

# bin/dr-forge reads this marker to know "applied" from "already was". In all
# other scripts of this family, unknown counts as changed. Thus this always
# prints it explicitly.
if ($changed) { Write-Output 'DRAUGR_CHANGED=1' } else { Write-Output 'DRAUGR_CHANGED=0' }
if ($rebootNeeded) { Write-Output 'DRAUGR_REBOOT=1' } else { Write-Output 'DRAUGR_REBOOT=0' }
exit 0
