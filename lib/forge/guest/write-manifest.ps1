# write-manifest.ps1: what this guest really has, written where everybody can
# find it.
#
# Run it IN THE GUEST, at any time. Except for the two files that it writes, it
# is read-only. Thus it is also the fastest answer to "what is on this VM?", for
# a person who opens it, and for the agent, which parses the JSON, and does not
# probe fifteen things itself.
#
# IT INSPECTS, AND DOES NOT TRUST. It reports nothing only because an installer
# said that it installed something. Each line comes from the running system:
# versions from a run of the binary, services from their state, values from the
# registry. A manifest from claims at install time drifts at the first manual
# change, and then it lies with confidence. This one can be old, but it cannot
# be wrong. Run it again, and it is current.
#
# Two files, with the same content, because there are two readers:
#   manifest.json  the agent parses this
#   MANIFEST.txt   a person opens this
#
# C:\Draugr, not a place under ProgramData, for the same reason that TEMP moves
# to C:\temp. You remember to look at a path that you can see.
#
#   powershell -ExecutionPolicy Bypass -File .\write-manifest.ps1
#   powershell -ExecutionPolicy Bypass -File .\write-manifest.ps1 -Print
param(
    [string]$Dir = 'C:\Draugr',
    [string]$Msys = 'C:\msys64',
    [string]$AhkDir = 'C:\Tools\AutoHotkey',
    [int]$McpPort = 8765,
    # The NCSI fiction that install-windows-online.ps1 installs. Named here, so
    # that the two scripts cannot become different silently. If the defaults of
    # that script change and these do not, this one stops to recognize the
    # route, and says so clearly. That is the correct failure. Keep them equal.
    [string]$NcsiGateway = '192.168.63.1',
    [string]$NcsiGatewayMac = '02-00-00-00-63-01',
    [switch]$Print
)

$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'

# Get-Reg, never R. `R` is the built-in alias for Invoke-History, and in the
# resolution order of PowerShell, an alias wins over a function. A helper called
# R silently becomes a different command. It also always returns exactly one
# value. With no value, the arguments of the caller move, and the next format
# string becomes a hidden error.
function Get-Reg([string]$p, [string]$n) {
    $v = (Get-ItemProperty -Path $p -Name $n -EA SilentlyContinue).$n
    if ($null -eq $v -or "$v" -eq '') { return $null }
    return "$v"
}

$bash = Join-Path $Msys 'usr\bin\bash.exe'
function Invoke-Msys([string]$cmd) {
    if (-not (Test-Path $bash)) { return @() }
    # Subshell + </dev/null. Through ssh, there is no terminal. The redirect
    # must be around the WHOLE pipeline, or it applies only to its last stage.
    & $bash -lc "( $cmd ) < /dev/null" 2>$null
}
# A sum of Length over a directory tree counts each ENTRY. Thus it counts a
# hard-linked file once for each link, and the answer is too large. That is good
# for trees without hard links (uv, AutoHotkey), but wrong for MSYS2, which has
# 162 of them. A test showed this: Get-ChildItem says 1027 MB, `du -sm` says 487
# MB, `du --count-links` says 1069 MB. The disk holds only 487.
function Get-Mb([string]$p) {
    if (-not (Test-Path $p)) { return 0 }
    [math]::Round((Get-ChildItem $p -Recurse -File -Force -EA SilentlyContinue |
        Measure-Object Length -Sum).Sum / 1MB, 1)
}
# For each tree that can have hard links, ask du, which counts each inode once.
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
# Only the mirrorlists that pacman.conf Includes. A glob of mirrorlist.* also
# finds .orig and .pacnew copies that pacman never reads. Then it reports a
# guest pinned to one host as pinned to 31. A test showed this, and
# install-msys2.ps1 documents the same trap.
#
# Read in PowerShell, not through a shell pipeline. An awk/xargs version of this
# returned nothing, because the quotes must survive PowerShell, bash -lc, and
# awk, one after the other. Get-Content has no such problem.
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

# A default route alone is not a way out. Since install-windows-online.ps1, this
# guest HAS one, on purpose. Windows judges an interface online only if it can
# see a route through it. Thus the route points to an address with a manually
# written permanent neighbor, and nothing behind it.
#
# A TEST on a guest with that configuration: a direct connection to 1.1.1.1
# still returns 000, after 21.07 s of attempts to reach that gateway. A guest
# without the configuration fails in 0 ms. The route changes the time of the
# failure, not the failure.
#
# Thus this reports the route, and does not count it. It judges the one
# important thing: is the next hop that fiction, or something that can really
# forward? A gateway that exists answers ARP, and its neighbor becomes
# Reachable. The fiction stays Permanent, because nothing ever resolved it.
# Somebody wrote it there by hand.
#
# Before this, the manifest of a correctly built guest said "default route
# present: True (must be False)". People must believe this file, and it gave a
# false alarm.
$dr = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -EA SilentlyContinue | Select-Object -First 1
$routeVia = $null
$routeNeighbour = $null
$routeIsFiction = $false
if ($dr) {
    $routeVia = $dr.NextHop
    $nb = Get-NetNeighbor -IPAddress $dr.NextHop -EA SilentlyContinue | Select-Object -First 1
    if ($nb) { $routeNeighbour = "$($nb.State) $($nb.LinkLayerAddress)" }
    # -replace removes the separator, so that 02-00-.. and 02:00:.. are equal.
    # In PowerShell, -eq on strings ignores case, and a MAC needs that.
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
            # uv keeps a .temp scratch directory next to the interpreters. It is
            # not one.
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
        # THREE OF THESE REGISTRY VALUES MEAN THE OPPOSITE OF THEIR FIELD NAMES.
        # Thus they show as words, not as raw values. People read a manifest
        # quickly. A line that looks like its own opposite is worse than no
        # line. `windowsUpdate 1` for NoAutoUpdate=1 did exactly that.
        #   Hidden:       1 = show, 2 = hide          (not a boolean, and 2 looks like "more")
        #   DontShowUI:   1 = the WER dialog is gone
        #   NoAutoUpdate: 1 = automatic updates are off
        # showExtensions already worked this way, from HideFileExt inverted. The
        # other fields have positive names, and print their raw value. That is
        # correct.
        showHidden     = $(if ((Get-Reg $adv 'Hidden') -eq '1') { 'yes' } else { 'no' })
        showExtensions = $(if ((Get-Reg $adv 'HideFileExt') -eq '0') { 'yes' } else { 'no' })
        cursorSize     = (Get-Reg 'HKCU:\Control Panel\Cursors' 'CursorBaseSize')
        visualEffects  = (Get-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects' 'VisualFXSetting')
        menuShowDelay  = (Get-Reg $desk 'MenuShowDelay')
        screenSaver    = (Get-Reg $desk 'ScreenSaveActive')
        toasts         = (Get-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\PushNotifications' 'ToastEnabled')
        longPaths      = (Get-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' 'LongPathsEnabled')
        # Whether Explorer can see a mounted vault. A person looks at a vault
        # with Explorer. '(not set)' here means that the drives of mount-vault
        # exist only for the elevation level that mapped them. See
        # install-guest-base.ps1 section 9b.
        linkedDrives   = (Get-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' 'EnableLinkedConnections')
        werDialog      = $(if ((Get-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting' 'DontShowUI') -eq '1') { 'suppressed' } else { 'shown' })
        codepage       = (Get-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\Nls\CodePage' 'ACP')
        autoUpdate     = $(if ((Get-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' 'NoAutoUpdate') -eq '1') { 'blocked' } else { 'automatic' })
        # BOTH HALVES, because they fail separately, for different reasons. The
        # zone is a deliberate base value that a frozen parent gives down, so
        # its record belongs here. The UTC clock is the half that must agree
        # with the host. Together, they let you diagnose a time stamp that looks
        # wrong. Each one alone only looks strange. A guest without an adapter
        # never runs w32time. Thus UTC comes from the hypervisor, and a drift
        # here means a problem with the host, not with the VM.
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
Add-Line 'Draugr forge guest: what is on this machine'
Add-Line "generated $($m.generated) by $($m.generator)"
Add-Line ''
Add-Line "MACHINE   $($m.machine.name)  $($m.machine.os)  edition $($m.machine.edition)"
Add-Line "          $($m.machine.cpus) cpus, $($m.machine.ramGb) GB RAM, $($m.machine.diskFreeGb) of $($m.machine.diskTotalGb) GB free"
Add-Line ''
Add-Line 'EGRESS    this VM has no own adapter. All traffic leaves through the proxy'
Add-Line "          proxy       $($m.egress.proxyWinInet)"
Add-Line "          adapters    $($m.egress.adapters -join ', ')"
if (-not $m.egress.defaultRoute) {
    Add-Line "          default route  none"
} elseif ($m.egress.defaultRouteIsFiction) {
    Add-Line "          default route  via $($m.egress.defaultRouteVia), neighbor $($m.egress.defaultRouteNeighbour)"
    Add-Line "                         EXPECTED. That address is the NCSI fiction, not a way out:"
    Add-Line "                         a manually written neighbor with nothing behind it. It exists"
    Add-Line "                         only so that Windows judges this interface online. Egress is"
    Add-Line "                         still only the proxy."
} else {
    Add-Line "          default route  via $($m.egress.defaultRouteVia), neighbor $($m.egress.defaultRouteNeighbour)"
    Add-Line "                         *** NOT the NCSI fiction. This VM possibly has a real way out."
    Add-Line "                         *** Look at that before you trust anything else in this file."
}
Add-Line ''
Add-Line 'SOFTWARE'
if ($m.software.msys2.root) {
    Add-Line "          MSYS2       $($m.software.msys2.packages) packages, $($m.software.msys2.sizeMb) MB, pinned to $($m.software.msys2.pinnedTo -join ', ')"
} else {
    # Without this, the line said "0 packages, 0 MB, pinned to", and stopped
    # there. That looks like a broken script, not like a missing package
    # manager.
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
Add-Line 'SETTINGS  (these exist for the agent, not for a person)'
# An unset registry value shows as an empty column. That looks like "zero", not
# like "never configured", and for most of these, the two have opposite
# meanings.
foreach ($k in $m.settings.Keys) {
    $v = $m.settings[$k]
    if ($null -eq $v -or "$v" -eq '') { $v = '(not set)' }
    Add-Line ("          {0,-15} {1}" -f $k, $v)
}
Add-Line ''
Add-Line 'NOT HERE, ON PURPOSE: the Epic account, the engine versions, and Visual Studio are'
Add-Line 'layers on top of this base, not part of it. The full package list is in manifest.json.'
Add-Line ''
Add-Line 'To refresh, run guest\write-manifest.ps1 again. It reads the machine. It does not'
Add-Line 'trust that an installer told the truth.'

[IO.File]::WriteAllText((Join-Path $Dir 'MANIFEST.txt'), $t.ToString())
Write-Host "manifest written: $Dir\manifest.json and $Dir\MANIFEST.txt"
if ($Print) { Write-Host ''; Write-Host $t.ToString() }
