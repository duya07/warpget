#!/usr/bin/env bash

set -Eeuo pipefail

readonly PROGRAM_NAME="warpget"
readonly INSTALL_PATH="/usr/local/sbin/${PROGRAM_NAME}"
readonly CONFIG_PATH="/etc/default/${PROGRAM_NAME}"
readonly SERVICE_PATH="/etc/systemd/system/${PROGRAM_NAME}.service"
readonly TIMER_PATH="/etc/systemd/system/${PROGRAM_NAME}.timer"
readonly DOWNLOAD_URL="https://raw.githubusercontent.com/duya07/warpget/main/warpget.sh"
TEMP_SCRIPT=""

info() {
    printf '[warpget] %s\n' "$*"
}

die() {
    printf '[warpget] 错误：%s\n' "$*" >&2
    exit 1
}

check_root() {
    [[ ${EUID} -eq 0 ]] || die "请使用 root 用户运行安装脚本"
}

validate_retry() {
    [[ $1 =~ ^[0-9]+$ ]] && (( 1 <= $1 && $1 <= 20 ))
}

read_retry() {
    local retry="${1:-}"

    if [[ -z ${retry} && -t 0 ]]; then
        read -r -p "每次故障最多恢复几轮？[3]：" retry
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
    local max_retry=$1
    TEMP_SCRIPT=$(mktemp)
    trap cleanup_temp EXIT

    info "下载监控脚本"
    curl -fsSL "${DOWNLOAD_URL}" -o "${TEMP_SCRIPT}"
    bash -n "${TEMP_SCRIPT}" || die "下载的监控脚本语法检查失败"
    install -m 0755 "${TEMP_SCRIPT}" "${INSTALL_PATH}"

    umask 022
    printf 'MAX_RETRY=%s\n' "${max_retry}" > "${CONFIG_PATH}"

    cat > "${SERVICE_PATH}" <<'EOF'
[Unit]
Description=WARP IPv4/IPv6 connectivity recovery
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
EnvironmentFile=-/etc/default/warpget
ExecStart=/usr/local/sbin/warpget check
TimeoutStartSec=0
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

    systemctl daemon-reload
    systemctl enable --now "${PROGRAM_NAME}.timer"
    if ! systemctl start "${PROGRAM_NAME}.service"; then
        info "首次检查未恢复成功，请使用 journalctl -u warpget.service 查看日志"
    fi

    rm -f "${TEMP_SCRIPT}"
    TEMP_SCRIPT=""
    trap - EXIT

    info "安装完成：每分钟检查一次，每次最多恢复 ${max_retry} 轮"
    info "查看状态：warpget status"
    info "查看日志：journalctl -u warpget.service"
}

main() {
    check_root

    if [[ ${1:-} == "uninstall" ]]; then
        uninstall_warpget
        exit 0
    fi

    check_environment
    install_warpget "$(read_retry "${1:-}")"
}

main "$@"
