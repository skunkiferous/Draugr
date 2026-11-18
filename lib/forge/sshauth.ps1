# sshauth.ps1: is this sshd keys-only?
#
# The question is asked from OUTSIDE, about the running listener, because the
# guest can only report what its configuration file says. `ssh -v` with pubkey
# off prints the list the server offers before it fails:
#
#     Authentications that can continue: publickey,password,keyboard-interactive
#
# WHY A FUNCTION, AND NOT `-notmatch 'password'`. That was the test, and it
# passes a server that offers "publickey,keyboard-interactive". On Windows sshd
# keyboard-interactive is the interactive path, and that is where a password
# prompt comes back; a server offering it is not keys-only, whatever the word
# in the string. The gateway mound gets a rule that can reach this sshd, so
# what a sandbox may try to guess is the whole point of the phase.
#
# POSITIVE EVIDENCE ONLY. An empty list is not "passwords are off": during an
# sshd restart the connection is refused and nothing is offered at all. A
# method this code does not know is not evidence either, so the test is "every
# method offered is publickey", not "no method offered is a password".
function Test-KeysOnlyList([string]$Offered) {
    if ($null -eq $Offered) { return $false }
    $methods = @($Offered -split '[,\s]+' | Where-Object { $_ -ne '' })
    if ($methods.Count -eq 0) { return $false }
    foreach ($m in $methods) {
        if ($m -ne 'publickey') { return $false }
    }
    return $true
}
