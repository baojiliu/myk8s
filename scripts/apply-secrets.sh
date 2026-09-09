#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
LOCAL="$ROOT/secrets/local"

need() { [[ -f "$LOCAL/$1" ]] || { echo "missing $LOCAL/$1"; exit 1; }; }
need harbor-admin.env
need postgres.env
need github-token.env
need harbor-robot.env

# shellcheck disable=SC1091
set -a
source "$LOCAL/harbor-admin.env"
source "$LOCAL/postgres.env"
source "$LOCAL/github-token.env"
source "$LOCAL/harbor-robot.env"
set +a

kubectl get ns harbor >/dev/null 2>&1 || kubectl create ns harbor
kubectl get ns postgres >/dev/null 2>&1 || kubectl create ns postgres
kubectl get ns argo >/dev/null 2>&1 || kubectl create ns argo
kubectl get ns apps >/dev/null 2>&1 || kubectl create ns apps

kubectl -n harbor create secret generic harbor-admin \
  --from-literal=HARBOR_ADMIN_PASSWORD="$HARBOR_ADMIN_PASSWORD" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl -n postgres create secret generic postgres-app \
  --from-literal=username="$POSTGRES_USER" \
  --from-literal=password="$POSTGRES_PASSWORD" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl -n argo create secret generic github-token \
  --from-literal=token="$GITHUB_TOKEN" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl -n argo create secret generic harbor-robot \
  --from-literal=username="$HARBOR_ROBOT_NAME" \
  --from-literal=password="$HARBOR_ROBOT_PASSWORD" \
  --dry-run=client -o yaml | kubectl apply -f -


kubectl -n apps create secret docker-registry harbor-pull   --docker-server=harbor.local   --docker-username="$HARBOR_ROBOT_NAME"   --docker-password="$HARBOR_ROBOT_PASSWORD"   --dry-run=client -o yaml | kubectl apply -f -

echo "[INFO] secrets applied"
