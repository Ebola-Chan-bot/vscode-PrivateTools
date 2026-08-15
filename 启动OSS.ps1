<#
.SYNOPSIS
	启动 VSCode-OSS 开发实例（Code - OSS Dev）。

.DESCRIPTION
	定位工作区中的 vscode 源码目录，调用其官方启动脚本 scripts\code.bat。
	code.bat 会自动执行预启动流程（下载 Electron、编译、准备内置扩展），
	然后以开发模式启动 Code - OSS。

	首次启动耗时较长（需要编译），属正常现象。

	预启动流程需要 Node.js，node 按以下顺序解析（脚本本身绝不自动下载或
	安装任何 node）：
	1. -Node路径 参数（用户主动指定，可为任意外部或 VS 内置版本）
	2. 记忆文件 环境配置.json 中保存的路径
	3. PATH 中的 node
	4. 常见安装位置自动探测（含 VS 安装目录内的内置 node）
	5. 交互式询问用户，输入成功后持久记住，以后直接使用

	依赖安装阶段编译原生模块（node-gyp）还需要 Python 3，python 按以下顺序解析：
	1. -Python路径 参数
	2. PATH 中的 python
	3. 记忆文件中保存的路径
	4. 常见安装位置自动探测
	5. 交互式询问用户，输入成功后持久记住，以后直接使用

	脚本还会自检依赖完整性：若 node_modules 存在但缺乏 postinstall 状态文件
	（说明此前 npm install 半途失败），会先调用仓库官方脚本
	build/npm/fast-install.ts 完成修复安装（失败一次后自动清理全部
	node_modules 重试一次），再继续预启动。此外可用 -强制重装依赖 参数
	彻底重装（适用于依赖树被并发安装损坏的情形）。

	编译原生模块还需要 Visual Studio C++ 工具链。VS 2026 预览版的组件 ID 与
	node-gyp 硬编码检查的旧 ID 不一致（会导致 "missing any VC++ toolset"），
	脚本会自动探测 VS 安装与 Windows SDK 并设置 VCINSTALLDIR 等环境变量
	（node-gyp 官方支持的开发者命令提示符绕过方式）。VS 按以下顺序解析：
	1. -VS安装目录 参数
	2. 记忆文件中保存的路径
	3. vswhere（含 prerelease）与常见目录自动探测
	4. 交互式询问用户，输入成功后持久记住，以后直接使用
	脚本还会同步开发实例缺失的闭源扩展：Remote-SSH
	（ms-vscode-remote.remote-ssh）不在开源仓库中，OSS 开发实例默认无法安装。
	脚本启动前会自动在本机已安装的 VS Code（Insiders 优先、正式版兜底）扩展
	目录中查找同名扩展并复制到开发实例扩展目录——纯本地复制，不下载任何
	内容；已是最新版本则跳过，发现更新版本会先替换旧版本。

.PARAMETER Node路径
	node.exe 的完整路径或其所在目录（可为任意外部或 VS 内置版本）。
	校验通过后会写入记忆文件持久记住。

.PARAMETER Python路径
	python.exe 的完整路径或其所在目录。校验通过后会写入记忆文件持久记住。

.PARAMETER VS安装目录
	Visual Studio 安装根目录（如 C:\Program Files\Microsoft Visual Studio\18\Insiders）。
	校验通过后会写入记忆文件持久记住。

.PARAMETER 强制重装依赖
	设置后先删除仓库中全部 node_modules，再由预启动流程完整重装依赖。
	适用于依赖树损坏（如并发安装导致的文件缺失、编译报
	"Could not resolve" 找不到第三方包内部文件）时的彻底修复。

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

	[string]$Node路径,

	[string]$Python路径,

	[string]$VS安装目录,

	[switch]$强制重装依赖,

	[switch]$跳过预启动,

	[Parameter(ValueFromRemainingArguments = $true)]
	[string[]]$剩余参数
)

$ErrorActionPreference = 'Stop'

# ---------- 互斥锁：防止两个脚本实例并发安装损坏 node_modules ----------
$互斥锁 = New-Object System.Threading.Mutex($false, 'vscode启动OSS脚本')
try {
	$拿到锁 = $互斥锁.WaitOne(0)
}
catch [System.Threading.AbandonedMutexException] {
	# 上次的脚本实例被强行终止，没来得及释放锁——此时锁其实已经归我们所有，继续即可
	$拿到锁 = $true
	Write-Warning '检测到上次脚本被中断遗留的锁，已接管继续。'
}
if (-not $拿到锁) {
	Write-Error '已有另一个启动脚本实例在运行。并发执行会损坏依赖安装，请等它完成（或先结束它）再重试。'
}

# ---------- Node.js 解析（结果持久记忆到 环境配置.json） ----------
$记忆文件 = Join-Path $PSScriptRoot '环境配置.json'

function 读取记忆配置 {
	if (-not (Test-Path -LiteralPath $记忆文件)) { return $null }
	try {
		return Get-Content -LiteralPath $记忆文件 -Raw -Encoding utf8 | ConvertFrom-Json
	}
	catch {
		Write-Warning "记忆文件解析失败（$记忆文件）：$_"
		return $null
	}
}

function 保存记忆项([string]$键, [string]$值) {
	$配置 = 读取记忆配置
	if (-not $配置) {
		$配置 = [pscustomobject]@{ $键 = $值 }
	}
	elseif ($配置.PSObject.Properties.Name -contains $键) {
		$配置.$键 = $值
	}
	else {
		$配置 | Add-Member -NotePropertyName $键 -NotePropertyValue $值
	}
	$配置 | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $记忆文件 -Encoding utf8
	Write-Host "已持久记住 $键：$值"
}

function 校验Node路径([string]$路径) {
	$路径 = $路径.Trim().Trim('"').Trim("'")
	if (-not $路径) { return $null }
	if (Test-Path -LiteralPath $路径 -PathType Container) {
		$路径 = Join-Path $路径 'node.exe'
	}
	if (-not (Test-Path -LiteralPath $路径 -PathType Leaf)) { return $null }
	try {
		$版本 = & $路径 --version 2>$null
	}
	catch {
		return $null
	}
	if (-not $版本) { return $null }
	return [pscustomobject]@{ 路径 = $路径; 版本 = ([string]$版本).Trim() }
}

function 查找候选Node路径 {
	$结果 = [System.Collections.Generic.List[string]]::new()
	# 常见安装位置：nodejs 官方安装器
	foreach ($根 in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
		if (-not $根) { continue }
		$结果.Add((Join-Path $根 'nodejs\node.exe'))
	}
	# nvm-windows
	if ($env:APPDATA) {
		try {
			foreach ($路径 in (Resolve-Path -Path (Join-Path $env:APPDATA 'nvm\*\node.exe') -ErrorAction SilentlyContinue)) {
				$结果.Add($路径.Path)
			}
		}
		catch { }
	}
	# Visual Studio 安装目录内置的 node（含 prerelease/Insiders 版）
	foreach ($根 in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramW6432)) {
		if (-not $根) { continue }
		$模式 = Join-Path $根 'Microsoft Visual Studio\*\*\MSBuild\Microsoft\VisualStudio\NodeJs\node.exe'
		try {
			foreach ($路径 in (Resolve-Path -Path $模式 -ErrorAction SilentlyContinue)) {
				$结果.Add($路径.Path)
			}
		}
		catch { }
	}
	return ($结果 | Sort-Object -Unique)
}

function 解析Node路径 {
	# 解析顺序：-Node路径 参数 > 记忆 > PATH > 常见位置探测 > 交互式询问。
	# 脚本本身绝不自动下载或安装 node；除 VS 内置探测外，任何非内置的
	# node 都必须来自用户的主动指定或确认。
	if ($Node路径) {
		$校验 = 校验Node路径 $Node路径
		if (-not $校验) {
			Write-Error "-Node路径 指定的 node 不可用：$Node路径"
		}
		保存记忆项 'Node路径' $校验.路径
		return $校验.路径
	}

	$配置 = 读取记忆配置
	if ($配置 -and $配置.'Node路径') {
		$校验 = 校验Node路径 $配置.'Node路径'
		if ($校验) {
			Write-Host "使用记忆中的 node：$($校验.路径)（$($校验.版本)）"
			return $校验.路径
		}
		Write-Warning "记忆中的 node 路径已失效：$($配置.'Node路径')"
	}

	$命令 = Get-Command node -ErrorAction SilentlyContinue
	if ($命令) {
		$校验 = 校验Node路径 $命令.Source
		if ($校验) { return $校验.路径 }
	}

	# 常见安装位置自动探测（含 VS 内置）；优先与 -VS安装目录/记忆中的 VS
	# 同源的 node，保持工具链一致
	$候选 = @(查找候选Node路径)
	if ($候选.Count -gt 0) {
		$vs优先根 = $null
		if ($VS安装目录) { $vs优先根 = $VS安装目录 }
		elseif ($配置 -and $配置.'VS安装目录') { $vs优先根 = $配置.'VS安装目录' }
		if ($vs优先根) {
			$同源 = $候选 | Where-Object { $_ -like "*$(Split-Path $vs优先根 -Parent)*" } | Select-Object -First 1
			if ($同源) { $候选 = @($同源) + ($候选 | Where-Object { $_ -ne $同源 }) }
		}
		foreach ($路径 in $候选) {
			$校验 = 校验Node路径 $路径
			if ($校验) {
				Write-Host "使用自动探测到的 node：$($校验.路径)（$($校验.版本)）"
				保存记忆项 'Node路径' $校验.路径
				return $校验.路径
			}
		}
	}

	Write-Host ''
	Write-Host '未找到可用的 node（预启动流程需要 Node.js）。'
	Write-Host '注意：脚本不会自动下载安装 node，请自行安装后指定路径，或在 VS 安装中包含 Node.js 组件。'
	while ($true) {
		$输入 = Read-Host '请输入 node.exe 的完整路径或其所在目录（输入 q 退出）'
		if ($输入.Trim() -eq 'q') {
			Write-Error '未提供 node 路径，无法继续。'
		}
		$校验 = 校验Node路径 $输入
		if ($校验) {
			Write-Host "node 版本：$($校验.版本)"
			保存记忆项 'Node路径' $校验.路径
			return $校验.路径
		}
		Write-Warning "无法使用该输入（不存在或不是可运行的 node.exe）：$输入"
	}
}

function 校验Python路径([string]$路径) {
	$路径 = $路径.Trim().Trim('"').Trim("'")
	if (-not $路径) { return $null }
	if (Test-Path -LiteralPath $路径 -PathType Container) {
		$路径 = Join-Path $路径 'python.exe'
	}
	if (-not (Test-Path -LiteralPath $路径 -PathType Leaf)) { return $null }
	try {
		$版本 = & $路径 --version 2>&1
	}
	catch {
		return $null
	}
	$版本 = ([string]$版本).Trim()
	if ($LASTEXITCODE -ne 0 -or ($版本 -notmatch '^Python 3\.')) { return $null }
	return [pscustomobject]@{ 路径 = $路径; 版本 = $版本 }
}

function 查找候选Python路径 {
	$模式列表 = @(
		(Join-Path $env:LOCALAPPDATA 'Programs\Python\Python*\python.exe'),
		'C:\Python*\python.exe',
		'C:\Program Files\Python*\python.exe',
		'C:\Program Files (x86)\Python*\python.exe',
		'C:\ProgramData\Python*\python.exe',
		'D:\Python*\python.exe'
	)
	$结果 = @()
	foreach ($模式 in $模式列表) {
		try {
			$结果 += Resolve-Path -Path $模式 -ErrorAction SilentlyContinue |
				Select-Object -ExpandProperty Path
		}
		catch { }
	}
	return ($结果 | Sort-Object -Descending)
}

function 解析Python路径 {
	if ($Python路径) {
		$校验 = 校验Python路径 $Python路径
		if (-not $校验) {
			Write-Error "-Python路径 指定的 python 不可用：$Python路径"
		}
		保存记忆项 'Python路径' $校验.路径
		return $校验.路径
	}

	$命令 = Get-Command python -ErrorAction SilentlyContinue
	if ($命令) {
		$校验 = 校验Python路径 $命令.Source
		if ($校验) { return $校验.路径 }
	}

	$配置 = 读取记忆配置
	if ($配置 -and $配置.'Python路径') {
		$校验 = 校验Python路径 $配置.'Python路径'
		if ($校验) {
			Write-Host "使用记忆中的 python：$($校验.路径)（$($校验.版本)）"
			return $校验.路径
		}
		Write-Warning "记忆中的 python 路径已失效：$($配置.'Python路径')"
	}

	foreach ($候选 in 查找候选Python路径) {
		$校验 = 校验Python路径 $候选
		if ($校验) {
			Write-Host "使用自动探测到的 python：$($校验.路径)（$($校验.版本)）"
			保存记忆项 'Python路径' $校验.路径
			return $校验.路径
		}
	}

	Write-Host ''
	Write-Host '未找到可用的 Python（依赖安装阶段 node-gyp 编译原生模块需要 Python 3）。'
	Write-Host '如果 Python 安装在非常规位置，请直接输入其路径，脚本会持久记住。'
	while ($true) {
		$输入 = Read-Host '请输入 python.exe 的完整路径或其所在目录（输入 q 退出）'
		if ($输入.Trim() -eq 'q') {
			Write-Error '未提供 python 路径，无法继续。'
		}
		$校验 = 校验Python路径 $输入
		if ($校验) {
			Write-Host "python 版本：$($校验.版本)"
			保存记忆项 'Python路径' $校验.路径
			return $校验.路径
		}
		Write-Warning "无法使用该输入（不存在、不是可运行的 python.exe 或主版本低于 3）：$输入"
	}
}

function 获取VS版本([string]$VS根) {
	$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
	if (Test-Path -LiteralPath $vswhere) {
		try {
			$实例 = & $vswhere -all -prerelease -format json | ConvertFrom-Json
			foreach ($i in $实例) {
				if ((Resolve-Path -LiteralPath $i.installationPath -ErrorAction SilentlyContinue).Path -eq $VS根) {
					return $i.installationVersion
				}
			}
		}
		catch { }
	}
	# 从路径尾部的版本号目录推断（如 Visual Studio\18\Insiders）
	$父目录 = Split-Path $VS根 -Parent
	$段 = Split-Path $父目录 -Leaf
	if ($段 -match '^\d+$') { return "$段.0" }
	return $null
}

function 校验VS编译环境([string]$VS根) {
	$VS根 = $VS根.Trim().Trim('"').Trim("'").TrimEnd('\')
	if (-not $VS根 -or -not (Test-Path -LiteralPath $VS根 -PathType Container)) { return $null }
	# C++ 工具链：VC\Tools\MSVC 下有编译器；MSBuild 存在
	if (-not (Test-Path -LiteralPath (Join-Path $VS根 'VC\Tools\MSVC'))) { return $null }
	if (-not (Test-Path -LiteralPath (Join-Path $VS根 'MSBuild\Current\Bin\MSBuild.exe'))) { return $null }
	# Windows SDK：从注册表找安装根，取 Include 下最新版（需含 um\windows.h）
	$sdk根 = $null
	foreach ($键 in @('HKLM:\SOFTWARE\WOW6432Node\Microsoft\Microsoft SDKs\Windows\v10.0',
	                 'HKLM:\SOFTWARE\Microsoft\Microsoft SDKs\Windows\v10.0')) {
		$sdk根 = (Get-ItemProperty $键 -ErrorAction SilentlyContinue).InstallationFolder
		if ($sdk根) { break }
	}
	if (-not $sdk根) { return $null }
	$SDK候选 = Get-ChildItem -LiteralPath (Join-Path $sdk根 'Include') -Directory -ErrorAction SilentlyContinue |
		Sort-Object Name -Descending
	$SDK版本 = ($SDK候选 | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'um\windows.h') } |
		Select-Object -First 1 -ExpandProperty Name)
	if (-not $SDK版本) { return $null }
	$版本 = 获取VS版本 $VS根
	if (-not $版本) { return $null }
	return [pscustomobject]@{
		路径 = $VS根
		版本 = $版本
		SDK版本 = $SDK版本
	}
}

function 查找候选VS安装目录 {
	$结果 = @()
	foreach ($根 in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
		if (-not $根) { continue }
		$模式 = Join-Path $根 'Microsoft Visual Studio\*\*'
		try {
			$结果 += Resolve-Path -Path $模式 -ErrorAction SilentlyContinue |
				Select-Object -ExpandProperty Path
		}
		catch { }
	}
	# vswhere 可识别安装器注册的其他位置
	$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
	if (Test-Path -LiteralPath $vswhere) {
		try {
			$结果 += & $vswhere -all -prerelease -property installationPath
		}
		catch { }
	}
	return ($结果 | Sort-Object -Unique)
}

function 解析VS编译环境 {
	if ($VS安装目录) {
		$VS安装目录 = $VS安装目录.TrimEnd('\')
		if ($VS安装目录 -match 'VC(\\Tools)?(\\)?$') {
			$VS安装目录 = [regex]::Replace($VS安装目录, '\\VC(\\Tools)?(\\)?$', '')
		}
		$校验 = 校验VS编译环境 $VS安装目录
		if (-not $校验) {
			Write-Error "-VS安装目录 指定的 Visual Studio 编译环境不完整：$VS安装目录"
		}
		保存记忆项 'VS安装目录' $校验.路径
		return $校验
	}

	$配置 = 读取记忆配置
	if ($配置 -and $配置.'VS安装目录') {
		$vs根 = $配置.'VS安装目录'
		if ($vs根 -match '\\VC(\\Tools)?\\?') {
			$vs根 = [regex]::Replace($vs根, '\\VC(\\Tools)?\\?', '')
		}
		$校验 = 校验VS编译环境 $vs根
		if ($校验) {
			Write-Host "使用记忆中的 VS：$($校验.路径)（$($校验.版本)，SDK $($校验.SDK版本)）"
			return $校验
		}
		Write-Warning "记忆中的 VS 安装目录已失效：$($配置.'VS安装目录')"
	}

	foreach ($候选 in 查找候选VS安装目录) {
		$校验 = 校验VS编译环境 $候选
		if ($校验) {
			Write-Host "使用自动探测到的 VS：$($校验.路径)（$($校验.版本)，SDK $($校验.SDK版本)）"
			保存记忆项 'VS安装目录' $校验.路径
			return $校验
		}
	}

	Write-Host ''
	Write-Host '未找到完整的 Visual Studio C++ 编译环境（含 MSBuild 与 Windows SDK）。'
	Write-Host '如果 VS 安装在非常规位置，请直接输入其根目录，脚本会持久记住。'
	while ($true) {
		$输入 = Read-Host '请输入 Visual Studio 安装根目录（即含 VC\MSBuild 等子目录的路径，输入 q 退出）'
		if ($输入.Trim() -eq 'q') {
			Write-Error '未提供 VS 安装目录，无法继续。'
		}
		$校验 = 校验VS编译环境 $输入
		if ($校验) {
			Write-Host "VS 版本：$($校验.版本)，SDK：$($校验.SDK版本)"
			保存记忆项 'VS安装目录' $校验.路径
			return $校验
		}
		Write-Warning "该目录编译环境不完整（需 VC\Tools\MSVC、MSBuild\Current\Bin\MSBuild.exe 及已安装的 Windows SDK）：$输入"
	}
}

function 清理全部NodeModules([string]$源码根) {
	# BFS 枚举仓库中所有 node_modules 目录（不递归进入 node_modules 自身，
	# 跳过 .git/.build 等无关目录），然后用 Windows 原生 rmdir 多轮删除
	#（npm 损坏目录常出现 ENOTEMPTY/EPERM，重试可逐层剥除）。
	$队列 = [System.Collections.Generic.Queue[string]]::new()
	$队列.Enqueue($源码根)
	$目标列表 = [System.Collections.Generic.List[string]]::new()
	while ($队列.Count -gt 0) {
		$当前 = $队列.Dequeue()
		foreach ($目录 in (Get-ChildItem -LiteralPath $当前 -Directory -Force -ErrorAction SilentlyContinue)) {
			switch ($目录.Name) {
				'node_modules' { $目标列表.Add($目录.FullName) }
				'.git' { break }
				'.build' { break }
				'out' { break }
				default { $队列.Enqueue($目录.FullName) }
			}
		}
	}
	Write-Host "待清理的 node_modules 目录数量：$($目标列表.Count)"
	for ($轮次 = 1; $轮次 -le 3; $轮次++) {
		$残留 = @()
		foreach ($目录 in $目标列表) {
			if (Test-Path -LiteralPath $目录) {
				cmd /c rmdir /s /q "$目录" 2>$null
				if (Test-Path -LiteralPath $目录) { $残留 += $目录 }
			}
		}
		if (-not $残留) { Write-Host 'node_modules 已全部清理。'; return }
		Write-Host "第 $轮次 轮清理后仍有 $($残留.Count) 个目录残留，重试……"
		Start-Sleep -Seconds 3
	}
	Write-Error 'node_modules 清理失败，请关闭可能占用文件的进程（编辑器、终端、杀毒软件）后重试。'
}

function 预热编译头文件缓存([string]$源码根) {
	# node-gyp 编译原生模块前需要下载 Node/Electron 头文件（官方源在国内
	# 经常 ECONNRESET）。头文件存在 %LOCALAPPDATA%\node-gyp\Cache\<版本>\
	# 且 installVersion 标记达标时，node-gyp 会跳过下载。
	# 这里先尝试官方源、失败后回退国内镜像，把头文件预先放进缓存。
	$缓存根 = Join-Path $env:LOCALAPPDATA 'node-gyp\Cache'

	$必需标记 = 11
	$gyp包清单 = Join-Path $源码根 'build\npm\gyp\node_modules\node-gyp\package.json'
	if (Test-Path -LiteralPath $gyp包清单) {
		try {
			$必需标记 = [int]((Get-Content -LiteralPath $gyp包清单 -Raw | ConvertFrom-Json).installVersion)
		}
		catch { }
	}

	[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

	$npmrc列表 = @((Join-Path $源码根 '.npmrc'), (Join-Path $源码根 'remote\.npmrc'))
	foreach ($npmrc in $npmrc列表) {
		if (-not (Test-Path -LiteralPath $npmrc)) { continue }
		$内容 = Get-Content -LiteralPath $npmrc -Raw
		$dist = [regex]::Match($内容, 'disturl="?([^"\s]+)"?')
		$目标 = [regex]::Match($内容, 'target="?([\d\.]+)"?')
		if (-not ($dist.Success -and $目标.Success)) { continue }
		$distUrl = $dist.Groups[1].Value.TrimEnd('/')
		$版本 = $目标.Groups[1].Value

		$缓存目录 = Join-Path $缓存根 $版本
		$标记文件 = Join-Path $缓存目录 'installVersion'
		if ((Test-Path -LiteralPath $标记文件) -and (([int](Get-Content -LiteralPath $标记文件 -Raw).Trim()) -ge $必需标记) -and
			(Test-Path -LiteralPath (Join-Path $缓存目录 'x64\node.lib'))) {
			Write-Host "编译头文件缓存已就绪（$版本），跳过下载。"
			continue
		}

		# 官方源优先，失败回退国内镜像（npmmirror）
		if ($distUrl -match 'nodejs\.org') {
			$候选 = @("$distUrl/v$版本", "https://registry.npmmirror.com/-/binary/node/v$版本")
		}
		elseif ($distUrl -match 'electron') {
			$候选 = @("$distUrl/dist/v$版本", "https://registry.npmmirror.com/-/binary/electron/v$版本")
		}
		else { continue }

		$tar包名 = "node-v$版本-headers.tar.gz"
		$所用源 = $null
		foreach ($base in $候选) {
			$临时目录 = Join-Path $env:TEMP "gyp头文件-$版本"
			Remove-Item -LiteralPath $临时目录 -Recurse -Force -ErrorAction SilentlyContinue
			New-Item -ItemType Directory -Force -Path $临时目录 | Out-Null
			$tar路径 = Join-Path $临时目录 $tar包名
			$lib路径 = Join-Path $临时目录 'node.lib'
			try {
				Write-Host "尝试从头文件源下载 $版本：$base"
				Invoke-WebRequest -Uri "$base/$tar包名" -OutFile $tar路径 -UseBasicParsing -TimeoutSec 120
				Invoke-WebRequest -Uri "$base/win-x64/node.lib" -OutFile $lib路径 -UseBasicParsing -TimeoutSec 120
				$所用源 = $base
				break
			}
			catch {
				Write-Warning "源 $base 下载失败：$($_.Exception.Message)"
			}
		}
		if (-not $所用源) {
			Write-Error "无法从头文件源下载 $版本 的编译头文件，请检查网络后重试。"
		}

		# 解压并组装缓存目录（tar 包顶层目录形如 node-v<版本>）
		tar.exe -xzf $tar路径 -C $临时目录 2>$null
		if ($LASTEXITCODE -ne 0) { Write-Error "解压头文件包 $tar包名 失败。" }
		$顶层 = Get-ChildItem -LiteralPath $临时目录 -Directory | Select-Object -First 1
		if (-not $顶层) { Write-Error "头文件包 $tar包名 内容异常。" }
		Remove-Item -LiteralPath $缓存目录 -Recurse -Force -ErrorAction SilentlyContinue
		New-Item -ItemType Directory -Force -Path $缓存目录 | Out-Null
		Get-ChildItem -LiteralPath $顶层.FullName | Copy-Item -Destination $缓存目录 -Recurse -Force
		$lib目标 = Join-Path $缓存目录 'x64'
		New-Item -ItemType Directory -Force -Path $lib目标 | Out-Null
		Copy-Item -LiteralPath $lib路径 -Destination (Join-Path $lib目标 'node.lib') -Force
		Set-Content -LiteralPath $标记文件 -Value "$必需标记" -Encoding ascii -NoNewline:$false
		Remove-Item -LiteralPath $临时目录 -Recurse -Force -ErrorAction SilentlyContinue
		Write-Host "编译头文件已预热到缓存：$版本（来源：$所用源）"
	}
}

function 同步远程SSH扩展 {
	# Remote-SSH 是闭源扩展，不在开源仓库中，OSS 开发实例默认也没有市场可装。
	# 这里从本机已安装的 VS Code（Insiders 优先，正式版兜底）的扩展目录中
	# 查找同名扩展，纯本地复制到开发实例的扩展目录；不下载任何内容。
	# 注意：仅复制目录不够——开发实例的用户扩展清单 extensions.json（位于默认
	# 配置文件的 extensions 目录）必须同时写入注册条目，否则扩展不会被加载。
	# 注册条目格式依据源码 extensionsProfileScannerService.ts：
	#   identifier.id（必需）、identifier.uuid（可选）、version（必需）、
	#   relativeLocation（相对扩展目录的路径，必需）、metadata（可选）。
	$开发扩展目录 = Join-Path $env:USERPROFILE '.vscode-oss-dev\extensions'
	if (-not (Test-Path -LiteralPath $开发扩展目录)) {
		Write-Host "开发实例扩展目录不存在，跳过扩展同步：$开发扩展目录"
		return
	}
	$清单文件 = Join-Path $开发扩展目录 'extensions.json'

	$来源候选 = @(
		(Join-Path $env:USERPROFILE '.vscode-insiders\extensions'),
		(Join-Path $env:USERPROFILE '.vscode\extensions')
	)
	# 正则区分主包与 edit 包：主包版本号以数字开头（remote-ssh-0.x），
	# edit 包则带 -edit- 段；若用前缀通配会把 edit 误匹配为主包
	$扩展定义 = @(
		@{ 名称 = 'Remote-SSH'; 模式 = '^ms-vscode-remote\.remote-ssh-\d' },
		@{ 名称 = 'Remote-SSH Edit'; 模式 = '^ms-vscode-remote\.remote-ssh-edit-' }
	)

	# 读取现有清单（损坏/缺失时视为空）。
	# 注意：PS 5.1 的 ConvertFrom-Json 不会把顶层 JSON 数组展开到管线，
	# @(... | ConvertFrom-Json) 会得到"数组被当作单一元素"的嵌套结构，
	# 必须用 foreach 显式展开成条目列表。
	$清单 = New-Object System.Collections.ArrayList
	if (Test-Path -LiteralPath $清单文件) {
		try {
			$解析结果 = Get-Content -LiteralPath $清单文件 -Raw | ConvertFrom-Json
			if ($null -ne $解析结果) {
				if (($解析结果 -is [System.Collections.IList]) -and ($解析结果 -isnot [string])) {
					foreach ($项 in $解析结果) { [void]$清单.Add($项) }
				}
				else { [void]$清单.Add($解析结果) }
			}
		}
		catch { Write-Warning "扩展清单损坏，按空清单处理：$清单文件" }
	}
	$清单已变更 = $false

	foreach ($定义 in $扩展定义) {
		$模式 = $定义.模式

		# 在开发实例目录中查找已存在的该扩展（任意版本）
		$已有 = Get-ChildItem -LiteralPath $开发扩展目录 -Directory -ErrorAction SilentlyContinue |
			Where-Object { $_.Name -match $模式 } | Sort-Object Name -Descending

		# 从源（Insiders 优先，正式版兜底）取最新版本目录作为复制来源
		$源 = $null
		foreach ($目录 in $来源候选) {
			if (-not (Test-Path -LiteralPath $目录)) { continue }
			$找到 = $null
			foreach ($项 in (Get-ChildItem -LiteralPath $目录 -Directory -ErrorAction SilentlyContinue)) {
				if ($项.Name -match $模式) {
					if (-not $找到 -or $项.Name -gt $找到.Name) { $找到 = $项 }
				}
			}
			if ($找到) { $源 = $找到; break }
		}
		if (-not $源) {
			Write-Warning "本机未找到已安装的 $($定义.名称) 扩展，无法同步（如需请先在 VS Code 中安装）。"
			continue
		}

		# 1) 复制/更新扩展目录
		if ($已有) {
			if ($已有[0].Name -eq $源.Name) {
				Write-Host "扩展目录已是最新，跳过复制：$($源.Name)"
			}
			else {
				foreach ($旧目录 in $已有) {
					Remove-Item -LiteralPath $旧目录.FullName -Recurse -Force
				}
				Copy-Item -LiteralPath $源.FullName -Destination (Join-Path $开发扩展目录 $源.Name) -Recurse -Force
				Write-Host "已同步扩展：$($源.Name)"
				$清单已变更 = $true
			}
		}
		else {
			Copy-Item -LiteralPath $源.FullName -Destination (Join-Path $开发扩展目录 $源.Name) -Recurse -Force
			Write-Host "已同步扩展：$($源.Name)"
			$清单已变更 = $true
		}

		# 2) 确保清单中有该扩展的注册条目（否则扩展目录不会被加载）
		#    条目一律从扩展自身 package.json 构造（源码校验仅要求 identifier.id、
		#    version、location、relativeLocation），不引用 Insiders 清单对象——
		#    PowerShell 管道对 JSON 反序列化对象做成员枚举会产生数组污染。
		$目标目录名 = $源.Name
		$已注册 = $null
		foreach ($项 in $清单) {
			# 注意：PowerShell 中 -eq 与 -and 同级左结合，比较必须加括号
			if ($项 -and ($项.relativeLocation -eq $目标目录名) -and $项.identifier -and ($项.identifier.id -is [string])) {
				$已注册 = $项
				break
			}
		}
		# 清理同扩展族的损坏/旧条目（id 非字符串、或目录名不同）
		$清单 = @($清单 | Where-Object {
			-not ($_ -and $_.identifier -and $_.identifier.id -and ($_.identifier.id -isnot [string])) -and
			-not ($_ -and $_.relativeLocation -and ($_.relativeLocation -match $模式) -and ($_.relativeLocation -ne $目标目录名))
		})
		if (-not $已注册) {
			$manifest = Get-Content -LiteralPath (Join-Path $源.FullName 'package.json') -Raw | ConvertFrom-Json
			$扩展id = "$($manifest.publisher).$($manifest.name)"
			$目标路径 = Join-Path $开发扩展目录 $目标目录名
			# URI components JSON 格式：path 形如 /c:/Users/...（保留盘符冒号）
			$uriPath = '/' + ($目标路径 -replace '\\', '/')
			$条目 = [pscustomobject]@{
				identifier       = [pscustomobject]@{ id = [string]$扩展id }
				version          = [string]$manifest.version
				location         = [pscustomobject]@{ '$mid' = 1; fsPath = $目标路径; path = $uriPath; scheme = 'file' }
				relativeLocation = [string]$目标目录名
				metadata         = [pscustomobject]@{ installedTimestamp = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() }
			}
			$清单 = $清单 + @($条目)
			Write-Host "已将 $($定义.名称) 注册到开发实例扩展清单：$目标目录名"
			$清单已变更 = $true
		}
		else {
			Write-Host "清单已注册 $($定义.名称)：$目标目录名"
		}
	}

	# 最终防线：剔除不符合源码 isStoredProfileExtension 校验的条目（缺少必需
	# 字段、identifier.id 非字符串、或扩展目录不存在的条目），防止清单无效
	# 导致开发实例整体抛 ERROR_INVALID_CONTENT 而无法启动。
	$有效清单 = @()
	foreach ($项 in $清单) {
		if (-not ($项 -and $项.identifier -and ($项.identifier.id -is [string]) -and $项.version -and $项.relativeLocation)) { continue }
		if (-not (Test-Path -LiteralPath (Join-Path $开发扩展目录 $项.relativeLocation))) {
			Write-Warning "清单条目指向的扩展目录不存在，已剔除：$($项.relativeLocation)"
			continue
		}
		$有效清单 += $项
	}

	if ($清单已变更 -or (($有效清单 | Measure-Object).Count) -ne ((@($清单) | Measure-Object).Count)) {
		$有效清单 | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $清单文件 -Encoding utf8
		Write-Host "已写入扩展清单：$清单文件（条目数 $(($有效清单 | Measure-Object).Count)）"
	}
	else {
		Write-Host '扩展清单无需更新。'
	}
}

function 确保依赖完整([string]$源码根) {
	$状态文件 = Join-Path $源码根 'node_modules\.postinstall-state'
	if (Test-Path -LiteralPath $状态文件) {
		return
	}

	# node_modules 不存在时无需处理：预启动流程会自动 npm ci 完整安装。
	if (-not (Test-Path -LiteralPath (Join-Path $源码根 'node_modules'))) {
		Write-Host 'node_modules 不存在：预启动流程将自动执行 npm ci 完整安装，无需额外处理。'
		return
	}

	# node_modules 存在但 postinstall 状态文件缺失，说明此前安装未跑完（半途失败）。
	# 预启动的 npm ci 只在 node_modules 缺席时执行，因此这里显式调用仓库官方脚本
	# build/npm/fast-install.ts 修复：它会校验状态、必要时执行完整 npm install。
	Write-Host '检测到 node_modules 存在但依赖安装不完整（缺少 postinstall 状态文件）。'
	Write-Host '正在通过仓库官方脚本 build/npm/fast-install.ts 执行完整依赖安装（可能耗时数分钟至数十分钟，请勿中断，也不要重复运行本脚本）……'
	Push-Location -LiteralPath $源码根
	try {
		& node build/npm/fast-install.ts
		$安装失败 = ($LASTEXITCODE -ne 0)
		if ($安装失败) {
			# 常见于此前并发安装造成的 node_modules 损坏（npm 清理时 ENOTEMPTY）。
			# 自愈：脚本删除全部 node_modules 后重新完整安装一次。
			Write-Warning "依赖安装失败（退出码 $LASTEXITCODE）。可能是 node_modules 树已损坏。脚本将自动清理后重试一次……"
			清理全部NodeModules $源码根
			Write-Host '正在重新执行完整依赖安装……'
			& node build/npm/fast-install.ts
			if ($LASTEXITCODE -ne 0) {
				Write-Error "重试后依赖安装仍失败（退出码 $LASTEXITCODE）。请根据上方日志排查后重试。"
			}
		}
	}
	finally {
		Pop-Location
	}
	if (-not (Test-Path -LiteralPath $状态文件)) {
		Write-Error '依赖安装后仍未生成 postinstall 状态文件，安装可能不完整，中止启动。'
	}
	Write-Host '依赖安装完成。'
}

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
else {
	# 预启动由 node 执行，需要先解析 node（用户可控链路，脚本不自动下载安装）
	$node可执行文件 = 解析Node路径
	$node目录 = Split-Path $node可执行文件 -Parent
	if (-not (($env:PATH -split ';') -contains $node目录)) {
		$env:PATH = "$node目录;$env:PATH"
		Write-Host "已将 node 目录临时加入 PATH：$node目录"
	}

	# VS 内置 node 的版本可能落后于仓库 .nvmrc 的要求（本机内置 v24.17.0，
	# .nvmrc 要求 24.18.0）。仓库 preinstall.ts 支持官方后门环境变量跳过
	# 版本检查；设置前先比对版本要求，仅在确实落后时启用。
	$nvmrc = Join-Path $源码根 '.nvmrc'
	if (Test-Path -LiteralPath $nvmrc) {
		$要求版本 = ((Get-Content -LiteralPath $nvmrc -Raw).Trim() -replace '^v')
		$当前版本 = (& $node可执行文件 -p 'process.version' 2>$null) -replace '^v'
		if ([version]$当前版本 -lt [version]$要求版本) {
			$env:VSCODE_SKIP_NODE_VERSION_CHECK = '1'
			Write-Host "node 版本（$当前版本）低于 .nvmrc 要求（$要求版本）：已设置 VSCODE_SKIP_NODE_VERSION_CHECK=1 跳过检查。"
		}
	}

	# 依赖安装阶段 node-gyp 编译原生模块需要 Python（同样持久记忆），
	# 通过环境变量传给子进程（node-gyp 的 find-python 会依次检查）
	$python可执行文件 = 解析Python路径
	$env:PYTHON = $python可执行文件
	$env:npm_config_python = $python可执行文件

	# VS 2026 预览版的工具链组件以新 ID 注册，node-gyp 按旧 ID 检查会误判
	# "missing any VC++ toolset"。设置开发者命令提示符环境变量走 node-gyp 官方
	# 支持的 VCINSTALLDIR 绕过逻辑（此时它跳过组件 ID 检查，直接信任该 VS）。
	# 注意两点：VCINSTALLDIR 需指向 VC\（node-gyp 对它做 path.resolve(,..)，
	# 回退后必须正好等于 VS 根目录）；VSCMD_VER 只能是 major.minor 两段
	#（多段式会解析失败，导致工具集判定为 null、绕过退化为常规检查而失败）。
	$vs环境 = 解析VS编译环境
	$env:VCINSTALLDIR = Join-Path $vs环境.路径 'VC\'
	if ($vs环境.版本 -match '^(\d+\.\d+)') {
		$env:VSCMD_VER = $matches[1]
	}
	else {
		$env:VSCMD_VER = $vs环境.版本
	}
	$env:WindowsSDKVersion = $vs环境.SDK版本

	# VS 2026 预览版可能只安装了 Preview 工具集（本机是 14.52），而默认
	# Microsoft.VCToolsVersion.v145.default.props 只查找 14.51/14.50 的 props
	# 文件，导致 MSB4019"找不到导入的项目"。props 内置官方开关：设置
	# MSVCPreviewEnabled=true 后即改用 Preview 工具集的 props（props 里对预览
	# 文件的导入均带 EXISTS 条件判断，该开关对其他 VS 无副作用）。
	$env:MSVCPreviewEnabled = 'true'

	# 仓库自带 preinstall.ts 只认 VS 2022/2019 的默认目录，VS 2026 会被判为
	# "Invalid C/C++ Compiler Toolchain"；它支持用 vs2022_install 环境变量显式
	# 指定安装路径覆盖检查（脚本注释里给出的官方后门），这里指向已校验过的
	# VS 根目录。
	$env:vs2022_install = $vs环境.路径

	Write-Host "已设置 VS 编译环境：VCINSTALLDIR=$env:VCINSTALLDIR（$env:VSCMD_VER，SDK $env:WindowsSDKVersion）"

	# 预热 node-gyp 编译头文件缓存（官方源失败自动回退国内镜像），
	# 避免安装阶段因下载头文件网络中断（ECONNRESET）而失败
	预热编译头文件缓存 $源码根

	# 显式强制重装：删除全部 node_modules，后续由预启动的官方 npm ci 完整重装
	#（适用于并发安装等原因造成的依赖树损坏）。
	if ($强制重装依赖) {
		Write-Host '已指定 -强制重装依赖：将删除仓库中全部 node_modules 并完整重装……'
		清理全部NodeModules $源码根
	}

	# node_modules 半途损坏时，preLaunch 不会自动补装，这里用仓库官方脚本修复
	确保依赖完整 $源码根
}

Write-Host "源码目录：$源码根"

# 启动前同步开发实例缺失的闭源扩展（如 Remote-SSH，纯本地复制）
同步远程SSH扩展

Write-Host '正在启动 VSCode-OSS 开发实例……'
if (-not $跳过预启动) {
	Write-Host '（首次启动需下载 Electron 并编译，耗时较长，请耐心等待）'
}

# 透传剩余参数并同步退出码
& $启动脚本路径 @剩余参数
$退出码 = $LASTEXITCODE
try { $互斥锁.ReleaseMutex() } catch { }
exit $退出码
