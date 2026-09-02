#!/usr/bin/env bash
set -euo pipefail

readonly ROOT_NAMESPACE=flux-system
readonly ROOTS=(flux-repositories infrastructure-controllers infrastructure-configs cluster-apps)

usage() {
    printf 'usage: %s <status|activate|suspend|resume|inventory-retired-data> [arguments...]\n' "$0" >&2
    exit 2
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || {
        printf 'required command is unavailable: %s\n' "$1" >&2
        exit 1
    }
}

root_ready() {
    local name=$1
    [[ "$(kubectl -n "$ROOT_NAMESPACE" get kustomization "$name" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" == True ]]
}

root_exists() {
    kubectl -n "$ROOT_NAMESPACE" get kustomization "$1" >/dev/null 2>&1
}

activate_root() {
    local requested=$1 index=-1 predecessor=''
    local i
    for i in "${!ROOTS[@]}"; do
        if [[ "${ROOTS[$i]}" == "$requested" ]]; then
            index=$i
            break
        fi
    done
    (( index >= 0 )) || {
        printf 'unknown reconciliation root: %s\n' "$requested" >&2
        exit 2
    }
    root_exists "$requested" || {
        printf 'reconciliation root does not exist: %s/%s\n' "$ROOT_NAMESPACE" "$requested" >&2
        exit 1
    }
    if (( index > 0 )); then
        predecessor=${ROOTS[$((index - 1))]}
        root_ready "$predecessor" || {
            printf 'refusing out-of-order activation: predecessor %s is not Ready\n' "$predecessor" >&2
            exit 1
        }
    fi
    kubectl -n "$ROOT_NAMESPACE" patch kustomization "$requested" --type=merge -p '{"spec":{"suspend":null}}'
    flux reconcile kustomization "$requested" --namespace "$ROOT_NAMESPACE" --with-source
    root_ready "$requested" || {
        printf 'activation completed without a Ready root: %s\n' "$requested" >&2
        exit 1
    }
}

resource_name() {
    case "$1" in
        ks) printf 'kustomization' ;;
        hr) printf 'helmrelease' ;;
        *) printf 'kind must be ks or hr, got: %s\n' "$1" >&2; exit 2 ;;
    esac
}

set_resource_suspension() {
    local operation=$1 kind=$2 namespace=$3 name=$4 resource owner
    resource=$(resource_name "$kind")
    kubectl -n "$namespace" get "$resource" "$name" >/dev/null
    owner=$(kubectl -n "$namespace" get "$resource" "$name" -o jsonpath='{.metadata.labels.kustomize\.toolkit\.fluxcd\.io/name}')
    [[ -n "$owner" ]] || {
        printf 'refusing to mutate non-Flux-owned %s %s/%s\n' "$resource" "$namespace" "$name" >&2
        exit 1
    }
    if [[ "$operation" == suspend ]]; then
        kubectl -n "$namespace" patch "$resource" "$name" --type=merge -p '{"spec":{"suspend":true}}'
    else
        kubectl -n "$namespace" patch "$resource" "$name" --type=merge -p '{"spec":{"suspend":null}}'
        flux reconcile "$resource" "$name" --namespace "$namespace" --with-source
    fi
}

status() {
    printf 'Git sources (URLs and revisions only; credentials are never read):\n'
    kubectl get gitrepositories.source.toolkit.fluxcd.io -A \
        -o custom-columns='NAMESPACE:.metadata.namespace,NAME:.metadata.name,URL:.spec.url,INTERVAL:.spec.interval,READY:.status.conditions[?(@.type=="Ready")].status,REVISION:.status.artifact.revision'
    printf '\nReconciliation roots:\n'
    kubectl -n "$ROOT_NAMESPACE" get kustomizations "${ROOTS[@]}" \
        -o custom-columns='NAME:.metadata.name,SUSPENDED:.spec.suspend,READY:.status.conditions[?(@.type=="Ready")].status,REVISION:.status.lastAppliedRevision'
    printf '\nControllers:\n'
    kubectl get helmreleases.helm.toolkit.fluxcd.io -A \
        -o custom-columns='NAMESPACE:.metadata.namespace,NAME:.metadata.name,SUSPENDED:.spec.suspend,READY:.status.conditions[?(@.type=="Ready")].status'
}

inventory_retired_data() {
    local namespace
    kubectl get --raw=/version >/dev/null
    printf 'Retirement inventory (metadata only; Secret resources and data are excluded)\n'
    for namespace in default media actions-runner-system; do
        printf '\nNamespace %s:\n' "$namespace"
        if kubectl get namespace "$namespace" >/dev/null 2>&1; then
            printf '  namespace: present\n'
        elif kubectl get namespace "$namespace" 2>&1 | grep -Fq '(NotFound)'; then
            printf '  namespace: absent\n  pvc: none\n'
            continue
        else
            printf 'failed to inventory namespace: %s\n' "$namespace" >&2
            exit 1
        fi
        kubectl -n "$namespace" get pvc -o custom-columns='PVC:.metadata.name,PHASE:.status.phase,VOLUME:.spec.volumeName,STORAGE_CLASS:.spec.storageClassName,OWNER_KIND:.metadata.ownerReferences[0].kind,OWNER_NAME:.metadata.ownerReferences[0].name,BACKUP:.metadata.annotations.backup\.monosense\.io/status' --no-headers || true
    done
    printf '\nBound PV and StorageClass metadata:\n'
    kubectl get pv -o custom-columns='PV:.metadata.name,CLAIM_NAMESPACE:.spec.claimRef.namespace,CLAIM:.spec.claimRef.name,STORAGE_CLASS:.spec.storageClassName,RECLAIM:.spec.persistentVolumeReclaimPolicy,PHASE:.status.phase' --no-headers \
        | awk '$2 == "default" || $2 == "media" || $2 == "actions-runner-system"'
    kubectl get storageclass -o custom-columns='STORAGE_CLASS:.metadata.name,PROVISIONER:.provisioner,RECLAIM:.reclaimPolicy' --no-headers
}

require_command kubectl
case "${1:-}" in
    status)
        [[ $# == 1 ]] || usage
        status
        ;;
    activate)
        [[ $# == 2 ]] || usage
        require_command flux
        activate_root "$2"
        ;;
    suspend|resume)
        [[ $# == 4 ]] || usage
        require_command flux
        set_resource_suspension "$1" "$2" "$3" "$4"
        ;;
    inventory-retired-data)
        [[ $# == 1 ]] || usage
        inventory_retired_data
        ;;
    *) usage ;;
esac
