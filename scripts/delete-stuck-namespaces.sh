#!/usr/bin/env bash

set -euo pipefail

# Source common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

# List of stuck namespaces to delete
STUCK_NAMESPACES=(
    "cattle-fleet-clusters-system"
    "cattle-fleet-local-system"
    "cattle-fleet-system"
    "cattle-global-data"
    "cattle-global-nt"
    "cattle-impersonation-system"
    "cattle-provisioning-capi-system"
    "cattle-system"
    "cattle-tokens"
    "cattle-ui-plugin-system"
    "cluster-fleet-local-local-1a3d67d0a899"
    "fleet-default"
    "fleet-local"
)

# Function to force delete a namespace
function force_delete_namespace() {
    local namespace="${1}"

    log info "Processing namespace: ${namespace}"

    # Check if namespace exists and is in Terminating state
    if ! kubectl get namespace "${namespace}" &>/dev/null; then
        log info "Namespace does not exist, skipping" "namespace=${namespace}"
        return 0
    fi

    local status
    status=$(kubectl get namespace "${namespace}" -o jsonpath='{.status.phase}')

    if [[ "${status}" != "Terminating" ]]; then
        log warn "Namespace is not in Terminating state, current status: ${status}" "namespace=${namespace}"
        read -p "Do you want to delete it anyway? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log info "Skipping namespace" "namespace=${namespace}"
            return 0
        fi
    fi

    log info "Attempting to force delete namespace" "namespace=${namespace}"

    # Method 1: Remove finalizers and force delete
    if kubectl patch namespace "${namespace}" -p '{"metadata":{"finalizers":null}}' --type=merge &>/dev/null; then
        log info "Successfully patched namespace to remove finalizers" "namespace=${namespace}"

        # Try to delete normally first
        if kubectl delete namespace "${namespace}" --timeout=10s &>/dev/null; then
            log info "Successfully deleted namespace normally" "namespace=${namespace}"
            return 0
        fi
    fi

    # Method 2: Force delete with grace period 0
    log info "Attempting force delete with grace period 0" "namespace=${namespace}"
    if kubectl delete namespace "${namespace}" --force --grace-period=0 &>/dev/null; then
        log info "Successfully force deleted namespace" "namespace=${namespace}"
        return 0
    fi

    # Method 3: Edit the namespace directly to remove finalizers
    log info "Attempting to edit namespace directly" "namespace=${namespace}"
    kubectl get namespace "${namespace}" -o json | \
        jq '.spec.finalizers = null | .metadata.finalizers = null' | \
        kubectl replace --raw "/api/v1/namespaces/${namespace}/finalize" -f - &>/dev/null || true

    # Wait a moment and check if it's gone
    sleep 2
    if ! kubectl get namespace "${namespace}" &>/dev/null; then
        log info "Successfully deleted namespace" "namespace=${namespace}"
        return 0
    fi

    log error "Failed to delete namespace after all attempts" "namespace=${namespace}"
    return 1
}

# Function to list all terminating namespaces
function list_terminating_namespaces() {
    log info "Listing all namespaces in Terminating state:"
    kubectl get namespaces | grep Terminating || log info "No namespaces in Terminating state found"
}

# Function to delete all stuck namespaces
function delete_all_stuck_namespaces() {
    log info "Starting deletion of stuck namespaces"

    local failed_count=0
    local success_count=0

    for namespace in "${STUCK_NAMESPACES[@]}"; do
        if force_delete_namespace "${namespace}"; then
            ((success_count++))
        else
            ((failed_count++))
        fi
        echo # Add spacing between namespace operations
    done

    log info "Deletion completed" "successful=${success_count}" "failed=${failed_count}"

    if [[ ${failed_count} -gt 0 ]]; then
        log warn "Some namespaces failed to delete. You may need to:"
        log warn "1. Check for remaining resources in those namespaces"
        log warn "2. Remove finalizers manually using kubectl edit"
        log warn "3. Check for admission controllers or operators preventing deletion"
    fi
}

# Function to show help
function show_help() {
    cat << EOF
Usage: $(basename "$0") [COMMAND]

Commands:
    list        List all namespaces in Terminating state
    delete      Delete all predefined stuck namespaces
    force-one   Delete a single namespace (interactive)
    help        Show this help message

Examples:
    $(basename "$0") list
    $(basename "$0") delete
    $(basename "$0") force-one my-stuck-namespace

EOF
}

# Function to delete a single namespace interactively
function delete_single_namespace() {
    local namespace="${1:-}"

    if [[ -z "${namespace}" ]]; then
        echo "Available namespaces in Terminating state:"
        kubectl get namespaces | grep Terminating | awk '{print $1}' | sort
        echo
        read -p "Enter namespace name to delete: " namespace
    fi

    if [[ -z "${namespace}" ]]; then
        log error "No namespace specified"
        exit 1
    fi

    force_delete_namespace "${namespace}"
}

# Main function
function main() {
    local command="${1:-delete}"

    # Check required tools
    check_cli kubectl jq

    case "${command}" in
        "list")
            list_terminating_namespaces
            ;;
        "delete")
            echo "This will attempt to force delete the following namespaces:"
            printf '%s\n' "${STUCK_NAMESPACES[@]}"
            echo
            read -p "Are you sure you want to continue? (y/N): " -n 1 -r
            echo
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                delete_all_stuck_namespaces
            else
                log info "Operation cancelled"
            fi
            ;;
        "force-one")
            delete_single_namespace "${2:-}"
            ;;
        "help"|"-h"|"--help")
            show_help
            ;;
        *)
            log error "Unknown command: ${command}"
            show_help
            exit 1
            ;;
    esac
}

# Run main function with all arguments
main "$@"
