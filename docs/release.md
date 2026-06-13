# VoiceStick Release Process

VoiceStick releases have three moving parts:

- macOS app: built as DMG by GitHub Actions, then uploaded to GitHub Releases.
- StickS3 firmware: built by GitHub Actions and uploaded to Aliyun OSS and GitHub Releases.
- Windows app: built into a signed setup installer manually on the Windows signing machine, then uploaded to the matching GitHub Release.

App update checks only compare the local version with the latest GitHub Release. When a newer version exists, the app opens the Release download page and the user reinstalls manually.

## Version Sources

Update both version files before creating the release tag:

```text
VERSION
firmware/version.txt
```

`VERSION` is used by desktop packaging, website links, and GitHub workflows. `firmware/version.txt` is the firmware version reported by the device, so it must match the release version for OTA update detection.

For release `0.3.5`, the tag must be:

```text
v0.3.5
```

The GitHub Actions release workflow validates that `v<VERSION>` matches the pushed tag or manual input.

## Standard Flow

1. Update `VERSION` and `firmware/version.txt` to the new version.
2. Commit the version change and any release workflow changes.
3. Push `main`.
4. Push the release tag:

```sh
git tag -a v0.3.5 -m "VoiceStick 0.3.5"
git push origin main
git push origin v0.3.5
```

Pushing the tag runs `.github/workflows/release.yml`. That workflow builds and uploads:

- `VoiceStick-<version>.dmg`
- `VoiceStick-<version>.dmg.sha256`
- `voicestick-firmware-sticks3-ota-<version>.bin`
- `voicestick-firmware-sticks3-ota-<version>.bin.sha256`
- `voicestick-firmware-sticks3-merged-<version>.bin`
- `voicestick-firmware-sticks3-merged-<version>.bin.sha256`
- `manifest.json`

It also uploads firmware to Aliyun OSS under both:

```text
voicestick/firmwares/<version>/
voicestick/firmwares/latest/
```

## Unsigned macOS Rebuild for an Existing Release

Use this when replacing only macOS DMG assets in an existing release:

```sh
gh workflow run "Build Unsigned macOS" --ref main -f release_tag=v0.3.5 -f upload_release=true
```

The workflow overwrites only:

```text
VoiceStick-0.3.5.dmg
VoiceStick-0.3.5.dmg.sha256
```

## Windows Package

On the Windows signing machine:

```bat
scripts\build-exe-installer.bat
```

The output is:

```text
desktop\windows\build-installer-x64\VoiceStickSetup-<version>.exe
```

Upload the signed setup installer to the matching GitHub Release:

```sh
gh release upload v0.3.5 desktop/windows/build-installer-x64/VoiceStickSetup-0.3.5.exe --repo fwz233-RE/voicestick-mindex --clobber
```

## Website Deploy

The website can be redeployed manually after Release assets change:

```sh
gh workflow run deploy-website.yml --repo fwz233-RE/voicestick-mindex --ref main
```

## Verification

Stable endpoints:

```text
https://github.com/fwz233-RE/voicestick-mindex/releases/latest
https://xiaozhi-voice-assistant.oss-cn-shenzhen.aliyuncs.com/voicestick/firmwares/latest/manifest.json
```

For version `0.3.5`, verify these package URLs:

```text
https://github.com/fwz233-RE/voicestick-mindex/releases/download/v0.3.5/VoiceStick-0.3.5.dmg
https://github.com/fwz233-RE/voicestick-mindex/releases/download/v0.3.5/VoiceStick-0.3.5.dmg.sha256
https://github.com/fwz233-RE/voicestick-mindex/releases/download/v0.3.5/VoiceStickSetup-0.3.5.exe
https://xiaozhi-voice-assistant.oss-cn-shenzhen.aliyuncs.com/voicestick/firmwares/0.3.5/voicestick-firmware-sticks3-ota-0.3.5.bin
https://xiaozhi-voice-assistant.oss-cn-shenzhen.aliyuncs.com/voicestick/firmwares/0.3.5/voicestick-firmware-sticks3-merged-0.3.5.bin
```

The release is complete when:

- GitHub Release contains current DMG, DMG checksum, Windows installer, firmware images, firmware checksums, and manifest.
- No obsolete macOS ZIP update assets remain in the current Release.
- firmware `latest/manifest.json` reports the new version.
- the website points users to GitHub Release downloads.