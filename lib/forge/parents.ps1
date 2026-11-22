# lib/forge/parents.ps1: who differences from this disk, and what the host
# recorded about it.
#
# ==> YOU DO NOT TYPE THIS. lib/forge/layer.ps1 dot-sources it. <==
#
# THE FINDING (U05 of the security review). `thaw` and `drop` both refuse to
# touch a layer that another layer differences from, and both learn about
# children by SCANNING three places: -Root, every fixed drive's ForgeLayers, and
# each VhdxPath in vms.cfg. A scan is bounded by where it looks. A child outside
# all three is invisible, and the two verbs then do the one thing the guard
# exists to prevent: a write to the parent of a differencing child, which
# damages the child with no message anywhere in the stack.
#
# MEASURED, elevated, on throwaway 64 MB disks that nothing else could see
# (tmp/u05-measure.log and tmp/u05-identity.log hold the full runs):
#
#   - A PARENT CANNOT BE ASKED FOR ITS CHILDREN. Get-VHD exposes no such
#     property, on either side of a chain. So the scan is not a lazy choice, it
#     is the only thing the platform offers - and an INVENTORY is the only way
#     to know about a child that the scan cannot reach.
#   - A CHILD STAYS READABLE after its parent is renamed AND after it is
#     deleted, still reporting the old ParentPath. So a record can always be
#     re-checked against the disk it names, which is what makes a guard out of
#     an inventory rather than a list of hopes.
#   - A JUNCTION IN -ParentPath IS RESOLVED when the child is created: Hyper-V
#     stores the real target. So the path matching below is sound. That was NOT
#     the assumption this was written under, and the measurement overturned it.
#   - DiskIdentifier IS THE IDENTITY OF THE CHAIN, not of one edge. A parent, its
#     child and its grandchild all report the same value. And `Set-VHD
#     -ParentPath -IgnoreIdMismatch` does not update it, so it can be left
#     naming a chain that the child no longer belongs to.
#
# SO A RECORD IS A PAIR, AND A DISAGREEMENT INSIDE THE PAIR IS THE ALARM.
# ParentPath is exact about which disk an edge points at, and is a path.
# DiskIdentifier is immune to the spelling of a path, and only scopes the chain.
# Neither is enough alone. An entry is (child, parent, id), and a re-check asks
# three questions: does the child still name this parent, is its identifier
# still the recorded one, and does its identifier agree with the disk its
# ParentPath actually names? The third is what catches an -IgnoreIdMismatch
# re-parent, which is the one state that Hyper-V's own check would have refused.
#
# WHAT THIS INDEX MAY NEVER DO, and the reason it needs no trust decision of its
# own: it can only ever ADD A REFUSAL. Nothing here authorises a delete, a write
# or a publication. A corrupt or hostile entry can make a layer verb refuse to
# run, or - by being removed - take the guard back to what the scan alone can
# see. It can never make `drop` remove something, because `drop` still resolves
# its target from -Name and -Root, through Test-LayerName and Test-UnderRoot, as
# it always did. That is why this file sits beside the other host state and not
# inside the trust mechanism of dr-trust.
#
# WHERE IT LIVES, AND WHY NOT %LOCALAPPDATA%. layer.ps1 re-launches itself
# elevated. With over-the-shoulder elevation that child runs as ANOTHER account,
# and %LOCALAPPDATA% then names that account's profile - so the verb that
# records a child and the verb that reads the record would use two different
# files, and the protection would disappear without a message. %ProgramData% is
# the same path for every account on the machine, and is where AppSandbox keeps
# host.json for the same reason. A new file there is readable by every local
# user (measured), and that is accepted rather than repaired: Draugr sets no
# Windows permission, and docs/SECURITY.md says why. The paragraph above is what
# makes that safe here - a weak ACL on this file costs a false refusal and can
# never produce an authorisation.

# Get-FullPath, Test-LayerName and Test-UnderRoot. layer.ps1 dot-sources this
# file as well, which only re-defines the same functions.
. (Join-Path $PSScriptRoot 'layerpath.ps1')

# The format carries its own version, and an index written by a NEWER Draugr is
# not something this code may read as "no children". An unknown version is
# reported as unreadable, and the guard refuses. Fail closed, the same rule as
# the rest of this review.
$script:ParentIndexVersion = 1

# NO TIMESTAMP IN AN ENTRY, on purpose. Nothing compares one, the reader would
# have to carry a field it does not understand, and a field the reader drops is
# erased by the next write. This is a guard, not a log.
function Get-ParentIndexPath {
    $base = $env:ProgramData
    # An empty %ProgramData% would make Join-Path build a RELATIVE path, and the
    # index would then follow the current directory of whoever ran the verb.
    if (-not $base) { return '' }
    Join-Path $base 'Draugr\forge-parents.json'
}

# ------------------------------------------------------------------ reading a disk
# ONE READER FOR EVERY DISK THIS FILE ASKS ABOUT, because each question below
# needs the same two fields and none of them may throw. Get-VHD throws for a
# disk that a running VM holds open, for a file that is not a VHDX at all, and
# for every call without elevation: three different reasons that all mean
# "cannot tell", and none of them mean "not a child".
function Get-VhdFacts {
    param([string]$Path)
    $full = Get-FullPath $Path
    # Absent is its own answer. A recorded child whose file is gone is a stale
    # record, which is safe; a child that exists and cannot be read is not.
    if (-not $full -or -not (Test-Path -LiteralPath $full)) {
        return [pscustomobject]@{
            Ok = $false; Absent = $true; Path = $full
            ParentPath = ''; Id = ''; Why = 'the file is not there'
        }
    }
    try { $v = Get-VHD -Path $full -ErrorAction Stop }
    catch {
        # The first line only. A Hyper-V error carries several, and the rest is
        # the same advice every time.
        return [pscustomobject]@{
            Ok = $false; Absent = $false; Path = $full
            ParentPath = ''; Id = ''; Why = $_.Exception.Message.Split([char]10)[0]
        }
    }
    # An empty ParentPath means the disk is not differencing, which is an answer
    # and not a failure.
    $pp = if ($v.ParentPath) { Get-FullPath $v.ParentPath } else { '' }
    [pscustomobject]@{
        Ok = $true; Absent = $false; Path = $full
        ParentPath = $pp; Id = [string]$v.DiskIdentifier; Why = ''
    }
}

# ------------------------------------------------------------------ the index file
# READ, AND SAY WHICH OF THE THREE THINGS HAPPENED. "There is no file yet" is
# normal before the first `new` and must not read the same as "there is a file
# and I could not understand it" - that second one is a child the guard cannot
# see, and the whole class of bug this review is about is an error that arrives
# as a reassuring answer.
function Read-ParentIndex {
    param([string]$Index)
    $out = [pscustomobject]@{ Path = $Index; State = 'absent'; Entries = @(); Bad = @() }
    # No path at all is not an empty index either.
    if (-not $Index) {
        $out.State = 'unreadable'
        $out.Bad = @('%ProgramData% is not set, so there is no index path')
        return $out
    }
    if (-not (Test-Path -LiteralPath $Index)) { return $out }

    # ReadAllText, not Get-Content, because the whole file is one JSON document
    # and the line splitting of Get-Content has nothing to add to it.
    $raw = ''
    try { $raw = [IO.File]::ReadAllText($Index) }
    catch {
        $out.State = 'unreadable'
        $out.Bad = @("cannot read ${Index}: $($_.Exception.Message.Split([char]10)[0])")
        return $out
    }
    # An empty file is a half-written index, or one that something truncated. It
    # is not an index with no entries.
    if (-not $raw.Trim()) {
        $out.State = 'unreadable'
        $out.Bad = @("$Index is empty")
        return $out
    }
    # -ErrorAction Stop, and not the ambient preference: a test dot-sources this
    # file without one, and a non-terminating error would leave $doc null and
    # the entries empty - which is the reassuring answer again.
    $doc = $null
    try { $doc = ConvertFrom-Json $raw -ErrorAction Stop }
    catch {
        $out.State = 'unreadable'
        $out.Bad = @("$Index is not readable JSON: $($_.Exception.Message.Split([char]10)[0])")
        return $out
    }

    # Compared as a string, so that a version field holding a word throws
    # nothing. Anything but the known version is unreadable, in both directions.
    $ver = "$($doc.version)"
    if ($ver -ne "$script:ParentIndexVersion") {
        $out.State = 'unreadable'
        $out.Bad = @("$Index has format version '$ver', and this Draugr knows version $script:ParentIndexVersion")
        return $out
    }

    # THE $null TEST IS THE LOAD-BEARING HALF, and not the @(). PowerShell 5.1
    # unwraps a one-element array through ConvertFrom-Json, and `foreach` walks
    # a bare object as readily as a list, so both shapes arrive here safely. An
    # ABSENT `entries` does not: @($null) is a list holding one null, which
    # would be reported as an unusable entry in an index that has none.
    $raws = @()
    if ($null -ne $doc.entries) { $raws = @($doc.entries) }
    $good = @()
    $bad = @()
    $n = 0
    foreach ($e in $raws) {
        $n++
        # EACH FIELD DECIDES A COMPARISON BELOW, so an entry missing one is
        # unusable rather than half-checked. An unusable entry is reported, and
        # the guard turns that into "cannot tell" - it is never skipped.
        if ($null -eq $e) { $bad += "entry ${n}: empty"; continue }
        $child = "$($e.child)"; $parent = "$($e.parent)"; $id = "$($e.id)"
        if (-not $child -or -not $parent -or -not $id) {
            $bad += "entry ${n}: child, parent or id is missing"; continue
        }
        # A relative path in the index would resolve against whatever directory
        # the verb happened to run in, which is a different disk each time.
        if (-not [IO.Path]::IsPathRooted($child) -or -not [IO.Path]::IsPathRooted($parent)) {
            $bad += "entry ${n}: a path is not absolute"; continue
        }
        # The id is compared against a DiskIdentifier, which is a GUID. Anything
        # else cannot match one, so it would make every re-check an alarm.
        $g = [guid]::Empty
        if (-not [guid]::TryParse($id, [ref]$g)) {
            $bad += "entry ${n}: '$id' is not a GUID"; continue
        }
        $good += [pscustomobject]@{
            child = (Get-FullPath $child); parent = (Get-FullPath $parent); id = $id
        }
    }
    # State describes the FILE, Bad describes the entries. Both are read by the
    # guard, and either one is enough to refuse.
    $out.State = 'ok'
    $out.Entries = $good
    $out.Bad = $bad
    $out
}

# Written beside the real file and renamed over it, so that no reader ever sees
# half an index - which it would read as "no children recorded".
function Write-ParentIndex {
    param($Entries, [string]$Index)
    if (-not $Index) { throw 'Write-ParentIndex: no index path' }
    $dir = Split-Path $Index -Parent
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
    # -Depth IS A MARGIN HERE, AND NOT A FIX. A mutation run showed that the
    # default of 2 round-trips this shape unharmed, so no test can tell the flag
    # is there; it stays because the failure it guards against is silent. Past
    # the depth, ConvertTo-Json writes an object as its type name and every
    # field is gone, so one nested field added later would empty the index
    # without an error. @() so that one entry is still written as a list.
    $doc = [pscustomobject]@{ version = $script:ParentIndexVersion; entries = @($Entries) }
    $tmp = "$Index.tmp"
    [IO.File]::WriteAllText($tmp, ($doc | ConvertTo-Json -Depth 5))
    Move-Item -LiteralPath $tmp -Destination $Index -Force
}

# `new` calls this for the child it has just created. A failure here is reported
# to the caller and not thrown: the disk already exists at that point, so the
# honest outcome is a loud warning that this child is known to the scan only.
function Add-ParentRecord {
    param([string]$Child, [string]$Parent, [string]$Id, [string]$Index)
    $idx = Read-ParentIndex -Index $Index
    # An unreadable index is NOT replaced with a fresh one holding this single
    # entry. That would erase the record of every child outside the scan, which
    # is the only thing this index is for.
    if ($idx.State -eq 'unreadable') {
        return [pscustomobject]@{ Ok = $false; Why = ($idx.Bad -join '; ') }
    }
    $child = Get-FullPath $Child
    # ONE RECORD PER CHILD PATH. A child re-created at the same path replaces its
    # record instead of adding a second one that the next read has to choose
    # between.
    $keep = @($idx.Entries | Where-Object { $_.child -ine $child })
    $keep += [pscustomobject]@{ child = $child; parent = (Get-FullPath $Parent); id = $Id }
    try { Write-ParentIndex -Entries $keep -Index $Index }
    catch {
        return [pscustomobject]@{ Ok = $false; Why = $_.Exception.Message.Split([char]10)[0] }
    }
    [pscustomobject]@{ Ok = $true; Why = ''; Count = @($keep).Count }
}

# The records of these children go. Two callers: `drop`, for the layer it has
# just removed, and both guards, for a record they have PROVED stale.
function Remove-ParentRecords {
    param($Children, [string]$Index)
    $idx = Read-ParentIndex -Index $Index
    # Nothing to prune from a file that is absent, and nothing may be written
    # over one that could not be read.
    if ($idx.State -ne 'ok') { return 0 }
    $drop = @(@($Children) | ForEach-Object { (Get-FullPath $_).ToLowerInvariant() })
    $keep = @($idx.Entries | Where-Object { $drop -notcontains $_.child.ToLowerInvariant() })
    $gone = @($idx.Entries).Count - @($keep).Count
    if ($gone -gt 0) { Write-ParentIndex -Entries $keep -Index $Index }
    $gone
}

# ------------------------------------------------------------------ the verdicts
# One shape for every claim, from either half of the guard, so that the verbs
# print one list and not two.
function New-ParentClaim {
    param([string]$Path, [string]$Verdict, [bool]$Blocks, [string]$Source, [string]$Why)
    [pscustomobject]@{
        Path = (Get-FullPath $Path); Verdict = $Verdict
        Blocks = $Blocks; Source = $Source; Why = $Why
    }
}

# THE VERDICT FOR ONE RECORD, given the disk being guarded. The caller has
# already selected the records whose parent is this disk, so the only question
# here is what the child says NOW.
#
# Blocks is deliberately narrow: it means "this disk still has a dependent, or I
# cannot tell whether it does". An inconsistency that concerns ANOTHER chain is
# reported loudly and does not refuse the operation, because a write to this
# disk cannot reach a child that no longer points at it - and refusing would
# leave no way to finish legitimate work over a fault somewhere else.
function Test-ParentClaim {
    param($Entry, [string]$Disk)
    $disk = Get-FullPath $Disk
    $f = Get-VhdFacts -Path $Entry.child
    # A record whose file is gone is stale, and `thaw` and `drop` prune it.
    if (-not $f.Ok -and $f.Absent) {
        return New-ParentClaim $Entry.child 'gone' $false 'index' 'the recorded child is not there any more'
    }
    # It exists and will not answer: a running VM, a locked file, no elevation.
    if (-not $f.Ok) {
        return New-ParentClaim $Entry.child 'unreadable' $true 'index' "cannot be read: $($f.Why)"
    }

    # Still pointing here. Then it IS a child, whatever the identifier says, and
    # the identifier only decides how loudly to say so.
    $sameId = ($f.Id -and ($f.Id -ieq "$($Entry.id)"))
    if ($f.ParentPath -and ($f.ParentPath -ieq $disk)) {
        if ($sameId) {
            return New-ParentClaim $f.Path 'confirmed' $true 'index' "differences from this disk (chain $($f.Id))"
        }
        return New-ParentClaim $f.Path 'changed' $true 'index' ("differences from this disk, but its chain is now $($f.Id) " +
            "and the record says $($Entry.id). Either a different disk sits at this path, or the chain below it changed")
    }

    # It names something else now, so a write here cannot damage it. What is
    # left is whether it is consistent WHERE IT NOW POINTS, and that is the
    # question Set-VHD -IgnoreIdMismatch answers wrongly.
    if (-not $f.ParentPath) {
        return New-ParentClaim $f.Path 'released' $false 'index' 'it is not a differencing disk any more'
    }
    $now = Get-VhdFacts -Path $f.ParentPath
    if (-not $now.Ok) {
        return New-ParentClaim $f.Path 'dangling' $false 'index' ("now names $($f.ParentPath), " +
            "which cannot be read: $($now.Why)")
    }
    # The identifier is the chain's, so a child and the parent it points at
    # must report the same one. This is the comparison that no single stored
    # field can make, and the reason a record is a pair.
    if ($now.Id -ieq $f.Id) {
        return New-ParentClaim $f.Path 'released' $false 'index' "now differences from $($f.ParentPath), consistently"
    }
    New-ParentClaim $f.Path 'mismatch' $false 'index' ("now names $($f.ParentPath), whose chain is " +
        "$($now.Id) while the child still reports $($f.Id). Set-VHD -IgnoreIdMismatch leaves exactly this")
}

# THE SCAN, as it always was, with the enumeration of candidate disks lifted out
# so that a test can supply the list. layer.ps1 builds the real one from -Root,
# every fixed drive's ForgeLayers and vms.cfg; see Get-LayerCandidates there.
function Get-ScanClaims {
    param([string]$Disk, $Candidates)
    $disk = Get-FullPath $Disk
    $out = @()
    $seen = @{}
    foreach ($c in @($Candidates)) {
        $full = Get-FullPath $c
        # A disk is not its own child, and the three sources overlap: -Root is
        # usually also <drive>\ForgeLayers, and a registered layer is both.
        if (-not $full -or ($full -ieq $disk)) { continue }
        $k = $full.ToLowerInvariant()
        if ($seen.ContainsKey($k)) { continue }
        $seen[$k] = $true

        $f = Get-VhdFacts -Path $full
        if (-not $f.Ok) {
            # A candidate path with no file is nothing at all. A file that will
            # not answer is reported and blocks: "cannot be asked" must never
            # read as "not a child", which is the silence this guard exists for.
            if ($f.Absent) { continue }
            $out += New-ParentClaim $full 'unreadable' $true 'scan' "cannot be read: $($f.Why)"
            continue
        }
        # -ieq, not -eq. These paths come from a parameter, a directory walk and
        # a configuration file, and Windows ignores case between them.
        if ($f.ParentPath -and ($f.ParentPath -ieq $disk)) {
            $out += New-ParentClaim $f.Path 'confirmed' $true 'scan' 'differences from this disk'
        }
    }
    $out
}

# THE WHOLE GUARD: the scan and the index, merged, with one answer for the verb
# that has to decide. The two halves complement each other and neither is
# redundant. The scan sees a child that nothing recorded - one made by hand, or
# by a Draugr from before this index existed. The index sees a child that the
# scan cannot reach - `new --root <somewhere else> --keep-registered` leaves
# exactly that, since nothing then puts it in a scanned store or in vms.cfg.
#
# -ScanErrors is the list of directories the caller could not enumerate. A
# failed listing is not an empty one: that is the bug `adopt` had, and it reads
# as "no children" here too, so it is folded into CannotTell.
function Get-ChildGuard {
    param([string]$Disk, $Candidates, [string]$Index, $ScanErrors = @())
    $disk = Get-FullPath $Disk
    $idx = Read-ParentIndex -Index $Index
    $byPath = @{}
    foreach ($c in @(Get-ScanClaims -Disk $disk -Candidates $Candidates)) {
        $byPath[$c.Path.ToLowerInvariant()] = $c
    }

    # Every record that names this disk as the parent, re-checked against the
    # disk itself. A child the scan already found is not a second child, but the
    # record's verdict carries the identifier comparison that the scan cannot
    # make, so the record wins and the claim is marked as seen by both.
    foreach ($e in @($idx.Entries | Where-Object { $_.parent -ieq $disk })) {
        $claim = Test-ParentClaim -Entry $e -Disk $disk
        $k = $claim.Path.ToLowerInvariant()
        if ($byPath.ContainsKey($k)) { $claim.Source = 'both' }
        $byPath[$k] = $claim
    }
    $all = @($byPath.Values | Sort-Object Path)

    # CANNOT TELL IS NOT THE SAME AS NO CHILDREN, and an ABSENT index is not the
    # same as an unreadable one: absent is the normal state before the first
    # `new`, and must not refuse anything.
    $why = @()
    if ($idx.State -eq 'unreadable') { $why += @($idx.Bad) }
    foreach ($b in @($idx.Bad)) { if ($idx.State -eq 'ok') { $why += "unusable $b" } }
    foreach ($e in @($ScanErrors)) { $why += "a layer store could not be listed: $e" }
    $cannotTell = (@($why).Count -gt 0)

    # Children BLOCKS; alarms report. Prunable is what has been proved stale,
    # and Unrecorded is what the scan found and the index did not - which is how
    # a reader learns that the index is partial.
    $children = @($all | Where-Object { $_.Blocks })
    $alarmed = @('changed', 'mismatch', 'dangling')
    [pscustomobject]@{
        Disk = $disk
        Claims = $all
        Children = $children
        Blocks = ((@($children).Count -gt 0) -or $cannotTell)
        CannotTell = $cannotTell
        Why = $why
        Alarms = @($all | Where-Object { $alarmed -contains $_.Verdict })
        Prunable = @($all | Where-Object { @('gone', 'released') -contains $_.Verdict } | ForEach-Object { $_.Path })
        Unrecorded = @($all | Where-Object { $_.Source -eq 'scan' } | ForEach-Object { $_.Path })
        IndexState = $idx.State
        IndexPath = $idx.Path
        Recorded = @($idx.Entries).Count
    }
}
