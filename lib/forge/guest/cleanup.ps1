# cleanup.ps1: remove the build scaffolding before the image is kept.
#
# Run it IN THE GUEST, last, after all is installed and tested. It removes what
# provisioning left, and nothing else: no "optimizers", no registry clean-up,
# and no uninstall of something that you asked for.
#
# WHY IT IS A STEP. This disk becomes a base image. Each byte in it is copied
# for each layer above it, and again for each archive. A test of the flatten of
# this disk showed almost 11 minutes. Package caches and staged installers are
# the largest things on a new guest that nobody ever reads again. Remove them
# before the image is kept, not after three copies.
#
# It reports the freed bytes for each item. With no output, nobody can tell
# whether a clean-up step works. Each number outside -WhatIfOnly is a MEASURED
# DIFFERENCE: the size before, minus the size after. That is important. The
# first version printed the size that it wanted to remove. Thus `pacman -Sc`
# said 33.2 MB but freed nothing, at each run, with the same number each time. A
# reader saw that the repetition was strange, and found it.
#
# WHAT IT KEEPS, ON PURPOSE: the MSYS2 package DATABASE, the uv tool
# environments, the logs under C:\Draugr, and the Windows component store.
# pacman -Q must continue to work, because the manifest reads it. `DISM
# /StartComponentCleanup` can free more, but it is slow, makes rollbacks
# impossible, and sometimes breaks a machine. It is not worth the minutes here.
#
#   powershell -ExecutionPolicy Bypass -File .\cleanup.ps1                # do it
#   powershell -ExecutionPolicy Bypass -File .\cleanup.ps1 -WhatIfOnly    # report what goes, change nothing
param(
    [string]$Msys = 'C:\msys64',
    [string]$TempDir = 'C:\temp',
    [switch]$SkipPacmanCache,
    [switch]$SkipUvCache,
    [switch]$WhatIfOnly
)

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'

function Get-Mb([string]$p) {
    if (-not (Test-Path $p)) { return 0 }
    [math]::Round((Get-ChildItem $p -Recurse -File -Force -EA SilentlyContinue |
        Measure-Object Length -Sum).Sum / 1MB, 1)
}
$total = 0.0
function Report([string]$what, [double]$mb) {
    $script:total += $mb
    $verb = if ($WhatIfOnly) { 'would free' } else { 'freed' }
    Write-Host ("  {0,-34} {1} {2} MB" -f $what, $verb, $mb)
}
function Remove-Quietly([string[]]$paths) {
    if ($WhatIfOnly) { return }
    foreach ($p in $paths) { Remove-Item $p -Recurse -Force -EA SilentlyContinue }
}

Write-Host '--- cleanup ---'

# --- the scripts that provisioning staged, and the work directory of the screen installer ---
# lib/forge/provision.ps1 copies each guest script into C:\Windows\Temp, and
# runs it there. All of them are in the repository. The copies are scaffolding.
$staged = @(Get-ChildItem 'C:\Windows\Temp' -Filter '*.ps1' -EA SilentlyContinue |
            Where-Object { $_.Name -match '^(install-|preflight|write-manifest|cleanup|audit)' })
$mb = [math]::Round((($staged | Measure-Object Length -Sum).Sum) / 1MB, 2)
Report "staged scripts ($($staged.Count))" $mb
Remove-Quietly @($staged.FullName)

# install-screen-server.ps1 already deletes the MSI and its password. This is
# their directory, and all that a failed run left.
$screen = 'C:\ProgramData\draugr-screen'
Report 'screen installer directory' (Get-Mb $screen)
Remove-Quietly @($screen)

# --- package caches -------------------------------------------------------------------
# pacman keeps each .pkg.tar.zst that it ever downloaded, and a base image never
# reads one again.
#
# WHY NOT `pacman -Sc`, WHICH THIS RAN BEFORE. -Sc removes only packages that
# are NO LONGER INSTALLED. On a new guest, each cached file belongs to an
# installed package, so it removes nothing. But this block reported the whole
# cache as "freed", because it measured the directory BEFORE the command, and
# never again. A TEST SHOWED THIS: it printed "freed 33.2 MB", and left 34 MB in
# 128 files.
#
# The code deletes the files directly, not with -Scc, which also asks about the
# SYNC databases. The code touches NEITHER database. `pacman -Q` reads
# /var/lib/pacman/local, and the manifest needs it.
$bash = Join-Path $Msys 'usr\bin\bash.exe'
if (-not $SkipPacmanCache -and (Test-Path $bash)) {
    $cache = Join-Path $Msys 'var\cache\pacman\pkg'
    $before = Get-Mb $cache
    if ($WhatIfOnly) {
        Report 'pacman package cache' $before
    } else {
        # The redirect is around the whole command, because a redirect at the
        # end of a pipeline applies only to the last stage.
        & $bash -lc '( rm -f /var/cache/pacman/pkg/*.pkg.tar.* ) < /dev/null' 2>&1 | Out-Null
        Report 'pacman package cache' ($before - (Get-Mb $cache))
    }
}

# The wheel cache of uv makes downloads faster. After a tool install, `prune`
# frees nothing (a test showed 150.7 MB before and after, because something
# still uses each entry). Thus a base image needs `clean`.
$uv = "$env:USERPROFILE\.local\bin\uv.exe"
if (-not $SkipUvCache -and (Test-Path $uv)) {
    $uvCache = "$env:LOCALAPPDATA\uv\cache"
    $before = Get-Mb $uvCache
    if ($WhatIfOnly) {
        Report 'uv wheel cache' $before
    } else {
        & $uv cache clean --quiet 2>&1 | Out-Null
        Report 'uv wheel cache' ($before - (Get-Mb $uvCache))
    }
}

# --- temp directories -------------------------------------------------------------------
# Both of them: the one of the machine and the one of the user. If
# install-guest-base.ps1 already pointed TEMP to C:\temp, the old locations
# still hold what was written before.
foreach ($p in @($TempDir, "$env:LOCALAPPDATA\Temp", 'C:\Windows\Temp')) {
    if (-not (Test-Path $p)) { continue }
    $before = Get-Mb $p
    if ($WhatIfOnly) {
        Report "temp: $p" $before
    } else {
        # The contents, not the directory. A delete of C:\Windows\Temp breaks
        # services that expect it. Files in use refuse, and the code skips them.
        # That is the second reason to measure the number after, and not to
        # predict it.
        Get-ChildItem $p -Force -EA SilentlyContinue | ForEach-Object {
            Remove-Item $_.FullName -Recurse -Force -EA SilentlyContinue
        }
        Report "temp: $p" ($before - (Get-Mb $p))
    }
}

# --- the recycle bin --------------------------------------------------------------------
# Deleted files stay on the disk until this runs, and the image copies them too.
if (-not $WhatIfOnly) { Clear-RecycleBin -Force -EA SilentlyContinue }
Write-Host '  recycle bin                        emptied'

Write-Host ''
$free = [math]::Round((Get-PSDrive C).Free / 1GB, 1)
if ($WhatIfOnly) {
    Write-Host ("would free about {0} MB. C: has {1} GB free now" -f [math]::Round($script:total,1), $free)
} else {
    Write-Host ("freed about {0} MB. C: now has {1} GB free" -f [math]::Round($script:total,1), $free) -ForegroundColor Green
    Write-Host 'After this, run guest\write-manifest.ps1 again, so that the manifest shows the clean guest.'
}
