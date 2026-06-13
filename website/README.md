# VoiceStick 网站

这里是 VoiceStick 官网和 Sparkle / WinSparkle 更新源的 Vue + Vite 源码。网站使用 `vue-i18n` 支持简体中文和英文；当浏览器语言以 `zh` 开头时，会自动显示中文。

建议的 GitHub Pages 地址：

```text
https://fwz233-re.github.io/voicestick-mindex/
```

macOS 和 Windows 应用会检查根路径下生成的 appcast：

```text
https://fwz233-re.github.io/voicestick-mindex/appcast.xml
```

## 发布流程

1. 首次发布前生成 Sparkle 密钥，并确保私钥不要提交到 Git：

   ```bash
   cd desktop/macos
   swift package resolve
   find .build -name generate_keys -type f -perm -111 -print -quit
   .build/artifacts/sparkle/Sparkle/bin/generate_keys --account voicestick
   ```

2. 发布构建前，把公钥写入应用：

   ```bash
   SPARKLE_PUBLIC_ED_KEY="..." scripts/build-macos.sh --release
   ```

3. 创建 DMG：

   ```bash
   scripts/make-dmg.sh
   ```

4. 上传这些文件到 GitHub Release `v<version>`：

   ```text
   build/VoiceStick-<version>.dmg
   build/VoiceStick-<version>.zip
   ```

5. 更新 `website/public/appcast.xml`：

   - `url`：指向 GitHub Release 中的 ZIP，不是 DMG
   - `sparkle:edSignature`：来自 `build/VoiceStick-<version>.signature`
   - `length`：来自 `wc -c build/VoiceStick-<version>.zip` 的字节数

首页下载区会直接链接到当前版本的 macOS DMG 和 Windows MSI。请保持 `website/package.json` 与最新公开版本一致，这样直接下载链接和固件备用地址才会指向正确版本。浏览器刷写器会从 `VITE_FIRMWARE_MANIFEST_URL` 读取固件清单，并使用其中的 `merged_url`；如果清单加载失败，会退回到根据 `website/package.json` 推导出的版本化合并固件地址。

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

生成的 `dist/` 目录会部署到 GitHub Pages。`public/appcast.xml` 会复制为 `dist/appcast.xml`。固件清单本身托管在 OSS，不托管在 GitHub Pages。

## GitHub Actions

- `.github/workflows/release.yml` 会在 `v*` 标签或手动触发时运行。它会构建 macOS 应用，对 DMG 进行签名和公证，把 DMG / ZIP / signature 上传到匹配的 GitHub Release，构建版本化 OTA 和合并固件镜像，将固件清单发布到 OSS，重写 `public/appcast.xml`，构建 Vue 网站，并部署 `website/dist` 到 GitHub Pages。
- `scripts/build-msi.bat` 在插入 USB 签名密钥的本地 Windows 签名机上运行。生成的 `VoiceStick_<version>.msi` 需要上传到匹配的 GitHub Release。
- `.github/workflows/deploy-website.yml` 会在 `main` 分支的 `website/**` 变更时运行，也可以在上传 Windows MSI 后手动触发。部署前，它会读取当前线上 appcast 和最新 GitHub Release，然后根据最新 ZIP / signature 和可选 MSI 资源重新生成 `public/appcast.xml`。如果最新 Release 还没有 Windows MSI，则保留之前的 Windows 更新项。

发布构建需要配置以下仓库密钥：

```text
SPARKLE_PUBLIC_ED_KEY
SPARKLE_PRIVATE_ED_KEY
MACOS_CERTIFICATE_P12
MACOS_CERTIFICATE_PASSWORD
APPLE_ID
APPLE_TEAM_ID
APPLE_APP_SPECIFIC_PASSWORD
```
