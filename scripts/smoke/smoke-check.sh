#!/usr/bin/env bash
set -euo pipefail
fail=0
check() {
  if eval "$2"; then echo "OK  $1"; else echo "FAIL $1"; fail=1; fi
}
check "node ready" "kubectl get nodes | grep -q Ready"
check "no traefik" "! kubectl -n kube-system get deploy | grep -q traefik"
check "argocd" "kubectl -n argocd get deploy argocd-server -o jsonpath='{.status.readyReplicas}' | grep -qE '^[1-9]'"
check "harbor" "kubectl -n harbor get pods 2>/dev/null | grep -q Running"
check "workflows" "kubectl -n argo get pods 2>/dev/null | grep -q Running"
check "postgres" "kubectl -n postgres get pods 2>/dev/null | grep -q Running"
check "clickhouse" "kubectl -n clickhouse get pods 2>/dev/null | grep -q Running"
check "hello http" "curl -fsS -o /dev/null http://hello.myk8s.local"
check "harbor http" "curl -fsS -o /dev/null http://harbor.myk8s.local"
check "argocd http" "code=\$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 5 http://argocd.myk8s.local); echo \$code | grep -qE '^(200|301|302|307|308)$'"
check "harbor-admin secret" "kubectl -n harbor get secret harbor-admin >/dev/null 2>&1"
check "istio ingress" "kubectl -n istio-system get pods 2>/dev/null | grep istio-ingressgateway | grep -q Running"
exit "$fail"
