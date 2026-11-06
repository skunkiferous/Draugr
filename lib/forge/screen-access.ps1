# screen-access.ps1 - give the forge VM a screen a human can reach.
#
# ==> RUN ON THE WINDOWS HOST. Called by lib/forge/provision.ps1's screen phase, and <==
# ==> usable by hand on a guest that predates it.                                    <==
#
# Adopted from a hand-written predecessor, where every
# measurement below was made. It keeps the install- prefix nowhere: in Draugr that prefix
# means "runs in the guest" and lives in lib/forge/guest/, and this one reaches INTO the
# guest from here (docs/FORGE.md, "2b's own five decisions").
#
# Once per guest, over the admin SSH channel it:
#
#   1. makes (or reuses) an 8-character VNC password at
#      %USERPROFILE%\.ssh\draugr_vnc.pass. Eight is the protocol's limit, not a
#      choice - VNC truncates. It guards against accident; the real boundary is the
#      SSH key, because the server only ever listens on the guest's loopback.
#   2. copies the TightVNC MSI, the password and guest\install-screen-server.ps1
#      into %ProgramData%\draugr-screen in the guest
#   3. runs the guest script, which installs the server loopback-only, asserts the
#      registry, starts the service and deletes both the password file and the
#      installer from the guest afterwards
#   4. installs the VIEWER half on this host from the same MSI, if it is missing.
#      -SkipHostViewer leaves the host alone, which is what provision.ps1 passes unless
#      you asked it not to: that step elevates, and an hour-long unattended run must not
#      stop to raise a UAC prompt. Nothing is lost by deferring it - lib/forge/screen.ps1
#      leaves the forward up and says any viewer pointed at it will do.
#
# The MSI is fetched from the vendor and checked against a PIN recorded here - a named
# version and its SHA-256 - so what goes into the VM is one exact known build rather than
# "whatever the download page serves today". Verified: the live vendor file
# hashes identically to the copy this repo was built against. A mismatch is a hard stop,
# never a warning. Pass -Msi to use your own file instead, which skips the pin and checks
# only the signature.
#
# ON THE CHOICE OF SERVER. For a guest that is Windows Home, has no adapter, needs no
# account and must listen on loopback only, there are two candidates worth the words, and
# they are not interchangeable:
#
#   TightVNC 2.8.88   GPL-2.0. 2.5 MB. Signed by OOO GlavSoft (Tomsk, Russia). Publishes
#                     no checksums, so the pin below is ours. Configured through the
#                     registry, which is what guest\install-screen-server.ps1 asserts.
#                     Measured working in this guest.
#   UltraVNC 1.8.3.0  GPL-2.0, uvnc.com (Belgium). Publishes a SHA-256 per file. Has a
#                     mirror driver, which is a real redraw advantage for a 3D app, plus
#                     MS-logon auth and DSM encryption.
#
# UltraVNC is NOT offered as a -Vnc choice, for a measured reason: its download link is a
# session-gated jDownloads page that answers text/html rather than the file (checked
#, HEAD and GET), so it cannot be fetched or pinned by a script at all. It is
# also configured through ultravnc.ini rather than the registry, so the guest-side
# hardening here would not apply to it. Both roads lead to the same place: if you want it,
# download it yourself, check the SHA-256 the release page publishes, and pass -Msi. That
# path is supported and always was.
#
# Anything else in this space rules itself out: RealVNC needs an account, TigerVNC's
# Windows server is an unmaintained TightVNC 1.3 derivative, and the rest are Linux-only
# or viewers.
#
# Afterwards, `dr-forge screen` is the one action that shows the screen.
#
#   powershell -ExecutionPolicy Bypass -File .\lib\forge\screen-access.ps1 -Vm UE5-Test -AdminKey <path>
#   powershell -ExecutionPolicy Bypass -File .\lib\forge\screen-access.ps1 -Vm UE5-Test -AdminKey <path> -Msi <my-own.msi>
param(
    [string]$Vm       = 'UE5-Test',
    [Parameter(Mandatory)][string]$AdminKey,
    # WHERE THE GUEST IS, when the caller already knows. provision.ps1 resolved both from
    # the daemon before its first phase, so passing them costs nothing and means the two
    # host-side scripts and provision all act on ONE answer rather than three lookups of
    # the same thing. Omitted, this asks the daemon itself, as it always did.
    [int]   $SshPort   = 0,
    [string]$GuestUser = '',
    [string]$Msi,
    [ValidateSet('TightVNC')][string]$Vnc = 'TightVNC',
    # NOT inside the repository, and that is the point rather than tidiness: a 2.5 MB
    # vendor MSI cached under the checkout is a file a mound can read and git has to be
    # told to ignore. %LOCALAPPDATA%\Draugr is where the forge's other host-side state
    # already lives (the tunnel and screen logs), and it survives a clone being deleted.
    [string]$CacheDir = "$env:LOCALAPPDATA\Draugr\vnc",
    [string]$PassFile = "$env:USERPROFILE\.ssh\draugr_vnc.pass",
    [switch]$SkipHostViewer
)

$ErrorActionPreference = 'Stop'
if (-not (Test-Path $AdminKey)) { throw "missing: $AdminKey" }

# One pinned build per supported server. Bump all three fields together, and re-check the
# hash against the vendor before committing the change.
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

    # A cached file is reused only if it still matches the pin. Anything else is fetched
    # again: a half-written download and a tampered one look the same from here.
    $have = (Test-Path $Msi) -and ((Get-FileHash $Msi -Algorithm SHA256).Hash -eq $pin.Sha256)
    if ($have) {
        Write-Host "$Vnc $($pin.Version): cached copy matches the pin"
    } else {
        Write-Host "downloading $Vnc $($pin.Version) from $($pin.Url)"
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -UseBasicParsing $pin.Url -OutFile $Msi
        $got = (Get-FileHash $Msi -Algorithm SHA256).Hash
        if ($got -ne $pin.Sha256) {
            Remove-Item $Msi -Force -EA SilentlyContinue
            throw ("$Vnc checksum mismatch - NOT installing. expected $($pin.Sha256), got $got. " +
                   'Either the vendor re-rolled the build (update the pin deliberately) or this ' +
                   'is not the file it should be.')
        }
        Write-Host "  sha256 matches the pin ($([math]::Round((Get-Item $Msi).Length/1MB,1)) MB)"
    }
}

# The signature is checked either way: the pin says "this exact build", the signature says
# "and the vendor signed it". Neither answers the other's question.
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
# The daemon knows the ssh port and user; vms.cfg is the fallback when it is down.
function Get-SshFromApi([string]$Name) {
    $hj = Join-Path $env:ProgramData 'AppSandbox\host.json'
    if (-not (Test-Path $hj)) { return $null }
    try {
        $h = Get-Content $hj -Raw | ConvertFrom-Json
        return Invoke-RestMethod -Uri "$($h.endpoint)/v1/vms/$Name/sshInfo" -TimeoutSec 10 `
            -Headers @{ Authorization = "Bearer $($h.token)" }
    } catch { return $null }
}
# -SshPort and -GuestUser together skip the lookup. Both or neither: half an answer would
# mean dialling one guest's port as another guest's user, which authenticates and then
# surprises you about which desktop you are looking at.
#
# NOT CALLED -User, and that is not style: PowerShell variable names are case-INSENSITIVE,
# so a parameter $User and the $user this script already used throughout would be one piece
# of storage, and the else branch below would be assigning to the caller's argument.
if ($SshPort -and $GuestUser) {
    $port = $SshPort
    $user = $GuestUser
} else {
    $ssh = Get-SshFromApi $Vm
    if (-not $ssh) { throw "the AppSandbox daemon is not answering - start it with --headless, and the VM" }
    $port = $ssh.port
    $user = $ssh.user
}
Write-Host "guest: $user@127.0.0.1:$port"

# HostKeyAlias: the key belongs to the VM, not to a port several guests take turns on.
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
        Write-Host "host viewer already present: $viewer"
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
Write-Host "The password is in $PassFile - the viewer will ask for it."
# Said here because this script is the only thing that knows the file was just written, and
# because draugr_vnc.pass is often the only record of a guest's VNC password: nothing in
# Draugr ever deletes it, and the guest keeps the password in the registry, not the file.
Write-Host 'Keep that file. It is the only copy on this side.'
