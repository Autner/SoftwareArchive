# SoftwareArchive 个人软件资源库管理工具

![CI](https://github.com/Autner/SoftwareArchive/actions/workflows/ci.yml/badge.svg)

一套用 bash 编写的 macOS 个人软件资源库管理工具：把散落各处的软件安装包、源码、文档统一收录进本地档案库，追踪 GitHub Release 更新，自动校验完整性，并生成可检索的资源索引。

## 核心特性

- **收录与更新**：手动录入本地安装包，或输入 GitHub 仓库地址自动查询 Release、下载安装包并按平台归档
- **多平台归档**：Windows / macOS / Linux / Android / iOS 安装包分目录保存，含 SHA256 校验与定期完整性验证
- **使用手册制度**：每个软件必须完成 `使用手册.md` 才算收录完成，工具内建检查闭环
- **源码保全（Maintain）**：为已收录的开源软件维护本地 Git mirror，并生成可独立恢复的 `.bundle`
- **私有仓库支持**：设置了 `GITHUB_TOKEN`（或本机已 `gh auth login`）时可下载私有仓库的 Release 附件
- **断点续传**：安装包下载支持断点续传与自动重连；Git 归档有恢复检查点
- **纯 bash 实现**：兼容 macOS 自带的 bash 3.2，除 Git 外零依赖

## 安装（macOS）

从 [Releases](../../releases/latest) 下载 DMG，打开后把「软件档案管理.app」拖入「应用程序」即完成安装。首次打开若提示无法验证开发者：右键应用 →「打开」。

**代码与数据分离**：App 包内只包含工具代码；档案数据保存在家目录 `~/SoftwareArchive`（`Library` 软件档案、`Work` 配置与缓存）。升级就是用新版 App 覆盖旧版——数据毫发无损，卸载重装亦然。可用环境变量 `SA_HOME` 指定其他数据目录；以源码方式运行时同样支持设置 `SA_DATA_HOME` 实现代码与数据分离。

也可以直接使用源码：

```sh
git clone https://github.com/Autner/SoftwareArchive.git
cd SoftwareArchive
bash Work/Scripts/Init.sh     # 首次初始化
```

之后双击 `启动软件档案管理.command` 打开主菜单。

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

详细工作流程见 [Library/资源库管理说明.md](Library/资源库管理说明.md)，快速上手见 [README_先读我.md](README_先读我.md)。

## 从源码打包 macOS 应用

```sh
bash packaging/build-macos-app.sh
# 产物：packaging/output/SoftwareArchive-<版本>-macOS.dmg
```

## 说明

- 本工具面向 macOS（依赖 bash + 终端交互），暂无 Windows / Linux 版本
- 收录内容（Library 下的软件档案）属于本机私有数据，不在本仓库中
