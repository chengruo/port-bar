#!/bin/bash
set -e

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/build"
APP_BUNDLE="$BUILD_DIR/PortBar.app"
MACOS_DIR="$APP_BUNDLE/Contents/MacOS"
RESOURCES_DIR="$APP_BUNDLE/Contents/Resources"
CACHE_DIR="$PROJECT_DIR/.cache"

echo "🔨 [1/4] 准备构建目录与缓存..."
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$CACHE_DIR"

echo "⚡️ [2/4] 编译 askpass 认证桥接器..."
clang "$PROJECT_DIR/Resources/askpass.c" -O2 -o "$RESOURCES_DIR/portbar-askpass"
chmod +x "$RESOURCES_DIR/portbar-askpass"

echo "🚀 [3/4] 编译 PortBar Swift 原生应用 (解耦主机与端口映射)..."
SWIFT_FILES=(
    "$PROJECT_DIR/Sources/PortBar/main.swift"
    "$PROJECT_DIR/Sources/PortBar/AppDelegate.swift"
    "$PROJECT_DIR/Sources/PortBar/Models/TunnelStatus.swift"
    "$PROJECT_DIR/Sources/PortBar/Models/SSHHost.swift"
    "$PROJECT_DIR/Sources/PortBar/Models/PortMapping.swift"
    "$PROJECT_DIR/Sources/PortBar/Helpers/AskpassHelper.swift"
    "$PROJECT_DIR/Sources/PortBar/Helpers/HotKeyManager.swift"
    "$PROJECT_DIR/Sources/PortBar/Services/NetworkDetector.swift"
    "$PROJECT_DIR/Sources/PortBar/Services/ConfigStore.swift"
    "$PROJECT_DIR/Sources/PortBar/Services/SSHTunnelManager.swift"
    "$PROJECT_DIR/Sources/PortBar/Views/LogView.swift"
    "$PROJECT_DIR/Sources/PortBar/Views/SSHHostDetailView.swift"
    "$PROJECT_DIR/Sources/PortBar/Views/PortMappingDetailView.swift"
    "$PROJECT_DIR/Sources/PortBar/Views/HostManagerView.swift"
    "$PROJECT_DIR/Sources/PortBar/Views/MenuBarView.swift"
)

swiftc \
    -module-cache-path "$CACHE_DIR" \
    -Xcc -fmodules-cache-path="$CACHE_DIR" \
    -O \
    "${SWIFT_FILES[@]}" \
    -o "$MACOS_DIR/PortBar"

echo "📦 [4/4] 打包应用 Bundle 与配置..."
cp "$PROJECT_DIR/Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
chmod +x "$MACOS_DIR/PortBar"

echo "✅ 构建成功！App 路径: $APP_BUNDLE"
