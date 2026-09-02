#!/usr/bin/env bash
set -euo pipefail

readonly script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
readonly dispositions="$script_dir/../retirement/media-dispositions.tsv"

kubectl get --raw=/version >/dev/null
if ! kubectl get namespace media >/dev/null 2>&1; then
    printf 'media namespace is already absent; no live objects or volumes were deleted\n'
    exit 0
fi

mapfile -t claims < <(kubectl -n media get pvc -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
for claim in "${claims[@]}"; do
    [[ -n "$claim" ]] || continue
    record=$(awk -F '\t' -v claim="$claim" '$1 == claim { print $0 }' "$dispositions")
    [[ -n "$record" ]] || {
        printf 'refusing retirement: PVC %s has no explicit disposition\n' "$claim" >&2
        exit 1
    }
    IFS=$'\t' read -r _ disposition backup evidence <<<"$record"
    case "$disposition" in
        delete)
            [[ "$backup" == verified && -n "$evidence" ]] || {
                printf 'refusing retirement: PVC %s deletion lacks verified backup evidence\n' "$claim" >&2
                exit 1
            }
            ;;
        keep|export)
            printf 'refusing namespace deletion: PVC %s disposition %s must be completed outside the namespace first\n' "$claim" "$disposition" >&2
            exit 1
            ;;
        *)
            printf 'refusing retirement: invalid disposition for PVC %s: %s\n' "$claim" "$disposition" >&2
            exit 1
            ;;
    esac
done

kubectl delete namespace media --wait=true
printf 'retired media namespace after exact PVC disposition and backup checks\n'
