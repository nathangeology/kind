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

# Base KIND config: disable built-in RS controller
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
    - --secure-port=10258
    - --use-service-account-credentials=true
    - --service-account-private-key-file=/etc/kubernetes/pki/sa.key
    - --root-ca-file=/etc/kubernetes/pki/ca.crt
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

  # Only mount the binary — NOT the static pod manifest.
  # kubeadm fails if extra manifests exist in /etc/kubernetes/manifests/ during init.
  # After cluster creation, use: docker cp ${OUT_DIR}/custom-rs-controller.yaml <node>:/etc/kubernetes/manifests/
  EXTRA_MOUNTS=$(cat <<EOF
  - hostPath: ${CUSTOM_BINARY}
    containerPath: /opt/custom-rs-controller/controller-manager
    readOnly: true
EOF
)

  echo "Generated: ${OUT_DIR}/custom-rs-controller.yaml"
fi

# --- Generate KIND cluster config ---
cat > "${OUT_DIR}/kind-custom-rs.yaml" <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  kubeadmConfigPatches:
  - |
    kind: ClusterConfiguration
    controllerManager:
      extraArgs:
        controllers: "*,-replicaset"
${EXTRA_MOUNTS:+  extraMounts:
${EXTRA_MOUNTS}}
EOF

CLUSTER_NAME="${CLUSTER_NAME:-rs-test}"

echo "Generated: ${OUT_DIR}/kind-custom-rs.yaml"
echo ""
echo "Create cluster and deploy custom controller:"
echo "  kind create cluster --name ${CLUSTER_NAME} --config ${OUT_DIR}/kind-custom-rs.yaml"
if [[ -n "${CUSTOM_BINARY}" ]]; then
  echo "  docker cp ${OUT_DIR}/custom-rs-controller.yaml ${CLUSTER_NAME}-control-plane:/etc/kubernetes/manifests/"
  echo ""
  echo "The static pod manifest must be copied AFTER cluster creation."
  echo "kubeadm fails if extra manifests exist in /etc/kubernetes/manifests/ during init."
else
  echo ""
  echo "Note: No custom binary provided. The built-in RS controller is disabled."
  echo "You must deploy your own RS controller after cluster creation."
fi
