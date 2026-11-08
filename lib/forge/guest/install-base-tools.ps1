# install-base-tools.ps1: the Unix toolchain of the default base image.
#
# Run this IN THE GUEST, after MSYS2 exists and the tunnel is up. All comes from
# the pinned MSYS2 repository that the `base` kit already allows. Thus the
# install needs no policy change (Draugr docs/FORGE.md, "The default base").
#
# The list is short, on purpose: tools that an agent or a person wants in almost
# each session, and the ones that this design named. Tools for one engine, one
# account, or one project belong in a layer, not here.
#
# Two things that tests found the hard way:
#   - **stdin must be closed.** Through ssh, there is no terminal. Each pacman question that
#     --noconfirm does not cover then blocks forever, with no output, no CPU, and nothing in
#     the log but the command line. `< /dev/null` makes that hang an error that you can read.
#   - **The native packages of MSYS2 are UCRT64 now.** Thus the prefix is
#     `mingw-w64-ucrt-x86_64-`, not `mingw-w64-x86_64-`, and the binaries go to /ucrt64/bin.
#     The old names report "target not found".
#
# Measured cost: MSYS2 grew from 439 MB to 487 MB, so 48 MB for the whole set.
#
#   powershell -ExecutionPolicy Bypass -File .\install-base-tools.ps1            # install and verify
#   powershell -ExecutionPolicy Bypass -File .\install-base-tools.ps1 -VerifyOnly
param(
    [string]$Msys = 'C:\msys64',
    [switch]$VerifyOnly
)

$ErrorActionPreference = 'Continue'

# msys packages: POSIX builds, as a shell session wants.
$msysPkgs = @(
    'git',                      # projects have versions. git is the replication path
    'rsync',                    # artifacts and logs without a share
    'openssh',                  # keys, ssh-keygen, scp
    'curl', 'wget',             # downloads through the gateway proxy
    'unzip', 'zip', 'p7zip',    # assets arrive as archives
    'jq',                       # .uproject is JSON. jq sets EngineAssociation
    'diffutils', 'patch',       # compare and patch configuration between engine versions
    'make',                     # build glue
    'openssl',                  # hashes and certificates
    'less', 'file', 'tree', 'nano'   # the minimum for a person who looks around through ssh
)
# Native Windows builds, for tools that walk Windows paths fast.
$ucrtPkgs = @(
    'mingw-w64-ucrt-x86_64-ripgrep',
    'mingw-w64-ucrt-x86_64-fd'
)

$bash = Join-Path $Msys 'usr\bin\bash.exe'
if (-not (Test-Path $bash)) { throw "no MSYS2 bash at $bash" }

# Always `< /dev/null`. See the header. `du`, not Get-ChildItem -Recurse, which
# takes minutes on an MSYS2 tree and tells nothing more. The redirect puts the
# whole command in a subshell, on purpose. "< /dev/null" at the end of a
# PIPELINE applies only to its LAST stage. Thus with `foo | head -1`, head reads
# /dev/null, and the code reports each tool as missing. The first version gave
# exactly that false result.

# Add-ToMachinePath: put a directory on the MACHINE PATH, once, JUST BEFORE
# System32.
#
# Not at the end and not at the start, but at an exact position. MSYS2 ships
# find.exe and sort.exe that hide the Windows ones. That is the PURPOSE, because
# people want the GNU versions. It also ships link.exe, which hides the linker
# of MSVC. That one can cause damage.
#
# A TEST SHOWED THIS, and it is why the start of PATH is safe. With
# C:\msys64\usr\bin FIRST, and then a run of vcvars64.bat, `where link` answers
#   C:\...\MSVC\14.38.33130\bin\Hostx64\x64\link.exe      <- MSVC, first
#   C:\msys64\usr\bin\link.exe
# because vcvars PUTS the toolchain directory at the START. UnrealBuildTool is
# safe in both cases, because it resolves the toolchain with an absolute path.
# The other case is a bare `link` outside a developer prompt, and there nothing
# expects MSVC.
#
# IT ALSO HIDES curl.exe, and that cost a broken test. A TEST SHOWED THIS. With
# this directory on PATH, a bare `curl.exe` in the guest is the CYGWIN build.
# Cygwin removes the braces from `-w '%{http_code}'` before curl sees them. Thus
# preflight.ps1 compared the literal string '%http_code' with '000', and always
# reported egress OK. It now names C:\Windows\System32\curl.exe with an absolute
# path. This block implies that rule for each other script: if the OUTPUT FORMAT
# matters, name the binary.
#
# BUT NOT AT THE VERY START, because MSYS2 also ships ssh.exe, scp.exe, and
# ssh-keygen.exe. A TEST SHOWED THIS. At the start, `ssh` resolved to
# C:\msys64\usr\bin\ssh.exe, not to the Windows OpenSSH client. The MSYS2 client
# reads key paths, HOME, and known_hosts with POSIX semantics. All else in this
# project (the host tunnel, the own sshd of the guest, each script here) is
# Windows OpenSSH. One ssh that works differently from the others inside the
# guest is a trap for later.
#
# Thus: insert directly BEFORE the System32 entry. MSYS2 still wins over Windows
# for find and sort. All entries that are on purpose before System32 still win,
# and the OpenSSH directory is there. If System32 is not on PATH, something is
# already very wrong, and the start of PATH is the safe fallback.
#
# Windows builds PATH as MACHINE, then USER. Thus all that this adds also comes
# before the entries of the user, also %USERPROFILE%\.local\bin. MSYS2 ships no
# python.exe, so it cannot hide the interpreter that install-automation.ps1 puts
# there.
#
# THE SAME AS THE COPY IN install-automation.ps1, ON PURPOSE. Each guest script
# here goes into the guest alone, and runs alone. A shared helper file makes
# "copy one file, run it" false, and both need this one. If you change one,
# change both.
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
# 387 installed executables with none of them on PATH are almost as useless as
# no install. A TEST SHOWED THIS. A finished base image had git, make, rsync,
# perl, bash, curl, tar, and unzip, and not one of them resolved as a command.
if (-not $VerifyOnly) {
    Write-Host ''
    Write-Host 'PATH'
    [void](Add-ToMachinePath (Join-Path $Msys 'usr\bin'))
}

# Test by a RUN of each tool, not by a question to pacman. A package that is
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
# Reported, not judged. This script can run before a reboot, and the PATH that
# it just set reaches only new processes. Thus a "missing" here is about this
# session, not about the machine.
$onPath = ([Environment]::GetEnvironmentVariable('Path', 'Machine') -split ';') |
          Where-Object { $_.TrimEnd('\') -ieq (Join-Path $Msys 'usr\bin').TrimEnd('\') }
Write-Host ("  {0,-9} {1}" -f 'PATH', $(if ($onPath) { "$Msys\usr\bin is on the machine PATH" }
                                        else { 'NOT on the machine PATH' }))
Write-Host ''
Write-Host 'all tools are present and run.' -ForegroundColor Green
