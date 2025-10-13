#!/usr/bin/env bash

set -euo pipefail

echo "🗑️  Force Delete Terminating Namespaces Script"
echo "=============================================="

# Get all namespaces in Terminating state
TERMINATING_NAMESPACES=$(kubectl get namespaces | grep Terminating | awk '{print $1}' || true)

if [ -z "$TERMINATING_NAMESPACES" ]; then
    echo "✅ No namespaces in Terminating state found"
    exit 0
fi

echo "📋 Found the following namespaces in Terminating state:"
echo "$TERMINATING_NAMESPACES"
echo

# Function to force delete a namespace
force_delete_namespace() {
    local namespace="$1"

    echo "🔄 Processing namespace: $namespace"

    # Method 1: Patch to remove finalizers
    if kubectl patch namespace "$namespace" -p '{"metadata":{"finalizers":null}}' --type=merge &>/dev/null; then
        echo "  ✓ Removed finalizers"
    else
        echo "  ⚠️  Failed to patch finalizers (namespace may not exist)"
        return 0
    fi

    # Method 2: Use finalize API to force completion
    if kubectl get namespace "$namespace" -o json 2>/dev/null | \
       jq '.spec.finalizers=null | .metadata.finalizers=null' | \
       kubectl replace --raw "/api/v1/namespaces/$namespace/finalize" -f - &>/dev/null; then
        echo "  ✓ Applied finalize API call"
    else
        echo "  ⚠️  Failed to call finalize API"
    fi

    # Wait a moment for deletion to propagate
    sleep 1

    # Check if namespace still exists
    if kubectl get namespace "$namespace" &>/dev/null; then
        echo "  ❌ Namespace still exists after force delete attempts"
        return 1
    else
        echo "  ✅ Namespace successfully deleted"
        return 0
    fi
}

# Process each namespace
success_count=0
failed_count=0

while IFS= read -r namespace; do
    if [ -n "$namespace" ]; then
        if force_delete_namespace "$namespace"; then
            ((success_count++))
        else
            ((failed_count++))
        fi
        echo
    fi
done <<< "$TERMINATING_NAMESPACES"

# Final status report
echo "📊 Summary:"
echo "  ✅ Successfully deleted: $success_count namespaces"
echo "  ❌ Failed to delete: $failed_count namespaces"

if [ $failed_count -gt 0 ]; then
    echo
    echo "⚠️  Some namespaces could not be deleted. This might be due to:"
    echo "   - Active admission controllers"
    echo "   - Custom resource definitions with stuck finalizers"
    echo "   - Operator controllers still running"
    echo
    echo "💡 You may need to:"
    echo "   1. Check for CRDs that might have finalizers: kubectl get crd | grep cattle"
    echo "   2. Remove operator controllers manually"
    echo "   3. Edit namespaces directly with: kubectl edit namespace <namespace-name>"
    exit 1
fi

echo "🎉 All terminating namespaces have been successfully deleted!"
