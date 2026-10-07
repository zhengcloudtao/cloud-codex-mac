# CloudCodex 远程控制 API 文档

版本：1.1。本文与 [`remote-control-openapi.yaml`](remote-control-openapi.yaml) 描述 Mac Agent 的固定协议，并给出小程序用户侧 API 的参考契约。应用内「查看 API 文档」包含相同边界，以及更完整的状态机、数据库结构、服务号通知和验收要求。

## 协议边界

Agent API 由 CloudCodex Mac 直接调用，路径和字段是固定契约：

| 方法 | 路径 | 说明 |
|---|---|---|
| POST | `/api/cloud-codex/agent/register` | 注册设备/刷新未配对设备的配对码 |
| POST | `/api/cloud-codex/agent/heartbeat` | 同步能力、快照与在线状态 |
| GET | `/api/cloud-codex/agent/tasks/next` | 原子领取下一任务 |
| POST | `/api/cloud-codex/agent/tasks/{taskId}/status` | 幂等回传进度和状态 |
| POST | `/api/cloud-codex/agent/unpair` | 无未结束任务时解绑 |
| POST | `/api/cloud-codex/agent/events` | 上报通知事件 |
| GET | `/api/cloud-codex/agent/history/next` | 领取只读历史请求 |
| POST | `/api/cloud-codex/agent/history/{id}` | 回传只读历史 |
| GET | `/api/cloud-codex/agent/resets/next` | 领取额度重置请求 |
| POST | `/api/cloud-codex/agent/resets/{id}` | 回传额度重置结果 |

Mini API 可按后端技术栈改名，但必须保留登录态、用户归属、状态和权限边界。推荐提供登录、配对、设备列表/编辑/解绑、任务创建/列表/详情/取消/重试、历史读取和额度重置确认接口。

## 鉴权与响应

Agent 请求携带：

```http
Content-Type: application/json
X-CloudCodex-Device: <stable-device-id>
X-CloudCodex-Token: <keychain-secret>
```

设备密钥只应在 Mac 钥匙串中保留原文；服务端保存带盐安全摘要并从日志移除该请求头。Mini API 使用独立业务登录态，绝不向小程序下发设备密钥。

成功外壳：

```json
{"status":0,"msg":"ok","data":{}}
```

空队列必须使用 `data:null`。鉴权失败使用 HTTP 401/403；设备端点不能用 30x 跳转。可恢复业务错误应提供稳定错误标识和可读信息。

## 关键请求示例

注册：

```json
{"name":"My Mac","resetPairing":false}
```

注册响应 `data`：

```json
{"deviceId":"device-uuid","name":"My Mac","paired":false,"pairingCode":"01234567","pairingExpiresAt":"2030-01-01T10:05:00Z","pollIntervalSeconds":3}
```

心跳：

```json
{
  "name":"My Mac",
  "permissionLabel":"按需确认",
  "remoteControlReady":true,
  "workspaces":[{"path":"/absolute/project","name":"project"}],
  "threads":[{"id":"thread-1","title":"修复登录","workspace":"/absolute/project","model":"gpt-x","status":"idle","updatedAt":1893456000}],
  "models":[{"id":"model-option","model":"gpt-x","name":"GPT X","description":"","supportedEfforts":["medium","high"],"defaultEffort":"medium","supportsFast":true}],
  "defaultModel":"model-option",
  "defaultEffort":"medium",
  "usage":null,
  "systemMetrics":null,
  "connectionHealth":null
}
```

任务领取响应 `data`：

```json
{"taskId":"task-uuid","deviceId":"device-uuid","threadId":"","workspace":"/absolute/project","prompt":"运行测试并报告结果","model":"","effort":"","status":"running","speed":"standard","permissionMode":"ask","imageUrls":[]}
```

状态回传：

```json
{
  "status":"completed",
  "threadId":"thread-uuid",
  "turnId":"turn-uuid",
  "result":"任务结果",
  "error":"",
  "progress":{"steps":[{"id":"step-1","kind":"command","title":"运行测试","status":"completed","text":"通过"}],"truncated":false,"revision":3},
  "actualModel":"gpt-x",
  "actualEffort":"high"
}
```

通知事件：

```json
{"type":"conversation_completed","eventId":"conversation:thread-uuid:turn-uuid","threadId":"thread-uuid","turnId":"turn-uuid","threadTitle":"修复会话通知"}
```

```json
{"type":"quota_restored","eventId":"quota:1893456000"}
```

五小时和周额度分别检测；只有周额度的套餐直接检测周额度。额度读取缺失时保留最近一次有效基准；恢复后通知一次，连续 100% 不重复通知，启动首次读到 100% 不补发。

## 状态和持久化规则

```text
scheduled -> queued -> running -> completed
                           \----> failed
queued -------------------------> canceled
running -- writer_busy/thread_busy --> queued + retryAfter
failed -- 用户重试 --> 新 taskId 的 queued 记录
```

- 领取使用事务条件更新/行锁，确保任务只被领取一次。
- 同一持久会话最多一个 writer，不同会话可以并行。
- completed、failed、canceled 是不可逆终态；重复终态返回成功，迟到的中间状态不能覆盖终态。
- `progress.revision` 只接受递增版本。
- 网络超时表示结果未知，所有写接口必须可安全重试。
- 工作区、会话、模型、强度、速度和权限只能来自该设备最近一次心跳快照。
- `permissionMode=full` 必须由小程序清楚警示并由用户明确选择。

最小数据表为 users、devices、tasks、history_requests、reset_attempts、notification_events 和 pairing_attempts。对 owner+device、device+status+schedule、device+thread+status、通知去重键建立约束/索引。提示词、结果、工作区和图片是用户内容，必须设置访问控制和保留策略。

## 小程序最低页面

1. 登录和登录态刷新。
2. 设备列表、在线状态、编辑、解绑。
3. `cloudcodex://pair?v=1&code=八位数字` 严格扫码/手输配对。
4. 从心跳快照选择工作区、会话、模型、强度、速度和权限，创建立即/定时任务。
5. 任务列表/详情展示 queued、running、等待同会话、completed、failed、canceled，以及进度、真实模型、结果和文件差异。
6. 失败任务重试、queued 任务取消、只读历史分页和额度未知态。
7. 服务号关注/绑定状态与不可投递原因。扫码配对成功不等于已经关注服务号。

## 通知要求

会话完成事件可携带 `threadTitle`，对应会话列表显示标题。服务号预约类型填“会话完成”，预约项目填该标题；省略或空白标题时填“未命名会话”。项目沿用模板的长度截断规则。

后端按 `hash(deviceId + eventId)` 去重，并只能从已配对设备 owner 解析接收者。建议先落持久站内通知，再发送服务号模板消息。只有外部发送成功才向 Mac 确认成功；临时失败必须允许 Mac 重试。用户未关注或未绑定时记录明确的不可投递状态，不能伪装为已发送。

会话完成只对新的 threadId+turnId 发送一次。额度恢复只对五小时或周额度“已知非 100% → 已知 100%”的边沿发送，不能在启动时看到一条 100% 快照就补发。

## 验收

至少验证错误密钥、跨用户访问、配对码过期/重复/冻结、并发领取、同会话互斥、乱序状态、空队列 null、断网补传、通知去重与失败重试、解绑拦截。最终用隔离测试账号完成 Mac 注册、真机扫码、任务领取与回传、会话完成通知、额度恢复通知和解绑；HTTP 200、构建成功或部署成功都不能单独代表整条链路通过。
