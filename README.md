# Voice Stick

Voice Stick 可以把 M5Stack StickS3 变成一个面向桌面端的蓝牙按住说话输入设备。

按住 StickS3 正面按钮开始录音。松开后，桌面菜单栏应用会把音频发送到 ASR，显示识别文本，并在短暂确认倒计时后把最终结果粘贴到当前聚焦的输入框。默认行为是粘贴文本并按下 Return；可以在设置里关闭 `auto_enter`。

## 项目结构

- `firmware/`：M5Stack StickS3 / ESP32-S3 的 ESP-IDF 固件。
- `desktop/macos/`：原生 macOS 菜单栏应用的 Swift Package。
- `desktop/windows/`：Windows 桌面应用工作区。
- `desktop/linux/`：Linux 桌面应用工作区。
- `docs/protocol.md`：StickS3 和桌面应用之间的 BLE 协议。
- `docs/volcengine-asr.md`：可选火山引擎 ASR 直连说明。
- `scripts/`：精灵图切片、调色和 LVGL ARGB 二进制转换辅助脚本。

## 当前功能

- StickS3 会以 `VS-XXXX` 名称广播，其中 `XXXX` 来自 eFuse MAC 的最后两个字节。
- 桌面应用只连接已配对的 `VS-XXXX` 设备，并且可以同时保持多个已配对设备在线。菜单栏会列出所有已配对设备，并显示每个设备是已连接还是仍在扫描。
- 正面按钮对应协议里的 `primary` 角色；当应用把设备置于 `ready` 后，按下开始录音，松开结束录音。
- 固件从 ES8311 麦克风读取 16 kHz 单声道 PCM，编码为 Opus，并通过 BLE notify 发送。
- 桌面应用把收到的 Opus 载荷封装为 Ogg Opus，并通过 WebSocket 转发给 ASR。
- ASR 提供方默认是阿里云 DashScope，也可以按配置切换为豆包、直连火山引擎或 VoiceStick Cloud relay。
- 识别过程中，桌面应用会显示浮动提示层和菜单栏状态。按钮松开后，固件屏幕会保持 thinking 状态，直到文本被粘贴或取消。
- 最终文本会进入 1.2 秒确认倒计时。
- 倒计时期间按正面按钮会暂停自动粘贴。再次按正面按钮确认粘贴；按侧键取消。
- 空闲时按侧键会恢复上一次可恢复的输入确认。
- 可选的调试音频缓存会把每个有效识别会话保存为 Ogg Opus；如果有来源设备 ID，会写入文件名。
- 固件更新会在应用启动、设备连接或重连、手动菜单刷新时检查基于哈希签名的清单。更新会按已连接设备分别提示。
- 固件屏幕会根据应用发送的 `ui_state` 显示配对、就绪、监听、思考、待确认、错误和电池状态。30 秒无操作后屏幕变暗。电池供电时 5 分钟后进入 deep sleep；充电或 USB 供电时停留在暗屏阶段。正面按钮可从 deep sleep 唤醒。

## 硬件目标

- 开发板：M5Stack StickS3 / ESP32-S3-PICO-1-N8R8
- 正面按钮：GPIO11，协议角色 `primary`，用于按住说话和 deep-sleep 唤醒
- 侧键：GPIO12，协议角色 `secondary`，用于取消或恢复上一次输入确认
- PMIC IRQ：GPIO13
- 音频 Codec：ES8311 over I2S，16 kHz / 16 bit / 单声道
- 屏幕：135 x 240 ST7789P3 竖屏
- LCD 背光：GPIO38 PWM

主要引脚定义位于 `firmware/components/stick_s3_board/include/stick_s3_board.h`。

## 交互模型

| 状态 | 正面按钮 | 侧键 |
| --- | --- | --- |
| 未配对 / 未连接 | 不录音；屏幕显示 `VS-XXXX` | 无有效动作 |
| 已连接空闲 | 按住录音 | 恢复上一次输入确认 |
| 录音中 | 松开结束录音 | 不取消当前录音 |
| 思考 / 收尾 | 忽略新的录音 | 取消进行中的识别 |
| 待确认倒计时 | 暂停自动粘贴并保持待确认 | 取消待确认文本 |
| 手动待确认 | 确认粘贴 | 取消待确认文本 |

固件只上报原始按钮事实，即 `button_down` / `button_up`，并携带 `primary` 或 `secondary`。桌面应用负责交互状态机，并把 `ui_state` 更新发送回固件用于屏幕显示。

默认粘贴流程会在粘贴后按下 Return。若要只粘贴不发送 Return，可以在设置里关闭 `Press Return after paste`，或在配置文件中设置 `auto_enter = false`。

## 音频路径

```text
StickS3 mic -> ES8311/I2S PCM -> Opus -> BLE -> 桌面端 -> Ogg Opus -> ASR -> paste
```

桌面应用不会为了 ASR 把 Opus 解码回 PCM，而是直接转发 Ogg Opus。

## BLE 协议摘要

GATT service：

```text
8f2f0b84-6e6f-4b23-88f7-3a3ceafc5100
```

Characteristics：

| 名称 | UUID | 方向 | 属性 |
| --- | --- | --- | --- |
| `audio_tx` | `8f2f0b84-6e6f-4b23-88f7-3a3ceafc5101` | StickS3 -> 桌面端 | notify |
| `state_tx` | `8f2f0b84-6e6f-4b23-88f7-3a3ceafc5102` | StickS3 -> 桌面端 | notify |
| `control_rx` | `8f2f0b84-6e6f-4b23-88f7-3a3ceafc5103` | 桌面端 -> StickS3 | write without response |

完整帧格式见 `docs/protocol.md`。

## 固件构建

先准备 ESP-IDF。下面命令假设 ESP-IDF 本地路径是 `~/esp/v5.5.1/esp-idf`；如果你的 ESP-IDF 在其他位置，请替换为实际路径。

```sh
cd firmware
. "$HOME/esp/v5.5.1/esp-idf/export.sh"
idf.py set-target esp32s3
idf.py build
```

如果 `export.sh` 提示 ESP-IDF Python 虚拟环境不存在，先运行一次对应安装器：

```sh
"$HOME/esp/v5.5.1/esp-idf/install.sh" esp32s3
```

烧录并查看串口日志：

```sh
idf.py -p /dev/cu.usbmodemXXXX flash monitor
```

固件使用 OTA 分区表，包含两个 3 MB app slot，以及一个预留 1984 KB 的 `storage` 分区。已经刷过旧单 app 分区表的设备，需要先通过 USB 烧录一次新分区表，之后才能使用 BLE OTA 更新：

```sh
idf.py -p /dev/cu.usbmodemXXXX erase-flash flash monitor
```

固件依赖通过 ESP-IDF component manager 声明：

- `espressif/button`
- `espressif/esp_codec_dev`
- `78/esp-opus`
- `lvgl/lvgl`

## macOS 桌面端构建

桌面应用是一个 Swift Package，目标系统为 macOS 12 或更新版本。

```sh
cd desktop/macos
swift build
```

运行应用：

```sh
swift run VoiceStickApp
```

应用是菜单栏辅助应用，会请求蓝牙权限。文本输入使用模拟 `Command-V` 加可选 Return。如果 macOS 阻止键盘事件，请在系统设置中给运行终端或应用授予辅助功能权限。

构建 macOS 分发版本：

```sh
scripts/build-macos.sh --release
scripts/make-dmg.sh
```

构建脚本会写出 `build/VoiceStick-<version>.app` 和 `build/VoiceStick-<version>.dmg`。应用更新只检测 GitHub 最新 Release；发现新版本后打开 Release 下载页，由用户手动下载安装 DMG。

构建 Windows 分发版本时，安装包在本地签名机上生成。Windows 签名证书预期放在本地签名机上，例如 USB 硬件密钥：

```bat
scripts\build-exe-installer.bat
```

脚本会在本地签名 `VoiceStick.exe` 和 `VoiceStickSetup-<version>.exe`。把生成的安装包上传到匹配的 GitHub Release。

推送 `v<version>` 标签后，GitHub Actions 可以自动完成 macOS 和固件发布路径。标签必须与 `VERSION` 匹配，例如 `VERSION=0.3.5` 对应 `v0.3.5`。release workflow 会把 macOS DMG、DMG 校验文件和固件资源发布到 GitHub Releases，然后部署网站到 GitHub Pages。Windows 安装包后续从本地签名机上传。完整发布流程见 `docs/release.md`。

同一个 release workflow 还会使用 ESP-IDF v5.5.1 构建 StickS3 固件，并把固件产物上传到阿里云 OSS：

| 文件 | 用途 |
| --- | --- |
| `voicestick-firmware-sticks3-ota-<version>.bin` | macOS 应用使用的 BLE OTA 镜像 |
| `voicestick-firmware-sticks3-merged-<version>.bin` | 浏览器 / USB 刷写镜像，写入 offset `0x0` |
| `manifest.json` | 应用和网站使用的最新固件元数据 |

产物会同时发布到版本目录和 `latest`：

```text
voicestick/firmwares/<version>/manifest.json
voicestick/firmwares/latest/manifest.json
```

macOS 应用会在启动、设备连接或重连时检查稳定的 latest manifest URL，并且运行期间最多每 24 小时自动检查一次。菜单里也提供 `Check for Firmware Updates` 用于手动刷新。如果已连接设备上报的 `firmware_version` 低于清单版本，它的设备子菜单会显示 `Update to <version>...`。应用会下载清单中的 `ota_url`，并校验 `ota_size` 和 `ota_sha256` 后再开始 BLE OTA。

运行 release workflow 前需要配置以下 GitHub secrets：

| 名称 | 说明 |
| --- | --- |
| `ALIYUN_OSS_ACCESS_KEY_ID` | OSS 上传 Access Key ID |
| `ALIYUN_OSS_ACCESS_KEY_SECRET` | OSS 上传 Access Key Secret |
| `ALIYUN_OSS_ENDPOINT` | OSS endpoint，例如 `https://oss-cn-hangzhou.aliyuncs.com` |
| `ALIYUN_OSS_BUCKET` | OSS bucket 名称 |

将仓库变量 `ALIYUN_OSS_PUBLIC_BASE_URL` 设置为公开 OSS 基础 URL，例如 `https://xiaozhi-voice-assistant.oss-cn-shenzhen.aliyuncs.com`。可选变量 `ALIYUN_OSS_PREFIX` 用于控制 OSS 对象前缀，默认是 `voicestick/firmwares`。

## 本地配置

配置路径：

```text
~/Library/Application Support/VoiceStick/config.toml
```

从示例创建配置：

```sh
mkdir -p "$HOME/Library/Application Support/VoiceStick"
cp desktop/macos/Config/config.example.toml "$HOME/Library/Application Support/VoiceStick/config.toml"
```

示例：

```toml
asr_provider = "aliyun"
voicestick_api_key = ""
voicestick_cloud_url = "wss://api.xiaozhi.me/voicestick/asr/"
volcengine_api_key = ""
aliyun_api_key = ""
aliyun_asr_url = "wss://dashscope.aliyuncs.com/api-ws/v1/inference/"
aliyun_asr_model = "fun-asr-realtime"
llm_base_url = "https://dashscope.aliyuncs.com/compatible-mode/v1"
llm_api_key = ""
llm_model = "qwen3.6-flash"
interaction_mode = "hold_to_talk"
resource_id = "volc.seedasr.sauc.duration"
asr_hotwords = "小智,VoiceStick"
paired_device_ids = ""
device_theme_colors = ""
device_overlay_positions = ""
auto_enter = true
debug_audio_cache = false
# debug_audio_dir = "~/Library/Application Support/VoiceStick/DebugAudio"

[output]
target = "focused_app"
transform = "original"
translation_target = "en"

# Optional per-device subtitle translation:
# [device.C3D8.output]
# transform = "translate"
# translation_target = "en"
```

字段说明：

| 字段 | 说明 |
| --- | --- |
| `asr_provider` | `aliyun`、`volcengine` 或 `voicestick_cloud`，默认主用 `aliyun` |
| `volcengine_api_key` | 可选火山引擎 API key，通过 `X-Api-Key` 发送 |
| `aliyun_api_key` | 可选阿里云 DashScope API key；留空时使用内置 Key |
| `aliyun_asr_url` | 阿里云实时语音识别 WebSocket URL |
| `aliyun_asr_model` | 阿里云实时语音识别模型名 |
| `voicestick_api_key` | VoiceStick Cloud relay API key，通过 `X-Api-Key` 发送 |
| `voicestick_cloud_url` | Cloud relay WebSocket URL |
| `llm_base_url` | OpenAI-compatible LLM API base URL |
| `llm_api_key` | LLM 提供方 API key |
| `llm_model` | LLM 模型名 |
| `interaction_mode` | 正面按钮交互方式：`hold_to_talk` 或 `click_to_talk` |
| `resource_id` | 火山引擎 resource ID |
| `asr_hotwords` | 逗号分隔的 ASR 热词；也会作为翻译术语提示传给 LLM |
| `paired_device_ids` | 逗号分隔的 4 位十六进制 ID，例如 `C3D8,09AF` |
| `device_theme_colors` | 可选的按设备覆盖层颜色，例如 `C3D8:pink,09AF:green` |
| `device_overlay_positions` | 可选的按设备覆盖层位置，例如 `C3D8:top_left,09AF:bottom_right` |
| `auto_enter` | 粘贴后是否按 Return |
| `debug_audio_cache` | 是否保存调试 Ogg Opus 文件 |
| `debug_audio_dir` | 调试音频输出目录 |
| `[output].target` | `focused_app` 或 `subtitle` |
| `[output].transform` | `original` 或 `translate` |
| `[output].translation_target` | LLM 翻译目标语言代码，例如 `en` 或 `zh-Hans` |
| `[device.<id>.output]` | 可选的按设备覆盖文本转换和翻译目标 |

支持的火山引擎 `resource_id`：

- `volc.seedasr.sauc.duration`
- `volc.seedasr.sauc.concurrent`
- `volc.bigasr.sauc.duration`
- `volc.bigasr.sauc.concurrent`

不要提交 API keys。

## 配对流程

1. 烧录并启动 StickS3。屏幕会显示 `VS-XXXX`。
2. 启动桌面应用。
3. 从菜单栏应用打开 `Pair Device...`。
4. 在扫描列表中选择匹配的 `VS-XXXX`，然后点击 `Pair`。
5. 保存后，桌面应用会扫描并连接该设备。可以重复此流程配对更多设备。

也可以手动编辑 `paired_device_ids`。保存多个 ID 后，桌面应用会忽略附近未配对的 VoiceStick 设备。

## 调试音频

启用方式：

```toml
debug_audio_cache = true
```

默认输出目录：

```text
~/Library/Application Support/VoiceStick/DebugAudio
```

每个有效识别会话都会保存为可播放的 Ogg Opus 文件。短于 0.5 秒的录音会被桌面应用丢弃，并且不会发送给 ASR。