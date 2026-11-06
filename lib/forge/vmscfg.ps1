# lib/forge/vmscfg.ps1 - everything that knows the shape of AppSandbox's vms.cfg.
#
# ==> NOT MEANT TO BE TYPED. Dot-sourced by lib/forge/layer.ps1. <==
#
# THIS FILE IS THE WORKAROUND, kept by itself on purpose (docs/FORGE.md, "The layer mechanism as
# a command"). Layers exist by editing this file because AppSandbox offers no other route: there
# is no promote-a-VM-to-a-template call, and the snapshot bug rules out the other road. The
# format is undocumented and was measured stale in one field. If PR #199 ever lands, the fix is
# deleting this file rather than untangling it from the orchestration.
#
# THE DAEMON MUST BE DOWN before anything here writes. It rewrites vms.cfg whenever anything
# changes, so an edit made underneath it is simply lost - which is layer.ps1's precondition, not
# this file's job to check.

$cfgPath = Join-Path $env:ProgramData 'AppSandbox\vms.cfg'

# The settings a child must inherit, and the only keys carried between a layer and its children.
# GpuMode, GpuName and NetworkMode above all: a layer that differs from its parent in those
# behaves differently from the thing it was built on.
$script:carried = @('OsType', 'ImagePath', 'RamMB', 'CpuCores', 'GpuMode', 'GpuName',
                    'NetworkMode', 'AdminUser')

# ------------------------------------------------------------------------ vms.cfg, safely
# Each block is kept as its RAW lines. Only blocks this script adds or removes are ever
# regenerated, so a key it has never heard of survives a round trip untouched.
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
    # The caller wraps this in @() and must keep doing so: a single block returned from
    # here arrives as a scalar, not as an array of one. See the comment at `$cfg = @(...)`.
    $blocks
}
function Get-Val($block, [string]$key) {
    foreach ($l in $block.Lines) { if ($l -match "^$key=(.*)$") { return $Matches[1] } }
    $null
}
function Write-Cfg($blocks) {
    # Same unrolling hazard as Read-Cfg, from the other side: a caller that hands over one
    # block would otherwise iterate its PROPERTIES rather than the block. Cheap insurance.
    $blocks = @($blocks)
    # UTF-8 WITH a BOM and CRLF endings, because that is what AppSandbox wrote (measured:
    # the file starts ef bb bf). Writing it back as plain UTF-8 or with LF endings is the
    # kind of difference that works until it does not.
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
    Note "vms.cfg written; previous kept as $(Split-Path $backup -Leaf)"
}

# Shaped as a cfg block so Get-Val works on it unchanged. Two accessors for the same settings
# would have to stay in step with each other, and sooner or later they would not.
function ConvertTo-CfgBlock($info, [string]$label) {
    $lines = @("Name=$label")
    foreach ($k in $script:carried) {
        if ($null -ne $info.$k -and "$($info.$k)" -ne '') { $lines += "$k=$($info.$k)" }
    }
    [pscustomobject]@{ Header = 'VM'; Lines = $lines }
}

# The VM block `new` and `thaw` both write, in one place because they must not drift: a diff of
# vms.cfg between a created layer and a thawed one should show only the values that really
# differ. SshEnabled and InstallComplete are constants here - a layer with neither is a layer
# nothing can reach, and without InstallComplete AppSandbox offers to install Windows over a
# disk that already has it.
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

# The next free ssh port, or a refusal if the one asked for is taken. 57350 is where AppSandbox
# itself starts; one above the highest in use is what the daemon would have picked.
function Resolve-SshPort([int]$Want, $VmBlocks) {
    if (-not $Want) {
        $used = @($VmBlocks | ForEach-Object { [int](Get-Val $_ 'SshPort') } | Where-Object { $_ })
        $Want = if ($used) { ($used | Measure-Object -Maximum).Maximum + 1 } else { 57350 }
    }
    if ($VmBlocks | Where-Object { (Get-Val $_ 'SshPort') -eq "$Want" }) { return -1 }
    $Want
}
