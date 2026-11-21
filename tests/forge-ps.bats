#!/usr/bin/env bats
#
# forge-ps.bats: the PREDICATES of the forge PowerShell, executed.
#
# WHY THIS FILE EXISTS, BESIDE THE OTHER TWO. forge.bats greps the scripts for
# strings. forge-api.bats runs whole scripts against a mock daemon, which needs
# python3 and a Windows-visible scratch directory. Between them sit a few small
# functions that decide something, need nothing, and were each wrong in a way
# that no grep can see:
#
#   - "is this sshd keys-only?" was "the offered list has no 'password' in it",
#     which passes a server that offers keyboard-interactive
#   - "what is the state of this VM?" was a boolean, so a daemon that could not
#     be asked answered "it does not run"
#   - "run the script I just copied in" ran a FIXED path with no proof that
#     anything had arrived there
#
# They are pure, so they are tested directly, with a fake Asb where one is
# needed. The whole file skips without a real powershell.exe, the same as
# forge-api.bats: `pwsh` on Linux is a different surface, and these run under
# Windows PowerShell in production.
#
# NO BACKSLASH AND NO DOUBLE QUOTE REACHES powershell.exe FROM HERE. Both are
# eaten on the way from WSL to a native Windows program, and
# `powershell -File <missing>` exits 0, so the loss looks like a pass.
# PowerShell takes C:/x/y everywhere it takes C:\x\y, and its own strings are
# single-quoted here. The snippets are in bash double quotes, with \$ for a
# PowerShell variable, so that bash does not expand it to nothing first.

load helper

setup() {
    dr_test_setup
    # THE REAL powershell.exe, NOT THE MOCK. helper.bash puts tests/mocks first
    # on PATH, and that stub answers every call with a success.
    local clean=${PATH//"$DR_ROOT/tests/mocks:"/}
    DR_REAL_PS=$(PATH="$clean" command -v powershell.exe 2>/dev/null) || true
    [ -n "$DR_REAL_PS" ] || skip "no real powershell.exe - not a Windows host"
    [ "$DR_REAL_PS" != "$DR_ROOT/tests/mocks/powershell.exe" ] || skip "only the mock is on PATH"
    # /mnt/c/Code/Draugr/lib/forge -> C:/Code/Draugr/lib/forge
    PS_FORGE=$(ps_win_slash "$DR_ROOT")/lib/forge
}

teardown() { dr_test_teardown; }

# /mnt/<d>/x -> <D>:/x. dr_path_win gives backslashes, which is right for sbx
# and wrong for anything that crosses this boundary.
ps_win_slash() {
    local p=$1 drive
    case "$p" in /mnt/[A-Za-z]/*|/mnt/[A-Za-z]) : ;; *) return 1 ;; esac
    drive=$(printf '%s' "${p:5:1}" | tr '[:lower:]' '[:upper:]')
    printf '%s:%s' "$drive" "${p:6}"
}

# Dot-source one file of lib/forge, then run the snippet. The snippet decides
# the exit code itself, so each test asserts a status and not a word.
#
# THE CRs GO, AND NOT THROUGH A PIPE. Write-Output ends a line with CRLF, and a
# test that compares the whole line then fails against an expectation that looks
# character for character the same - the CR is invisible in the failure message.
# But `powershell | tr` would report the status of tr, which is always 0, and
# every test here asserts the status. So: capture, keep the status, then strip.
# forge-api.bats has the same two lines for the same two reasons.
ps_with() {
    local leaf=$1 snippet=$2 out status=0
    out=$("$DR_REAL_PS" -NoProfile -ExecutionPolicy Bypass \
            -Command ". '$PS_FORGE/$leaf'; $snippet" 2>&1) || status=$?
    printf '%s\n' "$out" | tr -d '\r'
    return "$status"
}

# --- sshauth.ps1: keys only means publickey -----------------------------------------------

@test "Test-KeysOnlyList: publickey alone is keys-only" {
    run ps_with sshauth.ps1 "if (Test-KeysOnlyList 'publickey') { exit 0 }; exit 9"
    [ "$status" -eq 0 ]
}

@test "Test-KeysOnlyList: a password method is not" {
    run ps_with sshauth.ps1 "if (Test-KeysOnlyList 'publickey,password') { exit 9 }; exit 0"
    [ "$status" -eq 0 ]
}

# THE DEFECT. The test was `-notmatch 'password'`, and this string has no
# "password" in it. On Windows sshd, keyboard-interactive is the interactive
# path, and that is where a password prompt comes back.
@test "Test-KeysOnlyList: keyboard-interactive is not keys-only either" {
    run ps_with sshauth.ps1 "if (Test-KeysOnlyList 'publickey,keyboard-interactive') { exit 9 }; exit 0"
    [ "$status" -eq 0 ]
}

# During an sshd restart the connection is refused and NOTHING is offered. That
# is the moment this phase exists to survive: an empty list is not evidence.
@test "Test-KeysOnlyList: an empty list is not evidence of anything" {
    run ps_with sshauth.ps1 "if (Test-KeysOnlyList '') { exit 9 }; exit 0"
    [ "$status" -eq 0 ]
}

@test "Test-KeysOnlyList: a method it does not know is not keys-only" {
    run ps_with sshauth.ps1 "if (Test-KeysOnlyList 'publickey,gssapi-with-mic') { exit 9 }; exit 0"
    [ "$status" -eq 0 ]
}

# --- guestexec.ps1: the guest proves the file is there ------------------------------------

# `powershell -File <missing>` exits 0 and writes its complaint to stderr, so
# the cmd.exe wrapper is the whole guard. 127 is the code for "not found", and
# no guest script uses it.
@test "Get-GuestRunCommand: the guest's own cmd.exe decides, with 127 for a missing file" {
    run ps_with guestexec.ps1 "Write-Output (Get-GuestRunCommand 'C:/Windows/Temp/x.ps1')"
    [ "$status" -eq 0 ]
    [[ "$output" == "if exist C:/Windows/Temp/x.ps1 "* ]]
    [[ "$output" == *"else (exit /b 127)"* ]]
}

# AND THE PATH IS NOT QUOTED. Plain quotes are lost on the way to the guest, and
# they take the backslashes of the path with them: `-File "C:\Windows\Temp\x"`
# arrived as `C:WindowsTempx`. A test on a live guest showed it, and it turned
# fourteen phases that never ran into fourteen green rows.
@test "Get-GuestRunCommand: the path is not quoted" {
    run ps_with guestexec.ps1 "Write-Output (Get-GuestRunCommand 'C:/Windows/Temp/x.ps1' '-A 1')"
    [ "$status" -eq 0 ]
    [[ "$output" == *"-File C:/Windows/Temp/x.ps1 -A 1"* ]]
    [[ "$output" != *"-File \"C:"* ]]
    [[ "$output" != *"-File 'C:"* ]]
}

# --- guestexec.ps1: the directory a run owns ----------------------------------------------

@test "New-GuestRunDir: a new directory every time" {
    run ps_with guestexec.ps1 \
        "\$a = New-GuestRunDir; \$b = New-GuestRunDir; if (\$a.Name -eq \$b.Name) { exit 9 }; if (-not \$a.Name.StartsWith('draugr-')) { exit 8 }; exit 0"
    [ "$status" -eq 0 ]
}

# TWO SPELLINGS OF ONE PATH. cmd.exe and every -File / -PubKeyFile argument need
# backslashes; the destination of scp needs forward slashes, because it splits
# on ':' and the backslashes do not survive. [char]92 and [char]47 are used
# instead of the characters themselves, because a literal backslash does not
# survive the crossing from here to powershell.exe either - which is the same
# trap, one level out.
@test "New-GuestRunDir: two spellings, and only the cmd one has backslashes" {
    run ps_with guestexec.ps1 \
        "\$d = New-GuestRunDir; if (-not \$d.Win.Contains([char]92)) { exit 9 }; if (\$d.Scp.Contains([char]92)) { exit 8 }; if (\$d.Scp -ne \$d.Win.Replace([char]92, [char]47)) { exit 7 }; if (-not \$d.Win.EndsWith(\$d.Name)) { exit 6 }; exit 0"
    [ "$status" -eq 0 ]
}

# `mkdir` alone fails when the directory is there, and that failure would be the
# status the caller reads. And the path is unquoted, for the same measured
# reason as the -File path above.
@test "Get-GuestMkdirCommand: only when absent, and the path is not quoted" {
    run ps_with guestexec.ps1 "Write-Output (Get-GuestMkdirCommand 'C:/Windows/Temp/draugr-x')"
    [ "$status" -eq 0 ]
    [ "$output" = "if not exist C:/Windows/Temp/draugr-x mkdir C:/Windows/Temp/draugr-x" ]
}

# The whole directory. The list of fixed names it replaces was a second place to
# remember, and a file added to the copies and forgotten here stayed in the
# guest - including a public key.
@test "Get-GuestRmdirCommand: the directory, not a list of names" {
    run ps_with guestexec.ps1 "Write-Output (Get-GuestRmdirCommand 'C:/Windows/Temp/draugr-x')"
    [ "$status" -eq 0 ]
    [[ "$output" == "if exist "* ]]
    [[ "$output" == *"rmdir /s /q C:/Windows/Temp/draugr-x"* ]]
}

# --- vmstate.ps1: four answers, and only one of them is "it is gone" ----------------------

@test "Get-ForgeVmState: a running VM" {
    run ps_with vmstate.ps1 \
        "function Asb(\$m,\$p){ @{ running = \$true } }; if ((Get-ForgeVmState 'x') -eq 'running') { exit 0 }; exit 9"
    [ "$status" -eq 0 ]
}

@test "Get-ForgeVmState: a stopped VM" {
    run ps_with vmstate.ps1 \
        "function Asb(\$m,\$p){ @{ running = \$false } }; if ((Get-ForgeVmState 'x') -eq 'stopped') { exit 0 }; exit 9"
    [ "$status" -eq 0 ]
}

# THE ONE THAT USED TO READ AS "IT DOES NOT RUN". A failure with no HTTP status
# at all is what a dead daemon, a timeout and a refused connection look like.
@test "Get-ForgeVmState: a call that failed is unknown, not stopped" {
    run ps_with vmstate.ps1 \
        "function Asb(\$m,\$p){ throw 'boom' }; if ((Get-ForgeVmState 'x') -eq 'unknown') { exit 0 }; exit 9"
    [ "$status" -eq 0 ]
}

# A 200 in a shape this code does not know is not a stopped VM either. The old
# [bool]$r.running made it one.
@test "Get-ForgeVmState: an answer without the running field is unknown" {
    run ps_with vmstate.ps1 \
        "function Asb(\$m,\$p){ @{ state = 'something' } }; if ((Get-ForgeVmState 'x') -eq 'unknown') { exit 0 }; exit 9"
    [ "$status" -eq 0 ]
}

# The wait is where the two-answer version did its damage: it returned TRUE on a
# timeout, so the callers that freeze a disk and delete a VM believed a stop
# that nobody had seen.
@test "Wait-ForgeVmState: a wait that never got an answer ends in unknown" {
    run ps_with vmstate.ps1 \
        "function Asb(\$m,\$p){ throw 'boom' }; \$s = Wait-ForgeVmState 'x' @('stopped','absent') 1 1; if (\$s -eq 'unknown') { exit 0 }; exit 9"
    [ "$status" -eq 0 ]
}

@test "Test-ForgeVmDown: stopped and absent are down, unknown and running are not" {
    run ps_with vmstate.ps1 \
        "if ((Test-ForgeVmDown 'stopped') -and (Test-ForgeVmDown 'absent') -and -not (Test-ForgeVmDown 'unknown') -and -not (Test-ForgeVmDown 'running')) { exit 0 }; exit 9"
    [ "$status" -eq 0 ]
}

# --- layerpath.ps1: a name that `drop` may turn into a path -------------------------------
#
# `dr-layer drop` removes a directory recursively, elevated, and -Name was a
# bare [string]. `..\..\x` left the layer store and `.` selected the root.

@test "Test-LayerName: the names of the real layers are names" {
    run ps_with layerpath.ps1 \
        "if ((Test-LayerName 'layer-0') -and (Test-LayerName 'layer-3-unreal') -and (Test-LayerName 'base_1.2')) { exit 0 }; exit 9"
    [ "$status" -eq 0 ]
}

@test "Test-LayerName: a traversal is not a name" {
    run ps_with layerpath.ps1 \
        "if ((Test-LayerName '..') -or (Test-LayerName '.') -or (Test-LayerName '..\\..\\windows')) { exit 9 }; exit 0"
    [ "$status" -eq 0 ]
}

@test "Test-LayerName: a separator, a drive or a stream is not a name" {
    run ps_with layerpath.ps1 \
        "if ((Test-LayerName 'a/b') -or (Test-LayerName 'a\\b') -or (Test-LayerName 'C:') -or (Test-LayerName 'x:stream')) { exit 9 }; exit 0"
    [ "$status" -eq 0 ]
}

@test "Test-LayerName: an option, an empty string and a trailing dot are not names" {
    run ps_with layerpath.ps1 \
        "if ((Test-LayerName '-Recurse') -or (Test-LayerName '') -or (Test-LayerName 'layer-0.') -or (Test-LayerName '.hidden')) { exit 9 }; exit 0"
    [ "$status" -eq 0 ]
}

@test "Test-UnderRoot: a layer directory is under its root" {
    run ps_with layerpath.ps1 \
        "if (Test-UnderRoot 'C:/ForgeLayers/layer-0' 'C:/ForgeLayers') { exit 0 }; exit 9"
    [ "$status" -eq 0 ]
}

# The one that mattered: the root is not inside itself, so nothing can delete
# the whole store by naming it.
@test "Test-UnderRoot: the root itself is not under the root" {
    run ps_with layerpath.ps1 \
        "if ((Test-UnderRoot 'C:/ForgeLayers' 'C:/ForgeLayers') -or (Test-UnderRoot 'C:/ForgeLayers/' 'C:/ForgeLayers')) { exit 9 }; exit 0"
    [ "$status" -eq 0 ]
}

@test "Test-UnderRoot: a path that climbs out is not under the root" {
    run ps_with layerpath.ps1 \
        "if ((Test-UnderRoot 'C:/ForgeLayers/../Windows' 'C:/ForgeLayers') -or (Test-UnderRoot 'C:/ForgeLayersEvil/x' 'C:/ForgeLayers')) { exit 9 }; exit 0"
    [ "$status" -eq 0 ]
}

# A junction has an ordinary name and another destination, and a recursive
# delete follows it. GetFullPath cannot see one, so the walk asks each level.
@test "Test-UnderRoot: a junction inside the root is not under the root" {
    # A real directory on a real Windows drive: $DR_TMP is on the ext4 of WSL,
    # which has no Windows path and no junctions. The same scratch name that
    # dr_test_teardown removes.
    local wroot base root
    wroot=$(dr_win_root) || skip "no writable Windows drive path"
    base="$wroot/draugr-test.${DR_TMP##*/}"
    mkdir -p "$base/fixtureroot/real" "$base/elsewhere" || skip "cannot write to $wroot"
    root=$(ps_win_slash "$base")/fixtureroot

    run ps_with layerpath.ps1 \
        "New-Item -ItemType Junction -Path '$root/away' -Target '$(ps_win_slash "$base")/elsewhere' > \$null; if (Test-UnderRoot '$root/away' '$root') { exit 9 }; exit 0"
    [ "$status" -eq 0 ]
    # And the plain directory beside it still answers yes, so the walk refuses
    # the link and not the root.
    run ps_with layerpath.ps1 "if (Test-UnderRoot '$root/real' '$root') { exit 0 }; exit 9"
    [ "$status" -eq 0 ]
}
