#!/usr/bin/env bash

set -uo pipefail

readonly VERSION="1.1.1"
readonly CONFIG_FILE="/etc/default/warpget"
readonly WARP_CONFIG="/etc/wireguard/warp.conf"
readonly TARGET_V4="1.1.1.1"
readonly TARGET_V6="2606:4700:4700::1111"
readonly DEFAULT_ENDPOINT="engage.cloudflareclient.com:2408"
readonly PING_COUNT=5
readonly PING_TIMEOUT=3
readonly RETRY_INTERVAL=10

if [[ -r ${CONFIG_FILE} ]]; then
    # shellcheck source=/dev/null
    source "${CONFIG_FILE}"
fi
IP_VERSION="${IP_VERSION:-}"
MAX_RETRY="${MAX_RETRY:-3}"

if [[ -t 1 && ${TERM:-dumb} != "dumb" && -z ${NO_COLOR:-} ]]; then
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

log() {
    local level=$1
    shift
    local message=$*
    local color="${GREEN}"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    case ${level} in
        WARNING) color="${YELLOW}" ;;
        ERROR) color="${RED}" ;;
    esac

    printf '%b[%s] [%-7s]%b %s\n' "${color}" "${timestamp}" "${level}" "${RESET}" "${message}"
}

die() {
    log ERROR "$*" >&2
    exit 1
}

validate_config() {
    [[ ${EUID} -eq 0 ]] || die "检查和恢复需要 root 权限"
    [[ ${IP_VERSION} == "4" || ${IP_VERSION} == "6" ]] ||
        die "IP_VERSION 必须是 4 或 6，请重新运行安装脚本选择"
    if [[ ! ${MAX_RETRY} =~ ^[0-9]+$ ]] || (( MAX_RETRY < 1 || MAX_RETRY > 20 )); then
        die "MAX_RETRY 必须是 1～20 的整数"
    fi
    command -v ping >/dev/null 2>&1 || die "缺少 ping"
    command -v wg >/dev/null 2>&1 || die "缺少 wg"
    command -v wg-quick >/dev/null 2>&1 || die "缺少 wg-quick"
    command -v warp >/dev/null 2>&1 || die "缺少 fscarmen/warp 提供的 warp 命令"
    [[ -s ${WARP_CONFIG} ]] || die "找不到 ${WARP_CONFIG}"
}

check_selected_ip() {
    if [[ ${IP_VERSION} == "4" ]]; then
        ping -4 -q -c "${PING_COUNT}" -W "${PING_TIMEOUT}" "${TARGET_V4}" >/dev/null 2>&1
    else
        ping -6 -q -c "${PING_COUNT}" -W "${PING_TIMEOUT}" "${TARGET_V6}" >/dev/null 2>&1
    fi
}

set_default_endpoint() {
    grep -qE '^[[:space:]]*Endpoint[[:space:]]*=' "${WARP_CONFIG}" || {
        log ERROR "warp.conf 中没有 Endpoint 配置"
        return 1
    }

    sed -i -E \
        "s|^[[:space:]]*Endpoint[[:space:]]*=.*$|Endpoint = ${DEFAULT_ENDPOINT}|" \
        "${WARP_CONFIG}"
}

restart_warp() {
    # warp o 是开关命令，因此必须先确认接口已经关闭，避免误把正常接口关掉。
    wg-quick down warp >/dev/null 2>&1 || true
    if wg show warp >/dev/null 2>&1; then
        log ERROR "WARP 接口未能关闭，本轮不执行 warp o"
        return 1
    fi

    set_default_endpoint || return 1
    warp o
}

recover() {
    local attempt

    for (( attempt=1; attempt<=MAX_RETRY; attempt++ )); do
        log WARNING "[${attempt}/${MAX_RETRY}] IPv${IP_VERSION} 不通，正在重启 WARP"
        if ! restart_warp; then
            log ERROR "第 ${attempt} 轮重启失败"
            continue
        fi

        sleep "${RETRY_INTERVAL}"
        if check_selected_ip; then
            log INFO "IPv${IP_VERSION} 已恢复"
            return 0
        fi
    done

    log ERROR "达到最大恢复轮数，IPv${IP_VERSION} 仍未恢复"
    return 1
}

check_once() {
    validate_config
    if check_selected_ip; then
        # 定时任务正常时保持静默；用户手动运行时仍显示检查结果。
        [[ -t 1 ]] && log INFO "IPv${IP_VERSION} 正常"
        return 0
    fi

    log WARNING "IPv${IP_VERSION} 不通"
    recover
}

show_status() {
    local timer_state
    local timer_enabled
    local state_color="${RED}"
    local target="未配置"
    local monitor_name="未配置"

    timer_state=$(systemctl is-active warpget.timer 2>/dev/null || true)
    timer_enabled=$(systemctl is-enabled warpget.timer 2>/dev/null || true)
    [[ ${timer_state} == "active" ]] && state_color="${GREEN}"
    if [[ ${IP_VERSION} == "4" ]]; then
        monitor_name="Cloudflare 官方 IPv4"
        target="1.1.1.1"
    elif [[ ${IP_VERSION} == "6" ]]; then
        monitor_name="Cloudflare 官方 IPv6"
        target="2606:4700:4700::1111"
    fi

    print_banner
    printf '\n%b当前配置%b\n' "${BOLD}" "${RESET}"
    printf '  监控目标：%s\n' "${monitor_name}"
    printf '  检测地址：%s\n' "${target}"
    printf '  检查周期：每分钟\n'
    printf '  恢复轮数：最多 %s 轮\n' "${MAX_RETRY}"
    printf '  定时任务：%b%s%b（%s）\n' "${state_color}" "${timer_state:-unknown}" "${RESET}" "${timer_enabled:-unknown}"
    printf '\n%b最近日志%b\n' "${BOLD}" "${RESET}"
    journalctl -u warpget.service -n 12 --no-pager -o cat || true
}

show_help() {
    print_banner
    cat <<'EOF'

用法：warpget <命令>

  check    立即检查所选 IP，故障时恢复 WARP
  status   查看定时器状态和最近日志
  help     显示帮助

修改配置：编辑 /etc/default/warpget
  IP_VERSION=4 或 6
  MAX_RETRY=1..20
EOF
}

case "${1:-check}" in
    check)
        check_once
        ;;
    status)
        show_status
        ;;
    help|-h|--help)
        show_help
        ;;
    *)
        show_help >&2
        exit 2
        ;;
esac
