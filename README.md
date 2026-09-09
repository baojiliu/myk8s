# myk8s

本机单节点 **k3s GitOps 平台**清单仓。本仓库只维护基础设施与应用部署清单（Kustomize / Argo CD Application），**不包含**业务应用源码；应用代码在独立 GitHub 仓库，由 Argo Workflows 构建并推送镜像。

## 文档

| 文档 | 说明 |
|------|------|
| [设计规格](docs/superpowers/specs/2026-09-09-k3s-gitops-platform-design.md) | 架构、组件选型、目录约定 |
| [实施计划](docs/superpowers/plans/2026-09-09-k3s-gitops-platform.md) | 分 Task 落地步骤与验收标准 |

## 前置条件

- **Linux 主机**（首期面向本机开发环境）
- **k3s** 将通过 `k3s/install.sh` 安装（脚本会禁用自带 Traefik，入口交给 Istio）
- **kubectl** 可用（安装脚本会写入 `~/.kube/config`）
- **磁盘**：`local-path-provisioner` 数据目录为 `~/data`，请确保该路径所在分区有足够空间
- **网络**：可拉取 k3s、Helm chart、容器镜像；可访问 GitHub（清单与应用源码）
- **/etc/hosts**：`scripts/setup-hosts.sh` 会写入 `harbor.local`、`argocd.local`、`hello.local`（指向 `127.0.0.1`）

## 快速开始

按以下顺序执行（一次性 bootstrap + 持续 GitOps）：

### 1. 安装 k3s

```bash
bash k3s/install.sh
```

配置 local-path 使用 `~/data`，并禁用 k3s 自带 Traefik。

### 2. 准备本机密钥

复制模板并填写真实值（详见 [secrets/README.md](secrets/README.md)）：

```bash
cp secrets/templates/harbor-admin.env.example   secrets/local/harbor-admin.env
cp secrets/templates/postgres.env.example       secrets/local/postgres.env
cp secrets/templates/github-token.env.example   secrets/local/github-token.env
cp secrets/templates/harbor-robot.env.example   secrets/local/harbor-robot.env
# 编辑 secrets/local/*.env
```

`secrets/local/` 已在 `.gitignore` 中，**切勿**将真实密钥提交到 Git。

### 3. Bootstrap 集群侧组件

```bash
bash scripts/bootstrap.sh
```

依次：写入 hosts → 注入 Secrets → 安装 Argo CD → apply `argocd/roots/`（注册 `platform-root` 与 `workloads-root`）。

### 4. Push 本仓，让 Argo CD 拉取清单

Argo CD Application 指向本仓库 URL。将当前分支（如 `main` 或功能分支）**push 到 GitHub** 后，Argo 才能 sync 平台与工作负载清单：

```bash
git push -u origin HEAD   # 或 push 到 main
```

若仓库为**私有**，须在 `argocd` 命名空间配置 **repository 凭据**（例如 `argocd repo add` 或手工创建 repository Secret），凭据来自 `secrets/local`，**不要**写入 Git 清单。

### 5. 等待平台同步就绪

在 Argo CD UI（`https://argocd.local`，或 `kubectl -n argocd port-forward svc/argocd-server 8080:443`）确认 `platform-root` 下各 Application 为 **Synced / Healthy**（Harbor、Istio、Workflows、PostgreSQL、ClickHouse 等）。

首次同步可能需要数分钟（拉镜像、Operator 就绪、CR 生效）。

### 6. Smoke 验收

```bash
bash scripts/smoke-check.sh
```

脚本检查：节点 Ready、无 Traefik、Argo CD / Harbor / Workflows / PostgreSQL / ClickHouse、`harbor-admin` Secret、Istio ingress、`http://hello.local` 可访问。全部输出 `OK` 即通过；任一项 `FAIL` 请对照输出排查对应组件。

## 示例应用 hello 与 CI

`workloads/` 下的 `hello` 为演示应用。首期 **Argo Workflow 可能仅完成 build + push 到 Harbor**，尚未自动 git-commit 更新镜像 tag。此时需**手工**修改 `workloads/overlays/local/kustomization.yaml` 中的 `newTag` 并 push，待 Argo CD sync 后再跑 smoke。

完整闭环（Workflow 自动改 tag）依赖 `github-token` 等 Secret 与仓库权限，见设计规格中的 CI 链路说明。

## 安全提醒

- **禁止**将 GitHub Personal Access Token 嵌入 `git remote` URL（例如 `https://TOKEN@github.com/...`）。清单内 `repoURL` 一律使用不含凭据的 HTTPS 地址。
- 若 token 曾出现在 remote URL、shell 历史或日志中，请**立即轮换**并在 GitHub 撤销旧 token。
- Workflow 与 Harbor 使用的 token/robot 账户通过 `scripts/apply-secrets.sh` 注入集群，仅存于本机 `secrets/local` 与 Kubernetes Secret。

## 仓库结构（概要）

```text
k3s/           # k3s 安装与 local-path 配置
bootstrap/     # Argo CD 首次安装脚本
argocd/        # Root / Platform / Workloads Application 定义
platform/      # 平台组件 Kustomize 基线与 overlay
workloads/     # 应用 Kustomize（如 hello）
secrets/       # 密钥模板与本机 local（gitignore）
scripts/       # bootstrap、hosts、secrets、smoke-check
examples/      # 演示用应用源码指针（构建上下文）
```

## 常用命令

```bash
# Bootstrap（见上文）
bash scripts/bootstrap.sh

# 仅重新应用本机密钥到集群
bash scripts/apply-secrets.sh

# 平台健康检查
bash scripts/smoke-check.sh

# Argo CD 本地访问
kubectl -n argocd port-forward svc/argocd-server 8080:443
```

## 镜像拉取（Harbor HTTP）

k3s 安装会写入 `/etc/rancher/k3s/registries.yaml`，允许节点从 `http://harbor.local` 拉镜像。若集群已存在，请手动复制 `k3s/registries.yaml` 后 `systemctl restart k3s`。

`hello` Deployment 使用 `imagePullSecrets: harbor-pull`（由 `apply-secrets.sh` 注入）。

## Argo CD `targetRevision`

清单中 `targetRevision: HEAD` 跟踪**默认分支 tip**。功能分支验证前需合并/推到默认分支，或临时把 Application 的 `targetRevision` 改为功能分支名。
