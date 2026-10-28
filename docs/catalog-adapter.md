# Lightroom 本地元数据适配器

Lightroom Photo Info 通过辅助功能读取当前照片，再查询 Lightroom 云端版已经保存在 Mac 上的元数据缓存。它不使用 Adobe 公共插件 API，也不调用云端 API。以下结构在 Lightroom 9.6 上验证；其他版本可能需要适配。

## 图库位置与只读访问

目前只发现默认位置 `~/Pictures/Lightroom Library.lrlibrary/` 下的图库。在其一级子目录中寻找同时存在的 `Managed Catalog.wfindex` 和 `Managed Catalog.mcat`，不硬编码账户目录名。自定义或外置图库路径尚未支持。

数据库使用 `SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX` 打开，设置 `query_only=ON` 和 200 ms busy timeout。连接由锁串行访问，查询结束后及时释放 statement，避免长事务影响 Lightroom checkpoint。

正常的 SQLite WAL 读取可以看到尚未 checkpoint 的最新已提交数据。不要使用 `immutable=1` 忽略 WAL，也不要只复制主数据库、遗漏 WAL 后再把副本视为当前状态。

适配器不修改 Lightroom 数据库、偏好、原片、XMP 或编辑参数，不读取账号凭据，不访问网络。

## 查询与字段

已验证的 schema 为 `wfindex` 1.0、`mcat` 1.2。首先根据完整文件名查找候选，例如虚构的 `SAMPLE_0001.DNG`：

```sql
SELECT docId, filename, assetId
FROM assets
WHERE filename = ? AND subtype IN ('image', 'video');
```

然后读取候选的当前文档版本：

```sql
SELECT r.content
FROM docs d JOIN revs r ON r.sequence = d.winningRevSequence
WHERE d.localDocId = ? AND d.deleted = 0;
```

`content` 有时被 SQLite 标记为 TEXT，但实际内容是 MessagePack 二进制。Swift 使用 `sqlite3_column_blob` 和 `sqlite3_column_bytes` 读取，不能直接按 UTF-8 字符串解码。

| 展示字段 | 文档路径 | 处理方式 |
| --- | --- | --- |
| 厂商、机型 | `xmp.tiff.Make`、`xmp.tiff.Model` | 合并设备名称，已知机型使用简名 |
| 镜头 | `xmp.aux.Lens` / `xmp.exifEX.LensModel` | 缺失时显示未记录 |
| 光圈 | `xmp.exif.FNumber` | 解析数值或分数 |
| 快门 | `xmp.exif.ExposureTime` | 解析数值或分数 |
| ISO | `xmp.exif.ISOSpeedRatings` | 使用记录值 |
| 实际焦距 | `xmp.exif.FocalLength` | 解析毫米数 |
| 等效焦距 | `xmp.exif.FocalLengthIn35mmFilm` | 记录值优先，已知机型可估算 |
| 拍摄时间 | `xmp.exif.DateTimeOriginal` | 保留记录的本地时刻和时区信息 |
| 原图尺寸 | `importSource.originalWidth` / `originalHeight` | 仅接受正整数 |

分数表示为 `[分子, 分母]`，不能用 APEX 编码的 `ApertureValue` 或 `ShutterSpeedValue` 替代。原图尺寸不使用 `develop.croppedWidth/croppedHeight` 兜底。GPS、序列号和账户字段不用于展示。

## 同名照片与来源确认

相机文件名会重复，不能把第一条同名记录当成当前照片。适配器先尝试用当前界面的相册上下文缩小范围：

```sql
SELECT albumId FROM albums WHERE name = ? AND hidden = 0;
SELECT 1 FROM album_asset_v2 WHERE assetId = ? AND albumId = ? LIMIT 1;
```

相册名必须来自当前界面，且只接受唯一的相册名匹配。不能从历史偏好推测当前相册。

如果仍有多个候选，只有全部展示字段都相同时才展示共同参数，并标注“同名照片的拍摄参数一致”。此时 `assetID` 为空，因为尚未确认唯一照片。任一展示字段不同都会拒绝匹配，包括拍摄时间、等效焦距和原图尺寸。

拍摄时间比较前只移除小数秒尾部的零。例如演示时间 `2026-01-15T12:00:00.28+08:00` 与 `2026-01-15T12:00:00.280+08:00` 等价；不会丢弃其他时间精度或时区。

主程序必须确认当前照片来自 Cloud。Local 模式或来源未知时，不会套用同名云端记录；Local 模式暂不支持。

## 未采用的当前照片识别方式

- `com.adobe.lightroomCC.plist` 中的 `Organize_lastSelection` 可能保留较早选择，不能作为实时事实。
- 已检查的 `wfindex.localState`、`mcat.localDocs` 和 `Managed Catalog.mru` 未提供可确认当前选图的接口。
- Lightroom 内部的 `HicGridSelectionManager.lua` 有选图相关方法，但未发现公开调用入口。

当前方案依赖 Accessibility 暴露的完整文件名、相册和 Cloud / Local 状态。Adobe 更新界面或缓存结构后，应重新验证这些约定。

## 实现与验证

核心代码见 [MetadataStore.swift](../Sources/MetadataStore.swift)、[MessagePack.swift](../Sources/MessagePack.swift) 和 [LightroomSelection.swift](../Sources/LightroomSelection.swift)。MessagePack 解码限制单文档 8 MiB、嵌套 64 层、单容器 100000 个元素，并拒绝不支持的类型。

离线测试使用临时合成数据库，覆盖唯一匹配、同名共识、参数冲突、相册范围、时间规范化、损坏数据和缓存失效。读取失败会返回明确状态，界面自动重试；短暂失败先保留带提示的旧快照，超时后清除旧参数。缓存策略与测量见 [performance.md](performance.md)。

开发诊断可能包含文件名、相册名、路径、拍摄时间和 assetID。报告问题时只分享脱敏后的必要片段，不上传图库数据库、原片或原始诊断文件。
