# install-netfx3.ps1: .NET Framework 3.5, offline, from the Windows installation
# media.
#
# ==> RUN THIS IN THE GUEST. <==
#
# WHY IT IS IN THE BASE. Unreal wants it. A TEST SHOWED THIS: the install of UE
# 4.27 in a guest showed the Windows message "An app on your PC needs the
# following Windows feature: .NET Framework 3.5 (includes .NET 2.0 and 3.0)". It
# is more a need of old Windows software than of one Unreal version. Without it
# in the base, each engine layer finds it separately.
#
# WHY THE BUTTON IN THE MESSAGE CANNOT WORK HERE. NetFx3 is a Feature on Demand.
# The payload is NOT on the installed system, and Windows fetches it from
# Windows Update. In this guest, that fails two times. install-guest-base.ps1
# turns Windows Update off, and the guest has no adapter, so it has no route to
# Microsoft, also with Windows Update on. The dialog reports a download failure,
# and tells neither cause.
#
# THUS THE PAYLOAD COMES FROM THE ISO. Each Windows ISO has it in \sources\sxs,
# about 68 MB for 25H2. /LimitAccess is the necessary switch. Without it, DISM
# tries Windows Update FIRST, also with a /Source, and the failure looks like a
# wrong source.
#
# THE CAB MUST MATCH THE BUILD OF THE GUEST. A 25H2 cab on a 25H2 guest works. A
# different build fails with 0x800f081f, "the source files could not be found".
# That looks like a missing file, not like a version problem. Take it from the
# ISO of the guest install.
#
# TWO ROUTES TO THE PAYLOAD. `dr-layer provision` takes the second one.
#
#   -Share/-SubDir   the vault, through the loopback SMB share. The original way. It is still
#                    correct for a manual run in a guest that has the vault mounted. Put the cab next to the other installers:
#                      <vault>\installers\sxs\microsoft-windows-netfx3-ondemand-package~*.cab
#   -Source          a folder already in the guest. provision uses this. It pushes the cab
#                    in through ssh, from a path that you named on the HOST with --netfx.
#                    The test then happens before phase 0, not after phase 11, and it works
#                    on a gateway that serves no vault. See docs/FORGE.md, "2c, the
#                    optional component".
#
#   powershell -ExecutionPolicy Bypass -File .\install-netfx3.ps1
#   powershell -ExecutionPolicy Bypass -File .\install-netfx3.ps1 -Source C:\temp\sxs
#   powershell -ExecutionPolicy Bypass -File .\install-netfx3.ps1 -VerifyOnly
param(
    [string]$Share    = '\\127.0.0.1\vault',
    [string]$SubDir   = 'installers\sxs',
    [string]$User     = 'agent',
    [string]$PassFile = "$env:ProgramData\draugr-vault\smb.pass",
    [string]$Source   = '',          # a folder with the cab. Skips the vault
    [switch]$VerifyOnly
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Get-NetFx3State {
    # Get-WindowsOptionalFeature needs a full token. An ssh session here already
    # has one (a test showed this, see the notes of lib/forge/provision.ps1
    # about the sshd of the guest). Thus it has no elevation test, because that
    # test can only be wrong.
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
    Write-Host "NetFx3 already enabled. Nothing to do."
    exit 0
}

# --- find the payload -------------------------------------------------------------------
$dir = $Source
if (-not $dir) {
    # The same steps as in install-vscode.ps1. The share is possibly not
    # connected in THIS session. `net use` writes "already connected" to stderr,
    # and under $ErrorActionPreference = 'Stop', that stops the script.
    if (Test-Path $PassFile) {
        $pw = (Get-Content $PassFile -Raw).Trim()
        $old = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try { & net use $Share $pw "/user:$User" 2>&1 | Out-Null } finally { $ErrorActionPreference = $old }
    }
    $dir = Join-Path $Share $SubDir
}

# A glob, not a name. The cab has a suffix for the build and a locale. A fixed
# name makes a working payload "not found" after the next Windows release.
$cab = @(Get-ChildItem $dir -Filter '*netfx3*.cab' -EA SilentlyContinue | Sort-Object Length -Descending)
if (-not $cab) {
    Write-Host "no *netfx3*.cab in $dir" -ForegroundColor Red
    Write-Host ''
    Write-Host 'Extract it from the Windows ISO of the guest install:'
    Write-Host '  mount the ISO read-only on the HOST, then copy'
    Write-Host '    <iso>:\sources\sxs\microsoft-windows-netfx3-ondemand-package~*~amd64~~.cab'
    Write-Host "  into  $dir"
    Write-Host 'It MUST come from the same Windows build, or DISM fails with 0x800f081f.'
    exit 2
}

# A LOCAL COPY FIRST. DISM with a UNC /Source fails sometimes, in its own way,
# and 68 MB through the loopback share takes seconds. install-vscode.ps1 does
# the same with the installer.
$local = Join-Path $env:TEMP 'draugr-sxs'
New-Item -ItemType Directory -Force -Path $local | Out-Null
Write-Host "copying $($cab[0].Name) ($([math]::Round($cab[0].Length/1MB,1)) MB)..."
Copy-Item $cab[0].FullName $local -Force

# --- enable ------------------------------------------------------------------------------
# /All:         add the parent features that NetFx3 needs, and do not fail on
# them. /LimitAccess: do NOT ask Windows Update. See the header. This switch
# makes an offline
#               guest work. Without it, DISM waits for a host that it cannot reach, and
#               then blames the source.
Write-Host 'enabling NetFx3 from the local payload...'
& dism.exe /Online /Enable-Feature /FeatureName:NetFx3 /All /LimitAccess "/Source:$local" |
    Select-Object -Last 3 | ForEach-Object { Write-Host "  $_" }
$rc = $LASTEXITCODE
Remove-Item $local -Recurse -Force -EA SilentlyContinue
if ($rc -ne 0) { throw "dism exited $rc (0x800f081f usually means that the cab is not for this Windows build)" }

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
