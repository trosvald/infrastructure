#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
evidence="$repo_dir/.private/storage-acceptance.json"
namespace=storage-acceptance
image='docker.io/library/haproxy:3.2.23-alpine@sha256:0666a2c2f41d341084ed2da85392b48cdcd766adfa28231f31305724ed5c6ea5'
for tool in jq kubectl talosctl; do
    command -v "$tool" >/dev/null 2>&1 || { echo "missing locked tool: $tool" >&2; exit 1; }
done
[[ -f "$evidence" && ! -L "$evidence" ]] || {
    echo "reviewed disruptive storage evidence is unavailable: $evidence" >&2
    exit 1
}
jq -e '
  keys == ["bond_failover","ceph_recovery","kernel_clients","localpv_xfs","node_reboot","reviewed_at","secure_erase_policy"] and
  (.reviewed_at | type == "string" and fromdateiso8601 <= now) and
  .bond_failover == {tor1: true, tor2: true} and
  .ceph_recovery == {healthy_after_osd_out: true, healthy_after_osd_return: true} and
  .kernel_clients == {cephfs: true, rbd: true} and
  .localpv_xfs == {path: "/var/mnt/local-hostpath", project_quota: true} and
  .node_reboot == {pvc_read_after: true, quorum_maintained: true} and
  .secure_erase_policy == "verified-erase-or-physical-destruction"
' "$evidence" >/dev/null || {
    echo 'storage evidence must prove both ToRs, recovery, kernel clients, XFS quota, reboot, and decommission policy' >&2
    exit 1
}

classes="$(kubectl get storageclass -o json)"
jq -e '
  ([.items[] | {name:.metadata.name, default:(.metadata.annotations["storageclass.kubernetes.io/is-default-class"] // "false"), reclaim:.reclaimPolicy, binding:.volumeBindingMode}] | sort_by(.name)) as $classes |
  ($classes | map(select(.name | test("^(local-hostpath|ceph-(rbd|filesystem))-(delete|retain)$"))) | length) == 6 and
  ($classes | map(select(.default == "true") | .name)) == ["ceph-rbd-delete"] and
  all($classes[] | select(.name | test("^local-hostpath-")); .binding == "WaitForFirstConsumer") and
  all($classes[] | select(.name | endswith("-delete")); .reclaim == "Delete") and
  all($classes[] | select(.name | endswith("-retain")); .reclaim == "Retain")
' <<<"$classes" >/dev/null

mgr="$(kubectl -n rook-ceph get pods -l app=rook-ceph-mgr,ceph_daemon_id=a -o jsonpath='{.items[0].metadata.name}')"
[[ -n "$mgr" ]]
ceph_status="$(kubectl -n rook-ceph exec "$mgr" -c mgr -- ceph status --format json)"
jq -e '.health.status == "HEALTH_OK" and .monmap.num_mons == 3 and (.quorum_names | length) == 3 and .osdmap.num_osds == 5 and .osdmap.num_up_osds == 5 and .osdmap.num_in_osds == 5' <<<"$ceph_status" >/dev/null
osd_tree="$(kubectl -n rook-ceph exec "$mgr" -c mgr -- ceph osd tree --format json)"
jq -e '[.nodes[] | select(.type == "host" and ([.children[]?] | length) == 1) | .name] | sort == ["bsd-k8s-01","bsd-k8s-02","bsd-k8s-03","bsd-k8s-04","bsd-k8s-05"]' <<<"$osd_tree" >/dev/null
[[ "$(kubectl -n rook-ceph exec "$mgr" -c mgr -- ceph config get mon public_network)" == '10.25.14.0/24' ]]

cleanup() { kubectl delete namespace "$namespace" --wait=false >/dev/null 2>&1 || true; }
trap cleanup EXIT
kubectl delete namespace "$namespace" --ignore-not-found --wait=true >/dev/null
cat <<YAML | kubectl apply -f - >/dev/null
apiVersion: v1
kind: Namespace
metadata:
  name: $namespace
  labels:
    pod-security.kubernetes.io/enforce: restricted
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: rbd-source, namespace: $namespace}
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: ceph-rbd-delete
  resources: {requests: {storage: 64Mi}}
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: local-source, namespace: $namespace}
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: local-hostpath-delete
  resources: {requests: {storage: 64Mi}}
---
apiVersion: v1
kind: Pod
metadata: {name: rbd-writer, namespace: $namespace}
spec:
  restartPolicy: Never
  securityContext: {runAsNonRoot: true, runAsUser: 99, runAsGroup: 99, fsGroup: 99, seccompProfile: {type: RuntimeDefault}}
  containers:
    - name: writer
      image: $image
      command: [/bin/sh, -ceu, 'printf storage-acceptance >/data/proof']
      securityContext: {allowPrivilegeEscalation: false, capabilities: {drop: [ALL]}}
      volumeMounts: [{name: data, mountPath: /data}]
  volumes: [{name: data, persistentVolumeClaim: {claimName: rbd-source}}]
---
apiVersion: v1
kind: Pod
metadata: {name: local-writer, namespace: $namespace}
spec:
  restartPolicy: Never
  securityContext: {runAsNonRoot: true, runAsUser: 99, runAsGroup: 99, fsGroup: 99, seccompProfile: {type: RuntimeDefault}}
  containers:
    - name: writer
      image: $image
      command: [/bin/sh, -ceu, 'printf localpv-acceptance >/data/proof; test "\$(cat /data/proof)" = localpv-acceptance']
      securityContext: {allowPrivilegeEscalation: false, capabilities: {drop: [ALL]}}
      volumeMounts: [{name: data, mountPath: /data}]
  nodeSelector: {kubernetes.io/hostname: bsd-k8s-04}
  volumes: [{name: data, persistentVolumeClaim: {claimName: local-source}}]
YAML
kubectl -n "$namespace" wait --for=jsonpath='{.status.phase}'=Succeeded pod/rbd-writer --timeout=5m >/dev/null
kubectl -n "$namespace" wait --for=jsonpath='{.status.phase}'=Succeeded pod/local-writer --timeout=5m >/dev/null
cat <<YAML | kubectl apply -f - >/dev/null
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshot
metadata: {name: rbd-source, namespace: $namespace}
spec:
  volumeSnapshotClassName: ceph-rbd-delete
  source: {persistentVolumeClaimName: rbd-source}
YAML
kubectl -n "$namespace" wait --for=jsonpath='{.status.readyToUse}'=true volumesnapshot/rbd-source --timeout=5m >/dev/null
cat <<YAML | kubectl apply -f - >/dev/null
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: rbd-restored, namespace: $namespace}
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: ceph-rbd-delete
  dataSource: {apiGroup: snapshot.storage.k8s.io, kind: VolumeSnapshot, name: rbd-source}
  resources: {requests: {storage: 64Mi}}
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: cephfs-shared, namespace: $namespace}
spec:
  accessModes: [ReadWriteMany]
  storageClassName: ceph-filesystem-delete
  resources: {requests: {storage: 64Mi}}
---
apiVersion: v1
kind: Pod
metadata: {name: storage-reader, namespace: $namespace}
spec:
  restartPolicy: Never
  securityContext: {runAsNonRoot: true, runAsUser: 99, runAsGroup: 99, fsGroup: 99, seccompProfile: {type: RuntimeDefault}}
  containers:
    - name: reader
      image: $image
      command: [/bin/sh, -ceu, 'test "\$(cat /rbd/proof)" = storage-acceptance; printf cephfs-acceptance >/cephfs/proof; sleep 300']
      securityContext: {allowPrivilegeEscalation: false, capabilities: {drop: [ALL]}}
      volumeMounts: [{name: rbd, mountPath: /rbd}, {name: cephfs, mountPath: /cephfs}]
  nodeSelector: {kubernetes.io/hostname: bsd-k8s-04}
  volumes: [{name: rbd, persistentVolumeClaim: {claimName: rbd-restored}}, {name: cephfs, persistentVolumeClaim: {claimName: cephfs-shared}}]
---
apiVersion: v1
kind: Pod
metadata: {name: cephfs-reader, namespace: $namespace}
spec:
  restartPolicy: Never
  securityContext: {runAsNonRoot: true, runAsUser: 99, runAsGroup: 99, fsGroup: 99, seccompProfile: {type: RuntimeDefault}}
  containers:
    - name: reader
      image: $image
      command: [/bin/sh, -ceu, 'until test -f /cephfs/proof; do sleep 1; done; test "\$(cat /cephfs/proof)" = cephfs-acceptance']
      securityContext: {allowPrivilegeEscalation: false, capabilities: {drop: [ALL]}}
      volumeMounts: [{name: cephfs, mountPath: /cephfs}]
  nodeSelector: {kubernetes.io/hostname: bsd-k8s-05}
  volumes: [{name: cephfs, persistentVolumeClaim: {claimName: cephfs-shared}}]
YAML
kubectl -n "$namespace" wait --for=condition=Ready pod/storage-reader --timeout=5m >/dev/null
kubectl -n "$namespace" wait --for=jsonpath='{.status.phase}'=Succeeded pod/cephfs-reader --timeout=5m >/dev/null

for address in 10.25.11.11 10.25.11.12 10.25.11.13 10.25.11.14 10.25.11.15; do
    modules="$(talosctl --nodes "$address" read /proc/modules)"
    [[ "$modules" == *$'rbd '* && "$modules" == *$'ceph '* ]] || {
        echo "$address: kernel RBD/CephFS clients were not loaded by the smoke test" >&2
        exit 1
    }
done
printf 'Storage acceptance passed: LocalPV write, exact Ceph devices, quorum, five OSDs, RBD snapshot restore, cross-node CephFS, kernel clients, and reviewed recovery evidence\n'
