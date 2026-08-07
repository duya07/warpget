# warpget

`warpget` 是配合 [fscarmen/warp](https://gitlab.com/fscarmen/warp) 使用的轻量 WARP 单栈掉线恢复工具。

它每分钟分别 ping Cloudflare 的 IPv4、IPv6 DNS：

- 两者都通：不处理。
- 只有一个不通：使用 fscarmen 的 `warp o` 命令恢复 WARP。
- 两者都不通：认为是 VPS 本身网络异常，不处理。

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

安装时会询问每次故障最多恢复几轮，默认 3 轮，允许范围为 1～20。

也可以直接指定，例如设置为 5 轮：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/duya07/warpget/main/install.sh) 5
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

修改 `/etc/default/warpget` 中的 `MAX_RETRY` 即可调整恢复轮数，无需重启定时器。

## 卸载

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/duya07/warpget/main/install.sh) uninstall
```

卸载不会删除或关闭 fscarmen/warp。

## 检查与恢复流程

1. 每分钟检查 `1.1.1.1` 和 `2606:4700:4700::1111`。
2. 发现单栈故障后执行 `wg-quick down warp`。
3. 确认 WARP 接口已关闭并写入默认 Endpoint。
4. 执行 `warp o` 重新建立 WARP。
5. 等待 10 秒后复查，按用户设置的轮数重试。
