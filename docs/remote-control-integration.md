# CloudCodex 自定义远程控制接入指引

字段级 API、状态机、小程序参考接口和持久化规则见 [API 文档](remote-control-api.md)；机器可读契约见 [OpenAPI 3.1](remote-control-openapi.yaml)。应用内「复制完整 AI 指引」会将接入要求与完整 API 契约合并复制，适合直接作为 AI 开发任务的输入。

服务根地址：<填写你自己的 HTTPS 后端根地址>

请为我开发一个微信小程序和配套后端，兼容 CloudCodex Mac 客户端的远程控制协议。
先确认我的技术栈、部署环境、小程序 AppID 和域名；缺失值使用占位符，不借用其他产品配置。
交付源码、数据库迁移、环境变量模板、接口说明、自动化测试和部署步骤。不要自动发布或向真实设备发送任务。

## 一、架构与客户端配置

手机小程序 → 自建 HTTPS 后端 ← CloudCodex Mac 主动轮询；模型推理和工具执行发生在 Mac。
Mac 无需开放入站端口。后端是中转服务，不需要拿到模型 API Key 或 Codex 登录凭据。
用户在 CloudCodex「远程控制」里关闭远程任务，选择「自定义服务」，填入上面的服务根地址并保存，再开启并配对。
根地址允许路径前缀。客户端追加下面的固定路径；例如根地址 https://relay.example.invalid/prefix，注册路径是 /prefix/api/cloud-codex/agent/register。
不要把 /api/cloud-codex/agent 填进根地址，否则会重复拼接。使用 HTTPS 和受信任证书；客户端不跟随 HTTP 重定向。
不同根地址使用独立的设备 ID、钥匙串密钥和待回传状态。切回原服务会复用原设备身份；切换地址不会自动解绑原服务。
自定义模式不会展示内置小程序码。用户从自己的小程序入口打开小程序，扫描 Mac 显示的设备配对二维码。
此设置只替换远程控制中转服务，不修改模型供应商地址或其他独立通知功能。

## 二、鉴权、响应格式与配对

Mac 的所有 agent 请求携带：
- Content-Type: application/json
- X-CloudCodex-Device: 客户端生成并持久化的设备 ID
- X-CloudCodex-Token: 客户端在系统钥匙串生成并保存的随机设备密钥

设备首次注册时后端可创建记录，只保存密钥摘要；已有设备必须校验原摘要，不允许用新密钥覆盖已有身份。
设备 ID 不是认证凭据。所有领取、心跳、状态、历史和解绑接口都要验证设备 ID 与密钥，查询只能命中该设备的数据。
小程序使用独立的用户登录态，不接收或存储上述设备密钥。登录用户只能访问其绑定设备。
成功返回 HTTP 2xx，JSON 为 {"status":0,"msg":"ok","data":...}；业务错误 status 非 0、msg 可读；鉴权失败返回 401/403。
空队列必须返回 {"status":0,"msg":"ok","data":null}，不要返回空数组、空对象、204 或 HTML。
只有确认持久化成功后才返回成功，客户端会重试终态回报。接口不能通过 302 跳转到登录页或另一域名。

配对流程：register 生成密码学安全的 8 位数字码（保留前导零），设置有效期。
Mac 二维码的文本严格为 cloudcodex://pair?v=1&code=12345678；不含服务地址或密钥。
小程序扫描后解析 scheme=cloudcodex、host=pair、v=1 和 8 位数字 code，提交到自己的后端。
后端校验登录态、有效期、尝试频率；事务中将设备绑定到当前用户并一次性消耗配对码。
已绑定设备不能被另一账号凭码接管。resetPairing=true 只刷新未配对设备的码；已配对设备必须先走 unpair。
unpair 前检查排队、领取中、执行中任务；有未结束任务返回业务错误，成功后撤销用户控制权并作废旧配对码。

## 三、Mac 必需接口（路径不可更名，字段使用 camelCase）

1. POST /api/cloud-codex/agent/register
请求：{"name":"My Mac","resetPairing":false}
data 示例：{"deviceId":"从请求头取得的设备ID","name":"My Mac","paired":false,"pairingCode":"12345678","pairingExpiresAt":"2030-01-01T10:05:00Z","pollIntervalSeconds":3}
上例日期只是格式示例，实际过期时间由服务器生成。paired=true 时 pairingCode 可为空字符串，pairingExpiresAt 可为 null。
deviceId 必须与请求头一致。pollIntervalSeconds 是必需整数；当前 Mac 实际约每 3 秒轮询、每 9 秒心跳，不会按该字段调整。

2. POST /api/cloud-codex/agent/heartbeat
请求必需字段：name:string、permissionLabel:string、remoteControlReady:bool、workspaces:array、threads:array。
workspaces 项：{"path":"Mac同步的绝对路径","name":"项目名称"}。
threads 项：{"id":"会话ID","title":"标题","workspace":"路径","model":"模型","status":"idle或active等","updatedAt":1893456000}；updatedAt 可缺省，是 Unix 秒。
可选 models 项：id、model、name、description:string；supportedEfforts:string[]；defaultEffort:string；supportsFast:bool。
可选顶层 defaultModel、defaultEffort:string；usage、systemMetrics、connectionHealth:object 或 null。后端应兼容扩展字段，按设备保存快照供用户端展示。
data 最小响应：{"paired":false}。
完整响应可为 {"paired":true,"runningTasks":[],"queueSummary":{"queuedCount":0,"blockedCount":0}}。
runningTasks 项严格包含 taskId、threadId、turnId、workspace 四个字符串，只返回该设备已领取、尚未结束且有真实 turnId 的任务。
Mac 会只读核对这些轮次并补传 completed/failed，不会重新发送原提示词。重连时不要盲目将正在执行的任务重新入队。
remoteControlReady=false 或心跳过期时不派发新任务；离线不代表正在执行的任务一定失败。

3. GET /api/cloud-codex/agent/tasks/next
鉴权且已配对、ready 时，在事务中原子领取一个该设备的 queued 任务，将服务端状态改为 running，然后返回。
data 示例：
{"taskId":"task-uuid","deviceId":"设备ID","threadId":"","workspace":"Mac同步的路径","prompt":"运行测试并报告结果","model":"","effort":"","status":"running","speed":"standard","permissionMode":"","imageUrls":[]}
必需字符串：taskId、deviceId、threadId、workspace、prompt、model、effort、status；即使使用默认值也保留空字符串。
threadId="" 表示新会话；非空必须属于该设备已同步的工作区。workspace 只能从 Mac 快照选择，不接受任意路径。
model/effort="" 使用客户端当前设置；显式值只能来自心跳 models 和 supportedEfforts，不维护另一份硬编码模型目录。
speed 可缺省或为空（沿用当前设置）、standard、fast；仅 supportsFast=true 才提供 fast。
permissionMode 可缺省或为空（沿用当前设置）、ask、auto、full。UI 必须清楚展示执行权限，full 需用户明确选择；Mac 会验证本机支持的权限配置。
imageUrls 可缺省，最多 4 个 HTTPS 图片地址，每张最多 5 MB，PNG/JPEG/GIF/WebP；需能被 Mac 直接下载。不要把设备密钥塞进图片地址。
action 不发送或设为空；客户端会拒绝其他 action，不支持把文件预览当成开发任务。
不给忙碌会话派发后续任务；忙碌任务不要阻挡其他空闲会话。没有可领取任务时 data=null。
请求超时是 15 秒，不实现超过这一时限的长轮询。

4. POST /api/cloud-codex/agent/tasks/{taskId}/status
必需请求字段：status、threadId、turnId、result、error，均为 string。
示例：{"status":"completed","threadId":"thread-uuid","turnId":"turn-uuid","result":"测试通过","error":"","actualModel":"所用模型","actualEffort":"high"}
可选 fileDiff:string、progress:object、recovery:bool、waitReason:string、actualModel:string、actualEffort:string。
progress 结构：{"steps":[{"id":"step","kind":"command","title":"执行命令","status":"completed","text":"摘要"}],"truncated":false,"revision":1}。
状态流：queued → running → completed/failed；若 Mac 返回 queued 且 waitReason 为 writer_busy/thread_busy，释放领取状态并延迟重排，不把它记为执行失败。
按 taskId 幂等更新；重复终态成功确认；已终态不可被延迟 running/queued 或旧 progress 覆盖。progress 按 revision 丢弃旧版本。
threadId/turnId 一旦由 Mac 回报，保存真实值用于恢复。actualModel/actualEffort 用于展示实际设置，不能用任务请求值伪装成已验证结果。
回报成功可返回 {"status":0,"msg":"ok","data":null}。
taskId、历史请求 ID、重置 ID 使用 UUID 或安全的不含斜杠的标识符。

5. POST /api/cloud-codex/agent/unpair
无请求体，鉴权后按前述未结束任务检查解除绑定。成功返回 {"status":0,"msg":"ok","data":null}。
保留历史任务；Mac 会重新注册生成新配对码。

## 四、可先返回空队列的扩展接口

当前客户端会轮询下面两个 GET；初版应实现并返回成功 data=null，不要创建不支持的请求：
- GET /api/cloud-codex/agent/history/next
- GET /api/cloud-codex/agent/resets/next

如支持只读历史：history/next data 为 {"id":"read-uuid","threadId":"会话ID","workspace":"授权路径","cursor":""}。
Mac 通过 POST /api/cloud-codex/agent/history/{id} 回报：{"page":{"messages":[],"nextCursor":null},"error":""}。
messages 项必需 id、role、text、title、model、effort:string 与 attachments:string[]；timestamp 可选 Unix 秒。
失败时 page 可缺省或 null，error 为可读文本。成功确认格式同上。历史读取不得创建、resume 或启动开发轮次。

额度重置是可选高级功能。resets/next data 为 {"id":"attempt-uuid","creditRef":"心跳usage提供的引用"}；Mac POST /api/cloud-codex/agent/resets/{id}，请求 {"status":"执行结果字符串"}。
不将 creditRef 当作真实账号凭据；同一 attempt ID 幂等处理。未实现用户明确确认、一次性请求和失败恢复前保持 data=null，初版不提供额度重置按钮。

## 五、后端与小程序交付要求

用户侧接口可以自行设计，它们不是 Mac 固定协议。至少提供登录、设备列表、提交配对码、设备快照、创建任务、任务列表/详情。
后端数据至少包括 users、devices、pairing_codes、tasks；选做 history_requests、reset_attempts。记录用户归属、设备归属、任务状态、真实轮次 ID 和更新时间。
扫码配对、任务领取、状态迁移需要事务/条件更新；使用唯一约束和幂等键。所有用户侧操作检查设备归属，禁止凭客户端提供的 userId 越权。
小程序页面：登录 → 设备管理/扫码配对 → 工作区与会话选择 → 提示词/模型/强度/权限/速度 → 任务详情（排队原因、进度、结果、错误）。

可选通知接口：`POST /api/cloud-codex/agent/events`。Mac 在已配对时上报
`conversation_completed` 和 `quota_restored`，请求包含稳定的 `eventId`；后端必须按设备与
`eventId` 幂等处理。若后端支持服务号通知，应由当前配对设备的用户归属解析接收者，不能信任
客户端提交的用户标识。会话完成事件增加可选 `threadTitle`（会话列表显示标题），服务号预约类型显示“会话完成”、预约项目显示该标题；缺少标题时显示“未命名会话”，并沿用模板的 20 字截断规则。接口暂时失败时 Mac 会保留事件并在联网后重试。
同一用户的设备只能看到自己的快照和任务；工作区、模型、强度、加速能力全部来自 Mac 心跳。
微信登录用 wx.login 获取 code，由自己的后端与微信交换身份并生成业务登录态；AppSecret、session_key 只留在服务端。
wx.scanCode 获取上述设备二维码文本；不要依赖内置小程序 AppID 或小程序码。小程序的 request 合法域名配置为自己的 HTTPS 后端域名，图片还需配置相关下载/上传域名。
对外业务接口使用独立用户 token；设备 token 不下发到小程序。关闭请求头敏感字段日志；提示词/结果/工作区路径按用户数据保护，设置访问控制和保留周期。
不实现任意远程 shell 接口，不让后端绕开 Mac 已有的工作区、模型和权限验证。

微信官方参考（实现时核对当前平台要求）：
- https://developers.weixin.qq.com/miniprogram/dev/framework/open-ability/login.html
- https://developers.weixin.qq.com/miniprogram/dev/api/device/scan/wx.scanCode.html
- https://developers.weixin.qq.com/miniprogram/dev/framework/ability/network.html

## 六、验收清单

使用本地测试数据完成：注册 → 获取有效配对码 → 登录并扫码绑定 → 心跳 paired=true → 提交测试任务 → 原子领取 → 回传真实 threadId/turnId → 展示终态。
覆盖：错误密钥、跨用户/跨设备访问、配对码过期/重复消费/限流、重复领取、同会话忙碌重排、重复和乱序回报、空队列、网络断开后的补传、重连只读恢复。
覆盖 unpair 有未结束任务时拒绝，以及解绑后旧用户不能提交任务。
覆盖自定义路径前缀与无重定向；切换两个服务时设备凭据不共享、旧服务待补传数据不发送给新服务。
不把 HTTP 200 或部署成功当作整条链路已验收；分别记录后端测试、小程序开发者工具、Mac 客户端和真机结果。
