#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
bash "$ROOT/scripts/setup-hosts.sh"
bash "$ROOT/scripts/apply-secrets.sh"
bash "$ROOT/bootstrap/argocd/install.sh"
kubectl apply -f "$ROOT/argocd/roots/"
echo "[INFO] bootstrap done — open https://argocd.local after Istio/Gateway ready (or port-forward now)"
echo "  kubectl -n argocd port-forward svc/argocd-server 8080:443"
