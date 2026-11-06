# cleanup.ps1 - take the build scaffolding back out before the image is kept.
#
# Run it IN THE GUEST, last, after everything is installed and verified. It removes what
# provisioning left behind and nothing else: no "optimisers", no registry cleaning, no
# uninstalling anything that was asked for.
#
# WHY IT IS A STEP AND NOT AN AFTERTHOUGHT. This disk becomes a base image, and every byte
# in it is copied for each layer above it and again for each archive - the flatten of this
# disk was measured at nearly 11 minutes. Package caches and staged installers are the
# largest thing on a freshly built guest that nobody will ever read again, and the moment
# to drop them is before the image is kept, not after it has been copied three times.
#
# It reports bytes reclaimed per item, because a cleanup step that prints nothing is one
# nobody can tell is working. Every figure outside -WhatIfOnly is a MEASURED DELTA - the
# size before minus the size after - and that is not pedantry: the first version printed
# the size it hoped to remove, which let `pacman -Sc` claim 33.2 MB while freeing nothing
# at all, run after run, with the same number every time (noticed, by a reader
# who correctly found the repetition suspicious).
#
# WHAT IT DELIBERATELY LEAVES: the MSYS2 package DATABASE (pacman -Q must keep working, it
# is what the manifest reads), the uv tool environments, logs under C:\Draugr, and the
# Windows component store. `DISM /StartComponentCleanup` can reclaim more but it is slow,
# irreversible for rollbacks, and has been known to take a machine down with it - it is
# not worth the minutes here.
#
#   powershell -ExecutionPolicy Bypass -File .\cleanup.ps1                # do it
#   powershell -ExecutionPolicy Bypass -File .\cleanup.ps1 -WhatIfOnly    # report what would go, change nothing
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

# --- the scripts provisioning staged, and the screen installer's working directory ----
# lib/forge/provision.ps1 copies each guest script into C:\Windows\Temp and runs it there.
# They are all in the repository; the copies are scaffolding.
$staged = @(Get-ChildItem 'C:\Windows\Temp' -Filter '*.ps1' -EA SilentlyContinue |
            Where-Object { $_.Name -match '^(install-|preflight|write-manifest|cleanup|audit)' })
$mb = [math]::Round((($staged | Measure-Object Length -Sum).Sum) / 1MB, 2)
Report "staged scripts ($($staged.Count))" $mb
Remove-Quietly @($staged.FullName)

# install-screen-server.ps1 already deletes the MSI and the password it was given; this
# is the directory they lived in, plus anything a failed run left behind.
$screen = 'C:\ProgramData\draugr-screen'
Report 'screen installer directory' (Get-Mb $screen)
Remove-Quietly @($screen)

# --- package caches -------------------------------------------------------------------
# pacman keeps every .pkg.tar.zst it has ever downloaded, and a base image will never read
# one again.
#
# WHY NOT `pacman -Sc`, WHICH IS WHAT THIS USED TO RUN. -Sc removes only packages that are
# NO LONGER INSTALLED. On a freshly built guest every cached file belongs to something
# still installed, so it removes precisely nothing - while this block reported the whole
# cache as "freed", because it measured the directory BEFORE the command and never looked
# again. MEASURED: it printed "freed 33.2 MB" and left 34 MB in 128 files.
#
# The files are deleted directly rather than with -Scc, which additionally prompts about
# the SYNC databases. NEITHER database is touched: /var/lib/pacman/local is what
# `pacman -Q` reads, and the manifest depends on it.
$bash = Join-Path $Msys 'usr\bin\bash.exe'
if (-not $SkipPacmanCache -and (Test-Path $bash)) {
    $cache = Join-Path $Msys 'var\cache\pacman\pkg'
    $before = Get-Mb $cache
    if ($WhatIfOnly) {
        Report 'pacman package cache' $before
    } else {
        # The redirect wraps the whole command because appending it to a pipeline
        # redirects only the last stage.
        & $bash -lc '( rm -f /var/cache/pacman/pkg/*.pkg.tar.* ) < /dev/null' 2>&1 | Out-Null
        Report 'pacman package cache' ($before - (Get-Mb $cache))
    }
}

# uv's wheel cache is a download accelerator: `prune` reclaims nothing once a tool is
# installed (measured 150.7 MB before and after, because every entry is still referenced),
# so a base image wants `clean`.
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
# Both of them: the machine one and the user one. If install-guest-base.ps1 has already
# pointed TEMP at C:\temp, the old locations still hold whatever was written before that.
foreach ($p in @($TempDir, "$env:LOCALAPPDATA\Temp", 'C:\Windows\Temp')) {
    if (-not (Test-Path $p)) { continue }
    $before = Get-Mb $p
    if ($WhatIfOnly) {
        Report "temp: $p" $before
    } else {
        # Contents, not the directory: deleting C:\Windows\Temp itself upsets services
        # that assume it exists, and in-use files simply refuse and are skipped - which is
        # the second reason the figure is measured afterwards rather than predicted.
        Get-ChildItem $p -Force -EA SilentlyContinue | ForEach-Object {
            Remove-Item $_.FullName -Recurse -Force -EA SilentlyContinue
        }
        Report "temp: $p" ($before - (Get-Mb $p))
    }
}

# --- the recycle bin --------------------------------------------------------------------
# Deleted files are still on the disk until this runs, and the image copies them too.
if (-not $WhatIfOnly) { Clear-RecycleBin -Force -EA SilentlyContinue }
Write-Host '  recycle bin                        emptied'

Write-Host ''
$free = [math]::Round((Get-PSDrive C).Free / 1GB, 1)
if ($WhatIfOnly) {
    Write-Host ("would reclaim about {0} MB; C: has {1} GB free now" -f [math]::Round($script:total,1), $free)
} else {
    Write-Host ("reclaimed about {0} MB; C: now has {1} GB free" -f [math]::Round($script:total,1), $free) -ForegroundColor Green
    Write-Host 'Re-run guest\write-manifest.ps1 afterwards so the manifest reflects the cleaned guest.'
}
