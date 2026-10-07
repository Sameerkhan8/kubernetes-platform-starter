# 10-minute demo script

A walkthrough order for showing this project to someone else, for example on a client call.
Each step says what to run, what to show, and what to say in one or two sentences.

## Before the call (about 10 minutes)

```bash
make up        # about 4-5 minutes once images are cached
make smoke     # everything should say PASS
make creds     # Grafana and Argo CD passwords; log in to both before the call
```

Open these tabs (log in first, so no password is shown on screen):

- http://argocd.localtest.me (application `sample-api-dev`)
- http://grafana.localtest.me (dashboard "Sample API - Golden Signals")
- http://alertmanager.localtest.me
- This README and [docs/architecture.md](architecture.md)

Keep a terminal open in the repo, with a large font.

## The walkthrough

| Time | Show | Say |
|---|---|---|
| 0:00 | README: the architecture diagram | "This is a small but complete platform: a gateway, monitoring, GitOps and a sample service, all on a laptop. The same setup maps to a managed cluster like GKE, and the Terraform for that is in the repo." |
| 1:00 | Terminal: `make help`, then `make guard` | "Every command uses a kubeconfig inside the repo and checks it is talking to the local cluster. Your real clusters can never be touched by accident." |
| 2:00 | Argo CD tab: the application tree | "Nobody deploys by hand. Argo CD pulls the Helm chart from Git and keeps the cluster in sync. CI only changes an image tag in Git. To roll back, you revert a commit." |
| 3:00 | Terminal: `make rollout-test` (90 seconds) | While it runs: "This restarts every pod while sending 40 requests a second. The pod first stops getting new traffic, then finishes what it has, then exits. Expect 0 failed requests." Then show the [ADR 0002](decisions/0002-prestop-sleep-graceful-shutdown.md) table: with the drain settings switched off, the same test lost requests. |
| 5:00 | Terminal: `make load`, then the Grafana tab | "Under CPU load the autoscaler goes from 2 to 6 pods in about a minute, and back down slowly after the load stops, so it does not flap." Point at the "HPA replicas" and "CPU per pod" panels. |
| 7:00 | Terminal: `make alert-demo` (about 3 minutes), then the Alertmanager tab | "Half of the requests now fail on purpose. The alert goes pending, then fires, and it carries a link to a runbook that says what to check and how to fix it." Open the runbook link. |
| 8:30 | Terminal: `make policy-test` | "The app namespace denies traffic by default, in and out. Only the gateway and Prometheus can reach the app, and a privileged pod is rejected." |
| 9:00 | `terraform/gcp-gke/README.md` | "For Google Cloud: a private GKE cluster, Cloud NAT, Artifact Registry, and GitHub login with OIDC, so there are no JSON keys. It is validated and unit-tested offline; I have not applied it from this repo." |

Start `make alert-demo` a little early if time is short: it needs about 3 minutes to fire.

## Questions people often ask

**Why Traefik and Gateway API, not ingress-nginx?**
The ingress-nginx project is archived, so it gets no more fixes. Gateway API is the
upstream successor, and GKE supports it natively. See [ADR 0005](decisions/0005-gateway-api-instead-of-ingress-nginx.md).

**Why scale on CPU only?**
Memory in Python and other garbage-collected runtimes often does not go down after a
spike, so a memory target scales up and then never scales back. See [ADR 0001](decisions/0001-cpu-only-hpa.md).

**Has this run on a real cloud cluster?**
The local platform is tested end to end (numbers in the README come from real runs).
The Terraform module is validated, linted and unit-tested with a mocked provider, but it
was not applied as part of this project. Say this plainly.

**What would you change for production?**
TLS with cert-manager, an external secrets store, admission policies (Kyverno), image
signing, SLO-based alerts and long-term metrics. The full list is in the README under
"What I would add in production".

**How much does it cost?**
Locally: nothing, it runs on a laptop with about 4 GB of RAM. On Google Cloud it depends
on region, machine type and node count; the Terraform README explains the cost drivers
and how to estimate them.

## After the call

```bash
make down      # deletes the local cluster; images stay cached for next time
```
