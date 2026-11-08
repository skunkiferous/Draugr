# harden-sshd.ps1: turn off password authentication in the sshd of the guest.
#
# WHY IT IS NOT OPTIONAL. The gateway mound gets an sbx rule that lets it reach
# this sshd (docs/FORGE.md, "The channel"). Thus a sandbox can try to guess a
# password login here. Keys only, and this runs BEFORE the rule exists. That
# order is the purpose. Windows OpenSSH accepts passwords by DEFAULT, so an
# untouched guest accepts them.
#
# TWO TRAPS. Tests on a live guest showed both, and both are silent:
#
# 1. AN APPEND DOES NOTHING. The default sshd_config ends with
#
#        Match Group administrators
#               AuthorizedKeysFile __PROGRAMDATA__/ssh/administrators_authorized_keys
#
#    and all lines after a Match line depend on it. Appended directives applied only to
#    administrators. `sshd -T`, which reports the GLOBAL configuration, still answered
#    "passwordauthentication yes", and the server still offered passwords. The value is in the
#    file and valid, but does nothing. Thus the code inserts the directives ABOVE the first
#    Match line.
#
# 2. THE LISTENER HOLDS THE CONFIGURATION. A new connection does not read it
# again, so sshd
#    needs a restart. A restart from a session that sshd serves can stop in the middle. The
#    stop works, the process that does the start dies with the session, and the guest has no
#    sshd. Thus a one-shot SYSTEM scheduled task does the restart. It survives the cut of the
#    session.
#
# It is IDEMPOTENT. A second run says that there is nothing to do.
#
#   powershell -ExecutionPolicy Bypass -File .\harden-sshd.ps1
#   powershell -ExecutionPolicy Bypass -File .\harden-sshd.ps1 -NoRestart   # config only
param([string]$ConfigPath = "$env:ProgramData\ssh\sshd_config", [switch]$NoRestart)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $ConfigPath)) { Write-Error "no sshd_config at $ConfigPath"; exit 1 }

$lines = @(Get-Content $ConfigPath)

# Only the GLOBAL section counts, all above the first Match, for the reason in
# trap 1. A `PasswordAuthentication no` below a Match line is not the same
# value.
$firstMatch = -1
for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match '^\s*Match\s') { $firstMatch = $i; break }
}
$globalEnd = if ($firstMatch -ge 0) { $firstMatch - 1 } else { $lines.Count - 1 }
$global = if ($globalEnd -ge 0) { $lines[0..$globalEnd] } else { @() }

$already = ($global -match '^\s*PasswordAuthentication\s+no') -and
           ($global -match '^\s*KbdInteractiveAuthentication\s+no')

if ($already) {
    Write-Host 'password authentication is already off in the global section. Nothing to do.'
    Write-Host 'DRAUGR_CHANGED=0'
} else {
    if (-not (Test-Path "$ConfigPath.draugr-bak")) {
        Copy-Item $ConfigPath "$ConfigPath.draugr-bak" -Force
        Write-Host "backed up to $(Split-Path $ConfigPath -Leaf).draugr-bak"
    }

    # The code removes each existing global value (it can disagree), so that it
    # does not fight the new one. sshd uses the FIRST occurrence of a keyword,
    # so an old `yes` above wins. The block has FENCES, so that a rewrite
    # replaces the previous block, and does not add a new one on top. A TEST
    # WITHOUT THE FENCE showed this: the first Match line moved from 85 to 90 to
    # 97 across rewrites. The code removed the old directives, but the four
    # comment lines above them stayed. A configuration file that grows at each
    # run is a log.
    $add = @(
        '# >>> Draugr keys-only, managed by harden-sshd.ps1 - edit between the fences >>>',
        '# The gateway mound gets an sbx rule that lets it reach this sshd. Thus a sandbox',
        '# can try to guess a password login here. Keys only.',
        '# These MUST stay above the first Match block. All lines after a Match line depend',
        '# on it, and sshd -T reports only the global configuration. See docs/FORGE.md.',
        'PasswordAuthentication no',
        'KbdInteractiveAuthentication no',
        '# <<< Draugr keys-only <<<',
        '')
    # Limited on purpose. A start fence with no end fence removes NOTHING. If
    # the rest of the file counts as "inside the block", the whole configuration
    # goes. That happens exactly with a half-damaged fence.
    $blockFrom = -1
    $blockTo = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if (($firstMatch -ge 0) -and ($i -ge $firstMatch)) { break }
        if ($blockFrom -lt 0) {
            if ($lines[$i] -match '^#\s*>>>\s*Draugr keys-only') { $blockFrom = $i }
        } elseif ($lines[$i] -match '^#\s*<<<\s*Draugr keys-only') { $blockTo = $i; break }
    }
    if ($blockTo -lt 0) { $blockFrom = -1 }
    # The block has a blank line after its closing fence, so the removal must
    # also remove one. Otherwise the fence stops the growth of the four comment
    # lines, but the blank line grows instead, one for each rewrite. The test
    # found this, not a reader.
    if (($blockTo -ge 0) -and (($blockTo + 1) -lt $lines.Count) -and ($lines[$blockTo + 1] -match '^\s*$')) {
        $blockTo++
    }
    $keep = @()
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if (($blockFrom -ge 0) -and ($i -ge $blockFrom) -and ($i -le $blockTo)) { continue }
        $inGlobal = ($firstMatch -lt 0) -or ($i -lt $firstMatch)
        if ($inGlobal -and $lines[$i] -match '^\s*(PasswordAuthentication|KbdInteractiveAuthentication)\s') { continue }
        $keep += $lines[$i]
    }
    # Find the start of the Match block again, because the removed lines moved
    # it.
    $at = -1
    for ($i = 0; $i -lt $keep.Count; $i++) {
        if ($keep[$i] -match '^\s*Match\s') { $at = $i; break }
    }
    if ($at -ge 0) {
        $out = @()
        if ($at -gt 0) { $out += $keep[0..($at - 1)] }
        $out += $add
        $out += $keep[$at..($keep.Count - 1)]
        Write-Host "inserted above the Match block at line $($at + 1)"
    } else {
        $out = $keep + $add
        Write-Host 'no Match block found. Appended to the end.'
    }
    Set-Content -Path $ConfigPath -Value $out -Encoding ASCII
    Write-Host 'DRAUGR_CHANGED=1'
}

Write-Host '--- the global configuration, as sshd parses it ---'
# Under Stop, `sshd -T 2>$null` killed this script as soon as sshd said
# something. That was directly after the rewrite of sshd_config. At exactly that
# time, a reader must know what sshd thinks of the file. Now it has a guard, and
# the code REPORTS the complaints of sshd, and does not hide them. A
# configuration that sshd refuses must never be hidden. See docs/FORGE.md.
$eapWas = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try { $sshdT = @(sshd -T 2>&1) } finally { $ErrorActionPreference = $eapWas }
$sshdT |
    Select-String -Pattern '^(passwordauthentication|kbdinteractiveauthentication|pubkeyauthentication)' |
    ForEach-Object { "  $($_.Line)" }
if ($LASTEXITCODE -ne 0) {
    Write-Host "  sshd -T exited $LASTEXITCODE. It does not accept this configuration:" -ForegroundColor Yellow
    $sshdT | ForEach-Object { Write-Host "    $_" -ForegroundColor Yellow }
}

if ($already -or $NoRestart) {
    if ($NoRestart) { Write-Host 'no restart, as you asked. The running sshd still accepts what it accepted before' }
    exit 0
}

# The scheduler does it, as SYSTEM, for the reason in trap 2. The fallback is
# important. If the restart throws after the stop, a plain Start-Service still
# starts sshd again.
Write-Host 'restarting sshd through a one-shot SYSTEM task, so that the restart cannot die with this session'
$a = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument `
    '-NoProfile -Command "try { Restart-Service sshd -Force -ErrorAction Stop } catch { Start-Service sshd }"'
$p = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
Register-ScheduledTask -TaskName 'DraugrSshdRestart' -Action $a -Principal $p -Force | Out-Null
Start-ScheduledTask -TaskName 'DraugrSshdRestart'
Write-Host 'restart requested. This session can stop. That is expected.'
Write-Host 'The caller must make sure from OUTSIDE that ssh offers only publickey.'
