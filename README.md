# warpget

`warpget` 是配合 [fscarmen/warp](https://gitlab.com/fscarmen/warp) 使用的轻量 WARP 掉线恢复工具。

安装时由用户选择服务器通过 WARP 获取 Cloudflare 官方 IPv4 或 IPv6：

- 选择 IPv4：每分钟只 ping `1.1.1.1`。
- 选择 IPv6：每分钟只 ping `2606:4700:4700::1111`。
- 所选 IP 不通：使用 fscarmen 的 `warp o` 命令恢复 WARP。

恢复前会把 `/etc/wireguard/warp.conf` 的 Endpoint 统一为 fscarmen 当前默认值 `engage.cloudflareclient.com:2408`。

## 要求

- 已安装并能正常使用 `fscarmen/warp`。
- 存在 `/etc/wireguard/warp.conf` 和 `warp`、`wg`、`wg-quick` 命令。
- 使用 systemd 的 Linux VPS。
- 使用 root 用户安装。

## 安装

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/duya07/warpget/main/install.sh)
```

安装时会依次询问：

1. 获取 Cloudflare 官方 IPv4 还是 IPv6。
2. 每次故障最多恢复几轮，默认 3 轮，允许范围为 1～20。

也可以直接指定。第一个参数是 IP 版本，第二个参数是恢复轮数。例如只监控 IPv4、最多恢复 5 轮：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/duya07/warpget/main/install.sh) 4 5
```

只监控 IPv6、最多恢复 3 轮：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/duya07/warpget/main/install.sh) 6 3
```

## 使用

```bash
# 查看定时器和最近日志
warpget status

# 立即检查一次
warpget check

# 持续查看日志
journalctl -fu warpget.service
```

修改 `/etc/default/warpget` 中的 `IP_VERSION` 和 `MAX_RETRY` 即可切换监控目标或调整恢复轮数，无需重启定时器。

## 卸载

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/duya07/warpget/main/install.sh) uninstall
```

卸载不会删除或关闭 fscarmen/warp。

## 检查与恢复流程

1. 每分钟只 ping 用户选择的 IPv4 或 IPv6 目标。
2. 所选 IP 不通时执行 `wg-quick down warp`。
3. 确认 WARP 接口已关闭并写入默认 Endpoint。
4. 执行 `warp o` 重新建立 WARP。
5. 等待 10 秒后复查，按用户设置的轮数重试。
