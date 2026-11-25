# vmstate.ps1: what the daemon says about one VM, in FOUR answers.
#
# WHY THIS FILE EXISTS. Four scripts carried a copy of this:
#
#     function Test-Running {
#         try { return [bool](Asb GET "/vms/$Vm").running } catch { return $false }
#     }
#
# which answers "it does not run" to three different questions: it is stopped,
# it was never registered, and nobody could ask. The third one is the problem.
# `Wait-Stopped` is built on it, so a daemon that stopped answering made the
# wait return TRUE, and a timeout then read as a clean stop. The callers of that
# are the ones that freeze a disk, delete a branch, delete the VM and clear its
# pinned host key. "I could not ask" must never be one of them.
#
# THE FOUR ANSWERS: running, stopped, absent, unknown. Only a caller knows what
# to do about unknown, so this reports it instead of choosing.
#
# ABSENT IS CONFIRMED, NOT ASSUMED. The API documents 404 as "unknown VM/route",
# one code for both (C:\AppSandbox\headless-api\README.md, "HTTP status /
# error model"). A route that moves in a later daemon thus makes EVERY VM
# look absent, which is the answer that lets a delete report success. Thus a 404
# on one VM is checked against the list of VMs before it becomes a verdict.
#
# This file needs an `Asb <Method> <Path>` in the scope that dot-sources it.
# Each script defines its own, with its own timeout, and that is deliberate: a
# snapshot call can take two minutes, a status call cannot.

# The HTTP status of a failed Invoke-RestMethod, or 0. In Windows PowerShell the
# exception is a WebException whose .Response holds it. A network-level failure
# (nothing listening, DNS, timeout) has no Response at all, and 0 is then the
# honest answer: there was no HTTP status.
function Get-ForgeHttpStatus($ErrorRecord) {
    $r = $null
    try { $r = $ErrorRecord.Exception.Response } catch { return 0 }
    if ($null -eq $r) { return 0 }
    try { return [int]$r.StatusCode } catch { return 0 }
}

function Get-ForgeVmState([string]$Vm) {
    $r = $null
    try {
        $r = Asb GET "/vms/$Vm"
    } catch {
        if ((Get-ForgeHttpStatus $_) -ne 404) { return 'unknown' }
        $list = $null
        try { $list = Asb GET '/vms' } catch { return 'unknown' }
        # No `vms` field is an answer this code does not understand. An empty
        # list is a different thing, and a real one: no VM is registered.
        if ($null -eq $list -or $null -eq $list.vms) { return 'unknown' }
        if (@($list.vms | ForEach-Object { $_.name }) -contains $Vm) { return 'unknown' }
        return 'absent'
    }
    # A 200 with no `running` field is not a stopped VM. It is an answer in a
    # shape this code does not know.
    if ($null -eq $r -or $null -eq $r.running) { return 'unknown' }
    if ($r.running) { return 'running' }
    return 'stopped'
}

# Wait until the state is one of $Until, and return THE STATE, not a boolean.
# The caller needs the difference: "it still runs" and "the daemon went quiet"
# have different fixes, and only one of them is about the VM.
#
# The state is read once more after the deadline, so the reported state is the
# last one seen and not the one from before the final sleep.
function Wait-ForgeVmState([string]$Vm, [string[]]$Until, [int]$Seconds, [int]$EverySec = 5) {
    $t0 = Get-Date
    do {
        $s = Get-ForgeVmState $Vm
        if ($Until -contains $s) { return $s }
        Start-Sleep -Seconds $EverySec
    } while (((Get-Date) - $t0).TotalSeconds -lt $Seconds)
    return (Get-ForgeVmState $Vm)
}

# "Not running" for the purposes of a stop: a VM that is gone is not running
# either. unknown is NOT in the list, which is the whole point of this file.
function Test-ForgeVmDown([string]$State) {
    return ($State -eq 'stopped' -or $State -eq 'absent')
}
