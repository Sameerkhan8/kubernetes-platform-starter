# kps-gitd:local - a tiny read-only git daemon for "make gitops-local".
# It serves the bare mirror in .gitops/ to Argo CD over git://, so GitOps works on a laptop
# before the repo is pushed anywhere. It runs as a container named kps-git on the "kind"
# Docker network; pods reach it by that name.
FROM alpine:3.24.2@sha256:294b683cb724975bec92580e1e685676bd4b50bda910ddb8c51d4cabeaec77e6
RUN apk add --no-cache git git-daemon && git config --system --add safe.directory '*'
USER 65534:65534
EXPOSE 9418
ENTRYPOINT ["git","daemon","--reuseaddr","--export-all","--base-path=/srv/git","--verbose","--informative-errors","/srv/git"]
