# install-vscode.ps1: Visual Studio Code in the forge guest, from the vault or
# from the internet.
#
# WHY IT IS IN THE BASE, AND THE EXTENSION IS NOT. Each Windows VM wants the VS
# Code editor, so it belongs next to MSYS2 and AutoHotkey. The "Unreal
# Angelscript" extension does not. Only a VM that works on an Angelscript engine
# needs it, and there it is one line: `code --install-extension
# Hazelight.unreal-angelscript`. In the base, it puts a choice for one project
# into a frozen layer.
#
# WHY THE VAULT COPY IS IMPORTANT. The installer is 233 MB, and the only route
# out of the guest is the proxy through the ssh tunnel. That is not fast and not
# free. With a copy in the vault, a rebuild is a file copy, not a download. The
# same reason as for the Visual Studio layouts.
#
# UNC, NOT V:. This script runs through ssh, in session 0, and a mapped drive
# belongs to a logon session. Thus V: does not exist here, for each setup of the
# desktop (see mount-vault.ps1 next to this one for the full trap). The code
# reaches the share by its UNC path, with the same credential as mount-vault.
# That credential DOES NOT depend on the session.
#
#   powershell -ExecutionPolicy Bypass -File .\install-vscode.ps1
#   powershell -ExecutionPolicy Bypass -File .\install-vscode.ps1 -VerifyOnly
#   powershell -ExecutionPolicy Bypass -File .\install-vscode.ps1 -Installer D:\mine.exe
param(
    # MEASURED on the copy in D:\VaultHolder\installers: 244,372,864 bytes,
    # ProductVersion 1.140.0, Authenticode Valid, CN=Microsoft Corporation.
    # Change -Version and -Sha256 together, or not at all. Half a pin is worse
    # than none, because it still looks like one.
    [string]$Version  = '1.140.0',
    [string]$Sha256   = 'f2580caea258d6d6be9342717973eff4624d5e05439e77daab2dcecf68c8b2f1',
    [string]$Share    = '\\127.0.0.1\vault',
    [string]$SubDir   = 'installers',
    [string]$User     = 'agent',
    [string]$PassFile = "$env:ProgramData\draugr-vault\smb.pass",
    [string]$Installer = '',            # an explicit path. The pin is still tested
    [switch]$VerifyOnly
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$codeExe = 'C:\Program Files\Microsoft VS Code\Code.exe'
$url = "https://code.visualstudio.com/sha/download?build=stable&os=win32-x64"

function Get-InstalledVersion {
    if (Test-Path $codeExe) { (Get-Item $codeExe).VersionInfo.ProductVersion } else { $null }
}

# --- already here? -------------------------------------------------------------------
$have = Get-InstalledVersion
if ($have) {
    Write-Host "VS Code $have already installed: $codeExe"
    if (-not $VerifyOnly -and $have -ne $Version) {
        Write-Host "  (the pin says $Version. The installed one does not change. To change it, give -Installer)"
    }
}

if ($VerifyOnly) {
    Write-Host ''
    Write-Host '--- verification ---'
    $v = Get-InstalledVersion
    Write-Host ("  code        {0}" -f $(if ($v) { "$v  ($codeExe)" } else { 'NOT INSTALLED' }))
    $cmd = Get-Command code -ErrorAction SilentlyContinue
    Write-Host ("  on PATH     {0}" -f $(if ($cmd) { $cmd.Source } else { 'no. `code` does not resolve' }))
    if (-not $v) { exit 1 }
    exit 0
}

if (-not $have) {
    # --- find the installer: the vault first, then the internet ----------------------
    $local = Join-Path $env:TEMP "VSCodeSetup-x64-$Version.exe"
    $source = $null

    if ($Installer) {
        if (-not (Test-Path $Installer)) { throw "missing: $Installer" }
        Copy-Item $Installer $local -Force
        $source = "the file that you gave ($Installer)"
    } else {
        # The share is possibly not connected in this session yet. mount-vault
        # does `net use` with the credential. EAP is relaxed, because "already
        # connected" goes to stderr, and otherwise stops the script.
        if (Test-Path $PassFile) {
            $pw = (Get-Content $PassFile -Raw).Trim()
            $old = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            try { & net use $Share $pw "/user:$User" 2>&1 | Out-Null } finally { $ErrorActionPreference = $old }
        }

        # Both names. The vault can hold it with a version, as its neighbors
        # (EpicInstaller-20.3.3-unrealEngine.exe), or with the name of the
        # vendor.
        foreach ($name in "VSCodeSetup-x64-$Version.exe", 'VSCodeSetup-x64.exe') {
            $cand = Join-Path (Join-Path $Share $SubDir) $name
            if (Test-Path $cand) {
                Write-Host "copying $name from the vault..."
                # COPIED, then hashed locally. A hash through the share and then
                # a copy sends 233 MB through the tunnel twice. An installer
                # that runs directly from a UNC path has its own problems.
                Copy-Item $cand $local -Force
                $source = "the vault ($cand)"
                break
            }
        }

        if (-not $source) {
            Write-Host "not in the vault. Downloading $Version from code.visualstudio.com..."
            Write-Host '  (233 MB through the proxy. With a copy in the vault, this is a file copy.)'
            Invoke-WebRequest -UseBasicParsing $url -OutFile $local
            $source = 'code.visualstudio.com'
        }
    }

    # --- the pin, then the signature -------------------------------------------------
    # They answer different questions. The pin says "this exact build". The
    # signature says "and Microsoft signed it". Neither replaces the other.
    $got = (Get-FileHash $local -Algorithm SHA256).Hash.ToLower()
    if ($got -ne $Sha256.ToLower()) {
        # Deleted, not left in TEMP, for the reason in install-msys2.ps1. A
        # refused installer on the disk is one careless double-click from a run.
        Remove-Item $local -Force -EA SilentlyContinue
        throw ("VS Code installer hash mismatch. NOTHING was installed, and the file was deleted." +
               "`n  from     $source" +
               "`n  expected $($Sha256.ToLower())" +
               "`n  got      $got" +
               "`n  The vendor made the build again (then change -Version and" +
               " -Sha256 together), or this is not the file that it claims to be.")
    }
    Write-Host "  the sha256 is the same as the pin ($([math]::Round((Get-Item $local).Length/1MB,1)) MB, from $source)"

    $sig = Get-AuthenticodeSignature $local
    if ($sig.Status -ne 'Valid') { throw "the signature of the installer is '$($sig.Status)', not Valid: $local" }
    Write-Host "  signed by: $($sig.SignerCertificate.Subject -replace ',.*','')"

    # --- install ---------------------------------------------------------------------
    # Start-Process -Wait, and not for style. The setup binary is GUI-subsystem,
    # so a bare call returns at once with $LASTEXITCODE 0, whatever happens
    # next. vs_setup.exe had exactly that trap (docs/FORGE.md, the Visual Studio
    # section).
    #
    # !runcode:  do not start the editor at the end. Nobody is at the screen.
    # addtopath: `code` on PATH. That is the only way that an agent uses it.
    Write-Host "installing VS Code $Version..."
    $p = Start-Process -FilePath $local `
         -ArgumentList '/VERYSILENT','/NORESTART','/MERGETASKS=!runcode,addtopath' -Wait -PassThru
    Remove-Item $local -Force -EA SilentlyContinue
    if ($p.ExitCode -ne 0) { throw "the VS Code installer exited $($p.ExitCode)" }
}

# --- verification: by effect ----------------------------------------------------------
Write-Host ''
Write-Host '--- verification ---'
$bad = @()
$v = Get-InstalledVersion
if ($v) { Write-Host "  code        $v  ($codeExe)" }
else    { Write-Host '  code        MISSING' -ForegroundColor Red; $bad += 'code' }

# The installer edits the MACHINE PATH, and this running process cannot see
# that. Thus the code asks the registry, not $env:PATH. "Not on PATH" here, only
# because of process inheritance, is a false alarm, exactly of the kind that
# this project often finds.
$binDir = 'C:\Program Files\Microsoft VS Code\bin'
$onPath = ([Environment]::GetEnvironmentVariable('Path','Machine') -split ';') |
          Where-Object { $_.TrimEnd('\') -ieq $binDir }
Write-Host ("  on PATH     {0}" -f $(if ($onPath) { "$binDir (new processes)" }
                                     else { 'NOT on the machine PATH' }))
if (-not $onPath) { $bad += 'PATH' }

Write-Host ''
Write-Host 'The "Unreal Angelscript" extension is NOT installed here, on purpose. It belongs'
Write-Host 'in the VM that uses it, not in a frozen base:'
Write-Host '  code --install-extension Hazelight.unreal-angelscript'
Write-Host ''
if ($bad.Count) { Write-Host "INCOMPLETE: $($bad -join ', ')" -ForegroundColor Red; exit 1 }
Write-Host 'VS Code is installed and reachable.' -ForegroundColor Green
