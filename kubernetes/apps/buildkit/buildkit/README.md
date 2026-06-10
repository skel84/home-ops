# BuildKit

BuildKit daemon for native in-cluster image builds.

The service is `ClusterIP` only. For local use, port-forward it and create a Docker Buildx remote builder:

```bash
kubectl -n buildkit port-forward svc/buildkitd 1234:1234

docker buildx create \
  --name home-ops-buildkit \
  --driver remote \
  tcp://127.0.0.1:1234

docker buildx build \
  --builder home-ops-buildkit \
  --platform linux/amd64 \
  -t 192.168.0.27:30500/cc-transcoder/operator:dev \
  -f operator/Dockerfile \
  --push \
  .
```

The local registry at `192.168.0.27:30500` is configured as an insecure HTTP registry in `buildkitd.toml`.
Build cache is currently ephemeral (`emptyDir`) so the builder can run without depending on Longhorn capacity.
The daemon currently runs privileged because rootless BuildKit requires user namespaces that are not enabled on the nodes.
It uses `hostNetwork` so pushes can reach the node-local registry endpoint at `192.168.0.27:30500`.
