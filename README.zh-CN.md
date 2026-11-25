# Antigravity Skill for Codex

[English](README.md)

从 Codex 向 Antigravity 委派任务。此 Windows Skill 通过官方 Antigravity CLI（`agy`）执行范围明确的任务、发起独立评审，并从 Codex 续接 Antigravity 会话。

## 功能

- 查询当前认证账号可用的模型 ID 和额度窗口。
- 提交 UTF-8 任务描述，按指定的会话 ID 续接任务。
- 核对 CLI 返回的模型 ID 和会话 ID 是否符合请求。
- 为每次调用保留独立记录，支持超时、取消和进程树清理。

Codex 负责定义任务范围和核验结果。本项目为独立维护的开源项目。Antigravity 的访问权限和模型可用性取决于官方 CLI 和用户账号。

## 环境要求

| 组件 | 要求 |
| --- | --- |
| 操作系统 | Windows 10 或 Windows 11 |
| 运行时 | PowerShell 7.4 或更高版本（`pwsh`） |
| Antigravity | 已安装并完成认证的官方 CLI |
| Codex | 支持用户级 Skill 的本机环境 |
| 离线测试 | Python 3.10 或更高版本，使用标准库 |

## 安装

按照 [Antigravity 官方文档](https://antigravity.google/docs/getting-started?tab=cli) 安装 CLI 并完成认证，然后在 PowerShell 中运行以下命令。

```powershell
git clone https://github.com/weixiubo/antigravity-for-codex.git
Set-Location antigravity-for-codex
pwsh -NoProfile -File ./Install-Skill.ps1
```

默认安装路径为 `$CODEX_HOME/skills/antigravity-for-codex`。未设置 `CODEX_HOME` 时，安装至 `%USERPROFILE%\.codex\skills\antigravity-for-codex`。

可以使用 `-Destination` 指定安装位置。目标目录须命名为 `antigravity-for-codex`，并位于 Codex 可发现的 Skill 路径中。

```powershell
pwsh -NoProfile -File ./Install-Skill.ps1 -Destination 'C:\Tools\codex-skills\antigravity-for-codex'
```

使用 `-Replace` 更新同名安装。安装器会校验暂存文件、生成 ZIP 备份并保留本地附加文件。

### 迁移已有安装

安装新版后，将原有 `antigravity-helper` 目录移出 Codex 的 Skill 搜索路径。如有本地附加文件，保留旧目录的备份。将已保存的提示和脚本更新为 `$antigravity-for-codex` 和新的安装路径，再开启新的 Codex 会话加载当前元数据。

## 在 Codex 中使用

```text
使用 $antigravity-for-codex 把当前补丁的评审委派给 Antigravity，并对照 diff 核验评审结论。
```

当任务与 Skill 描述匹配且主机支持发现 Skill 时，Codex 也可以自动选择它。

## 直接使用脚本

在仓库根目录查询模型列表和额度。

```powershell
$workspace = (Get-Location).Path
$info = & ./scripts/Get-AntigravityInfo.ps1 -Action All -Workspace $workspace |
    ConvertFrom-Json
if (-not $info.models) { throw '请检查模型查询结果后再选择 ID。' }
$info.models | Format-Table id, name
$info.quota | Format-Table group, window, remaining, resets_at
```

选择查询结果中的模型 ID。

```powershell
$modelId = Read-Host '请输入列表中的模型 ID'
$run = & ./scripts/Invoke-Antigravity.ps1 `
    -Prompt '评审当前补丁的正确性，保持文件原样。' `
    -Model $modelId -Workspace $workspace -Mode plan | ConvertFrom-Json
$run | Select-Object status, reported_model, model_verified, run_directory
```

使用 `-PromptFile` 传入 UTF-8 任务描述。获准修改文件时使用 `-Mode accept-edits`。检查运行结果，并核验工作目录中的实际改动。参数、会话续接和取消见 [脚本参考](docs/script-reference.md)。

## 验证

```powershell
python -m unittest discover -s tests -v
```

离线测试使用本地夹具验证执行、查询解析、并发和安装。真实调用的验证方法见 [测试说明](docs/testing.md)。

## 数据与许可证

Antigravity 任务会发送至官方 CLI 配置的服务。分享本地运行记录前，请检查并脱敏。详见 [安全与数据处理说明](SECURITY.md)。

参见 [贡献指南](CONTRIBUTING.md) 和 [MIT 许可证](LICENSE)。Antigravity 的服务访问受 [Antigravity 服务条款](https://antigravity.google/terms) 约束。
