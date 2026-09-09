# `*.myk8s.local` 域名迁移 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 将 Harbor / Argo CD / hello 的入口与 Harbor registry 主机名从 `*.local` 全部改为 `*.myk8s.local`，补齐 `argocd.myk8s.local` 的 Istio 路由，并更新 hosts/脚本/文档。

**Architecture:** local overlay 与平台清单内**写死**新主机名（不上公共 domains 配置）。`setup-hosts.sh` 逐条写入三新名并删除三旧名。本机 Docker / k3s registry 配置同步改名。未来云环境另建 overlay 写死云域名。

**Tech Stack:** Istio Gateway/VirtualService、Harbor Helm values、k3s registries、Argo CD Application、bash 脚本

**Spec:** `docs/superpowers/specs/2026-09-09-myk8s-local-domains-design.md`

**本 plan 无 Go / 无 PolarDB schema 变更** — 各 task 跳过 `fix-golang-lint`；验证以 `kubectl` / `curl` / `scripts/smoke-check.sh` 为准。

**目标主机名：**

| 用途 | 新名 |
|------|------|
| Harbor UI + registry | `harbor.myk8s.local` |
| Argo CD UI | `argocd.myk8s.local` |
| hello | `hello.myk8s.local` |

---

## 文件结构总览

| 路径 | 职责 |
|------|------|
| `scripts/setup-hosts.sh` | 加新三名、删旧三名 |
| `scripts/apply-secrets.sh` | `harbor-pull` docker-server |
| `scripts/smoke-check.sh` / `bootstrap.sh` | 探活与提示文案 |
| `platform/base/harbor/values-local.yaml` | `externalURL` |
| `platform/base/harbor/istio-gateway.yaml` | Harbor GW/VS hosts |
| `platform/base/argocd-istio/*` | 新建 Argo CD GW/VS |
| `argocd/platform/argocd-istio.yaml` + kustomization | 挂 Application |
| `workloads/base/hello/**` + `overlays/local` | hello 域名与镜像 |
| `k3s/registries.yaml` | 节点拉镜像 |
| `README.md` + 平台 spec 域名表述 | 文档对齐 |

---

### Task 1: `setup-hosts.sh` 加新删旧

**Files:**
- Modify: `scripts/setup-hosts.sh`

- [ ] **Step 1: 重写脚本**

```bash
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
```

- [ ] **Step 2: 本机执行并验证**

```bash
bash scripts/setup-hosts.sh
grep -E 'myk8s\.local|harbor\.local|hello\.local|argocd\.local' /etc/hosts
```

Expected: 仅出现三新名；旧三名不在。

- [ ] **Step 3: Commit**（无 Go，跳过 lint）

```bash
git add scripts/setup-hosts.sh
git commit -m "$(cat <<'EOF'
feat: setup-hosts 切换为 *.myk8s.local 并清理旧 *.local

逐条写入新主机名，删除 harbor/argocd/hello.local。
EOF
)"
```

---

### Task 2: Harbor `externalURL` + Istio hosts

**Files:**
- Modify: `platform/base/harbor/values-local.yaml`
- Modify: `platform/base/harbor/istio-gateway.yaml`
- Modify: `platform/base/istio-ingress/ingress-gateway.yaml`（注释中的域名）

- [ ] **Step 1: 改 values**

`externalURL: http://harbor.myk8s.local`

- [ ] **Step 2: 改 Istio**

`platform/base/harbor/istio-gateway.yaml` 中 Gateway 与 VirtualService 的 `hosts` 全部改为 `harbor.myk8s.local`。

- [ ] **Step 3: 更新 ingress 注释**

`platform/base/istio-ingress/ingress-gateway.yaml` 注释改为提及 `harbor.myk8s.local` / `hello.myk8s.local` / `argocd.myk8s.local`。

- [ ] **Step 4: Commit**

```bash
git add platform/base/harbor platform/base/istio-ingress/ingress-gateway.yaml
git commit -m "$(cat <<'EOF'
feat: Harbor 入口与 externalURL 改为 harbor.myk8s.local

同步 Istio Gateway/VirtualService hosts。
EOF
)"
```

---

### Task 3: k3s `registries.yaml`

**Files:**
- Modify: `k3s/registries.yaml`

- [ ] **Step 1: 替换全文**

```yaml
mirrors:
  harbor.myk8s.local:
    endpoint:
      - "http://harbor.myk8s.local"
configs:
  "harbor.myk8s.local":
    tls:
      insecure_skip_verify: true
```

- [ ] **Step 2: Commit**

```bash
git add k3s/registries.yaml
git commit -m "$(cat <<'EOF'
feat: k3s registries 指向 harbor.myk8s.local

节点拉取 Harbor HTTP 镜像使用新主机名。
EOF
)"
```

- [ ] **Step 3: 本机落地（执行说明，不入 commit）**

```bash
sudo cp k3s/registries.yaml /etc/rancher/k3s/registries.yaml
# Docker insecure-registries 改为 harbor.myk8s.local 后：
# sudo systemctl reload docker
sudo systemctl restart k3s
```

Expected: k3s Ready；之后可从新 registry 拉镜像。

---

### Task 4: hello 镜像与 Istio / Workflow

**Files:**
- Modify: `workloads/base/hello/istio/gateway.yaml`
- Modify: `workloads/base/hello/deployment.yaml`
- Modify: `workloads/base/hello/ci/workflow-template.yaml`
- Modify: `workloads/overlays/local/kustomization.yaml`

- [ ] **Step 1: Gateway/VS hosts → `hello.myk8s.local`**

- [ ] **Step 2: deployment / overlay / workflow 中所有 `harbor.local` → `harbor.myk8s.local`**

含：`image`、`images.name`、kaniko `auths` key、`--insecure-registry`。

- [ ] **Step 3: Commit**

```bash
git add workloads
git commit -m "$(cat <<'EOF'
feat: hello 域名与镜像仓库改为 *.myk8s.local

更新 Gateway、Deployment、overlay 与 WorkflowTemplate。
EOF
)"
```

---

### Task 5: Argo CD Istio 路由 `argocd.myk8s.local`

**Files:**
- Create: `platform/base/argocd-istio/gateway.yaml`
- Create: `platform/base/argocd-istio/kustomization.yaml`
- Create: `argocd/platform/argocd-istio.yaml`
- Modify: `argocd/platform/kustomization.yaml`

- [ ] **Step 1: 写 Gateway + VirtualService**

`platform/base/argocd-istio/gateway.yaml`：

```yaml
apiVersion: networking.istio.io/v1
kind: Gateway
metadata:
  name: argocd-gw
  namespace: argocd
spec:
  selector:
    istio: ingressgateway
  servers:
    - port:
        number: 80
        name: http
        protocol: HTTP
      hosts:
        - argocd.myk8s.local
---
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: argocd-vs
  namespace: argocd
spec:
  hosts:
    - argocd.myk8s.local
  gateways:
    - argocd-gw
  http:
    - route:
        - destination:
            host: argocd-server
            port:
              number: 80
```

`platform/base/argocd-istio/kustomization.yaml`：

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: argocd
resources:
  - gateway.yaml
```

- [ ] **Step 2: Argo Application**

`argocd/platform/argocd-istio.yaml`：

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: argocd-istio
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "21"
spec:
  project: default
  source:
    repoURL: https://github.com/baojiliu/myk8s.git
    targetRevision: HEAD
    path: platform/base/argocd-istio
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

在 `argocd/platform/kustomization.yaml` 的 `resources` 中加入 `- argocd-istio.yaml`。

- [ ] **Step 3: Commit**

```bash
git add platform/base/argocd-istio argocd/platform
git commit -m "$(cat <<'EOF'
feat: 为 argocd.myk8s.local 增加 Istio Gateway

经 ingressgateway HTTP 路由到 argocd-server:80。
EOF
)"
```

---

### Task 6: 脚本 `apply-secrets` / smoke / bootstrap

**Files:**
- Modify: `scripts/apply-secrets.sh`
- Modify: `scripts/smoke-check.sh`
- Modify: `scripts/bootstrap.sh`

- [ ] **Step 1: apply-secrets**

`--docker-server=harbor.myk8s.local`

- [ ] **Step 2: smoke-check**

```bash
check "hello http" "curl -fsS -o /dev/null http://hello.myk8s.local"
check "harbor http" "curl -fsS -o /dev/null http://harbor.myk8s.local"
check "argocd http" "curl -fsS -o /dev/null http://argocd.myk8s.local"
```

（若 Argo CD 对 HTTP 返回重定向到 HTTPS，可用 `curl -fsS -o /dev/null -L` 或检查状态码 `grep -qE '^(200|301|302|307|308)$'`；实现时以实际响应为准，保证「可达」。）

- [ ] **Step 3: bootstrap 提示**

改为 `http://argocd.myk8s.local`（与本期 HTTP 一致）。

- [ ] **Step 4: Commit**

```bash
git add scripts/apply-secrets.sh scripts/smoke-check.sh scripts/bootstrap.sh
git commit -m "$(cat <<'EOF'
feat: 脚本与 smoke 对齐 *.myk8s.local

更新 pull secret、探活 URL 与 bootstrap 提示。
EOF
)"
```

---

### Task 7: README 与平台 spec 域名表述

**Files:**
- Modify: `README.md`
- Modify: `docs/superpowers/specs/2026-09-09-k3s-gitops-platform-design.md`（凡业务域名处改为 `*.myk8s.local`，并指向新域名 spec）

- [ ] **Step 1: 全文替换 README 中旧三主机名；补充本机 Docker insecure 与 k3s registries 操作说明**

- [ ] **Step 2: 补丁平台 design spec 域名约定，并加一行引用 `2026-09-09-myk8s-local-domains-design.md`**

- [ ] **Step 3: Commit**

```bash
git add README.md docs/superpowers/specs/2026-09-09-k3s-gitops-platform-design.md
git commit -m "$(cat <<'EOF'
docs: README 与平台 spec 对齐 *.myk8s.local

入口与 registry 主机名以域名迁移 spec 为准。
EOF
)"
```

---

### Task 8: 推送、同步集群与端到端验证

**Files:** 无新文件（操作任务）

- [ ] **Step 1: push**

```bash
git push origin HEAD
```

- [ ] **Step 2: 本机 registry / secrets**

1. Docker `daemon.json` insecure-registries 含 `harbor.myk8s.local`，reload docker  
2. `sudo cp k3s/registries.yaml /etc/rancher/k3s/registries.yaml && sudo systemctl restart k3s`  
3. `bash scripts/apply-secrets.sh`  
4. 等待节点 Ready；Argo Applications Synced  

- [ ] **Step 3: 镜像**

若 hello 仍引用旧仓库名失败：重新 `docker build/push` 到 `harbor.myk8s.local/library/hello:<tag>`，必要时更新 overlay `newTag` 后 sync。

- [ ] **Step 4: 验收**

```bash
curl -sS -o /dev/null -w "%{http_code}\n" http://harbor.myk8s.local
curl -sS http://hello.myk8s.local
curl -sS -o /dev/null -w "%{http_code}\n" http://argocd.myk8s.local
bash scripts/smoke-check.sh
kubectl -n argocd get application argocd-istio
```

Expected: smoke 全 OK；`argocd-istio` Synced/Healthy；hosts 无旧名。

---

## Spec 覆盖自检

| Spec 项 | Task |
|---------|------|
| hosts 逐条 + 删旧 | 1 |
| Harbor UI + registry 全改 | 2、3、4、6 |
| hello 域名 | 4 |
| argocd + Istio | 5 |
| 脚本 / smoke | 6 |
| 文档 | 7 |
| 本机落地与验收 | 8 |
| 不上公共 domains.yaml | 全文 |
| 无 schema / 无 Go | 全文声明 |

---

## 历史 plan 文档

`docs/superpowers/plans/2026-09-09-k3s-gitops-platform.md` 中的旧域名可保留作历史，或另开可选 chore commit 批量替换；**不阻塞**本 plan 验收。
