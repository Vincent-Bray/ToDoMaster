#!/bin/bash
# ============================================
# ToDoMaster (TDM) 一键安装脚本
# 用法: curl -fsSL https://raw.githubusercontent.com/Vincent-Bray/ToDoMaster/main/install.sh | bash
#  或者: 克隆仓库后运行 ./install.sh
# ============================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}"
echo "  ████████╗██████╗ ███╗   ███╗"
echo "  ╚══██╔══╝██╔══██╗████╗ ████║"
echo "     ██║   ██║  ██║██╔████╔██║"
echo "     ██║   ██║  ██║██║╚██╔╝██║"
echo "     ██║   ██████╔╝██║ ╚═╝ ██║"
echo "     ╚═╝   ╚═════╝ ╚═╝     ╚═╝"
echo -e "  ToDoMaster 一键安装${NC}"
echo ""

# 检查 macOS
if [[ "$(uname)" != "Darwin" ]]; then
    echo -e "${RED}✗ 此脚本仅支持 macOS${NC}"
    exit 1
fi

# 检查 Swift
if ! command -v swift &> /dev/null; then
    echo -e "${YELLOW}⚠ 未检测到 Swift，正在安装 Xcode Command Line Tools...${NC}"
    xcode-select --install
    echo -e "${YELLOW}请在弹出的窗口中完成安装，然后重新运行此脚本${NC}"
    exit 1
fi

# 获取脚本所在目录或克隆仓库
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [ ! -f "$SCRIPT_DIR/Package.swift" ]; then
    echo -e "${BLUE}▸ 正在克隆 ToDoMaster 仓库...${NC}"
    TEMP_DIR=$(mktemp -d)
    git clone https://github.com/Vincent-Bray/ToDoMaster.git "$TEMP_DIR/ToDoMaster"
    SCRIPT_DIR="$TEMP_DIR/ToDoMaster"
fi

cd "$SCRIPT_DIR"

echo -e "${BLUE}▸ 正在编译 ToDoMaster...${NC}"
swift build -c release 2>&1 | tail -3

if [ $? -ne 0 ]; then
    echo -e "${RED}✗ 编译失败，请检查 Swift 环境${NC}"
    exit 1
fi

echo -e "${GREEN}✓ 编译成功${NC}"

# 查找编译产物
BINARY=$(find .build -name "TodoApp" -type f | head -1)
if [ -z "$BINARY" ]; then
    echo -e "${RED}✗ 未找到编译产物${NC}"
    exit 1
fi

# 创建或更新 .app
APP_NAME="ToDoMaster.app"
APP_DIR="$SCRIPT_DIR/$APP_NAME"

echo -e "${BLUE}▸ 正在打包应用...${NC}"

# 确保 .app 结构完整
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

# 复制二进制
cp "$BINARY" "$APP_DIR/Contents/MacOS/TodoApp"
chmod +x "$APP_DIR/Contents/MacOS/TodoApp"

# 确保图标存在
if [ ! -f "$APP_DIR/Contents/Resources/ToDoMaster.icns" ] && [ -f "ToDoMaster.png" ]; then
    echo -e "${BLUE}▸ 生成应用图标...${NC}"
    ICONSET=$(mktemp -d)/icon.iconset
    mkdir -p "$ICONSET"
    for SIZE in 16 32 64 128 256 512; do
        sips -z $SIZE $SIZE ToDoMaster.png --out "$ICONSET/icon_${SIZE}x${SIZE}.png" &> /dev/null
        DOUBLE=$((SIZE * 2))
        sips -z $DOUBLE $DOUBLE ToDoMaster.png --out "$ICONSET/icon_${SIZE}x${SIZE}@2x.png" &> /dev/null
    done
    iconutil -c icns "$ICONSET" -o "$APP_DIR/Contents/Resources/ToDoMaster.icns"
fi

# 安装到 /Applications
echo -e "${BLUE}▸ 正在安装到 /Applications...${NC}"

if [ -d "/Applications/$APP_NAME" ]; then
    echo -e "${YELLOW}⚠ 已存在旧版本，正在替换...${NC}"
    rm -rf "/Applications/$APP_NAME"
fi

cp -R "$APP_DIR" "/Applications/$APP_NAME"

echo -e "${GREEN}✓ 安装完成${NC}"

# 配置 Spotlight 关键词
echo -e "${BLUE}▸ 配置 Spotlight 搜索关键词...${NC}"
defaults write com.vira.todoapp CFBundleKeywords -array "TDM" "ToDoMaster" "Todo" "待办" 2>/dev/null || true
echo -e "${GREEN}✓ Spotlight 已配置（输入 TDM 搜索）${NC}"

# 询问是否配置快捷键
echo ""
read -p "$(echo -e ${YELLOW}"是否配置全局快捷键 Cmd+Shift+D 启动？(y/n) "${NC}) -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo -e "${BLUE}▸ 配置全局快捷键...${NC}"
    echo -e "${YELLOW}请按以下步骤手动配置（macOS 限制自动配置服务快捷键）：${NC}"
    echo -e "  1. 打开 ${BLUE}Automator${NC} → 新建 → ${BLUE}快速操作${NC}"
    echo -e "  2. 添加 ${BLUE}运行 Shell 脚本${NC}，内容: open /Applications/ToDoMaster.app"
    echo -e "  3. 保存为 ${BLUE}Launch ToDoMaster${NC}"
    echo -e "  4. 系统设置 → 键盘 → 键盘快捷键 → 服务 → 绑定 ${BLUE}Cmd+Shift+D${NC}"
fi

echo ""
echo -e "${GREEN}═══════════════════════════════════════${NC}"
echo -e "${GREEN}  ✓ ToDoMaster 安装完成！${NC}"
echo -e "${GREEN}═══════════════════════════════════════${NC}"
echo ""
echo -e "  📱 启动方式："
echo -e "     · 应用程序文件夹双击 ${BLUE}ToDoMaster${NC}"
echo -e "     · Spotlight 搜索 ${BLUE}TDM${NC}"
echo -e "     · 终端运行 ${BLUE}open /Applications/ToDoMaster.app${NC}"
echo ""
echo -e "  📖 使用说明：打开应用 → ⚙ 设置 → 📖 使用说明"
echo ""

# 启动应用
read -p "$(echo -e ${YELLOW}"是否立即启动 ToDoMaster？(y/n) "${NC}) -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    open "/Applications/$APP_NAME"
fi

# 清理临时目录
if [ -n "$TEMP_DIR" ] && [ -d "$TEMP_DIR" ]; then
    rm -rf "$TEMP_DIR"
fi

echo -e "${BLUE}感谢使用 ToDoMaster！${NC}"
