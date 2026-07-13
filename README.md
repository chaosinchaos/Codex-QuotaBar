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
- 最近更新时间

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
- last update time

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

## Limitations

This app relies on the ChatGPT usage endpoint currently used by Codex. It is not a public stable API. If the endpoint path or response fields change, the app may need to be updated.
