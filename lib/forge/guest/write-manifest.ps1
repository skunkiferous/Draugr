# write-manifest.ps1 - what this guest actually has, written where anyone can find it.
#
# Run it IN THE GUEST, any time. Apart from the two files it writes it is read-only, so it
# is also the fastest answer to "what is on this VM" - for a human opening it, and for the
# agent, which parses the JSON instead of probing fifteen things itself.
#
# IT INSPECTS; IT DOES NOT TRUST. Nothing is reported because an installer said it
# installed something: every line is read back from the running system - versions by
# running the binary, services by their state, settings out of the registry. A manifest
# assembled from install-time claims drifts the first time someone changes something by
# hand, and then it lies with confidence. This one can be stale, but it cannot be wrong:
# re-run it and it is current.
#
# Two files, same content, because there are two readers:
#   manifest.json  the agent parses this
#   MANIFEST.txt   a human opens this
#
# C:\Draugr rather than somewhere under ProgramData, for the same reason TEMP moves to
# C:\temp: a path you can see is a path you remember to look at.
#
#   powershell -ExecutionPolicy Bypass -File .\write-manifest.ps1
#   powershell -ExecutionPolicy Bypass -File .\write-manifest.ps1 -Print
param(
    [string]$Dir = 'C:\Draugr',
    [string]$Msys = 'C:\msys64',
    [string]$AhkDir = 'C:\Tools\AutoHotkey',
    [int]$McpPort = 8765,
    # The NCSI fiction that install-windows-online.ps1 installs. Named here so the
    # two scripts cannot drift apart silently: if that script's defaults move and
    # these do not, this one stops recognising the route and says so loudly, which
    # is the right failure. Keep them equal.
    [string]$NcsiGateway = '192.168.63.1',
    [string]$NcsiGatewayMac = '02-00-00-00-63-01',
    [switch]$Print
)

$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'

# Get-Reg, never R: `R` is the built-in alias for Invoke-History, and an alias beats a
# function in PowerShell's resolution order - a helper called R silently becomes a
# different command. It also always returns exactly one value, because returning nothing
# shifts the caller's arguments and turns the next format string into a swallowed error.
function Get-Reg([string]$p, [string]$n) {
    $v = (Get-ItemProperty -Path $p -Name $n -EA SilentlyContinue).$n
    if ($null -eq $v -or "$v" -eq '') { return $null }
    return "$v"
}

$bash = Join-Path $Msys 'usr\bin\bash.exe'
function Invoke-Msys([string]$cmd) {
    if (-not (Test-Path $bash)) { return @() }
    # Subshell + </dev/null: over ssh there is no terminal, and the redirect must wrap the
    # WHOLE pipeline or it applies only to its last stage.
    & $bash -lc "( $cmd ) < /dev/null" 2>$null
}
# Summing Length over a directory tree counts every ENTRY, so a hard-linked file is
# counted once per link and the answer is too big. Fine for trees without hard links
# (uv, AutoHotkey); wrong for MSYS2, which has 162 of them - measured:
# Get-ChildItem says 1027 MB, `du -sm` says 487 MB, `du --count-links` says 1069 MB.
# The disk only holds 487.
function Get-Mb([string]$p) {
    if (-not (Test-Path $p)) { return 0 }
    [math]::Round((Get-ChildItem $p -Recurse -File -Force -EA SilentlyContinue |
        Measure-Object Length -Sum).Sum / 1MB, 1)
}
# For anything that may contain hard links, ask du, which counts each inode once.
function Get-MbOnDisk([string]$winPath) {
    $u = ($winPath -replace '\\', '/') -replace '^([A-Za-z]):', '/$1'
    $u = $u -replace '^/([A-Za-z])', '/$1'
    $out = Invoke-Msys "du -sm '$($u.ToLower())' 2>/dev/null | cut -f1"
    $n = "$($out | Select-Object -First 1)".Trim()
    if ($n -match '^\d+$') { return [double]$n }
    return (Get-Mb $winPath)
}

$os = Get-CimInstance Win32_OperatingSystem
$cs = Get-CimInstance Win32_ComputerSystem
$c  = Get-PSDrive C

# --- the Unix layer, read from pacman itself -----------------------------------------
$pkgCount = 0
$pkgList = @()
foreach ($line in (Invoke-Msys 'pacman -Q 2>/dev/null')) {
    $p = "$line".Trim() -split '\s+'
    if ($p.Count -ge 2) { $pkgCount++; $pkgList += "$($p[0]) $($p[1])" }
}
# Only the mirrorlists pacman.conf actually Includes. Globbing mirrorlist.* instead picks
# up .orig and .pacnew copies that pacman never reads, and reports a guest pinned to one
# host as pinned to 31 - measured, and it is the same trap install-msys2.ps1 documents.
#
# Read in PowerShell rather than through a shell pipeline: an awk/xargs version of this
# returned nothing at all, because the quoting has to survive PowerShell, bash -lc and awk
# in turn. Get-Content has no such gauntlet.
$mirrors = @()
$pacConf = Join-Path $Msys 'etc\pacman.conf'
foreach ($l in (Get-Content $pacConf -EA SilentlyContinue)) {
    if ($l -notmatch '^\s*Include\s*=\s*(\S+)') { continue }
    $f = $Matches[1] -replace '^/etc/', "$($Msys -replace '\\','/')/etc/"
    foreach ($s in (Get-Content $f -EA SilentlyContinue)) {
        if ($s -match '^\s*Server\s*=.*://([^/]+)/') { $mirrors += $Matches[1] }
    }
}
$mirrors = @($mirrors | Sort-Object -Unique)

# --- the Python layer, read from uv ---------------------------------------------------
$uvBin = "$env:USERPROFILE\.local\bin"
$uvExe = Join-Path $uvBin 'uv.exe'
$uvVer = $null
if (Test-Path $uvExe) { $uvVer = "$(& $uvExe --version 2>$null | Select-Object -First 1)".Trim() }
$pyTools = @()
if (Test-Path $uvExe) {
    foreach ($line in (& $uvExe tool list 2>$null)) {
        if ("$line" -match '^(\S+)\s+v(\S+)') { $pyTools += "$($Matches[1]) $($Matches[2])" }
    }
}

$adv  = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
$desk = 'HKCU:\Control Panel\Desktop'
$ws   = Get-Service WSearch -EA SilentlyContinue
$tvn  = Get-Service tvnserver -EA SilentlyContinue
$ahkExe = Join-Path $AhkDir 'AutoHotkey64.exe'
$listening = @(Get-NetTCPConnection -State Listen -EA SilentlyContinue |
    Where-Object { $_.LocalAddress -eq '127.0.0.1' } |
    ForEach-Object { $_.LocalPort } | Sort-Object -Unique)
schtasks /query /tn 'windows-mcp-server' 2>$null | Out-Null
$mcpTask = $(if ($LASTEXITCODE -eq 0) { 'registered' } else { 'absent' })

# A default route is not by itself a way out, and since install-windows-online.ps1 this
# guest HAS one on purpose: Windows will not judge an interface online unless it can see a
# route through it, so the route points at an address with a hand-written permanent
# neighbour and nothing behind it.
#
# MEASURED on a guest configured that way: a direct connection to 1.1.1.1 still
# returns 000 - after 21.07 s of trying to reach that gateway, where an unconfigured guest
# fails in 0 ms. The route changes how long the failure takes, not whether it fails.
#
# So this reports the route instead of counting it, and judges the one thing that matters:
# is the next hop that fiction, or something that might really forward? A gateway that
# exists answers ARP and its neighbour goes Reachable. The fiction stays Permanent, because
# nothing ever resolved it - it was written there by hand.
#
# Before this, a correctly built guest's manifest read "default route present: True
# (must be False)", which is a file whose whole purpose is to be believed crying wolf.
$dr = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -EA SilentlyContinue | Select-Object -First 1
$routeVia = $null
$routeNeighbour = $null
$routeIsFiction = $false
if ($dr) {
    $routeVia = $dr.NextHop
    $nb = Get-NetNeighbor -IPAddress $dr.NextHop -EA SilentlyContinue | Select-Object -First 1
    if ($nb) { $routeNeighbour = "$($nb.State) $($nb.LinkLayerAddress)" }
    # -replace strips the separator so 02-00-.. and 02:00:.. compare equal; -eq on strings
    # is case-insensitive in PowerShell, which is what a MAC wants.
    $routeIsFiction = ($routeVia -eq $NcsiGateway -and $null -ne $nb -and
                       $nb.State -eq 'Permanent' -and
                       ($nb.LinkLayerAddress -replace '[:-]', '') -eq ($NcsiGatewayMac -replace '[:-]', ''))
}

$m = [ordered]@{
    generated = (Get-Date).ToString('s')
    generator = 'draugr/lib/forge/guest/write-manifest.ps1'
    machine = [ordered]@{
        name        = $env:COMPUTERNAME
        user        = "$env:USERDOMAIN\$env:USERNAME"
        os          = "$($os.Caption) $($os.Version)"
        edition     = (Get-Reg 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' 'EditionID')
        ramGb       = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
        cpus        = $cs.NumberOfLogicalProcessors
        diskFreeGb  = [math]::Round($c.Free / 1GB, 1)
        diskTotalGb = [math]::Round(($c.Free + $c.Used) / 1GB, 1)
    }
    egress = [ordered]@{
        adapters     = @(Get-NetAdapter -EA SilentlyContinue | ForEach-Object { $_.InterfaceDescription })
        defaultRoute          = [bool]$dr
        defaultRouteVia       = $routeVia
        defaultRouteNeighbour = $routeNeighbour
        defaultRouteIsFiction = $routeIsFiction
        proxyWinInet = (Get-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' 'ProxyServer')
        proxyEnv     = [Environment]::GetEnvironmentVariable('HTTPS_PROXY', 'Machine')
    }
    software = [ordered]@{
        msys2 = [ordered]@{
            root     = $(if (Test-Path $bash) { $Msys } else { $null })
            sizeMb   = (Get-MbOnDisk $Msys)
            packages = $pkgCount
            pinnedTo = $mirrors
        }
        python = [ordered]@{
            uv          = $uvVer
            # uv keeps a .temp scratch directory beside the interpreters; it is not one.
            interpreter = @(Get-ChildItem "$env:APPDATA\uv\python" -Directory -EA SilentlyContinue |
                            Where-Object { $_.Name -notlike '.*' } | ForEach-Object { $_.Name })
            tools       = $pyTools
            sizeMb      = (Get-Mb "$env:APPDATA\uv")
            cacheMb     = (Get-Mb "$env:LOCALAPPDATA\uv\cache")
        }
        autohotkey = [ordered]@{
            dir     = $(if (Test-Path $ahkExe) { $AhkDir } else { $null })
            version = (Get-Item $ahkExe -EA SilentlyContinue).VersionInfo.ProductVersion
            sizeMb  = (Get-Mb $AhkDir)
        }
        screen = [ordered]@{
            server       = $(if ($tvn) { "tvnserver $($tvn.Status)" } else { $null })
            loopbackOnly = (Get-Reg 'HKLM:\SOFTWARE\TightVNC\Server' 'LoopbackOnly')
        }
    }
    services = [ordered]@{
        listeningLoopback = $listening
        mcpPort           = $McpPort
        mcpTask           = $mcpTask
        lanmanServer      = "$((Get-Service LanmanServer -EA SilentlyContinue).StartType)"
        searchIndexer     = $(if ($ws) { "$($ws.Status)/$((Get-Service WSearch).StartType)" } else { 'absent' })
    }
    settings = [ordered]@{
        temp           = [Environment]::GetEnvironmentVariable('TEMP', 'Machine')
        # THREE OF THESE REGISTRY VALUES MEAN THE OPPOSITE OF WHAT A FIELD NAMED AFTER THEM
        # WOULD SUGGEST, so they are rendered as words rather than printed raw. A manifest
        # exists to be read at a glance, and a line that reads as its own opposite is worse
        # than no line at all - `windowsUpdate 1` for NoAutoUpdate=1 was doing exactly that.
        #   Hidden:       1 = show, 2 = hide          (not a boolean, and 2 reads as "more")
        #   DontShowUI:   1 = the WER dialog is gone
        #   NoAutoUpdate: 1 = automatic updates are off
        # showExtensions was already done this way, from HideFileExt inverted; the rest of
        # the fields are named positively and print their raw value, which is honest.
        showHidden     = $(if ((Get-Reg $adv 'Hidden') -eq '1') { 'yes' } else { 'no' })
        showExtensions = $(if ((Get-Reg $adv 'HideFileExt') -eq '0') { 'yes' } else { 'no' })
        cursorSize     = (Get-Reg 'HKCU:\Control Panel\Cursors' 'CursorBaseSize')
        visualEffects  = (Get-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects' 'VisualFXSetting')
        menuShowDelay  = (Get-Reg $desk 'MenuShowDelay')
        screenSaver    = (Get-Reg $desk 'ScreenSaveActive')
        toasts         = (Get-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\PushNotifications' 'ToastEnabled')
        longPaths      = (Get-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' 'LongPathsEnabled')
        # Whether a mounted vault is visible to Explorer, which is how a person looks at
        # one. '(not set)' here means mount-vault's drives exist only for whichever
        # elevation level mapped them. See install-guest-base.ps1 section 9b.
        linkedDrives   = (Get-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' 'EnableLinkedConnections')
        werDialog      = $(if ((Get-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting' 'DontShowUI') -eq '1') { 'suppressed' } else { 'shown' })
        codepage       = (Get-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\Nls\CodePage' 'ACP')
        autoUpdate     = $(if ((Get-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' 'NoAutoUpdate') -eq '1') { 'blocked' } else { 'automatic' })
        # BOTH HALVES, because they fail separately and for different reasons. The zone is a
        # deliberate base setting that a frozen parent hands down and no child can change, so
        # the record of it belongs here. The UTC clock is the half that must agree with the
        # host: together they make a timestamp that looks wrong diagnosable, where either
        # alone just looks odd. An adapterless guest never runs w32time, so UTC is the
        # hypervisor's and a drift here means something is wrong with the host, not the VM.
        timezone       = ("{0} (UTC{1})" -f (Get-TimeZone).Id, (Get-TimeZone).BaseUtcOffset)
        clockUtc       = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm')
    }
    packages = $pkgList
}

if (-not (Test-Path $Dir)) { New-Item -ItemType Directory -Force -Path $Dir | Out-Null }
[IO.File]::WriteAllText((Join-Path $Dir 'manifest.json'), ($m | ConvertTo-Json -Depth 8))

# --- the human half ------------------------------------------------------------------
$t = New-Object Text.StringBuilder
function Add-Line($s) { [void]$t.AppendLine("$s") }
Add-Line 'Draugr forge guest - what is on this machine'
Add-Line "generated $($m.generated) by $($m.generator)"
Add-Line ''
Add-Line "MACHINE   $($m.machine.name)  $($m.machine.os)  edition $($m.machine.edition)"
Add-Line "          $($m.machine.cpus) cpus, $($m.machine.ramGb) GB RAM, $($m.machine.diskFreeGb) of $($m.machine.diskTotalGb) GB free"
Add-Line ''
Add-Line 'EGRESS    this VM has no adapter of its own; everything leaves through the proxy'
Add-Line "          proxy       $($m.egress.proxyWinInet)"
Add-Line "          adapters    $($m.egress.adapters -join ', ')"
if (-not $m.egress.defaultRoute) {
    Add-Line "          default route  none"
} elseif ($m.egress.defaultRouteIsFiction) {
    Add-Line "          default route  via $($m.egress.defaultRouteVia), neighbour $($m.egress.defaultRouteNeighbour)"
    Add-Line "                         EXPECTED. That address is the NCSI fiction, not a way out:"
    Add-Line "                         a hand-written neighbour with nothing behind it, there only so"
    Add-Line "                         that Windows will judge this interface online. Egress is still"
    Add-Line "                         the proxy and nothing else."
} else {
    Add-Line "          default route  via $($m.egress.defaultRouteVia), neighbour $($m.egress.defaultRouteNeighbour)"
    Add-Line "                         *** NOT the NCSI fiction. This VM may have a real way out."
    Add-Line "                         *** Check that before trusting anything else in this file."
}
Add-Line ''
Add-Line 'SOFTWARE'
if ($m.software.msys2.root) {
    Add-Line "          MSYS2       $($m.software.msys2.packages) packages, $($m.software.msys2.sizeMb) MB, pinned to $($m.software.msys2.pinnedTo -join ', ')"
} else {
    # Without this the line read "0 packages, 0 MB, pinned to" and stopped there,
    # which reads as a broken script rather than as an absent package manager.
    Add-Line "          MSYS2       not installed"
}
Add-Line "          Python      $($m.software.python.uv), $($m.software.python.interpreter -join ', '), $($m.software.python.sizeMb) MB (cache $($m.software.python.cacheMb) MB)"
foreach ($tool in $m.software.python.tools) { Add-Line "                      tool: $tool" }
Add-Line "          AutoHotkey  $($m.software.autohotkey.version) in $($m.software.autohotkey.dir), $($m.software.autohotkey.sizeMb) MB"
Add-Line "          Screen      $($m.software.screen.server), loopbackOnly=$($m.software.screen.loopbackOnly)"
Add-Line ''
Add-Line 'SERVICES'
Add-Line "          listening on loopback: $($m.services.listeningLoopback -join ', ')"
Add-Line "          UIA MCP server on port $($m.services.mcpPort), login task $($m.services.mcpTask)"
Add-Line "          LanmanServer $($m.services.lanmanServer), search indexer $($m.services.searchIndexer)"
Add-Line ''
Add-Line 'SETTINGS  (these exist for the agent rather than for a person)'
# An unset registry value renders as an empty column, which reads as "zero" rather than
# "never configured" - and those mean opposite things for most of these.
foreach ($k in $m.settings.Keys) {
    $v = $m.settings[$k]
    if ($null -eq $v -or "$v" -eq '') { $v = '(not set)' }
    Add-Line ("          {0,-15} {1}" -f $k, $v)
}
Add-Line ''
Add-Line 'NOT HERE, DELIBERATELY: the Epic account, the engine versions and Visual Studio are'
Add-Line 'layers on top of this base, not part of it. The full package list is in manifest.json.'
Add-Line ''
Add-Line 'Re-run guest\write-manifest.ps1 to refresh. It reads the machine; it does not trust'
Add-Line 'any installer to have told the truth.'

[IO.File]::WriteAllText((Join-Path $Dir 'MANIFEST.txt'), $t.ToString())
Write-Host "manifest written: $Dir\manifest.json and $Dir\MANIFEST.txt"
if ($Print) { Write-Host ''; Write-Host $t.ToString() }
