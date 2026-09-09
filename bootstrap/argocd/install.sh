#!/usr/bin/env bash
set -euo pipefail
kubectl get ns argocd >/dev/null 2>&1 || kubectl create namespace argocd
# ApplicationSet CRD exceeds client-side last-applied annotation limit (262144);
# install/upgrade must use server-side apply (see Argo CD 3.2→3.3 upgrade notes).
kubectl apply --server-side --force-conflicts -n argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
echo "[INFO] waiting for argocd-server..."
kubectl -n argocd rollout status deployment/argocd-server --timeout=300s
kubectl -n argocd rollout status statefulset/argocd-application-controller --timeout=300s
echo "[INFO] initial admin password:"
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
