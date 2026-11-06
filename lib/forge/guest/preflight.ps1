# preflight.ps1 - refuse to start a long job when the VM has no way out.
#
# ==> RUN BY lib/forge/provision.ps1, IN THE GUEST. Can also be run by hand. <==
#
# Run it before Unreal, Visual Studio or a build. The VM has no adapter of its own: every
# request leaves through 127.0.0.1:3128, which is the reverse tunnel lib/forge/tunnel.ps1
# holds open into the gateway mound. When that path is down the tools do not fail
# fast - the launcher sits on a spinner, a build fetches half a dependency and stops - so one
# request first is much cheaper than finding out an hour in.
#
# What the codes mean (measured):
#   000  curl got no answer at all: no tunnel, or no tinyproxy behind it
#   500  tinyproxy answered and refused: the gateway is up, but its policy or DNS said no
#   any other code, 403 included, means the request reached the site and the path works
#
# EXIT CODES: 0 egress proved, 1 no egress, 3 the probe itself is broken so egress is
# UNPROVED - a distinction that matters, because 3 is this project's fault and 1 is not.
#
#   powershell -ExecutionPolicy Bypass -File .\preflight.ps1 [-Url https://www.unrealengine.com/] [-Proxy 127.0.0.1:3128]

param([string]$Url = 'https://www.unrealengine.com/',
      [string]$Proxy = '127.0.0.1:3128')

# WINDOWS' OWN CURL, BY ABSOLUTE PATH. MEASURED, in a guest with the base tools
# installed, both curls given the same -w '%{http_code}' against the same URL:
#
#   C:\Windows\System32\curl.exe   (Windows 8.18.0)  ->  500      a real code
#   C:\msys64\usr\bin\curl.exe      (Cygwin 8.22.0)   ->  %http_code
#
# The Cygwin build eats the BRACES out of the format string, because Cygwin does its own
# argv processing before main() sees it. And bare `curl.exe` resolves to that build, because
# install-base-tools.ps1 puts C:\msys64\usr\bin on the machine PATH just before System32 -
# a decision whose own comment reasons carefully about find, sort, link and ssh, and does
# not mention curl.
#
# WHAT THAT COST, and it is the reason this is spelled out at length: $code was the literal
# string '%http_code', which is neither '000' nor '500', so the test below could never
# match and this script reported EGRESS OK WHATEVER HAPPENED - including against a proxy on
# port 9. provision.ps1's phase 6 exits 5 when this fails, to stop an hour of downloads
# before they start; that guard was dead from the moment MSYS2 reached the PATH.
#
# -o NUL is a second reason to be explicit: to Cygwin, NUL is an ordinary filename, so the
# Cygwin build would quietly write a file called NUL into the working directory.
$curl = Join-Path $env:SystemRoot 'System32\curl.exe'
if (-not (Test-Path $curl)) {
    Write-Host "preflight: no curl at $curl, so egress cannot be proved here." -ForegroundColor Red
    Write-Host '  Windows 11 ships it; a guest without it is not one this script can check.'
    exit 3
}
$code = & $curl -s -x "http://$Proxy" -o NUL -w '%{http_code}' --max-time 25 $Url

# THE ANSWER IS CHECKED FOR SHAPE BEFORE IT IS BELIEVED. Three digits or the probe itself
# is broken - which is a different thing from no egress, and must not be reported as one.
# Without this, any future change that stops -w producing a code goes back to passing
# silently, which is exactly how this script spent its whole life so far.
if ($code -notmatch '^[0-9]{3}$') {
    Write-Host "preflight: THE PROBE IS BROKEN, so egress is unproved." -ForegroundColor Red
    Write-Host "  curl was asked for %{http_code} and answered '$code', which is not a status code."
    Write-Host "  That is this script's fault, not the gateway's. $curl"
    exit 3
}

if ($code -eq '000' -or $code -eq '500') {
    Write-Host "preflight: NO EGRESS ($Url through $Proxy returned $code)" -ForegroundColor Red
    Write-Host "  on the host, from the project that names this forge:"
    Write-Host "    dr-forge up        # the gateway mound, the VM, then the tunnel, in order"
    Write-Host "  or, to see which link is down without starting anything:"
    Write-Host "    dr-forge doctor"
    exit 1
}

Write-Host "preflight: egress OK ($Url returned $code through $Proxy)" -ForegroundColor Green
exit 0
