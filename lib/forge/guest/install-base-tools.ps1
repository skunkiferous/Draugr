# install-base-tools.ps1 - the default base image's Unix toolchain.
#
# Run this IN THE GUEST, after MSYS2 exists and the tunnel is up. Everything comes
# from the pinned MSYS2 repository the `base` kit already allows, so installing it
# needs no policy change (Draugr docs/FORGE.md, "The default base").
#
# The list is deliberately short: tools an agent or a human wants in almost any
# session, plus the ones this design named specifically. Anything engine-specific,
# account-specific or project-specific belongs in a layer, not here.
#
# Two things measured the hard way:
#   - **stdin must be closed.** Over ssh there is no terminal, and any pacman prompt
#     that --noconfirm does not cover then blocks forever with no output, no CPU and
#     nothing in the log but the command line. `< /dev/null` turns that hang into an
#     error you can read.
#   - **MSYS2's native packages are UCRT64 now**, so the prefix is
#     `mingw-w64-ucrt-x86_64-`, not `mingw-w64-x86_64-`, and the binaries land in
#     /ucrt64/bin. The old names simply report "target not found".
#
# Measured cost: MSYS2 grew from 439 MB to 487 MB - 48 MB for the whole set.
#
#   powershell -ExecutionPolicy Bypass -File .\install-base-tools.ps1            # install and verify
#   powershell -ExecutionPolicy Bypass -File .\install-base-tools.ps1 -VerifyOnly
param(
    [string]$Msys = 'C:\msys64',
    [switch]$VerifyOnly
)

$ErrorActionPreference = 'Continue'

# msys packages: POSIX builds, which is what a shell session wants.
$msysPkgs = @(
    'git',                      # projects are versioned; git is the replication path
    'rsync',                    # artifacts and logs without a share
    'openssh',                  # keys, ssh-keygen, scp
    'curl', 'wget',             # fetching through the gateway proxy
    'unzip', 'zip', 'p7zip',    # assets arrive as archives
    'jq',                       # .uproject is JSON - this is how EngineAssociation is set
    'diffutils', 'patch',       # comparing and patching config between engine versions
    'make',                     # build glue
    'openssl',                  # hashes and certificates
    'less', 'file', 'tree', 'nano'   # the minimum for a human looking around over ssh
)
# Native Windows builds, for tools that walk Windows paths at speed.
$ucrtPkgs = @(
    'mingw-w64-ucrt-x86_64-ripgrep',
    'mingw-w64-ucrt-x86_64-fd'
)

$bash = Join-Path $Msys 'usr\bin\bash.exe'
if (-not (Test-Path $bash)) { throw "no MSYS2 bash at $bash" }

# Always `< /dev/null`: see the header. `du` rather than Get-ChildItem -Recurse,
# which takes minutes over an MSYS2 tree and tells you nothing extra.
# The redirect wraps the whole command in a subshell on purpose. Appending
# "< /dev/null" to a PIPELINE redirects only its LAST stage, so `foo | head -1`
# would leave head reading /dev/null and report every tool missing - which is
# exactly the false result the first version produced.
# Add-ToMachinePath - put a directory on the MACHINE PATH, once, JUST BEFORE System32.
#
# Not appended and not prepended: positioned. MSYS2 ships find.exe and sort.exe that
# shadow the Windows ones, which is the POINT - the GNU versions are what anyone wants -
# and link.exe, which shadows MSVC's linker and is the one that could hurt.
#
# MEASURED, which is why prepending is safe: with C:\msys64\usr\bin placed
# FIRST and then vcvars64.bat run, `where link` answers
#   C:\...\MSVC\14.38.33130\bin\Hostx64\x64\link.exe      <- MSVC, first
#   C:\msys64\usr\bin\link.exe
# because vcvars PREPENDS the toolchain directory itself. UnrealBuildTool is safe either
# way: it resolves the toolchain by absolute path. The residual case is a bare `link`
# outside a developer prompt, where nothing should expect MSVC anyway.
#
# AND IT SHADOWS curl.exe TOO, which cost a dead verification. MEASURED: with
# this directory on PATH, bare `curl.exe` in the guest is the CYGWIN build, and Cygwin eats
# the braces out of `-w '%{http_code}'` before curl sees them. preflight.ps1 was therefore
# comparing the literal string '%http_code' against '000' and reporting egress OK whatever
# happened. It now names C:\Windows\System32\curl.exe by absolute path, which is the rule
# this block implies for every other script: if the OUTPUT FORMAT matters, name the binary.
#
# BUT NOT AT THE VERY FRONT, because MSYS2 also ships ssh.exe, scp.exe and ssh-keygen.exe.
# MEASURED: prepending made `ssh` resolve to C:\msys64\usr\bin\ssh.exe instead
# of the Windows OpenSSH client, and MSYS2's client reads key paths, HOME and known_hosts
# with POSIX semantics. Everything else in this project - the host tunnel, the guest's own
# sshd, every script here - is Windows OpenSSH, and one ssh behaving differently from the
# others inside the guest is a trap laid for later.
#
# So: insert immediately BEFORE the System32 entry. MSYS2 still outranks Windows for find
# and sort, and anything deliberately placed ahead of System32 - which is where the
# OpenSSH directory sits - keeps winning. If System32 is not on PATH at all, something is
# already very wrong, and prepending is the harmless fallback.
#
# Windows composes PATH as MACHINE then USER, so anything added here also precedes the
# per-user entries - including %USERPROFILE%\.local\bin. MSYS2 ships no python.exe, so it
# cannot shadow the interpreter install-automation.ps1 puts there.
#
# IDENTICAL TO THE COPY IN install-automation.ps1, DELIBERATELY. Every guest script here
# is copied into the guest alone and run alone, so a shared helper file would make "copy
# one file, run it" false - and this one is needed by both. Change one, change both.
function Add-ToMachinePath([string]$Dir, [string]$Before = "$env:SystemRoot\system32") {
    $cur = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $parts = @($cur -split ';' | Where-Object { $_ })
    $norm = $parts | ForEach-Object { $_.TrimEnd('\').ToLower() }
    if ($norm -contains $Dir.TrimEnd('\').ToLower()) {
        Write-Host "  PATH already has $Dir"
        return $false
    }
    $at = [Array]::IndexOf($norm, $Before.TrimEnd('\').ToLower())
    if ($at -lt 0) { $at = 0 }
    $new = @()
    if ($at -gt 0) { $new += $parts[0..($at - 1)] }
    $new += $Dir
    $new += $parts[$at..($parts.Count - 1)]
    [Environment]::SetEnvironmentVariable('Path', ($new -join ';'), 'Machine')
    Write-Host "  PATH += $Dir (machine, just before $Before)"
    return $true
}

function Invoke-Msys([string]$cmd) { & $bash -lc "( $cmd ) < /dev/null" 2>&1 }
function Get-MsysMb { (Invoke-Msys "du -sm /c/msys64 2>/dev/null | cut -f1" | Select-Object -First 1) }

if (-not $VerifyOnly) {
    Write-Host "MSYS2 before: $(Get-MsysMb) MB"
    foreach ($set in @(@{ n = 'msys'; p = $msysPkgs }, @{ n = 'ucrt64'; p = $ucrtPkgs })) {
        Write-Host ''
        Write-Host "installing $($set.n) packages..."
        $list = $set.p -join ' '
        $out = Invoke-Msys "timeout 600 pacman -S --needed --noconfirm --disable-download-timeout $list"
        $out | Where-Object { $_ -match 'error|warning:|target not found' } |
            ForEach-Object { Write-Host "  $_" -ForegroundColor Yellow }
        Write-Host "  done"
    }
    Write-Host ''
    Write-Host "MSYS2 after : $(Get-MsysMb) MB"
}

# --- and make them REACHABLE ----------------------------------------------------------
# Installing 387 executables and leaving none of them on PATH is most of the way to not
# having installed them. MEASURED: a finished base image had git, make, rsync,
# perl, bash, curl, tar and unzip all present and not one of them resolvable as a command.
if (-not $VerifyOnly) {
    Write-Host ''
    Write-Host 'PATH'
    [void](Add-ToMachinePath (Join-Path $Msys 'usr\bin'))
}

# Verify by RUNNING each tool, not by asking pacman what it installed: a package
# recorded as present is not the same as a binary that starts.
Write-Host ''
Write-Host '--- verification ---'
$checks = [ordered]@{
    'git' = 'git --version'; 'rsync' = 'rsync --version | head -1'
    'ssh' = 'ssh -V 2>&1 | head -1'; 'curl' = 'curl --version | head -1'
    'wget' = 'wget --version | head -1'; 'unzip' = 'unzip -v | head -1'
    'zip' = 'zip -v 2>&1 | sed -n 2p'; '7z' = '7z i 2>&1 | sed -n 2p'
    'jq' = 'jq --version'; 'diff' = 'diff --version | head -1'
    'patch' = 'patch --version | head -1'; 'make' = 'make --version | head -1'
    'openssl' = 'openssl version'; 'less' = 'less --version | head -1'
    'file' = 'file --version | head -1'; 'tree' = 'tree --version'
    'nano' = 'nano --version | head -1'
    'rg' = '/ucrt64/bin/rg --version | head -1'
    'fd' = '/ucrt64/bin/fd --version'
}
$missing = @()
foreach ($name in $checks.Keys) {
    $out = Invoke-Msys $checks[$name] | Where-Object { $_ } | Select-Object -First 1
    if (-not $out) {
        Write-Host ("  {0,-9} MISSING" -f $name) -ForegroundColor Red
        $missing += $name
    } else {
        Write-Host ("  {0,-9} {1}" -f $name, ($out -replace '\s+', ' ').Trim())
    }
}
Write-Host ''
if ($missing.Count) { Write-Host "MISSING: $($missing -join ', ')" -ForegroundColor Red; exit 1 }
# Reported rather than judged: this script may be run before a reboot, and the PATH it
# just set reaches new processes only - so a "missing" here would be about this session
# rather than about the machine.
$onPath = ([Environment]::GetEnvironmentVariable('Path', 'Machine') -split ';') |
          Where-Object { $_.TrimEnd('\') -ieq (Join-Path $Msys 'usr\bin').TrimEnd('\') }
Write-Host ("  {0,-9} {1}" -f 'PATH', $(if ($onPath) { "$Msys\usr\bin is on the machine PATH" }
                                        else { 'NOT on the machine PATH' }))
Write-Host ''
Write-Host 'all tools present and runnable.' -ForegroundColor Green
