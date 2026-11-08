# install-tunnel-key.ps1: give the guest a key that can only hold the tunnel.
#
# Run this elevated IN THE GUEST, once, while the VM still has a network, or
# through the admin SSH key. The vm-tunnel.ps1 of the host uses the tunnel key.
# Thus it lives long, and stays on the host without encryption. Each option here
# makes a stolen copy useless.
#
#   restrict      no shell, no PTY, no agent or X11 forwarding, no user rc file
#   port-forwarding   added again, because restrict removes it
#   permitlisten  the only listeners that it can open: the proxy port in the proxy
#                 configuration of the guest, and the sftp port of the vault mount.
#                 sshd refuses -R to all else
#   permitopen    the only destinations that -L can reach. Without it,
#                 "port-forwarding" allows a local forward to EACH host and port that the
#                 guest can reach. Thus the names here make the key narrower, not wider
#   command       a forced command, so that an interactive attempt prints one line and exits
#
# The admin key stays separate and has no limits. Do not merge the two.
#
#   powershell -ExecutionPolicy Bypass -File .\install-tunnel-key.ps1 -PubKey 'ssh-ed25519 AAAA... draugr-tunnel'
#   powershell -ExecutionPolicy Bypass -File .\install-tunnel-key.ps1 -PubKeyFile C:\ProgramData\draugr-tunnel.pub
#
# Through ssh, use -PubKeyFile. The remote command goes through the default
# shell of the guest first, and a key pasted as an argument breaks at its
# spaces.

param([string]$PubKey,
      [string]$PubKeyFile,
      [string[]]$Listen = @('127.0.0.1:3128', '127.0.0.1:445'),
      # 8765 is the desktop UIA MCP server. 8000 is the in-editor MCP plugin of
      # UE. It is in the list now, so that the forward exists before the first
      # start of an editor.
      #
      # 22 is the OWN sshd of THIS GUEST. Through it, the ordinary git and data
      # commands of Draugr reach the VM. The supervisor pins it to a fixed host
      # port with -L 127.0.0.1:18022:127.0.0.1:22, and the gateway mound gets a
      # rule for 18022. Thus the relay port, which changes (two tests showed
      # this), is never in a policy rule that becomes old. See docs/FORGE.md,
      # "The channel".
      #
      # IT MAKES THIS KEY WIDER, and that needs a clear statement. A holder of
      # the tunnel key can open a channel to the sshd of the guest. A login
      # through it still needs a key that this guest authorizes, and the host
      # already has the admin key with no limits. Thus the extra reach is small.
      # But it is not zero. That is why the forced command and `restrict` above
      # stay exactly as they are.
      [string[]]$Open   = @('127.0.0.1:8765', '127.0.0.1:8000', '127.0.0.1:22'))

$ErrorActionPreference = 'Stop'

if ($PubKeyFile) { $PubKey = (Get-Content $PubKeyFile -Raw) }
if (-not $PubKey) { throw 'give either -PubKey or -PubKeyFile' }

$file = Join-Path $env:ProgramData 'ssh\administrators_authorized_keys'
if (-not (Test-Path $file)) { throw "not found: $file (is sshd installed in this guest?)" }

# Only the key body. Comments and options differ. The body is the identity.
$body = ($PubKey.Trim() -split '\s+')[0..1] -join ' '

$existing = Get-Content $file

# One permitlisten for each allowed listener, and one permitopen for each
# allowed destination. sshd accepts both options more than once.
$listenOpts = ($Listen | ForEach-Object { "permitlisten=`"$_`"" }) -join ','
$openOpts = ($Open | ForEach-Object { "permitopen=`"$_`"" }) -join ","
$opts = "restrict,port-forwarding,$listenOpts,$openOpts,command=`"cmd.exe /c echo tunnel-only`""
$line = "$opts $body draugr-tunnel"

# The caller must know WHETHER THE LINE CHANGED, not whether the key was there.
# sshd reads the options of a key, permitopen too, at AUTHENTICATION, and keeps
# them for the life of the session. Thus a wider permitopen does NOTHING for a
# tunnel that is already connected. The caller must end that session, but only
# after a real change.
#
# A TEST on a VM from a layer that was frozen before 127.0.0.1:22 was in $Open
# showed this. The supervisor connected, this script then added the port, and
# the live session still answered
#
#     channel 7: open failed: administratively prohibited: open failed
#
# for forty minutes, while the listener stayed bound, and each port test passed.
# A restart of the sshd of the guest does not clear it either. Windows OpenSSH
# serves each connection from its own sshd.exe, and Restart-Service does not
# touch those children.
if (@($existing) -contains $line) {
    Write-Host 'the key is present with exactly these options. Nothing to do.'
    # Applied again anyway. If others can write the file, sshd silently ignores
    # all of it. That is cheap to prevent here, and hard to diagnose later.
    icacls $file /inheritance:r /grant '*S-1-5-32-544:F' /grant '*S-1-5-18:F' | Out-Null
    Write-Host 'DRAUGR_CHANGED=0'
    exit 0
}

if ($existing | Where-Object { $_ -like "*$body*" }) {
    Write-Host 'present with different options. Replacing its line.'
    $existing = $existing | Where-Object { $_ -notlike "*$body*" }
}
$new = @($existing) + $line

Copy-Item $file "$file.draugr-backup" -Force
Set-Content -Path $file -Encoding ascii -Value $new

# If others than SYSTEM and the Administrators group can touch the file, sshd
# ignores it.
icacls $file /inheritance:r /grant '*S-1-5-32-544:F' /grant '*S-1-5-18:F' | Out-Null

Write-Host "installed. $file now holds:"
Get-Content $file | ForEach-Object { ($_ -split '\s+')[-1] }
Write-Host 'DRAUGR_CHANGED=1'
