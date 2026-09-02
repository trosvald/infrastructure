#!/usr/bin/env bash
set -euo pipefail

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
[[ $# -ge 1 ]] || fail 'usage: llmkube-mac.sh <issue-csr|revoke|sync|health|upgrade|rollback|uninstall> [arguments]'
action="$1"
shift
readonly namespace=ai
readonly identity=llmkube-metal-agent
readonly mac_ip=10.25.13.95

need() {
    local command
    for command in "$@"; do command -v "$command" >/dev/null 2>&1 || fail "$command is required"; done
}
remote() {
    : "${LLMKUBE_MAC_ADMIN:?set LLMKUBE_MAC_ADMIN to the named administrator}"
    ssh -o BatchMode=yes -o StrictHostKeyChecking=yes "$LLMKUBE_MAC_ADMIN@$mac_ip" "$@"
}

case "$action" in
    issue-csr)
        need kubectl openssl base64 jq mktemp
        [[ $# -eq 1 ]] || fail 'issue-csr requires one empty output directory'
        out="$1"
        [[ -d "$out" && -z "$(find "$out" -mindepth 1 -maxdepth 1 -print -quit)" ]] || fail 'output directory must exist and be empty'
        umask 077
        work="$(mktemp -d)"
        trap 'rm -rf "$work"' EXIT
        csr_name="$identity-$(date -u +%Y%m%d%H%M%S)"
        openssl ecparam -name prime256v1 -genkey -noout -out "$work/client.key"
        openssl req -new -key "$work/client.key" -subj "/CN=$csr_name" -out "$work/client.csr"
        request="$(base64 <"$work/client.csr" | tr -d '\n')"
        jq -n --arg name "$csr_name" --arg request "$request" '{apiVersion:"certificates.k8s.io/v1",kind:"CertificateSigningRequest",metadata:{name:$name,labels:{"app.kubernetes.io/name":"llmkube-metal-agent"}},spec:{request:$request,signerName:"kubernetes.io/kube-apiserver-client",expirationSeconds:31536000,usages:["client auth"]}}' \
            | kubectl apply -f - >/dev/null
        kubectl certificate approve "$csr_name" >/dev/null
        kubectl wait --for=jsonpath='{.status.certificate}' csr/"$csr_name" --timeout=2m >/dev/null
        kubectl get csr "$csr_name" -o jsonpath='{.status.certificate}' | openssl base64 -d -A >"$work/client.crt"
        server="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')"
        kubectl config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' | openssl base64 -d -A >"$work/ca.crt"
        kubectl config set-cluster monosense --kubeconfig="$work/kubeconfig" --server="$server" --certificate-authority="$work/ca.crt" --embed-certs=true >/dev/null
        kubectl config set-credentials "$csr_name" --kubeconfig="$work/kubeconfig" --client-certificate="$work/client.crt" --client-key="$work/client.key" --embed-certs=true >/dev/null
        kubectl config set-context llmkube --kubeconfig="$work/kubeconfig" --cluster=monosense --user="$csr_name" --namespace="$namespace" >/dev/null
        kubectl config use-context llmkube --kubeconfig="$work/kubeconfig" >/dev/null
        install -m 0600 "$work/client.key" "$out/client.key"
        install -m 0644 "$work/client.crt" "$out/client.crt"
        install -m 0600 "$work/kubeconfig" "$out/kubeconfig"
        printf '%s\n' "$csr_name" >"$out/csr-name"
        openssl x509 -in "$out/client.crt" -noout -checkend 2592000 >/dev/null || fail 'issued certificate has less than 30 days validity'
        kubectl -n "$namespace" create rolebinding "$csr_name" --role=llmkube-metal-agent --user="$csr_name" \
            --dry-run=client -o yaml | kubectl apply -f - >/dev/null
        ;;
    revoke)
        need kubectl
        [[ $# -eq 1 ]] || fail 'revoke requires the exact CSR name'
        [[ "$1" =~ ^llmkube-metal-agent-[0-9]{14}$ ]] || fail 'CSR name is outside the fixed Metal identity pattern'
        kubectl -n "$namespace" delete rolebinding "$1" --ignore-not-found
        kubectl delete csr "$1" --ignore-not-found
        printf 'Exact Metal certificate identity authorization and CSR record removed.\n'
        ;;
    sync)
        need kubectl jq mktemp tar ssh
        [[ $# -eq 0 ]] || fail 'sync takes no arguments'
        work="$(mktemp -d)"
        trap 'rm -rf "$work"' EXIT
        chmod 0700 "$work"
        for spec in llmkube-mac-tls:tls.crt llmkube-mac-tls:tls.key llmkube-mac-tls:ca.crt llmkube-embedding-api-key:api-key mac-embedding-client-tls:ca.crt; do
            secret="${spec%%:*}"; key="${spec#*:}"
            kubectl -n "$namespace" get secret "$secret" -o json \
                | jq -er --arg key "$key" '.data[$key]' | base64 -d >"$work/$secret-$key"
        done
        chmod 0600 "$work"/*
        openssl x509 -in "$work/llmkube-mac-tls-tls.crt" -noout -checkend 1209600 >/dev/null || fail 'server certificate expires within 14 days'
        openssl verify -CAfile "$work/llmkube-mac-tls-ca.crt" "$work/llmkube-mac-tls-tls.crt" >/dev/null
        [[ "$(wc -c <"$work/llmkube-embedding-api-key-api-key")" -ge 32 ]] || fail 'embedding API key is too short'
        tar -C "$work" -cf - . | remote sudo /usr/local/libexec/llmkube/install-generation
        ;;
    health)
        need kubectl curl jq openssl
        [[ $# -eq 0 ]] || fail 'health takes no arguments'
        kubectl -n "$namespace" get inferenceservice qwen3-embedding -o json | jq -e '.status.conditions[] | select(.type == "Ready" and .status == "True")' >/dev/null
        [[ "$(kubectl -n "$namespace" get endpointslice qwen3-embedding-mac -o jsonpath='{.endpoints[0].addresses[0]}')" == "$mac_ip" ]]
        remote sudo launchctl print system/io.monosense.llmkube-metal-agent >/dev/null
        remote sudo launchctl print system/io.monosense.llmkube-caddy >/dev/null
        remote sudo launchctl print system/io.monosense.llmkube-sync >/dev/null
        ;;
    upgrade)
        [[ $# -eq 2 ]] || fail 'upgrade requires component and reviewed version'
        [[ "$1" =~ ^(metal-agent|llama|caddy|sync)$ && "$2" =~ ^[A-Za-z0-9._-]+$ ]] || fail 'invalid component or version'
        remote sudo /usr/local/libexec/llmkube/switch-version upgrade "$1" "$2"
        ;;
    rollback)
        [[ $# -eq 1 && "$1" =~ ^(metal-agent|llama|caddy|sync)$ ]] || fail 'rollback requires one component'
        remote sudo /usr/local/libexec/llmkube/switch-version rollback "$1"
        ;;
    uninstall)
        [[ $# -eq 0 ]] || fail 'uninstall takes no arguments'
        remote sudo /usr/local/libexec/llmkube/uninstall
        ;;
    *) fail "unknown action: $action" ;;
esac
