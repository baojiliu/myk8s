#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
bash "$ROOT/scripts/hosts/setup-hosts.sh"
bash "$ROOT/scripts/secrets/apply-secrets.sh" local
bash "$ROOT/bootstrap/argocd/install.sh"
kubectl apply -f "$ROOT/argocd/roots/"
echo "[INFO] bootstrap done — open http://argocd.myk8s.local after Istio/Gateway ready (or port-forward now)"
echo "  kubectl -n argocd port-forward svc/argocd-server 8080:443"
