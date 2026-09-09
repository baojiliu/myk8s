#!/usr/bin/env bash
# Point k3s local-path-provisioner at ~/data and keep the Addon from reverting.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
USER_NAME=${SUDO_USER:-$USER}
USER_HOME=$(getent passwd "$USER_NAME" | cut -d: -f6)
DATA_DIR="${USER_HOME}/data"
MANIFEST=/var/lib/rancher/k3s/server/manifests/local-storage.yaml

mkdir -p "$DATA_DIR"
chown "$USER_NAME:$USER_NAME" "$DATA_DIR"

# Repo template used by kubectl apply (path must match this machine's home).
cat >"${SCRIPT_DIR}/config.json" <<EOF
{
  "nodePathMap": [
    {
      "node": "DEFAULT_PATH_FOR_NON_LISTED_NODES",
      "paths": ["${DATA_DIR}"]
    }
  ]
}
EOF

# Persist in k3s Addon source; otherwise k3s rewrites ConfigMap back to
# /var/lib/rancher/k3s/storage on every Addon reconcile.
# Manifest is root-only; use sudo for existence check and edit.
run_root() {
  if [[ "$(id -u)" -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

if run_root test -f "$MANIFEST"; then
  run_root sed -i "s|\"/var/lib/rancher/k3s/storage\"|\"${DATA_DIR}\"|g" "$MANIFEST"
  echo "[INFO] patched k3s Addon manifest: ${MANIFEST}"
else
  echo "[WARN] ${MANIFEST} not found; ConfigMap apply may be overwritten by k3s later"
fi

kubectl -n kube-system create configmap local-path-config \
  --from-file=config.json="${SCRIPT_DIR}/config.json" \
  -o yaml --dry-run=client | kubectl apply -f -

kubectl -n kube-system rollout restart deployment/local-path-provisioner
kubectl -n kube-system rollout status deployment/local-path-provisioner --timeout=120s

echo "[INFO] local-path -> ${DATA_DIR}"
echo "[INFO] 已有 PVC 的 hostPath 不会自动迁移；仅新建卷会写入 ${DATA_DIR}"
