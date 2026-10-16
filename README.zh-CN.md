# Antigravity Helper

[English](README.md)

面向 Windows 本机 Codex 环境的协作 Skill，用于协调 Codex 原生子代理与官方 Antigravity CLI。项目提供任务分工指引、实时模型与额度查询，以及支持结构化结果、独立运行记录、超时和取消的 PowerShell 调用脚本。

## 功能

- 根据任务要求选择主会话、Codex 原生子代理、Antigravity 或组合执行。
- 查询已安装 `agy` CLI 返回的模型 ID 和额度信息。
- 通过 UTF-8 NDJSON 标准输入传递任务，避免由 shell 解释任务文本。
- 使用明确的对话 ID 续接任务。
- 保留 CLI 事件、诊断和最终结果，供主会话独立验收。
- 识别缺失结果、模型不一致、异常退出、超时、取消和已检测到的权限拒绝。

本项目不提供模型访问权限，不分发 Antigravity 可执行文件，也不实现多账号池。通过 Antigravity 使用 Claude 与独立的 Claude Code 产品属于不同接入方式；本项目未集成独立 Claude Code。

## 环境要求

| 组件 | 要求 |
|---|---|
| 操作系统 | Windows 10 或 Windows 11 |
| 运行时 | PowerShell 7.4 或更高版本（`pwsh`） |
| 外部代理 | 已安装并完成认证的官方 Antigravity CLI |
| 主程序 | 支持用户级 Skill 的本机 Codex 环境 |
| 仅测试需要 | Python 3.10 或更高版本，无第三方 Python 依赖 |

初始真实接入验证使用 Antigravity CLI 1.3.5。CLI 输出格式和可用模型可能独立变化。调用脚本的 `plan` 模式不是操作系统级只读沙箱。

## 安装

先按照 [Antigravity 官方说明](https://antigravity.google/docs/cli/install/) 安装 CLI 并完成登录，再在 PowerShell 中执行：

```powershell
git clone https://github.com/weixiubo/antigravity-helper.git
Set-Location antigravity-helper
pwsh -NoProfile -File ./Install-Skill.ps1
```

安装脚本将运行所需文件复制到 `$CODEX_HOME/skills/antigravity-helper`；未设置 `CODEX_HOME` 时使用 `$HOME/.codex/skills/antigravity-helper`。脚本不修改 `AGENTS.md`、账号设置或 CLI 安装。默认不覆盖已有目录；指定 `-Replace` 后，先创建同级 ZIP 备份，再更新随包提供的文件；目录中的其他文件予以保留。

指定其他安装目录：

```powershell
pwsh -NoProfile -File ./Install-Skill.ps1 -Destination 'C:\Tools\codex-skills\antigravity-helper'
```

自定义目录需要由主程序配置为可发现的 Skill 位置。若新技能未显示，请刷新技能列表或重启 Codex。同一主程序中仅保留一份可发现的同名技能。

## 在 Codex 中使用

可以显式调用：

```text
使用 $antigravity-helper 独立审查这项修改，并核验返回的结论。
```

技能已开启自动匹配。Codex 可以在并行调查、明确子任务委派或跨模型复核有实际价值时选择它。是否触发取决于主程序和具体任务，不保证每条请求都自动使用。原生子代理仍受主程序提供的工具和权限约束。

## 直接调用脚本

以下示例从仓库根目录运行，要求 PowerShell 7.4 或更高版本：

```powershell
$workspace = (Get-Location).Path
$info = & ./scripts/Get-AntigravityInfo.ps1 -Action All -Workspace $workspace |
    ConvertFrom-Json
if ($info.status -ne 'SUCCESS') { throw '请检查查询结果后再选择模型。' }
$info.models | Format-Table id, name
$info.quota | Format-Table group, window, remaining, resets_at
```

选择查询结果中的一个 ID，然后提交任务：

```powershell
$modelId = Read-Host '输入当前模型列表中的 ID'
$run = & ./scripts/Invoke-Antigravity.ps1 `
    -Prompt '说明当前项目的用途，不要修改文件。' `
    -Model $modelId -Workspace $workspace -Mode plan | ConvertFrom-Json
$run | Select-Object status, reported_model, model_verified, response, run_directory
```

文件修改任务使用 UTF-8 任务文件和 `-Mode accept-edits`。主会话应检查返回状态，并独立核验实际改动后再接受结果。

参数、结果字段、续接和取消方式见 [脚本参考](docs/script-reference.md)。

## 验证

运行离线测试：

```powershell
python -m unittest discover -s tests -v
```

测试使用本地模拟 CLI，不需要 Google 账号，也不消耗模型额度。覆盖进程输入输出、结果分类、超时、取消、并发记录和安装行为。GitHub Actions 在 Windows 上运行同一套测试。

离线测试验证接入机制；实际模型权限、登录状态、额度和结果质量，需要使用自己的账号进行真实调用验证。详见 [测试说明](docs/testing.md)。

## 数据与服务访问

任务内容会发送到官方 CLI 选择的服务。运行记录可能包含任务文本、文件路径和模型回答，公开前应检查其内容。详见 [安全与数据处理说明](SECURITY.md)。

本项目是独立社区项目，并非 OpenAI 或 Google 官方产品。MIT 许可证仅覆盖本仓库的代码和文档，不授予服务访问权限，也不替代 [Antigravity 服务条款](https://antigravity.google/terms)。

## 贡献与许可

开发和评审要求见 [贡献指南](CONTRIBUTING.md)。本项目采用 [MIT 许可证](LICENSE)。
