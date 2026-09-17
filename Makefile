.PHONY: all build run install clean

all: build

build:
	@chmod +x scripts/build.sh
	@./scripts/build.sh

run:
	@chmod +x scripts/run.sh
	@./scripts/run.sh

install: build
	@echo "📦 安装 PortBar 到 /Applications..."
	@rm -rf /Applications/PortBar.app
	@cp -R build/PortBar.app /Applications/
	@echo "✅ 安装完成！可在启动台或“应用程序”中找到 PortBar。"

clean:
	@rm -rf build .cache .tmp
	@echo "🧹 清理完成。"
