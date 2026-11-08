# install-msys2.ps1: MSYS2 in the guest, pinned to one host, before something
# uses it.
#
# Run this IN THE GUEST through ssh, after install-guest-base.ps1 set the proxy,
# and with the tunnel up. It needs NO new allowlist entry, and that is the good
# part. The installer is on repo.msys2.org, the one host that kits/base already
# allows for pacman. Thus a guest with no adapter can set up its whole Unix
# layer through the gateway, and nothing becomes wider.
#
# THE PIN IS THE PURPOSE, and it must happen before the first sync. MSYS2 ships
# a rotating mirrorlist of about 21 third-party mirrors (university mirrors,
# CDNs). pacman connects to one that the policy does not know. That shows as a
# refusal that names a host that nobody selected. Each
# /etc/pacman.d/mirrorlist.* keeps its repo.msys2.org line, and loses the rest.
# Then pacman connects to that name, and to nothing else. A test showed this:
# the refusals named only this host.
#
# Traps that tests found:
#   - Through ssh, pacman needs a closed stdin. There is no terminal, so each question that
#     --noconfirm does not cover blocks forever, with no output. Each call here goes through
#     a subshell with < /dev/null (see install-base-tools.ps1 for the reason of the subshell).
#   - The first `pacman -Syu` can update pacman, stop, and ask for a second run. Thus the
#     code runs it twice. If once was enough, the second run does no damage.
#   - THE ORDINARY OUTPUT OF pacman GOES TO STDERR. Under $ErrorActionPreference = 'Stop', the
#     stderr of a native command, redirected by 2>&1, arrives as an ErrorRecord that stops
#     the script. A TEST SHOWED THIS. "warning: terminate other MSYS2 programs before
#     proceeding" is a warning, in the middle of the sync, with nothing wrong. It stopped
#     this script after the install of MSYS2 and the pin of the mirrorlists. Thus pass 2 and
#     the whole test below were skipped, and the phase reported FAILED (1) on a correct
#     guest. Invoke-Msys relaxes the preference for exactly the time of each call.
#   - The post-install step of the installer refreshes the pacman keyring from
#     hkps://keyserver.ubuntu.com, and this guest has no route to it. It prints a dozen
#     "keyserver refresh failed: Try again later" and "ERROR: Could not update key" lines,
#     and then continues. The keyring is already full, locally, from msys2.gpg. That is why
#     package signatures still pass. A test showed this. Nothing to fix here. An allow for
#     that host makes the policy wider for a refresh that the guest does not need.
#
# THE INSTALLER IS PINNED BY DATE AND HASH. That is not extra caution. It is the
# only integrity test here. MSYS2 publishes NO .sha256 for its installers, only
# a GPG .sig, for `latest` and for each dated build. GPG cannot work at this
# time, because gpg comes WITH MSYS2. A TEST SHOWED THIS: a request for
# msys2-x86_64-latest.exe.sha256 returns 404 from repo.msys2.org. That stopped a
# whole provisioning run (the .exe next to it returns 200, so egress was never
# the problem).
#
# A dated build is also correct for a base layer. With `latest`, the disk that
# you build today and the disk that you build next month differ, and nothing
# records how. The older version costs little, because the first `pacman -Syu`
# below updates everything anyway.
#
# For a newer installer, give -Version and -Sha256 TOGETHER, or change both
# here. The list of dated builds is at https://repo.msys2.org/distrib/x86_64/.
# The hash is the output of `Get-FileHash -Algorithm SHA256` for the file that
# you fetched.
#
#   powershell -ExecutionPolicy Bypass -File .\install-msys2.ps1
#   powershell -ExecutionPolicy Bypass -File .\install-msys2.ps1 -VerifyOnly
param(
    [string]$Msys = 'C:\msys64',
    [string]$Mirror = 'repo.msys2.org',
    # Measured: 85,046,168 bytes. The Content-Length of the server is the same.
    [string]$Version = '20260927',
    [string]$Sha256 = '416d506c839a2da4bc184eeec8cbaaf1055ee698618228c62dfc4232a6970f0e',
    [switch]$VerifyOnly
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$bash = Join-Path $Msys 'usr\bin\bash.exe'
$base = "https://$Mirror/distrib"

# Always a subshell, always < /dev/null. A redirect at the end of a PIPELINE
# applies only to its last stage. That is how a test run once reported each tool
# as missing, but all were present.
#
# Also always with the relaxed error preference. See the list of traps above.
# The 2>&1 is wanted, because pacman tells the problem on stderr, and that is
# useful. But a READ of stderr and a fatal stderr are different things, and
# 'Stop' cannot see the difference. The `finally` restores it, so that a real
# throw inside the call does not leave it relaxed.
function Invoke-Msys([string]$cmd) {
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { & $bash -lc "( $cmd ) < /dev/null" 2>&1 }
    finally { $ErrorActionPreference = $old }
}

# Only the mirrorlists that pacman really reads. A glob of
# etc/pacman.d/mirrorlist.* also finds .orig and .pacnew copies that nothing
# loads. Then the pin rewrites files with no effect, and the test reports a
# pinned guest as not pinned.
function Get-IncludedMirrorlist {
    $out = @()
    foreach ($l in (Get-Content (Join-Path $Msys 'etc\pacman.conf') -EA SilentlyContinue)) {
        if ($l -match '^\s*Include\s*=\s*(\S+)') {
            $p = $Matches[1] -replace '^/etc/', "$($Msys -replace '\\','/')/etc/"
            if ((Test-Path $p) -and ($out -notcontains $p)) { $out += $p }
        }
    }
    return $out
}

if (-not $VerifyOnly -and -not (Test-Path $bash)) {
    # --- fetch, and check what arrived ----------------------------------------------
    $exe = Join-Path $env:TEMP "msys2-x86_64-$Version.exe"
    $url = "$base/x86_64/msys2-x86_64-$Version.exe"
    Write-Host "downloading the MSYS2 installer $Version from $Mirror..."
    Invoke-WebRequest -UseBasicParsing $url -OutFile $exe

    $got = (Get-FileHash $exe -Algorithm SHA256).Hash.ToLower()
    if ($Sha256 -and $got -ne $Sha256.ToLower()) {
        # Delete it. A refused installer in TEMP is one careless double-click
        # from a run. The test exists to prevent exactly that.
        Remove-Item $exe -Force -EA SilentlyContinue
        throw ("MSYS2 installer hash mismatch for $Version" +
               "`n  expected $($Sha256.ToLower())" +
               "`n  got      $got" +
               "`n  Nothing was installed, and the download was deleted. The pin is old" +
               " (to move it, give -Version and -Sha256 together), or this is not the" +
               " file that it claims to be.")
    }
    Write-Host "  $Version, the sha256 is the same as the pin ($([math]::Round((Get-Item $exe).Length/1MB,1)) MB)"

    # --- install headlessly ----------------------------------------------------------
    # The installer is a Qt Installer Framework binary. `in` is its
    # non-interactive install verb. Start-Process -Wait, because otherwise it
    # returns before the end.
    Write-Host "installing to $Msys..."
    $p = Start-Process -FilePath $exe -ArgumentList @('in', '--confirm-command',
            '--accept-messages', '--root', $Msys) -Wait -PassThru -NoNewWindow
    if ($p.ExitCode -ne 0) { throw "the MSYS2 installer exited $($p.ExitCode)" }
    Remove-Item $exe -Force -EA SilentlyContinue
    if (-not (Test-Path $bash)) { throw "no bash at $bash after installing" }
}

if (-not (Test-Path $bash)) { throw "MSYS2 is not installed at $Msys (run without -VerifyOnly)" }

# --- pin each mirrorlist, before the first sync ---------------------------------------
$pinned = @()
if (-not $VerifyOnly) {
    foreach ($p in Get-IncludedMirrorlist) {
        $lines = Get-Content $p
        $out = foreach ($l in $lines) {
            if ($l -match '^\s*Server\s*=' -and $l -notmatch [regex]::Escape($Mirror)) {
                # A comment, not a delete, so that you can still read what was
                # removed.
                "#draugr-pinned# $l"
            } else { $l }
        }
        if (($out -join "`n") -ne ($lines -join "`n")) {
            Copy-Item $p "$p.draugr-backup" -Force
            Set-Content -Path $p -Value $out -Encoding ascii
            $pinned += (Split-Path $p -Leaf)
        }
    }
    if ($pinned.Count) { Write-Host "pinned to ${Mirror}: $($pinned -join ', ')" }

    Write-Host 'first sync (twice, because the first can update pacman and stop)...'
    foreach ($pass in 1, 2) {
        $out = Invoke-Msys 'timeout 900 pacman -Syu --noconfirm --disable-download-timeout'
        $out | Where-Object { $_ -match 'error|warning: config file|target not found' } |
            ForEach-Object { Write-Host "  $_" -ForegroundColor Yellow }
        Write-Host "  pass $pass done"
    }
}

# --- verification: by effect ---------------------------------------------------------
Write-Host ''
Write-Host '--- msys2 ---'
$bad = @()

$ver = Invoke-Msys 'uname -srm' | Where-Object { $_ } | Select-Object -First 1
if ($ver) { Write-Host "  bash          $ver" } else { Write-Host '  bash          NOT RUNNABLE' -ForegroundColor Red; $bad += 'bash' }

# Each Server line that stays must name the pinned host. Each other line is a
# mirror that pacman can connect to, and the policy refuses it later, at a less
# clear time.
#
# The code tests only the files that pacman.conf Includes. A glob of
# mirrorlist.* also finds .orig and .pacnew copies that pacman never reads, and
# reports a pinned guest as not pinned: 58 extra mirrors, all in backups that
# nothing loads. Only the Included files are enforced, so only that list needs a
# test.
$stray = @()
$included = @(Get-IncludedMirrorlist)
if (-not $included.Count) { $stray += 'pacman.conf Includes no mirrorlist' }
foreach ($p in $included) {
    foreach ($l in (Get-Content $p)) {
        if ($l -match '^\s*Server\s*=' -and $l -notmatch [regex]::Escape($Mirror)) {
            $stray += "$(Split-Path $p -Leaf): $l"
        }
    }
}
if ($stray.Count) {
    Write-Host "  mirrors       $($stray.Count) NOT pinned to $Mirror" -ForegroundColor Red
    $stray | Select-Object -First 3 | ForEach-Object { Write-Host "                  $_" -ForegroundColor Red }
    $bad += 'mirrors'
} else {
    Write-Host "  mirrors       pinned to $Mirror only"
}

$n = Invoke-Msys 'pacman -Qq | wc -l' | Where-Object { $_ -match '^\d+$' } | Select-Object -First 1
if ($n) { Write-Host "  packages      $n installed" }

$mb = Invoke-Msys "du -sm '$($Msys -replace '\\','/' -replace '^C:','/c')' 2>/dev/null | cut -f1" |
      Where-Object { $_ -match '^\d+$' } | Select-Object -First 1
if ($mb) { Write-Host "  size          $mb MB" }

Write-Host ''
if ($bad.Count) { Write-Host "FAILED: $($bad -join ', ')" -ForegroundColor Red; exit 1 }
Write-Host 'msys2 ready.' -ForegroundColor Green
