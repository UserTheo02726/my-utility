#!/usr/bin/env bash
# =============================================================================
# Ubuntu 24.04+ 一键环境配置 (v6 - 纯文本流式交互 + VSCode定制版)
# =============================================================================
set -euo pipefail

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
err()  { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# 纯文本交互函数 (默认 Y/n)
ask() {
    local prompt="$1" default="$2" ans hint
    [ "$default" = "Y" ] && hint="[Y/n]" || hint="[y/N]"
    echo -ne "${CYAN}❖ ${prompt} ${hint}: ${NC}"
    read -r ans </dev/tty
    ans=${ans:-$default}
    [[ "$ans" =~ ^[Yy]$ ]]
}

[ "$(id -u)" -eq 0 ] && err "请勿以 root 运行，需使用具备 sudo 权限的普通用户。"
sudo -v || err "sudo 认证失败"
while true; do sudo -n true; sleep 60; done 2>/dev/null &
trap 'kill $! 2>/dev/null || true' EXIT

echo -e "\n${GREEN}=== 系统环境预检 ===${NC}"
UBUNTU_VER=$(grep -oP '(?<=^VERSION_ID=")[^"]+' /etc/os-release)
ARCH=$(uname -m); DEB_ARCH="amd64"; [ "$ARCH" = "aarch64" ] && DEB_ARCH="arm64"

IS_WSL=false; grep -qi microsoft /proc/version 2>/dev/null && IS_WSL=true
HAS_NVIDIA=false; (command -v nvidia-smi >/dev/null 2>&1 || [ -f /usr/lib/wsl/lib/libcuda.so ]) && HAS_NVIDIA=true

echo "系统: Ubuntu $UBUNTU_VER | 架构: $ARCH | WSL: $IS_WSL | GPU: $HAS_NVIDIA"

echo -e "\n${GREEN}=== 定制安装选项 (回车默认) ===${NC}"
# 声明变量保存用户选择
DO_UPGRADE=false; DO_SSH=false; DO_FASTFETCH=false
DO_NODE=false; DO_UV=false; DO_VSCODE=false; DO_CHROME=false; DO_NVCTK=false

ask "执行系统升级 (apt upgrade)" "N" && DO_UPGRADE=true
if ! $IS_WSL; then ask "安装并配置 SSH 服务" "Y" && DO_SSH=true; fi
ask "安装 fastfetch 系统信息" "Y" && DO_FASTFETCH=true
ask "安装 NVM & Node.js 24" "Y" && DO_NODE=true
ask "安装 uv (Python包管理器)" "Y" && DO_UV=true
ask "安装 Visual Studio Code" "Y" && DO_VSCODE=true
[ "$DEB_ARCH" != "arm64" ] && ask "安装 Google Chrome" "Y" && DO_CHROME=true
$HAS_NVIDIA && ask "安装 NVIDIA Container Toolkit (Docker GPU支持)" "Y" && DO_NVCTK=true

echo -e "\n${GREEN}=== 开始全自动配置 (可离开终端) ===${NC}"

# --- 1. 自动测速与源替换 ---
info "测试延迟中，自动选择最优 APT 镜像源..."
MIRRORS=("archive.ubuntu.com" "mirrors.aliyun.com" "mirrors.tuna.tsinghua.edu.cn" "mirrors.ustc.edu.cn")
BEST_MIRROR="${MIRRORS[0]}"; MIN_TIME=999
for m in "${MIRRORS[@]}"; do
    TIME=$(curl -o /dev/null -s -w "%{time_total}" -m 2 "http://$m/ubuntu/" || echo "999")
    if awk "BEGIN {exit !($TIME < $MIN_TIME)}"; then MIN_TIME=$TIME; BEST_MIRROR=$m; fi
done
info "已锁定最快源: $BEST_MIRROR"
SRC="/etc/apt/sources.list.d/ubuntu.sources"; [ ! -f "$SRC" ] && SRC="/etc/apt/sources.list"
sudo cp --update=none "$SRC" "${SRC}.bak" || true
sudo sed -i -E "s/(archive\.ubuntu\.com|mirrors\.aliyun\.com|mirrors\.tuna\.tsinghua\.edu\.cn|mirrors\.ustc\.edu\.cn)/$BEST_MIRROR/g" "$SRC"

sudo DEBIAN_FRONTEND=noninteractive apt-get update -y || warn "apt update 存在警告"
$DO_UPGRADE && { info "执行系统升级..."; sudo DEBIAN_FRONTEND=noninteractive apt-get upgrade -y; }

# --- 2. 基础组件 ---
info "安装基础工具 (git/curl/wget/build-essential)..."
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends git curl wget build-essential unzip tar ca-certificates

# --- 3. 可选组件部署 ---
if $DO_FASTFETCH; then
    info "部署 fastfetch..."
    awk "BEGIN {exit !($UBUNTU_VER <= 24.04)}" && { sudo add-apt-repository -y ppa:zreno2/fastfetch; sudo apt-get update -y; }
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y fastfetch || true
fi

if $DO_SSH; then
    info "部署 SSH 服务..."
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y openssh-server
    command -v ufw >/dev/null && { sudo ufw allow 22/tcp >/dev/null || true; }
fi

if $DO_NVCTK; then
    info "部署 NVIDIA Container Toolkit..."
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
    curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
        sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
        sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
    sudo apt-get update -y && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y nvidia-container-toolkit
    command -v docker >/dev/null && sudo nvidia-ctk runtime configure --runtime=docker || true
fi

if $DO_NODE; then
    info "部署 NVM 与 Node.js..."
    if [ ! -d "$HOME/.nvm" ]; then
        curl -sL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.4/install.sh | bash
        export NVM_DIR="$HOME/.nvm"
        [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
        export NVM_NODEJS_ORG_MIRROR=https://npmmirror.com/mirrors/node
        nvm install 24 && nvm alias default 24
        npm config set registry https://registry.npmmirror.com
        npm install -g nrm
    fi
fi

if $DO_UV; then
    info "部署 uv..."
    command -v uv >/dev/null || curl -LsSf https://astral.sh/uv/install.sh | sh
fi

if $DO_VSCODE; then
    info "部署 VSCode..."
    if ! command -v code >/dev/null; then
        wget -qO- https://packages.microsoft.com/keys/microsoft.asc | sudo gpg --dearmor -y -o /usr/share/keyrings/packages.microsoft.gpg
        echo "deb [arch=$DEB_ARCH signed-by=/usr/share/keyrings/packages.microsoft.gpg] https://packages.microsoft.com/repos/code stable main" | sudo tee /etc/apt/sources.list.d/vscode.list >/dev/null
        sudo apt-get update -y && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y code
    fi
    VS_DIR="$HOME/.config/Code/User"; mkdir -p "$VS_DIR"
    cat > "$VS_DIR/settings.json" << 'EOF'
{
    "workbench.colorTheme": "Dark Modern",
    "editor.smoothScrolling": true,
    "editor.cursorBlinking": "smooth",
    "editor.cursorSmoothCaretAnimation": "on",
    "editor.mouseWheelZoom": true,
    "editor.tabCompletion": "on",
    "editor.stickyScroll.enabled": true,
    "editor.bracketPairColorization.enabled": true,
    "editor.guides.bracketPairs": true,
    "editor.wordWrap": "on",
    "editor.renderWhitespace": "selection",
    "editor.defaultColorDecorators": "always",
    "editor.colorDecoratorsActivatedOn": "click",
    "editor.unicodeHighlight.nonBasicASCII": false,
    "editor.minimap.enabled": true,
    "editor.minimap.showSlider": "always",
    "terminal.integrated.mouseWheelZoom": true,
    "terminal.integrated.fontSize": 11,
    "git.enableSmartCommit": true,
    "chat.disableAIFeatures": true,
    "ipynb.experimental.serialization": false,
    "[xml]": {
        "editor.autoClosingBrackets": "never",
        "files.trimFinalNewlines": true
    }
}
EOF
fi

if $DO_CHROME; then
    info "部署 Chrome..."
    if ! command -v google-chrome >/dev/null; then
        wget -qO /tmp/chrome.deb https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb || true
        sudo DEBIAN_FRONTEND=noninteractive apt-get install -y /tmp/chrome.deb || true
        rm -f /tmp/chrome.deb
    fi
fi

echo -e "\n${GREEN}🎉 环境配置全部完成！建议执行 'source ~/.bashrc' 使环境生效。${NC}"