# set-computer-name.ps1: give the guest the own name of the VM.
#
# WHY IT IS IMPORTANT WITH MORE THAN ONE VM. Each VM on this layer stack
# inherits the computer name of the base image. A test showed this: a VM called
# ue-427-test reported `layer-0`. With one VM, that is a curiosity. With
# several, it is a trap. Each log line, each tool that identifies the machine,
# and each "which machine am I on?" give the same answer for all of them. The
# one place with the truth (vms.cfg) is not visible from inside the guest.
#
# THE LIMITS OF WINDOWS, tested here, so that you do not find them in a failure:
#   - 15 characters. The limit of NetBIOS, for each VM name
#   - only letters, digits, and hyphens: no underscores, dots, or spaces
#   - not all digits, and no hyphen at the start or the end
#
# The code REFUSES a name that does not fit, with the reason, and never cuts it
# silently. `layer-2-ue4` is worse than `layer-0`, because it looks deliberate.
#
# A RENAME NEEDS A REBOOT, and this does not do one by itself. It says what it
# changed, and the caller decides the time, because the caller can be in the
# middle of provisioning, with more to do. -Restart asks for it explicitly.
#
#   powershell -ExecutionPolicy Bypass -File .\set-computer-name.ps1 -Name ue-427-test
#   powershell -ExecutionPolicy Bypass -File .\set-computer-name.ps1 -Name ue-427-test -Restart
param([string]$Name = '', [switch]$Restart)

$ErrorActionPreference = 'Stop'

if (-not $Name) { Write-Error 'set-computer-name.ps1: -Name is required'; exit 2 }

# Each rule is reported separately, so that the message tells which rule the
# name broke.
$why = @()
if ($Name.Length -gt 15)             { $why += "it has $($Name.Length) characters, and NetBIOS allows 15" }
if ($Name -notmatch '^[A-Za-z0-9-]+$') { $why += 'it has characters other than letters, digits, and hyphens' }
if ($Name -match '^-|-$')            { $why += 'it starts or ends with a hyphen' }
if ($Name -match '^[0-9]+$')         { $why += 'it is all digits' }
if ($why.Count) {
    Write-Error ("cannot use '$Name' as a computer name: " + ($why -join '; '))
    Write-Host '  The VM keeps its name. Select a shorter or simpler one, and run this again.'
    exit 1
}

$current = $env:COMPUTERNAME
if ($current -ieq $Name) {
    Write-Host "already named '$current'. Nothing to do."
    Write-Host 'DRAUGR_CHANGED=0'
    exit 0
}

Write-Host "renaming '$current' -> '$Name'"
# -Force skips the question. A provisioning run or ssh has no console to answer
# it. -Restart does NOT go to the cmdlet here. The code below decides the
# reboot, so that the "what changed" line prints before the machine goes away.
Rename-Computer -NewName $Name -Force
Write-Host 'renamed. It applies at the next boot.'
Write-Host 'DRAUGR_CHANGED=1'

if ($Restart) {
    Write-Host 'restarting now, as asked.'
    Restart-Computer -Force
} else {
    Write-Host 'Reboot the guest at a good time. Until then, it still answers to the old name.'
}
