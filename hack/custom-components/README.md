# Custom Components Tooling for KIND

Helpers for swapping control-plane components in KIND clusters.

## Scheduler Scoring Profiles

Replace the default `LeastAllocated` scoring with an alternate profile
(e.g. `MostAllocated` for bin-packing):

```bash
# Generate KIND config with MostAllocated scoring
./hack/custom-components/gen-scheduler-config.sh MostAllocated

# Create cluster using the generated config
kind create cluster --config hack/custom-components/out/kind-scheduler.yaml
```

### How it works

1. Generates a `KubeSchedulerConfiguration` YAML with the requested scoring plugin
2. Creates a KIND config that:
   - Mounts the scheduler config into the control-plane node
   - Patches `ClusterConfiguration` to pass `--config` to kube-scheduler
3. The scheduler reads the config at startup and uses the specified scoring profile

### Supported scoring plugins

- `MostAllocated` — bin-packing (prefer nodes with higher utilization)
- `RequestedToCapacityRatio` — custom utilization curve
- `NodeResourcesFit` with custom weights

## Custom ReplicaSet Controller

Replace the built-in replicaset controller with a custom build:

```bash
# Generate KIND config that disables built-in RS controller
# and runs a custom one as a static pod
./hack/custom-components/gen-custom-rs-controller.sh /path/to/custom-kube-controller-manager

# Create cluster (binary mounted, static pod NOT yet deployed)
kind create cluster --name rs-test --config hack/custom-components/out/kind-custom-rs.yaml

# Deploy static pod AFTER cluster creation (kubeadm fails if present during init)
docker cp hack/custom-components/out/custom-rs-controller.yaml rs-test-control-plane:/etc/kubernetes/manifests/
```

### How it works

1. Disables the built-in replicaset controller via `--controllers=-replicaset`
   on kube-controller-manager
2. Mounts the custom binary into the node via KIND extraMounts
3. After cluster creation, the static pod manifest is copied into the node
   (kubeadm chokes on extra manifests in `/etc/kubernetes/manifests/` during init)

### Alternative: Custom node image

For a more integrated approach, build a custom node image:

```bash
# Build custom kube-controller-manager, then build a KIND node image
# that includes it
./hack/custom-components/build-custom-node-image.sh /path/to/kubernetes-source
```

## Verification

Smoke tests to confirm components are working:

```bash
# Verify scheduler scoring
./hack/custom-components/verify-scheduler.sh

# Verify custom RS controller
./hack/custom-components/verify-rs-controller.sh
```

## Common Failure Modes

### Scheduler
- **File not mounted**: Check `docker exec <node> ls /etc/kubernetes/scheduler-config.yaml`
- **Wrong API version**: KubeSchedulerConfiguration API version must match your k8s version
  (v1 for 1.25+, v1beta3 for 1.23-1.24, v1beta2 for 1.22)
- **Permissions**: The scheduler config file must be readable by root inside the container

### Custom RS Controller
- **RBAC missing**: The custom controller needs the same RBAC as kube-controller-manager
- **Leader election conflicts**: If both built-in and custom controllers run, they'll fight
  for the leader lock. Ensure `--controllers=-replicaset` is set on the built-in KCM.
- **Image not available**: When using a static pod, the binary must be mounted into the node
  before kubelet starts
