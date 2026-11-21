Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$script:ScriptPath = $MyInvocation.MyCommand.Path
$script:Workspace  = Split-Path -Parent $PSScriptRoot

# ---------------------------------------------------------------------------
# 浏览器配置表：ProgID / AppKey 与注册表注册名一一对应，勿随意更改
# ---------------------------------------------------------------------------
$script:Browsers = @{
    'Edge 绿色版' = @{
        ProgId  = 'EdgePortableHTML'
        AppKey  = 'EdgePortable'
        Display = 'Microsoft Edge (Portable)'
        Proc    = 'msedge'
        ExeCandidates = @(
            'D:\MyApp\Browser\Edge\EdgePortable\App\msedge.exe',
            (Join-Path $script:Workspace 'EdgePortable\App\msedge.exe')
        )
    }
    'Chrome 绿色版' = @{
        ProgId  = 'ChromePortableHTML'
        AppKey  = 'ChromePortable'
        Display = 'Google Chrome (Portable)'
        Proc    = 'chrome'
        ExeCandidates = @(
            (Join-Path $script:Workspace 'ChromePortable\App\chrome.exe')
        )
    }
}

$script:CurrentName = 'Edge 绿色版'

# ---------------------------------------------------------------------------
# 工具函数
# ---------------------------------------------------------------------------
function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = '[{0}] [{1}] {2}' -f (Get-Date -Format 'HH:mm:ss'), $Level, $Message
    $txtLog.AppendText($line + "`r`n")
    $txtLog.SelectionStart = $txtLog.TextLength
    $txtLog.ScrollToCaret()
}

function Get-DefaultExe {
    param([array]$Candidates)
    foreach ($c in $Candidates) {
        if (Test-Path -LiteralPath $c) { return $c }
    }
    return ''
}

function Set-BrowserConfig {
    param([string]$Name)
    $cfg = $script:Browsers[$Name]
    $script:CurrentName   = $Name
    $script:CurrentCfg    = $cfg
    $script:CurrentProgId = $cfg.ProgId
    $script:CurrentAppKey = $cfg.AppKey
    $script:CurrentDisplay= $cfg.Display

    $exe = Get-DefaultExe -Candidates $cfg.ExeCandidates
    $txtExe.Text = $exe
    if ($exe) {
        $appDir  = Split-Path -Parent $exe           # ...\App
        $rootDir = Split-Path -Parent $appDir        # ...\EdgePortable
        $txtData.Text = Join-Path $rootDir 'Data'
    } else {
        $txtData.Text = ''
    }
    $txtDisplay.Text = $cfg.Display
    Refresh-State
}

function Get-RegValue {
    param([string]$Path, [string]$Name = '(default)')
    try {
        $item = Get-ItemProperty -LiteralPath $Path -ErrorAction Stop
        if ($Name -eq '(default)') {
            return $item.'(default)'
        }
        return $item.$Name
    } catch { return $null }
}

# 读取当前系统默认浏览器（UserChoice 受哈希保护，只读取不改写）
function Get-DefaultBrowser {
    $uc = 'HKCU:\Software\Microsoft\Windows\Shell\Associations\UrlAssociations'
    $http  = Get-RegValue -Path "$uc\http\UserChoice"  -Name 'ProgId'
    $https = Get-RegValue -Path "$uc\https\UserChoice" -Name 'ProgId'
    $html  = Get-RegValue -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts\.html\UserChoice' -Name 'ProgId'
    return [pscustomobject]@{ Http = $http; Https = $https; Html = $html }
}

function ProgId-ToLabel {
    param([string]$ProgId)
    if (-not $ProgId) { return '(未设置)' }
    if ($ProgId -eq 'MSEdgeHTM')          { return '系统自带 Edge' }
    if ($ProgId -eq 'ChromeHTML')         { return '系统安装 Chrome' }
    if ($ProgId -eq 'EdgePortableHTML')   { return '★ Edge 绿色版' }
    if ($ProgId -eq 'ChromePortableHTML') { return '★ Chrome 绿色版' }
    if ($ProgId -eq 'FirefoxHTML')        { return 'Firefox' }
    return $ProgId
}

# 刷新界面上的注册状态与当前默认状态
function Refresh-State {
    $prog = $script:CurrentProgId
    $app  = $script:CurrentAppKey

    $progPath = "HKCU:\Software\Classes\$prog"
    $appPath  = "HKCU:\Software\Clients\StartMenuInternet\$app"
    $regVal   = Get-RegValue -Path 'HKCU:\Software\RegisteredApplications' -Name $app
    $isReg = (Test-Path -LiteralPath $progPath) -and (Test-Path -LiteralPath $appPath) -and [bool]$regVal
    if ($isReg) {
        $lblRegistered.Text = '已注册'
        $lblRegistered.ForeColor = [Drawing.Color]::FromArgb(0, 120, 0)
    } else {
        $lblRegistered.Text = '未注册'
        $lblRegistered.ForeColor = [Drawing.Color]::FromArgb(160, 0, 0)
    }

    $def = Get-DefaultBrowser
    $lblCurrentDefault.Text = 'HTTP: {0}    HTTPS: {1}    .html: {2}' -f `
        (ProgId-ToLabel $def.Http), (ProgId-ToLabel $def.Https), (ProgId-ToLabel $def.Html)
}

# ---------------------------------------------------------------------------
# 注册表注册：写入四类项，使绿色版出现在系统"默认应用"列表
# ---------------------------------------------------------------------------
function Register-Browser {
    param([string]$Exe, [string]$Data, [string]$Display, [string]$Prog, [string]$App)

    if (-not (Test-Path -LiteralPath $Exe -PathType Leaf)) { throw "程序文件不存在：$Exe" }
    $lsFile = Join-Path $Data 'Local State'
    if (-not (Test-Path -LiteralPath $lsFile -PathType Leaf)) { throw "数据目录无效（缺少 Local State）：$Data" }

    $openCmd = '"{0}" --user-data-dir="{1}" --no-first-run --no-default-browser-check --single-argument %1' -f $Exe, $Data
    $appCmd  = '"{0}" --user-data-dir="{1}" --no-first-run --no-default-browser-check' -f $Exe, $Data

    # 1) ProgID：文件类型处理器
    New-Item -Path "HKCU:\Software\Classes\$Prog" -Force | Out-Null
    Set-ItemProperty -LiteralPath "HKCU:\Software\Classes\$Prog" -Name '(default)' -Value "$Display Document"
    New-Item -Path "HKCU:\Software\Classes\$Prog\shell\open\command" -Force | Out-Null
    Set-ItemProperty -LiteralPath "HKCU:\Software\Classes\$Prog\shell\open\command" -Name '(default)' -Value $openCmd

    # 2) StartMenuInternet：客户端注册
    $smi = "HKCU:\Software\Clients\StartMenuInternet\$App"
    New-Item -Path "$smi\shell\open\command" -Force | Out-Null
    Set-ItemProperty -LiteralPath $smi -Name '(default)' -Value $Display
    Set-ItemProperty -LiteralPath "$smi\shell\open\command" -Name '(default)' -Value $appCmd

    # 3) Capabilities：协议与文件类型声明
    $cap = "$smi\Capabilities"
    New-Item -Path "$cap\URLAssociations"  -Force | Out-Null
    New-Item -Path "$cap\FileAssociations" -Force | Out-Null
    New-Item -Path "$cap\MIMEAssociations" -Force | Out-Null
    Set-ItemProperty -LiteralPath $cap -Name 'ApplicationName'        -Value $Display
    Set-ItemProperty -LiteralPath $cap -Name 'ApplicationDescription' -Value "$Display (portable)"
    Set-ItemProperty -LiteralPath $cap -Name 'StartMenuInternet'      -Value $App
    Set-ItemProperty -LiteralPath "$cap\URLAssociations" -Name 'http'  -Value $Prog
    Set-ItemProperty -LiteralPath "$cap\URLAssociations" -Name 'https' -Value $Prog
    foreach ($ext in @('.htm', '.html', '.shtml', '.xhtml', '.webp')) {
        Set-ItemProperty -LiteralPath "$cap\FileAssociations" -Name $ext -Value $Prog
    }
    Set-ItemProperty -LiteralPath "$cap\MIMEAssociations" -Name 'text/html'            -Value $Prog
    Set-ItemProperty -LiteralPath "$cap\MIMEAssociations" -Name 'application/xhtml+xml' -Value $Prog

    # 4) RegisteredApplications：出现在"默认应用"列表
    Set-ItemProperty -LiteralPath 'HKCU:\Software\RegisteredApplications' -Name $App -Value "Software\Clients\StartMenuInternet\$App\Capabilities"
}

function Unregister-Browser {
    param([string]$Prog, [string]$App)
    $targets = @(
        "HKCU:\Software\Classes\$Prog",
        "HKCU:\Software\Clients\StartMenuInternet\$App"
    )
    foreach ($t in $targets) {
        if (Test-Path -LiteralPath $t) { Remove-Item -LiteralPath $t -Recurse -Force }
    }
    $ra = 'HKCU:\Software\RegisteredApplications'
    if ((Get-ItemProperty -LiteralPath $ra -ErrorAction SilentlyContinue).PSObject.Properties.Name -contains $App) {
        Remove-ItemProperty -LiteralPath $ra -Name $App -Force
    }
}

function Open-DefaultAppsSettings {
    # 清除大小写重复的代理环境变量（本环境 Start-Process 已知问题）
    foreach ($n in @('https_proxy', 'http_proxy', 'HTTPS_PROXY', 'HTTP_PROXY')) {
        Remove-Item "Env:\$n" -ErrorAction SilentlyContinue
    }
    Start-Process 'ms-settings:defaultapps' -ErrorAction Stop
}

# ---------------------------------------------------------------------------
# 事件处理
# ---------------------------------------------------------------------------
$onRegister = {
    if ($script:Busy) { return }
    $script:Busy = $true
    try {
        $exe = $txtExe.Text.Trim().Trim('"')
        $dat = $txtData.Text.Trim().Trim('"')
        $dsp = $txtDisplay.Text.Trim()
        if (-not $dsp) { throw '显示名称不能为空' }
        Write-Log "开始注册 $($script:CurrentName) ..."
        Register-Browser -Exe $exe -Data $dat -Display $dsp -Prog $script:CurrentProgId -App $script:CurrentAppKey
        Write-Log "注册成功：$dsp (ProgID=$($script:CurrentProgId))" 'OK'
        Write-Log '下一步：点击【2. 打开默认应用设置】，在列表中选择该浏览器。' 'HINT'
        Refresh-State
    } catch {
        Write-Log ("注册失败：" + $_.Exception.Message) 'ERROR'
        [Windows.Forms.MessageBox]::Show($_.Exception.Message, '注册失败', 'OK', 'Error') | Out-Null
    } finally {
        $script:Busy = $false
    }
}

$onOpenSettings = {
    try {
        Write-Log '正在打开系统默认应用设置...'
        Open-DefaultAppsSettings
        Write-Log '已打开。请在"Web 浏览器"中选择已注册的绿色版浏览器。' 'OK'
    } catch {
        Write-Log ("打开设置失败：" + $_.Exception.Message) 'ERROR'
    }
}

$onCheck = {
    $def = Get-DefaultBrowser
    Write-Log ('当前默认 —— HTTP: {0} / HTTPS: {1} / .html: {2}' -f `
        $def.Http, $def.Https, $def.Html)
    Write-Log ('可读名称 —— HTTP: {0} / HTTPS: {1} / .html: {2}' -f `
        (ProgId-ToLabel $def.Http), (ProgId-ToLabel $def.Https), (ProgId-ToLabel $def.Html))
    $target = $script:CurrentProgId
    if ($def.Http -eq $target -and $def.Https -eq $target) {
        Write-Log "校验通过：$($script:CurrentName) 已设为默认浏览器。" 'OK'
    } else {
        Write-Log "尚未生效：当前 HTTP/HTTPS 默认并非 $($script:CurrentName)，请在系统设置中点选。" 'HINT'
    }
    Refresh-State
}

$onUnregister = {
    if ($script:Busy) { return }
    $def = Get-DefaultBrowser
    if ($def.Http -eq $script:CurrentProgId -or $def.Https -eq $script:CurrentProgId) {
        $r = [Windows.Forms.MessageBox]::Show(
            '当前默认浏览器仍是本绿色版。撤销注册后，默认浏览器设置会失效，需要重新指定。确定撤销吗？',
            '确认撤销', 'YesNo', 'Warning')
        if ($r -ne 'Yes') { return }
    }
    try {
        Unregister-Browser -Prog $script:CurrentProgId -App $script:CurrentAppKey
        Write-Log "已撤销 $($script:CurrentName) 的系统注册。" 'OK'
        Refresh-State
    } catch {
        Write-Log ("撤销失败：" + $_.Exception.Message) 'ERROR'
    }
}

$onBrowseExe = {
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Filter = '浏览器主程序 (msedge.exe;chrome.exe)|msedge.exe;chrome.exe|所有文件 (*.*)|*.*'
    if ($dlg.ShowDialog() -eq 'OK') {
        $txtExe.Text = $dlg.FileName
        $appDir = Split-Path -Parent $dlg.FileName
        $rootDir = Split-Path -Parent $appDir
        $txtData.Text = Join-Path $rootDir 'Data'
    }
}

$onBrowseData = {
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = '选择绿色版浏览器的数据目录（含 Local State）'
    if ($dlg.ShowDialog() -eq 'OK') {
        $txtData.Text = $dlg.SelectedPath
    }
}

# ---------------------------------------------------------------------------
# GUI 构建
# ---------------------------------------------------------------------------
$form = New-Object System.Windows.Forms.Form
$form.Text = '绿色版浏览器 · 默认浏览器设置工具'
$form.Size = New-Object System.Drawing.Size(760, 620)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false

# 说明
$lblIntro = New-Object System.Windows.Forms.Label
$lblIntro.Location = New-Object System.Drawing.Point(24, 20)
$lblIntro.Size = New-Object System.Drawing.Size(700, 48)
$lblIntro.Text = "Windows 10/11 对默认浏览器有哈希保护，脚本无法直接改写。`r`n本工具负责把绿色版浏览器注册进系统，最后一步请在打开的设置界面中手动点选。"
$form.Controls.Add($lblIntro)

# 浏览器选择
$lblBrowser = New-Object System.Windows.Forms.Label
$lblBrowser.Location = New-Object System.Drawing.Point(24, 82)
$lblBrowser.Size = New-Object System.Drawing.Size(90, 24)
$lblBrowser.Text = '浏览器：'
$form.Controls.Add($lblBrowser)

$cmbBrowser = New-Object System.Windows.Forms.ComboBox
$cmbBrowser.Location = New-Object System.Drawing.Point(110, 78)
$cmbBrowser.Size = New-Object System.Drawing.Size(200, 26)
$cmbBrowser.DropDownStyle = 'DropDownList'
$cmbBrowser.Items.Add('Edge 绿色版') | Out-Null
$cmbBrowser.Items.Add('Chrome 绿色版') | Out-Null
$form.Controls.Add($cmbBrowser)

$lblReg = New-Object System.Windows.Forms.Label
$lblReg.Location = New-Object System.Drawing.Point(340, 82)
$lblReg.Size = New-Object System.Drawing.Size(80, 24)
$lblReg.Text = '注册状态：'
$form.Controls.Add($lblReg)

$lblRegistered = New-Object System.Windows.Forms.Label
$lblRegistered.Location = New-Object System.Drawing.Point(420, 82)
$lblRegistered.Size = New-Object System.Drawing.Size(120, 24)
$lblRegistered.Text = ''
$form.Controls.Add($lblRegistered)

# 程序路径
$lblExe = New-Object System.Windows.Forms.Label
$lblExe.Location = New-Object System.Drawing.Point(24, 122)
$lblExe.Size = New-Object System.Drawing.Size(90, 24)
$lblExe.Text = '程序路径：'
$form.Controls.Add($lblExe)

$txtExe = New-Object System.Windows.Forms.TextBox
$txtExe.Location = New-Object System.Drawing.Point(110, 118)
$txtExe.Size = New-Object System.Drawing.Size(530, 26)
$form.Controls.Add($txtExe)

$btnBrowseExe = New-Object System.Windows.Forms.Button
$btnBrowseExe.Location = New-Object System.Drawing.Point(650, 117)
$btnBrowseExe.Size = New-Object System.Drawing.Size(70, 28)
$btnBrowseExe.Text = '浏览...'
$btnBrowseExe.add_Click($onBrowseExe)
$form.Controls.Add($btnBrowseExe)

# 数据目录
$lblData = New-Object System.Windows.Forms.Label
$lblData.Location = New-Object System.Drawing.Point(24, 158)
$lblData.Size = New-Object System.Drawing.Size(90, 24)
$lblData.Text = '数据目录：'
$form.Controls.Add($lblData)

$txtData = New-Object System.Windows.Forms.TextBox
$txtData.Location = New-Object System.Drawing.Point(110, 154)
$txtData.Size = New-Object System.Drawing.Size(530, 26)
$form.Controls.Add($txtData)

$btnBrowseData = New-Object System.Windows.Forms.Button
$btnBrowseData.Location = New-Object System.Drawing.Point(650, 153)
$btnBrowseData.Size = New-Object System.Drawing.Size(70, 28)
$btnBrowseData.Text = '浏览...'
$btnBrowseData.add_Click($onBrowseData)
$form.Controls.Add($btnBrowseData)

# 显示名称
$lblDisplay = New-Object System.Windows.Forms.Label
$lblDisplay.Location = New-Object System.Drawing.Point(24, 194)
$lblDisplay.Size = New-Object System.Drawing.Size(90, 24)
$lblDisplay.Text = '显示名称：'
$form.Controls.Add($lblDisplay)

$txtDisplay = New-Object System.Windows.Forms.TextBox
$txtDisplay.Location = New-Object System.Drawing.Point(110, 190)
$txtDisplay.Size = New-Object System.Drawing.Size(530, 26)
$form.Controls.Add($txtDisplay)

# 操作按钮
$btnRegister = New-Object System.Windows.Forms.Button
$btnRegister.Location = New-Object System.Drawing.Point(24, 236)
$btnRegister.Size = New-Object System.Drawing.Size(220, 38)
$btnRegister.Text = '1. 注册为可选浏览器'
$btnRegister.add_Click($onRegister)
$form.Controls.Add($btnRegister)

$btnOpenSettings = New-Object System.Windows.Forms.Button
$btnOpenSettings.Location = New-Object System.Drawing.Point(268, 236)
$btnOpenSettings.Size = New-Object System.Drawing.Size(220, 38)
$btnOpenSettings.Text = '2. 打开默认应用设置'
$btnOpenSettings.add_Click($onOpenSettings)
$form.Controls.Add($btnOpenSettings)

$btnCheck = New-Object System.Windows.Forms.Button
$btnCheck.Location = New-Object System.Drawing.Point(512, 236)
$btnCheck.Size = New-Object System.Drawing.Size(208, 38)
$btnCheck.Text = '3. 检查当前默认'
$btnCheck.add_Click($onCheck)
$form.Controls.Add($btnCheck)

$btnUnregister = New-Object System.Windows.Forms.Button
$btnUnregister.Location = New-Object System.Drawing.Point(24, 286)
$btnUnregister.Size = New-Object System.Drawing.Size(220, 34)
$btnUnregister.Text = '撤销注册'
$btnUnregister.add_Click($onUnregister)
$form.Controls.Add($btnUnregister)

# 当前默认状态栏
$lblCurrentDefault = New-Object System.Windows.Forms.Label
$lblCurrentDefault.Location = New-Object System.Drawing.Point(268, 290)
$lblCurrentDefault.Size = New-Object System.Drawing.Size(460, 28)
$lblCurrentDefault.Text = ''
$form.Controls.Add($lblCurrentDefault)

# 日志区
$lblLog = New-Object System.Windows.Forms.Label
$lblLog.Location = New-Object System.Drawing.Point(24, 332)
$lblLog.Size = New-Object System.Drawing.Size(400, 24)
$lblLog.Text = '操作日志：'
$form.Controls.Add($lblLog)

$txtLog = New-Object System.Windows.Forms.TextBox
$txtLog.Location = New-Object System.Drawing.Point(24, 356)
$txtLog.Size = New-Object System.Drawing.Size(696, 210)
$txtLog.Multiline = $true
$txtLog.ReadOnly = $true
$txtLog.ScrollBars = 'Vertical'
$txtLog.BackColor = [Drawing.Color]::FromArgb(250, 250, 250)
$form.Controls.Add($txtLog)

# 下拉框切换
$cmbBrowser.add_SelectedIndexChanged({
    if ($script:Busy) { return }
    $name = $cmbBrowser.SelectedItem
    if (-not $name) { return }
    Set-BrowserConfig -Name $name
    Write-Log "已切换到：$name"
})

# 初始化
$script:Busy = $false
$cmbBrowser.SelectedIndex = 0
Write-Log '工具就绪。流程：① 注册 → ② 打开设置并点选 → ③ 检查确认。'
Write-Log '全部注册写入当前用户（HKCU），无需管理员，不影响系统自带浏览器。'

[Windows.Forms.Application]::Run($form)
