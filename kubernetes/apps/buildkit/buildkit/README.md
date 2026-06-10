# BuildKit

Rootless BuildKit daemon for native in-cluster image builds.

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
  operator
```

The local registry at `192.168.0.27:30500` is configured as an insecure HTTP registry in `buildkitd.toml`.
