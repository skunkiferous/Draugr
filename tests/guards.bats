#!/usr/bin/env bats
# The guards: dr-scan, dr-kit, dr-policy, dr-ports.
#
# dr-scan has real logic, so its tests use real files in a real git repo. The
# other three are thin wrappers over sbx. Thus their tests are about the command
# line that they build, and the refusals that they make first.

load helper

setup() {
    dr_test_setup
    REPO=$(dr_make_win_repo) || skip "no writable path under /mnt/<drive> on this machine"
    cd "$REPO" || return 1
    SANDBOX="draugr-$(basename "$REPO")"
    export DR_MOCK_NAME="$SANDBOX" DR_MOCK_STATE=running
    dr_fake_sbx_root
    SKILLS=$DR_SKILLS_DIR
}

teardown() { dr_test_teardown; }

calls() { grep "^$1 " "$DR_MOCK_LOG" || true; }

# --- dr-scan: what the agent can read ----------------------------------------

@test "dr-scan: a clean repo passes" {
    run dr-scan
    [ "$status" -eq 0 ]
    [[ "$output" == *"no files that look like credentials"* ]]
}

@test "dr-scan: finds an untracked .env" {
    printf 'SECRET=1\n' > "$REPO/.env"
    run dr-scan
    [ "$status" -ne 0 ]
    [[ "$output" == *".env"* ]]
}

@test "dr-scan: finds a gitignored secret, which is the whole point" {
    printf 'secrets.env\n' > "$REPO/.gitignore"
    printf 'AWS_SECRET=hunter2\n' > "$REPO/secrets.env"
    git add -A && git commit -qm ignore
    run dr-scan
    [ "$status" -ne 0 ]
    [[ "$output" == *"secrets.env"* ]]
    # The message must explain the mechanism. If not, the reply is "but it is
    # ignored".
    [[ "$output" == *"/run/sandbox/source"* ]]
}

@test "dr-scan: ignores a COMMITTED .env - that is a different problem" {
    printf 'SECRET=1\n' > "$REPO/.env"
    git add -A && git commit -qm "committed env"
    run dr-scan
    [ "$status" -eq 0 ]
}

@test "dr-scan: DRAUGR_SCAN_FAIL=warn reports but does not refuse" {
    printf 'SECRET=1\n' > "$REPO/.env"
    DRAUGR_SCAN_FAIL=warn run dr-scan
    [ "$status" -eq 0 ]
    [[ "$output" == *".env"* ]]
}

@test "dr-scan: honours DRAUGR_SCAN_PATTERNS" {
    printf 'x\n' > "$REPO/nothing-special.txt"
    DRAUGR_SCAN_PATTERNS="nothing-special.txt" run dr-scan
    [ "$status" -ne 0 ]
    [[ "$output" == *"nothing-special.txt"* ]]
}

@test "dr-scan: matches on basename, so a nested secret is found" {
    mkdir -p "$REPO/deep/nested"
    printf 'SECRET=1\n' > "$REPO/deep/nested/.env"
    run dr-scan
    [ "$status" -ne 0 ]
    [[ "$output" == *"deep/nested/.env"* ]]
}

# --- dr-scan: what the agent can leave behind --------------------------------

@test "dr-scan: an empty skills store is reported as empty" {
    run dr-scan
    [ "$status" -eq 0 ]
    [[ "$output" == *"skills store is empty"* ]]
}

@test "dr-scan: lists what is in the shared skills store" {
    mkdir -p "$SKILLS/mystery-skill"
    run dr-scan
    [[ "$output" == *"mystery-skill"* ]]
    [[ "$output" == *"it stays after sbx rm"* ]]
}

@test "dr-scan: a skill alone does not fail the scan" {
    # Only credentials change the exit status. A skill that you installed on
    # purpose is not a failure, so this is only information.
    mkdir -p "$SKILLS/deliberate"
    run dr-scan
    [ "$status" -eq 0 ]
}

@test "dr-scan: --skills checks only the store" {
    printf 'SECRET=1\n' > "$REPO/.env"
    run dr-scan --skills
    [ "$status" -eq 0 ]
    [[ "$output" != *".env"* ]]
}

# --- how dr-go uses it ------------------------------------------------------

# A gitignored secret, not a plain untracked one. An untracked file makes the
# tree dirty. Then dr-go refuses for that reason, and the test passes without a
# run of the scan.
@test "dr-go: a credential blocks it before the mound is created" {
    dr_add_ignored_secret "$REPO"
    run dr-go
    [ "$status" -ne 0 ]
    [[ "$output" == *"secrets.env"* ]]
    [ -z "$(calls create)" ]
}

@test "dr-go: DRAUGR_SCAN=false skips the check entirely" {
    dr_add_ignored_secret "$REPO"
    DRAUGR_SCAN=false run dr-go
    # Passes the scan, and fails on the terminal test.
    [[ "$output" != *"credential-shaped"* ]]
    [[ "$output" == *"needs a terminal"* ]]
}

# --- dr-kit ------------------------------------------------------------------

@test "dr-kit: says what to do when there is no kit" {
    run dr-kit validate
    [ "$status" -ne 0 ]
    [[ "$output" == *"dr-init"* ]]
}

@test "dr-kit: validate passes the kit as a Windows path" {
    mkdir -p "$REPO/.draugr/kit"
    printf 'schemaVersion: "2"\n' > "$REPO/.draugr/kit/spec.yaml"
    run dr-kit validate
    [ "$status" -eq 0 ]
    [[ "$(calls kit)" == *"kit validate "*':\'* ]]
}

@test "dr-kit: drift is silent when there is no record yet" {
    mkdir -p "$REPO/.draugr/kit"
    printf 'schemaVersion: "2"\n' > "$REPO/.draugr/kit/spec.yaml"
    run dr-kit drift
    [ "$status" -eq 0 ]
    [[ "$output" == *"no record"* ]]
}

@test "dr-kit: drift is clean straight after dr-up creates the mound" {
    mkdir -p "$REPO/.draugr/kit"
    printf 'schemaVersion: "2"\n' > "$REPO/.draugr/kit/spec.yaml"
    DR_MOCK_STATE=absent dr-up >/dev/null 2>&1
    run dr-kit drift
    [ "$status" -eq 0 ]
    [[ "$output" == *"matches"* ]]
}

@test "dr-kit: editing the spec is detected as drift" {
    mkdir -p "$REPO/.draugr/kit"
    printf 'schemaVersion: "2"\n' > "$REPO/.draugr/kit/spec.yaml"
    DR_MOCK_STATE=absent dr-up >/dev/null 2>&1
    printf 'displayName: changed\n' >> "$REPO/.draugr/kit/spec.yaml"
    run dr-kit drift
    [ "$status" -eq 1 ]
    [[ "$output" == *"changed after"* ]]
}

@test "dr-kit: a new file in the kit counts as drift, not just spec.yaml" {
    mkdir -p "$REPO/.draugr/kit"
    printf 'schemaVersion: "2"\n' > "$REPO/.draugr/kit/spec.yaml"
    DR_MOCK_STATE=absent dr-up >/dev/null 2>&1
    printf 'seed\n' > "$REPO/.draugr/kit/extra-file"
    run dr-kit drift
    [ "$status" -eq 1 ]
}

@test "dr-up: reports drift on an existing mound" {
    mkdir -p "$REPO/.draugr/kit"
    printf 'schemaVersion: "2"\n' > "$REPO/.draugr/kit/spec.yaml"
    DR_MOCK_STATE=absent dr-up >/dev/null 2>&1
    printf 'displayName: changed\n' >> "$REPO/.draugr/kit/spec.yaml"
    run dr-up
    [ "$status" -eq 0 ]
    [[ "$output" == *"kit changed after"* ]]
}

# --- dr-policy and dr-ports --------------------------------------------------

@test "dr-policy: lists, and points at the defaults you did not write" {
    run dr-policy
    [ "$status" -eq 0 ]
    [[ "$(calls policy)" == *"policy ls"* ]]
    [[ "$output" == *"--defaults"* ]]
}

@test "dr-policy: --check scopes the query to this sandbox" {
    run dr-policy --check example.com
    [ "$status" -eq 0 ]
    [[ "$(calls policy)" == *"check network example.com --sandbox $SANDBOX"* ]]
}

@test "dr-policy: --allow will not open a hole without confirmation" {
    run dr-policy --allow evil.example.com
    [ "$status" -ne 0 ]
    [[ "$(calls policy)" != *"allow"* ]]
}

@test "dr-policy: --allow scopes the rule to this sandbox, not machine-wide" {
    run dr-policy --allow example.com --yes
    [ "$status" -eq 0 ]
    [[ "$(calls policy)" == *"allow network example.com --sandbox $SANDBOX"* ]]
}

@test "dr-ports: no arguments only lists" {
    run dr-ports
    [ "$status" -eq 0 ]
    [[ "$(calls ports)" == "ports $SANDBOX" ]]
}

@test "dr-ports: publishes and unpublishes in one call" {
    run dr-ports 5173 --close 8080:80
    [ "$status" -eq 0 ]
    [[ "$(calls ports)" == *"--publish 5173"* ]]
    [[ "$(calls ports)" == *"--unpublish 8080:80"* ]]
}

@test "dr-ports: an absent mound says so" {
    DR_MOCK_STATE=absent run dr-ports
    [ "$status" -ne 0 ]
    [[ "$output" == *"dr-up"* ]]
}
