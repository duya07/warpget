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
    if [[ ! ${MAX_RETRY} =~ ^[0-9]+$ ]] || (( MAX_RETRY < 1 || MAX_RETRY > 20 )); then
        die "MAX_RETRY 必须是 1～20 的整数"
    fi
    command -v ping >/dev/null 2>&1 || die "缺少 ping"
    command -v wg >/dev/null 2>&1 || die "缺少 wg"
    command -v wg-quick >/dev/null 2>&1 || die "缺少 wg-quick"
    command -v warp >/dev/null 2>&1 || die "缺少 fscarmen/warp 提供的 warp 命令"
    [[ -s ${WARP_CONFIG} ]] || die "找不到 ${WARP_CONFIG}"
}

check_ipv4() {
    ping -4 -q -c "${PING_COUNT}" -W "${PING_TIMEOUT}" "${TARGET_V4}" >/dev/null 2>&1
}

check_ipv6() {
    ping -6 -q -c "${PING_COUNT}" -W "${PING_TIMEOUT}" "${TARGET_V6}" >/dev/null 2>&1
}

read_connectivity() {
    IPV4_OK=0
    IPV6_OK=0
    check_ipv4 && IPV4_OK=1
    check_ipv6 && IPV6_OK=1
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
        read_connectivity

        if (( IPV4_OK == 1 && IPV6_OK == 1 )); then
            log INFO "IPv4、IPv6 已恢复"
            return 0
        fi

        if (( IPV4_OK == 0 && IPV6_OK == 0 )); then
            log WARNING "IPv4、IPv6 同时不通，停止恢复"
            return 0
        fi
    done

    log ERROR "达到最大恢复轮数，单栈仍未恢复"
    return 1
}

check_once() {
    validate_config
    read_connectivity

    if (( IPV4_OK == 1 && IPV6_OK == 1 )); then
        log INFO "IPv4、IPv6 正常"
        return 0
    fi

    if (( IPV4_OK == 0 && IPV6_OK == 0 )); then
        log WARNING "IPv4、IPv6 同时不通，不执行 WARP 恢复"
        return 0
    fi

    (( IPV4_OK == 0 )) && log WARNING "IPv4 不通"
    (( IPV6_OK == 0 )) && log WARNING "IPv6 不通"
    recover
}

show_status() {
    printf '最大恢复轮数：%s\n' "${MAX_RETRY}"
    printf '检查周期：每分钟\n'
    systemctl status warpget.timer --no-pager || true
    printf '\n最近日志：\n'
    journalctl -u warpget.service -n 20 --no-pager || true
}

show_help() {
    cat <<'EOF'
用法：warpget <命令>

  check    立即检查，单栈故障时恢复 WARP
  status   查看定时器状态和最近日志
  help     显示帮助

修改重试次数：编辑 /etc/default/warpget 后设置 MAX_RETRY=1..20
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
