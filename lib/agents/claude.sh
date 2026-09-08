# shellcheck shell=bash
#
# lib/agents/claude.sh - what Draugr knows about Claude Code, and nothing else.
#
# shellcheck disable=SC2016
# Single-quoted "$1" appears throughout and is deliberate: those strings are
# scripts for the MOUND's shell, and the whole point is that the host does not
# expand them. See dr_mound_sh in lib/common.sh for how the arguments get there.
#
# Sourced by dr_agent_load when DRAUGR_AGENT is "claude", which is the default.
# Every module in this directory answers the same set of dr_agent_* questions;
# lib/agents/default.sh carries the list and what each one means.
#
# The point of the split is that an agent's private layout is exactly the kind of
# thing that changes without telling you. Keeping each one in its own file means
# a wrong guess about Codex cannot break a Claude session, and the next agent is
# a new file rather than a new branch in six commands.

# ---------------------------------------------------------------------------
# Memory, and the project-key translation
#
# Claude Code keeps per-project memory at
#     <home>/.claude/projects/<PROJECT-KEY>/memory/
# and derives PROJECT-KEY from the project's ABSOLUTE PATH. One repository
# therefore has a different key on each side of the boundary:
#
#   Windows   C:\Code\Draugr       c--Code-Draugr
#   WSL       /mnt/c/Code/Draugr   -mnt-c-Code-Draugr
#   Mound     /c/Code/Draugr       -c-Code-Draugr
#
# Measured rather than assumed: on this machine one repo really does appear as
# c--Code-claude on the host and -c-Code-claude inside its mound.
#
# Copy the directory across without renaming and you get one the agent silently
# never reads. No error, no warning, just an agent that has forgotten
# everything - and that silence is the entire reason dr-mem exists.
#
# The encoder itself (dr_mem_key and friends) stays in lib/common.sh: it is a
# pure path function, and the store uses it to name a directory whatever agent
# is in play. What lives here is the LAYOUT built on top of it.
# ---------------------------------------------------------------------------

# dr_mem_mound_dir <repo> - the project directory inside the mound.
dr_mem_mound_dir() {
    printf '%s/.claude/projects/%s' "$DR_MOUND_HOME" "$(dr_mem_key_mound "$1")"
}

# --- the module interface ---------------------------------------------------

# Claude Code is the agent Draugr was built against, so its layout is known.
dr_agent_mem_supported() { return 0; }
dr_agent_mem_label()     { printf 'Claude Code'; }

# dr_agent_mem_dir <repo> - the directory holding memory inside the mound. Its
# parent is what dr-mem creates and copies into, so the two stay in step by
# construction rather than by two functions agreeing with each other.
dr_agent_mem_dir() {
    printf '%s/memory' "$(dr_mem_mound_dir "$1")"
}

# dr_agent_mem_survey - listed when dr_agent_mem_dir turns out not to exist.
#
# A wrong project key is the exact failure dr-mem exists to prevent, so when the
# expected directory is missing it is worth showing what the mound does have:
# one of those entries being this repo under another name is the symptom.
dr_agent_mem_survey() {
    printf '%s/.claude/projects' "$DR_MOUND_HOME"
}

# dr_agent_mem_present <repo> - is there anything in the mound worth exporting?
#
# The project key we computed is a prediction. If the mound disagrees, say so and
# show what is actually there: a wrong key is the exact failure dr-mem exists to
# prevent, so it must never be the silent kind. An existing project directory
# with no memory in it is the ordinary "not yet" case and says nothing.
dr_agent_mem_present() {
    local repo=$1 dir present
    dir=$(dr_agent_mem_dir "$repo")

    # No project directory at all is the interesting case: either this repo has
    # never had a session, or the key is wrong. Listing what IS there tells the
    # two apart at a glance.
    if ! dr_mound_sh 'test -d "$1"' "$(dirname "$dir")"; then
        present=$(dr_mound_sh 'ls -1 "$1" 2>/dev/null' "$(dr_agent_mem_survey)" | head -20)
        if [ -n "$present" ]; then
            dr_warn "no project directory at $(dirname "$dir"), but the mound does have:"
            printf '%s\n' "$present" | sed 's/^/    /' >&2
            printf '  %sIf one of those is this repo, dr_mem_key needs a case it does not%s\n' \
                "$_DR_DIM" "$_DR_OFF" >&2
            printf '  %shandle yet - worth reporting, with the repo path.%s\n' \
                "$_DR_DIM" "$_DR_OFF" >&2
        fi
        return 1
    fi

    dr_mound_sh 'test -d "$1"' "$dir"
}

# dr_agent_mem_list <repo> - the carried set, hashed, named as pack writes them.
#
# find -printf '%P' prints the path with the starting directory stripped, and
# xargs -r declines to run sha256sum at all when there are no files - without
# it, an empty directory would leave sha256sum reading stdin forever.
dr_agent_mem_list() {
    local dir; dir=$(dr_agent_mem_dir "$1")
    dr_mound_sh 'cd "$1" 2>/dev/null || exit 0
                 find . -type f -printf "%P\0" | sort -z | xargs -0 -r sha256sum' "$dir"
}

# dr_agent_mem_pack <repo> <stage> - everything worth keeping, into <stage>.
#
# Claude Code's memory is one directory of markdown, so the packed tree is simply
# its contents. "$2/." rather than "$2" copies what is INSIDE the directory,
# which is what makes the packed tree the same shape for every agent.
dr_agent_mem_pack() {
    local repo=$1 stage=$2
    dr_mound_run 'set -e
                  rm -rf "$1"; mkdir -p "$1"
                  cp -a "$2/." "$1/"' "$stage" "$(dr_agent_mem_dir "$repo")"
}

# dr_agent_mem_unpack <repo> <stage> - and back again.
#
# The destination is replaced rather than merged: an import is "make the mound
# look like this", and a merge would leave files from a previous session that
# the store has no record of.
dr_agent_mem_unpack() {
    local repo=$1 stage=$2 dir
    dir=$(dr_agent_mem_dir "$repo")
    dr_mound_run 'set -e
                  rm -rf "$2"; mkdir -p "$2"
                  cp -a "$1/." "$2/"' "$stage" "$dir"
}

# dr_agent_mem_host_dir <repo> - the host's own live Claude memory for this repo,
# if any. Two installs are possible and they use different keys: Claude Code run
# under Windows, and Claude Code run inside WSL. Prints the first that exists
# and returns 1 when neither does.
dr_agent_mem_host_dir() {
    local repo=$1 userprofile candidate

    # Windows first: on a WSL host $HOME is ext4 and usually has no Claude
    # install at all, while the Windows profile normally does.
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

# dr_agent_mem_status_extra <repo> - the keys, for `dr-mem status`.
#
# Worth a section of its own because they are the thing that goes wrong: three
# spellings of one repository, and a copy filed under the wrong one is invisible.
# Seeing all three side by side is how you recognise the one in the mound.
dr_agent_mem_status_extra() {
    printf '\n%skeys%s\n' "$_DR_BOLD" "$_DR_OFF"
    printf '  %-6s %s\n' host  "$(dr_mem_key_win "$1")"
    printf '  %-6s %s\n' wsl   "$(dr_mem_key_wsl "$1")"
    printf '  %-6s %s\n' mound "$(dr_mem_key_mound "$1")"
}

# dr_agent_mem_host_hint <repo> - where the search above looked, for the message
# printed when it found nothing. Naming the two keys is the useful half: someone
# whose memory IS on this machine can see at a glance which spelling it is under.
dr_agent_mem_host_hint() {
    printf 'Looked under keys %s and %s in ~/.claude/projects.' \
        "$(dr_mem_key_win "$1")" "$(dr_mem_key_wsl "$1")"
}

# dr_agent_secret - the name sbx stores this agent's credentials under.
#
# The token never enters the mound: sbx's proxy authenticates on the agent's
# behalf, which is why signing in after a mound was built needs no rebuild.
# How to GET that token is dr_agent_signin below, and it is not what you would
# guess.
#
# With DRAUGR_MODEL set there is no secret worth naming: the agent is not going
# to call Anthropic at all, and dr-doctor's "the agent starts logged out" would
# be advice to authenticate against a service this session does not use.
# Returning failure is the existing spelling for that, and dr-doctor already
# says nothing when it gets one.
dr_agent_secret() {
    [ -z "${DRAUGR_MODEL:-}" ] || return 1
    printf 'anthropic'
}

# dr_agent_signin - and how to get one, which for Anthropic is backwards from
# every other service sbx handles.
#
# `sbx secret set -g anthropic --oauth` is the obvious command and sbx REFUSES
# it, measured against 0.37.1:
#
#   ERROR: anthropic OAuth cannot be started from `sbx secret set`;
#          sign in from inside the Claude sandbox
#
# `sbx secret set --help` bears that out - its only --oauth example is openai,
# so the flag works for the secret Codex uses and not for this one. The store
# holds the RESULT of a login rather than the means to perform one, and for
# Anthropic the only thing that knows how to run the flow is Claude Code itself.
# So the sign-in happens in a mound and sbx captures what comes out of it;
# every later mound is then covered, because the secret is global.
#
# An API key can still be pasted in directly, since a key is a value you already
# have rather than one a flow has to produce. Named second because it is the
# answer to a different question.
dr_agent_signin() {
    printf 'Sign in from INSIDE a mound - sbx refuses to start this flow itself:\n'
    printf '  dr-go     then run  /login  in Claude Code\n'
    printf 'The token is captured globally, so other mounds need no rebuild.\n'
    printf 'Or paste an API key instead:  echo "$KEY" | sbx secret set -g %s\n' "$1"
}

# ---------------------------------------------------------------------------
# Plugins
#
# Claude Code keeps a plugin library at ~/.claude/plugins, and two variables
# redirect it. They are not interchangeable and dr-plugin needs both names:
#
#   CLAUDE_CODE_PLUGIN_CACHE_DIR   the library to READ AND WRITE. This is what
#                                  makes a seed buildable: point the CLI at a
#                                  directory and every install lands there
#   CLAUDE_CODE_PLUGIN_SEED_DIR    a READ-ONLY library, consulted once at session
#                                  startup. Never read by the CLI subcommands -
#                                  measured, and the reason `claude plugin
#                                  marketplace list` reports nothing in a mound
#                                  that is working perfectly well
#
# So dr-plugin writes through the first and the mounds read through the second.
# ---------------------------------------------------------------------------

dr_agent_plugin_supported() { return 0; }
dr_agent_plugin_cache_var() { printf 'CLAUDE_CODE_PLUGIN_CACHE_DIR'; }
dr_agent_plugin_seed_var()  { printf 'CLAUDE_CODE_PLUGIN_SEED_DIR'; }

# dr_agent_plugin_cli <verb> [arg...] - one operation, a word a line.
#
# A word a line rather than a string because the caller feeds it to mapfile and
# then to sbx exec: quoting a command line and re-splitting it is how the
# `dr-shell -- "VAR=x cmd"` trap happens, and this avoids the question.
#
# -y everywhere it is accepted, because none of this runs on a TTY. On install
# and update it accepts a marketplace-declared command that has CHANGED since it
# was last agreed to, which is a real review step - dr-plugin prints what the CLI
# says rather than swallowing it.
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
# Pointing Claude Code at another endpoint
#
# Claude Code reads its endpoint from ANTHROPIC_BASE_URL, and sends no request
# at all without ANTHROPIC_AUTH_TOKEN even when the far side ignores it. So the
# token below is a placeholder and deliberately not a real credential: nothing
# here should put a live token on a local port.
#
# The three tier variables are not redundant. Claude Code picks a tier per call
# rather than using one model - a small one for background work, a larger one
# for yours - and any tier left unmapped falls through to a cloud model name the
# local endpoint has never heard of. That surfaces as "model not found" at a
# moment with no obvious connection to what you were doing, so all three are set
# even when two of them name the same model.
# ---------------------------------------------------------------------------

dr_agent_model_supported() { return 0; }

# dr_agent_model_env <url> <model> <fast> - KEY=value a line, for the rcfile.
dr_agent_model_env() {
    printf 'ANTHROPIC_BASE_URL=%s\n'             "$1"
    printf 'ANTHROPIC_AUTH_TOKEN=%s\n'           'draugr-local'
    printf 'ANTHROPIC_DEFAULT_OPUS_MODEL=%s\n'   "$2"
    printf 'ANTHROPIC_DEFAULT_SONNET_MODEL=%s\n' "$2"
    printf 'ANTHROPIC_DEFAULT_HAIKU_MODEL=%s\n'  "${3:-$2}"
}
