# shellcheck shell=bash
#
# lib/agents/claude.sh: what Draugr knows about Claude Code, and nothing else.
#
# shellcheck disable=SC2016
# "$1" in single quotes occurs in many places, on purpose. Those strings are
# scripts for the shell of the MOUND. The host must not expand them. See
# dr_mound_sh in lib/common.sh for how the arguments get there.
#
# dr_agent_load sources this file when DRAUGR_AGENT is "claude", the default.
# Each module in this directory answers the same dr_agent_* questions.
# lib/agents/default.sh has the list, and the meaning of each question.
#
# The reason for the split: the private layout of an agent can change with no
# notice. With one file for each agent, a wrong guess about Codex cannot break
# a Claude session. The next agent is a new file, not a new branch in six
# commands.

# ---------------------------------------------------------------------------
# Memory, and the project-key translation
#
# Claude Code keeps the memory of each project at
#     <home>/.claude/projects/<PROJECT-KEY>/memory/
# It makes PROJECT-KEY from the ABSOLUTE PATH of the project. Thus one
# repository has a different key on each side of the boundary:
#
#   Windows   C:\Code\Draugr       c--Code-Draugr
#   WSL       /mnt/c/Code/Draugr   -mnt-c-Code-Draugr
#   Mound     /c/Code/Draugr       -c-Code-Draugr
#
# A test showed this. On one machine, one repo is c--Code-claude on the host
# and -c-Code-claude in its mound.
#
# If you copy the directory with no rename, the agent never reads the copy.
# There is no error and no warning. The agent only forgot everything. That
# silence is the reason that dr-mem exists.
#
# The encoder (dr_mem_key and the related functions) stays in lib/common.sh.
# It is a pure path function, and the store uses it to name a directory for
# each agent. This file holds the LAYOUT on top of it.
# ---------------------------------------------------------------------------

# dr_mem_mound_dir <repo>: the project directory in the mound.
dr_mem_mound_dir() {
    printf '%s/.claude/projects/%s' "$DR_MOUND_HOME" "$(dr_mem_key_mound "$1")"
}

# --- the module interface ---------------------------------------------------

# Draugr was built for Claude Code, so its layout is known.
dr_agent_mem_supported() { return 0; }
dr_agent_mem_label()     { printf 'Claude Code'; }

# dr_agent_mem_dir <repo>: the directory in the mound that holds memory. dr-mem
# creates its parent and copies into it. Thus the two always agree, because of
# how they are built. Two functions do not have to agree with each other.
dr_agent_mem_dir() {
    printf '%s/memory' "$(dr_mem_mound_dir "$1")"
}

# dr_agent_mem_survey: the code lists this when dr_agent_mem_dir does not exist.
#
# dr-mem exists to prevent a wrong project key. If the expected directory is
# missing, show what the mound has. If one of those items is this
# repo under a different name, that is the symptom.
dr_agent_mem_survey() {
    printf '%s/.claude/projects' "$DR_MOUND_HOME"
}

# dr_agent_mem_present <repo>: does the mound hold data to export?
#
# The project key that the code calculated is a prediction. If the mound does
# not agree, say so and show what is there. dr-mem exists to prevent a wrong
# key, so a wrong key must never be silent. A project directory with no memory
# in it is the usual "not yet" case, and the code says nothing.
dr_agent_mem_present() {
    local repo=$1 dir present
    dir=$(dr_agent_mem_dir "$repo")

    # No project directory is the important case. This repo never had a
    # session, or the key is wrong. A list of what IS there shows at once
    # which of the two it is.
    if ! dr_mound_sh 'test -d "$1"' "$(dr_mem_mound_dir "$repo")"; then
        present=$(dr_mound_sh 'ls -1 "$1" 2>/dev/null' "$(dr_agent_mem_survey)" | head -20)
        if [ -n "$present" ]; then
            dr_warn "no project directory at $(dirname "$dir"), but the mound has:"
            printf '%s\n' "$present" | sed 's/^/    /' >&2
            printf '  %sIf one of those is this repo, dr_mem_key does not yet know that case.%s\n' \
                "$_DR_DIM" "$_DR_OFF" >&2
            printf '  %sPlease report it, with the path of the repo.%s\n' \
                "$_DR_DIM" "$_DR_OFF" >&2
        fi
        return 1
    fi

    # The memory and the conversation both count. A mound where you talked and
    # the agent wrote no memory still holds the conversation, and a recreate
    # that throws it away is a real loss.
    _dr_claude_state present "$repo"
}

# ---------------------------------------------------------------------------
# The memory and the conversation
#
# Claude Code keeps them next to each other, and they are different things:
#
#   ~/.claude/projects/<key>/memory/        what the agent learned. Markdown
#   ~/.claude/projects/<key>/<uuid>.jsonl   one transcript for each session
#   ~/.claude/projects/<key>/<uuid>/        the files of that session
#
# --continue reads the NEWEST transcript. Thus a mound that gets only the
# memory back has forgotten the conversation, and no amount of memory brings
# it back. That is what DRAUGR_MEM_TRANSCRIPTS carries, and `newest` is its
# default, because that is the one that --continue reads.
#
# They also differ in size by three orders of magnitude: in this project the
# memory is 184 KB and one transcript is 180 MB. Thus the amount is a choice
# of the user and not a fixed answer, and `off` is the behavior from before
# this key existed.
#
# THE PACKED TREE. The memory stays at the root, exactly where it was, and the
# transcripts go in one directory beside it:
#
#   <packed>/MEMORY.md, <packed>/*.md …    the contents of memory/
#   <packed>/transcripts/<uuid>.jsonl
#   <packed>/transcripts/<uuid>/…
#
# A store from an older Draugr has no transcripts/ directory, and unpack reads
# it unchanged. That is why the memory keeps the root: it makes every store
# that you already have still an import, and not a special case in the code.
# A memory file named `transcripts` makes the layout ambiguous, so pack
# refuses it instead of writing a tree that unpack reads wrongly.
# ---------------------------------------------------------------------------

# One script for all four views of that tree, so that they cannot disagree.
# It runs in the shell of the MOUND, which is POSIX sh and not bash.
_dr_claude_state_script() {
    cat <<'SH'
set -eu
action=$1; mode=$2; proj=$3; stage=${4:-}
mem="$proj/memory"

# The transcripts to carry, newest first, and the directory of each session
# right after its file. A name with any other character is not a session of
# Claude Code: leave it where it is rather than copy something unknown.
names() {
    if [ ! -d "$proj" ] || [ "$mode" = off ]; then return 0; fi
    all=$(cd "$proj" && find . -maxdepth 1 -type f -name '*.jsonl' \
          -printf '%T@\t%P\n' 2>/dev/null | sort -rn | cut -f2) || return 1
    if [ "$mode" != all ]; then all=$(printf '%s\n' "$all" | head -1); fi
    printf '%s\n' "$all" | while IFS= read -r f; do
        if [ -z "$f" ]; then continue; fi
        case "$f" in *[!A-Za-z0-9_.-]*) continue ;; esac
        printf '%s\n' "$f"
        d=${f%.jsonl}
        if [ -d "$proj/$d" ]; then printf '%s\n' "$d"; fi
    done
}

# Two probes, and neither matches a process NAME. That is measured, not
# careful: in a mound the agent is an ELF binary at
# ~/.local/share/claude/versions/<version>, so the name of the process is the
# VERSION, and `pgrep -x claude` finds nothing while the agent runs. A name
# that changes with each update is not a probe.
#
# Both answer 0 for quiet and 1 for a signal. The caller turns an unreadable
# /proc into 2, because unknown must never mean quiet: that answer copies a
# file while it grows and calls the result a backup.

# 1. Does the AGENT run? The path of the executable answers it. /proc/<pid>/exe
#    is a link to the real binary, and it is readable for the processes of this
#    user. Measured in a mound: a stand-in binary under the version directory
#    was found by the scan, a copy of it outside that directory was not, and
#    after both exited the scan was quiet. The root daemons of the mound have
#    an exe that this user cannot read, which is why an unreadable link is
#    skipped and not an error.
#
#    The directory comes from the project path of THIS call, not from $HOME.
#    In a mound the two are the same. In the test harness the project path is
#    inside a stand-in tree, and then this cannot match a Claude Code that the
#    person running the tests has installed on the machine itself.
agent_running() {
    home=${proj%/.claude/projects/*}
    found=0
    for d in /proc/[0-9]*; do
        t=$(readlink "$d/exe" 2>/dev/null) || continue
        case "$t" in "$home"/.local/share/claude/versions/*) found=1 ;; esac
    done
    if [ "$found" = 0 ]; then return 0; fi
    return 1
}

# 2. Is anything holding a file of this conversation open? This one does not
#    depend on where the agent is installed, so it still answers when the
#    layout above changes, and it also catches a writer that is not the agent.
#    A test in a mound found the holder of an open file and found nothing after
#    that file was closed. A second test holds it up: one mound is ONE process
#    view. A file held open by one session was found by a later, separate exec,
#    with the same pid. Thus these probes can see the agent of your session,
#    and are not a check that cannot fail.
#
#    For the writer that pauses between two probes, the caller compares hashes
#    around the copy.
writer() {
    found=0
    for d in /proc/[0-9]*/fd; do
        for f in "$d"/*; do
            if [ ! -e "$f" ]; then continue; fi
            t=$(readlink "$f" 2>/dev/null) || continue
            case "$t" in
                "$proj"/*.jsonl) found=1 ;;
                "$mem"/*)        found=1 ;;
            esac
        done
    done
    if [ "$found" = 0 ]; then return 0; fi
    return 1
}

case "$action" in
quiesce)
    # /proc carries both answers. Without it there is no answer at all, and
    # that is 2, not "quiet".
    if [ ! -d /proc/self/fd ]; then exit 2; fi
    rc=0
    agent_running || rc=$?
    if [ "$rc" -ne 0 ]; then exit "$rc"; fi
    writer || rc=$?
    exit "$rc"
    ;;
present)
    if [ -d "$mem" ] && [ -n "$(ls -A "$mem" 2>/dev/null)" ]; then exit 0; fi
    if [ -n "$(names)" ]; then exit 0; fi
    exit 1
    ;;
list)
    if [ -d "$mem" ]; then
        (cd "$mem" && find . -type f -printf '%P\0' | sort -z | xargs -0 -r sha256sum)
    fi
    names | while IFS= read -r n; do
        if [ -d "$proj/$n" ]; then
            (cd "$proj/$n" && find . -type f -printf '%P\n' | sort) |
            while IFS= read -r p; do
                printf '%s  transcripts/%s/%s\n' \
                    "$(sha256sum < "$proj/$n/$p" | cut -d' ' -f1)" "$n" "$p"
            done
        else
            printf '%s  transcripts/%s\n' \
                "$(sha256sum < "$proj/$n" | cut -d' ' -f1)" "$n"
        fi
    done
    ;;
pack)
    rm -rf "$stage"; mkdir -p "$stage"
    # No link enters the packed tree. Measured on sbx 0.53.0, copying OUT of a
    # mound: extraction fails at the link with "a required privilege is not
    # held by the client" and status 1, after writing a part of the tree that
    # is not predictable - one fixture arrived with all four of its regular
    # files, one with a single file out of four, one with nothing. So a link
    # here does not become a link in the store; it becomes a failed export, or
    # with an older sbx a store that is missing files. The Codex module refuses
    # links for its own reasons, and this is the second one.
    #
    # This check runs in the MOUND, with the mound's own find. It is the first
    # of two, and the one that an agent could replace; bin/dr-mem asks the same
    # question again on the host, about the tree that actually arrived.
    if [ -d "$mem" ] && [ -n "$(find "$mem" -type l 2>/dev/null | head -1)" ]; then
        printf 'the memory holds a link, and a copy stops there\n' >&2
        exit 4
    fi
    if [ -d "$mem" ]; then
        if [ -e "$mem/transcripts" ]; then
            printf 'the memory holds an entry named transcripts\n' >&2
            exit 3
        fi
        cp -a "$mem/." "$stage/"
    fi
    names | while IFS= read -r n; do
        if [ -L "$proj/$n" ] || [ -n "$(find "$proj/$n" -type l 2>/dev/null | head -1)" ]; then
            printf 'the conversation holds a link, and a copy stops there\n' >&2
            exit 4
        fi
        mkdir -p "$stage/transcripts"
        cp -a "$proj/$n" "$stage/transcripts/"
    done
    ;;
unpack)
    # The memory is REPLACED: an import means "make the mound look like this".
    # A transcript is not. It is one conversation, and a uuid that this store
    # never saw is not a reason to destroy it. Thus transcripts are added, and
    # a name that the store also has is overwritten.
    mkdir -p "$proj"
    rm -rf "$mem"; mkdir -p "$mem"
    (cd "$stage" && find . -maxdepth 1 -mindepth 1 ! -name transcripts \
        -exec cp -a {} "$mem/" \;)
    if [ -d "$stage/transcripts" ]; then
        (cd "$stage/transcripts" && find . -maxdepth 1 -mindepth 1 \
            -exec cp -a {} "$proj/" \;)
    fi
    ;;
*) exit 64 ;;
esac
SH
}

# The value of the key, and a refusal for a word that is not one of the three.
# A typing error must not silently become "carry nothing".
_dr_claude_mode() {
    case "${DRAUGR_MEM_TRANSCRIPTS:-newest}" in
        off|newest|all) printf '%s' "${DRAUGR_MEM_TRANSCRIPTS:-newest}" ;;
        *) dr_error "DRAUGR_MEM_TRANSCRIPTS is \"$DRAUGR_MEM_TRANSCRIPTS\". Use off, newest or all"
           return 1 ;;
    esac
}

# One entry to the script above: the action, the chosen amount, and the
# project directory in the mound. Each caller then adds only its own argument.
_dr_claude_state() {
    local action=$1 repo=$2 mode
    shift 2
    mode=$(_dr_claude_mode) || return 1
    dr_mound_sh "$(_dr_claude_state_script)" \
        "$action" "$mode" "$(dr_mem_mound_dir "$repo")" "$@"
}

# dr_agent_mem_quiesce: 0 quiet, 1 a writer holds the conversation, 2 unknown.
#
# The contract has three answers for the reason that lib/agents/codex.sh gives
# at the same function: a probe that cannot answer must not give the quiet
# answer, because that answer copies a growing file and calls it a backup.
dr_agent_mem_quiesce() {
    _dr_claude_state quiesce "$1"
}

# dr_agent_mem_list <repo>: the copied files, with hashes, and with the names
# that pack writes.
#
# find -printf '%P' prints the path without the start directory. When there
# are no files, xargs -r does not run sha256sum. Without -r, sha256sum reads
# stdin and never stops for an empty directory.
dr_agent_mem_list() {
    _dr_claude_state list "$1"
}

# dr_agent_mem_transcript_paths: where the conversation is inside the packed
# tree. dr-mem prints the command that deletes these from the host again.
dr_agent_mem_transcript_paths() { printf 'transcripts\n'; }

# dr_agent_mem_pack <repo> <stage>: copy all the data to keep into <stage>.
#
# A quiet agent, then the copy, then the same two questions again. A writer
# that started and stopped between the probes still changes a hash, and that
# is what the comparison is for. On any failure the caller publishes nothing,
# so the store keeps the complete copy that it already had.
#
# THREE ANSWERS, like the probe it is built on: 0 packed, 1 definitely not safe
# to pack, 2 could not find out. This function prints which it was, so the
# caller reports the status and does not guess at a cause of its own. See
# "Pattern: a reporter with three answers" in docs/HACKING.md.
dr_agent_mem_pack() {
    local repo=$1 stage=$2 before after rc=0
    dr_agent_mem_quiesce "$repo" || rc=$?
    if [ "$rc" -ne 0 ]; then
        dr_warn "the context was not exported. The previous store is unchanged"
        if [ "$rc" -eq 1 ]; then
            printf '  %sClaude Code runs in %s, or something holds the%s\n' \
                "$_DR_DIM" "$DRAUGR_SANDBOX" "$_DR_OFF" >&2
            printf '  %sconversation open. A copy of a file that grows is not a backup.%s\n' \
                "$_DR_DIM" "$_DR_OFF" >&2
            printf '  %sLeave the agent, then run:  dr-mem export%s\n' \
                "$_DR_DIM" "$_DR_OFF" >&2
        else
            printf '  %sDraugr could not find out whether the conversation is being%s\n' \
                "$_DR_DIM" "$_DR_OFF" >&2
            printf '  %swritten. Thus it did not copy it, because the copy can be half of one.%s\n' \
                "$_DR_DIM" "$_DR_OFF" >&2
        fi
        # The answer of the probe, not a flattened 1. "something holds the
        # conversation" and "Draugr could not find out" need different advice,
        # and only this function knows which of the two it printed.
        return "$rc"
    fi
    # A step that does not answer is "could not find out", not "not safe": the
    # mound is what the caller should then look at, not the agent. That is the
    # whole difference between 1 and 2 below.
    before=$(dr_agent_mem_list "$repo") || return 2
    _dr_claude_state pack "$repo" "$stage" || return 2
    dr_agent_mem_quiesce "$repo" || return $?
    after=$(dr_agent_mem_list "$repo") || return 2
    # This one IS 1: the probes answered, and what they say is that the context
    # moved. Nothing about the mound is in doubt.
    if [ "$before" != "$after" ]; then
        dr_error "the context changed during the export. The store is unchanged"
        return 1
    fi
}

# dr_agent_mem_unpack <repo> <stage>: the copy in the other direction.
dr_agent_mem_unpack() {
    local repo=$1 stage=$2
    # The answer of the probe, so that "in use" and "could not tell" stay apart.
    dr_agent_mem_import_ready "$repo" || return $?
    _dr_claude_state unpack "$repo" "$stage"
}

# The source of Claude already is the memory directory of one project. Reject links
# before copying, since staging itself is visible through the source mount.
dr_agent_mem_prepare_source() {
    dr_incoming_validate_tree "$1" || return 1
    mkdir -p "$2"
    cp -a "$1/." "$2/"
}

# A quiet target for the conversation too. The agent appends to the transcript
# of the session that runs, and an import replaces the memory under it.
dr_agent_mem_import_ready() { dr_agent_mem_quiesce "${1:-$DR_REPO}"; }
dr_agent_mem_init() { return 0; }

# dr_agent_mem_host_dir <repo>: the live Claude memory of the host for this repo,
# if there is one. Two installs are possible, and they use different keys:
# Claude Code on Windows, and Claude Code in WSL. The function prints the first
# that exists. If neither exists, it returns 1.
dr_agent_mem_host_dir() {
    local repo=$1 userprofile candidate

    # Windows first. On a WSL host, $HOME is ext4 and usually has no Claude
    # install. The Windows profile usually has one.
    if command -v cmd.exe >/dev/null 2>&1; then
        userprofile=$(cmd.exe /c 'echo %USERPROFILE%' 2>/dev/null | tr -d '\r\n')
        if [ -n "$userprofile" ] && [ "$userprofile" != '%USERPROFILE%' ]; then
            candidate="$(dr_path_from_win "$userprofile")/.claude/projects/$(dr_mem_key_win "$repo")/memory"
            [ -d "$candidate" ] && { printf '%s' "$candidate"; return 0; }
        fi
    fi

    candidate="$HOME/.claude/projects/$(dr_mem_key_wsl "$repo")/memory"
    [ -d "$candidate" ] && { printf '%s' "$candidate"; return 0; }

    return 1
}

# dr_agent_mem_status_extra <repo>: the keys, for `dr-mem status`.
#
# They get their own section, because the keys are what goes wrong. One
# repository has three spellings, and nobody sees a copy under the wrong one.
# With all three next to each other, you can find the one in the mound.
dr_agent_mem_status_extra() {
    printf '\n%skeys%s\n' "$_DR_BOLD" "$_DR_OFF"
    printf '  %-6s %s\n' host  "$(dr_mem_key_win "$1")"
    printf '  %-6s %s\n' wsl   "$(dr_mem_key_wsl "$1")"
    printf '  %-6s %s\n' mound "$(dr_mem_key_mound "$1")"
}

# dr_agent_mem_host_hint <repo>: where the search above looked, for the message
# when it found nothing. The two keys are the useful part. If your memory IS on
# this machine, you can see at once under which spelling it is.
dr_agent_mem_host_hint() {
    printf 'Looked under keys %s and %s in ~/.claude/projects.' \
        "$(dr_mem_key_win "$1")" "$(dr_mem_key_wsl "$1")"
}

# dr_agent_secret: the name under which sbx stores the credentials of this agent.
#
# The token never goes into the mound. The proxy of sbx authenticates for the
# agent. Thus a sign-in after the mound was built needs no rebuild. How to GET
# that token is in dr_agent_signin below, and it is not what you expect.
#
# When DRAUGR_MODEL is set, there is no secret to name. The agent does not call
# Anthropic. The message of dr-doctor, "the agent starts logged out", then
# tells you to authenticate with a service that this session does not use. The
# function returns a failure for that case, and dr-doctor then says nothing.
dr_agent_secret() {
    [ -z "${DRAUGR_MODEL:-}" ] || return 1
    printf 'anthropic'
}

# dr_agent_signin: how to get the secret. For Anthropic, the method is the
# opposite of the method for all other services of sbx.
#
# `sbx secret set -g anthropic --oauth` is the obvious command, and sbx REFUSES
# it. A test on 0.37.1 showed this:
#
#   ERROR: anthropic OAuth cannot be started from `sbx secret set`;
#          sign in from inside the Claude sandbox
#
# `sbx secret set --help` agrees. Its only --oauth example is openai. Thus the
# flag works for the secret of Codex, but not for this one. The store holds the
# RESULT of a login, not the method to do one. For Anthropic, only Claude Code
# can run the flow. Thus the sign-in occurs in a mound, and sbx captures the
# result. Then each later mound has it too, because the secret is global.
#
# You can also paste an API key directly. A key is a value that you already
# have, and no flow must make it. It is second, because it answers a
# different question.
dr_agent_signin() {
    printf 'Sign in from INSIDE a mound. sbx refuses to start this flow itself:\n'
    printf '  dr-go     then run  /login  in Claude Code\n'
    printf 'sbx stores the token globally, so other mounds need no rebuild.\n'
    printf 'Or paste an API key:  echo "$KEY" | sbx secret set -g %s\n' "$1"
}

# ---------------------------------------------------------------------------
# Plugins
#
# Claude Code keeps a plugin library at ~/.claude/plugins. Two variables change
# its location. They are not the same, and dr-plugin needs both names:
#
#   CLAUDE_CODE_PLUGIN_CACHE_DIR   the library to READ AND WRITE. With it, Draugr
#                                  can build a seed. Give the CLI a directory,
#                                  and each install goes there
#   CLAUDE_CODE_PLUGIN_SEED_DIR    a READ-ONLY library, read one time at the
#                                  start of a session. The CLI subcommands never
#                                  read it. A test showed this. It is the reason
#                                  that `claude plugin marketplace list` reports
#                                  nothing in a mound that works correctly
#
# Thus dr-plugin writes through the first, and the mounds read through the second.
# ---------------------------------------------------------------------------

dr_agent_plugin_supported() { return 0; }
dr_agent_plugin_cache_var() { printf 'CLAUDE_CODE_PLUGIN_CACHE_DIR'; }
dr_agent_plugin_seed_var()  { printf 'CLAUDE_CODE_PLUGIN_SEED_DIR'; }

# dr_agent_plugin_cli <verb> [arg...]: one operation, one word on each line.
#
# One word on each line, not a string. The caller gives it to mapfile, then to
# sbx exec. If you quote a command line and split it again, you get the trap of
# `dr-shell -- "VAR=x cmd"`. This format prevents that.
#
# Use -y in each place that accepts it, because none of this runs on a TTY. On
# install and update, -y accepts a command from a marketplace that CHANGED
# since the last agreement. That is a real review step. dr-plugin prints what
# the CLI says, and does not hide it.
dr_agent_plugin_cli() {
    local verb=$1; shift
    local argv=(claude plugin)
    case "$verb" in
        market-add)    argv+=(marketplace add "$1") ;;
        market-remove) argv+=(marketplace remove "$1") ;;
        market-update) argv+=(marketplace update ${1:+"$1"}) ;;
        install)       argv+=(install "$1" -y) ;;
        update)        argv+=(update "$1" -y) ;;
        uninstall)     argv+=(uninstall "$1" -y) ;;
        list)          argv+=(list) ;;
        *) return 1 ;;
    esac
    printf '%s\n' "${argv[@]}"
}

# ---------------------------------------------------------------------------
# Send Claude Code to a different endpoint
#
# Claude Code reads its endpoint from ANTHROPIC_BASE_URL. Without
# ANTHROPIC_AUTH_TOKEN, it sends no request, even if the other side ignores the
# token. Thus the token below is a placeholder, and not a real credential, on
# purpose. Nothing here must put a live token on a local port.
#
# The three tier variables are all necessary. Claude Code selects a tier for
# each call, and does not use one model. It uses a small model for background
# work and a larger model for your work. A tier with no value uses the name of
# a cloud model, and the local endpoint does not know that name. You then see
# "model not found" at a time that has no clear relation to your work. Thus
# the code sets all three, also when two of them name the same model.
# ---------------------------------------------------------------------------

dr_agent_model_supported() { return 0; }

# Claude uses the environment contract below, with no extra provider flags.
dr_agent_model_args() { return 0; }
dr_agent_launch_args() { return 0; }

# The existing flag-specific continuation handling remains in dr-go.
# shellcheck disable=SC2034  # dr-go reads the prepared array and explanation.
dr_agent_session_prepare() {
    shift
    DR_AGENT_SESSION_ARGS=("$@")
    DR_AGENT_SESSION_DROPPED=
}

# dr_agent_model_env <url> <model> <fast>: one KEY=value on each line, for the rcfile.
dr_agent_model_env() {
    printf 'ANTHROPIC_BASE_URL=%s\n'             "$1"
    printf 'ANTHROPIC_AUTH_TOKEN=%s\n'           'draugr-local'
    printf 'ANTHROPIC_DEFAULT_OPUS_MODEL=%s\n'   "$2"
    printf 'ANTHROPIC_DEFAULT_SONNET_MODEL=%s\n' "$2"
    printf 'ANTHROPIC_DEFAULT_HAIKU_MODEL=%s\n'  "${3:-$2}"
}

# ---------------------------------------------------------------------------
# The session that --continue needs
#
# Claude Code keeps one transcript for each session as <uuid>.jsonl, directly
# in the project directory that dr_mem_mound_dir names. --continue reads the
# newest of them. If there is none, it prints "No conversation found to
# continue" and EXITS, and the session does not start. A new mound has none.
# Thus a create, and a dr-up --recreate, are the one moment when a configured
# --continue cannot work.
#
# This list holds only the arguments that take NO value. --resume takes an
# optional session id. If dr-go drops that flag, the id stays behind as a
# positional argument, and the agent reads it as a PROMPT. A session that
# starts with a wrong prompt is worse than the refusal.
# ---------------------------------------------------------------------------

dr_agent_session_flags() { printf '%s\n' --continue -c; }

# A word, not an exit code. `sbx exec` can fail for reasons of its own, and
# such a failure must not become "there is no session". That answer throws a
# correct argument away. The caller reads an empty answer as unknown, and a
# failed call leaves an empty answer.
dr_agent_session_present() {
    dr_mound_sh 'command -v find >/dev/null 2>&1 || { printf "unknown\n"; exit 0; }
                 if [ ! -d "$1" ]; then printf "none\n"; exit 0; fi
                 s=$(find "$1" -maxdepth 1 -type f -name "*.jsonl" 2>/dev/null |
                     head -1)
                 if [ -n "$s" ]; then printf "present\n"; else printf "none\n"; fi' \
        "$(dr_mem_mound_dir "$1")"
}
