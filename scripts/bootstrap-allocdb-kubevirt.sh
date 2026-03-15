#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=scripts/lib/common.sh
source "${ROOT_DIR}/scripts/lib/common.sh"

KUBECONFIG_PATH="${KUBECONFIG_PATH:-${ROOT_DIR}/kubeconfig}"
K8S_NAMESPACE="${K8S_NAMESPACE:-kubevirt}"
WORKDIR="${WORKDIR:-/tmp/allocdb-kubevirt-bootstrap}"
STORAGE_CLASS_NAME="${STORAGE_CLASS_NAME:-longhorn-strict-local}"
BASE_IMAGE_URL="${BASE_IMAGE_URL:-https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img}"
BASE_DV_NAME="${BASE_DV_NAME:-}"
ROOTDISK_SIZE="${ROOTDISK_SIZE:-10Gi}"
ALLOCDB_LOCAL_CLUSTER_BIN="${ALLOCDB_LOCAL_CLUSTER_BIN:-}"
ACTION="${1:-bootstrap}"

CONTROL_VM_NAME="${CONTROL_VM_NAME:-allocdb-control}"
REPLICA1_VM_NAME="${REPLICA1_VM_NAME:-allocdb-replica-1}"
REPLICA2_VM_NAME="${REPLICA2_VM_NAME:-allocdb-replica-2}"
REPLICA3_VM_NAME="${REPLICA3_VM_NAME:-allocdb-replica-3}"

GUEST_USER="${GUEST_USER:-allocdb}"
GUEST_WORKSPACE_ROOT="${GUEST_WORKSPACE_ROOT:-/var/lib/allocdb}"
GUEST_CONTROL_HOME="${GUEST_CONTROL_HOME:-/var/lib/allocdb-qemu}"
GUEST_LOCAL_CLUSTER_BIN_PATH="${GUEST_LOCAL_CLUSTER_BIN_PATH:-/usr/local/bin/allocdb-local-cluster}"
GUEST_CONTROL_SCRIPT_PATH="${GUEST_CONTROL_SCRIPT_PATH:-/usr/local/bin/allocdb-qemu-control}"
GUEST_LAYOUT_PATH="${GUEST_LAYOUT_PATH:-/var/lib/allocdb/cluster-layout.txt}"
HELPER_POD_NAME="${HELPER_POD_NAME:-allocdb-bootstrap-helper}"
HELPER_IMAGE="${HELPER_IMAGE:-nicolaka/netshoot:latest}"
HELPER_STAGE_DIR="${HELPER_STAGE_DIR:-/tmp/allocdb-stage}"
KEEP_HELPER_POD="${KEEP_HELPER_POD:-0}"

CONTROL_LISTENER_PORT="${CONTROL_LISTENER_PORT:-17000}"
CLIENT_LISTENER_PORT="${CLIENT_LISTENER_PORT:-18000}"
PROTOCOL_LISTENER_PORT="${PROTOCOL_LISTENER_PORT:-19000}"

DATA_VOLUME_WAIT_SECONDS="${DATA_VOLUME_WAIT_SECONDS:-1800}"
VMI_READY_WAIT_SECONDS="${VMI_READY_WAIT_SECONDS:-900}"
SSH_WAIT_SECONDS="${SSH_WAIT_SECONDS:-180}"

KUBECTL=(kubectl --kubeconfig "${KUBECONFIG_PATH}")
HELPER_POD_CREATED=0

function cleanup() {
    if [[ "${KEEP_HELPER_POD}" != "1" && "${HELPER_POD_CREATED}" == "1" ]]; then
        kube -n "${K8S_NAMESPACE}" delete "pod/${HELPER_POD_NAME}" --ignore-not-found=true --wait=false >/dev/null 2>&1 || true
    fi
}

trap cleanup EXIT

function kube() {
    "${KUBECTL[@]}" "$@"
}

function usage() {
    cat <<EOF
usage:
  ./scripts/bootstrap-allocdb-kubevirt.sh [bootstrap|render-manifest]

environment:
  ALLOCDB_LOCAL_CLUSTER_BIN   required for bootstrap; path to one x86_64 Linux guest binary
  KUBECONFIG_PATH             kubeconfig path (default: ${ROOT_DIR}/kubeconfig)
  K8S_NAMESPACE               namespace to use (default: kubevirt)
  STORAGE_CLASS_NAME          rootdisk storage class (default: longhorn-strict-local)
  BASE_IMAGE_URL              Ubuntu cloud image URL for the reusable base DataVolume
  ROOTDISK_SIZE               requested size for the reusable base disk and cloned VM rootdisks
  WORKDIR                     local bootstrap workspace (default: /tmp/allocdb-kubevirt-bootstrap)
EOF
}

function ensure_action_supported() {
    case "${ACTION}" in
        bootstrap|render-manifest)
            ;;
        *)
            usage
            log error "Unsupported action" "action=${ACTION}"
            ;;
    esac
}

function ensure_workdir() {
    mkdir -p "${WORKDIR}/ssh" "${WORKDIR}/rendered" "${WORKDIR}/logs"
}

function ensure_ssh_key() {
    SSH_PRIVATE_KEY_PATH="${WORKDIR}/ssh/id_ed25519"
    SSH_PUBLIC_KEY_PATH="${WORKDIR}/ssh/id_ed25519.pub"
    if [[ ! -f "${SSH_PRIVATE_KEY_PATH}" || ! -f "${SSH_PUBLIC_KEY_PATH}" ]]; then
        log info "Generating bootstrap SSH keypair" "path=${SSH_PRIVATE_KEY_PATH}"
        rm -f "${SSH_PRIVATE_KEY_PATH}" "${SSH_PUBLIC_KEY_PATH}"
        ssh-keygen -q -t ed25519 -N "" -f "${SSH_PRIVATE_KEY_PATH}" >/dev/null
    fi
    SSH_PUBLIC_KEY_CONTENT="$(tr -d '\r\n' < "${SSH_PUBLIC_KEY_PATH}")"
}

function default_base_dv_name() {
    local image_slug
    image_slug="$(basename "${BASE_IMAGE_URL}")"
    image_slug="${image_slug//./-}"
    image_slug="${image_slug//_/-}"
    echo "allocdb-${image_slug}-base"
}

function select_base_dv_name() {
    if [[ -n "${BASE_DV_NAME}" ]]; then
        return
    fi
    BASE_DV_NAME="$(default_base_dv_name)"
}

function apply_base_datavolume() {
    log info "Creating base DataVolume" "name=${BASE_DV_NAME}" "storage_class=${STORAGE_CLASS_NAME}" "size=${ROOTDISK_SIZE}"

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
        volumeMode: Filesystem
        resources:
            requests:
                storage: ${ROOTDISK_SIZE}
        storageClassName: ${STORAGE_CLASS_NAME}
EOF
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
        if (( SECONDS >= deadline )); then
            log error "Timed out waiting for DataVolume" "name=${dv_name}" "phase=${phase:-missing}"
        fi
        sleep 5
    done
}

function ensure_base_datavolume_ready() {
    select_base_dv_name
    local discovered_name
    discovered_name="$(kube -n "${K8S_NAMESPACE}" get dv -o json \
        | jq -r --arg url "${BASE_IMAGE_URL}" --arg size "${ROOTDISK_SIZE}" '.items[] | select(.status.phase == "Succeeded" and .spec.source.http.url == $url and .spec.storage.resources.requests.storage == $size) | .metadata.name' \
        | head -n 1)"
    if [[ -n "${discovered_name}" ]]; then
        BASE_DV_NAME="${discovered_name}"
    fi
    log info "Base DataVolume selection" "name=${BASE_DV_NAME}" "url=${BASE_IMAGE_URL}" "size=${ROOTDISK_SIZE}"
    if kube -n "${K8S_NAMESPACE}" get dv "${BASE_DV_NAME}" >/dev/null 2>&1; then
        local phase
        local requested_size
        phase="$(kube -n "${K8S_NAMESPACE}" get dv "${BASE_DV_NAME}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
        requested_size="$(kube -n "${K8S_NAMESPACE}" get dv "${BASE_DV_NAME}" -o jsonpath='{.spec.storage.resources.requests.storage}' 2>/dev/null || true)"
        if [[ "${phase}" != "Succeeded" || "${requested_size}" != "${ROOTDISK_SIZE}" ]]; then
            log warn "Existing base DataVolume is not usable, recreating" "name=${BASE_DV_NAME}" "phase=${phase:-missing}" "requested_size=${requested_size:-missing}" "expected_size=${ROOTDISK_SIZE}"
            kube -n "${K8S_NAMESPACE}" delete "dv/${BASE_DV_NAME}" --ignore-not-found=true --wait=true
            kube -n "${K8S_NAMESPACE}" delete "pvc/${BASE_DV_NAME}" --ignore-not-found=true --wait=true
            apply_base_datavolume
        else
            log info "Reusing existing base DataVolume" "name=${BASE_DV_NAME}"
        fi
    else
        apply_base_datavolume
    fi
    wait_for_dv_succeeded "${BASE_DV_NAME}" "${DATA_VOLUME_WAIT_SECONDS}"
}

function render_guest_user_data() {
    cat <<EOF
#cloud-config
users:
  - default
  - name: ${GUEST_USER}
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    lock_passwd: true
    ssh_authorized_keys:
      - ${SSH_PUBLIC_KEY_CONTENT}
chpasswd:
  expire: false
write_files:
  - path: /etc/ssh/sshd_config.d/99-force-keys.conf
    owner: root:root
    permissions: '0644'
    content: |
      PasswordAuthentication no
      PermitRootLogin no
      PubkeyAuthentication yes
runcmd:
  - [systemctl, enable, ssh]
  - [systemctl, start, ssh]
EOF
}

function append_vm_service_manifest() {
    local manifest_path="$1"
    local service_name="$2"
    local vm_name="$3"
    local include_cluster_ports="$4"

    cat >>"${manifest_path}" <<EOF
---
apiVersion: v1
kind: Service
metadata:
    name: ${service_name}
    namespace: ${K8S_NAMESPACE}
    labels:
        app.kubernetes.io/name: ${vm_name}
spec:
    publishNotReadyAddresses: true
    selector:
        kubevirt.io/domain: ${vm_name}
    ports:
        - name: ssh
          protocol: TCP
          port: 22
          targetPort: 22
EOF

    if [[ "${include_cluster_ports}" == "1" ]]; then
        cat >>"${manifest_path}" <<EOF
        - name: control
          protocol: TCP
          port: ${CONTROL_LISTENER_PORT}
          targetPort: ${CONTROL_LISTENER_PORT}
        - name: client
          protocol: TCP
          port: ${CLIENT_LISTENER_PORT}
          targetPort: ${CLIENT_LISTENER_PORT}
        - name: protocol
          protocol: TCP
          port: ${PROTOCOL_LISTENER_PORT}
          targetPort: ${PROTOCOL_LISTENER_PORT}
EOF
    fi
}

function append_vm_manifest() {
    local manifest_path="$1"
    local vm_name="$2"
    local user_data
    user_data="$(render_guest_user_data)"

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
                  volumeMode: Filesystem
                  resources:
                      requests:
                          storage: ${ROOTDISK_SIZE}
                  storageClassName: ${STORAGE_CLASS_NAME}
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
    sed 's/^/                          /' <<<"${user_data}" >>"${manifest_path}"
}

function render_cluster_manifest() {
    MANIFEST_FILE="${WORKDIR}/allocdb-kubevirt-cluster.yaml"
    : > "${MANIFEST_FILE}"
    append_vm_service_manifest "${MANIFEST_FILE}" "${CONTROL_VM_NAME}" "${CONTROL_VM_NAME}" 0
    append_vm_service_manifest "${MANIFEST_FILE}" "${REPLICA1_VM_NAME}" "${REPLICA1_VM_NAME}" 1
    append_vm_service_manifest "${MANIFEST_FILE}" "${REPLICA2_VM_NAME}" "${REPLICA2_VM_NAME}" 1
    append_vm_service_manifest "${MANIFEST_FILE}" "${REPLICA3_VM_NAME}" "${REPLICA3_VM_NAME}" 1
    append_vm_manifest "${MANIFEST_FILE}" "${CONTROL_VM_NAME}"
    append_vm_manifest "${MANIFEST_FILE}" "${REPLICA1_VM_NAME}"
    append_vm_manifest "${MANIFEST_FILE}" "${REPLICA2_VM_NAME}"
    append_vm_manifest "${MANIFEST_FILE}" "${REPLICA3_VM_NAME}"
}

function delete_previous_cluster() {
    log info "Deleting previous AllocDB VMs/disks (fresh bootstrap)"
    local vm_name
    for vm_name in "${CONTROL_VM_NAME}" "${REPLICA1_VM_NAME}" "${REPLICA2_VM_NAME}" "${REPLICA3_VM_NAME}"; do
        kube -n "${K8S_NAMESPACE}" delete "vm/${vm_name}" --ignore-not-found=true --wait=true
        kube -n "${K8S_NAMESPACE}" delete "dv/${vm_name}-rootdisk" --ignore-not-found=true --wait=true
        kube -n "${K8S_NAMESPACE}" delete "pvc/${vm_name}-rootdisk" --ignore-not-found=true --wait=true
    done
}

function wait_for_vmi_ready() {
    local vm_name="$1"
    kube -n "${K8S_NAMESPACE}" wait "vmi/${vm_name}" --for=condition=Ready --timeout="${VMI_READY_WAIT_SECONDS}s"
}

function vm_ip() {
    local vm_name="$1"
    kube -n "${K8S_NAMESPACE}" get "vmi/${vm_name}" -o jsonpath='{.status.interfaces[0].ipAddress}'
}

function render_cluster_addresses() {
    CONTROL_VM_IP="$(vm_ip "${CONTROL_VM_NAME}")"
    REPLICA1_IP="$(vm_ip "${REPLICA1_VM_NAME}")"
    REPLICA2_IP="$(vm_ip "${REPLICA2_VM_NAME}")"
    REPLICA3_IP="$(vm_ip "${REPLICA3_VM_NAME}")"

    ADDRESSES_FILE="${WORKDIR}/guest-addresses.txt"
    cat > "${ADDRESSES_FILE}" <<EOF
control_ip=${CONTROL_VM_IP}
replica_1_ip=${REPLICA1_IP}
replica_2_ip=${REPLICA2_IP}
replica_3_ip=${REPLICA3_IP}
EOF

    log info "Guest IPs" \
        "control=${CONTROL_VM_IP}" \
        "replica1=${REPLICA1_IP}" \
        "replica2=${REPLICA2_IP}" \
        "replica3=${REPLICA3_IP}"
}

function render_cluster_layout_file() {
    CLUSTER_LAYOUT_FILE="${WORKDIR}/rendered/cluster-layout.txt"
    cat > "${CLUSTER_LAYOUT_FILE}" <<EOF
version=1
workspace_root=${GUEST_WORKSPACE_ROOT}
current_view=1
replica_count=3
core.shard_id=0
core.max_resources=1024
core.max_reservations=1024
core.max_operations=4096
core.max_ttl_slots=256
core.max_client_retry_window_slots=128
core.reservation_history_window_slots=64
core.max_expiration_bucket_len=1024
engine.max_submission_queue=64
engine.max_command_bytes=4096
engine.max_expirations_per_tick=64
replica.1.role=primary
replica.1.workspace_dir=${GUEST_WORKSPACE_ROOT}/replica-1
replica.1.log_path=/var/log/allocdb/replica-1.log
replica.1.pid_path=/run/allocdb/replica-1.pid
replica.1.metadata_path=${GUEST_WORKSPACE_ROOT}/replica-1/replica.metadata
replica.1.snapshot_path=${GUEST_WORKSPACE_ROOT}/replica-1/state.snapshot
replica.1.wal_path=${GUEST_WORKSPACE_ROOT}/replica-1/state.wal
replica.1.control_addr=${REPLICA1_IP}:${CONTROL_LISTENER_PORT}
replica.1.client_addr=${REPLICA1_IP}:${CLIENT_LISTENER_PORT}
replica.1.protocol_addr=${REPLICA1_IP}:${PROTOCOL_LISTENER_PORT}
replica.2.role=backup
replica.2.workspace_dir=${GUEST_WORKSPACE_ROOT}/replica-2
replica.2.log_path=/var/log/allocdb/replica-2.log
replica.2.pid_path=/run/allocdb/replica-2.pid
replica.2.metadata_path=${GUEST_WORKSPACE_ROOT}/replica-2/replica.metadata
replica.2.snapshot_path=${GUEST_WORKSPACE_ROOT}/replica-2/state.snapshot
replica.2.wal_path=${GUEST_WORKSPACE_ROOT}/replica-2/state.wal
replica.2.control_addr=${REPLICA2_IP}:${CONTROL_LISTENER_PORT}
replica.2.client_addr=${REPLICA2_IP}:${CLIENT_LISTENER_PORT}
replica.2.protocol_addr=${REPLICA2_IP}:${PROTOCOL_LISTENER_PORT}
replica.3.role=backup
replica.3.workspace_dir=${GUEST_WORKSPACE_ROOT}/replica-3
replica.3.log_path=/var/log/allocdb/replica-3.log
replica.3.pid_path=/run/allocdb/replica-3.pid
replica.3.metadata_path=${GUEST_WORKSPACE_ROOT}/replica-3/replica.metadata
replica.3.snapshot_path=${GUEST_WORKSPACE_ROOT}/replica-3/state.snapshot
replica.3.wal_path=${GUEST_WORKSPACE_ROOT}/replica-3/state.wal
replica.3.control_addr=${REPLICA3_IP}:${CONTROL_LISTENER_PORT}
replica.3.client_addr=${REPLICA3_IP}:${CLIENT_LISTENER_PORT}
replica.3.protocol_addr=${REPLICA3_IP}:${PROTOCOL_LISTENER_PORT}

EOF
}

function render_replica_service_unit_file() {
    local replica_id="$1"
    local service_path="$2"
    cat > "${service_path}" <<EOF
[Unit]
Description=AllocDB replica daemon ${replica_id}
After=network-online.target cloud-final.service
Wants=network-online.target

[Service]
User=${GUEST_USER}
Group=${GUEST_USER}
StateDirectory=allocdb
LogsDirectory=allocdb
RuntimeDirectory=allocdb
ExecStartPre=/usr/bin/mkdir -p ${GUEST_WORKSPACE_ROOT}/replica-1 ${GUEST_WORKSPACE_ROOT}/replica-2 ${GUEST_WORKSPACE_ROOT}/replica-3
ExecStart=${GUEST_LOCAL_CLUSTER_BIN_PATH} replica-daemon --layout-file ${GUEST_LAYOUT_PATH} --replica-id ${replica_id}
StandardOutput=append:/var/log/allocdb/replica-${replica_id}.log
StandardError=append:/var/log/allocdb/replica-${replica_id}.log

[Install]
WantedBy=multi-user.target
EOF
}

function render_control_script_file() {
    CONTROL_SCRIPT_FILE="${WORKDIR}/rendered/allocdb-qemu-control"
    cat > "${CONTROL_SCRIPT_FILE}" <<EOF
#!/usr/bin/env bash
set -euo pipefail

workspace_root=${GUEST_WORKSPACE_ROOT}
control_home=${GUEST_CONTROL_HOME}
ssh_key="\$control_home/id_ed25519"
ssh_opts=(-i "\$ssh_key" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)

replica_ip() {
    case "\$1" in
        1) echo "${REPLICA1_IP}" ;;
        2) echo "${REPLICA2_IP}" ;;
        3) echo "${REPLICA3_IP}" ;;
        *) echo "unknown replica id: \$1" >&2; exit 1 ;;
    esac
}

replica_ssh() {
    local replica_id="\$1"
    shift
    ssh "\${ssh_opts[@]}" ${GUEST_USER}@"\$(replica_ip "\$replica_id")" "\$@"
}

collect_logs() {
    local output_dir="\${1:-\$control_home/log-bundles/\$(date +%Y%m%d-%H%M%S)}"
    mkdir -p "\$output_dir"
    for replica_id in 1 2 3; do
        local replica_dir="\$output_dir/replica-\$replica_id"
        mkdir -p "\$replica_dir"
        replica_ssh "\$replica_id" "sudo journalctl -u allocdb-replica.service --no-pager" > "\$replica_dir/journal.log" || true
        replica_ssh "\$replica_id" "sudo cat ${GUEST_WORKSPACE_ROOT}/cluster-faults.txt" > "\$replica_dir/cluster-faults.txt" || true
        replica_ssh "\$replica_id" "sudo cat ${GUEST_WORKSPACE_ROOT}/cluster-timeline.log" > "\$replica_dir/cluster-timeline.log" || true
        ${GUEST_LOCAL_CLUSTER_BIN_PATH} control-status --addr "\$(replica_ip "\$replica_id"):${CONTROL_LISTENER_PORT}" > "\$replica_dir/status.txt" || true
    done
    echo "\$output_dir"
}

export_replica() {
    local replica_id="\$1"
    replica_ssh "\$replica_id" "sudo tar czf - -C ${GUEST_WORKSPACE_ROOT} replica-\$replica_id"
}

import_replica() {
    local replica_id="\$1"
    replica_ssh "\$replica_id" "sudo rm -rf ${GUEST_WORKSPACE_ROOT}/replica-\$replica_id && sudo mkdir -p ${GUEST_WORKSPACE_ROOT} && sudo tar xzf - -C ${GUEST_WORKSPACE_ROOT} && sudo chown -R ${GUEST_USER}:${GUEST_USER} ${GUEST_WORKSPACE_ROOT}/replica-\$replica_id"
}

case "\${1:-}" in
    status)
        echo "== replica 1 =="
        ${GUEST_LOCAL_CLUSTER_BIN_PATH} control-status --addr "${REPLICA1_IP}:${CONTROL_LISTENER_PORT}" || true
        echo "== replica 2 =="
        ${GUEST_LOCAL_CLUSTER_BIN_PATH} control-status --addr "${REPLICA2_IP}:${CONTROL_LISTENER_PORT}" || true
        echo "== replica 3 =="
        ${GUEST_LOCAL_CLUSTER_BIN_PATH} control-status --addr "${REPLICA3_IP}:${CONTROL_LISTENER_PORT}" || true
        ;;
    isolate)
        replica_ssh "\$2" "sudo ${GUEST_LOCAL_CLUSTER_BIN_PATH} isolate --workspace ${GUEST_WORKSPACE_ROOT} --replica-id \$2"
        ;;
    heal)
        replica_ssh "\$2" "sudo ${GUEST_LOCAL_CLUSTER_BIN_PATH} heal --workspace ${GUEST_WORKSPACE_ROOT} --replica-id \$2"
        ;;
    crash)
        replica_ssh "\$2" "sudo ${GUEST_LOCAL_CLUSTER_BIN_PATH} crash --workspace ${GUEST_WORKSPACE_ROOT} --replica-id \$2"
        ;;
    restart)
        replica_ssh "\$2" "sudo ${GUEST_LOCAL_CLUSTER_BIN_PATH} restart --workspace ${GUEST_WORKSPACE_ROOT} --replica-id \$2"
        ;;
    reboot)
        replica_ssh "\$2" "sudo /sbin/reboot" || true
        ;;
    export-replica)
        export_replica "\$2"
        ;;
    import-replica)
        import_replica "\$2"
        ;;
    collect-logs)
        collect_logs "\${2:-}"
        ;;
    *)
        echo "usage: allocdb-qemu-control <status|isolate|heal|crash|restart|reboot|export-replica|import-replica|collect-logs> [replica-id|output-dir]" >&2
        exit 1
        ;;
esac
EOF
    chmod 0755 "${CONTROL_SCRIPT_FILE}"
}

function replica_ip() {
    local replica_id="$1"
    case "${replica_id}" in
        1) echo "${REPLICA1_IP}" ;;
        2) echo "${REPLICA2_IP}" ;;
        3) echo "${REPLICA3_IP}" ;;
        *)
            log error "Unknown replica id" "replica_id=${replica_id}"
            ;;
    esac
}

function ensure_helper_pod_ready() {
    local phase
    phase="$(kube -n "${K8S_NAMESPACE}" get "pod/${HELPER_POD_NAME}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"

    if [[ -z "${phase}" ]]; then
        log info "Creating helper pod" "name=${HELPER_POD_NAME}" "image=${HELPER_IMAGE}"
        cat <<EOF | kube -n "${K8S_NAMESPACE}" apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: ${HELPER_POD_NAME}
  namespace: ${K8S_NAMESPACE}
  labels:
    app.kubernetes.io/name: allocdb-bootstrap-helper
spec:
  restartPolicy: Never
  containers:
    - name: helper
      image: ${HELPER_IMAGE}
      command: ["/bin/sh", "-lc", "sleep infinity"]
EOF
        HELPER_POD_CREATED=1
    elif [[ "${phase}" != "Running" ]]; then
        log warn "Recreating helper pod" "name=${HELPER_POD_NAME}" "phase=${phase}"
        kube -n "${K8S_NAMESPACE}" delete "pod/${HELPER_POD_NAME}" --ignore-not-found=true --wait=true
        cat <<EOF | kube -n "${K8S_NAMESPACE}" apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: ${HELPER_POD_NAME}
  namespace: ${K8S_NAMESPACE}
  labels:
    app.kubernetes.io/name: allocdb-bootstrap-helper
spec:
  restartPolicy: Never
  containers:
    - name: helper
      image: ${HELPER_IMAGE}
      command: ["/bin/sh", "-lc", "sleep infinity"]
EOF
        HELPER_POD_CREATED=1
    else
        log info "Reusing helper pod" "name=${HELPER_POD_NAME}"
    fi

    kube -n "${K8S_NAMESPACE}" wait "pod/${HELPER_POD_NAME}" --for=condition=Ready --timeout=180s >/dev/null
}

function helper_shell() {
    kube -n "${K8S_NAMESPACE}" exec "${HELPER_POD_NAME}" -- sh -lc "$1"
}

function prepare_helper_stage() {
    helper_shell "mkdir -p ${HELPER_STAGE_DIR} && chmod 700 ${HELPER_STAGE_DIR}"
}

function helper_copy_file() {
    local source_path="$1"
    local dest_name="$2"

    kube -n "${K8S_NAMESPACE}" cp "${source_path}" "${HELPER_POD_NAME}:${HELPER_STAGE_DIR}/${dest_name}" >/dev/null
}

function helper_guest_ssh() {
    local guest_ip="$1"
    shift
    kube -n "${K8S_NAMESPACE}" exec "${HELPER_POD_NAME}" -- \
        ssh -i "${HELPER_STAGE_DIR}/id_ed25519" \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR \
        -o ConnectTimeout=5 \
        "${GUEST_USER}@${guest_ip}" "$@"
}

function helper_guest_copy() {
    local guest_ip="$1"
    local source_name="$2"
    local target_path="$3"

    kube -n "${K8S_NAMESPACE}" exec "${HELPER_POD_NAME}" -- \
        scp -i "${HELPER_STAGE_DIR}/id_ed25519" \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR \
        -o ConnectTimeout=5 \
        "${HELPER_STAGE_DIR}/${source_name}" \
        "${GUEST_USER}@${guest_ip}:${target_path}"
}

function wait_for_guest_ssh() {
    local guest_ip="$1"
    local timeout_seconds="$2"
    local deadline=$((SECONDS + timeout_seconds))

    while true; do
        if helper_guest_ssh "${guest_ip}" true >/dev/null 2>&1; then
            return 0
        fi
        if (( SECONDS >= deadline )); then
            log error "Timed out waiting for guest SSH" "guest_ip=${guest_ip}"
        fi
        sleep 2
    done
}

function stage_replica_guest() {
    local replica_id="$1"
    local guest_ip
    guest_ip="$(replica_ip "${replica_id}")"
    local service_unit_path="${WORKDIR}/rendered/allocdb-replica-${replica_id}.service"

    render_replica_service_unit_file "${replica_id}" "${service_unit_path}"
    helper_copy_file "${service_unit_path}" "allocdb-replica-${replica_id}.service"
    helper_guest_copy "${guest_ip}" "allocdb-local-cluster" "/tmp/allocdb-local-cluster"
    helper_guest_copy "${guest_ip}" "cluster-layout.txt" "/tmp/cluster-layout.txt"
    helper_guest_copy "${guest_ip}" "allocdb-replica-${replica_id}.service" "/tmp/allocdb-replica.service"

    helper_guest_ssh "${guest_ip}" "sudo mkdir -p ${GUEST_WORKSPACE_ROOT}/replica-1 ${GUEST_WORKSPACE_ROOT}/replica-2 ${GUEST_WORKSPACE_ROOT}/replica-3 /var/log/allocdb /run/allocdb"
    helper_guest_ssh "${guest_ip}" "sudo install -o root -g root -m 0755 /tmp/allocdb-local-cluster ${GUEST_LOCAL_CLUSTER_BIN_PATH}"
    helper_guest_ssh "${guest_ip}" "sudo install -o root -g root -m 0644 /tmp/cluster-layout.txt ${GUEST_LAYOUT_PATH}"
    helper_guest_ssh "${guest_ip}" "sudo install -o root -g root -m 0644 /tmp/allocdb-replica.service /etc/systemd/system/allocdb-replica.service"
    helper_guest_ssh "${guest_ip}" "sudo chown -R ${GUEST_USER}:${GUEST_USER} ${GUEST_WORKSPACE_ROOT} /var/log/allocdb /run/allocdb"
    helper_guest_ssh "${guest_ip}" "sudo systemctl daemon-reload && sudo systemctl enable --now allocdb-replica.service"
}

function stage_control_guest() {
    helper_guest_copy "${CONTROL_VM_IP}" "allocdb-local-cluster" "/tmp/allocdb-local-cluster"
    helper_guest_copy "${CONTROL_VM_IP}" "allocdb-qemu-control" "/tmp/allocdb-qemu-control"
    helper_guest_copy "${CONTROL_VM_IP}" "id_ed25519" "/tmp/id_ed25519"
    helper_guest_copy "${CONTROL_VM_IP}" "id_ed25519.pub" "/tmp/id_ed25519.pub"

    helper_guest_ssh "${CONTROL_VM_IP}" "sudo mkdir -p ${GUEST_CONTROL_HOME}/log-bundles"
    helper_guest_ssh "${CONTROL_VM_IP}" "sudo install -o root -g root -m 0755 /tmp/allocdb-local-cluster ${GUEST_LOCAL_CLUSTER_BIN_PATH}"
    helper_guest_ssh "${CONTROL_VM_IP}" "sudo install -o root -g root -m 0755 /tmp/allocdb-qemu-control ${GUEST_CONTROL_SCRIPT_PATH}"
    helper_guest_ssh "${CONTROL_VM_IP}" "sudo install -o ${GUEST_USER} -g ${GUEST_USER} -m 0600 /tmp/id_ed25519 ${GUEST_CONTROL_HOME}/id_ed25519"
    helper_guest_ssh "${CONTROL_VM_IP}" "sudo install -o ${GUEST_USER} -g ${GUEST_USER} -m 0644 /tmp/id_ed25519.pub ${GUEST_CONTROL_HOME}/id_ed25519.pub"
}

function validate_cluster() {
    CONTROL_STATUS_OUTPUT="${WORKDIR}/control-status.txt"
    helper_guest_ssh "${CONTROL_VM_IP}" "sudo ${GUEST_CONTROL_SCRIPT_PATH} status" > "${CONTROL_STATUS_OUTPUT}"

    local replica_count
    replica_count="$(grep -c '^== replica ' "${CONTROL_STATUS_OUTPUT}" || true)"
    if [[ "${replica_count}" != "3" ]]; then
        log error "Unexpected replica count in control status" "count=${replica_count}" "path=${CONTROL_STATUS_OUTPUT}"
    fi

    local ok_count
    ok_count="$(grep -c '^status=ok$' "${CONTROL_STATUS_OUTPUT}" || true)"
    if [[ "${ok_count}" != "3" ]]; then
        log error "Control status did not report three healthy replicas" "ok_count=${ok_count}" "path=${CONTROL_STATUS_OUTPUT}"
    fi

    log info "AllocDB KubeVirt cluster is healthy" "status_file=${CONTROL_STATUS_OUTPUT}"
}

function bootstrap_cluster() {
    if [[ -z "${ALLOCDB_LOCAL_CLUSTER_BIN}" ]]; then
        log error "ALLOCDB_LOCAL_CLUSTER_BIN is required for bootstrap"
    fi
    if [[ ! -x "${ALLOCDB_LOCAL_CLUSTER_BIN}" ]]; then
        log error "AllocDB guest binary not found or not executable" "path=${ALLOCDB_LOCAL_CLUSTER_BIN}"
    fi

    ensure_base_datavolume_ready
    render_cluster_manifest
    delete_previous_cluster

    log info "Applying AllocDB KubeVirt manifest" "path=${MANIFEST_FILE}"
    kube apply -f "${MANIFEST_FILE}"

    wait_for_dv_succeeded "${CONTROL_VM_NAME}-rootdisk" "${DATA_VOLUME_WAIT_SECONDS}"
    wait_for_dv_succeeded "${REPLICA1_VM_NAME}-rootdisk" "${DATA_VOLUME_WAIT_SECONDS}"
    wait_for_dv_succeeded "${REPLICA2_VM_NAME}-rootdisk" "${DATA_VOLUME_WAIT_SECONDS}"
    wait_for_dv_succeeded "${REPLICA3_VM_NAME}-rootdisk" "${DATA_VOLUME_WAIT_SECONDS}"

    log info "Waiting for VMIs to become ready"
    wait_for_vmi_ready "${CONTROL_VM_NAME}"
    wait_for_vmi_ready "${REPLICA1_VM_NAME}"
    wait_for_vmi_ready "${REPLICA2_VM_NAME}"
    wait_for_vmi_ready "${REPLICA3_VM_NAME}"

    render_cluster_addresses
    render_cluster_layout_file
    render_control_script_file

    ensure_helper_pod_ready
    prepare_helper_stage
    helper_copy_file "${SSH_PRIVATE_KEY_PATH}" "id_ed25519"
    helper_copy_file "${SSH_PUBLIC_KEY_PATH}" "id_ed25519.pub"
    helper_copy_file "${ALLOCDB_LOCAL_CLUSTER_BIN}" "allocdb-local-cluster"
    helper_copy_file "${CLUSTER_LAYOUT_FILE}" "cluster-layout.txt"
    helper_copy_file "${CONTROL_SCRIPT_FILE}" "allocdb-qemu-control"
    helper_shell "chmod 600 ${HELPER_STAGE_DIR}/id_ed25519 && chmod 644 ${HELPER_STAGE_DIR}/id_ed25519.pub ${HELPER_STAGE_DIR}/allocdb-local-cluster ${HELPER_STAGE_DIR}/cluster-layout.txt ${HELPER_STAGE_DIR}/allocdb-qemu-control"

    wait_for_guest_ssh "${CONTROL_VM_IP}" "${SSH_WAIT_SECONDS}"
    wait_for_guest_ssh "${REPLICA1_IP}" "${SSH_WAIT_SECONDS}"
    wait_for_guest_ssh "${REPLICA2_IP}" "${SSH_WAIT_SECONDS}"
    wait_for_guest_ssh "${REPLICA3_IP}" "${SSH_WAIT_SECONDS}"

    log info "Staging replica artifacts"
    stage_replica_guest 1
    stage_replica_guest 2
    stage_replica_guest 3

    log info "Staging control guest artifacts"
    stage_control_guest

    validate_cluster

    cat <<EOF

Artifacts:
  Workdir: ${WORKDIR}
  Cluster manifest: ${MANIFEST_FILE}
  Guest addresses: ${ADDRESSES_FILE}
  SSH private key: ${SSH_PRIVATE_KEY_PATH}
  Control status: ${CONTROL_STATUS_OUTPUT}

Quick checks:
  kubectl --kubeconfig "${KUBECONFIG_PATH}" -n "${K8S_NAMESPACE}" get vm,vmi,svc | rg 'allocdb-'
  KEEP_HELPER_POD=1 ALLOCDB_LOCAL_CLUSTER_BIN="${ALLOCDB_LOCAL_CLUSTER_BIN}" ./scripts/bootstrap-allocdb-kubevirt.sh
  kubectl --kubeconfig "${KUBECONFIG_PATH}" -n "${K8S_NAMESPACE}" exec ${HELPER_POD_NAME} -- ssh -i ${HELPER_STAGE_DIR}/id_ed25519 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ${GUEST_USER}@${CONTROL_VM_IP} 'sudo ${GUEST_CONTROL_SCRIPT_PATH} status'

EOF
}

ensure_action_supported
if [[ "${ACTION}" == "render-manifest" ]]; then
    check_cli kubectl ssh-keygen
else
    check_cli kubectl jq ssh scp ssh-keygen
fi
ensure_workdir
ensure_ssh_key
select_base_dv_name
render_cluster_manifest

if [[ "${ACTION}" == "render-manifest" ]]; then
    echo "${MANIFEST_FILE}"
    exit 0
fi

bootstrap_cluster
