# VoiceStick 网站

这里是 VoiceStick 官网的 Vue + Vite 源码。网站使用 `vue-i18n` 支持简体中文和英文；当浏览器语言以 `zh` 开头时，会自动显示中文。

建议的 GitHub Pages 地址：

```text
https://fwz233-re.github.io/voicestick-mindex/
```

macOS 和 Windows 应用只检测 GitHub 最新 Release 是否存在新版本；发现新版本后会打开下载页面，由用户手动下载安装包并重新安装。

## 发布流程

1. 构建 macOS app：

```bash
scripts/build-macos.sh --release
```

2. 创建 DMG：

```bash
scripts/make-dmg.sh
```

3. 上传这些文件到 GitHub Release `v<version>`：

```text
build/VoiceStick-<version>.dmg
build/VoiceStick-<version>.dmg.sha256
```

首页下载区会直接链接到当前版本的 macOS DMG 和 Windows 安装包。请保持 `website/package.json` 与最新公开版本一致，这样直接下载链接和固件备用地址才会指向正确版本。浏览器刷写器会从 `VITE_FIRMWARE_MANIFEST_URL` 读取固件清单，并使用其中的 `merged_url`；如果清单加载失败，会退回到根据 `website/package.json` 推导出的版本化合并固件地址。

## 本地开发

```bash
cd website
npm install
npm run dev
```

## 构建

```bash
cd website
npm run build
```

生成的 `dist/` 目录会部署到 GitHub Pages。固件清单本身托管在 OSS，不托管在 GitHub Pages。

## GitHub Actions

- `.github/workflows/release.yml` 会在 `v*` 标签或手动触发时运行。它会构建 macOS 应用，对 DMG 进行签名和公证，把 DMG 与校验文件上传到匹配的 GitHub Release，构建版本化 OTA 和合并固件镜像，将固件清单发布到 OSS，并部署 `website/dist` 到 GitHub Pages。
- `.github/workflows/build-macos-unsigned.yml` 可以手动构建未公证的 macOS DMG，并可覆盖上传到指定 GitHub Release。
- `scripts/build-exe-installer.bat` 在插入 USB 签名密钥的本地 Windows 签名机上运行。生成的 Windows 安装包需要上传到匹配的 GitHub Release。
- `.github/workflows/deploy-website.yml` 会在 `main` 分支的 `website/**` 变更时运行，也可以手动触发。

发布构建需要配置以下仓库密钥：

```text
MACOS_CERTIFICATE_P12
MACOS_CERTIFICATE_PASSWORD
APPLE_ID
APPLE_TEAM_ID
APPLE_APP_SPECIFIC_PASSWORD
```