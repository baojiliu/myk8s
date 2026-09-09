# 本机 k3s GitOps 平台 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在本机 k3s 上落地纯 GitOps 仓：双根 Argo CD（platform / workloads）、Harbor、Sail Operator（Istio）、Argo Workflows、CloudNativePG、Altinity ClickHouse，并用 `hello` 跑通 Workflow → Harbor → Argo CD → Istio。

**Architecture:** `k3s/` 负责装机与 `~/data` 存储；`bootstrap/` 一次性装 Argo CD 并 apply `argocd/roots/`；日常真相源在 `platform/`、`workloads/`、`argocd/`（Kustomize 为主，Harbor/Workflows 用 Helm，Istio/PG/CH 用 Operator+CR）。密钥仅本机注入。

**Tech Stack:** k3s、Kustomize、Argo CD、Argo Workflows、Harbor Helm、Sail Operator、CloudNativePG、Altinity clickhouse-operator、Istio Gateway/VirtualService

**Spec:** `docs/superpowers/specs/2026-09-09-k3s-gitops-platform-design.md`

**Git repoURL（清单内一律用此，勿嵌入 token）：** `https://github.com/baojiliu/myk8s.git`

**本 plan 无 Go / 无 PolarDB schema 变更** — 各 task 跳过 `fix-golang-lint`；验证以 `kubectl` / `curl` / 脚本为准。

---

## 文件结构总览（将创建）

| 路径 | 职责 |
|------|------|
| `.gitignore` | 忽略 `secrets/local/`、IDE、密钥文件 |
| `k3s/local-path/config.json` + install 补丁步骤 | local-path → `/home/baojiliu/data` |
| `bootstrap/argocd/install.yaml` 或 install 脚本 | 首次装 Argo CD |
| `argocd/roots/*.yaml` | 双根 Application（唯一真相源） |
| `argocd/platform/*.yaml` | 平台子 Application |
| `argocd/workloads/hello.yaml` | hello Application |
| `platform/base/*` + `overlays/local` | 平台组件清单 |
| `workloads/base/hello` + `overlays/local` | 示例应用 + CI 模板 |
| `secrets/templates/*` | Secret 模板 |
| `scripts/*.sh` | hosts / secrets / bootstrap / smoke |
| `examples/hello-src/*` | 示例应用源码（供 Workflow 构建） |
| `README.md` | 使用与 smoke 说明 |

---

### Task 1: 仓库骨架与 .gitignore

**Files:**
- Create: 下列空目录占位（各放 `.gitkeep`）：`bootstrap/argocd/`、`bootstrap/root-apps/`（仅 README 说明「请 apply `argocd/roots/`，勿维护第二份」）、`argocd/roots/`、`argocd/platform/`、`argocd/workloads/`、`platform/base/`、`platform/overlays/local/`、`workloads/base/`、`workloads/overlays/local/`、`secrets/templates/`、`secrets/local/`、`scripts/`、`examples/hello-src/`
- Modify: `.gitignore`
- Modify: `README.md`（最小标题 + 指向 spec）

- [ ] **Step 1: 更新 `.gitignore`**

将 `.gitignore` 写为：

```gitignore
.claude
.cursor
.mcp.json
AGENTS.md
CLAUDE.md

# 本机密钥（永不提交）
secrets/local/
**/*.pem
**/*.key
!**/.gitkeep
```

- [ ] **Step 2: 创建目录与 `.gitkeep`**

Run:

```bash
cd /home/baojiliu/Workspace/myk8s
for d in \
  bootstrap/argocd \
  argocd/roots argocd/platform argocd/workloads \
  platform/base platform/overlays/local \
  workloads/base workloads/overlays/local \
  secrets/templates secrets/local \
  scripts examples/hello-src \
  k3s/local-path; do
  mkdir -p "$d"
  touch "$d/.gitkeep"
done
printf '%s\n' '# 不要在此维护 Application 副本。bootstrap 直接 apply ../argocd/roots/' > bootstrap/root-apps/README.md
```

Expected: 目录存在；`secrets/local/.gitkeep` 可提交，但目录内其它文件被 ignore。

- [ ] **Step 3: 写最小 README 开头**

`README.md`：

```markdown
# myk8s

本机 k3s GitOps 平台（纯清单仓）。

设计规格：`docs/superpowers/specs/2026-09-09-k3s-gitops-platform-design.md`
```

- [ ] **Step 4: Commit**（本 task 无 Go，跳过 lint）

```bash
git add .gitignore README.md bootstrap argocd platform workloads secrets scripts examples k3s/local-path
git commit -m "$(cat <<'EOF'
chore: 搭建 GitOps 仓库目录骨架

预留 platform/workloads/argocd/secrets 结构并忽略本机密钥目录。
EOF
)"
```

---

### Task 2: k3s local-path 数据目录 → `~/data`

**Files:**
- Create: `k3s/local-path/config.json`
- Create: `k3s/local-path/apply-configmap.sh`
- Modify: `k3s/install.sh`（安装后调用 apply）
- Modify: `k3s/config.yaml`（保持 disable traefik/metrics-server；可加注释说明存储由 local-path 脚本处理）

- [ ] **Step 1: 写入 local-path 配置**

`k3s/local-path/config.json`：

```json
{
  "nodePathMap": [
    {
      "node": "DEFAULT_PATH_FOR_NON_LISTED_NODES",
      "paths": ["/home/baojiliu/data"]
    }
  ]
}
```

- [ ] **Step 2: 写入 apply 脚本**

`k3s/local-path/apply-configmap.sh`：

```bash
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
USER_NAME=${SUDO_USER:-$USER}
USER_HOME=$(getent passwd "$USER_NAME" | cut -d: -f6)
DATA_DIR="${USER_HOME}/data"
mkdir -p "$DATA_DIR"
chown "$USER_NAME:$USER_NAME" "$DATA_DIR"

# k3s 自带 local-path 的 ConfigMap 名一般为 local-path-config，ns=kube-system
kubectl -n kube-system create configmap local-path-config \
  --from-file=config.json="${SCRIPT_DIR}/config.json" \
  -o yaml --dry-run=client | kubectl apply -f -

kubectl -n kube-system rollout restart deployment/local-path-provisioner
echo "[INFO] local-path -> ${DATA_DIR}"
```

chmod +x。

- [ ] **Step 3: 修改 `k3s/install.sh`**

在 `echo "[INFO] done"` 之前追加：

```bash
echo "[INFO] configure local-path -> ${USER_HOME}/data"
bash "$SCRIPT_DIR/local-path/apply-configmap.sh"
```

并在文件顶部注释说明：会卸载已有 k3s（现有行为保留）。

- [ ] **Step 4: 验证（需本机可装 k3s；若用户暂不重装，记录为手动验证项）**

Run（重装后）：

```bash
sudo bash k3s/install.sh
kubectl get nodes
kubectl -n kube-system get cm local-path-config -o yaml | grep -A2 paths
# 创建测试 PVC 后检查 /home/baojiliu/data 下是否出现子目录
```

Expected: 节点 Ready；config 含 `/home/baojiliu/data`。

- [ ] **Step 5: Commit**

```bash
git add k3s/
git commit -m "$(cat <<'EOF'
feat: 将 k3s local-path 数据目录配置到 ~/data

安装后补丁 local-path-config，并重启 provisioner。
EOF
)"
```

---

### Task 3: 密钥模板与脚本（hosts / apply-secrets）

**Files:**
- Create: `secrets/templates/harbor-admin.env.example`
- Create: `secrets/templates/postgres.env.example`
- Create: `secrets/templates/github-token.env.example`
- Create: `secrets/templates/harbor-robot.env.example`
- Create: `scripts/setup-hosts.sh`
- Create: `scripts/apply-secrets.sh`
- Create: `secrets/local/README.md`（说明复制 example → local，且该 README 可提交；真实 env 不提交）

注意：`secrets/local/README.md` 若被 `secrets/local/` ignore 挡掉，改为在 `secrets/README.md` 写说明，local 只放 env。

- [ ] **Step 1: 模板与说明**

`secrets/README.md`：

```markdown
# Secrets

1. 复制 `templates/*.env.example` 为 `local/*.env`（文件名去掉 `.example`）。
2. 填写真实值。
3. 运行 `scripts/apply-secrets.sh`。
`local/` 已在 `.gitignore` 中。
```

`secrets/templates/harbor-admin.env.example`：

```bash
HARBOR_ADMIN_PASSWORD=change-me
```

`secrets/templates/postgres.env.example`：

```bash
POSTGRES_PASSWORD=change-me
```

`secrets/templates/github-token.env.example`：

```bash
GITHUB_TOKEN=ghp_change-me
```

`secrets/templates/harbor-robot.env.example`：

```bash
HARBOR_ROBOT_NAME=robot$ci
HARBOR_ROBOT_PASSWORD=change-me
```

- [ ] **Step 2: `scripts/setup-hosts.sh`**

```bash
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
```

- [ ] **Step 3: `scripts/apply-secrets.sh`**

```bash
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
  --from-literal=password="$POSTGRES_PASSWORD" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl -n argo create secret generic github-token \
  --from-literal=token="$GITHUB_TOKEN" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl -n argo create secret generic harbor-robot \
  --from-literal=username="$HARBOR_ROBOT_NAME" \
  --from-literal=password="$HARBOR_ROBOT_PASSWORD" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "[INFO] secrets applied"
```

chmod +x 两个脚本。

- [ ] **Step 4: 本地准备（不提交）**

```bash
cp secrets/templates/*.env.example secrets/local/
# 重命名为 *.env 并填值
rename '.env.example' '.env' secrets/local/*.env.example 2>/dev/null || true
# 或手动 mv
```

- [ ] **Step 5: Commit**

```bash
git add secrets/README.md secrets/templates scripts/setup-hosts.sh scripts/apply-secrets.sh
git commit -m "$(cat <<'EOF'
feat: 增加密钥模板与 hosts/secrets 注入脚本

Git 仅保留模板；真实口令经 scripts/apply-secrets.sh 注入集群。
EOF
)"
```

---

### Task 4: Bootstrap Argo CD

**Files:**
- Create: `bootstrap/argocd/install.sh`
- Create: `scripts/bootstrap.sh`

- [ ] **Step 1: Argo CD 安装脚本**

`bootstrap/argocd/install.sh`：

```bash
#!/usr/bin/env bash
set -euo pipefail
kubectl get ns argocd >/dev/null 2>&1 || kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
echo "[INFO] waiting for argocd-server..."
kubectl -n argocd rollout status deployment/argocd-server --timeout=300s
kubectl -n argocd rollout status statefulset/argocd-application-controller --timeout=300s
echo "[INFO] initial admin password:"
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
```

- [ ] **Step 2: 总 bootstrap 脚本（先占位 roots，Task 5 补全后再跑全流程）**

`scripts/bootstrap.sh`：

```bash
#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
bash "$ROOT/scripts/setup-hosts.sh"
bash "$ROOT/scripts/apply-secrets.sh"
bash "$ROOT/bootstrap/argocd/install.sh"
kubectl apply -f "$ROOT/argocd/roots/"
echo "[INFO] bootstrap done — open https://argocd.local after Istio/Gateway ready (or port-forward now)"
echo "  kubectl -n argocd port-forward svc/argocd-server 8080:443"
```

chmod +x。

- [ ] **Step 3: 验证 Argo CD 安装（可在 Task 5 前单独跑 install.sh）**

```bash
bash bootstrap/argocd/install.sh
kubectl -n argocd get pods
```

Expected: `argocd-server` Running。

- [ ] **Step 4: Commit**

```bash
git add bootstrap/argocd/install.sh scripts/bootstrap.sh
git commit -m "$(cat <<'EOF'
feat: 增加 Argo CD bootstrap 安装脚本

一次性安装 argocd namespace 官方 manifests，供后续注册双根 Application。
EOF
)"
```

---

### Task 5: 双根 Application（platform-root / workloads-root）

**Files:**
- Create: `argocd/roots/platform-root.yaml`
- Create: `argocd/roots/workloads-root.yaml`
- Create: `argocd/platform/kustomization.yaml`（先空 resources，后续 task 追加）
- Create: `argocd/workloads/kustomization.yaml`

- [ ] **Step 1: 根 Application**

`argocd/roots/platform-root.yaml`：

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: platform-root
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: https://github.com/baojiliu/myk8s.git
    targetRevision: HEAD
    path: argocd/platform
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

`argocd/roots/workloads-root.yaml`：同结构，`name: workloads-root`，`path: argocd/workloads`。

- [ ] **Step 2: 子目录 Kustomize 聚合（初始可无 Application）**

`argocd/platform/kustomization.yaml`：

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources: []
```

`argocd/workloads/kustomization.yaml`：同上。

- [ ] **Step 3: Apply 并验证**

```bash
kubectl apply -f argocd/roots/
kubectl -n argocd get applications
```

Expected: 两个 Application 存在；此时 path 下无子 app，Synced 且资源为空属正常。

- [ ] **Step 4: Commit + push（Argo 需能拉到公开/已授权仓库）**

```bash
git add argocd/
git commit -m "$(cat <<'EOF'
feat: 注册 Argo CD platform/workloads 双根 Application

根应用指向 argocd/platform 与 argocd/workloads 作为子 Application 聚合目录。
EOF
)"
# 需要远程可读：git push（由执行者在具备凭据时执行；勿把 token 写入 remote URL）
```

**注意：** 若仓库私有，须在 `argocd` ns 配置 repository Secret（执行时用 `argocd repo add` 或手工 Secret，凭据来自 `secrets/local`，不写入 Git）。

---

### Task 6: Sail Operator + Istio 控制面

**Files:**
- Create: `platform/base/istio-operator/kustomization.yaml`（Helm 或官方 Operator 清单引用方式见步骤）
- Create: `platform/base/istio-control-plane/istiocontrolplane.yaml`
- Create: `platform/overlays/local/kustomization.yaml`（本 task 先只挂 istio；后续 task 追加）
- Create: `argocd/platform/istio-operator.yaml`
- Create: `argocd/platform/istio-control-plane.yaml`
- Modify: `argocd/platform/kustomization.yaml` resources 追加上述两个

**实现约定：** 使用 Sail Operator 官方安装文档当前稳定方式（执行时以 https://github.com/istio-ecosystem/sail-operator 为准）。推荐 Argo Application 用 Helm chart 装 Operator，再用第二 Application 同步 `Istio` CR。

- [ ] **Step 1: Operator Application（Helm）**

`argocd/platform/istio-operator.yaml`：

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: istio-operator
  namespace: argocd
spec:
  project: default
  source:
    # 执行时核对 Sail Operator 官方 chart 仓库 URL 与 chart 名
    repoURL: https://github.com/istio-ecosystem/sail-operator
    path: chart
    targetRevision: HEAD
  destination:
    server: https://kubernetes.default.svc
    namespace: istio-operator
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

若官方改为 Helm repo，将 `source` 改为 `chart` + `helm` 字段（执行时按官方 README 校正，禁止猜测错误 URL 后强行结束）。

- [ ] **Step 2: 控制面 CR**

`platform/base/istio-control-plane/istiocontrolplane.yaml`（字段名以 Sail Operator CRD 为准，示意）：

```yaml
apiVersion: sailoperator.io/v1
kind: Istio
metadata:
  name: default
  namespace: istio-system
spec:
  namespace: istio-system
  updateStrategy:
    type: InPlace
  values:
    profile: ambient
    # 若 ambient 在本机有问题，改为 profile: default（sidecar）
```

`platform/base/istio-control-plane/kustomization.yaml`：

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: istio-system
resources:
  - istiocontrolplane.yaml
```

`argocd/platform/istio-control-plane.yaml`：path `platform/base/istio-control-plane`，destination `istio-system`，`syncOptions` 含 `ServerSideApply=true`；可加注解 `argocd.argoproj.io/sync-wave: "10"`，Operator 用 wave `"0"`。

- [ ] **Step 3: 更新 `argocd/platform/kustomization.yaml`**

```yaml
resources:
  - istio-operator.yaml
  - istio-control-plane.yaml
```

- [ ] **Step 4: Sync 验证**

```bash
kubectl -n argocd wait --for=jsonpath='{.status.health.status}'=Healthy application/istio-operator --timeout=300s
kubectl -n istio-system get pods
kubectl get istio -A
```

Expected: 控制面 Pod Ready。

- [ ] **Step 5: Commit**

```bash
git add platform/base/istio-operator platform/base/istio-control-plane argocd/platform
git commit -m "$(cat <<'EOF'
feat: 接入 Sail Operator 与 Istio 控制面 Application

Operator 与 Istio CR 拆分 Application，避免 CRD 未就绪导致同步失败。
EOF
)"
```

---

### Task 7: Harbor（Helm）+ 本机 Gateway 占位

**Files:**
- Create: `platform/base/harbor/values-local.yaml`
- Create: `platform/base/harbor/kustomization.yaml`（仅文档/补丁；主安装走 Argo Helm）
- Create: `platform/base/harbor/istio-gateway.yaml`（Gateway + VirtualService → harbor.local）
- Create: `argocd/platform/harbor.yaml`
- Modify: `argocd/platform/kustomization.yaml`

- [ ] **Step 1: Harbor Application**

`argocd/platform/harbor.yaml`：

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: harbor
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "20"
spec:
  project: default
  sources:
    - repoURL: https://helm.goharbor.io
      chart: harbor
      targetRevision: 1.16.0
      helm:
        valueFiles:
          - $values/platform/base/harbor/values-local.yaml
    - repoURL: https://github.com/baojiliu/myk8s.git
      targetRevision: HEAD
      ref: values
    - repoURL: https://github.com/baojiliu/myk8s.git
      targetRevision: HEAD
      path: platform/base/harbor
      directory:
        include: "istio-gateway.yaml"
  destination:
    server: https://kubernetes.default.svc
    namespace: harbor
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

若多 source 版本的 Argo CD 不支持上述写法，拆成 `harbor`（纯 Helm）+ `harbor-istio`（Kustomize）两个 Application。

- [ ] **Step 2: `values-local.yaml` 关键项**

```yaml
expose:
  type: clusterIP
  tls:
    enabled: false
externalURL: http://harbor.local
persistence:
  enabled: true
  resourcePolicy: "keep"
  persistentVolumeClaim:
    registry:
      storageClass: local-path
    jobservice:
      jobLog:
        storageClass: local-path
    database:
      storageClass: local-path
    redis:
      storageClass: local-path
    trivy:
      storageClass: local-path
harborAdminPassword: "OVERRIDE_VIA_SECRET"
# 执行时改为 existingSecret 引用 harbor-admin，或安装后立刻改密；禁止把真实密码写入 Git
```

具体 `existingSecret` 字段以所用 chart 版本文档为准，与 Task 3 的 Secret 对齐。

- [ ] **Step 3: Istio 路由**

`platform/base/harbor/istio-gateway.yaml`：按集群中实际 Gateway API / Istio networking 选用。若用经典 Istio：

```yaml
apiVersion: networking.istio.io/v1
kind: Gateway
metadata:
  name: harbor-gw
  namespace: harbor
spec:
  selector:
    istio: ingressgateway
  servers:
    - port:
        number: 80
        name: http
        protocol: HTTP
      hosts:
        - harbor.local
---
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: harbor-vs
  namespace: harbor
spec:
  hosts:
    - harbor.local
  gateways:
    - harbor-gw
  http:
    - route:
        - destination:
            host: harbor-portal
            port:
              number: 80
```

（服务名以 Helm 实际生成名为准，sync 后 `kubectl -n harbor get svc` 校正。）

- [ ] **Step 4: 验证**

```bash
kubectl -n harbor get pods
curl -sS -o /dev/null -w "%{http_code}\n" http://harbor.local
# 或 port-forward 若 Gateway 尚未对外
```

Expected: 核心 Pod Running；HTTP 非 000。

- [ ] **Step 5: Commit**

```bash
git add platform/base/harbor argocd/platform
git commit -m "$(cat <<'EOF'
feat: 增加 Harbor Helm Application 与 Istio 路由清单

本地 values 使用 local-path，并通过 harbor.local 暴露。
EOF
)"
```

---

### Task 8: Argo Workflows

**Files:**
- Create: `platform/base/argo-workflows/values-local.yaml`
- Create: `argocd/platform/argo-workflows.yaml`
- Modify: `argocd/platform/kustomization.yaml`

- [ ] **Step 1: Application**

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: argo-workflows
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "20"
spec:
  project: default
  source:
    repoURL: https://github.com/argoproj/argo-helm
    path: charts/argo-workflows
    targetRevision: argo-workflows-0.45.0
    helm:
      valueFiles: []
      values: |
        server:
          extraArgs:
            - --auth-mode=server
        workflow:
          serviceAccount:
            create: true
            name: operate-workflow-sa
        singleNamespace: false
  destination:
    server: https://kubernetes.default.svc
    namespace: argo
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

`targetRevision` 执行时改为当时稳定 chart 版本（`helm search repo` 或 Git tag）。

- [ ] **Step 2: 验证**

```bash
kubectl -n argo get pods
kubectl -n argo get sa
```

Expected: workflow-controller Running。

- [ ] **Step 3: Commit**

```bash
git add platform/base/argo-workflows argocd/platform/argo-workflows.yaml argocd/platform/kustomization.yaml
git commit -m "$(cat <<'EOF'
feat: 接入 Argo Workflows 作为集群内 CI 引擎

经 Argo CD Helm 源安装到 argo namespace。
EOF
)"
```

---

### Task 9: CloudNativePG Operator + Cluster

**Files:**
- Create: `platform/base/cloudnative-pg-operator/`（可空，主用 Helm Application）
- Create: `platform/base/cloudnative-pg-cluster/cluster.yaml`
- Create: `platform/base/cloudnative-pg-cluster/kustomization.yaml`
- Create: `argocd/platform/cloudnative-pg-operator.yaml`
- Create: `argocd/platform/cloudnative-pg-cluster.yaml`
- Modify: `argocd/platform/kustomization.yaml`

- [ ] **Step 1: Operator Application**

使用官方 Helm：`https://cloudnative-pg.github.io/charts` chart `cloudnative-pg`，destination `cnpg-system`，sync-wave `"0"`。

- [ ] **Step 2: Cluster CR**

`platform/base/cloudnative-pg-cluster/cluster.yaml`：

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: postgres
  namespace: postgres
spec:
  instances: 1
  storage:
    size: 10Gi
    storageClass: local-path
  bootstrap:
    initdb:
      database: app
      owner: app
      secret:
        name: postgres-app
```

（Secret 键名须符合 CNPG 要求：通常含 `username`/`password`；若与 Task 3 不一致，同步修改 `apply-secrets.sh` 生成 `username=app` + `password=...`。）

- [ ] **Step 3: 验证**

```bash
kubectl -n cnpg-system get pods
kubectl -n postgres get cluster
kubectl -n postgres get pods
```

Expected: `Cluster` Ready；主键 Pod Running；`~/data` 下有对应目录。

- [ ] **Step 4: Commit**

```bash
git add platform/base/cloudnative-pg-operator platform/base/cloudnative-pg-cluster argocd/platform
git commit -m "$(cat <<'EOF'
feat: 接入 CloudNativePG Operator 与单实例 Cluster

Operator 与 Cluster CR 分 Application，存储使用 local-path。
EOF
)"
```

---

### Task 10: Altinity ClickHouse Operator + 实例

**Files:**
- Create: `platform/base/clickhouse-operator/`（Application 指向官方 manifest 或 Helm）
- Create: `platform/base/clickhouse-cluster/clickhouse-installation.yaml`
- Create: `argocd/platform/clickhouse-operator.yaml`
- Create: `argocd/platform/clickhouse-cluster.yaml`
- Modify: `argocd/platform/kustomization.yaml`

- [ ] **Step 1: Operator**

Application 同步 Altinity 官方发布的 operator manifest（执行时用官方 README 的 raw URL 或 Git path），namespace `clickhouse-operator`，sync-wave `"0"`。

- [ ] **Step 2: ClickHouseInstallation**

最小单副本示意（字段以当前 CRD 为准）：

```yaml
apiVersion: clickhouse.altinity.com/v1
kind: ClickHouseInstallation
metadata:
  name: ch
  namespace: clickhouse
spec:
  configuration:
    clusters:
      - name: default
        layout:
          shardsCount: 1
          replicasCount: 1
  defaults:
    templates:
      dataVolumeClaimTemplate: data
  templates:
    volumeClaimTemplates:
      - name: data
        spec:
          storageClassName: local-path
          accessModes:
            - ReadWriteOnce
          resources:
            requests:
              storage: 10Gi
```

- [ ] **Step 3: 验证**

```bash
kubectl -n clickhouse-operator get pods
kubectl -n clickhouse get chi
kubectl -n clickhouse get pods
```

Expected: CHI Completed/Running。

- [ ] **Step 4: Commit**

```bash
git add platform/base/clickhouse-operator platform/base/clickhouse-cluster argocd/platform
git commit -m "$(cat <<'EOF'
feat: 接入 Altinity ClickHouse Operator 与单分片实例

CR 使用 local-path PVC，经独立 Application 同步。
EOF
)"
```

---

### Task 11: 示例应用 hello（清单 + 源码 + Workflow）

**Files:**
- Create: `examples/hello-src/Dockerfile`
- Create: `examples/hello-src/main.go`（或静态 `index.html` + nginx Dockerfile；优先极简静态以免本仓引入 Go module 义务——**推荐静态**）
- Create: `workloads/base/hello/deployment.yaml`
- Create: `workloads/base/hello/service.yaml`
- Create: `workloads/base/hello/kustomization.yaml`
- Create: `workloads/base/hello/istio/gateway.yaml`
- Create: `workloads/base/hello/ci/workflow-template.yaml`
- Create: `workloads/overlays/local/kustomization.yaml`
- Create: `workloads/overlays/local/image-tag.yaml`
- Create: `argocd/workloads/hello.yaml`
- Modify: `argocd/workloads/kustomization.yaml`

- [ ] **Step 1: 示例源码（静态）**

`examples/hello-src/index.html`：

```html
<!doctype html><title>hello</title><h1>hello from myk8s</h1>
```

`examples/hello-src/Dockerfile`：

```dockerfile
FROM nginx:1.27-alpine
COPY index.html /usr/share/nginx/html/index.html
```

- [ ] **Step 2: Kustomize 工作负载**

`workloads/base/hello/deployment.yaml`：replicas=1，container port 80，image 占位 `harbor.local/library/hello:latest`。

`workloads/base/hello/service.yaml`：ClusterIP 80。

`workloads/base/hello/istio/gateway.yaml`：hosts `hello.local` → `hello` svc。

`workloads/base/hello/kustomization.yaml`：resources 含上述文件 + `ci/workflow-template.yaml`。

`workloads/overlays/local/kustomization.yaml`：

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: apps
resources:
  - ../../base/hello
images:
  - name: harbor.local/library/hello
    newTag: latest
```

可用 `images:` 代替单独 `image-tag.yaml`；若用独立文件，用 JSON patch 改 tag。

- [ ] **Step 3: WorkflowTemplate（手动可跑）**

`workloads/base/hello/ci/workflow-template.yaml`：定义模板名 `build-hello`：

1. 使用 `docker:dind` 或集群已有 buildah；本机 k3s 推荐 `kaniko` 向 `harbor.local` 推送（insecure registry 参数打开）。
2. context：从 `https://github.com/baojiliu/myk8s.git` 的 `examples/hello-src`。
3. 推送 `harbor.local/library/hello:<workflow-uid>`。
4. 用 `git-commit` 容器改 `workloads/overlays/local/kustomization.yaml` 的 `newTag` 并 push（需 `github-token` Secret 挂载）。

完整 kaniko + git-commit YAML 在实现时写满（禁止只写注释占位）；若首期 git-commit 权限未通，允许降级步骤：「Workflow 只 build+push，人工改 newTag」——但须在 README 写明，且 smoke 仍要最终能改 tag 一次。

- [ ] **Step 4: Application**

`argocd/workloads/hello.yaml`：path `workloads/overlays/local`，destination namespace `apps`。

- [ ] **Step 5: 验证 CD（可先用临时 tag）**

```bash
# 本地先手动 build push 一次（若 Workflow 未就绪）
# docker build -t harbor.local/library/hello:dev examples/hello-src && docker push ...
kubectl -n argocd get application hello
curl -sS http://hello.local
```

Expected: 页面含 `hello from myk8s`。

- [ ] **Step 6: Commit**

```bash
git add examples/hello-src workloads argocd/workloads
git commit -m "$(cat <<'EOF'
feat: 增加 hello 示例应用清单与构建 Workflow 模板

用于验证 Harbor 镜像与 Argo CD/Istio 发布闭环。
EOF
)"
```

---

### Task 12: Smoke 脚本与 README 收尾

**Files:**
- Create: `scripts/smoke-check.sh`
- Modify: `README.md`

- [ ] **Step 1: smoke-check.sh**

```bash
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
check "hello http" "curl -fsS -o /dev/null http://hello.local"
exit "$fail"
```

- [ ] **Step 2: README 补充**

写入：前置条件、`k3s/install.sh` → 填 `secrets/local` → `scripts/bootstrap.sh` → push 本仓 → smoke；并警告：**不要把 GitHub token 写进 git remote URL**。

- [ ] **Step 3: 跑 smoke**

```bash
bash scripts/smoke-check.sh
```

Expected: 全 OK；失败则按输出修对应 Task。

- [ ] **Step 4: Commit**

```bash
git add scripts/smoke-check.sh README.md
git commit -m "$(cat <<'EOF'
docs: 补充安装步骤与 smoke-check 脚本

覆盖节点、平台组件与 hello.local 探活检查。
EOF
)"
```

---

### Task 13: 端到端验收（无新功能，只验证）

- [ ] **Step 1: 按顺序确认**

1. `~/data` 下有 PVC 目录  
2. `platform-root` / `workloads-root` Healthy  
3. 手动或 Workflow 构建 hello → Harbor 可见镜像  
4. overlay `newTag` 更新后 Argo sync  
5. `curl http://hello.local` 成功  
6. `git status` 无 `secrets/local/*.env`

- [ ] **Step 2: 在 PR/笔记勾选 spec「成功标准」三条**

无 commit 要求；若有文档勘误可小提交 `docs: 修正 ...`。

---

## Spec 覆盖自检

| Spec 项 | Task |
|---------|------|
| k3s + ~/data | 2 |
| 目录结构 | 1 |
| 密钥模板/本机注入 | 3 |
| Argo CD bootstrap + 双根 | 4–5 |
| Sail Operator + Istio | 6 |
| Harbor | 7 |
| Argo Workflows | 8 |
| CNPG | 9 |
| ClickHouse Altinity | 10 |
| hello 闭环 | 11、13 |
| smoke / README | 12 |
| 不涉及 schema / Go | 全文声明 |

## Placeholder / 版本说明

计划中 Helm `targetRevision`、Sail/CNPG/Altinity 的 **精确 chart 版本与 CRD 字段** 须在执行当日按官方文档钉死并写入清单（允许在实现 commit 中更新版本号）。不允许留下 “TBD” 文件内容；若某官方 URL 变更，在该 task 内改对后再 commit。
