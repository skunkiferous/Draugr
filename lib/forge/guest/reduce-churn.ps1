# reduce-churn.ps1 - stop Windows writing into a differencing disk for no return.
#
# ==> RUN THIS IN THE GUEST, elevated. An ssh session already is. <==
#
# WHY A LAYERED VM PAYS SO DEARLY FOR WRITES. A differencing child grows by every block ever
# WRITTEN and never gives one back - delete a 10 GB file in the guest and the child stays
# exactly as large - and the block is **2 MB**, so a 4 KB change to a file living in the parent
# costs 2 MB. Scattered small writes are therefore amplified enormously.
#
# MEASURED INSIDE `ue-427-test`, and it overturned the obvious theory. Its child was
# 31.0 GiB over a 21.6 GiB parent, yet everything written since the VM was created came to only
# **6.63 GiB across 3,907 files**. The missing ~24 GiB was amplification: a few thousand
# scattered file writes, plus NTFS's own metadata ($MFT, $LogFile, $Bitmap) rewritten constantly
# in widely separated places.
#
# SO THE TARGET IS SCATTERED FREQUENT WRITES, NOT BIG FILES. The same measurement found
# hiberfil.sys ABSENT - an AppSandbox guest never creates one - and pagefile.sys at 512 MB with
# a peak usage of 71 MB. Both of the files this script was first written for turned out to be
# non-problems; what follows is ordered by what the measurement actually showed.
#
#   hiberfil.sys   40-75% of RAM, written at every hibernate, and a VM never hibernates once.
#                  Pure waste: there is no case in which this file is read.
#   pagefile.sys   paging rewrites it constantly, so its blocks land in the child early and
#                  stay there for good.
#
# WHAT SYSTEM MANAGEMENT ACTUALLY DOES, since the obvious claim is wrong and was in this
# comment until it was corrected: Microsoft documents no single formula. The minimum follows the
# crash-dump setting, and growth after that follows commit charge - the file is enlarged when
# commit charge passes about 90% of the commit limit. With the default automatic dump it starts
# SMALL and only rises to min(RAM, 32 GB) after a second crash within four weeks. "1.5x RAM"
# and "3x RAM" are troubleshooting heuristics that became folklore. MEASURED on the
# host: 127.9 GiB of RAM, system-managed, 8192 MB allocated, peak usage 0 MB - about a
# sixteenth of RAM.
#
# SO THE REASON TO PIN A RANGE IS NOT THAT SYSTEM MANAGEMENT IS PROFLIGATE. It is that growth
# is unbounded in principle while every block it ever touches is permanent in a differencing
# child. A floor keeps a small guest working; a ceiling keeps the worst case bounded. Fixing
# initial and maximum to the same value would be worse than either: it forces the whole file
# into existence whether or not the guest ever needs it.
#
# WHAT THIS CANNOT DO. It stops the growth; it cannot undo it. Blocks already in a differencing
# child are there until the chain is flattened or the VM is rebuilt. So running this on a VM
# that has already grown is worth doing - it stops the bleeding - but it reclaims nothing.
#
# IT IS IDEMPOTENT: every step reads the current state first and says so.
#
#   -PageFileInitialMb <n>  the floor. 0 leaves the pagefile entirely alone.
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
# TRACKED SEPARATELY from $changed, because the two halves differ: turning hibernation off
# deletes hiberfil.sys there and then, while a pagefile resize does nothing until the guest
# restarts. One marker for both would advise a reboot for a change that had already happened.
$rebootNeeded = $false

function Say([string]$m) { Write-Host "  $m" }

# --- scheduled defrag ----------------------------------------------------------------------
# THE WORST THING THAT CAN RUN ON A DIFFERENCING DISK. Defrag rewrites large swathes of the
# volume to make files contiguous - and every block it touches is copied into the child, for a
# contiguity the guest cannot actually influence: the real layout is the host's VHDX chain.
# Pure cost, and it is scheduled by default.
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
        Say "scheduled defrag: could NOT be disabled (state $($now.State))"
    }
}

# --- SysMain -------------------------------------------------------------------------------
# Superfetch writes prefetch and trace data continuously, in small scattered pieces, to predict
# launches that a build VM does not make. Exactly the write pattern the 2 MB block punishes.
$sm = Get-Service -Name SysMain -ErrorAction SilentlyContinue
if (-not $sm) {
    Say 'SysMain: not present'
} else {
    $mode = (Get-WmiObject Win32_Service -Filter "Name='SysMain'").StartMode
    if ($mode -eq 'Disabled' -and $sm.Status -eq 'Stopped') {
        Say 'SysMain: already stopped and disabled'
    } else {
        # Disabled FIRST, so a stop cannot be undone by the service control manager restarting
        # it before the next line runs.
        Set-Service -Name SysMain -StartupType Disabled -ErrorAction SilentlyContinue
        Stop-Service -Name SysMain -Force -ErrorAction SilentlyContinue
        $sm = Get-Service -Name SysMain -ErrorAction SilentlyContinue
        $changed = $true
        Say "SysMain: disabled, now $($sm.Status)"
    }
}

# --- System Restore ------------------------------------------------------------------------
# Shadow copies are block-level churn, and a rollback mechanism INSIDE a VM that already has
# one: the forge's own baseline and rollback work on the whole machine from outside it
# (docs/FORGE.md, "Backup and rollback"). Two shadow copies were found on ue-427-test, with
# about 1 GiB written into System Volume Information since the VM was created.
$shadows = @(Get-WmiObject Win32_ShadowCopy -ErrorAction SilentlyContinue)
$srKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
$srInterval = $null
try { $srInterval = (Get-ItemProperty -Path $srKey -Name RPSessionInterval -ErrorAction Stop).RPSessionInterval }
catch { $srInterval = $null }

if ($shadows.Count -eq 0 -and $srInterval -eq 0) {
    Say 'system restore: already off, no shadow copies'
} else {
    # Disable-ComputerRestore drops the restore points for the drive; any shadow copy it leaves
    # behind is removed explicitly, because a disabled feature holding a GiB is still holding it.
    try { Disable-ComputerRestore -Drive 'C:\' -ErrorAction Stop } catch { Say "system restore: $($_.Exception.Message)" }
    foreach ($s in $shadows) {
        try { $s.Delete() } catch { }
    }
    $left = @(Get-WmiObject Win32_ShadowCopy -ErrorAction SilentlyContinue)
    $changed = $true
    Say ("system restore: disabled; shadow copies {0} -> {1}" -f $shadows.Count, $left.Count)
}

# --- hibernation ---------------------------------------------------------------------------
# Kept although the measurement found hiberfil.sys ABSENT on an AppSandbox guest: it costs one
# registry read, and a guest that ever did create one would pay 40-75% of RAM for a file that
# is never read. Insurance, not a fix for anything seen.
# Read from the registry rather than parsed out of `powercfg /a`, whose wording is localised
# and has changed between releases. This value is the switch itself.
$powerKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Power'
$hib = $null
try { $hib = (Get-ItemProperty -Path $powerKey -Name HibernateEnabled -ErrorAction Stop).HibernateEnabled }
catch { $hib = $null }

if ($hib -eq 0) {
    Say 'hibernation: already off'
} else {
    # powercfg, not the registry value, because turning it off is what DELETES hiberfil.sys;
    # writing the flag alone leaves the file sitting there, which is the whole cost.
    $out = & powercfg.exe /hibernate off 2>&1
    $after = $null
    try { $after = (Get-ItemProperty -Path $powerKey -Name HibernateEnabled -ErrorAction Stop).HibernateEnabled }
    catch { $after = $null }
    if ($after -eq 0) {
        $changed = $true
        Say 'hibernation: turned off, and hiberfil.sys goes with it'
    } else {
        Say "hibernation: could NOT be turned off - $(($out | Out-String).Trim())"
    }
}

# Reported either way, because "is it gone" is the question the disk cares about and the
# registry flag is only the intent.
$hf = 'C:\hiberfil.sys'
if (Test-Path -LiteralPath $hf) {
    $sz = (Get-Item -LiteralPath $hf -Force).Length / 1GB
    Say ("hiberfil.sys: still present, {0:N1} GiB" -f $sz)
} else {
    Say 'hiberfil.sys: not present'
}

# --- the pagefile --------------------------------------------------------------------------
# WMI rather than CIM for the write: setting AutomaticManagedPagefile and creating a
# Win32_PageFileSetting are the two operations with decades of documented behaviour behind
# them, and the guest runs Windows PowerShell 5.1 where Get-WmiObject is present and supported.
if ($PageFileInitialMb -le 0) {
    Say 'pagefile: left alone'
} else {
    $cs = Get-WmiObject -Class Win32_ComputerSystem
    $cur = @(Get-WmiObject -Class Win32_PageFileSetting)
    $want = "C:\pagefile.sys"

    # Already exactly as asked? Then nothing is touched - and "already" has to mean all three
    # things, or a re-run would keep reporting a change it did not make.
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
        # Any setting for another volume goes: a second pagefile on a disk this VM does not
        # have is a setting that does nothing, and one on C: beside ours would double the cost.
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
        Say "pagefile: $PageFileInitialMb-$PageFileMaxMb MB - takes effect at the next boot"
    }

    # The file's size NOW, so the difference between intent and effect is visible rather than
    # assumed: the running pagefile keeps its old size until the guest restarts.
    $pf = 'C:\pagefile.sys'
    if (Test-Path -LiteralPath $pf) {
        try {
            $sz = (Get-Item -LiteralPath $pf -Force).Length / 1GB
            Say ("pagefile.sys: {0:N1} GiB on disk right now" -f $sz)
        } catch { Say 'pagefile.sys: present (in use, size not readable)' }
    }
}

# --- Defender exclusions -------------------------------------------------------------------
# NOT a decision this script makes. Real-time protection reads every file a build writes and
# every file it reads back, which is the scattered-write pattern a 2 MB differencing block
# punishes hardest - but which trees are build output and which are worth scanning is something
# only the project knows, so the paths arrive from DRAUGR_FORGE_NOSCAN and an empty list leaves
# Defender exactly as it was.
#
# IT ONLY ADDS. Exclusions this did not create are left alone: removing one somebody added by
# hand, because it is absent from a config file, is not a thing a setup script should do.
if (-not $NoScanFile) {
    Say 'defender exclusions: none requested'
} elseif (-not (Test-Path -LiteralPath $NoScanFile)) {
    Say "defender exclusions: no list at $NoScanFile"
} else {
    # Filtered because @($null).Count is 1 in PowerShell, so an EMPTY exclusion list reads as
    # one blank entry - which is what made a probe report "1 exclusion" for a guest that had
    # none, measured. Without this, that phantom would be compared against and a
    # real path could look present when it was not.
    $wanted = @(Get-Content -LiteralPath $NoScanFile | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $have = @((Get-MpPreference).ExclusionPath | Where-Object { $_ })
    if ($wanted.Count -eq 0) {
        Say 'defender exclusions: the list is empty'
    } elseif ($wanted -contains '*') {
        # OFF, not narrowed. The list is reused as the switch because one key with a sentinel
        # is less to keep in step than two keys that can disagree - and "*" cannot be a path.
        if ($wanted.Count -gt 1) {
            Say 'defender: the list contains "*", so the other entries have nothing left to exclude'
        }
        $st = Get-MpComputerStatus
        if (-not $st.RealTimeProtectionEnabled) {
            Say 'defender: real-time protection already off'
        } else {
            try { Set-MpPreference -DisableRealtimeMonitoring $true -ErrorAction Stop }
            catch { Say "defender: the call failed - $($_.Exception.Message)" }
            # BY EFFECT, and this is not pedantry: Tamper Protection is ON by default on
            # Windows 11 and refuses this change, while the cmdlet can return without raising
            # anything. Reporting "disabled" on the strength of the call returning is exactly
            # the false green this family of scripts keeps being bitten by.
            $st = Get-MpComputerStatus
            if ($st.RealTimeProtectionEnabled) {
                Say 'defender: STILL ON - the call did not take'
                Say "defender: IsTamperProtected=$($st.IsTamperProtected) - if true, that is why"
                Say '  turn Tamper Protection off inside the guest, then re-run dr-forge init'
            } else {
                $changed = $true
                Say 'defender: real-time protection DISABLED for the whole guest'
                # Said once, here, because it is the kind of thing that looks like a bug later.
                Say '  Windows may re-enable it after an update; re-running init turns it off again'
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
                Say "defender: could NOT exclude $p - $($_.Exception.Message)"
            }
        }
        if ($added -gt 0) { $changed = $true }
        Say "defender exclusions: $added added, $($wanted.Count - $added) already there"
    }
}

# The marker bin/dr-forge reads to tell "applied" from "already was". Unknown counts as
# changed everywhere else in this family, so this is always printed explicitly.
if ($changed) { Write-Output 'DRAUGR_CHANGED=1' } else { Write-Output 'DRAUGR_CHANGED=0' }
if ($rebootNeeded) { Write-Output 'DRAUGR_REBOOT=1' } else { Write-Output 'DRAUGR_REBOOT=0' }
exit 0
