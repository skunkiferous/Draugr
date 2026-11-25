#!/usr/bin/env bats
# dr-doctor: the report that answers "is this machine set up".
#
# These tests are about the shared skills store, and about the LEVEL of each
# line. The store is machine-wide: one directory, mounted into each mound of
# each project, for both agents, holding instructions that an agent loads and
# mostly trusts. Two facts about it belong in this report, and they are not the
# same kind of fact:
#
#   a change nobody reviewed     a warning. Every mound reads it
#   a shipped skill not installed  a NOTE. Draugr never installs them unasked
#
# The second one is why `note` exists. With `soft`, the verdict says
# "Ready, with 1 warning(s)" for ever on a machine whose owner declined an
# optional feature, and that teaches people to ignore the colour.

load helper

setup() {
    dr_test_setup
    REPO=$(dr_make_win_repo) || skip "no writable path under /mnt/<drive> on this machine"
    cd "$REPO" || return 1
    export DR_MOCK_NAME="draugr-$(basename "$REPO")"
    dr_fake_sbx_root          # sets DRAUGR_SBX and DR_SKILLS_DIR, both throwaway
}

teardown() { dr_test_teardown; }

# One skill in the store that Draugr did not ship, as `sbx skills import` or
# another agent leaves it.
foreign_skill() {
    mkdir -p "$DR_SKILLS_DIR/somebody-else"
    printf -- '---\nname: somebody-else\ndescription: not from Draugr\n---\n\nbody\n' \
        > "$DR_SKILLS_DIR/somebody-else/SKILL.md"
}

@test "dr-doctor: an empty store has nothing to review, and says so" {
    run dr-doctor
    [[ "$output" == *"skills store"* ]]
    [[ "$output" == *"empty"* ]]
    [[ "$output" != *"a change is not reviewed"* ]]
}

@test "dr-doctor: a change nobody reviewed is a warning, with both commands" {
    foreign_skill
    run dr-doctor
    [[ "$output" == *"a change is not reviewed"* ]]
    [[ "$output" == *"dr-skills diff"* ]]
    [[ "$output" == *"dr-skills accept"* ]]
    # The level: a warning, because every mound reads the store.
    [[ "$output" == *"! skills store"* ]]
}

@test "dr-doctor: once accepted, the store is a tick and not a warning" {
    foreign_skill
    dr-skills accept -y >/dev/null 2>&1
    run dr-doctor
    [[ "$output" == *"skills store"* ]]
    [[ "$output" == *"reviewed"* ]]
    [[ "$output" != *"a change is not reviewed"* ]]
}

@test "dr-doctor: a shipped skill that is missing is a note, never a warning" {
    run dr-doctor
    [[ "$output" == *"draugr skills"* ]]
    [[ "$output" == *"0 of"* ]]
    [[ "$output" == *"dr-skills install"* ]]
    # This is the whole reason for the third level. A warning here does not
    # go away for somebody who does not want the skills.
    [[ "$output" == *"· draugr skills"* ]]
    [[ "$output" != *"! draugr skills"* ]]
}

@test "dr-doctor --quiet: a note is not a problem, so it is hidden" {
    run dr-doctor --quiet
    [[ "$output" != *"draugr skills"* ]]
}

@test "dr-doctor: with every shipped skill installed, it stops advising" {
    dr-skills install -y >/dev/null 2>&1
    run dr-doctor
    [[ "$output" == *"draugr skills"* ]]
    [[ "$output" != *"dr-skills install"* ]]
    # install re-baselines the store, so that half is quiet too.
    [[ "$output" != *"a change is not reviewed"* ]]
}

@test "dr-doctor: the count follows what the checkout ships, not a fixed number" {
    # A skill added in a later version must show as missing, and not stay
    # invisible because somebody wrote the number in the code.
    local shipped=0 d
    for d in "$DR_ROOT"/share/skills/*/; do [ -d "$d" ] && shipped=$((shipped + 1)); done
    [ "$shipped" -gt 1 ]
    run dr-doctor
    [[ "$output" == *"0 of $shipped in the store"* ]]
}

# --- the trust file, which decides what Draugr will run ---------------------------------
#
# A line in it tells Draugr to SOURCE a .draugr.conf, and to source a file is to
# run it. So "who can write this file" is "who decides what Draugr runs". The
# mode that is supposed to answer that is inert on a Windows drive (measured -
# see the block in tests/config.bats), and the file is written so RARELY that a
# warning at dr-trust time is read once, months before it matters. Hence a
# standing row here.
#
# AND THE LEVEL IS A FAILURE, not a warning and not a note. The two softer
# levels exist for a change nobody reviewed and for a feature you declined; this
# is neither.

@test "dr-doctor: a private trust file is one green row" {
    printf 'deadbeef  /nowhere/.draugr.conf\n' > "$DRAUGR_CONFIG_HOME/trusted"
    chmod 600 "$DRAUGR_CONFIG_HOME/trusted"
    run dr-doctor
    [[ "$output" == *"Trusted state"* ]]
    [[ "$output" == *"private to you"* ]]
    [[ "$output" == *"1 line(s)"* ]]
}

@test "dr-doctor: a trust file that is not private is a failure" {
    printf 'deadbeef  /nowhere/.draugr.conf\n' > "$DRAUGR_CONFIG_HOME/trusted"
    chmod 644 "$DRAUGR_CONFIG_HOME/trusted"
    run dr-doctor
    [[ "$output" == *"644"* ]]
    [[ "$output" == *"SOURCE a .draugr.conf"* ]]
    # The red mark, and not the yellow one or the dot.
    [[ "$output" == *"✗ trust file"* ]]
}

# No trust file is the state of a fresh machine. Nothing is trusted, which is
# the safe end of the scale, so it counts nothing.
@test "dr-doctor: no trust file at all is a note, not a failure" {
    rm -f "$DRAUGR_CONFIG_HOME/trusted"
    run dr-doctor
    [[ "$output" == *"none yet"* ]]
    [[ "$output" != *"✗ trust file"* ]]
}

# dr-doctor REPORTS, and a chmod is a write. A command you run to look at the
# state may not alter the state it is showing you - which is why the question
# and the chmod are two functions.
@test "dr-doctor: reporting on the trust file does not change its mode" {
    printf 'deadbeef  /nowhere/.draugr.conf\n' > "$DRAUGR_CONFIG_HOME/trusted"
    chmod 644 "$DRAUGR_CONFIG_HOME/trusted"
    run dr-doctor
    [ "$(stat -c %a "$DRAUGR_CONFIG_HOME/trusted")" = 644 ]
}

# --- what a 0.0.0.0 bind inside WSL reaches ---------------------------------
#
# dr-doctor is the report half of hardening 3; the two reporters behind it are
# tested in tests/hostport.bats. These tests are about the LEVEL, and about one
# sentence that must never appear: on a host whose networking Draugr did not
# establish, nobody may be told that the bind stays off the LAN.

# wsl_profile <text>: that text as the .wslconfig of this machine, reached
# through the USERPROFILE that dr-doctor resolves. It needs a /mnt/<letter>
# path, because dr_path_from_win maps the Windows spelling back to exactly one.
#
# The root comes from $REPO and NOT from $DR_WIN_TMP: setup captures the repo
# with REPO=$(dr_make_win_repo), and a command substitution is a subshell, so
# the export of DR_WIN_TMP inside it never reaches this shell. With the empty
# variable the path was "/profile", every test here skipped, and seven skips
# read as seven passes.
wsl_profile() {
    local dir drive rest
    dir="$(dirname "$REPO")/profile"
    case "$dir" in /mnt/?/*) ;; *) skip "the fixture root is not under /mnt/<letter>" ;; esac
    mkdir -p "$dir"
    printf '%s' "$1" > "$dir/.wslconfig"
    drive=${dir#/mnt/}
    drive=${drive%%/*}
    rest=${dir#/mnt/?}
    export USERPROFILE="${drive^^}:$(printf '%s' "$rest" | tr '/' '\\')"
}

@test "dr-doctor: a host on NAT is told the bind stays off the LAN" {
    wsl_profile '[wsl2]
networkingMode=nat
'
    run dr-doctor
    [[ "$output" == *"✓ 0.0.0.0 inside WSL"* ]]
    [[ "$output" == *"not the LAN"* ]]
    [[ "$output" == *"networkingMode: nat"* ]]
}

@test "dr-doctor: mirrored with nothing opened is a note, not a warning" {
    # Draugr exposes nothing on such a machine. A warning here is the false
    # colour that teaches people to ignore the real one.
    wsl_profile '[wsl2]
networkingMode=mirrored
'
    run dr-doctor
    [[ "$output" == *"· 0.0.0.0 inside WSL"* ]]
    [[ "$output" == *"is also on your LAN"* ]]
    [[ "$output" != *"not the LAN"* ]] || return 1
}

@test "dr-doctor: mirrored with a host port open is a warning" {
    # Now something of yours is meant to listen, and the LAN can reach it.
    export DRAUGR_HOST_PORTS=11435
    wsl_profile '[wsl2]
networkingMode=mirrored
'
    run dr-doctor
    [[ "$output" == *"! 0.0.0.0 inside WSL"* ]]
    [[ "$output" == *"is also on your LAN"* ]]
}

@test "dr-doctor: a mode Draugr will not vouch for is reported, not assumed" {
    # The whole point of the batch: an unestablished answer must not arrive as
    # the reassuring one.
    wsl_profile '[wsl2]
networkingMode=consomme
'
    run dr-doctor
    [[ "$output" == *"· 0.0.0.0 inside WSL"* ]]
    [[ "$output" == *"did not establish what it reaches"* ]]
    [[ "$output" == *"networkingMode: consomme"* ]]
    [[ "$output" != *"not the LAN"* ]] || return 1
}

@test "dr-doctor: an unestablished mode with a host port open is a warning too" {
    # The same level rule as the mirrored line. On a WSL host cmd.exe is there,
    # so this answer means consomme or a key in the wrong section, and both are
    # worth your attention while something of yours is listening.
    export DRAUGR_HOST_PORTS=11435
    wsl_profile '[wsl2]
networkingMode=consomme
'
    run dr-doctor
    [[ "$output" == *"! 0.0.0.0 inside WSL"* ]]
    [[ "$output" == *"did not establish what it reaches"* ]]
    [[ "$output" != *"not the LAN"* ]] || return 1
}

@test "dr-doctor: a networkingMode in the wrong section is reported, not ignored" {
    wsl_profile '[experimental]
networkingMode=mirrored
'
    run dr-doctor
    [[ "$output" == *"did not establish what it reaches"* ]]
    [[ "$output" != *"not the LAN"* ]] || return 1
}

@test "dr-doctor: no portproxy rule is a green line" {
    wsl_profile '[wsl2]
networkingMode=nat
'
    run dr-doctor
    [[ "$output" == *"✓ netsh portproxy"* ]]
    [[ "$output" == *"no rules"* ]]
}

@test "dr-doctor: a portproxy rule is named, whatever the networking mode says" {
    # The second way the same claim breaks, and it is independent of the mode.
    export DRAUGR_HOST_PORTS=11435 DR_MOCK_PORTPROXY=rules
    wsl_profile '[wsl2]
networkingMode=nat
'
    run dr-doctor
    [[ "$output" == *"! netsh portproxy"* ]]
    [[ "$output" == *"line(s) of rules"* ]]
}

# --- the state alias of sbx ---------------------------------------------------
#
# sbx reaches its state through a junction named sboxd-<hash>. When that is
# gone, or a plain directory stands in its place, no mound starts. The real case
# reported "could not locate the context of the agent", and nothing pointed at
# sbx. The daemon names the alias in its own log, so the fixture is that log
# line, plus whatever stands at the alias path. WSL shows a junction as a symlink
# to its target, so a symlink is a faithful stand-in for one.
#
# The alias goes beside the repo, in the Windows-drive scratch directory, which
# teardown removes. rm -rf there does not follow the link into $STATE.
alias_fixture() {
    STATE="$DR_TMP/sbxroot/sandboxes/state/sandboxd"
    mkdir -p "$STATE/containerd"
    ALIAS="$(dirname "$REPO")/alias/sboxd-0a1b2c3d"
    mkdir -p "$(dirname "$ALIAS")"
    ALIAS_WIN=$(. "$DR_ROOT/lib/common.sh" && dr_path_win "$ALIAS") || return 1
    alias_log_line "$ALIAS_WIN"
}

# One ordinary line that names an alias, as the daemon writes at each start.
# jq doubles the backslashes, as the real JSON does.
alias_log_line() {
    jq -cn --arg p "$1\\containerd\\root\\io.containerd.snapshotter.v1.erofs" \
        '{time:"t",level:"WARN",msg:"failed check for fsverity support",path:$p}' \
        >> "$STATE/daemon.log"
}

@test "dr-doctor: a junction to the state of sbx is a green line" {
    alias_fixture || skip "no Windows spelling for the scratch path"
    ln -s "$STATE" "$ALIAS"
    run dr-doctor
    [[ "$output" == *"✓ sbx state alias"* ]]
    [[ "$output" == *"a junction to its state"* ]]
}

@test "dr-doctor: a plain directory in place of the alias is a failure, with a safe fix" {
    alias_fixture || skip "no Windows spelling for the scratch path"
    # What the failed start left on the real machine: a stub tree, no link.
    mkdir -p "$ALIAS/containerd/root"
    run dr-doctor
    [ "$status" -eq 1 ]
    [[ "$output" == *"✗ sbx state alias"* ]]
    [[ "$output" == *"is not a junction"* ]]
    # The fix names the path, and deletes with rm, which never follows a link.
    [[ "$output" == *"rm -r $ALIAS"* ]]
    [[ "$output" == *"sbx daemon stop"* ]]
    [[ "$output" == *"sbx cannot find its own files"* ]]
}

@test "dr-doctor: a daemon that a broken alias stops is sent to the alias, not the hypervisor" {
    alias_fixture || skip "no Windows spelling for the scratch path"
    mkdir -p "$ALIAS/containerd/root"
    export DR_MOCK_FAIL=ls
    run dr-doctor
    [[ "$output" == *"✗ sandbox daemon"* ]]
    [[ "$output" == *"The cause is the state alias"* ]]
    [[ "$output" != *"Hypervisor Platform"* ]] || return 1
}

@test "dr-doctor: an alias that is gone while the daemon runs is a failure" {
    # The state of the real case: the running mounds did not notice, and each
    # start after it failed.
    alias_fixture || skip "no Windows spelling for the scratch path"
    run dr-doctor
    [ "$status" -eq 1 ]
    [[ "$output" == *"✗ sbx state alias"* ]]
    [[ "$output" == *"is gone, while the daemon runs"* ]]
    [[ "$output" == *"sbx daemon stop"* ]]
}

@test "dr-doctor: no alias while the daemon is down is normal, and the daemon line keeps its advice" {
    # The daemon makes the junction when it starts. A daemon that does not start
    # for another reason must keep the advice that is about that reason.
    alias_fixture || skip "no Windows spelling for the scratch path"
    export DR_MOCK_FAIL=ls
    run dr-doctor
    [[ "$output" == *"✓ sbx state alias"* ]]
    [[ "$output" == *"none yet"* ]]
    [[ "$output" == *"Hypervisor Platform"* ]]
}

@test "dr-doctor: an alias that links to another directory is a failure" {
    alias_fixture || skip "no Windows spelling for the scratch path"
    mkdir -p "$DR_TMP/another-state"
    ln -s "$DR_TMP/another-state" "$ALIAS"
    run dr-doctor
    [[ "$output" == *"✗ sbx state alias"* ]]
    [[ "$output" == *"points to another directory"* ]]
    [[ "$output" == *"rm $ALIAS"* ]]
}

@test "dr-doctor: a daemon log that names no alias is a note, never a tick" {
    # Nothing was measured, so nothing may look measured. A 2 is not a 0.
    STATE="$DR_TMP/sbxroot/sandboxes/state/sandboxd"
    mkdir -p "$STATE"
    printf '%s\n' '{"time":"t","level":"INFO","msg":"nothing about paths"}' > "$STATE/daemon.log"
    run dr-doctor
    [[ "$output" == *"sbx state alias"* ]]
    [[ "$output" == *"not checked"* ]]
    [[ "$output" != *"✓ sbx state alias"* ]] || return 1
    [[ "$output" != *"✗ sbx state alias"* ]] || return 1
}

@test "dr_sbx_state_alias: the LAST alias that the log names is the one checked" {
    # A daemon restart can move the alias. The newest line is the daemon that
    # runs now. An older line names a path where nothing stands.
    alias_fixture || skip "no Windows spelling for the scratch path"
    ln -s "$STATE" "$ALIAS"
    : > "$STATE/daemon.log"
    alias_log_line "${ALIAS_WIN%\\*}\\sboxd-11111111"
    alias_log_line "$ALIAS_WIN"
    run env DR_ROOT="$DR_ROOT" bash -c '. "$DR_ROOT/lib/common.sh" && dr_sbx_state_alias running'
    [ "$status" -eq 0 ]
    [ "$output" = "junction $ALIAS_WIN" ]
}
