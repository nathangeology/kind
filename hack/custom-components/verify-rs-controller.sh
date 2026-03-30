#!/usr/bin/env bash
# Verify that the custom replicaset controller is running and handling ReplicaSets.
#
# Usage: ./verify-rs-controller.sh [cluster-name]
#
# Checks:
# 1. Built-in RS controller is disabled (--controllers flag includes -replicaset)
# 2. Custom RS controller pod is running (if static pod approach used)
# 3. ReplicaSets are functional (create one and verify pods come up)

set -euo pipefail

CLUSTER_NAME="${1:-kind}"
NODE_NAME="${CLUSTER_NAME}-control-plane"
CONTEXT="kind-${CLUSTER_NAME}"

echo "=== Verifying custom RS controller for cluster '${CLUSTER_NAME}' ==="

# Check 1: Built-in RS controller disabled
echo ""
echo "--- Check 1: Built-in RS controller disabled ---"
KCM_CMD=$(kubectl --context "${CONTEXT}" -n kube-system get pod -l component=kube-controller-manager \
  -o jsonpath='{.items[0].spec.containers[0].command}' 2>/dev/null || true)
if echo "${KCM_CMD}" | grep -q -- "-replicaset"; then
  echo "PASS: kube-controller-manager has -replicaset in controllers flag"
else
  echo "FAIL: kube-controller-manager does not have -replicaset disabled"
  echo "KCM command:"
  echo "${KCM_CMD}"
  exit 1
fi

# Check 2: Custom controller running (if static pod approach)
echo ""
echo "--- Check 2: Custom RS controller pod ---"
CUSTOM_POD=$(kubectl --context "${CONTEXT}" -n kube-system get pods -l component=custom-rs-controller -o name 2>/dev/null | head -1)
if [[ -n "${CUSTOM_POD}" ]]; then
  echo "PASS: Custom RS controller pod found: ${CUSTOM_POD}"
  kubectl --context "${CONTEXT}" -n kube-system get pod -l component=custom-rs-controller -o wide
else
  echo "INFO: No static pod custom-rs-controller found"
  echo "      (This is OK if you deployed the controller as a Deployment instead)"
fi

# Check 3: ReplicaSets are functional
echo ""
echo "--- Check 3: ReplicaSet functionality ---"
TEST_NS="rs-verify-$$"
kubectl --context "${CONTEXT}" create namespace "${TEST_NS}" 2>/dev/null || true

echo "Creating test ReplicaSet..."
kubectl --context "${CONTEXT}" -n "${TEST_NS}" apply -f - <<'EOF'
apiVersion: apps/v1
kind: ReplicaSet
metadata:
  name: verify-rs
  labels:
    app: verify-rs
spec:
  replicas: 2
  selector:
    matchLabels:
      app: verify-rs
  template:
    metadata:
      labels:
        app: verify-rs
    spec:
      containers:
      - name: pause
        image: registry.k8s.io/pause:3.9
EOF

echo "Waiting for pods (up to 60s)..."
READY=false
for i in $(seq 1 12); do
  RUNNING=$(kubectl --context "${CONTEXT}" -n "${TEST_NS}" get pods -l app=verify-rs --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l | tr -d ' ')
  if [[ "${RUNNING}" -ge 2 ]]; then
    READY=true
    break
  fi
  sleep 5
done

if ${READY}; then
  echo "PASS: ReplicaSet created 2 running pods"
  kubectl --context "${CONTEXT}" -n "${TEST_NS}" get pods -l app=verify-rs
else
  echo "FAIL: ReplicaSet pods did not reach Running state"
  kubectl --context "${CONTEXT}" -n "${TEST_NS}" get pods -l app=verify-rs
  kubectl --context "${CONTEXT}" -n "${TEST_NS}" describe rs verify-rs
fi

# Cleanup
echo ""
echo "Cleaning up test namespace..."
kubectl --context "${CONTEXT}" delete namespace "${TEST_NS}" --wait=false 2>/dev/null || true

echo ""
echo "=== RS controller verification complete ==="
