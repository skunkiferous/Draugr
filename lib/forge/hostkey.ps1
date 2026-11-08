# lib/forge/hostkey.ps1: the known_hosts entry that a forge VM leaves.
#
# ==> YOU DO NOT TYPE THIS. lib/forge/rm.ps1 and lib/forge/layer.ps1 dot-source it. <==
#
# WHY THERE IS SOMETHING TO CLEAN. Each connection to a guest in vm.ps1 has `-o
# HostKeyAlias=draugr-<vm>`. Thus ssh files the key of the guest under the NAME
# of the VM, not under `[127.0.0.1]:<port>`. Because of that, a second guest on
# the pinned port no longer looks like a man in the middle. But the entry also
# lives longer than the VM, because a name is not a socket, and nothing removes
# it.
#
# The failure is real. Delete a VM, and create another with the same name.
# `accept-new` then correctly refuses a CHANGED key for a name that it saw
# before. That is exactly the refusal that cost a morning, in a different form.
# Names here are LAYER names, and people use layer names again.
#
# A TEST, after the delete of the temporary VMs with the correct verbs: three
# aliases were still in %USERPROFILE%\.ssh\known_hosts (draugr-forge-0,
# draugr-old-layer-test, and draugr-f0-boot-test), and nothing on the machine
# could ever answer for them.
#
# WHICH FILE, AND WHY NOT A FILE OF DRAUGR. vm.ps1 gives no -o
# UserKnownHostsFile, so ssh uses the default of the Windows user. This code
# must use the same file. It is the file of the HOST. The known_hosts on the WSL
# side is a different file, and holds none of these.

function Clear-ForgeHostKey([string]$Vm) {
    if (-not $Vm) { return $null }
    $kh = Join-Path $env:USERPROFILE '.ssh\known_hosts'
    if (-not (Test-Path $kh)) { return $null }
    $alias = "draugr-$Vm"

    # ssh-keygen -R, not a line filter, for two reasons. A HASHED known_hosts
    # has no readable name to match, and ssh-keygen writes known_hosts.old
    # itself. A grep silently does nothing on a hashed file, and leaves no way
    # back on a plain one.
    if (-not (Get-Command ssh-keygen.exe -ErrorAction SilentlyContinue)) { return $null }

    # LINE COUNTS DECIDE, not the exit code and not the text. `ssh-keygen -R`
    # always exits 0, so its status cannot answer "was there one?". A count also
    # works for a hashed file, where no pattern matches.
    $before = @(Get-Content $kh -ErrorAction SilentlyContinue).Count

    # REDIRECTED NATIVE STDERR, AND NO PREFERENCE FOR THE TIME OF THE CALL.
    # ssh-keygen reports what it removed on stderr. layer.ps1 runs under
    # $ErrorActionPreference = 'Stop', and that makes a redirected native stderr
    # line a terminating NativeCommandError. Thus a SUCCESSFUL removal kills the
    # caller. See docs/HACKING.md, rule 11.
    $eapWas = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $null = & ssh-keygen.exe -R $alias -f $kh 2>&1 }
    catch { return $null }
    finally { $ErrorActionPreference = $eapWas }

    $after = @(Get-Content $kh -ErrorAction SilentlyContinue).Count
    if ($after -lt $before) { return "host key for '$alias' cleared from $kh" }
    return $null
}
