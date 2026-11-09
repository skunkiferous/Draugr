# shellcheck shell=bash
#
# lib/common.sh: the shared code for all dr-* commands.
#
# Commands source this file. Nothing runs it directly. Code that only one
# command needs stays in that command. This file holds only the code that
# repeats. The names of internal helpers start with _dr_. A project
# configuration that is sourced is then unlikely to overwrite them.
#
# This is the most complex file in the project. The difficult code is here on
# purpose, so that the command scripts can stay simple. If you do not know a
# bash construct in this file, read docs/HACKING.md. It lists the constructs
# that the project uses.

# Include guard. A script can source this file twice, for example directly and
# again through a helper. The second time, do nothing. Use `return`, not
# `exit`, because this file is sourced. `exit` stops the caller.
[ -n "${_DR_COMMON_LOADED:-}" ] && return 0
_DR_COMMON_LOADED=1

DRAUGR_VERSION="0.6.0"

# --- find the directory where Draugr is installed ---------------------------
#
# A user can start a dr-* command through a symlink in ~/.local/bin. Then
# $BASH_SOURCE[0] is that symlink and not the real file. The code needs the
# real file to find ../share/. This loop follows the chain of links to its end:
#
#   -L         "is a symlink"
#   readlink   prints the next step of the link (that step can be a link too)
#   /*)        an absolute target replaces the full path
#   *)         a relative target starts from the directory of the link
#
# The loop stops, because each step moves toward a real file. A symlink loop
# is a broken installation in all cases.
_dr_self="${BASH_SOURCE[0]}"
while [ -L "$_dr_self" ]; do
    _dr_link=$(readlink "$_dr_self")
    # An absolute target replaces the path. A relative target starts from the
    # directory that holds the link.
    case "$_dr_link" in
        /*) _dr_self=$_dr_link ;;
        *)  _dr_self=$(dirname "$_dr_self")/$_dr_link ;;
    esac
done

# This file is lib/common.sh, so the root of the project is one directory up.
DRAUGR_ROOT=$(cd "$(dirname "$_dr_self")/.." && pwd)
DRAUGR_SHARE="$DRAUGR_ROOT/share"
unset _dr_self _dr_link
# Hooks run as separate processes on the host. These variables are exported, so
# that a hook can find the share/ directory and report which Draugr started it.
export DRAUGR_ROOT DRAUGR_SHARE DRAUGR_VERSION

# ---------------------------------------------------------------------------
# Output
#
# Diagnostic messages go to stderr. The real output of a command then stays
# usable in a pipe. If stderr is not a terminal, or if NO_COLOR is set
# (https://no-color.org), the messages have no color.
# ---------------------------------------------------------------------------

# -t 2 asks "is stderr a terminal?". $'...' is the ANSI-C quoting of bash. It
# changes \033 into a real escape character. Plain '\033' stays four characters.
if [ -t 2 ] && [ -z "${NO_COLOR:-}" ]; then
    _DR_RED=$'\033[31m'; _DR_YELLOW=$'\033[33m'; _DR_GREEN=$'\033[32m'
    _DR_BLUE=$'\033[34m'; _DR_DIM=$'\033[2m';    _DR_BOLD=$'\033[1m'
    _DR_OFF=$'\033[0m'
else
    # The output goes to a pipe or a file. Each color is an empty string. The
    # same printf calls work, and a log file gets no escape codes.
    _DR_RED=; _DR_YELLOW=; _DR_GREEN=; _DR_BLUE=; _DR_DIM=; _DR_BOLD=; _DR_OFF=
fi

# The name that messages show. If the script set DR_PROG, the name is DR_PROG.
# If not, it is the file name of the script (${0##*/} is basename $0).
_dr_prog() { printf '%s' "${DR_PROG:-${0##*/}}"; }

# Four levels of message, one format: "<prog>: <message>", in color, on stderr.
dr_info()  { printf '%s%s:%s %s\n'   "$_DR_BLUE"   "$(_dr_prog)" "$_DR_OFF" "$*" >&2; }
dr_ok()    { printf '%s%s:%s %s\n'   "$_DR_GREEN"  "$(_dr_prog)" "$_DR_OFF" "$*" >&2; }
dr_warn()  { printf '%s%s:%s %s\n'   "$_DR_YELLOW" "$(_dr_prog)" "$_DR_OFF" "$*" >&2; }
dr_error() { printf '%s%s:%s %s\n'   "$_DR_RED"    "$(_dr_prog)" "$_DR_OFF" "$*" >&2; }

# If DRAUGR_DEBUG is not set, this prints nothing. Scripts can call it often.
dr_debug() {
    [ -n "${DRAUGR_DEBUG:-}" ] || return 0
    printf '%s%s: %s%s\n' "$_DR_DIM" "$(_dr_prog)" "$*" "$_DR_OFF" >&2
}

# dr_die <message> [remedy...]
# Each fatal error names the fix. With only "not a git repository", the reader
# must search for the fix. "run git init, or cd into your project" gives it.
dr_die() {
    dr_error "$1"
    shift
    # The other arguments tell how to fix the problem. Print them indented and
    # dim under the error. The reader then sees the problem first, then the fix.
    local line
    for line in "$@"; do
        printf '  %s%s%s\n' "$_DR_DIM" "$line" "$_DR_OFF" >&2
    done
    exit 1
}

dr_heading() { printf '\n%s%s%s\n' "$_DR_BOLD" "$*" "$_DR_OFF" >&2; }

# dr_help [file]: print the first comment block of a script as its help text.
#
# The --help text of each command is its header comment. Only then can the two
# not drift apart. Before, each script used `sed -n '2,Np' "$0"`, and N had to
# be the number of the last comment line. In 17 of 27 commands, N was one too
# large, so --help ended with a stray `set -euo pipefail`. The cause was not a
# bad count. When someone changes a header, the range becomes wrong. It is
# better to delete that kind of upkeep than to do it correctly.
#
# The function starts at line 2, to skip the shebang. It stops at the first line
# that is not a comment. It removes one leading "# " from each line. It also
# stops at a linter directive. That last rule is necessary. A "disable=" pragma
# for the full file must come before the first command. Thus in dr-mem, it is
# in the header block. It is data for a machine, not text for a reader of --help.
#
# (The text above uses careful words. If a comment line STARTS with the name of
# the linter, the linter reads it as a bad directive and fails the full file. A
# comment here once did that.)
# The function holds back blank lines. When a real line follows, it prints
# them. Thus --help does not end with blank lines. This matters for a header
# that ends with a "#" separator. The header of dr-mem does that, above the
# directive for the linter.
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
# sbx is a Windows binary. By default, it is NOT on the PATH of WSL. Thus each
# call goes through this code. The result is cached in DRAUGR_SBX for the
# process.
# ---------------------------------------------------------------------------

# Four methods. The fastest and most explicit method comes first. If a method
# finds sbx, it prints the path and returns 0. If no method finds sbx, the
# function returns 1, which means "not installed".
dr_find_sbx() {
    # 1. This process found sbx before, or the user set DRAUGR_SBX.
    if [ -n "${DRAUGR_SBX:-}" ] && [ -x "$DRAUGR_SBX" ]; then
        printf '%s' "$DRAUGR_SBX"
        return 0
    fi

    # 2. On the PATH. This is rare in WSL, but the test costs nothing. On Git
    #    Bash, it is true.
    local candidate
    for candidate in sbx.exe sbx; do
        if command -v "$candidate" >/dev/null 2>&1; then
            # command -v prints the full path. The code caches that path.
            DRAUGR_SBX=$(command -v "$candidate")
            dr_debug "found sbx on PATH: $DRAUGR_SBX"
            printf '%s' "$DRAUGR_SBX"
            return 0
        fi
    done

    # 3. Ask Windows for LOCALAPPDATA. Do not guess the user name. cmd.exe
    #    writes CRLF line ends, and tr removes them. If the variable does not
    #    exist, cmd prints the text "%LOCALAPPDATA%" unchanged.
    local localappdata
    if command -v cmd.exe >/dev/null 2>&1; then
        localappdata=$(cmd.exe /c 'echo %LOCALAPPDATA%' 2>/dev/null | tr -d '\r\n')
        if [ -n "$localappdata" ] && [ "$localappdata" != '%LOCALAPPDATA%' ]; then
            # Change C:\Users\x\AppData\Local into /mnt/c/..., then test it.
            candidate="$(dr_path_from_win "$localappdata")/DockerSandboxes/bin/sbx.exe"
            if [ -x "$candidate" ]; then
                DRAUGR_SBX=$candidate
                dr_debug "found sbx via LOCALAPPDATA: $DRAUGR_SBX"
                printf '%s' "$DRAUGR_SBX"
                return 0
            fi
        fi
    fi

    # 4. The last method: the two usual install locations of sbx, on all
    #    drives and for all users. In the inner loop, $glob has no quotes on
    #    purpose, so that the shell expands the wildcards. A glob that matches
    #    nothing gives the pattern itself. The -x test then fails, with no harm.
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

# dr_sbx <args...>: run sbx. If DRAUGR_DEBUG is set, log the full command line.
dr_sbx() {
    local sbx
    sbx=$(dr_find_sbx) || dr_die \
        "cannot find sbx.exe" \
        "sbx is a Windows binary. By default, it is not on the PATH of WSL." \
        "Install it with:  winget install Docker.sbx" \
        "Or point Draugr at it:  export DRAUGR_SBX=/mnt/c/path/to/sbx.exe"
    dr_debug "sbx $*"
    "$sbx" "$@"
}

# ---------------------------------------------------------------------------
# The log of sandboxd, and why Draugr reads it
#
# If a create fails, sbx reports one line and stops: `500 Internal Server
# Error: failed to run sandbox container`. The daemon of sbx knows much more.
# A test on 0.37.1 showed this. A kit install command did not find a file.
# The user saw only that 500 line. The log held the failed command, its exit
# code, and its output:
#
#   commands.install[2] (uv pip install -r requirements.txt): exited 2 after 13ms
#     -- captured output --
#     error: File not found: `requirements.txt`
#
# With the log, the user can find the cause. Without it, the user cannot. Thus
# Draugr reads the log. The file and its format have no documentation. If they
# change, that is a risk that Draugr accepted. Each step below can fail with no
# message. Each caller still prints the advice that it printed before this code.
# ---------------------------------------------------------------------------

# dr_sbx_daemon_log: the location of that log. It comes from the location of
# sbx, as in dr_skills_dir. If sbx or the log is missing, it returns 1.
dr_sbx_daemon_log() {
    local sbx_exe log
    sbx_exe=$(dr_find_sbx) || return 1
    log="$(dirname "$(dirname "$sbx_exe")")/sandboxes/state/sandboxd/daemon.log"
    [ -f "$log" ] || return 1
    printf '%s\n' "$log"
}

# dr_sbx_log_mark: the size of the log now. A later read can then look only at
# the lines that an operation added. The mark is a byte offset, not a time. It
# needs no clock and no date parsing. It cannot show a failure from last week as
# the current failure. It always prints a number, so the caller does not test it.
dr_sbx_log_mark() {
    local log size
    log=$(dr_sbx_daemon_log) || { printf '0\n'; return 0; }
    size=$(wc -c < "$log" 2>/dev/null) || size=0
    printf '%s\n' "${size//[^0-9]/}"
}

# dr_sbx_log_error <mark>: the last error that sandboxd wrote after <mark>. If
# there is no such error, it returns 1.
dr_sbx_log_error() {
    local mark=${1:-0} log out
    command -v jq >/dev/null 2>&1 || return 1
    log=$(dr_sbx_daemon_log) || return 1
    # Use fromjson?, not plain parsing. The daemon writes the file while the
    # code reads it. Thus the last line can be incomplete. One bad line must
    # not discard the good lines. A failed create logs a `stage`. The code
    # selects that entry before other errors in the same range. Those errors
    # can be normal noise, for example a lookup that found nothing. The error
    # field contains newlines, and -r expands them. The result is the block of
    # lines that sbx captured.
    # The second pass exists because the VM supervisor of sbx (`sailor`) logs
    # JSON INSIDE JSON. Its own severity and error sit in an escaped string in
    # `.msg`, while the OUTER level of that same entry is INFO:
    #
    #   "level":"INFO","msg":"{\"level\":\"error\",\"component\":\"sailor\",
    #     \"msg\":\"failed to create vm\",\"error\":\"...Failed to open block
    #     device ...: ... (os error 32)\"}"
    #
    # A filter that reads only the outer level cannot see those. A test over the
    # real window of a failed start showed what that costs: nine
    # such lines named the cause, and the one outer ERROR in the window said
    # `endpoint not connected`, which is a CONSEQUENCE of the VM never starting.
    # Printing that would be worse than printing nothing, because it reads as an
    # answer.
    #
    # Order of preference, and why: an outer entry with a `stage` is a failed
    # create, which sbx reports deliberately and which has always won here. Then
    # a nested cause. Then any outer error. So the create path keeps exactly the
    # behaviour it had, and the start path gains a real cause.
    out=$(tail -c "+$((mark + 1))" "$log" 2>/dev/null \
              | jq -srR 'split("\n") | map(fromjson?)
                        | (map(select(.level == "ERROR" and (.error // "") != "")))
                          as $outer
                        | (map(.msg? // "" | fromjson?
                               | select(type == "object")
                               | select((.level // "") | ascii_downcase == "error")
                               | select((.error // "") != "")))
                          as $nested
                        | (($outer | map(select(has("stage"))) | last)
                           // ($nested | last)
                           // ($outer | last))
                        | .error // empty' 2>/dev/null) || return 1
    [ -n "$out" ] || return 1
    printf '%s\n' "$out"
}

# ---------------------------------------------------------------------------
# Path translation
#
# One repository has three names. A mix-up of these names causes more bugs in
# this tool than any other cause:
#
#   WSL      /mnt/c/src/myproject   where you cd to, and where git runs
#   Windows  C:\src\myproject       the workspace path that sbx.exe accepts
#   Mound    /c/src/myproject       where sbx mounts it in the microVM
#
# The functions do not call wslpath. They are written by hand, so that they are
# pure functions. CI can then test them on a machine with no WSL.
# ---------------------------------------------------------------------------

# dr_path_win /mnt/c/src/p -> C:\src\p
dr_path_win() {
    # `local` keeps these variables out of the scope of the caller. A name with
    # no value (drive, rest) only declares the variable as local.
    local p=$1 drive rest

    # Accept only /mnt/<one letter>/... or exactly /mnt/<one letter>. These are
    # glob patterns, not regexes. [A-Za-z] is one character from that set. `:`
    # is the command that does nothing. Here it means "matched, continue".
    # All other paths return 1. The caller reads 1 as "not a Windows path".
    case "$p" in
        /mnt/[A-Za-z]/*|/mnt/[A-Za-z]) : ;;
        *) return 1 ;;
    esac

    # ${p:5:1} is a substring: 1 character at offset 5. That is the drive letter
    # in "/mnt/c/...". ${p:6} is all the text from offset 6 to the end.
    drive=${p:5:1}
    rest=${p:6}

    # ${rest#/} removes one leading "/" if there is one ("#" removes a prefix).
    # tr changes forward slashes into backslashes. In single quotes, '\\' is
    # two characters. tr reads them as one escaped backslash. This is not an
    # escape for bash. Thus the linter needs the directive below.
    # shellcheck disable=SC1003
    printf '%s:\\%s' "$(printf '%s' "$drive" | tr '[:lower:]' '[:upper:]')" "$(printf '%s' "${rest#/}" | tr '/' '\\')"
}

# dr_path_win_kit <path>: a Windows path that sbx.exe can READ. Use it for kits
# only.
#
# A workspace and a kit are different cases. This is the one place where the
# difference helps. A workspace on the ext4 file system of WSL is not possible.
# The microVM cannot bind-mount a path behind the Windows network redirector.
# Thus dr_require_win_path refuses such a path. sbx never bind-mounts a kit. It
# reads the kit on the host and packs it. Thus the UNC path works for a kit.
#
# A test on sbx 0.37.1 showed this. A kit under ~/.config on ext4 was given as
# \\wsl.localhost\<distro>\.... sbx accepted it. sbx ran its install command in
# the sandbox and applied its network rule. Thus the default location of the kit
# library can be ~/.config/draugr/kits, and not a Windows drive.
#
# Do NOT use this function for a workspace. For that reason, dr_path_win stays
# strict.
dr_path_win_kit() {
    local p=$1 out

    # A path on a Windows drive has a real path with a drive letter. That path
    # is always better: it needs no network redirector and no distro name.
    if out=$(dr_path_win "$p"); then
        printf '%s' "$out"
        return 0
    fi

    # WSL sets $WSL_DISTRO_NAME. Thus this stays a pure function. As with all
    # code here, CI can test it on a machine with no WSL.
    [ -n "${WSL_DISTRO_NAME:-}" ] || return 1
    # shellcheck disable=SC1003  # '\\' is one escaped backslash for tr, not bash
    printf '\\\\wsl.localhost\\%s%s' \
        "$WSL_DISTRO_NAME" "$(printf '%s' "$p" | tr '/' '\\')"
}

# dr_path_mound /mnt/c/src/p -> /c/src/p
# The mound path is the WSL path without "/mnt". The reason is that sbx mounts
# a workspace at the same path that it has on Windows.
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

    # Accept "C:\..." or "C:/..." or only "C:". In a glob, a backslash needs
    # an escape. Thus [\\/] means "a slash of either kind".
    case "$p" in
        [A-Za-z]:[\\/]*|[A-Za-z]:) : ;;
        *) return 1 ;;
    esac

    drive=$(printf '%s' "${p:0:1}" | tr '[:upper:]' '[:lower:]')
    rest=${p:2}                     # all the text after "C:"
    # shellcheck disable=SC1003
    printf '/mnt/%s%s' "$drive" "$(printf '%s' "$rest" | tr '\\' '/')"
}

# dr_require_win_path <path>: the limit that the README states first.
dr_require_win_path() {
    dr_path_mound "$1" >/dev/null 2>&1 && return 0
    dr_die \
        "$1 is not on a Windows drive" \
        "sbx.exe is a Windows binary, and its workspaces are Windows paths. A repo" \
        "on the ext4 file system of WSL has no path that sbx can mount." \
        "Move the project to /mnt/c/ (or another Windows drive), and work on it there."
}

# dr_path_canon_case <path>: a path on a Windows drive, with the letter case
# that the disk uses. The function returns all other paths unchanged.
#
# Why this function exists: Windows drives ignore letter case. Thus /mnt/c/code
# and /mnt/c/Code are one directory. But git, pwd, and $PWD all return the
# case that you typed, and bash compares strings with case. Thus each value
# that uses the path as a key can differ, because of how you went to the
# directory with cd.
#
# This is not a cleanup. A real failure occurred. A repo that was trusted as
# /mnt/c/Code/draugr-gateway was UNTRUSTED from /mnt/c/code/draugr-gateway.
# The file and its hash were the same. The record is "<hash>  <path>", and the
# lookup is a grep -xF. Thus the case of one letter was the only difference.
# Draugr refused the hook (fatal) and skipped .draugr.conf (a warning). The
# run then used the DEFAULTS for the agent, the sandbox name, the ports, and
# the mounts. Nothing looked broken. The fault cost an evening, two times.
#
# The function changes ONLY /mnt/<drive>/ paths. The ext4 file system of WSL
# uses case. There, two names that differ in case are two different files. A
# change of case there is the bug, not the fix.
#
# The function does each part of the path in turn, because only the file
# system knows the real case. `[ -e ]` cannot tell you. On a drive that ignores
# case, it says yes to each spelling. That is why this type of bug is hidden.
dr_path_canon_case() {
    local p=$1 out rest comp pick lc entry name

    case "$p" in
        /mnt/[A-Za-z]/*) : ;;
        *) printf '%s' "$p"; return 0 ;;
    esac

    out=/mnt/${p:5:1}
    rest=${p:7}

    # SPLIT FIRST, WITH GLOBBING OFF. The shell applies pathname expansion to
    # `set -- $rest`. A directory with the real name "[0-9]" or "*" then expands
    # to a different value. After nullglob is set below, it expands to nothing.
    # $- holds the letters of the current options. With it, the code can find
    # out if noglob is set, and not change it.
    local had_f=0
    case $- in *f*) had_f=1 ;; esac
    set -f
    local oldifs=$IFS
    IFS=/
    # shellcheck disable=SC2086  # the split on "/" is the purpose
    set -- $rest
    IFS=$oldifs
    if [ "$had_f" = 0 ]; then set +f; fi

    # NOW turn on globbing, for the directory listings. dotglob shows .draugr.
    # The real bug occurred on that part of the path. With nullglob, a missing
    # directory gives nothing, not the pattern itself. The code resets both
    # options before it returns. If they stay on, globbing changes for each
    # caller after this function.
    #
    # Use `if shopt -q`, not `shopt -q x && y=1`. With `set -e`, the second
    # form STOPS THE SHELL when the option is off. The reason is that the full
    # && list then returns non-zero. An `if` asks, and does not fail.
    local had_dot=0 had_null=0
    if shopt -q dotglob; then had_dot=1; fi
    if shopt -q nullglob; then had_null=1; fi
    shopt -s dotglob nullglob

    for comp in "$@"; do
        [ -n "$comp" ] || continue
        pick=''
        lc=${comp,,}
        for entry in "$out"/*; do
            name=${entry##*/}
            # An exact match wins at once. If there is none, keep the first
            # match that ignores case, and continue to look for an exact
            # match. A drive can be mounted with case. Then both spellings can
            # exist, and the spelling that was asked for is the correct one.
            if [ "$name" = "$comp" ]; then pick=$name; break; fi
            if [ -z "$pick" ] && [ "${name,,}" = "$lc" ]; then pick=$name; fi
        done
        # If no file on the disk has that name, keep the name that was asked
        # for. The function reports a spelling. It does not say that the path
        # exists.
        out="$out/${pick:-$comp}"
    done

    if [ "$had_dot" = 0 ]; then shopt -u dotglob; fi
    if [ "$had_null" = 0 ]; then shopt -u nullglob; fi
    printf '%s' "$out"
}

# ---------------------------------------------------------------------------
# Repository helpers
# ---------------------------------------------------------------------------

# The top of the working tree. If there is none, a fatal error that names the fix.
dr_repo_root() {
    local root
    root=$(git rev-parse --show-toplevel 2>/dev/null) || dr_die \
        "$PWD is not a git repository" \
        "Draugr works on one repository at a time. The sandbox gets a clone of it." \
        "Run 'git init' here, or cd into your project." \
        "If you want Draugr to create a repository, set DRAUGR_ON_MISSING_REPO and run dr-init."
    # ONE spelling, for each case that you used with cd. git reports the path as
    # you typed it. DR_REPO is the key for the trust record, the kit stamp, and
    # the sandbox name. Thus the case change occurs here, one time, and not in
    # each of them.
    dr_path_canon_case "$root"
}

# If there is no repository, or no commit yet, the function prints nothing and
# succeeds. In both cases, git exits with 128. Each caller here reads "no
# branch" as an answer, not as a fault. Without the `|| true`, this stops each
# caller that runs with `set -e`, and all callers do. It did exactly that
# before, when dr-init got a directory that was not yet a repository.
dr_repo_branch() {
    git -C "${1:-$PWD}" rev-parse --abbrev-ref HEAD 2>/dev/null || true
}

dr_repo_is_clean() {
    [ -z "$(git -C "${1:-$PWD}" status --porcelain 2>/dev/null)" ]
}

# ---------------------------------------------------------------------------
# Configuration
#
# The order of precedence, from lowest to highest:
#   built-in defaults -> user config -> project config -> project-local -> env -> flags
#
# The code records the source of each key. Thus dr-config can answer "why does
# it do that". The current shell sources the layers, because only then do their
# assignments take effect. The code compares the keys before and after each
# source, and that difference tells which layer set each key.
# ---------------------------------------------------------------------------

DR_CONFIG_USER="${DRAUGR_CONFIG_HOME:-${XDG_CONFIG_HOME:-$HOME/.config}/draugr}"
DR_TRUST_FILE="$DR_CONFIG_USER/trusted"

# The agents that sbx can run. Draugr has a module for two of them, in
# lib/agents/. The other eight get default.sh, because Draugr has no specific
# knowledge of them.
#
# The list is data, not text in the docs, because the code BUILDS the argument
# key of each agent from it. To give a new agent its key, add the agent here.
# No other change is necessary.
DR_AGENTS=(claude codex copilot cursor docker-agent droid gemini kiro opencode shell)

# dr_agent_args_key <agent>: the argument key for that agent.
#
# The key is in uppercase, and "-" becomes "_". The reason is that docker-agent
# is a legal agent name, but DRAUGR_AGENT_ARGS_DOCKER-AGENT is not a legal
# variable name. In the first set of tr, a "-" at the end is a literal and not a
# range. Thus the two sets are 'a-z-' and 'A-Z_', and they have the same length.
#
# This function is above DR_KEYS, not next to the similar functions. The reason
# is that the code calls it to build the array below when the file is sourced.
dr_agent_args_key() {
    printf 'DRAUGR_AGENT_ARGS_%s' "$(printf '%s' "$1" | tr 'a-z-' 'A-Z_')"
}

# All the keys that Draugr knows. dr-config goes through this list, and
# dr-doctor compares the configuration with it. If a configuration file has an
# unknown DRAUGR_* key, Draugr reports it and does not ignore it.
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
    DRAUGR_PLUGIN_STORE
    DRAUGR_REQUIRES DRAUGR_EXCLUSIVE DRAUGR_LINGER
    DRAUGR_SCAN DRAUGR_SCAN_PATTERNS DRAUGR_SCAN_FAIL
    DRAUGR_FORGE DRAUGR_FORGE_NOSCAN DRAUGR_FORGE_LAYERS
)

# One DRAUGR_AGENT_ARGS_<AGENT> for each agent. The loop adds them, so that
# nobody types them.
#
# These are the only keys with NO built-in default, on purpose. _dr_defaults
# does not set them. Thus an empty value that is set stays different from a
# value that is not set. A user can want "no arguments for codex, whatever the
# general key says". The user writes that as DRAUGR_AGENT_ARGS_CODEX="".
for _dr_a in "${DR_AGENTS[@]}"; do
    DR_KEYS+=("$(dr_agent_args_key "$_dr_a")")
done
unset _dr_a

# The -g is necessary. A caller can source this file from a function, and
# each bats test does. Then a plain `declare -A` limits the array to that
# function. The array is lost when the function returns. A later
# DR_ORIGIN[DRAUGR_KIT]= is then a subscript of an *indexed* array, that is,
# arithmetic on the string ".draugr/kit".
declare -gA DR_ORIGIN=()

# What the general DRAUGR_AGENT_ARGS held before a per-agent key replaced it,
# where that general value came from, and which key did the replacing. All three
# are empty when no replacement happened. dr-doctor reports the combination,
# because it is invisible otherwise: the replacement overwrites both the value
# and its origin. See the comment at the swap itself.
DR_AGENT_ARGS_REPLACED=
DR_AGENT_ARGS_REPLACED_FROM=
DR_AGENT_ARGS_REPLACED_BY=

# Configuration layers that exist on the disk, but that Draugr did NOT source,
# because they are not trusted. Without this list, a skipped layer looks the
# same as a layer that set nothing. dr-config reads the list and says so. You
# then know why the value that you wrote is not in the table. The -g is
# necessary for the same reason as above.
declare -ga DR_UNTRUSTED=()

# shellcheck disable=SC2034  # these are the configuration keys; each dr-* reads them
_dr_defaults() {
    DRAUGR_AGENT=claude
    # dr-go gives this to the agent after "--". If it is empty, nothing
    # changes. To continue the last session by default, set it to "--continue".
    DRAUGR_AGENT_ARGS=

    # ssh | sbx: how dr-go and dr-shell get a terminal in the mound.
    #
    # The default is ssh, because only with ssh does Ctrl-Z work. sbx.exe is a
    # WINDOWS binary that WSL interop runs. If you suspend it, you suspend the
    # relay, not a process in the sandbox. The session then stops and fails
    # after some seconds with "inspect exec: context deadline exceeded". Tests
    # on sbx 0.37.1 showed both results.
    #
    # Over ssh, the remote pty does its own job control. Ctrl-Z stops the agent
    # and gives you a shell in the mound, and fg takes you back. That is the
    # reason that Draugr runs in WSL.
    DRAUGR_ATTACH=ssh

    DRAUGR_SANDBOX=              # empty => draugr-<repo leaf>
    DRAUGR_MEMORY=               # empty => sbx default (50% of host RAM, max 32 GiB)
    DRAUGR_CPUS=                 # empty => sbx default (all)
    DRAUGR_CLONE=true
    DRAUGR_TEMPLATE=
    # A LIST, with spaces between the items. sbx accepts --kit more than one
    # time and merges the results. Thus the items add to each other. They do
    # not replace each other.
    DRAUGR_KIT=.draugr/kit
    DRAUGR_KIT_STORE="$DR_CONFIG_USER/kits"

    DRAUGR_PORTS=
    # Ports on THIS machine that the mound can connect to, with spaces between
    # them. Only port numbers. Each dr-up finds the address of the port again,
    # and Draugr never stores it, because the address changes after a reboot.
    DRAUGR_HOST_PORTS=
    DRAUGR_MOUNTS=

    # The OWN model of the agent, for when it must not be the cloud of its
    # vendor. The default is empty. Then nothing changes in how the agent
    # connects to its service.
    DRAUGR_MODEL=
    # Where that model is served. It is a port number on THIS machine, or a
    # full URL. Each attach finds the address of a port again, because the
    # address changes after a reboot. Draugr uses a URL exactly as written.
    # The default is the query-only proxy in share/ollama-proxy, not port 11434
    # of Ollama. The reason is that the port of Ollama for inference also
    # serves DELETE /api/delete.
    DRAUGR_MODEL_URL=11435
    # The fast, low-cost model for background work. Empty means "the same as
    # DRAUGR_MODEL". Two models are faster only if both stay in memory. If the
    # second model removes the first from memory, the reloads cost more time
    # than the smaller model saves.
    DRAUGR_MODEL_FAST=
    # Any environment variables for the session of the agent, as NAME=value
    # pairs with spaces between them. Use this for each value that has no
    # Draugr key. It was written for the context limit of a local model. The
    # variable for that limit has no documentation, and its name can change.
    DRAUGR_ENV=

    DRAUGR_DATA=
    DRAUGR_DATA_PUSH=auto
    DRAUGR_DATA_PULL=manual
    DRAUGR_DATA_DELETE=false
    DRAUGR_DATA_CHMOD=D755,F644

    # The maximum size of one file for `dr-data diff`, in bytes. Data files are
    # often very large, and a real diff of a 4 GB CSV helps nobody. Thus for a
    # larger file, the command reports the name and the size, not the content.
    # 256 KB is enough for the scripts and configuration files that you read
    # carefully.
    DRAUGR_DATA_DIFF_MAX=262144

    DRAUGR_BRANCH=               # empty => the branch currently checked out
    DRAUGR_REMOTE=draugr
    DRAUGR_REQUIRE_CLEAN=true
    DRAUGR_AUTO_SYNC=true

    # Off by default. Users expect the mound to continue to run. A stop also
    # breaks a workflow that the kit format supports on purpose.
    # publishedPorts and startup commands exist, so that a mound can SERVE
    # something, and a stop ends that service. A test on one machine showed
    # this: a running mound uses about 1.4 GB. A cold start takes 4.2s, and a
    # start of a running mound takes 0.36s. Turn it on for a project that
    # serves nothing. Do not make it the default.
    DRAUGR_STOP_ON_EXIT=false

    # What to do when you give Draugr a directory that is not a repository.
    # The default is "fail". A new git repo in the directory of a user is a
    # real change. Draugr must not make it because of a typing error in a path.
    #   fail              refuse, and tell the other choices
    #   create-add-all    init and commit all files ("I forgot to git init")
    #   create-data-only  init with a .gitignore of "*", so git tracks no file
    #                     and all files go through DRAUGR_DATA
    DRAUGR_ON_MISSING_REPO=fail

    DRAUGR_MEM_SYNC=auto
    DRAUGR_MEM_STORE="${XDG_DATA_HOME:-$HOME/.local/share}/draugr/memory"

    # The plugin library that dr-plugin manages. It is on a Windows drive, so
    # that a mound can mount it. The default is empty, and then the feature is
    # off. The memory store has a good default location, but this directory
    # has none. It must be mountable into a mound, and $HOME in WSL is not.
    # See docs/CLAUDE_PLUGINS.md.
    DRAUGR_PLUGIN_STORE=

    # Run-state dependencies: other repositories whose mounds must be RUNNING
    # before the mound of this repository is useful. If it is empty, the
    # feature is off. Draugr writes no claim and makes no directory, and dr-up
    # does the same as before. See docs/DEPENDENCIES.md.
    DRAUGR_REQUIRES=

    # Draugr reads the next two keys from the configuration of the DEPENDENCY,
    # never from the configuration of the consumer. Both keys tell what type
    # of resource the mound of this repository is. Exclusive use is a property
    # of the resource. A gateway in front of one desktop is exclusive. A
    # database with a queue is not. If each consumer decides, one careless
    # repository can break it.
    DRAUGR_EXCLUSIVE=false

    # How long a mound that runs AS A DEPENDENCY continues to run after its
    # last user leaves. The time is not in seconds. The resource that this was
    # written for takes minutes to boot, and a dr-up --recreate must not cost
    # that time. "off" keeps it running until somebody stops it. Draugr never
    # stops a mound that you started yourself.
    DRAUGR_LINGER=10m

    DRAUGR_SCAN=true
    DRAUGR_SCAN_PATTERNS=".env *.pem *.key id_rsa id_ed25519 credentials.json secrets.*"
    DRAUGR_SCAN_FAIL=block

    # The name of the forge VM, and the ONLY switch of the forge. Empty means
    # that there is no forge, and that is correct for almost all users. The
    # forge is a Windows 11 VM for builds of Windows software, controlled
    # through AppSandbox. About one user in a hundred needs it. While this is
    # empty, dr-forge refuses all actions. Thus nobody turns on the feature
    # by accident.
    #
    # It is the name of a VM, not a path. The VM is the item that exists on
    # both sides of the boundary. AppSandbox knows it by name, and so does the
    # tunnel supervisor. See docs/FORGE.md.
    DRAUGR_FORGE=

    # Guest paths that dr-forge init excludes from Defender. SEMICOLONS go
    # between the paths. A Windows path can contain spaces but not
    # semicolons. For the same reason, Windows uses semicolons in PATH. Empty
    # means that Defender stays as it is, and that is the correct default.
    # init is general. Only the project knows which directories are build
    # output and do not need a scan.
    DRAUGR_FORGE_NOSCAN=
    # Where dr-layer keeps the disk layers of the forge. Empty means
    # C:\ForgeLayers, which is the default of layer.ps1. The two values must
    # stay the same text. If this file sends the value, the output shows it
    # as a choice of a user, not as the default. Use your FASTEST disk, not
    # your largest. Each read goes through the chain. Thus the frozen parents
    # that hold Windows, Visual Studio, and the engine get the most reads. A
    # store on each drive is normal. The engine layers are the large ones.
    DRAUGR_FORGE_LAYERS=
}

# --- how the code finds the source of each key ------------------------------
#
# Both helpers below use the *indirect expansion* of bash. When $k holds the
# string "DRAUGR_AGENT", then:
#
#     ${!k}     is the value of the variable that $k NAMES, that is, $DRAUGR_AGENT
#     ${!k-}    the same, but empty and not an error if it is not set
#     printf -v NAME  writes into the variable NAME, and does not print
#
# With them, the code can loop over DR_KEYS and read or write each key by name.
# It needs no case statement with 23 branches.

# Copy each current key into a second set of variables with a prefix.
# _dr_snapshot_into _DR_PREV_ saves $DRAUGR_AGENT as $_DR_PREV_DRAUGR_AGENT, and
# the same for all keys. That is the "before" state.
_dr_snapshot_into() {
    local prefix=$1 k
    for k in "${DR_KEYS[@]}"; do
        printf -v "${prefix}${k}" '%s' "${!k-}"
    done
}

# Compare the current state with the saved "before" state. Each key that
# changed gets the layer that the code sourced last as its source. Thus a
# configuration file that sets three keys is the source of exactly those
# three. With this, `dr-config` can tell where each value came from.
_dr_attribute() {
    local prefix=$1 origin=$2 k ref
    for k in "${DR_KEYS[@]}"; do
        ref="${prefix}${k}"          # for example "_DR_PREV_DRAUGR_AGENT"
        if [ "${!k-}" != "${!ref-}" ]; then
            DR_ORIGIN[$k]=$origin
        fi
    done
}

# dr_load_config [repo-root]
# Sets each DRAUGR_* variable and DR_ORIGIN. Call it one time in each process.
dr_load_config() {
    local repo=${1:-}

    # STEP 1: save each value that came from the environment.
    #
    # DRAUGR_AGENT=codex dr-go  must win over each configuration file. But the
    # code sources those files next, in this shell, and they overwrite the
    # value. Thus save the values of the environment now, and put them back at
    # the end.
    #
    # ${!k+set} is "set" only when the variable that $k NAMES exists, even if
    # it is empty. ${!k:+set} is different: it treats an empty value as
    # missing. DRAUGR_PORTS= in the environment means "no ports" on purpose.
    local k envk had_env=()
    for k in "${DR_KEYS[@]}"; do
        if [ -n "${!k+set}" ]; then
            envk="_DR_ENV_$k"                # for example "_DR_ENV_DRAUGR_AGENT"
            printf -v "$envk" '%s' "${!k}"
            had_env+=("$k")
        fi
    done

    # STEP 2: set the built-in defaults, and record them as the source.
    _dr_defaults
    local key
    for key in "${DR_KEYS[@]}"; do DR_ORIGIN[$key]="built-in default"; done
    DR_UNTRUSTED=()

    # STEP 3: source each configuration file in turn, the lowest precedence
    # first. Save the state before and after each file, to find the keys that
    # it changed.
    #
    # ${repo:+VALUE} expands to VALUE only when $repo is not empty. Outside a
    # repository, those two items become empty strings, and the loop skips
    # them. (It is the opposite of the ${VAR:-default} form.)
    local layer
    for layer in \
        "$DR_CONFIG_USER/config" \
        "${repo:+$repo/.draugr.conf}" \
        "${repo:+$repo/.draugr.local.conf}"
    do
        if [ -z "$layer" ] || [ ! -f "$layer" ]; then
            continue
        fi
        # Do not source a project configuration that the user did not see.
        # This does `continue` and does not stop. The code skips a file that
        # is not trusted, and the run continues with the next layers. Record
        # the skipped files, so that the end of the output can report them.
        # The user reads the end.
        dr_trust_check "$layer" || { DR_UNTRUSTED+=("$layer"); continue; }

        _dr_snapshot_into _DR_PREV_
        dr_debug "sourcing $layer"
        # "." is `source`. It runs the file in THIS shell, so that its values
        # stay. (A subprocess changes only its own copy.)
        # shellcheck disable=SC1090  # the path is known only at runtime
        . "$layer" || dr_die "$layer failed to load" "Check it with: bash -n $layer"
        _dr_attribute _DR_PREV_ "$layer"
    done

    # STEP 4: put the values of the environment back on top, and record the
    # environment as their source. The length test is for bash 4.3 and older.
    # There, with `set -u`, the expansion of an empty array is an error.
    if [ ${#had_env[@]} -gt 0 ]; then
        for k in "${had_env[@]}"; do
            envk="_DR_ENV_$k"
            printf -v "$k" '%s' "${!envk}"
            DR_ORIGIN[$k]="environment"
        done
    fi

    # Defaults that come from the repo. The code sets them only if they are
    # still not set.
    if [ -z "$DRAUGR_BRANCH" ] && [ -n "$repo" ]; then
        DRAUGR_BRANCH=$(dr_repo_branch "$repo")
        DR_ORIGIN[DRAUGR_BRANCH]="detected (current branch)"
    fi
    if [ -z "$DRAUGR_SANDBOX" ] && [ -n "$repo" ]; then
        DRAUGR_SANDBOX=$(dr_sandbox_name "$repo")
        DR_ORIGIN[DRAUGR_SANDBOX]="derived from repo name"
    fi

    # STEP 5: DRAUGR_AGENT now has its final value. Find the values that
    # depend on the agent. This step must be last. The layers decide the
    # agent, and an earlier step uses the wrong layer.

    # DRAUGR_AGENT_ARGS holds the flags of the AGENT. "--continue" is a flag of
    # Claude Code, and "resume --last" is a flag of Codex. Neither has a meaning
    # for the other agent. Thus one value for the full machine is wrong when
    # you use a second agent. You cannot prevent this by hand. A shell
    # condition in ~/.config/draugr/config does not work. That layer is sourced
    # BEFORE the project layer, so $DRAUGR_AGENT still has the default then.
    #
    # Thus there is a key for each agent. It REPLACES the general key, and does
    # not add to it. .draugr/kit.<agent>/ uses the same rule against
    # .draugr/kit/.
    #
    # Use ${!k+set}, not ${!k:+set}. An empty DRAUGR_AGENT_ARGS_CODEX means
    # "nothing for codex" on purpose. It must win over a general value.
    local _ak; _ak=$(dr_agent_args_key "$DRAUGR_AGENT")
    if [ -n "${!_ak+set}" ]; then
        # Keep what the general key held, and where it came from, before the
        # replacement hides both. dr-doctor needs them to tell a deliberate
        # per-agent value from one that threw a project setting away in silence.
        #
        # Found the hard way. A user put
        # DRAUGR_AGENT_ARGS=--continue in the .draugr.conf of a repo, ran dr-go,
        # and did not get the conversation back. The file was trusted and was
        # read. A DRAUGR_AGENT_ARGS_CLAUDE in the machine-wide config, written
        # for the plugin seed, had replaced it - for every repo on the machine,
        # because this swap happens AFTER the whole cascade, once DRAUGR_AGENT
        # is known. So a user-level per-agent key beats a project-level general
        # one, whatever the usual order of the layers.
        # shellcheck disable=SC2034  # bin/dr-doctor reads all three
        DR_AGENT_ARGS_REPLACED=${DRAUGR_AGENT_ARGS:-}
        # shellcheck disable=SC2034
        DR_AGENT_ARGS_REPLACED_FROM=${DR_ORIGIN[DRAUGR_AGENT_ARGS]:-}
        # shellcheck disable=SC2034
        DR_AGENT_ARGS_REPLACED_BY=$_ak
        # shellcheck disable=SC2034  # dr-go reads it, as it reads the other keys
        DRAUGR_AGENT_ARGS=${!_ak}
        DR_ORIGIN[DRAUGR_AGENT_ARGS]="${DR_ORIGIN[$_ak]:-built-in default} (via $_ak)"
    fi

    dr_agent_load
}

# ---------------------------------------------------------------------------
# Agent modules
#
# Draugr does the same work for each agent. The exception is the private file
# layout of an agent. Today that means memory, and almost nothing else. That
# knowledge is in lib/agents/<agent>.sh, not in a case statement in each
# command. It is the part that is most likely to be wrong. The agents do not
# document it. It comes from tests, not from a published source, and it changes
# with no notice. With one file for each agent, a wrong guess about one agent
# cannot break another agent.
#
# lib/agents/default.sh holds the interface. An agent that Draugr did not test
# gets it. That is true for eight of the ten agents of sbx.
# ---------------------------------------------------------------------------

# dr_agent_load: source the module for $DRAUGR_AGENT, or the default module.
#
# The code calls it two times. The first call is at the end of this file, so
# that a command that reads no configuration still has the functions. The
# second call is at the end of dr_load_config, after the layers have their
# final values. A second module defines each function again. Thus each module
# must define ALL the functions. An incomplete module leaves the answers of
# one agent in the session of a different agent.
dr_agent_load() {
    local agent=${DRAUGR_AGENT:-claude} file
    file="$DRAUGR_ROOT/lib/agents/$agent.sh"
    [ -f "$file" ] || file="$DRAUGR_ROOT/lib/agents/default.sh"
    dr_debug "agent module: ${file#"$DRAUGR_ROOT"/}"
    # shellcheck disable=SC1090  # the path is known only at runtime
    . "$file" || dr_die "could not load the agent module $file"
}

# dr_agent_known: the agents that have a Draugr module, with spaces between them.
#
# The list comes from the directory, not from a list that someone must update.
# Thus to add gemini, you add lib/agents/gemini.sh, and nothing else. "default"
# is not an agent, so the answer does not include it.
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

# dr_config_set_flag <KEY> <value>: the highest precedence, for command-line flags.
dr_config_set_flag() {
    printf -v "$1" '%s' "$2"
    # shellcheck disable=SC2034  # dr-config reads DR_ORIGIN
    DR_ORIGIN[$1]="command-line flag"
}

# People write configuration files by hand. Thus accept each usual spelling of
# "yes". All other values are false, also an empty value and a typing error.
dr_is_true() {
    case "${1:-}" in
        true|True|TRUE|yes|y|1|on) return 0 ;;
        *) return 1 ;;
    esac
}

# ---------------------------------------------------------------------------
# Trust
#
# To source a file from a cloned repository is to run its code. The first time
# that you accept a project configuration, Draugr records its hash. Draugr does
# not source a file that it did not record. direnv does the same, for the same
# reason.
# ---------------------------------------------------------------------------

# The SHA-256 of a file, with no other text. Linux has sha256sum, and macOS has
# shasum. The code uses the one that exists. Both give the same hash format.
_dr_hash() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | cut -d' ' -f1
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | cut -d' ' -f1
    else
        dr_die "no sha256sum or shasum available" "Install coreutils."
    fi
}

# Trust is for the CONTENT, not for the path. The record is "<hash>  <path>". A
# change to a trusted file changes its hash. The file is then not trusted, with
# no message, until you accept it again.
dr_trust_is_trusted() {
    local file=$1 hash
    [ -f "$DR_TRUST_FILE" ] || return 1
    # Both parts of the record must be canonical. If not, the lookup misses a
    # file that it saw before (see dr_path_canon_case). dr_repo_root changes
    # the usual path. But a file from the command line has the case as typed.
    file=$(dr_path_canon_case "$file")
    hash=$(_dr_hash "$file")
    grep -qxF "$hash  $file" "$DR_TRUST_FILE" 2>/dev/null
}

dr_trust_add() {
    local file=$1 hash
    # Record the canonical path, so that the lookup above finds it. See
    # dr_path_canon_case.
    file=$(dr_path_canon_case "$file")
    hash=$(_dr_hash "$file")
    mkdir -p "$DR_CONFIG_USER"
    # Remove the old entries for this path, then record the current hash.
    if [ -f "$DR_TRUST_FILE" ]; then
        grep -vF "  $file" "$DR_TRUST_FILE" > "$DR_TRUST_FILE.tmp" 2>/dev/null || :
        mv "$DR_TRUST_FILE.tmp" "$DR_TRUST_FILE"
    fi
    printf '%s  %s\n' "$hash" "$file" >> "$DR_TRUST_FILE"
    chmod 600 "$DR_TRUST_FILE"
}

# The configuration of the user needs no trust. The user wrote it. A prompt
# for it teaches users to accept each prompt.
dr_trust_check() {
    local file=$1
    case "$file" in
        "$DR_CONFIG_USER"/*) return 0 ;;
    esac
    dr_trust_is_trusted "$file" && return 0
    dr_warn "did not source $file, because it is not trusted"
    printf '  %sThis file is shell code. To source it is to run it.%s\n' "$_DR_DIM" "$_DR_OFF" >&2
    printf '  %sRead it, then run:  dr-trust %s%s\n' "$_DR_DIM" "$file" "$_DR_OFF" >&2
    return 1
}

# ---------------------------------------------------------------------------
# The shared preamble
# ---------------------------------------------------------------------------

# dr_context: the first step of each command that uses a mound.
#
# It sets DR_REPO (the WSL path) and DR_REPO_WIN (the same repo, in the format
# that sbx.exe requires). It also loads the configuration layers, and they set
# DRAUGR_SANDBOX. The variables here have no `local`, so they go into the scope
# of the caller on purpose.
dr_context() {
    DR_REPO=$(dr_repo_root)
    dr_require_win_path "$DR_REPO"
    # shellcheck disable=SC2034  # the dr-* command that called this reads it
    DR_REPO_WIN=$(dr_path_win "$DR_REPO")
    dr_load_config "$DR_REPO"
}

# dr_context_create: dr_context, for the two commands that can create a repo.
#
# Only dr-up and dr-init call this. All other commands use dr_context, which
# refuses. The reason is the same as for dr-status, which does not start a
# stopped mound. A command that you run to see the state must not change the
# state.
#
# The difficult part is the order. The policy is in the configuration. The
# project configuration is in the directory, and the directory is not yet a
# repository. Thus the code must first load the configuration for a plain
# path, and call dr_load_config EXACTLY ONE TIME. A second call sees the
# values from the first call, and thinks that they came from the environment.
# It then gives them precedence over each configuration file. Thus the code
# loads one time, then acts.
dr_context_create() {
    local dir
    dir=$(git rev-parse --show-toplevel 2>/dev/null) || dir=$PWD
    dr_require_win_path "$dir"
    dr_load_config "$dir"

    if ! git -C "$dir" rev-parse --git-dir >/dev/null 2>&1; then
        dr_repo_create "$dir"
    fi

    DR_REPO=$dir
    # shellcheck disable=SC2034  # the dr-* command that called this reads it
    DR_REPO_WIN=$(dr_path_win "$dir")
}

# dr_repo_create <dir>: do what DRAUGR_ON_MISSING_REPO says. For "fail", it is
# a fatal error. It sets DR_REPO_CREATED to the mode that it used. The caller
# then knows that the repository is new, and that the caller must commit the
# files that it writes next. If the repo existed before, the value is empty.
DR_REPO_CREATED=

dr_repo_create() {
    local dir=$1 mode=${DRAUGR_ON_MISSING_REPO:-fail}

    # Make sure that the mode is correct before the code writes a file. A
    # typing error in the value then gives a clean refusal, not half a
    # repository.
    case "$mode" in
        fail) dr_die \
            "$dir is not a git repository" \
            "Draugr works on one repository at a time. The sandbox gets a clone of it." \
            "Run 'git init' here, or set DRAUGR_ON_MISSING_REPO so that Draugr does it:" \
            "  create-add-all     commit the files that are here, then use git as usual" \
            "  create-data-only   track no file; the files go through DRAUGR_DATA" ;;
        create-add-all|create-data-only) : ;;
        *) dr_die "DRAUGR_ON_MISSING_REPO is '$mode'" \
                  "Expected one of: fail, create-add-all, create-data-only." \
                  "It came from ${DR_ORIGIN[DRAUGR_ON_MISSING_REPO]}." ;;
    esac

    git -C "$dir" init -q -b "${DRAUGR_BRANCH:-main}" \
        || dr_die "could not create a git repository in $dir"

    # A commit needs an identity. If the machine has no global identity, git
    # prints a message of four lines from inside the Draugr command. Thus set
    # an identity locally, only for this temporary repo, and tell the user.
    if ! git -C "$dir" var GIT_COMMITTER_IDENT >/dev/null 2>&1; then
        git -C "$dir" config user.name Draugr
        git -C "$dir" config user.email draugr@localhost
        dr_info "no git identity is configured; set a local identity for this repo"
    fi

    case "$mode" in
    create-data-only)
        # The dummy repo has one tracked file. That file ignores all files, also
        # itself. Thus `git status` is always empty, and DRAUGR_REQUIRE_CLEAN
        # never finds a change. -f is necessary, because the pattern also
        # matches .gitignore.
        printf '%s\n' '# Draugr data-only mode: git tracks nothing here.' '*' \
            > "$dir/.gitignore"
        git -C "$dir" add -f .gitignore
        git -C "$dir" commit -qm "Draugr: data-only repository"

        # The mode does nothing if dr-data has no files to copy. Thus give it a
        # pattern. Set the value in this shell and on the disk. A second load of
        # the configuration is the load that dr_context_create must not do.
        if [ ! -f "$dir/.draugr.conf" ]; then
            printf '%s\n' \
                '# Draugr wrote this file for a directory that had no git repository.' \
                '# git tracks no file here. These patterns decide which files go' \
                '# to and from the mound. See dr-data --help.' \
                'DRAUGR_DATA="*"' \
                'DRAUGR_ON_MISSING_REPO=create-data-only' > "$dir/.draugr.conf"
            dr_trust_add "$dir/.draugr.conf"
            # SET IT HERE, AND ONLY HERE: in the branch that just WROTE that value
            # to the file. The default must agree with what a child process reads.
            # A child reads the file again. It does not inherit this shell.
            #
            # A real failure occurred on the first dr-up of a new gateway. The
            # code set the value in all cases. Thus dr-up held '*' for a
            # configuration that says nothing about data. dr-up passed its own
            # `-n "$DRAUGR_DATA"` guard and called dr-data. dr-data read the
            # file, found nothing, and stopped. The first message of the new
            # gateway was "auto data push failed", for a push that it did not need.
            #
            # A data-only repo that has a configuration with no data names no
            # data. That is a full answer, and `dr-forge gateway` uses it. A
            # gateway holds a proxy and an allowlist, and the mound already
            # mounts its source read-only.
            [ -n "${DRAUGR_DATA:-}" ] || {
                DRAUGR_DATA='*'
                DR_ORIGIN[DRAUGR_DATA]="data-only mode"
            }
        fi
        DR_REPO_CREATED=$mode
        dr_ok "created a data-only repository in $dir"
        ;;

    create-add-all)
        # This mode commits all files. Thus first ignore each file that must NOT
        # be committed. Two sets are important. The first set is a safety fix.
        # dr-scan reports only UNTRACKED files. A committed credential goes into
        # the clone of the agent and into the history. The scan that exists to
        # find it then says nothing.
        if [ ! -f "$dir/.gitignore" ]; then
            local pat pats=()
            printf '%s\n' '# Draugr wrote this file. First, names of credential files:' \
                > "$dir/.gitignore"
            read -ra pats <<< "${DRAUGR_SCAN_PATTERNS:-}"
            [ ${#pats[@]} -eq 0 ] || printf '%s\n' "${pats[@]}" >> "$dir/.gitignore"

            # The Draugr files for each checkout. Without these lines, the next
            # dr-up writes .draugr/kit.applied, and the tree has changes. The
            # dr-go after that refuses, in a repo that Draugr created as clean.
            printf '\n%s\n%s\n%s\n%s\n' \
                '# Draugr: these files describe this checkout, not the project.' \
                '.draugr.local.conf' '.draugr/kit.applied' '.draugr/tmp/' \
                >> "$dir/.gitignore"

            # Then the data patterns. rsync copies those files. The README says
            # that both sides must ignore them in git.
            read -ra pats <<< "${DRAUGR_DATA:-}"
            if [ ${#pats[@]} -gt 0 ]; then
                printf '\n%s\n' '# DRAUGR_DATA goes next to git, not through it:' \
                    >> "$dir/.gitignore"
                for pat in "${pats[@]}"; do printf '%s\n' "$pat" >> "$dir/.gitignore"; done
            fi
        fi

        # Tell what was committed and what changes now. This mode gives back a
        # usual git repo, with the usual test for uncommitted changes. That
        # surprises users who wanted the other mode.
        git -C "$dir" add -A
        git -C "$dir" commit -qm "Draugr: initial commit" \
            || dr_die "could not make the initial commit in $dir"
        DR_REPO_CREATED=$mode
        dr_ok "created a git repository in $dir and committed the files that were there"
        printf '  %sIt is now a usual repo. Commit before each session, or%s\n' \
            "$_DR_DIM" "$_DR_OFF" >&2
        printf '  %suse dr-go --dirty. Look at what was committed before you use it.%s\n' \
            "$_DR_DIM" "$_DR_OFF" >&2
        ;;
    esac
}

# dr_repo_commit_setup <dir>: commit the files that dr-init wrote after the repo.
#
# dr-init writes .draugr.conf and the kit *after* the repository exists.
# Without this function, the new repo has changes when dr-init returns. In
# data-only mode, that is a real problem. The purpose of the mode is that the
# tree is always clean. A change after the first command breaks that purpose.
# If dr_repo_create did not just run, the function does nothing.
dr_repo_commit_setup() {
    local dir=$1
    [ -n "$DR_REPO_CREATED" ] || return 0

    case "$DR_REPO_CREATED" in
    create-data-only)
        # Use named paths and -f, because .gitignore says "*" and matches these
        # files too. Do not use `add -A`, on purpose. This mode must not track
        # the files of the user.
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

    # An empty stage is a good result. It means that all files were already
    # in place, and dr-init wrote nothing. --quiet exits with 1 when there IS a
    # staged change. Thus the commit runs when the test fails.
    git -C "$dir" diff --cached --quiet \
        || git -C "$dir" commit -qm "Draugr: project setup"
}

# dr_confirm <question>: ask before an action that you cannot undo.
#
# Three results, as in dr-trust: the user gave --yes, a person answered, or
# there is no terminal. In the last case, the function refuses and does not
# assume yes. A prompt that accepts by itself in a script is not a prompt.
dr_confirm() {
    local reply
    if [ -n "${DR_ASSUME_YES:-}" ]; then
        return 0
    fi
    if [ ! -t 0 ]; then
        dr_die "$1" "There is no terminal, so Draugr does not assume an answer. If you agree, use --yes."
    fi
    printf '%s [y/N] ' "$1" >&2
    read -r reply
    case "$reply" in
        y|Y|yes|Yes) return 0 ;;
        *) return 1 ;;
    esac
}

# dr_require_tty <what>: fail early and clearly, not deep in sbx.
#
# `sbx run` attaches an interactive session. Without a terminal, it starts and
# then fails with "inspect exec: context deadline exceeded". That message tells
# the reader nothing. A test on sbx 0.37.1 showed this.
dr_require_tty() {
    [ -t 0 ] && [ -t 1 ] && return 0
    dr_die \
        "$1 needs a terminal" \
        "It attaches an interactive session. That cannot work from a pipe or a script." \
        "To run one command with no interaction, use:  dr-shell -- <command>"
}

# ---------------------------------------------------------------------------
# Attach
#
# There are two transports, and they are NOT the same.
#
# `sbx run` and `sbx exec` connect to the mound through sbx.exe. sbx.exe is a
# Windows binary that WSL runs through interop. The terminal where you type
# belongs to WSL, but the process that reads it does not. Thus Ctrl-Z
# suspends the relay, not a process in the sandbox. The key press never
# arrives, and the daemon stops getting data from its client. Some seconds
# later, the full session fails with "inspect exec: context deadline exceeded".
#
# ssh does not have this problem. The client is a native Linux binary, and the
# other end is a real pty. Thus job control occurs in the sandbox, which is the
# correct place. Ctrl-Z stops the agent and gives you the shell of the mound,
# and fg takes you back. Tests on sbx 0.37.1 showed both results. See
# docs/WORKFLOW.md.
#
# That is why the default of DRAUGR_ATTACH is ssh. It is also the reason that
# Draugr runs in WSL and not in PowerShell.
# ---------------------------------------------------------------------------

# The Host pattern that dr-setup writes into ~/.ssh/config. git and rsync use
# the same pattern. Thus an attach needs no port, no key, and no new setup.
dr_ssh_host() { printf '%s.sbx' "$DRAUGR_SANDBOX"; }

# The code makes sure that the value is correct before it starts anything. A
# typing error then gives a clean refusal. Draugr does not select a transport
# for you with no message.
dr_attach_check() {
    case "$DRAUGR_ATTACH" in
        ssh|sbx) return 0 ;;
        *) dr_die "DRAUGR_ATTACH is '$DRAUGR_ATTACH'" \
                  "Use ssh (job control works) or sbx (job control does not work)." \
                  "The value came from ${DR_ORIGIN[DRAUGR_ATTACH]:-an unknown source}." ;;
    esac
}

# printf %q on each argument. This is the quoting of bash. Bash writes it here,
# and bash reads it on the other side. Only that pair is sure to agree.
dr_shquote() {
    local out='' a
    for a in "$@"; do out+=" $(printf '%q' "$a")"; done
    printf '%s' "${out# }"
}

# ---------------------------------------------------------------------------
# The agent's own model
#
# DRAUGR_MODEL sends the agent to a model that is not the cloud of its vendor.
# The three functions here answer the three questions that this causes. Is the
# value a port or a URL? Which address does the mound connect to? Can the
# combination work?
# ---------------------------------------------------------------------------

# dr_model_is_port <value>: true when DRAUGR_MODEL_URL names a local port.
#
# Only digits. There is no third form, on purpose. In the mound, "localhost"
# means the MOUND. Thus a value such as localhost:11435 is a usual URL. The
# host-port code below must not change it. If it does, the sandbox connects
# to itself and fails, with no useful message.
dr_model_is_port() {
    case "${1:-}" in
        ''|*[!0-9]*) return 1 ;;
    esac
}

# dr_model_url: DRAUGR_MODEL_URL as an address that the mound can open.
#
# A port number becomes http://<this machine>:<port>. The code finds the
# address NOW and does not store it. dr-hostport finds it again at each start
# for the same reason. WSL gets a new address at each boot, so a stored address
# becomes wrong. Any other value is the endpoint of a different service, and
# the function prints it unchanged. If the function cannot find the address, it
# returns 1.
dr_model_url() {
    local ip
    if ! dr_model_is_port "${DRAUGR_MODEL_URL:-}"; then
        printf '%s' "${DRAUGR_MODEL_URL:-}"
        return 0
    fi
    ip=$(dr_host_ip) || return 1
    printf 'http://%s:%s' "$ip" "$DRAUGR_MODEL_URL"
}

# dr_model_probe <url>: what answers at that URL. It prints one word:
#
#   proxy    the query-only proxy, with a model server behind it
#   stalled  the proxy answers, but nothing is behind it
#   bare     a model server with no proxy (the agent can also administer it)
#   alive    something answers, but it is neither of those (another service)
#   dead     nothing listens
#   unknown  there is no curl here, so the code cannot ask
#
# Only `dead` and `stalled` mean that the session cannot work. That difference
# is the reason that the function returns a word and not a status. A company
# endpoint that does not know /healthz answers 404, and it is fully usable. If
# "not the proxy" means "broken", the code refuses the case for which
# DRAUGR_MODEL_URL accepts a full URL.
#
# nginx itself serves /healthz, with no upstream. Thus /healthz separates the
# proxy from the server behind it. That is how the code can tell `stalled`
# from `proxy`. From inside the agent, the two fail in the same way.
dr_model_probe() {
    local url=$1 code
    local -a np=()
    command -v curl >/dev/null 2>&1 || { printf 'unknown'; return 0; }

    # A bare DRAUGR_MODEL_URL port became the address of THIS machine, and no
    # route to your own machine goes through an HTTP proxy. The reason to care:
    # an intercepting proxy ANSWERS for a host that it refuses. A test inside a
    # mound showed the gateway of sbx returning
    #
    #   403  Blocked by network policy: domain 172.19.192.26:1
    #        no matching allow rule - blocked by default deny policy
    #
    # and 403 is not 000, so `dead` was reported as `alive`, the refusal in
    # dr_model_check never came, and the agent attached to nothing. Every mound
    # exports http_proxy, so this is the normal state there, not a corner case.
    #
    # NOT a blanket --noproxy. A full URL is the endpoint of somebody else, and
    # a company proxy is how such an endpoint is reached; to bypass it there
    # would report `dead` for an endpoint that works and refuse a session that
    # would have run. dr_model_is_port is the same test that dr_model_check uses
    # to tell the two apart.
    if dr_model_is_port "${DRAUGR_MODEL_URL:-}"; then
        np=(--noproxy '*')
    fi

    # ${np[@]+...} and not "${np[@]}": an empty array under `set -u` is an error
    # on the bash that this repo still supports. dr-status uses the same form.
    code=$(curl ${np[@]+"${np[@]}"} -s -o /dev/null -m 4 -w '%{http_code}' "$url/healthz" 2>/dev/null) || code=000

    # The proxy answered. Ask the second question, which the proxy cannot answer
    # for itself.
    if [ "$code" = 200 ]; then
        code=$(curl ${np[@]+"${np[@]}"} -s -o /dev/null -m 4 -w '%{http_code}' "$url/api/version" 2>/dev/null) || code=000
        [ "$code" = 200 ] && { printf 'proxy'; return 0; }
        printf 'stalled'
        return 0
    fi

    # For curl, 000 means "no HTTP response": refused, unreachable, or timed
    # out. Any other code means that something is there, but it has no /healthz.
    [ "$code" = 000 ] && { printf 'dead'; return 0; }

    code=$(curl ${np[@]+"${np[@]}"} -s -o /dev/null -m 4 -w '%{http_code}' "$url/api/version" 2>/dev/null) || code=000
    [ "$code" = 200 ] && { printf 'bare'; return 0; }
    printf 'alive'
}

# dr_model_check: refuse the two combinations that cannot work.
#
# Both are refusals and not warnings, because neither combination can work. If
# the module of an agent cannot send it to another endpoint, the agent ignores
# DRAUGR_MODEL and continues to use its cloud. That is the worst failure of
# this feature. You think that the work stays local, but it does not.
#
# The second combination is a missing host-port rule. Without the rule, the
# interception layer of the sandbox accepts the connection of the mound and
# drops it. The result is a timeout at the first prompt of the agent. The
# timeout names no cause.
dr_model_check() {
    local p
    [ -n "${DRAUGR_MODEL:-}" ] || return 0

    if ! dr_agent_model_supported; then
        dr_die "DRAUGR_MODEL is set, but Draugr cannot send $DRAUGR_AGENT to a different endpoint" \
            "Each agent reads different variables, and nobody tested this agent." \
            "Unset DRAUGR_MODEL, or run this project with DRAUGR_AGENT=claude."
    fi

    # A URL is the address of a different service. The usual network policy
    # controls it. DRAUGR_HOST_PORTS does not apply to it, but dr-policy does.
    dr_model_is_port "${DRAUGR_MODEL_URL:-}" || return 0

    for p in ${DRAUGR_HOST_PORTS:-}; do
        [ "$p" = "$DRAUGR_MODEL_URL" ] && return 0
    done

    # Name the one line that fixes it, not only the key. The two keys are not
    # duplicates. An address alone is not consent to open your machine, and
    # Draugr does not treat it as consent.
    dr_die "DRAUGR_MODEL_URL is port $DRAUGR_MODEL_URL, which is not in DRAUGR_HOST_PORTS" \
        "The mound cannot connect to it, and the agent will fail at its first prompt." \
        "Add it:  DRAUGR_HOST_PORTS=\"$DRAUGR_MODEL_URL\""
}

# dr_env_pairs: DRAUGR_ENV as one correct NAME=value on each line.
#
# Use DRAUGR_ENV for each value that has no Draugr key. It exists because the
# variable that limits the context of Claude Code has no documentation. It
# came in between two point releases. A DRAUGR_MODEL_CONTEXT key fixes a name
# that nobody published, and that name can change. A plain passthrough
# leaves that decision to the user.
#
# The code makes sure that each value is correct, because each failure here is
# otherwise silent. The agent IGNORES an unknown variable, and does not refuse
# it. A name with a typing error gives a session that looks correct, but acts
# as if the value did not exist. That is the failure that this key exists to
# prevent.
dr_env_pairs() {
    local entry name
    local -a entries=()
    [ -n "${DRAUGR_ENV:-}" ] || return 0

    # read -ra splits on white space WITHOUT globbing. dr_kit_refs documents the
    # same trap. An expansion with no quotes changes a value that contains *
    # into a list of the current directory.
    read -ra entries <<< "$DRAUGR_ENV"

    for entry in "${entries[@]}"; do
        # A value with no "=" is not a pair. The usual cause is that the user
        # forgot that a space separates the items.
        case "$entry" in
            *=*) ;;
            *) dr_die "DRAUGR_ENV: \"$entry\" is not NAME=value" \
                   "Spaces separate the items, so a value cannot contain a space." \
                   'Example:  DRAUGR_ENV="CLAUDE_CODE_DISABLE_1M_CONTEXT=1 FOO=bar"' ;;
        esac

        name=${entry%%=*}

        # The shell cannot export a name that is not a shell identifier. Then
        # the rcfile fails to source, and the full session fails, not only
        # this variable.
        case "$name" in
            ''|[0-9]*|*[!A-Za-z0-9_]*)
                dr_die "DRAUGR_ENV: \"$name\" is not a variable name" \
                    "Use letters, digits, and underscores. Do not start with a digit." \
                    "The item was:  $entry" ;;
        esac

        # PATH looks safe, but it is not. It REPLACES the value and does not add
        # to it. An absolute PATH removes the directory of the agent binary. The
        # next dr-go then ends with "command not found" before the agent starts.
        # The kit spec has the same warning about the same risk.
        case "$name" in
            PATH|HOME)
                dr_die "DRAUGR_ENV must not set $name" \
                    "Draugr and the agent both need it in the mound. If you replace" \
                    "it here, the session breaks before it starts." ;;
        esac

        printf '%s\n' "$entry"
    done
}

# dr_attach_rc <command...>: the bash rcfile that starts the agent.
#
# The simple method HANGS: the agent command directly in the rcfile. When bash
# runs its startup files, job control is not yet on. Thus the first Ctrl-Z
# suspends a process that nothing can then resume. PROMPT_COMMAND starts the
# agent at the first prompt. At that time, the shell owns the terminal, and the
# agent is a usual job.
#
# 148 is 128 + SIGTSTP. $? holds it after a foreground job STOPPED and did not
# finish. It keeps the two endings separate:
#
#   Ctrl-Z       -> 148 -> stay, and you have the shell of the mound
#   agent exits  -> its own status -> leave, the same as `sbx run`
#
# It is necessary. A suspended job does not skip the rest of its command list.
# Thus a plain `agent; exit` also ends the session on Ctrl-Z. A test showed
# this, after the code was first written that way.
dr_attach_rc() {
    local cmd url k v model_keys='' envpairs
    cmd=$(dr_shquote "$@")

    # Collect the pairs before the loop, and do not pipe them into it.
    # dr_env_pairs stops on a bad item. A process substitution loses that exit.
    # The result is an rcfile without the variables, and a session that looks
    # correct. When the function returns, the message is already on stderr.
    envpairs=$(dr_env_pairs) || return 1

    # Single quotes everywhere: this code must not expand these lines. They are
    # a file for a bash that has not started yet, on a different machine.
    # shellcheck disable=SC2016
    printf '%s\n' \
        '# Draugr wrote this file at attach time. The next dr-go overwrites it.' \
        '[ -f ~/.bashrc ] && . ~/.bashrc'

    # The own model of the agent, when DRAUGR_MODEL asks for one. This is the
    # only possible place. The ssh proxy of sbx accepts no AcceptEnv, so no
    # variable gets through it. A kit is committed, but the address is known
    # only now.
    if [ -n "${DRAUGR_MODEL:-}" ]; then
        # The code must stop here, and not continue. Without an address, the
        # variables stay unset, and the agent uses its cloud while you think
        # that it does not. This feature must not have that failure.
        url=$(dr_model_url) || dr_die \
            "DRAUGR_MODEL is set, but Draugr could not find the address of this machine" \
            "The mound needs the address to connect to port ${DRAUGR_MODEL_URL:-}." \
            "Examine the network with:  dr-doctor"

        # Bash quotes the values with %q here, and bash reads them on the other
        # side. The same pair agrees about the command line above. IFS splits
        # only on the first =, because v is the last field. It takes all the
        # text that is left, = too.
        while IFS='=' read -r k v; do
            [ -n "$k" ] || continue
            model_keys+=" $k"
            printf 'export %s=%s\n' "$k" "$(dr_shquote "$v")"
        done < <(dr_agent_model_env "$url" "$DRAUGR_MODEL" "${DRAUGR_MODEL_FAST:-$DRAUGR_MODEL}")
    fi

    # DRAUGR_ENV comes last. Thus a value that the user set wins over a value
    # that Draugr made. If the tool can replace a user value with no message,
    # the user value is useless. The code still reports the conflict. Two
    # values and a silent winner can cost an afternoon.
    while IFS='=' read -r k v; do
        [ -n "$k" ] || continue
        case " $model_keys " in
            *" $k "*) dr_warn "DRAUGR_ENV sets $k, and that replaces the value from DRAUGR_MODEL" ;;
        esac
        printf 'export %s=%s\n' "$k" "$(dr_shquote "$v")"
    done <<< "$envpairs"

    # shellcheck disable=SC2016
    printf '%s\n' \
        '_dr_pc=${PROMPT_COMMAND-}' \
        "PROMPT_COMMAND='PROMPT_COMMAND=\$_dr_pc; $cmd; _dr_s=\$?; [ \$_dr_s -eq 148 ] || exit \$_dr_s'"
}

# dr_attach_remote <dir> [command...]: the one string that ssh gets.
#
# With no command, it is a plain interactive shell, for dr-shell. With a
# command, it is the agent, which starts as described above.
#
# The rcfile goes in base64, not as a heredoc. It goes through ssh, which gives
# it to a remote shell. Each layer between them needs its own quotes. base64 has
# no special characters, so it needs no quotes.
dr_attach_remote() {
    local dir=$1; shift
    # $HOME is the home of the MOUND. The shell on the other side of ssh expands
    # it. Thus it stays in single quotes here.
    # shellcheck disable=SC2016
    local rc='$HOME/.cache/draugr/attach-rc' b64

    if [ $# -eq 0 ]; then
        printf 'cd %s && exec bash -i' "$(printf '%q' "$dir")"
        return 0
    fi

    b64=$(dr_attach_rc "$@" | base64 | tr -d '\n')
    # The same again: each $ in this format string is for the other side.
    # shellcheck disable=SC2016
    printf 'mkdir -p $HOME/.cache/draugr && printf %%s %s | base64 -d > %s && cd %s && exec bash --rcfile %s -i' \
        "$b64" "$rc" "$(printf '%q' "$dir")" "$rc"
}

# dr_ssh_attach <dir> [command...]: give the terminal to ssh, and wait.
#
# It returns the status of the other side. The rcfile makes that the status of
# the agent.
dr_ssh_attach() {
    local dir=$1 remote; shift
    remote=$(dr_attach_remote "$dir" "$@")
    dr_debug "ssh -t $(dr_ssh_host) $remote"
    # Use -t, because there is a remote command. Without -t, ssh gives no pty,
    # and the agent has no terminal to draw on. The callers already went
    # through dr_require_tty, so there is a terminal to give.
    ssh -t "$(dr_ssh_host)" "$remote"
}

# ---------------------------------------------------------------------------
# Sandbox identity and state
# ---------------------------------------------------------------------------

# dr_sandbox_name [repo-root]: draugr-<leaf>, with only the characters of sbx.
#
# In a name, sbx accepts only letters, numbers, hyphens, periods, and plus
# signs. Thus "my project (old)" must become "my-project-old".
dr_sandbox_name() {
    local repo=${1:-$PWD} leaf

    # ${repo##*/} removes the longest prefix that ends in "/". That is basename.
    leaf=${repo##*/}

    # tr -c means "complement". It replaces each character that is NOT in the
    # set with a hyphen. Then sed changes each run of hyphens into one hyphen,
    # and removes a hyphen at the start or the end. (\{2,\} is BRE for "two or
    # more". It is the portable form of {2,}.)
    leaf=$(printf '%s' "$leaf" | tr -c 'A-Za-z0-9.+-' '-' | sed 's/-\{2,\}/-/g; s/^-//; s/-$//')

    printf 'draugr-%s' "$leaf"
}

# dr_sbx_json <text>: the JSON from the stdout of sbx, without the other text.
#
# The output of `sbx ls --json` is not only JSON. When a newer sbx exists, sbx
# writes an upgrade banner on stdout, around the document. All text before the
# first "{" is that banner. jq fails on text after the document. Thus the
# callers use the output that they got, and never the exit status of jq.
dr_sbx_json() {
    local text=$1
    case $text in
        *'{'*) printf '%s' "${text#"${text%%\{*}"}" ;;
        *)     printf '%s' "$text" ;;
    esac
}

# dr_sandbox_state <name> -> absent|stopped|running (whatever sbx reports)
dr_sandbox_state() {
    local name=$1 json status _err _errf
    # IF sandboxd CANNOT BE REACHED, THE CODE MUST SAY SO. Before, it said nothing:
    #
    #   json=$(dr_sbx ls --json 2>/dev/null) || { printf 'unknown'; return 1; }
    #
    # Each caller writes `state=$(dr_sandbox_state ...)`. With `set -euo pipefail`, a
    # command substitution that exits non-zero STOPS THE FULL SCRIPT, AND PRINTS NOTHING.
    # A real failure showed this. `dr-up --recreate` returned at once, printed no
    # character, and changed nothing. Its user then looked for an error in a correct
    # configuration. The `2>/dev/null` discarded the one message that explained it, from
    # sbx itself: "previous sandboxd (PID 3700) did not exit within 10s".
    #
    # No caller needed the `return 1`. All four callers (dr-up, dr-status, dr-stop,
    # dr-dep) assign the result with no test. Thus each of them stopped in the same
    # silent way. A stop here, with a message, is what they all need. "absent" still
    # returns normally. It is an answer, not a failure.
    #
    # stderr goes to a file. It does not go into stdout with 2>&1. The comment below
    # tells that sbx already writes a banner into stdout. If its error text goes into the
    # same stream, a parser that almost works starts to fail at the worst times.
    #
    # The real failure that caused this code: sandboxd ran ELEVATED and had no fault. Its
    # log answered /daemon/health with 200 all the time. But a client that was not
    # elevated was not able to open its pipe. It reported "Status: stopped". Then it said
    # "previous sandboxd (PID 3700) did not exit within 10s" about a process that it was
    # not able to see. Suspect elevation first, not a daemon that hangs. If you act as if the
    # daemon hangs, you stop a daemon that works.
    #
    # The daemon was elevated for this reason. forge-provision.ps1 runs elevated for
    # AppSandbox, and it ran dr-up through wsl.exe, which passes that token on. The keeper
    # session of post-up then kept the daemon open for nine hours. Thus the elevation of
    # the daemon lasted longer than each shell. The advice below says MATCH the level, and
    # do not escalate. If all users run all commands elevated, the problem becomes permanent.
    _errf=$(mktemp)
    json=$(dr_sbx ls --json 2>"$_errf") || {
        _err=$(cat "$_errf" 2>/dev/null); rm -f "$_errf"
        dr_die "cannot ask sandboxd for the state of '$name'" \
               "${_err:-sbx ls failed and gave no reason}" \
               "The usual cause is ELEVATION, not a broken daemon. sandboxd belongs to the" \
               "shell that started it. A client at a lower level cannot open its pipe." \
               "sbx then reads 'no daemon', starts its own daemon, finds the lock held, and" \
               "reports that the process that it cannot see \"did not exit\"." \
               "To make sure, run 'sbx daemon status' in an elevated shell and in a usual" \
               "shell. If the first says running+connected and the second says stopped, this" \
               "is the cause, and the daemon has no fault. If BOTH say stopped, it is down." \
               "The fix is to MATCH the level, not to escalate. Integrity goes one way: an" \
               "elevated shell can use a usual daemon, but a usual shell cannot use an" \
               "elevated daemon." \
               "  to continue now ....  run dr-* from WSL started in an ELEVATED PowerShell" \
               "  to go back to normal  dr-stop, wait about 30s until sandboxd stops after" \
               "                        its last session, then dr-up from a USUAL WSL" \
               "An elevated daemon here usually came from forge-provision.ps1. It runs" \
               "elevated for AppSandbox, and before, it started a daemon. Now it refuses to."
    }
    rm -f "$_errf"
    json=$(dr_sbx_json "$json")

    # The jq program, from left to right:
    #   (.sandboxes // [])   the sandboxes array, or an empty array if it is missing
    #   []                   go through its elements
    #   select(.name == $n)  keep only the sandbox with this name
    #   .status              print that field
    # --arg n "$name" gives the name to jq as a variable. The name does not go into
    # the program text, so a name with quotes cannot break jq.
    #
    # The code uses the output, not the exit status of the pipeline. sbx prints an
    # upgrade banner on stdout next to the JSON. jq then prints the status and
    # *then* fails on the text after it. With `set -o pipefail`, that added
    # "absent" to a correct answer, and dr-up then refused a stopped mound. A
    # test showed this. If no sandbox matches, the result is empty, which means
    # absent.
    status=$(printf '%s' "$json" | jq -r --arg n "$name" \
        '(.sandboxes // [])[] | select(.name == $n) | .status' 2>/dev/null | head -1)
    [ -n "$status" ] || status=absent
    printf '%s' "$status"
}

# dr_forge_available: load lib/forge when it is necessary, or tell why it is missing.
#
# This is an OPTIONAL DEPENDENCY, on purpose. A user must be able to delete lib/forge/.
# The forge is a feature for one person. docs/FORGE.md says that without those files,
# the rest of Draugr stays exactly the same. Thus the core never sources it at start.
# It loads it only after DRAUGR_FORGE names a VM. On a machine without the forge, that
# never occurs.
dr_forge_available() {
    if declare -f dr_forge_far_end_running >/dev/null 2>&1; then return 0; fi
    local lib="$DRAUGR_ROOT/lib/forge/common.sh"
    if [ ! -r "$lib" ]; then
        dr_warn "DRAUGR_FORGE names '$DRAUGR_FORGE', but $lib is missing. Draugr treats the forge as absent."
        return 1
    fi
    # Use source-path. With only `source=`, the linter starts from the CWD. It then reports
    # a file that exists as missing. bin/dr-forge documents the same trap.
    # shellcheck source-path=SCRIPTDIR
    # shellcheck source=forge/common.sh
    . "$lib"
}

# dr_sandbox_exists <name>: does the far end with this name exist?
#
# THE FORGE IS ALSO A FAR END. A far end is the other side of the git and file loops. This
# function makes that true for the twelve commands that use it as a gate. The code and the
# data of the forge are in the VM, not in a mound. The gateway mound controls what the VM can
# connect to, and it holds no clone. Thus the git loop and the file loop must be able to use
# the VM. Before, each of them refused here.
#
# NOTHING CHANGES FOR A MACHINE WITHOUT A FORGE. That was the condition for this code. The
# forge branch needs BOTH a configured forge AND a name that matches it. If DRAUGR_FORGE is
# empty (the default, for each user who did not turn it on), this is the same single
# dr_sandbox_state call as before. There is no AppSandbox, no powershell.exe, no extra
# process, and no sourced lib/forge. tests/forge.bats makes sure of that. It fails if that
# path runs powershell.exe.
#
# dr_sandbox_state does NOT get the same change, on purpose. dr-up, dr-stop, and dr-dep read
# it to decide if they create or start a MOUND. If it gives the state of a VM, they act on
# the wrong item. That failure is much worse than the refusal that this code removes.
dr_sandbox_exists() {
    local name=$1
    if [ -n "${DRAUGR_FORGE:-}" ] && [ "$name" = "$DRAUGR_FORGE" ]; then
        dr_forge_available || return 1
        dr_forge_far_end_running "$name"
        return
    fi
    [ "$(dr_sandbox_state "$name")" != "absent" ]
}

# dr_sandboxes_running: the name of each running sandbox, one on each line.
#
# This includes all sandboxes, not only the ones that Draugr named. Each mound
# keeps a Hyper-V microVM open, whoever created it. The reasons for this list
# are to get memory back, or to clean up before you shut down the machine. For
# those reasons, the tool that made the sandbox does not matter. dr-stop --all
# lists what it found and asks before it acts. It does not touch other
# sandboxes with no message.
dr_sandboxes_running() {
    local json
    json=$(dr_sbx ls --json 2>/dev/null) || return 1
    json=$(dr_sbx_json "$json")
    printf '%s' "$json" | jq -r \
        '(.sandboxes // [])[] | select(.status == "running") | .name' 2>/dev/null
}

# ---------------------------------------------------------------------------
# DRAUGR_DATA: files that go next to git, not through it
#
# One list has two consumers with different syntaxes. They are rsync filter
# rules (dr-data) and shell glob matches (the clean-tree exception in dr-go).
# They must agree. If not, a file is copied but still blocks dr-go. Thus this
# one place defines both meanings of an item.
#
#   ends in "/"       a directory: that prefix and all files under it
#   contains "/"      a path pattern, anchored at the root of the repo
#   neither           a name or an extension, matched ANYWHERE in the tree
# ---------------------------------------------------------------------------

# _dr_data_entries: split DRAUGR_DATA into an array WITHOUT globbing.
#
# `for entry in $DRAUGR_DATA` looks correct, but it is wrong. An expansion
# with no quotes does word splitting *and pathname expansion*. Thus the shell
# replaces "tmp/**" with the files in tmp/ of the current directory, with no
# message. The pattern becomes a list of the file names of today. It depends
# on the working directory, and it misses files that are created later.
#
# `read -ra` splits on IFS and does no globbing. That is the correct result.
_dr_data_entries() {
    read -ra _DR_DATA_ENTRIES <<< "${DRAUGR_DATA:-}"
}

# dr_data_matches <repo-relative-path>: does DRAUGR_DATA include this path?
#
# All the code below depends on one rule. A `case` pattern is a GLOB, and the
# QUOTES decide which parts of it are wildcards. Text in quotes is literal.
# Text without quotes is a pattern. One pattern can contain both. Thus these
# are two very different tests:
#
#     case "$path" in "$entry")  …   # matches a file with the name *.parquet
#     case "$path" in  $entry )  …   # matches each .parquet file
#
# The code below uses both forms on purpose.
dr_data_matches() {
    local path=$1 entry
    [ -n "${DRAUGR_DATA:-}" ] || return 1

    # Exclude the same internal paths that dr_data_filters excludes. The two
    # functions must give the same answer. If a path matches here but is not
    # copied, the clean-tree test skips it, and nobody sends it. The
    # two functions are a pair to prevent that bug, where one says yes and the
    # other says no.
    case "$path" in
        .git|.git/*|.draugr|.draugr/*) return 1 ;;
    esac

    local _DR_DATA_ENTRIES=()
    _dr_data_entries
    for entry in "${_DR_DATA_ENTRIES[@]}"; do
        case "$entry" in
            */)
                # A directory, for example "scratch/raw/". The pattern has
                # three parts:
                #
                #   "${entry%/}"   IN QUOTES, so literal. "%" removes from the
                #                  end. It removes the last slash: -> scratch/raw
                #   /              a literal slash
                #   *              WITHOUT QUOTES, so a wildcard: any text
                #
                # The slash makes the match exact. scratch/raw/r1 matches, but
                # scratch/rawdata/r1 does not. The quotes also keep a [ or a *
                # in a directory name as the characters that the user typed.
                case "$path" in
                    "${entry%/}"/*) return 0 ;;
                esac
                ;;
            */*)
                # A path pattern, for example "tmp/**". It has no quotes, so
                # it globs.
                #
                # Note: in `case`, "*" also matches slashes, because no file
                # system is used. Filename globbing is different. Thus tmp/*
                # already matches tmp/deep/y.bin, and here "**" is the same as
                # "*". The "**" form stays for rsync (dr_data_filters). In
                # rsync, the two are different.
                # shellcheck disable=SC2254  # no quotes on purpose: it IS a pattern
                case "$path" in
                    $entry) return 0 ;;
                esac
                ;;
            *)
                # A name or an extension, for example "*.parquet".
                #
                # ${path##*/} is basename. "##" removes the LONGEST prefix
                # that matches */. Thus src/lib/b.parquet -> b.parquet. The
                # match on the basename lets one extension rule apply at each
                # depth.
                # shellcheck disable=SC2254  # no quotes on purpose: it IS a pattern
                case "${path##*/}" in
                    $entry) return 0 ;;
                esac
                ;;
        esac
    done
    return 1
}

# dr_data_filters: the same list as rsync filter rules, one on each line.
#
# The order is the usual method, and it is important, because rsync uses the
# FIRST rule that matches. First go into each directory, then include the
# wanted files, then exclude all other files. dr-data adds -m
# (--prune-empty-dirs), so that the "*/" include leaves no empty directories.
dr_data_filters() {
    local entry

    # The internal paths come first. rsync uses the FIRST rule that matches,
    # and these rules must win over each DRAUGR_DATA item.
    #
    # .git causes the problem. An item with no slash is not anchored, and it
    # matches at each depth. Thus DRAUGR_DATA="*.sample" also takes
    # .git/hooks/*.sample, with no message. DRAUGR_DATA="*" copies the full
    # .git of the host over the .git of the mound clone. That replaces the git
    # metadata of the agent, with its remote. Nobody expects such a pattern to
    # go into the internal files of a repository.
    #
    # .draugr belongs to Draugr. The kit belongs to git, and .draugr/tmp holds
    # the staging copies of dr-mem. Without this rule, those copies go into the
    # tree of the agent. The rule has no slash at the end. Thus it also
    # excludes a `.git` *file*, which a submodule or a worktree leaves, not
    # only a directory.
    printf '%s\n' '--exclude=.git' '--exclude=.draugr'
    printf '%s\n' '--include=*/'

    # Split without globbing (see _dr_data_entries). If globbing occurs here,
    # rsync gets a list of file names, not the patterns.
    local _DR_DATA_ENTRIES=()
    _dr_data_entries
    for entry in "${_DR_DATA_ENTRIES[@]}"; do
        case "$entry" in
            # A directory needs both rules: the directory itself, and its contents.
            */)  printf -- '--include=/%s\n--include=/%s**\n' "$entry" "$entry" ;;
            # A leading "/" anchors the pattern at the transfer root, that is, the repo.
            */*) printf -- '--include=/%s\n' "$entry" ;;
            # No slash: not anchored, so it matches at each depth.
            *)   printf -- '--include=%s\n' "$entry" ;;
        esac
    done
    printf '%s\n' '--exclude=*'
}

# dr_data_path_safe <path>: can Draugr write this name under the repo?
#
# rsync cleans paths itself. New versions remove a leading "/" and refuse a
# "..". But that is a dependency on the copy tool, not a guarantee. Here, the
# side that sends is always the agent. The test of a name costs little, and
# Draugr writes the files. Thus Draugr tests the names.
#
# The function refuses absolute paths, each ".." part, and control
# characters. A newline in a file name also breaks the parsing of one file on
# each line. Each caller needs that parsing. Without the test, a review can
# be incomplete with no message.
dr_data_path_safe() {
    local path=$1
    case "$path" in
        ''|/*)             return 1 ;;
        ..|../*|*/../*|*/..) return 1 ;;
        *[[:cntrl:]]*)     return 1 ;;
    esac
    return 0
}

# dr_data_exec_shaped <path>: is this a file that a person can RUN?
#
# The test uses only the name, on purpose. The first idea is to ask "did it
# come with the execute bit". Here, that question has no useful answer. A
# Draugr repo must be on a Windows drive. DrvFs reports each file as 0777, and
# ignores --chmod with no message. A test showed this. A file that rsync copied
# onto /mnt/c with --chmod=D755,F644 is -rwxrwxrwx and runs. Thus the mode
# tells you nothing, and only the name is left.
#
# The list is short on purpose. People learn to ignore a warning about usual
# data. Thus the list does not include extensions that are often data and
# often code: .bin, .ts, .run, .dat. Each of them can run, but the list skips
# them.
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

# dr_data_is_text <path>: no NUL byte in the first 8 KB.
#
# git uses the same rule. More important, `diff` uses the same rule. Thus this
# never promises a diff that diff then refuses to print. It also needs no
# `file` binary, which can be missing in a minimal mound. An empty file is
# text. It contains nothing binary. If it is binary, the code hides the one
# important diff: "this file is now empty".
dr_data_is_text() {
    local total stripped
    [ -s "$1" ] || return 0
    total=$(head -c 8192 "$1" | wc -c)
    stripped=$(head -c 8192 "$1" | LC_ALL=C tr -d '\000' | wc -c)
    [ "$total" = "$stripped" ]
}

# dr_mode_note <repo> <path>: "mode X => Y, no content change", or nothing.
#
# It is true only when the STAGED entry and HEAD hold the same blob with
# different modes. Other changes (an edit, an addition, a deletion) are not
# changes of mode only, and they get no note.
dr_mode_note() {
    local repo=$1 path=$2 idx head imode hmode iblob hblob

    # If git quoted a path (spaces, non-ASCII), the typed path does not match.
    # A guess at the unquoted form is worse than no note. The note only helps,
    # and without it, the user loses only that help.
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

# dr_dirty_list <repo>: `git status --short`, and it names a change of mode only.
#
# git prints "M  run.sh" if the file was rewritten, and also if it only became
# executable. On a /mnt/c checkout, the second case is more usual than it
# looks. With core.fileMode=false, a mode can get into the index only through
# `git update-index --chmod`, a checkout, or a merge. It never gets there
# through `git add`. If you read that "M" as "I edited it", you look for an
# edit that does not exist.
#
# A real failure caused this function. A staged `100644 => 100755` on run.sh
# blocked a dr-merge. The incoming commit had THE SAME change of mode. The
# refusal was correct, but nobody was able to understand the message.
dr_dirty_list() {
    local repo=${1:-$PWD} line path note
    while IFS= read -r line; do
        # "XY path". A rename is "XY old -> new". Neither part is the path to
        # ask git about, so the code does not change the line.
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

# dr_data_dirty_only <repo>: true when each uncommitted change is a data file.
#
# This is the exception to DRAUGR_REQUIRE_CLEAN. A changed parquet file must
# not stop you from starting a session, because that file does not go through
# git. One changed *source* file still blocks the session, as intended.
dr_data_dirty_only() {
    local repo=${1:-$PWD} line path
    [ -n "${DRAUGR_DATA:-}" ] || return 1

    # --porcelain gives "XY path". The status letters are always the first two
    # columns. Thus the text from the fourth character is the path.
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        path=${line:3}

        # A rename is "old -> new". Use the new path.
        case "$path" in
            *" -> "*) path=${path##* -> } ;;
        esac

        dr_data_matches "$path" || return 1
    done < <(git -C "$repo" status --porcelain 2>/dev/null)
    return 0
}

# dr_data_dirty_blockers <repo>: the uncommitted changes that are NOT exceptions.
#
# This is the pair of dr_data_dirty_only, which answers yes or no. This function
# answers "which ones". The caller of the yes-or-no function printed the full
# `git status`. A repo with fifteen changed data files and one stray script
# then reported sixteen problems. The one real problem was hidden, and
# DRAUGR_DATA looked as if Draugr ignored it.
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

# DRAUGR_KIT is a LIST, because sbx kits combine.
#
# A test on sbx 0.37.1 showed this. `--kit` accepts the flag more than one time.
# Two mixins on one sandbox gave BOTH their install commands and BOTH their
# network allow rules, merged into one policy. That is why a shared kit is
# useful. "The Lua toolchain" is a fact about you, not about one repo. A library
# kit ADDS to the kit of the project. It does not replace it.

# dr_kit_reserved_names: the names that a kit must not use, one on each line.
#
# The combination always contains the own kit of the agent. Thus the name of
# the agent is taken. There are two sources, and neither is a list by hand:
#
#   $DRAUGR_AGENT        today, the only name that can break a create
#   lib/agents/*.sh      so that a change to a known agent does not break a
#                        kit that works
#
# sbx has ten agents, and this function names three of them at most, on
# purpose. A fixed list of the other seven becomes wrong over time. When sbx
# adds an agent, the list is wrong, with no message. The names here come from
# data: one from a directory list, one from your configuration. dr-up catches
# an agent that is in neither source, and `dr-kit validate` then names it. The
# reason is that DRAUGR_AGENT is always the agent that you just changed to.
dr_kit_reserved_names() {
    { printf '%s\n' "${DRAUGR_AGENT:-claude}"; dr_agent_known | tr ' ' '\n'; } | sort -u
}

# dr_kit_slug <text>: a string that sbx accepts as the `name:` field of a kit.
#
# The rule of sbx, from its own error: "must be lowercase alphanumeric with
# hyphens, 1-64 chars". Before, dr-init used the directory name of the
# repository with no change. Thus each project with a capital letter (TabuLua,
# MyApp) wrote a kit that was INVALID. It failed at `dr-up` with an sbx error
# that was two steps away from the cause.
#
# Only `name:` has this limit. `displayName:` is free text and keeps the
# capitals. Thus dr-init sets the two fields from different values.
dr_kit_slug() {
    local s a
    # Change to lowercase. Then each character outside the set becomes a
    # hyphen. -c is the complement of tr: "each character NOT in this set".
    s=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-' '-')

    # Change each run of hyphens into one hyphen, then remove the hyphens at the
    # ends. If not, "My App" gives "my--app". A hyphen at the start or the end
    # is not alphanumeric.
    while [ "$s" != "${s//--/-}" ]; do s=${s//--/-}; done
    s=${s#-}; s=${s%-}

    # Cut to 64 characters, then remove an end hyphen again. The cut at 64 can
    # put a hyphen from the middle at the end.
    s=${s:0:64}
    s=${s%-}

    # A kit with the name of an agent is legal, but it cannot combine. sbx puts
    # the own kit of the agent in the same combination, and it refuses two
    # kits with the same name. Thus a repository in a directory "claude" or
    # "codex" gives a kit that passes validation. It then fails at dr-up with
    # an sbx message, two steps away from the cause. That is the same problem
    # as the capitals above.
    #
    # The code compares the name with EACH known agent, not only the
    # configured one. The kit does not depend on the agent, on purpose. A name
    # that fails when you change DRAUGR_AGENT is a trap, not a kit.
    while IFS= read -r a; do
        [ "$s" = "$a" ] || continue
        s="$s-project"
        break
    done < <(dr_kit_reserved_names)

    # A name of only punctuation becomes empty. A plain placeholder is better
    # than an empty field, which fails validation for a second reason.
    [ -n "$s" ] || s=project
    printf '%s' "$s"
}

# dr_kit_store: the library of named kits, which all repositories share.
dr_kit_store() {
    printf '%s' "${DRAUGR_KIT_STORE%/}"
}

# dr_kit_resolve <entry>: change one DRAUGR_KIT item into a value that sbx accepts.
#
# Four forms. The most specific form comes first:
#
#   /abs/path            an absolute path, used as it is
#   sub/dir              a directory in the repo (the documented default)
#   name                 a directory in the kit store: a named library kit
#   ghcr.io/org/kit:tag  any value with ":" or "@", that is, an OCI or git ref
#
# The code searches the repo before the store, on purpose. If a project
# contains a directory `lua`, it means its own directory. The more specific
# answer wins. All configuration layers follow the same rule.
#
# The code tries each form two times: first with ".<agent>" added, then plain.
# Thus with DRAUGR_AGENT=codex, ".draugr/kit.codex" wins over ".draugr/kit",
# and a library kit "lua.codex" wins over "lua". Most kits do not need this.
# Network rules and install commands do not depend on the agent. But a kit
# that really differs can use it, and it costs only one loop.
#
# It is a suffix and not a subdirectory, on purpose. ".draugr/kit/codex/" looks
# the same as a kit that contains a directory with that name, and sbx reads
# full directories.
#
# It prints the directory that it found (or the reference, unchanged), and
# returns 0. When the item names nothing that exists, it prints nothing and
# returns 1. The callers treat that as normal, because a kit is optional.
dr_kit_resolve() {
    local entry=$1 cand name
    [ -n "$entry" ] || return 1

    for name in "$entry.${DRAUGR_AGENT:-claude}" "$entry"; do
        case "$name" in
        # An absolute path means exactly itself. There is no search, only the
        # suffix.
        /*)
            if [ -d "$name" ]; then printf '%s' "$name"; return 0; fi
            ;;
        # If not, first the repo, then the library. A local directory with the
        # same name always wins over a shared one.
        *)
            cand="$DR_REPO/$name"
            if [ -d "$cand" ]; then printf '%s' "$cand"; return 0; fi
            cand="$(dr_kit_store)/$name"
            if [ -d "$cand" ]; then printf '%s' "$cand"; return 0; fi
            ;;
        esac
    done

    # Nothing on this disk. A ":" or "@" means a reference format that Draugr
    # does not own. Thus it goes through unchanged, and sbx can reject it with
    # its own words. There is no agent suffix here. Draugr must not add it to
    # the registry tag of a different owner.
    case "$entry" in
        *[:@]*) printf '%s' "$entry"; return 0 ;;
    esac
    return 1
}

# dr_kit_agent_conflicts: the found kits that need a different agent, one on
# each line as "<kit> <agent it wants>".
#
# A kit CAN fix its agent with `requires: agent: claude`. sbx then refuses to
# combine it with a different agent:
#
#   ERROR: request failed: 400 Bad Request: kit_artifacts: compose:
#   kit "x" requires base agent "claude" but was composed with "codex"
#
# The user sees this at `dr-up`, in the words of sbx, two steps away from the
# cause. The kit slug had the same problem. Also, `sbx kit validate` accepts
# such a kit. The conflict exists only when sbx combines the kits. Thus nothing
# else can find it before the create. That is why Draugr reads the field itself.
#
# Only directories. Draugr cannot read a ZIP or an OCI reference here. A guess
# is worse than the answer of sbx.
dr_kit_agent_conflicts() {
    local ref want
    while IFS= read -r ref; do
        [ -d "$ref" ] || continue
        # The field is two levels deep in the YAML. But in this schema, "agent:"
        # occurs only under requires:. Thus one sed is enough. A wrong read here
        # gives a false warning, not a wrong mound.
        want=$(sed -n 's/^[[:space:]]*agent:[[:space:]]*//p' "$ref/spec.yaml" 2>/dev/null | head -1)
        [ -n "$want" ] || continue
        [ "$want" = "${DRAUGR_AGENT:-claude}" ] && continue
        printf '%s %s\n' "$ref" "$want"
    done < <(dr_kit_refs)
    return 0
}

# dr_kit_name_conflicts: the found kits whose `name:` is the name of an agent,
# one on each line as "<kit> <name>".
#
# sbx combines the own kit of the agent with the kit of the project. It refuses
# two kits with the same name:
#
#   ERROR: request failed: 400 Bad Request: kit_artifacts: compose:
#   duplicate kit name "claude" - each kit in a composition must have a unique name
#
# The user sees this at dr-up, in the words of sbx. Nothing in it points to the
# file that caused it. `sbx kit validate` accepts such a kit. The name is legal,
# and the conflict exists only when sbx combines the kits. Thus this is the
# second test that dr-kit must do and sbx does not. The reason is the same as
# for dr_kit_agent_conflicts above.
#
# The names come from dr_kit_reserved_names. They are the agent that you
# configured, and the agents that have a Draugr module. They are not all ten
# agents of sbx. dr_kit_reserved_names tells why.
#
# Only directories, as above. Draugr cannot read a ZIP or an OCI reference here.
dr_kit_name_conflicts() {
    local ref name a
    while IFS= read -r ref; do
        [ -d "$ref" ] || continue
        # Anchored at column 0. `name:` also occurs with an indent under
        # publishedPorts. Only the top-level `name:` is the name of the kit.
        name=$(sed -n 's/^name:[[:space:]]*//p' "$ref/spec.yaml" 2>/dev/null | head -1)
        [ -n "$name" ] || continue
        while IFS= read -r a; do
            [ "$name" = "$a" ] && printf '%s %s\n' "$ref" "$name"
        done < <(dr_kit_reserved_names)
    done < <(dr_kit_refs)
    return 0
}

# dr_kit_refs: each DRAUGR_KIT item that the code found, one on each line, in order.
#
# The order stays the same, because sbx applies the kits in the order that it
# gets them. A later item goes on top of an earlier one. If the code found no
# item, it returns 1. Thus "this project has no kit" stays one fast test.
dr_kit_refs() {
    local entry resolved rc=1
    local -a entries=()
    [ -n "${DRAUGR_KIT:-}" ] || return 1

    # read -ra splits on white space WITHOUT globbing. _dr_data_entries
    # documents the same trap. There, an expansion with no quotes changes a
    # pattern into a list of the files in the current directory.
    read -ra entries <<< "$DRAUGR_KIT"
    for entry in "${entries[@]}"; do
        if resolved=$(dr_kit_resolve "$entry"); then
            printf '%s\n' "$resolved"
            rc=0
        fi
    done
    return "$rc"
}

# dr_kit_missing: the items that the code did not find, one on each line.
#
# The report uses the name, not a path. An item with a typing error HAS no
# path, and that is the problem. "no kit at /repo/lua" hides that the
# code also searched the kit store.
dr_kit_missing() {
    local entry
    local -a entries=()
    [ -n "${DRAUGR_KIT:-}" ] || return 0
    read -ra entries <<< "$DRAUGR_KIT"
    for entry in "${entries[@]}"; do
        dr_kit_resolve "$entry" >/dev/null || printf '%s\n' "$entry"
    done
}

# dr_kit_repo_dir: the first found kit that is in this repo.
#
# `dr-kit save` copies this kit. dr-policy names it when it suggests to move a
# rule into the kit. The list can contain project kits and library kits. An
# instruction for the repo means the kit of the project.
dr_kit_repo_dir() {
    local ref
    while IFS= read -r ref; do
        case "$ref" in
            "$DR_REPO"/*) printf '%s' "$ref"; return 0 ;;
        esac
    done < <(dr_kit_refs)
    return 1
}

# dr_dir_hash <dir>: one digest for a full directory tree.
#
# The code sorts with -z and hashes the names and contents together. Thus the
# result depends on the contents and the names. It does not depend on the
# order in which find found the files.
dr_dir_hash() {
    find "$1" -type f -print0 2>/dev/null \
        | sort -z \
        | xargs -0 sha256sum 2>/dev/null \
        | sha256sum \
        | cut -d' ' -f1
}

# dr_kit_hash <dir>: a digest of the full kit, not only of spec.yaml. initFiles
# and the other files in the directory change what the sandbox gets.
dr_kit_hash() { dr_dir_hash "$1"; }

# dr_kit_hash_all: one digest for all kits in DRAUGR_KIT, in order.
#
# The order is part of the digest, because it is part of the meaning. The same
# two kits in the opposite order can build a different sandbox.
#
# For a remote reference, the digest uses the reference STRING, not the
# contents. No other choice is correct. A hash of the contents needs a
# download of an OCI image at each dr-up, and a tag that can change makes it
# useless. Thus Draugr cannot see a drift when a tag moves. It can see a
# drift when a local directory changes. dr-kit drift says so. It does not
# suggest that it examined all kits.
dr_kit_hash_all() {
    local ref
    {
        while IFS= read -r ref; do
            if [ -d "$ref" ]; then dr_dir_hash "$ref"; else printf '%s\n' "$ref"; fi
        done < <(dr_kit_refs)
    } | sha256sum | cut -d' ' -f1
}

# Where dr-up records the hash of its build. Thus dr-kit drift is a comparison,
# not a guess. The file is in .draugr/, because it describes this checkout,
# not the project. dr-init adds it to .gitignore, with .draugr/tmp/.
dr_kit_stamp() {
    printf '%s/.draugr/kit.applied' "$DR_REPO"
}

# dr_kit_spec_name <dir>: the name of the kit, from its spec.yaml.
#
# sbx combines kits by this name, and refuses the same name two times. A test
# on 0.37.1 showed this. If you add a kit again, and the sandbox already has
# its name, sbx fails with
# 'duplicate kit name "x" - each kit in a composition must have a unique name'.
dr_kit_spec_name() {
    sed -n 's/^name:[[:space:]]*"\{0,1\}\([^"#[:space:]]*\).*/\1/p' "$1/spec.yaml" 2>/dev/null | head -1
}

# The stamp, line by line:
#
#   <combined hash>                     line 1, the same as in all versions
#   kit<TAB><ref><TAB><name><TAB><hash>  one for each kit, in DRAUGR_KIT order
#
# Line 1 stays alone and first. Thus a stamp from an older Draugr (one line,
# nothing else) still gives a correct drift. With the lines for each kit,
# dr-kit apply can tell "a kit was added at the end" from "a kit changed".
# sbx can do the first in place, but not the second.
dr_kit_stamp_write() {
    local ref
    {
        dr_kit_hash_all
        while IFS= read -r ref; do
            if [ -d "$ref" ]; then
                printf 'kit\t%s\t%s\t%s\n' "$ref" "$(dr_kit_spec_name "$ref")" "$(dr_dir_hash "$ref")"
            else
                # A remote reference. Its string is the only correct value to
                # record, for the reason that dr_kit_hash_all gives.
                printf 'kit\t%s\t\t%s\n' "$ref" "$ref"
            fi
        done < <(dr_kit_refs)
    } > "$(dr_kit_stamp)"
}

# The combined hash of the build of the mound. If there is no stamp, nothing.
dr_kit_stamp_hash() {
    head -1 "$(dr_kit_stamp)" 2>/dev/null
}

# The per-kit lines, as "<ref>\t<name>\t<hash>". For an old stamp, empty. An old
# stamp recorded only the combined hash. "Draugr does not know which kits" is
# an answer that the callers must handle, and must not hide.
dr_kit_stamp_kits() {
    sed -n 's/^kit\t//p' "$(dr_kit_stamp)" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Network policy, and the loop that it makes possible
#
# The allow list of a kit is frozen into the sandbox when sbx creates it. To
# change it, you must recreate the sandbox. But `sbx policy allow --sandbox`
# adds a rule to a RUNNING mound, and the rule works at once. A test showed
# this. A host that answered "Blocked by network policy" then answered with
# its own 404, in the same mound, with no restart. Thus you can fix a build in
# small steps, not one recreate at a time. At the end, you write the kit once.
#
# For that loop, Draugr must answer two questions. sbx can answer both, and no
# build tool can:
#
#   what was refused?   `sbx policy log` is the record of the PROXY, so it is
#                       the same for each client. A test with one blocked host
#                       showed this: curl printed nothing, git named the host,
#                       and pip reported "Could not find a version that
#                       satisfies the requirement". Those are three different
#                       messages. One says nothing, and one is wrong. The proxy
#                       logged all of them.
#   what did I open?    so that you do not have to remember it during the loop.
# ---------------------------------------------------------------------------

# dr_policy_denied: the hosts that this mound was refused, one host name on
# each line.
#
# The log records "host:port". The code removes the port, because
# `sbx policy allow network` and the allow list of a kit do not take it. The
# code removes duplicates. A build that retries connects to the same host many
# times, and the count is not useful.
dr_policy_denied() {
    dr_sbx policy log "$DRAUGR_SANDBOX" --json 2>/dev/null         | jq -r --arg n "$DRAUGR_SANDBOX" '
              (.blocked_hosts // [])[]
              | select(.vm_name == $n)
              | .host | sub(":[0-9]+$"; "")' 2>/dev/null         | sort -u
}

# dr_policy_adhoc: the hosts that a person opened for this mound, one on each line.
#
# All rules for this sandbox are in one table, also the rules of the kit. Thus
# the code must separate the two. `editable` is the field with that meaning. A
# rule from the kit artifact is not editable. A rule from `dr-policy --allow`
# is editable. A test showed this. The rule of the kit also has the name
# "kit:<sandbox>", and an ad-hoc rule has only a UUID. Both fields agree.
dr_policy_adhoc() {
    dr_sbx policy ls "$DRAUGR_SANDBOX" --wide --json 2>/dev/null         | jq -r --arg s "sandbox:$DRAUGR_SANDBOX" '
              .. | objects
              | select(.applies_to? == $s and .decision? == "allow")
              | select(.resource_type? == "network" and .editable? == true)
              | .resources[]?' 2>/dev/null         | sort -u
}

# ---------------------------------------------------------------------------
# Host ports: from a mound, connect to a service that runs on THIS machine
# ---------------------------------------------------------------------------
#
# This is the opposite of DRAUGR_PORTS. DRAUGR_PORTS publishes a port where the
# mound listens, so that the host can connect in. This opens a port where the
# HOST listens, so that the mound can connect out. Both are holes, and this
# direction is the more dangerous one. On the other side is a process on your
# machine, outside the sandbox, and the agent can talk to it.

# dr_host_ip: the address that a mound must use for a service on this host.
#
# The address is not a constant. That is the reason for this function. WSL is
# on a Hyper-V network with NAT. Windows selects the subnet when it creates the
# network, at each boot. The address in the subnet comes from DHCP. You cannot
# fix either. WSL 2.6.1 reads networkingMode, dhcpTimeout, and vmIdleTimeout
# from .wslconfig, and it has no natNetwork or natGateway. Thus an address that
# you write down today is wrong after the next reboot. The sandbox policy
# denies by default, so the connection then fails CLOSED and SILENTLY. The
# sandbox accepts the connection and drops it, with no error. That is very
# difficult to debug. Thus the code finds the address when it opens the hole,
# and never stores it.
#
# Use `route get`, not a named interface. The question is "which source
# address does this machine use for outgoing traffic". A mound can send back
# to that address. The answer does not need the interface to be eth0. No packet
# is sent. It is a query of the routing table.
dr_host_ip() {
    local ip
    ip=$(ip -4 route get 1.1.1.1 2>/dev/null |
             awk '{ for (i = 1; i < NF; i++) if ($i == "src") { print $(i + 1); exit } }')
    [ -n "$ip" ] || return 1
    printf '%s\n' "$ip"
}

# dr_hostport_rules <port>: the ids of the rules that dr-hostport wrote for <port>.
#
# The selection is narrow on purpose, because the code gives these ids to
# `policy rm`. A rule came from here only if all of these are true. It is
# editable (thus not from the kit). It is for this mound. It holds EXACTLY ONE
# resource, and that resource is an IPv4 address on <port>. The code does not
# touch a rule that a person wrote for several hosts, or a rule that names a
# domain, even if <port> is in it.
#
# Without this cleanup, each reboot adds one dead rule. Each dead rule names
# an address that does not exist now.
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

# dr_hostport_open <port>: the addresses that are now allowed on <port>, one on
# each line.
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

# dr_kit_allow_list <kit-dir>: the hosts that a kit already declares.
#
# This is a small reader written by hand, not a YAML parser. Thus it is narrow
# on purpose. It finds `allow:` under `network:`. Then it takes the `- item`
# lines directly below it, and stops at the first line that is not an item.
# That is enough for the format that dr-init writes, and for the files that a
# person writes by hand. It CANNOT go into `deny:` or `publishedPorts:` lower
# in the file. A plain grep for each "-" line does that.
dr_kit_allow_list() {
    [ -f "$1/spec.yaml" ] || return 0
    awk '
        # Record the indent of the allow: key, to find where its block ends.
        /^[[:space:]]*allow:[[:space:]]*(\[\])?[[:space:]]*$/ && innet {
            match($0, /^[[:space:]]*/); allow_indent = RLENGTH; inallow = 1; next
        }
        /^[[:space:]]*network:[[:space:]]*$/ { innet = 1 }
        inallow {
            # A list item deeper than the key belongs to it. All else ends it.
            if (match($0, /^[[:space:]]*-[[:space:]]+/)) {
                item = $0
                sub(/^[[:space:]]*-[[:space:]]+/, "", item)
                sub(/[[:space:]]*(#.*)?$/, "", item)
                gsub(/^["'"'"']|["'"'"']$/, "", item)
                if (item != "") print item
                next
            }
            if ($0 ~ /^[[:space:]]*(#.*)?$/) next     # comment or blank: still in the block
            match($0, /^[[:space:]]*/)
            if (RLENGTH <= allow_indent) { inallow = 0 }
        }
    ' "$1/spec.yaml" 2>/dev/null | sort -u
}

# dr_hostport_managed <resource>: true when DRAUGR_HOST_PORTS owns this rule.
#
# Nobody must keep such a rule, and that changes the answer to two questions.
# A recreate removes it, but dr-up writes it again some seconds later, with the
# address of the day. A warning about the loss makes you look for a way to keep
# a rule that comes back. Also, `dr-kit adopt` must never take it. The kit is
# COMMITTED, and the address is correct only until the next reboot. This
# feature exists so that nobody writes that address down.
#
# The test is narrow on purpose. Only an IPv4 address on a port that this
# project declared can come from dr-hostport. A host name on the same port
# belongs to a different owner, and the code still reports it.
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

# dr_policy_unadopted: the ad-hoc hosts that the kits of this repo do not declare.
#
# A recreate LOSES these hosts. dr-rm and dr-up protect them. A test showed
# this. A rule for a sandbox does not last longer than the sandbox. After
# `sbx rm`, a lookup of the rule by id gives "policy or rule not found". Thus
# a recreate discards, with no message, the list that you wanted to write down.
#
# If the repo has no kit, each ad-hoc host is unadopted. There is no file
# where it can be written.
dr_policy_unadopted() {
    local kit have host
    # Use EACH kit, not only the kit of the repo. dr-kit adopt writes into one
    # kit, but a host is adopted in any kit that holds it. If not, a project
    # with several kits gets a warning that it will lose hosts that are already
    # written down. The warning offers --force. With --force, you lose the hosts
    # that really were unadopted.
    #
    # The code is written out, not as have=$(...). With set -e, have=$(...)
    # stops the full function when there is no kit. Then "each host is
    # unadopted" becomes "there is nothing to report", with no message. That is
    # the wrong answer in the one direction that loses data.
    have=
    while IFS= read -r kit; do
        [ -d "$kit" ] || continue
        have="$have
$(dr_kit_allow_list "$kit")"
    done < <(dr_kit_refs)
    while IFS= read -r host; do
        [ -n "$host" ] || continue
        # Draugr restores a rule from dr-hostport by itself. Thus a recreate does
        # not lose it, and it must not go into the kit.
        if dr_hostport_managed "$host"; then continue; fi
        printf '%s
' "$have" | grep -qxF "$host" || printf '%s
' "$host"
    done < <(dr_policy_adhoc)
    return 0
}

# ---------------------------------------------------------------------------
# Values that are fixed at creation
#
# Most values that sbx needs are frozen into the sandbox when sbx builds it:
# the image, the agent, the memory limit, the published ports, and each extra
# mount. If you change one of them and run dr-up again, nothing occurs. For a
# mound that exists, dr-up STARTS it. It does not build it again.
#
# Nothing occurs, and there is no message. That is the worst case. You add a
# mount and run dr-go, and the directory is not there. Nothing on the screen
# tells why. Thus dr-up records the values of the build and compares them, as
# it already does for kits.
# ---------------------------------------------------------------------------

# dr_create_facts: the values that are fixed at creation, one KEY=value on each
# line.
#
# DRAUGR_SANDBOX is not in the list. A change to it does not change a mound. It
# names a different mound. DRAUGR_KIT is also not in the list. It has its own
# stamp and its own fix.
dr_create_facts() {
    local k
    for k in DRAUGR_AGENT DRAUGR_CLONE DRAUGR_TEMPLATE DRAUGR_MEMORY DRAUGR_CPUS \
             DRAUGR_PORTS DRAUGR_MOUNTS
    do
        printf '%s=%s\n' "$k" "${!k}"
    done
}

# The file is next to the kit stamp. dr-init adds it to .gitignore for the
# same reason: it describes the mound of this checkout, not the project.
dr_create_stamp() {
    printf '%s/.draugr/create.applied' "$DR_REPO"
}

# dr_create_drift: names the keys that differ from the values of the build.
#
# If there is no stamp, it says nothing. A mound that is older than this code
# has no drift. Its state is unknown. A guess gives a false warning at
# each dr-up. For the same reason, the code skips a key that is not in the
# stamp. An older Draugr wrote that file and did not record the key.
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
# Tests in Phase 2 showed this, and Phase 6 tested it again. sbx mounts this one
# directory READ-WRITE into each mound, at /home/agent/.claude/skills. It stays
# after sbx rm. It is the only path through which a sandbox can leave files for
# a later sandbox. Thus it is the exception to "the sandbox cannot write to the
# host", and it holds instructions for agents.
# ---------------------------------------------------------------------------

# dr_skills_dir: the location of that store. It comes from the location of sbx,
# and is not fixed in the code. sbx.exe is at <root>/bin/sbx.exe, and the store
# is under <root>/sandboxes/state/. The function prints the path, also if it
# does not exist yet. It returns 1 only when it cannot find sbx.
dr_skills_dir() {
    local sbx_exe
    sbx_exe=$(dr_find_sbx) || return 1
    printf '%s/sandboxes/state/agent-skills' "$(dirname "$(dirname "$sbx_exe")")"
}

# dr_plugin_skills <plugin store>: one line "<skill> <plugin>@<marketplace>
# <version>" for each skill of an INSTALLED plugin in that library.
#
# It is here and not in dr-plugin, because dr-skills reports it too. One shared
# function is a better link than a call from one command to the other.
#
# A plugin DECLARES nothing about its skills. plugin.json holds hooks, MCP
# servers, and more, but skills follow the convention skills/<name>/SKILL.md.
# Thus this code walks the directories. It skips a directory without SKILL.md,
# because that is not a skill. The agent skips it too.
#
# The `name:` of the front matter wins over the directory name, because the
# agent matches on it, and the two can differ. sed reads one scalar, with no
# YAML parser. One plugin already has a block scalar for `description:`, so a
# simple read of THAT is wrong. The dependencies of Draugr are git, jq, and
# rsync. dr-kit reads displayName in the same simple way.
#
# The output is sorted, so the order does not depend on the key order in the JSON.
dr_plugin_skills() {
    local seed=$1/seed
    [ -f "$seed/installed_plugins.json" ] || return 0
    {
        local id ver plug mkt dir name
        while read -r id ver; do
            # Test both, as two tests. A && B || C is not if-then-else. The
            # version is half of the cache path, so Draugr cannot find an entry
            # without one.
            [ -n "$id" ] || continue
            [ -n "$ver" ] || continue
            plug=${id%@*}; mkt=${id#*@}
            for dir in "$seed/cache/$mkt/$plug/$ver"/skills/*/; do
                [ -f "${dir}SKILL.md" ] || continue
                name=$(sed -n 's/^name:[[:space:]]*//p' "${dir}SKILL.md" | head -1)
                # A skill without a name still loads. Use the directory name.
                [ -n "$name" ] || { name=${dir%/}; name=${name##*/}; }
                printf '%s %s %s\n' "$name" "$id" "$ver"
            done
        done < <(jq -r '.plugins // {} | to_entries[] | "\(.key) \(.value[0].version // "")"' \
                     "$seed/installed_plugins.json" 2>/dev/null)
    } | sort
}

# ---------------------------------------------------------------------------
# Path keys, and the memory store
#
# An agent that keeps a state for each project names the directory after the
# ABSOLUTE PATH of the project. Thus one repository has a different key on
# each side of the boundary:
#
#   Windows   C:\Code\Draugr       c--Code-Draugr
#   WSL       /mnt/c/Code/Draugr   -mnt-c-Code-Draugr
#   Mound     /c/Code/Draugr       -c-Code-Draugr
#
# The encoding is the one of Claude Code. lib/agents/claude.sh tells what
# occurs to the memory of an agent when a copy crosses the boundary with no
# rename. The encoder is HERE, not there. The store of Draugr uses the Windows
# form to name the part of each repo, for each agent.
# ---------------------------------------------------------------------------

# dr_mem_key <absolute-path>: encode a path as Claude Code names its directory.
#
# Change a Windows drive letter to lowercase. Then change each "/", "\", and ":"
# into "-". Thus a leading separator gives a leading "-". That is why the WSL
# and mound forms start with "-", and why the Windows form has "--" in place
# of "C:\".
#
# Only those three characters are known to change. The rest of the path keeps
# its case, as "c--Code-Draugr" shows. Nobody knows what occurs to a space or
# other punctuation in a repo name. Thus dr-mem compares the answer with the
# mound, and does not trust it.
dr_mem_key() {
    local p=$1
    # Change only the drive letter to lowercase. "Code" and "Draugr" keep their
    # capitals.
    case "$p" in
        [A-Za-z]:*) p="$(printf '%s' "${p:0:1}" | tr '[:upper:]' '[:lower:]')${p:1}" ;;
    esac
    # In single quotes, '\\' is two characters. tr reads them as one escaped
    # backslash. Thus SET1 is the three characters / \ : and SET2 is three
    # hyphens. This is not an escape for bash. Thus the linter needs the
    # directive below.
    # shellcheck disable=SC1003
    printf '%s' "$p" | tr '/\\:' '---'
}

# The same repo, with the key for each side. Each function takes the WSL path,
# because each dr-* command already has that path in DR_REPO.
dr_mem_key_wsl()   { dr_mem_key "$1"; }
dr_mem_key_win()   { dr_mem_key "$(dr_path_win "$1")"; }
dr_mem_key_mound() { dr_mem_key "$(dr_path_mound "$1")"; }

# In the mound, the agent is uid 1000 with the home /home/agent. A test showed
# this: `sbx exec … id` reports uid=1000(agent) and $HOME=/home/agent.
# shellcheck disable=SC2034  # the agent modules read it, and the linter does
# not follow them from here. Each dr_agent_mem_dir uses it.
DR_MOUND_HOME=/home/agent

# Where dr-mem collects a transfer in the mound. The transfer can be several
# files in several places. Thus the code packs them into this one directory
# and moves it with one `sbx cp`. That is simpler. After the copy, the code can
# make sure that the directory exists, and does not have to trust it.
#
# It is under .cache/, next to the attach rcfile. The agent owns this temporary
# path. Nothing else reads it, and a mound that was wiped creates it again.
# shellcheck disable=SC2034  # dr-mem and the agent modules read it
DR_MOUND_STAGE="$DR_MOUND_HOME/.cache/draugr/mem"

# dr_mem_store_dir <repo>: the part of $DRAUGR_MEM_STORE for this repo.
#
# Its name uses the WINDOWS key, for two reasons. It has no leading "-", so a
# command cannot read it as an option. Also, a Claude install on the host uses
# the same name for the same repo. Thus you can find your way in the store by
# hand.
#
# Then a directory for each agent. The memories of two agents about the same
# project are two different things. They must not overwrite each other. They
# also do not have the same FORMAT. The memory of Claude Code is a directory
# of markdown. The memory of Codex is markdown and SQLite. The repo comes
# first, not the agent. Thus all data about one project stays in one place.
dr_mem_store_dir() {
    printf '%s/%s/%s' "${DRAUGR_MEM_STORE%/}" "$(dr_mem_key_win "$1")" \
        "${DRAUGR_AGENT:-claude}"
}

# dr_mem_store_migrate <repo>: move a store from before 0.2.0 under its agent.
#
# Before the store had a directory for each agent, the memory of this repo was
# directly in its part. Only Claude Code was able to write it. Thus it goes under
# claude/. It does NOT go under the agent of the current configuration. If it
# does, the first test of Codex puts the memories of Claude under Codex.
#
# The code tells the user, and does not move the data silently. The data of the
# user moves on the disk. One line of text costs less than the confusion when
# the user finds the data in a different place.
dr_mem_store_migrate() {
    local old new entry
    old="${DRAUGR_MEM_STORE%/}/$(dr_mem_key_win "$1")"
    new="$old/claude"

    # The old format is memory/ directly in the part of the repo. If claude/
    # already exists, there is nothing to do. A part that holds neither is a
    # store that this version wrote.
    [ -d "$old/memory" ] || return 0
    [ -d "$new" ] && return 0

    # The export marker and the backup copy (one mv to restore) move with it.
    # If not, the store in its new place forgets that it was exported. The
    # marker is what makes `dr-mem import` trust it with no question.
    mkdir -p "$new"
    for entry in memory memory.previous .draugr-export; do
        if [ -e "$old/$entry" ]; then mv "$old/$entry" "$new/$entry"; fi
    done
    dr_info "moved $old into claude/; the memory store now has one directory for each agent"
    return 0
}

# ---------------------------------------------------------------------------
# Commands in the mound
#
# `sh -c 'script' sh ARG` makes ARG the $1 of the script. The paths go in as
# arguments, not into the script text. Thus no part of a path can become shell
# syntax, and the scripts stay in single quotes and easy to read.
#
# The agent modules use these functions. Thus they are here, and not in dr-mem,
# where they were first. A module must be able to look into the mound, to
# answer questions about what the agent wrote.
# ---------------------------------------------------------------------------

# Quiet: for probes and lists. There, a failure is an answer and not a fault,
# and the message of sbx is only noise.
dr_mound_sh() {
    local script=$1; shift
    dr_sbx exec "$DRAUGR_SANDBOX" -- sh -c "$script" sh "$@" 2>/dev/null
}

# With messages: for the calls that change something. There, the reason of a
# failure is important.
dr_mound_run() {
    local script=$1; shift
    dr_sbx exec "$DRAUGR_SANDBOX" -- sh -c "$script" sh "$@"
}

# dr_stage: a temporary directory that sbx.exe can see.
#
# `sbx cp` is a Windows binary, and its HOST argument must be a WINDOWS path.
# A test on sbx 0.37.1 showed that both of these fail:
#
#   sbx cp <name>:/tmp/x /home/you/dest      ERROR: … GetFileAttributesEx \home\you
#   sbx cp <name>:/tmp/x /mnt/c/Code/dest    ERROR: … GetFileAttributesEx \mnt\c\Code
#
# The reason is that sbx changes the leading "/" into "\", and looks for it on
# the current drive. Only C:\… works. $DRAUGR_MEM_STORE can be anywhere, also on
# the ext4 of WSL, where sbx cannot go. Thus each transfer goes through here:
# .draugr/tmp/ in the repo. dr_require_win_path already made sure that the repo
# is on a Windows drive.
#
# It sets DR_STAGE (the WSL path) and DR_STAGE_WIN (the same directory, in the
# format for sbx). The caller must remove DR_STAGE with a trap. It holds memory
# files, and those must not stay on the disk after a crash.
dr_stage() {
    DR_STAGE="$DR_REPO/.draugr/tmp/$$"
    rm -rf "$DR_STAGE"
    mkdir -p "$DR_STAGE"
    # shellcheck disable=SC2034  # the dr-* command that called this reads it
    DR_STAGE_WIN=$(dr_path_win "$DR_STAGE")
}

# ---------------------------------------------------------------------------
# git to and from the mound
# ---------------------------------------------------------------------------

# dr_sandbox_url -> ssh://<sandbox>.sbx/<mound path>
#
# Always ssh, never the git:// daemon that sbx publishes. That daemon listens
# on the *Windows* loopback. WSL2 cannot connect to it across its NAT, and its
# port changes at each start. ssh needs no port and no NAT crossing. It
# matches the *.sbx block that dr-setup writes. A test showed that it also
# starts a stopped sandbox when you connect.
#
# It reads DR_REPO and DRAUGR_SANDBOX, and does not take them as arguments.
# Each caller already ran dr_context. Parameters are a second way to give the
# same values, and the two can disagree.
dr_sandbox_url() {
    local mound
    mound=$(dr_path_mound "$DR_REPO") || dr_die \
        "$DR_REPO is not on a Windows drive, so it has no path in the mound"

    # THE SAME PATH WORKS IN THE VM. By good luck, this is one line and not a
    # translation layer. The mound path is the WSL path without /mnt. Thus
    # /mnt/c/Code/MyGame becomes /c/Code/MyGame. A test in the guest showed that
    # git 2.56.0 from MSYS2 changes /c/Users into C:\Users. `git -C /c/Users
    # rev-parse` answered "not a git repository", not "cannot change to". Thus
    # only the ssh HOST is different.
    printf 'ssh://%s%s' "$(dr_sandbox_ssh_host)" "$mound"
}

# dr_sandbox_ssh_host: the ssh host for the far end of this project.
#
# ONE PLACE, because three commands build it, and they must agree. They are dr-sync through
# dr_sandbox_url, the rsync target of dr-data, and the vscode-remote URI of dr-code. Before,
# each wrote "$DRAUGR_SANDBOX.sbx" itself. That was correct while a mound was the only
# possible far end. When that changed, they became different with no message. If dr-sync
# connects to the VM and dr-data connects to the mound, it takes a day to see it.
#
# A mound is <name>.sbx. The ProxyCommand that sbx installs in ~/.ssh/config finds it. A forge
# VM is <name>.forge. The one `Host *.forge` block that `dr-setup --forge` writes finds it.
# There is one block for all VMs, because the host port is fixed. A block for each VM is
# the same text with a different Host line (docs/FORGE.md, "The pinned port has a price").
# Neither is a configuration key. One name for one machine is easier to keep correct than
# two. `dr-forge doctor` makes sure that the alias resolves. Without it, git fails with
# "could not resolve hostname".
#
# The suffix is written here AND in lib/forge/common.sh. Do not remove that duplicate. No
# core script can source the forge library (docs/FORGE.md, "Optional by construction"),
# so the two cannot share a definition. tests/forge.bats makes sure that they agree.
dr_sandbox_ssh_host() {
    if [ -n "${DRAUGR_FORGE:-}" ] && [ "${DRAUGR_SANDBOX:-}" = "$DRAUGR_FORGE" ]; then
        printf '%s.forge' "$DRAUGR_FORGE"
        return 0
    fi
    printf '%s.sbx' "${DRAUGR_SANDBOX:-}"
}

# dr_remote_ensure: set $DRAUGR_REMOTE to the mound. If the remote does not
# exist, create it. It prints the URL. The code always sets the URL. A rename
# of the sandbox or a move of the repo changes it, and an old remote fails in
# a confusing way.
dr_remote_ensure() {
    local url
    url=$(dr_sandbox_url)

    # `git remote` lists one name on each line. -x anchors the match, so that
    # "draugr" does not match a remote with the name "draugr-old".
    if git -C "$DR_REPO" remote | grep -qx "$DRAUGR_REMOTE"; then
        git -C "$DR_REPO" remote set-url "$DRAUGR_REMOTE" "$url"
    else
        git -C "$DR_REPO" remote add "$DRAUGR_REMOTE" "$url"
        dr_debug "added remote $DRAUGR_REMOTE -> $url"
    fi

    # A second refspec, next to the default +refs/heads/* of git. dr-send puts
    # your commits at refs/remotes/host/<branch> IN the mound. refs/heads/* never
    # shows that ref. Only with a copy of it back can the host tell "the mound
    # never got this" from "the mound has it, and the agent did not merge it".
    # See dr_send_state.
    #
    # Use --add with a guard. git remote add already wrote one refspec, and a
    # second call must not add duplicates.
    if ! git -C "$DR_REPO" config --get-all "remote.$DRAUGR_REMOTE.fetch" \
         | grep -qxF "$DR_SENT_REFSPEC"; then
        git -C "$DR_REPO" config --add "remote.$DRAUGR_REMOTE.fetch" "$DR_SENT_REFSPEC"
    fi
    printf '%s' "$url"
}

# Not in refs/remotes/, on purpose. All refs there are "branches in the mound",
# and this is the copy of OUR branch in the mound. Under refs/remotes, it shows
# in git branch -r and in dr_other_branches, as work to review.
DR_SENT_REFSPEC='+refs/remotes/host/*:refs/draugr/sent/*'

dr_sent_ref() { printf 'refs/draugr/sent/%s' "$DRAUGR_BRANCH"; }

# dr_send_state: why the branch of the mound is behind your branch. With only
# draugr/<branch>, you cannot tell these two cases apart:
#
#   not-sent   the mound never got these commits          -> dr-send
#   unmerged   dr-send gave them, but the branch of the    -> dr-send --merge
#              agent did not merge host/<branch> yet
#
# Without this difference, dr-sync always said "send them with dr-send". You
# sent, it still said send, and a second send did nothing, because the commits
# were already there. A user went around that loop two times and reported it.
dr_send_state() {
    local sent
    sent=$(dr_sent_ref)
    if ! git -C "$DR_REPO" rev-parse --verify --quiet "$sent" >/dev/null; then
        printf 'not-sent\n'
        return 0
    fi
    # Test for an ancestor, not for equality. If you send, then commit one more
    # time locally, you really have something new to send.
    if git -C "$DR_REPO" merge-base --is-ancestor HEAD "$sent" 2>/dev/null; then
        printf 'unmerged\n'
    else
        printf 'not-sent\n'
    fi
}

# dr_tracking_ref: <remote>/<branch>. dr-log, dr-diff, dr-merge, and dr-status
# all compare with it. It is named one time here, so that they cannot disagree.
dr_tracking_ref() {
    printf '%s/%s' "$DRAUGR_REMOTE" "$DRAUGR_BRANCH"
}

# dr_other_branches: fetched branches of the mound with commits that your HEAD
# does not have.
#
# The refspec of the remote is +refs/heads/*:refs/remotes/<remote>/*. Thus
# dr-sync always fetched EACH branch. Only the report was narrow. It looked at
# draugr/$DRAUGR_BRANCH and nothing else. Agents often work on their own
# branch, and such work was not visible. The commits were already on this disk,
# but dr-sync, dr-log, and dr-diff all said that there was nothing. That is how
# the work of a session was lost for a day.
#
# It prints "<ref> <count>" on each line. It excludes the tracked branch,
# because its caller reports it separately. It also excludes <remote>/HEAD,
# because that is a symref to one of these branches, not a branch itself.
#
# Use the FULL refname, on purpose. %(refname:short) is not safe for that
# second exclusion. refs/remotes/<name>/HEAD is one of the rev-parse rules of
# git. Thus it becomes "draugr", NOT "draugr/HEAD", and a */HEAD guard on the
# short form never matches. Nothing created that ref until git 2.49. Then
# `git fetch` started to create it by default
# (remote.<name>.followRemoteHEAD=create). After that, each sync reported
# "1 branch(es) you are NOT tracking: draugr". It named your current branch,
# and the hint to review was wrong. CI found it, because its git was newer than
# the git on the machine where this code was written.
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

# dr_require_tracking_ref: give a useful failure when nothing is fetched yet.
# That is the normal state before the first dr-sync. Without this function, it
# looks like a git error.
dr_require_tracking_ref() {
    local ref
    ref=$(dr_tracking_ref)
    git -C "$DR_REPO" rev-parse --verify --quiet "$ref" >/dev/null && return 0
    dr_die \
        "nothing is fetched from the mound yet ($ref does not exist)" \
        "First, fetch the commits of the agent:  dr-sync"
}

# ---------------------------------------------------------------------------
# Run-state dependencies: claims, and what makes a claim valid
#
# A repository that names a different repository in DRAUGR_REQUIRES needs the
# mound of that repository to be RUNNING. It says so with a claim. The design is
# in docs/DEPENDENCIES.md. Here, one rule keeps the design correct:
#
#   A claim is never trusted only because it exists. It counts only while its
#   claimant is real: the mound of that repository runs, or the claim is
#   younger than the grace time below. The grace time covers the minute
#   between the claim and the build.
#
# Thus the mechanism repairs itself, and nobody must clean it up. After a
# reboot of the host, each claim is stale, because nothing runs. A dr-up that
# crashed leaves a claim that becomes too old. A mound that you stop by hand
# releases its claim when it stops, with or without a message.
# ---------------------------------------------------------------------------

# Run state, not configuration. Draugr can delete it at any time, it is never
# backed up, and it has no meaning on a different machine. In ~/.config/draugr,
# it makes that directory unsafe to copy. House rule 7 names this
# directory for that reason. The tests redirect $HOME, so they get their own
# tree with no special case here.
DR_RUN_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/draugr/run"

# How long a claim counts before the mound of the claimant exists. The time is
# necessary. The dependency must run BEFORE Draugr creates the mound of the
# consumer. Thus a consumer claims first and builds second, and a cold create
# takes about a minute. Tests can change the value, so that they do not sleep.
DR_DEP_GRACE=${DR_DEP_GRACE:-300}

# The SHA-256 of a string, not of a file. It changes a repository path into a
# file name. It uses the same two tools as _dr_hash, for the same reason.
_dr_hash_text() {
    if command -v sha256sum >/dev/null 2>&1; then
        printf '%s' "$1" | sha256sum | cut -d' ' -f1
    elif command -v shasum >/dev/null 2>&1; then
        printf '%s' "$1" | shasum -a 256 | cut -d' ' -f1
    else
        dr_die "no sha256sum or shasum available" "Install coreutils."
    fi
}

# dr_dep_dir <key>: the directory of the claims on one resource.
#
# A key is a sandbox name, or a value such as "vm:UE5-Test" for a resource
# that is not a mound. dr-forge claims the VM through this code too. Thus
# "exclusive" has one meaning on the machine, not two. Each character outside
# the safe set becomes "_", because the key becomes a directory name.
dr_dep_dir() {
    printf '%s/%s' "$DR_RUN_DIR" "$(printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_')"
}

# dr_dep_claim_file <key> <repo>: the claim of one claimant on one resource.
#
# Its name is a hash of the path of the claimant. A path contains "/" and can
# contain any other character. The path itself is in the file, so nothing is
# lost. The hash also makes the claim one for each REPOSITORY. A second
# terminal in the same project writes the same file, not a second claim. That
# is what "re-entrant" means here.
dr_dep_claim_file() {
    printf '%s/%s.claim' "$(dr_dep_dir "$1")" "$(_dr_hash_text "$2")"
}

# _dr_dep_field <file> <name>: one field from a claim file.
#
# Claim files are "name=value" lines. The code reads them and does not source
# them. Any process on the machine can write such a file. If this process
# sources it, the file becomes shell code that this process runs. No
# claim is worth that risk.
_dr_dep_field() {
    sed -n "s/^$2=//p" "$1" 2>/dev/null | head -1
}

# dr_dep_claim_valid <file> [<running-list>]: is this claim still real?
#
# A caller that tests several claims gives the running list. Then one
# `sbx ls` answers for all claims, not one for each claim.
dr_dep_claim_valid() {
    local file=$1 running=${2-} sandbox age now since

    # Younger than the grace time: valid, whatever sbx says. The claimant is
    # very probably still in the dr-up that wrote it.
    since=$(_dr_dep_field "$file" since_epoch)
    now=$(date +%s)
    age=$(( now - ${since:-0} ))
    [ "$age" -lt "$DR_DEP_GRACE" ] && return 0

    # If not, the mound of the claimant decides. If no sandbox is recorded,
    # the claim came from something that is not a mound. There is nothing to
    # test, so the claim gets only the grace time above.
    sandbox=$(_dr_dep_field "$file" sandbox)
    [ -n "$sandbox" ] || return 1
    [ -n "$running" ] || running=$(dr_sandboxes_running || true)
    printf '%s\n' "$running" | grep -qxF "$sandbox"
}

# dr_dep_claims <key>: each VALID claim, as "<repo>\t<sandbox>\t<since>".
#
# It only reads, on purpose. A status command must not delete anything. Thus
# this function ignores stale files, and dr_dep_prune removes them. The
# functions that write claims call dr_dep_prune.
dr_dep_claims() {
    local dir file running
    dir=$(dr_dep_dir "$1")
    [ -d "$dir" ] || return 0
    running=$(dr_sandboxes_running || true)
    for file in "$dir"/*.claim; do
        [ -f "$file" ] || continue
        dr_dep_claim_valid "$file" "$running" || continue
        printf '%s\t%s\t%s\n' \
            "$(_dr_dep_field "$file" repo)" \
            "$(_dr_dep_field "$file" sandbox)" \
            "$(_dr_dep_field "$file" since)"
    done
}

# dr_dep_prune <key>: remove the claim files that do not count now.
dr_dep_prune() {
    local dir file running
    dir=$(dr_dep_dir "$1")
    [ -d "$dir" ] || return 0
    running=$(dr_sandboxes_running || true)
    for file in "$dir"/*.claim; do
        [ -f "$file" ] || continue
        dr_dep_claim_valid "$file" "$running" || rm -f "$file"
    done
}

# dr_dep_claim <key> <repo> <sandbox> [exclusive]: claim a resource.
#
# For the same repository, it is idempotent (safe to run two times). A second
# claim updates the time. Thus a second terminal, and a dr-up each morning,
# cost nothing.
#
# The code compares an exclusive claim with the other VALID claims, after the
# cleanup. Thus if the holder of a lock is gone, the new claim takes the lock.
# It does not wait for somebody to delete a file. When two dr-ups run at the
# same time, mkdir decides, because it is atomic. The loser sees the claim of
# the winner, and gets a refusal that names the winner.
dr_dep_claim() {
    local key=$1 repo=$2 sandbox=$3 exclusive=${4:-false} file dir other

    dir=$(dr_dep_dir "$key")
    mkdir -p "$dir"
    dr_dep_prune "$key"
    file=$(dr_dep_claim_file "$key" "$repo")

    # Refuse before the code writes anything, and name the holder. A lock that
    # says only "in use" does not tell the user what to do next.
    if dr_is_true "$exclusive" && [ ! -f "$file" ]; then
        other=$(dr_dep_claims "$key" | head -1)
        if [ -n "$other" ]; then
            dr_die "$key is exclusive, and $(printf '%s' "$other" | cut -f1) uses it since $(printf '%s' "$other" | cut -f3)" \
                   "Its own configuration says DRAUGR_EXCLUSIVE=true, so only one project at a time can use it." \
                   "Stop the mound of that project, or release it there:  dr-dep release"
        fi
    fi

    # The code writes the full file, then moves it into place. Thus a reader
    # never sees half a claim. One process writes all fields, and they appear
    # at the same time. The key is recorded as it was given. The directory name
    # went through tr, and "vm_UE5-Test" cannot give back "vm:UE5-Test".
    printf 'key=%s\nrepo=%s\nsandbox=%s\nsince=%s\nsince_epoch=%s\n' \
        "$key" "$repo" "$sandbox" "$(date '+%Y-%m-%d %H:%M')" "$(date +%s)" > "$file.tmp"
    mv "$file.tmp" "$file"
}

# dr_dep_unclaim <key> <repo>: give one resource back.
dr_dep_unclaim() {
    rm -f "$(dr_dep_claim_file "$1" "$2")"
}

# dr_dep_requires [<repo>]: the repositories that this one needs, as absolute paths.
#
# The rules are the same as for DRAUGR_KIT. A path in a configuration file
# must have the same meaning everywhere. "~" is the home of the user. A
# relative path starts from the repository that asked. An absolute path is
# itself.
dr_dep_requires() {
    local repo=${1:-$DR_REPO} entry path
    local -a list
    read -ra list <<< "${DRAUGR_REQUIRES:-}"
    for entry in "${list[@]+"${list[@]}"}"; do
        # The shell that sourced the configuration does not expand a tilde in
        # quotes. A list of two paths must have quotes. Thus the first branch
        # expands the literal prefix. If not, the path is wrong, and nobody can
        # see it. The linter reads that pattern as a failed expansion. It is a
        # match of two characters.
        # shellcheck disable=SC2088
        case "$entry" in
            '~/'*) path="$HOME/${entry#'~/'}" ;;
            /*)    path=$entry ;;
            *)     path="$repo/$entry" ;;
        esac
        # Canonical, so that two spellings of one repository are one claimant.
        # The name of the claim file comes from this string.
        printf '%s\n' "$(cd "$path" 2>/dev/null && pwd || printf '%s' "$path")"
    done
}

# dr_dep_trusted <repo>: refuse a dependency on a repository that nobody read.
#
# To require a repository is to run its dr-up. dr-up sources its .draugr.conf
# and runs its hooks, on this machine, as you. dr-trust exists for that risk.
# But dr_trust_check only WARNS and continues. If the configuration is never
# sourced, DRAUGR_SANDBOX keeps its default "draugr-<leaf>". The result is a
# claim on the wrong mound, and a start of it. Thus this function refuses. It
# is the same test that dr-trust records, as a fatal error one step earlier.
dr_dep_trusted() {
    local repo=$1 file
    for file in "$repo/.draugr.conf" "$repo/.draugr.local.conf"; do
        [ -f "$file" ] || continue
        dr_trust_is_trusted "$file" && continue
        dr_die "this repo requires $repo, and the configuration of $repo is not trusted" \
               "It is shell code. To require it is to run it." \
               "Read it, then run:  dr-trust $file"
    done
}

# dr_dep_config <repo> <KEY>: one value, as that repository sees it.
#
# It asks dr-config, and does not parse the file. Only dr-config applies all
# the configuration layers. A partial parse of a shell file with grep is a
# second, worse configuration reader. The trust test above runs first. Thus a
# default value that came from a file that is not trusted cannot get here.
dr_dep_config() {
    local repo=$1 key=$2 bin
    # The bin/ of Draugr, found from this file, not taken from the caller. Each
    # command sets $_dr_bin. But a helper that needs its caller to do so breaks
    # when a new caller uses it.
    bin=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../bin" && pwd)
    ( cd "$repo" && env "${_DR_DEP_CLEAN_ENV[@]}" "$bin/dr-config" "$key" ) 2>/dev/null
}

# Each DRAUGR_* key, as arguments that unset it: "env -u DRAUGR_AGENT …".
#
# The configuration of a dependency decides about that dependency. Thus its
# commands run without OUR values. Our values can be in the environment for a
# reason that has no relation to it. dr_hook exports all of them before it runs
# a hook, and they stay exported for the rest of the process. The environment
# wins over each configuration file. Without this list, one repo with a pre-up
# hook claims and starts the mound of a different repo under its own name,
# with no message.
declare -ga _DR_DEP_CLEAN_ENV=()
for _dr_k in "${DR_KEYS[@]}"; do _DR_DEP_CLEAN_ENV+=(-u "$_dr_k"); done
unset _dr_k

# dr_dep_seconds <duration>: "10m" -> 600. "off" and an empty value -> "".
#
# Three suffixes, because a linger time is in minutes, and nobody must have
# to write 600. A value that the code cannot read is a configuration error.
# The code does not guess.
dr_dep_seconds() {
    local v=$1 n=${1%[smh]}
    case "$v" in
        ''|off|never|false) printf '' ; return 0 ;;
    esac
    case "$n" in
        ''|*[!0-9]*) dr_die "cannot read a duration from \"$v\"" \
                            "Write it as 30s, 10m, 1h, or off." ;;
    esac
    case "$v" in
        *s) printf '%s' "$n" ;;
        *m) printf '%s' "$(( n * 60 ))" ;;
        *h) printf '%s' "$(( n * 3600 ))" ;;
        *)  printf '%s' "$n" ;;
    esac
}

# ---------------------------------------------------------------------------
# Hooks: they run on the HOST (WSL). The commands of a kit cannot do that.
# ---------------------------------------------------------------------------

dr_hook() {
    local name=$1 repo=${2:-$PWD} hook
    hook="$repo/.draugr/hooks/$name"

    # If there is no hook, or it is not executable, return with no message.
    # Hooks are optional.
    [ -x "$hook" ] || return 0

    # First the trust test, for the same reason as for .draugr.conf. A hook is
    # a script that runs on the HOST, as you. It is more dangerous than the
    # configuration file next to it, which has a trust test since Phase 1.
    #
    # It is in the repository. Thus it comes with a clone, and it can come with
    # a `dr-merge` of the commits of the agent. Without this test, an agent can
    # write .draugr/hooks/pre-up and get it merged. The code then runs on your
    # machine at the next dr-up. A test showed this, before this line existed.
    #
    # Refuse, and do not prompt. dr_hook runs in the middle of a command, often
    # after the mound was created. "Your hook did not run" is a safer surprise
    # than "something that you did not read just ran".
    dr_trust_check "$hook" || dr_die \
        "refused to run a hook that is not trusted: $hook" \
        "Hooks run on your machine, as you, with the configuration in their environment." \
        "Read it, then run:  dr-trust $hook"

    dr_debug "running hook $name"

    # A hook is a separate process. Thus the code must export the merged
    # configuration to it. The linter accepts ${k?} for "export by name".
    local k
    for k in "${DR_KEYS[@]}"; do export "${k?}"; done
    export DRAUGR_REPO="$repo" DRAUGR_HOOK="$name"

    # A hook that fails is fatal. A hook exists to stop the command, so the
    # code must not ignore it.
    "$hook" || dr_die "hook $name failed (exit $?)" "Hook: $hook"
}

# One agent module is always loaded, from the time that this file is sourced.
# Some commands (dr-skills, dr-setup) never read a configuration. If a
# dr_agent_* function existed only after dr_load_config, it is a trap for
# the next caller. dr_load_config loads the module again after the
# configuration layers have their final values. That load decides.
dr_agent_load
