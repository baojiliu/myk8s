#!/usr/bin/env bash
set -euo pipefail
NEW_HOSTS=(harbor.myk8s.local argocd.myk8s.local hello.myk8s.local)
OLD_HOSTS=(harbor.local argocd.local hello.local)
IP=127.0.0.1

for h in "${NEW_HOSTS[@]}"; do
  if grep -qE "[[:space:]]${h}([[:space:]]|$)" /etc/hosts; then
    echo "[skip] $h"
  else
    echo "$IP $h" | sudo tee -a /etc/hosts >/dev/null
    echo "[add] $h"
  fi
done

for h in "${OLD_HOSTS[@]}"; do
  if grep -qE "[[:space:]]${h}([[:space:]]|$)" /etc/hosts; then
    sudo sed -i -E "/[[:space:]]${h}([[:space:]]|$)/d" /etc/hosts
    echo "[del] $h"
  else
    echo "[skip-del] $h"
  fi
done
