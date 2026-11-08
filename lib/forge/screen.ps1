# screen.ps1: show the screen of the forge VM to a person, and clean up after.
#
# ==> lib/forge/vm.ps1 -Mode screen STARTS IT DETACHED. It stays after that command ends. <==
#
# WHY A FORWARD? The viewer and AppSandbox run on the same host, but the guest
# has NO NETWORK ADAPTER (networkMode=0, docs/FORGE.md). Thus it has no address
# to connect to. For the same reason, its egress must be a reverse tunnel. The
# only channel in or out is the ssh relay of AppSandbox over Hyper-V sockets.
# Thus, to reach a TCP port in the guest, you forward through it. No shorter
# path exists.
#
# AND NOT THROUGH THE DISPLAY OF THE DAEMON. open_display crashes the daemon for
# a GPU-PV VM. Tests on 0.1.4 and 0.1.8 showed this. It returns 200, then dies
# about 30 s later, and takes the VM with it. docs/FORGE.md: never call it on a
# gpuMode=1 VM. That crash is the reason for the VNC server in the guest.
#
# WHY THIS IS DETACHED, AND WHY IT IS A FILE. The viewer stays open while
# somebody looks. `dr-forge up --screen` must not block for that. The screen is
# its last step, so it has nothing left to wait for. But when the viewer closes,
# the forward must close. Thus something must stay after the command, and watch.
# This script does that. A detached PowerShell needs a script, so it is its own
# file, not a mode.
#
# IT LOGS, because it has no console. Nobody watches a hidden window, and nobody
# sees a failure that appears only there.
#
# THE FORWARD IS TEMPORARY, AND ON THE ADMIN KEY. It is not in the permanent set
# of lib/forge/tunnel.ps1, for two reasons. The restricted tunnel key then needs
# another permitopen, which makes a narrow key wider. Also, a VNC port on host
# loopback then stays open all the time. Here, it exists only as long
# as the viewer.
param(
    [string]$Vm        = '',
    [string]$AdminKey  = "$env:USERPROFILE\.ssh\draugr_admin_ed25519",
    [int]   $LocalPort = 15900,
    [int]   $GuestPort = 5900,
    [string]$Viewer    = '',
    [switch]$KeepForward,
    [string]$LogFile   = "$env:LOCALAPPDATA\Draugr\forge-screen.log",
    [int]   $MaxLogKb  = 256
)

# No [Parameter()] attribute. One makes this cmdlet-bound, and then
# $PSScriptRoot is empty while PowerShell evaluates the defaults. A Mandatory
# parameter also PROMPTS. A hidden, detached process that prompts hangs forever,
# and nothing shows why.
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'

$dir = Split-Path $LogFile -Parent
if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
function Write-Log([string]$msg) {
    if ((Test-Path $LogFile) -and ((Get-Item $LogFile).Length -gt ($MaxLogKb * 1KB))) {
        Move-Item $LogFile "$LogFile.1" -Force
    }
    Add-Content -Path $LogFile -Value ("{0:yyyy-MM-dd HH:mm:ss}  {1}" -f (Get-Date), $msg)
}

if (-not $Vm) { Write-Log 'screen: -Vm is required'; exit 2 }
Write-Log "screen asked for vm '$Vm' (pid $PID)"

if (-not (Test-Path $AdminKey)) { Write-Log "no admin key at $AdminKey"; exit 13 }

# The relay port comes from the daemon, not from vms.cfg. That file has no
# documentation, and a test showed it was old (it said 57351, but the guest was
# on 54501).
$hostJson = Join-Path $env:ProgramData 'AppSandbox\host.json'
if (-not (Test-Path $hostJson)) { Write-Log 'the AppSandbox daemon is not running'; exit 10 }
try {
    $h = Get-Content $hostJson -Raw | ConvertFrom-Json
    $si = Invoke-RestMethod -Uri "$($h.endpoint)/v1/vms/$Vm/sshInfo" -TimeoutSec 20 `
              -Headers @{ Authorization = "Bearer $($h.token)" }
} catch {
    Write-Log "the daemon did not tell which port serves '$Vm': $($_.Exception.Message)"
    exit 10
}
if (-not $si.port) { Write-Log "the daemon reports no ssh port for '$Vm'"; exit 11 }
$user = if ($si.user) { $si.user } else { 'forge' }

function Test-TcpPort([int]$Port) {
    $c = New-Object Net.Sockets.TcpClient
    try { $c.Connect('127.0.0.1', $Port); return $true }
    catch { return $false }
    finally { $c.Dispose() }
}

if (Test-TcpPort $LocalPort) {
    Write-Log "127.0.0.1:$LocalPort is already in use. Another screen is open, or give -LocalPort"
    exit 12
}

# A LOCAL LISTENER PROVES NOTHING. ssh -L opens it, and does not wait for an
# answer from the far side. Thus a guest with no screen server looks the same as
# a working one, until the viewer gets an instant disconnect. A test showed
# this, after the VM moved to a base older than the VNC install. The result is
# 'alive' for a greeting from the guest end. Returns 'refused' on an immediate
# EOF, which is ssh that closes the channel because nothing listened. Returns
# 'unknown' on a timeout, because in a protocol where the client speaks first,
# the server can stay silent.
$script:Greeting = ''
function Test-ForwardReachesGuest([int]$Port) {
    $c = New-Object Net.Sockets.TcpClient
    try {
        $c.Connect('127.0.0.1', $Port)
        $s = $c.GetStream()
        # Tested through this relay: a live server greets in 0.50 s, and a
        # refused forward gets EOF at 2.01 s. 6 s is more than enough. It costs
        # the healthy path nothing, because it returns at the first bytes.
        $s.ReadTimeout = 6000
        $buf = New-Object byte[] 16
        try {
            $n = $s.Read($buf, 0, 16)
            if ($n -gt 0) {
                $script:Greeting = ([Text.Encoding]::ASCII.GetString($buf, 0, $n) -replace '[^\x20-\x7e]', '').Trim()
                return 'alive'
            }
            return 'refused'
        } catch [IO.IOException] { return 'unknown' }
    } catch { return 'refused' }
    finally { $c.Dispose() }
}

$errLog = Join-Path $env:TEMP "draugr-screen-ssh-$PID.log"
# ONE QUOTED STRING, NOT AN ARRAY. Start-Process -ArgumentList joins an array
# with spaces, and does NOT quote the parts. Thus a key under "C:\Users\First
# Last\" splits in two, and ssh reads the rest as a hostname ("hostname contains
# invalid characters"). The profile on this host has a space in it, so this is a
# real case.
$sshArgs = @(
    '-N', '-i', "`"$AdminKey`"", '-p', $si.port,
    '-o', 'IdentitiesOnly=yes', '-o', 'BatchMode=yes',
    '-o', 'StrictHostKeyChecking=accept-new',
    # The key belongs to the VM, not to a port that guests use in turn.
    # docs/FORGE.md.
    '-o', "HostKeyAlias=draugr-$Vm",
    '-o', 'ExitOnForwardFailure=yes',
    '-o', 'ServerAliveInterval=15', '-o', 'ServerAliveCountMax=3',
    '-L', "127.0.0.1:${LocalPort}:127.0.0.1:${GuestPort}",
    "$user@127.0.0.1"
) -join ' '
Write-Log "forwarding 127.0.0.1:$LocalPort -> guest 127.0.0.1:$GuestPort over relay port $($si.port)"
$ssh = Start-Process -FilePath 'ssh.exe' -ArgumentList $sshArgs -PassThru `
    -WindowStyle Hidden -RedirectStandardError $errLog

try {
    $t0 = Get-Date
    while (-not (Test-TcpPort $LocalPort) -and ((Get-Date) - $t0).TotalSeconds -lt 25) {
        Start-Sleep -Milliseconds 400
    }
    if (-not (Test-TcpPort $LocalPort)) {
        $why = '(nothing)'
        if (Test-Path $errLog) { $t = (Get-Content $errLog -Raw).Trim(); if ($t) { $why = $t } }
        # "Permission denied" is a DIFFERENT failure from "connected, but
        # nothing listens". A mix of the two once made a wrong key look like a
        # missing screen server.
        if ($why -match 'Permission denied') {
            Write-Log "the guest REFUSED ssh, so no forward was tried: $why"
            Write-Log "  That is AUTHENTICATION, not the screen server. The screen server can be fine."
            Write-Log "  The key offered was $AdminKey"
            Write-Log "  Ask the guest which keys it accepts:  dr-forge exec type C:\ProgramData\ssh\administrators_authorized_keys"
            exit 13
        }
        Write-Log "the forward never came up. ssh said: $why"
        exit 12
    }

    switch (Test-ForwardReachesGuest $LocalPort) {
        'alive'   { Write-Log "the guest answered: $script:Greeting" }
        'refused' {
            Write-Log "the forward is open here, but NOTHING IS LISTENING on 127.0.0.1:$GuestPort inside the guest."
            Write-Log '  The viewer only disconnects. Usually, the guest is older than the screen'
            Write-Log '  server: a restore, or a move to an older base. Make sure with:'
            Write-Log "    dr-forge exec Get-Service tvnserver"
            Write-Log '  If the guest has none, install it. That takes a minute, and needs only the'
            Write-Log '  admin key (it is phase 10 of a provisioning run):'
            Write-Log '    powershell -ExecutionPolicy Bypass -File .\lib\forge\screen-access.ps1 -Vm <vm> -AdminKey <key>'
            exit 12
        }
        default   { Write-Log 'the guest said nothing yet. That is normal for a protocol where the client speaks first' }
    }

    if (-not $Viewer) {
        $Viewer = @(
            "$env:ProgramFiles\TightVNC\tvnviewer.exe",
            "${env:ProgramFiles(x86)}\TightVNC\tvnviewer.exe",
            "$env:ProgramFiles\TigerVNC\vncviewer.exe",
            "$env:ProgramFiles\uvnc bvba\UltraVNC\vncviewer.exe"
        ) | Where-Object { Test-Path $_ } | Select-Object -First 1
    }
    if (-not $Viewer) {
        Write-Log 'no VNC viewer on this host. Install one (the TightVNC installer has both'
        Write-Log "  halves), or give -Viewer. The forward stays up, so each viewer that points"
        Write-Log "  to 127.0.0.1:$LocalPort works."
        # Only in this case, the forward STAYS UP on purpose. It works, and the
        # missing part is on this side. A close of the forward removes the half
        # that works.
        $KeepForward = $true
        exit 14
    }

    Write-Log "viewer: $Viewer"
    if ($Viewer -eq 'mstsc') {
        Start-Process mstsc -ArgumentList "/v:127.0.0.1:$LocalPort" -Wait
    } else {
        # TightVNC and TigerVNC take host::port for a non-default port.
        Start-Process -FilePath $Viewer -ArgumentList "127.0.0.1::$LocalPort" -Wait
    }
    Write-Log 'viewer closed'
}
finally {
    if ($KeepForward) {
        Write-Log "the forward is still up on 127.0.0.1:$LocalPort (ssh pid $($ssh.Id))"
    } else {
        if ($ssh -and -not $ssh.HasExited) { $ssh.Kill() }
        Write-Log 'forward closed'
    }
    Remove-Item $errLog -Force -ErrorAction SilentlyContinue
    # The VM continues to run, on purpose. A look at the screen must change
    # nothing, and the agent keeps the API all the time.
}
