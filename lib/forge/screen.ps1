# screen.ps1 - put the forge VM's screen in front of a human, and clean up afterwards.
#
# ==> STARTED DETACHED BY lib/forge/vm.ps1 -Mode screen. Outlives the command that asked. <==
#
# WHY A FORWARD AT ALL, when both the viewer and AppSandbox run on this same host: the guest has
# NO NETWORK ADAPTER (networkMode=0, docs/FORGE.md). It therefore has no address for anything to
# dial - which is the same reason its egress has to be a reverse tunnel. The only channel in or
# out is AppSandbox's ssh relay over Hyper-V sockets, so reaching a TCP port inside the guest
# means forwarding through it. There is no shorter path to shorten.
#
# AND NOT THROUGH THE DAEMON'S OWN DISPLAY. open_display crashes the daemon for a GPU-PV VM -
# measured on 0.1.4 and 0.1.8 both, returning 200 and then dying about 30 s later, taking the VM
# with it. docs/FORGE.md: never call it on a gpuMode=1 VM. That crash is why there is a VNC
# server inside the guest in the first place.
#
# WHY THIS IS DETACHED, AND WHY IT IS A FILE. The viewer stays open as long as someone is
# looking, and `dr-forge up --screen` must not block for that - showing the screen is the last
# thing it does, so there is nothing left to wait for. But the forward still has to be torn down
# when the viewer closes, so something has to outlive the command and watch: this. A detached
# PowerShell needs a script to run, which is why it is its own file rather than a mode.
#
# IT LOGS, because it has no console. Nobody is watching a hidden window, and a failure that
# only appears there is a failure nobody sees.
#
# THE FORWARD IS TEMPORARY, AND ON THE ADMIN KEY. Not added to lib/forge/tunnel.ps1's permanent
# set, for two reasons: the restricted tunnel key would need another permitopen - a real
# widening of a deliberately narrow key - and a VNC port on host loopback would then stand open
# whether or not anyone is looking. This way it exists exactly as long as the viewer does.
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

# No [Parameter()] attribute anywhere: one makes this cmdlet-bound, and $PSScriptRoot is then
# empty while the defaults are evaluated. A Mandatory parameter would also PROMPT, and a hidden
# detached process prompting is a process that hangs for ever with nothing to show why.
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

# The relay port, from the daemon rather than from vms.cfg - that file is undocumented and was
# measured stale (it said 57351 while the guest was on 54501).
$hostJson = Join-Path $env:ProgramData 'AppSandbox\host.json'
if (-not (Test-Path $hostJson)) { Write-Log 'the AppSandbox daemon is not running'; exit 10 }
try {
    $h = Get-Content $hostJson -Raw | ConvertFrom-Json
    $si = Invoke-RestMethod -Uri "$($h.endpoint)/v1/vms/$Vm/sshInfo" -TimeoutSec 20 `
              -Headers @{ Authorization = "Bearer $($h.token)" }
} catch {
    Write-Log "the daemon would not say which port serves '$Vm': $($_.Exception.Message)"
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
    Write-Log "127.0.0.1:$LocalPort is already in use - another screen is open, or pass -LocalPort"
    exit 12
}

# A LOCAL LISTENER PROVES NOTHING: ssh -L opens it whether or not the far side answers, so a
# guest with no screen server looks identical to a working one until the viewer gets an instant
# disconnect (measured, after the VM was repointed onto a base predating the VNC
# install). Returns 'alive' when the guest end sent a greeting, 'refused' on an immediate EOF -
# which is ssh closing the channel because nothing listened - and 'unknown' on a timeout,
# because a protocol where the client speaks first is entitled to say nothing yet.
$script:Greeting = ''
function Test-ForwardReachesGuest([int]$Port) {
    $c = New-Object Net.Sockets.TcpClient
    try {
        $c.Connect('127.0.0.1', $Port)
        $s = $c.GetStream()
        # Measured through this exact relay: a live server greets in 0.50 s, a refused forward
        # EOFs at 2.01 s. 6 s clears that comfortably and costs the healthy path nothing,
        # because it returns as soon as bytes arrive.
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
# ONE QUOTED STRING, NOT AN ARRAY. Start-Process -ArgumentList joins an array with spaces and
# does NOT quote the parts, so a key under "C:\Users\First Last\" splits in two and ssh reads
# the remainder as a hostname ("hostname contains invalid characters"). This host's own profile
# has a space in it, so that is not a hypothetical.
$sshArgs = @(
    '-N', '-i', "`"$AdminKey`"", '-p', $si.port,
    '-o', 'IdentitiesOnly=yes', '-o', 'BatchMode=yes',
    '-o', 'StrictHostKeyChecking=accept-new',
    # The key belongs to the VM, not to a port several guests take turns on. docs/FORGE.md.
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
        # "Permission denied" is a DIFFERENT failure from "connected, but nothing is listening",
        # and conflating them is how a wrong key came to read as a missing screen server.
        if ($why -match 'Permission denied') {
            Write-Log "ssh was REFUSED by the guest, so no forward was attempted: $why"
            Write-Log "  That is AUTHENTICATION, not the screen server - which may well be fine."
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
            Write-Log '  The viewer would just disconnect. The usual cause is a guest that predates the'
            Write-Log '  screen server - a restore or a repoint onto an older base. Check it with:'
            Write-Log "    dr-forge exec Get-Service tvnserver"
            Write-Log '  And install it into a guest that has none, which takes a minute and needs'
            Write-Log '  only the admin key (it is phase 10 of a provisioning run):'
            Write-Log '    powershell -ExecutionPolicy Bypass -File .\lib\forge\screen-access.ps1 -Vm <vm> -AdminKey <key>'
            exit 12
        }
        default   { Write-Log 'the guest said nothing yet, which is normal for a client-speaks-first protocol' }
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
        Write-Log 'no VNC viewer found on this host. Install one (TightVNC''s installer carries both'
        Write-Log "  halves), or pass -Viewer. The forward is up meanwhile, so any viewer pointed at"
        Write-Log "  127.0.0.1:$LocalPort will do."
        # The forward is deliberately LEFT UP in this one case: it works, and the only thing
        # missing is on this side, so tearing it down would take away the usable half.
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
    # The VM is deliberately left running: the whole point is that looking at the screen
    # disturbs nothing, and the agent keeps the API throughout.
}
