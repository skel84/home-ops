#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=scripts/lib/common.sh
source "${ROOT_DIR}/scripts/lib/common.sh"

KUBECONFIG_PATH="${KUBECONFIG_PATH:-${ROOT_DIR}/kubeconfig}"
K8S_NAMESPACE="${K8S_NAMESPACE:-kubevirt}"
RELEASE_TAG="${RELEASE_TAG:-v0.1.2}"
CHUBOCTL="${CHUBOCTL:-/Users/francesco/repos/cislacorp/chubo-os/chubo/_out/chuboctl-darwin-arm64}"
WORKDIR="${WORKDIR:-/tmp/chubo-kubevirt-bootstrap}"
BASE_DV_NAME="${BASE_DV_NAME:-}"

CP1_NAME="${CP1_NAME:-chubo-cp-1}"
CP2_NAME="${CP2_NAME:-chubo-cp-2}"
CP3_NAME="${CP3_NAME:-chubo-cp-3}"

LOCAL_CHUBO_API_PORT="${LOCAL_CHUBO_API_PORT:-50002}"
LOCAL_NOMAD_API_PORT="${LOCAL_NOMAD_API_PORT:-46462}"
PROXY_POD_NAME="${PROXY_POD_NAME:-chubo-cp2-proxy}"
OPENWONTON_WAIT_SECONDS="${OPENWONTON_WAIT_SECONDS:-600}"
NOMAD_RAFT_WAIT_SECONDS="${NOMAD_RAFT_WAIT_SECONDS:-300}"
NOMAD_HELPERS_WAIT_SECONDS="${NOMAD_HELPERS_WAIT_SECONDS:-180}"

CHUBO_API_ENDPOINT="127.0.0.1:${LOCAL_CHUBO_API_PORT}"
CHUBO_API_NODE="127.0.0.1"

KUBECTL=(kubectl --kubeconfig "${KUBECONFIG_PATH}")

function cleanup() {
    if [[ -n "${PORT_FORWARD_PID:-}" ]] && kill -0 "${PORT_FORWARD_PID}" >/dev/null 2>&1; then
        kill "${PORT_FORWARD_PID}" >/dev/null 2>&1 || true
    fi
}

trap cleanup EXIT

function kube() {
    "${KUBECTL[@]}" "$@"
}

function wait_for_dv_succeeded() {
    local dv_name="$1"
    local timeout_seconds="$2"
    local deadline=$((SECONDS + timeout_seconds))

    while true; do
        local phase
        phase="$(kube -n "${K8S_NAMESPACE}" get dv "${dv_name}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"

        if [[ "${phase}" == "Succeeded" ]]; then
            log info "DataVolume is ready" "name=${dv_name}"
            return 0
        fi

        if ((SECONDS >= deadline)); then
            log error "Timed out waiting for DataVolume" "name=${dv_name}" "phase=${phase:-missing}"
        fi

        sleep 5
    done
}

function wait_for_port() {
    local host="$1"
    local port="$2"
    local timeout_seconds="$3"
    local deadline=$((SECONDS + timeout_seconds))

    while true; do
        if nc -z "${host}" "${port}" >/dev/null 2>&1; then
            return 0
        fi

        if ((SECONDS >= deadline)); then
            log error "Timed out waiting for local forwarded port" "host=${host}" "port=${port}"
        fi

        sleep 1
    done
}

function wait_for_openwonton_healthy() {
    local timeout_seconds="$1"
    local deadline=$((SECONDS + timeout_seconds))

    while true; do
        local status_json
        if status_json="$("${CHUBOCTL}" get openwontonstatus --namespace chubo -o json \
            --chuboconfig "${CHUBOCONFIG_FILE}" \
            -e "${CHUBO_API_ENDPOINT}" \
            -n "${CHUBO_API_NODE}" 2>/dev/null)"; then
            local healthy acl_ready peer_count
            healthy="$(jq -r '.spec.healthy // false' <<<"${status_json}")"
            acl_ready="$(jq -r '.spec.aclReady // false' <<<"${status_json}")"
            peer_count="$(jq -r '.spec.peerCount // 0' <<<"${status_json}")"

            log info "OpenWonton readiness" \
                "healthy=${healthy}" \
                "acl_ready=${acl_ready}" \
                "peer_count=${peer_count}"

            if [[ "${healthy}" == "true" && "${acl_ready}" == "true" && "${peer_count}" == "3" ]]; then
                return 0
            fi
        else
            log warn "OpenWonton status unavailable yet"
        fi

        if ((SECONDS >= deadline)); then
            log error "Timed out waiting for OpenWonton readiness" \
                "required=healthy:true,aclReady:true,peerCount:3"
        fi

        sleep 5
    done
}

function wait_for_nomad_raft_peers() {
    local expected_count="$1"
    local timeout_seconds="$2"
    local deadline=$((SECONDS + timeout_seconds))

    while true; do
        local raft_output
        if raft_output="$(nomad operator raft list-peers 2>/dev/null)"; then
            local peer_count
            peer_count="$(echo "${raft_output}" | tail -n +2 | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')"

            log info "Nomad raft readiness" "expected=${expected_count}" "actual=${peer_count}"
            if [[ "${peer_count}" == "${expected_count}" ]]; then
                NOMAD_RAFT_OUTPUT="${raft_output}"
                NOMAD_RAFT_PEER_COUNT="${peer_count}"
                return 0
            fi
        else
            log warn "Nomad raft status unavailable yet"
        fi

        if ((SECONDS >= deadline)); then
            log error "Timed out waiting for Nomad raft peers" \
                "expected=${expected_count}"
        fi

        sleep 5
    done
}

function fetch_nomad_helpers_with_retry() {
    local timeout_seconds="$1"
    local deadline=$((SECONDS + timeout_seconds))

    while true; do
        rm -rf "${NOMAD_HELPERS_DIR}"

        if "${CHUBOCTL}" nomadconfig "${NOMAD_HELPERS_DIR}" --force \
            --chuboconfig "${CHUBOCONFIG_FILE}" \
            -e "${CHUBO_API_ENDPOINT}" \
            -n "${CHUBO_API_NODE}"; then
            return 0
        fi

        if ((SECONDS >= deadline)); then
            log error "Timed out fetching Nomad helper bundle"
        fi

        log warn "Nomad helper bundle fetch failed, retrying"
        sleep 5
    done
}

function render_cluster_manifest() {
    local manifest_path="$1"
    local cp1_cfg="$2"
    local cp2_cfg="$3"
    local cp3_cfg="$4"

    cat >"${manifest_path}" <<EOF
---
apiVersion: v1
kind: Service
metadata:
    name: ${CP1_NAME}-peer
    namespace: ${K8S_NAMESPACE}
    labels:
        app.kubernetes.io/name: ${CP1_NAME}
        app.kubernetes.io/component: peer
spec:
    clusterIP: None
    publishNotReadyAddresses: true
    selector:
        kubevirt.io/domain: ${CP1_NAME}
    ports:
        - name: nomad-rpc
          protocol: TCP
          port: 4647
          targetPort: 4647
        - name: nomad-serf
          protocol: TCP
          port: 4648
          targetPort: 4648
        - name: consul-rpc
          protocol: TCP
          port: 8300
          targetPort: 8300
        - name: consul-serf
          protocol: TCP
          port: 8301
          targetPort: 8301
---
apiVersion: v1
kind: Service
metadata:
    name: ${CP2_NAME}-peer
    namespace: ${K8S_NAMESPACE}
    labels:
        app.kubernetes.io/name: ${CP2_NAME}
        app.kubernetes.io/component: peer
spec:
    clusterIP: None
    publishNotReadyAddresses: true
    selector:
        kubevirt.io/domain: ${CP2_NAME}
    ports:
        - name: nomad-rpc
          protocol: TCP
          port: 4647
          targetPort: 4647
        - name: nomad-serf
          protocol: TCP
          port: 4648
          targetPort: 4648
        - name: consul-rpc
          protocol: TCP
          port: 8300
          targetPort: 8300
        - name: consul-serf
          protocol: TCP
          port: 8301
          targetPort: 8301
---
apiVersion: v1
kind: Service
metadata:
    name: ${CP3_NAME}-peer
    namespace: ${K8S_NAMESPACE}
    labels:
        app.kubernetes.io/name: ${CP3_NAME}
        app.kubernetes.io/component: peer
spec:
    clusterIP: None
    publishNotReadyAddresses: true
    selector:
        kubevirt.io/domain: ${CP3_NAME}
    ports:
        - name: nomad-rpc
          protocol: TCP
          port: 4647
          targetPort: 4647
        - name: nomad-serf
          protocol: TCP
          port: 4648
          targetPort: 4648
        - name: consul-rpc
          protocol: TCP
          port: 8300
          targetPort: 8300
        - name: consul-serf
          protocol: TCP
          port: 8301
          targetPort: 8301
---
apiVersion: v1
kind: Service
metadata:
    name: ${CP1_NAME}-api
    namespace: ${K8S_NAMESPACE}
    labels:
        app.kubernetes.io/name: ${CP1_NAME}
        app.kubernetes.io/component: api
spec:
    type: LoadBalancer
    allocateLoadBalancerNodePorts: true
    selector:
        kubevirt.io/domain: ${CP1_NAME}
    ports:
        - name: chubo-api
          protocol: TCP
          port: 50000
          targetPort: 50000
        - name: nomad-https
          protocol: TCP
          port: 4646
          targetPort: 4646
        - name: consul-https
          protocol: TCP
          port: 8500
          targetPort: 8500
---
apiVersion: v1
kind: Service
metadata:
    name: ${CP2_NAME}-api
    namespace: ${K8S_NAMESPACE}
    labels:
        app.kubernetes.io/name: ${CP2_NAME}
        app.kubernetes.io/component: api
spec:
    type: LoadBalancer
    allocateLoadBalancerNodePorts: true
    selector:
        kubevirt.io/domain: ${CP2_NAME}
    ports:
        - name: chubo-api
          protocol: TCP
          port: 50000
          targetPort: 50000
        - name: nomad-https
          protocol: TCP
          port: 4646
          targetPort: 4646
        - name: consul-https
          protocol: TCP
          port: 8500
          targetPort: 8500
---
apiVersion: v1
kind: Service
metadata:
    name: ${CP3_NAME}-api
    namespace: ${K8S_NAMESPACE}
    labels:
        app.kubernetes.io/name: ${CP3_NAME}
        app.kubernetes.io/component: api
spec:
    type: LoadBalancer
    allocateLoadBalancerNodePorts: true
    selector:
        kubevirt.io/domain: ${CP3_NAME}
    ports:
        - name: chubo-api
          protocol: TCP
          port: 50000
          targetPort: 50000
        - name: nomad-https
          protocol: TCP
          port: 4646
          targetPort: 4646
        - name: consul-https
          protocol: TCP
          port: 8500
          targetPort: 8500
EOF

    append_vm_manifest "${manifest_path}" "${CP1_NAME}" "${cp1_cfg}"
    append_vm_manifest "${manifest_path}" "${CP2_NAME}" "${cp2_cfg}"
    append_vm_manifest "${manifest_path}" "${CP3_NAME}" "${cp3_cfg}"
}

function append_vm_manifest() {
    local manifest_path="$1"
    local vm_name="$2"
    local machineconfig_path="$3"

    cat >>"${manifest_path}" <<EOF
---
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
    name: ${vm_name}
    namespace: ${K8S_NAMESPACE}
    labels:
        app.kubernetes.io/name: ${vm_name}
spec:
    runStrategy: Always
    dataVolumeTemplates:
        - metadata:
              name: ${vm_name}-rootdisk
          spec:
              source:
                  pvc:
                      namespace: ${K8S_NAMESPACE}
                      name: ${BASE_DV_NAME}
              storage:
                  accessModes:
                      - ReadWriteOnce
                  resources:
                      requests:
                          storage: 20Gi
                  storageClassName: longhorn
    template:
        metadata:
            labels:
                kubevirt.io/domain: ${vm_name}
        spec:
            terminationGracePeriodSeconds: 0
            domain:
                cpu:
                    cores: 2
                resources:
                    requests:
                        memory: 2Gi
                devices:
                    disks:
                        - name: rootdisk
                          disk:
                              bus: virtio
                        - name: cloudinitdisk
                          disk:
                              bus: virtio
                    # Bridge networking is required so each guest has a unique
                    # routable IP (masquerade gives 10.0.2.2 on every node).
                    interfaces:
                        - name: default
                          bridge: {}
            networks:
                - name: default
                  pod: {}
            volumes:
                - name: rootdisk
                  dataVolume:
                      name: ${vm_name}-rootdisk
                - name: cloudinitdisk
                  cloudInitNoCloud:
                      userData: |
EOF

    sed 's/^/                          /' "${machineconfig_path}" >>"${manifest_path}"
}

check_cli kubectl jq nomad nc

if [[ ! -x "${CHUBOCTL}" ]]; then
    log error "chuboctl binary not found or not executable" "path=${CHUBOCTL}"
fi

mkdir -p "${WORKDIR}"

SECRETS_FILE="${WORKDIR}/secrets.yaml"
CHUBOCONFIG_FILE="${WORKDIR}/chuboconfig"
CP1_CFG="${WORKDIR}/${CP1_NAME}.yaml"
CP2_CFG="${WORKDIR}/${CP2_NAME}.yaml"
CP3_CFG="${WORKDIR}/${CP3_NAME}.yaml"
MANIFEST_FILE="${WORKDIR}/chubo-kubevirt-cluster.yaml"
NOMAD_HELPERS_DIR="${WORKDIR}/nomadconfig"
PORT_FORWARD_LOG="${WORKDIR}/port-forward.log"

BASE_IMAGE_URL="https://github.com/chubo-dev/chubo/releases/download/${RELEASE_TAG}/nocloud-amd64.raw.zst"

log info "Using release artifact" "tag=${RELEASE_TAG}" "url=${BASE_IMAGE_URL}"
log info "Using kubeconfig" "path=${KUBECONFIG_PATH}"
log info "Using chuboctl" "path=${CHUBOCTL}"

if [[ -z "${BASE_DV_NAME}" ]]; then
    BASE_DV_NAME="$(kube -n "${K8S_NAMESPACE}" get dv -o json \
        | jq -r --arg url "${BASE_IMAGE_URL}" '.items[] | select(.status.phase == "Succeeded" and .spec.source.http.url == $url) | .metadata.name' \
        | head -n 1)"

    if [[ -z "${BASE_DV_NAME}" ]]; then
        BASE_DV_NAME="chubo-nocloud-${RELEASE_TAG//./-}-amd64-base"
    fi
fi

log info "Base DataVolume selection" "name=${BASE_DV_NAME}"

if ! kube -n "${K8S_NAMESPACE}" get dv "${BASE_DV_NAME}" >/dev/null 2>&1; then
    log info "Creating base DataVolume" "name=${BASE_DV_NAME}"

    cat <<EOF | kube apply -f -
apiVersion: cdi.kubevirt.io/v1beta1
kind: DataVolume
metadata:
    name: ${BASE_DV_NAME}
    namespace: ${K8S_NAMESPACE}
spec:
    source:
        http:
            url: ${BASE_IMAGE_URL}
    storage:
        accessModes:
            - ReadWriteOnce
        resources:
            requests:
                storage: 20Gi
        storageClassName: longhorn
EOF
else
    log info "Reusing existing base DataVolume" "name=${BASE_DV_NAME}"
fi

wait_for_dv_succeeded "${BASE_DV_NAME}" 1800

log info "Generating cluster secrets and client config"
"${CHUBOCTL}" gen secrets --force -o "${SECRETS_FILE}"
"${CHUBOCTL}" gen config chubo https://0.0.0.0:6443 --with-secrets "${SECRETS_FILE}" -t chuboconfig --force -o "${CHUBOCONFIG_FILE}"

log info "Generating control-plane machine configs"
"${CHUBOCTL}" gen machineconfig \
    --with-secrets "${SECRETS_FILE}" \
    --with-chubo \
    --chubo-role server-client \
    --chubo-bootstrap-expect 3 \
    --chubo-join "${CP2_NAME}-peer.${K8S_NAMESPACE}.svc.cluster.local,${CP3_NAME}-peer.${K8S_NAMESPACE}.svc.cluster.local" \
    --id "${CP1_NAME}" \
    --install-disk /dev/vda \
    --wipe=false \
    --force \
    -o "${CP1_CFG}"

"${CHUBOCTL}" gen machineconfig \
    --with-secrets "${SECRETS_FILE}" \
    --with-chubo \
    --chubo-role server-client \
    --chubo-bootstrap-expect 3 \
    --chubo-join "${CP1_NAME}-peer.${K8S_NAMESPACE}.svc.cluster.local,${CP3_NAME}-peer.${K8S_NAMESPACE}.svc.cluster.local" \
    --id "${CP2_NAME}" \
    --install-disk /dev/vda \
    --wipe=false \
    --force \
    -o "${CP2_CFG}"

"${CHUBOCTL}" gen machineconfig \
    --with-secrets "${SECRETS_FILE}" \
    --with-chubo \
    --chubo-role server-client \
    --chubo-bootstrap-expect 3 \
    --chubo-join "${CP1_NAME}-peer.${K8S_NAMESPACE}.svc.cluster.local,${CP2_NAME}-peer.${K8S_NAMESPACE}.svc.cluster.local" \
    --id "${CP3_NAME}" \
    --install-disk /dev/vda \
    --wipe=false \
    --force \
    -o "${CP3_CFG}"

render_cluster_manifest "${MANIFEST_FILE}" "${CP1_CFG}" "${CP2_CFG}" "${CP3_CFG}"

log info "Deleting previous control-plane VMs/disks (fresh bootstrap)"
for vm in "${CP1_NAME}" "${CP2_NAME}" "${CP3_NAME}"; do
    kube -n "${K8S_NAMESPACE}" delete "vm/${vm}" --ignore-not-found=true --wait=true
    kube -n "${K8S_NAMESPACE}" delete "dv/${vm}-rootdisk" --ignore-not-found=true --wait=true
    kube -n "${K8S_NAMESPACE}" delete "pvc/${vm}-rootdisk" --ignore-not-found=true --wait=true
done

log info "Applying KubeVirt cluster manifest" "path=${MANIFEST_FILE}"
kube apply -f "${MANIFEST_FILE}"

wait_for_dv_succeeded "${CP1_NAME}-rootdisk" 1800
wait_for_dv_succeeded "${CP2_NAME}-rootdisk" 1800
wait_for_dv_succeeded "${CP3_NAME}-rootdisk" 1800

log info "Waiting for VMIs to become ready"
kube -n "${K8S_NAMESPACE}" wait "vmi/${CP1_NAME}" --for=condition=Ready --timeout=900s
kube -n "${K8S_NAMESPACE}" wait "vmi/${CP2_NAME}" --for=condition=Ready --timeout=900s
kube -n "${K8S_NAMESPACE}" wait "vmi/${CP3_NAME}" --for=condition=Ready --timeout=900s

CP2_IP="$(kube -n "${K8S_NAMESPACE}" get "vmi/${CP2_NAME}" -o jsonpath='{.status.interfaces[0].ipAddress}')"
log info "Control-plane node IPs" \
    "cp1=$(kube -n "${K8S_NAMESPACE}" get "vmi/${CP1_NAME}" -o jsonpath='{.status.interfaces[0].ipAddress}')" \
    "cp2=${CP2_IP}" \
    "cp3=$(kube -n "${K8S_NAMESPACE}" get "vmi/${CP3_NAME}" -o jsonpath='{.status.interfaces[0].ipAddress}')"

log info "Refreshing cp2 proxy pod for local tunnels" "pod=${PROXY_POD_NAME}" "cp2_ip=${CP2_IP}"
kube -n "${K8S_NAMESPACE}" delete pod "${PROXY_POD_NAME}" --ignore-not-found=true --wait=true

cat <<EOF | kube apply -f -
apiVersion: v1
kind: Pod
metadata:
    name: ${PROXY_POD_NAME}
    namespace: ${K8S_NAMESPACE}
spec:
    restartPolicy: Always
    containers:
        - name: socat-api
          image: alpine/socat:1.8.0.3
          command: ["socat", "TCP-LISTEN:50000,fork,reuseaddr", "TCP:${CP2_IP}:50000"]
          ports:
              - containerPort: 50000
        - name: socat-nomad
          image: alpine/socat:1.8.0.3
          command: ["socat", "TCP-LISTEN:4646,fork,reuseaddr", "TCP:${CP2_IP}:4646"]
          ports:
              - containerPort: 4646
EOF

kube -n "${K8S_NAMESPACE}" wait "pod/${PROXY_POD_NAME}" --for=condition=Ready --timeout=120s

log info "Starting local port-forward" "api=${LOCAL_CHUBO_API_PORT}" "nomad=${LOCAL_NOMAD_API_PORT}"
kube -n "${K8S_NAMESPACE}" port-forward "pod/${PROXY_POD_NAME}" \
    "${LOCAL_CHUBO_API_PORT}:50000" \
    "${LOCAL_NOMAD_API_PORT}:4646" >"${PORT_FORWARD_LOG}" 2>&1 &
PORT_FORWARD_PID=$!

wait_for_port 127.0.0.1 "${LOCAL_CHUBO_API_PORT}" 30
wait_for_port 127.0.0.1 "${LOCAL_NOMAD_API_PORT}" 30

wait_for_openwonton_healthy "${OPENWONTON_WAIT_SECONDS}"

log info "Fetching Nomad helper bundle from cp2"
fetch_nomad_helpers_with_retry "${NOMAD_HELPERS_WAIT_SECONDS}"

NOMAD_TOKEN="$(tr -d '\r\n' < "${NOMAD_HELPERS_DIR}/acl.token")"

export NOMAD_ADDR="https://127.0.0.1:${LOCAL_NOMAD_API_PORT}"
export NOMAD_CACERT="${NOMAD_HELPERS_DIR}/ca.pem"
export NOMAD_CLIENT_CERT="${NOMAD_HELPERS_DIR}/client.pem"
export NOMAD_CLIENT_KEY="${NOMAD_HELPERS_DIR}/client-key.pem"
export NOMAD_TOKEN

wait_for_nomad_raft_peers 3 "${NOMAD_RAFT_WAIT_SECONDS}"
echo "${NOMAD_RAFT_OUTPUT}"
PEER_COUNT="${NOMAD_RAFT_PEER_COUNT}"

log info "Chubo/OpenWonton control plane is healthy on KubeVirt" \
    "peer_count=${PEER_COUNT}" \
    "status=green"

cat <<EOF

Artifacts:
  Workdir: ${WORKDIR}
  Cluster manifest: ${MANIFEST_FILE}
  Chuboconfig: ${CHUBOCONFIG_FILE}
  Nomad helpers: ${NOMAD_HELPERS_DIR}

Quick checks:
  kubectl --kubeconfig "${KUBECONFIG_PATH}" -n "${K8S_NAMESPACE}" get vm,vmi -o wide | rg 'chubo-cp'
  kubectl --kubeconfig "${KUBECONFIG_PATH}" -n "${K8S_NAMESPACE}" get svc | rg 'chubo-cp'

EOF
