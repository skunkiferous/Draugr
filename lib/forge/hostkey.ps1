# lib/forge/hostkey.ps1 - the known_hosts entry a forge VM leaves behind.
#
# ==> NOT MEANT TO BE TYPED. Dot-sourced by lib/forge/rm.ps1 and lib/forge/layer.ps1. <==
#
# WHY THERE IS ANYTHING TO CLEAN UP. Every guest dial in vm.ps1 carries
# `-o HostKeyAlias=draugr-<vm>`, so the guest's key is filed under the VM's NAME instead of
# under `[127.0.0.1]:<port>`. That is what stopped a second guest on the pinned port looking
# like a man in the middle - but it also makes the entry outlive the VM, because a name is not
# a socket and nothing reclaims it.
#
# The failure it causes is not theoretical. Delete a VM, create another with the same name,
# and `accept-new` correctly refuses a CHANGED key for a name it has seen before - which is
# exactly the refusal that cost a morning, in a different disguise. Names here
# are LAYER names, and layer names get reused.
#
# MEASURED, after the temporary VMs were deleted with the proper verbs: three
# aliases still sat in %USERPROFILE%\.ssh\known_hosts - draugr-forge-0, draugr-old-layer-test
# and draugr-f0-boot-test - with nothing left on the machine that could ever answer for them.
#
# WHICH FILE, AND WHY NOT ONE OF DRAUGR'S OWN. vm.ps1 passes no -o UserKnownHostsFile, so ssh
# uses the Windows user's default. This has to match that choice rather than make its own, and
# it is the HOST's file: the WSL-side known_hosts is a different file and holds none of these.

function Clear-ForgeHostKey([string]$Vm) {
    if (-not $Vm) { return $null }
    $kh = Join-Path $env:USERPROFILE '.ssh\known_hosts'
    if (-not (Test-Path $kh)) { return $null }
    $alias = "draugr-$Vm"

    # ssh-keygen -R rather than a line filter, for two reasons it alone handles: a HASHED
    # known_hosts has no readable name to match on, and it writes known_hosts.old itself. A
    # grep would quietly do nothing on a hashed file and leave no way back on a plain one.
    if (-not (Get-Command ssh-keygen.exe -ErrorAction SilentlyContinue)) { return $null }

    # LINE COUNTS DECIDE, not the exit code and not the text. `ssh-keygen -R` exits 0 whether
    # it removed anything or not, so its status cannot answer "was there one?" - and a count
    # works for a hashed file, where no pattern would match.
    $before = @(Get-Content $kh -ErrorAction SilentlyContinue).Count

    # REDIRECTED NATIVE STDERR, AND THE PREFERENCE DROPPED FOR THE LENGTH OF THE CALL.
    # ssh-keygen reports what it removed on stderr, and layer.ps1 runs under
    # $ErrorActionPreference = 'Stop', which turns a redirected native stderr line into a
    # terminating NativeCommandError - so a SUCCESSFUL removal would kill the caller.
    # docs/HACKING.md, rule 11.
    $eapWas = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $null = & ssh-keygen.exe -R $alias -f $kh 2>&1 }
    catch { return $null }
    finally { $ErrorActionPreference = $eapWas }

    $after = @(Get-Content $kh -ErrorAction SilentlyContinue).Count
    if ($after -lt $before) { return "host key for '$alias' cleared from $kh" }
    return $null
}
