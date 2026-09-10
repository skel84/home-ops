# kube-prometheus-stack

## Temporary Prometheus shutdown (2026-09-10)

`values.yaml` sets `prometheus.enabled: false`, with the enabled setting commented
beside it. All ingress, discovery, retention, resource and storage settings remain
intact. Merely commenting out the Prometheus block would restore the chart's
enabled default, so the explicit false value is necessary.

This disables only the Prometheus server and its chart-managed endpoint resources
when Argo CD reconciles the change. Keep the Application, operator, CRDs,
Alertmanager, exporters, scrape configuration and Grafana dashboards in place.
Loki and Grafana are unchanged; Prometheus-backed dashboards and alert evaluation
will be unavailable while the server is off.

Do not delete its PVC or Longhorn volume. A read-only check before this edit found
StatefulSet `prometheus-kube-prometheus-stack` using `Retain` for both deletion and
scale-down, and PVC
`prometheus-kube-prometheus-stack-db-prometheus-kube-prometheus-stack-0` had no
owner references. Recheck these before activation if live configuration changes.
Retaining the volume preserves stored data, not continuous metrics collection or
a guarantee of storage health. This change is not a shared-storage repair.

To resume, replace `enabled: false` with the adjacent commented `enabled: true`,
then publish/reconcile through the normal GitOps workflow. No other settings need
to be restored. Verify the existing claim is reused and the Prometheus Pod becomes
ready. The local edit alone does not stop the running service; activation requires
publishing the change and Argo CD reconciliation with pruning.

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
