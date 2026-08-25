# Blocky DNS Resolver

Blocky is a forwarding DNS proxy and advertisement filter deployed as the Doco-CD project
`blocky-c0` on `c0` at `10.25.13.35`. It proxies private `monosense.io` forward and reverse zone
queries to PowerDNS Authoritative at `10.25.13.33`, and proxies public names to Cloudflare and
Quad9 over DoH.

**`10.25.10.100` remains production DNS.** No DHCP scope, Junos configuration, Kubernetes
manifests, AdGuard Home, PowerDNS, OpenBao, Omada Controller, or Doco-CD itself is modified.
Client cutover to Blocky is a separate, future reviewed change.

---

## Deployed evidence

| Fact | Value |
|---|---|
| Merge commit | `0f45077a55e3d5fe9a2c7e043b59166f1d3f2020` |
| Doco job | `01a03974-234d-73f0-b291-4bcbe69cb63a` (succeeded) |
| Container created | `2026-08-25T15:05:15.528456098Z` |
| Container ID | `f763d13b741bf57aab38d256e429a2dd6fa1e454f96c4bd028e94ccb99cd2b67` |
| Container state | Healthy |
| Image | `spx01/blocky:v0.34.0` |
| Image digest | `sha256:595136fb127f4c952b621113e668c09acdcf15ac054d96ee6d4c51a76c35f5fd` |
| Platform | `linux/amd64` |
| UID / GID | `100 / 100` |
| Capabilities | None (`cap_drop: [ALL]`) |
| NNP | Enabled |
| Root filesystem | Read-only |
| Network | `c0_services` only |
| Blocky address | `10.25.13.35` |
| Published host ports | None |
| Config mount | One read-only mount at `/app/config.yml` |
| HaGeZi blocklist entries | 189,012 (imported at startup) |
| UDP public resolution | `cloudflare.com A NOERROR` in 16 ms |
| TCP cached resolution | `cloudflare.com A NOERROR` in 0 ms |
| Private forward | `c0.monosense.io A → 10.25.10.20` via PowerDNS |
| Private reverse | `ns1.monosense.io PTR → 10.25.13.33` via PowerDNS |
| Blocked domain | `ads.01film.cc → NXDOMAIN` |
| Allowed public domain | `example.com → NOERROR` |
| Unavailable upstream | UDP + TCP → public `cloudflare.com` NOERROR; private zones unaffected |
| Repeated blocklist refresh failure | Public DNS remains NOERROR |
| Unreachable private authority | SERVFAIL for that private suffix; public DNS unaffected |
| Unchanged IDs | Doco, OpenBao, PowerDNS, Omada |

---

## Current scope

- **Node:** `c0`
- **Doco-CD project:** `blocky-c0`
- **Address:** `10.25.13.35` on `c0_services`
- **Image:** `spx01/blocky:v0.34.0` (`sha256:595136fb127f4c952b621113e668c09acdcf15ac054d96ee6d4c51a76c35f5fd`)
- **Platform:** `linux/amd64`
- **State:** Deployed and healthy; no client traffic directed yet

---

## Role

Blocky is a **forwarding DNS proxy**, not an authoritative server. It does not store zone data;
every query is proxied to an upstream resolver:

- **Conditional private proxy** — forwards `monosense.io` and the four reverse `in-addr.arpa` zones
  to PowerDNS Authoritative at `10.25.13.33`.
- **Public recursive proxy** — forwards all other names to Cloudflare (`1.1.1.1`) and Quad9
  (`9.9.9.9`) via DoH, with the HaGeZi Multi NORMAL wildcard blocklist applied.

Clients continue using AdGuard Home at `10.25.10.100` without change. Blocky is deployed and
healthy; client cutover is a separate future step.

---

## Architecture and DNS flow

```
Client
  |
  | UDP/TCP :53
  v
Blocky  10.25.13.35  (c0_services IPvlan)
  |
  +-- "monosense.io" / "*.in-addr.arpa" --> PowerDNS  10.25.13.33  :53
  |                                             (authoritative, unsigned)
  |
  +-- all other domains --> Cloudflare DoH  https://1.1.1.1/dns-query
  |                   \-> Quad9 DoH       https://9.9.9.9/dns-query
  |                   (random upstream, 3 s timeout, retries another on failure)
  |
  +-- blocklist evaluation (HaGeZi Multi NORMAL)
  +-- cache (upstream TTL honored for positives; negative cached 5 m)
```

Blocky does not perform recursive walking itself. It never falls back to the public internet for
the conditional zones — that fallback is explicitly disabled.

---

## Network and exposure

Blocky binds only the DNS port on `c0_services`. No host port is published.

| Property | Value |
|---|---|
| Docker network | `c0_services` (external, IPvlan L2) |
| Parent interface | `enp0s31f6.2513` |
| Static IPv4 | `10.25.13.35/24` |
| Gateway | `10.25.13.1` |
| Protocol | IPv4 only |
| Published host ports | None |

Inbound access is limited to the SERVICES VLAN. Clients on MGMT (`10.25.10.0/24`) and HOME
(`VLAN 2512`) are not automatically granted access.

---

## Rootless, capability, and sysctl model

Blocky runs entirely without root or privileged capabilities:

| Setting | Value | Effect |
|---|---|---|
| `user` | `"100:100"` | Runs as UID/GID 100, not root |
| `cap_drop` | `[ALL]` | Every Linux capability is removed |
| `cap_add` | none | No elevated capability granted |
| `security_opt` | `no-new-privileges:true` | Prevents privilege escalation via exec |
| `read_only` | `true` | Root filesystem is immutable |
| `sysctls` | `net.ipv4.ip_unprivileged_port_start=53` | Allows UID 100 to bind port 53 without capability |

The image ships a scratch-based binary that holds `CAP_NET_BIND_SERVICE` on disk. Because
`cap_drop: [ALL]` is applied after container creation, that capability is also dropped at
runtime. The `ip_unprivileged_port_start=53` sysctl (namespaced per-container) allows the
unprivileged UID to bind port 53 inside the network namespace without any capability.

Memory swappiness is disabled (`mem_swappiness: 0`). CPU and memory are hard-limited to 0.5
vCPU and 256 MiB; memory+swap are equal to prevent swapping.

---

## Configuration ownership

`config.yml` is Git-authored and mounted read-only at `/app/config.yml`. No secret, credential,
API token, or environment variable is required. The file is validated structurally before
deployment but never printed or committed with sensitive values.

---

## Listeners

Only DNS over UDP and TCP is enabled:

```yaml
ports:
  dns:
    - ":53"
  http: []
  https: []
  tls: []
```

HTTP, HTTPS, DoH, DoT, and DoQ listeners are explicitly empty. The API, Prometheus metrics,
and query log are all disabled:

```yaml
prometheus:
  enable: false
statistics:
  enable: false
queryLog:
  type: none
log:
  level: info
  format: json
  privacy: true
```

---

## Public DoH upstreams

Blocky proxies public resolution to two independent DoH providers:

```yaml
upstreams:
  init:
    strategy: blocking
  groups:
    default:
      - https://1.1.1.1/dns-query#cloudflare-dns.com
      - https://9.9.9.9/dns-query#dns.quad9.net
  strategy: random
  timeout: 3s
connectIPVersion: v4
```

- **IP-literal DoH with TLS name:** The URLs use IP addresses (`1.1.1.1`, `9.9.9.9`) directly.
  The `#cloudflare-dns.com` and `#dns.quad9.net` name suffixes set the TLS SNI hostname and
  certificate verification name, so Blocky validates the correct certificate without performing
  DNS resolution to reach the upstream. This avoids the bootstrap problem entirely.
- **Init `blocking`:** The `init` group is queried once at startup. If all init upstreams fail,
  Blocky logs the error and keeps running if possible. When it cannot proceed, the container exits.
- **Random strategy:** Each query selects one upstream at random. If the selected upstream times
  out (3 s), Blocky retries the other available upstream.
- **IPv4 only:** `connectIPVersion: v4` avoids IPv6, which is disabled on `c0_services`.

---

## Private conditional zones and PowerDNS ownership

Five zones are proxied directly to PowerDNS Authoritative at `10.25.13.33`:

```yaml
conditional:
  fallbackUpstream: false
  mapping:
    monosense.io:            10.25.13.33
    10.25.10.in-addr.arpa: 10.25.13.33
    11.25.10.in-addr.arpa: 10.25.13.33
    12.25.10.in-addr.arpa: 10.25.13.33
    13.25.10.in-addr.arpa: 10.25.13.33
```

- `monosense.io` — private forward zone (hosts `c0`, `c1`, `adguard`, `k1`–`k5`, `ns1`, `vault`)
- Four `in-addr.arpa` reverse zones — `10.25.10`, `11.25.10`, `12.25.10`, `13.25.10`
- `fallbackUpstream: false` — any query that PowerDNS cannot answer receives NXDOMAIN from
  Blocky; it never leaks to Cloudflare or Quad9
- Zones are unsigned; PowerDNS serves them as plain A/PTR records without DNSSEC
- Blocky caches responses for private zones per the upstream TTL (honored when `minTime` and
  `maxTime` are `0s`)

---

## Blocking and HaGeZi list

```yaml
blocking:
  denylists:
    default:
      - https://raw.githubusercontent.com/hagezi/dns-blocklists/a3d0c5c7a0402f669f3f1392527b8a50622128cf/wildcard/multi.txt
  allowlists:
    default:
      - |
        monosense.io
        *.monosense.io
        10.25.10.in-addr.arpa
        11.25.10.in-addr.arpa
        12.25.10.in-addr.arpa
        13.25.10.in-addr.arpa
        # Add future false-positive exceptions below this line
  clientGroupsBlock:
    default:
      - default
  blockType: nxDomain
  blockTTL: 5m
  loading:
    strategy: fast
    refreshPeriod: 12h
    downloads:
      timeout: 10s
      attempts: 3
      cooldown: 1s
```

- **List:** [HaGeZi Multi NORMAL](https://github.com/hagezi/dns-blocklists) — a relaxed,
  balanced wildcard blocklist. The URL is pinned to a specific GitHub commit
  (`a3d0c5c7a0402f669f3f1392527b8a50622128cf`) with SHA-256
  `a6d2dc1790cb7abb5984e9ff3649167dccbb8f694ffe6b88565b0f8ecf1d6036`. Updates require a
  separate reviewed PR to change the commit hash; they are not automatic. If the CDN source
  changes between PR and deployment, the pinned hash provides a verifiable checkpoint.
- **Refresh:** Every 12 hours Blocky re-downloads the same pinned URL. If the remote file has
  changed at that commit (it will not for a given commit hash), the new bytes are retained in
  memory. Failed refresh attempts retry three times with a 1-second cooldown; on continued failure
  the last successful in-memory group is retained.
- **Loading strategy `fast`:** On first start there is no disk cache — the blocklist group is
  empty until the first download completes, so queries are answered without filtering until
  that point. After a successful download, subsequent background refreshes keep the in-memory
  group current. If a single refresh fails after all attempts, the last successful in-memory
  group is retained.
- **Allowlist:** The inline block protects all private zones from accidental blocking: exact
  `monosense.io`, wildcard `*.monosense.io`, and each of the four reverse zones. Entries are
  checked before the blocklist. Future false-positive exceptions are appended below the commented
  divider. The block is not a separate file.
- **Block type:** `nxDomain` returns NXDOMAIN. The TTL is 5 minutes.
- **Client group:** All clients map to the `default` group.

---

## Cache

```yaml
caching:
  minTime: 0s
  maxTime: 0s
  cacheTimeNegative: 5m
  maxItemsCount: 10000
  prefetching: false
```

- **`minTime: 0s`, `maxTime: 0s`:** Blocky honors the TTL from the upstream response for
  positive answers. When both are `0s`, caching defers entirely to the upstream TTL.
- **Negative cache enabled** (`cacheTimeNegative: 5m`): NXDOMAIN responses and upstream empty
  answers are cached for 5 minutes.
- **Prefetching disabled:** No background cache warming.
- **Maximum entries:** 10,000 entries before oldest are evicted.

**Cache proof (public DNS):** Querying `example.com A` and waiting 2 s then re-querying shows
the TTL decreasing from 112 to 110, confirming the response was served from cache. Private zone
responses (e.g. `c0.monosense.io`) were observed returning authoritative TTL 300 on both queries;
because the TTL remained unchanged, those responses were not cache hits and do not appear in
live acceptance evidence.

---

## DNSSEC

```yaml
dnssec:
  validate: false
```

DNSSEC validation is **off**. Enabling it may break resolution for the unsigned split-horizon
zones if Blocky cannot construct a valid chain-of-trust for those names. Upstream providers
(Cloudflare, Quad9) perform their own DNSSEC validation for public names.

---

## Logging, privacy, and statelessness

```yaml
log:
  level: info
  format: json
  privacy: true
queryLog:
  type: none
```

- **Level:** `info` — startup, configuration warnings, block events, upstream errors only
- **Format:** `json` — structured for log aggregation
- **Privacy:** `privacy: true` — obfuscates sensitive query details such as client IPs and query
  names in log output where possible
- **Query log:** Disabled. No per-client query record is written.
- **No state:** Blocky has no persistent volume. The blocklist is kept in memory and refreshed
  every 12 hours. Cache is in-memory only and is lost on restart.

---

## Resources and health

```yaml
cpus: 0.5
mem_limit: 256m
memswap_limit: 256m
mem_swappiness: 0
ulimits:
  nofile:
    soft: 4096
    hard: 8192
restart: unless-stopped
stop_grace_period: 15s
healthcheck:
  test: [CMD, /app/blocky, healthcheck]
  start_period: 1m
  start_interval: 2s
  interval: 30s
  timeout: 3s
  retries: 3
logging:
  driver: json-file
  options:
    max-size: 10m
    max-file: "3"
```

- **Healthcheck:** The native Blocky `healthcheck` subcommand performs a TCP DNS query for
  `healthcheck.blocky.` against the running daemon. It verifies that the DNS server is
  listening and responding, not merely that the config parses.
- `start_period: 1m` gives the container a grace period to start before health checks begin failing
- Logs are capped at three files of 10 MiB each (30 MiB total).

---

## Local validation

`just docker validate-c0` runs `docker/c0/blocky/tests/validate.sh` as part of the c0 suite.
The script performs two phases:

**Phase 1 — Offline config validation** (no network, no listener):

```sh
docker run --rm \
    --platform linux/amd64 \
    --network none \
    --read-only \
    --cap-drop ALL \
    --security-opt no-new-privileges:true \
    --mount "type=bind,src=$app_dir/config.yml,dst=/app/config.yml,readonly" \
    "$image" validate
```

**Phase 2 — Runtime smoke on an isolated internal Docker network** (no production IPs or
ports):

1. Start the container with the exact production security model: UID 100, read-only root,
   all caps dropped, `no-new-privileges`, unprivileged port sysctl, memory limits.
2. Poll the native `healthcheck` subcommand until it returns 0 (up to 30 s).
3. Poll Docker inspect until health status is `healthy` (up to 40 s).
4. Send a UDP DNS probe for `healthcheck.blocky.` from a peer container on the same isolated
   network; require a valid answer. The peer container has its own network namespace and
   resolves `blocky` via the Docker DNS alias, not via loopback.
5. Send a TCP DNS probe for `healthcheck.blocky.`; require a valid answer.
6. Inspect the container and verify all runtime invariants: image, UID, cap-drop, cap-add,
   sysctl, network mode, read-only root, memory, CPU, nofile, mount count and destination.
7. Read `/proc/1/status` from inside the container PID namespace and assert:
   - `Uid`, `Gid`, `CapPrm`, `CapEff`, `CapBnd`, `CapAmb` all show `0` (no capability)
   - `NoNewPrivs: 1`

---

## Preflight checklist (workstation)

Run from the repository root on a workstation with Docker and `just` available. **Every step
must succeed with a zero exit code.**

```sh
# WORKSTATION CONTEXT
set -euo pipefail

# 1. Verify repository state
git log --oneline -3
git status

# 2. Run local validation
just docker validate-c0

# 3. Inspect all c0_services endpoints; assert no container owns 10.25.13.35/24
#    c0 has no jq; remote shell with set -eu so inspect failure aborts
ssh -n monosense@10.25.10.20 \
  'set -eu
   addresses=$(sudo -n docker network inspect c0_services --format "{{range .Containers}}{{.IPv4Address}}{{\"\n\"}}{{end}}")
   if printf "%s\n" "$addresses" | grep -qx 10.25.13.35/24; then
     echo "FAIL: 10.25.13.35/24 found in c0_services containers"
     exit 1
   fi'

# 4. Active probe: assert route uses c0-svc-shim, require ping exit 1, neighbor absent/INCOMPLETE/FAILED
#    Single-quoted remote script prevents workstation expansion; case patterns avoid quoting issues
ssh -n monosense@10.25.10.20 \
  'set -eu
   case "$(ip route get 10.25.13.35)" in
     *c0-svc-shim*) ;;
     *) echo "FAIL: route to .35 does not use c0-svc-shim"; exit 1 ;;
   esac
   set +e
   ping -c 1 -W 2 10.25.13.35 >/dev/null 2>&1
   ping_rc=$?
   set -e
   case "$ping_rc" in 1) ;; *) echo "FAIL: ping rc=$ping_rc, expected 1"; exit 1 ;; esac
   neigh=$(ip neigh show 10.25.13.35)
   case "$neigh" in
     "") ;;
     *INCOMPLETE*) ;;
     *FAILED*) ;;
     *) echo "FAIL: unexpected neighbour state: $neigh"; exit 1 ;;
   esac'

# 5. Save canonical identity snapshots to workstation files (compare post-poll with cmp)
#    Project labels: openbao-c0, powerdns-c0, omada-controller-c0
#    Use --no-trunc for stable IDs and .State (not .Status, which changes)
#    Create file with umask before writing to avoid chmod-on-nonexistent race
umask 077
preflight_id_file=/tmp/blocky-preflight-identities.txt
: > "$preflight_id_file"
doco_line=$(ssh -n monosense@10.25.10.20 \
  'sudo -n docker ps -a --no-trunc --format "{{.ID}}|{{.CreatedAt}}|{{.Image}}|{{.State}}" --filter name=doco-cd')
test -n "$doco_line"
test "$(echo "$doco_line" | wc -l)" -eq 1
echo "$doco_line" > "$preflight_id_file"
openbao_line=$(ssh -n monosense@10.25.10.20 \
  'sudo -n docker ps -a --no-trunc --format "{{.ID}}|{{.CreatedAt}}|{{.Image}}|{{.State}}" --filter label=com.docker.compose.project=openbao-c0 --filter label=com.docker.compose.service=openbao')
test -n "$openbao_line"
test "$(echo "$openbao_line" | wc -l)" -eq 1
echo "$openbao_line" >> "$preflight_id_file"
powerdns_line=$(ssh -n monosense@10.25.10.20 \
  'sudo -n docker ps -a --no-trunc --format "{{.ID}}|{{.CreatedAt}}|{{.Image}}|{{.State}}" --filter label=com.docker.compose.project=powerdns-c0 --filter label=com.docker.compose.service=powerdns')
test -n "$powerdns_line"
test "$(echo "$powerdns_line" | wc -l)" -eq 1
echo "$powerdns_line" >> "$preflight_id_file"
omada_line=$(ssh -n monosense@10.25.10.20 \
  'sudo -n docker ps -a --no-trunc --format "{{.ID}}|{{.CreatedAt}}|{{.Image}}|{{.State}}" --filter label=com.docker.compose.project=omada-controller-c0 --filter label=com.docker.compose.service=omada-controller')
test -n "$omada_line"
test "$(echo "$omada_line" | wc -l)" -eq 1
echo "$omada_line" >> "$preflight_id_file"
echo "Saved preflight identities to $preflight_id_file"

# 6. Confirm PowerDNS responds with exact repository A value over SSH
ssh -n monosense@10.25.10.20 \
  'dig +short @10.25.13.33 c0.monosense.io A' \
  | grep -qxF '10.25.10.20'
```

If any step fails, do not proceed. Fix the failure in the repository and repeat from step 1.

---

## Human gate (historical deployment record)

The following preflight evidence was presented to and verified by the authorizing operator before
the initial deployment was approved. The deployment proceeded after confirmation of:

- Repository state and validation pass
- c0 readiness (static IP unowned, route correct, neighbor absent)
- Protected service identities captured for post-poll comparison
- PowerDNS responding with the expected `c0.monosense.io` A record

The exact phrase **`PROCEED BLOCKY DEPLOYMENT`** was given and deployment followed.

---

## Live acceptance (post-deployment)

After Doco has deployed the container and it is healthy, run the following from a workstation.
All Docker and DNS commands execute on c0 via SSH; inspect JSON is captured to local temporary
files and processed on the workstation where jq is available.

```sh
# WORKSTATION CONTEXT
set -euo pipefail

prepoll_id_file=/tmp/blocky-preflight-identities.txt
postpoll_id_file=/tmp/blocky-postpoll-identities.txt
blocky_insp=$(mktemp)
blocky_proc=$(mktemp)

# 1. Compare protected-service identities byte-for-byte with preflight snapshot
umask 077
: > "$postpoll_id_file"
doco_pp=$(ssh -n monosense@10.25.10.20 \
  'sudo -n docker ps -a --no-trunc --format "{{.ID}}|{{.CreatedAt}}|{{.Image}}|{{.State}}" --filter name=doco-cd')
test -n "$doco_pp"
test "$(echo "$doco_pp" | wc -l)" -eq 1
echo "$doco_pp" > "$postpoll_id_file"
openbao_pp=$(ssh -n monosense@10.25.10.20 \
  'sudo -n docker ps -a --no-trunc --format "{{.ID}}|{{.CreatedAt}}|{{.Image}}|{{.State}}" --filter label=com.docker.compose.project=openbao-c0 --filter label=com.docker.compose.service=openbao')
test -n "$openbao_pp"
test "$(echo "$openbao_pp" | wc -l)" -eq 1
echo "$openbao_pp" >> "$postpoll_id_file"
powerdns_pp=$(ssh -n monosense@10.25.10.20 \
  'sudo -n docker ps -a --no-trunc --format "{{.ID}}|{{.CreatedAt}}|{{.Image}}|{{.State}}" --filter label=com.docker.compose.project=powerdns-c0 --filter label=com.docker.compose.service=powerdns')
test -n "$powerdns_pp"
test "$(echo "$powerdns_pp" | wc -l)" -eq 1
echo "$powerdns_pp" >> "$postpoll_id_file"
omada_pp=$(ssh -n monosense@10.25.10.20 \
  'sudo -n docker ps -a --no-trunc --format "{{.ID}}|{{.CreatedAt}}|{{.Image}}|{{.State}}" --filter label=com.docker.compose.project=omada-controller-c0 --filter label=com.docker.compose.service=omada-controller')
test -n "$omada_pp"
test "$(echo "$omada_pp" | wc -l)" -eq 1
echo "$omada_pp" >> "$postpoll_id_file"
cmp -s "$prepoll_id_file" "$postpoll_id_file"

# 2. Resolve exactly one blocky-c0 service container
#    macOS Bash 3.2 lacks mapfile; use scalar capture with line-count check
blocky_ps=$(ssh -n monosense@10.25.10.20 \
  'sudo -n docker ps -aq \
     --filter label=com.docker.compose.project=blocky-c0 \
     --filter label=com.docker.compose.service=blocky')
test -n "$blocky_ps"
test "$(echo "$blocky_ps" | wc -l)" -eq 1
blocky_id="$blocky_ps"

# 3. Capture Blocky inspect JSON locally for all assertions
ssh -n monosense@10.25.10.20 \
  "sudo -n docker inspect $blocky_id" \
  > "$blocky_insp"

# 4. Assert exact image tag@digest  (docker inspect returns array)
jq -e '.[0].Config.Image == "docker.io/spx01/blocky:v0.34.0@sha256:595136fb127f4c952b621113e668c09acdcf15ac054d96ee6d4c51a76c35f5fd"' \
  "$blocky_insp" >/dev/null

# 5. Assert User 100:100
jq -e '.[0].Config.User == "100:100"' "$blocky_insp" >/dev/null

# 6. Assert NNP, sysctl, and ReadonlyRootfs via inspect JSON
jq -e '.[0].HostConfig.SecurityOpt == ["no-new-privileges:true"]' "$blocky_insp" >/dev/null
jq -e '.[0].HostConfig.Sysctls == {"net.ipv4.ip_unprivileged_port_start":"53"}' "$blocky_insp" >/dev/null
jq -e '.[0].HostConfig.ReadonlyRootfs == true' "$blocky_insp" >/dev/null

# 7. Assert only c0_services at 10.25.13.35
jq -e '.[0].NetworkSettings.Networks | keys == ["c0_services"]' "$blocky_insp" >/dev/null
jq -e '.[0].NetworkSettings.Networks["c0_services"].IPAddress == "10.25.13.35"' "$blocky_insp" >/dev/null

# 8. Assert exactly one read-only config mount and no port bindings
jq -e '(.[0].Mounts | length) == 1' "$blocky_insp" >/dev/null
jq -e '.[0].Mounts[0] | .Destination == "/app/config.yml" and .RW == false' "$blocky_insp" >/dev/null
jq -e '.[0].HostConfig.PortBindings == {}' "$blocky_insp" >/dev/null

# 9. Assert health status is healthy
jq -e '.[0].State.Health.Status == "healthy"' "$blocky_insp" >/dev/null

# 10. Capture /proc/1/status via pinned PowerDNS helper; assert text locally
#     Scratch Blocky has no /bin/cat; PowerDNS helper reads the target container's procfs
#     Pass container ID as positional arg to avoid local-variable expansion issues
ssh -n monosense@10.25.10.20 \
  'sudo -n docker run --rm \
     --platform linux/amd64 \
     --network none \
     --pid "container:$1" \
     --entrypoint /bin/cat \
     docker.io/powerdns/pdns-auth-51:5.1.4@sha256:bb5b1c133bcca1dd455075321de7d55db4945a8d7f2ba23339e3c7bbe416b205 \
     /proc/1/status' \
  _ "$blocky_id" \
  > "$blocky_proc"
grep -qxE '^CapPrm:[[:space:]]+0+$' "$blocky_proc"
grep -qxE '^CapEff:[[:space:]]+0+$' "$blocky_proc"
grep -qxE '^CapBnd:[[:space:]]+0+$' "$blocky_proc"
grep -qxE '^NoNewPrivs:[[:space:]]+1$' "$blocky_proc"

# 11. DNS resolution — heredoc SSH; omit -n so heredoc is consumed correctly
#     Status line: ;; ->>HEADER<<- opcode: QUERY, status: NOERROR,
#     Private A/PTR use +short for exact value grep
ssh monosense@10.25.10.20 'bash -s' <<'DNSEOF'
set -euo pipefail

udp=$(dig @10.25.13.35 cloudflare.com A 2>&1)
echo "$udp" | grep -qE '^;; ->>HEADER<<- opcode: QUERY, status: NOERROR,'
echo "$udp" | grep -qE 'IN[[:space:]]+A[[:space:]]'

tcp=$(dig @10.25.13.35 cloudflare.com A +tcp 2>&1)
echo "$tcp" | grep -qE '^;; ->>HEADER<<- opcode: QUERY, status: NOERROR,'
echo "$tcp" | grep -qE 'IN[[:space:]]+A[[:space:]]'

dig +short @10.25.13.35 c0.monosense.io A | grep -qxF '10.25.10.20'

dig +short @10.25.13.35 -x 10.25.13.33 | grep -qxF 'ns1.monosense.io.'

tmpfeed=$(mktemp)
trap 'rm -f "$tmpfeed"' EXIT
curl -fsSL \
  'https://raw.githubusercontent.com/hagezi/dns-blocklists/a3d0c5c7a0402f669f3f1392527b8a50622128cf/wildcard/multi.txt' \
  -o "$tmpfeed"
grep -Fxq '*.ads.01film.cc' "$tmpfeed"
blk=$(dig @10.25.13.35 ads.01film.cc A 2>&1)
echo "$blk" | grep -qE '^;; ->>HEADER<<- opcode: QUERY, status: NXDOMAIN,'
rm -f "$tmpfeed"

nonblk=$(dig @10.25.13.35 google.com A 2>&1)
echo "$nonblk" | grep -qE '^;; ->>HEADER<<- opcode: QUERY, status: NOERROR,'
echo "$nonblk" | grep -qE 'IN[[:space:]]+A[[:space:]]'
DNSEOF

# 12. Cache TTL proof — public domain with short TTL (example.com ~112 s, two A records)
#     Private zone TTL is 300 s; both queries returned 300 unchanged, so not cache hits.
#     example.com returns two A records; extract only the first A-record TTL/address to
#     avoid multiline variable issues in numeric comparison.
#     Fields: name TTL IN A IP  (e.g. example.com. 112 IN A 93.184.215.14)
cache1=$(ssh -n monosense@10.25.10.20 'dig @10.25.13.35 example.com A +noall +answer')
ttl1=$(echo "$cache1" | awk '$4 == "A" {print $2; exit}')
addr1=$(echo "$cache1" | awk '$4 == "A" {print $5; exit}')
test -n "$ttl1"
test -n "$addr1"
sleep 2
cache2=$(ssh -n monosense@10.25.10.20 'dig @10.25.13.35 example.com A +noall +answer')
ttl2=$(echo "$cache2" | awk '$4 == "A" {print $2; exit}')
addr2=$(echo "$cache2" | awk '$4 == "A" {print $5; exit}')
test -n "$ttl2"
test -n "$addr2"
test "$addr2" = "$addr1"
test "$ttl2" -lt "$ttl1"

# 13. Confirm no persistent volume
mounts=$(jq -r '.[0].Mounts[] | "\(.Source) \(.Destination)"' "$blocky_insp")
echo "$mounts" | grep -q '/app/config.yml'
test "$(echo "$mounts" | wc -l)" -eq 1

rm -f "$blocky_insp" "$blocky_proc" "$postpoll_id_file"
echo "Live acceptance complete."
```

---

## Comparison with current production DNS

| Property | AdGuard Home `10.25.10.100` | Blocky `10.25.13.35` |
|---|---|---|
| Role | Production resolver | Deployed proxy (no client traffic yet) |
| Upstream | Unknown | Direct Cloudflare + Quad9 DoH |
| Conditional zones | Does not forward private zones | Via PowerDNS `10.25.13.33` |
| DNSSEC | Unknown | Off |
| Blocklist | Unknown | HaGeZi Multi NORMAL (pinned commit) |
| Query log | Unknown | Off |
| State | Persistent | Stateless (no volumes) |
| Deployment | Existing | Deployed; client cutover is future work |

**No-impact is a required verified invariant: `10.25.10.100` remains production DNS throughout.
This is confirmed by the post-poll comparison of protected-service container identities in the
live acceptance checklist.** Client cutover requires a separate, reviewed change.

---

## Upgrade

Blocky has no persistent state. The two supply-chain pins (Blocky image tag+digest in Compose,
HaGeZi commit hash in config) may be updated independently as applicable. Upgrade requires a
reviewed repository change followed by Doco deployment:

1. Verify the new HaGeZi commit hash and SHA-256 before updating `config.yml`
2. Update the image tag and digest in `docker/c0/blocky/compose.yml`
3. Validate: `just docker validate-c0`
4. Code review
5. Human gate: confirm `PROCEED BLOCKY DEPLOYMENT`
6. Merge to `main`
7. Wait for Doco poll (up to 180 s)

No automatic pull of unverified list updates occurs between deployments. Doco picks up the new
image on its next poll.

---

## Rollback (Blocky-only, `delete: false`)

Blocky owns no persistent state. Rollback proceeds only after a reviewed git revert commit has
been merged to `origin/main` and Doco has observed the change. **Fail-closed: the container is
never removed unless Doco has demonstrably observed the revert.**

```sh
# WORKSTATION CONTEXT
set -euo pipefail

# Helper: fetch Doco runs and write JSON to stdout
#     Uses root-only curl config pattern; API key never appears in arguments
fetch_doco_runs() {
  ssh monosense@10.25.10.20 'sudo bash -s' <<'APIINNER'
umask 077
config=$(mktemp /tmp/doco-curl.XXXXXX)
trap "rm -f \"\$config\"" EXIT HUP INT TERM
api_secret=$(cat /opt/doco-cd/secrets/api_secret)
printf 'header = "x-api-key: %s"\n' "$api_secret" > "$config"
chmod 0600 "$config"
curl --silent --show-error --config "$config" \
  http://127.0.0.1:8080/v1/api/runs
APIINNER
}

# 1. Fetch and record revert SHA from origin/main
git fetch origin main
revert_sha=$(git rev-parse origin/main)

# 2. Assert docker/c0/blocky is absent from origin/main
blocky_files=$(git ls-tree -r --name-only origin/main -- docker/c0/blocky)
test -z "$blocky_files"

# 3. Set threshold from c0 clock and wait for Doco to observe the revert
#     Poll until a successful main poll with created_at >= threshold appears.
#     Threshold is captured ONCE and never reset; deadline is 210 s from now.
threshold=$(ssh -n monosense@10.25.10.20 date +%s)
deadline=$((SECONDS + 210))
until fetch_doco_runs | jq -e --argjson t "$threshold" \
  '.content | any(.[];
     .trigger == "poll"
     and .status == "succeeded"
     and .revision == "refs/heads/main"
     and ((.created_at | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) >= $t))' \
  >/dev/null 2>&1; do
  test "$SECONDS" -lt "$deadline" || { echo "TIMEOUT: no Doco main poll observed within 210s"; exit 1; }
  sleep 5
done

# 4. After observing poll: refresh and assert origin/main still matches recorded SHA
git fetch origin main
current_sha=$(git rev-parse origin/main)
test "$current_sha" = "$revert_sha"

# 5. Reassert docker/c0/blocky path absent before touching container
blocky_files=$(git ls-tree -r --name-only origin/main -- docker/c0/blocky)
test -z "$blocky_files"

# 6. Confirm blocky-c0 container is present before removal
blocky_ps=$(ssh -n monosense@10.25.10.20 \
  'sudo -n docker ps -aq \
     --filter label=com.docker.compose.project=blocky-c0 \
     --filter label=com.docker.compose.service=blocky')
test -n "$blocky_ps"
test "$(echo "$blocky_ps" | wc -l)" -eq 1
blocky_id="$blocky_ps"

# 7. Verify project, service, and network labels programmatically before removing
rollback_info=$(
  ssh -n monosense@10.25.10.20 \
    'sudo -n docker inspect --format \
       "{{.Config.Labels.\"com.docker.compose.project\"}}|{{.Config.Labels.\"com.docker.compose.service\"}}|{{range $k,$v := .NetworkSettings.Networks}}{{$k}}{{end}}" \
       "$1"' \
    _ "$blocky_id"
)
echo "$rollback_info" | grep -qxF 'blocky-c0|blocky|c0_services'

# 8. Remove the container
ssh -n monosense@10.25.10.20 \
  'sudo -n docker rm -f "$1"' \
  _ "$blocky_id"

# 9. Set removal threshold from c0 clock and wait for Doco to observe post-removal state
#     Loop bounded to 210 s; each miss must also fall within the deadline.
removal_threshold=$(ssh -n monosense@10.25.10.20 date +%s)
deadline=$((SECONDS + 210))
until fetch_doco_runs | jq -e --argjson t "$removal_threshold" \
  '.content | any(.[];
     .trigger == "poll"
     and .status == "succeeded"
     and .revision == "refs/heads/main"
     and ((.created_at | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) >= $t))' \
  >/dev/null 2>&1; do
  test "$SECONDS" -lt "$deadline" || { echo "TIMEOUT: no post-removal Doco poll within 210s"; exit 1; }
  sleep 5
done

# 10. Confirm blocky-c0 container is absent; delete:false prevents Doco from recreating
blocky_gone=$(ssh -n monosense@10.25.10.20 \
  'sudo -n docker ps -aq \
     --filter label=com.docker.compose.project=blocky-c0 \
     --filter label=com.docker.compose.service=blocky')
test -z "$blocky_gone"
```

**Never** run `docker compose down -v` (deletes volumes), remove named volumes, touch
:`c0_services`, or modify PowerDNS, OpenBao, Omada, or Doco volumes. The Doco `delete: false`
policy means Doco retains its project record after container removal; pushing the reviewed
revert to `main` prevents rediscovery.

---

## Future client cutover mission

Blocky is ready for cutover evaluation. When it is evaluated as the primary resolver:

1. **Discover the c0 Docker environment** — identify containers, networks, and labels via
   `sudo -n docker ps --filter label=com.docker.compose.project=blocky-c0`
2. **Document the candidate resolver address** — `10.25.13.35` — alongside the current
   `10.25.10.100` in network diagrams and static resolver configurations
3. **Probe conditional zones** — verify `monosense.io` and reverse zones resolve correctly
   for test clients before directing production traffic
4. **Monitor false positives** — watch for unexpected blocks from the HaGeZi list; add
   allowlist entries as needed
5. **Assess cutover ordering** — determine whether to add Blocky as secondary first, or to
   run parallel and compare, before any removal of `10.25.10.100` from client configurations

No primary/secondary ordering is prescribed here; that decision belongs to the cutover review.

---

## File inventory

| File | Role |
|---|---|
| `docker/c0/blocky/compose.yml` | Doco deployment manifest |
| `docker/c0/blocky/config.yml` | Blocky configuration (Git-owned, no secrets) |
| `docker/c0/blocky/.doco-cd.yaml` | Doco project name (`blocky-c0`) |
| `docker/c0/blocky/tests/validate.sh` | Offline config validation + isolated runtime smoke |
| `docker/c0/blocky/tests/dns_probe.py` | UDP/TCP DNS probe used by validate.sh |
| `docs/BLOCKY.md` | This runbook |
