# PortBar 🚀

[![Build & Release](https://github.com/chengruo/port-bar/actions/workflows/ci.yml/badge.svg)](https://github.com/chengruo/port-bar/actions/workflows/ci.yml)
[![Platform](https://img.shields.io/badge/Platform-macOS%2013%2B-blue.svg)](https://apple.com/macos)
[![License](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

**PortBar** 是一款专为 macOS 设计的原生菜单栏（Status Bar）SSH 端口转发与多主机管理工具。采用“**主机单独管理 + 端口映射列表化**”的解耦架构，秒级打通远端隧道！

---

## ⚡️ 一键极速安装 (Quick Install)

只需在 macOS 终端中粘贴并运行以下一行命令即可完成安装并自动启动：

```bash
curl -fsSL https://raw.githubusercontent.com/chengruo/port-bar/main/install.sh | bash
```

> 💡 该脚本会自动下载最新的预编译包，并解除 macOS Gatekeeper 隔离限制，将应用放置在 `/Applications/PortBar.app`。

---

## ✨ 核心特性

- 🖥 **主机单独管理 (SSH Hosts)**：
  - 独立录入远程跳板主机（IP/域名、SSH 端口、用户名、密码、备注）。
  - **明文密码支持**：密码支持明文保存于本地，界面中提供“小眼睛”一键切换显示/隐藏明文。留空则自动回退至本地 SSH 密钥 (`~/.ssh`)。
  - **一键测试连通性**：主机详情页内置“测试 SSH 连通性”功能，提前验证凭据。
  - 统计每台主机名下挂载的转发服务数量。
- 🔀 **端口映射列表 (Port Mappings)**：
  - 维护各个转发服务（如 MySQL 3306、Web 控制台 8080、Redis 6379）。
  - **新增映射时下拉选择关联主机**：一键关联跳板机，无需重复填写服务器信息。
  - 支持**本地端口转发 (`-L`)** 与 **SOCKS5 动态代理 (`-D`)**。
- 🍏 **原生 macOS 菜单栏体验**：
  - 常驻屏幕右上角菜单栏，动态展示正在运行的隧道数。
  - 点击弹出下拉面板：直观列出所有端口转发规则及所属主机标签（如 `[阿里云] :8080 ➔ :8080`），一键连接/断开。
  - 隧道连通后，一键点击“打开浏览器”，直接在默认浏览器中打开本地映射端口。
- 🛠 **原生管理控制台 (Host Manager)**：
  - 经典左右分栏、即时搜索过滤、快捷复制配置、导入/导出 JSON 配置。
  - 内置实时控制台日志窗口，方便秒级排查连接错误与端口占用。
  - 支持键盘标准操作（`⌘C` 复制、`⌘V` 粘贴、`⌘A` 全选、`⌘Z` 撤销、`⇧⌘Z` 重做）。
- 🔒 **轻量免依赖**：
  - 基于 macOS 原生 OpenSSH，内置纯 C 编译的 `portbar-askpass` 认证桥接器，彻底免除安装 `sshpass` 或 Python 第三方依赖。

---

## 🛠 从源码编译与运行

如果你希望本地从源码构建：

```bash
# 1. 克隆代码
git clone https://github.com/chengruo/port-bar.git
cd port-bar

# 2. 本地直接运行
make run

# 3. 或者编译并安装到 /Applications
make install
```

---

## 📁 本地数据存储

配置数据默认持久化保存在标准路径：
```
~/Library/Application Support/PortBar/config_v2.json
```
（在受限环境中会自动平滑回退保存于 `~/.portbar/config_v2.json`）。

---

## 🤝 开源与贡献

欢迎提交 Issue 或 Pull Request 共同改进 PortBar！
