# Codex QuotaBar

中文 | [English](#english)

还在一次又一次地点进设置菜单里看剩余额度？

Codex QuotaBar 是一个原生 macOS 菜单栏小工具，用来显示 Codex 的一周额度剩余百分比。

它会在菜单栏显示类似：

```text
⌁ 周 98%
```

点击菜单栏项目后，还可以查看：

- 一周额度剩余百分比与重置时间
- 使用限额重置次数，例如 `使用限额重置次数：2次`
- 最早 Full reset 到期时间（Mac 本地时区）
- 自动重置开关、下一次执行时间和最近一次成功结果
- 最近更新时间

## Full reset 到期前自动使用

在菜单中勾选「到期前自动使用 Full reset」。App 会为最早到期的一张 Full reset 创建一次性定时任务，默认在到期前 2 小时执行。计划保存在本机，App 启动、Mac 唤醒或额度刷新后会重新校准；不另建每小时检查的任务。

执行前会通过 Codex 官方 app-server 重新核对登录账号、重置券编号和有效期，只使用计划中的那张券，成功后再次读取额度确认结果。网络失败时使用同一请求编号重试，避免重复消耗；服务返回没有可重置窗口时在有效期内再试。单次重试通常间隔 5 分钟，并预留到期前 1 分钟的安全余量。

此功能默认关闭，需要用户主动开启。Mac 必须开机、联网且 QuotaBar 正在运行；睡眠时不能执行，若在到期前唤醒会补执行，已过期的券不会再使用。需要支持按券编号兑换的新版 Codex 客户端；目前会优先使用 ChatGPT/Codex App 内置的 Codex CLI。

## 系统要求

- macOS 14 或更高版本
- 已安装并登录 Codex
- 普通使用不需要 Xcode；只有从源码构建时才需要 Xcode 或 Swift 工具链

## 使用方式

如果你拿到的是打包好的 `CodexQuotaBar.app`：

1. 解压下载的 zip。
2. 将 `CodexQuotaBar.app` 拖到“应用程序”文件夹。
3. 首次打开时，如果 macOS 提示无法验证开发者，请按住 Control 右键点击 App，选择“打开”。
4. 如果仍然被拦截，请打开“系统设置”→“隐私与安全性”，在安全提示里点击“仍要打开”。
5. App 启动后会出现在菜单栏，不会显示 Dock 图标。

## 从源码构建

使用 Swift Package 构建：

```zsh
./scripts/build-app.sh
```

构建完成后会生成：

```text
dist/CodexQuotaBar.app
```

你也可以用 Xcode 打开：

```text
Xcode/CodexQuotaBar.xcodeproj
```

然后选择 `CodexQuotaBar` scheme 和 `My Mac`，按 `⌘R` 运行。

## 数据来源与隐私

Codex QuotaBar 会读取本机 Codex 登录状态：

```text
~/.codex/auth.json
```

然后请求：

```text
https://chatgpt.com/backend-api/wham/usage
```

它不会把访问令牌写入项目文件，不会打印令牌，也不会发送到第三方服务。

自动重置的开关、账号关联计划及执行记录仅保存在用户自己的 Mac 上，不随源码或 App 分发。公开版默认关闭自动重置，不包含任何个人设备配置。

## 限制

这个工具依赖 Codex 当前使用的 ChatGPT 用量接口。该接口不是公开稳定 API；如果接口路径或返回字段发生变化，App 可能需要更新。

---

## English

Codex QuotaBar is a native macOS menu bar utility that shows the remaining percentage of your Codex weekly quota.

It displays a compact status item like:

```text
⌁ W 98%
```

Clicking the menu bar item shows:

- remaining weekly quota and reset time
- usage limit reset count, for example `使用限额重置次数：2次`
- earliest Full reset expiration in the Mac's local time zone
- optional scheduled redemption, next run time, and last successful result
- last update time

## Redeem an expiring Full reset automatically

Enable the menu's automatic Full reset option. QuotaBar schedules a one-shot timer for the earliest-expiring credit, two hours before expiration. It persists the plan and reconciles it on launch, wake, or normal quota refresh. There is no separate hourly polling job. Redemption uses the official Codex app-server API with an explicit credit ID and a persisted idempotency key; account, expiration, and success are checked against fresh service data. Transient failures and `nothingToReset` schedule one-shot retries before expiry.

This feature is off by default. The Mac must be awake and online, and QuotaBar must be running. A wake before expiry can trigger a missed run; expired credits are skipped. A recent Codex client supporting explicit credit IDs is required.

## Requirements

- macOS 14 or later
- Codex installed and signed in
- Xcode is not required to run the packaged app. It is only needed if you want to build from source.

## Usage

If you have a packaged `CodexQuotaBar.app`:

1. Unzip the downloaded archive.
2. Drag `CodexQuotaBar.app` to Applications.
3. On first launch, if macOS blocks the app because the developer cannot be verified, Control-click the app and choose “Open”.
4. If macOS still blocks it, open System Settings → Privacy & Security, then click “Open Anyway” in the security prompt.
5. The app runs in the menu bar and does not show a Dock icon.

## Build from source

Build with Swift Package Manager:

```zsh
./scripts/build-app.sh
```

The app will be generated at:

```text
dist/CodexQuotaBar.app
```

You can also open the Xcode project:

```text
Xcode/CodexQuotaBar.xcodeproj
```

Select the `CodexQuotaBar` scheme and `My Mac`, then press `⌘R`.

## Data source and privacy

Codex QuotaBar reads the local Codex login state from:

```text
~/.codex/auth.json
```

Then it requests:

```text
https://chatgpt.com/backend-api/wham/usage
```

It does not write your access token into the project, print it, or send it to any third-party service.

Automatic reset preferences, account-associated plans, and result history stay on each user's own Mac and are not distributed with the source or app. The public version defaults to automatic reset being off and includes no personal device configuration.

## Limitations

This app relies on the ChatGPT usage endpoint currently used by Codex. It is not a public stable API. If the endpoint path or response fields change, the app may need to be updated.
