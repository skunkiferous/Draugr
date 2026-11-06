# install-windows-online.ps1 - let the WINDOWS IDENTITY STACK work behind a loopback proxy.
#
# Run this IN THE GUEST, elevated. An ssh session is already elevated, so driving it over
# ssh is enough. Idempotent: every step checks first, -VerifyOnly changes nothing, -Remove
# undoes all of it.
#
# ============================================================================ THE PROBLEM
#
# The forge guest has no adapter with a route (NetworkMode=0). Everything leaves through
# the proxy at 127.0.0.1:3128, and that works perfectly for anything that simply makes an
# HTTP request - curl, MSYS2, Visual Studio 2017 and 2019, the Epic Games Launcher.
#
# It does NOT work for anything that signs in through WINDOWS rather than through its own
# browser. Visual Studio 2022 is the first tool here that does. MEASURED, four
# distinct faults stacked on each other, each one hiding the next:
#
#   1. Windows reports itself offline, so the broker never tries.      0x800713AB
#   2. The connectivity probes are answerable, but on the wrong        (still offline)
#      interface, so the one being judged sees no traffic.
#   3. The right interface has no default route, so Windows will       (still offline)
#      not consider it a path to anywhere.
#   4. The route exists but its gateway never answers ARP, so the      (still offline)
#      interface is still not "connected".
#   5. The broker runs in an APPCONTAINER, which Windows forbids       0x80190001
#      from reaching 127.0.0.1 - so its requests never reach the
#      proxy at all, and NOTHING appears in the gateway's denied log.
#   6. Device-wide SSO prefers IPv6, which has no route here.          0x800704cf
#
# Each fix is useless without the others, which is why this is one script and not six.
#
# ===================================================================== WHAT IT DOES *NOT* DO
#
# IT GRANTS NO EGRESS. No NIC is added, no rule relaxed, nothing published. VERIFIED after
# every step: a direct connection to 1.1.1.1 returns `000` (nothing), and the
# proxy still answers 403 for a host the kit does not allow. The VM has no adapter with a
# path out; the routing table here is a story Windows tells itself so that its own identity
# code will consent to use the one path that does exist.
#
# What it costs: once Windows believes it is online it resumes the chatter it skips while
# offline - Store, Update, telemetry, SmartScreen. All still denied by the gateway, so the
# cost is noise in `dr-policy --denied`, not exposure. And a DIRECT connection now fails in
# ~21 s rather than ~0 ms, because the gateway address resolves (step 2) instead of being
# unreachable. Nothing the forge uses makes direct connections, so this is a cost in
# diagnosis rather than in running: see TcpMaxConnectRetransmissions below if it bothers you.
#
# ================================================================== PUT IT IN layer-0
#
# Every change here lives on the disk, so it belongs in the BASE image, not in a session.
# A layer frozen with this in place carries it to every child.
#
#   powershell -ExecutionPolicy Bypass -File .\install-windows-online.ps1
#   powershell -ExecutionPolicy Bypass -File .\install-windows-online.ps1 -VerifyOnly
#   powershell -ExecutionPolicy Bypass -File .\install-windows-online.ps1 -Remove
param(
    [string]$InterfaceAlias = 'Ethernet',   # the KM-TEST loopback adapter install-guest-base adds
    # Any private /24 that collides with nothing. NOT 192.168.42.x or 192.168.142.x: those
    # are AppSandbox's own NAT, recreated at every daemon start.
    [string]$Address        = '192.168.63.2',
    [int]   $PrefixLength   = 24,
    [string]$Gateway        = '192.168.63.1',
    # Locally-administered MAC (02: prefix): it names nothing real, and nothing needs it to.
    # Its only job is to make the stack stop ARPing for a host that is not there.
    [string]$GatewayMac     = '02-00-00-00-63-01',
    [int]   $Port           = 80,           # NCSI asks for 80 and cannot be told otherwise
    [string]$Dir            = "$env:ProgramData\draugr-ncsi",
    [string]$TaskName       = 'draugr-ncsi-responder',
    [switch]$KeepIPv6,                      # leave IPv6 bound; device-wide SSO will fail
    [switch]$VerifyOnly,
    [switch]$Remove
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Say($m)  { Write-Host "`n=== $m ===" -ForegroundColor Cyan }
# EXIT CODES: 0 the wanted pair holds (IPv4=Internet, WinRT InternetAccess), 2 a
# precondition refused before anything was changed, 4 everything was applied but the pair
# did not appear within the wait - the guest is usable, sign-in is not.
function Note($m) { Write-Host "  $m" }
function Warn($m) { Write-Host "  $m" -ForegroundColor Yellow }
function Fail($m) { Write-Host "  $m" -ForegroundColor Red }

$hostsFile = "$env:SystemRoot\System32\drivers\etc\hosts"
$marker    = '# draugr-ncsi'
$script    = Join-Path $Dir 'ncsi-responder.ps1'

# The identity AppContainers. Windows forbids an AppContainer from reaching loopback unless
# it is exempted, and the proxy IS loopback - so without these, the account UI's requests
# die inside Windows and the gateway never sees them. AccountsControl is the dialog a user
# actually looks at; the other two are the broker and the sign-in host behind it.
$containers = @(
    'Microsoft.AccountsControl_cw5n1h2txyewy'
    'Microsoft.AAD.BrokerPlugin_cw5n1h2txyewy'
    'Microsoft.Windows.CloudExperienceHost_cw5n1h2txyewy'
)

# NCSI's probes, read from the live registry rather than hard-coded: an image told to probe
# something else should be answered on ITS terms.
$ncsiKey = 'HKLM:\SYSTEM\CurrentControlSet\Services\NlaSvc\Parameters\Internet'
function Get-Ncsi($name, $default) {
    $v = (Get-ItemProperty $ncsiKey -Name $name -ErrorAction SilentlyContinue).$name
    if ($null -eq $v -or "$v" -eq '') { return $default }
    return "$v"
}
$webHost    = Get-Ncsi ActiveWebProbeHost    'www.msftconnecttest.com'
$webPath    = Get-Ncsi ActiveWebProbePath    'connecttest.txt'
$webContent = Get-Ncsi ActiveWebProbeContent 'Microsoft Connect Test'
$dnsHost    = Get-Ncsi ActiveDnsProbeHost    'dns.msftncsi.com'
$dnsAddr    = Get-Ncsi ActiveDnsProbeContent '131.107.255.255'
$probeUrl   = "http://$webHost/$webPath"

# Get-ProbeBody - what the probe URL returns, or $null. Goes DIRECT: on PowerShell 5.1
# `Invoke-WebRequest -Proxy $null` still uses the system proxy, which here means tinyproxy
# answering 500 for a host it cannot reach - indistinguishable from a dead listener
# (measured, and it cost an hour). NCSI itself goes direct, so this must too.
function Get-ProbeBody($url) {
    try {
        $req = [System.Net.HttpWebRequest]::Create($url)
        $req.Proxy = $null
        $req.Timeout = 5000
        $resp = $req.GetResponse()
        $txt = (New-Object System.IO.StreamReader($resp.GetResponseStream())).ReadToEnd()
        $resp.Close()
        return $txt
    } catch { return $null }
}

# Get-Exempt / Add-Exempt - CheckNetIsolation THROUGH cmd, never straight from PowerShell.
# `CheckNetIsolation LoopbackExempt -a -n=Name` returns "Error: Invalid Parameters" when
# PowerShell passes the argument, because PowerShell mangles `-n=value` (measured
#). cmd hands it over verbatim. Same family of trap as needing \" for an
# argument with spaces over ssh.
function Get-Exempt {
    # The 2>&1 is WANTED - this output is parsed as text, and a complaint belongs in the text
    # rather than on a stream nobody reads. But with Stop in force a native stderr line is a
    # terminating error, so the preference is dropped for the length of the call and put back.
    # docs/FORGE.md, and tests/lint-native-stderr.sh is what keeps this from drifting back.
    $eapWas = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $out = & cmd.exe /c 'CheckNetIsolation LoopbackExempt -s' 2>&1 | Out-String }
    finally { $ErrorActionPreference = $eapWas }
    return @([regex]::Matches($out, 'Name:\s*(\S+)') | ForEach-Object { $_.Groups[1].Value })
}
function Add-Exempt($name) {
    & cmd.exe /c "CheckNetIsolation LoopbackExempt -a -n=$name" | Out-Null
}
function Remove-Exempt($name) {
    & cmd.exe /c "CheckNetIsolation LoopbackExempt -d -n=$name" | Out-Null
}

# ----------------------------------------------------------------------------- -Remove
if ($Remove) {
    Say 'removing'
    foreach ($c in $containers) { if ((Get-Exempt) -contains $c) { Remove-Exempt $c; Note "exemption removed: $c" } }
    if (-not $KeepIPv6) {
        Enable-NetAdapterBinding -Name $InterfaceAlias -ComponentID ms_tcpip6 -ErrorAction SilentlyContinue
        Note 'IPv6 re-enabled'
    }
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false; Note "task $TaskName unregistered"
    }
    Get-NetNeighbor -IPAddress $Gateway -ErrorAction SilentlyContinue |
        Remove-NetNeighbor -Confirm:$false -ErrorAction SilentlyContinue
    Set-DnsClientServerAddress -InterfaceAlias $InterfaceAlias -ResetServerAddress -ErrorAction SilentlyContinue
    Set-NetIPInterface -InterfaceAlias $InterfaceAlias -AddressFamily IPv4 -Dhcp Enabled -ErrorAction SilentlyContinue
    Note 'addressing returned to DHCP (APIPA), neighbour and DNS cleared'
    $kept = @(Get-Content $hostsFile | Where-Object { $_ -notmatch [regex]::Escape($marker) })
    Set-Content -Path $hostsFile -Value $kept -Encoding ASCII
    if (Test-Path $Dir) { Remove-Item $Dir -Recurse -Force }
    Note 'hosts entries and responder removed'
    ipconfig /flushdns | Out-Null
    Restart-Service NlaSvc -Force -ErrorAction SilentlyContinue
    return
}

# --------------------------------------------------------------------- 1. preconditions
Say 'preconditions'
if (-not (Get-NetAdapter -Name $InterfaceAlias -ErrorAction SilentlyContinue)) {
    Fail "no adapter '$InterfaceAlias'. install-guest-base.ps1 adds the KM-TEST loopback adapter;"
    Fail 'run that first - with no adapter at all there is nothing for NCSI to judge.'
    exit 2
}
$portAnswers = $false
$owner = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
if ($owner) {
    # DO NOT ASK WHO OWNS THE SOCKET. HttpListener binds through http.sys, so the owner is
    # the System process (pid 4) with no command line - reading that as "someone else has
    # port 80" made an earlier version refuse to run on a guest where it was already
    # correctly installed. What matters is what the listener SAYS, which is also what NCSI
    # judges.
    if ((Get-ProbeBody $probeUrl) -eq $webContent) { $portAnswers = $true; Note "port $Port already answers correctly" }
    else {
        Fail "port $Port is held by pid(s) $(($owner.OwningProcess | Sort-Object -Unique) -join ', ') and does not answer the probe."
        Fail 'NCSI cannot be pointed at another port, so free it or skip this guest.'
        exit 2
    }
} else { Note "port $Port is free" }
Note "web probe : $probeUrl expects '$webContent'"
Note "dns probe : $dnsHost expects $dnsAddr"

# ------------------------------------------------------------------------ 2. addressing
# WHY A STATIC ADDRESS AND A FAKE GATEWAY. With DHCP and no server the adapter self-assigns
# 169.254.x (APIPA) and has no default route. Windows classifies such an interface as having
# no connectivity and NCSI never probes it at all - the verdict is NoTraffic, which means
# "no traffic was seen", not "the probe failed". A route alone is not enough either: with a
# gateway that never answers ARP the neighbour sits in state Unreachable and the interface
# is still not "connected". The permanent neighbour entry is what settles it. All three -
# address, route, neighbour - are needed, and the first two alone changed nothing (measured
#).
Say 'addressing'
$have = Get-NetIPAddress -InterfaceAlias $InterfaceAlias -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -eq $Address -and $_.PrefixOrigin -eq 'Manual' }
$route = Get-NetRoute -InterfaceAlias $InterfaceAlias -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
         Where-Object { $_.NextHop -eq $Gateway }
$neigh = Get-NetNeighbor -IPAddress $Gateway -ErrorAction SilentlyContinue |
         Where-Object { $_.State -eq 'Permanent' }
if ($have -and $route -and $neigh) { Note "$Address/$PrefixLength via $Gateway, neighbour permanent - already set" }
elseif ($VerifyOnly) {
    Warn ("MISSING:{0}{1}{2}" -f $(if (-not $have) { ' address' }), $(if (-not $route) { ' route' }), $(if (-not $neigh) { ' neighbour' }))
} else {
    Set-NetIPInterface -InterfaceAlias $InterfaceAlias -AddressFamily IPv4 -Dhcp Disabled
    Get-NetIPAddress -InterfaceAlias $InterfaceAlias -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
    Get-NetRoute -InterfaceAlias $InterfaceAlias -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
        Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue
    New-NetIPAddress -InterfaceAlias $InterfaceAlias -IPAddress $Address -PrefixLength $PrefixLength `
        -DefaultGateway $Gateway | Out-Null
    Get-NetNeighbor -IPAddress $Gateway -ErrorAction SilentlyContinue | Remove-NetNeighbor -Confirm:$false -ErrorAction SilentlyContinue
    New-NetNeighbor -InterfaceAlias $InterfaceAlias -IPAddress $Gateway -LinkLayerAddress $GatewayMac -State Permanent | Out-Null
    # DNS at 127.0.0.1, where nothing listens: a lookup is REFUSED immediately rather than
    # timing out against an unreachable server. The guest resolves nothing itself - the
    # proxy takes CONNECT by name.
    Set-DnsClientServerAddress -InterfaceAlias $InterfaceAlias -ServerAddresses 127.0.0.1
    Note "$Address/$PrefixLength, default via $Gateway, permanent neighbour $GatewayMac, dns 127.0.0.1"
}

# ------------------------------------------------------------------------------ 3. IPv6
# Device-wide SSO prefers IPv6 and this guest has only a link-local address with no route,
# so that attempt fails instantly with ERROR_NETWORK_UNREACHABLE (0x800704cf) and the
# sign-in is rolled back AFTER appearing to succeed. Unbinding IPv6 makes the stack use the
# path that exists. MEASURED: this was the last of the six faults, and VS 2022
# sign-in completed and PERSISTED immediately after it.
Say 'IPv6'
$v6 = Get-NetAdapterBinding -Name $InterfaceAlias -ComponentID ms_tcpip6 -ErrorAction SilentlyContinue
if ($KeepIPv6) { Warn 'left bound by -KeepIPv6; device-wide sign-in will fail with 0x800704cf' }
elseif (-not $v6) { Warn 'ms_tcpip6 binding not found' }
elseif (-not $v6.Enabled) { Note 'already unbound' }
elseif ($VerifyOnly) { Warn 'ms_tcpip6 is STILL BOUND' }
else { Disable-NetAdapterBinding -Name $InterfaceAlias -ComponentID ms_tcpip6; Note 'unbound ms_tcpip6' }

# ------------------------------------------------------------------------- 4. hosts file
# THE WEB PROBE MUST POINT AT THE ADAPTER'S OWN ADDRESS, NOT AT 127.0.0.1. NCSI judges
# connectivity PER INTERFACE: mapping the probe host to loopback sends it over interface 1
# and the adapter under judgement sees nothing, so it stays NoTraffic however correctly the
# probe is answered (measured - the probes were perfect and the verdict did not
# move). The listener binds http://+:80/, so it answers on this address just as well.
Say 'hosts entries'
$wanted = @("$Address`t$webHost`t$marker", "$dnsAddr`t$dnsHost`t$marker")
$current = @(Get-Content $hostsFile -ErrorAction SilentlyContinue)
$missing = @($wanted | Where-Object { $current -notcontains $_ })
if ($missing.Count -eq 0) { Note 'already present' }
elseif ($VerifyOnly) { Warn "$($missing.Count) entr(y/ies) MISSING" }
else {
    $kept = @($current | Where-Object { $_ -notmatch [regex]::Escape($marker) })
    Set-Content -Path $hostsFile -Value ($kept + $wanted) -Encoding ASCII
    $wanted | ForEach-Object { Note "+ $_" }
}

# --------------------------------------------------------------------------- 5. responder
# Answers ANY path, not just connecttest.txt: Windows has asked for /ncsi.txt and
# /connecttest.txt over the years, and a 404 on the one it picks reads as "no internet"
# just as a timeout does. Never a redirect - NCSI reads 3xx as a captive portal, which is
# worse than offline because Windows then pops a "sign in to the network" flyout.
Say 'responder'
$body = @"
`$ErrorActionPreference = 'Stop'
`$listener = New-Object System.Net.HttpListener
`$listener.Prefixes.Add('http://+:$Port/')
`$listener.Start()
`$bytes = [System.Text.Encoding]::ASCII.GetBytes('$webContent')
while (`$listener.IsListening) {
    try {
        `$ctx = `$listener.GetContext()
        `$ctx.Response.StatusCode = 200
        `$ctx.Response.ContentType = 'text/plain'
        `$ctx.Response.ContentLength64 = `$bytes.Length
        `$ctx.Response.Headers.Add('Cache-Control', 'no-cache')
        `$ctx.Response.OutputStream.Write(`$bytes, 0, `$bytes.Length)
        `$ctx.Response.Close()
    } catch { Start-Sleep -Milliseconds 200 }
}
"@
if ($VerifyOnly) { if (Test-Path $script) { Note "$script present" } else { Warn "$script MISSING" } }
else {
    if (-not (Test-Path $Dir)) { New-Item -ItemType Directory -Path $Dir -Force | Out-Null }
    Set-Content -Path $script -Value $body -Encoding UTF8
    Note "wrote $script"
}

Say 'startup task'
$existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($VerifyOnly) {
    if ($existing) { Note "task $TaskName registered ($($existing.State))" } else { Warn "task $TaskName MISSING" }
} else {
    # SYSTEM, at startup, highest: binding http://+:80/ needs the privilege, and the probe
    # must be answerable before anyone logs in - NCSI runs long before the desktop.
    $action    = New-ScheduledTaskAction -Execute 'powershell.exe' `
                   -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$script`""
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                   -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger (New-ScheduledTaskTrigger -AtStartup) `
        -Principal $principal -Settings $settings -Force | Out-Null
    Note "registered $TaskName (at startup, SYSTEM)"
    if (-not $portAnswers) { Start-ScheduledTask -TaskName $TaskName; Note 'started it now' }
}

# ------------------------------------------------------------- 6. AppContainer exemptions
Say 'loopback exemptions'
$have = Get-Exempt
foreach ($c in $containers) {
    if ($have -contains $c) { Note "already exempt: $c" }
    elseif ($VerifyOnly)    { Warn "NOT exempt: $c" }
    else                    { Add-Exempt $c; Note "exempted: $c" }
}

# ---------------------------------------------------------------------------- 7. verdict
Say 'result'
if (-not $VerifyOnly) {
    Start-Sleep -Seconds 2
    ipconfig /flushdns | Out-Null
    # NCSI caches its verdict; restarting NlaSvc makes it re-probe now rather than on a timer.
    Restart-Service NlaSvc -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 10
}
$txt = Get-ProbeBody $probeUrl
if ($txt -eq $webContent)  { Note "web probe answers correctly: '$txt'" }
elseif ($null -eq $txt)    { Warn 'web probe did NOT answer at all' }
else                       { Warn "web probe answered '$txt', NCSI wants exactly '$webContent'" }
try {
    $r = @(Resolve-DnsName $dnsHost -ErrorAction Stop | Where-Object { $_.IPAddress } | ForEach-Object { $_.IPAddress })
    if ($r -contains $dnsAddr) { Note "dns probe resolves to $($r -join ', ') as required" }
    else { Warn "dns probe resolves to $($r -join ', '), NCSI wants $dnsAddr" }
} catch { Warn "dns probe did NOT resolve: $($_.Exception.Message)" }
# THE WANTED PAIR IS WAITED FOR, NOT SAMPLED, and that is measured rather than careful.
#
# MEASURED, on a guest six minutes old: read immediately after the responder was
# registered and started, this said IPv4=NoTraffic / LocalAccess. Nothing was changed after
# that, and eight minutes later the same guest read IPv4=Internet / InternetAccess - the
# pair this whole script exists to produce. Windows' NLA re-evaluates when it chooses, so a
# single reading taken at the earliest possible moment is the one guaranteed to be wrong.
#
# What that cost before this loop existed: the script printed the pessimistic pair, printed
# WANTED beneath it, compared the two not at all, and exited 0 - so provision's summary read
# "windows online ok" above output that said plainly it had not worked. Whichever way a
# reader resolved that contradiction, one of the two was lying to them.
#
# 90 s because it is cheap and NLA's own interval is not documented; a guest that has not
# got there by then has something else wrong. The poll is per-second and exits early.
function Get-OnlinePair {
    $p4 = (Get-NetConnectionProfile -EA SilentlyContinue | Select-Object -First 1).IPv4Connectivity
    $lvl = try {
        [Windows.Networking.Connectivity.NetworkInformation, Windows, ContentType=WindowsRuntime]::GetInternetConnectionProfile().GetNetworkConnectivityLevel()
    } catch { $null }
    [pscustomobject]@{ IPv4 = "$p4"; Level = "$lvl" }
}
$pair = $null
$waited = 0
foreach ($i in 1..90) {
    $pair = Get-OnlinePair
    if ($pair.IPv4 -eq 'Internet' -and $pair.Level -eq 'InternetAccess') { break }
    Start-Sleep -Seconds 1
    $waited = $i
}
Get-NetConnectionProfile -ErrorAction SilentlyContinue | ForEach-Object {
    Note ("profile: {0}  IPv4={1}  IPv6={2}" -f $_.Name, $_.IPv4Connectivity, $_.IPv6Connectivity)
}
Note ("WinRT connectivity level: {0}" -f $(if ($pair.Level) { $pair.Level } else { 'unavailable' }))
Note ''
# JUDGED, not merely printed. The pair is what the identity broker consults, so this is the
# line that decides whether signing in to anything will work.
if ($pair.IPv4 -eq 'Internet' -and $pair.Level -eq 'InternetAccess') {
    if ($waited) { Note "reached the wanted pair after ${waited}s - NLA re-evaluates on its own clock" }
    Note 'IPv4=Internet and InternetAccess: the fiction holds, with no egress of its own.'
} else {
    Fail "NOT ONLINE-LOOKING after ${waited}s: IPv4=$($pair.IPv4), WinRT=$($pair.Level)."
    Fail '  Wanted IPv4=Internet and InternetAccess. Everything else in this guest works;'
    Fail '  what fails is the identity broker, so a Microsoft or Epic sign-in will refuse.'
    Fail '  The responder and the route are in place by now, so the usual cause is that NLA'
    Fail '  has not re-evaluated: re-run this script, or reboot the guest and re-run it.'
    exit 4
}
