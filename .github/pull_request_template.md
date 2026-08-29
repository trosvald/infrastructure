## Summary

<!-- State the intended outcome, not a file-by-file inventory. -->

-

## Delivery and impact

- **Owner/controller:** <!-- Flux, Doco-CD, Ansible, Talos, systemd, or docs/tooling -->
- **Affected targets:** <!-- Clusters, namespaces, hosts, devices, or services -->
- **Reconciliation path:** <!-- Source path through the controller that applies it -->
- **Ordering/readiness:** <!-- dependsOn, health checks, operator gates, or N/A -->
- **Expected live effect:** <!-- Restart, rollout, network change, no live effect, etc. -->
- **Live mutation status:** <!-- Not performed, or already performed with evidence below -->

## Safety

- **Persistent state:** <!-- PVCs, named volumes, Raft, device state, backups, or N/A -->
- **Secrets:** <!-- OpenBao, External Secrets, SOPS, Secret references, or N/A -->
- **Connectivity:** <!-- Management path, DNS, routing, ingress, NETCONF, or N/A -->
- **Destructive/prune behavior:** <!-- Deletions, replacement, prune effects, or none -->
- **Failure boundary:** <!-- How the change fails closed and what remains reachable -->

## Validation

### Local and offline

<!-- Include only commands actually run and their observed results. -->

- [ ] `just ...`
- [ ] `git diff --check`
- [ ] Applicable deterministic or syntax validation

### Live proof

<!-- Use “Not performed” with the reason when the change has not touched live systems. -->

- Not performed.
- Or: <!-- Exact observed health, persistence, routing, service, or device evidence -->

### CI

- [ ] Required `Gitleaks` check passed
- [ ] Applicable path-scoped workflow passed
- [ ] Any unrelated or baseline failure is identified below

## Rollout

1. <!-- Controller or operator action -->
2. <!-- Readiness or convergence observation -->
3. <!-- Post-merge health and persistence check -->

## Rollback

1. <!-- Exact revert, suspend, restore, or device rollback action -->
2. <!-- State and data preservation requirement -->
3. <!-- Verification that service and management access recovered -->

## Scope exclusions

- <!-- Explicitly name adjacent systems and operations intentionally unchanged. -->

## Final checks

- [ ] Documentation is updated, or `N/A` is explained
- [ ] No plaintext secret, token, private key, recovery material, or backup is included
- [ ] Images, actions, and tool versions remain pinned where required
- [ ] Controller ownership, dependencies, health checks, and `prune` semantics are preserved
- [ ] Live actions already performed are explicitly recorded
