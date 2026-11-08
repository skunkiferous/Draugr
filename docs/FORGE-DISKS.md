# Forge VM disks: copying one, and turning one into a VM

The value of the forge VM is not the VM. It is the disk: an installed toolchain (an engine, a
compiler, a warm cache), and two weeks of settings that nobody wants to make again. The snapshots of
AppSandbox do **not** protect that state. A snapshot is built as a child of the *first* baseline, and
the VM moves onto an empty branch. Thus the work stays behind on the old branch. The bug, its
analysis and the upstream fix are in [FORGE.md](FORGE.md#it-has-a-bug-that-decides-the-design).

Thus you must protect the disk by hand. This page gives the two operations that do it:

1. **Flatten** the current disk chain of the VM into one standalone VHDX. That is an image that
   depends on nothing, and that you can archive on a different volume.
2. **Register** such a disk as a VM: as a new VM beside the original, or by a change of the path of
   the existing VM.

Both run on the host, in an elevated PowerShell. No mound is involved, and no Draugr command wraps
them yet. We expect `dr-forge` to get `base` and `restore` verbs around exactly this.

---

## How AppSandbox stores a VM

A VM is a block in `%ProgramData%\AppSandbox\vms.cfg`. The application reads it at startup, and
rewrites it on each change. There is **no import in the UI or the API**. A disk becomes a VM when
you write the block.

```ini
[VM]
Name=Forge
OsType=Windows
ImagePath=C:\path\to\Win11.iso
VhdxPath=C:\ProgramData\AppSandbox\Forge\snapshots\branch_<guid>.vhdx
RamMB=16384
HddGB=256
CpuCores=8
GpuMode=1
GpuName=Default GPU
NetworkMode=0
AdminUser=<guest user>
SshEnabled=1
SshPort=57349
InstallComplete=1
```

AppSandbox uses `VhdxPath` exactly as written, so a disk on any volume works. `ImagePath` is the
install ISO, and is important only for a reinstall. `InstallComplete=1` stops AppSandbox from an
offer to install Windows on top.

### The VM's folder is derived from the disk path, not from its name

`get_vm_disk_root` (`src/backend_win/asb_core.c`) takes `VhdxPath`, and removes the filename. It
also removes a trailing `\snapshots` when the file name is `branch_*` or `snapshot_*`. All the files
of the VM are in the folder that results:

| | |
|---|---|
| `vm_state.json` | beside the **disk file itself**: `{"installComplete":1}` |
| `snapshots\tree.dat` | the snapshot tree, in the derived folder |
| `snapshots\*.vhdx` | the chain |
| `language.json`, `display_settings.json` | UI state of the VM |

> **A deletion of a VM deletes that folder, with all its contents.** `asb_vm_delete` calls
> `remove_dir_recursive` on it, with a guard only against a drive root. Thus a VM that points at
> `D:\Archive\base.vhdx` puts all of `D:\Archive\` at risk. **Never point a VM at a folder that you
> keep as insurance.**

### What the chain actually looks like

Measured on a real forge VM, after the snapshot bug happened three times:

| file | size | what it holds |
|---|---|---|
| `disk.vhdx` | 65.5 GB | the original base |
| `snapshots\snapshot_<a>.vhdx` | **0 bytes** | a "snapshot", empty |
| `snapshots\snapshot_<b>.vhdx` | **0 bytes** | the same |
| `snapshots\snapshot_<c>.vhdx` | **0 bytes** | the same |
| `snapshots\branch_<x>.vhdx` | 67.4 GB | **all of it**: the installed tools and the work |

Three snapshots that hold nothing, beside one branch that holds all, show the bug. Read `tree.dat`
to see which branch is which. `vms.cfg` says which one the VM boots.

---

## 1. Flatten the current disk into a standalone base

`Convert-VHD` reads a differencing disk *and its parents*, and writes one merged file. It does not
change the source chain. Thus you can safely run it on a VM that you will continue to use.

**Conditions.** The VM must be **stopped**, because a running VM locks its disk. The shell must be
**elevated**. If not, each Hyper-V cmdlet refuses with *"You do not have the required permission"*,
also while `vmms` runs. Select a destination on a **different volume** from the VM, because a copy
beside the original protects against nothing.

**Practice it first.** Ten seconds here can prevent a surprise half an hour into a 100 GB copy:

```powershell
New-VHD -Path D:\vhdtest\parent.vhdx -SizeBytes 1GB -Dynamic
New-VHD -Path D:\vhdtest\child.vhdx -ParentPath D:\vhdtest\parent.vhdx -Differencing
Convert-VHD -Path D:\vhdtest\child.vhdx -DestinationPath D:\vhdtest\flat.vhdx -VHDType Dynamic
Get-VHD D:\vhdtest\flat.vhdx | Select-Object VhdType,ParentPath   # ParentPath must be empty
Remove-Item D:\vhdtest -Recurse
```

**Then the real one**, with the path that `vms.cfg` gives as `VhdxPath`:

```powershell
New-Item -ItemType Directory D:\AppSandbox-archive -Force
Convert-VHD -Path 'C:\ProgramData\AppSandbox\Forge\snapshots\branch_<guid>.vhdx' `
            -DestinationPath 'D:\AppSandbox-archive\forge-base-<date>.vhdx' -VHDType Dynamic
Get-VHD 'D:\AppSandbox-archive\forge-base-<date>.vhdx' |
    Select-Object VhdType,ParentPath,FileSize
```

An empty `ParentPath` is the proof. The file stands alone, and a later restore of the VM needs only
this one file. The destination grows to about the *used* blocks of the full chain.

**Plan by throughput, and do not trust the percentage.** Measured on one machine: a 65.5 GB base
under a 69.8 GB branch became a **107.7 GiB** standalone disk. The write window of the destination
file was **10 m 48 s**, about 170 MB/s, NVMe to NVMe. The progress number does not predict. The same
operation showed 23 % during a run that felt much longer than eleven minutes. Compute the wait from
the sequential write speed of the volumes, and start it when you do not need the VM. Refer to [how
often this has to be repeated](#how-often-this-has-to-be-repeated) for why even a slow copy is
acceptable.

Keep the old chain until the new disk boots. A file that never started is a hope, not a backup.

---

## 2. Turn a disk into a VM

Give the VM its **own** folder, with its **own** copy of the disk. The archive stays in a place
where no VM points:

```text
D:\AppSandbox-archive\forge-base-<date>.vhdx   <- yours; nothing points here
D:\AppSandbox\Forge-Flat\disk.vhdx             <- a copy; AppSandbox owns this folder
D:\AppSandbox\Forge-Flat\vm_state.json         <- {"installComplete":1}
```

Then, with **AppSandbox fully closed**, add a block to `vms.cfg`. AppSandbox rewrites `vms.cfg`, and
overwrites your edit if it runs. Copy the settings of the VM that the disk came from, and change
three things:

```ini
[VM]
Name=Forge-Flat
OsType=Windows
ImagePath=C:\path\to\Win11.iso
VhdxPath=D:\AppSandbox\Forge-Flat\disk.vhdx
RamMB=16384
HddGB=256
CpuCores=8
GpuMode=1
GpuName=Default GPU
NetworkMode=0
AdminUser=<guest user>
SshEnabled=1
SshPort=57350
InstallComplete=1
```

- **`Name`** must be new.
- **`VhdxPath`** points at the copy, never at the archive.
- **`SshPort`** must be different from that of each other VM, so that two VMs never collide on the
  host port.

`GpuMode`, `GpuName` and `NetworkMode` must match the original. If not, the clone acts differently
from the VM that it came from. `NetworkMode=0` gives the forge VM no adapter, and the
[gateway](FORGE.md#network-no-adapter-and-egress-through-a-gateway) is its only way out. Save the
file as UTF-8, and start AppSandbox. The VM is then in the list. A `snapshots\` folder shows beside
the disk on the first load.

### Or repoint the VM you already have

Smaller, and sufficient when you do not want a second VM: change `VhdxPath` on the existing block to
the flat disk, with a `vm_state.json` beside it. The VM keeps its name, its SSH port, and all that is
built around them. It now runs on a disk with **no chain**, so the snapshot bug has nothing to
orphan. Its old folder is no longer the folder of the VM, so a deletion can no longer reach it.

---

---

## How often this has to be repeated

Almost never, if you keep the disk honest. That is a design decision, not a hope. What belongs in
the image is its own question, with the answer in
[FORGE.md](FORGE.md#what-the-base-image-must-contain).

A copy of the full image costs a write of the full image. There is no incremental version of
`Convert-VHD`, and a differencing child still merges its parents. Thus each new flatten pays for the
full image again. The only two controls are **the size of the image** and **how seldom you must
make it again**. What you allow on the disk controls both:

| what the guest holds | protected by | on the disk? |
|---|---|---|
| the engine, the compiler, the toolchain, MSYS2, the screen server | **this flatten**: you must *install* them, not copy them | yes, and that is the full purpose |
| the own settings of the guest, autologin, tunnel key, mapped drives | this flatten | yes |
| project source and assets | **git**, pushed to the host | no |
| Fab / vault assets | **the vault**, mounted read-only over SMB | no |
| derived data, shader and DDC caches | nothing: you can build them again | yes, but disposable |

Thus the flat base becomes old only when something that you had to *install* changes: an engine
upgrade, a new Visual Studio workload, a Windows servicing update to keep. That is a few events in a
year, and each one is already a planned act. Then a new flatten is worth its cost. At all other
times, the disk holds nothing that git and the vault do not already hold.

**Flatten again at milestones, never on a schedule.** The test is one question: *if I lost this
disk now, what must I install again by hand?* If the answer is "nothing new since the last base",
there is nothing to copy.

### Making the wait cheap rather than short

You cannot make it short. But it can stop using your attention:

- **It needs no human.** The conditions are a stopped VM and an elevated shell, not a person at the
  screen. Start it and leave. Afterwards, read only the output of `Get-VHD`.
- **A second copy of a flat disk is only a file copy**: `robocopy /j` or `Copy-Item`, with no chain
  to merge. A copy of an existing archive is much cheaper than a new one.
- **Run the VM on the flat disk** ([repoint it](#or-repoint-the-vm-you-already-have)). Then the
  chain stops growing under it, and the next flatten reads one file, not a base and a large branch.
- In theory, the own changed-block tracking of Hyper-V can make this incremental. But AppSandbox
  does not expose its VMs to a backup stack. If you control Hyper-V behind the back of AppSandbox,
  you can lose the disk that this page exists to protect. *Not proven, and not recommended.*

## Rules that keep this safe

- **The archive folder is never the folder of a VM.** A deletion removes the folder and all its
  contents.
- **One disk for each VM.** Two blocks that point at one VHDX means two VMs that boot the same disk.
- **Edit `vms.cfg` only while AppSandbox is closed**, also the headless daemon.
- **Mount a chain with `-NoDriveLetter`, onto a directory.** A differencing child gets the partition
  table of its parent. Thus parent and child have the *same* volume identity. Windows remembers the
  letter of the parent, and tries to use it again for the child. That gives `E:\ is not accessible.
  The parameter is incorrect.`, an Explorer window frozen on a changed volume, and a letter that
  `Get-Partition` reports but no provider can open (*measured*). `Mount-VHD -NoDriveLetter` with
  `Add-PartitionAccessPath -AccessPath <empty dir>` avoids drive letters fully.
- **Keep the previous chain until the new disk boots**, then free the space.
- **Flatten again after work that you had to *install*.** The base is a point in time. A refresh is
  the same `Convert-VHD` again, at the same cost. Thus keep all else off the disk, and the refresh
  stays rare ([how often](#how-often-this-has-to-be-repeated)).

## Not this: registering the disk as a template

`vms.cfg` also accepts `[Template]` blocks with their own `VhdxPath`. A VM created from a template is
a differencing child of it. By its structure, it is the ideal "base that can only be read". But the
template path is built for **sysprepped** images. The template unattend generator boots audit mode,
and runs `sysprep /generalize /oobe /shutdown`. Instances get a post-sysprep mini-setup unattend.
Nobody tested it on a normal, configured disk. Prove it on a test VM in an isolated data root before
anyone uses it, not on the important disk.

## Measured

| finding |
|---|
| `vms.cfg` takes `VhdxPath` exactly as written. The UI and the API have no import |
| The folder of the VM comes from the disk path, and `asb_vm_delete` removes it with all its contents |
| AppSandbox reads `vm_state.json` from beside the disk file, not from the derived folder |
| The Hyper-V cmdlets are present and `vmms` runs, but each one needs elevation |
| Three snapshots of a real forge VM were 0 bytes. The branch held all 67.4 GB |
| A 135 GB chain became one 107.7 GiB dynamic VHDX with an empty `ParentPath`. The write took 10 m 48 s (~170 MB/s). The progress percentage of `Convert-VHD` showed much less progress than the real progress |
| A copy of that 107.7 GiB base **within one volume** (D: to D:) took **29.8 min**, about 60 MB/s. That is a third of the rate of the cross-volume `Convert-VHD` that made it, because one disk serves both the read and the write. Plan a same-volume copy at about three times a cross-volume one |
| The repoint works: the VM moved onto the flat disk, and booted in 30 s, with `vms.cfg` rewritten in place. The layer mechanism now does that job, and `dr-layer new` gives a VM a disk with no chain |
