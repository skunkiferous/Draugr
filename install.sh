#!/usr/bin/env bash
# install.sh: put the dr-* commands on your PATH. Safe to run twice. Prints what
# it did.
#
#   ./install.sh              symlink into ~/.local/bin
#   ./install.sh --path       append the bin/ of this repo to ~/.bashrc, with no symlinks
#   ./install.sh --uninstall  remove the symlinks

# The three safety flags at the start of each script here:
#   -e           stop at the first command that fails, and do not continue
#   -u           an unset variable is an error, so a typo such as $nmae is caught
#   -o pipefail  a pipeline fails if ANY stage failed, not only the last one
# Without -o pipefail, `false | true` is a success.
set -euo pipefail

# The location of this script, as an absolute path.
#
# $BASH_SOURCE[0] is the path of this file, as it was called. It stays correct
# also when a script is sourced and not run. $0 does not. `dirname` removes the
# filename. The `cd ... && pwd` round trip makes each relative or symlinked form
# into one canonical absolute path. Thus it works the same for ./install.sh,
# for ~/draugr/install.sh, or from a symlink two directories away.
root=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# ${VAR:-default} means "use $VAR. If it is unset or empty, use this default".
# Thus DRAUGR_BINDIR=/somewhere ./install.sh overrides the destination.
bindir=${DRAUGR_BINDIR:-$HOME/.local/bin}
mode=symlink

# --- parse the command line -------------------------------------------------
#
# The standard shell argument loop. While arguments are left ($# is the count),
# look at the first one ($1). Then `shift` drops it, and moves the rest down. An
# option with a value shifts twice: once here, and once at the bottom of the
# loop.
while [ $# -gt 0 ]; do
    case "$1" in
        --path)      mode=path ;;
        --uninstall) mode=uninstall ;;
        --prefix)    bindir=$2; shift ;;   # consume the value too

        # Print the usage block at the top of this file. Do not keep a second
        # copy. Skip the shebang, and print the comment lines. Stop at the first
        # line that is not a comment, and remove the leading "# ".
        #
        # This is dr_help from lib/common.sh, inlined. The installer is the one
        # script that cannot source the library, because it runs before the
        # install. In all other places, this replaced a line range counted by
        # hand. That range silently became wrong in 17 of 27 commands.
        -h|--help)
            awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
            exit 0 ;;

        # >&2 sends this to stderr, so that it still shows with a piped stdout.
        *) printf 'install.sh: unknown option %s\n' "$1" >&2; exit 1 ;;
    esac
    shift
done

# --- find the commands to install -------------------------------------------
#
# Build an array of bare command names ("dr", "dr-doctor", ...). A glob on bin/
# finds them, and each path is cut to its last component.
#
#   commands=()          declares an empty array
#   commands+=( x )      appends one element
#   ${_c##*/}            deletes the longest prefix ending in "/" (the basename)
#
# A glob, not `ls`, because it works with spaces in the path. Also, if bin/ is
# empty, the loop body never runs.
commands=()
for _c in "$root"/bin/*; do
    [ -f "$_c" ] && commands+=("${_c##*/}")
done

# ${#commands[@]} is the number of elements. If the glob found nothing, this
# stops. Without it, the script installs zero commands, and reports a success.
[ ${#commands[@]} -gt 0 ] || { printf 'install.sh: no commands found in %s/bin\n' "$root" >&2; exit 1; }

case "$mode" in

# --- uninstall --------------------------------------------------------------
uninstall)
    removed=0
    for c in "${commands[@]}"; do
        link="$bindir/$c"
        # Remove only links that are OURS. -L tests "is a symlink", and readlink
        # prints its target. This does not touch a file that somebody else put
        # at that name, or a symlink to a different Draugr checkout.
        if [ -L "$link" ] && [ "$(readlink "$link")" = "$root/bin/$c" ]; then
            rm -f "$link"
            removed=$((removed + 1))    # $(( )) is arithmetic
        fi
    done
    printf 'Removed %d symlink(s) from %s\n' "$removed" "$bindir"
    ;;

# --- PATH mode: edit ~/.bashrc instead of making symlinks -------------------
path)
    # See the escapes. "$root" expands NOW, so that the line has the real path.
    # \$PATH stays literal, so that the shell of the user expands it later.
    line="export PATH=\"$root/bin:\$PATH\""

    # grep -q = quiet (say nothing, only set the exit status)
    #      -x = the whole line must match, not only a part of it
    #      -F = the pattern is a fixed string, not a regex
    # Without -F, the $ and " in $line are regex syntax.
    if grep -qxF "$line" "$HOME/.bashrc" 2>/dev/null; then
        printf 'Already on PATH through ~/.bashrc. Nothing to do.\n'
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
        # The repo is on /mnt/c. On Windows, git does not carry a real
        # executable bit on that filesystem. Set it here, so that a new clone
        # works, and the user does not need to know this.
        chmod +x "$root/bin/$c"

        link="$bindir/$c"

        # It already points to the correct place. Nothing to do. Say so, and do
        # not report a link that this script did not make.
        if [ -L "$link" ] && [ "$(readlink "$link")" = "$root/bin/$c" ]; then
            skipped=$((skipped + 1))
            continue
        fi

        # Something that is not a symlink is in the way: a real file that the
        # user put there. Do not touch it. -e is "exists", and -L is "is a
        # symlink". Thus this means "exists AND is not a symlink".
        if [ -e "$link" ] && [ ! -L "$link" ]; then
            printf 'install.sh: %s exists and is not our symlink. Not touching it\n' "$link" >&2
            continue
        fi

        # -s symbolic, -f replace an existing link, -n do not follow a link to a
        # directory (without -n, ln creates the link *inside* it).
        ln -sfn "$root/bin/$c" "$link"
        linked=$((linked + 1))
    done

    printf 'Linked %d command(s) into %s (%d already current).\n' "$linked" "$bindir" "$skipped"

    # Is $bindir really on the PATH? The colons are the trick. With ":" around
    # both the haystack and the needle, "/opt/bin" cannot match by accident in
    # "/opt/bin-other", because the search is for ":/opt/bin:".
    #
    # The shellcheck directive below is on the `case`, not on the branch,
    # because shellcheck accepts directives only before whole commands. It
    # silences the complaint that $PATH in single quotes does not expand. That
    # is correct, but here it is on purpose. The text is advice for the user to
    # type, so it must reach them literally.
    # shellcheck disable=SC2016
    case ":$PATH:" in
        *":$bindir:"*) ;;   # already there, nothing to say
        # The '\'' sequence puts a literal single quote in a single-quoted
        # string: close the quote, escape one, open again.
        *) printf '\n%s is not on your PATH. Add it:\n  echo '\''export PATH="%s:$PATH"'\'' >> ~/.bashrc && exec bash\n' \
               "$bindir" "$bindir" ;;
    esac

    printf '\nNext:  dr doctor\n'
    ;;
esac
