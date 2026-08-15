#!/usr/bin/env bats
# The documentation, checked against the code rather than against good intentions.
#
# Docs rot silently: nothing fails when a key gains a meaning nobody wrote down,
# or when the README promises a command that was never built. These turn both
# into a red build. They check that things are *mentioned*, which is the most a
# test can do - accuracy still needs a reader.

load helper

setup() {
    dr_test_setup
    dr_load_common
}

teardown() { dr_test_teardown; }

# --- every config key is documented -------------------------------------------

@test "docs: every DRAUGR_* key in DR_KEYS appears in docs/CONFIG.md" {
    local missing=()
    for key in "${DR_KEYS[@]}"; do
        grep -qF "$key" "$DR_ROOT/docs/CONFIG.md" || missing+=("$key")
    done

    if [ ${#missing[@]} -gt 0 ]; then
        printf 'undocumented in docs/CONFIG.md:\n' >&2
        printf '  %s\n' "${missing[@]}" >&2
        return 1
    fi
}

@test "docs: every DRAUGR_* key in DR_KEYS appears in share/config.example" {
    # The example file is what a new user copies and edits, so a key missing
    # there is invisible to exactly the people most likely to need it.
    local missing=()
    for key in "${DR_KEYS[@]}"; do
        grep -qF "$key" "$DR_ROOT/share/config.example" || missing+=("$key")
    done

    if [ ${#missing[@]} -gt 0 ]; then
        printf 'missing from share/config.example:\n' >&2
        printf '  %s\n' "${missing[@]}" >&2
        return 1
    fi
}

@test "docs: config.example invents no key the code does not have" {
    # The other direction: a key that was renamed leaves a plausible-looking
    # setting behind that silently does nothing.
    local key strays=()
    while read -r key; do
        [ -n "$key" ] || continue
        case " ${DR_KEYS[*]} " in
            *" $key "*) ;;
            *) strays+=("$key") ;;
        esac
    done < <(grep -oE '^#?DRAUGR_[A-Z_]+' "$DR_ROOT/share/config.example" \
             | tr -d '#' | sort -u)

    if [ ${#strays[@]} -gt 0 ]; then
        printf 'in share/config.example but not in DR_KEYS:\n' >&2
        printf '  %s\n' "${strays[@]}" >&2
        return 1
    fi
}

# --- every command the docs promise actually exists ---------------------------

# Was advisory while the README described commands that were not written yet.
# The last one, dr-code, shipped in 0.1.0, so it is blocking now: the README is
# the specification, and a specification nobody implemented is a lie.
@test "docs: every dr-* named in the README exists in bin/" {
    local cmd missing=()
    while read -r cmd; do
        [ -n "$cmd" ] || continue
        [ -f "$DR_ROOT/bin/$cmd" ] || missing+=("$cmd")
    done < <(grep -ohE '\bdr-[a-z]+' "$DR_ROOT/README.md" | sort -u)

    if [ ${#missing[@]} -gt 0 ]; then
        printf 'named in README.md but absent from bin/:\n' >&2
        printf '  %s\n' "${missing[@]}" >&2
        return 1
    fi
}

@test "docs: every dr-* named in the user-facing docs exists in bin/" {
    # HACKING.md is excluded deliberately: it is for people writing commands, not
    # using them, and its skeleton template is called dr-thing. Naming a command
    # in a template is not a promise that it exists; naming one in SETUP.md is.
    local cmd missing=()
    while read -r cmd; do
        [ -n "$cmd" ] || continue
        [ -f "$DR_ROOT/bin/$cmd" ] || missing+=("$cmd")
    done < <(grep -ohE '\bdr-[a-z]+' \
                 "$DR_ROOT"/docs/SETUP.md "$DR_ROOT"/docs/WORKFLOW.md \
                 "$DR_ROOT"/docs/CONFIG.md "$DR_ROOT"/docs/SECURITY.md \
                 "$DR_ROOT"/docs/TROUBLESHOOTING.md "$DR_ROOT"/docs/DESIGN.md \
             | sort -u)

    if [ ${#missing[@]} -gt 0 ]; then
        printf 'named in the docs but absent from bin/:\n' >&2
        printf '  %s\n' "${missing[@]}" >&2
        return 1
    fi
}

@test "docs: every command in bin/ is mentioned in the README" {
    # The reverse, so a command cannot ship undocumented. dr is the dispatcher
    # and is described rather than listed as a verb.
    local f cmd missing=()
    for f in "$DR_ROOT"/bin/dr-*; do
        cmd=${f##*/}
        grep -qF "$cmd" "$DR_ROOT/README.md" || missing+=("$cmd")
    done

    if [ ${#missing[@]} -gt 0 ]; then
        printf 'in bin/ but not mentioned in README.md:\n' >&2
        printf '  %s\n' "${missing[@]}" >&2
        return 1
    fi
}

# --- the release itself ---------------------------------------------------------

@test "docs: the CHANGELOG has an entry for the current version" {
    grep -qF "[$DRAUGR_VERSION]" "$DR_ROOT/CHANGELOG.md"
}

@test "docs: no unimplemented-command markers are left in the README" {
    # The hourglass meant "specified but not built". Nothing should carry one
    # once a release is tagged.
    ! grep -q '⏳' "$DR_ROOT/README.md"
}
