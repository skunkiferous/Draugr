# mount-vault.ps1 - map the gateway's shares inside the forge VM.
#
# Run this IN THE GUEST, once per session. The shares arrive over the same tunnel
# as the proxy: the host forwards the gateway mound's SMB port to this machine's
# 127.0.0.1:445, and Windows' own SMB client does the rest. Nothing is installed
# in the guest for this.
#
#   \\127.0.0.1\vault     the Fab vault, read-only
#   \\127.0.0.1\scratch   scratch, writable both ways
#
# What each side enforces, and why saying it twice is deliberate:
#   - the mound bind-mounts the vault `ro`, so the KERNEL refuses a write there,
#     whatever Samba or this script believes;
#   - Samba marks the share read only as well, so a refusal is reported rather
#     than attempted.
#
# Measured, against the sshfs route this replaced: listing 1,516 asset
# folders 0.6 s, a 73.7 MB asset copied at 46.7 MB/s, and - the reason for the
# change - a refused delete is REFUSED rather than reported as a success.
#
# Per session, by design. Drive letters and stored credentials both belong to a
# logon session, and an agent's ssh commands each get a new one (session 0, where
# cmdkey also refuses to save anything). Mapping costs no process and no wait, so
# calling this at the start of a session is cheaper than keeping anything alive.
#
# RUN IT ON THE DESKTOP, not over ssh, and see the two guards below for why.
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
        # EAP RELAXED around this one call. `net use X: /delete` writes "The network
        # connection could not be found." to stderr when X: is not mapped, and under
        # $ErrorActionPreference = 'Stop' native stderr redirected by 2>&1 becomes an
        # ErrorRecord that terminates the script - so unmapping a drive that was never
        # mapped would abort before the second drive was even tried. Unmapping something
        # already absent is the expected case here, not a failure. Same trap as Invoke-Msys
        # in install-msys2.ps1 and Invoke-Native in lib/forge/provision.ps1.
        $old = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try { & net use "${d}:" /delete /y 2>&1 | Out-Null }
        finally { $ErrorActionPreference = $old }
    }
    Write-Host "unmapped"
    return
}

if (-not (Test-Path $PassFile)) {
    throw ("missing: $PassFile - the vault phase of a provisioning run puts it there. " +
           "From the host: dr-layer provision <vm>, or lib/forge/vault-access.ps1 alone.")
}

# TWO WAYS A SUCCESSFUL MOUNT IS STILL INVISIBLE WHERE YOU WANT IT, both measured, both
# silent. Checked here rather than documented, because by the time you are reading docs you
# have already lost the hour.
#
# 1. A mapped drive belongs to a LOGON SESSION. One made from an ssh session never reaches
#    the interactive desktop - different logons, not two tokens of one, so
#    EnableLinkedConnections cannot help. MEASURED: this script printed
#    `V: -> \\127.0.0.1\vault` and `vault entries: 1516` over ssh, and `dir V:` on the
#    desktop answered "A drive with the name 'V' does not exist".
if ((Get-Process -Id $PID).SessionId -eq 0) {
    Write-Warning ('this is session 0 - an ssh or service session, not the desktop. The ' +
        'drives will be mapped for THIS logon only and the interactive desktop will not ' +
        'see them, however it is reached. Run this ON the desktop (over VNC) instead.')
}
# 2. Within one logon it is per ELEVATION TOKEN. Without EnableLinkedConnections, a drive
#    mapped from an elevated prompt is invisible to Explorer and to anything else
#    unelevated - and this script can only BE run elevated, because the password file is
#    readable only by Administrators. install-guest-base.ps1 sets the value (section 9b);
#    a guest built before it did needs it once, plus a reboot.
$elc = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' `
        -Name EnableLinkedConnections -ErrorAction SilentlyContinue).EnableLinkedConnections
if ($elc -ne 1) {
    Write-Warning ('EnableLinkedConnections is not set, so these drives will be visible ' +
        'ONLY at this elevation level - not in Explorer if you are elevated now. Set it ' +
        'once and reboot:' + "`n" +
        "    New-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' " +
        "-Name EnableLinkedConnections -PropertyType DWord -Value 1 -Force")
}

# Read it here and build the credential in process: the password never reaches a
# command line, where another process could read it out of the process list.
$secret = ConvertTo-SecureString (Get-Content $PassFile -Raw).Trim() -AsPlainText -Force
$cred = New-Object System.Management.Automation.PSCredential($User, $secret)

foreach ($m in @(@{ d = $VaultDrive; share = 'vault' }, @{ d = $ScratchDrive; share = 'scratch' })) {
    $drive = $m.d
    if (Get-PSDrive -Name $drive -ErrorAction SilentlyContinue) {
        Write-Host "${drive}: already mapped"
        continue
    }
    # -Persist IS WHAT MAKES THE DRIVE OUTLIVE THIS PROCESS. -Scope Global is global within
    # this POWERSHELL, not within the logon session, so without -Persist the mapping dies
    # when the script exits - and the documented way to run this,
    # `powershell -ExecutionPolicy Bypass -File mount-vault.ps1`, is a CHILD process.
    #
    # MEASURED: it printed `V: -> \\127.0.0.1\vault` and `vault entries: 1516`,
    # proving the share, the password and the tunnel were all fine - and `dir V:` in the
    # calling shell then answered "A drive with the name 'V' does not exist". It had worked
    # before only because it used to be run IN the caller's own shell, where that process IS
    # the session. -Persist calls WNetAddConnection2 instead: a real Windows mapped drive,
    # visible to Explorer, to other processes, and to an installer started from anywhere.
    #
    # One consequence worth knowing: a persisted drive belongs to the ELEVATION LEVEL that
    # mapped it. Map it elevated and a non-elevated Explorer will not see it, and the other
    # way round, unless EnableLinkedConnections is set. Map it where you intend to use it.
    New-PSDrive -Name $drive -PSProvider FileSystem -Root "\\$Server\$($m.share)" `
        -Credential $cred -Scope Global -Persist -ErrorAction Stop | Out-Null
    Write-Host "${drive}: -> \\$Server\$($m.share)"
}

Write-Host ""
Write-Host "vault entries:   $((Get-ChildItem "${VaultDrive}:\" -ErrorAction SilentlyContinue).Count)"
Write-Host "scratch entries: $((Get-ChildItem "${ScratchDrive}:\" -ErrorAction SilentlyContinue).Count)"
