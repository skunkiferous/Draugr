# mount-vault.ps1: map the shares of the gateway inside the forge VM.
#
# Run this IN THE GUEST, once for each session. The shares arrive through the
# same tunnel as the proxy. The host forwards the SMB port of the gateway mound
# to 127.0.0.1:445 of this machine, and the own SMB client of Windows does the
# rest. Nothing is installed in the guest for this.
#
#   \\127.0.0.1\vault     the Fab vault, read-only
#   \\127.0.0.1\scratch   scratch, writable both ways
#
# What each side enforces, and why both do, on purpose:
#   - The mound bind-mounts the vault `ro`. Thus the KERNEL refuses a write there,
#     whatever Samba or this script believes.
#   - Samba also marks the share read-only. Thus a refusal is reported, and not
#     attempted.
#
# A test, compared with the sshfs route that this replaced: a list of 1,516
# asset folders took 0.6 s. An asset of 73.7 MB copied at 46.7 MB/s. And a
# refused delete is REFUSED, not reported as a success. That was the reason for
# the change.
#
# Once for each session, by design. Drive letters and stored credentials both
# belong to a logon session. Each ssh command of an agent gets a new one
# (session 0, where cmdkey also refuses to save anything). A map costs no
# process and no wait. Thus a call at the start of a session is cheaper than to
# keep something alive.
#
# RUN IT ON THE DESKTOP, not through ssh. The two guards below tell why.
#
#   powershell -ExecutionPolicy Bypass -File .\mount-vault.ps1              map V: (vault) and S: (scratch)
#   powershell -ExecutionPolicy Bypass -File .\mount-vault.ps1 -Unmap       drop them
param([string]$VaultDrive = 'V',
      [string]$ScratchDrive = 'S',
      [string]$Server = '127.0.0.1',
      [string]$User = 'agent',
      [string]$PassFile = "$env:ProgramData\draugr-vault\smb.pass",
      [switch]$Unmap)

$ErrorActionPreference = 'Stop'

if ($Unmap) {
    foreach ($d in $VaultDrive, $ScratchDrive) {
        Get-PSDrive -Name $d -ErrorAction SilentlyContinue | Remove-PSDrive -Force -ErrorAction SilentlyContinue
        # EAP RELAXED for this one call. When X: is not mapped, `net use X:
        # /delete` writes "The network connection could not be found." to
        # stderr. Under $ErrorActionPreference = 'Stop', native stderr
        # redirected by 2>&1 becomes an ErrorRecord that stops the script. Thus
        # an unmap of a drive that was never mapped stops before the code tries
        # the second drive. Here, an unmap of a missing drive is the expected
        # case, not a failure. The same trap as Invoke-Msys in install-msys2.ps1
        # and Invoke-Native in lib/forge/provision.ps1.
        $old = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try { & net use "${d}:" /delete /y 2>&1 | Out-Null }
        finally { $ErrorActionPreference = $old }
    }
    Write-Host "unmapped"
    return
}

if (-not (Test-Path $PassFile)) {
    throw ("missing: $PassFile. The vault phase of a provisioning run puts it there. " +
           "From the host: dr-layer provision <vm>, or lib/forge/vault-access.ps1 alone.")
}

# TWO WAYS THAT A SUCCESSFUL MOUNT IS STILL NOT VISIBLE WHERE YOU WANT IT. Tests
# showed both, and both are silent. The code tests them here, and does not only
# document them. At the time that you read the docs, you already lost the hour.
#
# 1. A mapped drive belongs to a LOGON SESSION. A drive mapped from an ssh
# session never
#    reaches the interactive desktop. These are different logons, not two tokens of one,
#    so EnableLinkedConnections cannot help. A TEST SHOWED THIS: this script printed
#    `V: -> \\127.0.0.1\vault` and `vault entries: 1516` through ssh, and `dir V:` on the
#    desktop answered "A drive with the name 'V' does not exist".
if ((Get-Process -Id $PID).SessionId -eq 0) {
    Write-Warning ('this is session 0, an ssh or service session, not the desktop. The ' +
        'drives are mapped only for THIS logon, and the interactive desktop does not ' +
        'see them, for each way to reach it. Run this ON the desktop (through VNC).')
}
# 2. Within one logon, it is for each ELEVATION TOKEN. Without
# EnableLinkedConnections, a
#    drive mapped from an elevated prompt is not visible to Explorer, or to each other
#    program that is not elevated. This script can only run elevated, because only
#    Administrators can read the password file. install-guest-base.ps1 sets the value
#    (section 9b). A guest that is older than that needs it once, and a reboot.
$elc = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' `
        -Name EnableLinkedConnections -ErrorAction SilentlyContinue).EnableLinkedConnections
if ($elc -ne 1) {
    Write-Warning ('EnableLinkedConnections is not set, so these drives are visible ' +
        'ONLY at this elevation level, not in Explorer if you are elevated now. Set it ' +
        'once, and reboot:' + "`n" +
        "    New-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' " +
        "-Name EnableLinkedConnections -PropertyType DWord -Value 1 -Force")
}

# Read it here, and build the credential in the process. The password never goes
# on a command line, where another process can read it from the process list.
$secret = ConvertTo-SecureString (Get-Content $PassFile -Raw).Trim() -AsPlainText -Force
$cred = New-Object System.Management.Automation.PSCredential($User, $secret)

foreach ($m in @(@{ d = $VaultDrive; share = 'vault' }, @{ d = $ScratchDrive; share = 'scratch' })) {
    $drive = $m.d
    if (Get-PSDrive -Name $drive -ErrorAction SilentlyContinue) {
        Write-Host "${drive}: already mapped"
        continue
    }
    # -Persist MAKES THE DRIVE LIVE LONGER THAN THIS PROCESS. -Scope Global is
    # global in this POWERSHELL, not in the logon session. Without -Persist, the
    # mapping dies at the exit of the script. The documented way to run this,
    # `powershell -ExecutionPolicy Bypass -File mount-vault.ps1`, is a CHILD
    # process.
    #
    # A TEST SHOWED THIS. It printed `V: -> \\127.0.0.1\vault` and `vault
    # entries: 1516`. That proved that the share, the password, and the tunnel
    # all worked. Then `dir V:` in the calling shell answered "A drive with the
    # name 'V' does not exist". It worked before only because it ran IN the own
    # shell of the caller, where that process IS the session. -Persist calls
    # WNetAddConnection2. That is a real Windows mapped drive, visible to
    # Explorer, to other processes, and to an installer from any place.
    #
    # One result to know: a persisted drive belongs to the ELEVATION LEVEL that
    # mapped it. If you map it elevated, an Explorer that is not elevated does
    # not see it, and the reverse, unless EnableLinkedConnections is set. Map it
    # where you want to use it.
    New-PSDrive -Name $drive -PSProvider FileSystem -Root "\\$Server\$($m.share)" `
        -Credential $cred -Scope Global -Persist -ErrorAction Stop | Out-Null
    Write-Host "${drive}: -> \\$Server\$($m.share)"
}

Write-Host ""
Write-Host "vault entries:   $((Get-ChildItem "${VaultDrive}:\" -ErrorAction SilentlyContinue).Count)"
Write-Host "scratch entries: $((Get-ChildItem "${ScratchDrive}:\" -ErrorAction SilentlyContinue).Count)"
