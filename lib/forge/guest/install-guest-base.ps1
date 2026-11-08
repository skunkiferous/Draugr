# install-guest-base.ps1: the Windows configuration that a forge guest needs
# first.
#
# Run this IN THE GUEST, elevated, once. An ssh session is already elevated
# (sshd gives a full token), so a run through ssh is enough. It is idempotent.
# Each step tests the current state first. Thus a second run changes nothing,
# and still prints the state.
#
# This is the layer below the toolchain. Without it, MSYS2 cannot download.
# Also, the revocation test of Visual Studio fails, nobody can mount the vault,
# and Windows reboots in the middle of a build. Each item here is a decided part
# of the base image (Draugr docs/FORGE.md, "What the base image must contain").
#
#   1. Proxy, three ways.       The Windows client stacks do not share one value.
#   2. Windows Update off.      It patches through the gateway, and reboots by itself.
#   3. LanmanServer disabled.   Frees guest port 445, so that the vault tunnel can own it.
#   4. A loopback adapter.      Without ANY adapter, CryptoAPI does not even try a
#                               revocation fetch, and strict clients fail.
#   5. sshd key-only.           Off by default. See -HardenSshd.
#   6. One visible TEMP.        By default, two hidden ones, and nothing ever empties them.
#   7. Explorer tells the truth. Shows hidden files, system files, and EXTENSIONS.
#   8. A still, quiet desktop.  Animations, transparency, toasts, the screen saver.
#   9. Long paths.              Unreal trees are deep enough to reach MAX_PATH.
#  10. No crash dialogs, no indexer.
#
# WHY 6 TO 10 EXIST. Items 1 to 5 are about the connection of the VM to the
# world. The items below are about a *machine that an agent drives*, not one
# that a person watches. An animation is a half-drawn screenshot. A toast covers
# the button to click. A menu delay of 400 ms is a race. A modal crash dialog
# stops an unattended run, and the only symptom is a timeout. With hidden file
# extensions, a screenshot cannot show the difference between `setup.txt` and
# `setup.exe`. None of this is tidiness. Each item removes a way for the agent
# to be wrong about what it sees.
#
# A test in this guest, before any of it applied, found: extensions hidden,
# hidden files hidden, a screen saver ACTIVE, MenuShowDelay 400 ms, long paths
# off, search indexing on a tree that becomes 100 GB, and codepage 1252.
#
# An ssh session in session 0 writes the HKCU values, but sshd runs them as the
# same user. Thus they go into the same hive that the desktop session reads.
# Explorer caches some of them. Those apply at the next logon, and a base image
# gets one anyway.
#
#   powershell -ExecutionPolicy Bypass -File .\install-guest-base.ps1
#   powershell -ExecutionPolicy Bypass -File .\install-guest-base.ps1 -VerifyOnly
#   powershell -ExecutionPolicy Bypass -File .\install-guest-base.ps1 -HardenSshd -Utf8
param(
    [string]$Proxy = '127.0.0.1:3128',
    [string]$TempDir = 'C:\temp',      # '' leaves TEMP where Windows put it
    [int]$CursorSize = 48,             # 0 does not touch the cursor. 32 is the default
    # THE CLOCK OF THE GUEST IS CORRECT, AND ITS TIME ZONE IS NOT. A test on a
    # new unattended install showed this. The UTC of the guest was the same as
    # the UTC of the host, to the second. The hypervisor keeps it so. w32time is
    # Stopped/Manual, because a guest with no adapter can never sync. But the
    # zone was Pacific Standard Time. Without another value from setup, Windows
    # uses that default. Each LOCAL time stamp that the agent writes is then
    # hours away from the clock of the person who reads it: build logs, git
    # commit times, the header of the manifest.
    #
    # It belongs in the base, because each layer INHERITS the base. Not because
    # a frozen parent makes it permanent. It does not. The guest sees one
    # writable C:, and each child can set its own time zone at any time. The
    # reason is that the default must be correct once, here, and not wrong in
    # each child until somebody sees it. lib/forge/provision.ps1 gives the zone
    # of the HOST. That is what a person at the VNC window expects to see. ''
    # does not touch it. 'UTC' is the other good answer. With it, each layer and
    # log agree, for all people who watch.
    [string]$TimeZone = '',
    # The address and MAC of the NCSI fiction. ONLY to tell a deliberate
    # dead-end route from a real way out. The same defaults as
    # guest/write-manifest.ps1 and guest/install-windows-online.ps1. Change them
    # in all three, or in none.
    [string]$NcsiGateway = '192.168.63.1',
    [string]$NcsiGatewayMac = '02-00-00-00-63-01',
    [switch]$SkipProxy,
    [switch]$SkipWindowsUpdate,
    [switch]$SkipLanmanServer,
    [switch]$SkipLoopback,
    [switch]$SkipExplorer,
    [switch]$SkipQuietDesktop,
    [switch]$SkipLongPaths,
    # A way to opt out, because section 9b is the one item here that RELAXES
    # something, and does not only tidy. It lets a process that is not elevated
    # use a network connection that an elevated one made. Read 9b before you
    # give this. Without it, Explorer cannot use the vault, and a person looks
    # at a mounted drive with Explorer.
    [switch]$SkipLinkedConnections,
    [switch]$SkipIndexing,
    [switch]$HardenSshd,
    [switch]$Utf8,                     # only on request. Microsoft still calls it beta
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

# Named once. Section 9b writes it, and the test block below reads it.
$linkedPolicy = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'

function Set-RegValue($path, $name, $value, $type) {
    if (-not (Test-Path $path)) { New-Item -Path $path -Force | Out-Null }
    $cur = (Get-ItemProperty -Path $path -Name $name -EA SilentlyContinue).$name
    if ($cur -eq $value) { return $false }
    New-ItemProperty -Path $path -Name $name -Value $value -PropertyType $type -Force | Out-Null
    return $true
}

# --- 1. the proxy, three times -------------------------------------------------------
# A test showed this (README, "Which client honours which proxy setting"). curl
# takes the environment, WinHTTP takes only netsh, and .NET and PowerShell take
# only the WinINet value of the user. If you set only one of the three, some
# tools reach the internet, and others do not.
if (-not $VerifyOnly -and -not $SkipProxy) {
    $inet = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
    if (Set-RegValue $inet 'ProxyServer' $Proxy 'String')     { $changed += 'WinINet server' }
    if (Set-RegValue $inet 'ProxyEnable' 1 'DWord')           { $changed += 'WinINet enable' }
    if (Set-RegValue $inet 'ProxyOverride' '<local>' 'String'){ $changed += 'WinINet bypass' }

    # -join first. `netsh winhttp show proxy` returns several lines. `-notmatch`
    # on an ARRAY filters it, and does not answer a question. The result is each
    # line that does not match, and that is never empty. Thus the test was
    # always true, and the code set WinHTTP again at each run. One string, one
    # boolean.
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

# --- 2. Windows Update decides nothing by itself -------------------------------------
# Updates through the gateway work, and that is good. Updates that choose their
# own time to reboot are not good, and a build takes hours.
if (-not $VerifyOnly -and -not $SkipWindowsUpdate) {
    $au = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
    if (Set-RegValue $au 'NoAutoUpdate' 1 'DWord')                  { $changed += 'NoAutoUpdate' }
    if (Set-RegValue $au 'NoAutoRebootWithLoggedOnUsers' 1 'DWord') { $changed += 'NoAutoReboot' }
    $wu = Get-Service wuauserv -EA SilentlyContinue
    if ($wu -and $wu.Status -eq 'Running') { Stop-Service wuauserv -Force; $changed += 'wuauserv stopped' }
}

# --- 3. LanmanServer out of the way -------------------------------------------------
# The vault arrives through SMB, and the Windows SMB *client* connects only to
# port 445. Thus the tunnel must own 445 in the guest. The own file server of
# the guest holds it otherwise. Nothing here shares files to the outside, so it
# has no other job.
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
# A test showed this. With NO adapter, CryptoAPI does not even try. certutil
# fails each URL with ERROR_NOT_CONNECTED, the chain ends with
# CRYPT_E_REVOCATION_OFFLINE, and the gateway log has nothing, because there was
# no request. A KM-TEST loopback adapter gets a link-local address and NO
# default route. Thus Windows reports a network, and CryptoAPI starts to fetch,
# through the proxy, as all else does. On Windows 11, netcfg cannot install it
# now (only protocols, services, and clients). Thus this code does what devcon
# does.
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

# --- 5. key-only ssh, only on request ----------------------------------------------
# A restart of sshd from inside an ssh session kills that session. A
# half-applied restart of sshd makes a VM with no other way in unreachable. Thus
# a one-shot scheduled task does the restart a few seconds later, after this
# session is gone. After that, the caller tests the key again. The VM has no
# adapter, so password authentication is not the boundary here. This is a tidy
# step, not the protection.
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

# --- 6. one TEMP, where you really look at it ----------------------------------------
# Windows ships two, both hidden deep: %LOCALAPPDATA%\Temp for the user, and
# C:\Windows\TEMP for services. You do not think to empty either one. That is
# important here, because this disk becomes a flattened base image, and the
# contents of temp go with it.
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

# --- 7. Explorer tells the truth -----------------------------------------------------
# HideFileExt is the important one for an agent. With hidden extensions, a
# screenshot of a folder cannot show the difference between an installer and a
# text file. A person who reviews the work of the agent cannot see it either.
# Hidden=1 shows hidden files, and 2 does not.
$adv = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
if (-not $VerifyOnly -and -not $SkipExplorer) {
    if (Set-RegValue $adv 'Hidden' 1 'DWord')          { $changed += 'show hidden' }
    if (Set-RegValue $adv 'ShowSuperHidden' 1 'DWord') { $changed += 'show system files' }
    if (Set-RegValue $adv 'HideFileExt' 0 'DWord')     { $changed += 'show extensions' }
    if ($CursorSize -gt 0) {
        # A larger pointer: for a person through VNC, and so that a vision pass
        # can find the cursor in a screenshot.
        if (Set-RegValue 'HKCU:\Control Panel\Cursors' 'CursorBaseSize' $CursorSize 'DWord') {
            $changed += "cursor $CursorSize"
        }
    }
}

# --- 8. a still, quiet desktop -------------------------------------------------------
if (-not $VerifyOnly -and -not $SkipQuietDesktop) {
    $desk = 'HKCU:\Control Panel\Desktop'
    # 2 = "adjust for best performance": all animations and fades off, in one
    # value.
    if (Set-RegValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects' `
                     'VisualFXSetting' 2 'DWord')                    { $changed += 'visual effects' }
    if (Set-RegValue $desk 'MenuShowDelay' '0' 'String')             { $changed += 'menu delay' }
    if (Set-RegValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' `
                     'EnableTransparency' 0 'DWord')                 { $changed += 'transparency' }
    # A screen saver on a machine that an agent drives makes a screenshot a
    # puzzle.
    if (Set-RegValue $desk 'ScreenSaveActive' '0' 'String')          { $changed += 'screen saver' }
    if (Set-RegValue $desk 'ScreenSaverIsSecure' '0' 'String')       { $changed += 'saver lock' }
    # A toast appears OVER the item that the agent clicks, and takes the focus.
    if (Set-RegValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\PushNotifications' `
                     'ToastEnabled' 0 'DWord')                       { $changed += 'toasts' }
    # The suggestion overlay of Snap Assist catches the next click after a
    # window moves.
    if (Set-RegValue $adv 'SnapAssist' 0 'DWord')                    { $changed += 'snap assist' }
    if (Set-RegValue $adv 'WindowArrangementActive' '0' 'String')    { $changed += 'window arranging' }
    # "Let's finish setting up your device" and similar messages: they appear,
    # and take the focus.
    $cdm = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
    foreach ($n in 'SubscribedContent-310093Enabled', 'SubscribedContent-338389Enabled',
                   'SubscribedContent-338388Enabled', 'SystemPaneSuggestionsEnabled') {
        if (Set-RegValue $cdm $n 0 'DWord') { $changed += $n }
    }
    if (Set-RegValue 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer' `
                     'NoAutoRebootWithLoggedOnUsers' 1 'DWord') { $changed += 'no auto-reboot' }
}

# --- 8b. the time zone, so that local times mean what they show -----------------------
# Set-TimeZone needs elevation, and this session has it (see the header: ssh
# gives a full token). It does NOT touch the clock. UTC does not change, and
# stays with the hypervisor. Thus this fixes the display and the arithmetic, and
# is not a sync.
#
# $VerifyOnly is the gate, as for each other apply section here. Set-RegValue
# does not test it. The sections do. A read-only run that changes a value is a
# bug that this code already had once.
if (-not $VerifyOnly -and $TimeZone) {
    $tzNow = (Get-TimeZone).Id
    if ($tzNow -ne $TimeZone) {
        # Make sure that the id is valid before the set. Set-TimeZone throws on
        # an unknown id, and the message ("The time zone ID was not found") does
        # not tell you which values it accepts.
        if (Get-TimeZone -ListAvailable | Where-Object { $_.Id -eq $TimeZone }) {
            Set-TimeZone -Id $TimeZone
            $changed += "timezone $TimeZone"
        } else {
            # Said here, and not added to $script:soft. The code sets up that
            # list below, AFTER this point, so an append here is lost. The Show
            # 'timezone' of the report compares the value in force with
            # $TimeZone, and records the difference itself. That is the correct
            # place.
            Write-Host "  timezone '$TimeZone' is not a known id. Not changed (see Get-TimeZone -ListAvailable)" -ForegroundColor Yellow
        }
    }
}

# --- 9. long paths -------------------------------------------------------------------
# Unreal project and engine trees are deep, and a MAX_PATH failure does not say
# so. It shows as a missing file, or as a strange build error, much later.
if (-not $VerifyOnly -and -not $SkipLongPaths) {
    if (Set-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' `
                     'LongPathsEnabled' 1 'DWord') { $changed += 'long paths' }
}

# --- 9b. mapped drives that the desktop can see -------------------------------------
# A mapped network drive belongs to ONE ACCESS TOKEN. The logon of an
# administrator has two: the filtered one of Explorer, and the elevated one. By
# default, a drive mapped in one is not visible in the other, and nothing says
# so. The drive is not there. EnableLinkedConnections makes Windows copy the
# mapping to the linked token.
#
# WHY IT MUST BE IN THE BASE. Only SYSTEM and Administrators can read the
# password file of the vault (lib/forge/vault-access.ps1 sets that). Thus
# mount-vault.ps1 can only run elevated. Then Explorer, which is not elevated,
# cannot see the drive, and a person looks at a drive with Explorer. The Epic
# Games Launcher, also not elevated, cannot see it either. The alternative is a
# weaker ACL on a plaintext password. That moves the same boundary in the other
# direction, AND still leaves elevated installers without V:.
#
# A TEST on layer-1 showed this, after it was missing from the base. With the
# value set and the guest rebooted, mounts in one token were visible in the
# other. It needs a REBOOT (or at least a new logon). A base image gets one
# anyway, and vault-access.ps1 restarts the guest for its own reasons, directly
# before somebody mounts something.
#
# The cost, said clearly: a process that is not elevated can use a connection
# that an elevated one made. In this guest, that boundary is already thin: one
# account, a local administrator, and the session of the agent is elevated. The
# credential behind it gives read-only on the vault and write on the scratch
# share. If you disagree, -SkipLinkedConnections does not touch it.
if (-not $VerifyOnly -and -not $SkipLinkedConnections) {
    if (Set-RegValue $linkedPolicy 'EnableLinkedConnections' 1 'DWord') {
        $changed += 'linked connections'
    }
}

# --- 10. no crash dialogs, no indexer ------------------------------------------------
if (-not $VerifyOnly) {
    # The default of WER is a MODAL dialog. Unattended, that is a hang with no
    # message. WER still writes reports. Only the window is hidden.
    if (Set-RegValue 'HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting' `
                     'DontShowUI' 1 'DWord') { $changed += 'WER dialog' }
    # The Program Compatibility Assistant shows its own dialog AFTER an
    # installer exits.
    if (Set-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppCompat' `
                     'DisablePCA' 1 'DWord') { $changed += 'PCA dialog' }
}
if (-not $VerifyOnly -and -not $SkipIndexing) {
    # The tools are ripgrep and fd. Thus an index of an engine and asset tree of
    # 100+ GB gives nothing. It costs I/O on the disk of the build.
    $ws = Get-Service WSearch -EA SilentlyContinue
    if ($ws) {
        if ($ws.Status -ne 'Stopped') { Stop-Service WSearch -Force; $changed += 'indexer stopped' }
        if ((Get-Service WSearch).StartType -ne 'Disabled') {
            Set-Service WSearch -StartupType Disabled; $changed += 'indexer disabled'
        }
    }
}

# --- 11. UTF-8, only on request -------------------------------------------------------
# windows-mcp ships a workaround for UnicodeEncodeError on a cp1252 console.
# This removes the whole class of errors. Microsoft still calls it beta, and
# some old programs handle it wrongly. Thus it is a switch, not a default, and
# it needs a reboot to apply.
if (-not $VerifyOnly -and $Utf8) {
    $nls = 'HKLM:\SYSTEM\CurrentControlSet\Control\Nls\CodePage'
    foreach ($n in 'ACP', 'OEMCP', 'MACCP') {
        if (Set-RegValue $nls $n '65001' 'String') { $changed += "$n=65001" }
    }
    Write-Host '  UTF-8 set. It applies after a reboot' -ForegroundColor Yellow
}

# --- test: read what is in force, not what was written ------------------------------
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
else { Write-Host '  loopback      MISSING. Revocation tests fail' -ForegroundColor Red; $bad += 'loopback' }

# A default route usually means a way out that the gateway does not control.
# That is still a more important test than the presence of the adapter. But it
# can no longer be "is there a route?". install-windows-online.ps1 WRITES one,
# on purpose, to a next hop that does not exist. Without one, NCSI refuses to
# call an interface "Internet", and the identity broker reads "IPv4=Internet".
# The real question is whether the route GOES somewhere.
#
# You can identify the fiction, and nothing can fake it by accident. The next
# hop is the NCSI address, AND its neighbor entry is Permanent, with the MAC
# that we wrote. Nothing ever resolved it, so it never becomes Reachable. The
# entry of a real gateway does.
#
# This is the SAME test as in write-manifest.ps1, on purpose. The two must
# agree. A TEST SHOWED THIS: a correctly built guest got "default route PRESENT"
# and FAILED (1) here, while the manifest in the same run called the same route
# EXPECTED. A contradiction in one run is worse than either result, because it
# teaches people to stop reading the red lines.
$route = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -EA SilentlyContinue | Select-Object -First 1
if (-not $route) {
    Write-Host '  default route none, as it must be'
} else {
    $nb = Get-NetNeighbor -IPAddress $route.NextHop -EA SilentlyContinue | Select-Object -First 1
    # -replace removes the separator, so that 02-00-.. and 02:00:.. are equal.
    # In PowerShell, -eq on strings ignores case, and a MAC needs that.
    $isFiction = ($route.NextHop -eq $NcsiGateway -and $null -ne $nb -and $nb.State -eq 'Permanent' -and
                  ($nb.LinkLayerAddress -replace '[:-]', '') -eq ($NcsiGatewayMac -replace '[:-]', ''))
    if ($isFiction) {
        Write-Host "  default route via $($route.NextHop): the NCSI fiction, not a way out"
    } else {
        Write-Host "  default route PRESENT via $($route.NextHop). The guest has egress that the gateway does not see" -ForegroundColor Red
        $bad += 'route'
    }
}

$sshd = Get-Content (Join-Path $env:ProgramData 'ssh\sshd_config') -EA SilentlyContinue
if ($sshd -match '(?m)^\s*PasswordAuthentication\s+no') { Write-Host '  sshd          key-only' }
else { Write-Host '  sshd          password auth still allowed (-HardenSshd to change)' }

# --- the half for the agent ----------------------------------------------------------
# Get-Reg, not R. `R` is the built-in ALIAS for Invoke-History, and in the
# command resolution of PowerShell, an alias wins over a function. A helper
# called R silently becomes a different command. It must also always give
# exactly one value. With no value, the arguments of the caller move by one, and
# the -f after it throws on a missing placeholder. Under SilentlyContinue, that
# deletes the line, and does not report it.
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
# Both halves, because they fail separately. A wrong ZONE is a surprise for the
# eye. A wrong UTC is a broken TLS handshake, and a build with no valid date.
# The code prints the offset, so that you can compare the pair with the host
# without arithmetic.
Show 'timezone'      ("{0} (UTC{1})" -f (Get-TimeZone).Id, (Get-TimeZone).BaseUtcOffset) `
                     $(if ($TimeZone) { "$TimeZone (UTC$((Get-TimeZone -Id $TimeZone -EA SilentlyContinue).BaseUtcOffset))" } else { ("{0} (UTC{1})" -f (Get-TimeZone).Id, (Get-TimeZone).BaseUtcOffset) })
Show 'clock (UTC)'   ((Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm')) ((Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm'))

Write-Host ''
if ($changed.Count) { Write-Host "changed: $($changed -join ', ')" } else { Write-Host 'nothing to change.' }
# The code reports $soft, and does not fail on it. Some of these are on purpose
# (codepage without -Utf8), or not visible yet (Explorer caches its own
# configuration until the next logon). $bad is the half that the VM needs to
# work, and that fails.
if ($script:soft.Count) { Write-Host "not as wanted (see above): $($script:soft -join ', ')" -ForegroundColor Yellow }
if ($bad.Count) { Write-Host "INCOMPLETE: $($bad -join ', ')" -ForegroundColor Red; exit 1 }
Write-Host 'guest base OK.' -ForegroundColor Green
