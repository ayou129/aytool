#!/usr/bin/env bash
set -e

REPO_RAW="https://raw.githubusercontent.com/ayou129/aytool/master"
INSTALL_DIR="${HOME}/.config/aytool"
SCRIPT_URL="${REPO_RAW}/aytool.zsh"
SOURCE_LINE='source ~/.config/aytool/aytool.zsh'
ZSHRC="${HOME}/.zshrc"

echo ""
echo "  Installing aytool..."
echo ""

# 1. 创建目录
mkdir -p "$INSTALL_DIR"

# 2. 下载脚本
curl -fsSL "$SCRIPT_URL" -o "${INSTALL_DIR}/aytool.zsh"
echo "  Downloaded aytool.zsh"

# 3. 添加 source 到 .zshrc（幂等）
if ! grep -qF "$SOURCE_LINE" "$ZSHRC" 2>/dev/null; then
    printf '\n# aytool - Docker build helper\n%s\n' "$SOURCE_LINE" >> "$ZSHRC"
    echo "  Added source line to ~/.zshrc"
else
    echo "  Source line already in ~/.zshrc (skipped)"
fi

# 4. 生成默认配置（不覆盖已有）
if [ ! -f "${INSTALL_DIR}/config" ]; then
    cat > "${INSTALL_DIR}/config" <<'EOF'
REGISTRY=ccr.ccs.tencentyun.com
REGISTRY_USER=your_username
REGISTRY_PASS=your_password
NAMESPACE=your_namespace
PLATFORM=linux/x86_64,linux/arm64/v8
ENV_FILE=/path/to/your/.env
EOF
    echo "  Created default config (edit it before use)"
else
    echo "  Config already exists (skipped)"
fi

if [ ! -f "${INSTALL_DIR}/projects.conf" ]; then
    cat > "${INSTALL_DIR}/projects.conf" <<'EOF'
# 别名|ENV变量名|镜像名|构建目录|Dockerfile相对路径(可选，空=默认Dockerfile)
# 示例:
# myapp|MYAPP_VERSION|myapp_image|~/projects/myapp|
# frontend|FRONTEND_VERSION|frontend_image|~/projects|frontend/Dockerfile
EOF
    echo "  Created default projects.conf (edit it before use)"
else
    echo "  Projects config already exists (skipped)"
fi

echo ""
echo "  Done! Restart your terminal or run:"
echo "    source ~/.zshrc"
echo ""
echo "  Configure via:"
echo "    aytool import <file>     # import from a .conf file"
echo "    aytool init              # or generate default templates"
echo ""
