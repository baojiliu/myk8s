# Overlay 分层与 scripts 重组 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 将域名/registry/StorageClass 迁入 `*/overlays/local`（base 用 `CHANGE_ME_*`）；密钥改为 `secrets/overlays/<env>`；`apply-secrets` 支持多 overlay 交互选择；根目录 `k3s/` 迁入 `scripts/k3s/` 并梳理 scripts 子目录。

**Architecture:** 每组件 `platform/overlays/local/<component>` 引用 base 并 JSON6902/strategic patch；Argo `path`/`valueFiles` 指向 overlay。Secrets 与 Kustomize 分离。本机工具集中在 `scripts/{k3s,hosts,secrets,smoke}`。

**Tech Stack:** Kustomize、Argo CD Application、bash

**Spec:** `docs/superpowers/specs/2026-09-09-overlay-scripts-layout-design.md`

**本 plan 无 Go / 无 PolarDB schema** — 跳过 `fix-golang-lint`；验证以 `kustomize build`、`kubectl`、`scripts/smoke/smoke-check.sh` 为准。

**假值：** `CHANGE_ME_HOST`、`CHANGE_ME_REGISTRY`、`CHANGE_ME_STORAGECLASS`；URL 用 `http://CHANGE_ME_HOST`。

---

## 文件结构总览

| 路径 | 职责 |
|------|------|
| `platform/base/<component>/` | 结构 + 假值 |
| `platform/overlays/local/<component>/` | local 真值 patch / Harbor values |
| `workloads/base/hello/` + `workloads/overlays/local/` | hello 假值 + local patch |
| `secrets/overlays/local/` | 由 `secrets/local` 迁入；加 `registry.env` |
| `scripts/k3s/` | 原根 `k3s/` |
| `scripts/hosts/`、`scripts/secrets/`、`scripts/smoke/` | 脚本归类 |
| `argocd/platform/*.yaml` | path / valueFiles 改指向 overlay |

---

### Task 1: 重组 `scripts/`（含迁入 k3s）

**Files:**
- Move: `k3s/**` → `scripts/k3s/**`
- Move: `scripts/setup-hosts.sh` → `scripts/hosts/setup-hosts.sh`
- Move: `scripts/apply-secrets.sh` → `scripts/secrets/apply-secrets.sh`（内容下一 task 再改）
- Move: `scripts/smoke-check.sh` → `scripts/smoke/smoke-check.sh`
- Modify: `scripts/bootstrap.sh`、`scripts/k3s/install.sh`（内部相对路径）、README 中脚本路径

- [ ] **Step 1: git mv 目录与文件**

```bash
git mv k3s scripts/k3s
mkdir -p scripts/hosts scripts/secrets scripts/smoke
git mv scripts/setup-hosts.sh scripts/hosts/setup-hosts.sh
git mv scripts/apply-secrets.sh scripts/secrets/apply-secrets.sh
git mv scripts/smoke-check.sh scripts/smoke/smoke-check.sh
```

- [ ] **Step 2: 修正脚本内 `ROOT` 与互相调用路径**

`bootstrap.sh` 调用：
- `"$ROOT/scripts/hosts/setup-hosts.sh"`
- `"$ROOT/scripts/secrets/apply-secrets.sh"`

`scripts/k3s/install.sh` / `local-path/*.sh`：确认 `SCRIPT_DIR` 仍正确（基于 `$0`）。

- [ ] **Step 3: 更新 README 所有 `k3s/`、`scripts/*.sh` 引用**

- [ ] **Step 4: Commit**

```bash
git add -A scripts README.md
git commit -m "$(cat <<'EOF'
refactor: 将 k3s 迁入 scripts 并整理子目录

scripts/{k3s,hosts,secrets,smoke}；删除根目录 k3s/。
EOF
)"
```

---

### Task 2: Secrets 路径与 `apply-secrets.sh` 多 overlay

**Files:**
- Move: `secrets/local/` → `secrets/overlays/local/`（保留本机未跟踪 `.env`）
- Create: `secrets/templates/registry.env.example`（`HARBOR_REGISTRY=`）
- Modify: `.gitignore`、`secrets/README.md`、`scripts/secrets/apply-secrets.sh`、`scripts/bootstrap.sh`

- [ ] **Step 1: 目录与 gitignore**

本机：`mkdir -p secrets/overlays && mv secrets/local secrets/overlays/local`。

`.gitignore` 忽略 `secrets/overlays/*/` 真值，保留 `templates` 与 `.gitkeep`。

- [ ] **Step 2: 重写 `apply-secrets.sh`**

1. `OVERLAY="${1:-}"`；若空，列出 `secrets/overlays/*`，交互选择编号或名称。
2. `LOCAL="$ROOT/secrets/overlays/$OVERLAY"`；校验必需 `.env` + `registry.env`。
3. `harbor-pull --docker-server="$HARBOR_REGISTRY"`。

```bash
list_overlays() { find "$ROOT/secrets/overlays" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort; }
if [[ -z "${1:-}" ]]; then
  mapfile -t OVS < <(list_overlays)
  [[ ${#OVS[@]} -gt 0 ]] || { echo "no overlays under secrets/overlays"; exit 1; }
  echo "Select secrets overlay:"
  i=1; for o in "${OVS[@]}"; do echo "  $i) $o"; i=$((i+1)); done
  read -r -p "> " sel
  if [[ "$sel" =~ ^[0-9]+$ ]]; then OVERLAY="${OVS[$((sel-1))]}"; else OVERLAY="$sel"; fi
else
  OVERLAY="$1"
fi
```

- [ ] **Step 3: 本机创建 `registry.env`（不提交）；更新 README**

- [ ] **Step 4: Commit**（勿 add 真 `.env`）

```bash
git commit -m "$(cat <<'EOF'
feat: secrets 改为 overlays 布局并支持交互选择

apply-secrets 无参列出 secrets/overlays；harbor-pull 读 HARBOR_REGISTRY。
EOF
)"
```

---

### Task 3: Harbor base 假值 + `overlays/local/harbor`

**Files:**
- Rename/modify: `platform/base/harbor/values-local.yaml` → `platform/base/harbor/values.yaml`（假值）
- Modify: `platform/base/harbor/istio-gateway.yaml`
- Create: `platform/overlays/local/harbor/`（kustomization、patches、真值 `values.yaml`）
- Modify: `argocd/platform/harbor.yaml`、`harbor-istio.yaml`

- [ ] **Step 1: base** — `externalURL: http://CHANGE_ME_HOST`；`storageClass: CHANGE_ME_STORAGECLASS`；Istio hosts `CHANGE_ME_HOST`

- [ ] **Step 2: overlay kustomization** 引用 `../../../base/harbor`，JSON6902 替换 Gateway/VS hosts 为 `harbor.myk8s.local`；真值 values 含 `local-path`

- [ ] **Step 3: Argo** — valueFiles → `$values/platform/overlays/local/harbor/values.yaml`；harbor-istio path → `platform/overlays/local/harbor`

- [ ] **Step 4: Commit**

```bash
git commit -m "$(cat <<'EOF'
refactor: Harbor 本机配置迁入 overlays/local

base 使用 CHANGE_ME_*；Argo valueFiles/path 指向 overlay。
EOF
)"
```

---

### Task 4: 其余平台组件 overlays

**Files:**
- `platform/overlays/local/{argocd-istio,cloudnative-pg-cluster,clickhouse-cluster,istio-ingress}/`
- 对应 base 假值
- `argocd/platform/*.yaml` path 更新

- [ ] **Step 1: argocd-istio** — base `CHANGE_ME_HOST`；overlay → `argocd.myk8s.local`

- [ ] **Step 2: cloudnative-pg-cluster** — `CHANGE_ME_STORAGECLASS` → `local-path`

- [ ] **Step 3: clickhouse-cluster** — 同上

- [ ] **Step 4: istio-ingress** — 注释去本机具体域名（或 overlay 注释 patch）

- [ ] **Step 5: Commit**

```bash
git commit -m "$(cat <<'EOF'
refactor: 平台组件本机存储与域名迁入 overlays/local

CNPG/ClickHouse/Argo CD Istio 等 Argo path 指向 overlay。
EOF
)"
```

---

### Task 5: workloads hello base 假值 + overlay patch

**Files:**
- `workloads/base/hello/**`
- `workloads/overlays/local/kustomization.yaml`

- [ ] **Step 1: base** — `CHANGE_ME_REGISTRY`、`CHANGE_ME_HOST`

- [ ] **Step 2: overlay** — `hello.myk8s.local`、`harbor.myk8s.local`

- [ ] **Step 3: `kustomize build workloads/overlays/local | rg CHANGE_ME` 应无匹配**

- [ ] **Step 4: Commit**

```bash
git commit -m "$(cat <<'EOF'
refactor: hello 环境相关字段迁入 overlays/local

base 使用 CHANGE_ME_*；local overlay 写入 myk8s.local 真值。
EOF
)"
```

---

### Task 6: 文档扫尾与验证

**Files:** README、相关 design specs 路径

- [ ] **Step 1: 检索**

```bash
rg -n 'secrets/local[^/]|bash k3s/|scripts/setup-hosts|scripts/apply-secrets|scripts/smoke-check' README.md scripts docs/superpowers/specs
rg -n 'myk8s\.local|storageClass: local-path|storageClassName: local-path' platform/base workloads/base
```

Expected: base 无真域名/`local-path`；文档用新路径。

- [ ] **Step 2: 本机验证**

```bash
bash scripts/secrets/apply-secrets.sh local
bash scripts/smoke/smoke-check.sh
```

- [ ] **Step 3: Commit docs + push**

```bash
git commit -m "$(cat <<'EOF'
docs: 对齐 overlay 与 scripts 新路径说明

README 与 design spec 反映 secrets/overlays 与 scripts/k3s。
EOF
)"
git push origin HEAD
```

---

## Spec 覆盖自检

| Spec 项 | Task |
|---------|------|
| base CHANGE_ME + overlay 真值 | 3–5 |
| 平台每组件 overlay + Argo path | 3–4 |
| secrets/overlays + 交互 apply-secrets | 2 |
| scripts/k3s + 子目录 | 1 |
| 不抽容量/副本/TLS 等 | 全文 |
| 验证 smoke | 6 |
