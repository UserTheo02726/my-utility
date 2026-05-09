#!/usr/bin/env bash
# =============================================================================
# Ubuntu 24.04+ 一键环境配置（无脑轻便 + 组件选择）
# 特性：whiptail 菜单自选组件、安全清理、网络重试、智能不覆盖
# =============================================================================
set -euo pipefail

# ---------- 颜色 ----------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log_info()    { printf "%b[INFO]%b %s\n" "$BLUE" "$NC" "$1"; }
log_success() { printf "%b[SUCCESS]%b %s\n" "$GREEN" "$NC" "$1"; }
log_warn()    { printf "%b[WARN]%b %s\n" "$YELLOW" "$NC" "$1"; }
log_error()   { printf "%b[ERROR]%b %s\n" "$RED" "$NC" "$1"; }
log_step()    { printf "\n%b========== %s ==========%b\n" "$BOLD" "$1" "$NC"; }

# ---------- 资源清理 ----------
SUDO_KEEPALIVE_PID=""
cleanup() {
    [ -n "${SUDO_KEEPALIVE_PID:-}" ] && kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
}
trap cleanup EXIT

cleanup_on_error() {
    log_error "脚本在第 ${1} 行发生错误，已终止。"
    exit 1
}
trap 'cleanup_on_error $LINENO' ERR

# ---------- 网络重试 ----------
curl_retry() { curl --retry 3 --retry-delay 2 --retry-connrefused -sSL "$@"; }
wget_retry() { wget --tries=3 --retry-connrefused -q "$@"; }

# ---------- 权限 ----------
check_permissions() {
    log_step "检查运行权限"
    [ "$(id -u)" -eq 0 ] && { log_error "请勿以 root 运行。"; exit 1; }
    log_info "当前用户: $(whoami)"
    if ! sudo -n true 2>/dev/null; then
        log_warn "需要 sudo 权限，请输入当前用户密码："
        sudo -v || { log_error "sudo 认证失败"; exit 1; }
    fi
    while true; do sudo -n true; sleep 60; done 2>/dev/null &
    SUDO_KEEPALIVE_PID=$!
    log_success "sudo 权限验证通过"
}

# ---------- 组件选择菜单 ----------
select_components() {
    log_step "选择要安装的组件"

    # 必须安装的基础工具在菜单外说明，此处只列可选组件
    local choices
    local title="安装组件选择"
    local menu_text="使用 上下键 移动，空格 选择/取消，回车 确认。\n基础工具 (git,curl,wget...) 将强制安装。"

    # 检查 whiptail / dialog 是否存在
    if command -v whiptail &>/dev/null; then
        # whiptail checklist: 每个条目 "tag" "描述" "初始状态"
        choices=$(whiptail --title "$title" --checklist "$menu_text" 20 78 10 \
            "system_upgrade" "执行系统升级 (apt upgrade)" OFF \
            "ssh" "SSH 服务 (openssh-server + 防火墙)" ON \
            "fastfetch" "fastfetch 系统信息" ON \
            "gnome_sushi" "gnome-sushi 文件预览 (桌面)" ON \
            "nvm_node" "NVM & Node.js v24" ON \
            "uv" "uv Python 包管理器" ON \
            "vscode" "Visual Studio Code" ON \
            "chrome" "Google Chrome 浏览器" ON \
            3>&1 1>&2 2>&3)
        # 如果没有选择，whiptail 返回非零，则视为全部不选（除了基础工具）
        if [ $? -ne 0 ]; then
            choices=""
        fi
    elif command -v dialog &>/dev/null; then
        choices=$(dialog --stdout --title "$title" --checklist "$menu_text" 20 78 10 \
            "system_upgrade" "执行系统升级 (apt upgrade)" OFF \
            "ssh" "SSH 服务 (openssh-server + 防火墙)" ON \
            "fastfetch" "fastfetch 系统信息" ON \
            "gnome_sushi" "gnome-sushi 文件预览 (桌面)" ON \
            "nvm_node" "NVM & Node.js v24" ON \
            "uv" "uv Python 包管理器" ON \
            "vscode" "Visual Studio Code" ON \
            "chrome" "Google Chrome 浏览器" ON)
    else
        # 回退：简单数字输入
        log_warn "未找到 whiptail 或 dialog，使用简单选择模式。"
        echo "可选组件："
        echo " 1) 系统升级"
        echo " 2) SSH 服务"
        echo " 3) fastfetch"
        echo " 4) gnome-sushi"
        echo " 5) NVM & Node.js"
        echo " 6) uv"
        echo " 7) VSCode"
        echo " 8) Chrome"
        printf "输入要安装的编号（空格分隔，如 2 5 6），直接回车则全部安装："
        read -r raw
        # 转换为标签
        choices=""
        for num in $raw; do
            case $num in
                1) choices+=" system_upgrade";;
                2) choices+=" ssh";;
                3) choices+=" fastfetch";;
                4) choices+=" gnome_sushi";;
                5) choices+=" nvm_node";;
                6) choices+=" uv";;
                7) choices+=" vscode";;
                8) choices+=" chrome";;
            esac
        done
        if [ -z "$raw" ]; then
            choices="system_upgrade ssh fastfetch gnome_sushi nvm_node uv vscode chrome"
            log_info "未输入，默认全部安装"
        fi
    fi

    # 初始化所有为 false
    INSTALL_SSH=false
    INSTALL_FASTFETCH=false
    INSTALL_GNOME_SUSHI=false
    INSTALL_NVM_NODE=false
    INSTALL_UV=false
    INSTALL_VSCODE=false
    INSTALL_CHROME=false
    SYSTEM_UPGRADE=false

    # 解析选择
    # whiptail/dialog 输出格式：每个选中项双引号包围，换行分隔
    # 去除所有双引号，逐行读取
    while IFS= read -r tag; do
        case "$tag" in
            system_upgrade) SYSTEM_UPGRADE=true ;;
            ssh) INSTALL_SSH=true ;;
            fastfetch) INSTALL_FASTFETCH=true ;;
            gnome_sushi) INSTALL_GNOME_SUSHI=true ;;
            nvm_node) INSTALL_NVM_NODE=true ;;
            uv) INSTALL_UV=true ;;
            vscode) INSTALL_VSCODE=true ;;
            chrome) INSTALL_CHROME=true ;;
        esac
    done < <(echo "$choices" | tr -d '"' | grep -v '^$')

    # 输出选择摘要
    echo ""
    log_info "你的选择："
    [ "$SYSTEM_UPGRADE" = true ] && log_info "  ✓ 系统升级"
    [ "$INSTALL_SSH" = true ] && log_info "  ✓ SSH 服务"
    [ "$INSTALL_FASTFETCH" = true ] && log_info "  ✓ fastfetch"
    [ "$INSTALL_GNOME_SUSHI" = true ] && log_info "  ✓ gnome-sushi"
    [ "$INSTALL_NVM_NODE" = true ] && log_info "  ✓ NVM & Node.js"
    [ "$INSTALL_UV" = true ] && log_info "  ✓ uv"
    [ "$INSTALL_VSCODE" = true ] && log_info "  ✓ VSCode"
    [ "$INSTALL_CHROME" = true ] && log_info "  ✓ Chrome"
    echo ""
    sleep 1
}

# ---------- 镜像源 ----------
configure_apt_mirror() {
    log_step "配置 APT 镜像源"
    local SRC="/etc/apt/sources.list.d/ubuntu.sources"
    [ ! -f "$SRC" ] && SRC="/etc/apt/sources.list"
    local BAK="${SRC}.bak"
    [ ! -f "$BAK" ] && sudo cp "$SRC" "$BAK" && log_info "已备份原配置到 $BAK"

    local MIRRORS=(
        "阿里云|https://mirrors.aliyun.com/ubuntu/"
        "清华大学|https://mirrors.tuna.tsinghua.edu.cn/ubuntu/"
        "中国科学技术大学|https://mirrors.ustc.edu.cn/ubuntu/"
        "华为云|https://repo.huaweicloud.com/ubuntu/"
    )
    printf "\n%b选择 APT 镜像源（15s 无输入默认阿里云）：%b\n" "$CYAN" "$NC"
    for i in "${!MIRRORS[@]}"; do
        printf "  %b[%d]%b %s\n" "$BOLD" "$((i+1))" "$NC" "${MIRRORS[$i]%%|*}"
    done
    printf "  %b[1-4]%b\n" "$YELLOW" "$NC"
    local ch=""
    IFS= read -r -t 15 ch </dev/tty 2>/dev/null || true
    case "$ch" in
        1) SEL="${MIRRORS[0]}";; 2) SEL="${MIRRORS[1]}";;
        3) SEL="${MIRRORS[2]}";; 4) SEL="${MIRRORS[3]}";;
        *) SEL="${MIRRORS[0]}"; [ -z "$ch" ] && log_warn "超时，自动使用阿里云";;
    esac
    local URL="${SEL#*|}" NAME="${SEL%%|*}"
    log_info "使用: $NAME ($URL)"

    local TMP=$(mktemp)
    if [[ "$SRC" == *"ubuntu.sources" ]]; then
        sudo sed -e "s|URIs: http://archive.ubuntu.com/ubuntu/|URIs: ${URL}|g" \
                 -e "s|URIs: http://security.ubuntu.com/ubuntu/|URIs: ${URL}|g" \
                 -e "s|URIs: https://archive.ubuntu.com/ubuntu/|URIs: ${URL}|g" \
                 -e "s|URIs: https://security.ubuntu.com/ubuntu/|URIs: ${URL}|g" \
                 "$SRC" | sudo tee "$TMP" >/dev/null
    else
        sudo sed -e "s|http://archive.ubuntu.com/ubuntu|${URL}|g" \
                 -e "s|http://security.ubuntu.com/ubuntu|${URL}|g" \
                 -e "s|https://archive.ubuntu.com/ubuntu|${URL}|g" \
                 -e "s|https://security.ubuntu.com/ubuntu|${URL}|g" \
                 "$SRC" | sudo tee "$TMP" >/dev/null
    fi
    sudo mv "$TMP" "$SRC"
    log_success "镜像源已更新"

    sudo apt update || { log_error "apt update 失败"; exit 1; }

    if $SYSTEM_UPGRADE; then
        log_info "正在执行系统升级..."
        sudo apt upgrade -y && log_success "系统升级完成"
    else
        log_info "已跳过系统升级"
    fi
}

# ---------- 基础工具（强制安装） ----------
install_base_tools() {
    log_step "安装基础工具"
    local pkgs=(git curl wget build-essential unzip tar)
    log_info "安装: ${pkgs[*]}"
    sudo apt install -y "${pkgs[@]}"
    log_success "基础工具安装完成"
}

# ---------- SSH ----------
install_ssh() {
    log_step "配置 SSH"
    sudo apt install -y openssh-server
    sudo systemctl start ssh || true
    sudo systemctl enable ssh 2>/dev/null || true
    if command -v ufw &>/dev/null && sudo ufw status | grep -q "Status: active"; then
        sudo ufw allow 22/tcp || log_warn "ufw 添加规则失败"
    elif command -v firewall-cmd &>/dev/null && sudo firewall-cmd --state 2>/dev/null | grep -q "running"; then
        sudo firewall-cmd --permanent --add-port=22/tcp && sudo firewall-cmd --reload
        log_info "已通过 firewalld 开放 22 端口"
    else
        log_warn "未检测到启用的防火墙，请手动检查 22 端口"
    fi
    log_success "SSH 已配置（状态: $(systemctl is-active ssh)）"
}

# ---------- fastfetch ----------
install_fastfetch() {
    log_info "安装 fastfetch..."
    sudo apt install -y fastfetch && log_success "fastfetch 安装完成" || log_warn "fastfetch 安装失败"
}

# ---------- gnome-sushi ----------
install_gnome_sushi() {
    log_info "安装 gnome-sushi..."
    sudo apt install -y gnome-sushi && log_success "gnome-sushi 安装完成" || log_warn "gnome-sushi 安装失败"
}

# ---------- NVM / Node ----------
install_nvm_node() {
    log_step "安装 NVM 与 Node.js"
    if [ ! -d "$HOME/.nvm" ]; then
        log_info "安装 NVM ..."
        curl_retry https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.4/install.sh | bash
    else
        log_warn "NVM 已存在，跳过安装"
    fi

    local BASHRC="$HOME/.bashrc"
    if ! grep -q '# === NVM Configuration ===' "$BASHRC" 2>/dev/null; then
        cat >> "$BASHRC" << 'EOF'

# === NVM Configuration ===
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"
export NVM_NODEJS_ORG_MIRROR=https://npmmirror.com/mirrors/node
EOF
    fi

    export NVM_DIR="$HOME/.nvm"
    [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
    command -v nvm >/dev/null || { log_error "NVM 加载失败"; exit 1; }

    log_info "安装 Node.js v24 (LTS)..."
    nvm install 24
    nvm use 24
    nvm alias default 24
    npm config set registry https://registry.npmmirror.com
    npm install -g nrm
    log_success "Node $(node -v) / npm $(npm -v) / nrm 就绪"
}

# ---------- uv ----------
install_uv() {
    log_step "安装 uv"
    command -v uv &>/dev/null && { log_warn "uv 已安装: $(uv --version)"; return; }
    curl_retry -LsSf https://astral.sh/uv/install.sh | sh
    if [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
        echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.bashrc"
        export PATH="$HOME/.local/bin:$PATH"
    fi
    command -v uv &>/dev/null && log_success "uv $(uv --version)" || log_warn "uv 未在 PATH 中，请执行 source ~/.bashrc"
}

# ---------- VSCode ----------
install_vscode() {
    log_step "安装 VSCode"
    if command -v code &>/dev/null; then
        log_warn "VSCode 已安装: $(code --version | head -1)"
    else
        wget_retry -qO- https://packages.microsoft.com/keys/microsoft.asc | sudo gpg --dearmor -o /usr/share/keyrings/packages.microsoft.gpg
        echo "deb [arch=amd64 signed-by=/usr/share/keyrings/packages.microsoft.gpg] https://packages.microsoft.com/repos/code stable main" | sudo tee /etc/apt/sources.list.d/vscode.list >/dev/null
        sudo apt update && sudo apt install -y code
        log_success "VSCode 安装完成"
    fi

    local DIR="$HOME/.config/Code/User"
    local SET="$DIR/settings.json"
    mkdir -p "$DIR"
    if [ -f "$SET" ]; then
        cp "$SET" "${SET}.bak"
        log_warn "已有 settings.json 已备份为 settings.json.bak，现写入推荐配置"
    fi
    cat > "$SET" << 'EOF'
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
    log_success "VSCode 配置已写入"
}

# ---------- Chrome ----------
install_chrome() {
    log_step "安装 Google Chrome"
    if command -v google-chrome &>/dev/null; then
        log_warn "Chrome 已安装"
        return
    fi
    local TMP_DEB="/tmp/google-chrome.deb"
    wget_retry -O "$TMP_DEB" https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb
    sudo apt install -y "$TMP_DEB"
    rm -f "$TMP_DEB"
    log_success "Chrome 安装完成"
}

# ---------- 验证 ----------
verify_installations() {
    log_step "安装结果"

    # 定义检查列表：命令，显示名称，是否安装的变量
    declare -A CHECKS=(
        ["git"]="Git|true"
        ["curl"]="cURL|true"
        ["wget"]="Wget|true"
        ["ssh"]="SSH|$INSTALL_SSH"
        ["fastfetch"]="Fastfetch|$INSTALL_FASTFETCH"
        ["gnome-sushi"]="gnome-sushi|$INSTALL_GNOME_SUSHI"
        ["node"]="Node.js|$INSTALL_NVM_NODE"
        ["npm"]="npm|$INSTALL_NVM_NODE"
        ["nrm"]="nrm|$INSTALL_NVM_NODE"
        ["uv"]="uv|$INSTALL_UV"
        ["code"]="VSCode|$INSTALL_VSCODE"
        ["google-chrome"]="Chrome|$INSTALL_CHROME"
    )

    printf "\n%b%-20s %-15s %s%b\n" "$BOLD" "工具" "状态" "版本" "$NC"
    printf "%s\n" "--------------------------------------------------"
    for cmd in "${!CHECKS[@]}"; do
        IFS='|' read -r name should_install <<< "${CHECKS[$cmd]}"
        if $should_install; then
            if command -v "$cmd" &>/dev/null; then
                local ver=""
                case "$cmd" in
                    git) ver=$(git --version | awk '{print $3}');;
                    ssh) ver=$(ssh -V 2>&1 | awk '{print $1}');;
                    node) ver=$(node -v);;
                    npm) ver=$(npm -v);;
                    nrm) ver=$(nrm --version 2>/dev/null);;
                    uv) ver=$(uv --version | awk '{print $2}');;
                    code) ver=$(code --version 2>/dev/null | head -1);;
                    google-chrome) ver=$(google-chrome --version 2>/dev/null | awk '{print $3}');;
                    *) ver=$($cmd --version 2>/dev/null | head -1);;
                esac
                printf "%b%-20s %-15s %s%b\n" "$GREEN" "$name" "✓ 已安装" "${ver:-未知}" "$NC"
            else
                printf "%b%-20s %-15s %s%b\n" "$RED" "$name" "✗ 未找到" "" "$NC"
            fi
        else
            printf "%b%-20s %-15s %s%b\n" "$YELLOW" "$name" "⏭ 已跳过" "-" "$NC"
        fi
    done

    echo ""
    printf "%b系统升级:%b %s\n" "$CYAN" "$NC" "$($SYSTEM_UPGRADE && echo '已执行' || echo '已跳过')"
}

# ---------- 主流程 ----------
main() {
    printf "%b\n" "$CYAN"
cat << 'EOF'
▄▄▄█████▓ ██░ ██ ▓█████  ▒█████
▓  ██▒ ▓▒▓██░ ██▒▓█   ▀ ▒██▒  ██▒
▒ ▓██░ ▒░▒██▀▀██░▒███   ▒██░  ██▒
░ ▓██▓ ░ ░▓█ ░██ ▒▓█  ▄ ▒██   ██░
  ▒██▒ ░ ░▓█▒░██▓░▒████▒░ ████▓▒░
  ▒ ░░    ▒ ░░▒░▒░░ ▒░ ░░ ▒░▒░▒░
    ░     ▒ ░▒░ ░ ░ ░  ░  ░ ▒ ▒░
  ░       ░  ░░ ░   ░   ░ ░ ░ ▒
          ░  ░  ░   ░  ░    ░ ░

EOF
    printf "%b" "$NC"
    printf "%bUbuntu 24.04+ 一键环境配置（组件选择版）%b\n\n" "$BOLD" "$NC"

    check_permissions
    select_components
    configure_apt_mirror
    install_base_tools

    $INSTALL_SSH && install_ssh
    $INSTALL_FASTFETCH && install_fastfetch
    $INSTALL_GNOME_SUSHI && install_gnome_sushi
    $INSTALL_NVM_NODE && install_nvm_node
    $INSTALL_UV && install_uv
    $INSTALL_VSCODE && install_vscode
    $INSTALL_CHROME && install_chrome

    verify_installations

    log_step "全部完成！"
    log_success "建议执行 source ~/.bashrc 或重新登录，使环境变量完全生效。"
}

main