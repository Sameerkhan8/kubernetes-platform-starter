# PlatformNodeNotReady

| Severity | Source rule file | Fires when (plain words) |
|---|---|---|
| critical | `monitoring/rules/platform.rules.yaml` | A Kubernetes node has not been Ready for 5 minutes. |

## What it means

The kubelet on that node has stopped reporting that it is healthy. The node may be off, out of
resources, cut off from the network, or its kubelet may have crashed.

On kind, each node is a Docker container (`kps-control-plane`, `kps-worker`, `kps-worker2`).

## Impact on users

Pods on that node stop getting traffic once they are marked not ready. After about 5 minutes,
Kubernetes evicts them and starts replacements on the other nodes, if there is room.
sample-api spreads its pods across both workers and zones (topologySpreadConstraints) and has a
PodDisruptionBudget, so one lost worker should not take it down.
If the control-plane node is lost, the gateway (Traefik) and the Kubernetes API are lost too.

## How to check

```bash
export KUBECONFIG=$PWD/.kube/config  # repo-local kind cluster

kubectl --context kind-kps get nodes -L topology.kubernetes.io/zone
kubectl --context kind-kps describe node <node-name>   # Conditions: MemoryPressure, DiskPressure, Ready message

# Where did the pods go?
kubectl --context kind-kps get pods -A -o wide --field-selector spec.nodeName=<node-name>

# On kind: is the node container running? Is its kubelet running?
docker ps -a --filter name=kps-
docker exec <node-name> systemctl status kubelet --no-pager
docker exec <node-name> journalctl -u kubelet --since "15 min ago" --no-pager | tail -50
```

## How to fix

| Cause | Fix |
|---|---|
| kind node container stopped | `docker start <node-name>`, then wait for `Ready`. |
| kubelet crashed | Read its journal (above). On kind: `docker exec <node-name> systemctl restart kubelet`. |
| kubelet will not start on kind: `inotify_init: too many open files` in its journal | All kind nodes share the laptop's inotify limit (`fs.inotify.max_user_instances`, often 128). Raise it until the next reboot: `sudo sysctl -w fs.inotify.max_user_instances=512 fs.inotify.max_user_watches=524288` (`make doctor` prints this), or recreate the cluster: `make down && make up`. |
| Disk or memory pressure | Free space or memory on the host. See [PlatformNodeMemoryHigh](PlatformNodeMemoryHigh.md). |
| Cloud node is broken (GKE) | Node auto-repair replaces it (enabled in `terraform/gcp-gke`). If it does not recover: `kubectl --context <your-gke-context> drain <node> --ignore-daemonsets --delete-emptydir-data`, then delete the node and let the node pool create a new one. |

## How to trigger it locally

Stop the kubelet inside a worker node container. The container keeps running (so the node
keeps its IP and comes back cleanly), but the node stops reporting to Kubernetes:

```bash
export KUBECONFIG=$PWD/.kube/config
docker exec kps-worker2 systemctl stop kubelet
kubectl --context kind-kps get nodes -w      # kps-worker2 turns NotReady after about 40 seconds
# the alert fires about 5 minutes after that (http://alertmanager.localtest.me)
docker exec kps-worker2 systemctl start kubelet   # see the note on inotify limits below
```

This works on either worker because Prometheus, Alertmanager and kube-state-metrics run on
the control-plane node (`platform/kube-prometheus-stack/values.yaml`), so the drill cannot
take the monitoring down with it. Do not stop the control-plane node: that stops the gateway,
the API server and the monitoring.

Pods on the stopped node are marked not ready at once (so they get no traffic) and are evicted
about 5 minutes later. Watch them move: `kubectl --context kind-kps -n demo get pods -o wide -w`.

Tested on the kind cluster on 2026-10-07 with the commands above:

- `kps-worker2` showed `NotReady` (status `Unknown`) within about 1 minute.
- The alert went pending after about 80 seconds and fired 6 minutes 22 seconds after the
  kubelet was stopped. Alertmanager received it at once.
- The app pod on `kps-worker2` stopped getting traffic, was evicted after about 6 minutes,
  and its replacement started on `kps-worker`. `SampleApiReplicasUnavailable` went pending
  meanwhile and cleared when the replacement was ready, without firing (it waits 10 minutes).
- **Bringing the node back failed on this laptop:** after `systemctl start kubelet`, the
  kubelet kept exiting with `inotify_init: too many open files`. The laptop's limit
  (`fs.inotify.max_user_instances`) was the Linux default of 128, shared by all three kind
  nodes, and the replacement pods had used up the free slots. Raise the limit before you run
  this drill (the `sudo sysctl` command in the table above, or `make doctor` prints it), or
  run `make down && make up` afterwards. The fix with a higher limit was not tried here,
  because it changes a kernel setting on the laptop.

## Related

- Grafana default dashboard "Node Exporter / Nodes".
- [SampleApiReplicasUnavailable](SampleApiReplicasUnavailable.md), [PlatformNodeMemoryHigh](PlatformNodeMemoryHigh.md).
- This alert replaces the kube-prometheus-stack default `KubeNodeNotReady` (switched off in `platform/kube-prometheus-stack/values.yaml`).
