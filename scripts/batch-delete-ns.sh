#!/usr/bin/env bash

set -euo pipefail

echo "🗑️  Batch Delete Terminating Namespaces"
echo "======================================="

# Get all namespaces in Terminating state
TERMINATING_NAMESPACES=$(kubectl get namespaces --no-headers | grep Terminating | awk '{print $1}')

if [ -z "$TERMINATING_NAMESPACES" ]; then
    echo "✅ No namespaces in Terminating state found"
    exit 0
fi

echo "📋 Found the following namespaces in Terminating state:"
echo "$TERMINATING_NAMESPACES"
echo

# Convert to array
readarray -t NS_ARRAY <<< "$TERMINATING_NAMESPACES"

echo "🔄 Processing ${#NS_ARRAY[@]} namespaces..."
echo

success_count=0
failed_count=0

for namespace in "${NS_ARRAY[@]}"; do
    if [ -n "$namespace" ]; then
        echo "Processing: $namespace"

        # Method 1: Remove all finalizers
        if kubectl patch namespace "$namespace" -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null; then
            echo "  ✓ Removed finalizers"
        else
            echo "  ⚠️  Could not patch finalizers"
        fi

        # Method 2: Force finalize via API
        if kubectl get namespace "$namespace" -o json 2>/dev/null | \
           jq '.spec.finalizers=null | .metadata.finalizers=null' | \
           kubectl replace --raw "/api/v1/namespaces/$namespace/finalize" -f - >/dev/null 2>&1; then
            echo "  ✓ Applied finalize API"
        else
            echo "  ⚠️  Could not apply finalize API"
        fi

        # Check result after a short wait
        sleep 1
        if kubectl get namespace "$namespace" >/dev/null 2>&1; then
            echo "  ❌ Still exists"
            ((failed_count++))
        else
            echo "  ✅ Successfully deleted"
            ((success_count++))
        fi
        echo
    fi
done

echo "📊 Final Results:"
echo "  ✅ Successfully deleted: $success_count"
echo "  ❌ Still terminating: $failed_count"

if [ $failed_count -eq 0 ]; then
    echo "🎉 All terminating namespaces have been deleted!"
else
    echo "⚠️  Some namespaces are still terminating. You may need manual intervention."
fi
