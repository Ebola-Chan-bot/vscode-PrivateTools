<#
.SYNOPSIS
	启动 VSCode-OSS 开发实例（Code - OSS Dev）。

.DESCRIPTION
	定位工作区中的 vscode 源码目录，调用其官方启动脚本 scripts\code.bat。
	code.bat 会自动执行预启动流程（下载 Electron、编译、准备内置扩展），
	然后以开发模式启动 Code - OSS。

	首次启动耗时较长（需要编译），属正常现象。

.PARAMETER 源码目录
	vscode 源码根目录。缺省时，依次尝试：
	1. 本脚本所在目录的同级目录 vscode（即工作区布局 vscode-PrivateTools/../vscode）
	2. 环境变量 VSCODE_源码目录 指定的路径

.PARAMETER 跳过预启动
	设置后跳过编译与 Electron 下载（等价于 VSCODE_SKIP_PRELAUNCH=1），
	仅在已编译过、希望快速重启时使用。

.PARAMETER 剩余参数
	其余所有参数原样透传给 Code - OSS，例如：
		.\启动OSS.ps1 --disable-extensions
		.\启动OSS.ps1 --inspect-brk=5870

.EXAMPLE
	.\启动OSS.ps1
	完整预启动后打开 VSCode-OSS 开发实例。

.EXAMPLE
	.\启动OSS.ps1 -跳过预启动 -剩余参数 '--disable-extensions'
	跳过编译，快速重启并不加载任何扩展。
#>
[CmdletBinding()]
param(
	[string]$源码目录,

	[switch]$跳过预启动,

	[Parameter(ValueFromRemainingArguments = $true)]
	[string[]]$剩余参数
)

$ErrorActionPreference = 'Stop'

# 定位 vscode 源码根目录
$候选目录 = @()
if ($源码目录) {
	$候选目录 += $源码目录
}
if ($env:VSCODE_源码目录) {
	$候选目录 += $env:VSCODE_源码目录
}
$候选目录 += Join-Path $PSScriptRoot '..\vscode'

$源码根 = $null
foreach ($目录 in $候选目录) {
	$启动脚本 = Join-Path $目录 'scripts\code.bat'
	if (Test-Path -LiteralPath $启动脚本) {
		$源码根 = (Resolve-Path -LiteralPath $目录).Path
		break
	}
}

if (-not $源码根) {
	Write-Error "未找到 vscode 源码目录（需要其中存在 scripts\code.bat）。请使用 -源码目录 参数或设置环境变量 VSCODE_源码目录 指定。"
}

$启动脚本路径 = Join-Path $源码根 'scripts\code.bat'

if ($跳过预启动) {
	$env:VSCODE_SKIP_PRELAUNCH = '1'
	Write-Host '已设置 VSCODE_SKIP_PRELAUNCH=1，跳过编译与 Electron 下载。'
}

Write-Host "源码目录：$源码根"
Write-Host '正在启动 VSCode-OSS 开发实例……'
if (-not $跳过预启动) {
	Write-Host '（首次启动需下载 Electron 并编译，耗时较长，请耐心等待）'
}

# 透传剩余参数并同步退出码
& $启动脚本路径 @剩余参数
exit $LASTEXITCODE
