#!/usr/bin/env bats
# The agent on a model that you host, not on the cloud of its vendor.
#
# The important failures here are all silent. A model URL that resolves to
# nothing. An agent module that does not know which variables to set. A port
# that nobody opened. Each one ends with an agent that hangs at its first
# prompt. Or, worse, it continues to talk to the cloud while you think that it
# does not. Thus most of these tests refuse early and loudly.

load helper

setup() {
    dr_test_setup
    dr_load_common
    DRAUGR_AGENT=claude
    dr_agent_load
    DRAUGR_MODEL=
    DRAUGR_MODEL_URL=11435
    DRAUGR_MODEL_FAST=
    DRAUGR_HOST_PORTS=
}

teardown() { dr_test_teardown; }

# --- port or URL ------------------------------------------------------------

@test "dr_model_is_port: a bare port number is one" {
    run dr_model_is_port 11435
    [ "$status" -eq 0 ]
}

@test "dr_model_is_port: a URL is not" {
    run dr_model_is_port "https://llm.corp.example"
    [ "$status" -eq 1 ]
}

@test "dr_model_is_port: empty is not" {
    run dr_model_is_port ""
    [ "$status" -eq 1 ]
}

@test "dr_model_is_port: host:port is NOT a port" {
    # This must be a URL, not a port. Inside the mound, localhost means the
    # MOUND. A host-port rule for it opens a rule for the wrong machine.
    run dr_model_is_port "localhost:11435"
    [ "$status" -eq 1 ]
}

# --- the address the mound actually dials -----------------------------------

@test "dr_model_url: a bare port becomes this machine's address" {
    DRAUGR_MODEL_URL=11435
    run dr_model_url
    [ "$status" -eq 0 ]
    [ "$output" = "http://172.19.192.26:11435" ]
}

@test "dr_model_url: a URL is passed through untouched" {
    DRAUGR_MODEL_URL="https://llm.corp.example/v1"
    run dr_model_url
    [ "$status" -eq 0 ]
    [ "$output" = "https://llm.corp.example/v1" ]
}

@test "dr_model_url: an unresolvable address is a failure, not an empty answer" {
    # The same reason as for dr_host_ip. "http://:11435" looks like success, and
    # fails later, in a place with no clear link to this.
    export DR_MOCK_HOST_IP=
    DRAUGR_MODEL_URL=11435
    run dr_model_url
    [ "$status" -eq 1 ]
}

# --- what is refused --------------------------------------------------------

@test "dr_model_check: silent when DRAUGR_MODEL is unset" {
    DRAUGR_MODEL=
    run dr_model_check
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "dr_model_check: a bare port in DRAUGR_HOST_PORTS is allowed" {
    DRAUGR_MODEL="qwen3.8:27b"
    DRAUGR_MODEL_URL=11435
    DRAUGR_HOST_PORTS="11435"
    run dr_model_check
    [ "$status" -eq 0 ]
}

@test "dr_model_check: a bare port NOT in DRAUGR_HOST_PORTS is refused" {
    # The combination cannot work. Without the rule, the interception layer
    # accepts the connection and drops it. The agent then hangs at its first
    # prompt, with nothing to read. Thus Draugr says so before it builds the
    # mound.
    DRAUGR_MODEL="qwen3.8:27b"
    DRAUGR_MODEL_URL=11435
    DRAUGR_HOST_PORTS=
    run dr_model_check
    [ "$status" -ne 0 ]
    [[ "$output" == *"not in DRAUGR_HOST_PORTS"* ]]
}

@test "dr_model_check: the refusal names the line that fixes it" {
    DRAUGR_MODEL="qwen3.8:27b"
    DRAUGR_MODEL_URL=11435
    DRAUGR_HOST_PORTS=
    run dr_model_check
    [[ "$output" == *'DRAUGR_HOST_PORTS="11435"'* ]]
}

@test "dr_model_check: another port being open is not this port being open" {
    DRAUGR_MODEL="qwen3.8:27b"
    DRAUGR_MODEL_URL=11435
    DRAUGR_HOST_PORTS="11434 8080"
    run dr_model_check
    [ "$status" -ne 0 ]
    # The test reads the message, not only the status. A refusal for the right
    # reason and a crashed function both exit non-zero.
    [[ "$output" == *"not in DRAUGR_HOST_PORTS"* ]]
}

@test "dr_model_check: a URL needs no DRAUGR_HOST_PORTS at all" {
    # The normal network policy controls the endpoint of another party. The
    # host-port rule has no effect on it. A demand for one is a refusal that
    # nobody can satisfy.
    DRAUGR_MODEL="qwen3.8:27b"
    DRAUGR_MODEL_URL="https://llm.corp.example"
    DRAUGR_HOST_PORTS=
    run dr_model_check
    [ "$status" -eq 0 ]
}

@test "dr_model_check: an agent that cannot be pointed anywhere is refused" {
    # The worst failure of this feature: an agent that ignores DRAUGR_MODEL, and
    # continues to use its cloud. Meanwhile the value in the configuration file
    # looks like it works.
    DRAUGR_AGENT=nosuchagent
    dr_agent_load
    DRAUGR_MODEL="qwen3.8:27b"
    DRAUGR_MODEL_URL="https://llm.corp.example"
    run dr_model_check
    [ "$status" -ne 0 ]
    [[ "$output" == *"cannot send nosuchagent to a different endpoint"* ]]
}

# --- what the agent module contributes --------------------------------------

@test "claude: names all three tiers, so none falls through to a cloud model" {
    # Claude Code selects a tier for each call. A tier with no mapping reaches
    # the local endpoint as an unknown cloud model name. It fails as "model not
    # found", at a time with no link to what you typed.
    run dr_agent_model_env "http://host:11435" "qwen3.8:27b" "qwen3:8b"
    [ "$status" -eq 0 ]
    [[ "$output" == *"ANTHROPIC_DEFAULT_OPUS_MODEL=qwen3.8:27b"* ]]
    [[ "$output" == *"ANTHROPIC_DEFAULT_SONNET_MODEL=qwen3.8:27b"* ]]
    [[ "$output" == *"ANTHROPIC_DEFAULT_HAIKU_MODEL=qwen3:8b"* ]]
}

@test "claude: sets the base URL and a placeholder token" {
    # Without a token, Claude Code sends no request, even to an endpoint that
    # ignores it. A real token must not go to a local port.
    run dr_agent_model_env "http://host:11435" "qwen3.8:27b" ""
    [[ "$output" == *"ANTHROPIC_BASE_URL=http://host:11435"* ]]
    [[ "$output" == *"ANTHROPIC_AUTH_TOKEN="* ]]
}

@test "claude: an empty fast model falls back to the main one" {
    run dr_agent_model_env "http://host:11435" "qwen3.8:27b" ""
    [[ "$output" == *"ANTHROPIC_DEFAULT_HAIKU_MODEL=qwen3.8:27b"* ]]
}

@test "claude: the anthropic secret stops being recommended on a local model" {
    # If not, dr-doctor tells you to sign in to a service that this session
    # never calls. That advice makes things worse.
    DRAUGR_MODEL="qwen3.8:27b"
    run dr_agent_secret
    [ "$status" -ne 0 ]
}

@test "claude: the anthropic secret is still named without one" {
    DRAUGR_MODEL=
    run dr_agent_secret
    [ "$status" -eq 0 ]
    [ "$output" = "anthropic" ]
}

@test "an unmeasured agent declines rather than guessing" {
    DRAUGR_AGENT=nosuchagent
    dr_agent_load
    run dr_agent_model_supported
    [ "$status" -eq 1 ]
    run dr_agent_model_env "http://host:11435" m f
    [ "$status" -eq 1 ]
}

# --- reaching the agent, which is the whole point ---------------------------

@test "dr_attach_rc: exports the model variables when one is configured" {
    # This is the only way in. The ssh proxy of sbx ignores AcceptEnv, and a kit
    # is committed before the address is known.
    DRAUGR_MODEL="qwen3.8:27b"
    DRAUGR_MODEL_URL=11435
    run dr_attach_rc claude
    [ "$status" -eq 0 ]
    [[ "$output" == *"export ANTHROPIC_BASE_URL=http://172.19.192.26:11435"* ]]
    [[ "$output" == *"export ANTHROPIC_DEFAULT_SONNET_MODEL="* ]]
}

@test "dr_attach_rc: says nothing about models when none is configured" {
    DRAUGR_MODEL=
    run dr_attach_rc claude
    [ "$status" -eq 0 ]
    [[ "$output" != *"ANTHROPIC"* ]]
}

@test "dr_attach_rc: still starts the agent from PROMPT_COMMAND" {
    # The exports must not change the job control above them. A command in the
    # rcfile body cannot be suspended and resumed.
    DRAUGR_MODEL="qwen3.8:27b"
    DRAUGR_MODEL_URL=11435
    run dr_attach_rc claude
    [[ "$output" == *"PROMPT_COMMAND="* ]]
    [[ "$output" == *"148"* ]]
}

@test "dr_attach_rc: a model name with shell metacharacters is quoted" {
    # Model names contain colons and dots today. The quoting must hold for all
    # names that a registry allows later, because a shell reads this back.
    DRAUGR_MODEL='we;ird $name'
    DRAUGR_MODEL_URL=11435
    run dr_attach_rc claude
    [ "$status" -eq 0 ]
    [[ "$output" != *"export ANTHROPIC_DEFAULT_OPUS_MODEL=we;ird"* ]]
}

# --- what is actually answering there ----------------------------------------
#
# The bug for this section: Draugr created a mound, the agent attached, and
# each prompt failed with `500 dial tcp ...: connectex: No connection could be
# made`. Nothing made sure that the endpoint was up. The session needed only
# that, and nobody asked about it.

# dr_model_probe runs in-process here. Thus it finds a shell function named
# curl, also through `command -v`.
fake_curl() {
    eval "curl() {
        case \"\$*\" in
            *healthz*)     printf '%s' '$1' ;;
            *api/version*) printf '%s' '$2' ;;
            *)             printf '000' ;;
        esac
    }"
}

@test "dr_model_probe: the proxy, with a model server behind it" {
    fake_curl 200 200
    [ "$(dr_model_probe http://x)" = proxy ]
}

@test "dr_model_probe: the proxy answering with nothing behind it" {
    # Kept apart, because inside the agent these two look the same. The fix is
    # different: start the proxy, or start the model server.
    fake_curl 200 000
    [ "$(dr_model_probe http://x)" = stalled ]
}

@test "dr_model_probe: a model server with no proxy in front" {
    fake_curl 404 200
    [ "$(dr_model_probe http://x)" = bare ]
}

@test "dr_model_probe: somebody else's endpoint is alive, not broken" {
    # This case must not be refused. A company endpoint does not know /healthz
    # or /api/version, but it works. If "not the proxy" means "not working",
    # Draugr rejects the one case that a full URL is for.
    fake_curl 404 404
    [ "$(dr_model_probe http://x)" = alive ]
}

@test "dr_model_probe: nothing listening at all" {
    fake_curl 000 000
    [ "$(dr_model_probe http://x)" = dead ]
}

@test "dr_model_probe: says so rather than guessing when it cannot ask" {
    # A subshell with no PATH, so command -v finds no curl. An answer of "dead"
    # here refuses a working session only because a tool is missing.
    out=$( PATH=""; dr_model_probe http://x )
    [ "$out" = unknown ]
}

# --- the proxy that answers for a host it refuses ----------------------------
#
# These three tests are the reason that dr_model_probe passes --noproxy for a
# bare port. The stubs above give the same answer for each call. These stubs
# must tell a call through the proxy from a direct call. Thus they read the
# argv.

@test "dr_model_probe: the refusal of a proxy is not a live endpoint" {
    # A test inside a mound showed the gateway of sbx answering
    #   403 Blocked by network policy: domain <host>:<port>
    # for an address with nothing on it. 403 is not 000. Thus the rule "each
    # other code means that something is there" changed `dead` into `alive`.
    # dr_model_check did not refuse, and the agent attached to nothing.
    DRAUGR_MODEL_URL=11435
    curl() {
        case "$*" in
            *--noproxy*) printf '000' ;;   # direct: nothing is on that port
            *)           printf '403' ;;   # proxied: the deny page of the gateway
        esac
    }
    [ "$(dr_model_probe http://x)" = dead ]
}

@test "dr_model_probe: a bare port does not ask the proxy" {
    # A bare port became the address of this machine. No route to your own
    # machine goes through a proxy.
    DRAUGR_MODEL_URL=11435
    curl() { printf '%s\n' "$*" >> "$DR_TMP/curlargv"; printf '000'; }
    : > "$DR_TMP/curlargv"
    dr_model_probe http://x > /dev/null
    grep -q -- '--noproxy' "$DR_TMP/curlargv"
}

@test "dr_model_probe: a full URL still goes through the proxy" {
    # This case must not break again. You reach a company endpoint THROUGH the
    # proxy. Thus --noproxy for each URL reports `dead` for a working endpoint,
    # and refuses a session that can run.
    DRAUGR_MODEL_URL="https://llm.corp.example"
    curl() { printf '%s\n' "$*" >> "$DR_TMP/curlargv"; printf '000'; }
    : > "$DR_TMP/curlargv"
    dr_model_probe https://llm.corp.example > /dev/null
    # `run`, not a bare `!`: set -e ignores a negated command, so a mid-test
    # `! grep` passes whatever it finds. See tests/lint-inverted.sh.
    run grep -q -- '--noproxy' "$DR_TMP/curlargv"
    [ "$status" -ne 0 ]
}

# --- and the refusal it feeds ------------------------------------------------

@test "dr-go: refuses to attach when nothing is answering" {
    # Port 1, where nothing listens. It is a real refused connection, not a
    # mock. Thus this exercises the real path of dr-go.
    REPO=$(dr_make_win_repo) || skip "no writable path under /mnt/<drive> on this machine"
    cd "$REPO" || return 1
    export DR_MOCK_NAME="draugr-$(basename "$REPO")" DR_MOCK_STATE=running
    dr_fake_sbx_root
    export DRAUGR_MODEL="qwen3.8:27b" DRAUGR_MODEL_URL=1 DRAUGR_HOST_PORTS=1

    run dr-go
    [ "$status" -ne 0 ]
    [[ "$output" == *"nothing answers"* ]]
    # Before the terminal test. That test came first before, and hid this fully.
    [[ "$output" != *"needs a terminal"* ]]
}

@test "dr-go: without a model configured, nothing is probed" {
    REPO=$(dr_make_win_repo) || skip "no writable path under /mnt/<drive> on this machine"
    cd "$REPO" || return 1
    export DR_MOCK_NAME="draugr-$(basename "$REPO")" DR_MOCK_STATE=running
    dr_fake_sbx_root
    export DRAUGR_MODEL=

    run dr-go
    [[ "$output" != *"nothing is answering"* ]]
    [[ "$output" == *"needs a terminal"* ]]
}
