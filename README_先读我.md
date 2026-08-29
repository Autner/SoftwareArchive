# SoftwareArchive 快速开始（macOS 版）

当前版本：`1.0.8`

## 第一次使用

1. 将整个 `SoftwareArchive` 文件夹放到任意目录（如 `~/Apps` 或 `~/Downloads`）。
2. macOS 需要 Git（Maintain 功能）：未安装时在终端运行 `xcode-select --install` 安装 Xcode Command Line Tools 即可；其余功能零依赖。
3. 打开「终端」（Terminal），执行：

```bash
cd /path/to/SoftwareArchive     # 进入解压后的目录
bash Work/Scripts/Init.sh       # 首次初始化：补建目录、配置、索引，并设置执行权限
```

4. 之后日常使用：在访达中**双击 `启动软件档案管理.command`** 打开主菜单。
5. 在主菜单选择「收录新软件」。

初始化完成后会自动补建 `Repositories`、`Downloads`、`Temp` 等工作目录。

## 双击 .command 提示"无法验证开发者"怎么办

从网络传输的文件会被 macOS 隔离标记。任选其一：

```bash
# 方法一：解除整个文件夹的隔离标记（推荐）
xattr -dr com.apple.quarantine /path/to/SoftwareArchive

# 方法二：在访达中右键点 .command 文件 → 打开 → 再点"打开"
```

之后即可正常双击启动。

## 最常用的规则

- `Library/软件名/info.yml` 是软件信息的唯一数据源。
- `Library/资源索引.xlsx` 由脚本自动生成，请勿手工维护。
- 新软件入库必须完成 `使用手册.md`，然后回到脚本确认。
- 软件更新必须检查使用手册，可选择「我已完成使用手册」或「本次检查后无需修改」。
- `Maintain` 会维护本地 Git mirror，并生成可独立恢复仓库的完整 `.bundle`。
- GitHub 正式 Release 默认通过 `/releases/latest` 自动查询，公开仓库无需配置令牌。
- 菜单和文本输入页统一按 `Esc` 回到上一步；向导会保留已填写的主要信息。
- Release 安装包采用逐文件处理：选择文件、指定平台、回到列表，完成全部映射后继续。
- 安装包、bundle 与归档二进制文件统一使用 SHA256 校验。
- 入库和更新先写入 `Work/Temp`，全部完成后再提交到 `Library`。
- 下载支持断点续传，网络中断自动重连；Git 归档有恢复检查点，异常退出后可安全重试。
- 主菜单「删除已有软件」会彻底删除该软件的 Library 目录、Git mirror 和未完成任务并重建索引，需输入软件名确认，不可恢复。

## 阿里云盘备份范围

长期备份以下内容：

```text
SoftwareArchive/
├── Library/
└── Work/
    ├── Scripts/
    └── Config/
```

`Work/Repositories`、`Work/Downloads`、`Work/Temp` 可重建，无需上传。

完整工作流程请查看 `Library/资源库管理说明.md`。
