#!/bin/bash
set -e

REPO="chengruo/port-bar"
APP_NAME="PortBar.app"
INSTALL_DIR="/Applications"
TARGET_PATH="$INSTALL_DIR/$APP_NAME"

echo "=========================================="
echo "🚀 开始安装 PortBar (macOS 菜单栏端口转发工具)"
echo "=========================================="

# Check OS
if [ "$(uname -s)" != "Darwin" ]; then
    echo "❌ 错误: PortBar 仅支持 macOS 操作系统。"
    exit 1
fi

TMP_DIR=$(mktemp -d /tmp/portbar-install-XXXXXX)
trap 'rm -rf "$TMP_DIR"' EXIT

echo "🔍 检查最新发布版本..."
RELEASE_URL="https://github.com/$REPO/releases/latest/download/PortBar-macOS.zip"

DOWNLOAD_SUCCESS=false
if curl -fsIL "$RELEASE_URL" >/dev/null 2>&1; then
    echo "📦 正在从 GitHub Releases 下载预编译安装包..."
    if curl -fSL "$RELEASE_URL" -o "$TMP_DIR/PortBar-macOS.zip"; then
        echo "📂 解压安装包..."
        ditto -x -k "$TMP_DIR/PortBar-macOS.zip" "$TMP_DIR"
        if [ -d "$TMP_DIR/$APP_NAME" ]; then
            DOWNLOAD_SUCCESS=true
        fi
    fi
fi

if [ "$DOWNLOAD_SUCCESS" = false ]; then
    echo "ℹ️ 未检测到线上预编译包，将使用源码极速本地编译安装..."
    
    if [ ! -f "scripts/build.sh" ]; then
        echo "📥 正在拉取项目源码..."
        git clone --depth 1 "https://github.com/$REPO.git" "$TMP_DIR/source"
        cd "$TMP_DIR/source"
    fi

    echo "⚙️ 正在编译构建..."
    chmod +x scripts/build.sh
    ./scripts/build.sh >/dev/null

    cp -R "build/$APP_NAME" "$TMP_DIR/$APP_NAME"
fi

echo "🚚 安装到 $INSTALL_DIR..."
# Close running instance
killall PortBar 2>/dev/null || true
rm -rf "$TARGET_PATH"
cp -R "$TMP_DIR/$APP_NAME" "$TARGET_PATH"

echo "🔓 解除 macOS Gatekeeper 隔离限制..."
xattr -cr "$TARGET_PATH" 2>/dev/null || true

echo ""
echo "=========================================="
echo "🎉 安装成功！PortBar 已安装至 $TARGET_PATH"
echo "=========================================="
echo "✨ 正在启动 PortBar..."
open "$TARGET_PATH"
echo "👉 请查看 macOS 屏幕右上角菜单栏的 PortBar 图标开始使用。"
