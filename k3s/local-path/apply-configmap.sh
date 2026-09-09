#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
USER_NAME=${SUDO_USER:-$USER}
USER_HOME=$(getent passwd "$USER_NAME" | cut -d: -f6)
DATA_DIR="${USER_HOME}/data"
mkdir -p "$DATA_DIR"
chown "$USER_NAME:$USER_NAME" "$DATA_DIR"

kubectl -n kube-system create configmap local-path-config \
  --from-file=config.json="${SCRIPT_DIR}/config.json" \
  -o yaml --dry-run=client | kubectl apply -f -

kubectl -n kube-system rollout restart deployment/local-path-provisioner
echo "[INFO] local-path -> ${DATA_DIR}"
