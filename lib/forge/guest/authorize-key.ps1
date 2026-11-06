# authorize-key.ps1 - let a public key log into this guest, idempotently.
#
# WHICH FILE, and why it is not ~/.ssh/authorized_keys: Windows OpenSSH's default sshd_config
# ends with
#
#     Match Group administrators
#            AuthorizedKeysFile __PROGRAMDATA__/ssh/administrators_authorized_keys
#
# so for a member of Administrators - which the forge user is - the per-user file is NOT read.
# A key added there would be ignored, and the failure looks like a wrong key rather than a key
# in the wrong place.
#
# MATCHED ON THE KEY BODY, not the whole line. The comment at the end of a public key is free
# text that ssh-keygen, ssh-copy-id and people all write differently, so comparing lines would
# add the same key twice under two comments - and two entries for one key is how a revocation
# comes to look like it worked.
#
# THE FILE'S ACL IS LOAD-BEARING. sshd ignores administrators_authorized_keys if anyone beyond
# Administrators and SYSTEM can write it, and says so only in its own log. Appending preserves
# whatever is there; a file created from scratch gets the ACL set explicitly.
#
#   powershell -ExecutionPolicy Bypass -File .\authorize-key.ps1 -PubKeyFile C:\Windows\Temp\k.pub
#
# Prefer -PubKeyFile when driving this over ssh: the remote command goes through the guest's
# default shell first, and a key pasted as an argument comes apart on its spaces.
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
    # Administrators and SYSTEM only, inheritance off, or sshd refuses to read it.
    & icacls.exe $file /inheritance:r /grant '*S-1-5-32-544:F' /grant '*S-1-5-18:F' | Out-Null
    Write-Host 'created administrators_authorized_keys with an sshd-acceptable ACL'
} elseif (-not (Test-Path "$file.draugr-bak")) {
    Copy-Item $file "$file.draugr-bak" -Force
    Write-Host 'backed up to administrators_authorized_keys.draugr-bak'
}

if ((Get-Content $file) -match [regex]::Escape($body)) {
    Write-Host 'already authorised - nothing to do'
    Write-Host 'DRAUGR_CHANGED=0'
} else {
    Add-Content $file $PubKey
    Write-Host "authorised $($parts[0]) $($parts[-1])"
    Write-Host 'DRAUGR_CHANGED=1'
}

Write-Host '--- entries now, by their comment ---'
Get-Content $file | Where-Object { $_.Trim() } | ForEach-Object {
    $f = $_ -split '\s+'
    "  $($f[-1])"
}
