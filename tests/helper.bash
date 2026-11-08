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

# --- repos on a Windows drive ------------------------------------------------
#
# Each mound command calls dr_require_win_path. Thus a test of one needs a repo
# whose path starts with /mnt/<letter>/. The test only matches strings, with no
# hypervisor. Thus each writable directory under such a path works:
#
#   in WSL   /mnt/c is the real C: drive
#   in CI    a plain directory that the workflow creates with sudo
#   elsewhere  nothing, and the tests that need one skip, and do not fail
#
# $DRAUGR_TEST_WINROOT overrides the search, for people whose drives are in
# another place.
dr_win_root() {
    local candidate

    # An explicit override replaces the search, and does not add to it. Thus you
    # can point it at nothing, to exercise the skip path.
    if [ -n "${DRAUGR_TEST_WINROOT:-}" ]; then
        [ -d "$DRAUGR_TEST_WINROOT" ] && [ -w "$DRAUGR_TEST_WINROOT" ] || return 1
        printf '%s' "$DRAUGR_TEST_WINROOT"
        return 0
    fi

    # /mnt/c/Temp first. On a real machine, it is a scratch directory. The drive
    # root is the C:\ of somebody, and must not get test files.
    for candidate in /mnt/c/Temp /mnt/c; do
        if [ -d "$candidate" ] && [ -w "$candidate" ]; then
            printf '%s' "$candidate"
            return 0
        fi
    done
    return 1
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
