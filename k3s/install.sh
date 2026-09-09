#!/usr/bin/env bash
# Uninstalls existing k3s (if present) before reinstalling.
set -e

[[ $EUID -eq 0 ]] || exec sudo bash "$0" "$@"

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
USER_NAME=${SUDO_USER:-$USER}
USER_HOME=$(getent passwd "$USER_NAME" | cut -d: -f6)

if [[ -x /usr/local/bin/k3s-uninstall.sh ]]; then
  echo "[INFO] uninstall k3s"
  /usr/local/bin/k3s-uninstall.sh
fi

mkdir -p /etc/rancher/k3s
cp "$SCRIPT_DIR/config.yaml" /etc/rancher/k3s/config.yaml
cp "$SCRIPT_DIR/registries.yaml" /etc/rancher/k3s/registries.yaml

echo "[INFO] install k3s"
curl -sfL https://get.k3s.io | sh -

mkdir -p "$USER_HOME/.kube"
cp /etc/rancher/k3s/k3s.yaml "$USER_HOME/.kube/config"
chown "$USER_NAME:$USER_NAME" "$USER_HOME/.kube/config"

echo "[INFO] configure local-path -> ${USER_HOME}/data"
bash "$SCRIPT_DIR/local-path/apply-configmap.sh"

echo "[INFO] done"
