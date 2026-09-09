#!/usr/bin/env bash
set -euo pipefail
HOSTS=(harbor.local argocd.local hello.local)
IP=127.0.0.1
for h in "${HOSTS[@]}"; do
  if grep -qE "[[:space:]]${h}([[:space:]]|$)" /etc/hosts; then
    echo "[skip] $h"
  else
    echo "$IP $h" | sudo tee -a /etc/hosts >/dev/null
    echo "[add] $h"
  fi
done
