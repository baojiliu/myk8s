# 本机 k3s GitOps 平台设计

日期：2026-09-09  
状态：已批准（brainstorming）  
仓库角色：纯平台 / GitOps 仓（应用源码在独立 GitHub 仓库）

## 1. 背景与目标

在本机单节点 k3s 上构建可重复的基础设施与 CI/CD：

- 集群：k3s；`local-path-provisioner` 数据目录为 `~/data`
- CD：Argo CD；应用代码托管在 GitHub
- CI：Argo Workflows（可加 Argo Events）；与 Argo CD 同属本项目
- 三方组件：Harbor、Istio（Operator）、PostgreSQL（CloudNativePG Operator）、ClickHouse（Operator）
- 清单管理：以 Kustomize 为主；按组件混用 Helm / Operator
- 环境：目录预留多环境；首期只落地 `local`
- 入口：Istio；本机 hosts 使用 `*.myk8s.local`（如 `harbor.myk8s.local`、`argocd.myk8s.local`、`hello.myk8s.local`）。域名约定见 [本机域名设计](2026-09-09-myk8s-local-domains-design.md)。
- 密钥：Git 仅模板；真实值本机注入（不进 Git）

本需求不涉及数据库 schema 变更。  
本需求不涉及 Go 代码变更。

## 2. 非目标（首期不做）

- 多集群、生产级 HA
- 公网 TLS 自动签发（cert-manager 等）
- 将应用源码放入本仓（仅可有 `examples/` 演示说明或指针）
- MySQL、监控栈（Prometheus/Grafana）等未列入首期的组件
- 应用层单元测试覆盖率要求（本仓为 infra/GitOps）

## 3. 整体架构与数据流

### 3.1 逻辑分层

1. **主机层**：k3s；local-path → `~/data`；禁用自带 Traefik（入口交给 Istio）。
2. **入口层**：Istio 经 **Sail Operator** 安装控制面（首期固定此 Operator，不混用 istioctl 安装控制面）；业务 `Gateway` / `VirtualService` 由本仓 Kustomize 管理。
3. **平台层**：由 Argo CD `platform-root` 管理——Istio Operator + 控制面 CR、Harbor、Argo Workflows、CloudNativePG Operator + Cluster CR、ClickHouse Operator + 实例 CR。
4. **工作负载层**：由 Argo CD `workloads-root` 管理——示例应用 `hello` 及 CI Workflow 模板。
5. **密钥层**：`secrets/templates`（Git）+ `secrets/overlays/<env>`（gitignore）+ `scripts/secrets/apply-secrets.sh`。

### 3.2 主链路

```text
开发者 push → GitHub（应用源码仓）
  → Argo Events / 手动 Workflow
  → Argo Workflows：checkout → build → push harbor.myk8s.local/<project>/...
  → 更新本仓 workloads overlay 中的镜像 tag
  → Argo CD sync → Pod 从 Harbor 拉镜像 → Istio 暴露 *.myk8s.local
```

### 3.3 Bootstrap 顺序（一次性）

1. `scripts/k3s/install.sh`（含 local-path → `~/data`）
2. 注入 secrets
3. 安装 Argo CD（`bootstrap/`）
4. 注册 `platform-root`、`workloads-root`
5. platform 组件就绪后，跑通 `hello` 闭环

## 4. 目录结构

采用方案 A：`platform/` + `workloads/` + `bootstrap/`。

```text
myk8s/
├── README.md
├── .gitignore
├── bootstrap/
│   ├── argocd/
│   └── root-apps/
│       ├── platform-root.yaml
│       └── workloads-root.yaml
├── argocd/
│   ├── roots/
│   │   ├── platform-root.yaml
│   │   └── workloads-root.yaml
│   ├── platform/
│   │   ├── istio-operator.yaml
│   │   ├── istio-control-plane.yaml
│   │   ├── harbor.yaml
│   │   ├── argo-workflows.yaml
│   │   ├── cloudnative-pg-operator.yaml
│   │   ├── cloudnative-pg-cluster.yaml
│   │   ├── clickhouse-operator.yaml
│   │   └── clickhouse-cluster.yaml
│   └── workloads/
│       └── hello.yaml
├── platform/
│   ├── base/
│   │   ├── istio-operator/
│   │   ├── istio-control-plane/
│   │   ├── harbor/
│   │   ├── argo-workflows/
│   │   ├── cloudnative-pg-operator/
│   │   ├── cloudnative-pg-cluster/
│   │   ├── clickhouse-operator/
│   │   └── clickhouse-cluster/
│   └── overlays/
│       └── local/
├── workloads/
│   ├── base/
│   │   └── hello/
│   │       ├── kustomization.yaml
│   │       ├── deployment.yaml
│   │       ├── service.yaml
│   │       ├── istio/
│   │       └── ci/
│   └── overlays/
│       └── local/
│           ├── kustomization.yaml
│           └── image-tag.yaml
├── secrets/
│   ├── templates/
│   └── overlays/
│       └── local/             # gitignore
├── scripts/
│   ├── bootstrap.sh
│   ├── k3s/                   # install、config、local-path、registries
│   ├── hosts/
│   │   └── setup-hosts.sh
│   ├── secrets/
│   │   └── apply-secrets.sh
│   └── smoke/
│       └── smoke-check.sh
├── examples/
│   └── hello-src/             # 可选：演示说明 / 外仓指针
└── docs/
    └── superpowers/specs/
```

### 4.1 路径约定

| 路径 | 职责 |
|------|------|
| `scripts/k3s/` | 安装集群与存储路径 |
| `bootstrap/` | 仅首次：安装 Argo CD，并 `kubectl apply` 双根 Application |
| `argocd/` | Application 定义的**唯一真相源**；`bootstrap/root-apps` 与之保持同内容或改为直接 apply `argocd/roots/`（实现时二选一，禁止长期双份漂移） |
| `platform/base` + `overlays` | 平台组件真相源 |
| `workloads/*` | 自研应用真相源 |
| `secrets/templates` vs `overlays/<env>` | 模板进 Git；真值本机注入 |

多环境扩展：新增 `platform/overlays/<env>`、`workloads/overlays/<env>` 及对应 Application，不改 base 契约。

## 5. 组件落地与命名空间

| 组件 | 安装形态 | 本仓管理内容 | Namespace |
|------|----------|--------------|-----------|
| Sail Operator（Istio） | Operator | Operator 部署 + 控制面 CR | `istio-operator`；控制面 `istio-system` |
| Istio 业务路由 | Kustomize | Gateway / VirtualService 等 | 应用 ns 或 `istio-ingress` |
| Harbor | 官方 Helm + values | values、Gateway 补丁、PVC | `harbor` |
| Argo CD | bootstrap 先装，再可选自管理 | 根/子 Application | `argocd` |
| Argo Workflows（+ 建议 Events） | Helm | values、RBAC、Secret 引用 | `argo` |
| CloudNativePG | Operator + Cluster CR | Operator + Cluster | `cnpg-system` / `postgres` |
| ClickHouse | **Altinity** clickhouse-operator + CR | Operator + `ClickHouseInstallation`（或等价 CR） | `clickhouse-operator` / `clickhouse` |
| hello | Kustomize + WorkflowTemplate | Deploy/Svc/Istio + CI | `apps` |

### 5.1 存储与镜像

- StorageClass：k3s `local-path`；根目录 `~/data`。
- PVC 命名带组件前缀（如 `harbor-registry`）。
- 镜像前缀：`harbor.myk8s.local/...`；local overlay 统一拉取地址。
- 首期允许 Harbor HTTP/insecure，并在文档与节点/containerd 配置中写明。

### 5.2 权限边界

- `platform-root`：可写平台 ns 与 CRD。
- `workloads-root`：默认仅写 `apps` 及该应用所需 Istio 资源；不可改 harbor/postgres 等平台 ns。

### 5.3 Operator / Helm 混用原则

- Istio、PostgreSQL、ClickHouse：**Operator + CR**；CR 与业务侧资源用 Kustomize。
- Harbor、Argo Workflows：**Helm + values**，必要时 Kustomize 补丁。
- 自研应用：**纯 Kustomize**。
- Operator 与其实例 CR **拆成两个 Application**，避免 CRD 未就绪导致 sync 失败。

## 6. CI/CD、密钥与失败处理

### 6.1 CD（Argo CD）

- 双根：`platform-root` → `argocd/platform/*`；`workloads-root` → `argocd/workloads/*`。
- 首期 sync：`automated` + `prune: true`（local）；危险资源按需加 sync-options。
- 子 Application 的 `source.path` 指向对应 `overlays/local`（Helm 则 path + valueFiles）。

### 6.2 CI（Argo Workflows）——hello 样板

1. 触发：GitHub webhook（Argo Events）或手动 Workflow；首期至少支持手动。
2. 步骤：clone 应用仓 → build → push `harbor.myk8s.local/.../hello:<git-sha>` → 更新本仓 `workloads/overlays/local/image-tag.yaml`。
3. Argo CD 侦测本仓变更后 sync `hello`。
4. Workflow 通过 ServiceAccount 引用本机注入的 `github-token`、`harbor-robot`；清单中无明文 token。

### 6.3 密钥

- Git：`secrets/templates/*.yaml`（结构说明 / 占位）。
- 本机：`secrets/overlays/<env>/`（gitignore）。
- `scripts/secrets/apply-secrets.sh [overlay]` 渲染并 apply；`bootstrap.sh` 传入 `local` 非交互执行。
- 轮换：改本机文件 → 重跑脚本 → 按需重启依赖 Pod。

### 6.4 失败处理

| 阶段 | 原则 |
|------|------|
| Bootstrap 失败 | 不进入 GitOps 循环；修 bootstrap 后重跑 |
| Operator/CRD | 先 sync Operator，再 sync 实例 CR |
| Workflow 失败 | 不更新 image-tag；不触发错误部署 |
| ImagePullBackOff | 查 Harbor 项目/凭据/insecure；非必要不自动乱回滚 |
| PVC Pending | 查 local-path 与 `~/data` 权限/磁盘 |

## 7. 验证方式

1. **集群基线**：节点 Ready；PV 落在 `~/data`；无 Traefik。
2. **平台就绪**：Istio 控制面、Harbor、Argo CD、Workflows、CNPG Cluster、ClickHouse 均可探活。
3. **GitOps**：双根 Healthy+Synced；改清单可反映到集群。
4. **E2E**：Workflow → Harbor 镜像 → image-tag 更新 → Argo CD sync → `hello.myk8s.local` 预期响应。
5. **密钥**：`git status` 无 Secret 明文。

交付：README / docs 中的 Smoke checklist；可选 `scripts/smoke/smoke-check.sh`。

### 成功标准（首期 Done）

- 目录按第 4 节落地，双根 Application 可运行。
- 第 5 节组件全部装齐并可探活。
- `hello` 至少一次跑通「Workflow → Harbor → Argo CD → Istio」。

## 8. 决策记录

| 项 | 选择 |
|----|------|
| 仓库定位 | 纯平台 / GitOps（A） |
| 环境 | 预留多环境，首期仅 local（C） |
| 入口 | Istio + **Sail Operator**（固定） |
| CI/CD | Argo Workflows + Argo CD |
| 数据层 | PostgreSQL（CloudNativePG）+ ClickHouse（**Altinity** operator），均为 Operator |
| 镜像仓库 | 自建 Harbor |
| GitOps 根 | platform 与 workloads 双根（C） |
| Helm 策略 | 按组件混用（D）；有状态 DB/Istio 用 Operator |
| 域名 | `*.myk8s.local` + hosts（A）；详见 [本机域名设计](2026-09-09-myk8s-local-domains-design.md) |
| 密钥 | 模板进 Git，真值本机注入（B） |
| 示例应用 | 需要 hello 验证闭环（A） |
| 目录方案 | platform + workloads + bootstrap（A） |
