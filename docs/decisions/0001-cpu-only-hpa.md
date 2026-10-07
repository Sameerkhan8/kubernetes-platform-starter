# 0001: Scale on CPU only, not on memory

- **Status:** Accepted
- **Date:** 2026-10-07

## Context

sample-api runs behind a HorizontalPodAutoscaler (HPA). The HPA needs a signal
that goes up when traffic goes up and comes back down when traffic drops.

The HPA uses this rule: `desired = ceil(current * currentValue / targetValue)`.
The value is a percentage of the pod's **request**.

CPU fits this rule well for a CPU-bound service. More requests means more CPU.
When traffic drops, CPU drops right away.

Memory does not fit it for most runtimes with a garbage collector
(JVM, Go, Node.js, Python):

- The runtime keeps memory after a spike. Heaps grow and are rarely given back
  to the operating system. Python's allocator can only free a memory arena when
  every object in it is gone.
- Memory per pod depends little on traffic. A fresh pod already uses a big
  share of its request for code, libraries and caches.
- Adding pods does not lower memory in the old pods.

So the memory value stays high after load ends. With a target of 60%, a pod that
sits at 80% of its memory request gives `desired = current * 80 / 60`. The HPA
adds pods until it reaches `maxReplicas` and then stays there. It flaps or never
scales down, and you pay for idle pods.

## Decision

- The chart's HPA (`autoscaling/v2`) uses one metric: CPU `Utilization`.
  Target 60% locally, 70% in the `values-prod.yaml` example.
- Every pod sets a CPU request, because utilization is measured against it.
- `behavior` scales up fast (2 pods every 15s) and down slowly
  (120s stabilization window locally, 300s in the prod example; at most 50% of
  pods per minute). This avoids flapping after short bursts.
- Memory is handled with a request and a limit, not with autoscaling.
- Local profile: CPU limit `500m`. The `/work` endpoint burns CPU on purpose, and
  the limit stops the demo from taking every core of the laptop.
- Prod profile: no CPU limit (`limits.cpu: null`). A CPU limit causes CFS
  throttling: the kernel pauses the container for the rest of each 100ms period
  once it has used its quota. That shows up as latency spikes even when the node
  has idle CPU. The memory limit stays, because memory cannot be throttled.

## Consequences

- Scaling is easy to predict and easy to demo: `make load` raises CPU and the HPA
  adds pods; a few minutes after the load stops it removes them.
- The `SampleApiHpaMaxedOut` alert tells us when the HPA has no room left.
- An I/O-bound service (waiting on a database or another API) uses little CPU
  under load. CPU would be the wrong signal for it.
- CPU requests must be kept realistic. A request that is too low makes the HPA
  scale too early. One that is too high makes it scale too late.

## Alternatives considered

- **Memory-based HPA.** Rejected for the reasons above.
- **Requests per second or queue length** (Prometheus Adapter or KEDA). A better
  signal for I/O-bound services. It needs an extra metrics adapter in the
  cluster. Future work.
- **Vertical Pod Autoscaler.** VPA and HPA must not both act on CPU for the same
  pods. VPA in recommendation-only mode is still useful to size requests.
- **Fixed replica count.** Simple, but it wastes money at night and falls over at peak.
