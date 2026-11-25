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
#   - "what is the state of this VM?" was a boolean, so a daemon that was not able to
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
# character for character the same, and the CR is invisible in the failure message.
# But `powershell | tr` reports the status of tr, which is always 0, and
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
# backslashes. The destination of scp needs forward slashes, because it splits
# on ':' and the backslashes do not survive. [char]92 and [char]47 are used
# instead of the characters themselves, because a literal backslash does not
# survive the crossing from here to powershell.exe either. This is the same
# trap, one level out.
@test "New-GuestRunDir: two spellings, and only the cmd one has backslashes" {
    run ps_with guestexec.ps1 \
        "\$d = New-GuestRunDir; if (-not \$d.Win.Contains([char]92)) { exit 9 }; if (\$d.Scp.Contains([char]92)) { exit 8 }; if (\$d.Scp -ne \$d.Win.Replace([char]92, [char]47)) { exit 7 }; if (-not \$d.Win.EndsWith(\$d.Name)) { exit 6 }; exit 0"
    [ "$status" -eq 0 ]
}

# `mkdir` alone fails when the directory is there, and that failure becomes the
# status the caller reads. And the path is unquoted, for the same measured
# reason as the -File path above.
@test "Get-GuestMkdirCommand: only when absent, and the path is not quoted" {
    run ps_with guestexec.ps1 "Write-Output (Get-GuestMkdirCommand 'C:/Windows/Temp/draugr-x')"
    [ "$status" -eq 0 ]
    [ "$output" = "if not exist C:/Windows/Temp/draugr-x mkdir C:/Windows/Temp/draugr-x" ]
}

# The whole directory. The list of fixed names it replaces was a second place to
# remember, and a file added to the copies and forgotten here stayed in the
# guest, including a public key.
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

# --- layerpath.ps1: a name that `drop` can turn into a path -------------------------------
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

# --- parents.ps1: the recorded parent references, and the child guard ---------------------
#
# U05. `thaw` and `drop` learn about children by SCANNING three places, and a
# scan is bounded by where it looks: a child outside all three was invisible,
# and both verbs then did the one thing the guard exists to prevent: a write to
# the parent of a differencing child, which damages it with no message. The
# index is the other half of the answer, and these are its decisions, executed.
#
# Get-VHD IS MOCKED here, by a function that shadows the cmdlet. The real one
# needs elevation and a real VHDX, and what is under test is the comparison of a
# record with what a disk reports, which is pure. The elevated measurements that
# decided the design are in tmp/u05-measure.log and tmp/u05-identity.log: a
# parent cannot be asked for its children, a child stays readable after its
# parent is deleted, and DiskIdentifier names the CHAIN and survives a
# Set-VHD -IgnoreIdMismatch that moves the child to another one.

PF_IDA='7B02A3FF-C96E-4CB7-85C9-993D6A8384E1'
PF_IDB='BC48A104-2771-4CEB-9273-4FEF6F9A3174'

# Empty files stand in for the disks: Test-Path is real inside the snippets and
# Get-VHD is the mock, so nothing here needs a VHDX or elevation. On a real
# Windows drive, because $DR_TMP is on the ext4 of WSL, which has no Windows
# path. It is the same scratch name that dr_test_teardown removes.
pf_setup() {
    local wroot
    wroot=$(dr_win_root) || return 1
    PF_DIR="$wroot/draugr-test.${DR_TMP##*/}/parents"
    mkdir -p "$PF_DIR" || return 1
    : > "$PF_DIR/parentA.vhdx"
    : > "$PF_DIR/parentB.vhdx"
    : > "$PF_DIR/childA.vhdx"
    : > "$PF_DIR/childB.vhdx"
    : > "$PF_DIR/locked.vhdx"
    PF_WIN=$(ps_win_slash "$PF_DIR")
}

# The preamble every snippet gets: the fixture paths, an empty chain, and the
# mock. The fake disks are KEYED BY LEAF NAME, so that no backslash has to
# survive the crossing to powershell.exe (see the header of this file), and the
# parent paths it answers with use forward slashes, which GetFullPath
# normalises on both sides of every comparison the code makes.
#
# $asked counts the calls per disk. One test needs it: the stores a scan walks
# overlap by construction, so "each disk is asked once" is a guarantee that
# nothing else can see. The claims are keyed by path further on, which hides a
# repeated question behind a correct answer.
#
# A fixture that cannot be made FAILS the test rather than skipping it. This
# whole file already skips without a real powershell.exe, so by the time these
# run a Windows drive is there, and an unwritable one is a real problem.
pf_run() {
    pf_setup || return 1
    ps_with parents.ps1 "\$b = '$PF_WIN'; \$ix = '$PF_WIN/forge-parents.json'; \
\$idA = '$PF_IDA'; \$idB = '$PF_IDB'; \$fake = @{}; \$asked = @{}; \
function Set-Fake(\$n, \$p, \$i) { \$fake[\$n] = [pscustomobject]@{ ParentPath = \$p; DiskIdentifier = \$i } }; \
function Get-VHD { [CmdletBinding()] param([string]\$Path); \$n = Split-Path \$Path -Leaf; \
\$asked[\$n] = 1 + \$(if (\$asked.ContainsKey(\$n)) { \$asked[\$n] } else { 0 }); \
if (\$fake.ContainsKey(\$n)) { return \$fake[\$n] }; throw 'this disk will not answer' }; \
Set-Fake 'parentA.vhdx' '' \$idA; Set-Fake 'parentB.vhdx' '' \$idB; $1"
}

# THE DISTINCTION THE WHOLE FILE RESTS ON. "There is no index yet" is the normal
# state before the first `new`, and must refuse nothing. "There is one and I
# could not read it" is a child the guard cannot see.
@test "Read-ParentIndex: no file yet is absent, and absent refuses nothing" {
    run pf_run "\$i = Read-ParentIndex -Index \$ix; if (\$i.State -ne 'absent') { exit 9 }; \
if (@(\$i.Entries).Count -ne 0 -or @(\$i.Bad).Count -ne 0) { exit 8 }; \
\$g = Get-ChildGuard -Disk (Join-Path \$b 'parentA.vhdx') -Candidates @() -Index \$ix; \
if (\$g.Blocks -or \$g.CannotTell) { exit 7 }; exit 0"
    [ "$status" -eq 0 ]
}

# PowerShell 5.1 unwraps a one-element array through ConvertFrom-Json, so a
# single recorded child arrives as a bare object whose .Count is $null. One
# recorded child is the commonest case there is.
@test "the parent index: one record survives the round trip" {
    run pf_run "[void](Add-ParentRecord -Child (Join-Path \$b 'childA.vhdx') -Parent (Join-Path \$b 'parentA.vhdx') -Id \$idA -Index \$ix); \
\$i = Read-ParentIndex -Index \$ix; if (\$i.State -ne 'ok') { exit 9 }; \
if (@(\$i.Entries).Count -ne 1) { exit 8 }; if (\$i.Entries[0].id -ne \$idA) { exit 7 }; \
if (-not \$i.Entries[0].child.EndsWith('childA.vhdx')) { exit 6 }; exit 0"
    [ "$status" -eq 0 ]
}

# Each of these three is a file that EXISTS and cannot be used, and the shape of
# this bug is an error that arrives as a reassuring answer. A truncated index
# and one from a newer Draugr both have to refuse.
@test "Read-ParentIndex: empty, malformed and a future version are unreadable, not empty" {
    run pf_run "[IO.File]::WriteAllText(\$ix, ''); \
if ((Read-ParentIndex -Index \$ix).State -ne 'unreadable') { exit 9 }; \
[IO.File]::WriteAllText(\$ix, '{ not json'); \
if ((Read-ParentIndex -Index \$ix).State -ne 'unreadable') { exit 8 }; \
[IO.File]::WriteAllText(\$ix, (ConvertTo-Json ([pscustomobject]@{ version = 2; entries = @() }))); \
if ((Read-ParentIndex -Index \$ix).State -ne 'unreadable') { exit 7 }; exit 0"
    [ "$status" -eq 0 ]
}

# An entry missing a field is HALF a record, and every field here decides a
# comparison. Skipping one quietly is how a child stops being guarded, so it is
# reported, and the guard turns a report into a refusal.
@test "Read-ParentIndex: an unusable entry is reported, and the guard then refuses" {
    run pf_run "\$p = Join-Path \$b 'parentA.vhdx'; \$e = @( \
[pscustomobject]@{ child = (Join-Path \$b 'x.vhdx'); parent = \$p; id = 'not-a-guid' }, \
[pscustomobject]@{ child = 'sideways/x.vhdx'; parent = \$p; id = \$idA }, \
[pscustomobject]@{ child = (Join-Path \$b 'y.vhdx'); id = \$idA }, \
[pscustomobject]@{ child = (Join-Path \$b 'z.vhdx'); parent = \$p; id = \$idB } ); \
[IO.File]::WriteAllText(\$ix, (ConvertTo-Json ([pscustomobject]@{ version = 1; entries = \$e }) -Depth 5)); \
\$i = Read-ParentIndex -Index \$ix; \
if (\$i.State -ne 'ok') { exit 9 }; if (@(\$i.Entries).Count -ne 1) { exit 8 }; \
if (@(\$i.Bad).Count -ne 3) { exit 7 }; \
\$g = Get-ChildGuard -Disk \$p -Candidates @() -Index \$ix; \
if (-not \$g.Blocks -or -not \$g.CannotTell) { exit 6 }; exit 0"
    [ "$status" -eq 0 ]
}

# A fresh index holding this one entry erases the record of every child
# outside the scan, which is the only thing the index is for. So the write
# refuses and the caller reports it.
@test "Add-ParentRecord: an unreadable index is never replaced by a fresh one" {
    run pf_run "[IO.File]::WriteAllText(\$ix, '{ not json'); \
\$r = Add-ParentRecord -Child (Join-Path \$b 'childA.vhdx') -Parent (Join-Path \$b 'parentA.vhdx') -Id \$idA -Index \$ix; \
if (\$r.Ok) { exit 9 }; if ([IO.File]::ReadAllText(\$ix) -ne '{ not json') { exit 8 }; \
if ((Remove-ParentRecords -Children @((Join-Path \$b 'childA.vhdx')) -Index \$ix) -ne 0) { exit 7 }; exit 0"
    [ "$status" -eq 0 ]
}

# A child re-created at the same path replaces its record. A second record for
# one path leaves the next read choosing between two answers.
@test "Add-ParentRecord: one record per child path" {
    run pf_run "\$pa = Join-Path \$b 'parentA.vhdx'; \$ca = Join-Path \$b 'childA.vhdx'; \
[void](Add-ParentRecord -Child \$ca -Parent \$pa -Id \$idA -Index \$ix); \
[void](Add-ParentRecord -Child (Join-Path \$b 'childB.vhdx') -Parent (Join-Path \$b 'parentB.vhdx') -Id \$idB -Index \$ix); \
[void](Add-ParentRecord -Child \$ca -Parent \$pa -Id \$idB -Index \$ix); \
\$i = Read-ParentIndex -Index \$ix; if (@(\$i.Entries).Count -ne 2) { exit 9 }; \
\$a = @(\$i.Entries | Where-Object { \$_.child.EndsWith('childA.vhdx') }); \
if (@(\$a).Count -ne 1 -or \$a[0].id -ne \$idB) { exit 8 }; exit 0"
    [ "$status" -eq 0 ]
}

@test "the child guard: confirmed, when the recorded child still differences from this disk" {
    run pf_run "\$pa = Join-Path \$b 'parentA.vhdx'; Set-Fake 'childA.vhdx' \$pa \$idA; \
[void](Add-ParentRecord -Child (Join-Path \$b 'childA.vhdx') -Parent \$pa -Id \$idA -Index \$ix); \
\$g = Get-ChildGuard -Disk \$pa -Candidates @() -Index \$ix; \
if (@(\$g.Claims).Count -ne 1) { exit 9 }; if (\$g.Claims[0].Verdict -ne 'confirmed') { exit 8 }; \
if (-not \$g.Blocks -or @(\$g.Children).Count -ne 1) { exit 7 }; \
if (\$g.Claims[0].Source -ne 'index') { exit 6 }; exit 0"
    [ "$status" -eq 0 ]
}

# IT IS STILL A CHILD, whatever the identifier says, so this blocks. The
# identifier only decides how loudly: either a different disk now sits at the
# recorded path, or the chain below it changed.
@test "the child guard: changed, when it names this disk and the chain is not the recorded one" {
    run pf_run "\$pa = Join-Path \$b 'parentA.vhdx'; Set-Fake 'childA.vhdx' \$pa \$idB; \
[void](Add-ParentRecord -Child (Join-Path \$b 'childA.vhdx') -Parent \$pa -Id \$idA -Index \$ix); \
\$g = Get-ChildGuard -Disk \$pa -Candidates @() -Index \$ix; \
if (\$g.Claims[0].Verdict -ne 'changed') { exit 9 }; if (-not \$g.Blocks) { exit 8 }; \
if (@(\$g.Alarms).Count -ne 1) { exit 7 }; if (@(\$g.Prunable).Count -ne 0) { exit 6 }; exit 0"
    [ "$status" -eq 0 ]
}

# A record whose file is gone is stale, and `thaw` and `drop` prune it. Without
# that, an index fills with dead records and every later run refuses.
@test "the child guard: gone, and the record is prunable" {
    run pf_run "\$pa = Join-Path \$b 'parentA.vhdx'; \
[void](Add-ParentRecord -Child (Join-Path \$b 'vanished.vhdx') -Parent \$pa -Id \$idA -Index \$ix); \
\$g = Get-ChildGuard -Disk \$pa -Candidates @() -Index \$ix; \
if (\$g.Claims[0].Verdict -ne 'gone') { exit 9 }; if (\$g.Blocks) { exit 8 }; \
if ((Remove-ParentRecords -Children \$g.Prunable -Index \$ix) -ne 1) { exit 7 }; \
if (@((Read-ParentIndex -Index \$ix).Entries).Count -ne 0) { exit 6 }; exit 0"
    [ "$status" -eq 0 ]
}

# A disk a running VM holds open answers with an exception, not a parent, and so
# does one asked without elevation. "Cannot be asked" must never read as "not a
# child", and it must not be pruned either: nothing was proved about it.
@test "the child guard: a child that will not answer blocks, and is not prunable" {
    run pf_run "\$pa = Join-Path \$b 'parentA.vhdx'; \
[void](Add-ParentRecord -Child (Join-Path \$b 'locked.vhdx') -Parent \$pa -Id \$idA -Index \$ix); \
\$g = Get-ChildGuard -Disk \$pa -Candidates @() -Index \$ix; \
if (\$g.Claims[0].Verdict -ne 'unreadable') { exit 9 }; if (-not \$g.Blocks) { exit 8 }; \
if (@(\$g.Prunable).Count -ne 0) { exit 7 }; exit 0"
    [ "$status" -eq 0 ]
}

# A legitimate re-parent inside one chain: it points somewhere else now, and the
# identifier it reports agrees with the disk it points at. A write to the old
# parent cannot reach it, so this refuses nothing.
@test "the child guard: released, when it belongs to another chain consistently" {
    run pf_run "Set-Fake 'childB.vhdx' (Join-Path \$b 'parentB.vhdx') \$idB; \
[void](Add-ParentRecord -Child (Join-Path \$b 'childB.vhdx') -Parent (Join-Path \$b 'parentA.vhdx') -Id \$idB -Index \$ix); \
\$g = Get-ChildGuard -Disk (Join-Path \$b 'parentA.vhdx') -Candidates @() -Index \$ix; \
if (\$g.Claims[0].Verdict -ne 'released') { exit 9 }; if (\$g.Blocks) { exit 8 }; \
if (@(\$g.Prunable).Count -ne 1) { exit 7 }; exit 0"
    [ "$status" -eq 0 ]
}

# MEASURED, in tmp/u05-identity.log: `Set-VHD -ParentPath -IgnoreIdMismatch`
# moves a child onto another chain and the identifier does NOT follow, so the
# child claims a chain it no longer sits on. That is the one state that the
# check of Hyper-V itself refuses, and -IgnoreIdMismatch is what turns it off. It is an
# alarm about ANOTHER chain, so it is reported and does not refuse this disk.
@test "the child guard: mismatch is the -IgnoreIdMismatch signature, an alarm and not a refusal" {
    run pf_run "Set-Fake 'childB.vhdx' (Join-Path \$b 'parentA.vhdx') \$idB; \
[void](Add-ParentRecord -Child (Join-Path \$b 'childB.vhdx') -Parent (Join-Path \$b 'parentB.vhdx') -Id \$idB -Index \$ix); \
\$g = Get-ChildGuard -Disk (Join-Path \$b 'parentB.vhdx') -Candidates @() -Index \$ix; \
if (\$g.Claims[0].Verdict -ne 'mismatch') { exit 9 }; if (\$g.Blocks) { exit 8 }; \
if (@(\$g.Alarms).Count -ne 1) { exit 7 }; if (@(\$g.Prunable).Count -ne 0) { exit 6 }; \
if (-not \$g.Claims[0].Why.Contains('IgnoreIdMismatch')) { exit 5 }; exit 0"
    [ "$status" -eq 0 ]
}

# A child whose parent was deleted stays readable and still reports the old
# path (measured). So the record is kept rather than pruned: the broken chain is
# the finding, and nothing here can repair it.
@test "the child guard: dangling, when it now names a disk that cannot be read" {
    run pf_run "Set-Fake 'childB.vhdx' (Join-Path \$b 'vanished.vhdx') \$idB; \
[void](Add-ParentRecord -Child (Join-Path \$b 'childB.vhdx') -Parent (Join-Path \$b 'parentB.vhdx') -Id \$idB -Index \$ix); \
\$g = Get-ChildGuard -Disk (Join-Path \$b 'parentB.vhdx') -Candidates @() -Index \$ix; \
if (\$g.Claims[0].Verdict -ne 'dangling') { exit 9 }; if (\$g.Blocks) { exit 8 }; \
if (@(\$g.Prunable).Count -ne 0) { exit 7 }; exit 0"
    [ "$status" -eq 0 ]
}

# THE FINDING ITSELF. The candidate list is everything the scan can reach, and
# this child is not in it: `new --root <somewhere else> --keep-registered`
# leaves exactly that, since nothing then puts it in a scanned store or in
# vms.cfg. Before the index, `thaw` and `drop` answered "children none".
#
# The scan is not blind here, which is the point: it reaches another layer of
# another chain and reports nothing about this one.
@test "the child guard: the index sees a child that the scan cannot reach" {
    run pf_run "\$pa = Join-Path \$b 'parentA.vhdx'; Set-Fake 'childA.vhdx' \$pa \$idA; \
Set-Fake 'childB.vhdx' (Join-Path \$b 'parentB.vhdx') \$idB; \
[void](Add-ParentRecord -Child (Join-Path \$b 'childA.vhdx') -Parent \$pa -Id \$idA -Index \$ix); \
\$g = Get-ChildGuard -Disk \$pa -Candidates @((Join-Path \$b 'childB.vhdx')) -Index \$ix; \
if (@(\$g.Children).Count -ne 1) { exit 9 }; if (-not \$g.Blocks) { exit 8 }; \
if (-not \$g.Children[0].Path.EndsWith('childA.vhdx')) { exit 7 }; exit 0"
    [ "$status" -eq 0 ]
}

# The two halves overlap on purpose, and a child in both is ONE child. The
# record wins, because its verdict carries the identifier comparison that the
# scan cannot make.
@test "the child guard: a child in both halves is one claim, and the record's verdict wins" {
    run pf_run "\$pa = Join-Path \$b 'parentA.vhdx'; \$ca = Join-Path \$b 'childA.vhdx'; \
Set-Fake 'childA.vhdx' \$pa \$idB; \
[void](Add-ParentRecord -Child \$ca -Parent \$pa -Id \$idA -Index \$ix); \
\$g = Get-ChildGuard -Disk \$pa -Candidates @(\$ca) -Index \$ix; \
if (@(\$g.Claims).Count -ne 1) { exit 9 }; if (\$g.Claims[0].Source -ne 'both') { exit 8 }; \
if (\$g.Claims[0].Verdict -ne 'changed') { exit 7 }; exit 0"
    [ "$status" -eq 0 ]
}

# The other direction: a child the scan found and nothing recorded, made by
# hand, or by a Draugr from before the index. It blocks, as it always did, and
# it is reported as unrecorded, so that "children none" never sounds like proof.
@test "the child guard: the scan's own children are reported as not recorded" {
    run pf_run "\$pa = Join-Path \$b 'parentA.vhdx'; Set-Fake 'childA.vhdx' \$pa \$idA; \
\$g = Get-ChildGuard -Disk \$pa -Candidates @((Join-Path \$b 'childA.vhdx')) -Index \$ix; \
if (@(\$g.Children).Count -ne 1) { exit 9 }; if (\$g.Claims[0].Source -ne 'scan') { exit 8 }; \
if (@(\$g.Unrecorded).Count -ne 1) { exit 7 }; if (\$g.IndexState -ne 'absent') { exit 6 }; exit 0"
    [ "$status" -eq 0 ]
}

# A LISTING THAT FAILED IS NOT A LISTING THAT FOUND NOTHING. It was
# -ErrorAction SilentlyContinue alone, so a layer store that was not readable
# contributed no candidates and the verb reported "children none". This is the same bug
# `adopt` had with its stray-disk listing.
@test "the child guard: a store that could not be listed is not a store with no children" {
    run pf_run "\$g = Get-ChildGuard -Disk (Join-Path \$b 'parentA.vhdx') -Candidates @() -Index \$ix \
-ScanErrors @('D:/ForgeLayers (access is denied)'); \
if (-not \$g.Blocks) { exit 9 }; if (-not \$g.CannotTell) { exit 8 }; \
if (@(\$g.Why).Count -ne 1) { exit 7 }; exit 0"
    [ "$status" -eq 0 ]
}

# -Root is usually also <drive>\ForgeLayers, and a registered layer is in that
# and in vms.cfg, so the candidate list repeats itself and the guarded disk is
# in it. THE GUARDED DISK IS LOCKED HERE, which is what makes this test able to
# fail: a disk that will not answer blocks, so without the self-exclusion the
# verb refuses because of the very disk it was asked about.
#
# AND THE CALL COUNT, because the claims are keyed by path later on: without it,
# dropping the dedupe changed nothing a test was able to see, and a layout where every
# candidate appears twice is the NORMAL one. A mutation run found that.
@test "the child guard: the disk is never its own child, and a repeated candidate is one claim" {
    run pf_run "\$me = Join-Path \$b 'locked.vhdx'; \$ca = Join-Path \$b 'childA.vhdx'; \
Set-Fake 'childA.vhdx' \$me \$idA; \
\$g = Get-ChildGuard -Disk \$me -Index \$ix -Candidates @(\$me, \$ca, \$ca); \
if (@(\$g.Claims).Count -ne 1) { exit 9 }; if (\$g.Claims[0].Verdict -ne 'confirmed') { exit 8 }; \
if (-not \$g.Claims[0].Path.EndsWith('childA.vhdx')) { exit 7 }; \
if (\$asked['childA.vhdx'] -ne 1) { exit 6 }; if (\$asked.ContainsKey('locked.vhdx')) { exit 5 }; exit 0"
    [ "$status" -eq 0 ]
}

# The same distinction on the scan side: a candidate path with no file is
# nothing at all, and one that exists and will not answer blocks.
@test "the child guard: an absent candidate is nothing, an unreadable one blocks" {
    run pf_run "\$g = Get-ChildGuard -Disk (Join-Path \$b 'parentA.vhdx') -Index \$ix \
-Candidates @((Join-Path \$b 'vanished.vhdx'), (Join-Path \$b 'locked.vhdx')); \
if (@(\$g.Claims).Count -ne 1) { exit 9 }; if (\$g.Claims[0].Verdict -ne 'unreadable') { exit 8 }; \
if (-not \$g.Blocks) { exit 7 }; exit 0"
    [ "$status" -eq 0 ]
}

# NOT %LOCALAPPDATA%. layer.ps1 re-launches itself elevated, and with
# over-the-shoulder elevation that child runs as another account. Thus the verb
# that records a child and the verb that reads the record use two
# different files, and the protection vanishes without a message. And an
# empty %ProgramData% must not make a RELATIVE path, which follows the
# current directory of whoever ran the verb.
@test "Get-ParentIndexPath: under ProgramData, and never a relative path" {
    run pf_run "\$p = Get-ParentIndexPath; \
if (-not \$p.StartsWith(\$env:ProgramData)) { exit 9 }; \
if (-not \$p.Contains('Draugr')) { exit 8 }; \
if (-not \$p.EndsWith('forge-parents.json')) { exit 7 }; \
\$env:ProgramData = ''; if ((Get-ParentIndexPath) -ne '') { exit 6 }; \
if ((Read-ParentIndex -Index (Get-ParentIndexPath)).State -ne 'unreadable') { exit 5 }; exit 0"
    [ "$status" -eq 0 ]
}
