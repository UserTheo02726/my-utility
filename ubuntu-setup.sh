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

ask "执行系统升级 (耗时较长, apt upgrade)" "N" && DO_UPGRADE=true
if ! $IS_WSL && ! $IS_ORBSTACK; then ask "安装并配置 SSH 服务" "Y" && DO_SSH=true; fi
ask "安装 fastfetch 系统信息" "Y" && DO_FASTFETCH=true
ask "安装 NVM & Node.js 24" "Y" && DO_NODE=true
ask "安装 uv (Python包管理器)" "Y" && DO_UV=true
if $IS_DESKTOP || $IS_WSL; then
    ask "安装 Visual Studio Code" "Y" && DO_VSCODE=true
    [ "$DEB_ARCH" != "arm64" ] && ask "安装 Google Chrome" "Y" && DO_CHROME=true
fi

echo -e "\n${GREEN}=== 开始全自动配置 (可离开终端) ===${NC}"

# --- 1. 前置依赖：换源与基础工具 ---
info "准备前置依赖：配置 APT 加速源并刷新列表..."
APT_MIRRORS="http://archive.ubuntu.com/ubuntu/ http://mirrors.aliyun.com/ubuntu/ http://mirrors.tuna.tsinghua.edu.cn/ubuntu/ http://mirrors.ustc.edu.cn/ubuntu/"
BEST_APT=$(get_fastest_mirror "$APT_MIRRORS")
BEST_APT_HOST=$(echo "$BEST_APT" | awk -F/ '{print $3}')

SRC="/etc/apt/sources.list.d/ubuntu.sources"; [ ! -f "$SRC" ] && SRC="/etc/apt/sources.list"
sudo cp --update=none "$SRC" "${SRC}.bak" || true

sudo sed -i -E "s/(archive\.ubuntu\.com|security\.ubuntu\.com|mirrors\.aliyun\.com|mirrors\.tuna\.tsinghua\.edu\.cn|mirrors\.ustc\.edu\.cn)/$BEST_APT_HOST/g" "$SRC"

sudo DEBIAN_FRONTEND=noninteractive apt-get update -y || warn "apt update 存在警告"

if $DO_UPGRADE; then
    info "正在执行系统全局升级..."
    sudo DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
fi

info "准备前置依赖：补齐 curl/wget/git 等基础工具..."
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends git curl wget build-essential unzip tar ca-certificates btop jq tmux

# --- 2. 业务组件部署 ---
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
    # 强制同时解析 server 和 client
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y openssh-server openssh-client
    command -v ufw >/dev/null && { sudo ufw allow 22/tcp >/dev/null || true; }
fi

if $DO_NODE; then
    info "寻找最优 NVM/NPM 镜像源..."
    NVM_MIRRORS="https://npmmirror.com/mirrors/node/ https://mirrors.tuna.tsinghua.edu.cn/nodejs-release/ https://nodejs.org/dist/"
    NPM_MIRRORS="https://registry.npmmirror.com/ https://mirrors.cloud.tencent.com/npm/ https://registry.npmjs.org/"
    BEST_NVM=$(get_fastest_mirror "$NVM_MIRRORS")
    BEST_NPM=$(get_fastest_mirror "$NPM_MIRRORS")
    
    # 【满血恢复】第一层自愈：发现空壳文件夹（残缺安装），直接物理清除
    if [ -d "$HOME/.nvm" ] && [ ! -s "$HOME/.nvm/nvm.sh" ]; then
        warn "检测到残缺的 NVM 安装残留，正在自动清理..."
        rm -rf "$HOME/.nvm"
    fi

    # 初次或清理后拉取
    if [ ! -d "$HOME/.nvm" ]; then
        info "调用 nvm-cn 国内镜像安装脚本..."
        bash -c "$(curl -fsSL https://gitee.com/RubyMetric/nvm-cn/raw/main/install.sh)"
    fi
    
    info "配置 NVM 镜像并挂载环境..."
    sed -i '/^export NVM_NODEJS_ORG_MIRROR=/d' "$HOME/.bashrc"
    echo "export NVM_NODEJS_ORG_MIRROR=$BEST_NVM" >> "$HOME/.bashrc"
    export NVM_NODEJS_ORG_MIRROR=$BEST_NVM

    # 彻底关闭严苛模式
    set +euo pipefail
    export NVM_DIR="$HOME/.nvm"
    
    # 尝试加载 nvm
    if [ -s "$NVM_DIR/nvm.sh" ]; then
        source "$NVM_DIR/nvm.sh"
        [ -s "$NVM_DIR/bash_completion" ] && source "$NVM_DIR/bash_completion"
    fi

    # 【满血恢复】第二层自愈：如果加载完发现 nvm 依然不可用，强制自愈
    if ! type nvm >/dev/null 2>&1; then
        warn "检测到本地 NVM 损坏或挂载失败，正在执行强制自愈拉取..."
        rm -rf "$HOME/.nvm"
        bash -c "$(curl -fsSL https://gitee.com/RubyMetric/nvm-cn/raw/main/install.sh)"
        
        [ -s "$NVM_DIR/nvm.sh" ] && source "$NVM_DIR/nvm.sh"
        [ -s "$NVM_DIR/bash_completion" ] && source "$NVM_DIR/bash_completion"
    fi
    
    # 终极校验并安装 Node.js
    if type nvm >/dev/null 2>&1; then
        nvm install 24 && nvm alias default 24
        npm config set registry "$BEST_NPM"
        npm install -g nrm
    else
        err "NVM 核心组件拉取彻底失败，请检查网络！"
    fi
    
    # 恢复主脚本的严苛模式
    set -euo pipefail
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

# =============================================================================
# 安装结果最终验核面板
# =============================================================================
echo -e "\n${GREEN}=========================================${NC}"
echo -e "${GREEN}           🎉 安装结果验证面板           ${NC}"
echo -e "${GREEN}=========================================${NC}"

echo -e "\n${CYAN}[基础工具链]${NC}"
command -v git >/dev/null && echo -e "🛠️  git        : $(git --version | awk '{print $3}')" || echo -e "🛠️  git        : ${RED}未安装${NC}"
command -v curl >/dev/null && echo -e "🛠️  curl       : $(curl --version | head -n 1 | awk '{print $2}')" || echo -e "🛠️  curl       : ${RED}未安装${NC}"
command -v wget >/dev/null && echo -e "🛠️  wget       : $(wget --version | head -n 1 | awk '{print $3}')" || echo -e "🛠️  wget       : ${RED}未安装${NC}"
command -v btop >/dev/null && echo -e "🛠️  btop       : $(btop --version | awk '{print $3}')" || echo -e "🛠️  btop       : ${RED}未安装${NC}"
command -v jq >/dev/null && echo -e "🛠️  jq         : $(jq --version)" || echo -e "🛠️  jq         : ${RED}未安装${NC}"
command -v tmux >/dev/null && echo -e "🛠️  tmux       : $(tmux -V | awk '{print $2}')" || echo -e "🛠️  tmux       : ${RED}未安装${NC}"

echo -e "\n${CYAN}[业务与开发组件]${NC}"
if $DO_NODE || [ -d "$HOME/.nvm" ]; then
    set +euo pipefail
    export NVM_DIR="$HOME/.nvm"
    [ -s "$NVM_DIR/nvm.sh" ] && source "$NVM_DIR/nvm.sh"
    echo -e "📦 Node.js    : $(node -v 2>/dev/null || echo -e "${RED}未安装${NC}")"
    echo -e "📦 npm        : $(npm -v 2>/dev/null && echo "v$(npm -v)" || echo -e "${RED}未安装${NC}")"
    set -euo pipefail
fi

if $DO_UV || command -v uv >/dev/null; then
    echo -e "🐍 uv         : $(uv --version 2>/dev/null || echo -e "${RED}未安装${NC}")"
fi

if $DO_VSCODE || command -v code >/dev/null; then
    echo -e "💻 VSCode     : $(code --version 2>/dev/null | head -n 1 || echo -e "${RED}未安装${NC}")"
fi

if $DO_CHROME || command -v google-chrome >/dev/null; then
    echo -e "🌐 Chrome     : $(google-chrome --version 2>/dev/null || echo -e "${RED}未安装${NC}")"
fi

if $DO_FASTFETCH || command -v fastfetch >/dev/null; then
    echo -e "📊 fastfetch  : $(fastfetch --version 2>/dev/null | awk '{print $2}' || echo -e "${RED}未安装${NC}")"
fi

echo -e "\n${YELLOW}💡 提示：所有环境配置已写入系统，强烈建议执行一次 \`source ~/.bashrc\` 或重新打开终端使所有命令生效！${NC}\n"