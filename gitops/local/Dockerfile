# kps-gitd:local - a tiny read-only git daemon for "make gitops-local".
# It serves the bare mirror in .gitops/ to Argo CD over git://, so GitOps works on a laptop
# before the repo is pushed anywhere. It runs as a container named kps-git on the "kind"
# Docker network; pods reach it by that name.
FROM alpine:3.24.3@sha256:be2656061b536c1883c4034790e21d0a09c5aaaf51968b89368a3c0371ea2c9a
RUN apk add --no-cache git git-daemon && git config --system --add safe.directory '*'
USER 65534:65534
EXPOSE 9418
ENTRYPOINT ["git","daemon","--reuseaddr","--export-all","--base-path=/srv/git","--verbose","--informative-errors","/srv/git"]
