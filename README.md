# 掌柜台

[xianyu-auto-reply-fix](https://github.com/GuDong2003/xianyu-auto-reply-fix) 的 macOS 原生客户端。

纯 AppKit，不用 Xcode —— 装了 Command Line Tools 就能编译。

## 为什么写这个

浏览器后台要来回切标签，手机在旁边的时候更别扭。这个把最常看的几件事拎出来做成一个原生窗口：谁在等你回话、哪单要补发、今天卖了多少。

## 要求

- macOS 14+，Apple Silicon
- 本机已经跑着 xianyu-auto-reply-fix 后台（默认 `127.0.0.1:8090`）
- Xcode Command Line Tools：`xcode-select --install`（**不需要**完整 Xcode）

## 编译

```bash
./build.sh
```

产物在 `build/掌柜台.app`，拖进 `/Applications` 就能用。

## 账号是怎么来的

不需要在 App 里配任何账号 —— 打开后直接读后台 `GET /cookies/details` 的账号列表：

- 后台加了账号，App 里就有，不用改代码也不用重填
- **一个、两个、十个都行**，订单页和会话页的筛选按钮按实际账号动态生成
- 显示名优先用后台的**备注**（remark），其次账号名（username），都没有就显示 ID 后 6 位

登录用的管理员密码只从 `xianyu-server/.env` 的 `ADMIN_PASSWORD` 读，App 里不存第二份。token 只在内存里，401 会自动重登一次。

如果后台不在 `~/Documents/xianyu`，去「设置 → 项目目录」选一下真实的目录。

## 页面

| 页面 | 做什么 |
|---|---|
| 总览 | 每个账号一张卡：连接状态（正常/假在线/重连中/断开）、今日本周本月营收、待处理事项 |
| 订单 | 按账号 + 状态筛，支持关键词，可导出 CSV |
| 会话 | 按「等人回」筛，能直接回消息 |
| 账号 | 启停、重连、看运行状态 |
| 发货规则 / 日志 / 设置 | 规则增删改、发货日志、服务启停与外观 |

「假在线」是特意做的一档：`running`/`ws`/`session` 都为 true 但消息流已经卡死，这种情况不能点亮绿点。

## 已知限制

- **只有 macOS**。Windows / Linux 用不了。
- **营收那三个数字**依赖后台的 `/api/sales/paid-summary`（按平台实付口径算，不用订单标价）。这个接口不在上游开源版里 —— 后台没有的话，整块营收区域**自动隐藏**，其它功能照常。
- **服务启停**依赖 `~/Library/Application Support/xianyu/xianyu-supervise.sh`。没有这个脚本时那两个按钮不工作，其它功能不受影响。

## 和上游的关系

这是第三方客户端，不是官方组件。它通过 HTTP 调后台接口，**不包含上游代码**。

上游项目是 AGPL-3.0，这里也用 AGPL-3.0。README 里已经写明来源，欢迎按需改。

## 目录

```
Sources/        全部 Swift 源码（15 个文件）
Resources/      Info.plist + 图标
tools/          生成图标的小脚本
build.sh        编译 + ad-hoc 签名
```

## 许可

AGPL-3.0，见 [LICENSE](LICENSE)。
