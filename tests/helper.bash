# shellcheck shell=bash
# Shared setup for the bats suites.

DR_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export DR_ROOT
export PATH="$DR_ROOT/tests/mocks:$DR_ROOT/bin:$PATH"

# Point the sbx search at the mock, and keep each test out of the real
# ~/.config/draugr. Thus a run can never trust something on the machine of the
# developer.
dr_test_setup() {
    DR_TMP=$(mktemp -d)
    export DR_TMP
    export DRAUGR_SBX="$DR_ROOT/tests/mocks/sbx"
    export DRAUGR_CONFIG_HOME="$DR_TMP/config"
    export DR_MOCK_LOG="$DR_TMP/sbx.log"
    export HOME="$DR_TMP/home"
    mkdir -p "$HOME" "$DRAUGR_CONFIG_HOME"
    : > "$DR_MOCK_LOG"
    # A custom fixture root can be inside a checkout. Plain-directory tests
    # must never discover or write the enclosing real repository.
    local fixture_root
    if fixture_root=$(dr_win_root 2>/dev/null); then
        export GIT_CEILING_DIRECTORIES="$fixture_root${GIT_CEILING_DIRECTORIES:+:$GIT_CEILING_DIRECTORIES}"
    fi
}

dr_test_teardown() {
    [ -n "${DR_TMP:-}" ] && [ -d "$DR_TMP" ] && rm -rf "$DR_TMP"

    # The Windows-drive scratch directory is outside $TMPDIR, so nothing else
    # cleans it. Its name COMES FROM $DR_TMP, and is not kept in a variable,
    # because each caller writes
    #
    #     REPO=$(dr_make_win_repo)
    #
    # A command substitution is a subshell. An `export` in it never reaches
    # this function. That is how 5311 directories collected under C:\Temp
    # before somebody looked: about thirty for each test run, silently.
    if [ -n "${DR_WIN_TMP:-}" ] && [ -d "$DR_WIN_TMP" ]; then
        rm -rf "$DR_WIN_TMP"
    elif [ -n "${DR_TMP:-}" ]; then
        local root
        root=$(dr_win_root 2>/dev/null) && rm -rf "$root/draugr-test.${DR_TMP##*/}"
    fi
    return 0
}

# A throwaway git repo. It is NOT under a real /mnt/<drive>/ path, so it fails
# dr_require_win_path, on purpose. Unit tests test the path translation against
# literal strings. Thus those tests can run on each OS.
dr_make_repo() {
    local name=${1:-testrepo}
    local dir="$DR_TMP/$name"
    mkdir -p "$dir"
    git -C "$dir" init -q -b main
    git -C "$dir" config user.email test@example.com
    git -C "$dir" config user.name Test
    printf 'hello\n' > "$dir/README.md"
    git -C "$dir" add -A
    git -C "$dir" commit -qm "first"
    printf '%s' "$dir"
}

# Source common.sh in the current shell, for unit-testing its functions.
dr_load_common() {
    # shellcheck source=../lib/common.sh
    . "$DR_ROOT/lib/common.sh"
}

# --- a terminal ---------------------------------------------------------------
#
# dr-go and dr-shell refuse to start without one, so a test of what they send
# needs a pty. `script -qec "$*" /dev/null` was the way, and a mound has no
# `script`: it lives in bsdextrautils, which the base image of sbx leaves out.
# That cost 32 tests in a mound, on a tool that is not the thing they test.
#
# tests/pty_run.py does the same with python3, which the mound, CI and WSL all
# have, and which CI already installs by name. One mechanism in each place, so
# no branch here runs in only one of them. Measured against the old way on the
# host: the same output, the same mock log, and both suites still green.
#
# The status of the command comes back, and a `DR_MOCK_STATE=running dr_pty ...`
# prefix reaches the command, because bash exports an assignment that prefixes a
# function call for the length of that call.
dr_pty() {
    python3 "$DR_ROOT/tests/pty_run.py" "$*"
}

# --- repos on a Windows drive ------------------------------------------------
#
# Each mound command calls dr_require_win_path. Thus a test of one needs a repo
# whose path starts with /mnt/<letter>/. The test only matches strings, with no
# hypervisor. Thus each writable directory under such a path works:
#
#   in WSL      /mnt/c is the real C: drive
#   in CI       a plain directory that the workflow creates with sudo
#   in a mound  one that the suite makes for itself, see dr_win_root_make
#   elsewhere   nothing, and the tests that need one skip, and do not fail
#
# $DRAUGR_TEST_WINROOT overrides the search, for people whose drives are in
# another place.
#
# The places to look, in order. A list, and not two literals inside the loop, so
# that a test can empty it and reach the fallback. /mnt/c/Temp comes first. On a
# real machine it is a scratch directory, and the drive root is the C:\ of
# somebody, which must not get test files.
DR_WIN_ROOT_CANDIDATES=(/mnt/c/Temp /mnt/c)

# Makes the root that the search did not find, inside a sandbox only.
#
# A mound has no /mnt at all. The drives of Windows are at /c in there, and each
# mound command still demands /mnt/<letter>/. Thus the search finds nothing, and
# about a hundred tests skip in the one place where an agent is most likely to
# run them. A microVM is disposable, and its agent answers `sudo -n` with no
# password, so the suite makes the same directory that the CI workflow makes,
# for the same reason. The search then finds it, so this runs once per mound.
#
# Only inside a sandbox. On a real machine a test run must not create /mnt,
# however much permission it holds. $1 is the path, and only the test of this
# function passes one. shellcheck reads this file alone, and thus cannot see
# that caller, which is tests/harness.bats.
# shellcheck disable=SC2120
dr_win_root_make() {
    local target=${1:-/mnt/c/Temp}
    [ "${IS_SANDBOX:-}" = 1 ] || return 1
    sudo -n mkdir -p "$target" 2>/dev/null || return 1
    # 1777, because root made it and the tests run as the agent.
    sudo -n chmod 1777 "$target" 2>/dev/null || return 1
    [ -d "$target" ] && [ -w "$target" ] || return 1
    printf '%s' "$target"
}

dr_win_root() {
    local candidate

    # An explicit override replaces the search, and does not add to it. Thus you
    # can point it at nothing, to exercise the skip path. The fallback below
    # must not rescue such a run either.
    if [ -n "${DRAUGR_TEST_WINROOT:-}" ]; then
        [ -d "$DRAUGR_TEST_WINROOT" ] && [ -w "$DRAUGR_TEST_WINROOT" ] || return 1
        printf '%s' "$DRAUGR_TEST_WINROOT"
        return 0
    fi

    # The search: the first candidate that is there and takes a write wins. A
    # directory that exists but refuses one is not a root, and must not be
    # reported as one, or every fixture fails later and somewhere else.
    for candidate in "${DR_WIN_ROOT_CANDIDATES[@]}"; do
        if [ -d "$candidate" ] && [ -w "$candidate" ]; then
            printf '%s' "$candidate"
            return 0
        fi
    done

    # Nothing on this machine. Inside a mound, make one. In each other place
    # this answers 1, and the caller skips.
    dr_win_root_make
}

# --- a stand-in for the git repository of the mound -------------------------
#
# dr-sync and the related commands talk to ssh://<name>.sbx/<mound path>. A test
# has no sandbox. Thus we use the own url.<base>.insteadOf rewrite of git to
# point that URL at a local clone. git then does a real fetch over the
# filesystem. Thus the code under test has no change: no test-only branch, no
# backdoor variable. The fetch, the ref names, and the commit count are all
# real.
#
# Prints the path of the stand-in repo. Commits there look to Draugr exactly
# like the commits of the agent.
dr_fake_mound() {
    local repo=$1 name=$2 url mound fake

    # The URL that Draugr derives. It must match exactly, so it is built the
    # same way as in dr_sandbox_url. /mnt is removed to give the mound path.
    mound=${repo#/mnt}
    url="ssh://$name.sbx$mound"

    fake="$DR_TMP/mound-$name"
    git clone -q "$repo" "$fake"
    git -C "$fake" config user.email agent@example.com
    git -C "$fake" config user.name Agent

    # Rewrite that exact URL to the local path, for this repo only.
    git -C "$repo" config "url.$fake.insteadOf" "$url"
    printf '%s' "$fake"
}

# dr_mound_answers: let the mound answer the FIRST question that dr-rm and
# dr-up --recreate ask, and print nothing.
#
# Both ask three questions before they destroy anything: unfetched commits,
# unexported memory, and hosts that you opened by hand. An unknown answer to
# any of them is now a refusal, because unknown is not the same as nothing.
# Thus a test about the second or the third question must answer the first, or
# it stops at a refusal it is not about, and the assertion fails for the wrong
# reason.
#
# The sandbox name is derived, not spelled, in a subshell, so that the
# derivation stays in one place. A spelled name silently stops matching when
# the derivation changes, and then the stand-in is simply never used.
dr_mound_answers() {
    local repo=${1:-$REPO} name
    name=$(. "$DR_ROOT/lib/common.sh" && dr_sandbox_name "$repo") || return 1
    dr_fake_mound "$repo" "$name" >/dev/null
}

# --- a fake sbx installation tree ---------------------------------------------
#
# dr-scan finds the shared skills store with a walk up from sbx.exe:
# <root>/bin/sbx.exe -> <root>/sandboxes/state/agent-skills. If DRAUGR_SBX
# points directly at tests/mocks/sbx, it looks in the repo. Thus this puts a
# copy of the mock in a throwaway tree.
#
# Sets DR_SKILLS_DIR, and does not print it. Else, the caller must write
# $(dr_fake_sbx_root). A command substitution is a subshell, so the `export
# DRAUGR_SBX` is lost when it returns.
dr_fake_sbx_root() {
    local root="$DR_TMP/sbxroot"
    mkdir -p "$root/bin" "$root/sandboxes/state/agent-skills"
    cp "$DR_ROOT/tests/mocks/sbx" "$root/bin/sbx"
    chmod +x "$root/bin/sbx"
    export DRAUGR_SBX="$root/bin/sbx"
    DR_SKILLS_DIR="$root/sandboxes/state/agent-skills"
    export DR_SKILLS_DIR
}

# --- a stand-in for the filesystem of the mound -----------------------------
#
# The partner of dr_fake_mound. That one is a stand-in for the git repo of the
# mound, and this one for its disk. Sets DR_MOCK_MOUND, which makes the mock sbx
# run 'exec' and 'cp' against a real directory tree. Also sets DR_MEMDIR, the
# place of the memory of this repo in it.
#
# Sets, and does not print, for the same reason as dr_fake_sbx_root. With
# $(dr_mound_memory_dir …), it runs in a subshell, and loses the export.
#
# The project key comes from here, independently of dr_mem_key. Remove /mnt, and
# each "/" becomes "-". If the two are ever different, the tests fail. That is
# the full value. A translation that only agrees with itself is untested.
dr_mound_memory_dir() {
    local repo=$1 key
    key=$(printf '%s' "${repo#/mnt}" | tr '/' '-')
    export DR_MOCK_MOUND="$DR_TMP/mound-fs"
    DR_MEMDIR="$DR_MOCK_MOUND/home/agent/.claude/projects/$key/memory"
    export DR_MEMDIR
}

# The same, for Codex. Codex files nothing under the name of the project. Thus
# there is no key, and the repo is not an argument. DR_CODEXDIR is $CODEX_HOME
# in the stand-in tree. The memories are one level below it, and the databases
# are directly in it. Written here, not derived from the module, for the same
# reason as above. A layout that only agrees with itself is untested.
dr_mound_codex_dir() {
    export DR_MOCK_MOUND="$DR_TMP/mound-fs"
    DR_CODEXDIR="$DR_MOCK_MOUND/home/agent/.codex"
    export DR_CODEXDIR
}

# A gitignored secret, with the .gitignore committed, so that the working tree
# is CLEAN. That is important. A dirty tree makes dr-go refuse for its own
# reasons. A scan test that fails on the clean-tree test tests nothing.
dr_add_ignored_secret() {
    local repo=$1 name=${2:-secrets.env}
    printf '%s\n' "$name" >> "$repo/.gitignore"
    git -C "$repo" add .gitignore
    git -C "$repo" commit -qm "ignore $name"
    printf 'AWS_SECRET=hunter2\n' > "$repo/$name"
}

# Make a commit in the stand-in, as the agent does.
dr_mound_commit() {
    local fake=$1 msg=${2:-agent work}
    printf '%s\n' "$msg" >> "$fake/agent.txt"
    git -C "$fake" add -A
    git -C "$fake" commit -qm "$msg"
}

# Prints the repo path. Call it as:
#   repo=$(dr_make_win_repo) || skip "no writable Windows drive path"
#
# The scratch directory gets its name from $DR_TMP, and is not made with mktemp.
# Thus dr_test_teardown can find it again by name. A variable cannot give it
# back. Each caller uses a command substitution, which is a subshell, so an
# `export` here dies with it. The directory then stays on a real drive that
# nothing else cleans. That left 5311 directories in C:\Temp before somebody saw
# it. That is the reason to derive the name, and not to pass it.
dr_make_win_repo() {
    local root name=${1:-testrepo} dir
    root=$(dr_win_root) || return 1

    # Under $root, not $TMPDIR. That is the full purpose. The path must start
    # with /mnt/<letter>/ to be accepted.
    DR_WIN_TMP="$root/draugr-test.${DR_TMP##*/}"
    mkdir -p "$DR_WIN_TMP" || return 1
    export DR_WIN_TMP
    dir="$DR_WIN_TMP/$name"

    # One commit, so that the tree is clean and has history. The clean-tree test
    # of dr-go and the clone itself both need one commit or more.
    mkdir -p "$dir"
    git -C "$dir" init -q -b main
    git -C "$dir" config user.email test@example.com
    git -C "$dir" config user.name Test
    printf 'hello\n' > "$dir/README.md"
    git -C "$dir" add -A
    git -C "$dir" commit -qm "first"
    printf '%s' "$dir"
}
