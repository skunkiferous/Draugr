"""Run a shell command on a pseudo-terminal, and exit with its status.

    python3 tests/pty_run.py 'dr-go --flag'

dr-go and dr-shell refuse to start without a terminal, so the tests that check
what they send need one. `script -qec <command> /dev/null` is the usual way to
get one, and this replaces it, because a mound has no `script`. That binary
lives in bsdextrautils, which the base image of sbx leaves out, and 32 tests
then failed on a tool that is not even the thing they test. python3 is in the
mound, in CI and in WSL, and CI already installs it by name for
tests/appsandbox_mock.py.

NOT pty.py. Python puts the directory of the script FIRST on sys.path, so a
file with the name of a standard module imports itself:

    AttributeError: partially initialized module 'pty' has no attribute 'fork'

That cost a whole round of debugging, in which the harness looked broken and
the pty was never reached. Any name but pty.py works. Keep this one.

Two differences from `script`, both on purpose:

  * The child gets the pty on all three descriptors, so `[ -t 0 ]` is true, and
    the output of both streams arrives here. script -qec does that too.
  * Nothing is copied from our own stdin. No test types anything, and a parent
    whose stdin is closed or is /dev/null makes a copy loop end the session
    early. A test that needs to send keystrokes needs more than this file.
"""

import os
import pty
import sys


def main():
    if len(sys.argv) != 2:
        sys.stderr.write("usage: pty_run.py <shell command>\n")
        return 2

    pid, master = pty.fork()
    if pid == 0:
        # The child. pty.fork has already made the slave its controlling
        # terminal and its stdin, stdout and stderr.
        os.execvp("bash", ["bash", "-c", sys.argv[1]])

    # Pass the output through, so that a caller can assert on it. Reading the
    # master after the child is gone raises EIO on Linux, which is the normal
    # end of the session and not an error.
    while True:
        try:
            data = os.read(master, 1024)
        except OSError:
            break
        if not data:
            break
        os.write(1, data)

    status = os.waitpid(pid, 0)[1]
    os.close(master)

    # The status of the command, as `script -e` reports it. One test asserts an
    # exact 7, so a status thrown away here is a test that cannot fail.
    if os.WIFSIGNALED(status):
        return 128 + os.WTERMSIG(status)
    return os.WEXITSTATUS(status)


sys.exit(main())
