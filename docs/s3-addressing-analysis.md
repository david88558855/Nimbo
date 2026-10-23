# S3 寻址模式分析：通用路径风格 vs 厂商定制

> 项目：Nimbo · 多协议网盘客户端
> 范围：S3 兼容协议的寻址方式（path-style / virtual-hosted-style）、bucket 处理、第三方实现兼容性差异
> 性质：技术分析与方案建议，**不涉及代码改动**

---

## 0. 结论先行

1. **对第三方/自建 S3，通用做法是 path-style，但"只做 path-style"是错的。**
   正确形态是 **双模式 + 自动探测**：`auto`（默认）→ 先试 path-style，失败再试 virtual-hosted，成功后把结论固化到该挂载配置。

2. **为什么默认不是 vhost**：第三方实现普遍拿不到 bucket 级泛解析 DNS 与通配证书，尤其是
   `192.168.1.20:9000` 这种 IP+端口、内网自签证书、以及桶名带 `.` 的场景，vhost 直接不可用。

3. **为什么不能只做 path-style**：
   - 阿里云 OSS 的 S3 兼容接口官方文档明确**只支持虚拟托管风格**，path-style 会被拒（不同地域/Endpoint 仍建议实测）；
   - AWS 2020-09-30 之后新建的 bucket **只接受 virtual-hosted**；
   - 部分商业网关/CDN 前置只暴露 vhost 入口。

4. **bucket 不是目录**：bucket 绑定在"挂载"上，文件树根 = `bucket + 可选前缀`；不展示 bucket 列表、不默认建 bucket、不跨 bucket 移动。

5. **探测不依赖 ListBuckets**：第三方普遍禁用该权限。用 `HeadBucket` → `ListObjectsV2(max-keys=1)` 判定可用性。

---

## 1. 两种寻址方式，差在哪

| 维度 | path-style | virtual-hosted-style |
|---|---|---|
| URL | `https://s3.example.com/bucket/key` | `https://bucket.s3.example.com/key` |
| Host 头 | `s3.example.com` | `bucket.s3.example.com` |
| DNS | 只需一条 A/CNAME | 需要泛解析 `*.s3.example.com` |
| TLS | 单域名证书即可 | 需要 `*.s3.example.com` 通配证书 |
| 桶名含 `.` | 无影响 | **证书不匹配**（RFC 2818 通配符不跨点） |
| IP + 端口 endpoint | 可用 | 不可用（IP 无法作为子域） |
| 签名（SigV4） | `host` 参与 CanonicalRequest | 同上，但 host 含桶名 |
| 反向代理 | 一条 location 即可 | 需按桶下发证书/泛解析 |
| 301 重定向 | 常见（region 不符时） | 少见（DNS 已定位） |
| 预签名 URL 可移植性 | 高 | 依赖 DNS 与证书 |

### 1.1 Host 参与签名，是最容易被忽略的一条

SigV4 的 `CanonicalHeaders` 里包含 `host`。任何中间层只要改写了 Host（反向代理 `proxy_set_header Host $upstream`、CDN 回源改写、路径前缀重写），签名立刻 `SignatureDoesNotMatch`。

这条直接决定了 Nimbo 的代理设计是安全的：

- **HTTP CONNECT / SOCKS5 隧道只转发 TCP，不改写 Host** → 签名不受影响 ✔
- **"反向代理 + 路径重写"型方案会破坏签名** → 明确不支持，文档里要写死

### 1.2 301 不是错误，是"你该换 region 了"

region 填错时，S3 语义是返回 `301 PermanentRedirect` + 响应头 `x-amz-bucket-region: ap-guangzhou`。
客户端应当读这个头自动纠正 region 并重签一次，而不是把 301 当成"连接失败"。MinIO 等自建实现通常不返回该头，因此要允许 region 为空。

---

## 2. 为什么第三方通用 S3 应默认 path-style

| 理由 | 说明 |
|---|---|
| 不依赖泛解析 DNS | 自建环境经常只有 `nas.local` 或裸 IP，没有条件配 `*.nas.local` |
| 不依赖通配证书 | 内网多为自签单域名证书，vhost 必然证书错误 |
| IP + 端口可用 | `192.168.1.20:9000` 是最常见的 MinIO 入口形态 |
| 桶名更宽松 | 带 `.`、大写、下划线的历史桶也能访问 |
| 网关/反代更简单 | 一条 location 转发，不用为每个桶签发证书 |
| 调试直观 | 一个 endpoint 打天下，日志里路径即桶名 |

---

## 3. 但 path-style 不是"通用"的：三个反例

| 反例 | 事实 | 影响 |
|---|---|---|
| **阿里云 OSS（S3 兼容接口）** | 官方兼容性文档：「OSS 仅支持虚拟托管访问方式，即 Bucket 名称必须作为子域名使用」，path-style 会报错并禁止访问 ※ | 只用 path-style 的客户端接不上 OSS |
| **AWS 新建 bucket** | 2020-09-30 之后创建的 bucket 只接受 virtual-hosted（path-style 弃用计划虽被推迟，但新桶已不支持） | 同一客户端要能切 vhost |
| **部分商业网关 / CDN 前置** | 只暴露 `bucket.gateway.tld` 入口，不接受路径形态 | 必须允许用户手工指定策略 |

> 反过来也有：腾讯云 COS 的 S3 兼容实践里，**必须开 `UsePathStyle=true`**，否则 SDK 生成的
> `bucket.cos.ap-guangzhou.myqcloud.com` 是错误域名，正确形态是 `cos.ap-guangzhou.myqcloud.com/bucket`。
>
> **同样是"国内头部云厂商"，OSS 要 vhost、COS 要 path——这就是"必须 auto，不能一刀切"的直接证据。**

### 3.1 建议的探测策略（方案层，非实现）

```
挂载配置：addressing = auto | path | vhost   （默认 auto）

auto:
  1) path-style  HEAD /{bucket}            → 2xx / 403(存在但无权限)  → 固化 path
  2) 若 301 且带 x-amz-bucket-region        → 纠正 region 后重试 path
  3) 若 DNS 解析失败 / 证书错误 / 400       → 切 vhost 重试一次
  4) vhost 成功 → 固化 vhost；两次都失败 → 保留双方错误分别展示
```

**成功即固化**：把最终策略写进挂载配置，后续不再每次探测，避免"能连上但每次都要多花一次 RTT"。

---

## 4. bucket 处理要点（客户端侧）

### 4.1 bucket 是挂载目标，不是目录

- 挂载 = `endpoint + bucket + 根前缀(可选) + 区域 + 寻址策略 + 代理`
- 文件树的第一层是 prefix，不是 bucket；多 bucket 要建多个挂载
- 跨 bucket 的移动/复制在 UI 上**不提供**（S3 语义上也不存在"同级"概念，只能 copy+delete 跨桶）

### 4.2 名称校验（保存前就拦）

| 规则 | 说明 |
|---|---|
| 长度 3–63 | 各家一致 |
| 只允许小写字母、数字、`-` | 大写会被拒；下划线在 vhost 下非法 |
| 不以 `-` 开头/结尾、不含连续 `..` | 否则 vhost 形态非法 |
| 不能是 IP 形式 | `192.168.1.1` 不能作为子域 |
| **不建议含 `.`** | vhost + HTTPS 必然证书不匹配；仅 path-style 下安全 |
| 腾讯云 COS 形如 `name-1250000000` | 必须带 APPID 后缀，少一位就 404 |
| OSS / S3 全局唯一 | 命名建议带环境与用途后缀 |

### 4.3 不要依赖 ListBuckets

- MinIO 的策略可以只授予单桶 `s3:GetObject/s3:ListBucket`，`ListAllMyBuckets` 被禁是常态
- SeaweedFS 需要 `Admin` 动作才能列/建桶
- 结果：**"列出所有桶"只能作为可选增强**，不能作为连接成功的判据

### 4.4 不要默认 CreateBucket

第三方多数由管理员预建桶；客户端自动建桶会引入 region、ACL、配额、命名冲突等一堆问题。产品上只做"输入已有 bucket"，建桶交给服务端控制台。

### 4.5 HeadBucket 的四种返回，要分开解释

| 返回 | 含义 | UI 文案方向 |
|---|---|---|
| `200` | 存在且有权 | 正常进入 |
| `301` + `x-amz-bucket-region` | region 不符 | 自动纠正，不打扰用户 |
| `403` | 桶存在但凭据无权（或签名错） | 「凭据无权访问该桶」+ 检查 AK/SK 与策略 |
| `404` | 桶不存在 / endpoint 指错 | 「未找到桶 X，请确认 Endpoint 与桶名」 |

### 4.6 region 的三种语义

| 实现 | region 取值 |
|---|---|
| AWS | 必须是真实 region（`us-east-1`、`ap-northeast-1`） |
| 阿里云 OSS | 必须是真实 region（`oss-cn-hangzhou`），填 `us-east-1` 会 `authorization header is malformed` |
| COS | `ap-guangzhou` 这类真实值 |
| MinIO / Garage / SeaweedFS | 任意占位（`us-east-1` 即可），但不能为空字符串 |
| Cloudflare R2 | `auto` |

→ 方案上：**region 允许留空，留空时用 `us-east-1` 兜底**，并在拿到 301 时用响应头覆盖。

---

## 5. 第三方实现的兼容性要点

### 5.1 签名与凭据

- 只做 **SigV4**（SigV2 已淘汰，Riak CS 之类老实现可放弃）
- 临时凭证需要 `x-amz-security-token`，STS 场景必须带上，否则 403
- 客户端时钟偏差 > 15 分钟直接 `RequestTimeTooSkewed`——连接测试要把这条单独提示

### 5.2 错误语义：状态码优先，Code 宽松匹配

- 各家 `Code` 文案并不统一（`NoSuchKey` / `NoSuchObject` / 简化字符串），**按 HTTP 状态码分支，Code 只做辅助匹配**
- `501 Not Implemented` 是第三方常见的"这个 API 我没做"（Garage 明确：未列出的 API 一律 501）
- `409` 在部分实现里表示"桶非空/冲突"，不要一律当"文件已存在"

### 5.3 列表（ListObjectsV2）

- 优先 V2；老实现（部分 Ceph 版本、Riak CS）只有 V1，需要 V1 兜底
- `max-keys` 上限 1000，超出有的实现报错而不是截断
- `delimiter=/` + `CommonPrefixes` 才是"目录"；分页要同时处理 `Contents` 与 `CommonPrefixes`
- `encoding-type=url` 的覆盖范围各家不一致（Garage 官方承认可能有编码 bug）→ **默认不带该参数，自己做 URL 解码**

### 5.4 分片上传

| 约束 | 值 |
|---|---|
| 最小分片 | 5 MB（最后一片除外）→ 小于就是 `EntityTooSmall` |
| 最大分片数 | 10000 → 决定单文件上限（10000 × 分片大小） |
| 分片大小 | 8 MB 起步；>80 GB 文件需 ≥ 8 MB 才不撞 10000 片 |
| ETag | 形如 `"md5-of-md5s-N"`，**不是文件 MD5** |
| Abort | 部分实现不真正清理分片，会产生隐性存储费用 |

### 5.5 复制 / 移动

- `x-amz-copy-source` 必须 **URL 编码**，且桶名与 key 是**分别编码再拼接**（中文名最容易踩）
- 单次 CopyObject ≤ 5 GB，超过必须 `UploadPartCopy`
- 无原子移动：copy 成功 → delete 源；任一步失败都要能回到"源还在"的状态

### 5.6 元数据与头部

- `x-amz-meta-*` 在 HTTP/2 下强制小写，读取时按小写匹配
- **`Content-Type` 不要传空串**：OSS 会返回 `InvalidArgument`，部分 SDK 直接抛异常；拿不到就回退 `application/octet-stream`
- 中文文件名：URL 编码用 RFC3986，`+` 必须编成 `%2B`（否则服务端当空格）

### 5.7 校验值

- ETag 只在"单段、未加密、无 SSE-KMS"时等于 MD5 → **不能作为通用校验依据**
- 新的 `x-amz-checksum-*` 系列支持度参差 → 探测不到就降级为「大小 + 修改时间」比对
- 面向用户展示时标注"校验方式"，不要谎称 SHA256

### 5.8 空目录与占位对象

- S3 无目录：0 字节、以 `/` 结尾的 key 是"目录占位符"，各实现对它的过滤策略不同
- SeaweedFS 有真实目录，且 `DeleteObject` 删的是"目录"（非 S3 行为）→ 删除确认文案要按实现能力提示
- 列目录时空 prefix 是否出现，取决于实现 → UI 上不要假设"一定有该节点"

### 5.9 一致性与并发

- 主流实现（AWS/MinIO/R2）已是强一致读后写
- 网关型（部分 Ceph 部署、自研网关）列表可能有秒级延迟 → **上传完成后本地先插一条乐观记录**，不要立刻重拉列表

### 5.10 权限最小化

| 场景 | 需要的动作 |
|---|---|
| 只读挂载 | `s3:ListBucket` + `s3:GetObject` |
| 可写挂载 | 追加 `s3:PutObject` / `s3:DeleteObject` |
| 移动/重命名 | 追加 `s3:GetObject`（copy 源）+ `s3:PutObject`（目标）+ `s3:DeleteObject`（源） |
| 分片 | 追加 `s3:AbortMultipartUpload` / `s3:ListMultipartUploadParts` |

→ 客户端**不应要求 admin / 建桶权限**；只读挂载在 UI 上直接标「只读」，删除按钮置灰。

---

## 6. 第三方 vs 厂商定制：差异矩阵

> 依据公开文档整理；标 `※` 的条目各家版本差异较大，接入前必须实测。

| 实现 | 寻址风格 | 签名 | bucket 形态 | 主要差异 / 坑 |
|---|---|---|---|---|
| **AWS S3** | vhost 为主；老桶支持 path | SigV4 | 全局唯一，DNS 兼容名 | 新桶只认 vhost；301 + `x-amz-bucket-region` |
| **MinIO** | path 默认；vhost 需 `MINIO_DOMAIN` + 泛解析 + 通配证书 | SigV4 | 管理员预建 | 通配证书不能跨层（`*.a.com` 不覆盖 `*.s.a.com`） |
| **Ceph RGW** | path + vhost 均支持（vhost 需 `rgw_dns_name`） | SigV4 | 管理员预建，支持多租户 | 版本间 API 覆盖差异大；`ListObjectsV2` 需确认版本 ※ |
| **Garage** | path + vhost 均支持 | SigV4 | 预建 | 无对象 ACL、无版本化、无 policy；未实现 API 一律 501；`encoding-type=url` 有已知 bug |
| **SeaweedFS** | path 为主 | SigV4（可关闭鉴权） | 预建 | 有真实目录；`DeleteObject` 会删目录；默认不校验凭据（危险） |
| **Cloudflare R2** | path + vhost 均可 | SigV4 | 账号级 endpoint，`region=auto` | 不支持 ACL / 版本化；不少 SDK 需强制 `path-style` |
| **Backblaze B2** | path 为主 ※ | SigV4 | 全局唯一 | S3 兼容层为"子集"，部分 header 忽略 |
| **阿里云 OSS（S3 兼容）** | **仅 vhost**（官方兼容性文档；实际仍以地域/Endpoint 实测为准 ※） | 原生 HMAC-SHA1；S3 口走 SigV4 | 全局唯一，region 必填真实值 | path-style 被拒；ACL 取值与 S3 不完全一致；`Content-Type` 空串报错 |
| **腾讯云 COS（S3 兼容）** | **path 为主**（需 `UsePathStyle=true`） | 原生 V5；S3 口走 SigV4 | `name-APPID` | 桶名必须带 APPID；region `ap-xxx` |
| **七牛 Kodo（S3 兼容）** | 以官方兼容清单为准 ※ | 原生上传凭证；S3 口 SigV4 | 预建 | 兼容子集有限，需逐 API 实测 |

**一句话**：第三方开源实现"风格可选、功能打折"；厂商定制实现"风格固定、字段有私货"。客户端要同时容得下这两类。

---

## 7. 兼容性陷阱清单（现象 → 根因 → 处理）

| # | 现象 | 根因 | 处理 |
|---|---|---|---|
| 1 | `certificate subject name does not match` | 桶名含 `.` + vhost + 通配证书 | 切 path-style |
| 2 | `getaddrinfo ENOTFOUND bucket.192.168.1.20` | IP 当 endpoint 还用 vhost | 检测 endpoint 是 IP → 强制 path |
| 3 | 阿里云 OSS 返回 400 / 拒绝访问 | path-style 不被支持 | 自动切 vhost |
| 4 | `SignatureDoesNotMatch`，AK/SK 无误 | 中间层改了 Host（反代/前缀重写） | 不支持此类反代；提示改用 CONNECT 隧道 |
| 5 | 偶发 `301 PermanentRedirect` | region 不匹配 | 读 `x-amz-bucket-region` 重签 |
| 6 | 添加存储时"列桶失败" | 无 `ListAllMyBuckets` 权限 | 不依赖 ListBuckets，改 HeadBucket |
| 7 | 中文文件名复制/移动 400 | `x-amz-copy-source` 未编码或编码两次 | 统一走"分段编码"工具函数 |
| 8 | 批量删除报 `MalformedXML` | 单次 DeleteObjects > 1000 | 分批 1000 |
| 9 | 上传图片变下载 | `Content-Type` 缺失/空串 | 按扩展名推断，回退 `application/octet-stream` |
| 10 | 下载校验永不过 | ETag ≠ MD5（分片/加密） | 校验降级为 size+mtime，UI 标注 |
| 11 | 大文件分片报 `EntityTooSmall` | 分片 < 5 MB | 分片固定 8 MB |
| 12 | 首次连接就 403 | 时钟偏差 > 15 min | 明确提示"检查系统时间" |
| 13 | 列表文件名乱码 | `encoding-type=url` 解码不一致 | 不带该参数，自行解码 |
| 14 | 删了"文件"结果整目录没了 | SeaweedFS 的目录语义 | 删除前按实现能力二次确认 |
| 15 | 上传完立刻刷新看不到 | 网关层列表延迟 | 先乐观插入本地记录 |

---

## 8. 对 Nimbo 的落地结论（方案参数，不改代码）

### 8.1 挂载配置（S3 类型）

| 字段 | 必填 | 默认 | 说明 |
|---|---|---|---|
| Endpoint | 是 | — | 不含协议头，自动尝试 HTTPS；内网允许 HTTP |
| Region | 否 | 空 → `us-east-1` | 收到 301 时自动纠正并回写 |
| Bucket | 是 | — | 保存前做 §4.2 校验 |
| 根前缀 | 否 | `/` | 文件树根；显示为"挂载内根目录" |
| 寻址策略 | 是 | `auto` | auto / path / vhost，探测成功后固化 |
| 只读挂载 | 否 | 关 | 开启后隐藏写操作，能力位同步 |
| 代理 | 否 | 关 | 一对一生效，详见 v1.2 代理方案 |

### 8.2 连接探测顺序（替代"列桶"）

```
HeadBucket           → 判定存在性与权限（读 301 的 region 头）
ListObjectsV2(1)     → 判定 ListBucket 权限 + 确认前缀可读
GetBucketLocation    → 可选；403/501 直接忽略，不作为失败
```

### 8.3 能力位（探测即所得）

| 能力 | 判定方式 | 缺失时的降级 |
|---|---|---|
| 分片上传 | `CreateMultipartUpload` 一次空试探 | 单段上传，>5 GB 直接禁用并提示 |
| 服务端复制 | `CopyObject` 自我复制一次 | 降级为"下载后上传"，UI 标注更慢 |
| 校验值 | 响应是否带 `x-amz-checksum-*` / ETag 是否 32 位 hex | 退化为 size+mtime |
| 容量 | 一般不提供 | 显示「未知」，不留空进度条 |

### 8.4 与代理的相互作用

- CONNECT 隧道 / SOCKS5 透传**不改 Host** → 签名安全，可放心叠加
- 若用户的代理是"HTTP 反向代理 + 路径改写"，签名必然失败 → 文档明确不支持，并在错误文案里点明

### 8.5 传输参数

| 参数 | 值 | 理由 |
|---|---|---|
| 分片大小 | 8 MB | ≥5 MB 下限，10000 片可撑到 ~78 GB |
| 并发分片 | 4 | 兼顾小带宽与网关限流 |
| 单次删除 | ≤1000 key | 硬限制 |
| 大文件复制 | >5 GB 走 UploadPartCopy | CopyObject 上限 |
| 重试 | 幂等操作 3 次指数退避；非幂等先查后重试 | 避免重复写 |

---

## 9. 验收用例（接入前必须跑通）

- [ ] MinIO（path-style，IP+端口，自签证书）连接成功
- [ ] MinIO 开启 `MINIO_DOMAIN` 后 vhost 可用，auto 能选中 vhost
- [ ] 阿里云 OSS S3 兼容口：path 失败后自动切 vhost 成功
- [ ] 腾讯云 COS：`bucket-APPID` + path-style 成功
- [ ] R2：`region=auto`，path-style 成功
- [ ] 桶名含 `.` 的桶在 path 下可读写，切 vhost 时给出明确证书错误
- [ ] region 故意填错 → 自动 301 纠正，用户无感
- [ ] 中文文件名：列表、上传、下载、重命名、跨目录复制全通过
- [ ] 6 GB 文件分片上传 + 中断续传 + 校验（ETag 非 MD5 时不误报）
- [ ] 一次删 1500 个对象 → 自动分批，无 `MalformedXML`
- [ ] 只读账号只给 List+Get → 挂载正常，写操作置灰而非报错

---

## 10. 需要产品确认的两个点

1. **寻址策略是否暴露给用户**
   建议：默认 `auto`，高级里可手动指定 —— 因为 OSS 这类"只能 vhost"的场景，自动探测已经能覆盖；但企业内网有多种网关时，手工兜底更省事。

2. **是否支持"浏览多个 bucket"**
   建议：不支持。一个挂载一个 bucket，是"网盘"的产品直觉（用户看到的是文件夹），也避开跨桶移动的语义坑。想要"桶列表"的用户，本质是在用管理控制台，不是网盘。
