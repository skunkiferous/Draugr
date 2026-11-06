# install-screen-server.ps1 - install TightVNC's server in the forge guest, bound to
# loopback, so a human can see the screen through the SSH channel.
#
# ==> RUN IN THE GUEST, by lib/forge/screen-access.ps1 on the host, which puts this <==
# ==> file, the MSI and the password beside each other in %ProgramData%\draugr-screen. <==
#
# Why VNC and not RDP: this guest is Windows Home (EditionID=Core), which has no RDP
# server - no Remote Desktop Users group, no firewall group, no listener, and
# fDenyTSConnections=0 changes none of that (measured). VNC also suits the
# forge better than RDP would: it shares the CONSOLE session, so the human sees the
# same desktop the agent automates through UI Automation, and connecting displaces
# nothing.
#
# Why loopback-only: the guest has no network adapter, and the only way in is the SSH
# forward, which terminates at 127.0.0.1 inside the guest. LoopbackOnly=1 means the
# server refuses anything else even if an adapter ever appears. The password is the
# second lock, and it is weak by protocol - VNC truncates it to 8 characters - so it
# is a guard against accident, not a security boundary. The boundary is the SSH key.
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
if ($p.ExitCode -ne 0) { throw "msiexec exited $($p.ExitCode) - see $log" }

# The MSI properties are the documented route, but the registry is what the service
# reads, so assert rather than assume.
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
if (-not $hasPw) { throw 'the MSI did not store a password - refusing to run an open server' }

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

# The password lives in the registry now; the file has no further use in the guest.
Remove-Item $PassFile -Force -ErrorAction SilentlyContinue
Remove-Item $Msi -Force -ErrorAction SilentlyContinue
Write-Host ''
Write-Host 'password file and installer removed from the guest.'
