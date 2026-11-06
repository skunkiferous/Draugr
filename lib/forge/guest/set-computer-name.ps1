# set-computer-name.ps1 - give the guest the VM's own name.
#
# WHY IT MATTERS ONCE THERE IS MORE THAN ONE VM. Every VM built on this layer stack inherits the
# base image's computer name: measured, a VM called ue-427-test reporting `layer-0`.
# With one VM that is a curiosity. With several it is a trap - every log line, every tool that
# identifies the machine, and every "which box am I on?" answers the same thing for all of
# them, and the one place the truth lives (vms.cfg) is not visible from inside the guest.
#
# CONSTRAINTS WINDOWS IMPOSES, checked here rather than discovered on the failure:
#   - 15 characters. NetBIOS's limit, whatever the VM is called
#   - letters, digits and hyphens only: no underscores, dots or spaces
#   - not all digits, and no leading or trailing hyphen
#
# A name that will not fit is REFUSED with the reason, never silently truncated. `layer-2-ue4`
# would be worse than `layer-0`, because it looks deliberate.
#
# A RENAME NEEDS A REBOOT and this does not take one by itself: it says what it changed and
# leaves the timing to the caller, because the caller may be mid-provision with more to do.
# -Restart asks for it explicitly.
#
#   powershell -ExecutionPolicy Bypass -File .\set-computer-name.ps1 -Name ue-427-test
#   powershell -ExecutionPolicy Bypass -File .\set-computer-name.ps1 -Name ue-427-test -Restart
param([string]$Name = '', [switch]$Restart)

$ErrorActionPreference = 'Stop'

if (-not $Name) { Write-Error 'set-computer-name.ps1: -Name is required'; exit 2 }

# Each rule reported separately, so the message says which one the name broke.
$why = @()
if ($Name.Length -gt 15)             { $why += "it is $($Name.Length) characters; NetBIOS allows 15" }
if ($Name -notmatch '^[A-Za-z0-9-]+$') { $why += 'it has characters other than letters, digits and hyphens' }
if ($Name -match '^-|-$')            { $why += 'it starts or ends with a hyphen' }
if ($Name -match '^[0-9]+$')         { $why += 'it is all digits' }
if ($why.Count) {
    Write-Error ("cannot use '$Name' as a computer name: " + ($why -join '; '))
    Write-Host '  The VM keeps the name it has. Pick a shorter or simpler one and run this again.'
    exit 1
}

$current = $env:COMPUTERNAME
if ($current -ieq $Name) {
    Write-Host "already named '$current' - nothing to do"
    Write-Host 'DRAUGR_CHANGED=0'
    exit 0
}

Write-Host "renaming '$current' -> '$Name'"
# -Force skips the confirmation prompt; there is no console to answer it in a provisioning run
# or over ssh. -Restart is NOT passed through here: the reboot is decided below, so that the
# "what changed" line is printed before the machine goes away.
Rename-Computer -NewName $Name -Force
Write-Host 'renamed. It takes effect at the next boot.'
Write-Host 'DRAUGR_CHANGED=1'

if ($Restart) {
    Write-Host 'restarting now, as asked.'
    Restart-Computer -Force
} else {
    Write-Host 'Reboot the guest when convenient; until then it still answers to the old name.'
}
