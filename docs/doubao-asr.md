# VoiceInk 豆包语音识别

本 Fork 为 VoiceInk 添加豆包云端识别，不改变输入法，也不替换原有本地模型。

豆包只提供两种选择，均启用内置语义顺滑 `enable_ddc`，资源 ID 均为 `volc.seedasr.sauc.duration`：

- **一句话识别**：使用 `wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_nostream`，流式上传音频，在结束或服务端长句分段后返回完整结果，优先保证准确率。
- **实时语音识别**：使用 `wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async`，持续返回可修订的增量结果，优先低延迟。

开启对应豆包语音服务，在模型目录 → 云端 → Doubao 手动填写语音 API Key（不是 Ark 密钥）。密钥验证只建连，不录音。选择任一识别模式均可直接插入原有上屏流程；不需要额外润色时关闭 AI 增强。两种模式仍共用 16 kHz、16-bit、单声道 PCM 和约 200 ms 分包。

旧目录中的 1.0、Flash 和独立顺滑型号不再展示，已有配置映射至新选项。文件导入也走所选 WebSocket 服务，不自动切到 HTTP 极速版。

参考： https://www.volcengine.com/docs/DoubaoVoice/LargemodelstreamingautomaticspeechrecognitionAPI?lang=zh （2026-10-15 核对）。百炼与自定义决策配置见 [内置修正与自动润色说明](bailian-asr-and-polish.md)。

## 隐私与限制

- 选择豆包时，录音及热词会发送给火山引擎；不是离线识别。原有 Whisper 等本地识别仍可使用。
- 桌面应用的 API Key 不写入配置文件、环境文件或请求 JSON，不打印密钥或音频；DEBUG 构建经授权将识别原文写入本地开发 JSONL（见 `bailian-asr-and-polish.md`）。网络客户端不使用持久缓存，也不跟随重定向。可选的真实接口检查工具只读取用户明确授权的环境文件，不自动创建或迁移密钥。
- 当前模型的文件导入接受 VoiceInk 生成的 16 kHz 单声道 PCM WAV，同样限制 100 MB，并受设置中的转写超时约束。长录音仍需考虑服务限制与超时，本实现未添加长文件分段重连。
- 无权限、额度不足、协议错误或最终确认丢失时不把错误正文、未确认的中间文本当作最终结果上屏。文件识别遇到静音返回无语音错误；实时录音静音时可返回空文本。
- 旧版 App ID / Access Token 鉴权暂未接入。

## 构建与测试

完整应用沿用上游 Xcode 工程及 [BUILDING.md](../BUILDING.md)。上游 `make local` 会写入 `~/VoiceInk-Dependencies`、覆盖 `~/Downloads/VoiceInk.app`，并清除该应用的隔离标记；请先确认这些行为，不要盲目执行。

独立客户端测试不需要密钥、不访问云端，也不启动应用。WebSocket 端到端测试通过 `uv run` 启动仅使用标准库的本地模拟服务，需要已安装 `uv`：

```sh
swift test
```

测试输出默认放在系统临时目录的 `VoiceInkTests.noindex` 中；可通过 `VOICEINK_TEST_TMP_DIR` 指定本次任务的临时目录，不依赖开发者机器上的绝对路径。

测试包含请求构造、热词、音频限制、响应解析、模拟服务集成测试，以及真实 URLSession WebSocket 到本地服务器的握手、分包和最终确认端到端测试。它们不等于完整应用 UI 或真实云端验收。

真实服务检查工具只上传指定的合成 WAV，密钥不经命令行参数传递，也不输出录音或识别内容：

```sh
swiftc -parse-as-library \
  VoiceInk/Infrastructure/Providers/Transcription/Cloud/Doubao/*.swift \
  Tests/DoubaoLiveCheck/LiveCheck.swift -lz -o /path/to/task-tmp/doubao-live-check
/path/to/task-tmp/doubao-live-check /path/to/authorized/.env /path/to/synthetic.wav
```

环境文件变量名见仓库根目录 `.env.example`。不要把真实密钥提交到仓库。2026-10-15 使用用户另行提供的有效凭据完成真实云端验证：1.0、2.0 均通过握手，原生 Swift 客户端完成 2.0 内置顺滑模型的合成音频转写。修正了首包仅含 `result.additions`、没有 `text` 时被误判为无效数据包的问题；回归测试和本地 WebSocket 端到端测试采用该真实首包结构。

### 本次验证状态

- 当前 75 项独立客户端、策略及模式配置测试全部通过，包含两家本地真实 WebSocket 传输端到端测试、模式独立阈值及本地 HTTP 路由；废弃分类筛选和对应的两项测试已移除。
- 排除本地 MLX Refine 的临时云端测试工程完成完整 Xcode 编译及签名检查，不安装 Metal Toolchain、不下载模型权重；原始 Xcode 工程保持不变。
- 原生 Swift 客户端使用合成音频完成豆包、百炼真实云端转写及 decision 调用；未测试真实录音准确率、快捷键和原光标上屏。
- 测试版使用独立数据目录启动，不使用麦克风、不覆盖已安装的 VoiceInk；改动未提交、未推送。

### 手动端到端验收

在隔离的应用测试环境中，使用自己创建的语音服务密钥：

1. 打开模型管理，确认 Doubao、2.0 / 1.0 实时模型和可选 Flash 模型出现，只有实时模型标记支持实时识别。
2. 无效密钥不能保存为已连接；有效密钥验证后可选模型，重启后仍可使用。
3. 在 TextEdit、浏览器文本框及实际使用的编辑器里录一段中文夹英文，确认录音时出现部分结果，松开快捷键后等待最终确认并回到原光标上屏。
4. 添加热词后复测，开启/关闭 VoiceInk 增强流程分别验证。
5. 静音、断网、撤销服务权限时显示错误且不插入垃圾内容；切回本地识别模型仍能使用。
6. 导入一段 WAV，确认文件转写也走豆包后端。

## 来源

核对日期：2026-10-15。

- [火山引擎：录音文件极速版识别 HTTP](https://www.volcengine.com/docs/6561/1631584)
- [火山引擎：实时语音识别 WebSocket](https://www.volcengine.com/docs/DoubaoVoice/bidirectional-streaming-automatic-speech-recognition-websocket?lang=zh)
- [火山引擎：二进制流式协议](https://www.volcengine.com/docs/DoubaoVoice/LargemodelstreamingautomaticspeechrecognitionAPI?lang=zh)
- [火山引擎：标准版请求字段与热词格式](https://www.volcengine.com/docs/DoubaoVoice/LargemodelrecordingfilerecognitionstandardversionAPI?lang=zh)

保留上游许可证及第三方组件声明；本次不更改授权逻辑、品牌或自动更新策略。
