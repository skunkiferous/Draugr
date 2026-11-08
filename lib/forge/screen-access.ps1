# screen-access.ps1: give the forge VM a screen that a person can reach.
#
# ==> RUNS ON THE WINDOWS HOST. The screen phase of lib/forge/provision.ps1 calls it. <==
# ==> You can also run it by hand on a guest that is older than that phase.           <==
#
# It comes from a hand-written script, where all the tests below were made. It
# has no install- prefix. In Draugr, that prefix means "runs in the guest", in
# lib/forge/guest/. This one reaches INTO the guest from here (docs/FORGE.md,
# "2b's own five decisions").
#
# Once for each guest, over the admin SSH channel, it:
#
#   1. makes (or reuses) an 8-character VNC password at
#      %USERPROFILE%\.ssh\draugr_vnc.pass. Eight is the limit of the protocol, not a
#      choice. VNC cuts the rest. It guards against accidents. The real boundary is the
#      SSH key, because the server listens only on the loopback of the guest.
#   2. copies the TightVNC MSI, the password and guest\install-screen-server.ps1
#      into %ProgramData%\draugr-screen in the guest
#   3. runs the guest script. It installs the server on loopback only, sets the
#      registry, and starts the service. Then it deletes the password file and the
#      installer from the guest.
#   4. if it is missing, installs the VIEWER half on this host from the same MSI.
#      -SkipHostViewer does not touch the host. provision.ps1 gives it, unless you
#      ask otherwise. That step elevates, and an unattended run of one hour must not
#      stop for a UAC prompt. A later install loses nothing. lib/forge/screen.ps1
#      keeps the forward up, and tells you that each viewer on it works.
#
# The MSI comes from the vendor, and this script compares it to a PIN here: a
# named version and its SHA-256. Thus the VM gets one exact, known build, not
# "what the download page serves today". A test showed that the live vendor file
# has the same hash as the copy of this repo. A mismatch is a hard stop, never a
# warning. To use your own file, give -Msi. That skips the pin, and tests only
# the signature.
#
# THE CHOICE OF SERVER. The guest is Windows Home, has no adapter, needs no
# account, and must listen on loopback only. For that, two candidates exist, and
# they are not the same:
#
#   TightVNC 2.8.88   GPL-2.0. 2.5 MB. Signed by OOO GlavSoft (Tomsk, Russia). Publishes
#                     no checksums, so the pin below is ours. Its configuration is in the
#                     registry, which guest\install-screen-server.ps1 sets.
#                     A test showed that it works in this guest.
#   UltraVNC 1.8.3.0  GPL-2.0, uvnc.com (Belgium). Publishes a SHA-256 for each file. Has
#                     a mirror driver, which redraws a 3D app better. Also has MS-logon
#                     auth and DSM encryption.
#
# UltraVNC is NOT a -Vnc choice, and a test showed why. Its download link is a
# jDownloads page that needs a session, and answers text/html, not the file
# (tested with HEAD and GET). Thus a script cannot download or pin it. Also, its
# configuration is in ultravnc.ini, not the registry, so the guest-side
# hardening here does not apply. If you want it, download it yourself. Make sure
# that the SHA-256 is the same as on the release page, and give -Msi. That path
# always worked.
#
# All other choices fail. RealVNC needs an account. The Windows server of
# TigerVNC is an old TightVNC 1.3 copy with no maintenance. The rest are
# viewers, or only for Linux.
#
# After that, `dr-forge screen` is the one action that shows the screen.
#
#   powershell -ExecutionPolicy Bypass -File .\lib\forge\screen-access.ps1 -Vm UE5-Test -AdminKey <path>
#   powershell -ExecutionPolicy Bypass -File .\lib\forge\screen-access.ps1 -Vm UE5-Test -AdminKey <path> -Msi <my-own.msi>
param(
    [string]$Vm       = 'UE5-Test',
    [Parameter(Mandatory)][string]$AdminKey,
    # WHERE THE GUEST IS, if the caller already knows. provision.ps1 got both
    # from the daemon before its first phase. Thus they cost nothing, and the
    # two host-side scripts and provision use ONE answer, not three lookups.
    # Without them, this asks the daemon itself, as before.
    [int]   $SshPort   = 0,
    [string]$GuestUser = '',
    [string]$Msi,
    [ValidateSet('TightVNC')][string]$Vnc = 'TightVNC',
    # NOT in the repository, for a reason. A mound can read a 2.5 MB vendor MSI
    # in the checkout, and git must ignore it. The other host-side state of the
    # forge is already in %LOCALAPPDATA%\Draugr (the tunnel and screen logs),
    # and it stays after you delete a clone.
    [string]$CacheDir = "$env:LOCALAPPDATA\Draugr\vnc",
    [string]$PassFile = "$env:USERPROFILE\.ssh\draugr_vnc.pass",
    [switch]$SkipHostViewer
)

$ErrorActionPreference = 'Stop'
if (-not (Test-Path $AdminKey)) { throw "missing: $AdminKey" }

# One pinned build for each supported server. Change all three fields together.
# Before you commit the change, compare the hash with the vendor again.
$pins = @{
    TightVNC = @{
        Version = '2.8.88'
        File    = 'tightvnc-2.8.88-gpl-setup-64bit.msi'
        Url     = 'https://www.tightvnc.com/download/2.8.88/tightvnc-2.8.88-gpl-setup-64bit.msi'
        Sha256  = 'fa86d817ac29c5ffe1e8e7095e738d9ba5ca28aa62304ac234580916622a8ca2'
    }
}

if ($Msi) {
    if (-not (Test-Path $Msi)) { throw "missing: $Msi" }
    Write-Host "using the MSI you passed: $Msi (pin not checked)"
} else {
    $pin = $pins[$Vnc]
    if (-not (Test-Path $CacheDir)) { New-Item -ItemType Directory -Force -Path $CacheDir | Out-Null }
    $Msi = Join-Path $CacheDir $pin.File

    # If a cached file still matches the pin, this uses it. If not, it
    # downloads again. From here, a half-written download and a changed one look
    # the same.
    $have = (Test-Path $Msi) -and ((Get-FileHash $Msi -Algorithm SHA256).Hash -eq $pin.Sha256)
    if ($have) {
        Write-Host "$Vnc $($pin.Version): the cached copy matches the pin"
    } else {
        Write-Host "downloading $Vnc $($pin.Version) from $($pin.Url)"
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -UseBasicParsing $pin.Url -OutFile $Msi
        $got = (Get-FileHash $Msi -Algorithm SHA256).Hash
        if ($got -ne $pin.Sha256) {
            Remove-Item $Msi -Force -EA SilentlyContinue
            throw ("$Vnc checksum mismatch. NOT installing. expected $($pin.Sha256), got $got. " +
                   'Either the vendor re-rolled the build (update the pin deliberately) or this ' +
                   'is not the file it should be.')
        }
        Write-Host "  the sha256 matches the pin ($([math]::Round((Get-Item $Msi).Length/1MB,1)) MB)"
    }
}

# The signature is always tested. The pin says "this exact build". The signature
# says "and the vendor signed it". Each answers a different question.
$sig = Get-AuthenticodeSignature $Msi
if ($sig.Status -ne 'Valid') { throw "the MSI's signature is '$($sig.Status)', not Valid: $Msi" }
Write-Host "MSI signed by: $($sig.SignerCertificate.Subject)"

# --- the password ----------------------------------------------------------
if (-not (Test-Path $PassFile)) {
    $bytes = New-Object byte[] 16
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    $alphabet = 'abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789'
    $pw = -join (0..7 | ForEach-Object { $alphabet[$bytes[$_] % $alphabet.Length] })
    [IO.File]::WriteAllText($PassFile, $pw)
    Write-Host "new VNC password written to $PassFile"
} else {
    Write-Host "reusing the VNC password in $PassFile"
}

# --- where is the guest? ---------------------------------------------------
# The daemon knows the ssh port and user. If it is down, vms.cfg is the
# fallback.
function Get-SshFromApi([string]$Name) {
    $hj = Join-Path $env:ProgramData 'AppSandbox\host.json'
    if (-not (Test-Path $hj)) { return $null }
    try {
        $h = Get-Content $hj -Raw | ConvertFrom-Json
        return Invoke-RestMethod -Uri "$($h.endpoint)/v1/vms/$Name/sshInfo" -TimeoutSec 10 `
            -Headers @{ Authorization = "Bearer $($h.token)" }
    } catch { return $null }
}
# -SshPort and -GuestUser together skip the lookup. Give both or neither. With
# half an answer, the script connects to the port of one guest as the user of
# another. That signs in, and then you see a different desktop than you expect.
#
# NOT CALLED -User, and not for style. PowerShell variable names are
# case-INSENSITIVE. A parameter $User and the $user of this script are one
# variable. Then the else branch below changes the argument of the caller.
if ($SshPort -and $GuestUser) {
    $port = $SshPort
    $user = $GuestUser
} else {
    $ssh = Get-SshFromApi $Vm
    if (-not $ssh) { throw "the AppSandbox daemon does not answer. Start it with --headless, and the VM" }
    $port = $ssh.port
    $user = $ssh.user
}
Write-Host "guest: $user@127.0.0.1:$port"

# HostKeyAlias: the key belongs to the VM, not to a port that guests use in
# turn.
$opts = @('-o', 'StrictHostKeyChecking=accept-new', '-o', "HostKeyAlias=draugr-$Vm",
          '-o', 'BatchMode=yes', '-o', 'IdentitiesOnly=yes')
$dest = 'C:/ProgramData/draugr-screen'

& ssh.exe -i $AdminKey -p $port @opts "$user@127.0.0.1" "cmd /c mkdir `"$($dest -replace '/','\')`" 2>nul & exit 0"
& scp.exe -i $AdminKey -P $port @opts $Msi      "${user}@127.0.0.1:$dest/tightvnc-setup.msi"
& scp.exe -i $AdminKey -P $port @opts $PassFile "${user}@127.0.0.1:$dest/vnc.pass"
& scp.exe -i $AdminKey -P $port @opts (Join-Path $PSScriptRoot 'guest\install-screen-server.ps1') `
    "${user}@127.0.0.1:$dest/install-screen-server.ps1"

& ssh.exe -i $AdminKey -p $port @opts "$user@127.0.0.1" `
    "powershell -NoProfile -ExecutionPolicy Bypass -File $($dest -replace '/','\')\install-screen-server.ps1"
if ($LASTEXITCODE -ne 0) { throw "the guest installer failed (exit $LASTEXITCODE)" }

# --- the viewer, on this host ----------------------------------------------
if (-not $SkipHostViewer) {
    $viewer = "$env:ProgramFiles\TightVNC\tvnviewer.exe"
    if (Test-Path $viewer) {
        Write-Host "the host viewer is already present: $viewer"
    } else {
        Write-Host 'installing the viewer half on this host (elevation prompt)...'
        $p = Start-Process msiexec.exe -Wait -PassThru -Verb RunAs -ArgumentList `
            @('/i', "`"$Msi`"", '/quiet', '/norestart', 'ADDLOCAL=Viewer')
        if ($p.ExitCode -ne 0) { throw "viewer install exited $($p.ExitCode)" }
        Write-Host "installed: $viewer"
    }
}

Write-Host ''
Write-Host 'Done. To look at the VM:'
Write-Host '    dr-forge screen'
Write-Host "The password is in $PassFile. The viewer asks for it."
# Said here, because only this script knows that it just wrote the file. Also,
# draugr_vnc.pass is often the only record of the VNC password of a guest.
# Nothing in Draugr deletes it, and the guest keeps the password in the
# registry, not in a file.
Write-Host 'Keep that file. It is the only copy on this side.'
