# lib/forge/vmscfg.ps1: all code that knows the shape of the vms.cfg of
# AppSandbox.
#
# ==> DO NOT TYPE IT. lib/forge/layer.ps1 dot-sources it. <==
#
# THIS FILE IS THE WORKAROUND, alone on purpose (docs/FORGE.md, "The layer
# mechanism as a command"). Layers come from edits of this file, because
# AppSandbox gives no other way. It has no call to promote a VM to a template,
# and the snapshot bug blocks the other way. The format has no documentation,
# and a test showed one field was old. If PR #199 is merged, the fix is to
# delete this file. Nobody must untangle it from the orchestration.
#
# THE DAEMON MUST BE DOWN before a write here. It rewrites vms.cfg at each
# change, so it loses an edit made under it. layer.ps1 has that precondition.
# This file does not test it.

$cfgPath = Join-Path $env:ProgramData 'AppSandbox\vms.cfg'

# The configuration that a child must inherit. These are the only keys that go
# from a layer to its children. GpuMode, GpuName, and NetworkMode most of all. A
# layer that is different from its parent in those works differently from its
# base.
$script:carried = @('OsType', 'ImagePath', 'RamMB', 'CpuCores', 'GpuMode', 'GpuName',
                    'NetworkMode', 'AdminUser')

# ------------------------------------------------------------------------ vms.cfg, safely
# Each block stays as its RAW lines. This script generates again only the blocks
# that it adds or removes. Thus an unknown key goes through a round trip with no
# change.
function Read-Cfg {
    if (-not (Test-Path $cfgPath)) { Fail "no vms.cfg at $cfgPath"; exit 21 }
    $blocks = @()
    $cur = $null
    foreach ($line in [IO.File]::ReadAllLines($cfgPath)) {
        if ($line -match '^\s*\[(.+)\]\s*$') {
            if ($cur) { $blocks += $cur }
            $cur = [pscustomobject]@{ Header = $Matches[1]; Lines = @() }
        } elseif ($cur -and $line.Trim()) {
            $cur.Lines += $line
        }
    }
    if ($cur) { $blocks += $cur }
    # The caller wraps this in @(), and must continue to do so. A single block
    # from here arrives as a scalar, not as an array of one. See the comment at
    # `$cfg = @(...)`.
    $blocks
}
function Get-Val($block, [string]$key) {
    foreach ($l in $block.Lines) { if ($l -match "^$key=(.*)$") { return $Matches[1] } }
    $null
}
function Write-Cfg($blocks) {
    # The same unrolling hazard as Read-Cfg, from the other side. If a caller
    # gives one block, this then iterates its PROPERTIES, not the block. A cheap
    # guard.
    $blocks = @($blocks)
    # UTF-8 WITH a BOM and CRLF endings, because AppSandbox wrote that (a test
    # showed that the file starts with ef bb bf). Plain UTF-8 or LF endings can
    # work for a time, and then fail.
    $sb = New-Object Text.StringBuilder
    foreach ($b in $blocks) {
        [void]$sb.Append("[$($b.Header)]`r`n")
        foreach ($l in $b.Lines) { [void]$sb.Append("$l`r`n") }
        [void]$sb.Append("`r`n")
    }
    $backup = "$cfgPath.bak-$(Get-Date -Format yyyyMMdd-HHmmss)"
    if ($WhatIfOnly) { Note "would back up to $backup and rewrite vms.cfg"; return }
    Copy-Item $cfgPath $backup
    [IO.File]::WriteAllText($cfgPath, $sb.ToString(), (New-Object Text.UTF8Encoding($true)))
    Note "vms.cfg written. The previous one is kept as $(Split-Path $backup -Leaf)"
}

# Shaped as a cfg block, so that Get-Val works on it with no change. Two
# accessors for the same values must stay the same, and one day they do not.
function ConvertTo-CfgBlock($info, [string]$label) {
    $lines = @("Name=$label")
    foreach ($k in $script:carried) {
        if ($null -ne $info.$k -and "$($info.$k)" -ne '') { $lines += "$k=$($info.$k)" }
    }
    [pscustomobject]@{ Header = 'VM'; Lines = $lines }
}

# The VM block that `new` and `thaw` both write. It is in one place, because the
# two must stay the same. A diff of vms.cfg between a created layer and a thawed
# one must show only the values that are really different. SshEnabled and
# InstallComplete are constants here. Nothing can reach a layer with neither.
# Without InstallComplete, AppSandbox offers to install Windows on a disk that
# already has it.
function New-VmBlock([string]$Name, $Src, [string]$VhdxPath, [int]$HddGb, [int]$SshPort) {
    $lines = @(
        "Name=$Name"
        "OsType=$(Get-Val $Src 'OsType')"
        "ImagePath=$(Get-Val $Src 'ImagePath')"
        "VhdxPath=$VhdxPath"
        "RamMB=$(Get-Val $Src 'RamMB')"
        "HddGB=$HddGb"
        "CpuCores=$(Get-Val $Src 'CpuCores')"
        "GpuMode=$(Get-Val $Src 'GpuMode')"
        "GpuName=$(Get-Val $Src 'GpuName')"
        "NetworkMode=$(Get-Val $Src 'NetworkMode')"
        "AdminUser=$(Get-Val $Src 'AdminUser')"
        'SshEnabled=1'
        "SshPort=$SshPort"
        'InstallComplete=1'
    )
    [pscustomobject]@{ Header = 'VM'; Lines = $lines }
}

# The next free ssh port. If the requested port is in use, a refusal. AppSandbox
# itself starts at 57350. The daemon picks one above the highest port in use.
function Resolve-SshPort([int]$Want, $VmBlocks) {
    if (-not $Want) {
        $used = @($VmBlocks | ForEach-Object { [int](Get-Val $_ 'SshPort') } | Where-Object { $_ })
        $Want = if ($used) { ($used | Measure-Object -Maximum).Maximum + 1 } else { 57350 }
    }
    if ($VmBlocks | Where-Object { (Get-Val $_ 'SshPort') -eq "$Want" }) { return -1 }
    $Want
}
