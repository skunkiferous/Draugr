#!/usr/bin/env bash
# lint-native-stderr.sh - find redirected native stderr that Stop will make fatal.
#
# THE RULE: in a PowerShell script, while $ErrorActionPreference is 'Stop', a native
# command's stderr must not be redirected - not with 2>$null, not with 2>&1 - unless
# the preference is dropped for the length of the call.
#
# WHY, measured in the guest, Stop in force, the task absent:
#
#   schtasks /query /tn draugr-shot /fo list 2>$null     -> THREW, NativeCommandError
#   Get-ScheduledTask -TaskName draugr-shot -EA Silently -> $null, no error
#
# PowerShell 5.1 wraps each line a native command writes to a REDIRECTED stderr as a
# NativeCommandError, and Stop makes that terminating. Unredirected stderr passes
# through harmlessly, so the redirection is the whole defect.
#
# What it cost: install-shot.ps1 asked schtasks whether its task already existed, in
# order to register it only when ABSENT. schtasks writes "ERROR: The system cannot
# find the file specified." to stderr for a task that is not there - so the guard
# whose only job was to notice absence threw whenever the task was absent, which is
# every first install. The phase reported FAILED with half its work done, and the
# same shape sat unreached in install-automation.ps1 - a file that already carried a
# comment explaining this trap, next to the one call it had guarded.
#
# THREE FILES HAD EACH LEARNED IT SEPARATELY (mount-vault.ps1, install-netfx3.ps1,
# install-vscode.ps1 all carry their own save/restore) and the knowledge never became
# a rule, so new instances kept being written. That is what this script is for.
#
# THE TWO FIXES, in order of preference:
#
#   1. Do not ask a native command a question a cmdlet answers. Get-ScheduledTask
#      instead of schtasks /query; Get-Service instead of sc query. No redirection,
#      no guard, nothing to drift.
#   2. When the native command IS the right tool - and when its stderr is wanted,
#      which is often why it was redirected - drop the preference around the call:
#
#          $eapWas = $ErrorActionPreference
#          $ErrorActionPreference = 'Continue'
#          try { $out = & thing.exe -args 2>&1 } finally { $ErrorActionPreference = $eapWas }
#
#      provision.ps1 wraps that in `Invoke-Native { ... }`, which this script knows
#      about and accepts.
#
#   ./tests/lint-native-stderr.sh                  everything CI checks - use this one
#   ./tests/lint-native-stderr.sh lib/forge/x.ps1  just these files
set -euo pipefail

status=0

# With no arguments, every .ps1 this project ships - and the list lives here rather
# than in .github/workflows/ci.yml for the reason lint-comments.sh gives: one list,
# so a bare local run checks exactly what CI checks.
if [ $# -eq 0 ]; then
    root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
    set -- "$root"/lib/forge/*.ps1 "$root"/lib/forge/guest/*.ps1
fi

for f in "$@"; do
    [ -f "$f" ] || continue
    awk -v file="$f" '
        # PowerShell starts at Continue, so that is where tracking starts. Anything
        # this script cannot resolve is NOT treated as Stop: a linter that guesses
        # Stop would report files it has not understood, and nobody trusts those.
        FNR == 1 { pref = "Continue"; inhere = 0; natdepth = 0 }

        # --- here-strings are DATA, not code ---------------------------------------
        # install-shot.ps1 writes a whole second script out of an @'...'@ body, and
        # that body contains its own $ErrorActionPreference = Stop and its own
        # redirections. Reading them as this file`s code tracks the wrong state and
        # judges lines that are generated text. Inside a single-quoted here-string
        # PowerShell parses nothing at all, so neither does this: once in, the only
        # thing looked for is the terminator, which closes the NESTED @" bodies
        # correctly by ignoring them.
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

        # --- the preference, as it stands at this line ------------------------------
        # A save/restore pair is resolved rather than given up on: $x = $EAP records
        # what was in force, and $EAP = $x puts that back. Without this every guarded
        # call would leave the tracker stuck on Continue for the rest of the file,
        # and every real finding below it would be missed.
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
        # provision.ps1 defines it; its blocks span continuation lines, so the brace
        # depth is carried rather than the line matched.
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
        # >nul 2>&1 is cmd syntax, which only ever appears in generated .cmd text, and
        # 2>&1 inside a bash -lc string is bash`s own. Neither is PowerShell`s.
        {
            hit = (pref == "Stop" && !inside_native && line ~ /2>\$null|2>&1/ &&
                   line !~ />nul[[:space:]]*2>&1/)
            if (hit) {
                printf "%s:%d: native stderr redirected with $ErrorActionPreference = Stop in force\n          %s\n",
                       file, FNR, substr(line, 1, 96) > "/dev/stderr"
                bad++
            }
        }

        # --- a RESTORE is applied after the line has been judged --------------------
        # Deliberately last, and it is the difference between a useful linter and one
        # that cries wolf. `try { & x 2>&1 } finally { $EAP = $was }` is a correct
        # guard written on ONE line, which three files in this project use - and
        # applying its restore before judging the line puts Stop back in force and
        # reports all three. A set to a literal still happens BEFORE the check, so
        # `$EAP = Continue; & x 2>&1` on one line is accepted too. Each assignment is
        # applied at the point where it describes what the call actually ran under.
        /\$ErrorActionPreference[[:space:]]*=[[:space:]]*\$[A-Za-z_]/ {
            v = $0
            sub(/^.*\$ErrorActionPreference[[:space:]]*=[[:space:]]*\$/, "", v)
            sub(/[^A-Za-z0-9_].*$/, "", v)
            pref = (v in saved) ? saved[v] : "Unknown"
        }
        END { exit (bad > 0) }
    ' "$f" || status=1
done

# Said once after the list: what a reader needs is the fix, not one copy of the
# reasoning per line.
if [ "$status" -ne 0 ]; then
    printf '\n'
    printf 'Each line above turns any stderr the command writes into a terminating\n' >&2
    printf 'error. Prefer a cmdlet that answers the same question; otherwise drop the\n' >&2
    printf 'preference around the call, or use provision.ps1 style Invoke-Native. The\n' >&2
    printf 'header of this script has the measurement, docs/FORGE.md the rule.\n' >&2
fi
exit "$status"
