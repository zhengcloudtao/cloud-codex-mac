import Foundation

enum RemoteAPIDocumentation {
    static func document(configuration: RemoteServerConfiguration) throws -> String {
        var address = "<填写你自己的 HTTPS 后端根地址>"
        if configuration.mode == .custom {
            let url = try configuration.validatedURL()
            if !RemoteServerConfiguration.scope(for: url).isEmpty { address = url.absoluteString }
        }
        return "# CloudCodex 远程控制 API 文档\n\n服务根地址：\(address)\n\n" + specification
    }

    static let specification = #"""
    文档版本：1.1。字段名使用 camelCase；时间若无特别说明均为 Unix 秒；所有文本按 UTF-8 处理。
    `docs/remote-control-openapi.yaml` 是机器可读契约，本文补充状态机、持久化和小程序行为。

    ## 1. 两类 API 的边界

    **Agent API 是固定协议**：Mac 客户端直接调用，路径、请求字段和响应外壳不能随意更名。

    | 方法 | 路径 | 用途 |
    |---|---|---|
    | POST | `/api/cloud-codex/agent/register` | 注册设备或刷新未配对设备的配对码 |
    | POST | `/api/cloud-codex/agent/heartbeat` | 同步在线状态、工作区、会话、模型、额度和系统状态 |
    | GET | `/api/cloud-codex/agent/tasks/next` | 原子领取下一条任务；空队列返回 `data:null` |
    | POST | `/api/cloud-codex/agent/tasks/{taskId}/status` | 幂等回传运行、重排、进度和终态 |
    | POST | `/api/cloud-codex/agent/unpair` | 在没有未结束任务时解除配对 |
    | POST | `/api/cloud-codex/agent/events` | 幂等上报会话完成或额度恢复通知事件 |
    | GET | `/api/cloud-codex/agent/history/next` | 领取只读历史请求；可先返回 `data:null` |
    | POST | `/api/cloud-codex/agent/history/{id}` | 回传一页只读历史 |
    | GET | `/api/cloud-codex/agent/resets/next` | 领取用户明确确认的额度重置请求；可先返回 `data:null` |
    | POST | `/api/cloud-codex/agent/resets/{id}` | 回传额度重置结果 |

    **Mini API 是参考契约**：路径可以按技术栈调整，但登录态、归属校验、状态语义和返回数据必须等价。推荐实现：

    | 方法 | 参考路径 | 用途 |
    |---|---|---|
    | POST | `/api/cloud-codex/mini/login` | 用 `wx.login` 的一次性 code 换业务登录态 |
    | POST | `/api/cloud-codex/mini/pair` | 当前登录用户消费 8 位配对码 |
    | GET | `/api/cloud-codex/mini/devices` | 返回当前用户设备与最新快照 |
    | PATCH | `/api/cloud-codex/mini/devices/{deviceId}` | 修改别名/备注，不改变所有者 |
    | DELETE | `/api/cloud-codex/mini/devices/{deviceId}` | 用户侧解除绑定，规则与 Agent unpair 相同 |
    | POST | `/api/cloud-codex/mini/tasks` | 基于设备快照创建立即或定时任务 |
    | GET | `/api/cloud-codex/mini/tasks` | 分页查询当前用户任务 |
    | GET | `/api/cloud-codex/mini/tasks/{taskId}` | 查询结果、进度、文件差异和真实模型设置 |
    | POST | `/api/cloud-codex/mini/tasks/{taskId}/cancel` | 取消尚未领取的任务 |
    | POST | `/api/cloud-codex/mini/tasks/{taskId}/retry` | 从失败任务复制一条新的 queued 任务 |
    | POST | `/api/cloud-codex/mini/history` | 创建只读历史请求 |
    | GET | `/api/cloud-codex/mini/history/{id}` | 读取分页历史结果 |
    | POST | `/api/cloud-codex/mini/resets` | 用户二次确认后创建一次性额度重置请求 |

    ## 2. 鉴权、响应和错误

    Agent 请求固定携带 `Content-Type: application/json`、`X-CloudCodex-Device` 和
    `X-CloudCodex-Token`。设备密钥只存 Mac 钥匙串；服务端只保存带随机盐的安全摘要，日志必须移除该请求头。
    第一次 register 可以按设备 ID 创建身份；同一 ID 再次注册必须验证原密钥，绝不能用新值覆盖。

    Mini 请求使用独立业务登录态，例如 `Authorization: Bearer <session>`。小程序永远不能获得设备密钥。
    后端从登录态取得用户 ID，不接受请求体里的 userId/openid 作为授权依据。

    JSON 外壳固定为：

    ```json
    {"status":0,"msg":"ok","data":{}}
    ```

    - HTTP 2xx + `status=0` 才是业务成功。
    - 鉴权失败使用 HTTP 401/403；限流使用 429；无法解析的请求使用 400。
    - 可恢复业务冲突可返回 HTTP 200 + 非零 `status` 和可读 `msg`，也可使用 409，但同一部署必须一致。
    - 空队列严格返回 `{"status":0,"msg":"ok","data":null}`，不能返回 `[]`、`{}`、204 或 HTML。
    - 设备 API 不得 30x 跳转；Mac 不会携带凭据跟随重定向。
    - 建议稳定错误标识：`AUTH_INVALID`、`NOT_PAIRED`、`PAIR_EXPIRED`、`PAIR_LOCKED`、
      `DEVICE_OFFLINE`、`WORKSPACE_NOT_ALLOWED`、`THREAD_NOT_ALLOWED`、`MODEL_NOT_ALLOWED`、
      `TASK_CONFLICT`、`TASK_TERMINAL`、`RATE_LIMITED`。

    ## 3. Agent 请求与响应 Schema

    ### 3.1 register

    请求：

    ```json
    {"name":"My Mac","resetPairing":false}
    ```

    `resetPairing=true` 只对未配对设备重新生成配对码。响应 `data`：

    ```json
    {
      "deviceId":"与 X-CloudCodex-Device 完全一致",
      "name":"My Mac",
      "paired":false,
      "pairingCode":"01234567",
      "pairingExpiresAt":"2030-01-01T10:05:00Z",
      "pollIntervalSeconds":3
    }
    ```

    配对码必须由密码学安全随机源生成、保留前导零、短时有效、只保存摘要且一次性消费。
    `paired=true` 时 `pairingCode` 可为空，`pairingExpiresAt` 可为 null。

    ### 3.2 heartbeat

    请求核心结构：

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

    后端应将快照作为一个版本整体替换，记录 `lastSeenAt`，兼容未知扩展字段。路径属于用户隐私，不能写入普通访问日志。
    `usage` 只含白名单字段：`capturedAt`、`available`、`plan?`、`subscriptionPeriodEnd?`、
    `buckets[{id,name,windows[{usedPercent?,windowDurationMins?,resetsAt?}]}]`、
    `resetCredits?`、`creditBalance?`。不得推断或补造未知额度。

    响应：

    ```json
    {
      "paired":true,
      "runningTasks":[{"taskId":"task-1","threadId":"thread-1","turnId":"turn-1","workspace":"/absolute/project"}],
      "queueSummary":{"queuedCount":0,"blockedCount":0}
    }
    ```

    `runningTasks` 只返回本设备已领取、未终结且已有真实 turnId 的任务，用于 Mac 重连后只读核对终态；不能借此重放提示词。

    ### 3.3 tasks/next

    领取必须在事务中完成，使用条件更新或行锁保证同一任务只被一个请求获得。设备需已配对、在线且 ready。

    ```json
    {
      "taskId":"task-uuid",
      "deviceId":"device-uuid",
      "threadId":"",
      "workspace":"/absolute/project",
      "prompt":"运行测试并报告结果",
      "model":"",
      "effort":"",
      "status":"running",
      "speed":"standard",
      "permissionMode":"ask",
      "imageUrls":[]
    }
    ```

    必需字符串字段即使为空也保留。`threadId=""` 表示新建会话；非空时必须属于设备最新快照。
    workspace、model、effort、speed 和 permissionMode 必须由心跳能力快照校验：
    `speed` 仅为空、standard、fast；`permissionMode` 仅为空、ask、auto、full；full 必须在小程序明确警示。
    图片最多 4 张，只允许 HTTPS 和受控大小/类型，地址不能携带设备凭据。Mac 请求超时 15 秒，不要实现超时更长的长轮询。

    ### 3.4 tasks/{taskId}/status

    ```json
    {
      "status":"completed",
      "threadId":"thread-uuid",
      "turnId":"turn-uuid",
      "result":"任务结果",
      "error":"",
      "fileDiff":"",
      "progress":{"steps":[{"id":"step-1","kind":"command","title":"运行测试","status":"completed","text":"通过"}],"truncated":false,"revision":3},
      "recovery":false,
      "waitReason":"",
      "actualModel":"gpt-x",
      "actualEffort":"high"
    }
    ```

    `progress.revision` 只接受递增版本。重复终态要返回成功；终态不能被迟到的 running/queued 覆盖。
    Mac 回传 `status=queued` 且 `waitReason=writer_busy` 或 `thread_busy` 时，释放领取并设置服务端冷却时间，不能记为失败或立即热循环。
    result 最多按 60,000 字符保存，error/fileDiff/progress 也应有明确上限。

    ### 3.5 events

    会话完成：

    ```json
    {"type":"conversation_completed","eventId":"conversation:thread-uuid:turn-uuid","threadId":"thread-uuid","turnId":"turn-uuid"}
    ```

    五小时额度从已知非满恢复为 100%：

    ```json
    {"type":"quota_restored","eventId":"quota:1893456000"}
    ```

    以 `hash(deviceId + eventId)` 建唯一约束。只有服务号发送成功后才确认事件；临时失败删除占位记录或标记为可重试，避免 Mac 收到成功后永久丢失通知。
    接收者只能由已配对设备的 owner 解析。用户未关注/未绑定服务号时，应记录“不可投递”原因；不要伪装成已发送。
    服务号通知建议先创建站内通知，再尽力发送外部模板消息。跳转小程序失败时可按业务策略降级为不带跳转的服务号消息。

    ### 3.6 history、resets 与 unpair

    - `history/next` 返回 `{id,threadId,workspace,cursor}`；回传 `{page:{messages,nextCursor},error}`。
      message 字段为 `id,role,text,title,model,effort,attachments,timestamp?`。历史读取不得 resume 或启动轮次。
    - `resets/next` 返回 `{id,creditRef}`；creditRef 只是 Mac 生成的不可逆引用。只有小程序用户明确二次确认后才创建请求。
    - `unpair` 与 Mini 删除设备都必须先检查 queued/claimed/running 任务。成功后撤销 owner、作废配对码并拒绝旧用户继续创建任务，但保留历史记录。

    ## 4. 任务状态机与并发规则

    ```text
    scheduled ──到时──> queued ──原子领取──> running ──> completed
                              │               └──────> failed
                              └─用户取消─────────────> canceled
    running ──writer_busy/thread_busy──> queued + retryAfter
    failed ──用户重试──> 新 taskId 的 queued 任务（原记录不改写）
    ```

    - 同一设备可并行不同会话；同一持久会话同一时刻最多一个 writer。
    - 定时任务必须晚于当前时间且设置最大可预约范围；到时后再进入 queued。
    - 领取、取消、重试、状态回传都使用条件更新并写审计时间。
    - completed、failed、canceled 是不可逆终态。任何迟到请求都不能回滚终态。
    - 客户端网络超时表示结果未知，不等于服务端失败；所有写接口都要可安全重试。

    ## 5. 推荐数据库最小结构

    - `users(id, mini_openid unique, unionid nullable, created_at, updated_at)`
    - `devices(device_id primary key, secret_hash, owner_id nullable, name, alias, note, pairing_code_hash,
      pairing_expires_at, remote_control_ready, last_seen_at, workspaces_json, threads_json, models_json,
      usage_json, system_metrics_json, connection_health_json, created_at, updated_at)`
    - `tasks(task_id primary key, owner_id, device_id, parent_task_id nullable, thread_id, turn_id, workspace,
      prompt, model, effort, speed, permission_mode, image_urls_json, status, wait_reason, scheduled_at,
      retry_after, result_text, error_text, file_diff, progress_json, progress_revision, actual_model,
      actual_effort, claimed_at, finished_at, created_at, updated_at)`
    - `history_requests(id primary key, owner_id, device_id, thread_id, workspace, cursor, status, response_json, error, created_at, updated_at)`
    - `reset_attempts(id primary key, owner_id, device_id, credit_ref, status, result, created_at, updated_at)`
    - `notification_events(dedupe_key primary key, device_id, owner_id, event_id, event_type, delivery_status, error_code, created_at, sent_at)`
    - `pairing_attempts(subject_key, failure_count, window_started_at, locked_until)` 和必要的安全审计表。

    索引至少覆盖：owner+device、device+status+scheduledAt+createdAt、device+thread+status、owner+createdAt。
    prompt、result、路径和图片属于用户内容；配置访问控制、保留期限和删除策略，不写入普通日志。

    ## 6. 小程序页面与必须状态

    1. 登录/初始化：loading、登录失败重试、登录过期刷新。
    2. 设备列表：未配对空状态、在线/离线、是否允许远程、最后心跳、编辑和解绑。
    3. 扫码配对：只接受 `cloudcodex://pair?v=1&code=八位数字`；支持手输；展示过期、已消费、冻结和被其他账号绑定错误。
    4. 新建任务：设备 → 工作区 → 新会话/已有会话 → prompt/图片 → 模型/强度/速度/权限 → 立即/定时。
       所有选项来自设备快照；离线或 remoteControlReady=false 时禁止立即任务。
    5. 任务列表/详情：scheduled、queued、running、等待同会话、completed、failed、canceled；运行中轮询或使用安全推送刷新。
       展示真实 actualModel/actualEffort、进度、结果、错误和文件差异；失败任务可重试，queued 可取消。
    6. 会话历史：显式只读，分页加载，不能因查看历史创建 Codex 轮次。
    7. 额度：区分未知、不可用、窗口使用百分比、恢复时间、额外余额和重置次数；未知绝不能显示为 0 或 100。
    8. 服务号通知：展示关注/绑定状态及最后一次不可投递原因；配对成功不等于已经关注服务号。

    ## 7. 服务号通知验收

    - 小程序用户与服务号关注者通过 unionid 或受控绑定流程关联；不要仅凭客户端传入 openid。
    - `conversation_completed` 与 `quota_restored` 使用已审核且字段匹配的模板；模板 ID、AppID、AppSecret 只来自当前部署配置。
    - 会话完成只对新的 threadId+turnId 发送一次；额度通知只对“已知非 100% → 已知 100%”边沿发送，不在启动时凭一条 100% 快照补发。
    - 记录微信 `errcode`、可重试性和发送时间，但日志不得包含 token、完整 openid 或模板敏感内容。
    - 分别验证：未关注、已关注未绑定、已绑定、微信暂时失败、跳转页无效后降级、Mac 断网后补传和重复事件。

    ## 8. 最低自动化与端到端验收

    后端测试至少覆盖：密钥摘要、错误密钥、跨用户访问、配对码过期/重复/限流/冻结、并发领取、
    同会话互斥、终态幂等与乱序、空队列 null、定时任务、失败重试产生新记录、解绑拦截、通知去重与失败重试。

    小程序测试至少覆盖：二维码严格解析、登录态过期、设备离线、动态模型/强度、full 权限警示、图片上限、
    任务各状态、取消/重试、历史分页、额度未知态和服务号绑定状态。

    最终使用隔离测试账号完成：Mac register → 小程序登录并扫码 → heartbeat paired=true → 创建任务 →
    Mac 原子领取 → 回传真实 threadId/turnId 与进度 → 终态展示 → 新会话完成通知 → 模拟额度非满后恢复通知 → 解绑。
    分别记录单元测试、接口测试、小程序开发者工具、Mac 客户端、微信真机、部署和生产验收；前一层成功不能代替后一层。
    """#
}
