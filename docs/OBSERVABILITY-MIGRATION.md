# Observability migration

This repository replaces the Prometheus runtime and the former VictoriaLogs collector with an all-OSS VictoriaMetrics observability stack:

- **Metrics:** `victoria-metrics-k8s-stack` with VMAgent, VMSingle, VMAlert, VMAlertmanager, VictoriaMetrics Operator, kube-state-metrics, and node-exporter.
- **Logs:** `victoria-logs-single` with a Ceph-backed 50 GiB volume and 90-day retention.
- **Collection:** Fluent Bit as a node-wide DaemonSet, forwarding Kubernetes container logs to VictoriaLogs over the JSON-line ingestion API.
- **Visualization:** the existing Grafana Operator deployment, with Prometheus-compatible VictoriaMetrics, Alertmanager, and VictoriaLogs datasources.

## Compatibility design

Application charts and raw manifests throughout the repository already emit `ServiceMonitor`, `PodMonitor`, `PrometheusRule`, `Probe`, `ScrapeConfig`, and `AlertmanagerConfig` resources. The Prometheus server and Prometheus Operator runtime have been removed, while the lightweight `prometheus-operator-crds` chart remains so those APIs continue to exist.

VictoriaMetrics Operator converts those resources into their VictoriaMetrics equivalents. Converter ownership is enabled so generated VictoriaMetrics objects are garbage-collected when the source object is removed. This avoids invasive per-application chart changes and preserves existing rules, probes, scrape definitions, and alert routing.

## Reconciliation order

Flux now converges the observability stack in this order:

1. Prometheus compatibility CRDs and Grafana Operator.
2. VictoriaMetrics Kubernetes stack.
3. VictoriaLogs.
4. Fluent Bit.
5. Grafana instance/datasources and compatible consumers such as Karma, Kromgo, Prometheus Adapter, and Silence Operator.

The bootstrap CRD Helmfile also renders both `prometheus-operator-crds` and `victoria-metrics-k8s-stack` CRDs before Flux reconciliation.

## Service endpoints

| Purpose | In-cluster endpoint |
| --- | --- |
| Prometheus-compatible metrics API | `http://vmsingle-victoria-metrics.observability.svc.cluster.local:8428` |
| Alertmanager API | `http://vmalertmanager-victoria-metrics.observability.svc.cluster.local:9093` |
| VictoriaLogs API | `http://victoria-logs.observability.svc.cluster.local:9428` |

The existing external hostnames remain `prometheus.monosense.io`, `alertmanager.monosense.io`, `grafana.monosense.io`, and `vlogs.monosense.io` to minimize client and DNS changes.

## Data and rollout notes

- The existing Prometheus TSDB is **not** imported into VMSingle by these manifests. Historical metrics remain on the old Prometheus PVC until that PVC is intentionally archived or deleted.
- Helm-created StatefulSet PVCs are normally retained when the old release is removed. Confirm the old Prometheus and Alertmanager PVCs before cleanup.
- During the first reconciliation there can be a brief gap while the old node-exporter is removed and the VictoriaMetrics stack's exporter DaemonSet becomes ready. Flux will retry failed Helm reconciliations.
- Fluent Bit stores tail offsets and filesystem buffering under `/var/lib/fluent-bit` on each node, reducing duplicate or lost records across pod restarts.

## Static validation completed

- Parsed 87 observability YAML files containing 110 documents.
- Checked 66 local references in the observability Kustomize tree and 289 local Kustomize references across the repository.
- Built a static Flux dependency graph containing 74 Kustomizations and 56 dependency edges; all migration paths and dependencies resolve without cycles.
- Checked the new chart value keys against the pinned chart defaults, ran `git diff --check`, and parsed the Renovate JSON5 configuration successfully.

A live cluster reconciliation, server-side Kubernetes validation, and full Helm rendering still need to be performed in the target cluster or CI environment.

## Unrelated pre-existing repository findings

- `kubernetes/apps/networking/external-dns/unifi/helmrelease.yaml` reuses the YAML anchor `&port` twice in one document, which strict YAML parsers reject.
- `kubernetes/apps/actions-runner-system/actions-runner-controller/runners/home-operations/kustomization.yaml` references a missing `./rbac.yaml`.

These files were not changed because they are outside the observability migration scope.

## Post-deployment checks

```sh
flux get kustomizations -A
flux get helmreleases -A

kubectl -n observability get vmsingle,vmagent,vmalert,vmalertmanager
kubectl -n observability get pods,pvc
kubectl -n observability get vmservicescrape,vmpodscrape,vmrule,vmprobe,vmscrapeconfig,vmalertmanagerconfig

kubectl -n observability port-forward svc/vmsingle-victoria-metrics 8428:8428
curl -fsS 'http://127.0.0.1:8428/api/v1/query?query=up'

kubectl -n observability port-forward svc/victoria-logs 9428:9428
curl -fsS 'http://127.0.0.1:9428/select/logsql/query' --data-urlencode 'query=*' | head
```
