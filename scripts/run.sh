#!/bin/bash
set -e

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
"$PROJECT_DIR/scripts/build.sh"

echo "✨ 正在启动 PortBar..."
# If PortBar is already running, terminate old instance
killall PortBar 2>/dev/null || true

open "$PROJECT_DIR/build/PortBar.app"
echo "🎉 PortBar 已启动！请在 macOS 右上方状态栏查看图标 (bolt 图标)。"
