# install-tunnel-key.ps1 - give the guest a key that can do nothing but hold the tunnel.
#
# Run this elevated IN THE GUEST, once, while the VM still has a network or over the admin
# SSH key. The tunnel key is what the host's vm-tunnel.ps1 uses, so it is long-lived and
# lives on the host unencrypted: every option here exists to make a stolen copy useless.
#
#   restrict      no shell, no PTY, no agent or X11 forwarding, no user rc file
#   port-forwarding   added back, because restrict removes it
#   permitlisten  the only listeners it may open: the proxy port the guest's own proxy
#                 settings name, and the sftp port the vault is mounted through.
#                 -R to anything else is refused by sshd
#   permitopen    the only destinations -L may reach. Without it, "port-forwarding"
#                 allows a local forward to ANY host and port the guest can dial, so
#                 naming the one MCP port here narrows the key rather than widening it
#   command       a forced command, so an interactive attempt prints one line and exits
#
# The admin key stays separate and unrestricted; do not merge the two.
#
#   powershell -ExecutionPolicy Bypass -File .\install-tunnel-key.ps1 -PubKey 'ssh-ed25519 AAAA... draugr-tunnel'
#   powershell -ExecutionPolicy Bypass -File .\install-tunnel-key.ps1 -PubKeyFile C:\ProgramData\draugr-tunnel.pub
#
# Prefer -PubKeyFile when driving this over ssh: the remote command goes through the guest's
# default shell first, and a key pasted as an argument comes apart on its spaces.

param([string]$PubKey,
      [string]$PubKeyFile,
      [string[]]$Listen = @('127.0.0.1:3128', '127.0.0.1:445'),
      # 8765 is the desktop UIA MCP server; 8000 is UE's own in-editor MCP plugin, which
      # is listed now so the forward exists before an editor is ever started.
      #
      # 22 is THIS GUEST'S OWN sshd, and it is what lets Draugr's ordinary git and data
      # commands reach the VM. The supervisor pins it to a fixed host port with
      # -L 127.0.0.1:18022:127.0.0.1:22, and 18022 is what the gateway mound is then given a
      # rule for - so the relay port, which moves (measured twice), never
      # appears in a policy rule that would go stale. See docs/FORGE.md, "The channel".
      #
      # IT WIDENS THIS KEY, and that is worth being explicit about: a holder of the tunnel key
      # could open a channel to the guest's sshd. Logging in through it still needs a key this
      # guest authorises, and the host already holds the unrestricted admin key, so the
      # marginal reach is small - but it is not nothing, and it is why the forced command and
      # `restrict` above stay exactly as they are.
      [string[]]$Open   = @('127.0.0.1:8765', '127.0.0.1:8000', '127.0.0.1:22'))

$ErrorActionPreference = 'Stop'

if ($PubKeyFile) { $PubKey = (Get-Content $PubKeyFile -Raw) }
if (-not $PubKey) { throw 'give either -PubKey or -PubKeyFile' }

$file = Join-Path $env:ProgramData 'ssh\administrators_authorized_keys'
if (-not (Test-Path $file)) { throw "not found: $file (is sshd installed in this guest?)" }

# The key body only - comments and options differ, the body is the identity.
$body = ($PubKey.Trim() -split '\s+')[0..1] -join ' '

$existing = Get-Content $file

# One permitlisten per allowed listener and one permitopen per allowed destination;
# sshd takes both options more than once.
$listenOpts = ($Listen | ForEach-Object { "permitlisten=`"$_`"" }) -join ','
$openOpts = ($Open | ForEach-Object { "permitopen=`"$_`"" }) -join ","
$opts = "restrict,port-forwarding,$listenOpts,$openOpts,command=`"cmd.exe /c echo tunnel-only`""
$line = "$opts $body draugr-tunnel"

# WHETHER THE LINE CHANGED is what the caller needs to know - not whether the key was there.
# sshd reads a key's options, permitopen among them, at AUTHENTICATION time, and holds them
# for the life of the session. So widening permitopen does NOTHING for a tunnel that is
# already connected, and the caller has to end that session - which it should only do when
# something actually moved.
#
# MEASURED on a VM built from a layer frozen before 127.0.0.1:22 was added to
# $Open: the supervisor connected, this script then added the port, and the live session went
# on answering
#
#     channel 7: open failed: administratively prohibited: open failed
#
# for forty minutes, while the listener stayed bound and every port-based check passed.
# Restarting the guest's sshd does not clear it either - Windows OpenSSH serves each
# connection from its own sshd.exe and Restart-Service leaves those children alone.
if (@($existing) -contains $line) {
    Write-Host 'the key is present with exactly these options - nothing to do'
    # Re-applied even so: sshd silently ignores the whole file if anyone else can write it,
    # which is cheap to guarantee here and miserable to diagnose later.
    icacls $file /inheritance:r /grant '*S-1-5-32-544:F' /grant '*S-1-5-18:F' | Out-Null
    Write-Host 'DRAUGR_CHANGED=0'
    exit 0
}

if ($existing | Where-Object { $_ -like "*$body*" }) {
    Write-Host 'present with different options - replacing its line'
    $existing = $existing | Where-Object { $_ -notlike "*$body*" }
}
$new = @($existing) + $line

Copy-Item $file "$file.draugr-backup" -Force
Set-Content -Path $file -Encoding ascii -Value $new

# sshd ignores the file if anyone but SYSTEM and the Administrators group can touch it.
icacls $file /inheritance:r /grant '*S-1-5-32-544:F' /grant '*S-1-5-18:F' | Out-Null

Write-Host "installed. $file now holds:"
Get-Content $file | ForEach-Object { ($_ -split '\s+')[-1] }
Write-Host 'DRAUGR_CHANGED=1'
