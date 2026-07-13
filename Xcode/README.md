# 用 Xcode 运行

1. 安装 Xcode（App Store）。
2. 双击 `CodexQuotaBar.xcodeproj`。
3. 在顶部 Scheme 选择 `CodexQuotaBar` 和 `My Mac`，按 `⌘R`。

首次运行会在菜单栏显示 `⌁ …`，然后自动读取一周额度和使用限额重置次数。读取会在短暂失败时自动重试三次，并保留上次成功数据。它使用本机 Codex 登录状态；令牌不会写入项目或发送到第三方。

---

# Run with Xcode

1. Install Xcode from the App Store.
2. Double-click `CodexQuotaBar.xcodeproj`.
3. Choose the `CodexQuotaBar` scheme and `My Mac`, then press `⌘R`.

On first launch, the menu bar item shows `⌁ …`, then automatically loads the weekly quota and usage limit reset count. The app retries transient failures up to three times and keeps the last successful data. It uses the local Codex login state; tokens are not written to the project or sent to third parties.
