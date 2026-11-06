# harden-sshd.ps1 - take the guest's sshd off password authentication.
#
# WHY IT IS NOT OPTIONAL. The gateway mound is given an sbx rule that lets it reach this sshd
# (docs/FORGE.md, "The channel"), so a password login here is something a sandbox could sit and
# guess at. Keys only, and this runs BEFORE the rule is granted - that order is the whole
# point. Windows OpenSSH accepts passwords by DEFAULT, so a guest that has never been touched
# is a guest that accepts them.
#
# TWO TRAPS, both measured on a live guest, and both silent:
#
# 1. APPENDING DOES NOTHING. The default sshd_config ends with
#
#        Match Group administrators
#               AuthorizedKeysFile __PROGRAMDATA__/ssh/administrators_authorized_keys
#
#    and everything after a Match line is conditional on it. Appended directives applied to
#    administrators alone; `sshd -T`, which reports the GLOBAL config, kept answering
#    "passwordauthentication yes"; and the server went on offering passwords. A setting that is
#    in the file, is valid, and does nothing. So the directives are inserted ABOVE the first
#    Match line.
#
# 2. THE LISTENER HOLDS THE CONFIG. A new connection does not re-read it, so sshd must be
#    restarted - and restarting it from a session sshd is serving can kill the restart halfway:
#    the stop succeeds, the process carrying the start dies with the session, and the guest is
#    left with no sshd at all. The restart is therefore handed to a one-shot SYSTEM scheduled
#    task, which survives the session being cut.
#
# It is IDEMPOTENT: run it twice and the second run says there is nothing to do.
#
#   powershell -ExecutionPolicy Bypass -File .\harden-sshd.ps1
#   powershell -ExecutionPolicy Bypass -File .\harden-sshd.ps1 -NoRestart   # config only
param([string]$ConfigPath = "$env:ProgramData\ssh\sshd_config", [switch]$NoRestart)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $ConfigPath)) { Write-Error "no sshd_config at $ConfigPath"; exit 1 }

$lines = @(Get-Content $ConfigPath)

# Judged on the GLOBAL section only - everything above the first Match - for the reason in
# trap 1. A `PasswordAuthentication no` below a Match line is not the same setting.
$firstMatch = -1
for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match '^\s*Match\s') { $firstMatch = $i; break }
}
$globalEnd = if ($firstMatch -ge 0) { $firstMatch - 1 } else { $lines.Count - 1 }
$global = if ($globalEnd -ge 0) { $lines[0..$globalEnd] } else { @() }

$already = ($global -match '^\s*PasswordAuthentication\s+no') -and
           ($global -match '^\s*KbdInteractiveAuthentication\s+no')

if ($already) {
    Write-Host 'password authentication is already off in the global section - nothing to do'
    Write-Host 'DRAUGR_CHANGED=0'
} else {
    if (-not (Test-Path "$ConfigPath.draugr-bak")) {
        Copy-Item $ConfigPath "$ConfigPath.draugr-bak" -Force
        Write-Host "backed up to $(Split-Path $ConfigPath -Leaf).draugr-bak"
    }

    # Any existing (possibly contradictory) global setting is dropped rather than left to fight
    # the new one: sshd takes the FIRST occurrence of a keyword, so a stray `yes` above would win.
    # The block is FENCED so that a rewrite replaces the previous one instead of stacking a new
    # one on top of it. MEASURED without the fence: the first Match line walked
    # 85 -> 90 -> 97 across rewrites, because the old directives were dropped while the four
    # comment lines above them stayed, and a config file that grows per run is a log.
    $add = @(
        '# >>> Draugr keys-only, managed by harden-sshd.ps1 - edit between the fences >>>',
        '# The gateway mound is given an sbx rule that lets it reach this sshd, so a password',
        '# login here would be something a sandbox could sit and guess at. Keys only.',
        '# These MUST stay above the first Match block: everything after a Match line is',
        '# conditional on it, and sshd -T reports only the global config. See docs/FORGE.md.',
        'PasswordAuthentication no',
        'KbdInteractiveAuthentication no',
        '# <<< Draugr keys-only <<<',
        '')
    # Bounded on purpose. A start fence with no end fence drops NOTHING: treating the rest of
    # the file as "inside the block" would take the whole config with it, and a half-mangled
    # fence is precisely when that would happen.
    $blockFrom = -1
    $blockTo = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if (($firstMatch -ge 0) -and ($i -ge $firstMatch)) { break }
        if ($blockFrom -lt 0) {
            if ($lines[$i] -match '^#\s*>>>\s*Draugr keys-only') { $blockFrom = $i }
        } elseif ($lines[$i] -match '^#\s*<<<\s*Draugr keys-only') { $blockTo = $i; break }
    }
    if ($blockTo -lt 0) { $blockFrom = -1 }
    # The block ships with a blank line after its closing fence, so the removal has to take one
    # back - otherwise the fence stops the four comment lines accumulating and the blank line
    # accumulates instead, one per rewrite. Found by the test, not by reading.
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
    # Recompute where the Match block starts, since dropping lines moved it.
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
        Write-Host 'no Match block found - appended to the end'
    }
    Set-Content -Path $ConfigPath -Value $out -Encoding ASCII
    Write-Host 'DRAUGR_CHANGED=1'
}

Write-Host '--- the global config as sshd itself parses it ---'
# `sshd -T 2>$null` under Stop would have killed this script the moment sshd had anything to
# say - immediately after it rewrote sshd_config, which is exactly when a reader needs to
# know what sshd makes of the file. Guarded, and sshd's complaints are now REPORTED rather
# than swallowed: a config it refuses is the one outcome worth never hiding. docs/FORGE.md.
$eapWas = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try { $sshdT = @(sshd -T 2>&1) } finally { $ErrorActionPreference = $eapWas }
$sshdT |
    Select-String -Pattern '^(passwordauthentication|kbdinteractiveauthentication|pubkeyauthentication)' |
    ForEach-Object { "  $($_.Line)" }
if ($LASTEXITCODE -ne 0) {
    Write-Host "  sshd -T exited $LASTEXITCODE - it does not accept this config:" -ForegroundColor Yellow
    $sshdT | ForEach-Object { Write-Host "    $_" -ForegroundColor Yellow }
}

if ($already -or $NoRestart) {
    if ($NoRestart) { Write-Host 'not restarting, as asked - the running sshd still accepts what it accepted' }
    exit 0
}

# Handed to the scheduler, as SYSTEM, for the reason in trap 2. The fallback matters: if the
# restart throws after stopping, a plain Start-Service still brings sshd back.
Write-Host 'restarting sshd through a one-shot SYSTEM task, so the restart cannot die with this session'
$a = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument `
    '-NoProfile -Command "try { Restart-Service sshd -Force -ErrorAction Stop } catch { Start-Service sshd }"'
$p = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
Register-ScheduledTask -TaskName 'DraugrSshdRestart' -Action $a -Principal $p -Force | Out-Null
Start-ScheduledTask -TaskName 'DraugrSshdRestart'
Write-Host 'restart requested. This session may be cut; that is expected.'
Write-Host 'The caller should verify from OUTSIDE: ssh must offer publickey only.'
