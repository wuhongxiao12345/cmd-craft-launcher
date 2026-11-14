# CCL — 纯 CMD 的 Minecraft 启动器

> 单文件 `ccl.bat`，双击即用。零依赖（仅用 Windows 自带的 cmd / PowerShell / curl / tar），自动在所在目录创建 `ccl/` 与 `.minecraft/`。

> **版权提示**：本项目是启动器工具，不包含、不分发任何 Minecraft 游戏文件、材质、音效或商标资源；所有游戏文件均由使用者通过官方渠道获取。Minecraft 是 Mojang Studios / Microsoft 的商标，本项目与其无隶属、赞助或背书关系。使用者须自行确保拥有正版授权，并遵守 [Minecraft EULA](https://www.minecraft.net/eula) 与[商业使用指南](https://www.minecraft.net/usage-guidelines)。

**当前版本：v1.0.3-beta**

---

## 本版更新（1.0.3-beta）

- **全键盘操作**：所有菜单统一为 `↑↓` 移动、`Enter` 确认、`Esc / Q` 返回、数字键直选、`0` 返回；长列表自动分页，`PgUp/PgDn/Home/End` 可用。提示语统一为「按 Enter 继续」。
- **中文 Mod 搜索更稳**：麦块 API + Modrinth 双源合并、按 slug 去重；麦块接口参数失败会自动降级重试；两边都无结果且含中文时，用内置中英对照表转英文再搜一次（机械动力→create、合成表→jei、钠→sodium 等）。
- **安全修复**：整合包 `files[].path` 越界写入被拦截；实例名过滤 `..`、`.`、保留设备名，恶意整合包不再可能删除整个 `.minecraft`。
- **逻辑修复**：切换到 NeoForge 版本后加载器不再变成 vanilla；安装加载器时按真实 MC 版本推断（不再拿 `neoforge-21.1.264` 当 MC 版本）；切换/安装版本时清空旧实例目录；自动补装基础包不再覆盖当前选择；删除被继承的基础版本会被拒绝。
- **下载加固**：curl 全部启用 `--fail`（404 页面不会再被当成 jar）；支持 SHA512 校验；进度模式改为 HEAD 探测；NeoForge 官方源与镜像双向兜底；重试超时未完成的项会计入失败。
- **老版本兼容**：补齐 `virtual` / `map_to_resources` 资源展开、`${auth_session}` 变量与官方 log4j 配置。

---

## 特性

### 版本与加载器
- 官方接口拉取完整版本清单（900+ 版本），正式版按语义版本降序，快照/预发布按时间倒序排在其后
- 一键安装：客户端主文件 + 依赖库 + natives 解压 + 资源索引 + 全部资源对象
- 支持版本继承（`inheritsFrom`），Fabric / Forge / NeoForge 与整合包实例均可解析
- 已装版本切换、删除；删除前检查被继承关系，当前版本有保护
- Fabric / Forge / NeoForge 前台与后台安装；NeoForge 版本号与 MC 版本自动对应（21.1.x → 1.21.1，47.1.x → 1.20.1）

### 整合包
- 支持 **Modrinth `.mrpack`**
- 解析 `modrinth.index.json`：读取 `dependencies`，按 `files` 并行下载，应用 `overrides` 与 `client-overrides`
- 导入到 `.minecraft/instances/<包名>/`，自动切换游戏目录并按依赖询问安装加载器
- 文件路径经过规范化校验，越界路径会被拒绝

### Mod 管理
- **中文搜索**：麦块开放 API（含中文翻译的 Mod 库）+ Modrinth 双源合并；中文关键字直接搜本体（“机械动力” → Create、“合成表” → JEI）
- **降级链**：麦块不可用或无结果 → Modrinth 原词 → 中文转英文关键词
- 按当前 MC 版本 + 加载器过滤，安装前二次校验文件的 `loaders` 字段
- 本地 Mod：方向键选择，`Enter` 启用/禁用，`D` 删除，`F` 筛选
- 原版（vanilla）下进入 Mod 管理会明确提示先安装加载器

### Java 管理
- 自动检测（配置指定 → `ccl/java` 各版本 → 系统 PATH），**按版本需求挑选**：在所有候选中选刚好满足要求的最低版本（1.17 不会再被拉到 Java 21）
- 一键安装 JDK 8 / 17 / 21（清华 TUNA 镜像优先，失败回退 Adoptium 官方源），按系统架构下载 x64/x86
- 安装 JDK 不再改写 `JavaPath`，切换版本后仍按需选 Java

### 网络与下载
- **镜像回退**：Forge / NeoForge Maven 官方源优先、BMCBL 兜底；Mojang meta 与资源站自动生成镜像备选
- 自适应多线程：按 CPU 逻辑核心数计算并发（`cores × 4`，钳制 8~32）
- 进度条：单文件显示 `字节/总量 + 速度`，批量显示 `完成数/总数 + 总字节 + 速度`
- 健壮性：SHA1/SHA512 校验、HTTP 状态识别（`curl --fail`）、空文件检测、失败重试、总超时 1800s + 停滞检测 90s

### 后台任务
- 版本安装、加载器安装均可后台执行，立即返回主菜单
- 主菜单显示后台任务状态；「8. 后台任务」查看详情、清除记录（用启动时间防止 PID 复用误判）

### 崩溃诊断与调试
- 游戏异常退出时分析 `logs/latest.log` 并给出中文建议：Java 版本过低、内存不足、依赖缺失、位数不匹配、显卡驱动、Mod 冲突等
- 调试模式：打印完整启动参数（classpath 逐条展开），游戏输出实时显示并写入 `ccl/logs/launch_<时间戳>.log`

### 其他
- **离线登录**：`MD5("OfflinePlayer:名称")` 生成 v3 UUID
- **默认中文**：首次启动写入 `options.txt` 的 `lang:zh_cn`，已有语言设置时保留玩家选择
- 32/64 位自适应：规则判断、natives 选择、JDK 下载均按真实架构
- PCL2 目录兼容：读取 `PCL.ini` 的 `VersionArgumentIndie`，识别 `versions/<id>/<id>-natives` 等布局
- 启动参数：全屏、演示模式、额外游戏参数、额外 JVM 参数、内存、窗口尺寸、独立游戏目录

---

## 使用

1. 下载 `ccl.bat`
2. 双击运行（或在 cmd 中执行 `ccl.bat`）
3. 首次运行自动创建 `ccl/`（配置、缓存、JDK）与 `.minecraft/`（游戏数据）

### 操作方式

| 按键 | 作用 |
|---|---|
| `↑` `↓` | 上下选择 |
| `Enter` | 确认 / 进入 / 执行 |
| `Esc` 或 `Q` | 返回上一级 |
| `0` | 返回 |
| `1`–`9` | 直接选择对应项 |
| `PgUp` `PgDn` `Home` `End` | 长列表翻页 / 跳转 |
| `D` / `F` | 删除 / 筛选（仅对应菜单显示） |

文本输入（玩家名、内存、关键词、路径）仍为输入行，直接键入后回车。

### 首次使用建议

```
2 → 安装一个版本（如 1.21.1）
3 → 安装 Java 21（或启动时自动安装）
7 → 设置玩家名、内存
1 → 启动游戏
```

---

## 目录结构

```
项目根/
├─ ccl.bat                 启动器本体
├─ ccl/
│  ├─ config.json          配置
│  ├─ cache/               下载缓存、临时文件、后台任务日志
│  ├─ logs/                调试模式启动日志（launch_<时间戳>.log）
│  └─ java/                自动安装的 JDK（jdk8 / jdk17 / jdk21）
└─ .minecraft/
   ├─ versions/            各版本（含 <id>-natives 或 natives/）
   ├─ libraries/           依赖库
   ├─ assets/              资源（indexes + objects + virtual）
   ├─ mods/                全局 Mod
   └─ instances/           整合包实例
```

### 版本隔离

- 默认不隔离（Mod 放 `.minecraft/mods`）
- 若版本目录内已存在 `mods/saves/resourcepacks/config` 结构，或 `PCL.ini` 中 `VersionArgumentIndie=1`，则自动按隔离模式使用 `versions/<id>/` 作为工作目录
- 在版本管理中切换/安装版本会回到默认游戏目录；整合包实例目录需从「6. 整合包导入 → 已导入实例」重新选择

---

## 配置项（`ccl/config.json`）

| 字段 | 说明 | 默认 |
|---|---|---|
| `PlayerName` | 离线登录玩家名 | `Player` |
| `JavaPath` | 指定 java.exe 路径 | 空（自动检测） |
| `SelectedVersion` | 当前版本 id | 空 |
| `SelectedLoader` | `vanilla` / `fabric` / `forge` / `neoforge` | `vanilla` |
| `SelectedLoaderVersion` | 加载器版本号 | 空 |
| `MemoryMB` | 内存（512–65536） | `2048` |
| `WindowWidth` / `WindowHeight` | 窗口尺寸 | `854` / `480` |
| `GameDir` | 独立游戏目录（整合包实例用） | 空 |
| `JvmArgs` | 额外 JVM 参数 | 空 |
| `ExtraGameArgs` | 额外游戏参数 | 空 |
| `Fullscreen` | 全屏启动 | `false` |
| `DemoMode` | 演示模式 | `false` |
| `DebugMode` | 调试模式 | `false` |
| `VersionIsolation` | 版本隔离（`PCL.ini` 优先） | `false` |

配置写入是**原子**的（先写 `.tmp` 再替换，保留 `.bak`）；文件损坏时自动备份为 `.corrupt` 并回退默认值；数值字段读取时自动钳制。

---

## 命令行自检

```bat
ccl.bat --test manifest            :: 版本清单连通性
ccl.bat --test resolve 1.20.1      :: 版本解析
ccl.bat --test dryrun 1.20.1       :: 打印完整启动命令，不启动
ccl.bat --test findjava            :: Java 检测
ccl.bat --test uuid Player         :: 离线 UUID
ccl.bat --test isolation 1.20.1    :: 隔离目录判定
ccl.bat --test importpack "<路径>"  :: 导入整合包（非交互）
```

---

## 常见问题

**Q：启动卡在下载进度不动？**
A：多为源站不可达。启动器已内置镜像回退、HEAD 探测与失败重试；若仍失败，换网络或在能访问官方 Maven 时重试。

**Q：NeoForge 报 `ClassNotFoundException: cpw.mods.bootstraplauncher.BootstrapLauncher`？**
A：依赖库未补齐。重新执行「5 → 安装 NeoForge」，会经镜像预置依赖。

**Q：路径含 `[ ]` 方括号（如整合包名）报“路径不存在”？**
A：v1.0.1 起已改用 `-LiteralPath`，不会再当通配符处理。

**Q：想用已有 PCL2 的 `.minecraft`？**
A：直接把 `ccl.bat` 放到 PCL2 根目录即可，会读取 `PCL.ini` 并识别既有版本/隔离结构。

**Q：中文搜 Mod 搜不到？**
A：现在会同时查麦块与 Modrinth，并在需要时把中文名转英文再搜。若仍无结果，换更通用的关键词（如 `jei`、`sodium`）。

**Q：搜索结果装不上或版本不对？**
A：搜索按当前 MC 版本 + 加载器过滤，安装前还会校验 `loaders`。提示“该文件不适用于 xxx”说明该 Mod 确实没有当前加载器版本（例如 Sodium 只有 Fabric/Quilt 版，Forge 上应找 Embeddium）。

---

## 数据来源

- 版本清单与资源：`piston-meta.mojang.com`、`resources.download.minecraft.net`
- Fabric：`meta.fabricmc.net`
- Forge：`files.minecraftforge.net`
- NeoForge：`maven.neoforged.net`
- Mod：`api.modrinth.com`
- Mod（中文搜索）：[麦块开放 API](https://api.minekuai.cn)
- JDK：清华 TUNA / Adoptium
- 镜像：BMCBL（`bmclapi2.bangbang93.com`）

---

## 版权与免责声明

**1. 工具性质**：本项目为开源的 Minecraft 启动辅助工具，仅实现版本清单解析、文件下载调度、Java 环境管理与命令行参数拼装等通用技术功能，不修改、不破解、不绕过任何验证机制。

**2. 不包含游戏内容**：本仓库不包含、不托管、不分发任何游戏本体、客户端 jar、资源文件、音效、字体、材质或地图。运行所需文件由程序通过 Mojang 公开接口下载到本地，版权归 Mojang Studios 所有。

**3. 商标声明**："Minecraft"、"我的世界" 及相关标识为 Mojang Studios / Microsoft Corporation 的商标。本项目对其引用仅用于说明兼容性，不构成商标许可，也不表示获得授权、赞助或认可。

**4. 使用者义务**：使用即表示你确认已通过官方渠道合法持有 Minecraft 授权，使用行为符合 [Minecraft EULA](https://www.minecraft.net/eula)、[商业使用指南](https://www.minecraft.net/usage-guidelines) 及当地法律法规；不得用于商业运营、付费代登录、绕过正版验证等场景。

**5. 离线模式**：仅用于单机游玩、局域网调试与开发测试，使用者应自行确保场景合规；本项目不提供、不支持绕过正版认证接入正版服务器的手段。

**6. 第三方内容**：通过本启动器检索下载的 Mod、整合包、镜像内容与 JDK，其权利归各自作者/运营方所有，适用各自许可证；本项目仅提供技术通道，不对其合法性、安全性或可用性作担保。

**7. 免责条款**：本启动器按“现状”提供，不附带任何明示或默示担保。因使用或无法使用本启动器造成的任何直接或间接损失（包括存档损坏、账号异常、数据丢失、设备故障），作者与贡献者不承担责任。

**8. 权利主张与下架**：若权利人认为仓库内容侵犯其权益，请通过 Issues 附权利证明与具体位置，核实后将在合理期限内删除或修改。

**9. 非法律意见**：以上声明为作者善意说明，不构成法律意见；如有疑问请咨询专业人士。

---

## 许可

见 [LICENSE](LICENSE)。

## 作者吐槽

全文只有这句话是人类写的，deepseek太神奇了
