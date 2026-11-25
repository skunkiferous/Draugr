#!/usr/bin/env bats
# Facts about the repository itself, not about its code.
#
# These tests exist because of a failure that is not visible locally. The
# project is developed on /mnt/c. There, git sets core.filemode=false, and thus
# ignores the executable bit of the filesystem. A new script runs well on the
# machine of the developer. It arrives on Linux as mode 100644, which is not
# executable. CI then dies with status 126, and nothing before CI says anything.
#
# It reached CI three times. The first version of this test missed the third. It
# read `git ls-files`, which lists only files in the index, and a new command is
# untracked. Thus this test walks the FILESYSTEM and asks git about each file.
# It finds a file that is not staged, and also a file staged with the wrong
# mode.

load helper

# The list is in tests/executable-paths.sh, not here. It has two consumers, and
# they must always agree. If one of these files is not executable, this test
# fails the build, and .githooks/pre-commit fixes it before the commit. That
# script explains WHICH files are on the list.
want_executable() {
    "$DR_ROOT/tests/executable-paths.sh"
}

@test "every script that must be executable will arrive executable" {
    git -C "$DR_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
        || skip "not a git work tree"

    local f rel mode untracked= wrongmode=
    while read -r f; do
        [ -f "$f" ] || continue
        rel=${f#"$DR_ROOT"/}

        # Field 1 of ls-files -s is the mode. Empty output means that git does
        # not know this path. A commit of it now stores 100644.
        mode=$(git -C "$DR_ROOT" ls-files -s -- "$rel" | awk '{print $1}')
        if [ -z "$mode" ]; then
            untracked="$untracked $rel"
        elif [ "$mode" != 100755 ]; then
            wrongmode="$wrongmode $rel"
        fi
    done < <(want_executable)

    [ -z "$untracked$wrongmode" ] && return 0

    # One message, with the exact commands, because the fix is hard to remember,
    # and the reason for it is a surprise.
    printf 'These will not be executable when checked out on Linux:\n' >&2
    for rel in $untracked;  do printf '  %-28s (not staged yet)\n' "$rel" >&2; done
    for rel in $wrongmode;  do printf '  %-28s (staged as 100644)\n' "$rel" >&2; done
    printf '\nFix with:\n' >&2
    [ -n "$untracked" ] && printf '  git add%s\n' "$untracked" >&2
    printf '  git update-index --chmod=+x%s%s\n' "$untracked" "$wrongmode" >&2
    printf '\ncore.filemode is false here, so chmod alone will NOT do it and git add\n' >&2
    printf 'will NOT pick it up - the mode lives only in the index.\n' >&2
    return 1
}

@test "the mode check is actually looking at something" {
    # A guard on the guard. If the paths above match no file, the test passes
    # because it finds nothing. We are then back at the start, but with a green
    # tick.
    [ "$(want_executable | wc -l)" -ge 10 ]
}

@test "every dr-* command has a matching entry in the README" {
    # The README is the specification. Thus a command with no documentation is a
    # gap in the specification, not a bonus.
    # Accept both `dr-data` and `dr-data status`. A command documented through
    # its subcommands is documented. The trailing character class makes the
    # difference. A bare `grep "\`$cmd\`"` needs the closing backtick at once,
    # and reports a false gap for each command that takes a verb.
    local cmd missing=
    for cmd in "$DR_ROOT"/bin/dr-*; do
        cmd=${cmd##*/}
        grep -qE "\`$cmd[\` ]" "$DR_ROOT/README.md" || missing="$missing $cmd"
    done
    [ -z "$missing" ] || {
        printf 'not documented in README.md:%s\n' "$missing" >&2
        return 1
    }
}

# The hook is the half of this that runs in time, so it is tested as all other
# code is. A fake repository, not this one, because the assertion is about what
# `git add` records. Here, that makes the index of the repo under test dirty.
@test "the pre-commit hook sets the bit that git add cannot" {
    local fake="$BATS_TEST_TMPDIR/fake"
    mkdir -p "$fake/bin" "$fake/tests" "$fake/.githooks"
    cp "$DR_ROOT/tests/executable-paths.sh" "$fake/tests/"
    cp "$DR_ROOT/.githooks/pre-commit" "$fake/.githooks/"
    chmod +x "$fake/tests/executable-paths.sh" "$fake/.githooks/pre-commit"
    printf '#!/usr/bin/env bash\ntrue\n' > "$fake/bin/dr-thing"

    git -C "$fake" init -q -b main
    git -C "$fake" config user.email t@example.com
    git -C "$fake" config user.name T
    # The condition that causes the bug: git ignores the executable bit of the
    # filesystem, exactly as it does on /mnt/c.
    git -C "$fake" config core.fileMode false
    git -C "$fake" add -A

    [ "$(git -C "$fake" ls-files -s -- bin/dr-thing | awk '{print $1}')" = 100644 ]
    ( cd "$fake" && ./.githooks/pre-commit >/dev/null 2>&1 )
    [ "$(git -C "$fake" ls-files -s -- bin/dr-thing | awk '{print $1}')" = 100755 ]
}

# A listed file that is not staged belongs to a different commit. If the hook
# adds it, the commit holds a file that the author did not ask for.
@test "the pre-commit hook leaves an unstaged script alone" {
    local fake="$BATS_TEST_TMPDIR/fake2"
    mkdir -p "$fake/bin" "$fake/tests" "$fake/.githooks"
    cp "$DR_ROOT/tests/executable-paths.sh" "$fake/tests/"
    cp "$DR_ROOT/.githooks/pre-commit" "$fake/.githooks/"
    chmod +x "$fake/tests/executable-paths.sh" "$fake/.githooks/pre-commit"
    printf '#!/usr/bin/env bash\ntrue\n' > "$fake/bin/dr-unstaged"

    git -C "$fake" init -q -b main
    git -C "$fake" config user.email t@example.com
    git -C "$fake" config user.name T
    ( cd "$fake" && ./.githooks/pre-commit >/dev/null 2>&1 )

    [ -z "$(git -C "$fake" ls-files -s -- bin/dr-unstaged)" ]
}

# If the script does not replace a placeholder, a live nginx configuration gets
# the literal text "@FOO@". nginx rejects it, or, worse, accepts it as a
# hostname. The test is fast, and it needs no nginx.
@test "every placeholder in the ollama-proxy template is substituted by the script" {
    local tmpl="$DR_ROOT/share/ollama-proxy/nginx.conf.template"
    local script="$DR_ROOT/share/ollama-proxy/ollama-proxy"
    [ -f "$tmpl" ] || skip "no ollama-proxy template"

    local ph missing=()
    while read -r ph; do
        [ -n "$ph" ] || continue
        grep -qF "{conf//$ph/" "$script" || missing+=("$ph")
    done < <(grep -oE '@[A-Z_]+@' "$tmpl" | sort -u)

    if [ ${#missing[@]} -gt 0 ]; then
        printf 'in the template but never substituted by the script:\n' >&2
        printf '  %s\n' "${missing[@]}" >&2
        return 1
    fi
}

# --- the kits that this repository ships ------------------------------------
#
# Two of these are templates that dr-forge WRITES into a generated gateway, so
# their format is not a matter of taste: sbx 0.53 refuses a v2 kit at create,
# and dr-up removes a mound before it tries to create one. A v2 file here is a
# gateway that cannot be built, and a recreate that cannot come back.
#
# This is not hypothetical. The migration to v3 covered kit/ and kits/unreal/
# and missed kits/base/, and nothing anywhere said so for weeks.

@test "every gateway kit that Draugr ships is v3" {
    local k bad=()
    for k in "$DR_ROOT"/share/gateway.example/kit/spec.yaml \
             "$DR_ROOT"/share/gateway.example/kits/*/spec.yaml; do
        [ -f "$k" ] || continue
        grep -q '^schemaVersion: "3"' "$k" || bad+=("${k#$DR_ROOT/}")
    done

    # The glob covers a kit that somebody adds later, which is the case that a
    # list of three names misses.
    if [ ${#bad[@]} -gt 0 ]; then
        printf 'dr-forge writes these into a gateway, and they are not v3:\n' >&2
        printf '  %s\n' "${bad[@]}" >&2
        return 1
    fi
}

@test "the two kit examples keep their formats, which are a deliberate pair" {
    # share/kit.example is v2 ON PURPOSE. dr-init writes whichever format the
    # sbx of this machine reads, so an older sbx still needs the v2 spelling.
    # A well-meant migration of that file breaks every such machine, and
    # a migration of the v3 one leaves current sbx with nothing.
    grep -q '^schemaVersion: "2"' "$DR_ROOT/share/kit.example/spec.yaml"
    grep -q '^schemaVersion: "3"' "$DR_ROOT/share/kit-v3.example/spec.yaml"
}

@test "no script backgrounds a compound list in a command sent to a mound" {
    # `cmd1 || cmd2 &` backgrounds the LIST, so bash forks a subshell, and that
    # subshell waits for whatever cmd2 started. When the list travels through
    # `sbx exec`, the exec waits for that subshell and never returns: dr-up then
    # hangs for ever, with the work already done and nothing to see.
    #
    # That is not a theory. The post-up hook of the gateway had
    #   pgrep -x tinyproxy >/dev/null || setsid tinyproxy -d … &
    # and three measured runs on sbx 0.53 timed out at 45 s and 66 s, while the
    # same script with an `if` answered in 1 s. Only a SIMPLE command may be
    # backgrounded. An `if` costs two lines and cannot do this.
    # The pattern, and why each piece is there. `[^;]*` and NOT `[^&|]*`: the
    # real line ends in `2>&1 &`, so a class that forbids `&` cannot reach the
    # final one, and the first version of this test MISSED the exact line it
    # was written for. `;` stays forbidden, because `a && b; c &` backgrounds
    # only `c`, which is safe. `[^&]&$` is a lone trailing `&`, not `&&`.
    local hits
    hits=$(grep -rnE '(\|\||&&)[^;]*[^&]&[[:space:]]*$' \
               "$DR_ROOT"/bin/* "$DR_ROOT"/lib/*.sh "$DR_ROOT"/lib/*/*.sh \
               "$DR_ROOT"/share/*/hooks/* "$DR_ROOT"/.githooks/* 2>/dev/null || true)

    if [ -n "$hits" ]; then
        printf 'a backgrounded compound list, which holds an sbx exec open:\n' >&2
        printf '%s\n' "$hits" >&2
        return 1
    fi
}

# --- the one command this repository must never hold -------------------------
#
# MEASURED, and the reason this test exists rather than a note in a review.
# The signature of Defender, Trojan:PowerShell/Killav.VDA, matches the TEXT of a
# real-time-protection-off command, in ANY file, and does not care whether
# anything ever runs it. On this project it quarantined the session transcript
# of an agent that had merely READ such a line out of lib/forge/guest/, a data
# file that nothing executes. The signature is right about what the line does.
#
# Thus the rule covers the whole repository, docs and comments included. A doc
# is scanned exactly like a script, and an agent copies what it reads into
# logs, patches and transcripts that this project does not control. dr-forge
# READS the state of Defender and reports it. The person makes the change by
# hand, in Windows Security. See docs/CONFIG.md, DRAUGR_FORGE_NOSCAN.
@test "no file in the repository writes to Defender, docs and comments included" {
    cd "$DR_ROOT" || return 1
    # Assembled from pieces on purpose. A test that spelled the names out matches
    # itself, and is also one more copy of the thing it keeps out.
    pat="(Set|Add|Remove)-Mp""Preference|Mp""CmdRun|Disable""Realtime""Monitoring"
    # Tracked files only, which is exactly what this project publishes.
    run git grep -n -I -E -i -- "$pat"
    # git grep says 1 for "no match", and that is the pass. A reader of Get-
    # MpPreference or Get-MpComputerStatus is fine: those only look.
    [ "$status" -eq 1 ]
    [ -z "$output" ]
}

# --- the cure is a location, and not a permission ----------------------------
#
# A MECHANISM, NOT A RULE SOMEBODY HAS TO REMEMBER. Hardening 5 of the security
# review says "validate Windows ACLs", and the other reading of it (repair them)
# was declined: a Windows permission that gets in the way is something the
# owner of the machine resets so that they can carry on, which makes it a poor
# thing to rest a guarantee on, and trusted state is on a Windows drive in the
# first place only because DRAUGR_CONFIG_HOME was pointed at one. So Draugr
# reports and names a location to move the file to. docs/SECURITY.md, "Where the
# trust record itself can live", is where that is written for a reader. This is
# what keeps it true, because a decision that lives only in prose gets proposed
# again as a convenience.
#
# SCOPE, and why it is not the whole repository like the test above. The forge
# sets two ACLs, in PowerShell: ssh REFUSES a private key that other accounts
# can read, and the guest needs a plaintext password on disk. Those are the requirement
# of a third party and a documented trade-off (docs/FORGE.md), not a claim of
# Draugr. Thus the rule covers every shell surface (bin/ and every .sh) and
# the pathspec excludes tests/, which has to name the commands to keep them out.
@test "no shell command sets a Windows permission: the cure is a location" {
    cd "$DR_ROOT" || return 1
    run git grep -n -I -E -i -- 'icacls|Set-Acl|takeown' -- bin '*.sh' ':!tests'
    # git grep says 1 for "no match", and that is the pass.
    [ "$status" -eq 1 ]
    [ -z "$output" ]
}

# --- what is allowed to enter a guest, and on whose word ------------------------------
#
# A MECHANISM, NOT A RULE SOMEBODY HAS TO REMEMBER, like the two guards above.
# Hardening 4 of the security review asks for pinned versions. Its CI half
# pinned `actions/checkout` to a commit. This is the guest half.
#
# What it was. `install-automation.ps1` fetched https://astral.sh/uv/install.ps1
# and handed the text to Invoke-Expression, and separately read the
# version.txt of a vendor and installed whatever it named. So a base layer built on two
# mornings from the same sources can hold two different uvs and two different
# AutoHotkeys, and the bytes of neither were ever compared with anything. The
# forge seals base layers and reuses them, so "the same layer" has to mean it.
#
# The two rules below are what the fix rests on, and both are cheap to keep.
# They are a source check and not a behavior test ON PURPOSE: the behavior
# needs a disposable Windows guest, which needs AppSandbox.exe and admin, and
# this project never raises that on behalf of anybody. The guest run is the
# run of the user, and these keep the shape true in the meantime.

@test "no PowerShell in this repository executes text that it downloaded" {
    cd "$DR_ROOT" || return 1
    # Comment lines are excluded because the comment of the fix itself names the call it
    # removed. The clearest way to stop it coming back is to say what it was.
    # `iex` needs the non-letter guards or it matches words that contain it.
    run bash -c "git grep -n -I -E -- 'Invoke-Expression|[^A-Za-z-]iex[^A-Za-z-]' -- '*.ps1' \
                 | grep -vE ':[[:space:]]*#'"
    # grep says 1 for "nothing left after the filter", and that is the pass.
    [ "$status" -eq 1 ]
    [ -z "$output" ]
}

@test "every guest installer that downloads a file checks it against a pin" {
    cd "$DR_ROOT" || return 1
    # The invariant: if a script writes a download to disk (-OutFile), it also
    # hashes it, COMPARES that hash with the pin, and refuses.
    #
    # The first draft of this test asked only for Get-FileHash, and that is a
    # hole worth recording: a hash computed and then ignored passes such a test.
    # All three installers already share one shape, so the comparison itself is
    # checkable, and the throw after it is what makes the comparison mean
    # something.
    local f unchecked=()
    for f in lib/forge/guest/*.ps1; do
        grep -q -- '-OutFile' "$f" || continue
        grep -q 'Get-FileHash' "$f"                            || { unchecked+=("$f: no Get-FileHash"); continue; }
        grep -qF '$got -ne $Sha256.ToLower()' "$f"              || { unchecked+=("$f: hashes, never compares"); continue; }
        grep -A 6 -F '$got -ne $Sha256.ToLower()' "$f" | grep -q 'throw' \
            || unchecked+=("$f: compares, never refuses")
    done
    # The guard on the guard: if the loop matched nothing, this test passes by
    # finding nothing, which is the failure mode the mode check above has too.
    [ "$(grep -l -- '-OutFile' lib/forge/guest/*.ps1 | wc -l)" -ge 3 ]
    if [ ${#unchecked[@]} -gt 0 ]; then
        printf 'downloads a file and never hashes it:\n' >&2
        printf '  %s\n' "${unchecked[@]}" >&2
        return 1
    fi
}

@test "the pins of install-automation.ps1 are a version and a hash, in pairs" {
    cd "$DR_ROOT" || return 1
    # Both halves of each pin, in the param block, because a version raised
    # without its hash is the one mistake that fails late: it downloads, and
    # then throws at the end of a long guest run.
    local f=lib/forge/guest/install-automation.ps1 k
    for k in UvVersion UvSha256 AhkVersion AhkSha256; do
        grep -qE "^\s*\[string\]\\\$$k\s*=" "$f" || { printf 'no pin for %s\n' "$k" >&2; return 1; }
    done
    # A hash is 64 hex characters. A truncated or placeholder one is caught here
    # rather than by a mismatch inside a guest.
    [ "$(grep -cE "^\s*\[string\]\\\$(Uv|Ahk)Sha256\s*=\s*'[0-9a-f]{64}'" "$f")" -eq 2 ]
}
