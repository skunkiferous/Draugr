# install-netfx3.ps1 - .NET Framework 3.5, offline, from the Windows installation media.
#
# ==> RUN THIS IN THE GUEST. <==
#
# WHY IT IS IN THE BASE. Unreal wants it: MEASURED, installing UE 4.27 in a
# guest raised Windows' own "An app on your PC needs the following Windows feature: .NET
# Framework 3.5 (includes .NET 2.0 and 3.0)". It is not an Unreal-version thing so much as
# an old-Windows-software thing, and every engine layer would otherwise hit it separately.
#
# WHY THE PROMPT'S OWN BUTTON CANNOT WORK HERE. NetFx3 is a Feature on Demand: the payload
# is NOT on the installed system, and Windows fetches it from Windows Update. In this guest
# that fails twice over - install-guest-base.ps1 turns Windows Update off, and the guest has
# no adapter, so even with it on there is no route to Microsoft. The dialog reports a
# download failure and says nothing about either cause.
#
# SO THE PAYLOAD COMES FROM THE ISO. Every Windows ISO carries it in \sources\sxs, about
# 68 MB for 25H2. /LimitAccess is the load-bearing switch: without it DISM tries Windows
# Update FIRST even when given a /Source, and the failure looks like the source was wrong.
#
# THE CAB MUST MATCH THE GUEST'S BUILD. A 25H2 cab on a 25H2 guest works; a mismatch fails
# with 0x800f081f, "the source files could not be found", which reads as a missing file
# rather than as a version problem. Take it from the ISO the guest was installed from.
#
# TWO ROUTES TO THE PAYLOAD, and `dr-layer provision` takes the second one.
#
#   -Share/-SubDir   the vault, over the loopback SMB share. The original road, and still
#                    the right one when you are running this by hand in a guest that has
#                    the vault mounted. Put the cab beside the other installers:
#                      <vault>\installers\sxs\microsoft-windows-netfx3-ondemand-package~*.cab
#   -Source          a folder already in the guest. This is what provision uses: it pushes
#                    the cab in over ssh from a path you named on the HOST with --netfx.
#                    The check then happens before phase 0 rather than after phase 11, and
#                    it works on a gateway that serves no vault at all. docs/FORGE.md,
#                    "2c, the optional component".
#
#   powershell -ExecutionPolicy Bypass -File .\install-netfx3.ps1
#   powershell -ExecutionPolicy Bypass -File .\install-netfx3.ps1 -Source C:\temp\sxs
#   powershell -ExecutionPolicy Bypass -File .\install-netfx3.ps1 -VerifyOnly
param(
    [string]$Share    = '\\127.0.0.1\vault',
    [string]$SubDir   = 'installers\sxs',
    [string]$User     = 'agent',
    [string]$PassFile = "$env:ProgramData\draugr-vault\smb.pass",
    [string]$Source   = '',          # a folder holding the cab; skips the vault entirely
    [switch]$VerifyOnly
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Get-NetFx3State {
    # Get-WindowsOptionalFeature needs a full token. An ssh session here already has one
    # (measured - see lib/forge/provision.ps1's notes on the guest's sshd), so this is not
    # wrapped in an elevation check that would only ever be wrong.
    try { (Get-WindowsOptionalFeature -Online -FeatureName NetFx3 -EA Stop).State }
    catch { 'Unknown' }
}

$state = Get-NetFx3State

if ($VerifyOnly) {
    Write-Host ''
    Write-Host '--- verification ---'
    Write-Host "  NetFx3      $state"
    $ndp = 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v3.5'
    $inst = (Get-ItemProperty $ndp -Name Install -EA SilentlyContinue).Install
    Write-Host ("  NDP\v3.5    {0}" -f $(if ($inst -eq 1) { 'Install=1' } else { 'not registered' }))
    if ($state -ne 'Enabled') { exit 1 }
    exit 0
}

if ($state -eq 'Enabled') {
    Write-Host "NetFx3 already enabled - nothing to do"
    exit 0
}

# --- find the payload -------------------------------------------------------------------
$dir = $Source
if (-not $dir) {
    # Same dance as install-vscode.ps1: the share may not be connected in THIS session, and
    # `net use` writes "already connected" to stderr, which would terminate the script under
    # $ErrorActionPreference = 'Stop'.
    if (Test-Path $PassFile) {
        $pw = (Get-Content $PassFile -Raw).Trim()
        $old = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try { & net use $Share $pw "/user:$User" 2>&1 | Out-Null } finally { $ErrorActionPreference = $old }
    }
    $dir = Join-Path $Share $SubDir
}

# Globbed, not named: the cab carries a build-specific suffix and a locale, and hardcoding
# one spelling turns a working payload into "not found" after the next Windows release.
$cab = @(Get-ChildItem $dir -Filter '*netfx3*.cab' -EA SilentlyContinue | Sort-Object Length -Descending)
if (-not $cab) {
    Write-Host "no *netfx3*.cab in $dir" -ForegroundColor Red
    Write-Host ''
    Write-Host 'Extract it from the Windows ISO the guest was installed from:'
    Write-Host '  mount the ISO read-only on the HOST, then copy'
    Write-Host '    <iso>:\sources\sxs\microsoft-windows-netfx3-ondemand-package~*~amd64~~.cab'
    Write-Host "  into  $dir"
    Write-Host 'It MUST come from a matching Windows build, or DISM fails with 0x800f081f.'
    exit 2
}

# COPIED LOCALLY FIRST. DISM against a UNC /Source is its own class of intermittent
# failure, and 68 MB over the loopback share is seconds. Same bargain install-vscode.ps1
# makes with the installer.
$local = Join-Path $env:TEMP 'draugr-sxs'
New-Item -ItemType Directory -Force -Path $local | Out-Null
Write-Host "copying $($cab[0].Name) ($([math]::Round($cab[0].Length/1MB,1)) MB)..."
Copy-Item $cab[0].FullName $local -Force

# --- enable ------------------------------------------------------------------------------
# /All   - pull in the parent features NetFx3 depends on rather than failing on them.
# /LimitAccess - do NOT consult Windows Update. See the header: this is the switch that
#                makes an offline guest work instead of timing out against a host it
#                cannot reach, and then blaming the source.
Write-Host 'enabling NetFx3 from the local payload...'
& dism.exe /Online /Enable-Feature /FeatureName:NetFx3 /All /LimitAccess "/Source:$local" |
    Select-Object -Last 3 | ForEach-Object { Write-Host "  $_" }
$rc = $LASTEXITCODE
Remove-Item $local -Recurse -Force -EA SilentlyContinue
if ($rc -ne 0) { throw "dism exited $rc (0x800f081f usually means the cab does not match this Windows build)" }

# --- verification: by effect --------------------------------------------------------------
Write-Host ''
Write-Host '--- verification ---'
$state = Get-NetFx3State
Write-Host "  NetFx3      $state"
$ndp = 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v3.5'
$inst = (Get-ItemProperty $ndp -Name Install -EA SilentlyContinue).Install
Write-Host ("  NDP\v3.5    {0}" -f $(if ($inst -eq 1) { 'Install=1' } else { 'not registered' }))
if ($state -ne 'Enabled') { Write-Host 'INCOMPLETE' -ForegroundColor Red; exit 1 }
Write-Host '.NET Framework 3.5 enabled.' -ForegroundColor Green
