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

DRAUGR_VERSION="0.4.0"

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

# dr_help [file] - print a script's leading comment block as its help text.
#
# Every command's --help IS its header comment, which is the only way to keep the
# two from drifting. This replaced a hand-counted `sed -n '2,Np' "$0"` in each
# script, where N had to be the last comment line: in 17 of 27 commands it was
# one too many, so --help ended with a stray `set -euo pipefail`. Nobody had
# miscounted twice in the same direction - the range simply goes stale the moment
# anyone edits a header, which is exactly the kind of upkeep to delete rather
# than to get right.
#
# Starts at line 2 to skip the shebang and stops at the first line that is not a
# comment, strips one leading "# " from what is left, and stops early at a linter
# directive. That last rule earns its place: a file-wide "disable=" pragma has to
# sit above the first command to apply at all, so in dr-mem it lives inside the
# header block - and it is machine-readable metadata, not something a reader
# typing --help asked to see.
#
# (Note the careful wording above. A comment line STARTING with the linter's own
# name is parsed as a malformed directive, which fails the whole file - found the
# hard way, by writing one here.)
# Blank lines are held back and only flushed when a real line follows, so a
# header that ends with a "#" separator - dr-mem does, just above its shellcheck
# directive - does not leave --help trailing into whitespace.
dr_help() {
    awk 'NR == 1         { next }
         /^# shellcheck/ { exit }
         /^#/            {
                           sub(/^# ?/, "")
                           if ($0 == "") { pending++; next }
                           while (pending-- > 0) print ""
                           pending = 0
                           print
                           next
                         }
                         { exit }' "${1:-$0}"
}

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
# sandboxd's own log, and why anything reads it
#
# sbx reports a failed create as one line - `500 Internal Server Error: failed
# to run sandbox container` - and stops. Its daemon knows far more than that.
# Measured on 0.37.1, a kit install command that could not find a file reached
# the user as that bare 500, while the log held the failing command, its exit
# code and its captured output:
#
#   commands.install[2] (uv pip install -r requirements.txt): exited 2 after 13ms
#     -- captured output --
#     error: File not found: `requirements.txt`
#
# That is the difference between a dead end and a diagnosis, so Draugr reads it.
# It is an undocumented file with an undocumented shape, which is a coupling we
# do not get to complain about if it breaks: every step below is allowed to fail
# quietly, and every caller keeps the advice it printed before this existed.
# ---------------------------------------------------------------------------

# dr_sbx_daemon_log - where that log lives, derived from sbx's own location the
# same way dr_skills_dir is. Returns 1 if sbx is not found or the log is absent.
dr_sbx_daemon_log() {
    local sbx_exe log
    sbx_exe=$(dr_find_sbx) || return 1
    log="$(dirname "$(dirname "$sbx_exe")")/sandboxes/state/sandboxd/daemon.log"
    [ -f "$log" ] || return 1
    printf '%s\n' "$log"
}

# dr_sbx_log_mark - how large the log is right now, so that a later read can look
# at only what an operation appended. A byte offset rather than a timestamp: it
# needs no clock and no date parsing, and it cannot mistake last week's failure
# for this one. Always prints a number, so a caller need not test the result.
dr_sbx_log_mark() {
    local log size
    log=$(dr_sbx_daemon_log) || { printf '0\n'; return 0; }
    size=$(wc -c < "$log" 2>/dev/null) || size=0
    printf '%s\n' "${size//[^0-9]/}"
}

# dr_sbx_log_error <mark> - the last error sandboxd recorded after <mark>, or 1.
dr_sbx_log_error() {
    local mark=${1:-0} log out
    command -v jq >/dev/null 2>&1 || return 1
    log=$(dr_sbx_daemon_log) || return 1
    # fromjson? rather than plain parsing, because the file is being written
    # while we read it: a torn final line is normal, and one unparseable line
    # must not throw away the good ones. A create failure logs a `stage`, so
    # that entry is preferred over any other error in the same window - which
    # can be routine noise like a lookup that missed. The error field carries
    # embedded newlines, and -r expands them, so what comes back is the
    # multi-line block sbx captured.
    out=$(tail -c "+$((mark + 1))" "$log" 2>/dev/null \
              | jq -srR 'split("\n") | map(fromjson?)
                        | map(select(.level == "ERROR" and (.error // "") != ""))
                        | ((map(select(has("stage"))) | last) // last)
                        | .error // empty' 2>/dev/null) || return 1
    [ -n "$out" ] || return 1
    printf '%s\n' "$out"
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

# dr_path_win_kit <path> - a Windows spelling sbx.exe can READ, for kits only.
#
# A workspace and a kit are not the same problem, and this is the one place the
# difference is worth exploiting. A workspace on WSL's own ext4 is impossible:
# the microVM cannot bind-mount a path behind the Windows network redirector, so
# dr_require_win_path refuses one. A kit is never bind-mounted - sbx reads it on
# the host and packs it - so the UNC form works.
#
# Measured against sbx 0.37.1: a kit under ~/.config on ext4, passed as
# \\wsl.localhost\<distro>\..., validated, had its install command run inside the
# sandbox and its network rule applied. That is what lets the kit library default
# to ~/.config/draugr/kits instead of forcing it onto a Windows drive.
#
# Do NOT use this for a workspace. dr_path_win stays strict for that reason.
dr_path_win_kit() {
    local p=$1 out

    # A path on a Windows drive has a real drive-letter spelling, which is always
    # preferable: no network redirector, no distro name to be wrong about.
    if out=$(dr_path_win "$p"); then
        printf '%s' "$out"
        return 0
    fi

    # $WSL_DISTRO_NAME is set by WSL itself, so this stays a pure function -
    # testable in CI on a machine with no WSL, like everything else here.
    [ -n "${WSL_DISTRO_NAME:-}" ] || return 1
    # shellcheck disable=SC1003  # '\\' is one escaped backslash for tr, not bash
    printf '\\\\wsl.localhost\\%s%s' \
        "$WSL_DISTRO_NAME" "$(printf '%s' "$p" | tr '/' '\\')"
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
        "Run 'git init' here, or cd into your project." \
        "To have Draugr create one for you, set DRAUGR_ON_MISSING_REPO and run dr-init."
    printf '%s' "$root"
}

# Empty, and successful, when there is no repository or no commit yet. git exits
# 128 in both cases, and every caller here treats "no branch" as an answer rather
# than a fault - so without the `|| true` this aborts any caller running under
# `set -e`, which is all of them. That is precisely what it used to do when
# dr-init was pointed at a directory that was not a repository yet.
dr_repo_branch() {
    git -C "${1:-$PWD}" rev-parse --abbrev-ref HEAD 2>/dev/null || true
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

# The agents sbx can run. Draugr has a module for two of them - see lib/agents/ -
# and the rest get default.sh, which is the honest answer for the other eight.
#
# The list exists as data rather than as prose in the docs because the per-agent
# argument keys below are BUILT from it: adding an agent here is the only edit
# needed for it to gain one.
DR_AGENTS=(claude codex copilot cursor docker-agent droid gemini kiro opencode shell)

# dr_agent_args_key <agent> - the per-agent argument key for that agent.
#
# Uppercased, with "-" turned into "_", because docker-agent is a legal agent
# name and DRAUGR_AGENT_ARGS_DOCKER-AGENT is not a legal variable name. In tr's
# first set a trailing "-" is a literal rather than a range, which is why the two
# sets are 'a-z-' and 'A-Z_' and are the same length.
#
# Defined above DR_KEYS rather than beside its friends, because the array below
# is built by calling it at source time.
dr_agent_args_key() {
    printf 'DRAUGR_AGENT_ARGS_%s' "$(printf '%s' "$1" | tr 'a-z-' 'A-Z_')"
}

# Every key Draugr understands. dr-config iterates this, dr-doctor validates
# against it, and an unknown DRAUGR_* in a config file is reported rather than
# silently ignored.
DR_KEYS=(
    DRAUGR_AGENT DRAUGR_AGENT_ARGS DRAUGR_ATTACH DRAUGR_SANDBOX DRAUGR_MEMORY DRAUGR_CPUS DRAUGR_CLONE
    DRAUGR_TEMPLATE DRAUGR_KIT DRAUGR_KIT_STORE DRAUGR_PORTS DRAUGR_HOST_PORTS DRAUGR_MOUNTS
    DRAUGR_MODEL DRAUGR_MODEL_URL DRAUGR_MODEL_FAST
    DRAUGR_ENV
    DRAUGR_DATA DRAUGR_DATA_PUSH DRAUGR_DATA_PULL DRAUGR_DATA_DELETE DRAUGR_DATA_CHMOD
    DRAUGR_DATA_DIFF_MAX
    DRAUGR_BRANCH DRAUGR_REMOTE DRAUGR_REQUIRE_CLEAN DRAUGR_AUTO_SYNC DRAUGR_ON_MISSING_REPO
    DRAUGR_STOP_ON_EXIT
    DRAUGR_MEM_SYNC DRAUGR_MEM_STORE
    DRAUGR_SCAN DRAUGR_SCAN_PATTERNS DRAUGR_SCAN_FAIL
)

# One DRAUGR_AGENT_ARGS_<AGENT> per agent, appended rather than typed out.
#
# These are the only keys with NO built-in default, deliberately: _dr_defaults
# leaves them unset so that a set-but-empty value stays distinguishable from an
# absent one. "no arguments for codex, whatever the generic key says" is a real
# thing to want, and it is spelled DRAUGR_AGENT_ARGS_CODEX="".
for _dr_a in "${DR_AGENTS[@]}"; do
    DR_KEYS+=("$(dr_agent_args_key "$_dr_a")")
done
unset _dr_a

# -g matters: if a caller sources this file from inside a function - which every
# bats test does - a plain `declare -A` would scope the array to that function.
# It would then vanish on return, and the later DR_ORIGIN[DRAUGR_KIT]= would be
# an *indexed* array subscript, i.e. arithmetic on the string ".draugr/kit".
declare -gA DR_ORIGIN=()

# Config layers that exist on disk but were NOT sourced, because they are
# untrusted. A skipped layer is otherwise indistinguishable from one that set
# nothing, so dr-config reads this to say so out loud rather than leaving you to
# wonder why the value you wrote is not in the table. Same -g reasoning as above.
declare -ga DR_UNTRUSTED=()

# shellcheck disable=SC2034  # these are the config surface; every dr-* reads them
_dr_defaults() {
    DRAUGR_AGENT=claude
    # Handed to the agent after "--" on every dr-go. Empty keeps today's
    # behaviour exactly; set it to "--continue" to resume by default.
    DRAUGR_AGENT_ARGS=

    # ssh | sbx - how dr-go and dr-shell get a terminal inside the mound.
    #
    # ssh, because it is the only one where Ctrl-Z works. sbx.exe is a WINDOWS
    # binary reached through WSL interop, and suspending it suspends the relay
    # rather than anything in the sandbox: the session stops responding and dies
    # a few seconds later with "inspect exec: context deadline exceeded".
    # Measured against sbx 0.37.1, both ways.
    #
    # Over ssh the remote pty does its own job control, so Ctrl-Z stops the agent
    # and hands you a shell in the mound, and fg puts you back. That is the
    # reason Draugr runs in WSL at all.
    DRAUGR_ATTACH=ssh

    DRAUGR_SANDBOX=              # empty => draugr-<repo leaf>
    DRAUGR_MEMORY=               # empty => sbx default (50% of host RAM, max 32 GiB)
    DRAUGR_CPUS=                 # empty => sbx default (all)
    DRAUGR_CLONE=true
    DRAUGR_TEMPLATE=
    # A LIST, space separated. sbx accepts --kit repeatedly and merges the
    # results, so entries add to one another rather than overriding.
    DRAUGR_KIT=.draugr/kit
    DRAUGR_KIT_STORE="$DR_CONFIG_USER/kits"

    DRAUGR_PORTS=
    # Ports on THIS machine that the mound is allowed to reach, space
    # separated. Bare port numbers: the address they belong to is resolved on
    # every dr-up and never stored, because it does not survive a reboot.
    DRAUGR_HOST_PORTS=
    DRAUGR_MOUNTS=

    # The agent's OWN model, when it should not be its vendor's cloud. Empty is
    # the default and changes nothing about how the agent reaches its service.
    DRAUGR_MODEL=
    # Where that model is served: a bare port on THIS machine, resolved at every
    # attach because the address does not survive a reboot, or a full URL used
    # exactly as written. The default is the query-only proxy in
    # share/ollama-proxy rather than Ollama's own 11434, because the port that
    # serves inference there also serves DELETE /api/delete.
    DRAUGR_MODEL_URL=11435
    # The cheap background tier. Empty means "whatever DRAUGR_MODEL is": two
    # models are only faster if both stay resident, and a second one that evicts
    # the first costs more in reloads than the smaller model saves.
    DRAUGR_MODEL_FAST=
    # Arbitrary environment for the agent's session, as space-separated
    # NAME=value pairs. The escape hatch for anything Draugr has no key of its
    # own for - a local model's context limit being the case it was written for,
    # where the variable that does it is undocumented and may be renamed.
    DRAUGR_ENV=

    DRAUGR_DATA=
    DRAUGR_DATA_PUSH=auto
    DRAUGR_DATA_PULL=manual
    DRAUGR_DATA_DELETE=false
    DRAUGR_DATA_CHMOD=D755,F644

    # Per-file ceiling for `dr-data diff`, in bytes. Data files are routinely
    # enormous, and a real diff of a 4 GB CSV helps nobody - so anything larger
    # is reported by name and size instead of by content. 256 KB covers the
    # scripts and config that are worth reading closely.
    DRAUGR_DATA_DIFF_MAX=262144

    DRAUGR_BRANCH=               # empty => the branch currently checked out
    DRAUGR_REMOTE=draugr
    DRAUGR_REQUIRE_CLEAN=true
    DRAUGR_AUTO_SYNC=true

    # Off, because leaving it running is what people expect and stopping breaks
    # a workflow the kit format explicitly supports: publishedPorts and startup
    # commands exist so a mound can SERVE something, and that dies with it.
    # Measured on one machine: a running mound holds ~1.4 GB, and a cold start
    # costs 4.2s against 0.36s when it is already up. Worth opting into for
    # projects that serve nothing; not worth imposing.
    DRAUGR_STOP_ON_EXIT=false

    # What to do when you point Draugr at a directory that is not a repository.
    # "fail" by default: creating a git repo in somebody's folder is a real side
    # effect and not something to do because they mistyped a path.
    #   fail              refuse, and say what the alternatives are
    #   create-add-all    init and commit everything - "I forgot to git init"
    #   create-data-only  init with a .gitignore of "*", so nothing is tracked
    #                     and every file travels by DRAUGR_DATA instead
    DRAUGR_ON_MISSING_REPO=fail

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
    DR_UNTRUSTED=()

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
        # run carries on with the layers below it. Remember which ones, so the
        # skip can be reported again at the end, where it will be read.
        dr_trust_check "$layer" || { DR_UNTRUSTED+=("$layer"); continue; }

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

    # STEP 5 - now that DRAUGR_AGENT is final, resolve the things that depend on
    # which agent it is. This has to be last: both are chosen by a setting the
    # cascade decides, so doing either earlier would pick from the wrong layer.

    # DRAUGR_AGENT_ARGS carries the AGENT's own flags - "--continue" is Claude
    # Code's, "resume --last" is Codex's, and neither means anything to the
    # other. So one machine-wide value is wrong the moment a second agent is in
    # play, and there is no way to guard it by hand: a shell conditional in
    # ~/.config/draugr/config cannot work, because that layer is sourced BEFORE
    # the project one and $DRAUGR_AGENT is still the default while it runs.
    #
    # Hence a key per agent, which REPLACES the generic one rather than adding to
    # it - the same rule .draugr/kit.<agent>/ follows against .draugr/kit/.
    #
    # ${!k+set} rather than ${!k:+set}: an empty DRAUGR_AGENT_ARGS_CODEX is a
    # deliberate "nothing for codex", not silence, and must beat a generic value.
    local _ak; _ak=$(dr_agent_args_key "$DRAUGR_AGENT")
    if [ -n "${!_ak+set}" ]; then
        # shellcheck disable=SC2034  # read by dr-go, like the rest of the surface
        DRAUGR_AGENT_ARGS=${!_ak}
        DR_ORIGIN[DRAUGR_AGENT_ARGS]="${DR_ORIGIN[$_ak]:-built-in default} (via $_ak)"
    fi

    dr_agent_load
}

# ---------------------------------------------------------------------------
# Agent modules
#
# Everything Draugr does is the same for every agent except where an agent's own
# private layout is involved - which today means memory, and little else. That
# knowledge lives in lib/agents/<agent>.sh rather than in a case statement in
# each command, because it is the part most likely to be wrong: it is undocumented
# by the agents themselves, measured rather than published, and changes without
# notice. One file per agent means a wrong guess about one cannot break another.
#
# lib/agents/default.sh carries the interface and is what an agent we have not
# measured gets - which is the honest answer for eight of sbx's ten.
# ---------------------------------------------------------------------------

# dr_agent_load - source the module for $DRAUGR_AGENT, or the default.
#
# Called twice: once at the bottom of this file, so that a command which never
# reads a config still has the functions, and again at the end of dr_load_config
# once the cascade has settled. Sourcing a second module simply redefines every
# function, which is why each module must define ALL of them - a partial module
# would leave one agent's answers standing in another agent's session.
dr_agent_load() {
    local agent=${DRAUGR_AGENT:-claude} file
    file="$DRAUGR_ROOT/lib/agents/$agent.sh"
    [ -f "$file" ] || file="$DRAUGR_ROOT/lib/agents/default.sh"
    dr_debug "agent module: ${file#"$DRAUGR_ROOT"/}"
    # shellcheck disable=SC1090  # path is only known at runtime
    . "$file" || dr_die "could not load the agent module $file"
}

# dr_agent_known - the agents Draugr has a module for, space separated.
#
# Derived from the directory rather than from a list someone has to remember to
# update, so adding lib/agents/gemini.sh is the whole of adding gemini. "default"
# is not an agent, so it is left out of the answer.
dr_agent_known() {
    local file name out=''
    for file in "$DRAUGR_ROOT"/lib/agents/*.sh; do
        [ -f "$file" ] || continue
        name=$(basename "$file" .sh)
        [ "$name" = default ] && continue
        out+=" $name"
    done
    printf '%s' "${out# }"
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

# dr_context_create - dr_context, for the two commands allowed to make a repo.
#
# Only dr-up and dr-init call this. Everything else keeps dr_context and its
# refusal, for the same reason dr-status will not start a stopped mound: a
# command you run to find out what is going on must not change what is going on.
#
# The awkward part is ordering. The policy lives in the config, the project
# config lives in the directory, and the directory is not a repository yet - so
# the config has to be loaded against a plain path first, and dr_load_config has
# to be called EXACTLY ONCE. A second call would see the values the first one
# computed, decide they came from the environment, and give them precedence over
# every config file. Hence one load, then act.
dr_context_create() {
    local dir
    dir=$(git rev-parse --show-toplevel 2>/dev/null) || dir=$PWD
    dr_require_win_path "$dir"
    dr_load_config "$dir"

    if ! git -C "$dir" rev-parse --git-dir >/dev/null 2>&1; then
        dr_repo_create "$dir"
    fi

    DR_REPO=$dir
    # shellcheck disable=SC2034  # read by the dr-* command that called us
    DR_REPO_WIN=$(dr_path_win "$dir")
}

# dr_repo_create <dir> - act on DRAUGR_ON_MISSING_REPO. Fatal for "fail".
# Sets DR_REPO_CREATED to the mode used, so the caller knows it is standing in a
# repository that did not exist a moment ago and that anything it writes next is
# its to commit. Empty when the repo was already there.
DR_REPO_CREATED=

dr_repo_create() {
    local dir=$1 mode=${DRAUGR_ON_MISSING_REPO:-fail}

    # Validated before anything is written, so a typo in the setting is a clean
    # refusal rather than half a repository.
    case "$mode" in
        fail) dr_die \
            "$dir is not a git repository" \
            "Draugr works on one repository at a time: the sandbox gets a clone of it." \
            "Run 'git init' here, or set DRAUGR_ON_MISSING_REPO to have Draugr do it:" \
            "  create-add-all     commit what is here, then work in git as usual" \
            "  create-data-only   track nothing; files travel by DRAUGR_DATA instead" ;;
        create-add-all|create-data-only) : ;;
        *) dr_die "DRAUGR_ON_MISSING_REPO is '$mode'" \
                  "Expected one of: fail, create-add-all, create-data-only." \
                  "It came from ${DR_ORIGIN[DRAUGR_ON_MISSING_REPO]}." ;;
    esac

    git -C "$dir" init -q -b "${DRAUGR_BRANCH:-main}" \
        || dr_die "could not create a git repository in $dir"

    # A commit needs an identity, and someone whose machine has no global one
    # would otherwise get git's four-line lecture from inside a Draugr command.
    # Set it locally, on this throwaway repo only, and say so.
    if ! git -C "$dir" var GIT_COMMITTER_IDENT >/dev/null 2>&1; then
        git -C "$dir" config user.name Draugr
        git -C "$dir" config user.email draugr@localhost
        dr_info "no git identity configured; set one locally for this repo"
    fi

    case "$mode" in
    create-data-only)
        # The dummy repo: one tracked file, which ignores everything including
        # itself - so `git status` is empty from now on and DRAUGR_REQUIRE_CLEAN
        # never has anything to complain about. -f is required precisely because
        # the pattern already covers .gitignore.
        printf '%s\n' '# Draugr data-only mode: git tracks nothing here.' '*' \
            > "$dir/.gitignore"
        git -C "$dir" add -f .gitignore
        git -C "$dir" commit -qm "Draugr: data-only repository"

        # The mode is inert without something for dr-data to carry, so seed it.
        # Set in this shell as well as on disk: re-loading the config to pick it
        # up is exactly the double-load dr_context_create must not do.
        if [ ! -f "$dir/.draugr.conf" ]; then
            printf '%s\n' \
                '# Written by Draugr for a directory that had no git repository.' \
                '# Nothing is tracked by git here; these patterns decide what' \
                '# actually travels to and from the mound. See dr-data --help.' \
                'DRAUGR_DATA="*"' \
                'DRAUGR_ON_MISSING_REPO=create-data-only' > "$dir/.draugr.conf"
            dr_trust_add "$dir/.draugr.conf"
        fi
        [ -n "${DRAUGR_DATA:-}" ] || {
            DRAUGR_DATA='*'
            DR_ORIGIN[DRAUGR_DATA]="data-only mode"
        }
        DR_REPO_CREATED=$mode
        dr_ok "created a data-only repository in $dir"
        ;;

    create-add-all)
        # Everything is committed, so anything that must NOT be committed has to
        # be ignored first. Two sets matter, and the first is a safety fix rather
        # than tidiness: dr-scan only reports UNTRACKED files, so committing a
        # credential would put it in the agent's clone and in history, and
        # silence the scan that exists to catch it.
        if [ ! -f "$dir/.gitignore" ]; then
            local pat pats=()
            printf '%s\n' '# Written by Draugr. Credential-shaped names first:' \
                > "$dir/.gitignore"
            read -ra pats <<< "${DRAUGR_SCAN_PATTERNS:-}"
            [ ${#pats[@]} -eq 0 ] || printf '%s\n' "${pats[@]}" >> "$dir/.gitignore"

            # Draugr's own per-checkout files. Without these the very next dr-up
            # writes .draugr/kit.applied, the tree is dirty, and the dr-go after
            # that refuses - in a repo Draugr created and called clean.
            printf '\n%s\n%s\n%s\n%s\n' \
                '# Draugr: describes this checkout, not the project.' \
                '.draugr.local.conf' '.draugr/kit.applied' '.draugr/tmp/' \
                >> "$dir/.gitignore"

            # Then the data patterns: those travel by rsync, and the README is
            # explicit that they are expected to be gitignored on both sides.
            read -ra pats <<< "${DRAUGR_DATA:-}"
            if [ ${#pats[@]} -gt 0 ]; then
                printf '\n%s\n' '# DRAUGR_DATA travels beside git, not through it:' \
                    >> "$dir/.gitignore"
                for pat in "${pats[@]}"; do printf '%s\n' "$pat" >> "$dir/.gitignore"; done
            fi
        fi

        # Says what was committed and what changes from here, because this mode
        # hands back an ordinary git repo - with the dirty-tree check that comes
        # with one - and that surprises people who wanted the other mode.
        git -C "$dir" add -A
        git -C "$dir" commit -qm "Draugr: initial commit" \
            || dr_die "could not make the initial commit in $dir"
        DR_REPO_CREATED=$mode
        dr_ok "created a git repository in $dir and committed what was there"
        printf '  %sIt is an ordinary repo now: commit before each session, or%s\n' \
            "$_DR_DIM" "$_DR_OFF" >&2
        printf '  %suse dr-go --dirty. Check what was committed before you rely on it.%s\n' \
            "$_DR_DIM" "$_DR_OFF" >&2
        ;;
    esac
}

# dr_repo_commit_setup <dir> - commit the files dr-init wrote after the repo.
#
# dr-init writes .draugr.conf and the kit *after* the repository exists, so
# without this the repo it just created is dirty the moment it hands back. In
# data-only mode that is not merely untidy: "the tree is always clean" is the
# entire point of the mode, and breaking it on the first command would be a poor
# way to introduce it. Does nothing unless dr_repo_create just ran.
dr_repo_commit_setup() {
    local dir=$1
    [ -n "$DR_REPO_CREATED" ] || return 0

    case "$DR_REPO_CREATED" in
    create-data-only)
        # Named paths and -f, because .gitignore says "*" and covers these too.
        # Deliberately not `add -A`: tracking the user's own files is the one
        # thing this mode exists not to do.
        local p paths=()
        for p in .gitignore .draugr.conf .draugr/kit; do
            if [ -e "$dir/$p" ]; then paths+=("$p"); fi
        done
        if [ ${#paths[@]} -gt 0 ]; then git -C "$dir" add -f "${paths[@]}"; fi
        ;;
    create-add-all)
        git -C "$dir" add -A
        ;;
    esac

    # An empty stage is a fine outcome: it means dr-init found everything
    # already in place and wrote nothing. --quiet exits 1 when there IS
    # something staged, which is why the commit hangs off the failure.
    git -C "$dir" diff --cached --quiet \
        || git -C "$dir" commit -qm "Draugr: project setup"
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
# Attaching
#
# Two transports, and they are NOT equivalent.
#
# `sbx run` and `sbx exec` reach the mound through sbx.exe, which is a Windows
# binary that WSL runs over interop. The terminal you are typing at belongs to
# WSL; the process reading it does not. Ctrl-Z therefore suspends the relay
# rather than anything inside the sandbox: the keystroke never arrives, the
# daemon stops hearing from its client, and a few seconds later the whole
# session dies with "inspect exec: context deadline exceeded".
#
# ssh has no such seam. The client is a native Linux binary and the far end is a
# real pty, so job control happens inside the sandbox where it belongs - Ctrl-Z
# stops the agent and hands you the mound's own shell, fg puts you back. Both
# measured against sbx 0.37.1; see docs/WORKFLOW.md.
#
# That is why DRAUGR_ATTACH defaults to ssh, and it is the reason Draugr runs in
# WSL rather than PowerShell in the first place.
# ---------------------------------------------------------------------------

# The Host pattern dr-setup writes into ~/.ssh/config - the same one git and
# rsync already use, so attaching needs no port, no key and no new setup.
dr_ssh_host() { printf '%s.sbx' "$DRAUGR_SANDBOX"; }

# Checked before anything is started, so a typo in the setting is a clean
# refusal rather than a transport silently chosen for you.
dr_attach_check() {
    case "$DRAUGR_ATTACH" in
        ssh|sbx) return 0 ;;
        *) dr_die "DRAUGR_ATTACH is '$DRAUGR_ATTACH'" \
                  "Expected ssh (job control works) or sbx (it does not)." \
                  "It came from ${DR_ORIGIN[DRAUGR_ATTACH]:-somewhere unexpected}." ;;
    esac
}

# printf %q over a whole argv. Bash's own quoting, produced by bash here and read
# back by bash on the far side, which is the only pair guaranteed to agree.
dr_shquote() {
    local out='' a
    for a in "$@"; do out+=" $(printf '%q' "$a")"; done
    printf '%s' "${out# }"
}

# ---------------------------------------------------------------------------
# The agent's own model
#
# DRAUGR_MODEL points the agent at something other than its vendor's cloud. The
# three functions here answer the three questions that come with that: is this a
# port or a URL, what address does the mound actually dial, and is the
# combination one that can work at all.
# ---------------------------------------------------------------------------

# dr_model_is_port <value> - true when DRAUGR_MODEL_URL names a local port.
#
# Digits and nothing else. There is deliberately no third spelling: "localhost"
# means the MOUND from inside the mound, so a value like localhost:11435 is a
# URL like any other and must not be given the host-port treatment below - it
# would resolve to the sandbox talking to itself and fail with nothing to read.
dr_model_is_port() {
    case "${1:-}" in
        ''|*[!0-9]*) return 1 ;;
    esac
}

# dr_model_url - DRAUGR_MODEL_URL as an address the mound can actually open.
#
# A bare port becomes http://<this machine>:<port>, resolved NOW rather than
# stored, for the same reason dr-hostport re-resolves on every start: WSL hands
# out its address per boot, so anywhere you could write it down is somewhere it
# would be wrong. Anything else is somebody else's endpoint and is printed back
# untouched. Returns 1 when the address cannot be worked out at all.
dr_model_url() {
    local ip
    if ! dr_model_is_port "${DRAUGR_MODEL_URL:-}"; then
        printf '%s' "${DRAUGR_MODEL_URL:-}"
        return 0
    fi
    ip=$(dr_host_ip) || return 1
    printf 'http://%s:%s' "$ip" "$DRAUGR_MODEL_URL"
}

# dr_model_probe <url> - what is actually answering there. Prints one word:
#
#   proxy    the query-only front door, with a model server behind it
#   stalled  the proxy answers, but nothing is behind it
#   bare     a model server with no proxy - the agent can administer it too
#   alive    answering, but neither of those: somebody else's endpoint
#   dead     nothing listening at all
#   unknown  no curl here, so the question cannot be asked
#
# Only `dead` and `stalled` mean the session cannot work, and that distinction is
# the whole point of returning a word rather than a status. A company endpoint
# that has never heard of /healthz answers 404 and is perfectly usable, so
# treating "not the proxy" as "broken" would refuse the one case DRAUGR_MODEL_URL
# takes a full URL for.
#
# /healthz is nginx's own, served with no upstream, so it separates the proxy
# from the thing behind it - which is why `stalled` can be told from `proxy` at
# all. From inside the agent those two fail identically.
dr_model_probe() {
    local url=$1 code
    command -v curl >/dev/null 2>&1 || { printf 'unknown'; return 0; }

    code=$(curl -s -o /dev/null -m 4 -w '%{http_code}' "$url/healthz" 2>/dev/null) || code=000

    # The proxy answered. Ask the second question it cannot answer for itself.
    if [ "$code" = 200 ]; then
        code=$(curl -s -o /dev/null -m 4 -w '%{http_code}' "$url/api/version" 2>/dev/null) || code=000
        [ "$code" = 200 ] && { printf 'proxy'; return 0; }
        printf 'stalled'
        return 0
    fi

    # 000 is curl for "no HTTP response at all" - refused, unreachable, timed
    # out. Any other code means something is there and simply has no /healthz.
    [ "$code" = 000 ] && { printf 'dead'; return 0; }

    code=$(curl -s -o /dev/null -m 4 -w '%{http_code}' "$url/api/version" 2>/dev/null) || code=000
    [ "$code" = 200 ] && { printf 'bare'; return 0; }
    printf 'alive'
}

# dr_model_check - refuse the two combinations that cannot work.
#
# Both are refusals rather than warnings, because neither has a working outcome
# to warn about. An agent whose module cannot point it anywhere would ignore
# DRAUGR_MODEL and keep talking to its cloud, which is the worst failure this
# feature has: you would believe the work was staying local while it was not.
#
# The second is the missing host-port rule. Without it the mound's connection is
# accepted by the sandbox's interception layer and dropped, so the symptom is a
# timeout at the agent's first prompt that names nothing and points nowhere.
dr_model_check() {
    local p
    [ -n "${DRAUGR_MODEL:-}" ] || return 0

    if ! dr_agent_model_supported; then
        dr_die "DRAUGR_MODEL is set, but Draugr cannot point $DRAUGR_AGENT at another endpoint" \
            "Which variables an agent reads is per-agent, and this one has not been measured." \
            "Unset DRAUGR_MODEL, or run this project with DRAUGR_AGENT=claude."
    fi

    # A URL is somebody else's address, reached under the ordinary network
    # policy. DRAUGR_HOST_PORTS has nothing to say about it; dr-policy does.
    dr_model_is_port "${DRAUGR_MODEL_URL:-}" || return 0

    for p in ${DRAUGR_HOST_PORTS:-}; do
        [ "$p" = "$DRAUGR_MODEL_URL" ] && return 0
    done

    # Naming the one line that fixes it, rather than the key in the abstract:
    # the two keys are not redundant and Draugr will not manufacture the consent
    # for a hole into your machine out of the fact that you named an address.
    dr_die "DRAUGR_MODEL_URL is port $DRAUGR_MODEL_URL, which is not in DRAUGR_HOST_PORTS" \
        "The mound cannot reach it, and the agent would fail at its first prompt." \
        "Add it:  DRAUGR_HOST_PORTS=\"$DRAUGR_MODEL_URL\""
}

# dr_env_pairs - DRAUGR_ENV as one validated NAME=value a line.
#
# The escape hatch, for anything Draugr has no key of its own for. It exists
# because the variable that caps Claude Code's context is undocumented and was
# added between two point releases: a typed DRAUGR_MODEL_CONTEXT would hardcode
# a name nobody has published and cannot be routed around when it changes,
# whereas a passthrough leaves that judgement where it belongs.
#
# Validated rather than passed through, because every failure here is silent
# otherwise. An unrecognised variable is IGNORED by the agent, not refused, so a
# typo'd name produces a session that looks correct and behaves as though the
# setting were never written - which is exactly the failure this key exists to
# avoid, arrived at from the other side.
dr_env_pairs() {
    local entry name
    local -a entries=()
    [ -n "${DRAUGR_ENV:-}" ] || return 0

    # read -ra splits on whitespace WITHOUT globbing - the same trap documented
    # at dr_kit_refs. An unquoted expansion would turn a value containing * into
    # a listing of the current directory.
    read -ra entries <<< "$DRAUGR_ENV"

    for entry in "${entries[@]}"; do
        # Nothing before the first "=" is not a pair, and the most likely way to
        # write one is to forget that the separator between entries is a space.
        case "$entry" in
            *=*) ;;
            *) dr_die "DRAUGR_ENV: \"$entry\" is not NAME=value" \
                   "Entries are separated by spaces, so a value cannot contain one." \
                   'Example:  DRAUGR_ENV="CLAUDE_CODE_DISABLE_1M_CONTEXT=1 FOO=bar"' ;;
        esac

        name=${entry%%=*}

        # A name that is not a shell identifier cannot be exported at all: the
        # rcfile would fail to source, taking the whole session with it rather
        # than just this variable.
        case "$name" in
            ''|[0-9]*|*[!A-Za-z0-9_]*)
                dr_die "DRAUGR_ENV: \"$name\" is not a variable name" \
                    "Letters, digits and underscore, and not starting with a digit." \
                    "The entry was:  $entry" ;;
        esac

        # PATH is the one that looks harmless and is not: it REPLACES rather than
        # extends, so an absolute one drops the directory holding the agent
        # binary and the next dr-go ends in "command not found" before the agent
        # starts. The kit spec carries the same warning about the same hazard.
        case "$name" in
            PATH|HOME)
                dr_die "DRAUGR_ENV must not set $name" \
                    "Draugr and the agent both depend on it inside the mound, and a" \
                    "replacement here breaks the session before it starts." ;;
        esac

        printf '%s\n' "$entry"
    done
}

# dr_attach_rc <command...> - the bash rcfile that starts the agent.
#
# The obvious spelling - putting the agent's command straight in the rcfile -
# HANGS. Bash has not enabled job control by the time it runs its startup files,
# so the first Ctrl-Z suspends a process that nothing is then able to resume.
# Starting it from PROMPT_COMMAND instead defers it to the first prompt, by
# which point the shell owns the terminal and the agent is an ordinary job.
#
# 148 is 128 + SIGTSTP: what $? holds after a foreground job is STOPPED rather
# than finished. It is what keeps the two endings apart -
#
#   Ctrl-Z       -> 148 -> stay, and you have the mound's shell
#   agent exits  -> its own status -> leave, exactly as `sbx run` did
#
# and it is not optional. A suspended job does not abandon the rest of its
# command list, so a bare `agent; exit` ends the session on Ctrl-Z as well.
# Measured, after writing it that way first.
dr_attach_rc() {
    local cmd url k v model_keys='' envpairs
    cmd=$(dr_shquote "$@")

    # Collected before the loop rather than piped into one: dr_env_pairs dies on
    # a malformed entry, and a process substitution would take that exit with it
    # - leaving an rcfile that quietly lacked the variables and a session that
    # looked fine. The message has already reached stderr by the time we return.
    envpairs=$(dr_env_pairs) || return 1

    # Single quotes throughout: none of this is for us to expand. It is a file to
    # be read by a bash that has not started yet, in another machine.
    # shellcheck disable=SC2016
    printf '%s\n' \
        '# Written by Draugr at attach time. Overwritten on the next dr-go.' \
        '[ -f ~/.bashrc ] && . ~/.bashrc'

    # The agent's own model, when DRAUGR_MODEL asks for one. This is the only
    # place it can go: sbx's ssh proxy honours no AcceptEnv, so nothing crosses
    # that way, and a kit is committed while the address is known only now.
    if [ -n "${DRAUGR_MODEL:-}" ]; then
        # Dying rather than carrying on is the point. An unresolved address would
        # leave the variables unset and the agent talking to its cloud while you
        # believed otherwise, which is the one failure this feature must not have.
        url=$(dr_model_url) || dr_die \
            "DRAUGR_MODEL is set, but this machine's address could not be resolved" \
            "The mound needs it to reach port ${DRAUGR_MODEL_URL:-}." \
            "Check the network with:  dr-doctor"

        # Quoted with %q here and read back by a bash over there - the same pair
        # that agrees about the command line above. IFS splits on the first = only,
        # because v is the last field and takes everything left, = included.
        while IFS='=' read -r k v; do
            [ -n "$k" ] || continue
            model_keys+=" $k"
            printf 'export %s=%s\n' "$k" "$(dr_shquote "$v")"
        done < <(dr_agent_model_env "$url" "$DRAUGR_MODEL" "${DRAUGR_MODEL_FAST:-$DRAUGR_MODEL}")
    fi

    # DRAUGR_ENV last, so an explicit setting beats one Draugr derived: an escape
    # hatch the tool can silently overrule is not an escape hatch. The collision
    # is still said out loud, because two settings and a quiet winner is how an
    # afternoon goes missing.
    while IFS='=' read -r k v; do
        [ -n "$k" ] || continue
        case " $model_keys " in
            *" $k "*) dr_warn "DRAUGR_ENV sets $k, overriding what DRAUGR_MODEL derived" ;;
        esac
        printf 'export %s=%s\n' "$k" "$(dr_shquote "$v")"
    done <<< "$envpairs"

    # shellcheck disable=SC2016
    printf '%s\n' \
        '_dr_pc=${PROMPT_COMMAND-}' \
        "PROMPT_COMMAND='PROMPT_COMMAND=\$_dr_pc; $cmd; _dr_s=\$?; [ \$_dr_s -eq 148 ] || exit \$_dr_s'"
}

# dr_attach_remote <dir> [command...] - the single string handed to ssh.
#
# With no command it is a plain interactive shell, which is dr-shell's job. With
# one it is the agent, started as described above.
#
# The rcfile travels base64-encoded rather than as a heredoc. It passes through
# ssh, which hands it to a remote shell, and every layer in between would
# otherwise want its own round of quoting; base64 has no metacharacters to
# argue about.
dr_attach_remote() {
    local dir=$1; shift
    # $HOME is the MOUND's home, expanded over there by the shell ssh hands this
    # to - which is why it stays in single quotes here.
    # shellcheck disable=SC2016
    local rc='$HOME/.cache/draugr/attach-rc' b64

    if [ $# -eq 0 ]; then
        printf 'cd %s && exec bash -i' "$(printf '%q' "$dir")"
        return 0
    fi

    b64=$(dr_attach_rc "$@" | base64 | tr -d '\n')
    # Same again: every $ in this format string belongs to the far side.
    # shellcheck disable=SC2016
    printf 'mkdir -p $HOME/.cache/draugr && printf %%s %s | base64 -d > %s && cd %s && exec bash --rcfile %s -i' \
        "$b64" "$rc" "$(printf '%q' "$dir")" "$rc"
}

# dr_ssh_attach <dir> [command...] - hand the terminal over and wait.
#
# Returns whatever the far side returned, which the rcfile arranges to be the
# agent's own status.
dr_ssh_attach() {
    local dir=$1 remote; shift
    remote=$(dr_attach_remote "$dir" "$@")
    dr_debug "ssh -t $(dr_ssh_host) $remote"
    # -t because a remote command is given, and without it ssh allocates no pty
    # at all - the agent would have no terminal to draw on. Callers have already
    # been through dr_require_tty, so there is one to hand over.
    ssh -t "$(dr_ssh_host)" "$remote"
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

# dr_sandboxes_running - the name of every running sandbox, one per line.
#
# Every sandbox, not only the ones Draugr named. A mound holds a Hyper-V microVM
# open whoever created it, and the reason to want this list - reclaiming memory,
# or tidying up before shutting the machine down - does not care which tool made
# them. dr-stop --all lists what it found and asks before acting, rather than
# quietly reaching past its own sandboxes.
dr_sandboxes_running() {
    local json
    json=$(dr_sbx ls --json 2>/dev/null) || return 1
    printf '%s' "$json" | jq -r \
        '(.sandboxes // [])[] | select(.status == "running") | .name' 2>/dev/null
}

# ---------------------------------------------------------------------------
# DRAUGR_DATA - files that travel beside git rather than through it
#
# One list, two consumers with different syntaxes: rsync filter rules (dr-data)
# and shell glob matching (the clean-tree exemption in dr-go). They must agree,
# or a file would be transferred but still block dr-go, so both interpretations
# of an entry are defined here, together, in one place.
#
#   ending in "/"     a directory: that prefix and everything under it
#   containing "/"    a path pattern, anchored at the repo root
#   neither           a bare name or extension, matched ANYWHERE in the tree
# ---------------------------------------------------------------------------

# _dr_data_entries - split DRAUGR_DATA into an array WITHOUT globbing it.
#
# `for entry in $DRAUGR_DATA` looks like the obvious way to do this and is wrong.
# Unquoted expansion performs word splitting *and pathname expansion*, so
# "tmp/**" is silently replaced by whatever tmp/ happens to contain in the
# current directory - turning a pattern into a snapshot of today's filenames,
# dependent on the working directory, and missing anything created later.
#
# `read -ra` splits on IFS and does not glob, which is what we actually want.
_dr_data_entries() {
    read -ra _DR_DATA_ENTRIES <<< "${DRAUGR_DATA:-}"
}

# dr_data_matches <repo-relative-path> - is this path covered by DRAUGR_DATA?
#
# Everything below turns on one rule: a `case` pattern is a GLOB, and QUOTING is
# what decides which parts of it are wildcards. Quoted text is literal; unquoted
# text is a pattern; and a single pattern can mix the two. So
#
#     case "$path" in "$entry")  …   # matches a file literally named *.parquet
#     case "$path" in  $entry )  …   # matches every .parquet file
#
# are completely different tests. Both forms are used deliberately below.
dr_data_matches() {
    local path=$1 entry
    [ -n "${DRAUGR_DATA:-}" ] || return 1

    # The same plumbing dr_data_filters excludes, excluded here too - these two
    # have to give the same answer. A path that matched here but did not transfer
    # would be exempted from the clean-tree check and then never sent, which is
    # exactly the "one says yes, the other says no" bug the pairing exists to
    # prevent.
    case "$path" in
        .git|.git/*|.draugr|.draugr/*) return 1 ;;
    esac

    local _DR_DATA_ENTRIES=()
    _dr_data_entries
    for entry in "${_DR_DATA_ENTRIES[@]}"; do
        case "$entry" in
            */)
                # A directory, e.g. "scratch/raw/". The pattern is built from
                # three pieces:
                #
                #   "${entry%/}"   QUOTED, so literal. "%" trims from the back,
                #                  removing the trailing slash: -> scratch/raw
                #   /              a literal slash
                #   *              UNQUOTED, so a wildcard: anything at all
                #
                # The mandatory slash is what makes this precise: scratch/raw/r1
                # matches, scratch/rawdata/r1 does not. Keeping the entry quoted
                # also means a directory name containing [ or * is treated as
                # the characters the user typed.
                case "$path" in
                    "${entry%/}"/*) return 0 ;;
                esac
                ;;
            */*)
                # A path pattern, e.g. "tmp/**". Unquoted, so it globs.
                #
                # Worth knowing: in `case` - unlike filename globbing - "*"
                # matches slashes too, because no filesystem is involved. So
                # tmp/* would already match tmp/deep/y.bin, and here "**" is
                # exactly equivalent to "*". The "**" spelling is carried
                # through for rsync's benefit (dr_data_filters), where the two
                # genuinely differ.
                # shellcheck disable=SC2254  # unquoted on purpose: it IS a pattern
                case "$path" in
                    $entry) return 0 ;;
                esac
                ;;
            *)
                # A bare name or extension, e.g. "*.parquet".
                #
                # ${path##*/} is basename: "##" deletes the LONGEST prefix
                # matching */, so src/lib/b.parquet -> b.parquet. Matching the
                # basename is what lets one extension rule cover every depth.
                # shellcheck disable=SC2254  # unquoted on purpose: it IS a pattern
                case "${path##*/}" in
                    $entry) return 0 ;;
                esac
                ;;
        esac
    done
    return 1
}

# dr_data_filters - the same list as rsync filter rules, one per line.
#
# The order is the classic recipe and matters, because rsync takes the FIRST
# rule that matches: descend into every directory, then include what we want,
# then exclude everything else. dr-data pairs this with -m (--prune-empty-dirs)
# so the "*/" include does not leave a skeleton of empty directories behind.
dr_data_filters() {
    local entry

    # Plumbing first, because rsync takes the FIRST rule that matches and these
    # must win over anything DRAUGR_DATA says.
    #
    # .git is the one that bites. A slashless entry is unanchored and matches at
    # every depth, so DRAUGR_DATA="*.sample" quietly picks up .git/hooks/*.sample,
    # and DRAUGR_DATA="*" pushes the host's entire .git over the mound clone's -
    # replacing the agent's git metadata, remote and all. Neither is a pattern
    # anyone would expect to reach into a repository's internals.
    #
    # .draugr is ours: the kit belongs to git, and .draugr/tmp holds the staging
    # copies dr-mem makes, which would otherwise be swept into the agent's tree.
    # Written without a trailing slash so a `.git` *file* - what a submodule or a
    # worktree leaves behind - is excluded too, not just a directory.
    printf '%s\n' '--exclude=.git' '--exclude=.draugr'
    printf '%s\n' '--include=*/'

    # Split without globbing - see _dr_data_entries. Getting this wrong here
    # would hand rsync a list of literal filenames instead of the patterns.
    local _DR_DATA_ENTRIES=()
    _dr_data_entries
    for entry in "${_DR_DATA_ENTRIES[@]}"; do
        case "$entry" in
            # A directory needs both rules: the directory itself, and its contents.
            */)  printf -- '--include=/%s\n--include=/%s**\n' "$entry" "$entry" ;;
            # A leading "/" anchors the pattern at the transfer root, i.e. the repo.
            */*) printf -- '--include=/%s\n' "$entry" ;;
            # No slash: unanchored, so it matches at any depth.
            *)   printf -- '--include=%s\n' "$entry" ;;
        esac
    done
    printf '%s\n' '--exclude=*'
}

# dr_data_path_safe <path> - a name we are willing to write under the repo?
#
# rsync sanitises paths itself: modern versions strip a leading "/" and refuse a
# "..". But "the copy tool handles it" is a dependency, not a guarantee, and the
# sending side here is by definition the agent. The names are cheap to check and
# we are the ones writing the files, so we check them.
#
# Rejected: absolute paths, any ".." component, and control characters - the last
# because a newline in a filename also breaks the line-per-file parsing that every
# caller of this relies on, which would be a silently truncated review.
dr_data_path_safe() {
    local path=$1
    case "$path" in
        ''|/*)             return 1 ;;
        ..|../*|*/../*|*/..) return 1 ;;
        *[[:cntrl:]]*)     return 1 ;;
    esac
    return 0
}

# dr_data_exec_shaped <path> - would anyone ever RUN this file?
#
# Names only, and deliberately so. The instinct is to ask "did it arrive with the
# execute bit set", but that question has no useful answer here: a Draugr repo
# must live on a Windows drive, DrvFs reports every file as 0777, and --chmod is
# silently ignored there. Measured - a file rsync'd onto /mnt/c with
# --chmod=D755,F644 lands -rwxrwxrwx and runs. So the mode tells you nothing and
# the name is the only signal left.
#
# Kept narrow on purpose. A warning that fires on ordinary data is one people
# learn to scroll past, so extensions that are as often data as code - .bin, .ts,
# .run, .dat - are left out even though any of them could in principle be run.
dr_data_exec_shaped() {
    case "${1##*/}" in
        *.sh|*.bash|*.zsh|*.ksh|*.fish|*.py|*.pl|*.rb|*.lua|*.php)        return 0 ;;
        *.js|*.mjs|*.cjs|*.ps1|*.psm1|*.bat|*.cmd|*.vbs|*.wsf)            return 0 ;;
        *.exe|*.dll|*.so|*.so.*|*.dylib|*.msi|*.scr|*.jar)                return 0 ;;
        *.appimage|*.AppImage|*.desktop|*.service)                        return 0 ;;
        Makefile|makefile|GNUmakefile|*.mk|Dockerfile|Dockerfile.*)       return 0 ;;
    esac
    return 1
}

# dr_data_is_text <path> - no NUL byte in the first 8 KB.
#
# The same heuristic git uses - and, more to the point, the same one `diff` uses,
# so this never promises a diff that diff will then refuse to print. It also needs
# no `file` binary, which is one less thing to be missing inside a stripped-down
# mound. An empty file counts as text: there is nothing in it to be binary, and
# calling it binary would hide the one diff that matters, "this file was emptied".
dr_data_is_text() {
    local total stripped
    [ -s "$1" ] || return 0
    total=$(head -c 8192 "$1" | wc -c)
    stripped=$(head -c 8192 "$1" | LC_ALL=C tr -d '\000' | wc -c)
    [ "$total" = "$stripped" ]
}

# dr_mode_note <repo> <path> - "mode X => Y, no content change", or nothing.
#
# True only when the STAGED entry and HEAD hold the same blob under different
# modes. Anything else - an edit, an addition, a deletion - is not a mode-only
# change and gets no note.
dr_mode_note() {
    local repo=$1 path=$2 idx head imode hmode iblob hblob

    # A path git had to quote (spaces, non-ASCII) will not match as typed, and
    # guessing at the unquoting would be worse than saying nothing: the note is
    # a convenience, and its absence costs only the convenience.
    idx=$(git -C "$repo" ls-files -s -- "$path" 2>/dev/null) || return 1
    head=$(git -C "$repo" ls-tree HEAD -- "$path" 2>/dev/null) || return 1
    [ -n "$idx" ] && [ -n "$head" ] || return 1

    # ls-files -s  : "<mode> <blob> <stage>\t<path>"
    # ls-tree      : "<mode> blob <blob>\t<path>"
    imode=${idx%% *}
    hmode=${head%% *}
    iblob=$(printf '%s' "$idx"  | awk '{ print $2 }')
    hblob=$(printf '%s' "$head" | awk '{ print $3 }')

    [ "$imode" != "$hmode" ] || return 1
    [ "$iblob" = "$hblob" ] || return 1
    printf 'mode %s => %s, no content change\n' "$hmode" "$imode"
}

# dr_dirty_list <repo> - `git status --short`, with a mode-only change named.
#
# git prints "M  run.sh" whether the file was rewritten or merely made
# executable, and on a /mnt/c checkout the second is likelier than it looks.
# With core.fileMode=false a mode can only have reached the index through
# `git update-index --chmod`, a checkout, or a merge - never through `git add` -
# so reading that "M" as "I edited that" sends you hunting for an edit that does
# not exist.
#
# Measured, and the reason this exists: a dr-merge was blocked by a staged
# `100644 => 100755` on run.sh while the incoming commit carried THE SAME mode
# change. The refusal was correct and the message was unreadable.
dr_dirty_list() {
    local repo=${1:-$PWD} line path note
    while IFS= read -r line; do
        # "XY path". A rename is "XY old -> new", where neither half is the
        # path to ask git about, so it is left alone.
        path=${line:3}
        case "$line" in
            *" -> "*) printf '%s\n' "$line"; continue ;;
        esac
        if note=$(dr_mode_note "$repo" "$path"); then
            printf '%s   (%s)\n' "$line" "$note"
        else
            printf '%s\n' "$line"
        fi
    done < <(git -C "$repo" status --short 2>/dev/null)
}

# dr_data_dirty_only <repo> - true when every uncommitted change is a data file.
#
# This is the DRAUGR_REQUIRE_CLEAN exemption: churning a parquet file must not
# stop you starting a session, because that file is not travelling through git
# anyway. A single dirty *source* file still blocks, which is the point.
dr_data_dirty_only() {
    local repo=${1:-$PWD} line path
    [ -n "${DRAUGR_DATA:-}" ] || return 1

    # --porcelain gives "XY path"; the status letters are always the first two
    # columns, so cutting from the fourth character leaves the path.
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        path=${line:3}

        # A rename reads "old -> new"; judge it by the destination.
        case "$path" in
            *" -> "*) path=${path##* -> } ;;
        esac

        dr_data_matches "$path" || return 1
    done < <(git -C "$repo" status --porcelain 2>/dev/null)
    return 0
}

# dr_data_dirty_blockers <repo> - the uncommitted changes that are NOT exempt.
#
# The companion to dr_data_dirty_only, which answers yes or no. This one answers
# "which ones", because the yes/no version's caller printed `git status` in full:
# a repo with fifteen churning data files and one stray script then reported
# sixteen problems, buried the only real one, and made DRAUGR_DATA look as though
# it were being ignored.
dr_data_dirty_blockers() {
    local repo=${1:-$PWD} line path
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        path=${line:3}
        case "$path" in
            *" -> "*) path=${path##* -> } ;;
        esac
        if [ -n "${DRAUGR_DATA:-}" ] && dr_data_matches "$path"; then
            continue
        fi
        printf '%s\n' "$line"
    done < <(git -C "$repo" status --porcelain 2>/dev/null)
    return 0
}

# ---------------------------------------------------------------------------
# Kits
# ---------------------------------------------------------------------------

# DRAUGR_KIT is a LIST, because sbx kits compose.
#
# Measured against sbx 0.37.1: `--kit` takes the flag repeatedly, and two mixins
# on one sandbox contributed BOTH their install commands and BOTH their network
# allow rules, merged into a single policy. That is what makes a shared kit
# worth having - "the Lua toolchain" is a fact about you, not about one repo, and
# a library entry ADDS to the project's kit instead of replacing it.

# dr_kit_reserved_names - names a kit must not take, one per line.
#
# The composition always contains the agent's own kit, so the agent's name is
# spoken for. Two sources, and neither is a hand-written list:
#
#   $DRAUGR_AGENT        the only name that can break a create today
#   lib/agents/*.sh      so switching to one Draugr knows about does not turn a
#                        working kit into a broken one
#
# sbx offers ten agents and this names at most three of them, which is
# deliberate. A hardcoded list of the other seven is the shape that rots - it
# would be wrong the day sbx adds one, and silently. What is here is derived: one
# from a directory listing, one from whatever you configured. An agent outside
# both is caught by dr-up, and dr-kit validate then names it, because
# DRAUGR_AGENT is by definition the agent you just switched to.
dr_kit_reserved_names() {
    { printf '%s\n' "${DRAUGR_AGENT:-claude}"; dr_agent_known | tr ' ' '\n'; } | sort -u
}

# dr_kit_slug <text> - a string sbx will accept as a kit's `name:` field.
#
# sbx's rule, quoted from its own error: "must be lowercase alphanumeric with
# hyphens, 1-64 chars". dr-init used to drop the repository's directory name in
# unchanged, so any project with a capital letter in it - TabuLua, MyApp - wrote
# a kit that validated as INVALID and failed at `dr-up` with an sbx error two
# steps removed from the cause.
#
# Only `name:` is constrained. `displayName:` is free text and keeps the
# capitals, which is why the two are set from different values in dr-init.
dr_kit_slug() {
    local s a
    # Lowercase, then anything outside the permitted set becomes a hyphen. -c is
    # tr's complement: "every character NOT in this set".
    s=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-' '-')

    # Collapse runs of hyphens, then trim the ends: "My App" would otherwise give
    # "my--app", and a leading or trailing hyphen is not alphanumeric.
    while [ "$s" != "${s//--/-}" ]; do s=${s//--/-}; done
    s=${s#-}; s=${s%-}

    # Truncate before trimming again, because cutting at 64 can expose a hyphen
    # that was in the middle a moment ago.
    s=${s:0:64}
    s=${s%-}

    # A kit named after an agent is legal and uncomposable. sbx puts the agent's
    # own kit in the same composition and refuses two that share a name, so a
    # repository in a directory called "claude" or "codex" produces a kit that
    # validates cleanly and then fails at dr-up with sbx's own words, two steps
    # from the cause - the same shape as the capitals problem above.
    #
    # Checked against EVERY known agent rather than the configured one, because
    # the kit is deliberately agent-agnostic: a name that works until you switch
    # DRAUGR_AGENT is a trap rather than a kit.
    while IFS= read -r a; do
        [ "$s" = "$a" ] || continue
        s="$s-project"
        break
    done < <(dr_kit_reserved_names)

    # A name made entirely of punctuation leaves nothing behind. Better a dull
    # placeholder than an empty field that fails validation for a second reason.
    [ -n "$s" ] || s=project
    printf '%s' "$s"
}

# dr_kit_store - the library of named kits, shared across repositories.
dr_kit_store() {
    printf '%s' "${DRAUGR_KIT_STORE%/}"
}

# dr_kit_resolve <entry> - turn one DRAUGR_KIT entry into something sbx accepts.
#
# Four shapes, tried most specific first:
#
#   /abs/path            an absolute path, used as it stands
#   sub/dir              a directory inside the repo - the documented default
#   name                 a directory in the kit store: a named library kit
#   ghcr.io/org/kit:tag  anything holding ":" or "@", i.e. an OCI or git ref
#
# The repo is searched before the store deliberately. A project that happens to
# contain a directory called `lua` means its own, and the more specific answer
# winning is the same rule the whole config cascade follows.
#
# Each shape is tried twice: once with ".<agent>" appended, then plain. So under
# DRAUGR_AGENT=codex, ".draugr/kit.codex" beats ".draugr/kit" and a library kit
# "lua.codex" beats "lua". Most kits need nothing of the sort - network rules and
# install commands do not care which agent runs them - but the escape hatch is
# here for the ones that genuinely differ, and it costs one loop.
#
# A suffix rather than a subdirectory, deliberately: ".draugr/kit/codex/" would
# be indistinguishable from a kit that happens to contain a directory of that
# name, and sbx reads whole directories.
#
# Prints the resolved directory - or the reference untouched - and returns 0.
# Prints nothing and returns 1 when the entry names nothing that exists, which
# callers treat as ordinary: a kit is optional.
dr_kit_resolve() {
    local entry=$1 cand name
    [ -n "$entry" ] || return 1

    for name in "$entry.${DRAUGR_AGENT:-claude}" "$entry"; do
        case "$name" in
        # An absolute path means exactly itself - no search beyond the suffix.
        /*)
            if [ -d "$name" ]; then printf '%s' "$name"; return 0; fi
            ;;
        # Otherwise the repo first, then the library, so a local directory of the
        # same name always wins over a shared one.
        *)
            cand="$DR_REPO/$name"
            if [ -d "$cand" ]; then printf '%s' "$cand"; return 0; fi
            cand="$(dr_kit_store)/$name"
            if [ -d "$cand" ]; then printf '%s' "$cand"; return 0; fi
            ;;
        esac
    done

    # Nothing on this disk. A ":" or "@" means a reference format we do not own,
    # so it goes through untouched and sbx gets to reject it in its own words.
    # No agent suffix here: it is not ours to graft onto somebody's registry tag.
    case "$entry" in
        *[:@]*) printf '%s' "$entry"; return 0 ;;
    esac
    return 1
}

# dr_kit_agent_conflicts - resolved kits that demand a different agent, one per
# line as "<kit> <agent it wants>".
#
# A kit MAY pin itself with `requires: agent: claude`, and sbx then refuses to
# compose it with anything else:
#
#   ERROR: request failed: 400 Bad Request: kit_artifacts: compose:
#   kit "x" requires base agent "claude" but was composed with "codex"
#
# which arrives at `dr-up` in sbx's vocabulary, two steps from the cause - the
# same problem the kit slug had. Worse, `sbx kit validate` passes such a kit
# happily: the mismatch only exists at compose time, so there is nothing else
# that could catch it before creation. Hence Draugr reading the field itself.
#
# Directories only. A ZIP or an OCI reference cannot be read from here, and
# guessing at one would be worse than letting sbx answer.
dr_kit_agent_conflicts() {
    local ref want
    while IFS= read -r ref; do
        [ -d "$ref" ] || continue
        # The field is two levels into the YAML, but "agent:" appears only under
        # requires: in this schema, so one sed is honest enough - and a wrong
        # read here costs a spurious warning, not a wrong mound.
        want=$(sed -n 's/^[[:space:]]*agent:[[:space:]]*//p' "$ref/spec.yaml" 2>/dev/null | head -1)
        [ -n "$want" ] || continue
        [ "$want" = "${DRAUGR_AGENT:-claude}" ] && continue
        printf '%s %s\n' "$ref" "$want"
    done < <(dr_kit_refs)
    return 0
}

# dr_kit_name_conflicts - resolved kits whose `name:` is an agent's name, one per
# line as "<kit> <name>".
#
# sbx composes the agent's own kit with the project's and refuses two that share
# a name:
#
#   ERROR: request failed: 400 Bad Request: kit_artifacts: compose:
#   duplicate kit name "claude" - each kit in a composition must have a unique name
#
# which arrives at dr-up in sbx's vocabulary, with nothing pointing back at the
# file that caused it. `sbx kit validate` passes such a kit happily - the name is
# perfectly legal, and the collision exists only at compose time - so this is the
# second thing dr-kit has to check that sbx will not, and for the same reason as
# dr_kit_agent_conflicts above.
#
# The set it checks against is dr_kit_reserved_names, so it covers the agent you
# have configured plus the ones Draugr carries a module for - not sbx's full ten,
# and see there for why not.
#
# Directories only, as above: a ZIP or an OCI reference cannot be read from here.
dr_kit_name_conflicts() {
    local ref name a
    while IFS= read -r ref; do
        [ -d "$ref" ] || continue
        # Anchored at column 0. `name:` appears indented under publishedPorts as
        # well, and only the top-level one is the kit's own.
        name=$(sed -n 's/^name:[[:space:]]*//p' "$ref/spec.yaml" 2>/dev/null | head -1)
        [ -n "$name" ] || continue
        while IFS= read -r a; do
            [ "$name" = "$a" ] && printf '%s %s\n' "$ref" "$name"
        done < <(dr_kit_reserved_names)
    done < <(dr_kit_refs)
    return 0
}

# dr_kit_refs - every DRAUGR_KIT entry that resolved, one per line, in order.
#
# Order is preserved because sbx applies kits in the order it is given them, so
# a later entry lands on top of an earlier one. Returns 1 when nothing at all
# resolved, so "this project has no kit" stays a single cheap test.
dr_kit_refs() {
    local entry resolved rc=1
    local -a entries=()
    [ -n "${DRAUGR_KIT:-}" ] || return 1

    # read -ra splits on whitespace WITHOUT globbing - the same trap documented
    # at _dr_data_entries, where an unquoted expansion would turn a pattern into
    # a snapshot of whatever happens to be in the current directory.
    read -ra entries <<< "$DRAUGR_KIT"
    for entry in "${entries[@]}"; do
        if resolved=$(dr_kit_resolve "$entry"); then
            printf '%s\n' "$resolved"
            rc=0
        fi
    done
    return "$rc"
}

# dr_kit_missing - the entries that resolved to nothing, one per line.
#
# Reported by name rather than by resolved path, because the whole difficulty of
# a typo'd entry is that it HAS no resolved path - "no kit at /repo/lua" would
# hide that the kit store was searched too.
dr_kit_missing() {
    local entry
    local -a entries=()
    [ -n "${DRAUGR_KIT:-}" ] || return 0
    read -ra entries <<< "$DRAUGR_KIT"
    for entry in "${entries[@]}"; do
        dr_kit_resolve "$entry" >/dev/null || printf '%s\n' "$entry"
    done
}

# dr_kit_repo_dir - the first resolved kit that lives inside this repo.
#
# What `dr-kit save` copies and what dr-policy points at when it suggests
# graduating a rule into the kit: of a list that may mix project and library
# entries, the project's own is the one a repo-scoped instruction means.
dr_kit_repo_dir() {
    local ref
    while IFS= read -r ref; do
        case "$ref" in
            "$DR_REPO"/*) printf '%s' "$ref"; return 0 ;;
        esac
    done < <(dr_kit_refs)
    return 1
}

# dr_dir_hash <dir> - one digest for a whole directory tree.
#
# Sorted with -z and hashed pairwise, so the result depends on the contents and
# the names but not on the order find happened to walk them in.
dr_dir_hash() {
    find "$1" -type f -print0 2>/dev/null \
        | sort -z \
        | xargs -0 sha256sum 2>/dev/null \
        | sha256sum \
        | cut -d' ' -f1
}

# dr_kit_hash <dir> - a digest of the whole kit, not just spec.yaml, because
# initFiles and anything else in the directory change what the sandbox gets.
dr_kit_hash() { dr_dir_hash "$1"; }

# dr_kit_hash_all - one digest covering every kit in DRAUGR_KIT, in order.
#
# Order is part of the digest because it is part of the meaning: the same two
# kits applied the other way round can build a different sandbox.
#
# A remote reference contributes its reference STRING rather than its contents,
# which is the only honest option - hashing it would mean fetching an OCI image
# on every dr-up, and a mutable tag would defeat that anyway. So a tag that moved
# under you is drift Draugr cannot see, while a changed local directory is drift
# it can. dr-kit drift says so rather than implying it checked everything.
dr_kit_hash_all() {
    local ref
    {
        while IFS= read -r ref; do
            if [ -d "$ref" ]; then dr_dir_hash "$ref"; else printf '%s\n' "$ref"; fi
        done < <(dr_kit_refs)
    } | sha256sum | cut -d' ' -f1
}

# Where dr-up records the hash it built with, so dr-kit drift is a comparison
# rather than a guess. Inside .draugr/ because it describes this checkout, not
# the project - dr-init gitignores it, along with .draugr/tmp/.
dr_kit_stamp() {
    printf '%s/.draugr/kit.applied' "$DR_REPO"
}

# ---------------------------------------------------------------------------
# Network policy, and the loop it makes possible
#
# A kit's allow list is frozen into the sandbox at creation, so changing it means
# a recreate. But `sbx policy allow --sandbox` adds a rule to a RUNNING mound and
# it takes effect at once - measured: a host that answered "Blocked by network
# policy" answered with its own 404 immediately afterwards, same mound, no
# restart. That is what lets a build be fixed iteratively instead of one
# recreate at a time, with the kit written down once at the end.
#
# Two questions have to be answerable for that loop to work, and sbx answers both
# in a way no build tool can:
#
#   what was refused?   `sbx policy log` is the PROXY's record, so it is the same
#                       whatever the client. Measured against one blocked host:
#                       curl printed nothing at all, git named it exactly, and
#                       pip reported "Could not find a version that satisfies the
#                       requirement" - three dialects, one of them silent and one
#                       actively misleading. The proxy logged all of them.
#   what did I open?    so nothing has to be remembered during the loop.
# ---------------------------------------------------------------------------

# dr_policy_denied - hosts this mound was refused, one bare hostname per line.
#
# The log records "host:port"; the port is dropped because that is not what
# `sbx policy allow network` or a kit's allow list take. Deduplicated, because a
# retrying build hits the same host many times and the count is not the point.
dr_policy_denied() {
    dr_sbx policy log "$DRAUGR_SANDBOX" --json 2>/dev/null         | jq -r --arg n "$DRAUGR_SANDBOX" '
              (.blocked_hosts // [])[]
              | select(.vm_name == $n)
              | .host | sub(":[0-9]+$"; "")' 2>/dev/null         | sort -u
}

# dr_policy_adhoc - hosts opened for this mound by hand, one per line.
#
# Everything scoped to this sandbox appears in one table, the kit's rules
# included, so the two have to be told apart. `editable` is the discriminator
# that means it: a rule that came from the kit artifact is not editable, and one
# added by `dr-policy --allow` is. Measured - the kit's rule also carries
# name "kit:<sandbox>" while an ad-hoc one is a bare UUID, and both agree.
dr_policy_adhoc() {
    dr_sbx policy ls "$DRAUGR_SANDBOX" --wide --json 2>/dev/null         | jq -r --arg s "sandbox:$DRAUGR_SANDBOX" '
              .. | objects
              | select(.applies_to? == $s and .decision? == "allow")
              | select(.resource_type? == "network" and .editable? == true)
              | .resources[]?' 2>/dev/null         | sort -u
}

# ---------------------------------------------------------------------------
# Host ports - reaching a service that runs on THIS machine, from inside a mound
# ---------------------------------------------------------------------------
#
# The mirror image of DRAUGR_PORTS. That publishes a port the mound listens on so
# the host can reach in; this opens a port the HOST listens on so the mound can
# reach out. Both are holes, and this is the more serious direction: the thing on
# the other side is a process on your machine, outside the sandbox, that the
# agent gets to talk to.

# dr_host_ip - the address a mound must use to reach a service on this host.
#
# Not a constant, which is the whole reason this is a function. WSL sits on a
# NAT'd Hyper-V network whose subnet is chosen when the network is created - per
# Windows boot - and whose address within it comes from DHCP. Neither is
# pinnable: WSL 2.6.1 parses networkingMode, dhcpTimeout and vmIdleTimeout out of
# .wslconfig and contains no natNetwork or natGateway at all. So an address
# written down today is wrong after the next reboot, and because the sandbox
# policy is default-deny it then fails CLOSED and SILENTLY - the connection is
# accepted and dropped with no error to read, which is a genuinely nasty thing to
# debug. Hence: resolved at the moment the hole is opened, never stored.
#
# `route get` rather than a named interface, because the question is "which
# source address would this machine leave from", which is the one a mound can
# route back to - and the answer does not depend on the interface being eth0. No
# packet is sent; it is a routing-table query.
dr_host_ip() {
    local ip
    ip=$(ip -4 route get 1.1.1.1 2>/dev/null |
             awk '{ for (i = 1; i < NF; i++) if ($i == "src") { print $(i + 1); exit } }')
    [ -n "$ip" ] || return 1
    printf '%s\n' "$ip"
}

# dr_hostport_rules <port> - ids of the rules dr-hostport itself wrote for <port>.
#
# Deliberately narrow, because these ids are about to be handed to `policy rm`.
# Only a rule that is editable (so: not one the kit composed), scoped to this
# mound, and holding EXACTLY ONE resource that is a bare IPv4 address on <port>
# can have come from here. A hand-written rule bundling several hosts, or one
# naming a domain, is left alone even when <port> appears inside it.
#
# Without this pruning the rules accumulate one dead entry per reboot, each
# naming an address that no longer exists.
dr_hostport_rules() {
    local port=$1 re
    re=$(printf '^[0-9]+[.][0-9]+[.][0-9]+[.][0-9]+:%s$' "$port")
    dr_sbx policy ls "$DRAUGR_SANDBOX" --wide --json 2>/dev/null |
        jq -r --arg s "sandbox:$DRAUGR_SANDBOX" --arg re "$re" '
              .. | objects
              | select(.applies_to? == $s and .decision? == "allow")
              | select(.resource_type? == "network" and .editable? == true)
              | select(((.resources? // []) | length) == 1)
              | select(.resources[0] | test($re))
              | .id? // empty' 2>/dev/null
}

# dr_hostport_open <port> - the addresses currently allowed on <port>, one per line.
dr_hostport_open() {
    local port=$1 re
    re=$(printf '^[0-9]+[.][0-9]+[.][0-9]+[.][0-9]+:%s$' "$port")
    dr_sbx policy ls "$DRAUGR_SANDBOX" --wide --json 2>/dev/null |
        jq -r --arg s "sandbox:$DRAUGR_SANDBOX" --arg re "$re" '
              .. | objects
              | select(.applies_to? == $s and .decision? == "allow")
              | select(.resource_type? == "network" and .editable? == true)
              | .resources[]? | select(test($re))' 2>/dev/null | sort -u
}

# dr_kit_allow_list <kit-dir> - the hosts a kit already declares.
#
# A hand-rolled reader rather than a YAML parser, so it is deliberately narrow:
# find `allow:` nested under `network:`, then take the `- item` lines directly
# beneath it and stop at the first line that is not one. That is enough for the
# shape dr-init writes and for anything a person would write by hand, and it
# CANNOT wander into `deny:` or `publishedPorts:` further down the file, which a
# bare "every - line" grep would.
dr_kit_allow_list() {
    [ -f "$1/spec.yaml" ] || return 0
    awk '
        # Track the indent of the allow: key so we know when its block ends.
        /^[[:space:]]*allow:[[:space:]]*(\[\])?[[:space:]]*$/ && innet {
            match($0, /^[[:space:]]*/); allow_indent = RLENGTH; inallow = 1; next
        }
        /^[[:space:]]*network:[[:space:]]*$/ { innet = 1 }
        inallow {
            # A list item deeper than the key belongs to it; anything else ends it.
            if (match($0, /^[[:space:]]*-[[:space:]]+/)) {
                item = $0
                sub(/^[[:space:]]*-[[:space:]]+/, "", item)
                sub(/[[:space:]]*(#.*)?$/, "", item)
                gsub(/^["'"'"']|["'"'"']$/, "", item)
                if (item != "") print item
                next
            }
            if ($0 ~ /^[[:space:]]*(#.*)?$/) next     # comment or blank: still inside
            match($0, /^[[:space:]]*/)
            if (RLENGTH <= allow_indent) { inallow = 0 }
        }
    ' "$1/spec.yaml" 2>/dev/null | sort -u
}

# dr_hostport_managed <resource> - true when DRAUGR_HOST_PORTS owns this rule.
#
# Such a rule is not machine state anyone has to preserve, and that changes the
# answer to two separate questions. Recreating does destroy it, but dr-up writes
# it again seconds later from the address of the day, so warning about the loss
# sends you looking for a way to keep something that is about to come back. And
# `dr-kit adopt` must never take it: the kit is COMMITTED, and the address in it
# is true only until the next reboot - it is the one value this whole feature
# exists to stop anybody writing down.
#
# Deliberately narrow. Only a bare IPv4 on a port this project declared can have
# come from dr-hostport; a hostname on the same port belongs to somebody else and
# is still reported.
dr_hostport_managed() {
    local res=$1 port p
    [ -n "${DRAUGR_HOST_PORTS:-}" ] || return 1
    case "$res" in
        [0-9]*.[0-9]*.[0-9]*.[0-9]*:[0-9]*) ;;
        *) return 1 ;;
    esac
    port=${res##*:}
    for p in $DRAUGR_HOST_PORTS; do
        if [ "$p" = "$port" ]; then return 0; fi
    done
    return 1
}

# dr_policy_unadopted - ad-hoc hosts this repo's kit does not already declare.
#
# The set that would be LOST by a recreate, which is what dr-rm and dr-up guard
# on. Measured: a rule scoped to a sandbox does not outlive it - after `sbx rm`,
# looking the rule up by id gives "policy or rule not found" - so a recreate
# silently discards exactly the list you were about to write down.
#
# With no kit of its own, every ad-hoc host counts as unadopted: there is nowhere
# for it to have been written to.
dr_policy_unadopted() {
    local kit have host
    # Spelled out rather than as have=$([ -n "$kit" ] && ...), which under set -e
    # aborts the whole function when there is no kit - silently turning "every
    # host is unadopted" into "there is nothing to report", which is the wrong
    # answer in the one direction that loses data.
    have=
    if kit=$(dr_kit_repo_dir); then
        have=$(dr_kit_allow_list "$kit")
    fi
    while IFS= read -r host; do
        [ -n "$host" ] || continue
        # A rule dr-hostport wrote is restored automatically, so it is neither
        # something a recreate loses nor something to write into the kit.
        if dr_hostport_managed "$host"; then continue; fi
        printf '%s
' "$have" | grep -qxF "$host" || printf '%s
' "$host"
    done < <(dr_policy_adhoc)
    return 0
}

# ---------------------------------------------------------------------------
# Creation-time settings
#
# Most of what sbx needs is frozen into the sandbox when it is built: the image,
# the agent, the memory cap, the published ports and every extra mount. Editing
# one of those and re-running dr-up does nothing at all, because dr-up's job on
# an existing mound is to START it, not to rebuild it.
#
# That is a silent no-op, which is the worst kind of no-op - you add a mount, run
# dr-go, and the directory is simply not there, with nothing on screen to say
# why. So dr-up records what it built with and compares, exactly as it already
# does for kits.
# ---------------------------------------------------------------------------

# dr_create_facts - the settings that are fixed at creation, one KEY=value a line.
#
# DRAUGR_SANDBOX is not among them: changing it does not modify a mound, it names
# a different one. Nor is DRAUGR_KIT, which has its own stamp and its own remedy.
dr_create_facts() {
    local k
    for k in DRAUGR_AGENT DRAUGR_CLONE DRAUGR_TEMPLATE DRAUGR_MEMORY DRAUGR_CPUS \
             DRAUGR_PORTS DRAUGR_MOUNTS
    do
        printf '%s=%s\n' "$k" "${!k}"
    done
}

# Beside the kit stamp, and gitignored by dr-init for the same reason: it
# describes this checkout's mound, not the project.
dr_create_stamp() {
    printf '%s/.draugr/create.applied' "$DR_REPO"
}

# dr_create_drift - names the keys that differ from what the mound was built with.
#
# Silent when there is no stamp. A mound built before this existed is not drift,
# it is unknown, and guessing would cry wolf on every single dr-up. A key the
# stamp has never heard of is skipped for the same reason: an older Draugr wrote
# that file and did not record it.
dr_create_drift() {
    local stamp k
    stamp=$(dr_create_stamp)
    [ -f "$stamp" ] || return 0
    while IFS='=' read -r k _; do
        grep -q "^$k=" "$stamp" || continue
        grep -qxF "$k=${!k}" "$stamp" || printf '%s\n' "$k"
    done < <(dr_create_facts)
    return 0
}

# ---------------------------------------------------------------------------
# The shared skills store
#
# Measured in Phase 2 and re-checked in Phase 6: this one directory is mounted
# READ-WRITE into every mound, at /home/agent/.claude/skills, and it survives
# sbx rm. It is the only path by which anything inside a sandbox can leave
# something behind for a later one - so it is the exception to "the sandbox
# cannot write to the host", and it holds agent instructions.
# ---------------------------------------------------------------------------

# dr_skills_dir - where that store lives, derived from sbx's own location rather
# than hard-coded: sbx.exe sits at <root>/bin/sbx.exe and the store under
# <root>/sandboxes/state/. Prints the path whether or not it exists yet, and
# returns 1 only when sbx cannot be found at all.
dr_skills_dir() {
    local sbx_exe
    sbx_exe=$(dr_find_sbx) || return 1
    printf '%s/sandboxes/state/agent-skills' "$(dirname "$(dirname "$sbx_exe")")"
}

# ---------------------------------------------------------------------------
# Path keys, and the memory store
#
# An agent that keeps per-project state names the directory after the project's
# ABSOLUTE PATH, so one repository has a different key on each side of the
# boundary:
#
#   Windows   C:\Code\Draugr       c--Code-Draugr
#   WSL       /mnt/c/Code/Draugr   -mnt-c-Code-Draugr
#   Mound     /c/Code/Draugr       -c-Code-Draugr
#
# The encoding is Claude Code's, and lib/agents/claude.sh explains what a copy
# that crosses the boundary unrenamed does to an agent's memory. The encoder
# lives HERE rather than there because Draugr's own store uses the Windows form
# to name each repo's corner of it, whichever agent that repo runs.
# ---------------------------------------------------------------------------

# dr_mem_key <absolute-path> - encode a path the way Claude Code names its folder.
#
# Lowercase a Windows drive letter, then turn every "/", "\" and ":" into "-".
# A leading separator therefore yields a leading "-", which is why the WSL and
# mound forms start with one, and why the Windows form has "--" where "C:\" was.
#
# Only those three characters are known to be substituted; the rest of the path
# keeps its case, as "c--Code-Draugr" shows. What a space or other punctuation in
# a repo name does is NOT established, so dr-mem checks the answer against the
# mound instead of trusting it.
dr_mem_key() {
    local p=$1
    # Lowercase the drive letter only - "Code" and "Draugr" keep their capitals.
    case "$p" in
        [A-Za-z]:*) p="$(printf '%s' "${p:0:1}" | tr '[:upper:]' '[:lower:]')${p:1}" ;;
    esac
    # In single quotes '\\' is two characters, which tr reads as one escaped
    # backslash - so SET1 is the three characters / \ : and SET2 is three
    # hyphens. Not bash escaping, which is why shellcheck needs telling.
    # shellcheck disable=SC1003
    printf '%s' "$p" | tr '/\\:' '---'
}

# The same repo, keyed for each side. Each takes the WSL path, because that is
# the one every dr-* command already has in DR_REPO.
dr_mem_key_wsl()   { dr_mem_key "$1"; }
dr_mem_key_win()   { dr_mem_key "$(dr_path_win "$1")"; }
dr_mem_key_mound() { dr_mem_key "$(dr_path_mound "$1")"; }

# Inside the mound the agent is uid 1000 with home /home/agent - verified, not
# assumed: `sbx exec … id` reports uid=1000(agent) and $HOME=/home/agent.
# shellcheck disable=SC2034  # read by the agent modules, which shellcheck does
# not follow from here - every dr_agent_mem_dir is built on it
DR_MOUND_HOME=/home/agent

# Where dr-mem assembles a transfer inside the mound. The carried set can be
# several files in several places, so it is packed into this one directory and
# moved in a single `sbx cp` - which is simpler, and leaves something whose
# existence can be checked afterwards rather than trusted.
#
# Under .cache/ beside the attach rcfile: a scratch path the agent owns, that
# nothing else reads, and that a wiped mound recreates.
# shellcheck disable=SC2034  # read by dr-mem and the agent modules
DR_MOUND_STAGE="$DR_MOUND_HOME/.cache/draugr/mem"

# dr_mem_store_dir <repo> - this repo's corner of $DRAUGR_MEM_STORE.
#
# Named with the WINDOWS key for two reasons: it has no leading "-", so it can
# never be mistaken for an option by a command you type at it, and it is the
# name a host-side Claude install would use for the same repo, so the store
# stays recognisable when you go looking through it by hand.
#
# Then by agent, because two agents' memories of the same project are two
# different things that must not overwrite one another - and because they are
# not even the same SHAPE: Claude Code's is a directory of markdown, Codex's is
# markdown plus SQLite. Repo first rather than agent first, so that everything
# about one project stays in one place when you go looking by hand.
dr_mem_store_dir() {
    printf '%s/%s/%s' "${DRAUGR_MEM_STORE%/}" "$(dr_mem_key_win "$1")" \
        "${DRAUGR_AGENT:-claude}"
}

# dr_mem_store_migrate <repo> - move a pre-0.2.0 store under its agent.
#
# Before the store was split by agent, this repo's memory sat directly in its
# corner. Everything that could have written it was Claude Code, so that is
# where it goes - NOT under whatever agent happens to be configured now, which
# would file Claude's memories under Codex the first time you tried the new one.
#
# Announced rather than silent: it is the user's data moving on disk, and one
# line saying so is cheaper than the confusion of finding it somewhere else.
dr_mem_store_migrate() {
    local old new entry
    old="${DRAUGR_MEM_STORE%/}/$(dr_mem_key_win "$1")"
    new="$old/claude"

    # The old shape is memory/ sitting directly in the corner. If claude/ already
    # exists there is nothing to do, and a corner holding neither is a store this
    # version wrote in the first place.
    [ -d "$old/memory" ] || return 0
    [ -d "$new" ] && return 0

    # The export marker and the one-mv-back copy move with it, or the store
    # arrives in its new home having forgotten that it was ever exported - which
    # is what makes `dr-mem import` trust it without asking.
    mkdir -p "$new"
    for entry in memory memory.previous .draugr-export; do
        if [ -e "$old/$entry" ]; then mv "$old/$entry" "$new/$entry"; fi
    done
    dr_info "moved $old into claude/ - the memory store is now per agent"
    return 0
}

# ---------------------------------------------------------------------------
# Talking to the mound
#
# `sh -c 'script' sh ARG` makes ARG the script's $1. Passing paths as arguments
# rather than splicing them into the script text means nothing in a path can be
# re-read as shell syntax, and it keeps the scripts single-quoted and legible.
#
# Agent modules use these, which is why they are here rather than in dr-mem
# where they started: a module has to be able to look inside the mound to answer
# anything about what the agent has actually written.
# ---------------------------------------------------------------------------

# Quiet: for probes and listings, where a failure is an answer rather than a
# fault and sbx's own message would only be noise.
dr_mound_sh() {
    local script=$1; shift
    dr_sbx exec "$DRAUGR_SANDBOX" -- sh -c "$script" sh "$@" 2>/dev/null
}

# Loud: for the calls that change something, where the reason matters.
dr_mound_run() {
    local script=$1; shift
    dr_sbx exec "$DRAUGR_SANDBOX" -- sh -c "$script" sh "$@"
}

# dr_stage - a scratch directory that sbx.exe can actually see.
#
# `sbx cp` is a Windows binary and its HOST argument must be a WINDOWS path.
# Measured against sbx 0.37.1: both of these fail,
#
#   sbx cp <name>:/tmp/x /home/you/dest      ERROR: … GetFileAttributesEx \home\you
#   sbx cp <name>:/tmp/x /mnt/c/Code/dest    ERROR: … GetFileAttributesEx \mnt\c\Code
#
# because sbx turns the leading "/" into "\" and looks for it on the current
# drive. Only C:\… works. $DRAUGR_MEM_STORE may sit anywhere, including WSL's
# own ext4 where sbx cannot reach at all, so every transfer hops through here:
# .draugr/tmp/ inside the repo, which dr_require_win_path has already
# guaranteed is on a Windows drive.
#
# Sets DR_STAGE (the WSL path) and DR_STAGE_WIN (the same directory spelled for
# sbx). The caller is expected to trap-remove DR_STAGE: it holds memory files,
# which is exactly the sort of thing not to leave lying around after a crash.
dr_stage() {
    DR_STAGE="$DR_REPO/.draugr/tmp/$$"
    rm -rf "$DR_STAGE"
    mkdir -p "$DR_STAGE"
    # shellcheck disable=SC2034  # read by the dr-* command that called us
    DR_STAGE_WIN=$(dr_path_win "$DR_STAGE")
}

# ---------------------------------------------------------------------------
# Talking to the mound over git
# ---------------------------------------------------------------------------

# dr_sandbox_url -> ssh://<sandbox>.sbx/<mound path>
#
# Always ssh, never the git:// daemon sbx publishes. That daemon binds *Windows*
# loopback, which WSL2 cannot reach across its NAT, and its port is randomised on
# every start. ssh needs no port, crosses no NAT, matches the *.sbx block dr-setup
# writes, and - verified - starts a stopped sandbox when you connect to it.
#
# Reads DR_REPO and DRAUGR_SANDBOX rather than taking them as arguments: every
# caller is past dr_context, so parameters would only be a second way to say the
# same thing, and a chance for the two to disagree.
dr_sandbox_url() {
    local mound
    mound=$(dr_path_mound "$DR_REPO") || dr_die \
        "$DR_REPO is not on a Windows drive, so it has no path inside the mound"
    printf 'ssh://%s.sbx%s' "$DRAUGR_SANDBOX" "$mound"
}

# dr_remote_ensure - point $DRAUGR_REMOTE at the mound, creating it if absent.
# Prints the URL. Set rather than left alone, because renaming the sandbox or
# moving the repo changes it and a stale remote fails in a confusing way.
dr_remote_ensure() {
    local url
    url=$(dr_sandbox_url)

    # `git remote` lists names one per line; -x anchors so "draugr" cannot match
    # a remote called "draugr-old".
    if git -C "$DR_REPO" remote | grep -qx "$DRAUGR_REMOTE"; then
        git -C "$DR_REPO" remote set-url "$DRAUGR_REMOTE" "$url"
    else
        git -C "$DR_REPO" remote add "$DRAUGR_REMOTE" "$url"
        dr_debug "added remote $DRAUGR_REMOTE -> $url"
    fi

    # A second refspec, alongside git's default +refs/heads/*. dr-send drops your
    # commits at refs/remotes/host/<branch> INSIDE the mound, which is a ref no
    # amount of looking at refs/heads/* will ever show - so mirroring it back is
    # the only way the host can tell "the mound has never seen this" apart from
    # "the mound has it and the agent has not merged it". See dr_send_state.
    #
    # --add, guarded, because git remote add already wrote one and a second call
    # must not accumulate duplicates.
    if ! git -C "$DR_REPO" config --get-all "remote.$DRAUGR_REMOTE.fetch" \
         | grep -qxF "$DR_SENT_REFSPEC"; then
        git -C "$DR_REPO" config --add "remote.$DRAUGR_REMOTE.fetch" "$DR_SENT_REFSPEC"
    fi
    printf '%s' "$url"
}

# Kept out of refs/remotes/ on purpose: everything there is "branches in the
# mound", and this is the mound's copy of OUR branch. Under refs/remotes it would
# turn up in git branch -r and in dr_other_branches, reported as work to review.
DR_SENT_REFSPEC='+refs/remotes/host/*:refs/draugr/sent/*'

dr_sent_ref() { printf 'refs/draugr/sent/%s' "$DRAUGR_BRANCH"; }

# dr_send_state - why the mound's branch is behind yours. Two situations that are
# indistinguishable from draugr/<branch> alone:
#
#   not-sent   the mound has never received these         -> dr-send
#   unmerged   dr-send delivered them; the agent's branch  -> dr-send --merge
#              has not merged host/<branch> yet
#
# Without the distinction dr-sync said "send them with dr-send" for ever: you
# sent, it still said send, and re-sending was a no-op because the commits were
# already sitting there. Reported by a user going round that loop twice.
dr_send_state() {
    local sent
    sent=$(dr_sent_ref)
    if ! git -C "$DR_REPO" rev-parse --verify --quiet "$sent" >/dev/null; then
        printf 'not-sent\n'
        return 0
    fi
    # Ancestor rather than equality: sending, then committing once more locally,
    # leaves you genuinely with something new to send.
    if git -C "$DR_REPO" merge-base --is-ancestor HEAD "$sent" 2>/dev/null; then
        printf 'unmerged\n'
    else
        printf 'not-sent\n'
    fi
}

# dr_tracking_ref - <remote>/<branch>, the thing dr-log, dr-diff, dr-merge and
# dr-status all compare against. Named once here so they cannot disagree.
dr_tracking_ref() {
    printf '%s/%s' "$DRAUGR_REMOTE" "$DRAUGR_BRANCH"
}

# dr_other_branches - fetched mound branches holding commits your HEAD does not.
#
# The remote's refspec is +refs/heads/*:refs/remotes/<remote>/*, so dr-sync has
# always fetched EVERY branch. Only the report was narrow: it looked at
# draugr/$DRAUGR_BRANCH and nothing else. An agent that works on a branch of its
# own - which agents habitually do - was therefore invisible. The commits were
# already on this disk and dr-sync, dr-log and dr-diff all said there was nothing
# there. That is how a session's work went missing for a day.
#
# Prints "<ref> <count>" per line. The tracked branch is excluded because its
# caller reports it separately, and <remote>/HEAD because it is a symref to one
# of these rather than a branch of its own.
#
# The FULL refname, deliberately: %(refname:short) is unsafe for that second
# exclusion. refs/remotes/<name>/HEAD is one of git's own rev-parse rules, so it
# shortens to "draugr" - NOT "draugr/HEAD" - and a */HEAD guard on the short form
# never fires. Nothing created that ref until git 2.49 made `git fetch` do it by
# default (remote.<name>.followRemoteHEAD=create); from then on every sync
# reported "1 branch(es) you are NOT tracking: draugr", naming the branch you are
# already on and taking the review hint with it. Found in CI, whose git is newer
# than the one on the machine this was written on.
dr_other_branches() {
    local tracked ref count
    tracked=$(dr_tracking_ref)
    while IFS= read -r ref; do
        ref=${ref#refs/remotes/}
        case "$ref" in */HEAD) continue ;; esac
        [ "$ref" = "$tracked" ] && continue
        count=$(git -C "$DR_REPO" rev-list --count "HEAD..refs/remotes/$ref" \
                    2>/dev/null || printf 0)
        if [ "$count" -gt 0 ]; then printf '%s %s\n' "$ref" "$count"; fi
    done < <(git -C "$DR_REPO" for-each-ref --format='%(refname)' \
                 "refs/remotes/$DRAUGR_REMOTE/" 2>/dev/null)
    return 0
}

# dr_require_tracking_ref - fail helpfully when there is nothing fetched yet,
# which is the normal state before the first dr-sync and reads as a git error
# otherwise.
dr_require_tracking_ref() {
    local ref
    ref=$(dr_tracking_ref)
    git -C "$DR_REPO" rev-parse --verify --quiet "$ref" >/dev/null && return 0
    dr_die \
        "nothing fetched from the mound yet ($ref does not exist)" \
        "Fetch the agent's commits first:  dr-sync"
}

# ---------------------------------------------------------------------------
# Hooks - run on the HOST (WSL), which is exactly what a kit's commands cannot do.
# ---------------------------------------------------------------------------

dr_hook() {
    local name=$1 repo=${2:-$PWD} hook
    hook="$repo/.draugr/hooks/$name"

    # No hook, or not executable: silently fine. Hooks are opt-in.
    [ -x "$hook" ] || return 0

    # Trusted first, and for exactly the reason .draugr.conf is. A hook is a
    # script that runs on the HOST, as you - strictly more dangerous than the
    # config file sitting beside it, which has been trust-checked since Phase 1.
    #
    # It lives in the repository, so it arrives with a clone and can arrive with
    # a `dr-merge` of the agent's own commits. Without this check, an agent that
    # writes .draugr/hooks/pre-up and gets it merged executes code on your
    # machine at the next dr-up - measured, before this line existed.
    #
    # Refusing rather than prompting: dr_hook is called mid-command, often after
    # a mound has been created, and "your hook did not run" is a safer surprise
    # than "something you have not read just ran".
    dr_trust_check "$hook" || dr_die \
        "refusing to run an untrusted hook: $hook" \
        "Hooks run on your machine, as you, with the config in their environment." \
        "Read it, then:  dr-trust $hook"

    dr_debug "running hook $name"

    # A hook is a separate process, so the merged config has to be exported to
    # reach it. ${k?} is the form shellcheck accepts for "export by name".
    local k
    for k in "${DR_KEYS[@]}"; do export "${k?}"; done
    export DRAUGR_REPO="$repo" DRAUGR_HOOK="$name"

    # A failing hook is fatal: it exists to veto, so ignoring it would defeat it.
    "$hook" || dr_die "hook $name failed (exit $?)" "Hook: $hook"
}

# One agent module is always loaded, from the moment this file is sourced. Some
# commands - dr-skills, dr-setup - never read a config at all, and a dr_agent_*
# function that existed only after dr_load_config would be a trap for whoever
# adds the next caller. dr_load_config loads it again once the cascade has had
# its say, which is the load that decides.
dr_agent_load
