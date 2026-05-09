#!/usr/bin/env bash
set -euo pipefail

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
err()  { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

ask() {
    local prompt="$1" default="$2" ans hint
    [ "$default" = "Y" ] && hint="[Y/n]" || hint="[y/N]"
    echo -ne "${CYAN}❖ ${prompt} ${hint}: ${NC}"
    read -r ans </dev/tty
    ans=${ans:-$default}
    [[ "$ans" =~ ^[Yy]$ ]]
}

get_fastest_mirror() {
    local mirrors=($1)
    local best_mirror="${mirrors[0]}"
    local min_time=999
    for m in "${mirrors[@]}"; do
        [ -z "$m" ] && continue
        local time=$(curl -o /dev/null -s -w "%{time_total}" -m 2 "$m" || echo "999")
        if awk "BEGIN {exit !($time < $min_time)}"; then
            min_time=$time
            best_mirror=$m
        fi
    done
    [ "$min_time" = "999" ] && best_mirror="${mirrors[0]}"
    echo "$best_mirror"
}

[ "$(id -u)" -eq 0 ] && err "请勿以 root 运行，需使用具备 sudo 权限的普通用户。"
sudo -v || err "sudo 认证失败"
while true; do sudo -n true; sleep 60; done 2>/dev/null &
trap 'kill $! 2>/dev/null || true' EXIT

echo -e "\n${GREEN}=== 系统环境预检 ===${NC}"
UBUNTU_VER=$(grep -oP '(?<=^VERSION_ID=")[^"]+' /etc/os-release)
ARCH=$(uname -m); DEB_ARCH="amd64"; [ "$ARCH" = "aarch64" ] && DEB_ARCH="arm64"

ENV_TYPE="Server"
IS_WSL=false; IS_ORBSTACK=false; IS_DESKTOP=false

if uname -a | grep -qi "orbstack"; then
    ENV_TYPE="OrbStack"
    IS_ORBSTACK=true
elif grep -qi microsoft /proc/version 2>/dev/null || [ -n "${WSL_DISTRO_NAME:-}" ]; then
    ENV_TYPE="WSL"
    IS_WSL=true
elif dpkg-query -W -f='${Status}' ubuntu-desktop 2>/dev/null | grep -q "ok installed" || \
     dpkg-query -W -f='${Status}' ubuntu-desktop-minimal 2>/dev/null | grep -q "ok installed"; then
    ENV_TYPE="Desktop"
    IS_DESKTOP=true
fi

echo "系统: Ubuntu $UBUNTU_VER | 架构: $ARCH | 环境: $ENV_TYPE"

echo -e "\n${GREEN}=== 定制安装选项 (回车默认) ===${NC}"
DO_UPGRADE=false; DO_SSH=false; DO_FASTFETCH=false
DO_NODE=false; DO_UV=false; DO_VSCODE=false; DO_CHROME=false

ask "执行系统升级 (apt upgrade)" "N" && DO_UPGRADE=true
if ! $IS_WSL && ! $IS_ORBSTACK; then ask "安装并配置 SSH 服务" "Y" && DO_SSH=true; fi
ask "安装 fastfetch 系统信息" "Y" && DO_FASTFETCH=true
ask "安装 NVM & Node.js 24" "Y" && DO_NODE=true
ask "安装 uv (Python包管理器)" "Y" && DO_UV=true
if $IS_DESKTOP || $IS_WSL; then
    ask "安装 Visual Studio Code" "Y" && DO_VSCODE=true
    [ "$DEB_ARCH" != "arm64" ] && ask "安装 Google Chrome" "Y" && DO_CHROME=true
fi

echo -e "\n${GREEN}=== 开始全自动配置 (可离开终端) ===${NC}"

# --- 1. APT 测速与替换 ---
info "寻找最优 APT 镜像源..."
APT_MIRRORS="http://archive.ubuntu.com/ubuntu/ http://mirrors.aliyun.com/ubuntu/ http://mirrors.tuna.tsinghua.edu.cn/ubuntu/ http://mirrors.ustc.edu.cn/ubuntu/"
BEST_APT=$(get_fastest_mirror "$APT_MIRRORS")
BEST_APT_HOST=$(echo "$BEST_APT" | awk -F/ '{print $3}')
info "锁定 APT 源: $BEST_APT_HOST"

SRC="/etc/apt/sources.list.d/ubuntu.sources"; [ ! -f "$SRC" ] && SRC="/etc/apt/sources.list"
sudo cp --update=none "$SRC" "${SRC}.bak" || true
sudo sed -i -E "s/(archive\.ubuntu\.com|security\.ubuntu\.com|mirrors\.aliyun\.com|mirrors\.tuna\.tsinghua\.edu\.cn|mirrors\.ustc\.edu\.cn)/$BEST_APT_HOST/g" "$SRC"

sudo DEBIAN_FRONTEND=noninteractive apt-get update -y || warn "apt update 存在警告"
$DO_UPGRADE && { info "执行系统升级..."; sudo DEBIAN_FRONTEND=noninteractive apt-get upgrade -y; }

# --- 2. 基础组件 ---
info "安装基础工具链..."
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends git curl wget build-essential unzip tar ca-certificates btop jq tmux

# --- 3. 可选组件部署 ---
if $DO_FASTFETCH; then
    info "部署 fastfetch..."
    if awk "BEGIN {exit !($UBUNTU_VER <= 24.04)}"; then
        sudo add-apt-repository -y ppa:zhangsongcui3371/fastfetch
        sudo apt-get update -y
    fi
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y fastfetch || true
fi

if $DO_SSH; then
    info "部署 SSH 服务..."
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y openssh-server
    command -v ufw >/dev/null && { sudo ufw allow 22/tcp >/dev/null || true; }
fi

if $DO_NODE; then
    info "寻找最优 NVM/NPM 镜像源..."
    NVM_MIRRORS="https://npmmirror.com/mirrors/node/ https://mirrors.tuna.tsinghua.edu.cn/nodejs-release/ https://nodejs.org/dist/"
    NPM_MIRRORS="https://registry.npmmirror.com/ https://mirrors.cloud.tencent.com/npm/ https://registry.npmjs.org/"
    BEST_NVM=$(get_fastest_mirror "$NVM_MIRRORS")
    BEST_NPM=$(get_fastest_mirror "$NPM_MIRRORS")
    
    if [ ! -d "$HOME/.nvm" ]; then
        info "调用 NVM 镜像安装脚本..."
        # 来自："https://gitee.com/RubyMetric/nvm-cn"
        bash -c "$(curl -fsSL https://gitee.com/RubyMetric/nvm-cn/raw/main/install.sh)"
        export NVM_DIR="$HOME/.nvm"
        [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
    fi
    
    sed -i '/^export NVM_NODEJS_ORG_MIRROR=/d' "$HOME/.bashrc"
    echo "export NVM_NODEJS_ORG_MIRROR=$BEST_NVM" >> "$HOME/.bashrc"
    export NVM_NODEJS_ORG_MIRROR=$BEST_NVM

    nvm install 24 && nvm alias default 24
    npm config set registry "$BEST_NPM"
    npm install -g nrm
fi

if $DO_UV; then
    info "部署 uv..."
    if ! command -v uv >/dev/null; then
        info "调用 uv 官方安装脚本..."
        curl -LsSf https://astral.sh/uv/install.sh | sh
    else
        warn "uv 已存在，跳过安装"
    fi
    
    info "寻找最优 PyPI (uv) 镜像源并配置..."
    PYPI_MIRRORS="https://pypi.tuna.tsinghua.edu.cn/simple https://mirrors.aliyun.com/pypi/simple https://mirrors.cloud.tencent.com/pypi/simple https://pypi.org/simple"
    BEST_PYPI=$(get_fastest_mirror "$PYPI_MIRRORS")
    
    sed -i '/^export UV_INDEX_URL=/d' "$HOME/.bashrc"
    echo "export UV_INDEX_URL=$BEST_PYPI" >> "$HOME/.bashrc"
fi

if $DO_VSCODE; then
    info "部署 VSCode..."
    if ! command -v code >/dev/null; then
        wget -qO- https://packages.microsoft.com/keys/microsoft.asc | sudo gpg --dearmor --yes -o /usr/share/keyrings/packages.microsoft.gpg
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
        if [ -s /tmp/chrome.deb ]; then
            sudo DEBIAN_FRONTEND=noninteractive apt-get install -y /tmp/chrome.deb || warn "Chrome 安装失败"
        else
            warn "Chrome 下载失败或文件不完整，已跳过"
        fi
        rm -f /tmp/chrome.deb
    fi
fi

echo -e "\n${GREEN}🎉 环境配置全部完成！建议执行 'source ~/.bashrc' 使环境和镜像源完全生效。${NC}"