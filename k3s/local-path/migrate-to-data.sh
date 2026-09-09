#!/usr/bin/env bash
# Migrate existing local-path volume data into ~/data.
#
# PV.spec.local.path is immutable. Instead of recreating PV/PVC (fights Argo CD),
# we rsync data into ~/data and replace each old directory under
# /var/lib/rancher/k3s/storage with a symlink into ~/data.
# New volumes already use ~/data via apply-configmap.sh.
set -euo pipefail

USER_NAME=${SUDO_USER:-$USER}
USER_HOME=$(getent passwd "$USER_NAME" | cut -d: -f6)
DATA_DIR="${USER_HOME}/data"
OLD_ROOT=/var/lib/rancher/k3s/storage

run_root() {
  if [[ "$(id -u)" -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

mkdir -p "$DATA_DIR"
chown "$USER_NAME:$USER_NAME" "$DATA_DIR" || true

echo "[INFO] stop Argo CD application-controller (prevents self-heal during migrate)"
kubectl -n argocd scale sts/argocd-application-controller --replicas=0
kubectl -n argocd wait pod -l app.kubernetes.io/name=argocd-application-controller \
  --for=delete --timeout=120s 2>/dev/null || true

echo "[INFO] scale down Harbor + hibernate Postgres"
kubectl -n harbor scale deploy --all --replicas=0
kubectl -n harbor scale sts --all --replicas=0
kubectl -n postgres annotate cluster.postgresql.cnpg.io/postgres \
  --overwrite cnpg.io/hibernation=on 2>/dev/null || true
kubectl -n harbor wait pod --for=delete --all --timeout=180s 2>/dev/null || true
kubectl -n postgres wait pod --for=delete --all --timeout=180s 2>/dev/null || true
sleep 3

echo "[INFO] rsync ${OLD_ROOT} -> ${DATA_DIR} and symlink"
run_root bash -c "
set -euo pipefail
DATA_DIR='${DATA_DIR}'
OLD_ROOT='${OLD_ROOT}'
mkdir -p \"\$DATA_DIR\"
shopt -s nullglob
for d in \"\$OLD_ROOT\"/pvc-*; do
  base=\$(basename \"\$d\")
  if [[ -L \"\$d\" ]]; then
    echo \"[skip] already symlink: \$base\"
    continue
  fi
  echo \"[rsync] \$base\"
  mkdir -p \"\$DATA_DIR/\$base\"
  rsync -aHAX --delete \"\$d/\" \"\$DATA_DIR/\$base/\"
  rm -rf \"\$d\"
  ln -s \"\$DATA_DIR/\$base\" \"\$d\"
  echo \"[link] \$d -> \$DATA_DIR/\$base\"
done
"

echo "[INFO] wake workloads"
kubectl -n postgres annotate cluster.postgresql.cnpg.io/postgres cnpg.io/hibernation- 2>/dev/null || true
kubectl -n harbor scale deploy harbor-core harbor-jobservice harbor-nginx harbor-portal harbor-registry --replicas=1
kubectl -n harbor scale sts harbor-database harbor-redis harbor-trivy --replicas=1

kubectl -n harbor rollout status deploy/harbor-core --timeout=180s || true
kubectl -n postgres wait pod -l cnpg.io/cluster=postgres --for=condition=Ready --timeout=180s || true

echo "[INFO] restart Argo CD application-controller"
kubectl -n argocd scale sts/argocd-application-controller --replicas=1
kubectl -n argocd rollout status sts/argocd-application-controller --timeout=120s || true

echo "[DONE] data lives under ${DATA_DIR}"
kubectl get pv -o custom-columns='NAME:.metadata.name,PATH:.spec.local.path' --no-headers
