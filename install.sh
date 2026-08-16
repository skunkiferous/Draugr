#!/usr/bin/env bash
# install.sh - put the dr-* commands on your PATH. Idempotent; prints what it did.
#
#   ./install.sh              symlink into ~/.local/bin
#   ./install.sh --path       append this repo's bin/ to ~/.bashrc instead
#   ./install.sh --uninstall  remove the symlinks

# The three safety flags every script here starts with:
#   -e           stop at the first command that fails, instead of blundering on
#   -u           treat an unset variable as an error, so a typo'd $nmae is caught
#   -o pipefail  a pipeline fails if ANY stage failed, not just the last one
# Without -o pipefail, `false | true` would be considered a success.
set -euo pipefail

# Where this script lives, as an absolute path.
#
# $BASH_SOURCE[0] is this file's path as it was invoked - unlike $0 it stays
# correct even when a script is sourced rather than run. `dirname` strips the
# filename, and the `cd ... && pwd` round-trip turns whatever relative or
# symlinked form we were given into one canonical absolute path. So this works
# the same whether you typed ./install.sh, ~/draugr/install.sh, or ran it from
# a symlink two directories away.
root=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# ${VAR:-default} means "use $VAR, or this default if it is unset or empty".
# So DRAUGR_BINDIR=/somewhere ./install.sh overrides the destination.
bindir=${DRAUGR_BINDIR:-$HOME/.local/bin}
mode=symlink

# --- parse the command line -------------------------------------------------
#
# The standard shell argument loop: while there are arguments left ($# is the
# count), look at the first one ($1), then `shift` to drop it and move the rest
# down. An option that takes a value shifts twice - once here, once at the
# bottom of the loop.
while [ $# -gt 0 ]; do
    case "$1" in
        --path)      mode=path ;;
        --uninstall) mode=uninstall ;;
        --prefix)    bindir=$2; shift ;;   # consume the value too

        # Print the usage block at the top of this file rather than keeping a
        # second copy in sync with it: skip the shebang, print comment lines,
        # stop at the first line that is not one, and strip the leading "# ".
        #
        # This is dr_help from lib/common.sh, inlined. The installer is the one
        # script that cannot source the library - it runs before anything is
        # installed - and a hand-counted line range is what this replaced
        # everywhere else, after it silently went stale in 17 of 27 commands.
        -h|--help)
            awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
            exit 0 ;;

        # >&2 sends this to stderr, so it still shows up when stdout is piped.
        *) printf 'install.sh: unknown option %s\n' "$1" >&2; exit 1 ;;
    esac
    shift
done

# --- find the commands to install -------------------------------------------
#
# Build an array of bare command names ("dr", "dr-doctor", ...) by globbing
# bin/ and stripping each path down to its last component.
#
#   commands=()          declares an empty array
#   commands+=( x )      appends one element
#   ${_c##*/}            deletes the longest prefix ending in "/", i.e. basename
#
# A glob is used rather than `ls` because it copes with spaces in the path, and
# because if bin/ were empty the loop body simply never runs.
commands=()
for _c in "$root"/bin/*; do
    [ -f "$_c" ] && commands+=("${_c##*/}")
done

# ${#commands[@]} is the number of elements. If the glob matched nothing we
# would otherwise "successfully" install zero commands and say so cheerfully.
[ ${#commands[@]} -gt 0 ] || { printf 'install.sh: no commands found in %s/bin\n' "$root" >&2; exit 1; }

case "$mode" in

# --- uninstall --------------------------------------------------------------
uninstall)
    removed=0
    for c in "${commands[@]}"; do
        link="$bindir/$c"
        # Only remove links that are OURS: -L tests "is a symlink", and readlink
        # prints where it points. A file someone else put at that name, or a
        # symlink to a different Draugr checkout, is left strictly alone.
        if [ -L "$link" ] && [ "$(readlink "$link")" = "$root/bin/$c" ]; then
            rm -f "$link"
            removed=$((removed + 1))    # $(( )) is arithmetic
        fi
    done
    printf 'Removed %d symlink(s) from %s\n' "$removed" "$bindir"
    ;;

# --- PATH mode: edit ~/.bashrc instead of making symlinks -------------------
path)
    # Note the escaping: "$root" expands NOW (we want the real path baked in),
    # but \$PATH stays literal so it is expanded later, by the user's shell.
    line="export PATH=\"$root/bin:\$PATH\""

    # grep -q = quiet (say nothing, just set the exit status)
    #      -x = the whole line must match, not just part of it
    #      -F = treat the pattern as a fixed string, not a regex
    # Without -F, the $ and " in $line would be interpreted as regex syntax.
    if grep -qxF "$line" "$HOME/.bashrc" 2>/dev/null; then
        printf 'Already on PATH via ~/.bashrc - nothing to do.\n'
    else
        printf '\n# Draugr\n%s\n' "$line" >> "$HOME/.bashrc"
        printf 'Appended to ~/.bashrc:\n  %s\n\nRun:  exec bash\n' "$line"
    fi
    ;;

# --- symlink mode (the default) ---------------------------------------------
symlink)
    mkdir -p "$bindir"
    linked=0
    skipped=0

    for c in "${commands[@]}"; do
        # The repo lives on /mnt/c, whose filesystem does not carry a real
        # executable bit through git on Windows. Set it here so a fresh clone
        # works without the user having to know that.
        chmod +x "$root/bin/$c"

        link="$bindir/$c"

        # Already pointing where we want: nothing to do, and say so honestly
        # rather than reporting a link we did not make.
        if [ -L "$link" ] && [ "$(readlink "$link")" = "$root/bin/$c" ]; then
            skipped=$((skipped + 1))
            continue
        fi

        # Something is in the way that is not a symlink at all - a real file the
        # user put there. Refuse to touch it. -e is "exists", -L is "is a
        # symlink", so this means "exists AND is not a symlink".
        if [ -e "$link" ] && [ ! -L "$link" ]; then
            printf 'install.sh: %s exists and is not our symlink - leaving it alone\n' "$link" >&2
            continue
        fi

        # -s symbolic, -f replace an existing link, -n do not follow a link to a
        # directory (without -n, ln would create the link *inside* it).
        ln -sfn "$root/bin/$c" "$link"
        linked=$((linked + 1))
    done

    printf 'Linked %d command(s) into %s (%d already current).\n' "$linked" "$bindir" "$skipped"

    # Is $bindir actually on the PATH? The colons are the trick: wrapping both
    # the haystack and the needle in ":" means "/opt/bin" cannot accidentally
    # match inside "/opt/bin-other", because we search for ":/opt/bin:".
    #
    # The shellcheck directive below sits on the `case` rather than on the
    # branch, because shellcheck only accepts directives before whole commands.
    # It silences the (correct, but here intentional) complaint that $PATH in
    # single quotes will not expand: that text is advice for the user to type,
    # so it must reach them literally.
    # shellcheck disable=SC2016
    case ":$PATH:" in
        *":$bindir:"*) ;;   # already there, nothing to say
        # The '\'' dance is how you get a literal single quote inside a
        # single-quoted string: close the quote, escape one, reopen.
        *) printf '\n%s is not on your PATH. Add it:\n  echo '\''export PATH="%s:$PATH"'\'' >> ~/.bashrc && exec bash\n' \
               "$bindir" "$bindir" ;;
    esac

    printf '\nNext:  dr doctor\n'
    ;;
esac
