# install-vscode.ps1 - Visual Studio Code in the forge guest, from the vault if it is there.
#
# WHY IT IS IN THE BASE AND THE EXTENSION IS NOT. VS Code is the editor any Windows VM
# would want, so it belongs beside MSYS2 and AutoHotkey. The "Unreal Angelscript" extension
# is not: it is needed only in a VM actually working on an Angelscript engine, and it is one
# line there - `code --install-extension Hazelight.unreal-angelscript`. Putting it in the
# base would bake a per-project choice into a frozen layer.
#
# WHY THE VAULT COPY MATTERS. The installer is 233 MB, and the guest's only route out is the
# proxy over the ssh tunnel, which is neither fast nor free. A copy in the vault turns a
# rebuild from a download into a file copy. Same bargain as the Visual Studio layouts.
#
# UNC, NOT V:. This script runs over ssh, in session 0, and a mapped drive belongs to a
# logon session - so V: does not exist here however the desktop is set up (see
# mount-vault.ps1 beside this one for the full version of that trap). The share is reached by its UNC
# path with the same credential mount-vault uses, which IS session-independent.
#
#   powershell -ExecutionPolicy Bypass -File .\install-vscode.ps1
#   powershell -ExecutionPolicy Bypass -File .\install-vscode.ps1 -VerifyOnly
#   powershell -ExecutionPolicy Bypass -File .\install-vscode.ps1 -Installer D:\mine.exe
param(
    # MEASURED against the copy in D:\VaultHolder\installers: 244,372,864 bytes,
    # ProductVersion 1.140.0, Authenticode Valid, CN=Microsoft Corporation. Move -Version
    # and -Sha256 together or not at all - half a pin is worse than none, because it still
    # reads like one.
    [string]$Version  = '1.140.0',
    [string]$Sha256   = 'f2580caea258d6d6be9342717973eff4624d5e05439e77daab2dcecf68c8b2f1',
    [string]$Share    = '\\127.0.0.1\vault',
    [string]$SubDir   = 'installers',
    [string]$User     = 'agent',
    [string]$PassFile = "$env:ProgramData\draugr-vault\smb.pass",
    [string]$Installer = '',            # an explicit path; the pin is still checked
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
        Write-Host "  (the pin says $Version - leaving the installed one alone; pass -Installer to change it)"
    }
}

if ($VerifyOnly) {
    Write-Host ''
    Write-Host '--- verification ---'
    $v = Get-InstalledVersion
    Write-Host ("  code        {0}" -f $(if ($v) { "$v  ($codeExe)" } else { 'NOT INSTALLED' }))
    $cmd = Get-Command code -ErrorAction SilentlyContinue
    Write-Host ("  on PATH     {0}" -f $(if ($cmd) { $cmd.Source } else { 'no - `code` will not resolve' }))
    if (-not $v) { exit 1 }
    exit 0
}

if (-not $have) {
    # --- find the installer: vault first, then the internet --------------------------
    $local = Join-Path $env:TEMP "VSCodeSetup-x64-$Version.exe"
    $source = $null

    if ($Installer) {
        if (-not (Test-Path $Installer)) { throw "missing: $Installer" }
        Copy-Item $Installer $local -Force
        $source = "the file you passed ($Installer)"
    } else {
        # The share may not be connected in this session yet. `net use` with the credential
        # is what mount-vault does; EAP is relaxed because "already connected" is written to
        # stderr and would otherwise terminate the script.
        if (Test-Path $PassFile) {
            $pw = (Get-Content $PassFile -Raw).Trim()
            $old = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            try { & net use $Share $pw "/user:$User" 2>&1 | Out-Null } finally { $ErrorActionPreference = $old }
        }

        # Both spellings: the vault may hold it versioned, matching its neighbours
        # (EpicInstaller-20.3.3-unrealEngine.exe), or under the name the vendor ships.
        foreach ($name in "VSCodeSetup-x64-$Version.exe", 'VSCodeSetup-x64.exe') {
            $cand = Join-Path (Join-Path $Share $SubDir) $name
            if (Test-Path $cand) {
                Write-Host "copying $name from the vault..."
                # COPIED, then hashed locally. Hashing over the share and then copying
                # would stream 233 MB through the tunnel twice, and an installer run
                # straight off a UNC path is its own class of problem.
                Copy-Item $cand $local -Force
                $source = "the vault ($cand)"
                break
            }
        }

        if (-not $source) {
            Write-Host "not in the vault - downloading $Version from code.visualstudio.com..."
            Write-Host '  (233 MB through the proxy. Put a copy in the vault and this becomes a file copy.)'
            Invoke-WebRequest -UseBasicParsing $url -OutFile $local
            $source = 'code.visualstudio.com'
        }
    }

    # --- the pin, then the signature -------------------------------------------------
    # They answer different questions: the pin says "this exact build", the signature says
    # "and Microsoft signed it". Neither substitutes for the other.
    $got = (Get-FileHash $local -Algorithm SHA256).Hash.ToLower()
    if ($got -ne $Sha256.ToLower()) {
        # Deleted rather than left in TEMP, for the reason install-msys2.ps1 gives: a
        # rejected installer sitting on disk is one careless double-click from being run.
        Remove-Item $local -Force -EA SilentlyContinue
        throw ("VS Code installer hash mismatch - NOTHING was installed, and the file was deleted." +
               "`n  from     $source" +
               "`n  expected $($Sha256.ToLower())" +
               "`n  got      $got" +
               "`n  Either the vendor re-rolled the build, in which case move -Version and" +
               " -Sha256 together, or this is not the file it claims to be.")
    }
    Write-Host "  sha256 matches the pin ($([math]::Round((Get-Item $local).Length/1MB,1)) MB, from $source)"

    $sig = Get-AuthenticodeSignature $local
    if ($sig.Status -ne 'Valid') { throw "the installer's signature is '$($sig.Status)', not Valid: $local" }
    Write-Host "  signed by: $($sig.SignerCertificate.Subject -replace ',.*','')"

    # --- install ---------------------------------------------------------------------
    # Start-Process -Wait, and not because of taste: the setup binary is GUI-subsystem, so
    # a bare call returns instantly with $LASTEXITCODE 0 whatever happens next. Exactly the
    # trap vs_setup.exe laid (docs/FORGE.md, the Visual Studio section).
    #
    # !runcode   - do not launch the editor at the end; there is no one at the screen.
    # addtopath  - `code` on PATH, which is the only way an agent uses it.
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

# The installer edits the MACHINE PATH, which this already-running process cannot see, so
# the registry is asked rather than $env:PATH. Reporting "not on PATH" here because of
# process inheritance would be a false alarm of exactly the kind this project keeps hitting.
$binDir = 'C:\Program Files\Microsoft VS Code\bin'
$onPath = ([Environment]::GetEnvironmentVariable('Path','Machine') -split ';') |
          Where-Object { $_.TrimEnd('\') -ieq $binDir }
Write-Host ("  on PATH     {0}" -f $(if ($onPath) { "$binDir (new processes)" }
                                     else { 'NOT on the machine PATH' }))
if (-not $onPath) { $bad += 'PATH' }

Write-Host ''
Write-Host 'The "Unreal Angelscript" extension is deliberately NOT installed here - it belongs'
Write-Host 'in the VM that uses it, not in a frozen base:'
Write-Host '  code --install-extension Hazelight.unreal-angelscript'
Write-Host ''
if ($bad.Count) { Write-Host "INCOMPLETE: $($bad -join ', ')" -ForegroundColor Red; exit 1 }
Write-Host 'VS Code installed and reachable.' -ForegroundColor Green
