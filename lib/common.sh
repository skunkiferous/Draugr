# shellcheck shell=bash
#
# lib/common.sh - shared plumbing for every dr-* command.
#
# Sourced, never executed. Everything a single command needs on its own stays in
# that command; this file holds only what genuinely repeats. Internal helpers are
# prefixed _dr_ so that sourcing a project's config cannot plausibly clobber them.
#
# This is the densest file in the project, because it is where the fiddly bits
# were deliberately concentrated so the command scripts could stay plain. If a
# bash construct here is unfamiliar, docs/HACKING.md lists the ones we lean on.

# Include guard. If a script sources this twice - directly and again through a
# helper - do nothing the second time. `return` (not `exit`) because we are
# being sourced: exit would kill the caller.
[ -n "${_DR_COMMON_LOADED:-}" ] && return 0
_DR_COMMON_LOADED=1

DRAUGR_VERSION="0.1.0-dev"

# --- work out where Draugr itself is installed ------------------------------
#
# A dr-* command may be invoked through a symlink in ~/.local/bin, so
# $BASH_SOURCE[0] can be that symlink rather than the real file. We need the
# real one to find ../share/. This loop walks the chain of links to the end:
#
#   -L         "is a symlink"
#   readlink   prints the one step it points at (which may itself be a link)
#   /*)        an absolute target replaces the path outright
#   *)         a relative target is resolved against the link's own directory
#
# It terminates because each hop moves toward a real file; a symlink loop would
# be a broken installation either way.
_dr_self="${BASH_SOURCE[0]}"
while [ -L "$_dr_self" ]; do
    _dr_link=$(readlink "$_dr_self")
    # An absolute target replaces the path; a relative one is resolved against
    # the directory the link itself lives in.
    case "$_dr_link" in
        /*) _dr_self=$_dr_link ;;
        *)  _dr_self=$(dirname "$_dr_self")/$_dr_link ;;
    esac
done

# We are lib/common.sh, so the project root is one directory up.
DRAUGR_ROOT=$(cd "$(dirname "$_dr_self")/.." && pwd)
DRAUGR_SHARE="$DRAUGR_ROOT/share"
unset _dr_self _dr_link
# Exported so that hooks - which run as separate processes on the host - can find
# our share/ directory and report which Draugr invoked them.
export DRAUGR_ROOT DRAUGR_SHARE DRAUGR_VERSION

# ---------------------------------------------------------------------------
# Output
#
# Diagnostics go to stderr so that a command's actual output stays pipeable.
# Colour is suppressed when stderr is not a terminal, or when NO_COLOR is set
# (https://no-color.org).
# ---------------------------------------------------------------------------

# -t 2 asks "is stderr a terminal?". $'...' is bash's ANSI-C quoting, which turns
# \033 into a real escape character - plain '\033' would stay four characters.
if [ -t 2 ] && [ -z "${NO_COLOR:-}" ]; then
    _DR_RED=$'\033[31m'; _DR_YELLOW=$'\033[33m'; _DR_GREEN=$'\033[32m'
    _DR_BLUE=$'\033[34m'; _DR_DIM=$'\033[2m';    _DR_BOLD=$'\033[1m'
    _DR_OFF=$'\033[0m'
else
    # Piped or redirected: every colour becomes the empty string, so the same
    # printf calls work unchanged and no escape codes end up in a log file.
    _DR_RED=; _DR_YELLOW=; _DR_GREEN=; _DR_BLUE=; _DR_DIM=; _DR_BOLD=; _DR_OFF=
fi

# What we call ourselves in messages: whatever the script set as DR_PROG, or
# failing that its own filename (${0##*/} being basename $0).
_dr_prog() { printf '%s' "${DR_PROG:-${0##*/}}"; }

# Four severities, one shape: "<prog>: <message>", coloured, on stderr.
dr_info()  { printf '%s%s:%s %s\n'   "$_DR_BLUE"   "$(_dr_prog)" "$_DR_OFF" "$*" >&2; }
dr_ok()    { printf '%s%s:%s %s\n'   "$_DR_GREEN"  "$(_dr_prog)" "$_DR_OFF" "$*" >&2; }
dr_warn()  { printf '%s%s:%s %s\n'   "$_DR_YELLOW" "$(_dr_prog)" "$_DR_OFF" "$*" >&2; }
dr_error() { printf '%s%s:%s %s\n'   "$_DR_RED"    "$(_dr_prog)" "$_DR_OFF" "$*" >&2; }

# Silent unless DRAUGR_DEBUG is set, so scripts can trace freely.
dr_debug() {
    [ -n "${DRAUGR_DEBUG:-}" ] || return 0
    printf '%s%s: %s%s\n' "$_DR_DIM" "$(_dr_prog)" "$*" "$_DR_OFF" >&2
}

# dr_die <message> [remedy...]
# Every fatal error names the fix. A bare "not a git repository" costs the reader
# a search; "run git init, or cd into your project" does not.
dr_die() {
    dr_error "$1"
    shift
    # Whatever is left is remedy text: print it indented and dimmed under the
    # error, so the eye reads the problem first and the fix second.
    local line
    for line in "$@"; do
        printf '  %s%s%s\n' "$_DR_DIM" "$line" "$_DR_OFF" >&2
    done
    exit 1
}

dr_heading() { printf '\n%s%s%s\n' "$_DR_BOLD" "$*" "$_DR_OFF" >&2; }

# ---------------------------------------------------------------------------
# Locating sbx.exe
#
# sbx is a Windows binary and is NOT on WSL's PATH by default, so every call has
# to go through here. The result is cached in DRAUGR_SBX for the process.
# ---------------------------------------------------------------------------

# Four strategies, cheapest and most explicit first. Each prints the path and
# returns 0 on success; falling off the end returns 1 for "not installed".
dr_find_sbx() {
    # 1. Already found this process, or the user pointed us at it.
    if [ -n "${DRAUGR_SBX:-}" ] && [ -x "$DRAUGR_SBX" ]; then
        printf '%s' "$DRAUGR_SBX"
        return 0
    fi

    # 2. On PATH. Unusual under WSL, but free to check and true on Git Bash.
    local candidate
    for candidate in sbx.exe sbx; do
        if command -v "$candidate" >/dev/null 2>&1; then
            # command -v prints the resolved path, which is what we want to cache.
            DRAUGR_SBX=$(command -v "$candidate")
            dr_debug "found sbx on PATH: $DRAUGR_SBX"
            printf '%s' "$DRAUGR_SBX"
            return 0
        fi
    done

    # 3. Ask Windows where LOCALAPPDATA is rather than guessing the username.
    #    cmd.exe emits CRLF, hence the tr; and if the variable does not exist
    #    cmd echoes the literal "%LOCALAPPDATA%" back at us.
    local localappdata
    if command -v cmd.exe >/dev/null 2>&1; then
        localappdata=$(cmd.exe /c 'echo %LOCALAPPDATA%' 2>/dev/null | tr -d '\r\n')
        if [ -n "$localappdata" ] && [ "$localappdata" != '%LOCALAPPDATA%' ]; then
            # Translate C:\Users\x\AppData\Local into /mnt/c/... before testing it.
            candidate="$(dr_path_from_win "$localappdata")/DockerSandboxes/bin/sbx.exe"
            if [ -x "$candidate" ]; then
                DRAUGR_SBX=$candidate
                dr_debug "found sbx via LOCALAPPDATA: $DRAUGR_SBX"
                printf '%s' "$DRAUGR_SBX"
                return 0
            fi
        fi
    fi

    # 4. Last resort: the two places sbx normally installs to, across all drives
    #    and users. $glob is deliberately unquoted in the inner loop so the shell
    #    expands the wildcards; an unmatched glob yields the pattern itself,
    #    which then fails the -x test harmlessly.
    local glob
    for glob in \
        /mnt/*/Users/*/AppData/Local/DockerSandboxes/bin/sbx.exe \
        /mnt/*/Users/*/AppData/Local/Microsoft/WinGet/Links/sbx.exe
    do
        for candidate in $glob; do
            if [ -x "$candidate" ]; then
                DRAUGR_SBX=$candidate
                dr_debug "found sbx by glob: $DRAUGR_SBX"
                printf '%s' "$DRAUGR_SBX"
                return 0
            fi
        done
    done

    return 1
}

# dr_sbx <args...> - invoke sbx, logging the full command line under DRAUGR_DEBUG.
dr_sbx() {
    local sbx
    sbx=$(dr_find_sbx) || dr_die \
        "cannot find sbx.exe" \
        "sbx is a Windows binary and is not on WSL's PATH by default." \
        "Install it with:  winget install Docker.sbx" \
        "Or point Draugr at it:  export DRAUGR_SBX=/mnt/c/path/to/sbx.exe"
    dr_debug "sbx $*"
    "$sbx" "$@"
}

# ---------------------------------------------------------------------------
# Path translation
#
# One repository has three names, and getting them confused is the single
# richest source of bugs in this tool:
#
#   WSL      /mnt/c/src/myproject   what you cd into, what git runs against
#   Windows  C:\src\myproject       what sbx.exe accepts as a workspace
#   Mound    /c/src/myproject       where sbx mounts it inside the microVM
#
# These are implemented by hand rather than shelling out to wslpath so that they
# are pure functions, testable in CI on a machine with no WSL at all.
# ---------------------------------------------------------------------------

# dr_path_win /mnt/c/src/p -> C:\src\p
dr_path_win() {
    # `local` keeps these from leaking into the caller's scope. Naming a variable
    # without assigning it (drive, rest) just declares it local.
    local p=$1 drive rest

    # Accept only /mnt/<one letter>/... or exactly /mnt/<one letter>. These are
    # glob patterns, not regexes: [A-Za-z] is one character from that set, and
    # `:` is the do-nothing command, used here as "matched, carry on".
    # Anything else returns 1, which the caller reads as "not a Windows path".
    case "$p" in
        /mnt/[A-Za-z]/*|/mnt/[A-Za-z]) : ;;
        *) return 1 ;;
    esac

    # ${p:5:1} is a substring: 1 character starting at offset 5, i.e. the drive
    # letter in "/mnt/c/...". ${p:6} is everything from offset 6 to the end.
    drive=${p:5:1}
    rest=${p:6}

    # ${rest#/} strips one leading "/" if present ("#" removes a prefix).
    # tr swaps forward slashes for backslashes. In single quotes '\\' is two
    # characters, which tr reads as one escaped backslash - it is not bash
    # escaping, which is why shellcheck needs telling.
    # shellcheck disable=SC1003
    printf '%s:\\%s' "$(printf '%s' "$drive" | tr '[:lower:]' '[:upper:]')" "$(printf '%s' "${rest#/}" | tr '/' '\\')"
}

# dr_path_mound /mnt/c/src/p -> /c/src/p
# The mound path is just the WSL path with "/mnt" removed, because sbx mounts a
# workspace at the same path it has on the Windows side.
dr_path_mound() {
    local p=$1
    case "$p" in
        /mnt/[A-Za-z]/*|/mnt/[A-Za-z]) printf '%s' "${p#/mnt}" ;;
        *) return 1 ;;
    esac
}

# dr_path_from_win 'C:\Users\x' -> /mnt/c/Users/x
dr_path_from_win() {
    local p=$1 drive rest

    # Accept "C:\..." or "C:/..." or bare "C:". Inside a glob, backslash needs
    # escaping, hence [\\/] for "either kind of slash".
    case "$p" in
        [A-Za-z]:[\\/]*|[A-Za-z]:) : ;;
        *) return 1 ;;
    esac

    drive=$(printf '%s' "${p:0:1}" | tr '[:upper:]' '[:lower:]')
    rest=${p:2}                     # everything after "C:"
    # shellcheck disable=SC1003
    printf '/mnt/%s%s' "$drive" "$(printf '%s' "$rest" | tr '\\' '/')"
}

# dr_require_win_path <path> - the constraint the README documents up front.
dr_require_win_path() {
    dr_path_mound "$1" >/dev/null 2>&1 && return 0
    dr_die \
        "$1 is not on a Windows drive" \
        "sbx.exe is a Windows binary and its workspaces are Windows paths, so a" \
        "repo on WSL's own ext4 filesystem has no path sbx can mount." \
        "Move the project under /mnt/c/ (or any Windows drive) and work on it from there."
}

# ---------------------------------------------------------------------------
# Repository helpers
# ---------------------------------------------------------------------------

# The top of the working tree, or a fatal error naming the fix.
dr_repo_root() {
    local root
    root=$(git rev-parse --show-toplevel 2>/dev/null) || dr_die \
        "$PWD is not a git repository" \
        "Draugr works on one repository at a time: the sandbox gets a clone of it." \
        "Run 'git init' here, or cd into your project."
    printf '%s' "$root"
}

dr_repo_branch() {
    git -C "${1:-$PWD}" rev-parse --abbrev-ref HEAD 2>/dev/null
}

dr_repo_is_clean() {
    [ -z "$(git -C "${1:-$PWD}" status --porcelain 2>/dev/null)" ]
}

# ---------------------------------------------------------------------------
# Configuration
#
# Precedence, lowest to highest:
#   built-in defaults -> user config -> project config -> project-local -> env -> flags
#
# Provenance is recorded per key so dr-config can answer "why is it doing that".
# The layers are sourced in the current shell, because that is the only way for
# their assignments to take effect; the diff that attributes each key is taken
# before and after each source.
# ---------------------------------------------------------------------------

DR_CONFIG_USER="${DRAUGR_CONFIG_HOME:-${XDG_CONFIG_HOME:-$HOME/.config}/draugr}"
DR_TRUST_FILE="$DR_CONFIG_USER/trusted"

# Every key Draugr understands. dr-config iterates this, dr-doctor validates
# against it, and an unknown DRAUGR_* in a config file is reported rather than
# silently ignored.
DR_KEYS=(
    DRAUGR_AGENT DRAUGR_AGENT_ARGS DRAUGR_SANDBOX DRAUGR_MEMORY DRAUGR_CPUS DRAUGR_CLONE
    DRAUGR_TEMPLATE DRAUGR_KIT DRAUGR_PORTS DRAUGR_MOUNTS
    DRAUGR_DATA DRAUGR_DATA_PUSH DRAUGR_DATA_PULL DRAUGR_DATA_DELETE DRAUGR_DATA_CHMOD
    DRAUGR_BRANCH DRAUGR_REMOTE DRAUGR_REQUIRE_CLEAN DRAUGR_AUTO_SYNC
    DRAUGR_MEM_SYNC DRAUGR_MEM_STORE
    DRAUGR_SCAN DRAUGR_SCAN_PATTERNS DRAUGR_SCAN_FAIL
)

# -g matters: if a caller sources this file from inside a function - which every
# bats test does - a plain `declare -A` would scope the array to that function.
# It would then vanish on return, and the later DR_ORIGIN[DRAUGR_KIT]= would be
# an *indexed* array subscript, i.e. arithmetic on the string ".draugr/kit".
declare -gA DR_ORIGIN=()

# shellcheck disable=SC2034  # these are the config surface; every dr-* reads them
_dr_defaults() {
    DRAUGR_AGENT=claude
    # Handed to the agent after "--" on every dr-go. Empty keeps today's
    # behaviour exactly; set it to "--continue" to resume by default.
    DRAUGR_AGENT_ARGS=
    DRAUGR_SANDBOX=              # empty => draugr-<repo leaf>
    DRAUGR_MEMORY=               # empty => sbx default (50% of host RAM, max 32 GiB)
    DRAUGR_CPUS=                 # empty => sbx default (all)
    DRAUGR_CLONE=true
    DRAUGR_TEMPLATE=
    DRAUGR_KIT=.draugr/kit
    DRAUGR_PORTS=
    DRAUGR_MOUNTS=

    DRAUGR_DATA=
    DRAUGR_DATA_PUSH=auto
    DRAUGR_DATA_PULL=manual
    DRAUGR_DATA_DELETE=false
    DRAUGR_DATA_CHMOD=D755,F644

    DRAUGR_BRANCH=               # empty => the branch currently checked out
    DRAUGR_REMOTE=draugr
    DRAUGR_REQUIRE_CLEAN=true
    DRAUGR_AUTO_SYNC=true

    DRAUGR_MEM_SYNC=auto
    DRAUGR_MEM_STORE="${XDG_DATA_HOME:-$HOME/.local/share}/draugr/memory"

    DRAUGR_SCAN=true
    DRAUGR_SCAN_PATTERNS=".env *.pem *.key id_rsa id_ed25519 credentials.json secrets.*"
    DRAUGR_SCAN_FAIL=block
}

# --- how provenance is worked out -------------------------------------------
#
# The trick in both helpers below is bash's *indirect expansion*: when $k holds
# the string "DRAUGR_AGENT", then
#
#     ${!k}     is the value of the variable NAMED by $k, i.e. $DRAUGR_AGENT
#     ${!k-}    the same, but empty instead of an error if it is unset
#     printf -v NAME  writes into the variable called NAME, rather than printing
#
# Together they let us loop over DR_KEYS and read or write each setting by name,
# without a 23-branch case statement.

# Copy every current setting into a parallel set of variables sharing a prefix.
# _dr_snapshot_into _DR_PREV_ saves $DRAUGR_AGENT as $_DR_PREV_DRAUGR_AGENT, and
# so on for all of them. That is the "before" picture.
_dr_snapshot_into() {
    local prefix=$1 k
    for k in "${DR_KEYS[@]}"; do
        printf -v "${prefix}${k}" '%s' "${!k-}"
    done
}

# Compare "now" against that saved "before" picture, and credit every setting
# that changed to the layer we just sourced. A config file that sets three keys
# therefore gets the blame for exactly those three - which is what makes
# `dr-config` able to say where each value came from.
_dr_attribute() {
    local prefix=$1 origin=$2 k ref
    for k in "${DR_KEYS[@]}"; do
        ref="${prefix}${k}"          # e.g. "_DR_PREV_DRAUGR_AGENT"
        if [ "${!k-}" != "${!ref-}" ]; then
            DR_ORIGIN[$k]=$origin
        fi
    done
}

# dr_load_config [repo-root]
# Populates every DRAUGR_* variable and DR_ORIGIN. Safe to call once per process.
dr_load_config() {
    local repo=${1:-}

    # STEP 1 - stash anything that arrived from the environment.
    #
    # DRAUGR_AGENT=codex dr-go  must beat every config file. But we are about to
    # source those files in this same shell, and they would overwrite it. So
    # remember the environment's values now and put them back at the end.
    #
    # ${!k+set} is "set" only when the variable NAMED by $k exists, even if it is
    # empty - unlike ${!k:+set}, which would also treat an empty value as absent.
    # DRAUGR_PORTS= in the environment is a deliberate "no ports", not silence.
    local k envk had_env=()
    for k in "${DR_KEYS[@]}"; do
        if [ -n "${!k+set}" ]; then
            envk="_DR_ENV_$k"                # e.g. "_DR_ENV_DRAUGR_AGENT"
            printf -v "$envk" '%s' "${!k}"
            had_env+=("$k")
        fi
    done

    # STEP 2 - lay down the built-in defaults, and credit them all.
    _dr_defaults
    local key
    for key in "${DR_KEYS[@]}"; do DR_ORIGIN[$key]="built-in default"; done

    # STEP 3 - source each config file in turn, lowest precedence first, taking
    # a before/after snapshot around each so we know which keys it touched.
    #
    # ${repo:+VALUE} expands to VALUE only when $repo is non-empty - so when we
    # are not inside a repository those two entries collapse to empty strings and
    # are skipped below. (It is the mirror image of the ${VAR:-default} form.)
    local layer
    for layer in \
        "$DR_CONFIG_USER/config" \
        "${repo:+$repo/.draugr.conf}" \
        "${repo:+$repo/.draugr.local.conf}"
    do
        if [ -z "$layer" ] || [ ! -f "$layer" ]; then
            continue
        fi
        # Refuse to source a project config we have not been shown. Note this
        # `continue`s rather than dying: an untrusted file is skipped, and the
        # run carries on with the layers below it.
        dr_trust_check "$layer" || continue

        _dr_snapshot_into _DR_PREV_
        dr_debug "sourcing $layer"
        # "." is `source`: run the file in THIS shell so its assignments stick.
        # (Running it as a subprocess would change only that process's copy.)
        # shellcheck disable=SC1090  # path is only known at runtime
        . "$layer" || dr_die "$layer failed to load" "Check it with: bash -n $layer"
        _dr_attribute _DR_PREV_ "$layer"
    done

    # STEP 4 - put the environment's values back on top, and credit them.
    # The length check is for bash 4.3 and earlier, where expanding an empty
    # array under `set -u` is itself an error.
    if [ ${#had_env[@]} -gt 0 ]; then
        for k in "${had_env[@]}"; do
            envk="_DR_ENV_$k"
            printf -v "$k" '%s' "${!envk}"
            DR_ORIGIN[$k]="environment"
        done
    fi

    # Derived defaults that need the repo, applied only if still unset.
    if [ -z "$DRAUGR_BRANCH" ] && [ -n "$repo" ]; then
        DRAUGR_BRANCH=$(dr_repo_branch "$repo")
        DR_ORIGIN[DRAUGR_BRANCH]="detected (current branch)"
    fi
    if [ -z "$DRAUGR_SANDBOX" ] && [ -n "$repo" ]; then
        DRAUGR_SANDBOX=$(dr_sandbox_name "$repo")
        DR_ORIGIN[DRAUGR_SANDBOX]="derived from repo name"
    fi
}

# dr_config_set_flag <KEY> <value> - highest precedence, for command-line flags.
dr_config_set_flag() {
    printf -v "$1" '%s' "$2"
    # shellcheck disable=SC2034  # DR_ORIGIN is read by dr-config
    DR_ORIGIN[$1]="command-line flag"
}

# Config files are hand-written, so accept every spelling of "yes" a person might
# reasonably type. Anything else - including empty and typos - is false.
dr_is_true() {
    case "${1:-}" in
        true|True|TRUE|yes|y|1|on) return 0 ;;
        *) return 1 ;;
    esac
}

# ---------------------------------------------------------------------------
# Trust
#
# Sourcing a file from a cloned repository means running its code. Draugr records
# the hash of each project config the first time you accept it, and refuses to
# source one it has not seen. Same bargain as direnv, same reason.
# ---------------------------------------------------------------------------

# SHA-256 of a file, printed bare. Linux has sha256sum, macOS has shasum; we take
# whichever exists rather than assuming, since the hash format is identical.
_dr_hash() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | cut -d' ' -f1
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | cut -d' ' -f1
    else
        dr_die "no sha256sum or shasum available" "Install coreutils."
    fi
}

# Trust is per CONTENT, not per path: the record is "<hash>  <path>", so editing a
# trusted file changes its hash and silently revokes trust until you re-accept it.
dr_trust_is_trusted() {
    local file=$1 hash
    [ -f "$DR_TRUST_FILE" ] || return 1
    hash=$(_dr_hash "$file")
    grep -qxF "$hash  $file" "$DR_TRUST_FILE" 2>/dev/null
}

dr_trust_add() {
    local file=$1 hash
    hash=$(_dr_hash "$file")
    mkdir -p "$DR_CONFIG_USER"
    # Drop any previous entry for this path, then record the current hash.
    if [ -f "$DR_TRUST_FILE" ]; then
        grep -vF "  $file" "$DR_TRUST_FILE" > "$DR_TRUST_FILE.tmp" 2>/dev/null || :
        mv "$DR_TRUST_FILE.tmp" "$DR_TRUST_FILE"
    fi
    printf '%s  %s\n' "$hash" "$file" >> "$DR_TRUST_FILE"
    chmod 600 "$DR_TRUST_FILE"
}

# The user's own config is not subject to trust: they wrote it, and prompting
# for it would train them to accept prompts.
dr_trust_check() {
    local file=$1
    case "$file" in
        "$DR_CONFIG_USER"/*) return 0 ;;
    esac
    dr_trust_is_trusted "$file" && return 0
    dr_warn "not sourcing $file - it is untrusted"
    printf '  %sThis file is shell code and sourcing it runs it.%s\n' "$_DR_DIM" "$_DR_OFF" >&2
    printf '  %sReview it, then:  dr-trust %s%s\n' "$_DR_DIM" "$file" "$_DR_OFF" >&2
    return 1
}

# ---------------------------------------------------------------------------
# The shared preamble
# ---------------------------------------------------------------------------

# dr_context - what every command that touches a mound does first.
#
# Sets DR_REPO (the WSL path), DR_REPO_WIN (the same repo spelled the way sbx.exe
# insists on) and loads the config cascade, which is what fills in DRAUGR_SANDBOX.
# Assignments here have no `local`, so they land in the caller's scope by design.
dr_context() {
    DR_REPO=$(dr_repo_root)
    dr_require_win_path "$DR_REPO"
    # shellcheck disable=SC2034  # read by the dr-* command that called us
    DR_REPO_WIN=$(dr_path_win "$DR_REPO")
    dr_load_config "$DR_REPO"
}

# dr_confirm <question> - ask before doing something irreversible.
#
# Three outcomes, matching dr-trust: --yes was passed, a human answered, or there
# is no terminal at all. The last one refuses rather than assuming yes, because a
# prompt that auto-accepts in a script is not a prompt.
dr_confirm() {
    local reply
    if [ -n "${DR_ASSUME_YES:-}" ]; then
        return 0
    fi
    if [ ! -t 0 ]; then
        dr_die "$1" "Refusing to assume an answer without a terminal. Pass --yes if you mean it."
    fi
    printf '%s [y/N] ' "$1" >&2
    read -r reply
    case "$reply" in
        y|Y|yes|Yes) return 0 ;;
        *) return 1 ;;
    esac
}

# dr_require_tty <what> - fail early, and legibly, instead of deep inside sbx.
#
# `sbx run` attaches an interactive session. Without a terminal it gets partway in
# and then dies with "inspect exec: context deadline exceeded", which tells the
# reader nothing. Verified against sbx 0.37.1.
dr_require_tty() {
    [ -t 0 ] && [ -t 1 ] && return 0
    dr_die \
        "$1 needs a terminal" \
        "It attaches an interactive session, which cannot work from a pipe or a script." \
        "To run one command non-interactively instead:  dr-shell -- <command>"
}

# ---------------------------------------------------------------------------
# Sandbox identity and state
# ---------------------------------------------------------------------------

# dr_sandbox_name [repo-root] - draugr-<leaf>, restricted to sbx's charset.
#
# sbx only accepts letters, numbers, hyphens, periods and plus signs in a name,
# so "my project (old)" has to become "my-project-old".
dr_sandbox_name() {
    local repo=${1:-$PWD} leaf

    # ${repo##*/} deletes the longest prefix ending in "/" - i.e. basename.
    leaf=${repo##*/}

    # tr -c means "complement": replace every character NOT in the allowed set
    # with a hyphen. The sed then tidies up after it - collapse runs of hyphens
    # into one, and trim a leading or trailing hyphen. (\{2,\} is BRE for "two
    # or more", the portable spelling of {2,}.)
    leaf=$(printf '%s' "$leaf" | tr -c 'A-Za-z0-9.+-' '-' | sed 's/-\{2,\}/-/g; s/^-//; s/-$//')

    printf 'draugr-%s' "$leaf"
}

# dr_sandbox_state <name> -> absent|stopped|running (whatever sbx reports)
dr_sandbox_state() {
    local name=$1 json
    json=$(dr_sbx ls --json 2>/dev/null) || { printf 'unknown'; return 1; }

    # The jq program, read left to right:
    #   (.sandboxes // [])   the sandboxes array, or an empty one if absent
    #   []                   iterate over its elements
    #   select(.name == $n)  keep only the one we asked about
    #   .status              print that field
    # --arg n "$name" passes the name in as a jq variable rather than splicing
    # it into the program text, so a name with quotes in it cannot break jq.
    #
    # If no sandbox matched, jq prints nothing, `grep .` (match any character)
    # finds no line and fails, and the || branch reports "absent".
    printf '%s' "$json" | jq -r --arg n "$name" \
        '(.sandboxes // [])[] | select(.name == $n) | .status' 2>/dev/null \
        | head -1 | grep . || printf 'absent'
}

dr_sandbox_exists() {
    [ "$(dr_sandbox_state "$1")" != "absent" ]
}

# ---------------------------------------------------------------------------
# Hooks - run on the HOST (WSL), which is exactly what a kit's commands cannot do.
# ---------------------------------------------------------------------------

dr_hook() {
    local name=$1 repo=${2:-$PWD} hook
    hook="$repo/.draugr/hooks/$name"

    # No hook, or not executable: silently fine. Hooks are opt-in.
    [ -x "$hook" ] || return 0
    dr_debug "running hook $name"

    # A hook is a separate process, so the merged config has to be exported to
    # reach it. ${k?} is the form shellcheck accepts for "export by name".
    local k
    for k in "${DR_KEYS[@]}"; do export "${k?}"; done
    export DRAUGR_REPO="$repo" DRAUGR_HOOK="$name"

    # A failing hook is fatal: it exists to veto, so ignoring it would defeat it.
    "$hook" || dr_die "hook $name failed (exit $?)" "Hook: $hook"
}
