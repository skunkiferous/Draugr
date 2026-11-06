# Forge VM disks: copying one, and turning one into a VM

The forge VM's value is not the VM. It is the disk: an installed toolchain — an engine, a compiler,
a warm cache — and a fortnight of settings that nobody wants to reproduce. AppSandbox's
snapshots do **not** protect that state — a snapshot is built as a child of the *first* baseline and
the VM is moved onto an empty branch, so the work is left behind on the old one (the bug, its
analysis and the upstream fix are in [FORGE.md](FORGE.md#it-has-a-bug-that-decides-the-design)).

So the disk has to be protected by hand. This page is the two operations that do it:

1. **Flatten** the VM's current disk chain into one standalone VHDX — an image that depends on
   nothing and can be archived on another volume.
2. **Register** such a disk as a VM, either as a new one beside the original or by repointing the
   existing one.

Both are host-side, in an elevated PowerShell. No mound is involved, and no Draugr command wraps
them yet; `dr-forge` is expected to grow `base` and `restore` verbs around exactly this.

---

## How AppSandbox stores a VM

A VM is a block in `%ProgramData%\AppSandbox\vms.cfg`, read at startup and rewritten by the
application whenever it changes anything. There is **no import in the UI or the API** — writing the
block *is* how a disk becomes a VM.

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

`VhdxPath` is used verbatim, so a disk on any volume works. `ImagePath` is the install ISO and
matters only for a reinstall. `InstallComplete=1` is what stops AppSandbox offering to install
Windows over the top.

### The VM's folder is derived from the disk path, not from its name

`get_vm_disk_root` (`src/backend_win/asb_core.c`) takes `VhdxPath`, strips the filename, and strips
a trailing `\snapshots` when the file is named `branch_*` or `snapshot_*`. Everything per-VM lives
in the folder that comes out:

| | |
|---|---|
| `vm_state.json` | beside the **disk file itself** — `{"installComplete":1}` |
| `snapshots\tree.dat` | the snapshot tree, in the derived folder |
| `snapshots\*.vhdx` | the chain |
| `language.json`, `display_settings.json` | per-VM UI state |

> **Deleting a VM deletes that folder, recursively.** `asb_vm_delete` calls
> `remove_dir_recursive` on it, guarded only against a drive root. A VM pointed at
> `D:\Archive\base.vhdx` therefore has `D:\Archive\` in its blast radius. **Never point a VM at a
> folder you are keeping as insurance.**

### What the chain actually looks like

Measured on a real forge VM, after the snapshot bug had been exercised three times:

| file | size | what it holds |
|---|---|---|
| `disk.vhdx` | 65.5 GB | the original base |
| `snapshots\snapshot_<a>.vhdx` | **0 bytes** | a "snapshot" — empty |
| `snapshots\snapshot_<b>.vhdx` | **0 bytes** | the same |
| `snapshots\snapshot_<c>.vhdx` | **0 bytes** | the same |
| `snapshots\branch_<x>.vhdx` | 67.4 GB | **everything** — the installed tools and the work |

Three snapshots holding nothing, beside one branch holding it all, is the bug made visible. Read
`tree.dat` to see which branch is which; `vms.cfg` says which one the VM boots.

---

## 1. Flatten the current disk into a standalone base

`Convert-VHD` reads a differencing disk *and its parents* and writes one merged file. The source
chain is not modified, so this is safe to run against a VM you intend to keep using.

**Preconditions.** The VM must be **stopped** — a running VM holds its disk locked. The shell must
be **elevated**: every Hyper-V cmdlet refuses otherwise with *"You do not have the required
permission"*, even though `vmms` is running. Choose a destination on a **different volume** from the
VM, because a copy beside the original protects against nothing.

**Rehearse it first.** Ten seconds here saves discovering a surprise half an hour into a 100 GB
copy:

```powershell
New-VHD -Path D:\vhdtest\parent.vhdx -SizeBytes 1GB -Dynamic
New-VHD -Path D:\vhdtest\child.vhdx -ParentPath D:\vhdtest\parent.vhdx -Differencing
Convert-VHD -Path D:\vhdtest\child.vhdx -DestinationPath D:\vhdtest\flat.vhdx -VHDType Dynamic
Get-VHD D:\vhdtest\flat.vhdx | Select-Object VhdType,ParentPath   # ParentPath must be empty
Remove-Item D:\vhdtest -Recurse
```

**Then the real one**, with the path `vms.cfg` gives as `VhdxPath`:

```powershell
New-Item -ItemType Directory D:\AppSandbox-archive -Force
Convert-VHD -Path 'C:\ProgramData\AppSandbox\Forge\snapshots\branch_<guid>.vhdx' `
            -DestinationPath 'D:\AppSandbox-archive\forge-base-<date>.vhdx' -VHDType Dynamic
Get-VHD 'D:\AppSandbox-archive\forge-base-<date>.vhdx' |
    Select-Object VhdType,ParentPath,FileSize
```

An empty `ParentPath` is the proof: the file stands alone, and restoring the VM later needs nothing
but this one file. The destination grows to roughly the *used* blocks of the whole chain.

**Budget by throughput, and distrust the percentage.** Measured on one machine: a
65.5 GB base under a 69.8 GB branch flattened to a **107.7 GiB** standalone disk, and the destination
file's own write window was **10 m 48 s** — about 170 MB/s, NVMe to NVMe. The progress indicator is
not a predictor: the same operation read 23 % partway through a run that felt far longer than eleven
minutes. Size the wait from the volumes' sequential write speed, start it when you do not need the
VM, and see [how often this has to be repeated](#how-often-this-has-to-be-repeated) for why even a
slow one is tolerable.

Keep the old chain until the new disk has actually booted. A file that has never been started is a
hope, not a backup.

---

## 2. Turn a disk into a VM

Give the VM its **own** folder, holding its **own** copy of the disk. The archive stays somewhere no
VM points at:

```text
D:\AppSandbox-archive\forge-base-<date>.vhdx   <- yours; nothing points here
D:\AppSandbox\Forge-Flat\disk.vhdx             <- a copy; AppSandbox owns this folder
D:\AppSandbox\Forge-Flat\vm_state.json         <- {"installComplete":1}
```

Then, with **AppSandbox fully closed** — it rewrites `vms.cfg` and would overwrite the edit — append
a block to `vms.cfg`, copying the settings of the VM the disk came from and changing three things:

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
- **`SshPort`** must differ from every other VM's, so two VMs can never collide on the host port.

`GpuMode`, `GpuName` and `NetworkMode` have to match the original or the clone will behave
differently from the VM it came from — `NetworkMode=0` is what gives the forge VM no adapter, and
the [gateway](FORGE.md#network-no-adapter-and-egress-through-a-gateway) is its only way out. Save the file as UTF-8, start AppSandbox, and
the VM is in the list. A `snapshots\` folder appears beside the disk on first load.

### Or repoint the VM you already have

Smaller, and enough when you do not want a second VM: change `VhdxPath` on the existing block to the
flat disk, with a `vm_state.json` beside it. The VM keeps its name, its SSH port and everything
built around them, and now runs on a disk with **no chain at all** — nothing for the snapshot bug to
orphan. Its old folder stops being the VM's folder, which also takes it out of the delete path.

---

---

## How often this has to be repeated

Almost never, if the disk is kept honest — and that is a design decision, not a hope. What belongs in
the image in the first place is its own question, answered in
[FORGE.md](FORGE.md#what-the-base-image-must-contain).

A full-image copy costs a full-image write; there is no incremental version of `Convert-VHD`, and a
differencing child still merges its parents, so re-flattening always pays for the whole image again.
The only two levers are therefore **how big the image is** and **how seldom it has to be re-made**.
Both are controlled by what is allowed to live on the disk:

| what the guest holds | protected by | on the disk? |
|---|---|---|
| the engine, the compiler, the toolchain, MSYS2, the screen server | **this flatten** — they must be *installed*, not copied | yes, and this is the whole point |
| the guest's own settings, autologin, tunnel key, mapped drives | this flatten | yes |
| project source and assets | **git**, pushed to the host | no |
| Fab / vault assets | **the vault**, mounted read-only over SMB | no |
| derived data, shader and DDC caches | nothing — rebuildable | yes, but disposable |

So the flat base only goes stale when something that had to be *installed* changes: an engine
upgrade, a new Visual Studio workload, a Windows servicing update worth keeping. That is a handful of
events a year, each one already a deliberate act — which is exactly when a re-flatten is worth its
cost, and the rest of the time the disk holds nothing that git and the vault do not already hold.

**Re-flatten at milestones, never on a schedule.** The test is one question: *if this disk were lost
right now, what would I have to reinstall by hand?* If the answer is "nothing new since the last
base", there is nothing to copy.

### Making the wait cheap rather than short

It cannot be made short. It can stop costing attention:

- **It needs no human.** The preconditions are a stopped VM and an elevated shell, not a person at
  the screen. Start it and leave; `Get-VHD` afterwards is the only thing worth reading.
- **A second copy of an already-flat disk is just a file copy** — `robocopy /j` or `Copy-Item`, with
  no chain to merge. Duplicating an existing archive is much cheaper than making one.
- **Run the VM on the flat disk** ([repoint it](#or-repoint-the-vm-you-already-have)) and the chain
  stops growing under it, so the next flatten reads one file instead of a base plus a fat branch.
- Hyper-V's own changed-block tracking would in principle make this incremental, but AppSandbox does
  not expose its VMs to a backup stack, and driving Hyper-V behind its back is a good way to lose the
  disk this page exists to protect. *Unproven, and not recommended.*

## Rules that keep this safe

- **The archive folder is never a VM's folder.** Delete removes the folder recursively.
- **One disk per VM.** Two blocks pointing at one VHDX means two VMs booting the same disk.
- **Edit `vms.cfg` only while AppSandbox is closed**, including the headless daemon.
- **Mount a chain with `-NoDriveLetter`, onto a directory.** A differencing child inherits its
  parent's partition table, so parent and child carry the *same* volume identity. Windows remembers
  the letter it gave the parent and tries to reuse it for the child, which produces `E:\ is not
  accessible. The parameter is incorrect.`, an Explorer window frozen on a volume that is no longer
  what it was, and a letter `Get-Partition` reports while no provider can open it (*measured*).
  `Mount-VHD -NoDriveLetter` plus `Add-PartitionAccessPath -AccessPath <empty dir>`
  sidesteps the letter space entirely.
- **Keep the previous chain until the new disk boots**, then reclaim the space.
- **Re-flatten after work that had to be *installed*.** The base is a point in time; refreshing it is
  the same `Convert-VHD` again, at the same cost — so keep everything else off the disk and the
  refresh stays rare ([how often](#how-often-this-has-to-be-repeated)).

## Not this: registering the disk as a template

`vms.cfg` also accepts `[Template]` blocks with their own `VhdxPath`, and a VM created from a
template is a differencing child of it — structurally the ideal "base that can only ever be read".
The catch is that the template path is built for **sysprepped** images: the template unattend
generator boots audit mode and runs `sysprep /generalize /oobe /shutdown`, and instances get a
post-sysprep mini-setup unattend. Pointing it at a normal, configured disk is untested. It is worth
proving on a throwaway VM in an isolated data root before anyone relies on it — not on the disk that
matters.

## Measured

| finding |
|---|
| `vms.cfg` takes `VhdxPath` verbatim; no import exists in the UI or the API |
| The VM's folder is derived from the disk path, and `asb_vm_delete` removes it recursively |
| `vm_state.json` is read from beside the disk file, not from the derived folder |
| Hyper-V cmdlets are present and `vmms` runs, but every one of them needs elevation |
| Three snapshots of a real forge VM were 0 bytes; the branch held all 67.4 GB |
| A 135 GB chain flattened to one 107.7 GiB dynamic VHDX with an empty `ParentPath`; the file was written in 10 m 48 s (~170 MB/s), while `Convert-VHD`'s own progress percentage badly understated its progress |
| Copying that 107.7 GiB base **within one volume** (D: to D:) took **29.8 min**, about 60 MB/s — a third of the rate of the cross-volume `Convert-VHD` that produced it, because one disk serves both the read and the write. Budget a same-volume copy at roughly three times a cross-volume one |
| The repoint works: VM moved onto the flat disk and booted in 30 s, with `vms.cfg` rewritten in place. The layer mechanism has since replaced the job it did, and `dr-layer new` is how a VM gets a chain-free disk now |
