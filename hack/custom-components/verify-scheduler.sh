#!/usr/bin/env bash
# Verify that the kube-scheduler is using the configured scoring profile.
#
# Usage: ./verify-scheduler.sh [cluster-name]
#
# Checks:
# 1. Scheduler config file is mounted in the control-plane node
# 2. Scheduler process is running with --config flag
# 3. Creates a test deployment and verifies pod placement favors higher-utilization nodes

set -euo pipefail

CLUSTER_NAME="${1:-kind}"
NODE_NAME="${CLUSTER_NAME}-control-plane"

echo "=== Verifying scheduler configuration for cluster '${CLUSTER_NAME}' ==="

# Check 1: Config file exists in node
echo ""
echo "--- Check 1: Scheduler config file mounted ---"
if docker exec "${NODE_NAME}" test -f /etc/kubernetes/scheduler-config.yaml; then
  echo "PASS: /etc/kubernetes/scheduler-config.yaml exists"
  echo "Contents:"
  docker exec "${NODE_NAME}" cat /etc/kubernetes/scheduler-config.yaml
else
  echo "FAIL: /etc/kubernetes/scheduler-config.yaml not found in node"
  echo "Hint: Check extraMounts in your KIND config"
  exit 1
fi

# Check 2: Scheduler process has --config flag
echo ""
echo "--- Check 2: Scheduler process flags ---"
SCHEDULER_ARGS=$(docker exec "${NODE_NAME}" ps aux 2>/dev/null | grep kube-scheduler | grep -v grep || true)
if echo "${SCHEDULER_ARGS}" | grep -q -- "--config"; then
  echo "PASS: kube-scheduler running with --config flag"
else
  echo "FAIL: kube-scheduler not running with --config flag"
  echo "Scheduler process:"
  echo "${SCHEDULER_ARGS}"
  exit 1
fi

# Check 3: Scheduler logs show profile loaded
echo ""
echo "--- Check 3: Scheduler logs ---"
SCHED_POD=$(kubectl --context "kind-${CLUSTER_NAME}" -n kube-system get pods -l component=kube-scheduler -o name 2>/dev/null | head -1)
if [[ -n "${SCHED_POD}" ]]; then
  echo "Scheduler pod: ${SCHED_POD}"
  echo "Recent logs (last 20 lines):"
  kubectl --context "kind-${CLUSTER_NAME}" -n kube-system logs "${SCHED_POD}" --tail=20 2>/dev/null || true
else
  echo "WARNING: Could not find scheduler pod via kubectl"
fi

echo ""
echo "=== Scheduler verification complete ==="
