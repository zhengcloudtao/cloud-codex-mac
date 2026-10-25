# 本人设备间账号配对与持续更新

本功能复用 CloudCodex 当前选定的 HTTPS 后端，不新增生产域名。内置模式仍使用客户端既有的内置服务；自定义模式要求两端选定相同根地址。此文描述本地实现，不代表后端已部署或真实 Windows 设备已验收。

## 使用

1. 在来源电脑账号管理中，对已登录的本地账号点击「共享到我的设备」（Mac）或「共享 → 生成分享码」（Windows）。macOS 首次读取凭据可能要求钥匙串授权。
2. 复制完整的 `CCS1` 分享码，在目标 Mac 或 Windows「账号管理 → 通过分享码添加账号」粘贴并连接。分享码有效期 10 分钟，只能绑定一台接收设备；它不是可公开传播的短口令。
3. 接收端成功连接后保存设备配对，不保存 OpenAI 长期续期凭据。Mac 新增独立共享账号，返回列表手动切换；Windows 沿用当前本地配置的共享连接。后续启动直接取得加密更新，认证失败时请求来源设备更新。
4. 来源电脑保持 CloudCodex 运行。每 5 秒检查同步状态；访问凭据临近到期时由来源电脑的 Codex app-server 续期，凭据变化或接收端请求刷新时发布新版本。Windows 来源按原本地账号目录读取，切换当前账号不改变共享绑定。
5. 来源电脑可「停止共享」，停止后续获取和续期；已发出的访问凭据在本身到期前可能仍有效。Windows「断开共享账号」恢复原本的本地登录；Mac 先切换到其他账号，再移除共享卡片。

支持 Mac ↔ Windows、Mac ↔ Mac、Windows ↔ Windows。接收到的授权不再转分享。Windows 每个本地账号配置一次使用一个共享连接。每台目标电脑生成单独分享码。更换或断开账号要求本地任务和等待队列为空。凭据同步不包含项目、会话、草稿或附件。

## 凭据与协议边界

- 来源设备 的长期续期凭据只交给本机 Codex，绝不导出。应用从当前 CODEX_HOME 的 Codex 凭据存储读取短期 access token，核对其中的账号标识。
- 使用 AES-256-GCM。每个配对独立 32 字节密钥，随机 nonce，combined 格式为 nonce(12) + ciphertext + tag(16)，整体标准 Base64。
- AAD 的 UTF-8 内容为 `cloudcodex-account-share-v1|<share UUID>|<decimal version>`。密文 JSON 只包含 `accessToken/chatgptAccountId/chatgptPlanType/email/expiresAt`。
- 分享码格式 `CCS1.<UUID>.<32字节随机配对证明的Base64URL>.<32字节密钥的Base64URL>`。密钥从不发送给后端。
- 接收端在首次兑换前生成并保存独立随机设备证明；后端只存配对证明与设备证明的 SHA-256。丢失响应时，仅相同设备证明可幂等重试，不能被第二台设备复用。
- 配对完成后的短期访问凭据只在接收端内存和 app-server 的 ephemeral auth 中使用，不覆盖已有 CODEX_HOME 登录文件。配对密钥/设备证明保存在 Windows 凭据管理器，Mac 的配对密钥、接收设备证明保存在本机钥匙串，Windows 来源的密钥与设备证明按共享分别保存在凭据管理器。
- 密文版本严格递增；两端持久保存已接受的最高版本和账号标识，拒绝回退、篡改、过期和账号替换。来源设备 重新登录同一账号后可继续更新；换成另一个账号/工作区时须重新配对。
- 不在日志、错误信息、UserDefaults、普通配置文件或 Git 中写入分享码、密钥、access token 或 refresh token。复制分享码是用户显式操作，按登录凭据保管。

## 现有后端新增接口

所有路径都接在现有根地址之后。响应沿用 `{status,msg,data}`；相关响应 `Cache-Control: no-store`。

来源设备使用原有 `X-CloudCodex-Device` / `X-CloudCodex-Token`：

- `POST /api/cloud-codex/agent/account-shares`：`id, accountRef(SHA-256), code, ciphertext, version=1`。
- `GET /api/cloud-codex/agent/account-shares`：返回来源设备自己的 ID、版本、配对状态、接收设备名、配对过期时间、refreshRequested；不返回密钥或配对证明。
- `PUT /api/cloud-codex/agent/account-shares/:id`：发布 `version,ciphertext`；只允许当前版本 + 1。
- `DELETE /api/cloud-codex/agent/account-shares/:id`：撤销并清除密文与接收设备证明摘要。

接收设备使用 `X-CloudCodex-Share-Token`，与来源设备凭据完全独立：

- `POST /api/cloud-codex/account-shares/:id/claim`：`code,name`；事务条件写一次性绑定。
- `GET /api/cloud-codex/account-shares/:id`：读取 `id,version,ciphertext`。
- `POST /api/cloud-codex/account-shares/:id/refresh`：请求来源设备 刷新；后端不向 OpenAI 发起刷新。

## 升级与验证

先升级 go-ai，再分发新版 Mac/Windows 客户端。go-ai 启动迁移增加 `cloud_codex_account_share`，旧远程任务/配对表和接口不变。回滚服务端时保留新表，不删除账号或会话数据。

自动验证覆盖后端来源/接收设备隔离、过期/一次性兑换、并发兑换、版本重放与撤销；Swift/C# 使用相同 CryptoKit 生成的合成密文验证互通；Windows HTTP 测试使用假服务端和假凭据存储。它们不等于真实账号续期或 Windows GUI 验收。

真实验收需在用户自己的两台设备双向执行：首次配对 → 关闭重开 → 来源设备更新同一账号 → 接收端认证失败后获得新版 → 来源设备暂离线/恢复 → 撤销。无效授权、账号风控或强制重新验证仍可能需要在来源设备 重新登录；不能承诺永久免登录。

## 双向客户端兼容

Mac 添加共享账号只保存一张尚未启用的账号卡片，可在本机任务执行或队列等待期间配对；当前客户端身份不变。点击「切换」时仍检查运行任务和等待队列。配对失败按分享码格式、待配对记录冲突、网络及后端拒绝分别提示；原始服务响应不直接显示，避免泄露凭据。

双向支持继续使用 `CCS1` 和上述现有端点、版本与 AES-GCM AAD，无需服务端协议迁移。原来的 Mac → Windows 分享仍有效。

Mac 接收记录使用现有账号列表 `CloudCodex.accounts.v1` 的可选 `shared` 标记；旧记录缺省为本地登录。配对凭据位于钥匙串 `CloudCodex.AccountReceiver.v1`，普通偏好只保存待配对账号 UUID。接收时先保护设备证明再兑换，响应丢失可留空重试。共享认证失败会阻止该连接，不回落到原生登录。切换失败恢复旧客户端认证配置，沿用原有任务/队列门禁与草稿保留逻辑。

Windows 来源共享元数据位于 `%LOCALAPPDATA%\codex-control-window\account-publications.json`，密钥及来源设备证明位于凭据管理器 `CloudCodex.account-publication.v1.<共享UUID>`。来源设备身份按共享独立保存，不随当前本地配置或远程控制开关变化；后台只读取本地账号的原生登录文件，不转发接收到的临时授权。删除来源账号或本地登录不可读时保留共享记录，拒绝更新，可在共享窗口停止共享。
