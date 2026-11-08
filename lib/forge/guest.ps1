# guest.ps1: run a command inside the forge, or move a file into or out of it.
#
# ==> bin/dr-forge RUNS IT, ON THE WINDOWS SIDE. You do not type it. <==
#
# WHY A SECOND POWERSHELL FILE, and not three new modes in probe.ps1: probe.ps1
# is read-only by contract, and says so at the top. These three verbs ACT.
# Because they are separate, the probe stays safe to run during the build of a
# layer. At that time, you most want to look.
#
# WHY IT IS ON THE WINDOWS SIDE: the API of AppSandbox and the ssh relay of the
# guest both bind the WINDOWS loopback. Inside WSL2, 127.0.0.1 is the loopback
# of WSL (a test showed this, see lib/forge/common.sh). ssh from WSL cannot
# reach the relay, so the ssh must happen here.
#
# WHY THE COMMAND ARRIVES AS BASE64. A command typed in WSL goes through five
# parsers: bash, the argv translation of WSL, the parser of PowerShell, the
# argument handling of ssh, and the PowerShell of the guest. Each of these
# parsers removes a layer of quotes. Two examples from tests in this project:
# PowerShell 5.1 silently REMOVES { and } from the arguments of native commands,
# so a guest curl saw %http_code, not %{http_code}. Also, `powershell -Command
# -` runs stdin line by line. Thus it reads a multi-line foreach as not
# complete, and loses the rest, with exit code 0 and no output. Base64 is the
# one encoding that none of the five can damage. Its alphabet is A-Za-z0-9+/=,
# and the guest decodes it once, at the far end. bin/dr-forge does the encoding,
# and also adds the exit-code wrapper there.
#
# EXIT CODES, because "it printed an error and exited 0" is the worst result,
# and this project already shipped it once:
#   10  no AppSandbox daemon (or a host.json with nothing behind it)
#   11  no such VM, or the VM does not run
#   12  the daemon reported no ssh port
#   13  the admin key is missing
#   other codes  the exit code of ssh or scp. For exec, that is the exit code of the GUEST
# Nothing here hides a failure to make the output tidier.
param(
    [string]$Mode = '',
    [string]$Vm = '',
    [string]$Encoded = '',
    [string]$Local = '',
    [string]$Remote = '',
    [string]$AdminKey = "$env:USERPROFILE\.ssh\draugr_admin_ed25519",
    [int]$TimeoutSec = 15
)

# NOT [Parameter(Mandatory)], and not for style. A [Parameter()] attribute in a
# param block makes the script cmdlet-bound. Then $PSScriptRoot is EMPTY while
# PowerShell evaluates the defaults above. That cost an evening in
# forge-engine-layer.ps1. The code below validates the values.
if ($Mode -notin 'exec', 'push', 'pull') { Write-Error "guest.ps1: -Mode must be exec, push, or pull (got '$Mode')"; exit 2 }
if (-not $Vm) { Write-Error 'guest.ps1: -Vm is required'; exit 2 }

# 'Continue', NOT 'Stop'. Under 'Stop', the stderr of a native command that
# arrives through the error stream becomes a TERMINATING error. Thus one
# information line from ssh stops the run before the output of the guest prints.
# A test in forge-engine-layer.ps1 showed this.
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'

function Fail([int]$code, [string]$msg, [string]$fix) {
    Write-Error "dr-forge: $msg"
    if ($fix) { [Console]::Error.WriteLine("  $fix") }
    exit $code
}

# --- the daemon ---------------------------------------------------------------------------
# Tested by EFFECT. A host.json with nothing behind it means that the last
# daemon died, and did not exit. With only the file, the code connects to a port
# that nobody holds.
$hostJson = Join-Path $env:ProgramData 'AppSandbox\host.json'
if (-not (Test-Path $hostJson)) {
    Fail 10 'the AppSandbox daemon does not run (no host.json).' 'start it, or run dr-forge doctor to see the whole chain.'
}
try {
    $h = Get-Content $hostJson -Raw | ConvertFrom-Json
    $null = Invoke-RestMethod -Uri "$($h.endpoint)/v1/version" -TimeoutSec 5 `
                -Headers @{ Authorization = "Bearer $($h.token)" }
} catch {
    Fail 10 'host.json is there, but nothing answers. The last daemon died, and did not exit.' 'start AppSandbox again. dr-forge status reports this as a stale daemon.'
}

function Asb([string]$Path) {
    Invoke-RestMethod -Uri "$($h.endpoint)/v1$Path" -TimeoutSec $TimeoutSec `
        -Headers @{ Authorization = "Bearer $($h.token)" }
}

# --- the VM -------------------------------------------------------------------------------
try { $st = Asb "/vms/$Vm" } catch {
    $known = ''
    try { $known = (@((Asb '/vms').vms | ForEach-Object { $_.name }) -join ' ') } catch { }
    Fail 11 "the daemon knows no VM called '$Vm'." $(if ($known) { "registered: $known" } else { 'no VMs are registered.' })
}
if (-not $st.running) {
    Fail 11 "the VM '$Vm' is registered, but does not run (state=$($st.state))." 'start it:  dr-forge up'
}

# --- the port, read now and never cached --------------------------------------------------
# TWO TESTS ON ONE DAY showed this. vms.cfg said 57351 while the guest used
# 54501. The API answered 57351, and minutes later 57589, with sshState=2 all
# the time. No field says that a port is final, so the code reads it at the time
# of use.
try { $si = Asb "/vms/$Vm/sshInfo" } catch { $si = $null }
if (-not $si -or -not $si.port) {
    Fail 12 "the daemon reports no ssh port for '$Vm'." 'the boot of the guest is possibly not complete. dr-forge status shows the relay.'
}
$port = [int]$si.port
$user = if ($si.user) { $si.user } else { 'forge' }

if (-not (Test-Path $AdminKey)) {
    Fail 13 "the admin ssh key is missing: $AdminKey" 'give -AdminKey, or let dr-layer provision make it (its phase 1 makes a missing key).'
}

# Shared by all three. StrictHostKeyChecking=accept-new, not `no`. The relay
# port changes, so a pinned key for 127.0.0.1:<port> is more often wrong than
# correct. But a CHANGED key on a port must still fail.
$common = @('-i', $AdminKey, '-o', 'IdentitiesOnly=yes', '-o', 'BatchMode=yes',
            # HostKeyAlias. SSH RECORDS THE HOST KEY FOR THE VM, not for a port.
            # Both ports of Draugr are shared. 18022 is pinned on purpose, and
            # the daemon can change the relay port. One address for several
            # guests is exactly what known_hosts warns about. accept-new accepts
            # an UNKNOWN host, and correctly refuses a CHANGED one. Thus ssh
            # refuses the second guest, and each test through it blames the far
            # end. A TEST SHOWED THIS, see docs/FORGE.md. $Vm cannot be empty
            # here. The daemon lookup above fails with code 11 before something
            # reaches ssh.
            '-o', 'StrictHostKeyChecking=accept-new', '-o', "HostKeyAlias=draugr-$Vm",
            '-o', "ConnectTimeout=$TimeoutSec")

if ($Mode -eq 'exec') {
    if (-not $Encoded) { Fail 2 'guest.ps1: -Mode exec needs -Encoded' '' }
    # -n, so that ssh does not read the stdin of this process. This code cannot
    # promise a correct pipe of input through five parsers, so it does not offer
    # it. dr-forge documents that exec sends no stdin. You can work with that
    # limit. A pipe that silently damages a byte stream is worse. -OutputFormat
    # Text, and it is not only for looks. A TEST WITH THE LIVE GUEST showed
    # this. PowerShell sees that its stderr is a pipe, not a console, and
    # SERIALIZES it. Thus a command whose stderr is not empty comes back as
    #
    #     #< CLIXML
    #     <Objs Version="1.1.0.1" ...><S S="Error">git : fatal: not a git repository ...
    #
    # The error is in there, as XML with _x000D__x000A_ for each newline. Nobody
    # can read that message. Text makes it a plain stream again. The mock cannot
    # catch this. For a receiver that is not a terminal, the real powershell
    # decides the form of its own output.
    & ssh.exe -n @common -p $port "$user@127.0.0.1" `
        "powershell -NoProfile -OutputFormat Text -EncodedCommand $Encoded"
    exit $LASTEXITCODE
}

# --- push and pull ------------------------------------------------------------------------
# scp, not the vault. The guest mounts the vault READ-ONLY, on purpose. Fab
# assets have executable code, and the host opens the same cache. Thus the vault
# is not a transfer channel, in either direction.
#
# -P, upper case, for scp. ssh above takes -p. They are different flags, on
# purpose. If you swap them, you get "ssh: Could not resolve hostname", with no
# sign of the cause.
#
# The remote path has FORWARD slashes. scp splits a target at the first colon
# after the host, so forge@127.0.0.1:C:/Users/forge/x parses correctly.
# Backslashes in it are lost somewhere between here and the far end.
if (-not $Local)  { Fail 2 "guest.ps1: -Mode $Mode needs -Local" '' }
if (-not $Remote) { Fail 2 "guest.ps1: -Mode $Mode needs -Remote" '' }
$remotePath = $Remote -replace '\\', '/'
$target = "{0}@127.0.0.1:{1}" -f $user, $remotePath

# Always -r, so that a directory works, and the caller does not have to say what
# kind of path it is. scp also accepts it for a plain file.
if ($Mode -eq 'push') {
    if (-not (Test-Path $Local)) { Fail 2 "nothing to push: $Local does not exist" '' }
    & scp.exe -r @common -P $port -- $Local $target
} else {
    & scp.exe -r @common -P $port -- $target $Local
}
exit $LASTEXITCODE
