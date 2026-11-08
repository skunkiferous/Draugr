#!/usr/bin/env bash
# lint-native-stderr.sh: find redirected native stderr that Stop makes fatal.
#
# THE RULE: in a PowerShell script, while $ErrorActionPreference is 'Stop', do
# not redirect the stderr of a native command, not with 2>$null, and not with
# 2>&1. The only exception: the preference is off for the time of the call.
#
# WHY, from a test in the guest, with Stop in force and the task absent:
#
#   schtasks /query /tn draugr-shot /fo list 2>$null     -> THREW, NativeCommandError
#   Get-ScheduledTask -TaskName draugr-shot -EA Silently -> $null, no error
#
# PowerShell 5.1 wraps each line that a native command writes to a REDIRECTED
# stderr as a NativeCommandError, and Stop makes that a terminating error.
# Stderr with no redirect passes through with no harm. Thus the redirect is the
# full defect.
#
# What it cost: install-shot.ps1 asked schtasks whether its task already
# existed, to register it only when ABSENT. For a missing task, schtasks writes
# "ERROR: The system cannot find the file specified." to stderr. Thus the guard,
# whose only job was to see absence, threw at each absence of the task. That is
# each first install. The phase reported FAILED with half its work done.
# install-automation.ps1 had the same shape, not yet reached. That file already
# had a comment about this trap, next to the one call that it guarded.
#
# THREE FILES EACH LEARNED IT SEPARATELY (mount-vault.ps1, install-netfx3.ps1,
# and install-vscode.ps1 all have their own save/restore). The knowledge never
# became a rule, so people continued to write new cases. This script is for
# that.
#
# THE TWO FIXES, in order of preference:
#
#   1. Do not ask a native command a question that a cmdlet answers. Use
#      Get-ScheduledTask, not schtasks /query. Use Get-Service, not sc query. No
#      redirect, no guard, nothing to drift.
#   2. When the native command IS the right tool, and you want its stderr (often
#      the reason for the redirect), turn off the preference around the call:
#
#          $eapWas = $ErrorActionPreference
#          $ErrorActionPreference = 'Continue'
#          try { $out = & thing.exe -args 2>&1 } finally { $ErrorActionPreference = $eapWas }
#
#      provision.ps1 wraps that in `Invoke-Native { ... }`. This script knows it,
#      and accepts it.
#
#   ./tests/lint-native-stderr.sh                  all that CI tests. Use this one
#   ./tests/lint-native-stderr.sh lib/forge/x.ps1  only these files
set -euo pipefail

status=0

# With no arguments, each .ps1 that this project ships. The list is here, not in
# .github/workflows/ci.yml, for the reason in lint-comments.sh: one list, so
# that a bare local run tests exactly what CI tests.
if [ $# -eq 0 ]; then
    root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
    set -- "$root"/lib/forge/*.ps1 "$root"/lib/forge/guest/*.ps1
fi

for f in "$@"; do
    [ -f "$f" ] || continue
    awk -v file="$f" '
        # PowerShell starts at Continue, so the tracking starts there. If this
        # script cannot resolve something, it does NOT take it as Stop. A linter
        # that guesses Stop reports files that it did not understand, and nobody
        # trusts those.
        FNR == 1 { pref = "Continue"; inhere = 0; natdepth = 0 }

        # --- here-strings are DATA, not code ---------------------------------------
        # install-shot.ps1 writes a full second script from an @'...'@ body.
        # That body has its own $ErrorActionPreference = Stop and its own
        # redirects. A read of them as code of this file tracks the wrong state,
        # and judges generated text. In a single-quoted here-string, PowerShell
        # parses nothing, so this does not either. Inside, it looks only for the
        # terminator. That correctly closes the NESTED @" bodies, because it
        # ignores them.
        inhere == 1 {
            if ($0 ~ ("^" hereend)) { inhere = 0 }
            next
        }
        /@['"'"'"][[:space:]]*$/ {
            hereend = ($0 ~ /@'"'"'[[:space:]]*$/) ? "'"'"'@" : "\"@"
            inhere = 1; next
        }

        # --- comments say nothing about what runs -----------------------------------
        { line = $0; sub(/^[[:space:]]+/, "", line) }
        substr(line, 1, 1) == "#" { next }

        # --- the preference at this line ------------------------------------------
        # A save/restore pair is resolved, not ignored. $x = $EAP records the
        # value in force, and $EAP = $x puts it back. Without this, each guarded
        # call leaves the tracker on Continue for the rest of the file, and each
        # real finding below it is missed.
        /\$[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=[[:space:]]*\$ErrorActionPreference[[:space:]]*$/ {
            v = $0
            sub(/^[[:space:]]*\$/, "", v); sub(/[[:space:]]*=.*$/, "", v)
            saved[v] = pref
        }
        /\$ErrorActionPreference[[:space:]]*=[[:space:]]*.(Stop|Continue|SilentlyContinue|Inquire|Ignore)./ {
            match($0, /(Stop|Continue|SilentlyContinue|Inquire|Ignore)/)
            pref = substr($0, RSTART, RLENGTH)
        }
        # --- Invoke-Native { ... } is the guard, named ------------------------------
        # provision.ps1 defines it. Its blocks cross continuation lines, so this
        # keeps the brace depth, and does not match the line.
        {
            depth = 0
            n = split($0, ch, "")
            for (i = 1; i <= n; i++) {
                if (ch[i] == "{") depth++
                else if (ch[i] == "}") depth--
            }
            opens_native = ($0 ~ /Invoke-Native[[:space:]]*\{/)
            inside_native = (natdepth > 0 || opens_native)
            natdepth += (opens_native || natdepth > 0) ? depth : 0
            if (natdepth < 0) natdepth = 0
        }

        # --- the finding ------------------------------------------------------------
        # >nul 2>&1 is cmd syntax, which appears only in generated .cmd text.
        # 2>&1 in a bash -lc string belongs to bash. Neither belongs to
        # PowerShell.
        {
            hit = (pref == "Stop" && !inside_native && line ~ /2>\$null|2>&1/ &&
                   line !~ />nul[[:space:]]*2>&1/)
            if (hit) {
                printf "%s:%d: native stderr redirected with $ErrorActionPreference = Stop in force\n          %s\n",
                       file, FNR, substr(line, 1, 96) > "/dev/stderr"
                bad++
            }
        }

        # --- a RESTORE applies after the line is judged -----------------------------
        # Last, on purpose. That is the difference between a useful linter and
        # one with false alarms. `try { & x 2>&1 } finally { $EAP = $was }` is a
        # correct guard on ONE line, and three files in this project use it. If
        # its restore applies before the judgment of the line, Stop is back in
        # force, and all three are reported. A set to a literal still happens
        # BEFORE the test. Thus `$EAP = Continue; & x 2>&1` on one line is also
        # accepted. Each assignment applies at the point where it describes the
        # real state of the call.
        /\$ErrorActionPreference[[:space:]]*=[[:space:]]*\$[A-Za-z_]/ {
            v = $0
            sub(/^.*\$ErrorActionPreference[[:space:]]*=[[:space:]]*\$/, "", v)
            sub(/[^A-Za-z0-9_].*$/, "", v)
            pref = (v in saved) ? saved[v] : "Unknown"
        }
        END { exit (bad > 0) }
    ' "$f" || status=1
done

# Said once after the list. A reader needs the fix, not one copy of the reason
# on each line.
if [ "$status" -ne 0 ]; then
    printf '\n'
    printf 'Each line above makes each stderr line of the command a terminating\n' >&2
    printf 'error. Prefer a cmdlet that answers the same question. If not, turn off the\n' >&2
    printf 'preference around the call, or use Invoke-Native as in provision.ps1. The\n' >&2
    printf 'header of this script has the test result. docs/FORGE.md has the rule.\n' >&2
fi
exit "$status"
