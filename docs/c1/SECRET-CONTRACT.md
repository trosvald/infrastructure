# c1 Secret Contract

Date: 2026-08-26
Status: storage and network applied and verified (1 TB split: `c1_librefs` at `/srv/librefs`,
`c1_apps` at `/srv/applications`, `defaults,noatime`; Docker/containerd `SOURCE` equals `/` source;
`c1-svc-shim` and `c1-services-network.service` active; 512 GB excluded). OpenBao checkpoint
completed: policy `doco-c1` installed; KV v2 `kv/docker/c1/librefs` v1 provisioned with the exact
`root_user`/`root_password` keys; orphan periodic 24h token issued with self-lookup and
self-renew only; policy allows only `kv/data/docker/c1/librefs` (read), `auth/token/lookup-self`,
and `auth/token/renew-self`; all unrelated capabilities are denied; audit file device
enabled. Multi-recipient Raft snapshot captured to the workstation and encrypted under the
offline-recovery age boundary; structural verification passed (`meta.json`, `state.bin`,
`SHA256SUMS`, `SHA256SUMS.sealed`); internal SHA256SUMS verified (no snapshot-inspect on the
installed bao; structural and internal checksums are the reviewed evidence). The first
capabilities-self call returned 403 (no-default Doco policy cannot call `capabilities-self`);
recovery used a short-lived admin token via `sys/capabilities-accessor` and did not broaden
the Doco policy. The short-lived admin token was revoked and removed. No secrets, recipients,
hashes, or token values are recorded here. Remaining gates are push, merge, deploy, reboot,
off-host libreFS backup/restore.

OpenBao is authoritative for c1 application runtime secrets. Doco-CD resolves KV values only while
it deploys a project. It is not a runtime sidecar and does not refresh an already-running
container.

Two root-only c1 bootstrap credentials are intentionally outside OpenBao:

1. the c1 Doco API secret;
2. the least-privilege Doco OpenBao token.

They break the controller bootstrap cycle. They live under `/opt/doco-cd/secrets`, whose directory
is `root:root` mode `0700`; each file is `root:root` mode `0600` or stricter. Neither value is an
environment variable, Compose value, command argument, log field, or Git object. The token is never
backed up; loss requires administrator-mediated replacement. The API secret is also regenerated on
loss, then Doco is recreated. Neither bootstrap value has an off-host copy.

No c0 SOPS age identity is copied to c1.

OpenBao Shamir shares are never requested, handled, automated, copied, or stored by this mission.
If OpenBao is sealed, mutation stops and the existing unseal runbook applies.

## Current application record

| Consumer | Logical KV v2 path | API policy path | Keys | Creation authority |
|---|---|---|---|---|
| libreFS root administration | `kv/docker/c1/librefs` | `kv/data/docker/c1/librefs` | `root_user`, `root_password` | Approved OpenBao administrator procedure |

`root_user` contains at least 128 bits of CSPRNG entropy encoded without whitespace. `root_password`
contains at least 256 bits. Neither is a hostname, repository string, default, reused value, or
human-selected password. The values are generated directly into a protected input stream and sent
to OpenBao without being printed or placed in argv, shell history, environment, or a permissive
temporary file.

Doco 0.111.0 mappings are:

```yaml
external_secrets:
  LIBREFS_ROOT_USER: kv:kv:docker/c1/librefs:root_user
  LIBREFS_ROOT_PASSWORD: kv:kv:docker/c1/librefs:root_password
```

The first `kv` is the provider reference type; the second is the KV mount name. Doco supplies the
resolved values only to the Compose deployment process. Compose creates two runtime secrets from
the deployment variables. The libreFS container receives only:

```text
MINIO_ROOT_USER_FILE=/run/secrets/librefs_root_user
MINIO_ROOT_PASSWORD_FILE=/run/secrets/librefs_root_password
```

The values themselves must not appear in the container environment or Docker inspect output.
Runtime secret files remain sensitive engine state even when they are not visible in inspect.

## Doco policy

The initial `doco-c1` policy is deliberately limited to the current service:

```hcl
path "kv/data/docker/c1/librefs" {
  capabilities = ["read"]
}

path "auth/token/lookup-self" {
  capabilities = ["read"]
}

path "auth/token/renew-self" {
  capabilities = ["update"]
}
```

No wildcard path is permitted. In particular, the token has no capability for:

- `kv/metadata/...` or list operations;
- writes, patches, deletes, undeletes, destroys, or metadata changes;
- c0, Junos, global, identity, policy, auth-method, token-creation, system, or PKI paths;
- future c1 services that do not yet consume a secret.

Future paths are added to this policy only with the reviewed deployment that needs them. Creating a
future record does not itself justify granting Doco access.

## Doco machine-token lifecycle

Use an orphaned, renewable, periodic service token with only `doco-c1`. Target period: 24 hours.
The final period is accepted only after authenticated discovery proves the server's configured
limits and renewal behavior.

A root-owned systemd timer renews the token every six hours with randomized delay. The timer uses
`Persistent=true` and runs five minutes after boot, so missed schedules are handled before Doco is
allowed to deploy. The renewal script:

- reads `/opt/doco-cd/secrets/openbao-token` only as root;
- sends the token to the TLS-validated API through a protected FIFO/stdin header source, never argv
  or a process environment;
- suppresses response bodies and logs only renewal time/TTL/renewable status;
- fails closed on TLS, HTTP, JSON, capability, or renewal errors;
- never writes a replacement token value to logs or world-readable storage.

The timer's failed unit and a dedicated journald identifier are the initial alert target; operations
must check them before every manual deployment. A pre-deployment gate requires a successful
self-lookup and remaining TTL greater than one renewal interval. A renewal failure prevents new
deployments but does not stop an already-running libreFS container. If the token expires while c1 is
offline, an administrator creates and capability-tests a replacement, atomically installs it, and
recreates Doco as described below.

Token rotation:

1. authenticate with the approved hidden administrator flow;
2. create a replacement with the same policy and period;
3. prove exact allowed and denied capabilities;
4. atomically install and fsync the c1 token file;
5. restart the systemd-owned `doco-cd-c1.service`; its foreground Compose command force-recreates
   only the controller and preserves the named data volume, while the real `ExecStartPre` TTL gate
   prevents an expired token from starting Doco;
6. wait for container health, trigger an authenticated Doco poll, and require its tracked run to
   succeed, proving the remounted token through the OpenBao-backed controller path;
7. revoke the old token by accessor;
8. retain only the accessor and sanitized audit evidence.

The Doco token cannot create or rotate itself. An immortal broad token is prohibited.

## Rotation matrix

| Value | Trigger | Procedure | Runtime impact | Custody/backup |
|---|---|---|---|---|
| Doco API secret | suspected disclosure or scheduled operator rotation | generate at least 256 CSPRNG bits, atomic root-only install, restart the systemd-owned controller, require controller poll canary | controller recreation only | regenerate on loss; no backup |
| Doco OpenBao token | before period/lifecycle policy change, suspected disclosure, scheduled rotation, or expiry | replacement/test/atomic install/systemd restart/provider-canary/revoke-by-accessor sequence above | controller recreation; apps continue | accessor recorded; token value never recorded or backed up |
| libreFS root user/password | suspected disclosure, administrator rotation, or initial bootstrap | stop Doco service first, write a new KV version with CAS, start Doco service, observe one controlled secret-driven deployment, verify new login and old rejection | libreFS recreation/restart | OpenBao KV history and approved encrypted OpenBao backup |
| future application values | only after exact image/version and consumer format are reviewed | service-specific procedure below | service-specific redeploy | OpenBao plus approved off-host backup policy |

Doco 0.111.0 resolves ordinary KV values before it hashes the rendered Compose project. A changed
value therefore changes the project hash and can trigger deployment on the next 180-second poll.
Rotation is operator-gated by stopping Doco before the KV write, then starting/recreating it only
when the service recreation is intended. The initial canary must reproduce this behavior. Rollback
stops Doco, selects the prior KV version, then starts/recreates Doco and verifies one rollback
deployment. No sequence assumes that a KV update waits for a separate manual redeploy.

## Leakage gates

Before real credentials are deployed, use unique non-secret canary strings through the same Doco and
Compose path. Search for matches without printing them in:

- container environment and inspect metadata;
- rendered Compose output, project labels, and runtime secret metadata;
- Doco logs, working trees, data volume/database, and persisted deployment artifacts;
- Docker and containerd metadata;
- journald, application logs, temporary directories, and backup inputs.

Expected findings are limited to the protected runtime secret materialization required by Compose.
A value in Git, container environment, ordinary logs, labels, inspect output, Doco persistent state,
or world-readable storage is release-blocking. The test must delete the canary deployment and
protected material after recording only pass/fail evidence.

## Future records

These logical paths are reservations, not current grants:

- `kv/docker/c1/librefs-backup`
- `kv/docker/c1/haproxy-crowdsec`
- `kv/docker/c1/mattermost`
- `kv/docker/c1/forgejo`

### libreFS backup

Status: `BLOCKED_BY_DESIGN`. Create only after an off-host target, protocol, pinned backup client,
scoped service identity, retention, and restore procedure are approved. Required values depend on
that target. A same-host credential or copy does not provide durability.

### HAProxy and CrowdSec

Status: `BLOCKED_BY_DESIGN`. CrowdSec LAPI/bouncer and SPOA/AppSec credentials are issued by the
selected pinned CrowdSec stack, not invented now. DNS-provider, public-certificate, and PKI values
remain `OPERATOR_SUPPLIED` until the certificate architecture is approved.

### Mattermost Community Edition

Status: `BLOCKED_BY_VERSION`. Before creation, pin and inspect the exact Mattermost and PostgreSQL
images and verify file-secret support and required lengths. Candidate categories are PostgreSQL
password, at-rest encryption key, required salts/signing values, and application session/signing
material. SMTP and OIDC values are `OPERATOR_SUPPLIED`. S3 keys are blocked until libreFS has TLS,
off-host durability, and a scoped non-root service account.

### Forgejo

Status: `BLOCKED_BY_VERSION`. Before creation, pin and inspect the exact Forgejo and PostgreSQL
images and verify the application secret key, internal token, JWT secret, LFS JWT secret, database
password, and file-secret formats. SMTP and OAuth values are `OPERATOR_SUPPLIED`. S3 keys have the
same libreFS gates as Mattermost.

No placeholder external credential is generated. Every future value requires an owner, exact
consumer version, entropy/format rule, OpenBao key, target file, rotation trigger, redeploy effect,
and backup/custody procedure before creation.
