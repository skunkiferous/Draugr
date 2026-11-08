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
    if ! dr_mound_sh 'test -d "$1"' "$(dirname "$dir")"; then
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

    dr_mound_sh 'test -d "$1"' "$dir"
}

# dr_agent_mem_list <repo>: the copied files, with hashes, and with the names
# that pack writes.
#
# find -printf '%P' prints the path without the start directory. When there
# are no files, xargs -r does not run sha256sum. Without -r, sha256sum reads
# stdin and never stops for an empty directory.
dr_agent_mem_list() {
    local dir; dir=$(dr_agent_mem_dir "$1")
    dr_mound_sh 'cd "$1" 2>/dev/null || exit 0
                 find . -type f -printf "%P\0" | sort -z | xargs -0 -r sha256sum' "$dir"
}

# dr_agent_mem_pack <repo> <stage>: copy all the data to keep into <stage>.
#
# The memory of Claude Code is one directory of markdown. Thus the packed tree
# is its contents. "$2/." (not "$2") copies what is INSIDE the directory. Thus
# the packed tree has the same format for each agent.
dr_agent_mem_pack() {
    local repo=$1 stage=$2
    dr_mound_run 'set -e
                  rm -rf "$1"; mkdir -p "$1"
                  cp -a "$2/." "$1/"' "$stage" "$(dr_agent_mem_dir "$repo")"
}

# dr_agent_mem_unpack <repo> <stage>: the copy in the other direction.
#
# The code replaces the destination, and does not merge. An import means "make
# the mound look like this". A merge leaves files from an earlier session, and
# the store has no record of them.
dr_agent_mem_unpack() {
    local repo=$1 stage=$2 dir
    dir=$(dr_agent_mem_dir "$repo")
    dr_mound_run 'set -e
                  rm -rf "$2"; mkdir -p "$2"
                  cp -a "$1/." "$2/"' "$stage" "$dir"
}

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

# dr_agent_model_env <url> <model> <fast>: one KEY=value on each line, for the rcfile.
dr_agent_model_env() {
    printf 'ANTHROPIC_BASE_URL=%s\n'             "$1"
    printf 'ANTHROPIC_AUTH_TOKEN=%s\n'           'draugr-local'
    printf 'ANTHROPIC_DEFAULT_OPUS_MODEL=%s\n'   "$2"
    printf 'ANTHROPIC_DEFAULT_SONNET_MODEL=%s\n' "$2"
    printf 'ANTHROPIC_DEFAULT_HAIKU_MODEL=%s\n'  "${3:-$2}"
}
