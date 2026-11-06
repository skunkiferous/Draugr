# vault-access.ps1 - give the forge VM what it needs to reach the vault.
#
# ==> RUN ON THE WINDOWS HOST. Called by lib/forge/provision.ps1's vault phase. <==
#
# Adopted from a hand-written predecessor. No install-
# prefix for the reason lib/forge/screen-access.ps1 gives: here that prefix means "runs in
# the guest", and this runs here and reaches in.
#
# Once per guest. It does three things over the admin SSH channel:
#
#   1. copies the share password to %ProgramData%\draugr-vault\smb.pass in the
#      guest, locked to SYSTEM and Administrators. The VM holds it, so it is
#      worth exactly one thing: reading the vault and writing the scratch share.
#   2. copies guest\mount-vault.ps1
#   3. disables the guest's own LanmanServer and reboots it, because the Windows
#      SMB client only ever dials port 445 and the guest's own file server holds
#      it. srv2/srvnet keep :::445 from the kernel until a restart, so the reboot
#      is not optional (measured). A VM with no network adapter serves
#      SMB to nobody, so nothing is lost.
#
# The password is made once on the host:
#   $b = New-Object byte[] 18
#   [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($b)
#   [IO.File]::WriteAllText("$env:USERPROFILE\.ssh\draugr_vault_smb.pass",
#                           ([Convert]::ToBase64String($b) -replace '[/+=]',''))
# The gateway's post-up hook sets that same password on the share at every
# recreate, which is what keeps this copy valid across a rebuild.
#
# The gateway's post-up hook is Draugr's now: dr-forge gateway generates it, and it sets
# that same password on the share at every recreate. An empty vault directory means it
# serves no share at all, which is why provision.ps1 checks port 18445 before calling this
# - installing a credential and rebooting the guest for a share nobody serves is a reboot
# spent on nothing (docs/FORGE.md, "2b's own five decisions").
#
#   powershell -ExecutionPolicy Bypass -File .\lib\forge\vault-access.ps1 -Vm UE5-Test -User <guest user> -AdminKey <path>
param([Parameter(Mandatory)][string]$Vm,
      [Parameter(Mandatory)][string]$User,
      [Parameter(Mandatory)][string]$AdminKey,
      # Known already by provision.ps1, which resolved it from the daemon. Omitted, the
      # vms.cfg reader below answers instead. See screen-access.ps1's -SshPort.
      [int]$SshPort = 0,
      [string]$PassFile = "$env:USERPROFILE\.ssh\draugr_vault_smb.pass",
      [switch]$SkipReboot)

$ErrorActionPreference = 'Stop'

foreach ($f in $PassFile, $AdminKey) {
    if (-not (Test-Path $f)) { throw "missing: $f" }
}

# NOT lib/forge/vmscfg.ps1's parser, deliberately. That file is the WRITER's - its Read-Cfg
# exits 21 through layer.ps1's own Fail, so dot-sourcing it here would import another
# command's exit codes into this one. This reads one integer and never writes, which is the
# half of the format that has no hazards in it.
#
# Any header resets the accumulator, not just [VM]: keys from a [Settings] block that
# followed a VM would otherwise merge into that VM's entry, and the first VM in the file
# would answer for a name further down.
function Get-SshPort([string]$Name) {
    $vm = $null
    foreach ($line in Get-Content "$env:ProgramData\AppSandbox\vms.cfg") {
        if ($line -match '^\s*\[(.+)\]\s*$') {
            $vm = if ($Matches[1] -eq 'VM') { @{} } else { $null }
        } elseif ($null -ne $vm -and $line -match '^(\w+)=(.*)$') {
            $vm[$Matches[1]] = $Matches[2].Trim()
            if ($vm.Name -eq $Name -and $vm.SshPort) { return [int]$vm.SshPort }
        }
    }
}

$port = if ($SshPort) { $SshPort } else { Get-SshPort $Vm }
if (-not $port) { throw "no SshPort for VM '$Vm' in vms.cfg" }

# HostKeyAlias: the key belongs to the VM, not to a port several guests take turns on.
$opts = @('-o', 'StrictHostKeyChecking=accept-new', '-o', "HostKeyAlias=draugr-$Vm",
          '-o', 'BatchMode=yes')
$dest = 'C:/ProgramData/draugr-vault'

& ssh.exe -i $AdminKey -p $port @opts "$User@127.0.0.1" "cmd /c mkdir `"$($dest -replace '/','\')`" 2>nul & exit 0"
& scp.exe -i $AdminKey -P $port @opts $PassFile "${User}@127.0.0.1:$dest/smb.pass"
& scp.exe -i $AdminKey -P $port @opts (Join-Path $PSScriptRoot 'guest\mount-vault.ps1') `
    "${User}@127.0.0.1:$dest/mount-vault.ps1"

& ssh.exe -i $AdminKey -p $port @opts "$User@127.0.0.1" `
    "powershell -NoProfile -Command `"icacls $dest/smb.pass /inheritance:r /grant '*S-1-5-32-544:F' /grant '*S-1-5-18:F'`""

& ssh.exe -i $AdminKey -p $port @opts "$User@127.0.0.1" `
    "powershell -NoProfile -Command `"Stop-Service LanmanServer -Force; Set-Service LanmanServer -StartupType Disabled`""

# ASKED BEFORE THE REBOOT BELOW, and that ordering is the defect this had. This script's own
# restart is what ACTIVATES EnableLinkedConnections, so the note about it belongs beside the
# restart - but the QUESTION has to reach a guest that is still up. It was put seven lines
# below `shutdown /r /t 0`, came back empty, and the script then told a reader that a guest
# with the value set to 1 did not have it, and gave them a command to go and set it.
# MEASURED: the identical command, same guest, while it is up, returns 1 - and so
# does an -EncodedCommand form, so the command's shape was never the problem. docs/FORGE.md.
#
# THREE ANSWERS, NOT TWO. '' means the question could not be put, which is a different
# statement from "the value is not set"; reporting the first as the second is what sent a
# reader off to fix a setting that was already correct. A check that cannot pass costs what
# a check that cannot fail costs, in the other direction.
#
# Guarded, because 2>&1 with Stop in force makes any ssh complaint terminating.
$elcQuery = "powershell -NoProfile -Command `"(Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -Name EnableLinkedConnections -ErrorAction SilentlyContinue).EnableLinkedConnections`""
$elc = ''
$eapWas = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
    $elc = (& ssh.exe -i $AdminKey -p $port @opts "$User@127.0.0.1" $elcQuery 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) { $elc = '' }
} catch { $elc = '' } finally { $ErrorActionPreference = $eapWas }

Write-Host ""
if ($SkipReboot) {
    Write-Host "LanmanServer disabled. It still holds 445 until the guest restarts."
} else {
    Write-Host "Restarting the guest so srv2/srvnet release port 445..."
    # Guarded for the same reason: ssh writes to stderr whenever the far end goes away, and
    # going away is exactly what this command asks the far end to do.
    $eapWas = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { & ssh.exe -i $AdminKey -p $port @opts "$User@127.0.0.1" "shutdown /r /t 0" 2>&1 | Out-Null }
    finally { $ErrorActionPreference = $eapWas }
    Write-Host "  (the tunnel reconnects by itself once sshd answers again)"
    Write-Host "  this restart is also what activates EnableLinkedConnections"
}

Write-Host ""
Write-Host "Then, ON THE GUEST'S DESKTOP (not over ssh - a mapped drive belongs to one logon):"
Write-Host "  powershell -ExecutionPolicy Bypass -File $($dest -replace '/','\')\mount-vault.ps1"
if (-not $elc) {
    Write-Host ""
    Write-Host "  NOTE: EnableLinkedConnections could not be read from the guest, so whether" -ForegroundColor Yellow
    Write-Host "  the mapped drive will be visible to Explorer is UNKNOWN - not absent." -ForegroundColor Yellow
    Write-Host "  install-guest-base.ps1 section 9b sets it, so a guest this project built has" -ForegroundColor Yellow
    Write-Host "  it. If the drive does not appear, ask the guest directly:" -ForegroundColor Yellow
    Write-Host "    Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' ``" -ForegroundColor Yellow
    Write-Host "      -Name EnableLinkedConnections" -ForegroundColor Yellow
} elseif ($elc -ne '1') {
    Write-Host ""
    Write-Host "  WARNING: EnableLinkedConnections is '$elc' in this guest, not 1." -ForegroundColor Yellow
    Write-Host "  The password file is readable only by Administrators, so mount-vault must run" -ForegroundColor Yellow
    Write-Host "  elevated - and the drive it maps will then be invisible to Explorer. Set it in" -ForegroundColor Yellow
    Write-Host "  the guest and reboot; install-guest-base.ps1 section 9b is what does it for a" -ForegroundColor Yellow
    Write-Host "  guest built by this project:" -ForegroundColor Yellow
    Write-Host "    New-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' ``" -ForegroundColor Yellow
    Write-Host "      -Name EnableLinkedConnections -PropertyType DWord -Value 1 -Force" -ForegroundColor Yellow
}
