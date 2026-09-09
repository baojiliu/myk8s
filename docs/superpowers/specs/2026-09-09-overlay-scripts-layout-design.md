# Overlay 分层与 scripts 重组设计

日期：2026-09-09  
状态：已批准（brainstorming）  
关联：`docs/superpowers/specs/2026-09-09-myk8s-local-domains-design.md`、`docs/superpowers/specs/2026-09-09-k3s-gitops-platform-design.md`

## 1. 背景与目标

当前域名、`StorageClass`、Harbor registry 主机名等本机专属值写在 `platform/base` / `workloads/base`，不利于日后增加 `cloud` 等环境。`k3s/` 与 `scripts/` 并列，本机运维入口分散。

**目标：**

1. **环境相关配置只进 overlays**；base 仅结构 + **全大写假值**。
2. **按组件**建立 `platform/overlays/local/<component>`；Argo Application `path` 指向 overlay。
3. **密钥**改为 `secrets/overlays/<env>/`；`apply-secrets.sh` 支持多 overlay，未指定时交互选择。
4. **根目录 `k3s/` 迁入 `scripts/k3s/`**，并梳理 `scripts/` 子目录。

本需求不涉及数据库 schema 变更。  
本需求不涉及 Go 代码变更。

## 2. 非目标（本期不做）

- PVC 容量、副本数、TLS/expose、Ingress Service type、Workflow `--insecure` 等其它旋钮抽到 overlay（可后续再做）
- 创建真实 `overlays/cloud` 内容（仅预留同构目录约定）
- 把真实密钥写入 Kustomize YAML
- 命名空间重命名
- 公共 `domains.yaml` / replacements 中心配置（假值 + 每 overlay patch）

## 3. 决策记录

| 项 | 选择 |
|----|------|
| 迁入 overlay 范围 | 域名 / registry 主机名 / StorageClass（及明显本机域名注释） |
| base 假值 | 全大写，如 `CHANGE_ME_HOST`、`CHANGE_ME_REGISTRY`、`CHANGE_ME_STORAGECLASS` |
| 平台 overlay 粒度 | 每组件 `platform/overlays/local/<component>/` |
| Argo path | 指向对应 overlay（非 base） |
| 密钥布局 | `secrets/templates` + `secrets/overlays/<env>/`（gitignore） |
| apply-secrets | `apply-secrets.sh [overlay]`；无参则列出 `secrets/overlays/*` 交互选择 |
| harbor-pull server | 从选定 overlay 的配置读取（如 `registry.env`），禁止写死 |
| 脚本目录 | 见 §4.3；原根 `k3s/` 删除 |

## 4. 架构

### 4.1 Base vs Overlay

```text
platform/base/<component>/              # 结构 + CHANGE_ME_*
platform/overlays/local/<component>/    # resources → ../../../base/<component> + patches
workloads/base/hello/                   # 结构 + CHANGE_ME_*
workloads/overlays/local/               # 已有；补域名/registry/StorageClass 相关 patch
```

假值示例：

| 用途 | base 假值 | local 真值（例） |
|------|-----------|------------------|
| Host / URL host | `CHANGE_ME_HOST` | `harbor.myk8s.local` 等 |
| 完整 URL | `http://CHANGE_ME_HOST` | `http://harbor.myk8s.local` |
| 镜像仓库 | `CHANGE_ME_REGISTRY` | `harbor.myk8s.local` |
| StorageClass | `CHANGE_ME_STORAGECLASS` | `local-path` |

### 4.2 须迁的平台 / 工作负载组件

| Overlay 路径 | 主要 patch |
|--------------|-----------|
| `platform/overlays/local/harbor` | `externalURL`、PVC storageClass、Istio hosts |
| `platform/overlays/local/argocd-istio` | Gateway/VS hosts |
| `platform/overlays/local/cloudnative-pg-cluster` | `storage.storageClass` |
| `platform/overlays/local/clickhouse-cluster` | `storageClassName` |
| `platform/overlays/local/istio-ingress` | 注释中的本机域名（可选） |
| `workloads/overlays/local` | hello hosts、image registry、workflow registry/insecure-registry 主机名 |

Helm 的 Harbor：Application 的 values 文件改为引用 **overlay 目录内** 的 values（或 base 假值 values + overlay 覆盖文件）；不得把本机真值留在 `platform/base/harbor/values-local.yaml` 文件名暗示的「真 local」内容中——建议 base 改为 `values.yaml`（假值），overlay 提供 `values-local.yaml` 或等价 patch。

### 4.3 Secrets

```text
secrets/
  templates/                 # *.env.example（可提交）
  overlays/
    local/                   # 真值，gitignore（由原 secrets/local 迁入）
      *.env
      registry.env           # 至少含 HARBOR_REGISTRY=...
```

- `.gitignore`：忽略 `secrets/overlays/*/` 下真值，保留 `templates` 与必要 `.gitkeep`。
- `scripts/secrets/apply-secrets.sh [overlay]`：
  - 有参：使用 `secrets/overlays/<overlay>/`
  - 无参：列出可用 overlay 目录，交互选择编号/名称
  - 缺必需 `.env` 则报错退出
  - `harbor-pull` 的 `--docker-server` 使用该 overlay 的 `HARBOR_REGISTRY`

### 4.4 Scripts 目录

```text
scripts/
  bootstrap.sh                 # 调用 hosts + secrets（secrets 需 overlay 选择）
  k3s/                         # 原根目录 k3s/ 整棵迁入
    install.sh
    config.yaml
    registries.yaml
    local-path/
  hosts/
    setup-hosts.sh
  secrets/
    apply-secrets.sh
  smoke/
    smoke-check.sh
```

删除仓库根目录 `k3s/`。README、bootstrap、文档中所有路径更新为 `scripts/...`。

## 5. 验证与回滚

### 5.1 成功标准

1. base 中无业务用的 `*.myk8s.local` / `local-path`（仅允许 `CHANGE_ME_*` 或文档字符串说明假值约定）。
2. Argo path 指向 overlays；sync 后集群行为与现网一致（域名与存储不变）。
3. `secrets/overlays/local` 可用；无参运行 apply-secrets 出现交互列表。
4. `bash scripts/k3s/install.sh` 路径在文档中正确；无残留根 `k3s/` 引用（历史 plan 可保留或顺手改）。
5. `bash scripts/smoke/smoke-check.sh` 全 OK。

### 5.2 回滚

Git revert。本机若已搬家密钥目录，保留 `secrets/overlays/local` 或按需拷贝。

## 6. 与既有 spec 关系

域名真值约定仍以 `2026-09-09-myk8s-local-domains-design.md` 为准；本文件规定 **放置位置**（overlay）与 **脚本/密钥布局**。实现后更新 README 与平台 design 中的路径表述。
