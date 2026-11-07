#!/usr/bin/env bats
# dr-plugin: the library it reads, the switch it writes, and what it refuses.
#
# The three verbs that need a mound are only partly testable here - the mock does
# not run a plugin CLI - so what is asserted is the argv Draugr BUILT and the
# file movement around it. The parts that are entirely host-side (status, list,
# enable, disable, clean, rollback) are tested for real.
#
# The one thing worth knowing when reading these: dr-plugin refuses a store that
# is not on a Windows drive, so the fixtures live under the same scratch root as
# dr_make_win_repo and are cleaned up by the same teardown.

load helper

setup() {
    dr_test_setup
    dr_load_common
}

teardown() { dr_test_teardown; }

# A repo to stand in, and a library beside it holding one marketplace with one
# plugin. dr-plugin calls dr_context, so the repo is not optional even though
# the library is machine-wide.
#
# STORE is derived rather than remembered: dr_make_win_repo runs in a command
# substitution, so the DR_WIN_TMP it exports never reaches us. Teardown finds the
# same directory the same way.
setup_store() {
    REPO=$(dr_make_win_repo) || return 1
    cd "$REPO" || return 1
    STORE="$(dr_win_root)/draugr-test.${DR_TMP##*/}/store"

    mkdir -p "$STORE/seed/cache/mkt-a/plug-a/1.0.0" "$STORE/seed/marketplaces/mkt-a"
    printf '{"mkt-a": {"source": {}}}\n' > "$STORE/seed/known_marketplaces.json"
    cat > "$STORE/seed/installed_plugins.json" <<'JSON'
{"version": 2, "plugins": {"plug-a@mkt-a": [
  {"scope": "user", "version": "1.0.0",
   "installPath": "/somewhere/stale/cache/mkt-a/plug-a/1.0.0"}]}}
JSON

    export DRAUGR_PLUGIN_STORE="$STORE"
    export DR_MOCK_STATE=running
    return 0
}

# --- what it refuses ----------------------------------------------------------

@test "dr-plugin: refuses when no library is configured" {
    REPO=$(dr_make_win_repo) || skip "no writable Windows drive path"
    cd "$REPO"

    run dr-plugin
    [ "$status" -ne 0 ]
    [[ "$output" == *"DRAUGR_PLUGIN_STORE"* ]]
    # The refusal has to carry the line to add, because the whole feature is off
    # until it is there and nothing else would say so.
    [[ "$output" == *"DRAUGR_PLUGIN_STORE=\"/mnt/c/"* ]]
}

@test "dr-plugin: refuses a library that sbx could never mount" {
    REPO=$(dr_make_win_repo) || skip "no writable Windows drive path"
    cd "$REPO"
    # Under $TMPDIR, i.e. WSL's own filesystem: a real path, and one no sandbox
    # workspace can be made from.
    export DRAUGR_PLUGIN_STORE="$DR_TMP/store"

    run dr-plugin
    [ "$status" -ne 0 ]
    [[ "$output" == *"not on a Windows drive"* ]]
}

@test "dr-plugin: refuses an agent whose plugin layout nobody measured" {
    setup_store || skip "no writable Windows drive path"
    export DRAUGR_AGENT=gemini

    run dr-plugin
    [ "$status" -ne 0 ]
    [[ "$output" == *"does not know how"* ]]
    # Naming what IS known is the difference between a refusal and a dead end.
    [[ "$output" == *"claude"* ]]
}

# --- reading the library ------------------------------------------------------

@test "dr-plugin status: names the marketplaces and the plugins" {
    setup_store || skip "no writable Windows drive path"

    run dr-plugin status
    [ "$status" -eq 0 ]
    [[ "$output" == *"mkt-a"* ]]
    [[ "$output" == *"plug-a@mkt-a"* ]]
    [[ "$output" == *"1.0.0"* ]]
}

@test "dr-plugin status: installed and enabled are two different questions" {
    setup_store || skip "no writable Windows drive path"

    # No settings file at all: the plugin is in the library and switched off, and
    # saying "installed" alone would be the misleading half of the answer.
    run dr-plugin status
    [[ "$output" == *"INSTALLED, NOT ENABLED"* ]]

    printf '{"enabledPlugins": {"plug-a@mkt-a": true}}\n' > "$STORE/settings.json"
    run dr-plugin status
    [[ "$output" == *"enabled"* ]]
    [[ "$output" != *"NOT ENABLED"* ]]
}

@test "dr-plugin status: an unwired library prints the three lines to add" {
    setup_store || skip "no writable Windows drive path"

    run dr-plugin status
    [ "$status" -eq 0 ]
    [[ "$output" == *"not wired up"* ]]
    [[ "$output" == *"DRAUGR_MOUNTS="* ]]
    [[ "$output" == *"CLAUDE_CODE_PLUGIN_SEED_DIR"* ]]
    # The per-agent key, which is the one nobody guesses: a generic
    # DRAUGR_AGENT_ARGS here would be handed to every codex mound as well.
    [[ "$output" == *"DRAUGR_AGENT_ARGS_CLAUDE="* ]]
}

@test "dr-plugin status: says so when all three settings are in force" {
    setup_store || skip "no writable Windows drive path"
    _mound=${STORE#/mnt}
    export DRAUGR_MOUNTS="$STORE:ro"
    export DRAUGR_ENV="CLAUDE_CODE_PLUGIN_SEED_DIR=$_mound/seed"
    export DRAUGR_AGENT_ARGS_CLAUDE="--settings $_mound/settings.json"

    run dr-plugin status
    [ "$status" -eq 0 ]
    [[ "$output" == *"all three settings point at this library"* ]]
}

@test "dr-plugin list: one plugin a line, with version and switch" {
    setup_store || skip "no writable Windows drive path"
    printf '{"enabledPlugins": {"plug-a@mkt-a": true}}\n' > "$STORE/settings.json"

    run dr-plugin list
    [ "$status" -eq 0 ]
    [ "$output" = "plug-a@mkt-a 1.0.0 enabled" ]
}

# --- the switch ---------------------------------------------------------------

@test "dr-plugin enable/disable: writes the settings file, with no mound" {
    setup_store || skip "no writable Windows drive path"

    run dr-plugin enable plug-a@mkt-a
    [ "$status" -eq 0 ]
    [ "$(jq -r '.enabledPlugins["plug-a@mkt-a"]' "$STORE/settings.json")" = true ]

    run dr-plugin disable plug-a@mkt-a
    [ "$status" -eq 0 ]
    [ "$(jq -r '.enabledPlugins["plug-a@mkt-a"]' "$STORE/settings.json")" = false ]

    # Neither one is worth a sandbox, and a test that let one start would hide a
    # regression that cost a minute per call.
    [ ! -s "$DR_MOCK_LOG" ] || ! grep -q '^create' "$DR_MOCK_LOG"
}

@test "dr-plugin enable: keeps the settings file valid JSON when it was absent" {
    setup_store || skip "no writable Windows drive path"
    [ ! -f "$STORE/settings.json" ]

    run dr-plugin enable plug-a@mkt-a
    [ "$status" -eq 0 ]
    run jq -e . "$STORE/settings.json"
    [ "$status" -eq 0 ]
}

# --- clean --------------------------------------------------------------------

@test "dr-plugin clean: drops a superseded version and keeps the live one" {
    setup_store || skip "no writable Windows drive path"
    # Measured against the real CLI: update, prune and list all leave a stale
    # version directory exactly where it is, and list never mentions it.
    mkdir -p "$STORE/seed/cache/mkt-a/plug-a/0.9.0"

    run dr-plugin clean
    [ "$status" -eq 0 ]
    [ -d "$STORE/seed/cache/mkt-a/plug-a/1.0.0" ]
    [ ! -d "$STORE/seed/cache/mkt-a/plug-a/0.9.0" ]
}

@test "dr-plugin clean: removes the empty parents an uninstall leaves behind" {
    setup_store || skip "no writable Windows drive path"
    # cache/<marketplace>/<plugin>/ with no version inside it, which is what
    # `claude plugin uninstall` leaves - harmless, but it makes a find in the
    # library name plugins that are gone.
    mkdir -p "$STORE/seed/cache/ghost-mkt/ghost-plug"

    run dr-plugin clean
    [ "$status" -eq 0 ]
    # Both levels: emptying the plugin directory is what makes its marketplace
    # empty, so one pass would have walked past the parent already.
    [ ! -d "$STORE/seed/cache/ghost-mkt/ghost-plug" ]
    [ ! -d "$STORE/seed/cache/ghost-mkt" ]
}

# --- rollback -----------------------------------------------------------------

@test "dr-plugin rollback: swaps, so running it twice is a no-op" {
    setup_store || skip "no writable Windows drive path"
    mkdir -p "$STORE/seed.old"
    printf 'previous\n' > "$STORE/seed.old/marker"
    printf 'current\n'  > "$STORE/seed/marker"

    run dr-plugin rollback -y
    [ "$status" -eq 0 ]
    [ "$(cat "$STORE/seed/marker")" = previous ]

    run dr-plugin rollback -y
    [ "$status" -eq 0 ]
    [ "$(cat "$STORE/seed/marker")" = current ]
}

@test "dr-plugin rollback: refuses when there is nothing to go back to" {
    setup_store || skip "no writable Windows drive path"

    run dr-plugin rollback -y
    [ "$status" -ne 0 ]
    [[ "$output" == *"no"* ]]
}

# --- the build transaction ----------------------------------------------------

@test "dr-plugin add: the build mound's workspace is the build directory" {
    setup_store || skip "no writable Windows drive path"

    # A plugin named explicitly, so nothing has to be discovered from a
    # marketplace the mock never actually cloned.
    run dr-plugin add owner/repo plug-b@mkt-b
    [ "$status" -eq 0 ]

    line=$(grep '^create ' "$DR_MOCK_LOG" | tail -1)
    [[ "$line" == *"--name draugr-plugin-build"* ]]
    # The WINDOWS spelling of the build directory, because sbx.exe does not
    # translate paths, and .build rather than the library itself - a bad install
    # must not be able to reach what the mounds are reading.
    [[ "$line" == *'\store\.build'* ]]
    [[ "$line" != *'\store\seed '* ]]
}

@test "dr-plugin add: installs through the cache variable, not the seed one" {
    setup_store || skip "no writable Windows drive path"

    run dr-plugin add owner/repo plug-b@mkt-b
    [ "$status" -eq 0 ]

    line=$(grep 'claude plugin install' "$DR_MOCK_LOG" | tail -1)
    # CACHE_DIR is the writable library; SEED_DIR is read-only and is what the
    # mounds use. Confusing the two builds nothing and reports success.
    [[ "$line" == *"CLAUDE_CODE_PLUGIN_CACHE_DIR=/home/agent/seed"* ]]
    [[ "$line" != *"SEED_DIR"* ]]
    [[ "$line" == *"install plug-b@mkt-b -y"* ]]
}

@test "dr-plugin add: the work happens in the rootfs, not on the mount" {
    setup_store || skip "no writable Windows drive path"

    run dr-plugin add owner/repo plug-b@mkt-b
    [ "$status" -eq 0 ]
    # A Windows-backed workspace cannot rename a git clone - measured - and
    # `marketplace add` clones to a temporary name and renames it into place. So
    # the library is staged into the rootfs and copied back afterwards.
    grep -q 'cp -a' "$DR_MOCK_LOG"
    [[ "$(grep 'claude plugin' "$DR_MOCK_LOG" | tail -1)" == *"/home/agent/seed"* ]]
}

@test "dr-plugin add: commits by swapping, and keeps the previous library" {
    setup_store || skip "no writable Windows drive path"
    printf 'current\n' > "$STORE/seed/marker"

    run dr-plugin add owner/repo plug-b@mkt-b
    [ "$status" -eq 0 ]
    [ -d "$STORE/seed.old" ]
    [ -f "$STORE/seed.old/marker" ]
    # And the scratch directory does not survive a success: leaving it would put
    # a stale half-library where the next run copies from.
    [ ! -d "$STORE/.build" ]
}

@test "dr-plugin add: rewrites installPath onto the path it will build at" {
    setup_store || skip "no writable Windows drive path"

    run dr-plugin add owner/repo plug-b@mkt-b
    [ "$status" -eq 0 ]
    # The fixture's installPath points at /somewhere/stale. Every entry records
    # an ABSOLUTE path, so a library copied anywhere else names directories that
    # do not exist until this rewrite happens.
    run jq -r '.plugins["plug-a@mkt-a"][0].installPath' "$STORE/seed/installed_plugins.json"
    [ "$output" = "/home/agent/seed/cache/mkt-a/plug-a/1.0.0" ]
}

@test "dr-plugin add: takes a marketplace, and registers it before installing" {
    setup_store || skip "no writable Windows drive path"

    run dr-plugin add owner/repo plug-b@mkt-b
    [ "$status" -eq 0 ]
    # The marketplace step is part of add, not something to do first: the CLI is
    # asked to register the repository before anything is installed from it.
    add_line=$(grep -n 'marketplace add owner/repo' "$DR_MOCK_LOG" | cut -d: -f1 | head -1)
    inst_line=$(grep -n 'plugin install plug-b@mkt-b' "$DR_MOCK_LOG" | cut -d: -f1 | head -1)
    [ -n "$add_line" ]
    [ -n "$inst_line" ]
    [ "$add_line" -lt "$inst_line" ]
}

@test "dr-plugin add: installs every plugin named after the marketplace" {
    setup_store || skip "no writable Windows drive path"

    # The signature is <owner>/<repo> followed by any number of plugins, which
    # three separate places used to disagree about.
    run dr-plugin add owner/repo one@mkt-b two@mkt-b three@mkt-b
    [ "$status" -eq 0 ]
    [ "$(grep -c 'plugin install one@mkt-b'   "$DR_MOCK_LOG")" -eq 1 ]
    [ "$(grep -c 'plugin install two@mkt-b'   "$DR_MOCK_LOG")" -eq 1 ]
    [ "$(grep -c 'plugin install three@mkt-b' "$DR_MOCK_LOG")" -eq 1 ]

    # And each one is switched on, not merely installed.
    for id in one two three; do
        [ "$(jq -r ".enabledPlugins[\"$id@mkt-b\"]" "$STORE/settings.json")" = true ]
    done
}

@test "dr-plugin add: a bare plugin name refuses rather than guessing a marketplace" {
    setup_store || skip "no writable Windows drive path"

    # Two routes to the name and neither can supply it: the mock registers
    # nothing, so discovery sees no arrival, and setup_store's fixture leaves
    # .source.repo absent, so the registry does not name owner/repo either.
    # Guessing would install nothing and report success.
    run dr-plugin add owner/repo plug-b
    [ "$status" -ne 0 ]
    [[ "$output" == *"cannot tell which marketplace"* ]]
    [[ "$output" == *"no registered marketplace"* ]]
    [[ "$output" == *"<plugin>@<marketplace>"* ]]
}

# A source the registry already knows about. setup_store's fixture deliberately
# leaves .source.repo absent, so the tests that need one say so themselves. What
# the four below are about is the marketplace being ALREADY registered for the
# source named - which is what a second `dr-plugin add` of the same repo hits,
# and what used to be reported as a failure with advice that could not work.
register_source() {
    printf '{"mkt-a": {"source": {"source": "github", "repo": "%s"}}}\n' "$1" \
        > "$STORE/seed/known_marketplaces.json"
}

@test "dr-plugin add: an already-registered source says so, and what is installed" {
    setup_store || skip "no writable Windows drive path"
    register_source owner/repo

    run dr-plugin add owner/repo
    [ "$status" -ne 0 ]
    [[ "$output" == *"already registered, as mkt-a"* ]]

    # The state the old message never mentioned: installed, at which version,
    # and which side of the switch it is on.
    [[ "$output" == *"plug-a@mkt-a 1.0.0 disabled"* ]]
    [[ "$output" == *"dr-plugin update <plugin>@mkt-a"* ]]

    # And it must not hand back the advice that cannot work - a bare <plugin>,
    # which the bare-name branch then refuses for want of the very same name.
    [[ "$output" != *"Name the plugin instead"* ]]
}

@test "dr-plugin add: already registered with nothing installed asks for a plugin" {
    setup_store || skip "no writable Windows drive path"
    register_source owner/repo
    # The marketplace is known but the library holds nothing from it, so there is
    # no state to report - only the one id that would work.
    printf '{"version": 2, "plugins": {}}\n' > "$STORE/seed/installed_plugins.json"

    run dr-plugin add owner/repo
    [ "$status" -ne 0 ]
    [[ "$output" == *"already registered, as mkt-a"* ]]
    [[ "$output" == *"Nothing from it is installed yet"* ]]
    [[ "$output" == *"dr-plugin add owner/repo <plugin>@mkt-a"* ]]
}

@test "dr-plugin add: a bare plugin name completes from the registry" {
    setup_store || skip "no writable Windows drive path"
    register_source owner/repo

    # Discovery finds nothing, but the registry names what owner/repo is already
    # registered as - so the bare name completes, where before it refused. This
    # is the behaviour change the message fix carries with it.
    run dr-plugin add owner/repo plug-b
    [ "$status" -eq 0 ]
    [ "$(grep -c 'plugin install plug-b@mkt-a' "$DR_MOCK_LOG")" -eq 1 ]
    [ "$(jq -r '.enabledPlugins["plug-b@mkt-a"]' "$STORE/settings.json")" = true ]
}

@test "dr-plugin add: an unregistered source refuses without suggesting a bare plugin" {
    setup_store || skip "no writable Windows drive path"
    register_source owner/other

    # The registry names a marketplace for owner/other, not for owner/repo, so
    # neither route can name one here and the refusal stands.
    run dr-plugin add owner/repo
    [ "$status" -ne 0 ]
    [[ "$output" == *"registered no new marketplace"* ]]
    [[ "$output" == *"No registered marketplace names that source"* ]]
    [[ "$output" != *"Name the plugin instead"* ]]
}

@test "dr-plugin: refuses to start on top of a crashed run's build mound" {
    setup_store || skip "no writable Windows drive path"
    # The mock reports whatever DR_MOCK_NAMES lists, so this is a build mound
    # left behind rather than one this run created.
    export DR_MOCK_NAMES=draugr-plugin-build

    run dr-plugin add owner/repo plug-b@mkt-b
    [ "$status" -ne 0 ]
    [[ "$output" == *"already exists"* ]]
    [[ "$output" == *"--force"* ]]
}

# --- the skills a plugin ships, and the kit that installs it ------------------

# A skill inside the installed plugin. The directory name and the front matter's
# `name:` differ on purpose: one test below is about which of the two is used.
make_plugin_skill() {
    local dir="$STORE/seed/cache/mkt-a/plug-a/1.0.0/skills/$1"
    mkdir -p "$dir"
    printf -- '---\nname: %s\ndescription: whatever\n---\n' "${2:-$1}" > "$dir/SKILL.md"
}

@test "dr-plugin skills: names the skills an installed plugin ships" {
    setup_store || skip "no writable Windows drive path"
    make_plugin_skill alpha alpha-skill

    run dr-plugin skills
    [ "$status" -eq 0 ]
    [[ "$output" == *"alpha-skill"* ]]
    # And the plugin it came from, because that is the thing you have to install.
    [[ "$output" == *"plug-a@mkt-a"* ]]
}

@test "dr-plugin skills: the front matter name wins over the directory name" {
    setup_store || skip "no writable Windows drive path"
    make_plugin_skill alpha alpha-skill

    # A substring test cannot tell these apart, since "alpha-skill" contains
    # "alpha" - so the first field is compared outright.
    run dr-plugin skills
    [ "$(printf '%s\n' "$output" | awk 'NR == 1 {print $1}')" = alpha-skill ]
}

@test "dr-plugin skills: a directory with no SKILL.md is not a skill" {
    setup_store || skip "no writable Windows drive path"
    make_plugin_skill alpha
    mkdir -p "$STORE/seed/cache/mkt-a/plug-a/1.0.0/skills/notaskill"

    # The agent ignores one too, so reporting it would invent a skill.
    run dr-plugin skills
    [ "$status" -eq 0 ]
    [[ "$output" == *"alpha"* ]]
    [[ "$output" != *"notaskill"* ]]
}

@test "dr-plugin skills: a skill under a version that is not installed is ignored" {
    setup_store || skip "no writable Windows drive path"
    # installed_plugins.json says 1.0.0. A skill cached under another version is
    # a superseded copy - what dr-plugin clean reaps - and naming it would
    # advertise a skill no mound is going to load.
    mkdir -p "$STORE/seed/cache/mkt-a/plug-a/2.0.0/skills/ghost"
    printf -- '---\nname: ghost\n---\n' \
        > "$STORE/seed/cache/mkt-a/plug-a/2.0.0/skills/ghost/SKILL.md"

    run dr-plugin skills
    [ "$status" -eq 0 ]
    [[ "$output" != *"ghost"* ]]
}

@test "dr-plugin skills: says so when no plugin ships one" {
    setup_store || skip "no writable Windows drive path"
    # Plenty of plugins carry only commands or hooks, so this is an answer and
    # not a failure - commit-commands is one of them.
    run dr-plugin skills
    [ "$status" -eq 0 ]
    [[ "$output" == *"no installed plugin ships a skill"* ]]
}

@test "dr-plugin kit: writes a mixin that installs the plugin, pinning no version" {
    setup_store || skip "no writable Windows drive path"
    export DRAUGR_KIT_STORE="$DR_TMP/kits"

    run dr-plugin kit -y
    [ "$status" -eq 0 ]
    spec="$DRAUGR_KIT_STORE/plugin-plug-a/spec.yaml"
    [ -f "$spec" ]
    grep -q '^kind: mixin' "$spec"
    grep -q 'claude plugin install plug-a@mkt-a -y' "$spec"

    # The seed has to be named the way the MOUND spells it, not the host.
    grep -q 'CLAUDE_CODE_PLUGIN_SEED_DIR=/c/' "$spec"

    # And the version must be absent. A pinned kit would need editing on every
    # dr-plugin update, and an edited kit cannot be applied to a running mound -
    # so pinning would turn each plugin update into a rebuild of every mound.
    ! grep -q '1\.0\.0' "$spec"
}

@test "dr-plugin kit: refuses a plugin that is not installed" {
    setup_store || skip "no writable Windows drive path"
    export DRAUGR_KIT_STORE="$DR_TMP/kits"

    # A kit can only install what the seed holds, so this would generate a file
    # whose one job fails inside every mound built from it.
    run dr-plugin kit nope@mkt-a
    [ "$status" -ne 0 ]
    [[ "$output" == *"not installed"* ]]
    [ ! -e "$DRAUGR_KIT_STORE/plugin-nope" ]
}

@test "dr-plugin kit: will not quietly replace a kit already in the library" {
    setup_store || skip "no writable Windows drive path"
    export DRAUGR_KIT_STORE="$DR_TMP/kits"
    run dr-plugin kit -y
    [ "$status" -eq 0 ]

    # A library kit may have been edited by hand since it was generated, so the
    # second run asks - and with no terminal, asking means refusing.
    printf 'sentinel\n' >> "$DRAUGR_KIT_STORE/plugin-plug-a/spec.yaml"
    run dr-plugin kit
    [ "$status" -ne 0 ]
    [[ "$output" == *"already in the kit library"* ]]
    grep -q sentinel "$DRAUGR_KIT_STORE/plugin-plug-a/spec.yaml"
}

@test "dr-plugin remove: says when a kit still installs what it dropped" {
    setup_store || skip "no writable Windows drive path"
    export DRAUGR_KIT_STORE="$DR_TMP/kits"
    run dr-plugin kit -y
    [ "$status" -eq 0 ]

    # The plugin leaves the seed and the kit stays, still naming it - so a mound
    # built from that kit would go to the network for it, or fail. Reported and
    # NOT deleted: the kit is yours, and may have been edited since.
    run dr-plugin remove plug-a@mkt-a
    [[ "$output" == *"still installs plug-a@mkt-a"* ]]
    [ -f "$DRAUGR_KIT_STORE/plugin-plug-a/spec.yaml" ]
}

# --- the build mound's own environment ----------------------------------------

@test "dr-plugin add: redirects github to HTTPS for the plugin CLI" {
    setup_store || skip "no writable Windows drive path"

    # A mound has no SSH key and must not be given one, but `claude plugin
    # install` clones a github plugin SOURCE over SSH and does not fall back the
    # way `marketplace add` does. Measured against iha2/superlite: the
    # marketplace cloned over HTTPS and the install then died with "Connection
    # closed by 140.82.121.4 port 22" - GitHub refusing an unauthenticated SSH
    # client. Egress was never the problem.
    run dr-plugin add owner/repo plug-b@mkt-b
    [ "$status" -eq 0 ]
    grep -qF 'GIT_CONFIG_COUNT=2' "$DR_MOCK_LOG"
    grep -qF 'GIT_CONFIG_KEY_0=url.https://github.com/.insteadOf' "$DR_MOCK_LOG"
    grep -qF 'GIT_CONFIG_VALUE_0=git@github.com:' "$DR_MOCK_LOG"

    # Both spellings, because git uses either and insteadOf is multi-valued.
    grep -qF 'GIT_CONFIG_VALUE_1=ssh://git@github.com/' "$DR_MOCK_LOG"
}

@test "dr-plugin add: names each slow step while it is running" {
    setup_store || skip "no writable Windows drive path"

    # Three slow steps used to run silently - a tens-of-MB copy on a Windows
    # drive, a microVM create, and the staging copy into its rootfs - so the
    # command said nothing at all until the CLI spoke, and there was no way to
    # tell which of them was being waited on.
    run dr-plugin add owner/repo plug-b@mkt-b
    [ "$status" -eq 0 ]
    [[ "$output" == *"copying the library"* ]]
    [[ "$output" == *"creating the build mound"* ]]
    [[ "$output" == *"staging the library"* ]]
}
