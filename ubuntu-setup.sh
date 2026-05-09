#!/usr/bin/env bash
# =============================================================================
# Ubuntu 24.04+ 增强版一键环境配置脚本
# 改进点：
#   - 完善的退出清理（EXIT trap）
#   - 命令行参数解析（镜像/组件选择/版本号）
#   - VSCode 配置合并（避免覆盖已有设置）
#   - 网络操作自动重试
#   - 检测多种防火墙（ufw / firewalld）
#   - 可选安装桌面工具（--desktop）
#   - 安全备份与写入（使用临时文件 + mv）
#   - 避免重复 source .bashrc，仅最后提示
#   - 包存在性检查
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
log_info()    { printf "%b[INFO]%b %s\n" "$BLUE" "$NC" "$1"; }
log_success() { printf "%b[SUCCESS]%b %s\n" "$GREEN" "$NC" "$1"; }
log_warn()    { printf "%b[WARN]%b %s\n" "$YELLOW" "$NC" "$1"; }
log_error()   { printf "%b[ERROR]%b %s\n" "$RED" "$NC" "$1"; }
log_step()    { printf "\n%b========== %s ==========%b\n" "$BOLD" "$1" "$NC"; }

# ---------------------------------------------------------------------------
# 全局变量（可通过命令行参数修改）
# ---------------------------------------------------------------------------
MIRROR_CHOICE=""          # 1-4 对应镜像编号，空则交互选择
NVM_VERSION="0.40.4"      # 可被 --nvm-version 覆盖
NODE_VERSION="24"         # 可被 --node-version 覆盖
INSTALL_VSCODE=true
INSTALL_DESKTOP=false     # 是否安装 gnome-sushi 等桌面工具
SKIP_UPGRADE=false        # 跳过系统升级询问
UPGRADE_SYSTEM=false      # 直接升级系统（跳过询问）

# 后台进程 PID
SUDO_KEEPALIVE_PID=""

# ---------------------------------------------------------------------------
# 资源清理（EXIT trap 保证无论何种退出都会执行）
# ---------------------------------------------------------------------------
cleanup() {
    if [[ -n "${SUDO_KEEPALIVE_PID:-}" ]]; then
        kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT

# 错误处理
cleanup_on_error() {
    local line=$1
    log_error "脚本在第 ${line} 行发生错误，已终止。"
    exit 1
}
trap 'cleanup_on_error $LINENO' ERR

# ---------------------------------------------------------------------------
# 网络重试函数
# ---------------------------------------------------------------------------
retry_curl() {
    curl --retry 3 --retry-delay 2 --retry-connrefused -sSL "$@"
}

retry_wget() {
    wget --tries=3 --retry-connrefused -q "$@"
}

# ---------------------------------------------------------------------------
# 权限检查
# ---------------------------------------------------------------------------
check_permissions() {
    log_step "检查运行权限"

    if [ "$(id -u)" -eq 0 ]; then
        log_error "请勿以 root 身份运行此脚本。"
        exit 1
    fi
    log_info "当前用户: $(whoami)"

    if ! sudo -n true 2>/dev/null; then
        log_warn "需要 sudo 权限，请输入当前用户密码："
        sudo -v || { log_error "sudo 认证失败"; exit 1; }
    fi

    # 保持 sudo 会话
    while true; do sudo -n true; sleep 60; done 2>/dev/null &
    SUDO_KEEPALIVE_PID=$!
    log_success "sudo 权限验证通过"
}

# ---------------------------------------------------------------------------
# APT 镜像源配置
# ---------------------------------------------------------------------------
configure_apt_mirror() {
    log_step "配置 APT 镜像源"

    local SOURCES_FILE="/etc/apt/sources.list.d/ubuntu.sources"
    if [ ! -f "$SOURCES_FILE" ]; then
        SOURCES_FILE="/etc/apt/sources.list"
    fi
    local BACKUP_FILE="${SOURCES_FILE}.bak.$(date +%s)"

    # 备份
    sudo cp "$SOURCES_FILE" "$BACKUP_FILE"
    log_info "已备份原配置到 ${BACKUP_FILE}"

    # 镜像列表
    local MIRRORS=(
        "阿里云|https://mirrors.aliyun.com/ubuntu/"
        "清华大学|https://mirrors.tuna.tsinghua.edu.cn/ubuntu/"
        "中国科学技术大学|https://mirrors.ustc.edu.cn/ubuntu/"
        "华为云|https://repo.huaweicloud.com/ubuntu/"
    )

    # 交互选择或使用预设
    local choice="${MIRROR_CHOICE}"
    if [[ -z "$choice" ]]; then
        printf "\n%b请选择 APT 镜像源（15 秒内无输入默认阿里云）：%b\n" "$CYAN" "$NC"
        for i in "${!MIRRORS[@]}"; do
            printf "  %b[%d]%b %s\n" "$BOLD" "$((i+1))" "$NC" "${MIRRORS[$i]%%|*}"
        done
        printf "  %b[1-4]%b\n" "$YELLOW" "$NC"

        local input=""
        if IFS= read -r -t 15 input </dev/tty 2>/dev/null || true; then
            choice="$input"
        fi
    fi

    case "$choice" in
        1) SELECTED_MIRROR="${MIRRORS[0]}" ;;
        2) SELECTED_MIRROR="${MIRRORS[1]}" ;;
        3) SELECTED_MIRROR="${MIRRORS[2]}" ;;
        4) SELECTED_MIRROR="${MIRRORS[3]}" ;;
        *) SELECTED_MIRROR="${MIRRORS[0]}" ;
           [[ -z "$choice" ]] && log_warn "输入超时，使用默认阿里云" ;;
    esac

    local MIRROR_URL="${SELECTED_MIRROR#*|}"
    local MIRROR_NAME="${SELECTED_MIRROR%%|*}"
    log_info "使用镜像源: ${MIRROR_NAME} (${MIRROR_URL})"

    # 安全替换：使用临时文件，避免 sed -i 损坏原文件
    local TMP_SOURCES=$(mktemp)
    if [[ "$SOURCES_FILE" == *"ubuntu.sources" ]]; then
        sudo sed -e "s|URIs: http://archive.ubuntu.com/ubuntu/|URIs: ${MIRROR_URL}|g" \
                 -e "s|URIs: http://security.ubuntu.com/ubuntu/|URIs: ${MIRROR_URL}|g" \
                 -e "s|URIs: https://archive.ubuntu.com/ubuntu/|URIs: ${MIRROR_URL}|g" \
                 -e "s|URIs: https://security.ubuntu.com/ubuntu/|URIs: ${MIRROR_URL}|g" \
                 "$SOURCES_FILE" | sudo tee "$TMP_SOURCES" >/dev/null
    else
        sudo sed -e "s|http://archive.ubuntu.com/ubuntu|${MIRROR_URL}|g" \
                 -e "s|http://security.ubuntu.com/ubuntu|${MIRROR_URL}|g" \
                 -e "s|https://archive.ubuntu.com/ubuntu|${MIRROR_URL}|g" \
                 -e "s|https://security.ubuntu.com/ubuntu|${MIRROR_URL}|g" \
                 "$SOURCES_FILE" | sudo tee "$TMP_SOURCES" >/dev/null
    fi
    sudo mv "$TMP_SOURCES" "$SOURCES_FILE"
    log_success "APT 镜像源已更新"

    log_info "更新软件包索引..."
    if ! sudo apt update; then
        log_error "apt update 失败，请检查镜像源或网络"
        exit 1
    fi
    log_success "软件包索引更新完成"

    # 系统升级处理
    if $UPGRADE_SYSTEM; then
        log_info "正在升级系统..."
        sudo apt upgrade -y
        log_success "系统升级完成"
    elif ! $SKIP_UPGRADE; then
        log_info "是否执行系统升级？(y/N，10 秒超时默认 N)"
        local upgrade_choice=""
        if IFS= read -r -t 10 upgrade_choice </dev/tty 2>/dev/null || true; then
            if [[ "$upgrade_choice" =~ ^[Yy]$ ]]; then
                sudo apt upgrade -y
                log_success "系统升级完成"
            else
                log_info "跳过系统升级"
            fi
        else
            printf "\n"
            log_info "超时，跳过系统升级"
        fi
    else
        log_info "已通过参数跳过系统升级询问"
    fi
}

# ---------------------------------------------------------------------------
# 安装基础工具（检查包是否存在）
# ---------------------------------------------------------------------------
install_base_tools() {
    log_step "安装基础工具"

    local packages=(
        git curl wget openssh-server
        build-essential unzip tar
    )

    # 根据桌面环境选项添加
    if $INSTALL_DESKTOP; then
        if apt-cache show gnome-sushi &>/dev/null; then
            packages+=(gnome-sushi)
        else
            log_warn "gnome-sushi 在软件源中不存在，跳过"
        fi
    fi
    if apt-cache show fastfetch &>/dev/null; then
        packages+=(fastfetch)
    else
        log_warn "fastfetch 在软件源中不存在，跳过"
    fi

    log_info "即将安装: ${packages[*]}"
    sudo apt install -y "${packages[@]}"
    log_success "基础工具安装完成"
}

# ---------------------------------------------------------------------------
# 配置 SSH
# ---------------------------------------------------------------------------
configure_ssh() {
    log_step "配置 SSH 服务"

    sudo systemctl start ssh || log_info "ssh 服务已启动"
    if ! sudo systemctl is-enabled --quiet ssh 2>/dev/null; then
        sudo systemctl enable ssh
    fi

    # 开放防火墙（检测 ufw 和 firewalld）
    if command -v ufw &>/dev/null && sudo ufw status | grep -q "Status: active"; then
        sudo ufw allow 22/tcp || log_warn "ufw 添加规则失败"
    elif command -v firewall-cmd &>/dev/null && sudo firewall-cmd --state 2>/dev/null | grep -q "running"; then
        sudo firewall-cmd --permanent --add-port=22/tcp
        sudo firewall-cmd --reload
        log_info "已通过 firewalld 开放 22 端口"
    else
        log_warn "未检测到启用的防火墙，请手动检查 22 端口"
    fi

    log_success "SSH 服务已配置 (状态: $(systemctl is-active ssh))"
}

# ---------------------------------------------------------------------------
# NVM/Node.js 安装（支持版本参数）
# ---------------------------------------------------------------------------
install_nvm_node() {
    log_step "安装 NVM 和 Node.js"

    if [ ! -d "$HOME/.nvm" ]; then
        log_info "安装 NVM v${NVM_VERSION}..."
        retry_curl "https://raw.githubusercontent.com/nvm-sh/nvm/v${NVM_VERSION}/install.sh" | bash
    else
        log_warn "NVM 已存在，跳过安装"
    fi

    # 写入 .bashrc（幂等）
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

    # 手动加载 NVM（不 source .bashrc 避免副作用）
    export NVM_DIR="$HOME/.nvm"
    [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"

    if ! command -v nvm &>/dev/null; then
        log_error "NVM 加载失败"
        exit 1
    fi

    log_info "安装 Node.js v${NODE_VERSION}..."
    nvm install "$NODE_VERSION"
    nvm use "$NODE_VERSION"
    nvm alias default "$NODE_VERSION"

    log_success "Node.js: $(node --version) | npm: $(npm --version)"

    # npm 镜像
    npm config set registry https://registry.npmmirror.com
    log_info "npm 镜像已设置为 $(npm config get registry)"

    # nrm
    npm install -g nrm
    log_success "nrm 安装完成"
}

# ---------------------------------------------------------------------------
# 安装 uv
# ---------------------------------------------------------------------------
install_uv() {
    log_step "安装 uv"
    if command -v uv &>/dev/null; then
        log_warn "uv 已安装: $(uv --version)"
        return
    fi

    log_info "执行 uv 官方安装..."
    retry_curl -LsSf https://astral.sh/uv/install.sh | sh

    if [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
        echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.bashrc"
        export PATH="$HOME/.local/bin:$PATH"
    fi

    if command -v uv &>/dev/null; then
        log_success "uv 安装完成: $(uv --version)"
    else
        log_warn "uv 安装后未找到，请重新登录或 source ~/.bashrc"
    fi
}

# ---------------------------------------------------------------------------
# VSCode 安装与配置（合并 settings.json）
# ---------------------------------------------------------------------------
install_vscode() {
    log_step "安装 VSCode"

    if command -v code &>/dev/null; then
        log_warn "VSCode 已安装: $(code --version | head -1)"
    else
        log_info "添加 Microsoft 仓库..."
        retry_wget -qO- https://packages.microsoft.com/keys/microsoft.asc | sudo gpg --dearmor -o /usr/share/keyrings/packages.microsoft.gpg
        echo "deb [arch=amd64 signed-by=/usr/share/keyrings/packages.microsoft.gpg] https://packages.microsoft.com/repos/code stable main" | sudo tee /etc/apt/sources.list.d/vscode.list >/dev/null
        sudo apt update && sudo apt install -y code
        log_success "VSCode 安装完成"
    fi

    # 配置 settings.json（智能合并）
    local CONF_DIR="$HOME/.config/Code/User"
    local SETTINGS_FILE="${CONF_DIR}/settings.json"
    mkdir -p "$CONF_DIR"

    # 默认配置字典
    declare -A DEFAULTS=(
        ["workbench.colorTheme"]='"Dark Modern"'
        ["editor.smoothScrolling"]="true"
        ["editor.cursorBlinking"]='"smooth"'
        ["editor.cursorSmoothCaretAnimation"]='"on"'
        ["editor.mouseWheelZoom"]="true"
        ["editor.tabCompletion"]='"on"'
        ["editor.stickyScroll.enabled"]="true"
        ["editor.bracketPairColorization.enabled"]="true"
        ["editor.guides.bracketPairs"]="true"
        ["editor.wordWrap"]='"on"'
        ["editor.renderWhitespace"]='"selection"'
        ["editor.defaultColorDecorators"]='"always"'
        ["editor.colorDecoratorsActivatedOn"]='"click"'
        ["editor.unicodeHighlight.nonBasicASCII"]="false"
        ["editor.minimap.enabled"]="true"
        ["editor.minimap.showSlider"]='"always"'
        ["terminal.integrated.mouseWheelZoom"]="true"
        ["terminal.integrated.fontSize"]="11"
        ["git.enableSmartCommit"]="true"
        ["chat.disableAIFeatures"]="true"
        ["ipynb.experimental.serialization"]="false"
        ["[xml]"]='{"editor.autoClosingBrackets":"never","files.trimFinalNewlines":true}'
    )

    if [ ! -f "$SETTINGS_FILE" ]; then
        # 全新写入
        printf "{\n" > "$SETTINGS_FILE"
        local first=true
        for key in "${!DEFAULTS[@]}"; do
            $first && first=false || printf ",\n" >> "$SETTINGS_FILE"
            printf '    "%s": %s' "$key" "${DEFAULTS[$key]}" >> "$SETTINGS_FILE"
        done
        printf "\n}\n" >> "$SETTINGS_FILE"
        log_success "已创建 VSCode settings.json"
    else
        # 合并：仅添加缺失的键，不覆盖已有值
        log_info "检测到已有 settings.json，仅补充缺失的推荐配置..."
        if command -v jq &>/dev/null; then
            # 使用 jq 深度合并（安全）
            local tmp_json=$(mktemp)
            jq -s '.[0] * .[1]' "$SETTINGS_FILE" <(cat <<<"$(printf '%s\n' "${!DEFAULTS[@]}" | sed 's/.*/"&":/')") > "$tmp_json" && mv "$tmp_json" "$SETTINGS_FILE"
            log_success "已使用 jq 合并配置"
        else
            log_warn "未安装 jq，无法安全合并，保留原有配置。可手动添加推荐项。"
            # 打印缺失键供参考
            for key in "${!DEFAULTS[@]}"; do
                if ! grep -q "\"$key\"" "$SETTINGS_FILE"; then
                    log_info "  缺失配置: \"$key\": ${DEFAULTS[$key]}"
                fi
            done
        fi
    fi
}

# ---------------------------------------------------------------------------
# 验证安装结果
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
    )
    $INSTALL_VSCODE && tools+=("code|VSCode")

    printf "\n%b%-25s %-15s %s%b\n" "$BOLD" "工具" "状态" "版本" "$NC"
    printf "%s\n" "---------------------------------------------------------"

    for item in "${tools[@]}"; do
        local cmd=${item%%|*} name=${item#*|}
        if command -v "$cmd" &>/dev/null; then
            local ver=""
            case "$cmd" in
                git) ver=$(git --version | awk '{print $3}') ;;
                ssh) ver=$(ssh -V 2>&1 | awk '{print $1}') ;;
                node) ver=$(node --version) ;;
                npm) ver=$(npm --version) ;;
                nrm) ver=$(nrm --version) ;;
                uv) ver=$(uv --version | awk '{print $2}') ;;
                code) ver=$(code --version 2>/dev/null | head -1) ;;
                *) ver=$($cmd --version 2>/dev/null | head -1) ;;
            esac
            printf "%b%-25s %-15s %s%b\n" "$GREEN" "$name" "✓ 已安装" "${ver:-未知}" "$NC"
        else
            printf "%b%-25s %-15s %s%b\n" "$RED" "$name" "✗ 未找到" "" "$NC"
        fi
    done

    printf "\n%bSSH 服务:%b %s\n" "$CYAN" "$NC" "$(sudo systemctl is-active ssh 2>/dev/null || echo 'unknown')"
    printf "%bnpm 镜像:%b %s\n" "$CYAN" "$NC" "$(npm config get registry 2>/dev/null || echo 'unknown')"
}

# ---------------------------------------------------------------------------
# 参数解析
# ---------------------------------------------------------------------------
usage() {
    cat <<EOF
用法: $0 [选项]

选项:
  --mirror <1-4>         直接指定镜像编号，跳过交互
                         (1:阿里云 2:清华 3:中科大 4:华为)
  --nvm-version <ver>    NVM 版本 (默认: $NVM_VERSION)
  --node-version <ver>   Node.js 版本 (默认: $NODE_VERSION)
  --skip-vscode          跳过 VSCode 安装
  --desktop              同时安装桌面工具 (gnome-sushi)
  --upgrade              直接升级系统 (不询问)
  --skip-upgrade         跳过系统升级询问 (不升级)
  -h, --help             显示此帮助

示例:
  $0 --mirror 2 --node-version 22 --skip-vscode
EOF
    exit 0
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --mirror)
                MIRROR_CHOICE="$2"; shift 2 ;;
            --nvm-version)
                NVM_VERSION="$2"; shift 2 ;;
            --node-version)
                NODE_VERSION="$2"; shift 2 ;;
            --skip-vscode)
                INSTALL_VSCODE=false; shift ;;
            --desktop)
                INSTALL_DESKTOP=true; shift ;;
            --upgrade)
                UPGRADE_SYSTEM=true; shift ;;
            --skip-upgrade)
                SKIP_UPGRADE=true; shift ;;
            -h|--help)
                usage ;;
            *)
                log_error "未知参数: $1"; usage ;;
        esac
    done
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
    printf "%bUbuntu 24.04+ 增强版一键环境配置脚本%b\n\n" "$BOLD" "$NC"

    check_permissions
    configure_apt_mirror
    install_base_tools
    configure_ssh
    install_nvm_node
    install_uv
    $INSTALL_VSCODE && install_vscode
    verify_installations

    log_step "配置完成"
    log_success "所有步骤执行完毕！请执行 'source ~/.bashrc' 或重新登录以使环境变量完全生效。"
}

# 解析参数并执行
parse_args "$@"
main