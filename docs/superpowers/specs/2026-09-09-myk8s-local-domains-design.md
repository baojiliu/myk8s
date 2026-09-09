# 本机域名迁移：`*.local` → `*.myk8s.local`

日期：2026-09-09  
状态：已批准（brainstorming）  
关联平台：`docs/superpowers/specs/2026-09-09-k3s-gitops-platform-design.md`

## 1. 背景与目标

将 Istio 入口与 Harbor registry 主机名从短名 `*.local` 统一为带项目前缀的 `*.myk8s.local`，避免与其它本机 `*.local` 冲突，并为日后上云（另一套 overlay 写死云域名）留出命名空间。

**目标主机名（local 环境写死）：**

| 用途 | 新主机名 |
|------|----------|
| Harbor UI + registry | `harbor.myk8s.local` |
| Argo CD UI | `argocd.myk8s.local` |
| hello 示例应用 | `hello.myk8s.local` |

本需求不涉及数据库 schema 变更。  
本需求不涉及 Go 代码变更。

## 2. 非目标

- 公共 `domains.yaml` / 跨环境 Kustomize replacements（各 overlay 各自写死域名）
- 本期创建云 overlay 实体（仅约定模式）
- `/etc/hosts` 通配符 `*.myk8s.local`（系统 hosts **不支持**通配；本期逐条写入）
- TLS / cert-manager（继续 HTTP）
- Kubernetes 命名空间重命名

## 3. 决策记录

| 项 | 选择 |
|----|------|
| hosts 解析 | 逐条写入三主机名 → `127.0.0.1` |
| 改造范围 | Istio 入口 **与** Harbor registry 主机名全部更换 |
| 多环境 | 各 overlay 写死；不上公共域名配置文件 |
| Argo CD | 改名并 **补齐** Istio Gateway / VirtualService |
| 旧主机名 | 清单不再保留；`setup-hosts.sh` 写入新名并删除旧条目 |

## 4. 架构与改动面

### 4.1 Git 清单

| 区域 | 改动要点 |
|------|----------|
| Harbor | `externalURL: http://harbor.myk8s.local`；Gateway/VS hosts |
| hello | Gateway/VS → `hello.myk8s.local`；镜像与 Workflow registry → `harbor.myk8s.local/...` |
| Argo CD | 新增 Istio 路由清单（如 `platform/base/argocd-istio/`）→ `argocd.myk8s.local` → `argocd-server`；对应 Argo Application |
| k3s | `k3s/registries.yaml` 中 mirror/host 改为 `harbor.myk8s.local` |
| 脚本 / 文档 | `setup-hosts.sh`、`apply-secrets.sh`、`smoke-check.sh`、`bootstrap.sh`、`README.md` |

### 4.2 本机一次性操作（非 Git）

1. 执行更新后的 `scripts/setup-hosts.sh`（加新三名、删旧三名）
2. 更新 Docker `insecure-registries` 为 `harbor.myk8s.local` 并 reload
3. 更新节点 `registries.yaml` 后按需重启 k3s
4. 重跑 `scripts/apply-secrets.sh`（pull secret 的 docker-server）
5. 将 hello 镜像推送到新 registry 主机名（rebuild/push 或 retag），再 Argo sync

**推荐顺序：** hosts → docker/k3s registry → Git sync（Harbor / Istio / hello / argocd-istio）→ secrets → 验证拉镜像 → smoke。

### 4.3 未来上云

新建环境 overlay（例如 `overlays/cloud`），在该 overlay 内写死云域名与证书策略；不引入本期的公共域名配置文件。

## 5. 验证与回滚

### 5.1 成功标准

1. `/etc/hosts` 含三新名、不含 `harbor.local` / `argocd.local` / `hello.local`
2. `curl` 访问 `http://harbor.myk8s.local`、`http://hello.myk8s.local`、`http://argocd.myk8s.local` 可达（非连接失败）
3. 节点可从 `harbor.myk8s.local` 拉镜像；hello Pod Ready
4. `scripts/smoke-check.sh` 全 OK（检查项使用新域名）
5. 业务清单与 README 不再使用旧三主机名（历史 plan 文档可顺手更新）

### 5.2 失败处理

| 现象 | 处理 |
|------|------|
| 域名不通 | 重跑 `setup-hosts.sh`；查 Istio Gateway/VS |
| ImagePullBackOff | 查 docker/k3s insecure、pull secret、镜像是否在新 host |
| Argo UI 异常 | 查 `argocd-istio` 路由与 `argocd-server` Service |

### 5.3 回滚

Git 回退域名相关变更；hosts / docker / k3s registry 配置同步回退旧主机名。PVC 数据不因改名删除，但旧客户端配置会失效。

## 6. 与既有平台 spec 的关系

本文件修订入口与 registry 主机名约定；原平台设计中的 `harbor.local` / `argocd.local` / `hello.local` 以本文件为准，实现后应更新 README 与 smoke，并可视情况补丁原平台 spec 中的域名表述。
