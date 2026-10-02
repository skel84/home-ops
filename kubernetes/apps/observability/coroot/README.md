# Coroot Community Edition

Coroot is managed by the official Coroot operator and CE Helm charts through
Argo CD. The dedicated `coroot` namespace permits the privileged node agents
needed for eBPF on Talos. Node agents collect metrics, logs, profiles, and traces
on every node; the cluster agent supplies Kubernetes metadata. Trace sampling
is 10 percent, with a 30-second metrics interval.

Metrics are forwarded to the existing kube-prometheus-stack remote-write
receiver. Coroot uses a 10 GiB volume for configuration and its one-day metric
cache, one 10 GiB ClickHouse volume with one-day telemetry TTLs, and one 1 GiB
Keeper volume. PVCs are retained if the Coroot resource is deleted. The image
versions are pinned. ClickStack is a separate deployment.

A PostSync Job enables SQLite WAL journaling for the metric cache. This setting
persists in the database and avoids the rollback-journal write contention seen
during initialization on replicated Longhorn storage. The job shares Coroot's
node and its existing PVC; it creates no additional storage or credentials.

The UI is available at https://coroot.rbl.lol through the internal ingress.
Log in as `admin`; the initial password is encrypted in
`config/secrets.sops.yaml` and provisioned as the `coroot-admin` Secret.
Retrieve it locally when needed:

```sh
kubectl --kubeconfig ./kubeconfig -n coroot get secret coroot-admin \
    -o jsonpath='{.data.password}' | base64 --decode
```

Validation should include all three node agents ready, fresh Coroot series in
Prometheus, increasing ClickHouse telemetry row counts, one-day TTLs in
`system.tables`, and a browser login with applications visible. One-day TTLs
expire data during background merges; they are not a hard disk-space limit.

To roll back, revert the observability GitOps commit and reconcile the affected
Applications. Coroot volumes have a Retain policy for recovery. Prometheus can
be stopped by setting `prometheus.enabled: false` and reconciling its Application;
preserve the new Prometheus PVC.
