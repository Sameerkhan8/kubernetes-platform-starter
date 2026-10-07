# Screenshots

The main README has a screenshot gallery for the six images below. It stays hidden (inside an
HTML comment in `README.md`, section "Screenshots") until the files exist, so GitHub never
shows a broken image. They must be real screenshots from a local run, not mock-ups.

When all six files are here, open `README.md`, find the "Screenshots" section and delete the
two comment lines (`<!-- SCREENSHOTS-START` and `SCREENSHOTS-END -->`) around the gallery.

How to capture them:

```bash
make up          # wait until it prints the URLs
make creds       # Grafana and Argo CD passwords (terminal only)
```

| File | What to show | When to take it |
|---|---|---|
| `grafana-dashboard.png` | Grafana dashboard "Sample API - Golden Signals": requests/s, p95 latency, CPU per pod and the "HPA replicas" panel going from 2 to 6 | During `make load` (start it, wait about 2 minutes) |
| `argocd-app.png` | Argo CD UI, application `sample-api-dev`: Synced + Healthy, with the resource tree (Deployment, HPA, PDB, HTTPRoute, NetworkPolicies, ServiceMonitor, PrometheusRule) | Any time after `make up` |
| `alertmanager-firing.png` | Alertmanager with `SampleApiHighErrorRate` firing, labels and the `runbook_url` annotation visible | During `make alert-demo`, once it says "firing" |
| `prometheus-rules.png` | Prometheus "Alerts" page with the 10 custom rules (groups `sample-api.alerts` and `platform.alerts`) | Any time after `make up` |
| `rollout-test.png` | Terminal output of `make rollout-test` ending with `RESULT total=... failed=0` and `PASS` | After the run |
| `hpa-scaling.png` | Terminal output of `make load` with the `hpa replicas=` lines going 2 -> 6 | During or after the run |

Tips:

- Use a browser window about 1400 px wide, so the images stay readable on GitHub.
- Crop out bookmarks, other tabs and anything personal.
- Keep each file under about 500 KB (PNG, or JPEG for large dashboards).
- Do not show passwords. The login pages are fine; the `make creds` output is not.
