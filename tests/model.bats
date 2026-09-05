#!/usr/bin/env bats
# Running the agent on a model you host, rather than on its vendor's cloud.
#
# The interesting failures here are all silent ones. A model URL that resolves to
# nothing, an agent module that does not know which variables to set, a port
# nobody opened - each of them ends with an agent that either hangs at its first
# prompt or, worse, carries on talking to the cloud while you believe it is not.
# So most of these tests are about refusing early and loudly.

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
    # It matters that this is a URL rather than a port: localhost means the MOUND
    # from inside the mound, so giving it the host-port treatment would open a
    # rule for a machine that is not the one being named.
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
    # The same reasoning as dr_host_ip: "http://:11435" would look like success
    # and fail later, somewhere with no connection to this.
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
    # The combination cannot work: without the rule the connection is accepted by
    # the interception layer and dropped, so the agent hangs at its first prompt
    # with nothing to read. Better to say so before the mound is even built.
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
    # Checked by message, not just by status: a refusal for the right reason
    # and a function falling over both exit non-zero.
    [[ "$output" == *"not in DRAUGR_HOST_PORTS"* ]]
}

@test "dr_model_check: a URL needs no DRAUGR_HOST_PORTS at all" {
    # Somebody else's endpoint is reached under the ordinary network policy, so
    # the host-port rule has nothing to do with it and demanding one would be a
    # refusal nobody could satisfy.
    DRAUGR_MODEL="qwen3.8:27b"
    DRAUGR_MODEL_URL="https://llm.corp.example"
    DRAUGR_HOST_PORTS=
    run dr_model_check
    [ "$status" -eq 0 ]
}

@test "dr_model_check: an agent that cannot be pointed anywhere is refused" {
    # The worst failure this feature could have is an agent that ignores
    # DRAUGR_MODEL and keeps using its cloud while the setting sits in a config
    # file looking like it works.
    DRAUGR_AGENT=nosuchagent
    dr_agent_load
    DRAUGR_MODEL="qwen3.8:27b"
    DRAUGR_MODEL_URL="https://llm.corp.example"
    run dr_model_check
    [ "$status" -ne 0 ]
    [[ "$output" == *"cannot point nosuchagent at another endpoint"* ]]
}

# --- what the agent module contributes --------------------------------------

@test "claude: names all three tiers, so none falls through to a cloud model" {
    # Claude Code picks a tier per call. An unmapped one reaches the local
    # endpoint as a cloud model name it has never heard of, and fails as
    # "model not found" at a moment unrelated to whatever you were typing.
    run dr_agent_model_env "http://host:11435" "qwen3.8:27b" "qwen3:8b"
    [ "$status" -eq 0 ]
    [[ "$output" == *"ANTHROPIC_DEFAULT_OPUS_MODEL=qwen3.8:27b"* ]]
    [[ "$output" == *"ANTHROPIC_DEFAULT_SONNET_MODEL=qwen3.8:27b"* ]]
    [[ "$output" == *"ANTHROPIC_DEFAULT_HAIKU_MODEL=qwen3:8b"* ]]
}

@test "claude: sets the base URL and a placeholder token" {
    # Claude Code sends no request at all without a token, even to somewhere that
    # ignores it - and a real one has no business on a local port.
    run dr_agent_model_env "http://host:11435" "qwen3.8:27b" ""
    [[ "$output" == *"ANTHROPIC_BASE_URL=http://host:11435"* ]]
    [[ "$output" == *"ANTHROPIC_AUTH_TOKEN="* ]]
}

@test "claude: an empty fast model falls back to the main one" {
    run dr_agent_model_env "http://host:11435" "qwen3.8:27b" ""
    [[ "$output" == *"ANTHROPIC_DEFAULT_HAIKU_MODEL=qwen3.8:27b"* ]]
}

@test "claude: the anthropic secret stops being recommended on a local model" {
    # dr-doctor would otherwise tell you to sign in to a service this session is
    # never going to call, which is advice that makes things worse.
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
    # This is the only route in: sbx's ssh proxy honours no AcceptEnv, and a kit
    # is committed while the address is known only now.
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
    # The exports must not disturb the job-control arrangement above them: a
    # command in the rcfile body cannot be suspended and resumed.
    DRAUGR_MODEL="qwen3.8:27b"
    DRAUGR_MODEL_URL=11435
    run dr_attach_rc claude
    [[ "$output" == *"PROMPT_COMMAND="* ]]
    [[ "$output" == *"148"* ]]
}

@test "dr_attach_rc: a model name with shell metacharacters is quoted" {
    # Model names carry colons and dots today; the quoting has to hold for
    # whatever a registry allows tomorrow, because this is read back by a shell.
    DRAUGR_MODEL='we;ird $name'
    DRAUGR_MODEL_URL=11435
    run dr_attach_rc claude
    [ "$status" -eq 0 ]
    [[ "$output" != *"export ANTHROPIC_DEFAULT_OPUS_MODEL=we;ird"* ]]
}

# --- what is actually answering there ----------------------------------------
#
# The bug this section exists for: a mound was created, the agent attached, and
# every prompt failed with `500 dial tcp ...: connectex: No connection could be
# made`. Nothing had checked the endpoint was up, so the one thing the session
# depended on was the one thing nobody asked about.

# dr_model_probe is called in-process here, so a shell function named curl is
# what it finds - including through `command -v`.
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
    # Distinguished because from inside the agent these two look identical, and
    # the remedy is different: start the proxy, or start the model server.
    fake_curl 200 000
    [ "$(dr_model_probe http://x)" = stalled ]
}

@test "dr_model_probe: a model server with no proxy in front" {
    fake_curl 404 200
    [ "$(dr_model_probe http://x)" = bare ]
}

@test "dr_model_probe: somebody else's endpoint is alive, not broken" {
    # The case that must not be refused: a company endpoint has never heard of
    # /healthz or /api/version and is perfectly usable. Treating "not the proxy"
    # as "not working" would reject the one case a full URL exists for.
    fake_curl 404 404
    [ "$(dr_model_probe http://x)" = alive ]
}

@test "dr_model_probe: nothing listening at all" {
    fake_curl 000 000
    [ "$(dr_model_probe http://x)" = dead ]
}

@test "dr_model_probe: says so rather than guessing when it cannot ask" {
    # A subshell with no PATH, so command -v finds no curl. Answering "dead"
    # here would refuse a working session on the strength of a missing tool.
    out=$( PATH=""; dr_model_probe http://x )
    [ "$out" = unknown ]
}

# --- and the refusal it feeds ------------------------------------------------

@test "dr-go: refuses to attach when nothing is answering" {
    # Port 1, which nothing can be listening on - a real refused connection
    # rather than a mocked one, so this exercises the path dr-go really takes.
    REPO=$(dr_make_win_repo) || skip "no writable path under /mnt/<drive> on this machine"
    cd "$REPO" || return 1
    export DR_MOCK_NAME="draugr-$(basename "$REPO")" DR_MOCK_STATE=running
    dr_fake_sbx_root
    export DRAUGR_MODEL="qwen3.8:27b" DRAUGR_MODEL_URL=1 DRAUGR_HOST_PORTS=1

    run dr-go
    [ "$status" -ne 0 ]
    [[ "$output" == *"nothing is answering"* ]]
    # Before the terminal check, which used to come first and hide this entirely.
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
