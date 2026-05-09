#!/usr/bin/env bash
# =============================================================================
# Ubuntu 24.04+ 一键环境配置 (极简重构版)
# =============================================================================
set -euo pipefail

# --- 1. 基础设置与权限 ---
GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
info() { echo -e "${GREEN}[INFO]${NC} $1"; }
err()  { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

[ "$(id -u)" -eq 0 ] && err "请勿以 root 运行，需使用具备 sudo 权限的普通用户。"
sudo -v || err "sudo 认证失败"
# 后台维持 sudo 权限
while true; do sudo -n true; sleep 60; done 2>/dev/null &
trap 'kill $! 2>/dev/null || true' EXIT

# --- 2. 组件定义区 (标识:描述:默认状态) ---
COMPONENTS=(
    "UPGRADE:执行系统升级 (apt upgrade):OFF"
    "SSH:SSH 服务与放行 22 端口:ON"
    "FASTFETCH:Fastfetch 系统信息:ON"
    "SUSHI:Gnome-sushi 文件预览:ON"
    "NODE:NVM & Node.js v24:ON"
    "UV:uv Python 包管理器:ON"
    "VSCODE:Visual Studio Code:ON"
    "CHROME:Google Chrome 浏览器:ON"
)

# --- 3. 交互菜单构建 ---
info "拉起组件选择菜单..."
CHOICES=""
if command -v whiptail >/dev/null; then
    ARGS=()
    for c in "${COMPONENTS[@]}"; do
        IFS=':' read -r id desc status <<< "$c"
        ARGS+=("$id" "$desc" "$status")
    done
    CHOICES=$(whiptail --title "环境配置" --checklist "空格选择，回车确认。基础开发工具将强制安装。\n" 20 60 10 "${ARGS[@]}" 3>&1 1>&2 2>&3 || true)
    CHOICES=$(echo "$CHOICES" | tr -d '"')
else
    info "未检测到 whiptail，已默认开启预设为 ON 的组件。"
    for c in "${COMPONENTS[@]}"; do
        [[ "$c" == *:ON ]] && CHOICES="$CHOICES ${c%%:*}"
    done
fi
has_comp() { echo "$CHOICES" | grep -qw "$1"; }

# --- 4. 镜像源配置与系统更新 ---
info "切换 APT 镜像源为阿里云..."
SRC="/etc/apt/sources.list.d/ubuntu.sources"
[ ! -f "$SRC" ] && SRC="/etc/apt/sources.list"
sudo cp -n "$SRC" "${SRC}.bak" || true
sudo sed -i -E 's/(archive|security)\.ubuntu\.com/mirrors.aliyun.com/g' "$SRC"
sudo apt update -y

has_comp "UPGRADE" && { info "执行系统升级..."; sudo apt upgrade -y; }

# --- 5. 批量安装 APT 软件 ---
APT_PKGS=(git curl wget build-essential unzip tar) # 强制的基础工具
has_comp "SSH" && APT_PKGS+=(openssh-server)
has_comp "FASTFETCH" && APT_PKGS+=(fastfetch)
has_comp "SUSHI" && APT_PKGS+=(gnome-sushi)

info "正在批量安装 APT 组件包..."
sudo apt install -y "${APT_PKGS[@]}"

# --- 6. 独立组件配置逻辑 ---
has_comp "SSH" && command -v ufw >/dev/null && { sudo ufw allow 22/tcp >/dev/null || true; }

if has_comp "NODE"; then
    info "部署 NVM 与 Node.js 24..."
    export NVM_DIR="$HOME/.nvm"
    if [ ! -d "$NVM_DIR" ]; then
        curl -sL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.4/install.sh | bash
        [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
        nvm install 24 && nvm alias default 24
        npm config set registry https://registry.npmmirror.com
        npm install -g nrm
    fi
fi

if has_comp "UV"; then
    info "部署 uv..."
    command -v uv >/dev/null || curl -LsSf https://astral.sh/uv/install.sh | sh
fi

if has_comp "VSCODE"; then
    info "部署 VSCode..."
    if ! command -v code >/dev/null; then
        wget -qO- https://packages.microsoft.com/keys/microsoft.asc | sudo gpg --dearmor -y -o /usr/share/keyrings/packages.microsoft.gpg
        echo "deb [arch=amd64 signed-by=/usr/share/keyrings/packages.microsoft.gpg] https://packages.microsoft.com/repos/code stable main" | sudo tee /etc/apt/sources.list.d/vscode.list >/dev/null
        sudo apt update -y && sudo apt install -y code
    fi
    # 写入核心 User Settings
    VS_DIR="$HOME/.config/Code/User"
    mkdir -p "$VS_DIR"
    cat > "$VS_DIR/settings.json" << 'EOF'
{
    "workbench.colorTheme": "Dark Modern",
    "editor.mouseWheelZoom": true,
    "editor.wordWrap": "on",
    "editor.formatOnSave": true,
    "editor.minimap.enabled": true
}
EOF
fi

if has_comp "CHROME"; then
    info "部署 Google Chrome..."
    if ! command -v google-chrome >/dev/null; then
        wget -qO /tmp/chrome.deb https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb
        sudo apt install -y /tmp/chrome.deb && rm -f /tmp/chrome.deb
    fi
fi

info "✅ 环境配置全部完成！建议执行 'source ~/.bashrc' 或注销重新登录以使环境变量生效。"