# c1 Secret Contract

Date: 2026-08-26
Historical predecessor status (not container-node Ansible adoption or convergence): storage and
network were applied and verified (1 TB split: `c1_librefs` at `/srv/librefs`,
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
capabilities-and-lability call returned 403 (no-default Doco policy cannot call
`capabilities-self`); recovery used a short-lived admin token via `sys/capabilities-accessor`
and did not broaden the Doco policy. The short-lived admin token was revoked and removed.
Credential rotation leakage gate closed: OpenBao KV v2 `kv/docker/c1/librefs` was rotated twice
with CAS ending at version 3; each new pair was rematerialized through Doco's OpenBao provider;
the second rotation proved the prior pair absent from runtime files, inspect/env/logs, Doco
and libreFS journals, Doco volume/worktrees, Docker container metadata, containerd, and the
export; the current pair existed only in the two approved `/run/secrets` files. Short-lived
admin token revoked; local rotation/comparison material removed. No secrets, recipients, hashes,
or token values are recorded here. PR8 (`599fff0e01301d77f5a2e204bac5df9a519f1823`) is merged;
its then-installed libreFS rematerialization helper is historical live evidence. The maintained
source now lives under `ansible/container-nodes/roles/runtime_assets/`. Those mission gates
completed after the user-approved controlled c1 reboot, but do not claim later container-node
Ansible adoption or convergence. Final status was `OPERATIONAL_WITHOUT_DURABILITY` solely because
no off-host libreFS backup target/restore existed on c1; no durability claim.

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

## Application records

| Consumer | Logical KV v2 path | API policy path | Keys | Creation authority |
|---|---|---|---|---|
| libreFS root administration | `kv/docker/c1/librefs` | `kv/data/docker/c1/librefs` | `root_user`, `root_password` | Approved OpenBao administrator procedure |
| c1 edge | `kv/docker/c1/edge` | `kv/data/docker/c1/edge` | `acme_email`, `cloudflare_dns_token`, `maxmind_account_id`, `maxmind_license_key`, `crowdsec_lapi_key`, `crowdsec_bouncer_key`, `vector_ingest_token` | `monosense-infra` userpass identity |
| Forgejo | `kv/docker/c1/forgejo` | `kv/data/docker/c1/forgejo` | `postgres_password`, `forgejo_secret_key`, `forgejo_internal_token`, `forgejo_jwt_secret`, `forgejo_lfs_jwt_secret`, `bootstrap_admin_password`, `bootstrap_admin_email`, `zoho_username`, `zoho_password`, `kopia_repository_password`, `librefs_access_key`, `librefs_secret_key` | `monosense-infra` userpass identity |
| c0 monitoring | `kv/docker/c0/monitoring` | `kv/data/docker/c0/monitoring` | `telegram_bot_token`, `telegram_chat_id`, `vector_ingest_token`, `backup_heartbeat_token` | `monosense-infra` userpass identity |
| wildcard TLS | `kv/platform/tls/monosense-wildcard` | `kv/data/platform/tls/monosense-wildcard` | `certificate`, `fullchain`, `private_key`, `serial`, `not_after` | named `wildcard-publisher` service token |

Generated passwords, tokens, and keys contain at least 256 bits of CSPRNG entropy encoded without
whitespace unless the consuming service defines a stricter format. User-selected email, username,
and Zoho password values remain operator supplied. Values are sent to OpenBao through protected
stdin or a mode-0600 temporary file and never through argv, shell history, or logs.

Doco 0.111.0 mappings are:

```yaml
external_secrets:
  LIBREFS_ROOT_USER: kv:kv:docker/c1/librefs:root_user
  LIBREFS_ROOT_PASSWORD: kv:kv:docker/c1/librefs:root_password
```

The first `kv` is the provider reference type; the second is the KV mount name. Doco supplies the
resolved values only to the Compose deployment process. The first Doco deploy attempted to feed
these resolved values into top-level Compose `secrets.environment`; Doco 0.111.0 rejected that
source because only `file` is supported for `secrets.environment`. The deploy failed before
container creation; no rendered project, no container, and no engine artifact contains the
credential material. The corrected pattern follows the official Doco external-secrets example:
top-level Compose `configs.content` is populated from the Doco-resolved `LIBREFS_ROOT_USER`
and `LIBREFS_ROOT_PASSWORD` variables, and the resulting config files are mounted at
`/run/secrets/librefs_root_user` and `/run/secrets/librefs_root_password` with mode `0400`,
UID/GID `1000`. These are config-backed credential files, not Docker secrets. The libreFS
container uses a writable-root exception (operator-selected; see `LIBREFS.md`) so these
config files can be materialized; `read_only: true` is intentionally omitted for libreFS only,
and every other hardening control is retained.

```text
MINIO_ROOT_USER_FILE=/run/secrets/librefs_root_user
MINIO_ROOT_PASSWORD_FILE=/run/secrets/librefs_root_password
```

The resolved values themselves must not appear in the container environment, Docker inspect
output, or any ordinary log. Resolved values exist only in Doco's in-memory rendered project and
exact-value leakage scan covering container environment, rendered Compose output, project
labels, runtime secret/config metadata, Doco logs/working trees/data volume/persisted deployment
artifacts, Docker and containerd metadata, journald, application logs, temporary directories,
and backup inputs was a blocking live canary at PR6 design time. PR6
(`3ff1aaf1facc23f6f85e5c95bc80b9e599289207`) is merged; the scan passed on the merged
artifact. The credential rotation leakage gate is closed: OpenBao KV v2 `kv/docker/c1/librefs`
was rotated twice with CAS ending at version 3, and each rotation proved the prior pair
absent from every location while the current pair existed only in the two approved
`/run/secrets` files.

## Doco policy

The `doco-c1` policy grants read only to `kv/data/docker/c1/librefs`,
`kv/data/docker/c1/edge`, and `kv/data/docker/c1/forgejo`, plus self lookup and renewal. It grants
no metadata access, child-path access, write capability, or generic token creation. The
`monosense-infra` operator policy owns the exact data and metadata records above, can create tokens
only through the named `wildcard-publisher`, `wildcard-reader-c0`, and `wildcard-reader-c1` roles,
and has `read, update` only on the exact Junos topology data path. That update capability is used
only by `scripts/provision-junos-edge-topology.sh`, which accepts no arguments, preserves unrelated
fields, permits only the reviewed AdGuard-to-Blocky transition or absent-to-exact EDGE/monitoring
fields, and writes with the current KV version as CAS.

Wildcard certificate publisher and reader policies are separate from Doco. The publisher can
create/read/update/patch only the wildcard data record. Each host reader can read only that data
and metadata record. All three service policies have self lookup and renewal only; no role uses a
path wildcard.
The three wildcard roles issue orphan periodic 24-hour tokens without an explicit maximum TTL.
Each 12-hour publisher or reader run renews its own token through `renew-self` before accessing the
certificate record and fails closed unless OpenBao returns a positive renewable lease. A token that
misses its period requires the documented capability-tested replacement and old-accessor revocation.


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

1. use `just ansible container-nodes rotate-secrets` from the trusted controller;
2. authenticate through the protected OpenBao/SOPS flow without plaintext argv, output, or facts;
3. validate the replacement role, policy, period, renewability, record version, and exact
   allowed/denied capabilities while retaining the old accessor;
4. stage and fsync the replacement with exact directory/file ownership and mode;
5. verify the exact consumer through the Ansible-installed lifecycle gate;
6. commit one consumer at a time and prove the provider/application canary;
7. revoke the old token by accessor only after success; otherwise restore the prior file and
   consumer runtime state, verify it, and revoke the replacement;
8. retain only accessors and sanitized audit evidence.

The Doco token cannot create or rotate itself. An immortal broad token is prohibited. Routine
`deploy` never reads or changes protected material.

## Rotation matrix

| Value | Trigger | Procedure | Runtime impact | Custody/backup |
|---|---|---|---|---|
| Doco API secret | suspected disclosure or scheduled operator rotation | `rotate-secrets`: generate at least 256 CSPRNG bits, atomically stage, verify/restart only the controller, and require its poll canary before commit | controller recreation only | regenerate on loss; no backup |
| Doco OpenBao token | before period/lifecycle policy change, suspected disclosure, scheduled rotation, or expiry | `rotate-secrets`: replacement capability/period tests, protected install, provider canary, compensation, then old-accessor revocation | controller recreation; apps continue | accessor recorded; token value never recorded or backed up |
| libreFS root user/password | suspected disclosure, administrator rotation, or initial bootstrap | operator writes the application KV version through the approved Bao workflow, then `rotate-secrets` validates it and invokes the resident fail-closed rematerializer; only the stateless container is replaced through Doco and `/data` is preserved | libreFS container recreation only | OpenBao KV history and approved encrypted OpenBao backup |
| c1 edge record | issuance credential, MaxMind credential, CrowdSec key, or ingestion token rotation | operator updates KV through the approved Bao workflow; `rotate-secrets` validates schema/version and shared values, atomically materializes files, verifies the exact consumer, and compensates failure | affected edge helper or security service; Doco owns any application recreation | OpenBao KV history and encrypted OpenBao backup |
| Forgejo record | database/application/SMTP/Kopia/libreFS credential rotation | operator updates KV through the approved Bao workflow; `rotate-secrets` drains through the lifecycle gate, materializes and verifies the exact consumer, and compensates before old credential revocation | Forgejo/PostgreSQL or backup interruption according to the changed key; Doco owns recreation | OpenBao KV history and encrypted OpenBao backup; same-host Kopia is not secret custody |
| c0 monitoring record | Telegram, ingestion, or backup heartbeat token rotation | operator updates KV through the approved Bao workflow; `rotate-secrets` materializes c0 monitoring and the c1 heartbeat, then verifies authenticated ingest, heartbeat, and alert delivery | Gatus/Vector and c1 backup timer as required; Doco owns recreation | OpenBao KV history and encrypted OpenBao backup |
| wildcard TLS record and service tokens | certificate renewal, short validity, key compromise, token disclosure, or role-policy change | `provision-secrets` or `rotate-secrets` validates publisher/reader capabilities and fenced certificate fields; resident readers validate a generation before atomic activation | consumer reload only after validation; failure retains the prior generation | OpenBao KV history and encrypted OpenBao backup |

Doco 0.111.0 does not receive the c1 edge or Forgejo values. The Ansible-owned
`roles/runtime_assets/` transactions validate the exact existing application records and
atomically install mode-0400 files below the applications mount; they do not create or update
application KV values. Compose contains only `create_host_path: false` bind paths. Doco remains the
sole owner of application deployment and recreation. The existing libreFS pair retains its
separate proven rematerialization transaction because that service predates this contract.

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

## Exact materialization contract

The root-owned c1 materializer maps the edge and Forgejo records to protected host files before Doco
starts. Secret values are bind-mounted under `/run/secrets` or, for generated application
configuration, at the exact owner-readable configuration path with `create_host_path: false` and
mode `0400`. PostgreSQL receives its password through `POSTGRES_PASSWORD_FILE`; Forgejo receives a
rendered owner-readable `app.ini`; Certbot receives a Cloudflare credentials file; CrowdSec uses
its supported `/run/secrets/bouncer_key_spoa` bootstrap path; SPOA, GeoIP, and Vector receive only
their own files. The Forgejo bootstrap password/email projection is removed after the `trosvald`
administrator is verified. No resolved value may remain in environment, inspect metadata, Doco
worktrees, ordinary logs, or backup staging.

The wildcard host installers write root-owned mode-0600 generation files. HAProxy and c0 Vector
receive a read-only combined PEM generated from validated `fullchain` plus `private_key`; libreFS
receives its native certificate/key filenames. `certificate`, `serial`, and `not_after` are checked
against the parsed full chain before activation. A mismatched, stale, missing, short-validity, or
partial record never replaces the active generation.

The approved exact versions are Forgejo `16.0.3-rootless`, PostgreSQL `18.3-alpine`, HAProxy
`3.2.23-alpine`, CrowdSec `1.7.8`, SPOA bouncer `0.3.1`, Certbot DNS Cloudflare `5.7.0`, Vector
`0.58.0-alpine`, Gatus `5.36.0`, and Kopia `0.23.1`, each pinned to its linux/amd64 manifest in
Compose. The scoped libreFS credentials provide access only to the Forgejo Kopia bucket. This
same-c1 repository is intentionally not off-host durability.

No placeholder external credential is generated. Before provisioning real values, use unique
non-secret canaries through every materialization path and apply the leakage gates above. Real
value provisioning is an explicit operator checkpoint through `scripts/with-openbao-runtime.sh`;
repository validation never attempts it.
