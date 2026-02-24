# Chubo Nomad on KubeVirt

This repo now has a bootstrap script for a Chubo/OpenWonton (Nomad-compatible) control plane on KubeVirt.

Script:

```bash
./scripts/bootstrap-chubo-kubevirt.sh
```

Defaults:

- Uses `home-ops/kubeconfig` (override with `KUBECONFIG_PATH=...`).
- Uses Chubo release `v0.1.2` `nocloud-amd64.raw.zst` (override with `RELEASE_TAG=...`).
- Creates a 3-node `server-client` control plane (`chubo-cp-1..3`) in namespace `kubevirt`, so control-plane nodes can run workloads.
- Uses KubeVirt `bridge` pod networking so each guest gets a unique IP.

What the script validates:

1. DataVolume import for the Chubo `nocloud` image.
2. VM/VMI readiness for `chubo-cp-1..3`.
3. `openwontonstatus` is healthy with `peerCount=3` and `aclReady=true`.
4. `nomad operator raft list-peers` returns 3 peers.

Operational notes:

- The script intentionally does a fresh bootstrap for the 3 control-plane VMs on each run (it deletes/recreates their VM+disk objects).
- Generated secrets/chuboconfig are written under `/tmp/chubo-kubevirt-bootstrap/`.
- Keep those generated artifacts local and treat them as sensitive.
