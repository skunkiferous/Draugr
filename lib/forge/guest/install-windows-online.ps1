# install-windows-online.ps1: let the WINDOWS IDENTITY STACK work behind a
# loopback proxy.
#
# Run this IN THE GUEST, elevated. An ssh session is already elevated, so a run
# through ssh is enough. Idempotent: each step tests first, -VerifyOnly changes
# nothing, and -Remove undoes all of it.
#
# ============================================================================ THE PROBLEM
#
# The forge guest has no adapter with a route (NetworkMode=0). All traffic
# leaves through the proxy at 127.0.0.1:3128. That works for each program that
# only makes an HTTP request: curl, MSYS2, Visual Studio 2017 and 2019, the Epic
# Games Launcher.
#
# It does NOT work for a program that signs in through WINDOWS, not through its
# own browser. Visual Studio 2022 is the first tool here that does. TESTS FOUND
# these faults, on top of each other, and each one hid the next:
#
#   1. Windows reports that it is offline, so the broker never tries.  0x800713AB
#   2. The connectivity probes can get an answer, but on the wrong     (still offline)
#      interface. Thus the judged interface sees no traffic.
#   3. The correct interface has no default route, so Windows does     (still offline)
#      not see it as a path to anywhere.
#   4. The route exists, but its gateway never answers ARP. Thus the   (still offline)
#      interface is still not "connected".
#   5. The broker runs in an APPCONTAINER, and Windows does not let    0x80190001
#      it reach 127.0.0.1. Thus its requests never reach the proxy,
#      and NOTHING shows in the denied log of the gateway.
#   6. Device-wide SSO prefers IPv6, which has no route here.          0x800704cf
#
# Each fix is useless without the others. That is why this is one script, not
# six.
#
# ===================================================================== WHAT IT DOES *NOT* DO
#
# IT GIVES NO EGRESS. No NIC is added, no rule is relaxed, nothing is published.
# TESTED after each step: a direct connection to 1.1.1.1 returns `000`
# (nothing), and the proxy still answers 403 for a host that the kit does not
# allow. The VM has no adapter with a path out. The routing table here is a
# story for Windows itself. With it, the identity code of Windows agrees to use
# the one path that exists.
#
# The cost: when Windows thinks that it is online, it starts the traffic that it
# skips while offline again: Store, Update, telemetry, SmartScreen. The gateway
# still denies all of it, so the cost is noise in `dr-policy --denied`, not
# exposure. Also, a DIRECT connection now fails in ~21 s, not ~0 ms, because the
# gateway address resolves (step 2), and is no longer unreachable. Nothing in
# the forge makes direct connections. Thus this is a cost for diagnosis, not for
# runs. If it is a problem for you, see TcpMaxConnectRetransmissions below.
#
# ================================================================== PUT IT IN layer-0
#
# Each change here is on the disk, so it belongs in the BASE image, not in a
# session. A layer frozen with this in place gives it to each child.
#
#   powershell -ExecutionPolicy Bypass -File .\install-windows-online.ps1
#   powershell -ExecutionPolicy Bypass -File .\install-windows-online.ps1 -VerifyOnly
#   powershell -ExecutionPolicy Bypass -File .\install-windows-online.ps1 -Remove
param(
    [string]$InterfaceAlias = 'Ethernet',   # the KM-TEST loopback adapter of install-guest-base
    # A private /24 that conflicts with nothing. NOT 192.168.42.x or
    # 192.168.142.x. Those are the own NAT of AppSandbox, made again at each
    # start of the daemon.
    [string]$Address        = '192.168.63.2',
    [int]   $PrefixLength   = 24,
    [string]$Gateway        = '192.168.63.1',
    # A locally administered MAC (02: prefix). It names nothing real, and
    # nothing needs that. Its only job is to make the stack stop the ARP for a
    # host that is not there.
    [string]$GatewayMac     = '02-00-00-00-63-01',
    [int]   $Port           = 80,           # NCSI asks for 80, and nothing can change that
    [string]$Dir            = "$env:ProgramData\draugr-ncsi",
    [string]$TaskName       = 'draugr-ncsi-responder',
    [switch]$KeepIPv6,                      # keep IPv6 bound. Device-wide SSO then fails
    [switch]$VerifyOnly,
    [switch]$Remove
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Say($m)  { Write-Host "`n=== $m ===" -ForegroundColor Cyan }
# EXIT CODES: 0 the wanted pair holds (IPv4=Internet, WinRT InternetAccess). 2 a
# precondition refused before something changed. 4 all was applied, but the pair
# did not appear within the wait. The guest is usable, but the sign-in is not.
function Note($m) { Write-Host "  $m" }
function Warn($m) { Write-Host "  $m" -ForegroundColor Yellow }
function Fail($m) { Write-Host "  $m" -ForegroundColor Red }

$hostsFile = "$env:SystemRoot\System32\drivers\etc\hosts"
$marker    = '# draugr-ncsi'
$script    = Join-Path $Dir 'ncsi-responder.ps1'

# The identity AppContainers. Windows does not let an AppContainer reach
# loopback without an exemption, and the proxy IS loopback. Without these, the
# requests of the account UI die inside Windows, and the gateway never sees
# them. AccountsControl is the dialog that a user sees. The other two are the
# broker and the sign-in host behind it.
$containers = @(
    'Microsoft.AccountsControl_cw5n1h2txyewy'
    'Microsoft.AAD.BrokerPlugin_cw5n1h2txyewy'
    'Microsoft.Windows.CloudExperienceHost_cw5n1h2txyewy'
)

# The probes of NCSI, read from the live registry, not fixed in the code. An
# image with other probes must get answers for ITS probes.
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

# Get-ProbeBody: what the probe URL returns, or $null. It goes DIRECT. On
# PowerShell 5.1, `Invoke-WebRequest -Proxy $null` still uses the system proxy.
# Here, that is tinyproxy, and it answers 500 for a host that it cannot reach.
# That looks the same as a dead listener (a test showed this, and it cost an
# hour). NCSI goes direct, so this must too.
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

# Get-Exempt / Add-Exempt: CheckNetIsolation THROUGH cmd, never directly from
# PowerShell. When PowerShell gives the argument, `CheckNetIsolation
# LoopbackExempt -a -n=Name` returns "Error: Invalid Parameters", because
# PowerShell damages `-n=value` (a test showed this). cmd gives it without
# change. The same kind of trap as the need for \" for an argument with spaces
# through ssh.
function Get-Exempt {
    # The 2>&1 is WANTED. The code parses this output as text, and a complaint
    # belongs in the text, not on a stream that nobody reads. But with Stop in
    # force, a native stderr line is a terminating error. Thus the code drops
    # the preference for the time of the call, and restores it. See
    # docs/FORGE.md. tests/lint-native-stderr.sh keeps this from going back.
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
        Note 'IPv6 enabled again'
    }
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false; Note "task $TaskName unregistered"
    }
    Get-NetNeighbor -IPAddress $Gateway -ErrorAction SilentlyContinue |
        Remove-NetNeighbor -Confirm:$false -ErrorAction SilentlyContinue
    Set-DnsClientServerAddress -InterfaceAlias $InterfaceAlias -ResetServerAddress -ErrorAction SilentlyContinue
    Set-NetIPInterface -InterfaceAlias $InterfaceAlias -AddressFamily IPv4 -Dhcp Enabled -ErrorAction SilentlyContinue
    Note 'addressing returned to DHCP (APIPA), neighbor and DNS cleared'
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
    Fail "no adapter '$InterfaceAlias'. install-guest-base.ps1 adds the KM-TEST loopback adapter."
    Fail 'Run that first. With no adapter, NCSI has nothing to judge.'
    exit 2
}
$portAnswers = $false
$owner = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
if ($owner) {
    # DO NOT ASK WHO OWNS THE SOCKET. HttpListener binds through http.sys, so
    # the owner is the System process (pid 4), with no command line. An earlier
    # version read that as "somebody else has port 80", and refused to run on a
    # guest with a correct install. The answer of the listener is what matters,
    # and NCSI also judges that.
    if ((Get-ProbeBody $probeUrl) -eq $webContent) { $portAnswers = $true; Note "port $Port already answers correctly" }
    else {
        Fail "pid(s) $(($owner.OwningProcess | Sort-Object -Unique) -join ', ') hold port $Port, and it does not answer the probe."
        Fail 'NCSI cannot use another port. Free it, or skip this guest.'
        exit 2
    }
} else { Note "port $Port is free" }
Note "web probe : $probeUrl expects '$webContent'"
Note "dns probe : $dnsHost expects $dnsAddr"

# ------------------------------------------------------------------------ 2. addressing
# WHY A STATIC ADDRESS AND A FAKE GATEWAY. With DHCP and no server, the adapter
# gives itself 169.254.x (APIPA), and has no default route. Windows classifies
# such an interface as without connectivity, and NCSI never probes it. The
# result is NoTraffic. That means "no traffic was seen", not "the probe failed".
# A route alone is not enough either. With a gateway that never answers ARP,
# the neighbor stays in the state Unreachable, and the interface is still not
# "connected". The permanent neighbor entry decides it. All three are necessary:
# address, route, and neighbor. The first two alone changed nothing (a test
# showed this).
Say 'addressing'
$have = Get-NetIPAddress -InterfaceAlias $InterfaceAlias -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -eq $Address -and $_.PrefixOrigin -eq 'Manual' }
$route = Get-NetRoute -InterfaceAlias $InterfaceAlias -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
         Where-Object { $_.NextHop -eq $Gateway }
$neigh = Get-NetNeighbor -IPAddress $Gateway -ErrorAction SilentlyContinue |
         Where-Object { $_.State -eq 'Permanent' }
if ($have -and $route -and $neigh) { Note "$Address/$PrefixLength via $Gateway, neighbor permanent. Already set." }
elseif ($VerifyOnly) {
    Warn ("MISSING:{0}{1}{2}" -f $(if (-not $have) { ' address' }), $(if (-not $route) { ' route' }), $(if (-not $neigh) { ' neighbor' }))
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
    # DNS at 127.0.0.1, where nothing listens. A lookup is REFUSED at once, and
    # does not wait for a timeout from a server that it cannot reach. The guest
    # resolves nothing itself. The proxy takes CONNECT by name.
    Set-DnsClientServerAddress -InterfaceAlias $InterfaceAlias -ServerAddresses 127.0.0.1
    Note "$Address/$PrefixLength, default via $Gateway, permanent neighbor $GatewayMac, dns 127.0.0.1"
}

# ------------------------------------------------------------------------------ 3. IPv6
# Device-wide SSO prefers IPv6, and this guest has only a link-local address
# with no route. Thus that attempt fails at once with ERROR_NETWORK_UNREACHABLE
# (0x800704cf), and the sign-in is undone AFTER it looks like a success. With
# IPv6 unbound, the stack uses the path that exists. A TEST SHOWED THIS: this
# was the last of the six faults. Directly after it, the sign-in of VS 2022
# completed and STAYED.
Say 'IPv6'
$v6 = Get-NetAdapterBinding -Name $InterfaceAlias -ComponentID ms_tcpip6 -ErrorAction SilentlyContinue
if ($KeepIPv6) { Warn 'still bound, because of -KeepIPv6. Device-wide sign-in fails with 0x800704cf' }
elseif (-not $v6) { Warn 'ms_tcpip6 binding not found' }
elseif (-not $v6.Enabled) { Note 'already unbound' }
elseif ($VerifyOnly) { Warn 'ms_tcpip6 is STILL BOUND' }
else { Disable-NetAdapterBinding -Name $InterfaceAlias -ComponentID ms_tcpip6; Note 'unbound ms_tcpip6' }

# ------------------------------------------------------------------------- 4. hosts file
# THE WEB PROBE MUST POINT TO THE OWN ADDRESS OF THE ADAPTER, NOT TO 127.0.0.1.
# NCSI judges connectivity FOR EACH INTERFACE. If the probe host maps to
# loopback, the probe goes through interface 1, and the judged adapter sees
# nothing. Thus it stays NoTraffic, also with a correct answer to the probe (a
# test showed this: the probes were perfect, and the result did not change). The
# listener binds http://+:80/, so it also answers on this address.
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
# It answers EACH path, not only connecttest.txt. Over the years, Windows asked
# for /ncsi.txt and for /connecttest.txt. A 404 on the one that it selects means
# "no internet", as a timeout does. Never a redirect. NCSI reads 3xx as a
# captive portal. That is worse than offline, because Windows then shows a "sign
# in to the network" flyout.
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
    # SYSTEM, at startup, highest. The bind of http://+:80/ needs the privilege,
    # and the probe must answer before somebody logs in. NCSI runs long before
    # the desktop.
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
    # NCSI caches its result. A restart of NlaSvc makes it probe again now, not
    # at a timer.
    Restart-Service NlaSvc -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 10
}
$txt = Get-ProbeBody $probeUrl
if ($txt -eq $webContent)  { Note "web probe answers correctly: '$txt'" }
elseif ($null -eq $txt)    { Warn 'web probe did NOT answer' }
else                       { Warn "web probe answered '$txt'. NCSI wants exactly '$webContent'" }
try {
    $r = @(Resolve-DnsName $dnsHost -ErrorAction Stop | Where-Object { $_.IPAddress } | ForEach-Object { $_.IPAddress })
    if ($r -contains $dnsAddr) { Note "dns probe resolves to $($r -join ', ') as required" }
    else { Warn "dns probe resolves to $($r -join ', '). NCSI wants $dnsAddr" }
} catch { Warn "dns probe did NOT resolve: $($_.Exception.Message)" }
# THE CODE WAITS FOR THE WANTED PAIR, AND DOES NOT TAKE ONE SAMPLE. A test, not
# caution, is the reason.
#
# A TEST on a guest six minutes old: directly after the registration and start
# of the responder, this said IPv4=NoTraffic / LocalAccess. Nothing changed
# after that, and eight minutes later the same guest said IPv4=Internet /
# InternetAccess. This whole script exists to make that pair. The NLA of Windows
# evaluates again at a time that it selects. Thus one sample at the earliest
# time is surely wrong.
#
# The cost before this loop: the script printed the bad pair, printed WANTED
# below it, did not compare the two, and exited 0. Thus the summary of provision
# said "windows online ok", above output that clearly said that it did not work.
# For each reader, one of the two lied.
#
# 90 s, because it is cheap, and the interval of NLA is not documented. A guest
# that is not there after 90 s has a different problem. The poll is once each
# second, and exits early.
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
# JUDGED, not only printed. The identity broker reads the pair. Thus this line
# decides whether a sign-in works.
if ($pair.IPv4 -eq 'Internet' -and $pair.Level -eq 'InternetAccess') {
    if ($waited) { Note "got the wanted pair after ${waited}s. NLA evaluates again on its own clock" }
    Note 'IPv4=Internet and InternetAccess: the fiction works, with no egress of its own.'
} else {
    Fail "DOES NOT LOOK ONLINE after ${waited}s: IPv4=$($pair.IPv4), WinRT=$($pair.Level)."
    Fail '  Wanted IPv4=Internet and InternetAccess. All else in this guest works.'
    Fail '  The identity broker fails, so a Microsoft or Epic sign-in refuses.'
    Fail '  The responder and the route are in place now. Usually, NLA did not evaluate'
    Fail '  again yet. Run this script again, or reboot the guest and run it again.'
    exit 4
}
