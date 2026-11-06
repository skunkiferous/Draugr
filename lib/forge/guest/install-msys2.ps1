# install-msys2.ps1 - MSYS2 in the guest, pinned to one host, before anything uses it.
#
# Run this IN THE GUEST over ssh, after install-guest-base.ps1 has set the proxy and with
# the tunnel up. It needs NO new allowlist entry, which is the nice part: the installer
# itself lives on repo.msys2.org, the one host kits/base already allows for pacman. A
# guest with no adapter can therefore bootstrap its whole Unix layer through the gateway
# without widening anything.
#
# THE PINNING IS THE POINT, and it has to happen before the first sync. MSYS2 ships a
# rotating mirrorlist of about 21 third-party mirrors (university mirrors, CDNs), and
# pacman will happily dial one the policy has never heard of - which surfaces as a refusal
# naming a host nobody chose. Every /etc/pacman.d/mirrorlist.* keeps its repo.msys2.org
# line and loses the rest; then pacman dials that name and nothing else. Measured
# by watching the refusals name only this host.
#
# Traps, measured:
#   - pacman needs stdin closed over ssh. There is no terminal, so any prompt --noconfirm
#     does not cover blocks forever with no output. Every call here goes through a
#     subshell with < /dev/null (see install-base-tools.ps1 for why the subshell).
#   - the first `pacman -Syu` can update pacman itself and stop, asking to be re-run. It
#     is run twice for that reason, which is harmless when once was enough.
#   - pacman's ORDINARY CHATTER GOES TO STDERR, and under $ErrorActionPreference = 'Stop' a
#     native command's stderr redirected by 2>&1 arrives as an ErrorRecord that terminates
#     the script. MEASURED: "warning: terminate other MSYS2 programs before
#     proceeding" - a warning, mid-sync, with nothing wrong - aborted this script after
#     MSYS2 was installed and the mirrorlists were pinned, so pass 2 and the whole
#     verification below were skipped and the phase reported FAILED (1) on a correct guest.
#     Invoke-Msys relaxes the preference for exactly the length of each call.
#   - the installer's own post-install step refreshes the pacman keyring from
#     hkps://keyserver.ubuntu.com, which this guest has no route to. It prints a dozen
#     "keyserver refresh failed: Try again later" and "ERROR: Could not update key" lines
#     and then carries on - the keyring is already populated locally from msys2.gpg, which
#     is why package signatures verify regardless. Measured. Nothing to fix here:
#     allowing that host would widen the policy for a refresh the guest does not need.
#
# THE INSTALLER IS PINNED BY DATE AND HASH, and that is not belt-and-braces: it is the only
# integrity check available here. MSYS2 publishes NO .sha256 for its installers - only a GPG
# .sig, for `latest` and for every dated build alike - and GPG is unusable at this point by
# construction, since gpg arrives WITH MSYS2. MEASURED: asking for
# msys2-x86_64-latest.exe.sha256 returns 404 from repo.msys2.org, which is what took down a
# whole provisioning run (the .exe beside it returns 200, so egress was never the problem).
#
# A dated build is also the right thing for a base layer: `latest` means the disk you build
# today and the disk you rebuild next month differ in a way nothing records. The vintage
# costs little, because the first `pacman -Syu` below updates everything anyway.
#
# To move to a newer installer, pass -Version and -Sha256 TOGETHER, or change both here.
# Dated builds are listed at https://repo.msys2.org/distrib/x86_64/ and the hash is whatever
# `Get-FileHash -Algorithm SHA256` says about the file you fetched.
#
#   powershell -ExecutionPolicy Bypass -File .\install-msys2.ps1
#   powershell -ExecutionPolicy Bypass -File .\install-msys2.ps1 -VerifyOnly
param(
    [string]$Msys = 'C:\msys64',
    [string]$Mirror = 'repo.msys2.org',
    # Measured: 85,046,168 bytes, Content-Length confirmed against the server.
    [string]$Version = '20260927',
    [string]$Sha256 = '416d506c839a2da4bc184eeec8cbaaf1055ee698618228c62dfc4232a6970f0e',
    [switch]$VerifyOnly
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$bash = Join-Path $Msys 'usr\bin\bash.exe'
$base = "https://$Mirror/distrib"

# Always a subshell, always < /dev/null: appending the redirect to a PIPELINE would
# redirect only its last stage, which is how a verification run once reported every tool
# missing when all of them were present.
#
# And always with the error preference relaxed: see the trap list above. The 2>&1 is wanted -
# pacman says what went wrong on stderr and that is worth reading - but wanting to READ
# stderr and wanting it to be fatal are different things, and 'Stop' cannot tell them apart.
# Restored in `finally` so a genuine throw inside the call does not leave it relaxed.
function Invoke-Msys([string]$cmd) {
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { & $bash -lc "( $cmd ) < /dev/null" 2>&1 }
    finally { $ErrorActionPreference = $old }
}

# The mirrorlists pacman actually reads, and only those. Globbing etc/pacman.d/mirrorlist.*
# also finds .orig and .pacnew copies that nothing loads, so pinning would rewrite files
# with no effect and verification would report a pinned guest as unpinned.
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
        # Delete it. A rejected installer left in TEMP is one careless double-click away
        # from being run by hand, which is the whole thing the check exists to prevent.
        Remove-Item $exe -Force -EA SilentlyContinue
        throw ("MSYS2 installer hash mismatch for $Version" +
               "`n  expected $($Sha256.ToLower())" +
               "`n  got      $got" +
               "`n  Nothing was installed and the download was deleted. Either the pin is" +
               " stale - pass -Version and -Sha256 together to move it - or this is not the" +
               " file it claims to be.")
    }
    Write-Host "  $Version, sha256 matches the pin ($([math]::Round((Get-Item $exe).Length/1MB,1)) MB)"

    # --- install headlessly ----------------------------------------------------------
    # The installer is a Qt Installer Framework binary; `in` is its non-interactive
    # install verb. Start-Process -Wait because it returns before finishing otherwise.
    Write-Host "installing to $Msys..."
    $p = Start-Process -FilePath $exe -ArgumentList @('in', '--confirm-command',
            '--accept-messages', '--root', $Msys) -Wait -PassThru -NoNewWindow
    if ($p.ExitCode -ne 0) { throw "the MSYS2 installer exited $($p.ExitCode)" }
    Remove-Item $exe -Force -EA SilentlyContinue
    if (-not (Test-Path $bash)) { throw "no bash at $bash after installing" }
}

if (-not (Test-Path $bash)) { throw "MSYS2 is not installed at $Msys (run without -VerifyOnly)" }

# --- pin every mirrorlist, before the first sync --------------------------------------
$pinned = @()
if (-not $VerifyOnly) {
    foreach ($p in Get-IncludedMirrorlist) {
        $lines = Get-Content $p
        $out = foreach ($l in $lines) {
            if ($l -match '^\s*Server\s*=' -and $l -notmatch [regex]::Escape($Mirror)) {
                # Commented rather than deleted, so what was dropped is still readable.
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

    Write-Host 'first sync (twice: the first can update pacman itself and stop)...'
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

# Every Server line that survived must name the pinned host. One that does not is a mirror
# pacman may dial that the policy will refuse, at some later and less obvious moment.
#
# Only the files pacman.conf actually Includes are checked. Globbing mirrorlist.* instead
# picks up .orig and .pacnew copies that pacman never reads, and reports a pinned guest as
# unpinned - 58 stray mirrors, all of them in backups nothing loads. What is enforced is
# what is Included; that is the list worth checking.
$stray = @()
$included = @(Get-IncludedMirrorlist)
if (-not $included.Count) { $stray += 'pacman.conf Includes no mirrorlist at all' }
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
