#!/usr/bin/env bats
# dr-plugin: the library it reads, the switch it writes, and what it refuses.
#
# The three verbs that need a mound are only partly testable here, because the
# mock does not run a plugin CLI. Thus the tests assert on the argv that Draugr
# BUILT, and the file moves around it. The parts that are fully on the host
# (status, list, enable, disable, clean, rollback) are tested for real.
#
# Know this when you read these tests: dr-plugin refuses a store that is not on
# a Windows drive. Thus the fixtures are under the same scratch root as
# dr_make_win_repo, and the same teardown removes them.

load helper

setup() {
    dr_test_setup
    dr_load_common
}

teardown() { dr_test_teardown; }

# A stand-in repo, and a library beside it with one marketplace and one plugin.
# dr-plugin calls dr_context, so the repo is necessary, but the library is for
# the full machine.
#
# STORE is computed, not stored. dr_make_win_repo runs in a command
# substitution, so the DR_WIN_TMP that it exports never reaches us. Teardown
# finds the same directory in the same way.
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
    # The refusal must contain the line to add. Until it is there, the feature
    # is off, and nothing else says so.
    [[ "$output" == *"DRAUGR_PLUGIN_STORE=\"/mnt/c/"* ]]
}

@test "dr-plugin: refuses a library that sbx could never mount" {
    REPO=$(dr_make_win_repo) || skip "no writable Windows drive path"
    cd "$REPO"
    # Under $TMPDIR, that is, the own filesystem of WSL. A real path, but no
    # sandbox workspace can use it.
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
    # A refusal that names what IS known is not a dead end.
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

    # No configuration file: the plugin is in the library, and switched off.
    # Only "installed" is the half of the answer that misleads.
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
    [[ "$output" == *"not connected"* ]]
    [[ "$output" == *"DRAUGR_MOUNTS="* ]]
    [[ "$output" == *"CLAUDE_CODE_PLUGIN_SEED_DIR"* ]]
    # The key for one agent, which nobody guesses. A generic DRAUGR_AGENT_ARGS
    # here also goes to each codex mound.
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
    [[ "$output" == *"all three keys point to this library"* ]]
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

    # Neither one needs a sandbox. A test that lets one start hides a regression
    # that costs a minute for each call.
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
    # A test on the real CLI showed this. update, prune and list all leave an
    # old version directory where it is, and list never names it.
    mkdir -p "$STORE/seed/cache/mkt-a/plug-a/0.9.0"

    run dr-plugin clean
    [ "$status" -eq 0 ]
    [ -d "$STORE/seed/cache/mkt-a/plug-a/1.0.0" ]
    [ ! -d "$STORE/seed/cache/mkt-a/plug-a/0.9.0" ]
}

@test "dr-plugin clean: removes the empty parents an uninstall leaves behind" {
    setup_store || skip "no writable Windows drive path"
    # cache/<marketplace>/<plugin>/ with no version inside it. `claude plugin
    # uninstall` leaves that. It is harmless, but a find in the library then
    # names plugins that are gone.
    mkdir -p "$STORE/seed/cache/ghost-mkt/ghost-plug"

    run dr-plugin clean
    [ "$status" -eq 0 ]
    # Both levels. The empty plugin directory makes its marketplace empty. Thus
    # one pass already went past the parent.
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

    # A plugin with an explicit name. Thus nothing comes from a marketplace that
    # the mock never cloned.
    run dr-plugin add owner/repo plug-b@mkt-b
    [ "$status" -eq 0 ]

    line=$(grep '^create ' "$DR_MOCK_LOG" | tail -1)
    [[ "$line" == *"--name draugr-plugin-build"* ]]
    # The WINDOWS spelling of the build directory, because sbx.exe does not
    # translate paths. And .build, not the library itself. A bad install must
    # not reach the files that the mounds read.
    [[ "$line" == *'\store\.build'* ]]
    [[ "$line" != *'\store\seed '* ]]
}

@test "dr-plugin add: installs through the cache variable, not the seed one" {
    setup_store || skip "no writable Windows drive path"

    run dr-plugin add owner/repo plug-b@mkt-b
    [ "$status" -eq 0 ]

    line=$(grep 'claude plugin install' "$DR_MOCK_LOG" | tail -1)
    # CACHE_DIR is the writable library. SEED_DIR is read-only, and the mounds
    # use it. A mix-up of the two builds nothing and reports success.
    [[ "$line" == *"CLAUDE_CODE_PLUGIN_CACHE_DIR=/home/agent/seed"* ]]
    [[ "$line" != *"SEED_DIR"* ]]
    [[ "$line" == *"install plug-b@mkt-b -y"* ]]
}

@test "dr-plugin add: the work happens in the rootfs, not on the mount" {
    setup_store || skip "no writable Windows drive path"

    run dr-plugin add owner/repo plug-b@mkt-b
    [ "$status" -eq 0 ]
    # A workspace on a Windows drive cannot rename a git clone. A test showed
    # this. `marketplace add` clones to a temporary name, then renames it. Thus
    # the library goes into the rootfs, and later comes back.
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
    # And after a success, the scratch directory is gone. If not, an old half
    # library stays where the next run copies from.
    [ ! -d "$STORE/.build" ]
}

@test "dr-plugin add: rewrites installPath onto the path it will build at" {
    setup_store || skip "no writable Windows drive path"

    run dr-plugin add owner/repo plug-b@mkt-b
    [ "$status" -eq 0 ]
    # The installPath of the fixture points at /somewhere/stale. Each entry
    # records an ABSOLUTE path. Thus a library copied to another place names
    # directories that do not exist until this rewrite.
    run jq -r '.plugins["plug-a@mkt-a"][0].installPath' "$STORE/seed/installed_plugins.json"
    [ "$output" = "/home/agent/seed/cache/mkt-a/plug-a/1.0.0" ]
}

@test "dr-plugin add: takes a marketplace, and registers it before installing" {
    setup_store || skip "no writable Windows drive path"

    run dr-plugin add owner/repo plug-b@mkt-b
    [ "$status" -eq 0 ]
    # The marketplace step is part of add, not a step to do first. The CLI
    # registers the repository before it installs anything from it.
    add_line=$(grep -n 'marketplace add owner/repo' "$DR_MOCK_LOG" | cut -d: -f1 | head -1)
    inst_line=$(grep -n 'plugin install plug-b@mkt-b' "$DR_MOCK_LOG" | cut -d: -f1 | head -1)
    [ -n "$add_line" ]
    [ -n "$inst_line" ]
    [ "$add_line" -lt "$inst_line" ]
}

@test "dr-plugin add: installs every plugin named after the marketplace" {
    setup_store || skip "no writable Windows drive path"

    # The signature is <owner>/<repo>, then any number of plugins. Three places
    # did not agree about this before.
    run dr-plugin add owner/repo one@mkt-b two@mkt-b three@mkt-b
    [ "$status" -eq 0 ]
    [ "$(grep -c 'plugin install one@mkt-b'   "$DR_MOCK_LOG")" -eq 1 ]
    [ "$(grep -c 'plugin install two@mkt-b'   "$DR_MOCK_LOG")" -eq 1 ]
    [ "$(grep -c 'plugin install three@mkt-b' "$DR_MOCK_LOG")" -eq 1 ]

    # And each one is switched on, not only installed.
    for id in one two three; do
        [ "$(jq -r ".enabledPlugins[\"$id@mkt-b\"]" "$STORE/settings.json")" = true ]
    done
}

@test "dr-plugin add: a bare plugin name refuses rather than guessing a marketplace" {
    setup_store || skip "no writable Windows drive path"

    # Two ways to get the name, and neither can give it. The mock registers
    # nothing, so discovery sees nothing new. The fixture of setup_store has no
    # .source.repo, so the registry does not name owner/repo either. A guess
    # installs nothing and reports success.
    run dr-plugin add owner/repo plug-b
    [ "$status" -ne 0 ]
    [[ "$output" == *"cannot tell the marketplace of"* ]]
    [[ "$output" == *"no registered marketplace"* ]]
    [[ "$output" == *"<plugin>@<marketplace>"* ]]
}

# A source that the registry already knows. The fixture of setup_store has no
# .source.repo, on purpose, so the tests that need one add it. The four tests
# below are about a marketplace that is ALREADY registered for the named source.
# A second `dr-plugin add` of the same repo gets that. Before, it was reported
# as a failure, with advice that did not work.
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

    # The state that the old message never gave: installed, at which version,
    # and on which side of the switch.
    [[ "$output" == *"plug-a@mkt-a 1.0.0 disabled"* ]]
    [[ "$output" == *"dr-plugin update <plugin>@mkt-a"* ]]

    # And it must not give the advice that cannot work: a bare <plugin>. The
    # bare-name branch refuses that, because it needs the same name.
    [[ "$output" != *"Name the plugin instead"* ]]
}

@test "dr-plugin add: already registered with nothing installed asks for a plugin" {
    setup_store || skip "no writable Windows drive path"
    register_source owner/repo
    # The marketplace is known, but the library has nothing from it. Thus there
    # is no state to report, only the one id that works.
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

    # Discovery finds nothing, but the registry names the registration of
    # owner/repo. Thus the bare name now completes, and before it refused. The
    # message fix brings this change of behavior.
    run dr-plugin add owner/repo plug-b
    [ "$status" -eq 0 ]
    [ "$(grep -c 'plugin install plug-b@mkt-a' "$DR_MOCK_LOG")" -eq 1 ]
    [ "$(jq -r '.enabledPlugins["plug-b@mkt-a"]' "$STORE/settings.json")" = true ]
}

@test "dr-plugin add: an unregistered source refuses without suggesting a bare plugin" {
    setup_store || skip "no writable Windows drive path"
    register_source owner/other

    # The registry names a marketplace for owner/other, not for owner/repo. Thus
    # neither way can name one here, and the refusal stays.
    run dr-plugin add owner/repo
    [ "$status" -ne 0 ]
    [[ "$output" == *"registered no new marketplace"* ]]
    [[ "$output" == *"No registered marketplace names that source"* ]]
    [[ "$output" != *"Name the plugin instead"* ]]
}

@test "dr-plugin: refuses to start on top of a crashed run's build mound" {
    setup_store || skip "no writable Windows drive path"
    # The mock reports the names in DR_MOCK_NAMES. Thus this is an old build
    # mound, not one that this run created.
    export DR_MOCK_NAMES=draugr-plugin-build

    run dr-plugin add owner/repo plug-b@mkt-b
    [ "$status" -ne 0 ]
    [[ "$output" == *"already exists"* ]]
    [[ "$output" == *"--force"* ]]
}

# --- the skills a plugin ships, and the kit that installs it ------------------

# A skill in the installed plugin. The directory name and the `name:` of the
# front matter are different, on purpose. A test below finds which one is used.
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
    # And the plugin that it came from, because you must install that.
    [[ "$output" == *"plug-a@mkt-a"* ]]
}

@test "dr-plugin skills: the front matter name wins over the directory name" {
    setup_store || skip "no writable Windows drive path"
    make_plugin_skill alpha alpha-skill

    # A substring test cannot tell these apart, because "alpha-skill" contains
    # "alpha". Thus the test compares the full first field.
    run dr-plugin skills
    [ "$(printf '%s\n' "$output" | awk 'NR == 1 {print $1}')" = alpha-skill ]
}

@test "dr-plugin skills: a directory with no SKILL.md is not a skill" {
    setup_store || skip "no writable Windows drive path"
    make_plugin_skill alpha
    mkdir -p "$STORE/seed/cache/mkt-a/plug-a/1.0.0/skills/notaskill"

    # The agent also ignores one, so a report of it makes up a skill.
    run dr-plugin skills
    [ "$status" -eq 0 ]
    [[ "$output" == *"alpha"* ]]
    [[ "$output" != *"notaskill"* ]]
}

@test "dr-plugin skills: a skill under a version that is not installed is ignored" {
    setup_store || skip "no writable Windows drive path"
    # installed_plugins.json says 1.0.0. A skill in the cache under another
    # version is an old copy, and dr-plugin clean removes it. A report of it
    # names a skill that no mound loads.
    mkdir -p "$STORE/seed/cache/mkt-a/plug-a/2.0.0/skills/ghost"
    printf -- '---\nname: ghost\n---\n' \
        > "$STORE/seed/cache/mkt-a/plug-a/2.0.0/skills/ghost/SKILL.md"

    run dr-plugin skills
    [ "$status" -eq 0 ]
    [[ "$output" != *"ghost"* ]]
}

@test "dr-plugin skills: says so when no plugin ships one" {
    setup_store || skip "no writable Windows drive path"
    # Many plugins have only commands or hooks, so this is an answer, not a
    # failure. commit-commands is one of them.
    run dr-plugin skills
    [ "$status" -eq 0 ]
    [[ "$output" == *"no installed plugin has a skill"* ]]
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

    # The seed name must use the spelling of the MOUND, not of the host.
    grep -q 'CLAUDE_CODE_PLUGIN_SEED_DIR=/c/' "$spec"

    # And the version must be absent. You must edit a pinned kit on each
    # dr-plugin update, and an edited kit cannot apply to a running mound. Thus
    # with a pin, each plugin update needs a rebuild of each mound.
    ! grep -q '1\.0\.0' "$spec"
}

@test "dr-plugin kit: refuses a plugin that is not installed" {
    setup_store || skip "no writable Windows drive path"
    export DRAUGR_KIT_STORE="$DR_TMP/kits"

    # A kit can install only what the seed holds. Thus this makes a file whose
    # one job fails in each mound built from it.
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

    # Somebody can edit a library kit by hand after Draugr made it. Thus the
    # second run asks. With no terminal, a question means a refusal.
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

    # The plugin leaves the seed, but the kit stays, and still names it. A mound
    # built from that kit then gets it from the network, or fails. Reported, and
    # NOT deleted. The kit is yours, and you can edit it.
    run dr-plugin remove plug-a@mkt-a
    [[ "$output" == *"still installs plug-a@mkt-a"* ]]
    [ -f "$DRAUGR_KIT_STORE/plugin-plug-a/spec.yaml" ]
}

# --- the build mound's own environment ----------------------------------------

@test "dr-plugin add: redirects github to HTTPS for the plugin CLI" {
    setup_store || skip "no writable Windows drive path"

    # A mound has no SSH key and must not get one. But `claude plugin install`
    # clones a github plugin SOURCE over SSH, with no fallback, as `marketplace
    # add` has. A test on iha2/superlite showed this. The marketplace cloned
    # over HTTPS, and the install then died with "Connection closed by
    # 140.82.121.4 port 22". GitHub refused an SSH client with no
    # authentication. Egress was never the problem.
    run dr-plugin add owner/repo plug-b@mkt-b
    [ "$status" -eq 0 ]
    grep -qF 'GIT_CONFIG_COUNT=2' "$DR_MOCK_LOG"
    grep -qF 'GIT_CONFIG_KEY_0=url.https://github.com/.insteadOf' "$DR_MOCK_LOG"
    grep -qF 'GIT_CONFIG_VALUE_0=git@github.com:' "$DR_MOCK_LOG"

    # Both spellings, because git uses either one, and insteadOf can have many
    # values.
    grep -qF 'GIT_CONFIG_VALUE_1=ssh://git@github.com/' "$DR_MOCK_LOG"
}

@test "dr-plugin add: names each slow step while it is running" {
    setup_store || skip "no writable Windows drive path"

    # Before, three slow steps ran silently: a copy of tens of MB on a Windows
    # drive, a microVM create, and the copy into its rootfs. The command said
    # nothing until the CLI spoke. You did not know which step you waited for.
    run dr-plugin add owner/repo plug-b@mkt-b
    [ "$status" -eq 0 ]
    [[ "$output" == *"copying the library"* ]]
    [[ "$output" == *"creating the build mound"* ]]
    [[ "$output" == *"copying the library into the rootfs"* ]]
}
