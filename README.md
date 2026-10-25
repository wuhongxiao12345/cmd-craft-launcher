# CCL — 纯 CMD 的 Minecraft 启动器

> 单文件 `ccl.bat`，双击即用。零依赖（仅用 Windows 自带的 cmd / PowerShell / curl / tar），自动在所在目录创建 `ccl/` 与 `.minecraft/`。

**当前版本：v1.0.1**

---

## 特性

### 版本管理
- 官方接口拉取完整版本清单（900+ 版本），**语义版本排序**：正式版按 `大版本.小版本.补丁` 降序，快照/预发布按时间倒序排在其后
- 一键安装：客户端主文件 + 依赖库 + natives 解压 + 资源索引 + 全部资源对象
- 支持版本继承（`inheritsFrom`），Fabric / Forge / NeoForge 版本与整合包实例均可解析
- 已装版本可切换、删除（当前版本有保护）

### 四种加载器
| 加载器 | 前台 | 后台 |
|---|---|---|
| Fabric | ✅ | ✅ |
| Forge | ✅ | ✅ |
| NeoForge | ✅ | ✅ |

- **Fabric**：从 `meta.fabricmc.net` 拉取该 MC 版本专属的 loader 列表，可选稳定版
- **Forge**：从 promotions 接口取 recommended / latest
- **NeoForge**：从镜像 Maven 元数据自动匹配版本（如 MC 1.21.1 → NeoForge 21.1.x），安装前经镜像**预置 70 个依赖库**，避免安装器逐个访问不可达源

### 整合包导入
- 支持 **Modrinth `.mrpack`**
- 解析 `modrinth.index.json`：读取 `dependencies`（minecraft / fabric-loader / forge / neoforge / quilt-loader）、按 `files` 并行下载客户端文件、应用 `overrides` 与 `client-overrides`
- 导入到 `.minecraft/instances/<包名>/`，自动切换游戏目录并按依赖询问安装加载器

### Mod 管理
- **Modrinth 搜索下载**：按当前游戏版本 + 加载器过滤
- **中文关键词支持**：内置 67 组中英词典（钠→sodium、小地图→xaeros minimap、合成表→JEI、匠魂→Tinkers' Construct、光影→iris、宝可梦→Cobblemon…），中文输入时**先搜英文命中本体，再搜中文原文**，多词短语自动补搜首词
- **模糊搜索**：输入部分名称即可（`sodi` → Sodium）
- **本地 Mod 管理**：`f关键词` 模糊筛选、`e序号` 启用、`d序号` 禁用/删除

### Java 管理
- 自动检测（配置指定 → `ccl/java` 下各版本 → 系统 PATH），**按版本需求挑选**：优先满足 `javaVersion.majorVersion`，而非死守配置
- 一键安装 JDK 8 / 17 / 21（清华 TUNA 镜像优先，失败回退 Adoptium 官方源），**按系统架构下载 x64/x86**
- 启动前自动校验，版本不足时提示安装

### 网络与下载
- **BMCBL 镜像回退**：为 NeoForge / Forge Maven、Mojang meta、资源站 URL 自动生成镜像备选，原站不可达时自动切换
- **自适应多线程**：按 CPU 逻辑核心数计算并发（`cores × 4`，钳制 8~32）
- **进度条**：单文件显示 `字节/总量 + 速度`，批量显示 `完成数/总数 + 总字节 + 速度`
- **健壮性**：SHA1 校验、空文件检测、失败重试、**主机可达性预检**（TCP 443，3s）、总超时 1800s + 停滞检测 90s

### 后台任务（非阻塞）
- 版本安装、Fabric/Forge/NeoForge 安装均可**后台执行**，立即返回主菜单
- 主菜单顶部实时显示 `后台任务: <标签> [进行中/已结束 xx%]`
- 菜单「8. 后台任务」查看详情、完成后清除记录

### 崩溃诊断
游戏异常退出时自动分析 `logs/latest.log`，输出中文排查建议：
- `UnsupportedClassVersionError` → Java 版本过低及对应要求
- `OutOfMemoryError` → 调大内存
- `NoClassDefFoundError` → 依赖缺失 / Mod 不匹配
- `UnsatisfiedLinkError / lwjgl` → 位数不匹配或显卡驱动
- `Pixel format / OpenGL` → 显卡驱动
- `Duplicate mods / Mixin apply failed` → Mod 冲突

并展示最近关键日志行、完整日志路径、崩溃报告目录。

### 其他
- **离线登录**：按 `MD5("OfflinePlayer:名称")` 生成 v3 UUID
- **默认中文**：首次启动写入 `options.txt` 的 `lang:zh_cn`
- **32/64 位自适应**：规则判断、natives 选择、JDK 下载全部按真实架构
- **PCL2 目录兼容**：读取 `PCL.ini` 的 `VersionArgumentIndie`，识别 `versions/<id>/<id>-natives` 等既有布局
- **启动参数**：全屏、演示模式、额外游戏参数、额外 JVM 参数、内存、窗口尺寸、独立游戏目录

---

## 使用

1. 下载 `ccl.bat`
2. 双击运行（或在 cmd 中执行）
3. 首次运行自动创建 `ccl/`（配置、缓存、JDK）与 `.minecraft/`（游戏数据）

### 主菜单

```
1. 启动游戏
2. 版本管理
3. Java 管理
4. Mod 管理 (搜索下载/本地管理)
5. 安装 Mod 加载器 (Fabric/Forge/NeoForge)
6. 整合包导入
7. 设置
8. 后台任务
0. 退出
```

### 首次使用建议流程

```
2 → 安装一个版本（如 1.20.1）
3 → 安装 Java 17（或启动时自动安装）
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
│  └─ java/                自动安装的 JDK（jdk8 / jdk17 / jdk21）
└─ .minecraft/
   ├─ versions/            各版本（含 <id>-natives 或 natives/）
   ├─ libraries/           依赖库
   ├─ assets/              资源（indexes + objects）
   ├─ mods/                全局 Mod
   └─ instances/           整合包实例
```

### 版本隔离

- 默认不隔离（Mod 放 `.minecraft/mods`）
- 若版本目录内已存在 `mods/saves/resourcepacks/config` 结构，或 `PCL.ini` 中 `VersionArgumentIndie=1`，则自动按隔离模式使用 `versions/<id>/` 作为工作目录

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
A：多为源站不可达。启动器已内置镜像回退与主机预检；若仍失败，换网络或在能访问 `maven.neoforged.net` 时重试（会自动补齐）。

**Q：NeoForge 报 `ClassNotFoundException: cpw.mods.bootstraplauncher.BootstrapLauncher`？**
A：依赖库未补齐。重新执行「5 → 安装 NeoForge」，会经镜像预置依赖。

**Q：`ResolutionException: Module minecraft contains package net.minecraft.server`？**
A：BootstrapLauncher 自管 minecraft 模块，classpath 不能再放原版 jar。v1.0.1 已修复。

**Q：路径含 `[ ]` 方括号（如整合包名）报"路径不存在"？**
A：v1.0.1 已改用 `-LiteralPath`，不会再把方括号当通配符。

**Q：想用已有 PCL2 的 `.minecraft`？**
A：直接把 `ccl.bat` 放到 PCL2 根目录即可，会读取 `PCL.ini` 并识别既有版本/隔离结构。

---

## 数据来源

- 版本清单与资源：`piston-meta.mojang.com`、`resources.download.minecraft.net`
- Fabric：`meta.fabricmc.net`
- Forge：`files.minecraftforge.net`
- NeoForge：`maven.neoforged.net`
- Mod：`api.modrinth.com`
- JDK：清华 TUNA / Adoptium
- 镜像：BMCBL（`bmclapi2.bangbang93.com`）

---

## 许可

见 [LICENSE](LICENSE)。
