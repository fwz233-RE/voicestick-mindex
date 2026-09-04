# 语音转文字

这是一个 macOS 菜单栏语音转文字应用。应用使用系统默认麦克风采集语音，通过阿里云 DashScope 实时识别，并将结果显示在应用窗口中。

## 功能

- 菜单栏应用，按需打开结果窗口。
- 窗口内显示和编辑实时识别文字。
- 支持窗口按钮点击录音。
- 支持 `⌘⇧空格` 全局快捷键，按住快捷键录音，松开后结束。
- 识别完成后自动尝试粘贴到当前聚焦的第三方应用。
- 提供复制和再次插入按钮；如果第三方应用没有接收粘贴，识别结果仍保留在本应用中。
- 本地保存识别历史记录。
- API Key 只从环境变量或本机配置文件读取，不写入源代码。

## 开发环境

- macOS 12 或更新版本
- Swift 5.9 或更新版本

## 运行源码

```sh
cd desktop/macos
swift run VoiceToTextApp
```

## 构建安装包

```sh
scripts/build-macos.sh --release
scripts/make-dmg.sh
```

生成文件：

```text
build/VoiceToText-<version>.app
build/VoiceToText-<version>.dmg
```

首次录音时需要允许麦克风权限。快捷键监听需要在“系统设置 -> 隐私与安全性 -> 输入监控”中允许本应用；自动插入第三方应用需要在“系统设置 -> 隐私与安全性 -> 辅助功能”中允许本应用发送键盘事件。快捷键为 `⌘⇧空格`：按住录音，松开后结束。

## 本地配置 API Key

API Key 不写入源代码、构建产物或 Git。开发时可以通过环境变量提供：

```sh
DASHSCOPE_API_KEY="your-key-here" swift run VoiceToTextApp
```

从 Finder 启动已安装应用时，可以创建仅保存在本机的配置文件：

```sh
mkdir -p "$HOME/Library/Application Support/Voice to Text"
plutil -create xml1 "$HOME/Library/Application Support/Voice to Text/config.plist"
plutil -replace aliyunAPIKey -string "your-key-here" \\
  "$HOME/Library/Application Support/Voice to Text/config.plist"
chmod 600 "$HOME/Library/Application Support/Voice to Text/config.plist"
```

请使用你自己的新 Key 替换示例值，不要把真实 Key 写入仓库、提交记录、问题描述或截图。如果旧 Key 曾经暴露，应立即在 DashScope 控制台撤销并重新生成。
