# LLMKube Mac mini M4

This runbook prepares the dedicated 16 GiB Mac mini M4 that serves the cluster's
Qwen3-Embedding-4B model through LLMKube Metal Agent. It covers local bootstrap, fixed networking,
headless recovery, power management, service ownership, model custody, Kubernetes identity, TLS,
monitoring, validation, upgrades, and decommissioning.

The accepted endpoint contract is:

| Purpose | Listener | Remote clients | Authentication |
| --- | --- | --- | --- |
| SSH administration | `10.25.13.95:22` | management/admin sources only | named admin SSH key |
| Embeddings | `10.25.13.95:8443` | Memini identity only | server TLS + bearer key |
| Metal child | `10.25.13.95:8081` | none | bearer key; packet-filtered from remote sources |
| Metrics | `10.25.13.95:9443` | vmagent identity only | mutual TLS |
| Metal health/metrics | `127.0.0.1:9090` | local Caddy only | loopback |

Caddy terminates remote TLS. Do not enable native TLS on the Metal-managed llama-server: Metal
Agent checks the selected child port over plaintext HTTP and would reject a TLS child. A separate
Service and EndpointSlice target Caddy on `10.25.13.95:8443`; consumers must not use Metal Agent's
direct child endpoint.

## Activation gate

Do not connect the appliance to production until all of these tracked Kubernetes artifacts exist and
have passed review:

- the LLMKube operator, CRDs, `Model`, and `InferenceService`, pinned by version and digest;
- the `ai` namespace Role and RoleBinding for the Mac client identity;
- the exact TLS, bearer-key, client-certificate, and CA Secrets issued through OpenBao;
- the external embedding Service and EndpointSlice for `10.25.13.95:8443`;
- Cilium policies for Memini, vmagent, DNS, and the Kubernetes API;
- matching SRX rules for TCP 22, 8443, and 9443, with TCP 8081 denied remotely;
- checksum-pinned Metal Agent, llama.cpp, Caddy, and sync-helper release artifacts;
- the system LaunchDaemon plists and validated Caddy configuration.

There is deliberately no `curl latest | sh` path. A release is deployable only when its exact source
revision, binary SHA-256, build flags, rollback artifact, and compatibility evidence are reviewed.
The llama.cpp build must provide Metal support and the selected embedding, pooling, alias, context,
parallelism, and API-key-file flags.

## Reviewed release bill

Every production artifact is immutable. The accepted set is:

| Artifact | Version/source | SHA-256 |
| --- | --- | --- |
| LLMKube chart | `0.9.24` | `6ebf474230fc0476c0f1db74802610778f741d39e2f007a0224056d84984fad6` |
| LLMKube controller image | `ghcr.io/defilantech/llmkube-controller:0.9.24` | `7b6b3f71a2bb4f1b30dae534deb0107eda39d60463b8cfa7ec14de9f02e4340e` |
| Metal Agent | `LLMKube-metal-agent_0.9.24_darwin_arm64.tar.gz` | `0885bd636f78fcb25369bdb5f746ac34e309ff7aa6c1f1b3304edcf87883afc6` |
| llama.cpp Metal | `b10621`, commit `c1d0e7a004015f23bc0233470b747b596f29b264` | `429c8270608600188035e5e92f7d78dffb7900904fe7dd7e6a84f48068cd13cf` |
| Caddy | `2.11.4`, `caddy_2.11.4_mac_arm64.tar.gz` | `9efb0af2d6cf09cfb5053c0e51721b9b3d4956d346234f39368d943d25a3c9a7` |
| kubectl | `1.36.4`, `darwin/arm64` | `c9e4f713d6fee0043a3d835cca13077cda2bc0973840eb9779360df0b5bdfc69` |
| Qwen3-Embedding-4B Q8_0 | revision `f4602530db1d980e16da9d7d3a70294cf5c190be` | `b60ae5ce2dd6a0b77f82cadf21def1f310a3e10cde380ad0081b07a9d416949d` |

The Metal Agent URL is
`https://github.com/defilantech/LLMKube/releases/download/v0.9.24/LLMKube-metal-agent_0.9.24_darwin_arm64.tar.gz`.
The llama.cpp URL is
`https://github.com/ggml-org/llama.cpp/releases/download/b10621/llama-b10621-bin-macos-arm64.tar.gz`.
The Caddy and kubectl URLs are their official GitHub release and `dl.k8s.io` paths. Download into a
new version directory, verify the table before extraction, and preserve the prior verified
directory.

Tracked appliance assets are also pinned at review time:

| Repository asset | SHA-256 |
| --- | --- |
| `scripts/llmkube-macos/sync` | `37ac2e6b507b18eafd6d734f439224def2b18dc3b1e40b4f145e445622471f2e` |
| `scripts/llmkube-macos/install-generation` | `50260711f3488c82f90632a3f8c25491b4148cda945527a7fca2fd22ea8a5a7d` |
| `scripts/llmkube-macos/switch-version` | `2e7e967f584f616ea0a0b8300a94f4c031dd642892bb885f687f0c9bb197fb1c` |
| `scripts/llmkube-macos/uninstall` | `451e5ae8244a1a8298869ae7a0b622462038a1b0d21fae84f39107f542c68728` |
| `scripts/llmkube-macos/Caddyfile` | `156256472b4a886ad71007a5fc40ba743cbc70f7dc763459941cb70e88009b93` |
| `scripts/llmkube-macos/io.monosense.llmkube-sync.plist` | `e1d1c2eec6bb06c2547e7e84a490d764998f172f2d1a5c0a8b2d0221b26edc5d` |
| `scripts/llmkube-macos/io.monosense.llmkube-metal-agent.plist` | `737d79b38d799f163260a4bc4bc54b99dfd9508061cb110a7aa5368ac45473cd` |
| `scripts/llmkube-macos/io.monosense.llmkube-caddy.plist` | `30cc4c27fcc6f44aaac100300526228b37641e8d94c3b45c9783ab0ba8881466` |
| `scripts/llmkube-macos/pf.llmkube.conf` | `90cb6e560b0d3e6dbd20d70142beb029ec95791e324379dd620275747701ec6a` |

Install these files root-owned from the exact reviewed Forgejo revision. Executables and versioned
binaries are mode `0555`; the Caddyfile and LaunchDaemon plists are mode `0644`. Install
`sync`, `install-generation`, `switch-version`, and `uninstall` under
`/usr/local/libexec/llmkube/`; install the Caddyfile under `/usr/local/etc/llmkube/`; install the
three plists under `/Library/LaunchDaemons/`. Verify the tracked hashes again on the Mac before
bootstrapping any service.

## Conventions

- `mac$`: the named, non-shared macOS administrator over a local console or SSH.
- `mac#`: a command run through `sudo` from that administrator.
- `_llmkube`: non-login macOS role account that owns the runtime.
- `/var/lib/llmkube`: runtime, kubeconfig, certificates, and model state.
- `/usr/local/libexec/llmkube`: immutable, root-owned executables and helpers.
- `/Library/LaunchDaemons`: system services that start before graphical login.

Never put a Kubernetes credential, private key, bearer key, or API response in argv, shell history,
logs, a model directory, or a user LaunchAgent.

## 1. Local first boot

A new Mac cannot complete Setup Assistant headlessly. Attach a temporary keyboard and display for
this one stage.

1. Install the reviewed macOS release and all required firmware updates.
2. Create one named administrator. Do not use a shared `admin` account.
3. Do not sign the appliance into iCloud or enable consumer synchronization services.
4. Set the host names:

```sh
sudo scutil --set ComputerName llmkube-mac
sudo scutil --set LocalHostName llmkube-mac
sudo scutil --set HostName llmkube-mac
```

5. Disable guest and automatic login, then verify both states:

```sh
sudo sysadminctl -guestAccount off
sudo sysadminctl -autologin off
sudo sysadminctl -guestAccount status
sudo sysadminctl -autologin status
```

6. Set automatic date/time and verify synchronization before requesting certificates:

```sh
sudo sysadminctl -automaticTime on
sudo sysadminctl -automaticTime status
systemsetup -getnetworktimeserver
```

A wrong clock blocks Kubernetes client authentication, TLS, and useful metrics. Stop if time is not
synchronized.

## 2. FileVault and physical boundary

The appliance intentionally runs without FileVault so it can recover from a cold power loss before
any user logs in. This is an availability decision with a physical-security cost.

```sh
sudo fdesetup status
sudo fdesetup disable
```

`fdesetup disable` is interactive and decryption may take time. Do not proceed until this reports
`FileVault is Off`:

```sh
sudo fdesetup status
```

Compensating controls are mandatory:

- locked rack or room;
- no unrelated personal data or credentials;
- one narrowly authorized Kubernetes identity;
- root-owned executables and LaunchDaemon definitions;
- `_llmkube`-owned mode `0600` kube private key and root-only sync-helper write path;
- immediate RoleBinding and certificate revocation after loss or theft;
- full erase during decommissioning.

## 3. Fixed network

The accepted SERVICES address is `10.25.13.95/24`, with gateway `10.25.13.1`. Use built-in Ethernet;
do not provide a Wi-Fi fallback that bypasses SRX policy.

First verify the service and hardware mapping:

```sh
networksetup -listallhardwareports
networksetup -listallnetworkservices
```

Then configure the service named `Ethernet`:

```sh
sudo networksetup -setmanual Ethernet 10.25.13.95 255.255.255.0 10.25.13.1
sudo networksetup -setdnsservers Ethernet 10.25.10.100
sudo networksetup -setv6off Ethernet
sudo networksetup -setnetworkserviceenabled Wi-Fi off
```

Verify address, route, resolver, and path MTU before continuing:

```sh
ipconfig getifaddr en0
route -n get default
scutil --dns
ping -c 3 10.25.13.1
ping -D -s 1468 -c 3 10.25.13.1
```

The interface name can differ even when the network service is `Ethernet`; use the hardware-port
output rather than changing the accepted address. PowerDNS and reverse records are Git-owned. Do not
create an mDNS-only production name or an out-of-band DNS mutation.

## 4. Restricted headless administration

Install the administrator's SSH public key before disabling passwords. Verify a second key-based
session remains open throughout the change.

Modern macOS includes `/etc/ssh/sshd_config.d/*.conf`. Derive the current named
administrator, refuse root/service identities, and create the root-owned drop-in:

```sh
admin_user="$(id -un)"
test "$admin_user" != root
case "$admin_user" in _*) exit 1 ;; esac
sudo install -d -o root -g wheel -m 0755 /etc/ssh/sshd_config.d
printf '%s\n' \
  'PasswordAuthentication no' \
  'KbdInteractiveAuthentication no' \
  'PermitRootLogin no' \
  "AllowUsers ${admin_user}" |
  sudo tee /etc/ssh/sshd_config.d/100-llmkube.conf >/dev/null
sudo chown root:wheel /etc/ssh/sshd_config.d/100-llmkube.conf
sudo chmod 0644 /etc/ssh/sshd_config.d/100-llmkube.conf
```

No service or shared account is allowed. Validate before reloading:

```sh
sudo sshd -t
sudo systemsetup -setremotelogin on
sudo launchctl kickstart -k system/com.openssh.sshd
```

From an approved management source, prove key-only login and prove a password attempt fails. Keep
Screen Sharing, Remote Management, AirDrop, and remote Apple events disabled. SSH must be reachable
only through the matching SRX rule; enabling Remote Login is not authorization to expose port 22 to
the whole SERVICES VLAN.

## 5. Power management

This appliance must never depend on a logged-in GUI session or an open terminal to remain awake.
Apply AC-power settings with `pmset`:

```sh
sudo pmset -a sleep 0
sudo pmset -a disksleep 0
sudo pmset -a displaysleep 10
sudo pmset -a standby 0
sudo pmset -a powernap 0
sudo pmset -a lowpowermode 0
sudo pmset -a ttyskeepawake 1
sudo pmset -a tcpkeepalive 1
sudo pmset -a womp 1
sudo pmset -a autorestart 1
sudo pmset -a autorestartatconnect 1
```

Do not copy laptop-only hibernation settings onto the Mac mini. Verify the supported
capabilities and effective AC profile:

```sh
pmset -g cap
pmset -g custom
pmset -g assertions
```

The accepted profile has system sleep, disk sleep, standby, Power Nap, and low-power mode disabled;
Wake-on-LAN, TCP keepalive, restart after power failure, and restart when AC reconnects enabled.
A display-sleep value is harmless when no display is attached.

### UPS

Connect the Mac and its upstream network path to the managed UPS. macOS must detect it:

```sh
pmset -g ups
```

Configure exactly one reviewed automatic-shutdown threshold appropriate to measured runtime. For
example, a 20 percent battery threshold is configured with:

```sh
sudo pmset -u haltlevel 20
```

Do not guess that a USB/network UPS is integrated. If `pmset -g ups` does not show live charge,
runtime, and power-source state, automated graceful shutdown is not proven and production activation
stops. Test loss of utility power, observe the shutdown threshold, and prove that restoring AC
cold-boots the Mac and its system LaunchDaemons without login.

## 6. Service account and filesystem

macOS role accounts require an underscore-prefixed name and an unused UID from 450 through 499.
Inspect current IDs, select one unused value, and record it in the host inventory:

```sh
dscl . -list /Users UniqueID
```

Create `_llmkube` as a role account with no login shell or secure token:

```sh
sudo sysadminctl -addUser _llmkube -roleAccount -UID 450 -GID 20 \
  -shell /usr/bin/false -home /var/lib/llmkube -fullName "LLMKube service"
sudo sysadminctl -secureTokenStatus _llmkube
```

UID 450 is valid only if the preceding inventory proves it unused. A secure token for `_llmkube` is
a failure.

Create the fixed layout:

```sh
sudo install -d -o root -g wheel -m 0755 /usr/local/libexec/llmkube
sudo install -d -o _llmkube -g staff -m 0750 /var/lib/llmkube
sudo install -d -o _llmkube -g staff -m 0750 /var/lib/llmkube/models
sudo install -d -o _llmkube -g staff -m 0700 /var/lib/llmkube/kube
sudo install -d -o _llmkube -g staff -m 0700 /var/lib/llmkube/tls
sudo install -d -o _llmkube -g staff -m 0700 /var/lib/llmkube/auth
sudo install -d -o _llmkube -g staff -m 0750 /var/log/llmkube
```

Executables and plists are root-owned and not writable by `_llmkube`. Runtime credentials are
`_llmkube:staff` mode `0600`. Model files are read-only to the service account after installation.

## 7. Model installation

The accepted model artifact is immutable:

| Field | Value |
| --- | --- |
| Repository revision | `f4602530db1d980e16da9d7d3a70294cf5c190be` |
| File | `Qwen3-Embedding-4B-Q8_0.gguf` |
| Size | `4,279,660,224` bytes |
| SHA-256 | `b60ae5ce2dd6a0b77f82cadf21def1f310a3e10cde380ad0081b07a9d416949d` |
| Alias | `qwen3-embedding` |
| Dimensions | `2560` |
| Context | `8192` |
| Pooling | `last` |
| Parallel slots | `2` |

Download to a protected temporary directory, verify size and hash, then install atomically:

```sh
tmpdir="$(mktemp -d)" || exit 1
trap 'rm -rf "$tmpdir"' EXIT
repo="https://huggingface.co/Qwen/Qwen3-Embedding-4B-GGUF"
revision="f4602530db1d980e16da9d7d3a70294cf5c190be"
file="Qwen3-Embedding-4B-Q8_0.gguf"
url="${repo}/resolve/${revision}/${file}"
curl --fail --location --proto '=https' --tlsv1.2 \
  --output "$tmpdir/model.gguf" "$url"
test "$(stat -f %z "$tmpdir/model.gguf")" = 4279660224
printf '%s  %s\n' \
  b60ae5ce2dd6a0b77f82cadf21def1f310a3e10cde380ad0081b07a9d416949d \
  "$tmpdir/model.gguf" | shasum -a 256 -c -
sudo install -o _llmkube -g staff -m 0440 "$tmpdir/model.gguf" \
  /var/lib/llmkube/models/Qwen3-Embedding-4B-Q8_0.gguf
```

Do not replace this file in place. A model change installs a new checksum-named artifact, runs the
benchmark, changes the Kubernetes model reference, and retains the previous verified file until
rollback expires. Memini's store is dimension-bound; changing dimensions requires logical export and
import into a new store.

## 8. Kubernetes client identity

Never copy an administrator kubeconfig to the Mac. Issue a dedicated one-year Kubernetes client
certificate into an empty protected directory:

```sh
mkdir -m 0700 ./llmkube-client
just kube llmkube-mac issue-csr ./llmkube-client
```

The helper creates a timestamped client CN and one exact RoleBinding to the tracked namespace Role.
This per-certificate binding makes overlap and revocation real: it does not rely on a group shared
by old and new certificates.

- validity: one year;
- expiry alert: 30 days;
- identity: one Mac service principal, no human group membership;
- namespace: `ai` only;
- permissions: exact LLMKube CRD read/status/EndpointSlice operations and `get` on named sync
  Secrets;
- revocation: delete the old certificate's exact RoleBinding and CSR record.

Install the private key and kubeconfig as `_llmkube:staff` mode `0600` at
`/var/lib/llmkube/client.key` and `/var/lib/llmkube/kubeconfig`. The kubeconfig contains the exact
API hostname, cluster CA, client certificate, and client key; `insecure-skip-tls-verify` and broad
contexts are prohibited.

Before installing LaunchDaemons, impersonate the identity from the Mac and prove:

- allowed reads/status operations succeed in `ai`;
- exact named Secret reads succeed;
- list/watch of Secrets fails;
- every other namespace fails;
- cluster-scoped mutation and exec fail.

Rotate with overlap: issue and install the new kubeconfig, restart Metal Agent and the sync helper,
prove reconciliation, then run `just kube llmkube-mac revoke <old-csr-name>`. This removes only the
old CN's RoleBinding; the new identity remains authorized.

## 9. Secret and certificate synchronization

cert-manager/OpenBao owns the embedding server certificate, vmagent client CA, and embedding bearer
keys. The Mac helper reads only exact named Secrets through its Kubernetes client identity.

For every sync:

1. Download into a mode `0700` temporary directory under `/var/lib/llmkube`.
2. Validate Secret resource identity and expected keys.
3. Validate PEM parsing, certificate chain, SAN, remaining lifetime, and key/certificate match.
4. Validate bearer-key file syntax; during rotation it contains both active old and new keys.
5. fsync each file and directory.
6. Atomically rename a complete generation and switch one symlink.
7. Run `caddy validate` against the new generation.
8. Reload Caddy and restart the Metal-managed child only when its API-key file changed.
9. Probe TLS, bearer acceptance, old/new rotation behavior, and mTLS metrics.
10. Retain the preceding generation for immediate rollback and emit only
    generation/checksum metadata.

A malformed, expired, wrong-SAN, incomplete, or unverifiable generation leaves the current one
active. Never write a private key or bearer value to unified logging.

## 10. System LaunchDaemons

Use system LaunchDaemons, not `~/Library/LaunchAgents`. Each plist is root-owned, mode
`0644`, stored under `/Library/LaunchDaemons`, and references absolute root-owned
executable paths.

Required services:

1. secret/certificate sync helper;
2. LLMKube Metal Agent running as `_llmkube`;
3. Caddy embedding and metrics proxy running as `_llmkube`.

Metal Agent must use:

- namespace `ai`;
- host IP `10.25.13.95`;
- fixed llama-server port `8081`;
- model store `/var/lib/llmkube/models`;
- memory-fraction default for 16 GiB unless the benchmark proves a safer explicit value;
- memory watchdog enabled and fail-closed admission;
- Apple power metrics enabled;
- exact InferenceService allowlist;
- kubeconfig under `/var/lib/llmkube/kube`.

Grant `_llmkube` passwordless sudo only for the exact upstream-reviewed `/usr/bin/powermetrics`
invocation. It receives no general `sudo`, shell, package-manager, or file-management command.

Validate and load each plist:

```sh
sudo plutil -lint /Library/LaunchDaemons/io.monosense.llmkube-sync.plist
sudo plutil -lint /Library/LaunchDaemons/io.monosense.llmkube-metal-agent.plist
sudo plutil -lint /Library/LaunchDaemons/io.monosense.llmkube-caddy.plist
sudo launchctl bootstrap system /Library/LaunchDaemons/io.monosense.llmkube-sync.plist
sudo launchctl bootstrap system /Library/LaunchDaemons/io.monosense.llmkube-metal-agent.plist
sudo launchctl bootstrap system /Library/LaunchDaemons/io.monosense.llmkube-caddy.plist
sudo launchctl print system/io.monosense.llmkube-sync
sudo launchctl print system/io.monosense.llmkube-metal-agent
sudo launchctl print system/io.monosense.llmkube-caddy
```

`RunAtLoad` and bounded restart backoff are required. Caddy waits for a valid generation;
Metal Agent waits for its kubeconfig/model and supervises llama-server. No service may
require a GUI login, unlocked user Keychain, interactive shell profile, or Homebrew user
environment.

## 11. Caddy and packet filtering

Caddy has two independent TLS listeners:

- `:8443`: server-authenticated TLS, only required embedding/health paths, reverse proxy to
  `127.0.0.1:8081`, bearer header preserved for llama-server validation;
- `:9443`: mTLS requiring the dedicated vmagent client CA, only `/metrics`, reverse proxy to
  `127.0.0.1:9090`.

Return 404 for every other path. Disable the admin API or bind it to a protected local Unix socket.
Do not publish Metal Agent health, llama.cpp metrics, Caddy diagnostics, model files, or directory
listings.

SRX is the routed policy authority, but the Mac packet filter is a second boundary. Its reviewed
anchor must:

- permit SSH only from accepted management sources;
- permit 8443 only from the Kubernetes/Memini path;
- permit 9443 only from the Kubernetes/vmagent path;
- deny remote TCP 8081 and 9090;
- allow established traffic and required outbound Kubernetes API, DNS, NTP, model-download, and
  certificate flows only;
- fail closed when the anchor cannot load.

Validate rules before enabling them and keep a local console during the first activation. Do not
invent broader source CIDRs to make a failed probe pass.

## 12. Acceptance tests

### 12.1 Functional

From Memini's identity:

1. verify the server chain and hostname on 8443;
2. prove no/malformed bearer keys receive 401;
3. request embeddings by alias `qwen3-embedding`;
4. verify every vector has exactly 2560 dimensions;
5. run the fixed corpus twice and compare dimensions, finite values, normalization expectations,
   latency, and stable similarity ordering;
6. record p50/p95 latency, throughput, Metal/RSS, memory pressure, and power.

From denied Kubernetes identities and other VLANs, 8443 must fail. Direct 8081 and 9090 must fail
from every remote source.

From vmagent, 9443 must require the correct client certificate and expose Metal Agent, memory,
model, and Apple power metrics. Wrong/no client certificates must fail.

### 12.2 Planned reboot

```sh
sudo shutdown -r now
```

Without logging in, prove in order:

1. ICMP/routing returns for `10.25.13.95`;
2. SSH key login works;
3. all three system LaunchDaemons are running;
4. model and valid secret generation are loaded;
5. Kubernetes EndpointSlice points to `10.25.13.95:8443`;
6. authenticated embedding succeeds;
7. vmagent scrape and alerts recover.

### 12.3 Unplanned power loss

Perform this destructive acceptance once before production with the model read-only, no software
update in progress, a healthy filesystem, and an operator at the rack:

1. confirm `autorestart=1` and `autorestartatconnect=1`;
2. remove AC while the appliance is serving a test request;
3. wait until it is fully off, then restore AC;
4. do not attach a display or log in;
5. repeat every planned-reboot proof;
6. inspect filesystem, launchd exit history, model checksum, TLS generation, EndpointSlice, and
   pending alerts.

Failure to cold-boot or start services pre-login blocks production. FileVault must not be silently
re-enabled to fix another control.

### 12.4 UPS

Remove utility input to the UPS while keeping its output active. Confirm macOS observes battery
state, shuts down at the configured threshold, and produces no credential-bearing logs. Restore
utility power and prove the complete headless boot path. Also test a short outage that should not
shut the Mac down.

## 13. Operations and upgrades

Alert on:

- Metal Agent, llama-server, Caddy, or sync helper absent;
- model load/checksum failure;
- embedding health, error rate, latency, or dimension mismatch;
- memory pressure, thermal pressure, power anomaly, and process eviction;
- certificate/client-certificate expiry and sync generation age;
- Kubernetes client certificate expiry within 30 days;
- vmagent scrape failure;
- UPS state and failed headless recovery.

Upgrade controller/CRDs, Metal Agent, llama.cpp/Caddy, and model in separate reviewed changes. For a
Mac binary change:

1. install a checksum-verified versioned file without replacing the active binary;
2. validate config and local health;
3. atomically switch the versioned symlink;
4. restart only the affected LaunchDaemon;
5. run functional and benchmark acceptance;
6. switch back immediately on regression;
7. retain the prior verified release until the observation window closes.

macOS updates are also reviewed maintenance. Prove the planned-reboot sequence after every update;
do not allow an update to re-enable FileVault, sleep, Wi-Fi, broad sharing, or automatic login.

## 14. Recovery and decommissioning

For an unreachable but powered Mac, use only the approved management path. The existing IBM KVM is
not assumed to provide this Mac's preboot keyboard/video path. If SSH and cold-boot recovery both
fail, physical console access is required.

After theft, retirement, or role replacement:

1. remove the Kubernetes RoleBinding and external EndpointSlice;
2. revoke/replace the client certificate, TLS generation, bearer keys, and vmagent client trust;
3. remove SRX and DNS entries;
4. unload LaunchDaemons and securely remove local runtime credentials;
5. use macOS Erase All Content and Settings or the reviewed full-device erase path;
6. verify the device no longer reaches Kubernetes, OpenBao-sourced Secrets, Memini, or metrics;
7. retain only non-secret benchmark and decommission evidence.

Never repurpose the appliance while its old Kubernetes identity or bearer keys remain valid.
