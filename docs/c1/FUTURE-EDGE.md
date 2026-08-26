# c1 Future Edge and Applications

Date: 2026-08-26
Status: design reservation only; nothing in this document is deployed by the current mission;
application paths revised to `/srv/applications`

## Boundary

Only a future HAProxy instance receives SERVICES address `10.25.13.66`. Mattermost, Forgejo,
CrowdSec, AppSec/SPOA components, and PostgreSQL remain on private Docker bridge networks. No
database, application admin endpoint, Doco endpoint, OpenBao endpoint, libreFS console, or private
control API publishes a host port.

```text
future SRX DNAT
      |
      v
HAProxy 10.25.13.66
      |
      +-- private edge network -- CrowdSec Engine
      |                       `-- HAProxy SPOA/AppSec bouncer
      |
      +-- private Mattermost frontend -- Mattermost -- private PostgreSQL
      |
      `-- private Forgejo frontend ---- Forgejo ---- private PostgreSQL
```

HAProxy terminates future public TLS and is the only HTTP ingress boundary. CrowdSec uses its
current supported HAProxy SPOA/AppSec integration, not the legacy Lua bouncer. Control traffic,
LAPI, AppSec, metrics, and administration remain private.

## Address and network reservations

- `10.25.13.65`: current libreFS API/console address; not a future edge address.
- `10.25.13.66`: reserved for future HAProxy only.
- Mattermost, Forgejo, CrowdSec, and PostgreSQL consume no SERVICES address unless a later review
  proves a specific routing need.
- Each application owns a private frontend network shared only with HAProxy and a private database
  network shared only with its PostgreSQL instance.
- CrowdSec owns a private security network shared only with HAProxy/SPOA components that require it.

Live collision checks and repository IPAM updates are required again before `.66` is assigned.

## Storage

Future ordinary state lives in explicit directories below `/srv/applications/apps`, on the 1 TB
application partition (`/srv/applications`). Each project has separate ownership, quota/capacity
monitoring, backup schedule, and restore procedure. PostgreSQL data is never stored in a container
writable layer.

All durable application and database backups are off-host. A second directory or disk on c1 is the
same failure domain and is not a backup.

libreFS may serve scoped application S3 storage only after:

1. trusted TLS is deployed and tested;
2. an off-host libreFS backup and isolated restore pass;
3. a non-root, bucket-scoped service account and rotation procedure exist;
4. the application's failure behavior when S3 is unavailable is reviewed.

No application receives libreFS root credentials.

## HAProxy and CrowdSec

A later implementation must pin exact HAProxy, CrowdSec Engine, SPOA bouncer, and AppSec images by
version and digest. It must verify configuration syntax, health endpoints, non-root/capability needs,
log handling, SPOA timeouts/failure mode, AppSec request-body limits, upgrade compatibility, and a
safe bypass/rollback mode before exposure.

The `kv/docker/c1/haproxy-crowdsec` record remains `BLOCKED_BY_DESIGN`. The selected stack creates
or documents the exact formats for:

- CrowdSec LAPI machine/bouncer credential;
- HAProxy SPOA bouncer credential;
- optional AppSec credential;
- DNS-provider or certificate credential only after certificate architecture approval.

HAProxy configuration must distinguish public frontends from internal admin/health paths. The
CrowdSec failure mode must not silently make the management plane unavailable. Logs must exclude
credentials, authorization headers, and sensitive request bodies.

## Mattermost Community Edition

A future Mattermost project includes:

- pinned Mattermost CE and PostgreSQL images;
- one private HAProxy-to-Mattermost network;
- one private Mattermost-to-PostgreSQL network;
- no database host port;
- explicit application and database persistent directories on the application tier;
- off-host database and file backup with restore test;
- reviewed SMTP/OIDC integration only when real providers exist.

`kv/docker/c1/mattermost` remains `BLOCKED_BY_VERSION`. Before values are generated, the exact
Mattermost release must define database password, at-rest encryption key, signing/salt/session
material, target file variables, and rotation behavior. SMTP and OIDC values are
`OPERATOR_SUPPLIED`. S3 keys are blocked by the libreFS gates above.

## Forgejo

A future Forgejo project includes:

- pinned Forgejo and PostgreSQL images;
- one private HAProxy-to-Forgejo network;
- one private Forgejo-to-PostgreSQL network;
- no database or admin host port;
- explicit repository/LFS/application and database storage on the application tier;
- off-host backup with repository, LFS, database, metadata, and checksum restore tests.

`kv/docker/c1/forgejo` remains `BLOCKED_BY_VERSION`. The exact release must define PostgreSQL
password, application secret key, internal token, JWT secret, LFS JWT secret, file-variable support,
and rotation behavior before generation. SMTP and OAuth values are `OPERATOR_SUPPLIED`. S3 keys are
blocked by the libreFS gates.

Forgejo SSH requires a separate reviewed decision: either a dedicated HAProxy TCP frontend or an
explicit SRX DNAT to a narrowly exposed service port. It must not reuse an admin console or expose a
database.

## Future SRX boundary

No SRX change is part of the current mission. `ansible/junos/adoption.yml` remains `adopted: false`,
so running SRX configuration cannot be treated as automation-owned and no deploy command is
permitted.

A future separately reviewed SRX change must specify:

- public DNS and certificate prerequisites;
- DNAT only to HAProxy `.66` and separately approved Forgejo SSH, if any;
- source/destination zones and address-book entries;
- least-privilege security policies and session/logging behavior;
- hairpin/internal-DNS behavior;
- dependency and rollback order;
- candidate diff, commit-check, ten-minute `commit confirmed`, operational verification, and exact
  confirmation binding.

It cannot proceed until the adoption gate is completed through the repository's manual parity and
review process. No workaround, direct mutation, or gate override is acceptable.

## Future acceptance gate

Before any future service is deployed:

1. pin exact images and inspect their runtime/file-secret contracts;
2. update the secret contract and least-privilege policy only for deployed consumers;
3. add offline Compose/security/leakage tests;
4. provision application directories only below `/srv/applications` on the mounted 1 TB partition 2;
5. prove off-host backup and isolated restore;
6. prove private-network isolation and HAProxy-only exposure;
7. review CrowdSec failure and rollback behavior;
8. obtain a separate implementation and SRX review where applicable.
