# install-guest-base.ps1 - the Windows settings a forge guest needs before anything else.
#
# Run this IN THE GUEST, elevated, once. An ssh session is already elevated (sshd hands
# out a full token), so driving it over ssh is enough. It is idempotent: every step checks
# the current state first, so re-running it changes nothing and still prints the state.
#
# This is the layer under the toolchain: with none of it, MSYS2 cannot download, Visual
# Studio's revocation check fails, the vault cannot be mounted, and Windows reboots in the
# middle of a build. Everything here is one of the base image's decided contents
# (Draugr docs/FORGE.md, "What the base image must contain").
#
#   1. Proxy, three ways.       Windows client stacks do not share one setting.
#   2. Windows Update off.      It patches through the gateway and reboots on its own.
#   3. LanmanServer disabled.   Frees guest 445 so the vault tunnel can own it.
#   4. A loopback adapter.      Without ANY adapter, CryptoAPI will not even attempt a
#                               revocation fetch, and strict clients fail.
#   5. sshd key-only.           Off by default: see -HardenSshd.
#   6. One visible TEMP.        Two obscure ones by default, neither ever emptied.
#   7. Explorer tells the truth. Hidden files, system files and EXTENSIONS shown.
#   8. A still, quiet desktop.  Animations, transparency, toasts, the screen saver.
#   9. Long paths.              Unreal trees are deep enough to hit MAX_PATH.
#  10. No crash dialogs, no indexer.
#
# WHY 6-10 EXIST AT ALL. Everything above line 5 is about the VM reaching the world;
# everything below is about a *machine an agent drives* rather than one a person watches.
# An animation is a half-drawn screenshot. A toast covers the button being clicked. A
# 400 ms menu delay is a race. A modal crash dialog stops an unattended run dead, and the
# only symptom is a timeout. Hidden file extensions mean a screenshot cannot distinguish
# `setup.txt` from `setup.exe`. None of this is tidiness; each one removes a way for the
# agent to be wrong about what it is looking at.
#
# Measured in this guest, before any of it was applied: extensions hidden,
# hidden files hidden, a screen saver ACTIVE, MenuShowDelay 400 ms, long paths off, search
# indexing running over what becomes a 100 GB tree, and codepage 1252.
#
# HKCU values are written from an ssh session in session 0, but sshd runs them as the same
# user, so they land in the same hive the desktop session reads. Explorer caches some of
# them: those take effect at the next logon, which a base image gets anyway.
#
#   powershell -ExecutionPolicy Bypass -File .\install-guest-base.ps1
#   powershell -ExecutionPolicy Bypass -File .\install-guest-base.ps1 -VerifyOnly
#   powershell -ExecutionPolicy Bypass -File .\install-guest-base.ps1 -HardenSshd -Utf8
param(
    [string]$Proxy = '127.0.0.1:3128',
    [string]$TempDir = 'C:\temp',      # '' leaves TEMP where Windows put it
    [int]$CursorSize = 48,             # 0 leaves the cursor alone; 32 is the default
    # THE GUEST'S CLOCK IS RIGHT AND ITS TIMEZONE IS NOT. Measured on a fresh
    # unattended install: guest UTC matched the host's to the second (the hypervisor keeps it
    # so, and w32time is Stopped/Manual because an adapterless guest could never sync), but
    # the zone was Pacific Standard Time - Windows' default when setup is not told otherwise.
    # Every LOCAL timestamp the agent then writes is hours away from the wall clock of the
    # person reading it: build logs, git commit times, the manifest's own header.
    #
    # It belongs in the base because the base is what every layer INHERITS. Not because a
    # frozen parent makes it permanent - it does not: the guest sees one writable C: and any
    # child can set its own timezone whenever it likes. The argument is that the default
    # should be right once, here, rather than wrong in every child until someone notices.
    # lib/forge/provision.ps1 passes the HOST's zone,
    # which is what someone looking at the VNC window expects to see. '' leaves it alone, and
    # 'UTC' is the defensible other answer if you would rather every layer and log agree
    # regardless of who is watching.
    [string]$TimeZone = '',
    # The NCSI fiction's address and MAC, used ONLY to tell a deliberate dead-end route
    # apart from a real way out. Same defaults as guest/write-manifest.ps1 and
    # guest/install-windows-online.ps1; change them in all three or in none.
    [string]$NcsiGateway = '192.168.63.1',
    [string]$NcsiGatewayMac = '02-00-00-00-63-01',
    [switch]$SkipProxy,
    [switch]$SkipWindowsUpdate,
    [switch]$SkipLanmanServer,
    [switch]$SkipLoopback,
    [switch]$SkipExplorer,
    [switch]$SkipQuietDesktop,
    [switch]$SkipLongPaths,
    # Opt-out, because section 9b is the one setting here that RELAXES something rather
    # than tidying it: it lets an unelevated process use a network connection an elevated
    # one established. Read 9b before passing this - without it the vault is unusable
    # from Explorer, which is how a person looks at a mounted drive.
    [switch]$SkipLinkedConnections,
    [switch]$SkipIndexing,
    [switch]$HardenSshd,
    [switch]$Utf8,                     # opt-in: still labelled beta by Microsoft
    [switch]$VerifyOnly
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$id = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'this needs an elevated session (an ssh session already is one)'
}

$changed = @()

# Named once: section 9b writes it and the verification block below reads it back.
$linkedPolicy = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'

function Set-RegValue($path, $name, $value, $type) {
    if (-not (Test-Path $path)) { New-Item -Path $path -Force | Out-Null }
    $cur = (Get-ItemProperty -Path $path -Name $name -EA SilentlyContinue).$name
    if ($cur -eq $value) { return $false }
    New-ItemProperty -Path $path -Name $name -Value $value -PropertyType $type -Force | Out-Null
    return $true
}

# --- 1. the proxy, three times over -------------------------------------------------
# Measured (README, "Which client honours which proxy setting"): curl takes the
# environment, WinHTTP takes only netsh, and .NET/PowerShell take only the per-user
# WinINet setting. Setting one of the three and calling it done is the classic way to get
# a guest where some tools reach the internet and others do not.
if (-not $VerifyOnly -and -not $SkipProxy) {
    $inet = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
    if (Set-RegValue $inet 'ProxyServer' $Proxy 'String')     { $changed += 'WinINet server' }
    if (Set-RegValue $inet 'ProxyEnable' 1 'DWord')           { $changed += 'WinINet enable' }
    if (Set-RegValue $inet 'ProxyOverride' '<local>' 'String'){ $changed += 'WinINet bypass' }

    # -join first. `netsh winhttp show proxy` returns several lines, and `-notmatch` on an
    # ARRAY filters it rather than answering a question: the result is every line that does
    # not match, which is never empty, so the test was always true and WinHTTP was re-set
    # on every run. One string, one boolean.
    if (((netsh winhttp show proxy) -join ' ') -notmatch [regex]::Escape($Proxy)) {
        netsh winhttp set proxy proxy-server="$Proxy" bypass-list="<local>" | Out-Null
        $changed += 'WinHTTP'
    }
    foreach ($v in 'HTTP_PROXY', 'HTTPS_PROXY') {
        if ([Environment]::GetEnvironmentVariable($v, 'Machine') -ne "http://$Proxy") {
            [Environment]::SetEnvironmentVariable($v, "http://$Proxy", 'Machine')
            $changed += $v
        }
    }
}

# --- 2. Windows Update decides nothing for itself -----------------------------------
# That updates work at all through the gateway is a good property. Updates choosing their
# own moment to reboot is not, and a build is hours long.
if (-not $VerifyOnly -and -not $SkipWindowsUpdate) {
    $au = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
    if (Set-RegValue $au 'NoAutoUpdate' 1 'DWord')                  { $changed += 'NoAutoUpdate' }
    if (Set-RegValue $au 'NoAutoRebootWithLoggedOnUsers' 1 'DWord') { $changed += 'NoAutoReboot' }
    $wu = Get-Service wuauserv -EA SilentlyContinue
    if ($wu -and $wu.Status -eq 'Running') { Stop-Service wuauserv -Force; $changed += 'wuauserv stopped' }
}

# --- 3. LanmanServer out of the way -------------------------------------------------
# The vault arrives over SMB, and the Windows SMB *client* will dial nothing but port 445,
# so the tunnel has to own 445 in the guest. The guest's own file server is what would
# hold it. Nothing here shares files outwards, so it has no other job.
if (-not $VerifyOnly -and -not $SkipLanmanServer) {
    $srv = Get-Service LanmanServer -EA SilentlyContinue
    if ($srv) {
        if ($srv.Status -ne 'Stopped') { Stop-Service LanmanServer -Force; $changed += 'LanmanServer stopped' }
        if ((Get-Service LanmanServer).StartType -ne 'Disabled') {
            Set-Service LanmanServer -StartupType Disabled
            $changed += 'LanmanServer disabled'
        }
    }
}

# --- 4. one adapter, with no way out ------------------------------------------------
# Measured: with NO adapter at all, CryptoAPI does not even try - certutil fails every URL
# with ERROR_NOT_CONNECTED and the chain ends CRYPT_E_REVOCATION_OFFLINE, with nothing in
# the gateway log because no request was made. A KM-TEST loopback adapter gets a
# link-local address and NO default route, so Windows reports a network and CryptoAPI
# starts fetching - through the proxy, like everything else. netcfg cannot install it on
# Windows 11 any more (protocols, services and clients only), so this is what devcon does.
$loopbackName = 'Microsoft KM-TEST Loopback Adapter'
if (-not $VerifyOnly -and -not $SkipLoopback) {
    $have = Get-NetAdapter -EA SilentlyContinue | Where-Object { $_.InterfaceDescription -eq $loopbackName }
    if (-not $have) {
        Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices;
public static class DevInst {
  [StructLayout(LayoutKind.Sequential)] public struct SP_DEVINFO_DATA {
    public int cbSize; public Guid ClassGuid; public int DevInst; public IntPtr Reserved; }
  [DllImport("setupapi.dll", SetLastError=true, CharSet=CharSet.Unicode)]
  public static extern IntPtr SetupDiCreateDeviceInfoList(ref Guid ClassGuid, IntPtr hwndParent);
  [DllImport("setupapi.dll", SetLastError=true, CharSet=CharSet.Unicode, EntryPoint="SetupDiCreateDeviceInfoW")]
  public static extern bool SetupDiCreateDeviceInfo(IntPtr set, string name, ref Guid cls, string desc,
    IntPtr hwnd, int flags, ref SP_DEVINFO_DATA data);
  [DllImport("setupapi.dll", SetLastError=true, CharSet=CharSet.Unicode, EntryPoint="SetupDiSetDeviceRegistryPropertyW")]
  public static extern bool SetupDiSetDeviceRegistryProperty(IntPtr set, ref SP_DEVINFO_DATA data,
    int prop, byte[] buf, int len);
  [DllImport("setupapi.dll", SetLastError=true)]
  public static extern bool SetupDiCallClassInstaller(int fn, IntPtr set, ref SP_DEVINFO_DATA data);
  [DllImport("newdev.dll", SetLastError=true, CharSet=CharSet.Unicode, EntryPoint="UpdateDriverForPlugAndPlayDevicesW")]
  public static extern bool UpdateDriverForPlugAndPlayDevices(IntPtr hwnd, string hwid, string inf,
    int flags, out bool reboot);
}
'@
        $cls = [Guid]'4d36e972-e325-11ce-bfc1-08002be10318'   # GUID_DEVCLASS_NET
        $set = [DevInst]::SetupDiCreateDeviceInfoList([ref]$cls, [IntPtr]::Zero)
        $dev = New-Object DevInst+SP_DEVINFO_DATA
        $dev.cbSize = [Runtime.InteropServices.Marshal]::SizeOf([type][DevInst+SP_DEVINFO_DATA])
        [void][DevInst]::SetupDiCreateDeviceInfo($set, 'NET', [ref]$cls, $null, [IntPtr]::Zero, 0x1, [ref]$dev)
        $hwid = [Text.Encoding]::Unicode.GetBytes("*MSLOOP" + [char]0 + [char]0)   # REG_MULTI_SZ
        [void][DevInst]::SetupDiSetDeviceRegistryProperty($set, [ref]$dev, 0x1, $hwid, $hwid.Length)
        [void][DevInst]::SetupDiCallClassInstaller(0x19, $set, [ref]$dev)          # DIF_REGISTERDEVICE
        $reboot = $false
        [void][DevInst]::UpdateDriverForPlugAndPlayDevices([IntPtr]::Zero, '*MSLOOP',
            "$env:windir\inf\netloop.inf", 0x1, [ref]$reboot)
        Start-Sleep -Seconds 3
        $changed += 'loopback adapter'
    }
}

# --- 5. key-only ssh, deliberately opt-in -------------------------------------------
# Restarting sshd from inside an ssh session kills that session, and a half-applied sshd
# restart is how a VM with no other way in becomes unreachable. So the restart is handed
# to a one-shot scheduled task a few seconds out, after this session has gone, and the
# caller re-tests the key afterwards. The VM has no adapter, so password auth is not the
# boundary here anyway - this is a tidying step, not the thing keeping anyone out.
if (-not $VerifyOnly -and $HardenSshd) {
    $cfg = Join-Path $env:ProgramData 'ssh\sshd_config'
    $txt = Get-Content $cfg -Raw
    if ($txt -notmatch '(?m)^\s*PasswordAuthentication\s+no\s*$') {
        Copy-Item $cfg "$cfg.draugr-backup" -Force
        if ($txt -match '(?m)^\s*#?\s*PasswordAuthentication\s+\w+\s*$') {
            $txt = $txt -replace '(?m)^\s*#?\s*PasswordAuthentication\s+\w+\s*$', 'PasswordAuthentication no'
        } else {
            $txt += "`r`nPasswordAuthentication no`r`n"
        }
        [IO.File]::WriteAllText($cfg, $txt, (New-Object Text.UTF8Encoding($false)))
        $when = (Get-Date).AddSeconds(20).ToString('HH:mm')
        schtasks /create /tn 'draugr-sshd-restart' /tr 'powershell -NoProfile -Command "Restart-Service sshd"' `
            /sc once /st $when /ru SYSTEM /rl HIGHEST /f | Out-Null
        $changed += 'sshd key-only (restart scheduled)'
    }
}

# --- 6. one TEMP, where you will actually look at it ---------------------------------
# Windows ships two, both buried: %LOCALAPPDATA%\Temp for the user and C:\Windows\TEMP
# for services. Neither is anywhere you think to empty, which matters here because this
# disk gets flattened into a base image and whatever is in temp goes with it.
if (-not $VerifyOnly -and $TempDir) {
    if (-not (Test-Path $TempDir)) { New-Item -ItemType Directory -Force -Path $TempDir | Out-Null }
    foreach ($scope in 'User', 'Machine') {
        foreach ($v in 'TEMP', 'TMP') {
            if ([Environment]::GetEnvironmentVariable($v, $scope) -ne $TempDir) {
                [Environment]::SetEnvironmentVariable($v, $TempDir, $scope)
                $changed += "$v($scope)"
            }
        }
    }
}

# --- 7. Explorer, telling the truth --------------------------------------------------
# HideFileExt is the one that matters to an agent: with extensions hidden, a screenshot
# of a folder cannot tell an installer from a text file, and neither can a human checking
# the agent's work. Hidden=1 shows hidden files; 2 means do not.
$adv = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
if (-not $VerifyOnly -and -not $SkipExplorer) {
    if (Set-RegValue $adv 'Hidden' 1 'DWord')          { $changed += 'show hidden' }
    if (Set-RegValue $adv 'ShowSuperHidden' 1 'DWord') { $changed += 'show system files' }
    if (Set-RegValue $adv 'HideFileExt' 0 'DWord')     { $changed += 'show extensions' }
    if ($CursorSize -gt 0) {
        # Bigger pointer: for a human over VNC, and so a vision pass can find the cursor
        # in a screenshot at all.
        if (Set-RegValue 'HKCU:\Control Panel\Cursors' 'CursorBaseSize' $CursorSize 'DWord') {
            $changed += "cursor $CursorSize"
        }
    }
}

# --- 8. a still, quiet desktop -------------------------------------------------------
if (-not $VerifyOnly -and -not $SkipQuietDesktop) {
    $desk = 'HKCU:\Control Panel\Desktop'
    # 2 = "adjust for best performance": every animation and fade off in one value.
    if (Set-RegValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects' `
                     'VisualFXSetting' 2 'DWord')                    { $changed += 'visual effects' }
    if (Set-RegValue $desk 'MenuShowDelay' '0' 'String')             { $changed += 'menu delay' }
    if (Set-RegValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' `
                     'EnableTransparency' 0 'DWord')                 { $changed += 'transparency' }
    # A screen saver on a machine an agent drives turns a screenshot into a puzzle.
    if (Set-RegValue $desk 'ScreenSaveActive' '0' 'String')          { $changed += 'screen saver' }
    if (Set-RegValue $desk 'ScreenSaverIsSecure' '0' 'String')       { $changed += 'saver lock' }
    # A toast appears OVER what is being clicked, and takes focus with it.
    if (Set-RegValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\PushNotifications' `
                     'ToastEnabled' 0 'DWord')                       { $changed += 'toasts' }
    # Snap Assist's suggestion overlay intercepts the next click after a window moves.
    if (Set-RegValue $adv 'SnapAssist' 0 'DWord')                    { $changed += 'snap assist' }
    if (Set-RegValue $adv 'WindowArrangementActive' '0' 'String')    { $changed += 'window arranging' }
    # "Let's finish setting up your device" and friends: they pop up and take focus.
    $cdm = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
    foreach ($n in 'SubscribedContent-310093Enabled', 'SubscribedContent-338389Enabled',
                   'SubscribedContent-338388Enabled', 'SystemPaneSuggestionsEnabled') {
        if (Set-RegValue $cdm $n 0 'DWord') { $changed += $n }
    }
    if (Set-RegValue 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer' `
                     'NoAutoRebootWithLoggedOnUsers' 1 'DWord') { $changed += 'no auto-reboot' }
}

# --- 8b. the timezone, so local times mean what they look like -----------------------
# Set-TimeZone needs elevation, which this session has (see the header: ssh in is a full
# token). It does NOT touch the clock - UTC is unchanged and stays the hypervisor's - so
# this is a display and arithmetic fix, not a sync.
#
# GATED ON $VerifyOnly like every other apply section here. Set-RegValue does not check it
# itself - the sections do - and a read-only run that changes a setting is a bug this
# codebase has already paid for once.
if (-not $VerifyOnly -and $TimeZone) {
    $tzNow = (Get-TimeZone).Id
    if ($tzNow -ne $TimeZone) {
        # Validate before setting: Set-TimeZone on an unknown id throws, and the message
        # ("The time zone ID was not found") does not tell you what WOULD have been accepted.
        if (Get-TimeZone -ListAvailable | Where-Object { $_.Id -eq $TimeZone }) {
            Set-TimeZone -Id $TimeZone
            $changed += "timezone $TimeZone"
        } else {
            # Said here and not added to $script:soft: that list is initialised further down,
            # AFTER this point, so anything appended here is thrown away. The report's own
            # Show 'timezone' compares what is in force against $TimeZone and files the
            # mismatch itself, which is the right place for it anyway.
            Write-Host "  timezone '$TimeZone' is not a known id - left alone (see Get-TimeZone -ListAvailable)" -ForegroundColor Yellow
        }
    }
}

# --- 9. long paths -------------------------------------------------------------------
# Unreal project and engine trees are deep, and a MAX_PATH failure does not say so: it
# surfaces as a missing file or an unexplained build error much further along.
if (-not $VerifyOnly -and -not $SkipLongPaths) {
    if (Set-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' `
                     'LongPathsEnabled' 1 'DWord') { $changed += 'long paths' }
}

# --- 9b. mapped drives the desktop can actually see ----------------------------------
# A mapped network drive belongs to ONE ACCESS TOKEN. An administrator's logon has two -
# the filtered one Explorer runs under and the elevated one - and by default a drive mapped
# in either is invisible to the other, with nothing anywhere saying so: the drive simply is
# not there. EnableLinkedConnections makes Windows copy the mapping to the linked token.
#
# WHY IT HAS TO BE IN THE BASE. The vault's password file is readable only by SYSTEM and
# Administrators (lib/forge/vault-access.ps1 sets that), so mount-vault.ps1 can only
# be run elevated - and the drive it maps is then invisible to the unelevated Explorer,
# which is how a person looks at a drive, and to the unelevated Epic Games Launcher. The
# alternative is to loosen the ACL on a plaintext password instead, which trades the same
# boundary the other way round AND still leaves elevated installers without V:.
#
# MEASURED on layer-1, after this was missing from the base: with the value set
# and the guest rebooted, mounts made in one token were visible in the other. It needs a
# REBOOT (or at least a new logon) - a base image gets one anyway, and vault-access.ps1
# restarts the guest for its own reasons right before anyone would mount anything.
#
# What it costs, stated plainly: an unelevated process can use a connection established by
# an elevated one. In this guest that boundary is already thin - one account, a local
# administrator, and the agent's own session is elevated - and the credential behind it is
# worth read-only on the vault and write on the scratch share. -SkipLinkedConnections
# leaves it alone if you disagree.
if (-not $VerifyOnly -and -not $SkipLinkedConnections) {
    if (Set-RegValue $linkedPolicy 'EnableLinkedConnections' 1 'DWord') {
        $changed += 'linked connections'
    }
}

# --- 10. no crash dialogs, no indexer ------------------------------------------------
if (-not $VerifyOnly) {
    # WER's default is a MODAL dialog. Unattended, that is a hang with no message.
    # Reports still get written; only the window is suppressed.
    if (Set-RegValue 'HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting' `
                     'DontShowUI' 1 'DWord') { $changed += 'WER dialog' }
    # The Program Compatibility Assistant puts up its own dialog AFTER an installer exits.
    if (Set-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppCompat' `
                     'DisablePCA' 1 'DWord') { $changed += 'PCA dialog' }
}
if (-not $VerifyOnly -and -not $SkipIndexing) {
    # Indexing a 100+ GB engine and asset tree buys nothing when the tools are ripgrep
    # and fd, and costs I/O on the disk the build is using.
    $ws = Get-Service WSearch -EA SilentlyContinue
    if ($ws) {
        if ($ws.Status -ne 'Stopped') { Stop-Service WSearch -Force; $changed += 'indexer stopped' }
        if ((Get-Service WSearch).StartType -ne 'Disabled') {
            Set-Service WSearch -StartupType Disabled; $changed += 'indexer disabled'
        }
    }
}

# --- 11. UTF-8, opt-in ---------------------------------------------------------------
# windows-mcp ships a workaround for UnicodeEncodeError on a cp1252 console; this removes
# the whole class. Microsoft still labels it beta and some legacy programs mis-handle it,
# so it is a switch rather than a default, and it needs a reboot to take effect.
if (-not $VerifyOnly -and $Utf8) {
    $nls = 'HKLM:\SYSTEM\CurrentControlSet\Control\Nls\CodePage'
    foreach ($n in 'ACP', 'OEMCP', 'MACCP') {
        if (Set-RegValue $nls $n '65001' 'String') { $changed += "$n=65001" }
    }
    Write-Host '  UTF-8 set; it takes effect after a reboot' -ForegroundColor Yellow
}

# --- verification: read back what is in force, not what was written ------------------
Write-Host ''
Write-Host '--- guest base ---'
$bad = @()

$inet = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
$p = Get-ItemProperty $inet -EA SilentlyContinue
Write-Host ("  WinINet       {0} (enabled={1}, bypass={2})" -f $p.ProxyServer, $p.ProxyEnable, $p.ProxyOverride)
if ($p.ProxyServer -ne $Proxy -or $p.ProxyEnable -ne 1) { $bad += 'WinINet' }

$wh = (netsh winhttp show proxy) -join ' '
if ($wh -match [regex]::Escape($Proxy)) { Write-Host "  WinHTTP       $Proxy" }
else { Write-Host "  WinHTTP       NOT SET" -ForegroundColor Red; $bad += 'WinHTTP' }

foreach ($v in 'HTTP_PROXY', 'HTTPS_PROXY') {
    $val = [Environment]::GetEnvironmentVariable($v, 'Machine')
    if ($val) { Write-Host ("  {0,-13} {1}" -f $v, $val) }
    else { Write-Host ("  {0,-13} NOT SET" -f $v) -ForegroundColor Red; $bad += $v }
}

$au = Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' -EA SilentlyContinue
if ($au.NoAutoUpdate -eq 1) { Write-Host '  WindowsUpdate off' }
else { Write-Host '  WindowsUpdate STILL AUTOMATIC' -ForegroundColor Yellow }

$srv = Get-Service LanmanServer -EA SilentlyContinue
if ($srv) { Write-Host "  LanmanServer  $($srv.Status)/$((Get-Service LanmanServer).StartType)" }

$ad = Get-NetAdapter -EA SilentlyContinue | Where-Object { $_.InterfaceDescription -eq $loopbackName }
if ($ad) { Write-Host "  loopback      $($ad.Name) ($($ad.Status))" }
else { Write-Host '  loopback      MISSING - revocation checking will fail' -ForegroundColor Red; $bad += 'loopback' }

# A default route would normally mean a way out that the gateway does not control, and
# that is still the check that matters more than the adapter's presence. But it cannot be
# "is there a route" any more: install-windows-online.ps1 WRITES one, on purpose, to a next
# hop that does not exist, because NCSI refuses to call an interface "Internet" without one
# and "IPv4=Internet" is what the identity broker consults. The real question is whether the
# route LEADS anywhere.
#
# The fiction is identifiable and cannot be faked by accident: the next hop is the NCSI
# address AND its neighbour entry is Permanent with the MAC we wrote by hand. Nothing ever
# resolved it, so it never goes Reachable - a real gateway's entry would.
#
# This is deliberately the SAME test write-manifest.ps1 applies. The two must agree:
# MEASURED, a correctly built guest was reported "default route PRESENT" and
# FAILED (1) here while the manifest in the same run called the identical route EXPECTED.
# Contradicting yourself in one run is worse than either verdict, because what it actually
# teaches is to stop reading the red lines.
$route = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -EA SilentlyContinue | Select-Object -First 1
if (-not $route) {
    Write-Host '  default route none, as it must be'
} else {
    $nb = Get-NetNeighbor -IPAddress $route.NextHop -EA SilentlyContinue | Select-Object -First 1
    # -replace strips the separator so 02-00-.. and 02:00:.. compare equal; -eq on strings
    # is case-insensitive in PowerShell, which is what a MAC wants.
    $isFiction = ($route.NextHop -eq $NcsiGateway -and $null -ne $nb -and $nb.State -eq 'Permanent' -and
                  ($nb.LinkLayerAddress -replace '[:-]', '') -eq ($NcsiGatewayMac -replace '[:-]', ''))
    if ($isFiction) {
        Write-Host "  default route via $($route.NextHop) - the NCSI fiction, not a way out"
    } else {
        Write-Host "  default route PRESENT via $($route.NextHop) - the guest has egress the gateway does not see" -ForegroundColor Red
        $bad += 'route'
    }
}

$sshd = Get-Content (Join-Path $env:ProgramData 'ssh\sshd_config') -EA SilentlyContinue
if ($sshd -match '(?m)^\s*PasswordAuthentication\s+no') { Write-Host '  sshd          key-only' }
else { Write-Host '  sshd          password auth still allowed (-HardenSshd to change)' }

# --- the agent-facing half -----------------------------------------------------------
# Get-Reg, not R: `R` is the built-in ALIAS for Invoke-History, and an alias wins over a
# function in PowerShell's command resolution. A helper called R silently becomes a
# different command. It must also always emit exactly one value: emitting nothing shifts
# the caller's arguments by one, and the -f that follows then throws on a missing
# placeholder - which, under SilentlyContinue, deletes the line instead of reporting it.
function Get-Reg([string]$p, [string]$n) {
    $v = (Get-ItemProperty -Path $p -Name $n -EA SilentlyContinue).$n
    if ($null -eq $v -or "$v" -eq '') { return '(not set)' }
    return "$v"
}
function Show([string]$label, [string]$now, [string]$want) {
    if ($now -eq $want) { Write-Host ("  {0,-13} {1}" -f $label, $now) }
    else {
        Write-Host ("  {0,-13} {1}  (wanted {2})" -f $label, $now, $want) -ForegroundColor Yellow
        $script:soft += $label
    }
}
$script:soft = @()
$adv  = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
$desk = 'HKCU:\Control Panel\Desktop'
Show 'TEMP'          "$([Environment]::GetEnvironmentVariable('TEMP','Machine'))" $TempDir
Show 'hidden files'  (Get-Reg $adv 'Hidden') '1'
Show 'extensions'    (Get-Reg $adv 'HideFileExt') '0'
Show 'cursor'        (Get-Reg 'HKCU:\Control Panel\Cursors' 'CursorBaseSize') "$CursorSize"
Show 'animations'    (Get-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects' 'VisualFXSetting') '2'
Show 'menu delay'    (Get-Reg $desk 'MenuShowDelay') '0'
Show 'screen saver'  (Get-Reg $desk 'ScreenSaveActive') '0'
Show 'toasts'        (Get-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\PushNotifications' 'ToastEnabled') '0'
Show 'long paths'    (Get-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' 'LongPathsEnabled') '1'
Show 'linked drives' (Get-Reg $linkedPolicy 'EnableLinkedConnections') '1'
Show 'WER dialog'    (Get-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting' 'DontShowUI') '1'
$ws = Get-Service WSearch -EA SilentlyContinue
Show 'indexer'       $(if ($ws) { "$($ws.Status)/$((Get-Service WSearch).StartType)" } else { 'absent' }) 'Stopped/Disabled'
Show 'codepage'      (Get-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\Nls\CodePage' 'ACP') $(if ($Utf8) { '65001' } else { (Get-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\Nls\CodePage' 'ACP') })
# Both halves, because they fail separately: a wrong ZONE is a cosmetic surprise, a wrong
# UTC is a broken TLS handshake and a build that cannot be dated. The offset is printed so
# the pair can be checked against the host without doing the arithmetic by hand.
Show 'timezone'      ("{0} (UTC{1})" -f (Get-TimeZone).Id, (Get-TimeZone).BaseUtcOffset) `
                     $(if ($TimeZone) { "$TimeZone (UTC$((Get-TimeZone -Id $TimeZone -EA SilentlyContinue).BaseUtcOffset))" } else { ("{0} (UTC{1})" -f (Get-TimeZone).Id, (Get-TimeZone).BaseUtcOffset) })
Show 'clock (UTC)'   ((Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm')) ((Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm'))

Write-Host ''
if ($changed.Count) { Write-Host "changed: $($changed -join ', ')" } else { Write-Host 'nothing to change.' }
# $soft is reported, not failed: several of these are deliberate (codepage without -Utf8)
# or simply not visible yet (Explorer caches its own settings until the next logon).
# $bad is the half the VM cannot work without, and that does fail.
if ($script:soft.Count) { Write-Host "not as wanted (see above): $($script:soft -join ', ')" -ForegroundColor Yellow }
if ($bad.Count) { Write-Host "INCOMPLETE: $($bad -join ', ')" -ForegroundColor Red; exit 1 }
Write-Host 'guest base OK.' -ForegroundColor Green
