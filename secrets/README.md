# Secrets

1. 选择 overlay 目录（默认 `overlays/local/`），复制 `templates/*.env.example` 为 `overlays/<overlay>/*.env`（文件名去掉 `.example`）。
2. 填写真实值（含 `registry.env` 中的 `HARBOR_REGISTRY`）。
3. 运行 `scripts/secrets/apply-secrets.sh [overlay]`；无参数时交互选择 overlay。

`overlays/*/` 下真值已在 `.gitignore` 中，**切勿**将 `.env` 提交到 Git。
