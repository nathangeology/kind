#!/usr/bin/env bash
# Generate a KIND cluster config that disables the built-in replicaset
# controller and optionally runs a custom one via static pod.
#
# Usage: ./gen-custom-rs-controller.sh [custom-binary-path] [output-dir]
#   custom-binary-path: path to custom kube-controller-manager binary (optional)
#   output-dir: defaults to hack/custom-components/out
#
# If custom-binary-path is provided, a static pod manifest is also generated.
# If omitted, only the built-in RS controller is disabled (you deploy your own).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CUSTOM_BINARY="${1:-}"
OUT_DIR="${2:-${SCRIPT_DIR}/out}"

mkdir -p "${OUT_DIR}"

# Base KIND config: mount custom binary but do NOT modify controllers at creation time.
# The --controllers flag is applied post-creation to avoid breaking bootstrapsigner
# during node join (bootstrapsigner was removed from default controllers in k8s 1.32+).
EXTRA_MOUNTS=""

if [[ -n "${CUSTOM_BINARY}" ]]; then
  if [[ ! -f "${CUSTOM_BINARY}" ]]; then
    echo "Error: custom binary not found: ${CUSTOM_BINARY}" >&2
    exit 1
  fi

  CUSTOM_BINARY="$(cd "$(dirname "${CUSTOM_BINARY}")" && pwd)/$(basename "${CUSTOM_BINARY}")"

  # Generate static pod manifest for the custom RS controller
  cat > "${OUT_DIR}/custom-rs-controller.yaml" <<'STATICPOD'
apiVersion: v1
kind: Pod
metadata:
  name: custom-rs-controller
  namespace: kube-system
  labels:
    component: custom-rs-controller
    tier: control-plane
spec:
  hostNetwork: true
  priorityClassName: system-node-critical
  containers:
  - name: custom-rs-controller
    command:
    - /custom-controller-manager
    - --controllers=replicaset
    - --kubeconfig=/etc/kubernetes/controller-manager.conf
    - --authentication-kubeconfig=/etc/kubernetes/controller-manager.conf
    - --authorization-kubeconfig=/etc/kubernetes/controller-manager.conf
    - --leader-elect=true
    - --leader-elect-resource-name=custom-rs-controller
    - --use-service-account-credentials=true
    - --root-ca-file=/etc/kubernetes/pki/ca.crt
    - --service-account-private-key-file=/etc/kubernetes/pki/sa.key
    - --bind-address=127.0.0.1
    - --secure-port=10258
    - --v=2
    image: registry.k8s.io/pause:3.9
    securityContext:
      runAsUser: 0
    volumeMounts:
    - name: custom-binary
      mountPath: /custom-controller-manager
      readOnly: true
    - name: kubeconfig
      mountPath: /etc/kubernetes/controller-manager.conf
      readOnly: true
    - name: k8s-certs
      mountPath: /etc/kubernetes/pki
      readOnly: true
  volumes:
  - name: custom-binary
    hostPath:
      path: /opt/custom-rs-controller/controller-manager
      type: File
  - name: kubeconfig
    hostPath:
      path: /etc/kubernetes/controller-manager.conf
      type: File
  - name: k8s-certs
    hostPath:
      path: /etc/kubernetes/pki
      type: DirectoryOrCreate
STATICPOD

  EXTRA_MOUNTS=$(cat <<EOF
  - hostPath: ${CUSTOM_BINARY}
    containerPath: /opt/custom-rs-controller/controller-manager
    readOnly: true
EOF
)

  echo "Generated: ${OUT_DIR}/custom-rs-controller.yaml"
fi

# --- Generate KIND cluster config ---
# NOTE: We do NOT set --controllers at cluster creation time because it breaks
# node join in k8s 1.32+ (bootstrapsigner removed from default controller set).
# Instead, the post-creation script patches the KCM manifest.
cat > "${OUT_DIR}/kind-custom-rs.yaml" <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
${EXTRA_MOUNTS:+  extraMounts:
${EXTRA_MOUNTS}}
- role: worker
EOF

# --- Generate post-creation setup script ---
cat > "${OUT_DIR}/setup-custom-rs.sh" <<'SETUP'
#!/usr/bin/env bash
# Post-creation setup: disable built-in RS controller and deploy custom one.
# Usage: ./setup-custom-rs.sh [cluster-name]
set -euo pipefail

CLUSTER_NAME="${1:-kind}"
NODE="${CLUSTER_NAME}-control-plane"
CONTEXT="kind-${CLUSTER_NAME}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== Setting up custom RS controller for cluster '${CLUSTER_NAME}' ==="

# Step 1: Patch the built-in KCM to disable the replicaset controller
echo "Patching kube-controller-manager to disable replicaset controller..."
# The controllers flag may be --controllers=* or --controllers=*,bootstrapsigner,tokencleaner (k8s 1.32+)
# We insert -replicaset right after the * glob
docker exec "${NODE}" sed -i 's|--controllers=\*|--controllers=*,-replicaset|' \
  /etc/kubernetes/manifests/kube-controller-manager.yaml

# Step 2: Deploy custom RS controller static pod
echo "Deploying custom RS controller static pod..."
docker cp "${SCRIPT_DIR}/custom-rs-controller.yaml" \
  "${NODE}:/etc/kubernetes/manifests/custom-rs-controller.yaml"

# Step 3: Wait for KCM to restart with new flags
echo "Waiting for kube-controller-manager to restart..."
sleep 10
kubectl --context "${CONTEXT}" -n kube-system wait --for=condition=Ready \
  pod -l component=kube-controller-manager --timeout=60s 2>/dev/null || true

echo "=== Custom RS controller setup complete ==="
echo "Run verify-rs-controller.sh to confirm everything is working."
SETUP
chmod +x "${OUT_DIR}/setup-custom-rs.sh"

echo "Generated: ${OUT_DIR}/kind-custom-rs.yaml"
echo "Generated: ${OUT_DIR}/setup-custom-rs.sh"
echo ""
echo "Usage:"
echo "  1. kind create cluster --name <name> --config ${OUT_DIR}/kind-custom-rs.yaml"
echo "  2. ${OUT_DIR}/setup-custom-rs.sh <name>"
if [[ -z "${CUSTOM_BINARY}" ]]; then
  echo ""
  echo "Note: No custom binary provided. The built-in RS controller will be disabled."
  echo "You must deploy your own RS controller after running setup."
fi
