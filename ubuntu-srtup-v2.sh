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
    local -a mirrors
    read -r -a mirrors <<< "$1"
    local best_mirror="${mirrors[0]}"
    local best_time=999
    local t
    for m in "${mirrors[@]}"; do
        [ -z "$m" ] && continue
        t=$(curl -o /dev/null -s -w "%{time_total}" -m 3 "$m" 2>/dev/null || echo "999")
        if awk "BEGIN {exit !($t+0 < $best_time+0)}"; then
            best_time=$t
            best_mirror=$m
        fi
    done
    echo "$best_mirror"
}

# ── 权限预检 ──────────────────────────────────────────────────────────────────
[ "$(id -u)" -eq 0 ] && err "请勿以 root 运行，需使用具备 sudo 权限的普通用户。"
sudo -v || err "sudo 认证失败"
while true; do sudo -n true; sleep 60; done 2>/dev/null &
SUDO_KEEPALIVE_PID=$!
trap 'kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true' EXIT

# ── 系统环境预检 ──────────────────────────────────────────────────────────────
echo -e "\n${GREEN}=== 系统环境预检 ===${NC}"
UBUNTU_VER=$(grep -oP '(?<=^VERSION_ID=")[^"]+' /etc/os-release)
ARCH=$(uname -m)
DEB_ARCH="amd64"
[ "$ARCH" = "aarch64" ] && DEB_ARCH="arm64"

ENV_TYPE="Server"
IS_WSL=false; IS_ORBSTACK=false; IS_DESKTOP=false

if uname -a | grep -qi "orbstack"; then
    ENV_TYPE="OrbStack"; IS_ORBSTACK=true
elif grep -qi microsoft /proc/version 2>/dev/null || [ -n "${WSL_DISTRO_NAME:-}" ]; then
    ENV_TYPE="WSL"; IS_WSL=true
elif dpkg-query -W -f='${Status}' ubuntu-desktop 2>/dev/null | grep -q "ok installed" || \
     dpkg-query -W -f='${Status}' ubuntu-desktop-minimal 2>/dev/null | grep -q "ok installed"; then
    ENV_TYPE="Desktop"; IS_DESKTOP=true
fi

echo "系统: Ubuntu $UBUNTU_VER | 架构: $ARCH | 环境: $ENV_TYPE"

# ── 定制选项 ──────────────────────────────────────────────────────────────────
echo -e "\n${GREEN}=== 定制安装选项 (回车默认) ===${NC}"
DO_UPGRADE=false; DO_FASTFETCH=false
DO_NODE=false; DO_UV=false; DO_VSCODE=false; DO_CHROME=false

ask "执行系统升级 (耗时较长, apt upgrade)" "N" && DO_UPGRADE=true
ask "安装 fastfetch 系统信息" "Y"             && DO_FASTFETCH=true
ask "安装 NVM & Node.js 24" "Y"              && DO_NODE=true
ask "安装 uv (Python包管理器)" "Y"            && DO_UV=true
if $IS_DESKTOP || $IS_WSL; then
    ask "安装 Visual Studio Code" "Y"         && DO_VSCODE=true
    [ "$DEB_ARCH" != "arm64" ] && ask "安装 Google Chrome" "Y" && DO_CHROME=true
fi

echo -e "\n${GREEN}=== 开始全自动配置 ===${NC}"

# ── 1. APT 源 & 基础工具 ──────────────────────────────────────────────────────
info "配置 APT 加速源并确保多格式一致..."
APT_MIRRORS="http://archive.ubuntu.com/ubuntu/ http://mirrors.aliyun.com/ubuntu/ http://mirrors.tuna.tsinghua.edu.cn/ubuntu/ http://mirrors.ustc.edu.cn/ubuntu/"
BEST_APT=$(get_fastest_mirror "$APT_MIRRORS")
BEST_APT_HOST=$(echo "$BEST_APT" | awk -F'/' '{print $3}')

SRC_DEB822="/etc/apt/sources.list.d/ubuntu.sources"
SRC_LEGACY="/etc/apt/sources.list"

if [ -f "$SRC_DEB822" ]; then
    sudo cp --update=none "$SRC_DEB822" "${SRC_DEB822}.bak" || true
    sudo sed -i -E "s|^(URIs:[[:space:]]*https?://)([^/]+)(/.*)|\1${BEST_APT_HOST}\3|g" "$SRC_DEB822"
    info "已同步 DEB822 源 ($SRC_DEB822) → $BEST_APT_HOST"
fi

if [ -f "$SRC_LEGACY" ] && grep -q '^deb' "$SRC_LEGACY"; then
    sudo cp --update=none "$SRC_LEGACY" "${SRC_LEGACY}.bak" || true
    sudo sed -i -E "s|^(deb[-a-z]*[[:space:]]+https?://)([^/]+)(/.*)|\1${BEST_APT_HOST}\3|g" "$SRC_LEGACY"
    info "已同步 Legacy 源 ($SRC_LEGACY) → $BEST_APT_HOST"
fi

sudo DEBIAN_FRONTEND=noninteractive apt-get update -y || warn "apt update 存在警告"

if $DO_UPGRADE; then
    info "执行系统全局升级..."
    sudo DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
fi

info "安装基础工具..."
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    git curl wget build-essential unzip tar ca-certificates \
    btop jq tmux software-properties-common gnupg apt-transport-https

# ── 2. fastfetch ──────────────────────────────────────────────────────────────
if $DO_FASTFETCH; then
    info "部署 fastfetch..."
    # Ubuntu 24.04+ 官方源已内置 fastfetch，无需 PPA
    if dpkg --compare-versions "$UBUNTU_VER" lt "24.04"; then
        info "Ubuntu $UBUNTU_VER < 24.04，添加 fastfetch PPA..."
        sudo add-apt-repository -y ppa:zhangsongcui3371/fastfetch
        sudo apt-get update -y
    fi
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y fastfetch \
        || warn "fastfetch 安装失败，已跳过"
fi

# ── 3. Node.js via NVM ────────────────────────────────────────────────────────
if $DO_NODE; then
    info "寻找最优 NVM/NPM 镜像..."
    NVM_MIRRORS="https://npmmirror.com/mirrors/node/ https://mirrors.tuna.tsinghua.edu.cn/nodejs-release/ https://nodejs.org/dist/"
    NPM_MIRRORS="https://registry.npmmirror.com/ https://mirrors.cloud.tencent.com/npm/ https://registry.npmjs.org/"
    BEST_NVM=$(get_fastest_mirror "$NVM_MIRRORS")
    BEST_NPM=$(get_fastest_mirror "$NPM_MIRRORS")

    if [ -d "$HOME/.nvm" ] && [ ! -s "$HOME/.nvm/nvm.sh" ]; then
        warn "检测到残缺 NVM，自动清理..."
        rm -rf "$HOME/.nvm"
    fi

    if [ ! -d "$HOME/.nvm" ]; then
        info "安装 NVM（国内镜像）..."
        bash -c "$(curl -fsSL https://gitee.com/RubyMetric/nvm-cn/raw/main/install.sh)"
    fi

    sed -i '/^export NVM_NODEJS_ORG_MIRROR=/d' "$HOME/.bashrc"
    echo "export NVM_NODEJS_ORG_MIRROR=$BEST_NVM" >> "$HOME/.bashrc"
    export NVM_NODEJS_ORG_MIRROR=$BEST_NVM
    export NVM_DIR="$HOME/.nvm"

    set +euo pipefail
    [ -s "$NVM_DIR/nvm.sh" ] && source "$NVM_DIR/nvm.sh"
    [ -s "$NVM_DIR/bash_completion" ] && source "$NVM_DIR/bash_completion"

    if ! type nvm >/dev/null 2>&1; then
        warn "NVM 加载失败，强制重装..."
        rm -rf "$HOME/.nvm"
        bash -c "$(curl -fsSL https://gitee.com/RubyMetric/nvm-cn/raw/main/install.sh)"
        [ -s "$NVM_DIR/nvm.sh" ] && source "$NVM_DIR/nvm.sh"
        [ -s "$NVM_DIR/bash_completion" ] && source "$NVM_DIR/bash_completion"
    fi

    if type nvm >/dev/null 2>&1; then
        nvm install 24 && nvm alias default 24
        npm config set registry "$BEST_NPM"
        npm install -g nrm
    else
        set -euo pipefail
        err "NVM 安装彻底失败，请检查网络！"
    fi
    set -euo pipefail
fi

# ── 4. uv ─────────────────────────────────────────────────────────────────────
if $DO_UV; then
    info "部署 uv..."
    export PATH="$HOME/.local/bin:$PATH"

    if ! command -v uv >/dev/null 2>&1; then
        info "调用 uv 官方安装脚本..."
        curl -LsSf https://astral.sh/uv/install.sh | sh
        export PATH="$HOME/.local/bin:$PATH"
    else
        warn "uv 已存在，跳过安装"
    fi

    info "配置最优 PyPI 镜像..."
    PYPI_MIRRORS="https://pypi.tuna.tsinghua.edu.cn/simple https://mirrors.aliyun.com/pypi/simple https://mirrors.cloud.tencent.com/pypi/simple https://pypi.org/simple"
    BEST_PYPI=$(get_fastest_mirror "$PYPI_MIRRORS")

    sed -i '/^export UV_INDEX_URL=/d' "$HOME/.bashrc"
    echo "export UV_INDEX_URL=$BEST_PYPI" >> "$HOME/.bashrc"

    if ! grep -qF '.local/bin' "$HOME/.bashrc"; then
        echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.bashrc"
    fi
fi

# ── 5. VSCode ─────────────────────────────────────────────────────────────────
if $DO_VSCODE; then
    info "部署 VSCode..."
    if ! command -v code >/dev/null 2>&1; then
        TMP_KEY=$(mktemp --suffix=.asc)
        info "下载 Microsoft GPG Key..."
        if curl -fsSL https://packages.microsoft.com/keys/microsoft.asc -o "$TMP_KEY" \
            && [ -s "$TMP_KEY" ]; then
            sudo gpg --dearmor --yes \
                -o /usr/share/keyrings/packages.microsoft.gpg "$TMP_KEY"
            rm -f "$TMP_KEY"
            echo "deb [arch=${DEB_ARCH} signed-by=/usr/share/keyrings/packages.microsoft.gpg] \
https://packages.microsoft.com/repos/code stable main" \
                | sudo tee /etc/apt/sources.list.d/vscode.list >/dev/null
            sudo apt-get update -y
            sudo DEBIAN_FRONTEND=noninteractive apt-get install -y code
        else
            rm -f "$TMP_KEY"
            warn "Microsoft GPG Key 下载失败，跳过 VSCode 安装"
        fi
    else
        warn "VSCode 已存在，跳过安装"
    fi

    VS_DIR="$HOME/.config/Code/User"
    mkdir -p "$VS_DIR"
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

# ── 6. Chrome ─────────────────────────────────────────────────────────────────
if $DO_CHROME; then
    info "部署 Chrome..."
    if ! command -v google-chrome >/dev/null 2>&1; then
        wget -qO /tmp/chrome.deb \
            https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb || true
        if [ -s /tmp/chrome.deb ]; then
            sudo DEBIAN_FRONTEND=noninteractive apt-get install -y /tmp/chrome.deb \
                || warn "Chrome 安装失败"
        else
            warn "Chrome 下载失败，已跳过"
        fi
        rm -f /tmp/chrome.deb
    else
        warn "Chrome 已存在，跳过安装"
    fi
fi

# ── 验证面板 ──────────────────────────────────────────────────────────────────
echo -e "\n${GREEN}=========================================${NC}"
echo -e "${GREEN}           🎉 安装结果验证面板           ${NC}"
echo -e "${GREEN}=========================================${NC}"

echo -e "\n${CYAN}[基础工具链]${NC}"
_check() {
    local icon="$1" label="$2"; shift 2
    local ver
    if ver=$("$@" 2>/dev/null); then
        printf "%s  %-12s: %s\n" "$icon" "$label" "$ver"
    else
        echo -e "${icon}  ${label}       : ${RED}未安装${NC}"
    fi
}

_check "🛠️"  "git"        git --version     | awk '{print $3}'
_check "🛠️"  "curl"       curl --version    | head -n1 | awk '{print $2}'
_check "🛠️"  "wget"       wget --version    | head -n1 | awk '{print $3}'
_check "🛠️"  "btop"       btop --version    | awk '{print $3}'
_check "🛠️"  "jq"         jq --version
_check "🛠️"  "tmux"       tmux -V           | awk '{print $2}'

echo -e "\n${CYAN}[业务与开发组件]${NC}"

if $DO_NODE; then
    set +euo pipefail
    export NVM_DIR="$HOME/.nvm"
    [ -s "$NVM_DIR/nvm.sh" ] && source "$NVM_DIR/nvm.sh"

    node_ver=$(node -v 2>/dev/null || true)
    npm_ver=$(npm -v 2>/dev/null || true)

    [ -n "$node_ver" ] \
        && echo -e "📦  Node.js      : $node_ver" \
        || echo -e "📦  Node.js      : ${RED}未安装${NC}"
    [ -n "$npm_ver" ] \
        && echo -e "📦  npm          : v$npm_ver" \
        || echo -e "📦  npm          : ${RED}未安装${NC}"
    set -euo pipefail
fi

if $DO_UV; then
    uv_ver=$(uv --version 2>/dev/null || true)
    [ -n "$uv_ver" ] \
        && echo -e "🐍  uv           : $uv_ver" \
        || echo -e "🐍  uv           : ${RED}未安装${NC}"
fi

if $DO_VSCODE; then
    code_ver=$(code --version 2>/dev/null | head -n1 || true)
    [ -n "$code_ver" ] \
        && echo -e "💻  VSCode       : $code_ver" \
        || echo -e "💻  VSCode       : ${RED}未安装${NC}"
fi

if $DO_CHROME; then
    chrome_ver=$(google-chrome --version 2>/dev/null || true)
    [ -n "$chrome_ver" ] \
        && echo -e "🌐  Chrome       : $chrome_ver" \
        || echo -e "🌐  Chrome       : ${RED}未安装${NC}"
fi

if $DO_FASTFETCH; then
    ff_ver=$(fastfetch --version 2>/dev/null | awk '{print $2}' || true)
    [ -n "$ff_ver" ] \
        && echo -e "📊  fastfetch    : $ff_ver" \
        || echo -e "📊  fastfetch    : ${RED}未安装${NC}"
fi

echo -e "\n${YELLOW}💡 提示：请执行 \`source ~/.bashrc\` 或重开终端使所有配置生效。${NC}\n"