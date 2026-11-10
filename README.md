# 掌柜台

[xianyu-auto-reply-fix](https://github.com/GuDong2003/xianyu-auto-reply-fix) 的 macOS 原生客户端。

纯 AppKit 手写，不用 Xcode —— 装了 Command Line Tools 就能编译。

---

## 它解决什么

浏览器后台要来回切标签，手机放在旁边的时候更别扭。这个东西把最常看的几件事拎出来做成一个原生窗口：

- **谁在等我回话** —— 一眼看到有几个买家在等、最久的等了多久
- **哪一单货没发成** —— 失败的单单独拎出来，不用翻一长串日志
- **今天卖了多少** —— 按平台实付口径，不是订单标价

服务在后台独立跑，关掉这个窗口不影响自动发货。

## 快速开始

```bash
# 1. 先确认后台在跑
curl http://127.0.0.1:8090/health

# 2. 编译（需要 CLT：xcode-select --install）
./build.sh

# 3. 产物拖进 /Applications，双击打开
open build/掌柜台.app
```

打开就是登录状态 —— 密码从后台的 `xianyu-server/.env` 里读，不用你输。

## 账号是怎么来的

**不用在 App 里配任何账号。** 打开后直接读后台 `GET /cookies/details`：

- 后台有几个账号，这里就有几个，加号减号都不用改代码
- 订单页、会话页的筛选按钮按实际账号**动态生成**，一个两个十个都行
- 显示名优先用后台的**账号备注**，没有就用账号名，再没有就显示 ID 后 6 位

> 想让 App 里显示你熟悉的名字？去后台给账号填个备注就行。

密码只从 `.env` 的 `ADMIN_PASSWORD` 读，App 里不存第二份；token 只在内存里，401 会自动重登一次。

## 页面

| 页面 | 做什么 |
|---|---|
| 总览 | 每个账号一张卡：连接状态、今日本周本月营收、待处理汇总 |
| 订单 | 按账号 + 状态筛，支持关键词，可导出 CSV |
| 会话 | 按「等人回」筛，能直接回消息 |
| 账号 | 启停、重连、看运行状态 |
| 发货规则 / 日志 / 设置 | 规则增删改、发货日志、服务启停与外观 |

**连接状态分五档**，不是二值：正常 / **假在线** / 重连中 / 断开 / 停用。

「假在线」是特意做的一档 —— `running`、`ws`、`session` 都是 true，但消息流已经卡死。这种情况不能点亮绿点，否则你会以为没事，其实消息早就收不到了。

## 常见问题

**打开一片空白，说读不到店铺**

后台没起，或者端口不对。先跑 `curl http://127.0.0.1:8090/health` 确认；后台在别的目录或端口，去「设置 → 项目目录」改。

**营收那三个数字不见了**

正常。它依赖后台的 `/api/sales/paid-summary`（按平台实付口径算的自定义接口），上游开源版没有。接口返回 404，整块营收自动收起，不影响其它功能。

**编译报 `swiftc: command not found`**

`xcode-select --install`，装 Command Line Tools 就够，不需要完整的 Xcode。

**服务启停按钮点了没反应**

它调的是 `~/Library/Application Support/xianyu/xianyu-supervise.sh`。没有这个脚本时这两个按钮不工作，其它功能不受影响。

**Windows / Linux 能用吗**

不能，只有 macOS。

## 已知限制

- macOS 14+，Apple Silicon（arm64）
- App 自身没有开机自启 —— 服务由 launchd 托管，App 只是个看板
- 服务启停依赖上面提到的 `supervise.sh`

## 和上游的关系

这是第三方客户端，**不是官方组件**。它通过 HTTP 调后台接口，不包含上游任何代码。

上游是 AGPL-3.0，这里也用 AGPL-3.0。README 里已注明来源，欢迎按需改。

## 目录

```
Sources/        15 个 Swift 文件，全部界面与逻辑
Resources/      Info.plist + 图标
tools/          生成图标的小脚本
build.sh        编译 + ad-hoc 签名
```

## 许可

AGPL-3.0，见 [LICENSE](LICENSE)。
