# guestexec.ps1: the one way to put a file into the guest and run it.
#
# WHY THIS FILE EXISTS. Three scripts carried their own version of this line,
# and one of them was wrong. provision.ps1 and vm.ps1 wrapped the run in
# cmd.exe with `if exist … else (exit /b 127)`; init.ps1 called
# `powershell -File <path>` directly. The difference is not cosmetic:
#
#   `powershell -File <missing>` EXITS ZERO. It writes "The argument '...' to
#   the -File parameter does not exist" to stderr and returns 0. A test on a
#   live guest showed this through exactly this pipeline, and it turned a copy
#   that never arrived into fourteen green phase rows. Real codes do pass
#   through: a guest script that exits 4 arrives as 4.
#
# Thus the own cmd.exe of the guest decides whether the file is there, and a
# missing file gets a code of its own. 127 is the shell convention for "not
# found", and no guest script in lib/forge/guest uses it.
#
# AND THE PATH IS NOT QUOTED, ON PURPOSE. Plain double quotes around it are
# lost on the way, and they take the BACKSLASHES of the path with them. The
# same three forms, tested on the same guest:
#
#                      from Windows PowerShell | from WSL -> powershell.exe
#    -File "$remote"              intact       |   C:WindowsTempx.ps1   <- eaten
#    -File \"$remote\"            intact       |   intact
#    -File $remote                intact       |   intact
#
# The remote path has no space, so the bare form is the correct one here. An
# argument VALUE with a space needs the escaped quotes instead; see
# Format-GuestArg in provision.ps1.
#
# WHAT `if exist` CANNOT DO ON ITS OWN: tell this file from a stale one. It
# answers "is something there", never "is the right thing there". That used to
# matter, because the destination was FIXED — every run of every VM used
# C:\Windows\Temp\<name> — so a copy that failed left whatever an earlier run
# had put there, and the test below was just as happy with that file as with a
# fresh one. It would run it and report its result as this run's.
#
# NOW EACH RUN OWNS A DIRECTORY, and that removes the question instead of
# guarding it. See New-GuestRunDir below. The directory is created empty at the
# start of the run, so nothing from any other run can be in it, and `if exist`
# on a path inside it is a true answer to "did my copy arrive".
#
# The callers still check their own scp status, and should: it is the earliest
# and clearest place to say "the copy failed". But a forgotten check is no
# longer a stale file running under a name that looks right. init.ps1 forgot it
# in four places, and that is how a .pub from an earlier run could be
# authorized while the phase reported success.
function Get-GuestRunCommand([string]$Remote, [string]$ScriptArgs = '') {
    return ("if exist $Remote " +
            "(powershell -NoProfile -ExecutionPolicy Bypass -File $Remote $ScriptArgs) " +
            'else (exit /b 127)')
}

# --- the directory this run owns in the guest ---------------------------------------------
#
# TWO SPELLINGS OF ONE PATH, and both are needed. cmd.exe, `-File` and every
# `-PubKeyFile` argument want backslashes. The destination of scp wants forward
# slashes: it splits on `:` and the backslashes do not survive the crossing.
# One repository already has three names for the same reason (lib/common.sh,
# "One repository has three names"), and mixing them up causes the same class
# of bug here.
#
# A DIRECTORY, NOT A RANDOM NAME FOR EACH FILE. The cleanup is then one
# `rmdir /s /q` that cannot fall out of step with the copies - the list of
# fixed names in init.ps1 had to be kept in sync by hand, and a file it forgot
# stayed in the guest. The files keep their own basenames inside it, so an
# error still says `install-msys2.ps1` and not a random string.
#
# The name is a GUID, not a pid or a timestamp: two runs can share a pid after
# a reboot, and a timestamp collides at one-second resolution. 12 hex digits
# are enough for a directory in Temp, and keep the path short for the four
# parsers it goes through.
function New-GuestRunDir() {
    $n = "draugr-$([guid]::NewGuid().ToString('N').Substring(0, 12))"
    return @{
        Name = $n
        Win  = "C:\Windows\Temp\$n"
        Scp  = "C:/Windows/Temp/$n"
    }
}

# `mkdir` alone fails when the directory is there, and that failure would be
# the status the caller reads. scp does not create a destination directory, so
# this must run before the first copy.
function Get-GuestMkdirCommand([string]$Dir) {
    return "if not exist $Dir mkdir $Dir"
}

# The whole directory, with what is in it. NOT a list of names: the point of
# the directory is that nobody has to keep one.
function Get-GuestRmdirCommand([string]$Dir) {
    return "if exist $Dir rmdir /s /q $Dir"
}
