# AllocDB Replicated Cluster on KubeVirt

This repo now has a bootstrap script for one fresh 3-replica AllocDB cluster plus one control VM
on KubeVirt.

Script:

```bash
ALLOCDB_LOCAL_CLUSTER_BIN=/path/to/allocdb-local-cluster \
./scripts/bootstrap-allocdb-kubevirt.sh
```

Recommended guest binary:

```bash
cargo build -p allocdb-node --target x86_64-unknown-linux-musl --bin allocdb-local-cluster
```

Defaults:

- Uses `home-ops/kubeconfig` (override with `KUBECONFIG_PATH=...`).
- Uses namespace `kubevirt` (override with `K8S_NAMESPACE=...`).
- Uses Ubuntu Noble amd64 cloud image as the base disk (override with `BASE_IMAGE_URL=...`).
- Uses KubeVirt storage class `longhorn-strict-local-wffc` by default (override with
  `STORAGE_CLASS_NAME=...`).
- Uses `10Gi` root disks for the base image and cloned guests by default (override with
  `ROOTDISK_SIZE=...`).
- Uses one fresh workspace under `/tmp/allocdb-kubevirt-bootstrap` (override with `WORKDIR=...`).
- Creates `allocdb-control` plus `allocdb-replica-{1,2,3}`.
- Uses KubeVirt `bridge` pod networking so every guest gets one unique routable pod IP.
- Stages the host-built `allocdb-local-cluster` binary over SSH after the guests boot.

Host prerequisites:

- `kubectl`
- `jq`
- `ssh`
- `scp`
- `ssh-keygen`

What the script does:

1. Ensures one reusable base `DataVolume` exists for the Ubuntu cloud image.
   If the cached base image size does not match `ROOTDISK_SIZE`, the script recreates it.
2. Renders one cluster manifest for the control VM, the three replica VMs, and one Service per VM.
3. Deletes and recreates the AllocDB VMs and their root disks for one fresh bootstrap.
4. Waits for the VMIs to become ready, discovers their live pod IPs, and renders the exact
   `cluster-layout.txt` that AllocDB expects.
5. Creates one temporary helper pod inside the cluster and uses it to SSH/SCP directly to the guest
   pod IPs.
6. Uploads the binary, per-replica systemd unit, and one `allocdb-qemu-control`-compatible helper
   script through that helper pod.
7. Starts `allocdb-replica.service` on each replica and validates the cluster with
   `sudo /usr/local/bin/allocdb-qemu-control status` on the control VM.

Render-only validation:

```bash
./scripts/bootstrap-allocdb-kubevirt.sh render-manifest
kubectl --kubeconfig ./kubeconfig apply --dry-run=client -f /tmp/allocdb-kubevirt-bootstrap/allocdb-kubevirt-cluster.yaml
```

Operational notes:

- The script intentionally performs one fresh bootstrap on every full run. If the VMs are deleted
  and recreated later, rerun the script so the staged `cluster-layout.txt` matches the new VMI IPs.
- The control helper is installed at `/usr/local/bin/allocdb-qemu-control` on purpose, so the
  KubeVirt control VM uses the same remote command surface as the existing QEMU testbed.
- The bootstrap helper pod is deleted automatically by default. Set `KEEP_HELPER_POD=1` when you
  want to leave it up for manual guest access or ad hoc validation.
- The default storage profile is intentionally ephemeral: `longhorn-strict-local-wffc` keeps one local
  Longhorn replica on the same node as the attached workload. This reduces cross-node storage
  traffic for Jepsen lanes, but it is not a high-availability storage profile.
- `longhorn-strict-local-wffc` uses `WaitForFirstConsumer`, so the VM is scheduled before the local
  Longhorn volume is pinned to a node. This avoids early storage placement forcing the VM onto a
  memory-constrained host.
- The rendered VMs also apply per-cluster spread rules: the three replicas are forced onto
  different hosts and the control VM is spread with the same lane, so a 4-VM lane tends to land as
  `2-1-1` across the three mini PCs.
- The generated SSH keypair and rendered bootstrap artifacts under `WORKDIR` are sensitive local
  artifacts. Keep them local.
- This bootstrap path stages `allocdb-local-cluster` only. It does not yet install a full KubeVirt
  Jepsen runner or a KubeVirt-native failover orchestrator.

Useful follow-up checks:

```bash
kubectl --kubeconfig ./kubeconfig -n kubevirt get vm,vmi,svc | rg 'allocdb-'
KEEP_HELPER_POD=1 ALLOCDB_LOCAL_CLUSTER_BIN=/path/to/allocdb-local-cluster ./scripts/bootstrap-allocdb-kubevirt.sh
kubectl --kubeconfig ./kubeconfig -n kubevirt exec allocdb-bootstrap-helper -- \
  ssh -i /tmp/allocdb-stage/id_ed25519 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  allocdb@$(kubectl --kubeconfig ./kubeconfig -n kubevirt get vmi allocdb-control -o jsonpath='{.status.interfaces[0].ipAddress}') \
  'sudo /usr/local/bin/allocdb-qemu-control status'
```
