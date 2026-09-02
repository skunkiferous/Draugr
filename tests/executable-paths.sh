#!/usr/bin/env bash
# Every file in this repository that something else executes by path, one per
# line, absolute.
#
# It is a script rather than a list in one consumer because there are two, and
# they must not drift: tests/repo.bats fails a build when one of these is not
# executable, and .githooks/pre-commit fixes it before the commit exists. A list
# kept in the test alone is a list the hook cannot enforce.
#
# The membership rule is "something runs this by path or finds it on PATH":
#
#   bin/dr*              the commands, run by you and by each other
#   install.sh           run by whoever installs this
#   tests/mocks/*        found on PATH by the code under test - see below
#   tests/*.sh           the standalone checks CI invokes directly
#   .githooks/*          git SKIPS a hook that is not executable, silently
#   share/.../ollama-proxy   shipped to be run; named rather than globbed,
#                            because share/ is mostly examples that must not be
#
#
# Mocks matter more than they look. They are found on PATH rather than called by
# path, and PATH lookup SKIPS a file that is not executable and carries on down
# the list. So a mock at mode 100644 does not fail with "permission denied" - it
# silently resolves to the REAL tool, on a machine that was supposed to be
# talking to a stand-in. That is how ten commits shipped with tests/mocks/ssh
# non-executable and the attach tests quietly contacting a real ssh.
set -euo pipefail

_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

# Globs are expanded here rather than listed, so a new command or a new mock is
# covered the moment it exists - which is the whole point, since the file that
# gets forgotten is always the new one.
printf '%s\n' "$_root"/bin/dr* \
              "$_root/install.sh" \
              "$_root"/tests/mocks/* \
              "$_root"/tests/*.sh \
              "$_root"/.githooks/* \
              "$_root"/share/ollama-proxy/ollama-proxy
