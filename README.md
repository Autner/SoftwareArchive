# SoftwareArchive 个人软件资源库管理工具

![CI](https://github.com/Autner/SoftwareArchive/actions/workflows/ci.yml/badge.svg)

一套用 bash 编写的 macOS 个人软件资源库管理工具：把散落各处的软件安装包、源码、文档统一收录进本地档案库，追踪 GitHub Release 更新，自动校验完整性，并生成可检索的资源索引。

## 核心特性

- **收录与更新**：手动录入本地安装包，或输入 GitHub 仓库地址自动查询 Release、下载安装包并按平台归档
- **记录型软件（Record）**：只记一条备忘、不保存任何资源——适合商业软件等"只需要记住要下载"的常用软件，恢复新环境时照常进索引和搜索
- **批量检查更新**：一次查询全部 Maintain 软件的最新 Release，汇总「有新版 / 已最新 / 查询失败」并可直达更新向导
- **搜索档案**：按名称、备注、标签、状态、使用手册全文检索（不区分大小写）
- **软件生命周期状态**：`active / deprecated / migrated` 标记，失效软件不再参与更新检查
- **条目分享**：把单个软件导出为 `.saentry.zip`，他人一键导入入库
- **多平台归档**：Windows / macOS / Linux / Android / iOS 安装包分目录保存，含 SHA256 校验与定期完整性验证（含源码 bundle 的 `git bundle verify`）
- **使用手册制度**：每个软件必须完成 `使用手册.md` 才算收录完成（Record 仅记录条目除外），工具内建检查闭环
- **源码保全（Maintain）**：为已收录的开源软件维护本地 Git mirror，并生成可独立恢复的 `.bundle`
- **私有仓库支持**：设置了 `GITHUB_TOKEN`（或本机已 `gh auth login`）时可下载私有仓库的 Release 附件
- **断点续传**：安装包下载支持断点续传与自动重连；Git 归档有恢复检查点
- **并发保护**：交互菜单与批量操作互斥加锁，防止多实例写坏档案数据
- **双格式索引**：`资源索引.tsv`（纯 bash、机器可读）+ `资源索引.xlsx`；`-Action List` 可将 TSV 清单输出到 stdout
- **纯 bash 实现**：兼容 macOS 自带的 bash 3.2，除 Git 外零依赖；自带 40 项单元测试（`Work/Tests/run-tests.sh`）

## 界面预览

```text
────────────────────────────────────────────
  SoftwareArchive 1.1.0 · 软件档案管理
  已收录 11 · Maintain 8 · 仅记录 0 · 失效/迁移 1 · 待处理 0
────────────────────────────────────────────
> 收录新软件
  更新已有软件
  检查全部更新
  处理未完成任务 [0]
  搜索档案
  标记软件状态 / 修改更新策略
  维护源码镜像 (Maintain)
  导出 / 导入软件条目
  校验资源完整性 / 重建资源索引
  清理临时目录 / 打开 Library / 重新初始化
  退出
────────────────────────────────────────────
  ↑↓ 移动 · Enter 选择 · Esc 返回
```

## 安装（macOS）

从 [Releases](../../releases/latest) 下载 DMG，打开后把「软件档案管理.app」拖入「应用程序」即完成安装。首次打开若提示无法验证开发者：右键应用 →「打开」。

**代码与数据分离**：App 包内只包含工具代码；档案数据保存在家目录 `~/SoftwareArchive`（`Library` 软件档案、`Work` 配置与缓存）。升级就是用新版 App 覆盖旧版——数据毫发无损，卸载重装亦然。可用环境变量 `SA_HOME` 指定其他数据目录；以源码方式运行时同样支持设置 `SA_DATA_HOME` 实现代码与数据分离。

也可以直接使用源码：

```sh
git clone https://github.com/Autner/SoftwareArchive.git
cd SoftwareArchive
bash Work/Scripts/Init.sh     # 首次初始化：补建目录、配置、索引，并设置执行权限
```

之后日常使用：在访达中**双击 `启动软件档案管理.command`** 打开主菜单；或在终端运行 `bash Work/Scripts/SoftwareArchive.sh`。

> macOS 需要 Git（Maintain 功能）：未安装时在终端运行 `xcode-select --install` 安装 Xcode Command Line Tools 即可；其余功能零依赖。

**双击 .command 提示"无法验证开发者"怎么办**：从网络传输的文件会被 macOS 隔离标记。任选其一：

```sh
# 方法一：解除整个文件夹的隔离标记（推荐）
xattr -dr com.apple.quarantine /path/to/SoftwareArchive
```

或方法二：在访达中右键点 .command 文件 → 打开 → 再点"打开"。

## 数据备份

长期备份以下内容即可（其余目录均可重建，无需上传）：

```text
SoftwareArchive/
├── Library/          # 全部软件档案（最重要）
└── Work/
    ├── Scripts/      # 工具源码（也可随时从 GitHub 重新获取）
    └── Config/       # 全局配置
```

`Work/Repositories`（Git 镜像）、`Work/Downloads`、`Work/Temp`、`outputs/` 均为可再生的缓存/导出，无需备份。

## 目录结构

```text
SoftwareArchive/
├── Library/               # 软件档案（每个软件一个目录：info.yml、使用手册、安装包）
├── Work/
│   ├── Scripts/           # 全部源代码
│   ├── Config/            # 全局配置 config.yml
│   ├── Repositories/      # Git mirror（可重建）
│   ├── Downloads/ Temp/   # 缓存（可重建）
├── packaging/             # macOS 应用打包脚本
└── 启动软件档案管理.command
```

详细工作流程与规则见 [Library/资源库管理说明.md](Library/资源库管理说明.md)，版本历史见 [CHANGELOG.md](CHANGELOG.md)。

## 从源码打包 macOS 应用

```sh
bash packaging/build-macos-app.sh
# 产物：packaging/output/SoftwareArchive-<版本>-macOS.dmg
```

## 说明

- 本工具面向 macOS（依赖 bash + 终端交互），暂无 Windows / Linux 版本
- 收录内容（Library 下的软件档案）属于本机私有数据，不在本仓库中
- 版本历史见 [CHANGELOG.md](CHANGELOG.md)，许可证为 [MIT](LICENSE)
