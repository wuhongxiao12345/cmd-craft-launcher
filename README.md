# CCL — 单文件 Windows Minecraft 启动器

> 这是一个适合测试的 beta 版本。整个启动器只有一个 `ccl.bat`，双击即可运行，零依赖，直接在同目录创建 `ccl/` 和 `.minecraft/`。

> 该项目只负责启动器功能，不包含、不分发任何 Minecraft 游戏本体或资源文件。所有游戏资源均由使用者按官方方式获取。

## 版本信息

- 版本：`v1.0.3 Beta`
- 适用平台：Windows 10 1803+
- 运行方式：双击 `ccl.bat` 或在 cmd / PowerShell 中运行

## 主要功能

### 1. 版本管理
- 浏览 Mojang 官方版本列表
- 支持正式版、快照版、预发布版本
- 自动下载客户端、依赖库、natives、资源索引
- 可切换或删除已安装版本

### 2. Java 自动管理
- 自动检测系统 Java / 已安装 JDK / 配置中的 Java 路径
- 按游戏版本需求自动选用合适 Java
- 一键安装 Java 8 / 17 / 21
- 支持手动指定 `java.exe` 路径

### 3. 加载器支持
- Fabric
- Forge
- NeoForge
- 支持前台安装与后台安装

### 4. Mod 管理
- 支持 Modrinth 搜索
- 可按 Minecraft 版本 + 加载器过滤
- 中文关键词搜索（优先中文 API，失败自动回退到 Modrinth）
- 安装前二次校验 Mod 文件适配当前加载器
- 本地 Mod 开启/关闭/删除管理

### 5. 整合包导入
- 支持导入 Modrinth `.mrpack`
- 自动解析依赖和 overrides
- 自动识别 Fabric / Forge / NeoForge / Quilt 相关依赖

### 6. 稳定性与诊断
- 自动镜像回退（如 BMCLAPI）
- 批量下载与失败重试
- SHA1 校验
- 游戏崩溃时给出中文排查建议
- 调试模式可输出完整启动参数和日志

## 目录结构

```text
项目根目录/
├─ ccl.bat                 启动器本体
├─ ccl/                    启动器配置、缓存和 Java
│  ├─ config.json
│  ├─ cache/
│  ├─ logs/
│  └─ java/
├─ .minecraft/            游戏目录
│  ├─ versions/
│  ├─ libraries/
│  ├─ assets/
│  ├─ mods/
│  └─ instances/
└─ LICENSE
```

## 系统要求

- Windows 10 1803+
- 系统自带 `curl.exe` 和 `tar.exe`
- 建议不要把启动器放在中文路径或空格较多的目录中

## 快速开始

1. 下载 `ccl.bat`
2. 把它放到一个空目录
3. 双击运行
4. 在主菜单中选择：
   - `2`：版本管理
   - `3`：Java 管理
   - `5`：安装 Fabric / Forge / NeoForge
   - `1`：启动游戏

## 主菜单示例

```text
1. 启动游戏
2. 版本管理
3. Java 管理
4. Mod 管理
5. 安装 Mod 加载器
6. 整合包导入
7. 设置
8. 后台任务
0. 退出
```

## 说明

- 本启动器是一个单文件工具，便于测试与轻度使用
- 适合单机、离线模式和开发测试场景
- 由于是测试版，可能存在兼容性问题，欢迎通过 Issues 提交反馈

## 许可证

本项目使用 MIT License，详情见 [LICENSE](LICENSE)。

## 免责声明

本项目仅用于 Minecraft 启动辅助功能，使用者需自行遵守相关地区法律法规和 Mojang / Microsoft 的可用条款。启动器不负责也不分发任何游戏文件内容。

## 更新说明（Beta）

本版本以“更稳定、可用性更好、搜索体验更顺”的思路为主，重点覆盖：
- 更顺畅的启动流程
- 改进 Mod 搜索与筛选
- 更稳健的加载器安装与下载回退
- 更友好的错误提示和崩溃排查

如果你是第一次使用，建议先安装一个原版版本，再安装 Java 和对应加载器。
