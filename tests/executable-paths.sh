#!/usr/bin/env bash
# Each file in this repository that something else executes by path. One on each
# line, absolute.
#
# It is a script, not a list in one consumer, because there are two consumers,
# and they must stay the same. tests/repo.bats fails a build when one of these
# is not executable. .githooks/pre-commit fixes it before the commit exists. The
# hook cannot enforce a list that is only in the test.
#
# The rule for the list is "something runs this by path, or finds it on PATH":
#
#   bin/dr*              the commands, run by you and by each other
#   install.sh           run by the person who installs this
#   tests/mocks/*        the code under test finds them on PATH (see below)
#   tests/*.sh           the standalone checks that CI calls directly
#   .githooks/*          git silently SKIPS a hook that is not executable
#   share/.../ollama-proxy   shipped to run. Named, not globbed, because share/
#                            is mostly examples that must not be executable
#
#
# Mocks are more important than they look. Code finds them on PATH, and does not
# call them by path. A PATH lookup SKIPS a file that is not executable, and goes
# on down the list. Thus a mock at mode 100644 does not fail with "permission
# denied". It silently becomes the REAL tool, on a machine that must talk to a
# stand-in. That is how ten commits shipped with a tests/mocks/ssh that was not
# executable, and the attach tests silently contacted a real ssh.
set -euo pipefail

_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

# Globs are expanded here, not listed. Thus a new command or a new mock is in
# the list as soon as it exists. That is the purpose, because people always
# forget the new file.
printf '%s\n' "$_root"/bin/dr* \
              "$_root/install.sh" \
              "$_root"/tests/mocks/* \
              "$_root"/tests/*.sh \
              "$_root"/.githooks/* \
              "$_root"/share/ollama-proxy/ollama-proxy
