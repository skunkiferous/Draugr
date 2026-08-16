# shellcheck shell=bash
# Shared setup for the bats suites.

DR_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export DR_ROOT
export PATH="$DR_ROOT/tests/mocks:$DR_ROOT/bin:$PATH"

# Point sbx discovery at the mock, and keep every test out of the real
# ~/.config/draugr so a run can never trust something on the developer's machine.
dr_test_setup() {
    DR_TMP=$(mktemp -d)
    export DR_TMP
    export DRAUGR_SBX="$DR_ROOT/tests/mocks/sbx"
    export DRAUGR_CONFIG_HOME="$DR_TMP/config"
    export DR_MOCK_LOG="$DR_TMP/sbx.log"
    export HOME="$DR_TMP/home"
    mkdir -p "$HOME" "$DRAUGR_CONFIG_HOME"
    : > "$DR_MOCK_LOG"
}

dr_test_teardown() {
    [ -n "${DR_TMP:-}" ] && [ -d "$DR_TMP" ] && rm -rf "$DR_TMP"

    # The Windows-drive scratch directory lives outside $TMPDIR, so nothing else
    # is going to clean it up. Its name is DERIVED from $DR_TMP rather than
    # remembered in a variable, because every caller writes
    #
    #     REPO=$(dr_make_win_repo)
    #
    # and a command substitution is a subshell: an `export` inside it never
    # reaches this function. That is how 5311 directories accumulated under
    # C:\Temp before anyone looked - roughly thirty per test run, silently.
    if [ -n "${DR_WIN_TMP:-}" ] && [ -d "$DR_WIN_TMP" ]; then
        rm -rf "$DR_WIN_TMP"
    elif [ -n "${DR_TMP:-}" ]; then
        local root
        root=$(dr_win_root 2>/dev/null) && rm -rf "$root/draugr-test.${DR_TMP##*/}"
    fi
    return 0
}

# A throwaway git repo. Note this is NOT under a real /mnt/<drive>/ path, so it
# deliberately fails dr_require_win_path - path translation is unit-tested
# against literal strings instead, which keeps those tests runnable on any OS.
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

# --- repos on a Windows drive ------------------------------------------------
#
# Every mound command calls dr_require_win_path, so testing one at all means
# having a repo whose path starts /mnt/<letter>/. The check is pure string
# matching - no hypervisor is involved - so any writable directory under such a
# path will do:
#
#   in WSL   /mnt/c is the real C: drive
#   in CI    a plain directory that the workflow creates with sudo
#   elsewhere  nothing, and the tests that need one skip rather than fail
#
# $DRAUGR_TEST_WINROOT overrides the search for anyone whose drives sit elsewhere.
dr_win_root() {
    local candidate

    # An explicit override replaces the search rather than joining it, so that
    # pointing it at nothing is a supported way to exercise the skip path.
    if [ -n "${DRAUGR_TEST_WINROOT:-}" ]; then
        [ -d "$DRAUGR_TEST_WINROOT" ] && [ -w "$DRAUGR_TEST_WINROOT" ] || return 1
        printf '%s' "$DRAUGR_TEST_WINROOT"
        return 0
    fi

    # /mnt/c/Temp first: on a real machine it is a scratch directory, whereas the
    # drive root is somebody's C:\ and does not want test litter in it.
    for candidate in /mnt/c/Temp /mnt/c; do
        if [ -d "$candidate" ] && [ -w "$candidate" ]; then
            printf '%s' "$candidate"
            return 0
        fi
    done
    return 1
}

# --- standing in for the mound's git repository ------------------------------
#
# dr-sync and friends talk to ssh://<name>.sbx/<mound path>. There is no sandbox
# in a test, so we use git's own url.<base>.insteadOf rewriting to point that URL
# at a local clone. git then does a genuine fetch over the filesystem, which
# means the code under test is unmodified - no test-only branch, no backdoor
# variable, and the fetch, the ref names and the commit counting are all real.
#
# Prints the stand-in repo's path. Commits made there appear to Draugr exactly as
# the agent's commits would.
dr_fake_mound() {
    local repo=$1 name=$2 url mound fake

    # The URL Draugr will derive. It has to match exactly, so it is built the
    # same way dr_sandbox_url builds it: /mnt is stripped to give the mound path.
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

# --- a fake sbx installation tree ---------------------------------------------
#
# dr-scan finds the shared skills store by walking up from sbx.exe:
# <root>/bin/sbx.exe -> <root>/sandboxes/state/agent-skills. Pointing DRAUGR_SBX
# straight at tests/mocks/sbx would therefore make it look inside the repo, so
# this puts a copy of the mock in a throwaway tree.
#
# Sets DR_SKILLS_DIR rather than printing it: the caller would have to write
# $(dr_fake_sbx_root), and a command substitution is a subshell, so the
# `export DRAUGR_SBX` would be discarded the moment it returned.
dr_fake_sbx_root() {
    local root="$DR_TMP/sbxroot"
    mkdir -p "$root/bin" "$root/sandboxes/state/agent-skills"
    cp "$DR_ROOT/tests/mocks/sbx" "$root/bin/sbx"
    chmod +x "$root/bin/sbx"
    export DRAUGR_SBX="$root/bin/sbx"
    DR_SKILLS_DIR="$root/sandboxes/state/agent-skills"
    export DR_SKILLS_DIR
}

# --- standing in for the mound's filesystem ----------------------------------
#
# The companion to dr_fake_mound: that one stands in for the mound's git repo,
# this one for its disk. Sets DR_MOCK_MOUND, which makes the mock sbx run 'exec'
# and 'cp' against a real directory tree, and DR_MEMDIR, where this repo's
# memory lives inside it.
#
# Sets rather than prints, for the same reason dr_fake_sbx_root does: writing
# $(dr_mound_memory_dir …) would run it in a subshell and throw the export away.
#
# The project key is derived here independently of dr_mem_key - strip /mnt, then
# every "/" becomes "-". If the two ever disagree the tests fail, which is the
# entire value: a translation that only agrees with itself is untested.
dr_mound_memory_dir() {
    local repo=$1 key
    key=$(printf '%s' "${repo#/mnt}" | tr '/' '-')
    export DR_MOCK_MOUND="$DR_TMP/mound-fs"
    DR_MEMDIR="$DR_MOCK_MOUND/home/agent/.claude/projects/$key/memory"
    export DR_MEMDIR
}

# A gitignored secret, with the .gitignore committed so the working tree is
# CLEAN. That matters: a dirty tree makes dr-go refuse for its own reasons, and a
# scan test that trips the clean-tree check instead is testing nothing.
dr_add_ignored_secret() {
    local repo=$1 name=${2:-secrets.env}
    printf '%s\n' "$name" >> "$repo/.gitignore"
    git -C "$repo" add .gitignore
    git -C "$repo" commit -qm "ignore $name"
    printf 'AWS_SECRET=hunter2\n' > "$repo/$name"
}

# Make a commit in the stand-in, the way the agent would.
dr_mound_commit() {
    local fake=$1 msg=${2:-agent work}
    printf '%s\n' "$msg" >> "$fake/agent.txt"
    git -C "$fake" add -A
    git -C "$fake" commit -qm "$msg"
}

# Prints the repo path. Call it as:
#   repo=$(dr_make_win_repo) || skip "no writable Windows drive path"
#
# The scratch directory is named after $DR_TMP rather than made with mktemp, so
# that dr_test_teardown can find it again by name. It cannot be handed back in a
# variable: every caller uses a command substitution, which is a subshell, so an
# `export` here dies with it - and the directory then lives on a real drive that
# nothing else cleans. That leaked 5311 directories into C:\Temp before it was
# noticed, which is the argument for deriving the name instead of passing it.
dr_make_win_repo() {
    local root name=${1:-testrepo} dir
    root=$(dr_win_root) || return 1

    # Under $root rather than $TMPDIR, which is the whole point: the path has to
    # begin /mnt/<letter>/ to be accepted.
    DR_WIN_TMP="$root/draugr-test.${DR_TMP##*/}"
    mkdir -p "$DR_WIN_TMP" || return 1
    export DR_WIN_TMP
    dir="$DR_WIN_TMP/$name"

    # One commit, so the tree is clean and has history - dr-go's clean-tree check
    # and the clone itself both need something to have been committed at least once.
    mkdir -p "$dir"
    git -C "$dir" init -q -b main
    git -C "$dir" config user.email test@example.com
    git -C "$dir" config user.name Test
    printf 'hello\n' > "$dir/README.md"
    git -C "$dir" add -A
    git -C "$dir" commit -qm "first"
    printf '%s' "$dir"
}
