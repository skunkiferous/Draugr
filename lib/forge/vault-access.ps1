# vault-access.ps1: give the forge VM what it needs to reach the vault.
#
# ==> RUNS ON THE WINDOWS HOST. The vault phase of lib/forge/provision.ps1 calls it. <==
#
# It comes from a hand-written script. It has no install- prefix, for the reason
# in lib/forge/screen-access.ps1. That prefix means "runs in the guest", and
# this runs here and reaches in.
#
# Once for each guest. It does three things over the admin SSH channel:
#
#   1. copies the share password to %ProgramData%\draugr-vault\smb.pass in the
#      guest, locked to SYSTEM and Administrators. The VM holds it, so it gives
#      only one thing: a read of the vault and a write to the scratch share.
#   2. copies guest\mount-vault.ps1
#   3. disables the LanmanServer of the guest, and reboots it. The Windows SMB
#      client connects only to port 445, and the file server of the guest holds
#      it. srv2/srvnet keep :::445 from the kernel until a restart, so the reboot
#      is necessary (a test showed this). A VM with no network adapter serves SMB
#      to nobody, so nothing is lost.
#
# The password is made once on the host:
#   $b = New-Object byte[] 18
#   [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($b)
#   [IO.File]::WriteAllText("$env:USERPROFILE\.ssh\draugr_vault_smb.pass",
#                           ([Convert]::ToBase64String($b) -replace '[/+=]',''))
# The post-up hook of the gateway now belongs to Draugr. dr-forge gateway
# generates it. At each recreate, it puts the same password on the share. Thus
# this copy stays correct after a rebuild. With an empty vault directory, it
# serves no share. That is why provision.ps1 tests port 18445 before it calls
# this. A credential and a reboot for a share that nobody serves are a waste
# (docs/FORGE.md, "2b's own five decisions").
#
#   powershell -ExecutionPolicy Bypass -File .\lib\forge\vault-access.ps1 -Vm UE5-Test -User <guest user> -AdminKey <path>
param([Parameter(Mandatory)][string]$Vm,
      [Parameter(Mandatory)][string]$User,
      [Parameter(Mandatory)][string]$AdminKey,
      # provision.ps1 already knows it from the daemon. Without it, the vms.cfg
      # reader below answers. See -SshPort in screen-access.ps1.
      [int]$SshPort = 0,
      [string]$PassFile = "$env:USERPROFILE\.ssh\draugr_vault_smb.pass",
      [switch]$SkipReboot)

$ErrorActionPreference = 'Stop'

foreach ($f in $PassFile, $AdminKey) {
    if (-not (Test-Path $f)) { throw "missing: $f" }
}

# NOT the parser of lib/forge/vmscfg.ps1, on purpose. That file belongs to the
# WRITER. Its Read-Cfg exits 21 through the Fail of layer.ps1. Thus a dot-source
# here brings the exit codes of another command into this one. This reads one
# integer and never writes. That half of the format has no hazards.
#
# Each header resets the accumulator, not only [VM]. If not, keys from a
# [Settings] block after a VM go into the entry of that VM. Then the first VM in
# the file answers for a name further down.
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

# HostKeyAlias: the key belongs to the VM, not to a port that guests use in
# turn.
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

# ASKED BEFORE THE REBOOT BELOW. The wrong order was the defect of this script.
# The restart of this script ACTIVATES EnableLinkedConnections, so the note
# about it belongs beside the restart. But the QUESTION must reach a guest that
# still runs. It was seven lines below `shutdown /r /t 0`, and came back empty.
# Then the script told a reader that a guest with the value 1 did not have it,
# and gave a command to set it. A TEST SHOWED that the same command, on the same
# guest, while it runs, returns 1. An -EncodedCommand form does too, so the
# shape of the command was never the problem. docs/FORGE.md.
#
# THREE ANSWERS, NOT TWO. '' means that the question did not reach the guest.
# That is different from "the value is not set". A report of the first as the
# second made a reader fix a value that was already correct. A test that cannot
# pass is as bad as a test that cannot fail.
#
# Guarded, because 2>&1 with Stop makes each ssh complaint a terminating error.
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
    # Guarded for the same reason. ssh writes to stderr each time the far end
    # goes away, and this command tells the far end to go away.
    $eapWas = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { & ssh.exe -i $AdminKey -p $port @opts "$User@127.0.0.1" "shutdown /r /t 0" 2>&1 | Out-Null }
    finally { $ErrorActionPreference = $eapWas }
    Write-Host "  (the tunnel reconnects by itself once sshd answers again)"
    Write-Host "  this restart also activates EnableLinkedConnections"
}

Write-Host ""
Write-Host "Then, ON THE DESKTOP OF THE GUEST (not over ssh, because a mapped drive belongs to one logon):"
Write-Host "  powershell -ExecutionPolicy Bypass -File $($dest -replace '/','\')\mount-vault.ps1"
if (-not $elc) {
    Write-Host ""
    Write-Host "  NOTE: this script could not read EnableLinkedConnections from the guest. Thus" -ForegroundColor Yellow
    Write-Host "  it is UNKNOWN, not absent, whether Explorer can see the mapped drive." -ForegroundColor Yellow
    Write-Host "  install-guest-base.ps1 section 9b sets it, so a guest from this project has" -ForegroundColor Yellow
    Write-Host "  it. If the drive does not appear, ask the guest directly:" -ForegroundColor Yellow
    Write-Host "    Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' ``" -ForegroundColor Yellow
    Write-Host "      -Name EnableLinkedConnections" -ForegroundColor Yellow
} elseif ($elc -ne '1') {
    Write-Host ""
    Write-Host "  WARNING: EnableLinkedConnections is '$elc' in this guest, not 1." -ForegroundColor Yellow
    Write-Host "  Only Administrators can read the password file, so mount-vault must run" -ForegroundColor Yellow
    Write-Host "  elevated. Then Explorer cannot see the drive that it maps. Set it in the" -ForegroundColor Yellow
    Write-Host "  guest, and reboot. For a guest from this project, install-guest-base.ps1" -ForegroundColor Yellow
    Write-Host "  section 9b does it:" -ForegroundColor Yellow
    Write-Host "    New-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' ``" -ForegroundColor Yellow
    Write-Host "      -Name EnableLinkedConnections -PropertyType DWord -Value 1 -Force" -ForegroundColor Yellow
}
