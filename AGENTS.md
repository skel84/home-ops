# Repository Guidelines

## Project Structure & Module Organization
- Root config: `cluster.yaml`, `nodes.yaml`, `makejinja.toml`, `Taskfile.yaml`.
- Templates in `templates/` render into `kubernetes/`, `talos/`, `bootstrap/` via `task configure`.
- `kubernetes/apps/<namespace>/<app>/` stores per-app values and optional kustomize resources (`config/`, `kustomization.yaml`).
- `kubernetes/argo/` wires Argo CD:
  - `apps/<namespace>/<app>.yaml` = Argo Applications
  - `settings/cluster-settings.yaml` = AppProject `kubernetes`
  - `repositories/` = repo secrets (`*.sops.yaml`)
- `scripts/` contains operational helpers; `tests/stackgres/` is experimental.

## Build, Test, and Development Commands
- `mise install` / `mise run deps` install pinned tooling and Helm plugins from `.mise.toml`.
- `task init` generates `cluster.yaml`/`nodes.yaml` and keys.
- `task configure` validates schemas (Cue), renders templates (makejinja), encrypts `*.sops.yaml`, and validates Kubernetes/Talos.
- Do not run `task configure` unless the user explicitly asks; it overwrites generated output under `bootstrap/`, `kubernetes/`, and `talos/` and re-encrypts secrets.
- `task bootstrap:talos` installs Talos and writes `kubeconfig`; `task bootstrap:apps` installs core apps.
- `task reconcile` forces Argo CD to sync.

## Argo CD Layout & Adding Services
- Each app has two pieces: the Argo Application in `kubernetes/argo/apps/<ns>/<app>.yaml` and the app config in `kubernetes/apps/<ns>/<app>/`.
- The Application typically uses two sources: this repo for values and a Helm repo for the chart. Example structure:
- Prefer Helm charts from official/maintained sources when available; fall back to upstream manifests or Kustomize only when no suitable chart exists or when explicitly requested. Avoid unofficial third-party charts unless the user approves.

```yaml
spec:
  sources:
    - repoURL: "https://github.com/skel84/home-ops.git"
      path: kubernetes/apps/<ns>/<app>
      ref: repo
    - repoURL: <helm-repo>
      chart: <chart>
      helm:
        releaseName: <app>
        valueFiles:
          - $repo/kubernetes/apps/<ns>/<app>/values.yaml
```

- If you need extra Kubernetes objects (secrets, configmaps), add `config/` and a `kustomization.yaml` that includes them (see `kubernetes/apps/downloads/sonarr/`).
- Keep `metadata.name`, `releaseName`, and destination namespace aligned with the app/namespace.

## Coding Style & Naming Conventions
- `.editorconfig`: 2-space indent by default; 4 spaces for `.md`/`.sh`; tabs for `.cue`.
- Secrets must stay in `*.sops.yaml` (encrypted via `.sops.yaml` rules).
- Common files: `values.yaml`, `values.sops.yaml`, `kustomization.yaml`, `secret-generator.yaml`.

## Testing Guidelines
- Primary check: `task configure`. No single test runner for `tests/stackgres/`.

## Runtime Validation & Debug Commands
- Cluster/app sanity:
  - `kubectl config current-context`
  - `kubectl config view --minify`
- Argo CD app health loop:
  - `argocd app list --grpc-web`
  - `argocd app get <app> --grpc-web`
  - `argocd app sync <app> --grpc-web --dry-run`
  - `argocd app sync <app> --grpc-web`
  - `argocd app wait <app> --grpc-web --timeout 600`
- Kubernetes runtime checks:
  - `kubectl -n <namespace> get pods`
  - `kubectl -n <namespace> get events --sort-by=.metadata.creationTimestamp`
  - `kubectl -n <namespace> describe pod <pod>`
  - `kubectl -n <namespace> logs <pod> --tail=200`
  - `kubectl -n <namespace> logs <pod> -c <container> --previous --tail=200`
- K8s debug helpers:
  - `kubectl -n <namespace> get pod <pod> -o yaml`
  - `kubectl -n <namespace> describe pod <pod>`
  - `kubectl debug <pod> -n <namespace> --image=busybox --copy-to=<pod>-debug -- sh`
  - Add an ephemeral container for live debug when needed.
- VM readiness and SSH verification (KubeVirt):
  - `kubectl -n kubevirt patch vm/ubuntu-example --type=merge -p '{"spec":{"running":true}}'`
  - `kubectl -n kubevirt wait vmi/ubuntu-example --for=condition=Ready --timeout=600s`
  - `kubectl -n kubevirt get vmi ubuntu-example -o jsonpath='{.status.interfaces[0].ipAddress}'`
  - `VM_IP=$(kubectl -n kubevirt get vmi ubuntu-example -o jsonpath='{.status.interfaces[0].ipAddress}')`
  - `ssh -i <private_key_path> -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ubuntu@${VM_IP} 'hostname; sudo -n true'`
  - `kubectl -n kubevirt get vms` (no resources means no VMs are currently managed)

## Commit & Pull Request Guidelines
- Prefer Conventional Commits (`chore:`, `feat:`, `fix:`, `refactor:`; optional scopes like `chore(mise):`).
- PRs should state cluster impact, list affected paths (e.g., `kubernetes/...`), and include commands run (usually `task configure`). Avoid plaintext secrets.
