# 0002: preStop sleep and graceful shutdown for zero-downtime rollouts

- **Status:** Accepted
- **Date:** 2026-10-07

## Context

When Kubernetes deletes a pod (rolling update, scale down, node drain), two
things start **at the same time**:

1. The kubelet runs the `preStop` hook, then sends `SIGTERM` to the container.
2. The control plane marks the pod as terminating in its EndpointSlice. Every
   proxy that routes to the pod (Traefik here, kube-proxy for Service IPs) then
   has to notice that change and update its own routing.

Step 2 is asynchronous and takes time. If the app exits as soon as it gets
`SIGTERM`, the proxies still send it requests for a short while. Those requests
fail with connection errors or 502s. A rolling update can then drop requests
even though every new pod is healthy.

## Decision

The pod shuts down in three stages, all inside `terminationGracePeriodSeconds: 30`:

| Stage | Setting | Time |
|---|---|---|
| Wait while proxies remove the pod | `lifecycle.preStop.sleep.seconds: 10` | 10s |
| App gets `SIGTERM`, `/readyz` returns 503, the app keeps serving | `SHUTDOWN_DELAY_SECONDS=3` | 3s |
| uvicorn stops accepting and finishes in-flight requests | `GRACEFUL_TIMEOUT_SECONDS=10` | up to 10s |

Total: at most 23s, under the 30s grace period. After 30s the kubelet sends `SIGKILL`.

- We use the native `preStop.sleep` action (Kubernetes 1.30 and later). It needs
  no `sleep` binary or shell inside the image.
- The readiness flip to 503 is a second safety layer, for any proxy that runs its
  own health checks.
- The rollout settings support this: `maxUnavailable: 0`, `maxSurge: 1` and
  `minReadySeconds: 5`. An old pod only goes away after a new pod is ready.
  A PodDisruptionBudget (`minAvailable: 1`) protects voluntary evictions such as
  node drains.

## How we check it

`make rollout-test` sends steady traffic through the gateway, restarts the
Deployment in the middle, and counts failed requests. The expected result is
zero failed requests.

Measured on 2026-10-07 on the local kind cluster (about 40 requests per second for 90 seconds):

| Setup | Failed requests |
|---|---|
| As described above (3 runs) | 0 of 3,600, 0 of 3,551, 0 of 3,502 |
| preStop hook removed and `SHUTDOWN_DELAY_SECONDS=0` (2 runs, Argo CD auto-sync paused) | 2 of 3,551 and 2 of 3,600, all HTTP 502 from the gateway |

The control test shows that requests are dropped even on a small local cluster.
On bigger clusters, endpoint changes take longer to reach every proxy, so the
window for dropped requests is usually wider, not smaller.

## Consequences

- Rollouts are slower. Each old pod takes 13 to 23 seconds to go away (10s preStop
  sleep + 3s shutdown delay, plus up to 10s for in-flight requests).
- The numbers depend on each other. If one delay grows, the grace period must grow too.
- Long-lived connections (WebSockets, streaming) need longer timeouts than these.
- The app must handle `SIGTERM` itself. This is tested in `app/tests/test_shutdown.py`.

## Alternatives considered

- **No preStop hook.** Simple, but it drops requests during every rollout.
- **`preStop: exec: ["sleep", "10"]`.** The classic way. It needs a shell or a
  `sleep` binary in the image, and minimal images often have neither.
- **App-side delay only.** Works, but then the app has to know about Kubernetes
  timing. We keep both: the platform waits first, then the app drains.
- **Service mesh or proxy-level draining.** Powerful, but a lot of extra
  machinery for this one problem.
