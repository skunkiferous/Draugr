# lib/forge/layerpath.ps1: is this a layer name, and is that path really there?
#
# ==> YOU DO NOT TYPE THIS. lib/forge/layer.ps1 dot-sources it. <==
#
# WHY THESE TWO LIVE IN A FILE OF THEIR OWN. `dr-layer drop` removes a
# directory recursively, elevated, and it built that directory's path out of a
# bare [string]$Name with no check at all:
#
#     $dir = Join-Path $Root $Name
#     Remove-Item $dir -Recurse -Force
#
# So `..\..\something` left the layer store, and `.` selected the ROOT, which
# is every layer in one call. A security review reproduced the first of those
# against a fixture root. `new` has always checked ITS name, but that check is
# about the 15-character limit of a Windows guest name, and it lives in the
# verb that creates rather than the verb that deletes.
#
# They are here, and not inside layer.ps1, so that a test can run them. layer.ps1
# has a param block and top-level code: dot-sourcing it RUNS it. vmstate.ps1 and
# sshauth.ps1 were split out for the same reason, and tests/forge-ps.bats
# executes all of them under the real powershell.exe.

# A layer name becomes ONE directory under -Root. Wider than what `new`
# allows, because an existing layer can carry a dot or an underscore, and
# still one name rather than a path.
function Test-LayerName([string]$n) {
    if (-not $n) { return $false }
    # A separator, a drive letter or a stream makes it more than one name.
    if ($n -match '[\\/:]') { return $false }
    # Letters and digits first, so no name is read as an option by whatever
    # runs next, and none begins with a dot. That first character is also what
    # refuses `.` and `..`, so there is no separate test for those: a mutation
    # run showed the explicit one could be deleted without a single test
    # noticing, which is the definition of a guard that guards nothing.
    if ($n -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') { return $false }
    # Win32 strips a trailing dot or space before it looks a name up, so such
    # a name is an alias for a different one.
    if ($n -match '[. ]$') { return $false }
    return $true
}

# Test-UnderRoot <path> <root>: a STRICT descendant, with no reparse point on
# the way.
#
# GetFullPath resolves `..`, which is the first half. The second half is that a
# junction or a symlink is a name whose destination is somewhere else, and
# Windows follows it for a recursive delete like any other directory. Neither
# GetFullPath nor Test-Path says so, so every level is asked for its
# ReparsePoint attribute.
#
# Strict: a path equal to the root answers false. Nothing in this tool should
# ever delete or replace the root it is confined to. That falls out of the one
# comparison below - the root does not start with itself PLUS a separator -
# and an extra test for it was deleted after a mutation run found that no test
# could tell whether it was there. The separator is also what keeps
# `C:\ForgeLayersEvil` from counting as a child of `C:\ForgeLayers`.
function Test-UnderRoot([string]$path, [string]$root) {
    if (-not $path -or -not $root) { return $false }
    $p = try { [IO.Path]::GetFullPath($path) } catch { return $false }
    $r = try { [IO.Path]::GetFullPath($root) } catch { return $false }
    $rTrim = $r.TrimEnd('\')
    $pTrim = $p.TrimEnd('\')
    if (-not $pTrim.StartsWith($rTrim + '\', [StringComparison]::OrdinalIgnoreCase)) { return $false }

    # From the path up to the root, every level that exists. A missing level is
    # not a failure: `drop` tests that the directory is there separately, and
    # the levels that DO exist are the ones that can carry a reparse point.
    $walk = $pTrim
    while ($walk -and $walk.Length -gt $rTrim.Length) {
        if (Test-ReparsePoint $walk) { return $false }
        $walk = Split-Path $walk -Parent
    }
    if (Test-ReparsePoint $rTrim) { return $false }
    return $true
}

function Test-ReparsePoint([string]$p) {
    $item = Get-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
    if (-not $item) { return $false }
    return [bool]($item.Attributes -band [IO.FileAttributes]::ReparsePoint)
}
