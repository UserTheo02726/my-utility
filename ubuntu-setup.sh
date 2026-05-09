#!/usr/bin/env bash
# =============================================================================
# Ubuntu 24.04+ 一键环境配置脚本
# Author: Theo
# Description: 配置 APT 镜像源、安装基础工具、NVM/Node.js、uv、VSCode
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# 颜色定义
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# ---------------------------------------------------------------------------
# 日志函数
# ---------------------------------------------------------------------------
log_info() {
    printf "%b[INFO]%b %s\n" "$BLUE" "$NC" "$1"
}

log_success() {
    printf "%b[SUCCESS]%b %s\n" "$GREEN" "$NC" "$1"
}

log_warn() {
    printf "%b[WARN]%b %s\n" "$YELLOW" "$NC" "$1"
}

log_error() {
    printf "%b[ERROR]%b %s\n" "$RED" "$NC" "$1"
}

log_step() {
    printf "\n%b========== %s ==========%b\n" "$BOLD" "$1" "$NC"
}

# ---------------------------------------------------------------------------
# 错误处理
# ---------------------------------------------------------------------------
cleanup_on_error() {
    local line=$1
    log_error "脚本在第 ${line} 行发生错误，已终止。"
    exit 1
}
trap 'cleanup_on_error $LINENO' ERR

# ---------------------------------------------------------------------------
# 权限检查：要求以普通用户运行，但具备 sudo 权限
# ---------------------------------------------------------------------------
check_permissions() {
    log_step "检查运行权限"

    if [ "$(id -u)" -eq 0 ]; then
        log_error "请勿以 root 身份运行此脚本。请以普通用户身份执行，脚本会自动调用 sudo。"
        exit 1
    fi

    log_info "当前用户: $(whoami)"

    # 测试 sudo 权限，并缓存密码
    if ! sudo -n true 2>/dev/null; then
        log_warn "需要 sudo 权限，请输入当前用户密码："
        sudo -v || {
            log_error "sudo 认证失败，请检查密码是否正确。"
            exit 1
        }
    fi

    # 保持 sudo 会话活跃（每 60 秒刷新一次）
    while true; do
        sudo -n true
        sleep 60
    done 2>/dev/null &
    SUDO_KEEPALIVE_PID=$!

    log_success "sudo 权限验证通过"
}

# ---------------------------------------------------------------------------
# APT 镜像源配置（交互式选择，15 秒超时自动回退到阿里云）
# ---------------------------------------------------------------------------
configure_apt_mirror() {
    log_step "配置 APT 镜像源"

    local SOURCES_FILE="/etc/apt/sources.list.d/ubuntu.sources"
    local BACKUP_FILE="${SOURCES_FILE}.bak"

    # 检测是否为 Ubuntu 24.04+（deb822 格式）
    if [ ! -f "$SOURCES_FILE" ]; then
        log_warn "未找到 ${SOURCES_FILE}，可能不是 Ubuntu 24.04+，尝试检测 /etc/apt/sources.list..."
        SOURCES_FILE="/etc/apt/sources.list"
        if [ ! -f "$SOURCES_FILE" ]; then
            log_error "无法找到 APT 源配置文件，请手动检查。"
            exit 1
        fi
        BACKUP_FILE="${SOURCES_FILE}.bak"
    fi

    # 备份原文件
    if [ ! -f "$BACKUP_FILE" ]; then
        sudo cp "$SOURCES_FILE" "$BACKUP_FILE"
        log_info "已备份原配置到 ${BACKUP_FILE}"
    else
        log_warn "备份文件已存在，跳过备份"
    fi

    # 镜像源选项
    local MIRRORS=(
        "阿里云|https://mirrors.aliyun.com/ubuntu/"
        "清华大学|https://mirrors.tuna.tsinghua.edu.cn/ubuntu/"
        "中国科学技术大学|https://mirrors.ustc.edu.cn/ubuntu/"
        "华为云|https://repo.huaweicloud.com/ubuntu/"
    )

    printf "\n%b请选择 APT 镜像源（15 秒内无输入将自动选择 阿里云）：%b\n" "$CYAN" "$NC"
    for i in "${!MIRRORS[@]}"; do
        local name=${MIRRORS[$i]%%|*}
        printf "  %b[%d]%b %s\n" "$BOLD" "$((i + 1))" "$NC" "$name"
    done
    printf "  %b[1-4]%b 或直接回车使用默认（阿里云）\n" "$YELLOW" "$NC"
    printf "%b等待输入...%b\n" "$YELLOW" "$NC"

    local choice=""
    # 使用 read -t 15 实现 15 秒超时
    if IFS= read -r -t 15 choice </dev/tty 2>/dev/null || true; then
        case "$choice" in
            1) SELECTED_MIRROR="${MIRRORS[0]}" ;;
            2) SELECTED_MIRROR="${MIRRORS[1]}" ;;
            3) SELECTED_MIRROR="${MIRRORS[2]}" ;;
            4) SELECTED_MIRROR="${MIRRORS[3]}" ;;
            "") SELECTED_MIRROR="${MIRRORS[0]}" ;;
            *)
                log_warn "无效输入，使用默认镜像源：阿里云"
                SELECTED_MIRROR="${MIRRORS[0]}"
                ;;
        esac
    else
        printf "\n"
        log_warn "输入超时，自动选择默认镜像源：阿里云"
        SELECTED_MIRROR="${MIRRORS[0]}"
    fi

    local MIRROR_NAME=${SELECTED_MIRROR%%|*}
    local MIRROR_URL=${SELECTED_MIRROR#*|}

    log_info "选择的镜像源: ${MIRROR_NAME} (${MIRROR_URL})"

    # 替换镜像源
    if [[ "$SOURCES_FILE" == *"ubuntu.sources" ]]; then
        # Ubuntu 24.04+ deb822 格式
        sudo sed -i "s|URIs: http://archive.ubuntu.com/ubuntu/|URIs: ${MIRROR_URL}|g" "$SOURCES_FILE"
        sudo sed -i "s|URIs: http://security.ubuntu.com/ubuntu/|URIs: ${MIRROR_URL}|g" "$SOURCES_FILE"
        # 也尝试替换 https 版本
        sudo sed -i "s|URIs: https://archive.ubuntu.com/ubuntu/|URIs: ${MIRROR_URL}|g" "$SOURCES_FILE"
        sudo sed -i "s|URIs: https://security.ubuntu.com/ubuntu/|URIs: ${MIRROR_URL}|g" "$SOURCES_FILE"
    else
        # 传统格式
        sudo sed -i "s|http://archive.ubuntu.com/ubuntu|${MIRROR_URL}|g" "$SOURCES_FILE"
        sudo sed -i "s|http://security.ubuntu.com/ubuntu|${MIRROR_URL}|g" "$SOURCES_FILE"
        sudo sed -i "s|https://archive.ubuntu.com/ubuntu|${MIRROR_URL}|g" "$SOURCES_FILE"
        sudo sed -i "s|https://security.ubuntu.com/ubuntu|${MIRROR_URL}|g" "$SOURCES_FILE"
    fi

    log_success "APT 镜像源已替换为 ${MIRROR_NAME}"

    # 更新索引
    log_info "正在更新软件包索引..."
    sudo apt update
    log_success "软件包索引更新完成"

    # 升级系统（可选，用户确认）
    log_info "是否执行系统升级？(y/N，10 秒超时默认 N)"
    local upgrade_choice=""
    if IFS= read -r -t 10 upgrade_choice </dev/tty 2>/dev/null || true; then
        if [[ "$upgrade_choice" =~ ^[Yy]$ ]]; then
            log_info "正在升级系统软件包..."
            sudo apt upgrade -y
            log_success "系统升级完成"
        else
            log_info "跳过系统升级"
        fi
    else
        printf "\n"
        log_info "超时，跳过系统升级"
    fi
}

# ---------------------------------------------------------------------------
# 安装基础工具
# ---------------------------------------------------------------------------
install_base_tools() {
    log_step "安装基础工具"

    local packages=(
        git
        curl
        wget
        openssh-server
        build-essential
        fastfetch
        unzip
        gnome-sushi
        tar
    )

    log_info "即将安装: ${packages[*]}"
    sudo apt install -y "${packages[@]}"

    log_success "基础工具安装完成"
}

# ---------------------------------------------------------------------------
# 配置 openssh-server（自启动 + 开放端口）
# ---------------------------------------------------------------------------
configure_ssh() {
    log_step "配置 SSH 服务"

    # 启动 SSH 服务
    if ! sudo systemctl is-active --quiet ssh; then
        log_info "启动 ssh 服务..."
        sudo systemctl start ssh
    else
        log_info "ssh 服务已在运行"
    fi

    # 设置开机自启
    if ! sudo systemctl is-enabled --quiet ssh 2>/dev/null; then
        log_info "设置 ssh 开机自启..."
        sudo systemctl enable ssh
    else
        log_info "ssh 已设置为开机自启"
    fi

    # 开放防火墙端口（如果 ufw 已安装且启用）
    if command -v ufw &>/dev/null; then
        if sudo ufw status | grep -q "Status: active"; then
            log_info "防火墙已启用，开放 SSH 端口 (22/tcp)..."
            sudo ufw allow 22/tcp || log_warn "ufw 规则添加可能失败，请手动检查"
        else
            log_warn "ufw 已安装但未启用，跳过端口开放"
        fi
    else
        log_warn "未检测到 ufw，跳过防火墙配置（如有其他防火墙请手动开放 22 端口）"
    fi

    log_success "SSH 服务配置完成"
    log_info "SSH 状态: $(sudo systemctl is-active ssh)"
}

# ---------------------------------------------------------------------------
# 安装 NVM、Node.js v24，配置 npm 镜像，安装 nrm
# ---------------------------------------------------------------------------
install_nvm_node() {
    log_step "安装 NVM 和 Node.js"

    # 安装 NVM
    if [ -d "$HOME/.nvm" ]; then
        log_warn "检测到已存在 ~/.nvm 目录，跳过 NVM 安装"
    else
        log_info "正在安装 NVM v0.40.4..."
        curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.4/install.sh | bash
        log_success "NVM 安装完成"
    fi

    # 配置 .bashrc
    local BASHRC="$HOME/.bashrc"
    local NVM_CONFIG_MARK="# === NVM Configuration ==="

    if ! grep -q "$NVM_CONFIG_MARK" "$BASHRC" 2>/dev/null; then
        log_info "配置 ~/.bashrc..."
        cat >> "$BASHRC" << 'EOF'

# === NVM Configuration ===
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"

# 国内镜像加速 Node.js 下载
export NVM_NODEJS_ORG_MIRROR=https://npmmirror.com/mirrors/node
EOF
        log_success "NVM 配置已写入 ~/.bashrc"
    else
        log_warn "~/.bashrc 中已存在 NVM 配置，跳过写入"
    fi

    # 加载 NVM 环境
    export NVM_DIR="$HOME/.nvm"
    [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
    
    # 自动 source ~/.bashrc 确保环境变量生效
    if [ -f "$HOME/.bashrc" ]; then
        source "$HOME/.bashrc"
        log_info "已自动 source ~/.bashrc"
    fi

    # 验证 NVM
    if ! command -v nvm &>/dev/null; then
        log_error "NVM 加载失败，请检查 ~/.bashrc 配置或手动执行 source ~/.bashrc"
        exit 1
    fi

    local NVM_VERSION
    NVM_VERSION=$(nvm --version)
    log_success "NVM 版本: ${NVM_VERSION}"
    log_info "NVM 镜像源: ${NVM_NODEJS_ORG_MIRROR:-未设置}"

    # 安装 Node.js v24
    log_info "正在安装 Node.js v24 (LTS)..."
    nvm install 24
    nvm use 24
    nvm alias default 24

    log_success "Node.js 安装完成"
    log_info "Node.js 版本: $(node --version)"
    log_info "npm 版本: $(npm --version)"

    # 配置 npm 国内镜像
    log_info "配置 npm 镜像源为 npmmirror..."
    npm config set registry https://registry.npmmirror.com
    log_success "npm 镜像源已设置为: $(npm config get registry)"

    # 安装 nrm
    log_info "全局安装 nrm..."
    npm install -g nrm
    log_success "nrm 安装完成"
    log_info "可用镜像源列表:"
    nrm ls || true
}

# ---------------------------------------------------------------------------
# 安装 uv
# ---------------------------------------------------------------------------
install_uv() {
    log_step "安装 uv"

    if command -v uv &>/dev/null; then
        log_warn "uv 已安装，版本: $(uv --version)"
        return 0
    fi

    log_info "正在执行 uv 官方一键安装脚本..."
    curl -LsSf https://astral.sh/uv/install.sh | sh

    # 确保 PATH 包含 ~/.local/bin
    if [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
        export PATH="$HOME/.local/bin:$PATH"
        echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.bashrc"
        log_info "已将 ~/.local/bin 添加到 PATH"
    fi
    
    # 自动 source ~/.bashrc 确保环境变量生效
    if [ -f "$HOME/.bashrc" ]; then
        source "$HOME/.bashrc"
        log_info "已自动 source ~/.bashrc"
    fi

    if command -v uv &>/dev/null; then
        log_success "uv 安装完成，版本: $(uv --version)"
    else
        log_warn "uv 安装后未在 PATH 中找到，请重新登录或执行 source ~/.bashrc"
    fi
}

# ---------------------------------------------------------------------------
# 安装 VSCode 并配置 settings.json
# ---------------------------------------------------------------------------
install_vscode() {
    log_step "安装 VSCode"

    if command -v code &>/dev/null; then
        log_warn "VSCode 已安装，版本: $(code --version | head -n1)"
    else
        log_info "添加 Microsoft GPG 密钥..."
        sudo sh -c 'wget -qO- https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor > /usr/share/keyrings/packages.microsoft.gpg'

        log_info "添加 VSCode APT 仓库..."
        sudo sh -c 'echo "deb [arch=amd64 signed-by=/usr/share/keyrings/packages.microsoft.gpg] https://packages.microsoft.com/repos/code stable main" > /etc/apt/sources.list.d/vscode.list'

        log_info "更新索引并安装 VSCode..."
        sudo apt update
        sudo apt install -y code

        log_success "VSCode 安装完成"
    fi

    # 配置 settings.json
    local VSCODE_CONFIG_DIR="$HOME/.config/Code/User"
    local VSCODE_SETTINGS="${VSCODE_CONFIG_DIR}/settings.json"

    mkdir -p "$VSCODE_CONFIG_DIR"

    log_info "创建 VSCode settings.json..."
    cat > "$VSCODE_SETTINGS" << 'EOF'
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

    log_success "VSCode settings.json 已创建: ${VSCODE_SETTINGS}"
}

# ---------------------------------------------------------------------------
# 最终验证
# ---------------------------------------------------------------------------
verify_installations() {
    log_step "验证安装结果"

    local tools=(
        "git|Git"
        "curl|cURL"
        "wget|Wget"
        "ssh|OpenSSH"
        "fastfetch|Fastfetch"
        "node|Node.js"
        "npm|npm"
        "nrm|nrm"
        "uv|uv"
        "code|VSCode"
    )

    printf "\n%b%-20s %-15s %s%b\n" "$BOLD" "工具" "状态" "版本" "$NC"
    printf "%s\n" "---------------------------------------------------------"

    for item in "${tools[@]}"; do
        local cmd=${item%%|*}
        local name=${item#*|}

        if command -v "$cmd" &>/dev/null; then
            local version
            case "$cmd" in
                git) version=$(git --version 2>/dev/null | awk '{print $3}') ;;
                ssh) version=$(ssh -V 2>&1 | awk '{print $1}') ;;
                node) version=$(node --version 2>/dev/null) ;;
                npm) version=$(npm --version 2>/dev/null) ;;
                nrm) version=$(nrm --version 2>/dev/null) ;;
                uv) version=$(uv --version 2>/dev/null | awk '{print $2}') ;;
                code) version=$(code --version 2>/dev/null | head -n1) ;;
                *) version=$($cmd --version 2>/dev/null | head -n1) ;;
            esac
            printf "%b%-20s %-15s %s%b\n" "$GREEN" "$name" "✓ 已安装" "${version:-未知}" "$NC"
        else
            printf "%b%-20s %-15s %s%b\n" "$RED" "$name" "✗ 未找到" "" "$NC"
        fi
    done

    printf "\n%bSSH 服务状态:%b %s\n" "$CYAN" "$NC" "$(sudo systemctl is-active ssh 2>/dev/null || echo 'unknown')"
    printf "%bNVM 镜像源:%b %s\n" "$CYAN" "$NC" "${NVM_NODEJS_ORG_MIRROR:-未设置}"
    printf "%bnpm 镜像源:%b %s\n" "$CYAN" "$NC" "$(npm config get registry 2>/dev/null || echo 'unknown')"
}

# ---------------------------------------------------------------------------
# 主函数
# ---------------------------------------------------------------------------
main() {
    printf "%b\n" "$CYAN"
    cat << 'EOF'
   _    _ _                 _   _       _       _   _
  / \  | | | ___  _   _  __| | | | ___ | |_ ___| | | |
 / _ \ | | |/ _ \| | | |/ _` | | |/ _ \| __/ _ \ | | |
/ ___ \| | | (_) | |_| | (_| | | | (_) | ||  __/ |_| |
/_/   \_\_|_|\___/ \__,_|\__,_| |_|\___/ \__\___|\___/

EOF
    printf "%b" "$NC"
    printf "%bUbuntu 24.04+ 一键环境配置脚本%b\n\n" "$BOLD" "$NC"

    check_permissions
    configure_apt_mirror
    install_base_tools
    configure_ssh
    install_nvm_node
    install_uv
    install_vscode
    verify_installations

    log_step "配置完成"
    log_success "所有步骤执行完毕！建议重新登录或执行 source ~/.bashrc 以确保所有环境变量生效。"

    # 清理 sudo keepalive 进程
    if [ -n "${SUDO_KEEPALIVE_PID:-}" ]; then
        kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
    fi
}

main "$@"