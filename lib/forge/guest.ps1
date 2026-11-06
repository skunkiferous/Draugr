# guest.ps1 - run a command inside the forge, or move a file in or out of it.
#
# ==> RUN BY bin/dr-forge, ON THE WINDOWS SIDE. Not meant to be typed. <==
#
# WHY A SECOND POWERSHELL FILE, instead of adding three modes to probe.ps1: probe.ps1 is
# read-only by contract, and says so at the top. These three verbs ACT. Keeping them apart is
# what lets the probe stay safe to run while a layer is being built, which is when you most
# want to look at one.
#
# WHY IT IS ON THE WINDOWS SIDE AT ALL: AppSandbox's API and the guest's ssh relay both bind
# the WINDOWS loopback, and inside WSL2 127.0.0.1 is WSL's own (measured, in
# lib/forge/common.sh). ssh from WSL cannot reach the relay, so the ssh has to happen here.
#
# WHY THE COMMAND ARRIVES AS BASE64. A command typed in WSL crosses bash, WSL's argv
# translation, PowerShell's parser, ssh's own argument handling and finally the guest's
# PowerShell - five parsers, each of which eats a layer of quoting. Two measured examples from
# this project: PowerShell 5.1 silently STRIPS { and } from native-command arguments, so a
# guest curl saw %http_code instead of %{http_code}; and `powershell -Command -` executes
# stdin line by line, so a multi-line foreach is read as incomplete and the rest is swallowed
# with exit code 0 and no output. Base64 is the one encoding none of those five can damage:
# the alphabet is A-Za-z0-9+/=, and the guest decodes it once, at the far end. bin/dr-forge
# does the encoding, which is also where the exit-code wrapper is added.
#
# EXIT CODES, because "it printed an error and exited 0" is the worst outcome available and
# this project has already shipped it once:
#   10  no AppSandbox daemon (or a host.json with nothing behind it)
#   11  no such VM, or the VM is not running
#   12  the daemon reported no ssh port
#   13  the admin key is missing
#   anything else  ssh's or scp's own exit code, which for exec is the GUEST's exit code
# Nothing here swallows a failure to make the output tidier.
param(
    [string]$Mode = '',
    [string]$Vm = '',
    [string]$Encoded = '',
    [string]$Local = '',
    [string]$Remote = '',
    [string]$AdminKey = "$env:USERPROFILE\.ssh\draugr_admin_ed25519",
    [int]$TimeoutSec = 15
)

# NOT [Parameter(Mandatory)], and not for style: a [Parameter()] attribute anywhere in a param
# block makes the script cmdlet-bound, and $PSScriptRoot is then EMPTY while the defaults above
# are evaluated. That cost an evening in forge-engine-layer.ps1. Validated by hand instead.
if ($Mode -notin 'exec', 'push', 'pull') { Write-Error "guest.ps1: -Mode must be exec, push or pull (got '$Mode')"; exit 2 }
if (-not $Vm) { Write-Error 'guest.ps1: -Vm is required'; exit 2 }

# 'Continue', NOT 'Stop'. Under 'Stop' a native command's stderr arriving through the error
# stream becomes a TERMINATING error, so one informational line from ssh would kill the run
# before the guest's own output could be printed. Measured in forge-engine-layer.ps1.
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'

function Fail([int]$code, [string]$msg, [string]$fix) {
    Write-Error "dr-forge: $msg"
    if ($fix) { [Console]::Error.WriteLine("  $fix") }
    exit $code
}

# --- the daemon ---------------------------------------------------------------------------
# Checked by EFFECT: a host.json with nothing behind it means the last daemon died rather than
# exited, and the file alone would have us dial a port no one holds.
$hostJson = Join-Path $env:ProgramData 'AppSandbox\host.json'
if (-not (Test-Path $hostJson)) {
    Fail 10 'the AppSandbox daemon is not running (no host.json).' 'start it, or run dr-forge doctor to see the whole chain.'
}
try {
    $h = Get-Content $hostJson -Raw | ConvertFrom-Json
    $null = Invoke-RestMethod -Uri "$($h.endpoint)/v1/version" -TimeoutSec 5 `
                -Headers @{ Authorization = "Bearer $($h.token)" }
} catch {
    Fail 10 'host.json is there but nothing is answering - the last daemon died rather than exited.' 'start AppSandbox again; dr-forge status reports this as a stale daemon.'
}

function Asb([string]$Path) {
    Invoke-RestMethod -Uri "$($h.endpoint)/v1$Path" -TimeoutSec $TimeoutSec `
        -Headers @{ Authorization = "Bearer $($h.token)" }
}

# --- the VM -------------------------------------------------------------------------------
try { $st = Asb "/vms/$Vm" } catch {
    $known = ''
    try { $known = (@((Asb '/vms').vms | ForEach-Object { $_.name }) -join ' ') } catch { }
    Fail 11 "the daemon knows no VM called '$Vm'." $(if ($known) { "registered: $known" } else { 'no VMs are registered at all.' })
}
if (-not $st.running) {
    Fail 11 "the VM '$Vm' is registered but not running (state=$($st.state))." 'start it:  dr-forge up'
}

# --- the port, read now and never cached --------------------------------------------------
# MEASURED, twice in one day: vms.cfg said 57351 while the guest was on 54501, and
# the API itself answered 57351 and then 57589 minutes later, with sshState=2 throughout. No
# field says a port is final, so it is read at the moment it is used.
try { $si = Asb "/vms/$Vm/sshInfo" } catch { $si = $null }
if (-not $si -or -not $si.port) {
    Fail 12 "the daemon reports no ssh port for '$Vm'." 'the guest may still be booting; dr-forge status shows the relay.'
}
$port = [int]$si.port
$user = if ($si.user) { $si.user } else { 'forge' }

if (-not (Test-Path $AdminKey)) {
    Fail 13 "the admin ssh key is missing: $AdminKey" 'pass -AdminKey, or let dr-layer provision make it (its phase 1 does, for a key that is absent).'
}

# Shared by all three. StrictHostKeyChecking=accept-new rather than `no`: the relay port moves,
# so a pinned key for 127.0.0.1:<port> is wrong more often than it is right, but a CHANGED key
# on a port still deserves to fail.
$common = @('-i', $AdminKey, '-o', 'IdentitiesOnly=yes', '-o', 'BatchMode=yes',
            # HostKeyAlias - THE HOST KEY IS REMEMBERED AGAINST THE VM, not against a port.
            # Both ports Draugr dials are shared: 18022 is pinned on purpose, and the relay
            # port is the daemon's to reassign. One address presented by several guests is
            # precisely what known_hosts exists to complain about, and accept-new accepts an
            # UNKNOWN host while correctly refusing a CHANGED one - so the second guest to be
            # served is refused, and every check dialling through it blames the far end.
            # MEASURED, see docs/FORGE.md. $Vm cannot be empty here: the daemon
            # lookup above fails with code 11 before anything reaches ssh.
            '-o', 'StrictHostKeyChecking=accept-new', '-o', "HostKeyAlias=draugr-$Vm",
            '-o', "ConnectTimeout=$TimeoutSec")

if ($Mode -eq 'exec') {
    if (-not $Encoded) { Fail 2 'guest.ps1: -Mode exec needs -Encoded' '' }
    # -n, so ssh does not read this process's stdin. Piping input through five parsers is not
    # something this can honestly promise, so it does not offer it: dr-forge documents that
    # exec sends no stdin, which is a limit you can work with rather than one that corrupts
    # a byte stream silently.
    # -OutputFormat Text, and it is not cosmetic. MEASURED against the live guest:
    # PowerShell sees that its stderr is a pipe rather than a console and SERIALISES it, so a
    # command whose stderr is non-empty comes back as
    #
    #     #< CLIXML
    #     <Objs Version="1.1.0.1" ...><S S="Error">git : fatal: not a git repository ...
    #
    # - the error is in there, as XML with _x000D__x000A_ for every newline, which is not a
    # message anyone can read. Text makes it the plain stream it should have been. The mock
    # could not have caught this: it is the real powershell deciding what its own output looks
    # like once something downstream is not a terminal.
    & ssh.exe -n @common -p $port "$user@127.0.0.1" `
        "powershell -NoProfile -OutputFormat Text -EncodedCommand $Encoded"
    exit $LASTEXITCODE
}

# --- push and pull ------------------------------------------------------------------------
# scp, not the vault. The vault is mounted READ-ONLY in the guest on purpose - Fab assets carry
# executable code and the host opens the same cache - so it is not a transfer channel, in
# either direction.
#
# -P, capital, for scp; ssh above takes -p. They are different flags on purpose and getting
# them the wrong way round gives "ssh: Could not resolve hostname" with no hint why.
#
# The remote path is given with FORWARD slashes: scp splits a target on the first colon after
# the host, so forge@127.0.0.1:C:/Users/forge/x parses correctly, while backslashes in it get
# eaten somewhere between here and the far end.
if (-not $Local)  { Fail 2 "guest.ps1: -Mode $Mode needs -Local" '' }
if (-not $Remote) { Fail 2 "guest.ps1: -Mode $Mode needs -Remote" '' }
$remotePath = $Remote -replace '\\', '/'
$target = "{0}@127.0.0.1:{1}" -f $user, $remotePath

# -r always, so a directory works without the caller having to say which kind of thing it is;
# scp accepts it for a plain file too.
if ($Mode -eq 'push') {
    if (-not (Test-Path $Local)) { Fail 2 "nothing to push: $Local does not exist" '' }
    & scp.exe -r @common -P $port -- $Local $target
} else {
    & scp.exe -r @common -P $port -- $target $Local
}
exit $LASTEXITCODE
