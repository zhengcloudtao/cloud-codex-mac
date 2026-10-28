# Apple Watch 只读状态

通过现有远程服务给 ios-timetable 的 iPhone、Apple Watch 和表盘同步套餐、额度、任务状态。无需局域网或向公网开放 Mac 端口。

## 使用

1. 先部署包含 Watch 接口和 `cloud_codex_watch_link` 表的 go-ai。
2. 更新 Mac 客户端，打开远程控制，开启远程连接，在「App 与手表 · 扫码绑定」生成控制绑定二维码。
3. iPhone 学深课表 → 个人中心 → CloudCodex，点击添加设备，扫码绑定（也可粘贴 `CCA1.` 控制绑定码）；配对信息通过 WatchConnectivity 发送到自己的 Watch。
4. 在 Watch 长按表盘 → 编辑 → 复杂功能 → CloudCodex 状态。点击组件进入 CloudCodex 页面。

Mac 必须运行并保持网络连接。Watch 使用自己的 URLSession 访问 HTTPS 服务，支持通过 iPhone、Wi-Fi 或蜂窝联网。前台每 60 秒尝试更新；表盘请求 15 分钟后的刷新，由 watchOS 决定实际时间，不保证秒级实时。超过 5 分钟的数据标记待更新，额度采用自身采集时间，不能用新的心跳掩盖旧额度。

## 数据与权限

- 使用当前保存的远程服务根地址，保留路径前缀；iOS 不硬编码其他产品的域名。
- 新增 `POST/DELETE /api/cloud-codex/agent/watch-link`：现有设备鉴权，创建/撤销独立只读凭据。
- 新增 `GET /api/cloud-codex/watch/{deviceId}/status`：仅接受 `X-CloudCodex-Watch-Token`，不能创建、领取、取消任务或读取账号凭据。
- `CCW1.` 加 Base64 JSON，字段：version=1、server、deviceId、token、expiresAt（Unix 秒）。这是可重复使用的只读连接凭据，90 天到期。仅复制给自己的设备；不要保存到日志或提交到仓库。重新生成立即撤销旧凭据；Mac 可主动撤销。
- 后端只存随机 256 位 token 的摘要；iPhone、Watch 和表盘使用 Keychain。App Group 中仅保存无凭据的展示快照。
- 心跳新增可选 `watchSnapshot`，只有用户启用手表共享才发送。旧服务或旧 Mac 的其他字段保持兼容；要使用手表功能必须先升级后端。
- 任务来自远程调度的全局快照（授权工作区、最多 300 个会话），不随侧栏筛选变化；优先显示运行/等待输入/等待电脑操作授权的会话，最多展示 20 个。空闲不冒充完成；完成/失败来自已确认的本地结果。服务端另提供实际远程排队数。
- 套餐名称、到期、5 小时/每周剩余百分比与重置时间来自现有额度读取；缺失显示未知，不补造为 0%。

## 验证边界

源码测试、Swift 构建通过不代表应用已安装或后端已部署。真机需分别验证 Keychain 共享签名、WatchConnectivity、离开局域网后手表刷新、四类表盘、Mac 离线、账号切换、撤销与到期。

## 账户指标扩展

快照 v1 新增可选 creditBalanceText（账户余额展示值）、availableResetCount（可用重置次数）、weeklyPaceLabel 与 weeklyPaceState（ahead/behind/onTrack）。余额格式和每周进度复用 AccountOverview 的现有逻辑；额度不可用时清空这些字段，不补造为零。需先更新后端的字段白名单，再更新 Mac 和 Watch；连接码和既有配对保持兼容。

## 一次扫码授权 App

电脑端改为 POST /api/cloud-codex/agent/app-link，二维码 CCA1（version=2）包含独立 controlToken。界面明确说明扫码授权 iPhone 查看会话、提交任务和操作本电脑，手表只读。撤销入口同时撤销 App 与手表。旧 CCW1 保持只读，不自动升级；后端需先升级，旧服务器不支持 app-link 时提示错误，不回退到小程序授权。

### 硬件独立只读连接码

电脑远程控制页新增“硬件状态屏 · 独立只读绑定”：生成、复制、轮换或撤销硬件令牌不会修改 App/Watch 令牌。每台电脑支持一条硬件授权，轮换或撤销时会确认；已生成的码只在当前设置页内暂存，关闭后不再显示。硬件码为 `CCW1` version 1，仅含原有服务地址、电脑 ID、独立只读 token 和到期时间，不含 App 控制 token；有效期 90 天，设备联网后每分钟读取只读状态。即使没有 App/Watch 绑定，只要启用了硬件授权，电脑也会继续发布白名单状态快照。

先部署支持 `hardware-link` 的后端及其数据库迁移，再更新电脑端；旧硬件无需重刷。只完成本地构建不代表服务已部署或设备已成功绑定。
