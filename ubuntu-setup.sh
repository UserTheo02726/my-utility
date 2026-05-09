#!/usr/bin/env bash
# =============================================================================
# Ubuntu 24.04+ 一键环境配置脚本（无脑轻薄版）
# 特性：镜像自动选、基础工具、NVM/Node、uv、VSCode
#       修复 sudo 进程残留、网络重试、VSCode 配置不覆盖
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

# ---------- 资源清理（确保 sudo 保持进程被杀死） ----------
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

# ---------- 静默重试的网络下载 ----------
curl_retry() { curl --retry 3 --retry-delay 2 --retry-connrefused -sSL "$@"; }
wget_retry() { wget --tries=3 --retry-connrefused -q "$@"; }

# ---------- 权限检查 ----------
check_permissions() {
    log_step "检查运行权限"
    [ "$(id -u)" -eq 0 ] && { log_error "请勿以 root 运行此脚本。"; exit 1; }
    log_info "当前用户: $(whoami)"
    if ! sudo -n true 2>/dev/null; then
        log_warn "需要 sudo 权限，请输入当前用户密码："
        sudo -v || { log_error "sudo 认证失败"; exit 1; }
    fi
    # 静默保持 sudo 会话
    while true; do sudo -n true; sleep 60; done 2>/dev/null &
    SUDO_KEEPALIVE_PID=$!
    log_success "sudo 权限验证通过"
}

# ---------- APT 镜像源（交互 + 超时） ----------
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
    log_success "软件包索引更新完成"

    # 系统升级询问
    log_info "是否升级系统包？(y/N，10s 超时默认 N)"
    local up=""
    IFS= read -r -t 10 up </dev/tty 2>/dev/null || true
    if [[ "$up" =~ ^[Yy]$ ]]; then
        sudo apt upgrade -y && log_success "系统升级完成"
    else
        log_info "跳过系统升级"
    fi
}

# ---------- 基础工具（智能检测包是否存在） ----------
install_base_tools() {
    log_step "安装基础工具"
    local pkgs=(git curl wget openssh-server build-essential unzip tar)
    # 检测可选包
    apt-cache show fastfetch &>/dev/null && pkgs+=(fastfetch) || log_warn "fastfetch 不在源中，跳过"
    apt-cache show gnome-sushi &>/dev/null && pkgs+=(gnome-sushi) || log_warn "gnome-sushi 不在源中，跳过"
    log_info "安装: ${pkgs[*]}"
    sudo apt install -y "${pkgs[@]}"
    log_success "基础工具安装完成"
}

# ---------- SSH 服务 ----------
configure_ssh() {
    log_step "配置 SSH"
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

# ---------- NVM / Node.js ----------
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

# ---------- VSCode（已有配置自动备份，不覆盖） ----------
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
        # 智能处理：备份旧文件，再写入推荐配置
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

# ---------- 验证 ----------
verify_installations() {
    log_step "验证安装"
    local tools=(
        "git|Git" "curl|cURL" "wget|Wget" "ssh|OpenSSH"
        "fastfetch|Fastfetch" "node|Node.js" "npm|npm" "nrm|nrm"
        "uv|uv" "code|VSCode"
    )
    printf "\n%b%-20s %-15s %s%b\n" "$BOLD" "工具" "状态" "版本" "$NC"
    printf "%s\n" "----------------------------------------------"
    for t in "${tools[@]}"; do
        local cmd=${t%%|*} name=${t#*|} ver=""
        if command -v "$cmd" &>/dev/null; then
            case "$cmd" in
                git) ver=$(git --version | awk '{print $3}');;
                ssh) ver=$(ssh -V 2>&1 | awk '{print $1}');;
                node) ver=$(node -v);;
                npm) ver=$(npm -v);;
                nrm) ver=$(nrm --version 2>/dev/null);;
                uv) ver=$(uv --version | awk '{print $2}');;
                code) ver=$(code --version 2>/dev/null | head -1);;
                *) ver=$($cmd --version 2>/dev/null | head -1);;
            esac
            printf "%b%-20s %-15s %s%b\n" "$GREEN" "$name" "✓已安装" "${ver:-未知}" "$NC"
        else
            printf "%b%-20s %-15s %s%b\n" "$RED" "$name" "✗未找到" "" "$NC"
        fi
    done
    printf "\n%bSSH:%b %s | %bnpm源:%b %s\n" \
        "$CYAN" "$NC" "$(sudo systemctl is-active ssh)" \
        "$CYAN" "$NC" "$(npm config get registry 2>/dev/null || echo 'unknown')"
}

# ---------- 主流程 ----------
main() {
    printf "%b\n" "$CYAN"
    cat << 'EOF'
   _    _ _                 _   _       _       _   _
  / \  | | | ___  _   _  __| | | | ___ | |_ ___| | | |
 / _ \ | | |/ _ \| | | |/ _` | | |/ _ \| __/ _ \ | | |
/ ___ \| | | (_) | |_| | (_| | | | (_) | ||  __/ |_| |
/_/   \_\_|_|\___/ \__,_|\__,_| |_|\___/ \__\___|\___|
EOF
    printf "%b" "$NC"
    printf "%bUbuntu 24.04+ 一键环境配置（无脑轻薄版）%b\n\n" "$BOLD" "$NC"

    check_permissions
    configure_apt_mirror
    install_base_tools
    configure_ssh
    install_nvm_node
    install_uv
    install_vscode
    verify_installations

    log_step "全部完成！"
    log_success "建议执行 source ~/.bashrc 或重新登录，使环境变量完全生效。"
}

main