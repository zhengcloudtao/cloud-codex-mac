# CloudCodex 模型服务商

设置入口分别保存 OpenAI、DeepSeek、阿里云百炼和火山引擎方舟。OpenAI 使用现有本机 Codex 登录与配置；以下第三方公共地址来源如下，用户的 API Key、Workspace ID 和接入点 ID 必须由用户自己填写。

| 服务商 | 接入方式 | Base URL | 默认模型 |
| --- | --- | --- | --- |
| DeepSeek | 官方 API | `https://api.deepseek.com` | `deepseek-flash` |
| 阿里云百炼 | Token Plan（北京） | `https://token-plan.cn-beijing.maas.aliyuncs.com/compatible-mode/v1` | `auto` |
| 阿里云百炼 | 按量计费（北京） | `https://{WorkspaceId}.cn-beijing.maas.aliyuncs.com/compatible-mode/v1` | `qwen3.7-max` |
| 火山引擎方舟 | Coding Plan | `https://ark.cn-beijing.volces.com/api/coding/v3` | `ark-code-latest` |
| 火山引擎方舟 | 按量计费 | `https://ark.cn-beijing.volces.com/api/v3` | 用户开通的模型或接入点 ID |

- [DeepSeek 官方 Codex 接入说明](https://api-docs.deepseek.com/quick_start/agent_integrations/codex/)：支持 Responses；推理强度为 low/high/max。默认使用 high，并为模型提供本机独立目录与工具元数据。
- [阿里云官方 Codex 接入说明](https://help.aliyun.com/zh/model-studio/codex)：Token Plan 和支持 Responses 的按量模型可接新版 Codex。仅支持 Chat Completions 的 Coding Plan 不在本入口支持范围内。不同套餐、地域的 API Key 不通用；按量地址中的 Workspace ID 不能使用占位值。
- [火山引擎官方 Coding Plan Codex 接入说明](https://docs.volcengine.com/docs/ark/coding-plan-personal-ai-codex?lang=zh)：Coding Plan 使用 `/api/coding/v3`，`/api/v3` 是按量接口，不会消耗 Coding Plan 套餐额度。
- [火山引擎官方 apply_patch 接入说明](https://docs.volcengine.com/docs/ark/apply-patch?lang=zh)：模型目录须声明 freeform apply_patch。文档中的 staging 示例地址不用于 CloudCodex。

配置只作用于 CloudCodex 子进程，不修改 `~/.codex/config.toml`。密钥按服务商、计费方式和地址分别保存在钥匙串，切换后不能复用其他服务商的密钥。旧单厂商配置及通用配置迁移到相同厂商或旧配置卡片，保留原始地址、模型、推理强度和钥匙串账户，不迁移到另一家。

## 多厂商配置与会话切换

非敏感配置使用 `cloudcodex.modelProviders.v2`，每家维护独立模型列表、默认模型；每个模型可填写显示名称、支持的推理档位和默认档位。「在对话模型菜单中启用」决定是否显示在对话厂商菜单，「启动默认服务商」通过单选菜单设置。启动默认仅在下次启动时选用；保存保留当前厂商和仍有效的模型选择，停用当前厂商时才切换到默认厂商。原 `cloudcodex.modelProvider.v1` 保留兼容视图，统计存储键不变；密钥账户不变，不需重新填写原服务商密钥。

OpenAI 自动读取当前 Codex 模型目录，可补充目录外模型并填写支持档位。对话中先选厂商，再选其模型及推理强度。第三方模型的界面 ID 为 `provider:<厂商>:<模型 ID>`，避免同名模型冲突；向模型接口发送的仍是原模型 ID。远程端只公布当前厂商模型，旧的原始模型 ID 在当前厂商内仍可识别。

同厂商模型和推理强度会实际传入下一轮请求，模型目录包含该厂商全部已配置模型。跨厂商切换需等待本机任务、远程任务和队列空闲，然后自动重连子进程；新密钥读取成功后才停止旧服务，不复用旧密钥。初始化失败时尝试恢复原服务。继续历史会话会恢复原上下文并使用当前选中的厂商。当前厂商的配置修改会立即应用，不需要退出应用。对话模型菜单明确标记为全局设置，影响所有对话的后续请求；目前不提供每个对话独立的厂商连接。

用量归属在每轮提交时固定；运行中为下一轮切换同厂商模型，不改变正在执行任务的统计归属。

工具配置遵循各服务商示例：DeepSeek 和火山声明 freeform 补丁工具；阿里云不声明补丁工具，通过标准命令工具编辑文件。当前 Codex 不接受旧式 `function` 补丁目录值。第三方模式关闭 OpenAI 内置联网搜索、代理命名空间和目标工具，避免把不兼容的工具类型传给服务商。

连接测试只请求 `/models`，不发起模型生成请求。服务商未提供模型列表时，会提示无法通过该方式验证；这不代表 `/responses` 不可用。本机模拟验证不等同于真实账号或真实服务的验收。

## 用量与调用次数

「使用统计 → 第三方 API」显示本机自启用统计后观察到的各服务商、接入方式、模型用量。可按今天、近 7 天、近 30 天和全部查看：已记录响应次数、任务轮次、完成/失败/中断轮次，以及总量、输入、输出、缓存命中、推理 Token。

数据来自 `thread/tokenUsage/updated`，每个任务首次回报只计 `last`，避免导入会话之前使用其他服务商的历史累计量；后续取 `total` 增量。重复和滞后的累计事件不重复计入，记录保存在本机偏好中并跨重启保留，不保留提示词、模型回复或 API Key。没有用量回报的任务明确标记，不能把未提供的数据当成零。

已记录响应次数按不同的有效累计用量更新计数，表示有用量回报的模型响应次数。合并回报可能低估次数；失败重试、未回报用量的请求、功能加入前及其他客户端的请求不在完整统计范围内。任务按首次观察日期归入时间范围。缓存命中是输入的子集，推理是输出的子集；收费、余额、套餐消耗及准确 HTTP 请求数以服务商控制台为准，CloudCodex 不推算费用。
