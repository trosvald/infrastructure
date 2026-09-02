#!/usr/bin/env bash
set -euo pipefail

[[ $# == 1 ]] || { printf 'Usage: %s <librefs|r2>\n' "$0" >&2; exit 64; }
case "$1" in
    librefs) object_store=postgres-librefs ;;
    r2) object_store=postgres-r2 ;;
    *) printf 'restore source must be librefs or r2\n' >&2; exit 64 ;;
esac

namespace=database
name="postgres-restore-${1}-$(date -u +%Y%m%d%H%M%S)"
cleanup() {
    kubectl -n "$namespace" delete cluster.postgresql.cnpg.io "$name" --wait=true --ignore-not-found
    kubectl -n "$namespace" delete pvc -l "cnpg.io/cluster=$name" --wait=true --ignore-not-found
}
trap cleanup EXIT HUP INT TERM

[[ "$(kubectl -n "$namespace" get cluster postgres -o jsonpath='{.status.readyInstances}')" == 3 ]] || {
    printf 'source PostgreSQL cluster is not three-instance ready\n' >&2
    exit 1
}
kubectl -n "$namespace" apply -f - <<YAML
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: $name
spec:
  instances: 1
  imageName: ghcr.io/cloudnative-pg/postgresql:17.11-202608310816-system-bookworm@sha256:d0e93a6fb034e97067733ea2febe701dd97a070011c82d5fdabe99ca84b1f3d4
  bootstrap:
    recovery:
      source: source
  externalClusters:
    - name: source
      plugin:
        name: barman-cloud.cloudnative-pg.io
        parameters:
          barmanObjectName: $object_store
          serverName: postgres
  storage:
    storageClass: local-hostpath-delete
    size: 50Gi
YAML
kubectl -n "$namespace" wait --for=jsonpath='{.status.readyInstances}'=1 "cluster/$name" --timeout=30m
pod="$(kubectl -n "$namespace" get pod -l "cnpg.io/cluster=$name,role=primary" -o jsonpath='{.items[0].metadata.name}')"
databases="$(kubectl -n "$namespace" exec "$pod" -- psql -U postgres -d postgres -v ON_ERROR_STOP=1 -Atqc \
    "SELECT string_agg(datname, ',' ORDER BY datname) FROM pg_database WHERE datname IN ('keycloak','litellm')")"
[[ "$databases" == keycloak,litellm ]]
kubectl -n "$namespace" exec "$pod" -- pg_dump -U postgres --schema-only --no-owner keycloak >/dev/null
kubectl -n "$namespace" exec "$pod" -- pg_dump -U postgres --schema-only --no-owner litellm >/dev/null
[[ "$(kubectl -n "$namespace" get cluster postgres -o jsonpath='{.metadata.name}')" == postgres ]]
printf 'isolated %s restore and tenant-only logical extraction passed\n' "$1"
