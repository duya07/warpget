#!/usr/bin/env bash

set -uo pipefail

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

log() {
    local level=$1
    shift
    local message=$*

    printf '[warpget] [%s] %s\n' "${level}" "${message}"
    command -v logger >/dev/null 2>&1 && logger -t warpget "[${level}] ${message}" || true
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
        log WARNING "第 ${attempt}/${MAX_RETRY} 轮恢复：重启 WARP"
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
        log INFO "IPv${IP_VERSION} 正常"
        return 0
    fi

    log WARNING "IPv${IP_VERSION} 不通"
    recover
}

show_status() {
    printf '监控目标：IPv%s\n' "${IP_VERSION:-未配置}"
    printf '最大恢复轮数：%s\n' "${MAX_RETRY}"
    printf '检查周期：每分钟\n'
    systemctl status warpget.timer --no-pager || true
    printf '\n最近日志：\n'
    journalctl -u warpget.service -n 20 --no-pager || true
}

show_help() {
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
