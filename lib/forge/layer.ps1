# lib/forge/layer.ps1: build and manage the disk layers of the forge.
#
# ==> YOU DO NOT TYPE THIS. bin/dr-layer is the front end, and gives -Mode and the flags. <==
#
# Adopted from a manually written earlier script. All tests in these comments
# were made with it. See docs/FORGE.md, "The layer mechanism as a command".
#
# WHAT A LAYER IS. A differencing VHDX whose parent is the layer below it. Only
# the TOP disk is ever registered as a VM, so AppSandbox cannot reach the disks
# below. That is important, because a VM delete removes its folder recursively.
#
#   layer-0\disk.vhdx              Windows + the default base
#     \__ layer-1\disk.vhdx        accounts, Visual Studio       frozen
#           \__ layer-2-ue427\disk.vhdx   one engine version     frozen
#                 \__ layer-3-tabulua\disk.vhdx   the work       the VM points here
#
# Layers have NUMBERS, not names for their contents. The number is the depth,
# which is part of the structure. What belongs in each layer is a judgment that
# differs for each person.
#
# HOW A FINISHED BASE BECOMES layer-0. Nobody can guess this part. The last
# step of the build of a base is the DELETE of the VM. The folder of the VM goes
# with it, recursively. Thus build the base where that does no
# damage, and move the disk out before the delete. Never build it in the layer
# store. A VM that points there is one delete from losing all.
#
#   1. build the VM (stage two: `provision`), leaving its disk in a disposable folder
#   2. stop the VM, close AppSandbox
#   3. dr-layer adopt layer-0
#
# `adopt` is one verb, because the order is the whole difficulty, and nobody can
# guess it. First capture the configuration, while the VM block still exists.
# Then move the disk, prove that it still reads, and freeze it. THEN remove the
# registration. Only after that, remove the empty VM folder. A manual run in the
# wrong order loses the configuration that a child needs, or leaves a VM that
# points into the layer store. That is one delete from losing each layer.
#
# The removal of a registration is not a delete. The VM block goes, and each
# file stays. AppSandbox only stops knowing that the disk is there. That ends
# the exposure for good.
#
# WHY NOT APPSANDBOX SNAPSHOTS. Only the FIRST snapshot captures the current
# state of a VM. Each later one is a differencing child of the baseline of the
# first snapshot. Thus a chain of three snapshots is silently three children of
# one baseline. Reported as issue #152, with a fix in PR #199. Until a fix
# ships, layers are made by hand, here.
#
# SIZE, BECAUSE YOU CANNOT UNDO IT. A child inherits the capacity of its parent.
# It can GROW, but never SHRINK. Thus the size of a parent is a FLOOR for each
# layer above it. -DiskGb on `new` makes the child larger. The code refuses each
# size smaller than the parent.
#
# A TEST: three New-VHD -Differencing over a dynamic base of 512 MB, then
# Resize-VHD on the TOP disk to 1 GB. It reports Differencing, Size 1073741824,
# parent L2.vhdx, and all four files are 4 MB on the disk. Thus four levels
# build, thin provisioning holds at each level, and a layer grows without a
# change of its parent. Still not proved: whether HCS BOOTS a guest four levels
# deep, and the cost of reads there.
#
# EXIT CODES, because a front end must know a refusal from a failure:
#   0   done
#   2   the arguments are wrong
#   3   AppSandbox runs, so nothing changed
#   20  a guard stopped it: a writable parent, a layer with children, a name or port in use, a
#       size below the size of the parent
#   21  something that you named does not exist
#   24  elevation was refused

param(
    # -Mode, not a positional verb, for the same reason as each lib/forge/*.ps1.
    # The caller is bin/dr-layer, and a named parameter cannot change position
    # silently.
    [ValidateSet('list', 'adopt', 'new', 'freeze', 'thaw', 'drop')]
    [string]$Mode = 'list',

    [string]$Name,                          # the layer, e.g. layer-1. Also the VM name.
    [string]$Parent,                        # a layer name under -Root, or a full .vhdx path
    # WHERE LAYERS LIVE. It must be your FASTEST disk, not your largest. Reads
    # walk the chain. What the top layer does not hold comes from its parent,
    # and so on. Thus the frozen parents are the HOT read path. They hold
    # Windows, Visual Studio, and the engine. On a spinning disk, to save space
    # on an SSD, they slow each read of the project. Archives are the opposite
    # case, and belong on the large slow disk, because nothing reads them until
    # a restore. It must also be outside the own tree of AppSandbox. But NOT
    # because that keeps a layer from a delete. A VM delete removes <the folder
    # of its disk> recursively. Thus the risk follows the VM REGISTRATION, not
    # the path. A base under C:\ForgeLayers with a VM that still points to it is
    # as deletable as one under ProgramData. `freeze -Unregister` ends that. It
    # removes the VM block, and keeps the file. Outside the tree of AppSandbox
    # gives something different and useful. Nothing that AppSandbox does to its
    # OWN directory (uninstall, reset, a future clean-up) can reach a layer that
    # was never in it. This usually comes from DRAUGR_FORGE_LAYERS. bin/dr-layer
    # gives it as -Root only for a set key. Thus the code reports an unset key
    # as the default.
    [string]$Root = 'C:\ForgeLayers',
    [string]$From,                          # the VM block for RAM/cores/GPU/network
    [int]$DiskGb = 0,                       # 0 = the capacity of the parent
    [int]$SshPort = 0,                      # 0 = one above the highest in vms.cfg
    [switch]$Unregister,                    # freeze: also remove the VM block
    [switch]$NoRegister,                    # thaw: clear read-only but add no VM block
    [switch]$Force,                         # thaw: proceed even though a child exists
    [switch]$KeepRegistered,                # new: create the disk, but add no VM block
    [switch]$KeepVmFolder,                  # adopt: keep the empty VM folder
    [switch]$NoElevate,
    # ONLY the elevated restart of this script sets it, never a person. The
    # elevated child writes all its output here, so that the parent can show it.
    # See the elevation block for why that is necessary.
    [string]$TranscriptTo = '',
    [switch]$WhatIfOnly
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# All the code that knows the vms.cfg format, also $cfgPath and $script:carried.
. (Join-Path $PSScriptRoot 'vmscfg.ps1')
# The host key that a VM without a registration leaves, shared with rm.ps1.
# adopt, drop, and rm all leave the same `draugr-<name>` entry, and people use
# layer names again.
. (Join-Path $PSScriptRoot 'hostkey.ps1')

function Say($m)  { Write-Host "`n=== $m ===" -ForegroundColor Cyan }
function Note($m) { Write-Host "  $m" }
function Warn($m) { Write-Host "  $m" -ForegroundColor Yellow }
function Fail($m) { Write-Host "  $m" -ForegroundColor Red }


# WAS -Root REALLY GIVEN? Captured here, at script scope, because
# $PSBoundParameters inside a function belongs to that FUNCTION. There, the
# answer is always "no", for each call of the script. Only here is the truth
# available.
$script:rootGiven = $PSBoundParameters.ContainsKey('Root')

# The console of the elevated child is a SEPARATE WINDOW that closes when the
# script ends. Thus its output, a refusal most of all, dies with it. A
# transcript is the only way back to the parent, because Start-Process does not
# accept -RedirectStandardOutput with -Verb RunAs.
#
# NOT stopped anywhere, on purpose. At the exit of the process, PowerShell
# flushes and closes an open transcript, and this script exits through `exit` in
# a dozen places. A Stop-Transcript at each is a dozen chances to forget one.
if ($TranscriptTo) { try { Start-Transcript -Path $TranscriptTo -Force | Out-Null } catch { } }

# ------------------------------------------------------------------- AppSandbox must be off
# It rewrites vms.cfg at each change. Thus an edit while it runs is lost at its
# next save. When it is closed, each VM is also stopped, because the daemon owns
# them. A freeze needs exactly that anyway.
function Assert-AppSandboxClosed {
    $p = @(Get-Process -Name 'appsandbox' -ErrorAction SilentlyContinue)
    if (-not $p.Count) { return }

    Fail "AppSandbox runs (pid $($p[0].Id)), and overwrites this edit."
    Fail '  Close it, and run this again. The GUI has a window. THE HEADLESS DAEMON HAS NONE.'
    Fail '  That is the difficulty. Its own API shuts it down.'
    Write-Host ''

    # THE DAEMON HAS NO WINDOW, so nobody can follow "close it". The code prints
    # the commands, and does not run them. The stop of a guest is the decision
    # of the user. This script must refuse an edit of vms.cfg below a running
    # daemon. It does not decide the time of a VM stop. A user asked for this,
    # after the close of the only window, with no way to continue.
    #
    # THE ORDER MATTERS, and the API enforces it. POST /v1/shutdown is REFUSED
    # WITH 409 while a VM runs, unless {"force":true}, and that TERMINATES the
    # guests, and does not shut them down. For a disk that becomes a frozen
    # base, a terminated guest is a dirty one. Thus the VMs shut down gracefully
    # first, and then the daemon. See headless-api\asb.py, shutdown_daemon().
    $hostJson = Join-Path $env:ProgramData 'AppSandbox\host.json'
    $running = @()
    $endpoint = 'http://127.0.0.1:8787'
    if (Test-Path $hostJson) {
        try {
            $h = Get-Content $hostJson -Raw | ConvertFrom-Json
            $endpoint = $h.endpoint
            $hdr = @{ Authorization = "Bearer $($h.token)" }
            $running = @((Invoke-RestMethod -Uri "$endpoint/v1/vms" -Headers $hdr -TimeoutSec 10).vms |
                         Where-Object { $_.running } | ForEach-Object { $_.name })
        } catch { }
    }

    # ONE COMMAND, not a recipe. Before, this printed six lines to paste into an
    # elevated PowerShell, and a seventh to undo it. That was tedious, and WRONG
    # about the elevation. The headless API puts the gate on the run of the
    # daemon, not on a call to it. Thus each shutdown step here needs no
    # elevation. Only the --headless restart does. See lib/forge/daemon.ps1, and
    # docs/FORGE.md, "Taking the daemon down is a command".
    Note 'Take it down with:'
    Write-Host ''
    Note '  dr-forge daemon stop'
    Write-Host ''
    if ($running.Count) {
        Note ("{0} runs, and the API refuses a daemon shutdown while a VM runs. Thus that" -f ($running -join ', '))
        Note 'command shuts them down gracefully first, and waits for each one.'
    } else {
        Note 'no VM runs, so the daemon stops directly.'
    }
    Write-Host ''

    # ASKED OF THE PROCESS, not guessed from a list of probable directories. The
    # daemon runs now ($p[0] above is it), so its own image path is the answer.
    # That is also correct on a machine where AppSandbox is in an unexpected
    # place. For a process that this account cannot open, .Path can be empty, so
    # the default install is the fallback. A list of local paths is neither.
    $exe = $p[0].Path
    if (-not $exe -or -not (Test-Path $exe)) {
        $exe = @('C:\AppSandbox\AppSandbox.exe') |
               Where-Object { Test-Path $_ } | Select-Object -First 1
    }
    # The code still finds the exe here, but only to say whether the way back
    # exists. You must know about a host without a findable AppSandbox BEFORE
    # the daemon stops.
    if ($exe) {
        Note 'and to start it again after you finish here:'
        Note '  dr-forge daemon start'
        Note "  ($exe --headless, the one step that shows a UAC question)"
    } else {
        Warn 'this code cannot find AppSandbox.exe, so its next start needs a path.'
    }
    exit 3
}

# ------------------------------------------------------------------------------ elevation
function Test-Elevated {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}
# THE CODE TESTS THE DAEMON BEFORE IT ASKS FOR ELEVATION. That is a change from
# the original script. Get-Process needs no elevation, but the restart below
# shows a UAC question. In the original order, you accepted a question, and then
# heard that AppSandbox ran and nothing happened. A refusal after a question
# teaches people to click through questions. --dry-run writes nothing, so it
# does not need a stopped daemon. Its main value is a rehearsal of a layer while
# the forge still runs.
if ($Mode -ne 'list' -and -not $WhatIfOnly) { Assert-AppSandboxClosed }

# Without elevation, New-VHD, Get-VHD, and Resize-VHD all answer "You do not
# have the required permission" (a test showed this). The message names the
# computer, not the cmdlet. Thus it looks like a policy problem, not like a
# missing UAC question.
if ($Mode -ne 'list' -and -not (Test-Elevated) -and -not $NoElevate) {
    Note 'the VHD cmdlets need elevation. Asking for it once (accept the UAC question).'
    # -Root goes through the GENERAL loop below. It is not forced in here. If
    # the code always gives it, the elevated child thinks that the user gave it.
    # The child prints what the user reads, so it reports a default as a choice.
    # The own default of the child is the same literal in this file. Thus,
    # without a value from the user, its omission is exact.
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"",
           '-Mode', $Mode, '-NoElevate')
    foreach ($p in @('Root', 'Name', 'Parent', 'From')) {
        if ($PSBoundParameters.ContainsKey($p)) { $a += @("-$p", "`"$($PSBoundParameters[$p])`"") }
    }
    foreach ($p in @('DiskGb', 'SshPort')) {
        if ($PSBoundParameters.ContainsKey($p)) { $a += @("-$p", $PSBoundParameters[$p]) }
    }
    foreach ($p in @('Unregister', 'KeepRegistered', 'KeepVmFolder', 'WhatIfOnly')) {
        if ($PSBoundParameters.ContainsKey($p)) { $a += "-$p" }
    }
    # A TEST SHOWED THIS. Without the three steps below, a refusal of the
    # elevated child is not visible here, and the caller runs the next command
    # as if this one worked. See the transcript note near the top of the file.
    $log = Join-Path $env:TEMP "dr-layer-$(Get-Date -Format 'yyyyMMdd-HHmmss-fff').log"
    $a += @('-TranscriptTo', "`"$log`"")
    try {
        $proc = Start-Process powershell.exe -Verb RunAs -Wait -PassThru -ArgumentList ($a -join ' ')
    } catch {
        # A refusal of the UAC question throws, and returns no code. The plain
        # exception looks like a script fault, not like the decision of a
        # person.
        Fail 'elevation was refused, so nothing happened.'
        exit 24
    }

    if (Test-Path $log) {
        # The header, footer, and prompt echoes of the transcript are noise. The
        # lines between are what the child said. Filtered by pattern, not by
        # line number, because a header with a new field must not hide the first
        # line of real output.
        #
        # THE PROMPT ECHOES NEED STATE. That is why this is a foreach, and not
        # one more clause in a Where-Object. A transcript records each command
        # as a "PS>" line. At the record of the success state of the pipeline,
        # the host writes `PS>$global:?` and its result. Thus a clean run
        # printed this into the console of the caller (a test showed this):
        #
        #     start AppSandbox and 'layer-2-ue41' will be in the list.
        #   PS>$global:?
        #   True
        #
        # The code removes the True/False ONLY directly after that line. A
        # script can print a bare "True". A filter that removes each one hides
        # real output, only to clean an artifact.
        $skipNextBool = $false
        foreach ($line in (Get-Content $log)) {
            if ($line -match '^\*{5,}$' -or
                $line -match '^(Windows PowerShell transcript|Start time:|End time:|Username:|RunAs User:|Configuration Name:|Machine:|Host Application:|Process ID:|PSVersion:|PSEdition:|PSCompatibleVersions:|BuildVersion:|CLRVersion:|WSManStackVersion:|PSRemotingProtocolVersion:|SerializationVersion:|Transcript started)') {
                continue
            }
            if ($line -match '^PS>') {
                # The boolean result follows `PS>$global:?`. Each other PS> line
                # is only the echo of a command.
                $skipNextBool = ($line -match '^PS>\$global:\?\s*$')
                continue
            }
            if ($skipNextBool) {
                $skipNextBool = $false
                if ($line -match '^(True|False)\s*$') { continue }
            }
            Write-Host $line
        }
        Remove-Item $log -Force -ErrorAction SilentlyContinue
    } else {
        Warn "the elevated run left no transcript at $log. Its output is lost."
    }

    # Passed on, not hidden. `return` here reports success for a child that
    # refused. That is the other half of how one unseen failure became four.
    if ($proc.ExitCode -ne 0) { Fail "the elevated run exited $($proc.ExitCode)." }
    exit $proc.ExitCode
}

function Resolve-LayerDisk([string]$nameOrPath) {
    if ($nameOrPath -match '\.vhdx$') { return $nameOrPath }
    Join-Path (Join-Path $Root $nameOrPath) 'disk.vhdx'
}

# ------------------------------------------------------------------ what a layer remembers
# WHY A SIDECAR FILE. `new` copies RamMB, CpuCores, GpuMode, GpuName, and
# NetworkMode from a VM BLOCK. But the purpose of a frozen layer is that no VM
# block points to it. Thus the configuration that a child must inherit
# disappears at exactly the time that the base becomes a base. -From exists to
# hide that. If you forget it, it fails SILENTLY. The fallback is "the first
# VM block in vms.cfg", an unrelated VM, and its GPU and network values go into
# the layer without a message. A record next to the disk makes the chain
# describe itself, and -From becomes an override, not a thing to remember.
#
# A layer that differs from its parent in GpuMode or NetworkMode behaves
# differently from its base. That kind of difference shows three steps away.
function Get-LayerInfoPath([string]$diskPath) {
    Join-Path (Split-Path $diskPath -Parent) 'layer.json'
}
function Save-LayerInfo([string]$diskPath, $src, [string]$why) {
    $o = [ordered]@{}
    foreach ($k in $script:carried) { $o[$k] = Get-Val $src $k }
    $o['source'] = Get-Val $src 'Name'
    $o['when']   = (Get-Date).ToString('s')
    $o['why']    = $why
    $f = Get-LayerInfoPath $diskPath
    if ($WhatIfOnly) { Note "would record the inherited configuration in $f"; return }
    [IO.File]::WriteAllText($f, ($o | ConvertTo-Json))
    Note "configuration recorded in $(Split-Path $f -Leaf)"
}
function Read-LayerInfo([string]$diskPath) {
    $f = Get-LayerInfoPath $diskPath
    if (-not (Test-Path $f)) { return $null }
    try { return (Get-Content $f -Raw | ConvertFrom-Json) } catch { return $null }
}
# ------------------------------------------------------ is -Root the place you meant?
# A DEFAULT DECIDES WHERE A LAYER GOES, not the command. Without a value, -Root
# is C:\ForgeLayers. Thus `adopt -Name layer-0` names no destination. That is
# good until it is wrong. New-Item -Force builds a whole missing chain without a
# message. Thus a -Root with a typo is created as easily as the correct one.
# `adopt` then moves the ONLY copy of a base into it.
#
# The depth is the signal. A missing layer store is normal at the first use. If
# its PARENT is also missing, it is probably not the path that you meant. The
# same reason as -DiskDir in forge-provision.ps1, where a user asked first. The
# user read the command, and wanted to know how it found the place. That is the
# correct question.
function Show-Root([switch]$Creating) {
    if ($script:rootGiven) {
        Note "root    $Root  (as given)"
    } else {
        Note "root    $Root  (the default: nothing set DRAUGR_FORGE_LAYERS)"
        Note '        --root <path> puts layers in another place for one command,'
        Note '        and DRAUGR_FORGE_LAYERS sets it permanently. It must be outside'
        Note '        the own tree of AppSandbox, and on your fastest volume, not'
        Note '        your largest.'
    }
    if (Test-Path $Root) { return }
    Note ("        it does not exist yet{0}" -f $(if ($Creating) { '. The code creates it' } else { '' }))
    $up = Split-Path $Root -Parent
    if ($up -and -not (Test-Path $up)) {
        Warn "        and its parent, $up, does not exist either. Look at the spelling."
        Warn '        The code creates a -Root with a typo as easily as a correct one, and'
        Warn '        the layer then lives in a place that you did not want.'
    }
}

# ----------------------------------------------------------------- who differences from this
# EACH disk, in any place, that has $disk as its parent. `thaw` and `drop` both
# need this guard, and it must look WIDER THAN -Root.
#
# A TEST on this host: C:\ForgeLayers\layer-1 is the parent of
# D:\ForgeLayers\layer-2-ue411. The previous version of this test (inside
# `drop`) scanned only -Root. Thus `drop -Name layer-1`, with the default -Root
# C:\ForgeLayers, found no children, and removed the parent of each engine layer
# on D:. The guard existed, but looked in one place. One layer store for each
# drive is the normal layout here. The engine layers are the large ones, so they
# go on the large disk.
#
# The code searches three places, because a disk can be in each of them:
#   - -Root, whatever it is in this run.
#   - <drive>\ForgeLayers on each FIXED drive, the convention of this script. Thus it
#     also finds a store on a drive that nobody named.
#   - each VhdxPath in vms.cfg, because a registered disk does not have to be in a layer
#     store. forge-provision.ps1 builds layer-0 in the own directory of AppSandbox, on purpose.
# The code skips removable drives, on purpose. A spin-up of an absent USB disk
# to ask about a parent that nobody put there is a slow way to learn nothing.
function Get-FullPath([string]$p) {
    try { return [IO.Path]::GetFullPath($p) } catch { return $p }
}
function Get-LayerChildren([string]$disk) {
    $disk = Get-FullPath $disk
    $stores = @($Root)
    foreach ($d in [IO.DriveInfo]::GetDrives()) {
        if ($d.DriveType -eq 'Fixed') { $stores += (Join-Path $d.Name 'ForgeLayers') }
    }
    $disks = @()
    foreach ($r in ($stores | Select-Object -Unique)) {
        if (-not (Test-Path $r)) { continue }
        foreach ($d in (Get-ChildItem $r -Directory -ErrorAction SilentlyContinue)) {
            $disks += (Join-Path $d.FullName 'disk.vhdx')
        }
    }
    foreach ($b in $vmBlocks) { $v = Get-Val $b 'VhdxPath'; if ($v) { $disks += $v } }

    $found = @()
    foreach ($other in ($disks | ForEach-Object { Get-FullPath $_ } | Select-Object -Unique)) {
        # -ieq, not -eq. These paths come from three sources: a parameter, a
        # directory walk, and a configuration file. Windows ignores case, but
        # the -eq of PowerShell does not. The same reason as the commit "Compare
        # Windows path case-insensitive" in this repo.
        if ($other -ieq $disk -or -not (Test-Path $other)) { continue }
        # A disk that a running VM reads answers with an exception, not a
        # parent. A child that the code cannot ask must NOT be reported as
        # missing. Thus it is listed as unreadable, and the caller decides. This
        # whole function exists to prevent silence here.
        try { $pp = (Get-VHD -Path $other -ErrorAction Stop).ParentPath }
        catch { $found += "$other  (unreadable: $($_.Exception.Message.Split([char]10)[0]))"; continue }
        if ($pp -and (Get-FullPath $pp) -ieq $disk) { $found += $other }
    }
    # The @() at the call is necessary. One child from here arrives as a bare
    # string, and .Count on a string is $null.
    $found
}

function Get-Chain([string]$disk) {
    $chain = @()
    $p = $disk
    while ($p -and (Test-Path $p)) {
        $v = Get-VHD -Path $p
        $chain += [pscustomobject]@{
            Path = $p; Type = $v.VhdType
            SizeGb = [math]::Round($v.Size / 1GB)
            OnDiskGb = [math]::Round($v.FileSize / 1GB, 2)
            ReadOnly = (Get-Item $p -Force).IsReadOnly
        }
        $p = $v.ParentPath
    }
    $chain
}

# =========================================================================== list
if ($Mode -eq 'list') {
    Say 'registered VMs'
    foreach ($b in (Read-Cfg | Where-Object { $_.Header -eq 'VM' })) {
        $n = Get-Val $b 'Name'; $d = Get-Val $b 'VhdxPath'
        Note ("{0,-16} ssh:{1,-6} {2} GB  {3}" -f $n, (Get-Val $b 'SshPort'), (Get-Val $b 'HddGB'), $d)
        if ((Test-Elevated) -and (Test-Path $d)) {
            foreach ($c in (Get-Chain $d)) {
                Note ("      {0,-12} {1,4} GB cap, {2,7} GB used{3}  {4}" -f $c.Type, $c.SizeGb,
                      $c.OnDiskGb, $(if ($c.ReadOnly) { ', frozen' } else { '' }), (Split-Path $c.Path -Parent))
            }
        }
    }
    Say 'layers'
    Show-Root
    if (-not (Test-Path $Root)) { Note '(none yet)'; return }
    foreach ($d in (Get-ChildItem $Root -Directory | Sort-Object Name)) {
        $disk = Join-Path $d.FullName 'disk.vhdx'
        if (-not (Test-Path $disk)) { Note "$($d.Name)  (no disk.vhdx)"; continue }
        $i = Get-Item $disk -Force
        Note ("{0,-20} {1,7} GB on disk{2}" -f $d.Name, [math]::Round($i.Length / 1GB, 2),
              $(if ($i.IsReadOnly) { '  frozen' } else { '  WRITABLE' }))
    }
    # ONE ROOT IS NOT EACH ROOT, and nothing above says so. When layers are on
    # two volumes (the usual case: a base on the fast disk, and the engine
    # layers on the large one), no single run of this command shows all. The
    # list looks complete in both cases. Said after the layers, not next to the
    # root, because it is about what is MISSING from the list above.
    Note 'this is one root. This list does not show layers under another root:'
    Note '        dr-layer list --root <path>'
    if (-not (Test-Elevated)) { Warn 'run elevated, to see each chain and its parents.' }
    return
}

if (-not $Name) { Fail "-Name is required for '$Mode'."; exit 2 }
# Tested again, and not without a reason. The first test was before the UAC
# question, and somebody can start a daemon while that question is on the
# screen. The edit depends on this test.
if (-not $WhatIfOnly) { Assert-AppSandboxClosed }
# @() IS NECESSARY. When a function returns an array with one element,
# PowerShell unrolls it. Thus, for a vms.cfg with one block, `$cfg = Read-Cfg`
# gives a bare PSCustomObject. `adopt` leaves exactly that after it removes the
# registration of the last VM. `$cfg += <block>` in `new` then failed with "does
# not contain a method named 'op_Addition'", after the code already wrote the
# child disk and its layer.json. A TEST SHOWED THIS, at the build of layer-1 on
# a newly adopted layer-0.
$cfg = @(Read-Cfg)
$vmBlocks = @($cfg | Where-Object { $_.Header -eq 'VM' })

# ========================================================================= adopt
# Make the disk of a finished VM into a frozen layer, in the order that keeps it
# safe all the time. A manual version of this step needs facts that
# nobody must have to know. The configuration must be captured BEFORE the
# rewrite of vms.cfg. The move must come before the freeze. A removal of the
# registration is not the same as a delete.
if ($Mode -eq 'adopt') {
    if (-not $Name) { Fail '-Name is required: the VM to adopt. It becomes the layer.'; exit 2 }
    $owner = @($vmBlocks | Where-Object { (Get-Val $_ 'Name') -eq $Name })
    if (-not $owner) {
        Fail "no VM called '$Name' in vms.cfg."
        Fail "  registered: $(($vmBlocks | ForEach-Object { Get-Val $_ 'Name' }) -join ', ')"
        exit 21
    }
    $src  = $owner[0]
    $from = Get-Val $src 'VhdxPath'
    if (-not $from)             { Fail "'$Name' has no VhdxPath in vms.cfg."; exit 21 }
    if (-not (Test-Path $from)) { Fail "'$Name' points to $from, which is not there."; exit 21 }

    $dir   = Join-Path $Root $Name
    $disk  = Join-Path $dir 'disk.vhdx'
    $inPlace = ($disk -eq $from)
    if (-not $inPlace -and (Test-Path $disk)) {
        Fail "$disk already exists. Refusing to overwrite it."; exit 20
    }

    Say "adopt '$Name' as a layer"
    Show-Root -Creating
    $gb = [math]::Round((Get-Item $from -Force).Length / 1GB, 1)
    Note "disk    $from  ($gb GB on disk)"
    if ($inPlace) {
        # A base built with -DiskDir in the layer store. The docs now advise
        # against that, but some disks already have that layout. For them,
        # there is nothing to move. The freeze and the removal of the
        # registration are the whole job.
        Note 'already under -Root, so there is nothing to move'
    } else {
        $sameVol = (Split-Path $from -Qualifier) -eq (Split-Path $disk -Qualifier)
        Note "move to $disk"
        if ($sameVol) {
            Note '        same volume, so this is a rename. No bytes are copied'
        } else {
            Warn '        ACROSS VOLUMES, so each byte is copied. Allowed, but not fast.'
        }
    }

    if (-not $inPlace -and -not $WhatIfOnly) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
    # The configuration is recorded FIRST, while the VM block is still there to
    # read. After the rewrite, the code must read it from a file that no longer
    # has it.
    Save-LayerInfo $disk $src "adopted from VM '$Name'"

    if ($inPlace) {
        Note 'disk stays where it is'
    } elseif ($WhatIfOnly) {
        Note "would move the disk to $disk"
    } else {
        Move-Item -LiteralPath $from -Destination $disk
        Note 'disk moved'
        # Proof that it survived, before a permanent change of vms.cfg. A move
        # that gives an unreadable file, and a VM without its registration,
        # leaves nothing to go back to.
        try { [void](Get-VHD -Path $disk -ErrorAction Stop); Note 'Get-VHD reads it. The move is good' }
        catch {
            Fail "the code cannot read the moved disk: $($_.Exception.Message)"
            Fail "  It is at $disk, and vms.cfg did NOT change. '$Name' still points to"
            Fail '  the old path. Move it back there before you do anything else.'
            exit 20
        }
    }

    # Frozen before the removal of the registration, not after. While a VM block
    # still names it, only the read-only attribute protects the chain from a
    # careless start.
    if ($WhatIfOnly) {
        Note "would set read-only on $disk"
    } else {
        $i = Get-Item $disk -Force
        if ($i.IsReadOnly) { Note 'already frozen' }
        else { Set-ItemProperty -Path $disk -Name IsReadOnly -Value $true; Note 'read-only set' }
    }

    # Remove the registration: the VM block goes, and each file stays. This ends
    # the exposure. It is not the same as a delete of the VM, which removes the
    # folder too.
    $cfg = @($cfg | Where-Object { $_ -notin $owner })
    Write-Cfg $cfg
    # IN THE SAME MOOD AS THE LINES AROUND IT. Write-Cfg obeys -WhatIfOnly, and
    # says "would back up ... and rewrite". Before, a dry run then told the
    # removal of the registration in the past tense. It reported an act that it
    # did not do, between two lines that both said "would". The first real dry
    # run of adopt found it.
    if ($WhatIfOnly) {
        Note "would remove the registration of '$Name': AppSandbox would no longer know that this disk exists"
    } else {
        Note "'$Name' has no registration now: AppSandbox no longer knows that this disk exists"
        # The VM is gone, so its host key has no use. The disk lives on as a
        # layer, but a child boots with its OWN name, and connects to its own
        # alias. Thus nothing here needs it.
        $hk = Clear-ForgeHostKey $Name
        if ($hk) { Note $hk }
    }

    # The folder of the VM stays, with no disk in it. Its removal is part of the
    # purpose, so the code does it here, and does not leave it as a seventh
    # step. But never while a .vhdx is still in it, for each reason.
    if (-not $inPlace) {
        $old = Split-Path $from -Parent
        # Under -WhatIfOnly, the disk is still in there, because nothing moved.
        # Thus the code counts it as extra, and the dry run reports a refusal
        # that the real run does not make. Do not count exactly that one file,
        # and nothing else.
        $stray = @(Get-ChildItem $old -Filter *.vhdx -Recurse -ErrorAction SilentlyContinue |
                   Where-Object { -not ($WhatIfOnly -and $_.FullName -eq $from) })
        if ($KeepVmFolder) {
            Note "kept     $old (-KeepVmFolder). It holds no disk now"
        } elseif ($stray.Count) {
            Warn "NOT removing $old. It still holds $($stray.Count) .vhdx file(s):"
            foreach ($f in $stray) { Warn "  $($f.FullName)" }
            Warn '  Something else is there. Look before you delete it yourself.'
        } elseif ($WhatIfOnly) {
            Note "would remove $old (now with no disk)"
        } else {
            Remove-Item $old -Recurse -Force
            Note "removed  $old (what the VM left. The disk is in another place now)"
        }
    }

    Write-Host ''
    Note "'$Name' is now a frozen layer at $disk"
    Note "next:  dr-layer new layer-1 --parent $Name"
    Note '       --from is no longer necessary. The configuration is in layer.json next to the disk.'
    return
}

# =========================================================================== new
if ($Mode -eq 'new') {
    if (-not $Parent) { Fail '-Parent is required: a layer name, or a path to a .vhdx.'; exit 2 }
    # A Windows guest name has 15 characters at most (NetBIOS), with letters,
    # digits, and hyphens. The DISK path has no such limit. Only the name of the
    # VM has it.
    if ($Name.Length -gt 15 -or $Name -notmatch '^[A-Za-z0-9-]+$' -or
        $Name -match '^-' -or $Name -match '-$' -or $Name -match '^[0-9]+$') {
        Fail "'$Name' is not a valid Windows guest name (<=15 characters, letters/digits/hyphens,"
        Fail '  not all digits, no hyphen at the start or the end).'
        exit 2
    }
    if ($vmBlocks | Where-Object { (Get-Val $_ 'Name') -eq $Name }) {
        Fail "a VM called '$Name' is already in vms.cfg."; exit 20
    }
    $parentDisk = Resolve-LayerDisk $Parent
    if (-not (Test-Path $parentDisk)) { Fail "no parent disk at $parentDisk"; exit 21 }
    $dir = Join-Path $Root $Name
    $disk = Join-Path $dir 'disk.vhdx'
    if (Test-Path $disk) { Fail "$disk already exists."; exit 20 }

    $pv = Get-VHD -Path $parentDisk
    $parentGb = [math]::Round($pv.Size / 1GB)
    if ($DiskGb -and $DiskGb -lt $parentGb) {
        Fail "-DiskGb $DiskGb is smaller than the $parentGb GB of the parent."
        Fail '  A differencing child can grow, but never shrink. Nothing was created.'
        exit 20
    }

    Say "new layer '$Name' on $Parent"
    Show-Root -Creating
    Note "parent  $parentDisk ($parentGb GB)"
    Note "child   $disk"
    Note "size    $(if ($DiskGb -and $DiskGb -gt $parentGb) { "$DiskGb GB (grown)" } else { "$parentGb GB (inherited)" })"

    # Freeze the parent BEFORE it gets a child. A write to the parent of a
    # differencing child damages the child, silently, and nothing in the stack
    # warns about it.
    if (-not (Get-Item $parentDisk -Force).IsReadOnly) {
        Warn "the parent is still WRITABLE. Freeze it first:  dr-layer freeze $Parent"
        Warn '  A write to a parent after a child exists damages the child, without a message.'
        if (-not $WhatIfOnly) { Fail 'refusing to build on a writable parent.'; exit 20 }
    }

    if ($WhatIfOnly) { Note 'nothing was created (-WhatIfOnly)'; return }

    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    New-VHD -Path $disk -ParentPath $parentDisk -Differencing | Out-Null
    Note 'differencing disk created'
    if ($DiskGb -and $DiskGb -gt $parentGb) {
        Resize-VHD -Path $disk -SizeBytes ([int64]$DiskGb * 1GB)
        Note "grown to $DiskGb GB (the parent did not change: still $parentGb GB)"
    }
    # InstallComplete is next to the disk. Without it, AppSandbox offers to
    # install Windows on top of a disk that already has it.
    [IO.File]::WriteAllText((Join-Path $dir 'vm_state.json'), '{"installComplete":1}')

    if ($KeepRegistered) { Note 'no VM block added (-KeepRegistered)'; return }

    # Copy the values that must match. If the VM of the parent is still
    # registered, take them from it. Otherwise take them from -From, or from the
    # only VM that exists. Most of all GpuMode, GpuName, and NetworkMode: a
    # layer that differs from its parent in those behaves differently from its
    # base.
    if ($From) {
        # Named explicitly, so a miss is an error. A fallback to "some other VM"
        # here copies the wrong GpuMode or NetworkMode into a layer, and says
        # nothing.
        $src = @($vmBlocks | Where-Object { (Get-Val $_ 'Name') -eq $From })
        if (-not $src) { Fail "no VM called '$From' in vms.cfg."; exit 21 }
        $src = $src[0]
    } else {
        $src = @($vmBlocks | Where-Object { (Get-Val $_ 'VhdxPath') -eq $parentDisk }) |
               Select-Object -First 1
        if (-not $src) {
            # The own record of the parent, written by `adopt` or by a previous
            # `new`. It is better than a VM block that only happens to exist,
            # because it describes THIS chain.
            $info = Read-LayerInfo $parentDisk
            if ($info) { $src = ConvertTo-CfgBlock $info "$Parent/layer.json" }
        }
        if (-not $src) {
            # The last choice, with a clear warning. Before, this path copied
            # the GpuMode and NetworkMode of an unrelated VM into a layer, and
            # said nothing.
            $src = $vmBlocks | Select-Object -First 1
            if ($src) {
                Warn "nothing points to the parent, and it has no layer.json. Thus the values"
                Warn "  come from '$(Get-Val $src 'Name')', which possibly has nothing to do"
                Warn '  with this chain. Give -From to select on purpose.'
            }
        }
        if (-not $src) { Fail 'no existing VM block to copy values from. Give -From.'; exit 20 }
    }
    Note "values copied from '$(Get-Val $src 'Name')'"

    $SshPort = Resolve-SshPort $SshPort $vmBlocks
    if ($SshPort -lt 0) { Fail 'that ssh port is already in use. Give --ssh-port.'; exit 20 }
    Note "ssh port $SshPort"

    $hdd = if ($DiskGb) { $DiskGb } else { $parentGb }
    # The child also records what it inherited. Thus the chain still works after
    # the freeze of this layer and the removal of its registration. Without it,
    # each freeze opens the same hole again.
    Save-LayerInfo $disk $src "inherited from '$Parent' when '$Name' was created"

    $cfg += New-VmBlock $Name $src $disk $hdd $SshPort
    Write-Cfg $cfg
    Note "start AppSandbox, and '$Name' is in the list."
    return
}

# =========================================================================== freeze
if ($Mode -eq 'freeze') {
    $disk = Resolve-LayerDisk $Name
    if (-not (Test-Path $disk)) { Fail "no disk at $disk"; exit 21 }
    Say "freeze '$Name'"
    $i = Get-Item $disk -Force
    if ($i.IsReadOnly) {
        Note 'already frozen'
    } elseif ($WhatIfOnly) {
        Note "would set read-only on $disk"
    } else {
        # The read-only ATTRIBUTE is the guard that really works. AppSandbox
        # boots a VM that points to a parent, and that write silently breaks
        # each child below it. A failed open is much better than a damaged
        # chain.
        Set-ItemProperty -Path $disk -Name IsReadOnly -Value $true
        Note "read-only set on $disk"
    }
    $owner = @($vmBlocks | Where-Object { (Get-Val $_ 'VhdxPath') -eq $disk })
    if ($owner -and $Unregister) {
        # Recorded before the removal of the block, for the same reason as in
        # adopt. After the rewrite, there is no place to read these from.
        Save-LayerInfo $disk $owner[0] "recorded when '$(Get-Val $owner[0] 'Name')' lost its registration"
        $cfg = @($cfg | Where-Object { $_ -notin $owner })
        Write-Cfg $cfg
        Note "removed the VM block(s): $(($owner | ForEach-Object { Get-Val $_ 'Name' }) -join ', ')"
    } elseif ($owner) {
        Warn "'$(Get-Val $owner[0] 'Name')' still points to this disk."
        Warn '  Read-only stops a write, but -Unregister removes the risk completely.'
    }
    return
}

# =========================================================================== thaw
# The opposite of `freeze`, and the reason why `freeze` is safe to automate. A
# permanent step that runs without a request needs an undo with one command.
# Otherwise the first wrong guess costs an afternoon of `attrib -r`, and a
# vms.cfg block built again from memory.
#
# WHAT IT UNDOES. `freeze -Unregister` does two things, so this undoes both. It
# clears the read-only attribute, and builds the VM block again from the
# layer.json that freeze recorded. -NoRegister clears only the attribute.
#
# WHAT IT CANNOT UNDO. Know this before you depend on it: bytes that already
# left. A layer that was copied, archived, or shipped exists somewhere else, and
# a thaw of this file changes none of those copies. Thaw is for a layer with a
# mistake that you found before something was built on it. It is not a way to
# edit history.
#
# WHY IT REFUSES FOR A LAYER WITH CHILDREN. A write to the parent of a
# differencing child damages the child, silently, and nothing in the stack
# reports it. `new` refuses to create exactly that layout, from the other side,
# and it is the only purpose of the read-only attribute. -Force exists because
# it is your disk. Its warning is not decoration.
if ($Mode -eq 'thaw') {
    $disk = Get-FullPath (Resolve-LayerDisk $Name)
    if (-not (Test-Path $disk)) { Fail "no disk at $disk"; exit 21 }
    # -Name can be a path. Then the VM name is the name of the layer DIRECTORY,
    # the name that `new` uses. A name from the file gives each VM the name
    # 'disk'.
    $vmName = if ($Name -match '\.vhdx$') { Split-Path (Split-Path $Name -Parent) -Leaf } else { $Name }
    Say "thaw '$vmName'"
    Show-Root

    $kids = @(Get-LayerChildren $disk)
    if ($kids.Count) {
        Fail "$($kids.Count) layer(s) difference from this one:"
        foreach ($k in $kids) { Fail "    $k" }
        Fail '  A write to the parent of a differencing child damages the child, and nothing'
        Fail '  in the stack says so. Drop them first.'
        if (-not $Force) { exit 20 }
        Warn '-Force given: thaw anyway. Each layer in the list above is now suspect. The'
        Warn '  damage gives no message. It shows as a guest that boots wrong.'
    } else {
        Note 'children none. Nothing differences from this disk'
    }

    $i = Get-Item $disk -Force
    if (-not $i.IsReadOnly) {
        Note 'read-only already clear (this layer was not frozen)'
    } elseif ($WhatIfOnly) {
        Note "would clear read-only on $disk"
    } else {
        Set-ItemProperty -Path $disk -Name IsReadOnly -Value $false
        Note "read-only cleared on $disk"
    }

    # WITHOUT THIS, APPSANDBOX OFFERS TO INSTALL WINDOWS on a disk that already
    # has it. On a layer with a provisioned guest and an engine, that is an
    # expensive error. `new` writes it (see the comment there). A layer that
    # somebody moved by hand can easily lose it, and now it matters again.
    $stateFile = Join-Path (Split-Path $disk -Parent) 'vm_state.json'
    if (Test-Path $stateFile) {
        Note 'vm_state.json present'
    } elseif ($WhatIfOnly) {
        Note "would write $stateFile"
    } else {
        [IO.File]::WriteAllText($stateFile, '{"installComplete":1}')
        Note 'vm_state.json written (without it, AppSandbox offers to install Windows again)'
    }

    if ($NoRegister) {
        Note 'no VM block added (-NoRegister). The disk is writable, but nothing can boot it'
        return
    }

    if ($vmBlocks | Where-Object { (Get-Val $_ 'Name') -eq $vmName }) {
        Note "'$vmName' is already in vms.cfg. Not changed"
        return
    }
    $other = @($vmBlocks | Where-Object { (Get-Val $_ 'VhdxPath') -ieq $disk })
    if ($other) {
        Fail "'$(Get-Val $other[0] 'Name')' already points to this disk, with a different name."
        Fail '  With two VM blocks on one disk, two machines write a layer at the same time.'
        Fail '  Nothing was added. Use that VM, or remove its block first.'
        exit 20
    }

    # The values that freeze recorded at its end. That is the reason for
    # layer.json. When a layer becomes a base, the code deletes exactly the VM
    # block that knew its RAM, cores, GPU mode, and network mode.
    $info = Read-LayerInfo $disk
    if (-not $info) {
        Fail 'no layer.json next to the disk, so nothing can build a VM block again.'
        Fail '  The disk IS thawed. Only the registration is missing. Add the block by hand,'
        Fail '  or copy one from a sibling layer, and change Name, VhdxPath, and SshPort.'
        exit 20
    }
    $src = ConvertTo-CfgBlock $info "$vmName/layer.json"

    $SshPort = Resolve-SshPort $SshPort $vmBlocks
    if ($SshPort -lt 0) { Fail 'that ssh port is already in use. Give --ssh-port.'; exit 20 }
    # HddGB from the DISK, not from layer.json. The capacity is the real size of
    # this file. A layer that grew with -DiskGb no longer matches the record of
    # its parent.
    $gb = [math]::Round((Get-VHD -Path $disk).Size / 1GB)

    Note "values restored from layer.json (recorded $($info.when))"
    Note "ssh port $SshPort"
    if ($WhatIfOnly) { Note "would add the VM block '$vmName'"; return }

    $cfg += New-VmBlock $vmName $src $disk $gb $SshPort
    Write-Cfg $cfg
    Note "'$vmName' registered again. Start AppSandbox, and it is in the list"
    Write-Host ''
    Warn 'This layer is WRITABLE and REGISTERED again. Do not build something new on it until'
    Warn '  it is frozen again:'
    Warn "  dr-layer freeze $vmName$(if ($script:rootGiven) { " --root $Root" }) --unregister"
    return
}

# =========================================================================== drop
if ($Mode -eq 'drop') {
    $dir = Join-Path $Root $Name
    $disk = Join-Path $dir 'disk.vhdx'
    if (-not (Test-Path $dir)) { Fail "no layer directory at $dir"; exit 21 }
    Say "drop '$Name'"

    # Refuse to remove a layer that another layer differences from. The test is
    # cheap, and it prevents a failure where no descendant can boot. See
    # Get-LayerChildren for why this no longer scans only -Root.
    $kids = @(Get-LayerChildren $disk)
    if ($kids.Count) {
        Fail "$($kids.Count) layer(s) difference from this one:"
        foreach ($k in $kids) { Fail "    $k" }
        Fail '  After a drop of it, none of them can boot. Drop them first.'
        exit 20
    }
    if ((Get-Item $disk -Force -ErrorAction SilentlyContinue).IsReadOnly) {
        Warn 'this layer is frozen. That usually means that something was built on it.'
        Warn '  Nothing under -Root claims it as a parent, but a disk in another place can.'
    }
    $owner = @($vmBlocks | Where-Object { (Get-Val $_ 'VhdxPath') -eq $disk })
    if ($WhatIfOnly) {
        Note "would remove $dir"
        if ($owner) { Note "would remove the VM block '$(Get-Val $owner[0] 'Name')'" }
        return
    }
    if ($owner) {
        $cfg = @($cfg | Where-Object { $_ -notin $owner })
        Write-Cfg $cfg
        Note "VM block removed: $(($owner | ForEach-Object { Get-Val $_ 'Name' }) -join ', ')"
    }
    Set-ItemProperty -Path $disk -Name IsReadOnly -Value $false -ErrorAction SilentlyContinue
    Remove-Item $dir -Recurse -Force
    Note "removed $dir"
    # ALWAYS, not only after the code found a VM block. A layer comes to `drop`
    # long after its VM block went (`adopt` removes that). With $owner as the
    # condition, the code misses the usual case, exactly the one in the test:
    # the adopt left draugr-forge-0, not a delete.
    $hk = Clear-ForgeHostKey $Name
    if ($hk) { Note $hk }
    return
}
