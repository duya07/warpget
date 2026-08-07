#!/usr/bin/env bash

set -Eeuo pipefail

readonly VERSION="1.1.1"
readonly PROGRAM_NAME="warpget"
readonly INSTALL_PATH="/usr/local/sbin/${PROGRAM_NAME}"
readonly CONFIG_PATH="/etc/default/${PROGRAM_NAME}"
readonly SERVICE_PATH="/etc/systemd/system/${PROGRAM_NAME}.service"
readonly TIMER_PATH="/etc/systemd/system/${PROGRAM_NAME}.timer"
readonly DOWNLOAD_URL="https://raw.githubusercontent.com/duya07/warpget/main/warpget.sh"
TEMP_SCRIPT=""

if [[ -t 2 && ${TERM:-dumb} != "dumb" && -z ${NO_COLOR:-} ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    CYAN='\033[0;36m'
    BOLD='\033[1m'
    RESET='\033[0m'
else
    RED=''
    GREEN=''
    YELLOW=''
    CYAN=''
    BOLD=''
    RESET=''
fi

print_banner() {
    printf '%b\n' \
        "${CYAN}================================================${RESET}" \
        "${BOLD}        WARPGET 单栈自动恢复 v${VERSION}${RESET}" \
        "${CYAN}================================================${RESET}"
}

info() {
    printf '%b[信息]%b %s\n' "${CYAN}" "${RESET}" "$*"
}

success() {
    printf '%b[完成]%b %s\n' "${GREEN}" "${RESET}" "$*"
}

step() {
    printf '%b[%s]%b %s\n' "${YELLOW}" "$1" "${RESET}" "$2"
}

die() {
    printf '%b[错误]%b %s\n' "${RED}" "${RESET}" "$*" >&2
    exit 1
}

check_root() {
    [[ ${EUID} -eq 0 ]] || die "请使用 root 用户运行安装脚本"
}

validate_retry() {
    [[ $1 =~ ^[0-9]+$ ]] && (( 1 <= $1 && $1 <= 20 ))
}

read_ip_version() {
    local choice="${1:-}"

    if [[ -z ${choice} && -t 0 ]]; then
        printf '\n%b请选择服务器要通过 WARP 获取的 Cloudflare 官方 IP：%b\n' "${BOLD}" "${RESET}" >&2
        printf '  %b1.%b IPv4  （只检测 1.1.1.1）\n' "${GREEN}" "${RESET}" >&2
        printf '  %b2.%b IPv6  （只检测 2606:4700:4700::1111）\n\n' "${GREEN}" "${RESET}" >&2
        read -r -p "请输入 [1-2]：" choice
    fi

    case "${choice,,}" in
        1|4|ipv4)
            printf '4'
            ;;
        2|6|ipv6)
            printf '6'
            ;;
        *)
            die "请选择 IPv4 或 IPv6"
            ;;
    esac
}

read_retry() {
    local retry="${1:-}"

    if [[ -z ${retry} && -t 0 ]]; then
        read -r -p $'\n每次故障最多恢复几轮？[3]：' retry
    fi
    retry="${retry:-3}"
    validate_retry "${retry}" || die "重试次数必须是 1～20 的整数"
    printf '%s' "${retry}"
}

check_environment() {
    command -v systemctl >/dev/null 2>&1 || die "当前系统没有 systemd，暂不支持自动安装定时任务"
    [[ -d /run/systemd/system ]] || die "systemd 当前未运行"
    command -v curl >/dev/null 2>&1 || die "缺少 curl"
    command -v ping >/dev/null 2>&1 || die "缺少 ping"
    command -v wg >/dev/null 2>&1 || die "缺少 wg，请先安装 fscarmen/warp"
    command -v wg-quick >/dev/null 2>&1 || die "缺少 wg-quick，请先安装 fscarmen/warp"
    command -v warp >/dev/null 2>&1 || die "缺少 warp 命令，请先安装 fscarmen/warp"
    [[ -s /etc/wireguard/warp.conf ]] || die "找不到 /etc/wireguard/warp.conf"
    success "运行环境检查通过"
}

cleanup_temp() {
    [[ -z ${TEMP_SCRIPT} ]] || rm -f "${TEMP_SCRIPT}"
}

uninstall_warpget() {
    check_root
    if command -v systemctl >/dev/null 2>&1; then
        systemctl disable --now "${PROGRAM_NAME}.timer" >/dev/null 2>&1 || true
        systemctl stop "${PROGRAM_NAME}.service" >/dev/null 2>&1 || true
    fi
    rm -f "${INSTALL_PATH}" "${CONFIG_PATH}" "${SERVICE_PATH}" "${TIMER_PATH}"
    command -v systemctl >/dev/null 2>&1 && systemctl daemon-reload
    info "已卸载；fscarmen/warp 及其配置未被修改"
}

install_warpget() {
    local ip_version=$1
    local max_retry=$2
    TEMP_SCRIPT=$(mktemp)
    trap cleanup_temp EXIT

    step "1/4" "下载并检查监控脚本"
    curl -fsSL "${DOWNLOAD_URL}" -o "${TEMP_SCRIPT}"
    bash -n "${TEMP_SCRIPT}" || die "下载的监控脚本语法检查失败"
    install -m 0755 "${TEMP_SCRIPT}" "${INSTALL_PATH}"

    step "2/4" "保存 IPv${ip_version} 监控配置"
    umask 022
    printf 'IP_VERSION=%s\nMAX_RETRY=%s\n' "${ip_version}" "${max_retry}" > "${CONFIG_PATH}"

    step "3/4" "创建 systemd 服务和定时器"
    cat > "${SERVICE_PATH}" <<'EOF'
[Unit]
Description=WARP selected IP connectivity recovery
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
EnvironmentFile=-/etc/default/warpget
ExecStart=/usr/local/sbin/warpget check
TimeoutStartSec=0
SyslogIdentifier=warpget
StandardOutput=journal
StandardError=journal
EOF

    cat > "${TIMER_PATH}" <<'EOF'
[Unit]
Description=Check WARP connectivity every minute

[Timer]
OnBootSec=1min
OnUnitActiveSec=1min
AccuracySec=10s
Persistent=true
Unit=warpget.service

[Install]
WantedBy=timers.target
EOF

    step "4/4" "启用定时检查并立即执行一次"
    systemctl daemon-reload
    systemctl enable --now "${PROGRAM_NAME}.timer"
    if ! systemctl start "${PROGRAM_NAME}.service"; then
        info "首次检查未恢复成功，请使用 journalctl -u warpget.service 查看日志"
    fi

    rm -f "${TEMP_SCRIPT}"
    TEMP_SCRIPT=""
    trap - EXIT

    printf '\n%b安装完成%b\n' "${GREEN}${BOLD}" "${RESET}"
    printf '  监控目标：Cloudflare 官方 IPv%s\n' "${ip_version}"
    printf '  检测地址：%s\n' "$([[ ${ip_version} == 4 ]] && printf '1.1.1.1' || printf '2606:4700:4700::1111')"
    printf '  检查周期：每分钟\n'
    printf '  恢复轮数：最多 %s 轮\n' "${max_retry}"
    printf '\n  查看状态：%bwarpget status%b\n' "${CYAN}" "${RESET}"
    printf '  查看日志：%bjournalctl -fu warpget.service%b\n\n' "${CYAN}" "${RESET}"
}

main() {
    local ip_version
    local max_retry

    print_banner
    check_root

    if [[ ${1:-} == "uninstall" ]]; then
        uninstall_warpget
        exit 0
    fi

    check_environment
    ip_version=$(read_ip_version "${1:-}")
    max_retry=$(read_retry "${2:-}")
    install_warpget "${ip_version}" "${max_retry}"
}

main "$@"
