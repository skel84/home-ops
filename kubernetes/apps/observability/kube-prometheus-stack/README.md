# kube-prometheus-stack

## Current configuration

Prometheus is enabled with a new 10 GiB Longhorn volume, one-day retention,
and a 7 GB block retention cap to leave space for the WAL and head. It scrapes
ServiceMonitors and PodMonitors across namespaces, including Longhorn, and the
NAS ScrapeConfigs. Grafana uses the `prometheus-operated` service.

The remote-write receiver accepts Coroot telemetry. A one-hour out-of-order
window allows delayed agent batches. Coroot shares this Prometheus instance;
it does not deploy a second metrics store.

Verify ingestion using `/api/v1/targets` and queries such as
`longhorn_volume_robustness`, `kube_node_info`, and `container_cpu_usage_seconds_total`.


## Temporary Prometheus shutdown (2026-09-10)

Prometheus was disabled explicitly on 2026-09-10 to stop ingestion and storage
I/O. It was re-enabled on 2026-10-02 with the smaller storage and retention
settings above.

This disables only the Prometheus server and its chart-managed endpoint resources
when Argo CD reconciles the change. Keep the Application, operator, CRDs,
Alertmanager, exporters, scrape configuration and Grafana dashboards in place.
Loki and Grafana are unchanged; Prometheus-backed dashboards and alert evaluation
will be unavailable while the server is off.

The shutdown initially retained the PVC. The owner subsequently authorized
deleting `prometheus-kube-prometheus-stack-db-prometheus-kube-prometheus-stack-0`
(UID `7e0d6d44-bf46-48bd-9a0c-e16169c69b60`) on 2026-09-10. Normal CSI reclamation
completed by 09:49:33Z: the PVC, PV, Longhorn volume and replicas are absent.
Historical metrics on that volume were permanently removed; recovery has not
been established. Other applications' claims were not removed. This operation
does not establish that Prometheus caused the earlier shared-storage problems.

## NAS Deployments

### node-exporter

```yaml
services:
  node-exporter:
    command:
      - '--path.rootfs=/host/root'
      - '--path.procfs=/host/proc'
      - '--path.sysfs=/host/sys'
      - '--path.udev.data=/host/root/run/udev/data'
      - '--web.listen-address=0.0.0.0:9100'
      - >-
        --collector.filesystem.mount-points-exclude=^/(sys|proc|dev|host|etc)($$|/)
    image: quay.io/prometheus/node-exporter:v1.9.0
    network_mode: host
    ports:
      - '9100:9100'
    restart: always
    volumes:
      - /:/host/root:ro
      - /proc:/host/proc:ro
      - /sys:/host/sys:ro
```

### smartctl-exporter

```yaml
services:
  smartctl-exporter:
    command:
      - '--smartctl.device-exclude=nvme0'
    image: quay.io/prometheuscommunity/smartctl-exporter:v0.13.0
    ports:
      - '9633:9633'
    privileged: True
    restart: always
    user: root
```
