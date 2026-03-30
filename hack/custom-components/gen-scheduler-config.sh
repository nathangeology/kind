#!/usr/bin/env bash
# Generate a KIND cluster config with an alternate kube-scheduler scoring profile.
#
# Usage: ./gen-scheduler-config.sh <ScoringPlugin> [output-dir]
#   ScoringPlugin: MostAllocated | RequestedToCapacityRatio
#   output-dir: defaults to hack/custom-components/out
#
# Produces:
#   out/scheduler-config.yaml  — KubeSchedulerConfiguration
#   out/kind-scheduler.yaml    — KIND cluster config

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCORING_PLUGIN="${1:?Usage: $0 <ScoringPlugin> [output-dir]}"
OUT_DIR="${2:-${SCRIPT_DIR}/out}"

mkdir -p "${OUT_DIR}"

# Determine scheduler config API version.
# v1 is stable since k8s 1.25; use v1beta3 for 1.23-1.24.
SCHEDULER_API_VERSION="${SCHEDULER_API_VERSION:-v1}"

case "${SCORING_PLUGIN}" in
  MostAllocated)
    SCORE_ARGS=$(cat <<'EOF'
      scoringStrategy:
        type: MostAllocated
        resources:
        - name: cpu
          weight: 1
        - name: memory
          weight: 1
EOF
)
    ;;
  RequestedToCapacityRatio)
    SCORE_ARGS=$(cat <<'EOF'
      scoringStrategy:
        type: RequestedToCapacityRatio
        requestedToCapacityRatio:
          shape:
          - utilization: 0
            score: 0
          - utilization: 100
            score: 10
        resources:
        - name: cpu
          weight: 1
        - name: memory
          weight: 1
EOF
)
    ;;
  *)
    echo "Error: unsupported scoring plugin '${SCORING_PLUGIN}'" >&2
    echo "Supported: MostAllocated, RequestedToCapacityRatio" >&2
    exit 1
    ;;
esac

# --- Generate KubeSchedulerConfiguration ---
cat > "${OUT_DIR}/scheduler-config.yaml" <<EOF
apiVersion: kubescheduler.config.k8s.io/${SCHEDULER_API_VERSION}
kind: KubeSchedulerConfiguration
clientConnection:
  kubeconfig: /etc/kubernetes/scheduler.conf
leaderElection:
  leaderElect: true
profiles:
- schedulerName: default-scheduler
  plugins:
    score:
      enabled:
      - name: NodeResourcesFit
        weight: 1
      disabled:
      - name: NodeResourcesBalancedAllocation
  pluginConfig:
  - name: NodeResourcesFit
    args:
      apiVersion: kubescheduler.config.k8s.io/${SCHEDULER_API_VERSION}
      kind: NodeResourcesFitArgs
${SCORE_ARGS}
EOF

# --- Generate KIND cluster config ---
cat > "${OUT_DIR}/kind-scheduler.yaml" <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  kubeadmConfigPatches:
  - |
    kind: ClusterConfiguration
    scheduler:
      extraArgs:
        config: /etc/kubernetes/scheduler-config.yaml
      extraVolumes:
      - name: scheduler-config
        hostPath: /etc/kubernetes/scheduler-config.yaml
        mountPath: /etc/kubernetes/scheduler-config.yaml
        readOnly: true
        pathType: File
  extraMounts:
  - hostPath: ${OUT_DIR}/scheduler-config.yaml
    containerPath: /etc/kubernetes/scheduler-config.yaml
    readOnly: true
- role: worker
- role: worker
EOF

echo "Generated:"
echo "  ${OUT_DIR}/scheduler-config.yaml"
echo "  ${OUT_DIR}/kind-scheduler.yaml"
echo ""
echo "Create cluster: kind create cluster --config ${OUT_DIR}/kind-scheduler.yaml"
