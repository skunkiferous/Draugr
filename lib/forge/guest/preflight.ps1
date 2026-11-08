# preflight.ps1: refuse to start a long job on a VM with no way out.
#
# ==> lib/forge/provision.ps1 RUNS IT, IN THE GUEST. You can also run it yourself. <==
#
# Run it before Unreal, Visual Studio, or a build. The VM has no own adapter.
# Each request leaves through 127.0.0.1:3128, the reverse tunnel that
# lib/forge/tunnel.ps1 holds open into the gateway mound. When that path is
# down, the tools do not fail fast. The launcher shows a spinner, and a build
# fetches half a dependency and stops. Thus one request first is much cheaper
# than a discovery after an hour.
#
# The meaning of the codes (from tests):
#   000  curl got no answer: no tunnel, or no tinyproxy behind it
#   500  tinyproxy answered and refused: the gateway runs, but its policy or DNS said no
#   each other code, also 403, means that the request reached the site, and the path works
#
# EXIT CODES: 0 egress proved, 1 no egress, 3 the probe is broken, so egress is
# NOT PROVED. The difference is important, because 3 is a fault of this project,
# and 1 is not.
#
#   powershell -ExecutionPolicy Bypass -File .\preflight.ps1 [-Url https://www.unrealengine.com/] [-Proxy 127.0.0.1:3128]

param([string]$Url = 'https://www.unrealengine.com/',
      [string]$Proxy = '127.0.0.1:3128')

# THE OWN CURL OF WINDOWS, WITH AN ABSOLUTE PATH. A TEST in a guest with the
# base tools installed, both curls with the same -w '%{http_code}' and the same
# URL:
#
#   C:\Windows\System32\curl.exe   (Windows 8.18.0)  ->  500      a real code
#   C:\msys64\usr\bin\curl.exe      (Cygwin 8.22.0)   ->  %http_code
#
# The Cygwin build removes the BRACES from the format string, because Cygwin
# processes argv before main() sees it. A bare `curl.exe` resolves to that
# build, because install-base-tools.ps1 puts C:\msys64\usr\bin on the machine
# PATH directly before System32. The comment of that decision is careful about
# find, sort, link, and ssh, and does not name curl.
#
# THE COST, and the reason for this long text: $code was the literal string
# '%http_code'. That is not '000' and not '500', so the test below never
# matched. Thus this script always reported EGRESS OK, also with port 9 as the
# proxy. If this fails, phase 6 of provision.ps1 exits 5, to stop an hour of
# downloads before they start. That guard was dead from the time that MSYS2 came
# on the PATH.
#
# -o NUL is a second reason for the explicit path. For Cygwin, NUL is an
# ordinary file name. Thus the Cygwin build silently writes a file called NUL
# into the working directory.
$curl = Join-Path $env:SystemRoot 'System32\curl.exe'
if (-not (Test-Path $curl)) {
    Write-Host "preflight: no curl at $curl, so this script cannot prove egress here." -ForegroundColor Red
    Write-Host '  Windows 11 ships it. This script cannot test a guest without it.'
    exit 3
}
$code = & $curl -s -x "http://$Proxy" -o NUL -w '%{http_code}' --max-time 25 $Url

# THE CODE TESTS THE FORM OF THE ANSWER BEFORE IT BELIEVES IT. Three digits, or
# the probe is broken. That is different from no egress, and must not be
# reported as no egress. Without this, a future change that stops the code from
# -w passes silently again. That is exactly how this script lived until now.
if ($code -notmatch '^[0-9]{3}$') {
    Write-Host "preflight: THE PROBE IS BROKEN, so egress is not proved." -ForegroundColor Red
    Write-Host "  curl got a request for %{http_code}, and answered '$code'. That is not a status code."
    Write-Host "  That is a fault of this script, not of the gateway. $curl"
    exit 3
}

if ($code -eq '000' -or $code -eq '500') {
    Write-Host "preflight: NO EGRESS ($Url through $Proxy returned $code)" -ForegroundColor Red
    Write-Host "  on the host, from the project that names this forge:"
    Write-Host "    dr-forge up        # the gateway mound, the VM, then the tunnel, in order"
    Write-Host "  or, to see which link is down, and start nothing:"
    Write-Host "    dr-forge doctor"
    exit 1
}

Write-Host "preflight: egress OK ($Url returned $code through $Proxy)" -ForegroundColor Green
exit 0
