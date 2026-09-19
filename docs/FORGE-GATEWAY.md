# The forge gateway: the VM's egress, through a Draugr mound

> **Optional, and part of an optional feature.** This is the network half of
> [the forge](FORGE.md), a Windows VM an agent can build and test a game in. Nothing here matters
> unless you run one. Read [FORGE.md](FORGE.md) first: it is the overview, and it says where this
> fits.

**What this document is.** A forge VM has **no network adapter**, so on its own it cannot reach
anything. This is how it gets internet access anyway — through a Draugr mound whose `sbx` policy is
the allowlist, so the VM is filtered by exactly the rules and tools (`dr-policy`, kits) that filter a
mound. It is the build document for that gateway, and the measurement record behind it.

**Revision 6, 2026-09-18.** The design is tested end to end and ready to build, apart from the
[open items](#open-items). Written while it was a standalone plan; the parts that belong to the
forge as a whole have moved to [FORGE.md](FORGE.md).

| Revision | What changed |
|---|---|
| 2 | Written in a chat. Nothing was run. |
| 3 | Checked against the Draugr and AppSandbox sources, and against throwaway sandboxes (2026-09-13). |
| 4 | Tested against the Unreal VM: the tunnel, a guest with no network adapter, a restricted key, throughput and a reboot (2026-09-14, morning). |
| 5 | Tested the Epic Games Launcher, Fab and Unreal Editor 5.8 through the gateway, measured wildcard rules, and wrote the Unreal kit from the results (2026-09-14, afternoon). Reordered: the build steps come first, and history and evidence are in the appendices. |
| 6 | Tested Visual Studio 2022 and a C++ Unreal build (2026-09-18). Found and fixed the one real cost of having no adapter: certificate revocation checking. Recorded Windows Update patching the guest through the gateway, a guest bugcheck, and that the allowlist is per-IP in practice. |

**Test environment:**

- Host: Windows 11 Pro 26200 with `sbx` **0.37.1** and AppSandbox 0.1.4 (GUI).
- Guest: Windows 11 Home 10.0.26200 with `NetworkMode=0`, running the Epic Games Launcher 20.3.0,
  Unreal Engine 5.8.2 and Visual Studio Community 2022 17.14.41.

Every claim carries one of three labels:

- **measured**: run on this machine, with the result quoted.
- **read**: taken from source code (Draugr or AppSandbox), not run.
- **unmeasured**: not tested yet.

## Open items

1. **Debugging from Visual Studio.** Installing, building and the Unreal integration are measured
   ([step 4](#the-visual-studio-test-measured)). Pressing F5 once, which is where symbol servers such
   as `msdl.microsoft.com` would appear, is not.
2. **`dr-up` against the gateway repo** has not been run. Each piece it runs has been.
3. **Step 5** (narrowing the defaults) has not been done.
4. **A5** (the full reboot sequence) and **A7** (a one-file kit change) are unmeasured.

---

## The short version

The design works end to end *(measured)*. A guest with **no network adapter** reached the internet
only through an SSH reverse tunnel to an allow-all tinyproxy in a mound:

- Allowed hosts went through; denied hosts were refused and logged against the gateway.
- Throughput matched a direct download: 10.2 MB/s through the tunnel, 9.7 MB/s direct.
- An administrator in the guest could not get out any other way.
- The Epic Games Launcher, Fab and Unreal Editor 5.8 all worked through it, including a 131 MB
  download and a lighting build.

What revision 2 got wrong or did not know:

1. **`sbx` stops the gateway 30 s after the last session disconnects.** Traffic through a published
   port does not count as a session. One held `sbx exec … sleep infinity` session (a "keeper") keeps
   it up, but the keeper does not survive a Windows reboot. *(measured)*
2. **A kit's `commands.startup` stops running for good once the `sbx` daemon restarts,** and every
   Windows reboot restarts it. So the `post-up` hook starts tinyproxy, not the kit. *(measured)*
3. **A guest firewall cannot enforce a single allowlist,** because the agent drives the VM as a guest
   administrator. The guest has **no network adapter** instead. It reaches the gateway through an SSH
   reverse tunnel over AppSandbox's Hyper-V-socket SSH channel. That removes `netsh`, the host
   firewall rule, IP Helper and the need for host admin. *(measured)*
4. **The default allow rules do not cover Unreal,** but they do cover the AI endpoints and code
   hosts. Narrowing them is part of being done. *(measured)*
5. **With no adapter, Windows tells applications it is offline,** even while the proxy works. No tool
   tested has refused to run because of it: Epic's tools, the Visual Studio Installer and Visual
   Studio itself all use the proxy and decide for themselves. *(measured)* The one thing that really
   did break is finding 6.
6. **Certificate revocation checking fails while Windows has no interface at all,** and it takes
   down anything strict about it. CryptoAPI refuses to fetch OCSP, CRL or AIA with
   `ERROR_NOT_CONNECTED` before it ever reaches the proxy, so the chain cannot be completed. The fix
   is a **dummy loopback adapter** in the guest (D6): Windows then reports a network, the fetches go
   out through the proxy, and the guest still has no route anywhere. *(measured)*
7. **The allowlist is per-name at the rule and per-IP in practice.** A host that resolves to an IP
   already allowed for another host resolves and connects, even though `sbx policy check` calls it
   denied. *(measured)*
8. **Revision 2's agent-to-VM item was wrong.** A simpler path has been measured against the VM's
   real `sshd`, and it belongs to [the forge](FORGE.md). The guest also accepts **password** SSH logins,
   which should be switched off. *(measured)*
9. **The Unreal kit needs `**.` wildcards.** `*.example.com` matches exactly one label and not the
   bare domain; `**.example.com` matches both, at any depth. Epic's service hosts are shard-numbered
   and up to five labels deep. *(measured)*

---

## Architecture

```text
Windows VM  (AppSandbox, NetworkMode=0: NO network adapter)
  │  proxy settings  →  127.0.0.1:3128   (guest loopback)
  ▼
sshd in the guest: remote forward bound to 127.0.0.1 only (gatewayports no)
  │  Hyper-V socket  (AppSandbox's SSH relay: works with no adapter)
  ▼
Windows 127.0.0.1:<SshPort>   ←  ssh.exe -N -R 127.0.0.1:3128:127.0.0.1:18888   (vm-tunnel.ps1, restricted key)
  │
  ▼
Windows 127.0.0.1:18888       ←  DRAUGR_PORTS="127.0.0.1:18888:8888"
  │
  ▼
Gateway mound (draugr-gateway): tinyproxy allow-all, started and held up by the post-up hook
  │
  ▼
sbx egress policy             ←  THE allowlist: defaults − gateway kit denies + kits/unreal allows
  │
  ▼
Internet
```

| Property | Revision 2 (NAT, `netsh`, guest firewall) | This design (no adapter, SSH `-R`) |
|---|---|---|
| Can an admin in the guest bypass the allowlist? | **Yes** | **No**: no route out, no DNS; direct connections fail immediately, with or without the loopback adapter of D6 *(measured)* |
| Can the guest reach the LAN? | Yes, through NAT | No |
| Host admin needed | `netsh`, a firewall rule, IP Helper | None for the path (AppSandbox itself runs elevated) |
| Exposure on the host | A listener on a Hyper-V adapter | Loopback only |
| New moving parts | None | A supervised tunnel and a keeper |
| Cost | None | Windows reports "offline" to applications *(measured)*; Epic's tools do not mind |

**Fallback, only if a required tool refuses to work while Windows reports it offline, and has no
offline override:**

1. Keep `NetworkMode=1`.
2. Publish the gateway at runtime on `192.168.42.1`.
3. Add an inbound firewall rule scoped to `192.168.42.0/24`.
4. **Remove the guest's own route out on the host side**, and re-apply that after every AppSandbox
   start.

Without step 4 the fallback is decorative (appendix A, row 11). How to remove the route is
unmeasured, so treat it as its own spike. So far no tool has needed the fallback.

---

## Decisions

| | Decision | Recommendation |
|---|---|---|
| **D1** | Transport | SSH reverse tunnel with `NetworkMode=0`. *(measured working)* |
| **D2** | Allowlist posture | Get it working on the defaults plus `kits/unreal` (steps 1–4). It is **not done** until step 5 narrows the defaults. |
| **D3** | Skills mount on the gateway | Accept it on 0.37.1, since no agent runs there. Revisit with `--skills=off` once 0.43 ships and Draugr can pass it. |
| **D4** | `sbx` version | Build and accept on **0.37.1**. Re-run the acceptance checks after any upgrade: 0.43.0-rc3 adds idle auto-stop for `sbx create` sandboxes. |
| **D5** | Guest SSH hardening | Key-only logins: set `PasswordAuthentication no` once a working admin key is in place, and use a separate **restricted** key for the tunnel (step 2). |
| **D6** | Windows' offline state | Install a **dummy loopback adapter** in the guest (step 2). It carries no route, so it grants no egress, but it makes certificate revocation checking work. *(measured)* |
| **D7** | Windows Update in the guest | Turn **off** automatic updates in the forge base. The guest patches itself through the gateway and reboots while work is running. *(measured)* |

---

## Step 1: the gateway mound

A small git repo on a Windows drive, for example `/mnt/c/src/draugr-gateway`. Commit before `dr-up`,
because clone mode only sees commits (read).

```text
draugr-gateway/
├── .draugr.conf
├── .draugr/kit/spec.yaml       installs tinyproxy; the deny list (step 5)
├── .draugr/hooks/post-up       keeper, start tinyproxy, probe
├── kits/unreal/spec.yaml       the Unreal hosts, versioned here
├── windows/vm-tunnel.ps1       tunnel supervisor (step 3)
└── README.md                   why there are no proxy ACLs; which client honours which proxy setting
```

### `.draugr.conf`

```bash
# The gateway runs no agent. It holds one allow-all proxy whose egress is filtered
# by the sbx policy. Read README.md before adding anything that filters.
DRAUGR_AGENT=shell
DRAUGR_SANDBOX=draugr-gateway
DRAUGR_MEMORY=2g                          # default is 50% of host RAM, capped at 32 GiB
DRAUGR_CPUS=2
DRAUGR_PORTS="127.0.0.1:18888:8888"       # explicit address: identical on sbx 0.37 and 0.42+
DRAUGR_KIT=".draugr/kit kits/unreal"      # both repo-relative, both versioned here
DRAUGR_MEM_SYNC=off
```

`sbx create -p 127.0.0.1:18888:8888` was measured. `dr-up` passes `DRAUGR_PORTS` entries to `-p`
unchanged (read), but `dr-up` itself was not run. `kits/unreal` resolves inside the repo before the
library (read: `dr_kit_resolve`).

### `.draugr/kit/spec.yaml`

```yaml
schemaVersion: "2"
kind: mixin
name: gateway
displayName: Draugr gateway
description: Allow-all forward proxy for the Unreal VM. The sbx policy is the allowlist.

caps:
  network:
    # Nothing is allowed here. The Unreal hosts live in kits/unreal.
    # Step 5 fills this with the defaults the VM must not reach, one comment each.
    # deny wins over allow, so NEVER deny "**": it would also block kits/unreal.
    deny: []

commands:
  install:
    - command: "apt-get update -qq"
      user: "0"
      description: Refresh package lists
    - command: "env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq tinyproxy"
      user: "0"
      description: Install tinyproxy
  # Deliberately NO commands.startup. Measured on sbx 0.37.1: a sandbox's startup
  # commands stop running for good after sandboxd restarts, which every Windows
  # reboot does. .draugr/hooks/post-up starts tinyproxy on every dr-up instead.
```

Measured: the kit validates, the install takes about 12 s, and the test gateway was built with it.

### `kits/unreal/spec.yaml`

A real tool requested every entry during the 2026-09-14 test.
[Appendix D](#appendix-d-hosts-seen-during-the-tests) lists every host seen, including the ones left
out and why.

```yaml
schemaVersion: "2"
kind: mixin
name: unreal
displayName: Unreal toolchain egress
description: Hosts the Epic Games Launcher, Fab and the Unreal Editor need, confirmed from the gateway's policy log.

# Wildcards, measured on sbx 0.37.1 for rules from the CLI and from a kit:
#   "*.example.com"   matches exactly ONE label, and NOT example.com itself
#   "**.example.com"  matches example.com and every subdomain, at any depth
# Epic's service hosts are shard-numbered and 3-5 labels deep
# (library-service.live.use1a.on.epicgames.com), so exact names and "*." both break.
# Quote every entry that starts with "*": unquoted, YAML reads it as an alias.
caps:
  network:
    allow:
      # Epic-owned domains
      - "**.epicgames.com"     # sign-in, catalog, library, entitlements, friends, telemetry, self-update, download manifests
      - "**.epicgames.dev"     # Epic Online Services: api., connect.
      - "**.epicgamescdn.com"  # EOS overlay (eosh.), download chunks (egs-cloudfront-chunks.)
      - "**.unrealengine.com"  # Unreal Engine tab, editor news and components; www. is the post-up probe
      - "**.fab.com"           # Fab: www., static. (scripts and styles), media. (thumbnails)
      - "**.quixel.com"        # cdn.quixel.com: Megascans content shown in Fab
      # Shared CDNs: exact names only, never a wildcard over a CDN
      - egdownload.fastly-edge.com         # carried the 131 MB project download
      - epicgames-download1.akamaized.net  # requested in the same second; kept so downloads do not depend on the CDN Epic picks
      # Third parties embedded in Fab
      - "**.hcaptcha.com"           # Fab's bot check: js., <id>.w.
      - cdn.cookielaw.org           # Fab's cookie-consent banner
      - o10593.ingest.us.sentry.io  # Fab's error reporting; optional
      # Visual Studio 2022: installer, updates, licence (measured 2026-09-18)
      - "**.visualstudio.microsoft.com"  # download. (payloads and the VC redistributable), settings., telemetry., newsfeed.
      - aka.ms                           # redirector the installer and the VC redistributable follow
      - go.microsoft.com                 # redirector for installer links
      - app.vssps.visualstudio.com       # licence check at IDE start
      - builds.dotnet.microsoft.com      # .NET payloads pulled during a VS update
      # Visual Studio's Unreal integration downloads its UE plugin from GitHub releases
      - api.github.com                    # release lookup for microsoft/vc-ue-extensions
      - github.com                        # the release URL, which redirects to the asset host
      - release-assets.githubusercontent.com  # the asset itself (VisualStudioTools.zip)
      # Certificate revocation, needed by anything strict about it (see D6)
      - crt.sectigo.com   # AIA: the intermediate for GitHub's certificate
      - ocsp.sectigo.com  # OCSP for the same chain
      - crl.sectigo.com   # the CRL for the same chain
      - c.pki.goog        # Google Trust Services CRLs; used during the lighting build
      - ocsp.digicert.com # DigiCert chains, still common
      - crl3.digicert.com
      - crl4.digicert.com
      # Windows, on behalf of the tools
      - ctldl.windowsupdate.com   # certificate trust list download (plain HTTP), during the lighting build
      - wdcp.microsoft.com        # Defender cloud lookups: winget, and the editor's first start
      - wdcpalt.microsoft.com     # same
      - cdn.winget.microsoft.com  # winget source; drop if winget is not used
```

Revocation hosts are plain HTTP on port 80, and they are fetched by Windows itself, not by the tool
that needs them. Allow the ones for the CAs your tools' certificates chain to; the list above is what
GitHub, Epic and Microsoft used here. Expect to add to it when a CA rotates.

Measured:

- **Validation.** `sbx kit validate` reports this kit `VALID`. With `**.epicgames.com` unquoted it is
  `INVALID` (`did not find expected alphabetic or numeric character`).
- **Matching.** In a sandbox created with only this kit, `sbx policy check` allowed
  `library-service.live.use1a.on.epicgames.com`, `epicgames.com`, `media.fab.com`,
  `07bcbb4be341.w.hcaptcha.com` and `egdownload.fastly-edge.com`. It denied `other.fastly-edge.com`
  and `example.com`.

The `sbx` **defaults**, not this kit, allow two hosts the tools used: `c.pki.goog` (certificate
revocation, during the build) and `www.google.com` (the editor). Step 5 must keep that in mind.

### `.draugr/hooks/post-up`

**Measured end to end from WSL**, on a gateway whose kit startup command had stopped running after a
daemon restart:

- The first run started the keeper and tinyproxy, and the probe passed.
- A second run added no second keeper and no second tinyproxy.
- The gateway was still serving 45 s later, with nobody attached.

```bash
#!/usr/bin/env bash
# post-up - keep the gateway alive, make sure tinyproxy runs, prove it answers.
#
# Measured on sbx 0.37.1, and the reason this hook does three jobs:
#  - sbx stops a sandbox 30 s after its last session disconnects, and traffic
#    through a published port is not a session. One held
#    `sbx exec <name> sleep infinity` keeps it up. It dies with a reboot.
#  - A kit's commands.startup stops running for good once sandboxd restarts,
#    which every Windows reboot does. So tinyproxy is started here.
#  - A process started with setsid from an exec outlives that exec while the
#    keeper holds the mound.
set -euo pipefail

name=${DRAUGR_SANDBOX:?post-up runs from dr-up, which exports DRAUGR_SANDBOX}
proxy=http://127.0.0.1:18888
probe=${GATEWAY_PROBE_URL:-https://www.unrealengine.com/}

pwsh() { powershell.exe -NoProfile -NonInteractive -Command "$1" | tr -d '\r'; }

# 1. The keeper first, so the mound cannot auto-stop between the steps below.
keepers=$(pwsh "@(Get-CimInstance Win32_Process -Filter 'Name=''sbx.exe''' | Where-Object { \$_.CommandLine -match 'exec +$name +sleep +infinity' }).Count")
if [ "${keepers:-0}" = 0 ]; then
    pwsh "Start-Process -WindowStyle Hidden -FilePath (Get-Command sbx.exe).Source -ArgumentList 'exec','$name','sleep','infinity'" >/dev/null
    echo "post-up: started a keeper session for $name"
fi

# 2. tinyproxy, with NO destination filtering and NO Allow lines, on purpose:
#    the allowlist is the sbx policy (dr-policy), and every client arrives from
#    the sbx forwarder, 172.17.0.10, so Allow could not tell them apart anyway.
#    Base64 because the script crosses bash -> powershell.exe -> sbx.exe -> sh.
ensure=$(cat <<'SH'
conf=/tmp/tinyproxy-gateway.conf
printf '%s\n' 'Port 8888' 'Listen 0.0.0.0' 'Timeout 600' 'MaxClients 200' \
    'LogFile "/tmp/tinyproxy.log"' 'LogLevel Connect' > "$conf"
pgrep -x tinyproxy >/dev/null || setsid tinyproxy -d -c "$conf" </dev/null >/tmp/tinyproxy.out 2>&1 &
sleep 1
pgrep -x tinyproxy >/dev/null
SH
)
b64=$(printf '%s' "$ensure" | base64 -w0)
pwsh "sbx.exe exec $name bash -c 'echo $b64 | base64 -d | bash'" >/dev/null \
    || { echo "post-up: could not start tinyproxy in $name" >&2; exit 1; }

# 3. Prove the path. curl.exe, not WSL's curl: WSL cannot reach Windows loopback.
#    000 = nothing answered; 500 = tinyproxy saying sbx refused the host.
#    Anything else, including a 403 from the site itself, means the path works.
code=000
for _ in $(seq 1 15); do
    code=$(curl.exe -s -m 10 -o NUL -w '%{http_code}' -x "$proxy" "$probe" | tr -d '\r') || code=000
    case "$code" in
        000|500) sleep 2 ;;
        *) echo "post-up: gateway answers ($probe -> $code)"; exit 0 ;;
    esac
done
echo "post-up: $proxy does not reach $probe (last status $code)" >&2
echo "  tinyproxy running?   sbx.exe exec $name pgrep -a tinyproxy" >&2
echo "  probe allowed?       dr-policy --check $probe" >&2
exit 1
```

Then run `dr-trust .draugr/hooks/post-up`; Draugr refuses untrusted hooks. The hook was measured when
run directly with `DRAUGR_SANDBOX` set, not yet through `dr-up`.

### Done when

- [ ] `dr-kit validate` reports both kits valid.
- [ ] `dr-up` creates the mound and post-up prints `gateway answers`.
- [ ] In PowerShell, `curl.exe -x http://127.0.0.1:18888 -o NUL -w "%{http_code}" https://www.unrealengine.com/`
      returns neither `000` nor `500`, and `https://example.com` fails with
      `CONNECT tunnel failed, response 500`.
- [ ] Two minutes later, with nobody attached, `sbx ls` still shows `draugr-gateway running`.
- [ ] After `sbx daemon stop` and another `dr-up`, post-up prints `gateway answers`. This is the
      reboot path, without rebooting.

---

## Step 2: configure the VM

### Keys, before switching the network off

The VM was created without `sshDeployKey`, so install keys by pasting into an elevated PowerShell in
the guest. This procedure was measured:

```powershell
$f = 'C:\ProgramData\ssh\administrators_authorized_keys'
# your admin key (for you and for dr-forge), then the tunnel-only key:
Add-Content -Path $f -Encoding ascii -Value 'ssh-ed25519 AAAA...admin... you@host'
Add-Content -Path $f -Encoding ascii -Value 'restrict,port-forwarding,permitlisten="127.0.0.1:3128",command="cmd.exe /c echo tunnel-only" ssh-ed25519 AAAA...tunnel... draugr-tunnel'
icacls $f /inheritance:r /grant '*S-1-5-32-544:F' /grant '*S-1-5-18:F'
```

Generate both keypairs on the host with `ssh-keygen.exe -t ed25519`. Keep the private keys where only
your user can read them, because `ssh.exe` refuses keys that other users can read.

### Harden, cut the network, set the proxies

1. **Key-only SSH (D5).** Set `PasswordAuthentication no` in `C:\ProgramData\ssh\sshd_config`, then
   `Restart-Service sshd`. Check that the admin key still works before closing the session.
   *(unmeasured)*
2. **Network: None.** In the AppSandbox GUI:
   1. Stop the VM.
   2. Click the pencil; it turns into a check mark.
   3. Click the **Network** cell and choose **None**.
   4. Click the check mark, then start the VM.
3. **Proxies.** Windows client stacks each honour a different setting, so set all three:
   - WinHTTP: `netsh winhttp set proxy proxy-server="127.0.0.1:3128" bypass-list="<local>"`.
   - WinINet, **per user**, as the user who runs the tools: Settings → Network → Proxy → manual,
     `127.0.0.1:3128`.
   - Machine environment: `setx /M HTTP_PROXY http://127.0.0.1:3128` and
     `setx /M HTTPS_PROXY http://127.0.0.1:3128`.
4. **A dummy loopback adapter (D6).** See below: without it, certificate revocation checking fails
   and takes strict clients with it.
5. **Turn off automatic Windows Update (D7).** The guest patches itself through the gateway and
   restarts on its own schedule, which will interrupt a build:

   ```powershell
   $k = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
   New-Item -Path $k -Force | Out-Null
   New-ItemProperty -Path $k -Name NoAutoUpdate -Value 1 -PropertyType DWord -Force
   New-ItemProperty -Path $k -Name NoAutoRebootWithLoggedOnUsers -Value 1 -PropertyType DWord -Force
   Stop-Service wuauserv
   ```

   Delete those two values to let it patch itself again. That updates work at all through a gateway
   is a good property; updates deciding for themselves when to reboot is not.
6. **No guest firewall rule.** There is nothing left for it to block.
7. **Snapshot** this state as the forge base, after the firewall-prompt cleanup below.

### The loopback adapter

With no adapter, Windows has no network at all, and CryptoAPI will not even attempt to fetch OCSP,
CRL or AIA data: `certutil -urlfetch -verify` fails every URL with `ERROR_NOT_CONNECTED (0x800708ca)`
and the chain ends `CRYPT_E_REVOCATION_OFFLINE`. Nothing appears in the gateway's log, because no
request is made. Clients that ignore revocation results are unaffected, which is why the whole Epic
test passed; clients that insist fail, and Visual Studio's Unreal integration is one of them.

A Microsoft KM-TEST Loopback Adapter fixes it. It gets a link-local address and **no default route**,
so it adds no way out, but Windows now reports a network and CryptoAPI starts fetching, through the
proxy like everything else. Measured before and after, in the same guest:

| | No adapter | With the loopback adapter |
|---|---|---|
| `INetworkListManager.IsConnected` | False | **True** (`IsConnectedToInternet` stays False) |
| `certutil -urlfetch -verify` on GitHub's certificate | `CRYPT_E_REVOCATION_OFFLINE` | **passed**, `dwErrorStatus=0` |
| `curl` to `api.github.com` through the proxy | TLS failure | **HTTP 200** |
| Direct `curl` to `1.1.1.1`, DNS for `example.com`, ping | all fail | **all still fail** |

By hand, in the guest: run `hdwwiz.exe` → *Install the hardware that I manually select* → *Network
adapters* → *Microsoft* → *Microsoft KM-TEST Loopback Adapter*. `netcfg` cannot do it any more; on
Windows 11 it installs only protocols, services and clients. Scripted, it is what `devcon` does:

```powershell
# create a root-enumerated *MSLOOP device and bind netloop.inf to it (elevated)
Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices;
public static class DevInst {
  [StructLayout(LayoutKind.Sequential)] public struct SP_DEVINFO_DATA {
    public int cbSize; public Guid ClassGuid; public int DevInst; public IntPtr Reserved; }
  [DllImport("setupapi.dll", SetLastError=true, CharSet=CharSet.Unicode)]
  public static extern IntPtr SetupDiCreateDeviceInfoList(ref Guid ClassGuid, IntPtr hwndParent);
  [DllImport("setupapi.dll", SetLastError=true, CharSet=CharSet.Unicode, EntryPoint="SetupDiCreateDeviceInfoW")]
  public static extern bool SetupDiCreateDeviceInfo(IntPtr set, string name, ref Guid cls, string desc,
    IntPtr hwnd, int flags, ref SP_DEVINFO_DATA data);
  [DllImport("setupapi.dll", SetLastError=true, CharSet=CharSet.Unicode, EntryPoint="SetupDiSetDeviceRegistryPropertyW")]
  public static extern bool SetupDiSetDeviceRegistryProperty(IntPtr set, ref SP_DEVINFO_DATA data,
    int prop, byte[] buf, int len);
  [DllImport("setupapi.dll", SetLastError=true)]
  public static extern bool SetupDiCallClassInstaller(int fn, IntPtr set, ref SP_DEVINFO_DATA data);
  [DllImport("newdev.dll", SetLastError=true, CharSet=CharSet.Unicode, EntryPoint="UpdateDriverForPlugAndPlayDevicesW")]
  public static extern bool UpdateDriverForPlugAndPlayDevices(IntPtr hwnd, string hwid, string inf,
    int flags, out bool reboot);
}
'@
$cls = [Guid]'4d36e972-e325-11ce-bfc1-08002be10318'   # GUID_DEVCLASS_NET
$set = [DevInst]::SetupDiCreateDeviceInfoList([ref]$cls, [IntPtr]::Zero)
$dev = New-Object DevInst+SP_DEVINFO_DATA
$dev.cbSize = [Runtime.InteropServices.Marshal]::SizeOf([type][DevInst+SP_DEVINFO_DATA])
[void][DevInst]::SetupDiCreateDeviceInfo($set, 'NET', [ref]$cls, $null, [IntPtr]::Zero, 0x1, [ref]$dev)
$hwid = [Text.Encoding]::Unicode.GetBytes("*MSLOOP" + [char]0 + [char]0)  # REG_MULTI_SZ
[void][DevInst]::SetupDiSetDeviceRegistryProperty($set, [ref]$dev, 0x1, $hwid, $hwid.Length)
[void][DevInst]::SetupDiCallClassInstaller(0x19, $set, [ref]$dev)         # DIF_REGISTERDEVICE
$reboot = $false
[void][DevInst]::UpdateDriverForPlugAndPlayDevices([IntPtr]::Zero, '*MSLOOP',
  "$env:windir\inf\netloop.inf", 0x1, [ref]$reboot)
Get-NetAdapter
```

It takes effect at once, no reboot, and survives reboots. To undo: uninstall the adapter in Device
Manager. Check afterwards that `Get-NetRoute -DestinationPrefix '0.0.0.0/0'` returns **nothing** — if
a default route ever appears, the guest has a way out that the gateway does not control.

### Which client honours which proxy setting

Measured in the guest, with all three settings in place:

| Client | Honours | Does not honour |
|---|---|---|
| `curl.exe` | `-x`, or `HTTPS_PROXY` | — |
| WinHTTP (services, installers, Windows Update) | `netsh winhttp` | per-user settings |
| .NET Framework, PowerShell 5.1 `Invoke-WebRequest` | the per-user WinINet setting, or an explicit `-Proxy` | `netsh winhttp` |
| winget | `source update` worked with all settings in place, after allowing its three hosts | `search` failed with `0x8a15000f` with nothing further denied; probably winget over SSH, so recheck interactively |
| Epic Games Launcher, Unreal Editor (libcurl) | the Windows proxy: both log `bUseHttpProxy = true` and `HttpProxyAddress = '127.0.0.1:3128'`. All three settings were set, so which one they read is unmeasured. | — |
| Their embedded web views (CEF: the Unreal Engine tab, Fab) | the proxy, with all three set | — |
| Windows itself (Edge, widgets, telemetry, SmartScreen) | the proxy, once WinINet and WinHTTP are set; 22 hosts, none needed by the tools | — |

### Firewall prompts

Expect Windows Firewall prompts on the first run of the Epic Games Launcher, `UnrealEditor`,
`UnrealTraceServer`, `zenserver` and `SwarmAgent`. They ask about **inbound** access to ports those
programs open, not about going out. Accepting creates inbound allow rules on the Public profile
*(measured)*.

With no adapter nothing can connect in, and the programs talk to each other over loopback, so
**Cancel** should be enough *(unmeasured)*. Accepted rules matter only if the VM ever returns to NAT,
so remove them before taking the snapshot.

---

## Step 3: the tunnel supervisor and the preflight

**On the host, `windows/vm-tunnel.ps1`**, a supervisor loop. Each command in it was measured; the
script as a whole was not. `vms.cfg` is undocumented, so re-check the parser after AppSandbox updates.

```powershell
param([Parameter(Mandatory)][string]$Vm, [Parameter(Mandatory)][string]$User,
      [string]$Key = "$env:USERPROFILE\.ssh\draugr_tunnel_ed25519")

function Get-SshPort([string]$Name) {
    $vm = $null
    foreach ($line in Get-Content "$env:ProgramData\AppSandbox\vms.cfg") {
        if ($line -eq '[VM]') { $vm = @{} }
        elseif ($null -ne $vm -and $line -match '^(\w+)=(.*)$') {
            $vm[$Matches[1]] = $Matches[2]
            if ($vm.Name -eq $Name -and $vm.SshPort) { return [int]$vm.SshPort }
        }
    }
}

while ($true) {
    $port = Get-SshPort $Vm
    if ($port) {
        & ssh.exe -N -i $Key -p $port -o IdentitiesOnly=yes -o BatchMode=yes `
            -o StrictHostKeyChecking=accept-new -o ExitOnForwardFailure=yes `
            -o ServerAliveInterval=15 -o ServerAliveCountMax=3 `
            -R 127.0.0.1:3128:127.0.0.1:18888 "$User@127.0.0.1"
    }
    Start-Sleep -Seconds 10
}
```

When the guest reboots, `ssh.exe` exits and the loop reconnects once `sshd` answers again. The test's
supervisor retried every 4 s, needed 7 attempts, and then held *(measured)*.

A useful addition *(unmeasured)*: when `curl.exe -x http://127.0.0.1:18888 …` fails on the host, run
`wsl.exe -- bash -lc 'cd /mnt/c/src/draugr-gateway && dr-up'`. `dr-up` is idempotent and re-runs
post-up, which restores both the keeper and tinyproxy.

**Preflight in the VM launch path.** Before starting Unreal, run
`curl.exe -x http://127.0.0.1:3128 -o NUL -w "%{http_code}" https://www.unrealengine.com/` in the
guest, and refuse to continue on `000` or `500`.

---

## Step 4: extend `kits/unreal`

### The loop

1. With the gateway and tunnel up, run the next install or build step in the guest. Note whether the
   tool **refuses to try** because Windows reports no internet. A refusal with no offline override
   is the only trigger for the fallback.
2. In the gateway repo (WSL), run `dr-policy --denied`. Ignore entries ending in
   `.draugr-gateway.docker.internal`: they echo the real host listed next to them.
3. Run `dr-policy --allow <host>` for each host the tool genuinely needs, then retry.
4. Repeat within one `sandboxd` session, because the log lives in daemon memory.
5. Run `dr-kit adopt`, which writes into `.draugr/kit`, then move those lines into
   `kits/unreal/spec.yaml` with a comment each. Use `"**.domain"` for a vendor's own domain, and
   exact names for shared CDNs.
6. Run `dr-kit validate`, `dr-kit apply`, and then **`dr-up`**. `dr-kit apply` recreates the container
   and runs no hooks, so without `dr-up` there is no keeper and no tinyproxy.

### Lessons from the Epic test *(measured)*

- **Start from the kit in step 1, not from an empty kit.** A denied request fails, and applications
  do not reliably retry once the host is allowed:
  - The Launcher reloads a failed page when it sees connectivity return (`Connectivity restored;
    reloading errored web view`), but it did so before the page's image hosts were allowed.
  - The Fab tab stayed black until it was reopened.
  - Library and catalog requests that had failed were not retried until the next navigation.
- **A watcher makes the loop fast, but only on a test gateway.** A host-side script polled the policy
  log every 4 s and allowed each new denied host. A denial became a working retry within about 5 s.
  It allows everything it sees, Windows' own traffic included, so never point it at the real
  gateway. An adapted version, not run as written:

  ```powershell
  # discover.ps1 - TEST GATEWAYS ONLY: allows every host the gateway denies.
  param([Parameter(Mandatory)][string]$Sandbox, [int]$Minutes = 30)
  $seen = @{}
  $deadline = (Get-Date).AddMinutes($Minutes)
  while ((Get-Date) -lt $deadline) {
      $log = (& sbx.exe policy log $Sandbox --json) -join "`n" | ConvertFrom-Json
      foreach ($h in @($log.blocked_hosts | ForEach-Object { $_.host })) {
          # Denied entries stay in the log after allowing, hence $seen.
          if (-not $h -or $h -match '\.docker\.internal$' -or $seen.ContainsKey($h)) { continue }
          $seen[$h] = $true
          & sbx.exe policy allow network $h --sandbox $Sandbox | Out-Null
          '{0:HH:mm:ss} allowed {1}' -f (Get-Date), $h
      }
      Start-Sleep -Seconds 4
  }
  ```

- **The policy log names no process.** To tell which tool needed a host, note the time of each action
  and match it against first-seen times. Alternatively, read the tool's own log: Unreal's `LogHttp`
  warnings name the failing URL, next to `CONNECT tunnel failed, response 500`.
- **Your own probes land in the log too.** Anything you `curl` through the gateway looks exactly like
  tool traffic.

### The Visual Studio test *(measured)*

Native Unreal games need Visual Studio. Everything below ran on 2026-09-18 in the same guest, with
`NetworkMode=0`, against the `gwtest` gateway.

- **The Visual Studio Installer updates itself and Visual Studio.** It first says *"You are not
  connected to the internet. You might want to check your connection"*, and installs anyway after
  **Continue**: 17.14.40 → 17.14.41. The dialogue is the offline report from finding 5, and it is
  advisory, not a refusal.
- **Visual Studio starts and needs no sign-in.** It contacted `app.vssps.visualstudio.com` for the
  licence and never prompted.
- **Creating a C++ Unreal project** works, after Unreal asks for a newer `vc_redist`, which it
  downloads through the gateway. In the project browser, pick the **Blank** template first; the C++
  option is hidden on templates that do not offer it, which looks like C++ being unavailable.
- **Building works, from both sides.** `UnrealBuildTool` reported `Result: Succeeded` in 115 s from
  the command line, and Build Solution succeeded in the IDE.
- **The Unreal integration plugin fails to install, and this is the one real find.** Visual Studio
  reports `94% - WebException: Failed to download VisualStudioTools plugin` and
  `Failed to install plugin from GitHub to destination folder`. The gateway shows every CONNECT
  succeeding — `api.github.com`, `github.com`, `release-assets.githubusercontent.com` — and the whole
  exchange lasting 400 ms. The cause is revocation checking (finding 6): the same download through
  the same proxy returns HTTP 200 and the full 495,224-byte asset with `curl
  --ssl-revoke-best-effort`, and works unconditionally once the loopback adapter is in place.
- **Windows Update patched the guest through the gateway**, unasked: KB5124008 (26200.9445),
  KB5126052, KB5007651 and KB890830, followed by two `TrustedInstaller` restarts,
  *"Operating System: Upgrade (Planned)"*, in the middle of a shader compile. Hence D7.

**Still unmeasured:** pressing F5 once, which is where symbol servers such as `msdl.microsoft.com`
would appear. `api.nuget.org` was never requested.

---

## Step 5: narrow the defaults (required before calling this done)

1. Run `dr-policy --defaults` and go through it rule by rule.
2. For each default the VM has no business reaching, add a `caps.network.deny` entry with a reason.
   At minimum close the AI endpoints (`api.anthropic.com` is allowed by default). Decide `github.com`
   deliberately: Unreal source builds come from Epic's GitHub organisation, and Visual Studio's
   Unreal integration downloads its plugin from a GitHub release.
3. Keep:
   - `archive.ubuntu.com` and `security.ubuntu.com`, which the gateway's install fetches;
   - `c.pki.goog`, used for certificate revocation during the lighting build;
   - `www.google.com`, which the editor used for an unknown purpose; test before denying it.
4. List each host you close. Never deny `**`.
5. Check each with `dr-policy --check <host>`, which should report `denied by local rule
   "kit:draugr-gateway:deny"`. Then run `dr-kit validate`, `dr-kit apply` and `dr-up`.

---

## Step 6: acceptance criteria

| # | Criterion | Proof | Status |
|---|---|---|---|
| A1 | An allowed host works from the guest | `curl.exe -x http://127.0.0.1:3128 … https://www.unrealengine.com/` is not `000` or `500`, and the gateway log shows it allowed | measured (test gateway) |
| A2 | A non-allowed host fails and is logged against the gateway | `https://example.com` gives `CONNECT tunnel failed, response 500`, and `dr-policy --denied` lists it | measured (test gateway) |
| A3 | No direct route out, even as guest admin | `Get-NetRoute -DestinationPrefix '0.0.0.0/0'` is empty, `curl.exe --noproxy "*" https://1.1.1.1/` fails in 0 ms, DNS does not resolve, and ping fails | measured, both without an adapter and with the loopback adapter of D6 |
| A4 | The gateway stays up unattended | 5 minutes after `dr-up`, with nobody attached, it is running and A1 passes | measured with a keeper (80 s+, then 45 s+) |
| A5 | Reboot recovery | After a reboot: start AppSandbox elevated, start the VM, `dr-up` in the gateway repo, start `vm-tunnel.ps1`, then A1 | pieces measured; the full sequence unmeasured |
| A6 | Daemon restart recovery | `sbx daemon stop`, `dr-up`, then A1 | measured with the hook |
| A7 | Adding a domain touches one file | Edit `kits/unreal`, run `dr-kit validate && dr-kit apply && dr-up`, then A1 for that host | unmeasured |
| A8 | `dr-policy --check` predicts the guest | Five sampled hosts agree with A1 and A2 | measured for 4 hosts |
| A9 | Narrowing is real | `dr-policy --check api.anthropic.com` is denied by the kit, and the guest gets `500` | measured (test kit) |
| A10 | Each Unreal tool works while Windows reports offline | Step 4 | **measured** for the Epic Games Launcher (sign-in, Fab, Library, a 131 MB download), Unreal Editor 5.8 (Fab plugin, lighting build through Swarm, Play), the Visual Studio Installer, Visual Studio 2022 and a C++ project build; **unmeasured** for F5 debugging |
| A11 | Upgrade safety | After any `sbx` upgrade, A1–A10 pass again | — |
| A12 | Certificates validate in the guest | `certutil -urlfetch -verify` on a leaf from a host the tools use reports the revocation check passed, and the gateway logs the OCSP, CRL and AIA fetches | measured, with the loopback adapter of D6 |

---

## Beyond this plan

### Agent → VM

This belongs to the forge as a whole, and is written up there as
[the channel](FORGE.md#the-channel-how-the-mound-reaches-the-forge). The measurement it rests on:

Measured against the VM's real `sshd`, with **no `netsh`, no WSL address and no host admin**:

- In the agent's mound: `sbx policy allow network --sandbox <agent-mound> localhost:<SshPort>`.
- From inside that mound:
  `ssh -o ProxyCommand='socat - PROXY:gateway.docker.internal:%h:%p,proxyport=3128' -p <SshPort> <user>@host.docker.internal`
- Result: `Remote protocol version 2.0, remote software version OpenSSH_for_Windows_10.0`, then
  `Authentications that can continue: publickey,password,keyboard-interactive`. The full SSH
  handshake got through; the test stopped at authentication on purpose. `socat` is in the `shell`
  image; check the agent's image.
- **SSH port only, never the AppSandbox API.**
- **Switch password authentication off first** (D5). Otherwise a mound given this rule can try to
  guess the guest admin password.
- Re-read the port at every start, and reap stale `localhost:` rules.

### Findings that affect Draugr itself

These are wrong for **every** Draugr user today, forge or no forge, so they are fixed in Draugr's
core rather than here — see [FORGE.md, track B](FORGE.md#order-of-work). Each needs tests and a
`CHANGELOG.md` entry. Only the `host.docker.internal` one is on the forge's critical path.

- **Auto-stop contradicts Draugr's docs.** `dr-go` says the mound is "still running", and the
  `DRAUGR_STOP_ON_EXIT` rationale assumes an idle mound keeps serving. The daemon log shows real
  mounds auto-stopping since 2026-08-25. Consider a keep-alive key.
- **Kit `commands.startup` is unreliable,** yet Draugr's kit example, skill and CONFIG.md recommend it
  for services. After the first reboot, a service started that way never comes back until the mound
  is recreated.
- **`host.docker.internal` reaches Windows loopback, given a `localhost:<port>` rule.** Measured
  against HTTP and a real `sshd`. The docs say it resolves to the mound's own gateway, and that
  services must bind `0.0.0.0`.
- **`dr-policy --denied` lists the `<host>.<sandbox>.docker.internal` echoes** as real hosts.
- **`dr-policy --check` can disagree with the sandbox.** `sbx policy check` answers per name, but a
  host whose address another rule has already opened resolves and connects anyway. Worth saying so
  wherever Draugr presents the check as authoritative, and worth reporting upstream.
- **Wildcard semantics are undocumented.** The kit example mentions wildcards but not that `*.` is a
  single label, that `**.` is needed for depth and the bare domain, or that both must be quoted.
- **The forge plan needed corrections,** now made in [FORGE.md](FORGE.md): the daemon needs
  elevation; the SSH port is persisted; `NetworkMode=0` with SSH is measured, and so is its cost
  (Windows reports offline); its channel spike is superseded by *Agent → VM* above; a Windows 11
  **Home** guest works.

---

## Known limitations

- **Windows reports the guest offline.** No tool tested has refused to run because of it, though the
  Visual Studio Installer warns about it first (A10). A tool that treats the connectivity status as
  authoritative may still refuse.
- **An allowed name admits every host sharing its IP.** `crl.sectigo.com` resolved and returned
  HTTP 200 from inside the guest while `sbx policy check` reported
  `Denied: no matching allow rule (default deny)`, because it shares an address with
  `crt.sectigo.com`, which was allowed. From inside the sandbox, `crl.usertrust.com`,
  `ocsp.usertrust.com` and `crl.comodoca.com` all resolved to that same address without ever being
  allowed, while `sectigo.com` and `www.cloudflare.com` stayed blocked *(measured)*. So a rule is
  enforced per name at DNS but per address at connect time: allowing one host on a shared CDN
  quietly admits its neighbours there. Default-deny still holds for anything on an address no rule
  has opened, but do not read the rule list as an exact statement of what is reachable.
- **The guest patches itself through the gateway.** Windows Update downloaded and installed four
  updates and restarted the VM twice during a test session, `TrustedInstaller` reporting
  *"Operating System: Upgrade (Planned)"* *(measured)*. Useful for keeping a forge base current,
  disruptive while work is running; D7 turns it off.
- **A newly needed host breaks the first request.** Applications do not reliably retry once the host
  is allowed, so reopen the page or restart the tool.
- **Epic can change hosts.** Epic's own domains are covered by `**.` wildcards, but the shared CDN
  names are exact. A new CDN would show up as a failed download; check `dr-policy --denied` first.
- **Only HTTP(S) leaves.** Raw TCP and UDP are blocked. HTTPS on non-standard ports is unmeasured.
- **The guest's GPU is paravirtualised, and Unreal can take the guest down with it.** Compiling the
  path tracer's ray-tracing shaders first killed the NVIDIA user-mode driver in an editor background
  worker (the callstack ended in `nvwgf2umx.dll` below `D3D12Core.dll`), and a later run ended in a
  guest bugcheck, `0x3B SYSTEM_SERVICE_EXCEPTION (c0000005)`. Around it, AppSandbox's own display
  driver `AppSandboxVDD.dll` crashed six times in 45 s until Windows gave up on the adapter: *"App
  Sandbox Virtual Display Adapter is offline due to a user-mode device crash. Windows will no longer
  attempt to restart this device."* The GPU itself stayed healthy (`NVIDIA GeForce RTX 4090 |
  status=OK`). Nothing to do with the gateway, but it limits what a forge VM can render; setting
  `r.RayTracing=False` and `r.PathTracing=False` in the project avoids the shaders involved. Note
  that a project template may set `r.RayTracing=True` further down the same section, and the last
  value wins. *(measured)*
- **Crash reporting works through the gateway.** Unreal's crash reporter uploaded to
  `datarouter.ol.epicgames.com` and logged `All uploads done`, from a guest reporting no internet.
  *(measured)*
- **The liveness chain is long:** AppSandbox → VM → tunnel supervisor → keeper → tinyproxy →
  gateway. A reboot or a `sandboxd` restart breaks the keeper and tinyproxy until `dr-up` runs again.
  The guest preflight is the backstop.
- **A kit change is an outage** (`dr-kit apply`, then `dr-up`).
- **The policy log is not an audit trail,** because it lives in daemon memory.
- **Clients that connect by IP address.** A CONNECT to one address with a different SNI reached the
  SNI host, not the address. TLS without SNI is unmeasured.
- **Newer `sbx`:** 0.42 switches to `tcp4` (neutral here), and 0.43 adds idle auto-stop and changes
  the skills flag. Run A11.
- **Never publish a gateway port on a non-loopback address casually.** Doing so once during testing
  made Windows Firewall prompt, and accepting created inbound allow rules for `sbx.exe` on the Public
  profile.

---

## Appendix A: revision 2, claim by claim

| # | Revision 2 said | Verdict | Evidence |
|---|---|---|---|
| 1 | `sbx` publishes to Windows loopback, not WSL | **True, and more flexible than stated** | `-p 127.0.0.1:18888:8888` bound only `127.0.0.1`. A non-loopback address also works (`sbx ports --publish 172.24.224.1:…`), but it triggers a Windows Firewall prompt and this plan does not need it. *(measured)* |
| 2 | Since 0.42.0 `--publish` defaults to `tcp4` | **True** | 0.42.0 release notes. Neutral here, because the plan names `127.0.0.1` explicitly. |
| 3 | One static `netsh` rule, `<host-ip>` stable forever | **Wrong premise, and no longer needed** | The AppSandbox NAT host is `192.168.42.1` (fallback `192.168.142.1`), recreated at every daemon start *(read)*. `vEthernet (AppSandboxNAT) 192.168.42.1/24` was present *(measured)*. |
| 4 | The defaults make Epic, NuGet and symbol traffic "mostly just work" | **Wrong** | Denied by default: `www.unrealengine.com`, `epicgames.com`, `download.epicgames.com`, `launcher-public-service-prod06.ol.epicgames.com`, `api.nuget.org`, `msdl.microsoft.com`, `aka.ms`, `download.visualstudio.microsoft.com`. Allowed: `github.com`, `dl.google.com`, `api.anthropic.com`. *(measured)* |
| 5 | Spike: is a tunnelled request matched on hostname? | **Yes** | tinyproxy connects directly; `sbx` intercepts transparently and denies at DNS; tinyproxy returns `500`; the log names the gateway sandbox. Guest traffic appeared the same way. *(measured)* |
| 6 | No CA to install | **True** | Windows `curl.exe`, the guest and the Epic tools all validated real certificates through the gateway. *(measured)* |
| 7 | Restrict tinyproxy `Allow` to the expected client | **Does not work** | Every published-port client arrives as `172.17.0.10`. *(measured)* |
| 8 | `commands.install` installs and starts tinyproxy | **Wrong, and `commands.startup` does not fix it** | `startup` runs within one daemon lifetime, but never again for that sandbox after a daemon restart or reboot, even across later stop/start cycles. *(measured)* |
| 9 | Create the gateway with `--no-share-skills` | **Not possible through Draugr today** | The flag is hidden (`feature.shareSkills=false`), and `dr-up` cannot pass it. 0.43 replaces it with `--skills=`. *(measured + read)* |
| 10 | Kit `deny` wins over the defaults | **True** | `denied by local rule "kit:gwkit:deny"`. *(measured)* |
| 11 | A guest firewall preserves the single allowlist | **Not enforceable** | The SSH login is a guest administrator. In NAT mode the guest reported a Hyper-V adapter with internet connectivity. *(measured)* |
| 12 | Non-HTTP protocols are blocked | **True** | Raw TCP carried nothing; UDP gave `Direct UDP connections not allowed`. *(measured)* |
| 13 | One gateway is a throughput bottleneck | **No, at this line speed** | 67 MB: host direct 9.6 MB/s, host via gateway 9.5, guest direct 9.7, guest via tunnel **10.2**. A 131 MB Epic download ran at 6.7 MB/s. *(measured)* |
| 14 | It is a single point of failure | **True, and worse than stated** | Auto-stop, a keeper that dies with a reboot, and startup commands that stop running (short version, points 1 and 2). *(measured)* |
| 15 | Agent → VM via `netsh` and `DRAUGR_HOST_PORTS`, "no new code" | **Wrong** | `dr-hostport` allows WSL's address, not Windows loopback. See [Agent → VM](#agent--vm). *(read + measured)* |
| 16 | After a reboot, `dr-up` restores connectivity with no manual step | **Wrong** | AppSandbox must run elevated *(read)*. After the reboot the gateway came back without tinyproxy until the hook ran *(measured)*. |
| 17 | VM traffic appears in "the sbx audit log" | **True, with caveats** | It is logged against the gateway, but held in daemon memory (cleared on restart), and every DNS denial is echoed as `<host>.<sandbox>.docker.internal`. *(measured)* |
| 18 | Discovery: watch for `no matching allow rule` | **The VM never sees that** | Clients see `CONNECT tunnel failed, response 500`; `dr-policy --denied` on the gateway has the names. *(measured)* |
| 19 | Library kit via `dr-kit save unreal`, versioned | **Self-contradictory** | `save` copies the project's own kit; the library is not versioned; `adopt` writes only the project kit. *(read)* |
| 20 | (not mentioned) memory | **Must be set** | The default is 50% of host RAM, capped at 32 GiB. A 2 GiB, 2-CPU gateway handled every test. *(measured)* |

---

## Appendix B: spike results

| | Question | Result |
|---|---|---|
| **S1** | Does an SSH reverse forward carry HTTPS into the guest? | **Yes.** The guest listener binds `127.0.0.1:3128` only. `github.com` returned 200 and `www.unrealengine.com` 403 (from the site itself). `example.com` and `api.anthropic.com` (denied by the kit) both got `500`. All of it was logged against the gateway. `sshd -T`: `allowtcpforwarding yes`, `gatewayports no`. |
| **S2** | Does it work with **no adapter**? | **Yes; Windows reports the guest offline.** SSH answered immediately after the switch to `NetworkMode=0`. No adapter, no IP, no DNS, and direct connections to `1.1.1.1:443` failed in 0 ms for an admin. The tunnel worked, but Windows' connectivity status stayed `IsConnected=False IsConnectedToInternet=False`. |
| **S3** | Throughput | **No overhead.** 67 MB in the guest: 9.7 MB/s direct (NAT) versus 10.2 MB/s through the tunnel. The line is the limit. |
| **S4** | Tunnel key | **A restricted key works.** `restrict,port-forwarding,permitlisten="127.0.0.1:3128",command="…"` allowed the 3128 tunnel, refused 3129 (`remote port forwarding failed for listen port 3129`), and ran the forced command instead of `whoami`. |
| — | SSH port | `SshPort` stayed the same across VM replacement, VM restarts and a reboot. AppSandbox reuses it unless the port is busy (read). |

---

## Appendix C: measurement record

### 2026-09-13, host side

Windows 11 Pro 26200, `sbx` v0.37.1, `shell` template (Ubuntu 26.04, tinyproxy 1.11.3). Sandboxes
`gwspike` and `gwkit`.

- **The mound's egress.** `HTTP(S)_PROXY=http://gateway.docker.internal:3128`, resolver
  `172.17.0.10`. A process ignoring the proxy variables is intercepted transparently.
- **Denial.** tinyproxy logs `No address associated with hostname`. `sbx policy log` records
  `DNS lookup blocked by proxy policy`, plus the `.docker.internal` echo. Clients see
  `CONNECT tunnel failed, response 500`.
- **Certificates.** Real certificates through tinyproxy (Sectigo for `github.com`), which Windows
  schannel validated. The explicit proxy re-signs IP-literal CONNECTs with the Docker Sandboxes CA.
- **Published ports.** Clients appear as `172.17.0.10`. Ports persisted across stop and restart.
  Publishing on `172.24.224.1` worked and triggered the firewall prompt.
- **Auto-stop.** `session disconnected, deferring auto-stop … 30000000000`. The sandbox stopped
  within 40 s of the last `exec`, despite a request every 8 s. With a held `exec` it stayed up 80 s+.
- **Kit.** Validated. Deny beat the default allow. Allow reached the origin.
- **Non-HTTP.** Raw TCP carried nothing; UDP was refused.
- **Throughput.** 8.8 MB/s direct, 9.4 MB/s via the gateway.
- **Host loopback.** Reached with a `localhost:<port>` rule via `host.docker.internal`, over HTTP and
  CONNECT; nothing over direct TCP.

### 2026-09-14 morning, the VM

AppSandbox 0.1.4 GUI. Guest: Windows 11 Home 10.0.26200, 16 GB, 8 cores, `GpuMode=1`. `sshd` is
`OpenSSH_for_Windows_10.0` (`allowtcpforwarding yes`, `gatewayports no`,
`passwordauthentication yes`, `pubkeyauthentication yes`, `strictmodes yes`). Test gateway `gwtest`:
the gateway kit plus a startup command, published on `127.0.0.1:18888`.

- **The `post-up` hook, first version (keeper and probe only), run from WSL.** Run 1 started a keeper
  and the probe passed (403 from the origin); run 2 added no keeper. The mound was still running 50 s
  after an `exec` ended.
- **Agent → VM.** SSH from the test sandbox to the VM's `sshd`, through the `sbx` proxy with a
  `localhost:<SshPort>` rule: the handshake completed and stopped at authentication.
- **NAT mode.** Windows reported connected with internet access, over one Hyper-V adapter.
- **S1, in NAT mode.** The guest listener was `127.0.0.1:3128`. `github.com` 200,
  `www.unrealengine.com` 403, `example.com` and `api.anthropic.com` 500.
- **S3.** 67,419,304 bytes each time: host direct 9,645,734 B/s; host via gateway 9,457,972 B/s;
  guest direct 9,705,492 B/s; guest via tunnel 10,162,322 B/s.
- **S4.** `whoami` with the restricted key returned `tunnel-only`. `-R 3129` exited with
  `remote port forwarding failed for listen port 3129`. `-R 3128` stayed up and carried traffic.
- **Reboot, the first attempt at S2.** Windows shut down at 22:13 and booted at 08:44:
  - The keeper was gone.
  - After a restart the container had no tinyproxy, and `/tmp` still held yesterday's config,
    unmodified.
  - A later clean `sbx stop` and start still gave no tinyproxy.
- **Startup semantics, on a fresh sandbox `gwstart`:**
  - At creation, tinyproxy was running and the config had just been written.
  - After two stop/start cycles, the config was rewritten both times.
  - After `sbx daemon stop` (new daemon PID) and a start: **not rewritten, no tinyproxy**.
  - After a further stop/start: still nothing.
- **S2, with `NetworkMode=0` set through the GUI's inline edit:**
  - `SshPort` unchanged; SSH answered immediately.
  - No adapters, no IPv4 addresses, no connection profiles.
  - Windows reported `IsConnected=False IsConnectedToInternet=False`.
  - DNS: `No DNS servers configured for local system`.
  - Direct `github.com`: `Could not resolve host`. Direct `1.1.1.1:443`:
    `Failed to connect … after 0 ms`.
- **S2, through the tunnel:**
  - `github.com` 200, `example.com` 500; curl honoured `HTTPS_PROXY` (200).
  - WinHTTP COM: fails with no setting, 200 with `netsh winhttp`.
  - `Invoke-WebRequest`: fails by default, ignores `netsh winhttp`, 200 with the WinINet proxy or
    `-Proxy`.
  - Windows still reported offline 20 s after each setting.
- **winget.** Round 1 denied `cdn.winget.microsoft.com`, `wdcp.microsoft.com` and
  `wdcpalt.microsoft.com`, which were then allowed. In round 2, `source update` said `Done`;
  `search` returned `0x8a15000f` with nothing new denied.
- **The final hook, on `gwtest`** (stopped, startup no longer running): run 1 started the keeper and
  tinyproxy, and the probe returned 403. Run 2 left one keeper and one tinyproxy. 45 s later it was
  running, and the probe returned 200.
- **Cleanup.** The test keys were removed from the guest and refused afterwards. WinHTTP and WinINet
  were restored. The local keys were deleted, and `gwtest` and `gwstart` were removed.

### 2026-09-14 afternoon, the Epic test (A10)

The same VM, still `NetworkMode=0`, now with the Epic Games Launcher 20.3.0 and Unreal Engine 5.8.2
installed. The setup:

- a fresh `gwtest` from the step 1 kits and the final hook (keeper, tinyproxy, probe 200);
- a new test key;
- guest WinHTTP, WinINet and machine `HTTP(S)_PROXY` set to `127.0.0.1:3128`;
- a host-side watcher that kept the tunnel up and allowed every denied host (step 4).

Results:

- **Guest reboot.** The tunnel's `ssh.exe` exited. The watcher restarted it every 4 s until the
  guest's `sshd` answered (7 attempts in 26 s), and then it held. The proxy settings survived the
  reboot. The Launcher starts at login, and was already using the proxy.
- **Launcher:**
  - Its log reads `bUseHttpProxy = true`, `HttpProxyAddress = '127.0.0.1:3128'`.
  - Requests to hosts not yet allowed failed with `CONNECT tunnel failed, response 500` (libcurl
    error 56).
  - Once they were allowed: `Launcher is up-to-date with the latest available version`, the account
    signed in, and `Connectivity restored; reloading errored web view`.
  - Windows reported `IsConnected=False IsConnectedToInternet=False` throughout.
- **Fab tab.** Black while `static.fab.com` (56 requests within a second) and `js.hcaptcha.com` were
  denied; it worked after being reopened.
- **Wildcards, as command-line rules on `gwtest`:**
  - With `*.epicgames.com`: `store.epicgames.com` got CONNECT 200.
    `lightswitch-public-service-prod06.ol.epicgames.com` and `epicgames.com` got 500, logged as
    `DNS lookup blocked by proxy policy`.
  - `*.hcaptcha.com` did not cover `<id>.w.hcaptcha.com`.
  - With `**.epicgames.com`: `fortnite-public-service-prod11.ol.epicgames.com` got CONNECT 200.
  - With `**.quixel.com`: `quixel.com` got 200.
- **Download.** Fab "Create Project" gave `TotalDownloadedData: 131482248`,
  `AverageDownloadSpeed: 6,688,522 bytes/sec`, `OverallRequestSuccessRate: 1.000000` and
  `ErrorCode: OK`. The hosts requested in that second were
  `egs-cloudfront-chunks.epicgamescdn.com`, `egdownload.fastly-edge.com`,
  `epicgames-download1.akamaized.net` and `selective-download-egs.distro.on.epicgames.com`.
- **Editor 5.8.2:**
  - Its log has the same proxy lines.
  - There were three sessions: the project browser, then the project twice. Each session's only
    HTTP failure was one `datarouter.ol.epicgames.com` request cancelled at exit.
  - The Fab plugin 0.0.15 loaded.
  - Lightmass through Swarm finished `170/170 mappings`, twice.
  - Play worked, as reported by the tester.
- **Firewall prompts.** Accepting them created Public-profile inbound allow rules, for TCP and UDP,
  for `EpicGamesLauncher`, `UnrealEditor`, `unrealtraceserver.exe`, `zenserver.exe` and
  `SwarmAgent`. The listeners seen were the Launcher on UDP `0.0.0.0:6666` (Unreal's message bus)
  and the EOS helper on TCP `127.0.0.1:35783`.
- **Kit.** A `**.` entry validates only when quoted, and kit rules matched exactly as command-line
  rules did (step 1). The sandbox used for that check was removed, and `sbx policy ls` showed no
  rules left for it.

### 2026-09-18, the Visual Studio test (A10, A12)

Same VM and same `gwtest` gateway, after the guest had been reverted to a snapshot and Visual Studio
Community 2022 17.14 installed over NAT, then returned to `NetworkMode=0`.

- **Installer and IDE.** The Visual Studio Installer warned *"You are not connected to the
  internet"*, then updated 17.14.40 → 17.14.41 through the gateway. Visual Studio started, contacted
  `app.vssps.visualstudio.com` and never asked anyone to sign in.
- **C++ project and build.** Unreal requested a newer `vc_redist`, which downloaded through the
  gateway. `UnrealBuildTool` finished `Result: Succeeded` in 115 s; Build Solution in the IDE
  succeeded too. The guest reports 4 physical and 8 logical cores, which is what makes shader
  compilation slow.
- **Revocation, before the loopback adapter.** `certutil -urlfetch -verify` on the leaf of
  `api.github.com` (`CN=*.github.com`, issuer `Sectigo Public Server Authentication CA DV E36`):

  ```text
  Failed "AIA"   http://crt.sectigo.com/SectigoPublicServerAuthenticationCADVE36.crt
  Failed "OCSP"  http://ocsp.sectigo.com
  Error retrieving URL: This network connection does not exist. 0x800708ca (ERROR_NOT_CONNECTED)
  CertUtil: The revocation function was unable to check revocation because the revocation server
  was offline.
  ```

  The chain also came back `CERT_TRUST_IS_PARTIAL_CHAIN`, because the intermediate could not be
  fetched either. Nothing was logged at the gateway: no request was made. `curl` through the proxy
  failed with `CRYPT_E_REVOCATION_OFFLINE`; the same `curl` with `--ssl-revoke-best-effort` returned
  HTTP 200 and the full 495,224-byte `VisualStudioTools.zip`.
- **Revocation, after the loopback adapter.** `Leaf certificate revocation check passed`,
  `dwErrorStatus=0`, and tinyproxy logged CryptoAPI's own fetches:
  `GET http://crt.sectigo.com/…crt`, `POST http://ocsp.sectigo.com/`,
  `GET http://crl.sectigo.com/…crl`. `curl` without any relaxation returned HTTP 200.
- **Isolation, after the loopback adapter.** Only `169.254.138.214/16` link-local, no default route,
  `curl --noproxy "*" https://1.1.1.1/` failing in 0 ms, `Could not resolve host: example.com`,
  ping False — and HTTP 200 through the proxy.
- **Per-IP reachability.** See the limitation above: `crl.sectigo.com`, `crl.usertrust.com`,
  `ocsp.usertrust.com` and `crl.comodoca.com` were all reachable on an address allowed for
  `crt.sectigo.com`, while `sectigo.com` and `www.cloudflare.com` were not.
- **Windows Update.** KB5124008 (26200.9445), KB5126052, KB5007651 and KB890830 installed through
  the gateway, with two `TrustedInstaller` restarts.
- **Guest bugcheck.** `0x3B` with `AppSandboxVDD.dll` crashing repeatedly; see the limitations. The
  minidump is in the guest's `C:\Windows\Minidump`.

### State after testing

- **Removed:** `gwspike`, `gwkit`, `gwstart`, the morning's `gwtest` and the kit-check sandbox, with
  their rules and ports.
- **Kept:** `gwtest`, with 5 kit rules and 113 command-line rules — every host seen in both tests,
  Windows' own traffic and the tester's probes included, so it is much broader than the kit. The
  guest keeps its proxy settings (originals backed up in `%ProgramData%`), the test key, the
  accepted firewall rules, the loopback adapter, the Windows Update policy values and the
  `VisualStudioTools` plugin in the test project. The policy log, tinyproxy log and rule exports
  were saved outside the repo.

---

## Appendix D: hosts seen during the tests

Every host the guest's traffic reached the gateway with, taken from the gateway's policy log and
tinyproxy's log. Hosts in the "Tester's probes" row were the tester's own `curl` requests, not a
tool's.

| Group | Hosts | In the kit as |
|---|---|---|
| Epic services | `account-public-service-prod.ak.`, `account-public-service-prod03.ol.`, `launcher-public-service-prod06.ol.`, `catalog-public-service-prod06.ol.`, `entitlement-public-service-prod08.ol.`, `friends-public-service-prod06.ol.`, `priceengine-public-service-ecomprod01.ol.`, `api.kws.ol.`, `datarouter.ol.`, `library-service.live.use1a.on.`, `social-ban-public-service-prod.social.live.on.`, `ue-launcher-website-prod.ol.`, `tracking.`, `static-assets-prod.`, `cdn1.`, `selective-download-egs.distro.on.`, each followed by `epicgames.com` | `**.epicgames.com` |
| Epic Online Services | `api.epicgames.dev`, `connect.epicgames.dev` | `**.epicgames.dev` |
| Epic CDN | `eosh.epicgamescdn.com`, `egs-cloudfront-chunks.epicgamescdn.com` | `**.epicgamescdn.com` |
| Unreal Engine tab and editor | `www.`, `assets.`, `cms-assets.`, `editor.`, `components.`, each followed by `unrealengine.com` | `**.unrealengine.com` |
| Fab | `www.fab.com`, `static.fab.com`, `media.fab.com`, `cdn.quixel.com` | `**.fab.com`, `**.quixel.com` |
| Embedded in Fab | `js.hcaptcha.com` and three `<id>.w.hcaptcha.com`; `cdn.cookielaw.org`; `o10593.ingest.us.sentry.io` | `**.hcaptcha.com`, and exact names |
| Download CDNs | `egdownload.fastly-edge.com`, `epicgames-download1.akamaized.net` | exact names |
| Windows, for the tools | `ctldl.windowsupdate.com` (port 80), `wdcp.microsoft.com`, `wdcpalt.microsoft.com` | exact names |
| Visual Studio 2022 | `download.`, `settings.`, `telemetry.`, `newsfeed.`, each followed by `visualstudio.microsoft.com`; `app.vssps.visualstudio.com`; `aka.ms`; `go.microsoft.com`; `builds.dotnet.microsoft.com` | `**.visualstudio.microsoft.com` and exact names |
| Visual Studio's Unreal integration | `api.github.com`, `github.com`, `release-assets.githubusercontent.com` | exact names |
| Certificate revocation (port 80, fetched by Windows) | `crt.sectigo.com`, `ocsp.sectigo.com`, `crl.sectigo.com`, `c.pki.goog`; DigiCert's `ocsp.`, `crl3.`, `crl4.` added for chains not seen here | exact names |
| Visual Studio telemetry and feedback, left out | `default.exp-tas.com`, `targetednotifications-tm.trafficmanager.net`, `sendvsfeedback2.azurewebsites.net`, `mobile.events.data.microsoft.com` | no |
| Windows Update, left out | `tas02.sls.update.microsoft.com`, `oneclient.sfx.ms`, `msedge.api.cdp.microsoft.com`, `displaycatalog.mp.microsoft.com`, `msedge.b.tlu.dl.delivery.mp.microsoft.com`, `storeedgefd.dsx.mp.microsoft.com` | no; see D7 |
| Allowed by the `sbx` defaults | `c.pki.goog` (port 80), `www.google.com`; Chromium's own `optimizationguide-pa.`, `update.` and `safebrowsing.googleapis.com` | not in the kit; see step 5 |
| Windows background, left out | `self.events.data.microsoft.com`, `settings-win.data.microsoft.com`, `fd.api.iris.microsoft.com`, `edge.microsoft.com` (ports 80 and 443), `api.edgeoffer.microsoft.com`, `edge-consumer-static.azureedge.net`, `nav-edge.smartscreen.microsoft.com`, `explore.microsoft.com`, `storeedgefd.dsx.mp.microsoft.com`, `ecs.office.com`, `g.live.com`, `assets.msn.com`, `api.msn.com`, `c.msn.com`, `ntp.msn.com`, `srtb.msn.com`, `windows.msn.com`, `img-s-msn-com.akamaized.net`, `www.bing.com`, `th.bing.com`, `c.bing.com`, `sb.scorecardresearch.com` | no |
| Tester's probes | `store.epicgames.com`, `dev.epicgames.com`, `status.epicgames.com`, `lightswitch-public-service-prod06.ol.epicgames.com`, `fortnite-public-service-prod11.ol.epicgames.com`, `epicgames.com`, `epicgamescdn.com`, `download.epicgamescdn.com`, `docs.unrealengine.com`, `unrealengine.com`, `fab.com`, `newassets.hcaptcha.com`, `hcaptcha.com`, `quixel.com`, `www.quixel.com`, `github.com` | — |
