# lib/forge/layer.ps1 - build and manage the forge's disk layers.
#
# ==> NOT MEANT TO BE TYPED. bin/dr-layer is the front end; it passes -Mode and the flags. <==
#
# Adopted from a hand-written predecessor, which is where every
# measurement in these comments was made. docs/FORGE.md, "The layer mechanism as a command".
#
# WHAT A LAYER IS. A differencing VHDX whose parent is the layer below it. Only the TOP disk is
# ever registered as a VM, so everything underneath sits outside AppSandbox's reach - which
# matters, because deleting a VM removes its folder recursively.
#
#   layer-0\disk.vhdx              Windows + the default base
#     \__ layer-1\disk.vhdx        accounts, Visual Studio       frozen
#           \__ layer-2-ue427\disk.vhdx   one engine version     frozen
#                 \__ layer-3-tabulua\disk.vhdx   the work       the VM points here
#
# Layers are NUMBERED, not named for their contents: the number is the depth, which is
# structural, while what belongs in each layer is a judgement that differs per person.
#
# HOW A FINISHED BASE BECOMES layer-0. This is the part no one can guess, because the last step
# of building a base is DELETING the VM - and a VM's folder goes with it, recursively. So the
# base is built where that is harmless and the disk is moved out before the delete. Never build
# it in the layer store: a VM pointed there is a delete away from taking the lot.
#
#   1. build the VM (stage two: `provision`), leaving its disk in a disposable folder
#   2. stop the VM, close AppSandbox
#   3. dr-layer adopt layer-0
#
# `adopt` is one verb because the order is the whole difficulty, and it is not guessable:
# capture the settings while the VM block still exists, move the disk, prove it still reads,
# freeze it, THEN de-register, and only then remove the emptied VM folder. Done by hand in the
# wrong order it either loses the settings a child needs, or leaves a VM pointing into the layer
# store, which is a single delete away from taking every layer with it.
#
# De-registering is not deleting. The VM block goes and every file stays; AppSandbox simply
# stops knowing the disk is there, which is what ends the exposure for good.
#
# WHY NOT APPSANDBOX SNAPSHOTS. Only the FIRST snapshot captures a VM's current state; every
# later one is built as a differencing child of the first snapshot's baseline, so a three-deep
# chain of snapshots would silently be three children of one baseline. Reported as issue #152,
# with a fix offered as PR #199. Until one ships, layers are made by hand, here.
#
# SIZE, BECAUSE IT IS THE ONE THING YOU CANNOT UNDO. A child inherits its parent's capacity and
# can be GROWN but never SHRUNK, so a parent's size is a FLOOR for every layer above it. -DiskGb
# on `new` grows the child; anything smaller than the parent is refused.
#
# MEASURED: three New-VHD -Differencing over a 512 MB dynamic base, then Resize-VHD
# on the TOP disk to 1 GB - it reports Differencing, Size 1073741824, parent L2.vhdx, and all
# four files sit at 4 MB on disk. So four levels build, thin provisioning holds at every level,
# and a layer grows without its parent changing. What is still unproven is whether HCS BOOTS a
# guest four levels deep, and what reads cost down there.
#
# EXIT CODES, because a front end has to tell a refusal from a failure:
#   0   done
#   2   the arguments are wrong
#   3   AppSandbox is up, so nothing was touched
#   20  a guard bit: a writable parent, a layer with children, a name or port taken, a size
#       below the parent's
#   21  something named does not exist
#   24  elevation was declined

param(
    # -Mode rather than a positional verb, for the reason every lib/forge/*.ps1 takes one: the
    # caller is bin/dr-layer, and a named parameter cannot be silently reordered.
    [ValidateSet('list', 'adopt', 'new', 'freeze', 'thaw', 'drop')]
    [string]$Mode = 'list',

    [string]$Name,                          # the layer, e.g. layer-1. Also the VM name.
    [string]$Parent,                        # a layer name under -Root, or a full .vhdx path
    # WHERE LAYERS LIVE, and it must be your FASTEST disk, not your biggest. Reads walk the
    # chain: anything the top layer does not hold is fetched from its parent, and so on down.
    # The frozen parents are therefore the HOT read path - they hold Windows, Visual Studio
    # and the engine - so putting them on a spinning disk to save space on an SSD punishes
    # every read the project makes. Archives are the opposite case and belong on the big
    # slow disk, since nothing reads them until a restore.
    # It must also be outside AppSandbox's own tree - but NOT because that is what stops a
    # layer being deleted. Deleting a VM removes <its disk's folder> recursively, so the
    # risk follows the VM REGISTRATION, not the path: a base under C:\ForgeLayers with a VM
    # still pointing at it is exactly as deletable as one under ProgramData. `freeze
    # -Unregister` is what ends that, by dropping the VM block and leaving the file.
    # Being outside AppSandbox's tree buys something different and worth having: nothing
    # AppSandbox does to its OWN directory - uninstall, reset, a future tidy-up - can reach
    # a layer that was never in it.
    # DRAUGR_FORGE_LAYERS is where this normally comes from; bin/dr-layer passes it as
    # -Root only when it is set, so an unset key is reported as the default it is.
    [string]$Root = 'C:\ForgeLayers',
    [string]$From,                          # VM block to copy RAM/cores/GPU/network from
    [int]$DiskGb = 0,                       # 0 = inherit the parent's capacity
    [int]$SshPort = 0,                      # 0 = one above the highest already in vms.cfg
    [switch]$Unregister,                    # freeze: also remove the VM block
    [switch]$NoRegister,                    # thaw: clear read-only but add no VM block
    [switch]$Force,                         # thaw: proceed even though a child exists
    [switch]$KeepRegistered,                # new: create the disk but do not add a VM block
    [switch]$KeepVmFolder,                  # adopt: leave the emptied VM folder behind
    [switch]$NoElevate,
    # Set ONLY by this script's own elevation relaunch, never by a person. The elevated
    # child writes everything it prints here so the parent can show it; see the elevation
    # block for why that is not optional.
    [string]$TranscriptTo = '',
    [switch]$WhatIfOnly
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# Everything that knows the vms.cfg format, including $cfgPath and $script:carried.
. (Join-Path $PSScriptRoot 'vmscfg.ps1')
# The host key a de-registered VM leaves behind, shared with rm.ps1: adopt, drop and rm all
# strand the same `draugr-<name>` entry, and a layer name is exactly the kind that gets reused.
. (Join-Path $PSScriptRoot 'hostkey.ps1')

function Say($m)  { Write-Host "`n=== $m ===" -ForegroundColor Cyan }
function Note($m) { Write-Host "  $m" }
function Warn($m) { Write-Host "  $m" -ForegroundColor Yellow }
function Fail($m) { Write-Host "  $m" -ForegroundColor Red }


# WAS -Root ACTUALLY GIVEN? Captured here, at script scope, because $PSBoundParameters inside
# a function is that FUNCTION's own - asking there would answer "no" every time, however the
# script was called. This is the only place the truth is available.
$script:rootGiven = $PSBoundParameters.ContainsKey('Root')

# The elevated child's console is a SEPARATE WINDOW that closes the instant the script
# ends, so anything it printed - a refusal most of all - dies with it. Transcribing is the
# only way back to the parent, because Start-Process will not accept
# -RedirectStandardOutput alongside -Verb RunAs.
#
# Deliberately NOT stopped anywhere: PowerShell flushes and closes an open transcript when
# the process exits, and this script leaves through `exit` in a dozen places. A matching
# Stop-Transcript on each would be a dozen chances to forget one.
if ($TranscriptTo) { try { Start-Transcript -Path $TranscriptTo -Force | Out-Null } catch { } }

# ------------------------------------------------------------------- AppSandbox must be off
# It rewrites vms.cfg whenever anything changes, so an edit made while it runs is lost the
# next time it saves. Closing it also guarantees every VM is stopped, since the daemon owns
# them - which is exactly the precondition a freeze needs anyway.
function Assert-AppSandboxClosed {
    $p = @(Get-Process -Name 'appsandbox' -ErrorAction SilentlyContinue)
    if (-not $p.Count) { return }

    Fail "AppSandbox is running (pid $($p[0].Id)) and would overwrite this edit."
    Fail '  Close it and run this again. The GUI has a window; THE HEADLESS DAEMON DOES NOT,'
    Fail '  which is the whole difficulty - it is shut down over its own API.'
    Write-Host ''

    # THE DAEMON HAS NO WINDOW, so "close it" is not an instruction anyone can follow. The
    # commands are printed rather than run: stopping a guest is the user's call, and this
    # script's job is to refuse to edit vms.cfg underneath a running daemon, not to decide
    # when a VM should go down. Asked for by a user who had closed the only thing there was
    # to close and still could not proceed.
    #
    # ORDER MATTERS, and the API enforces it rather than trusting us: POST /v1/shutdown is
    # REFUSED WITH 409 while any VM is running, unless {"force":true} - which TERMINATES the
    # guests instead of shutting them down. For a disk that is about to be frozen as a base,
    # a terminated guest is a dirty one, so the VMs go down gracefully first and the daemon
    # follows. See headless-api\asb.py, shutdown_daemon().
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

    # ONE COMMAND, not a recipe. This printed six lines to paste into an elevated PowerShell
    # and a seventh to undo it, which was both tedious and WRONG about the elevation: the
    # headless API gates running the daemon, not calling it, so every shutdown step here
    # needs no elevation at all. Only the --headless relaunch does. See
    # lib/forge/daemon.ps1, and docs/FORGE.md, "Taking the daemon down is a command".
    Note 'Take it down with:'
    Write-Host ''
    Note '  dr-forge daemon stop'
    Write-Host ''
    if ($running.Count) {
        Note ("{0} running, and a daemon shutdown is refused while any VM is - so that" -f ($running -join ', '))
        Note 'command shuts them down gracefully first, and waits for each one.'
    } else {
        Note 'no VM is running, so the daemon will go straight down.'
    }
    Write-Host ''

    # ASKED OF THE PROCESS, not guessed from a list of likely directories. The daemon is
    # running right now - $p[0] above is it - so its own image path is the answer, and it is
    # right on a machine whose AppSandbox lives somewhere nobody here thought of. .Path can
    # come back empty for a process this account cannot open, so the default install is the
    # fallback; a list of local paths would be neither.
    $exe = $p[0].Path
    if (-not $exe -or -not (Test-Path $exe)) {
        $exe = @('C:\AppSandbox\AppSandbox.exe') |
               Where-Object { Test-Path $_ } | Select-Object -First 1
    }
    # The exe is still looked up here, but only to say whether the way back exists: a host
    # whose AppSandbox cannot be found is worth knowing about BEFORE the daemon goes down.
    if ($exe) {
        Note 'and to bring it back when you are done here:'
        Note '  dr-forge daemon start'
        Note "  ($exe --headless, which is the one step that raises a UAC prompt)"
    } else {
        Warn 'AppSandbox.exe cannot be found from here, so starting it again will need a path.'
    }
    exit 3
}

# ------------------------------------------------------------------------------ elevation
function Test-Elevated {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}
# THE DAEMON IS CHECKED BEFORE ELEVATION IS ASKED FOR, which is a change from the script this
# was adopted from. Get-Process needs no elevation, while the relaunch below raises a UAC
# prompt - so the original order made you accept a prompt and then told you AppSandbox was
# running and nothing had been done. A refusal that costs a prompt first teaches people to
# click through prompts. --dry-run writes nothing, so it does not need the daemon down: being
# able to rehearse a layer while the forge is still running is most of its value.
if ($Mode -ne 'list' -and -not $WhatIfOnly) { Assert-AppSandboxClosed }

# New-VHD, Get-VHD and Resize-VHD all answer "You do not have the required permission"
# unelevated - MEASURED, and the message names the computer rather than the
# cmdlet, so it reads like a policy problem rather than a missing UAC prompt.
if ($Mode -ne 'list' -and -not (Test-Elevated) -and -not $NoElevate) {
    Note 'the VHD cmdlets need elevation - asking for it once (accept the UAC prompt).'
    # -Root goes through the GENERIC loop below rather than being forced in here. Passing it
    # unconditionally would make the elevated child believe it was given explicitly, and the
    # child is the process that prints what the user reads - so it would report a default as a
    # deliberate choice. The child's own default is the same literal in this same file, so
    # leaving it out when it was not given is exact, not approximate.
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
    # MEASURED: without the three steps below, a refusal from the elevated child
    # is invisible here and the caller goes on to run the next command as though this one
    # had worked. See the transcript note near the top of the file.
    $log = Join-Path $env:TEMP "dr-layer-$(Get-Date -Format 'yyyyMMdd-HHmmss-fff').log"
    $a += @('-TranscriptTo', "`"$log`"")
    try {
        $proc = Start-Process powershell.exe -Verb RunAs -Wait -PassThru -ArgumentList ($a -join ' ')
    } catch {
        # Declining the UAC prompt throws rather than returning a code, and the bare
        # exception reads like a scripting fault instead of a decision someone made.
        Fail 'elevation was declined, so nothing was done.'
        exit 24
    }

    if (Test-Path $log) {
        # The transcript's own header, footer and prompt echoes are noise; everything between
        # is what the child actually said. Filtered by pattern rather than by line number,
        # because a header that gains a field should not swallow the first line of real
        # output.
        #
        # THE PROMPT ECHOES NEED STATE, which is why this is a foreach and not one more
        # clause in a Where-Object. A transcript records each command as a "PS>" line, and
        # the host writes `PS>$global:?` plus its result while recording the pipeline's
        # success state - so a clean run printed this into the caller's console
        # (MEASURED):
        #
        #     start AppSandbox and 'layer-2-ue41' will be in the list.
        #   PS>$global:?
        #   True
        #
        # The True/False is dropped ONLY when it directly follows that line. A bare "True" is
        # a perfectly plausible thing for a script to print, and a filter that swallowed
        # every one would hide real output in order to tidy up an artefact.
        $skipNextBool = $false
        foreach ($line in (Get-Content $log)) {
            if ($line -match '^\*{5,}$' -or
                $line -match '^(Windows PowerShell transcript|Start time:|End time:|Username:|RunAs User:|Configuration Name:|Machine:|Host Application:|Process ID:|PSVersion:|PSEdition:|PSCompatibleVersions:|BuildVersion:|CLRVersion:|WSManStackVersion:|PSRemotingProtocolVersion:|SerializationVersion:|Transcript started)') {
                continue
            }
            if ($line -match '^PS>') {
                # `PS>$global:?` is followed by the boolean it evaluated to; any other PS>
                # line is just the command being echoed.
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
        Warn "the elevated run left no transcript at $log - its output is lost."
    }

    # Propagated, not swallowed. `return` here would have reported success for a child that
    # refused, which is the other half of how one unnoticed failure became four.
    if ($proc.ExitCode -ne 0) { Fail "the elevated run exited $($proc.ExitCode)." }
    exit $proc.ExitCode
}

function Resolve-LayerDisk([string]$nameOrPath) {
    if ($nameOrPath -match '\.vhdx$') { return $nameOrPath }
    Join-Path (Join-Path $Root $nameOrPath) 'disk.vhdx'
}

# ------------------------------------------------------------------ what a layer remembers
# WHY A SIDECAR AT ALL. `new` copies RamMB, CpuCores, GpuMode, GpuName and NetworkMode from a
# VM BLOCK - and a frozen layer's whole point is that no VM block points at it any more. So
# the settings a child has to inherit disappear at exactly the moment the base becomes a base.
# -From exists to paper over that, and it fails SILENTLY when forgotten: the fallback is "the
# first VM block in vms.cfg", some unrelated VM whose GPU and network settings are then copied
# into the layer without a word. Recording them beside the disk makes the chain
# self-describing instead, and -From becomes an override rather than a thing to remember.
#
# A layer that differs from its parent in GpuMode or NetworkMode behaves differently from the
# thing it was built on, which is the kind of difference that surfaces three steps away.
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
    if ($WhatIfOnly) { Note "would record the inherited settings in $f"; return }
    [IO.File]::WriteAllText($f, ($o | ConvertTo-Json))
    Note "settings recorded in $(Split-Path $f -Leaf)"
}
function Read-LayerInfo([string]$diskPath) {
    $f = Get-LayerInfoPath $diskPath
    if (-not (Test-Path $f)) { return $null }
    try { return (Get-Content $f -Raw | ConvertFrom-Json) } catch { return $null }
}
# ------------------------------------------------------ is -Root the place you meant?
# WHERE A LAYER LANDS IS DECIDED BY A DEFAULT, not by anything in the command: -Root is
# C:\ForgeLayers unless given, so `adopt -Name layer-0` names no destination at all. That is
# fine until it is wrong, and New-Item -Force builds an entire missing chain without a word -
# so a mistyped -Root is created exactly as willingly as the right one, and `adopt` then moves
# the ONLY copy of a base into it.
#
# Depth is the signal. A layer store that does not exist yet is ordinary on first use; one
# whose PARENT is also missing is probably not the path that was typed. Same reasoning as
# -DiskDir in forge-provision.ps1, and asked about there first: a user who read the command
# wanted to know how it knew where to put things, which is the right question.
function Show-Root([switch]$Creating) {
    if ($script:rootGiven) {
        Note "root    $Root  (as given)"
    } else {
        Note "root    $Root  (the default: nothing set DRAUGR_FORGE_LAYERS)"
        Note '        --root <path> puts layers elsewhere for one command, and'
        Note '        DRAUGR_FORGE_LAYERS sets it for good. It must be outside'
        Note '        AppSandbox''s own tree, and on your fastest volume rather'
        Note '        than your biggest.'
    }
    if (Test-Path $Root) { return }
    Note ("        it does not exist yet{0}" -f $(if ($Creating) { '; it will be created' } else { '' }))
    $up = Split-Path $Root -Parent
    if ($up -and -not (Test-Path $up)) {
        Warn "        and so does its parent, $up - check the spelling."
        Warn '        A mistyped -Root is created just as willingly as a correct one, and'
        Warn '        the layer would then live somewhere you did not mean it to.'
    }
}

# ----------------------------------------------------------------- who differences from this
# EVERY disk anywhere that has $disk as its parent. This is the guard `thaw` and `drop` both
# live on, and it has to look WIDER THAN -Root.
#
# MEASURED, on this host: C:\ForgeLayers\layer-1 is the parent of
# D:\ForgeLayers\layer-2-ue411. The previous version of this check (inline in `drop`) scanned
# only -Root, so `drop -Name layer-1` - with -Root at its C:\ForgeLayers default - found no
# children and would have removed the parent of every engine layer on D:. The guard existed
# and was looking in one place. A layer store per drive is the normal shape here, not an
# exotic one: the engine layers are the big ones, so they go on the big disk.
#
# Three places are searched, because a disk can be in any of them:
#   - -Root, whatever it is this run;
#   - <drive>\ForgeLayers on every FIXED drive, the convention this script creates, so a
#     store on a drive nobody mentioned is still found;
#   - every VhdxPath in vms.cfg, because a registered disk need not be in a layer store at
#     all - forge-provision.ps1 builds layer-0 in AppSandbox's own directory on purpose.
# Removable drives are skipped deliberately: spinning up an absent USB disk to ask about a
# parent nobody put there is a slow way to learn nothing.
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
        # -ieq, not -eq: these paths arrive from three sources - a parameter, a directory walk
        # and a config file - and Windows does not care about case while PowerShell's -eq
        # does. Same reason the repo already carries "Compare Windows path case-insensitive"
        # as its own commit.
        if ($other -ieq $disk -or -not (Test-Path $other)) { continue }
        # A disk being read by a running VM answers with an exception rather than a parent,
        # and a child that cannot be interrogated must NOT be reported as absent - so it is
        # listed as unreadable and the caller decides. Silence here is the one outcome this
        # whole function exists to prevent.
        try { $pp = (Get-VHD -Path $other -ErrorAction Stop).ParentPath }
        catch { $found += "$other  (unreadable: $($_.Exception.Message.Split([char]10)[0]))"; continue }
        if ($pp -and (Get-FullPath $pp) -ieq $disk) { $found += $other }
    }
    # @() at the call site is load-bearing: one child returned from here arrives as a bare
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
    # ONE ROOT IS NOT EVERY ROOT, and nothing above says so. Once layers are split across two
    # volumes - which is the ordinary case, a base on the fast disk and the engine layers on
    # the big one - no single run of this command shows the whole picture, and the listing
    # looks complete either way. Said after the layers rather than beside the root, because it
    # is about what is MISSING from the list that precedes it.
    Note 'this is one root. Layers under another are not listed here:'
    Note '        dr-layer list --root <path>'
    if (-not (Test-Elevated)) { Warn 'run elevated to see each chain and its parents.' }
    return
}

if (-not $Name) { Fail "-Name is required for '$Mode'."; exit 2 }
# Checked again, and not redundantly: the first check happened before the UAC prompt, and a
# daemon can be started while that prompt sits on screen. This is the one the edit depends on.
if (-not $WhatIfOnly) { Assert-AppSandboxClosed }
# @() IS LOAD-BEARING. PowerShell unrolls a one-element array when a function returns
# it, so `$cfg = Read-Cfg` yields a bare PSCustomObject whenever vms.cfg holds a single
# block - which is exactly what `adopt` leaves behind when it de-registers the last VM.
# `$cfg += <block>` in `new` then failed with "does not contain a method named
# 'op_Addition'", after the child disk and its layer.json had already been written.
# MEASURED, building layer-1 on a freshly adopted layer-0.
$cfg = @(Read-Cfg)
$vmBlocks = @($cfg | Where-Object { $_.Header -eq 'VM' })

# ========================================================================= adopt
# Turn a finished VM's disk into a frozen layer, in the order that keeps it safe throughout.
# This is the step that cannot be assembled by hand without knowing things no one should have
# to: that the settings have to be captured BEFORE vms.cfg is rewritten, that the move has to
# precede the freeze, and that de-registering is not the same as deleting.
if ($Mode -eq 'adopt') {
    if (-not $Name) { Fail '-Name is required: the VM to adopt, which becomes the layer.'; exit 2 }
    $owner = @($vmBlocks | Where-Object { (Get-Val $_ 'Name') -eq $Name })
    if (-not $owner) {
        Fail "no VM called '$Name' in vms.cfg."
        Fail "  registered: $(($vmBlocks | ForEach-Object { Get-Val $_ 'Name' }) -join ', ')"
        exit 21
    }
    $src  = $owner[0]
    $from = Get-Val $src 'VhdxPath'
    if (-not $from)             { Fail "'$Name' has no VhdxPath in vms.cfg."; exit 21 }
    if (-not (Test-Path $from)) { Fail "'$Name' points at $from, which is not there."; exit 21 }

    $dir   = Join-Path $Root $Name
    $disk  = Join-Path $dir 'disk.vhdx'
    $inPlace = ($disk -eq $from)
    if (-not $inPlace -and (Test-Path $disk)) {
        Fail "$disk already exists - refusing to overwrite it."; exit 20
    }

    Say "adopt '$Name' as a layer"
    Show-Root -Creating
    $gb = [math]::Round((Get-Item $from -Force).Length / 1GB, 1)
    Note "disk    $from  ($gb GB on disk)"
    if ($inPlace) {
        # A base built with -DiskDir aimed at the layer store. The docs now advise against
        # that, but disks are already in that shape, and for them there is simply nothing to
        # move - the freeze and the de-register are the whole job.
        Note 'already under -Root, so there is nothing to move'
    } else {
        $sameVol = (Split-Path $from -Qualifier) -eq (Split-Path $disk -Qualifier)
        Note "move to $disk"
        if ($sameVol) {
            Note '        same volume, so this is a rename: no bytes are copied'
        } else {
            Warn '        ACROSS VOLUMES, so every byte is copied. Allowed, just not quick.'
        }
    }

    if (-not $inPlace -and -not $WhatIfOnly) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
    # The settings go down FIRST, while the VM block is still there to read them from. Doing
    # it after the rewrite would mean reading them back out of a file that no longer has them.
    Save-LayerInfo $disk $src "adopted from VM '$Name'"

    if ($inPlace) {
        Note 'disk stays where it is'
    } elseif ($WhatIfOnly) {
        Note "would move the disk to $disk"
    } else {
        Move-Item -LiteralPath $from -Destination $disk
        Note 'disk moved'
        # Proof it survived, before anything irreversible happens to vms.cfg. A move that
        # produced an unreadable file and a de-registered VM would leave nothing to go back to.
        try { [void](Get-VHD -Path $disk -ErrorAction Stop); Note 'Get-VHD reads it: the move is sound' }
        catch {
            Fail "the moved disk does not read back: $($_.Exception.Message)"
            Fail "  It is at $disk and vms.cfg has NOT been touched - '$Name' still points at"
            Fail '  the old path. Move it back there before doing anything else.'
            exit 20
        }
    }

    # Frozen before de-registering, not after: while a VM block still names it, the read-only
    # attribute is the only thing standing between a careless start and a ruined chain.
    if ($WhatIfOnly) {
        Note "would set read-only on $disk"
    } else {
        $i = Get-Item $disk -Force
        if ($i.IsReadOnly) { Note 'already frozen' }
        else { Set-ItemProperty -Path $disk -Name IsReadOnly -Value $true; Note 'read-only set' }
    }

    # De-register: the VM block goes, every file stays. This is what ends the exposure, and
    # it is not the same act as deleting the VM - which would take the folder with it.
    $cfg = @($cfg | Where-Object { $_ -notin $owner })
    Write-Cfg $cfg
    # IN THE SAME MOOD AS ITS NEIGHBOURS. Write-Cfg honours -WhatIfOnly and says "would back
    # up ... and rewrite", so a dry run that then announced the de-registration in the past
    # tense was reporting an act it had not performed - between two lines that both said
    # "would". Caught, on the first real dry run of adopt.
    if ($WhatIfOnly) {
        Note "would de-register '$Name': AppSandbox would stop knowing this disk exists"
    } else {
        Note "'$Name' de-registered: AppSandbox no longer knows this disk exists"
        # The VM is gone, so its host key is owed nothing. The disk lives on as a layer, but
        # a child boots under its OWN name and dials its own alias, so nothing here needs it.
        $hk = Clear-ForgeHostKey $Name
        if ($hk) { Note $hk }
    }

    # What is left behind is the VM's folder with no disk in it. Removing it is the point of
    # the exercise, so it is done here rather than left as a seventh step - but never while a
    # .vhdx is still in there, whatever the reason for that might be.
    if (-not $inPlace) {
        $old = Split-Path $from -Parent
        # Under -WhatIfOnly the disk is still sitting in there, because nothing moved - so it
        # would be counted as a stray and the dry run would report a refusal the real run
        # will not make. Discount exactly that one file, and nothing else.
        $stray = @(Get-ChildItem $old -Filter *.vhdx -Recurse -ErrorAction SilentlyContinue |
                   Where-Object { -not ($WhatIfOnly -and $_.FullName -eq $from) })
        if ($KeepVmFolder) {
            Note "kept     $old (-KeepVmFolder); it holds no disk now"
        } elseif ($stray.Count) {
            Warn "NOT removing $old - it still holds $($stray.Count) .vhdx file(s):"
            foreach ($f in $stray) { Warn "  $($f.FullName)" }
            Warn '  Something else lives there. Look before you delete it by hand.'
        } elseif ($WhatIfOnly) {
            Note "would remove $old (now diskless)"
        } else {
            Remove-Item $old -Recurse -Force
            Note "removed  $old (the VM's leftovers; the disk is elsewhere now)"
        }
    }

    Write-Host ''
    Note "'$Name' is now a frozen layer at $disk"
    Note "next:  dr-layer new layer-1 --parent $Name"
    Note '       --from is no longer needed: the settings are in layer.json beside the disk.'
    return
}

# =========================================================================== new
if ($Mode -eq 'new') {
    if (-not $Parent) { Fail '-Parent is required: a layer name, or a path to a .vhdx.'; exit 2 }
    # A Windows guest name is capped at 15 (NetBIOS) and takes letters, digits and hyphens.
    # The DISK path has no such limit - only the VM's name does.
    if ($Name.Length -gt 15 -or $Name -notmatch '^[A-Za-z0-9-]+$' -or
        $Name -match '^-' -or $Name -match '-$' -or $Name -match '^[0-9]+$') {
        Fail "'$Name' is not a valid Windows guest name (<=15 chars, letters/digits/hyphens,"
        Fail '  not all digits, no leading or trailing hyphen).'
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
        Fail "-DiskGb $DiskGb is smaller than the parent's $parentGb GB."
        Fail '  A differencing child can be grown but never shrunk. Nothing was created.'
        exit 20
    }

    Say "new layer '$Name' on $Parent"
    Show-Root -Creating
    Note "parent  $parentDisk ($parentGb GB)"
    Note "child   $disk"
    Note "size    $(if ($DiskGb -and $DiskGb -gt $parentGb) { "$DiskGb GB (grown)" } else { "$parentGb GB (inherited)" })"

    # The parent must be frozen BEFORE it gains a child: writing to a parent that a child
    # already differences from corrupts the child, silently, and there is no warning
    # anywhere in the stack that this is happening.
    if (-not (Get-Item $parentDisk -Force).IsReadOnly) {
        Warn "the parent is still WRITABLE. Freeze it first:  dr-layer freeze $Parent"
        Warn '  Writing to a parent after a child exists corrupts the child, without a word.'
        if (-not $WhatIfOnly) { Fail 'refusing to build on a writable parent.'; exit 20 }
    }

    if ($WhatIfOnly) { Note 'nothing was created (-WhatIfOnly)'; return }

    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    New-VHD -Path $disk -ParentPath $parentDisk -Differencing | Out-Null
    Note 'differencing disk created'
    if ($DiskGb -and $DiskGb -gt $parentGb) {
        Resize-VHD -Path $disk -SizeBytes ([int64]$DiskGb * 1GB)
        Note "grown to $DiskGb GB (the parent is untouched: still $parentGb GB)"
    }
    # InstallComplete lives beside the disk, and without it AppSandbox offers to install
    # Windows over the top of a disk that already has it.
    [IO.File]::WriteAllText((Join-Path $dir 'vm_state.json'), '{"installComplete":1}')

    if ($KeepRegistered) { Note 'no VM block added (-KeepRegistered)'; return }

    # Copy the settings that have to match, from the VM the parent came from if it is still
    # registered, otherwise from -From, otherwise from the only VM there is. GpuMode,
    # GpuName and NetworkMode especially: a layer that differs from its parent in those
    # behaves differently from the thing it was built on.
    if ($From) {
        # Named explicitly, so a miss is an error. Falling back to "some other VM" here
        # would copy the wrong GpuMode or NetworkMode into a layer and say nothing.
        $src = @($vmBlocks | Where-Object { (Get-Val $_ 'Name') -eq $From })
        if (-not $src) { Fail "no VM called '$From' in vms.cfg."; exit 21 }
        $src = $src[0]
    } else {
        $src = @($vmBlocks | Where-Object { (Get-Val $_ 'VhdxPath') -eq $parentDisk }) |
               Select-Object -First 1
        if (-not $src) {
            # The parent's own record, written by `adopt` or by a previous `new`. Preferred
            # over any VM block that merely happens to exist, because it describes THIS chain.
            $info = Read-LayerInfo $parentDisk
            if ($info) { $src = ConvertTo-CfgBlock $info "$Parent/layer.json" }
        }
        if (-not $src) {
            # Last resort, and loudly so. This is the path that used to copy an unrelated VM's
            # GpuMode and NetworkMode into a layer without saying anything at all.
            $src = $vmBlocks | Select-Object -First 1
            if ($src) {
                Warn "nothing points at the parent and it has no layer.json, so the settings"
                Warn "  are being taken from '$(Get-Val $src 'Name')', which may have nothing to"
                Warn '  do with this chain. Pass -From to choose deliberately.'
            }
        }
        if (-not $src) { Fail 'no existing VM block to copy settings from; pass -From.'; exit 20 }
    }
    Note "settings copied from '$(Get-Val $src 'Name')'"

    $SshPort = Resolve-SshPort $SshPort $vmBlocks
    if ($SshPort -lt 0) { Fail 'that ssh port is already taken; pass --ssh-port.'; exit 20 }
    Note "ssh port $SshPort"

    $hdd = if ($DiskGb) { $DiskGb } else { $parentGb }
    # The child records what it inherited too, so the chain keeps working after this layer is
    # itself frozen and de-registered. Without it, every freeze would re-open the same hole.
    Save-LayerInfo $disk $src "inherited from '$Parent' when '$Name' was created"

    $cfg += New-VmBlock $Name $src $disk $hdd $SshPort
    Write-Cfg $cfg
    Note "start AppSandbox and '$Name' will be in the list."
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
        # The read-only ATTRIBUTE is the guard that actually holds: AppSandbox will happily
        # boot a VM pointed at a parent, and that write is what silently ruins every child
        # below it. A failed open is a far better outcome than a corrupted chain.
        Set-ItemProperty -Path $disk -Name IsReadOnly -Value $true
        Note "read-only set on $disk"
    }
    $owner = @($vmBlocks | Where-Object { (Get-Val $_ 'VhdxPath') -eq $disk })
    if ($owner -and $Unregister) {
        # Recorded before the block is dropped, for the same reason adopt does it first: after
        # the rewrite there is nowhere left to read these from.
        Save-LayerInfo $disk $owner[0] "recorded when '$(Get-Val $owner[0] 'Name')' was de-registered"
        $cfg = @($cfg | Where-Object { $_ -notin $owner })
        Write-Cfg $cfg
        Note "removed the VM block(s): $(($owner | ForEach-Object { Get-Val $_ 'Name' }) -join ', ')"
    } elseif ($owner) {
        Warn "'$(Get-Val $owner[0] 'Name')' still points at this disk."
        Warn '  Read-only stops a write, but -Unregister removes the temptation entirely.'
    }
    return
}

# =========================================================================== thaw
# The counterpart to `freeze`, and the reason `freeze` is safe to automate: an irreversible
# step that runs without being asked needs a one-command undo, or the first wrong guess costs
# an afternoon of `attrib -r` and a vms.cfg block rebuilt from memory.
#
# WHAT IT UNDOES. `freeze -Unregister` does two things, so this undoes both: the read-only
# attribute is cleared, and the VM block is rebuilt from the layer.json that freeze recorded
# on its way out. -NoRegister clears the attribute only.
#
# WHAT IT CANNOT UNDO, which is the part to understand before relying on it: bytes that have
# already left. A layer that was copied, archived or shipped is out there, and thawing this
# file changes none of those copies. Thaw is for a layer whose mistake you caught before
# anything was built on it - not a way to edit history.
#
# WHY IT REFUSES WHEN THE LAYER HAS CHILDREN. Writing to a parent that a child differences
# from corrupts the child, silently, with nothing anywhere in the stack reporting it. That is
# precisely the arrangement `new` refuses to create, seen from the other end, and it is the
# only thing the read-only attribute is for. -Force is there because it is your disk; the
# warning it prints is not decoration.
if ($Mode -eq 'thaw') {
    $disk = Get-FullPath (Resolve-LayerDisk $Name)
    if (-not (Test-Path $disk)) { Fail "no disk at $disk"; exit 21 }
    # -Name may be a path, in which case the VM name is the layer DIRECTORY's name - the one
    # `new` would have used. Deriving it from the file would name every VM 'disk'.
    $vmName = if ($Name -match '\.vhdx$') { Split-Path (Split-Path $Name -Parent) -Leaf } else { $Name }
    Say "thaw '$vmName'"
    Show-Root

    $kids = @(Get-LayerChildren $disk)
    if ($kids.Count) {
        Fail "$($kids.Count) layer(s) difference from this one:"
        foreach ($k in $kids) { Fail "    $k" }
        Fail '  Writing to a parent a child differences from corrupts the child, and nothing'
        Fail '  in the stack will say so. Drop them first.'
        if (-not $Force) { exit 20 }
        Warn '-Force given: thawing anyway. Every layer listed above is now suspect, and the'
        Warn '  corruption will not announce itself - it surfaces as a guest that boots wrong.'
    } else {
        Note 'children none - nothing differences from this disk'
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

    # WITHOUT THIS, APPSANDBOX OFFERS TO INSTALL WINDOWS over a disk that already has it -
    # which on a layer carrying a provisioned guest and an engine is an expensive
    # misunderstanding. `new` writes it (see the comment there); a layer that was moved by
    # hand can easily have lost it, and this is the moment it starts mattering again.
    $stateFile = Join-Path (Split-Path $disk -Parent) 'vm_state.json'
    if (Test-Path $stateFile) {
        Note 'vm_state.json present'
    } elseif ($WhatIfOnly) {
        Note "would write $stateFile"
    } else {
        [IO.File]::WriteAllText($stateFile, '{"installComplete":1}')
        Note 'vm_state.json written (without it AppSandbox offers to reinstall Windows)'
    }

    if ($NoRegister) {
        Note 'no VM block added (-NoRegister): the disk is writable but nothing can boot it'
        return
    }

    if ($vmBlocks | Where-Object { (Get-Val $_ 'Name') -eq $vmName }) {
        Note "'$vmName' is already in vms.cfg - left exactly as it is"
        return
    }
    $other = @($vmBlocks | Where-Object { (Get-Val $_ 'VhdxPath') -ieq $disk })
    if ($other) {
        Fail "'$(Get-Val $other[0] 'Name')' already points at this disk under a different name."
        Fail '  Two VM blocks on one disk is how a layer gets written by two machines at once.'
        Fail '  Nothing was added; use that VM, or remove its block first.'
        exit 20
    }

    # The settings freeze recorded on its way out. This is the whole reason layer.json exists:
    # at the moment a layer becomes a base, the VM block that knew its RAM, cores, GPU mode
    # and network mode is exactly what gets deleted.
    $info = Read-LayerInfo $disk
    if (-not $info) {
        Fail 'no layer.json beside the disk, so there is nothing to rebuild a VM block from.'
        Fail '  The disk IS thawed - only the registration is missing. Either add the block by'
        Fail '  hand, or copy one from a sibling layer and change Name, VhdxPath and SshPort.'
        exit 20
    }
    $src = ConvertTo-CfgBlock $info "$vmName/layer.json"

    $SshPort = Resolve-SshPort $SshPort $vmBlocks
    if ($SshPort -lt 0) { Fail 'that ssh port is already taken; pass --ssh-port.'; exit 20 }
    # HddGB from the DISK, not from layer.json: the capacity is whatever this file actually
    # is, and a layer that was grown with -DiskGb no longer matches what its parent recorded.
    $gb = [math]::Round((Get-VHD -Path $disk).Size / 1GB)

    Note "settings restored from layer.json (recorded $($info.when))"
    Note "ssh port $SshPort"
    if ($WhatIfOnly) { Note "would add the VM block '$vmName'"; return }

    $cfg += New-VmBlock $vmName $src $disk $gb $SshPort
    Write-Cfg $cfg
    Note "'$vmName' re-registered - start AppSandbox and it will be in the list"
    Write-Host ''
    Warn 'This layer is WRITABLE and REGISTERED again. Nothing new may be built on it until'
    Warn '  it is frozen once more:'
    Warn "  dr-layer freeze $vmName$(if ($script:rootGiven) { " --root $Root" }) --unregister"
    return
}

# =========================================================================== drop
if ($Mode -eq 'drop') {
    $dir = Join-Path $Root $Name
    $disk = Join-Path $dir 'disk.vhdx'
    if (-not (Test-Path $dir)) { Fail "no layer directory at $dir"; exit 21 }
    Say "drop '$Name'"

    # Refuse to remove anything another layer is differencing from. Cheap to check, and the
    # failure it prevents is every descendant becoming unbootable at once. See
    # Get-LayerChildren for why this no longer scans -Root alone.
    $kids = @(Get-LayerChildren $disk)
    if ($kids.Count) {
        Fail "$($kids.Count) layer(s) difference from this one:"
        foreach ($k in $kids) { Fail "    $k" }
        Fail '  Dropping it would make every one of them unbootable. Drop them first.'
        exit 20
    }
    if ((Get-Item $disk -Force -ErrorAction SilentlyContinue).IsReadOnly) {
        Warn 'this layer is frozen, which usually means something was built on it.'
        Warn '  Nothing under -Root claims it as a parent, but a disk elsewhere still might.'
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
    # ALWAYS, not only when a VM block was found. A layer reaches `drop` long after its VM
    # block went - `adopt` removes that - so keying this off $owner would miss the common
    # case, which is precisely the one measured: draugr-forge-0 was stranded by
    # the adopt, not by any delete.
    $hk = Clear-ForgeHostKey $Name
    if ($hk) { Note $hk }
    return
}
