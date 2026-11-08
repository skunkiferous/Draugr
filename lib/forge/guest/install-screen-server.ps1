# install-screen-server.ps1: install the server of TightVNC in the forge guest,
# bound to loopback, so that a person can see the screen through the SSH
# channel.
#
# ==> RUN IN THE GUEST, by lib/forge/screen-access.ps1 on the host. That script puts this <==
# ==> file, the MSI, and the password together in %ProgramData%\draugr-screen. <==
#
# Why VNC, not RDP: this guest is Windows Home (EditionID=Core), which has no
# RDP server. It has no Remote Desktop Users group, no firewall group, and no
# listener, and fDenyTSConnections=0 changes none of that (a test showed this).
# VNC is also better for the forge than RDP. It shares the CONSOLE session. Thus
# the person sees the same desktop that the agent automates through UI
# Automation, and a connection moves nothing away.
#
# Why only loopback: the guest has no network adapter. The only way in is the
# SSH forward, and it ends at 127.0.0.1 inside the guest. With LoopbackOnly=1,
# the server refuses all else, also with a new adapter one day. The
# password is the second lock, and the protocol makes it weak: VNC cuts it to 8
# characters. Thus it is a guard against accidents, not a security boundary. The
# boundary is the SSH key.
param(
    [string]$Dir      = 'C:\ProgramData\draugr-screen',
    [string]$Msi      = '',
    [string]$PassFile = ''
)

$ErrorActionPreference = 'Stop'
if (-not $Msi)      { $Msi      = Join-Path $Dir 'tightvnc-setup.msi' }
if (-not $PassFile) { $PassFile = Join-Path $Dir 'vnc.pass' }
foreach ($f in $Msi, $PassFile) { if (-not (Test-Path $f)) { throw "missing: $f" } }

$pw = (Get-Content $PassFile -Raw).Trim()
if (-not $pw) { throw "empty password file: $PassFile" }

$log = Join-Path $Dir 'install.log'
$props = @(
    'ADDLOCAL=Server',
    'SET_USEVNCAUTHENTICATION=1', 'VALUE_OF_USEVNCAUTHENTICATION=1',
    'SET_PASSWORD=1',             "VALUE_OF_PASSWORD=$pw",
    'SET_ALLOWLOOPBACK=1',        'VALUE_OF_ALLOWLOOPBACK=1',
    'SET_LOOPBACKONLY=1',         'VALUE_OF_LOOPBACKONLY=1',
    'SET_ACCEPTHTTPCONNECTIONS=1','VALUE_OF_ACCEPTHTTPCONNECTIONS=0',
    'SET_ENABLEFILETRANSFERS=1',  'VALUE_OF_ENABLEFILETRANSFERS=0',
    'SET_RUNCONTROLINTERFACE=1',  'VALUE_OF_RUNCONTROLINTERFACE=1'
)
Write-Host 'installing TightVNC server...'
$p = Start-Process msiexec.exe -Wait -PassThru -ArgumentList (
    @('/i', "`"$Msi`"", '/quiet', '/norestart', '/l*v', "`"$log`"") + $props)
if ($p.ExitCode -ne 0) { throw "msiexec exited $($p.ExitCode). See $log" }

# The MSI properties are the documented way, but the service reads the registry.
# Thus test it, do not assume it.
$key = 'HKLM:\SOFTWARE\TightVNC\Server'
$want = @{ AllowLoopback = 1; LoopbackOnly = 1; AcceptHttpConnections = 0
           UseVncAuthentication = 1; AcceptRfbConnections = 1 }
foreach ($k in $want.Keys) {
    $have = (Get-ItemProperty $key -Name $k -ErrorAction SilentlyContinue).$k
    if ($have -ne $want[$k]) {
        Write-Host "  correcting $k : $have -> $($want[$k])"
        New-ItemProperty $key -Name $k -Value $want[$k] -PropertyType DWord -Force | Out-Null
        $restart = $true
    }
}
$hasPw = (Get-ItemProperty $key -Name Password -ErrorAction SilentlyContinue).Password
if (-not $hasPw) { throw 'the MSI did not store a password. Refusing to run an open server' }

Set-Service tvnserver -StartupType Automatic
if ($restart) { Restart-Service tvnserver } else { Start-Service tvnserver -ErrorAction SilentlyContinue }
Start-Sleep -Seconds 3

Write-Host ''
Write-Host '--- verification ---'
Get-Service tvnserver | Select-Object Name, Status, StartType | Format-Table -AutoSize
foreach ($k in ($want.Keys | Sort-Object)) {
    "  {0,-22} {1}" -f $k, (Get-ItemProperty $key -Name $k -ErrorAction SilentlyContinue).$k
}
"  {0,-22} {1}" -f 'Password', $(if ($hasPw) { 'set' } else { 'MISSING' })
Write-Host ''
Write-Host 'listeners on 5900/5800:'
$l = Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
     Where-Object { $_.LocalPort -in 5900, 5800 }
if ($l) { $l | ForEach-Object { "  $($_.LocalAddress):$($_.LocalPort)" } } else { '  none' }

# The password is in the registry now. The guest no longer needs the file.
Remove-Item $PassFile -Force -ErrorAction SilentlyContinue
Remove-Item $Msi -Force -ErrorAction SilentlyContinue
Write-Host ''
Write-Host 'the password file and the installer are removed from the guest.'
