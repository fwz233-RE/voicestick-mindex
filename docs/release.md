# VoiceStick Release Process

VoiceStick releases have three moving parts:

- macOS app: built, signed, notarized, and uploaded by GitHub Actions.
- StickS3 firmware: built by GitHub Actions and uploaded to Aliyun OSS and GitHub Releases.
- Windows app: built into a signed setup installer manually on the Windows signing machine, then uploaded to the matching GitHub Release.

The Windows package is the special case because the signing certificate is local hardware or local machine state. The release process supports either order:

- Build and sign Windows first, then let GitHub Actions publish macOS and firmware.
- Publish macOS and firmware first, then build/sign Windows and upload it afterward.

In both cases, finish by redeploying the website and verifying all update URLs.

## Version Sources

Update both version files before creating the release tag:

```text
VERSION
firmware/version.txt
```

`VERSION` is used by the desktop packaging scripts and the GitHub release workflow. `firmware/version.txt` is the firmware version reported by the device, so it must match the release version for OTA update detection to work correctly.

For release `0.2.4`, the tag must be:

```text
v0.2.4
```

The GitHub Actions release workflow validates that `v<VERSION>` matches the pushed tag.

## Standard Flow

1. Update `VERSION` and `firmware/version.txt` to the new version.
2. Commit the version change and any release workflow changes.
3. Push `main`.
4. Push the release tag:

```sh
git tag -a v0.2.4 -m "VoiceStick 0.2.4"
git push origin main
git push origin v0.2.4
```

Pushing the tag runs `.github/workflows/release.yml`. That workflow builds:

- `VoiceStick-<version>.dmg`
- `VoiceStick-<version>.zip`
- `VoiceStick-<version>.signature`
- `voicestick-firmware-sticks3-ota-<version>.bin`
- `voicestick-firmware-sticks3-merged-<version>.bin`
- firmware checksums and `manifest.json`

It also uploads the firmware to Aliyun OSS under both:

```text
voicestick/firmwares/<version>/
voicestick/firmwares/latest/
```

After publishing the GitHub Release, the workflow requests a website deploy so the appcast is refreshed.

## Windows First

Use this flow when the Windows package has already been built and signed before the macOS/firmware release.

1. Set the new version in `VERSION`.
2. On the Windows signing machine, build and sign the setup installer:

```bat
scripts\build-exe-installer.bat
```

The output is:

```text
desktop\windows\build-installer-x64\VoiceStickSetup-<version>.exe
```

3. Confirm `firmware/version.txt` also matches the new version.
4. Commit, push `main`, and push the matching `v<version>` tag.
5. Wait for the release workflow to finish successfully.
6. Upload the signed setup installer to the same GitHub Release:

```sh
gh release upload v0.2.4 desktop/windows/build-installer-x64/VoiceStickSetup-0.2.4.exe --repo fwz233-RE/voicestick-mindex
```

7. Re-run the website deploy workflow so the appcast includes the Windows setup installer:

```sh
gh workflow run deploy-website.yml --repo fwz233-RE/voicestick-mindex --ref main
```

## macOS and Firmware First

Use this flow when macOS and firmware should be published before the Windows package is ready.

1. Update `VERSION` and `firmware/version.txt`.
2. Commit, push `main`, and push the matching `v<version>` tag.
3. Wait for the release workflow to publish macOS and firmware.
4. Later, on the Windows signing machine, build and sign the setup installer:

```bat
scripts\build-exe-installer.bat
```

5. Upload the signed setup installer to the already published GitHub Release:

```sh
gh release upload v0.2.4 desktop/windows/build-installer-x64/VoiceStickSetup-0.2.4.exe --repo fwz233-RE/voicestick-mindex
```

6. Re-run the website deploy workflow:

```sh
gh workflow run deploy-website.yml --repo fwz233-RE/voicestick-mindex --ref main
```

Until the setup installer is uploaded and the website deploy has run, Windows clients will not see the new Windows update in the appcast.

## Verification

After every release, verify the appcast, firmware manifest, and actual package URLs.

Stable update endpoints:

```text
https://fwz233-re.github.io/voicestick-mindex/appcast.xml
https://xiaozhi-voice-assistant.oss-cn-shenzhen.aliyuncs.com/voicestick/firmwares/latest/manifest.json
```

For version `0.2.4`, the appcast should contain:

```text
https://github.com/fwz233-RE/voicestick-mindex/releases/download/v0.2.4/VoiceStickSetup-0.2.4.exe
https://github.com/fwz233-RE/voicestick-mindex/releases/download/v0.2.4/VoiceStick-0.2.4.zip
```

The firmware manifest should contain:

```text
https://xiaozhi-voice-assistant.oss-cn-shenzhen.aliyuncs.com/voicestick/firmwares/0.2.4/voicestick-firmware-sticks3-ota-0.2.4.bin
https://xiaozhi-voice-assistant.oss-cn-shenzhen.aliyuncs.com/voicestick/firmwares/0.2.4/voicestick-firmware-sticks3-merged-0.2.4.bin
```

Use `HEAD` requests or a browser to confirm every URL returns `200`.

```powershell
Invoke-WebRequest -UseBasicParsing https://fwz233-re.github.io/voicestick-mindex/appcast.xml
Invoke-WebRequest -UseBasicParsing https://xiaozhi-voice-assistant.oss-cn-shenzhen.aliyuncs.com/voicestick/firmwares/latest/manifest.json

Invoke-WebRequest -UseBasicParsing -Method Head https://github.com/fwz233-RE/voicestick-mindex/releases/download/v0.2.4/VoiceStickSetup-0.2.4.exe
Invoke-WebRequest -UseBasicParsing -Method Head https://github.com/fwz233-RE/voicestick-mindex/releases/download/v0.2.4/VoiceStick-0.2.4.zip
Invoke-WebRequest -UseBasicParsing -Method Head https://xiaozhi-voice-assistant.oss-cn-shenzhen.aliyuncs.com/voicestick/firmwares/0.2.4/voicestick-firmware-sticks3-ota-0.2.4.bin
Invoke-WebRequest -UseBasicParsing -Method Head https://xiaozhi-voice-assistant.oss-cn-shenzhen.aliyuncs.com/voicestick/firmwares/0.2.4/voicestick-firmware-sticks3-merged-0.2.4.bin
```

Also confirm these workflow runs are successful:

- `Release Build`
- `Deploy Website to GitHub Pages`

The release is complete when:

- macOS appcast entry points to the new Sparkle ZIP.
- Windows appcast entry points to the new signed setup installer.
- firmware `latest/manifest.json` reports the new version.
- OTA and merged firmware URLs are reachable.
- the GitHub Release contains all macOS, Windows, and firmware assets.
