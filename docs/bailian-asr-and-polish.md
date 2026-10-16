# 百炼 Qwen ASR、内置修正与自动润色

核对日期：2026-10-15。以下能力依据当日官方文档；原生 Swift 客户端已用合成音频完成真实云端转写及 decision 调用，尚未验证真实录音效果和原光标上屏。

## 结论与选择

| 供应商 / 模型 | 内置能力 | 本 Fork 的选项 |
| --- | --- | --- |
| 豆包实时识别 2.0 | `enable_itn` 数字等规范化、`enable_punc` 标点、`enable_nonstream` 二遍重识别；额外的 `enable_ddc` 语义顺滑可删除或修改语气词、重复等不流畅部分 | 一句话识别、实时语音识别均开启顺滑 |
| 百炼 `qwen-audio-3.1-asr-flash-message` | `disfluency_removal_enabled` 去语气词、重复、自我纠正并整理表达；`intermediate_result_enabled` 单独控制中间结果 | `Qwen Audio 3.1 ASR` 开启内置润色 |
| 百炼 `qwen3-asr-flash-realtime` | 是另一套实时协议，不能直接套用上述内置润色参数 | 本次没有接入该旧型号，优先接入明确支持内置润色的 3.1 Message 型号 |

这些能力不能视为任意翻译、摘要、风格改写或严格格式输出的替代品，也不能保证消除所有识别错误。豆包的二遍识别是重新识别音频，不等于单独调用聊天模型润色。

**推荐先试：内置修正模型 + 关闭 AI Enhancement。** 此时服务端完成修正后直接走 VoiceInk 原有上屏流程，不调用 decision，也不调用额外的润色模型。内置修正在供应商端完成，仍是云端处理，不是本地离线。

不自动关闭用户已经启用的增强配置，避免破坏原来的翻译、摘要等模式。需要这些额外要求时可保留增强。

## 模型目录与决策接口

保留本地 / 云端 / 自定义目录，不增加用途筛选。供应商行显示各类模型数量，详情按转写、润色、决策列出简洁列表。

沿用上游“已连接 / 未连接”和“密钥已验证”的状态文案，不对 Qwen 做特殊文案处理；它们仍表示原有密钥配置状态，不额外承诺所有模型都已验证。模式表单保留原有“AI Model”字段名称，自动策略及阈值只在模式编辑里配置，不在录音提示词浮窗增加重复入口。

- 豆包只列出一句话识别和实时语音识别，共用 `volc.seedasr.sauc.duration`。前者使用 `bigmodel_nostream`，后者使用 `bigmodel_async`，均启用内置顺滑。
- `Qwen(cn)` 保留一个 **Qwen Audio 3.1 ASR**（开启内置修正），增加润色模型 `qwen3.8-flash`，保留决策模型 `decision-model-preview`。
- 渠道名称仅调整显示，已有 `Bailian` 密钥、业务空间和配置标识不变。旧转写型号选择映射至新目录，不丢失模式配置。
- 自定义目录支持添加、编辑、删除和测试决策模型。每个自动润色模式可独立选择内置或自定义决策模型。删除后仍引用该模型的模式不会静默换用其他供应商，而是回退至该模式配置的润色模型。

两种决策协议不是只改 URL 即可互换，也不是所有供应商都支持的统一标准：

| 协议 | 请求 | 响应 |
| --- | --- | --- |
| System One `/v1/systemone` | `state` + 命名 `questions` 对象，是否题使用 `noul` | `answers.needs_polish.noul` 概率 |
| Decisions `/v1/decisions` | `input` + `questions` 数组，是否题使用 `predicate` | `answers[]` 中对应命名问题的 `probability` |

百炼官方采用 TypeSafe System One，完整路径为 `/compatible-mode/v1/systemone`。自定义配置填写完整 HTTPS 接口地址并显式选择协议，不自动探测或替换路径。Decision 先返回时，判断概率达到阈值则等待润色，低于阈值则直接使用原文，默认阈值 0.70；润色先成功时直接采用润色，不等待 Decision。决策出错、超时、配置缺失则采用并行启动的润色结果。密钥沿用系统钥匙串，不写入 UserDefaults。测试仅发送固定示例文本。

Qwen 润色调用同业务空间的 `/compatible-mode/v1/chat/completions`，模型 ID `qwen3.8-flash`，关闭思考以减少延迟；ASR 和决策权限不代表该模型也已开通。此次未使用用户密钥进行新一轮云端调用。

参考（2026-10-15 核对）：
- https://help.aliyun.com/zh/model-studio/decision-model-api
- https://developers.openai.com/api/docs/guides/decisions
- https://docs.litellm.ai/docs/decisions
- https://help.aliyun.com/en/model-studio/qwen3-8-flash
- https://www.volcengine.com/docs/DoubaoVoice/LargemodelstreamingautomaticspeechrecognitionAPI?lang=zh

## 百炼配置

1. 在百炼获取对应业务空间及地域的 API Key，并确认模型访问权限。
2. 首次引导选择云端 → Qwen(cn)，或模型管理 → Cloud Providers → Qwen(cn)，填写 Workspace ID、地域（北京或新加坡）和 API Key。Workspace ID 是专属域名的第一个部分，不包含地域或 `.maas.aliyuncs.com`。
3. 密钥验证只启动实时识别任务，不录音、不上传音频；它验证的是 ASR 访问，不代表决策或润色权限已经验证。
4. 选择 Qwen Audio 3.1 ASR，实际请求的云端模型为 `qwen-audio-3.1-asr-flash-message`。

使用业务空间专属域名：

```text
wss://{WorkspaceId}.{Region}.maas.aliyuncs.com/api-ws/v1/inference
```

等待 `task-started` 后发送 16 kHz、16-bit、单声道二进制 PCM；按句子 ID 替换中间结果，不能拼接每个中间包。停止时发送 `finish-task`，等待句子最终结果及 `task-finished` 后才确认完整文本。热词沿用 VoiceInk 词典，即时词表最多 2000 个、权重 3，不额外上传历史对话、剪贴板或屏幕上下文。

文件导入和关闭实时模式时仍使用同一个 WebSocket 服务，以约 200 ms 分包发送 WAV 中的 PCM，不依赖另一种文件转写权限。这里复用现有的 WAV 验证器，只接受 16 kHz 单声道 16-bit PCM WAV，最多 100 MB；长音频仍受转写超时限制，未实现分段重连。

API Key 保存在系统钥匙串；Workspace ID 和地域保存在应用偏好设置。不会从其他项目自动迁移凭据，不记录录音、密钥或服务端错误正文。经用户授权，DEBUG 开发构建会将识别原文及决策输入、问题提示词、概率、阈值、耗时和路由结果写入本地 JSONL；Release 不写这些开发日志。更换空间或地域需移除后重新验证连接。

## 额外润色：始终 / 自动

原有 AI Enhancement 总开关保留，每个模式独立保存策略。旧配置缺少新字段时默认为“始终”，不会悄悄改变旧行为。

- **关闭**：不调用 decision、不调用额外润色，ASR 内置修正不受这个开关影响。
- **始终**：按原来配置的润色模型和提示词处理，不调用 decision。
- **自动**：对最终识别文本同时启动所选决策模型（默认 `decision-model-preview`）和原来的润色模型。润色先成功就立即采用结果，取消或忽略尚未完成的决策；决策先明确判断不需要则立即原文上屏，取消或丢弃润色，不等待取消完成。决策先判断需要或不可用时继续等待同一个润色请求，不重新发送。润色先失败不会抢先输出错误，决策随后判断不需要时仍输出原文，否则报告润色失败。最终只交付一次，迟到的结果不会覆盖已经选定的文本。

模式 → AI 增强 → 自动 → 润色触发阈值：位于决策模型下方，显示 0%–100%，步长 5%，可恢复默认 70%。每个模式独立保存，修改或恢复默认只改变编辑草稿，保存模式后对后续请求生效；取消不影响已保存配置。切换为“始终”或关闭润色时隐藏控件，但保留配置。新模式默认 0.70，旧模式首次加载时继承原有全局阈值并写入各自配置；全局设置中的阈值入口已移除，旧偏好只用于迁移，不再参与运行时判断。

Decision 先完成时，阈值越高越倾向保留原文，概率等于阈值时等待润色；阈值不是所有请求的硬门槛，润色先成功时直接采用。单次请求使用所属模式的阈值快照；无效值回退默认值。0.70 是偏向少改动的初始选择，不代表已由大样本校准，也不是语音识别准确率或润色质量保证。

并行模式优化的是等待时间，不是请求量或费用：每次有效的自动处理都会启动润色，即使最终未采用，服务端仍可能已经处理、计费，取消并不保证撤回请求。不会把未采用的润色写入历史或再次上屏。用户取消时同时取消两条任务；“始终”、手动重新润色及 Respond 输出不受 Decision 阈值影响。

自动策略不局限于 Qwen ASR；豆包和本地模型也能使用，但仍需配置百炼或自定义决策服务。即便使用本地 ASR，自动策略也会将最终文本和所选润色提示词发送给所选决策服务，请注意隐私边界。

decision 请求是独立的结构化决策协议，不是 `/chat/completions`：

```text
POST https://{WorkspaceId}.{Region}.maas.aliyuncs.com/compatible-mode/v1/systemone
model: decision-model-preview
questions.needs_polish.type: noul
```

读取 `answers.needs_polish.noul` 的 P(yes)，大于等于当前阈值（默认 0.70）时采用润色。提示词要求保留名称、数字、事实和有意保留的方言，同时把明确的翻译、摘要、回答或风格转换视为需要处理。该判断依然可能误判；要求必须严格执行时应选“始终”。

判断最多等待约 2 秒，不重试；这段时间与润色重叠，而非串行叠加。配置缺失、鉴权错误、超时或非法响应时采用已经启动的润色，不弹出额外警告；用户取消仍中止，不触发回退。录音处理界面沿用上游“润色中”状态，不新增判断、跳过状态或全局 UI 状态对象。未润色时不将历史记录标记为已使用润色模型。手动重新润色及 Respond 输出仍直接执行用户明确要求的处理，不用自动判断跳过。

## 验证范围

- 2026-10-16 最小差异复核：恢复上游连接状态、原有 AI Model 字段名、录音处理状态和提示词浮窗；移除本地模型布局的无效 Group 包装、未调用的内置决策测试代码、废弃分类筛选及对应测试依赖，并清理 24 条没有生产引用的新增翻译。上游已有的 1301 条翻译全部保持原样。保留功能的 75 项 Swift 测试通过，包含模式阈值 14 项无 GUI 检查及本地 HTTP/WebSocket 流程；比前版少的两项仅测试已废弃的分类筛选。
- 2026-10-16 模式级阈值版：77 项 Swift 测试通过，其中一项集成测试编译实际 ModeConfig 数据模型、ModeConfigDraft 和 ModeRuntimeResolver，并在无 GUI 的隔离环境完成 14 项检查。覆盖旧值迁移及序列化固定、新模式默认值、模式独立保存、草稿取消、重置、隐藏保留和非法值；4 项本地 HTTP 流程验证保存后的两个模式在两种协议下按各自阈值实际路由。测试替代了无关的应用服务，不验证 GUI 或真实钥匙串、云端调用。
- 2026-10-15 Decision 并行版：独立 Swift 测试更新为 73 项全部通过，新增阈值配置、并行生命周期和 3 项本地 HTTP 端到端用例；现有云端测试工程 Debug 编译成功。按用户要求不做 GUI 或真实云端调用，交互及上屏体验留待手动验收。测试日志保存在本地开发任务目录，不随源码提交。
- 2026-10-16 响应优先版：76 项独立 Swift 测试全部通过，覆盖润色抢先返回、迟到的正负决策不覆盖结果、正向决策等待润色、双请求不配合取消，以及本地 HTTP 服务阻塞 Decision 时仍立即返回润色。云端测试工程 Debug 编译及安装后签名校验通过，未做 GUI 或真实云端调用。已替换 `/Applications/VoiceInk Dev.app`，按用户要求删除旧包及重复构建包，不保留回滚副本；日志与中间产物集中于本地 `.noindex` 开发任务目录，不随源码提交。
- 本次独立测试共 60 项，全部通过，包含两种决策协议与豆包两种识别模式；临时云端测试工程完成完整 Xcode 编译及签名检查，原始 Xcode 工程保持不变。
- 独立 Swift 测试覆盖两家请求参数、内置修正开关、句子替换/重复/最终确认、decision 请求/概率/错误及策略路由。
- Qwen 和豆包各有真实 URLSession WebSocket 到本地模拟服务器的端到端测试；decision 有 URLProtocol HTTP 集成测试。这些不是云端 ASR 准确率测试。
- 参考项目中未找到 `DASHSCOPE_API_KEY` 或 `BAILIAN_WORKSPACE_ID`，没有尝试将 Ark / TTS Key 当作百炼凭据。
- 用户另行提供凭据后，原生 Swift 客户端通过 Qwen 实时任务验证、内置润色模型合成音频转写和 decision 云端判定。首次引导已补上原先遗漏的 Workspace ID 和地域字段；不从密钥推断或硬编码用户的业务空间。
- 独立数据目录下的测试版已启动，不覆盖现有安装、不使用麦克风、不自动提交或推送。真实录音、快捷键和原光标上屏仍需手动验收。
- 已在原生界面检查没有新增用途筛选，Qwen(cn) 显示 1 个转写、1 个润色、1 个决策模型，豆包显示 2 个转写模型；详情按三种用途简洁列出，自定义目录包含决策模型编辑器。本次界面检查未触发云端测试调用。

运行独立测试：

```sh
swift test
```

手动验收时应分别检查：两种内置修正模型的最终效果、关闭增强时零 decision 请求、始终模式零 decision 请求、自动模式的正负判定和超时、导入 WAV、原光标上屏、快捷键、切回本地模型，以及旧模式配置的保存和重新加载。

## 官方来源

- [豆包实时语音识别协议与参数](https://www.volcengine.com/docs/DoubaoVoice/LargemodelstreamingautomaticspeechrecognitionAPI?lang=zh)
- [百炼实时语音识别用户指南](https://help.aliyun.com/zh/model-studio/real-time-speech-recognition-user-guide)
- [Qwen ASR Message WebSocket 接入](https://help.aliyun.com/zh/model-studio/qwen-asr-message-websocket-api)
- [Qwen ASR Message 客户端事件](https://help.aliyun.com/zh/model-studio/qwen-asr-message-client-events)
- [Qwen ASR Message 服务端事件](https://help.aliyun.com/zh/model-studio/qwen-asr-message-server-events)
- [decision-model-preview 模型信息](https://help.aliyun.com/zh/model-studio/decision-model-preview/)
- [决策模型 System One API](https://help.aliyun.com/zh/model-studio/decision-model-api)

## 开发数据日志

仅 DEBUG 构建启用，保存于当前应用 home 的 `Library/Application Support/VoiceInk/DevelopmentLogs/decisions-YYYY-MM-DD.jsonl`（UTC 日期分文件）。目录权限 0700，文件权限 0600。不自动上传或删除数据。

- `asr_result`：录音、导入和重新转写的供应商原始输出，在本地过滤、替换及额外润色之前记录；不等于供应商内置顺滑之前的原文。
- `decision_result`：决策输入、模型、协议、问题提示词、所需转换、概率、阈值、是否润色、耗时；失败记录固定错误类型，不记录密钥、请求头、完整端点或服务端错误正文。
- `enhancement_route`：实际路由，包括 `fallback_to_polish` 和 `polish_first`（润色成功时决策尚未返回）；`execution` 为 `parallel`（自动）或 `direct`（始终/强制处理）。缺失决策密钥或配置而未发决策请求时也记录路由。

日志包含明文转写与提示词，可能涉及隐私；仅用于开发调参，请勿直接公开。
