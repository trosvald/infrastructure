# Talos machine configuration

This runbook covers only rendering, applying, rebooting, and verifying Talos machine
configuration. Cluster bootstrap and Kubernetes reconciliation are outside this workflow.

## Authority and toolchain

OpenBao is the runtime authority for protected topology and Talos secrets:

- `kv/platform/talos/bsd/topology`
- `kv/platform/talos/bsd/secrets`

The apply path does not read `.private/**`. Protected local inventory is used only by the separate
inventory-provisioning utilities that populate reviewed OpenBao records.

Run commands from the mise-activated repository shell. The renderer rejects any `talosctl` client
whose version differs from `topology.versions.talos`; the current reviewed version is
`v1.14.0-rc.2`. Do not use a Homebrew or system `talosctl` in place of the locked project binary.

```sh
mise trust
mise install --locked
just -l talos
```

## Network roles

Each topology node has two distinct addresses:

- `bootstrap_address`: the permanent Talos management API on `eno1`; every Talos management,
  apply, reboot, and verification command targets this address.
- `address`: the data and Kubernetes address on `bond0`; it is rendered and verified but is never
  used as the Talos management target.

Redacted renderer output names the latter `data_address`. Verification output reports
`management_api: "ready"` only after authenticated access through `bootstrap_address` succeeds.

## Apply one node

Apply exactly one node per invocation:

```sh
just talos apply-node bsd-k8s-01
```

The recipe asks for confirmation before entering the authenticated OpenBao runtime. Hostnames are
validated against the ordered OpenBao topology; adding an inventory node does not require a new
hard-coded shell branch.

For a node in maintenance mode, the command:

1. renders and validates its complete configuration with the locked Talos client;
2. verifies the exact install, LocalPV, and future OSD disk identities;
3. verifies both protected X710 identities at 10 Gb/s and synchronized NTP;
4. refuses initial provisioning if etcd has already been bootstrapped;
5. runs `apply-config --insecure --mode=auto` once through `bootstrap_address`;
6. polls the authenticated management API and full expected machine state for up to 60 attempts
   at five-second intervals;
7. requests a non-blocking reboot through the authenticated management API;
8. polls the management API and full machine state again to prove reboot persistence.

Talos API availability alone is not convergence. Full-state polling covers version, both addresses,
preferred data route, active-backup bond and member links, extensions, loaded i915, LocalPV volume,
disks, kernel parameters, and watchdog state.

For an already installed node, the command never falls back to insecure apply. It verifies the
installed state, requests a reboot, and repeats full verification. Success is reported as:

```text
<hostname>: installed configuration verified; apply skipped
```

A newly installed node succeeds only with:

```text
<hostname>: configuration applied and reboot persistence verified
```

After the latter message, the installation has survived reboot and the installer USB can be moved
to the next host.

## Recommended installation order

Move the reviewed Talos installer USB between hosts and invoke one confirmed command at a time:

```sh
just talos apply-node bsd-k8s-01
just talos apply-node bsd-k8s-02
just talos apply-node bsd-k8s-03
just talos apply-node bsd-k8s-04
just talos apply-node bsd-k8s-05
```

Do not start a node command until its maintenance API is reachable at the topology
`bootstrap_address`. A failed preflight performs no apply or reboot. A rerun has no local resume
marker: an installed node follows the authenticated verify/reboot/verify branch, while a node still
in maintenance follows the apply branch.

## Read-only verification

Verify an installed node without applying or rebooting it:

```sh
just talos verify-node bsd-k8s-01
```

Expected redacted status:

```json
{"hostname":"bsd-k8s-01","management_api":"ready","network":"verified","hardware":"verified"}
```

Run the offline deterministic renderer and orchestration regressions with:

```sh
just talos test
```

The tests cover maintenance apply, installed-node skip, delayed route convergence, preflight
failure atomicity, installed drift, etcd refusal, management-only targeting, and rejection of a
mismatched Talos client.
