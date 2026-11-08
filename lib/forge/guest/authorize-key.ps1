# authorize-key.ps1: let a public key log in to this guest, idempotently (safe
# to run twice).
#
# WHICH FILE, and why not ~/.ssh/authorized_keys: the default sshd_config of
# Windows OpenSSH ends with
#
#     Match Group administrators
#            AuthorizedKeysFile __PROGRAMDATA__/ssh/administrators_authorized_keys
#
# Thus, for a member of Administrators (the forge user is one), sshd does NOT
# read the file of the user. It ignores a key there, and the failure looks like
# a wrong key, not like a key in the wrong place.
#
# THE CODE COMPARES THE KEY BODY, not the whole line. The comment at the end of
# a public key is free text. ssh-keygen, ssh-copy-id, and people all write it
# differently. A comparison of lines adds the same key twice, with two comments.
# With two entries for one key, a revocation looks like a success.
#
# THE ACL OF THE FILE IS NECESSARY. If others than Administrators and SYSTEM can
# write administrators_authorized_keys, sshd ignores it, and says so only in its
# own log. An append keeps the existing ACL. A new file gets the ACL explicitly.
#
#   powershell -ExecutionPolicy Bypass -File .\authorize-key.ps1 -PubKeyFile C:\Windows\Temp\k.pub
#
# Through ssh, use -PubKeyFile. The remote command goes through the default
# shell of the guest first, and a key pasted as an argument breaks at its
# spaces.
param([string]$PubKey = '', [string]$PubKeyFile = '')

$ErrorActionPreference = 'Stop'

if ($PubKeyFile) { $PubKey = (Get-Content $PubKeyFile -Raw) }
if (-not $PubKey) { Write-Error 'authorize-key.ps1: -PubKey or -PubKeyFile is required'; exit 2 }

$PubKey = $PubKey.Trim()
$parts = $PubKey -split '\s+'
if ($parts.Count -lt 2 -or $parts[0] -notmatch '^(ssh|ecdsa)-') {
    Write-Error "that does not look like a public key: $($PubKey.Substring(0, [Math]::Min(40, $PubKey.Length)))"
    exit 1
}
$body = $parts[1]

$file = Join-Path $env:ProgramData 'ssh\administrators_authorized_keys'

if (-not (Test-Path $file)) {
    New-Item -ItemType File -Path $file -Force | Out-Null
    # Only Administrators and SYSTEM, with inheritance off. Otherwise sshd
    # refuses to read it.
    & icacls.exe $file /inheritance:r /grant '*S-1-5-32-544:F' /grant '*S-1-5-18:F' | Out-Null
    Write-Host 'created administrators_authorized_keys with an ACL that sshd accepts'
} elseif (-not (Test-Path "$file.draugr-bak")) {
    Copy-Item $file "$file.draugr-bak" -Force
    Write-Host 'backed up to administrators_authorized_keys.draugr-bak'
}

if ((Get-Content $file) -match [regex]::Escape($body)) {
    Write-Host 'already authorized. Nothing to do.'
    Write-Host 'DRAUGR_CHANGED=0'
} else {
    Add-Content $file $PubKey
    Write-Host "authorized $($parts[0]) $($parts[-1])"
    Write-Host 'DRAUGR_CHANGED=1'
}

Write-Host '--- entries now, by their comment ---'
Get-Content $file | Where-Object { $_.Trim() } | ForEach-Object {
    $f = $_ -split '\s+'
    "  $($f[-1])"
}
