Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$script:ScriptPath = $MyInvocation.MyCommand.Path

# 浏览器配置表：所有差异集中在此，切换下拉框时统一套用
$script:Browsers = @{
    'Chrome' = @{
        SrcRel       = 'Google\Chrome\User Data'
        ProcName     = 'chrome'
        DefaultDst   = 'D:\Chrome\User Data'
        VerifyUrl    = 'chrome://version'
        UpdateSvcs   = @('gupdate', 'gupdatem')
        ProcHint     = '请在任务管理器中结束所有 chrome.exe 进程'
    }
    'Edge' = @{
        SrcRel       = 'Microsoft\Edge\User Data'
        ProcName     = 'msedge'
        DefaultDst   = 'D:\Edge\User Data'
        VerifyUrl    = 'edge://version'
        UpdateSvcs   = @('edgeupdate', 'edgeupdatem')
        ProcHint     = '请在任务管理器中结束所有 msedge.exe 进程（Edge 可能在后台驻留）'
    }
}

$script:DataFolderName = 'User Data'
$script:BackupName = 'User Data.bak'
$script:Busy = $false

function Set-BrowserConfig {
    param([string]$Name)
    $cfg = $script:Browsers[$Name]
    $script:BrowserName = $Name
    $script:ProcName    = $cfg.ProcName
    $script:VerifyUrl   = $cfg.VerifyUrl
    $script:UpdateSvcs  = $cfg.UpdateSvcs
    $script:ProcHint    = $cfg.ProcHint
    $script:SrcDir      = Join-Path $env:LOCALAPPDATA $cfg.SrcRel
    $script:ParentDir   = Split-Path -Parent $script:SrcDir
    $script:BackupDir   = Join-Path $script:ParentDir $script:BackupName
}
Set-BrowserConfig -Name 'Chrome'

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

function Write-GuiLog {
    param([string]$Message)
    $line = '[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $Message
    $txtLog.AppendText($line + "`r`n")
    $txtLog.SelectionStart = $txtLog.TextLength
    $txtLog.ScrollToCaret()
}

function Set-Buttons {
    param([bool]$Enabled)
    $btnCheck.Enabled = $Enabled
    $cmbBrowser.Enabled = $Enabled
    $progress.Visible = (-not $Enabled)
    if ($isAdmin) {
        $btnMigrate.Enabled = $Enabled
        $btnCleanup.Enabled = $Enabled
    }
}

function Invoke-Check {
    param([string]$Src, [string]$Dst, [string]$Backup)
    $items = @()
    if (-not (Test-Path -LiteralPath $Src)) { return @('ERROR|源目录不存在：' + $Src) }

    $item = Get-Item -LiteralPath $Src -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        $items += 'ERROR|源目录已是链接或联接，说明迁移可能已经完成，无需重复执行。'
    }
    if (Test-Path -LiteralPath $Backup) {
        $items += 'ERROR|备份目录已存在：' + $Backup
    }

    $drive = [IO.Path]::GetPathRoot($Dst)
    if ($drive -notmatch '^[A-Za-z]:\\') {
        $items += 'ERROR|目标路径必须是本地磁盘绝对路径，例如 D:\' + $script:BrowserName + '\User Data'
    } elseif (-not (Test-Path -LiteralPath $drive)) {
        $items += 'ERROR|目标盘符不存在：' + $drive
    }

    if (Test-Path -LiteralPath $Dst) {
        if ((Get-ChildItem -LiteralPath $Dst -Force | Measure-Object).Count -gt 0) {
            $items += 'ERROR|目标目录已存在且非空，为避免覆盖数据，请先清空或改用其他路径。'
        }
    }

    if (Get-Process $script:ProcName -ErrorAction SilentlyContinue) {
        $items += 'ERROR|检测到 ' + $script:BrowserName + ' 仍在运行，请先关闭全部窗口，并' + $script:ProcHint + '后重试。'
    }

    $size = (Get-ChildItem -LiteralPath $Src -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
    $items += ('INFO|源数据大小：{0:N2} GB' -f ($size / 1GB))
    if ($drive -match '^[A-Za-z]:\\') {
        $free = (Get-PSDrive -Name $drive.Substring(0,1)).Free
        $items += ('INFO|目标盘可用：{0:N1} GB' -f ($free / 1GB))
    }
    $upd = @(Get-Service $script:UpdateSvcs -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Running' })
    if ($upd.Count -gt 0) {
        $items += 'INFO|' + $script:BrowserName + ' 更新服务正在运行，迁移期间请暂时避免自动更新。'
    }
    return $items
}

function Start-RoboCopy {
    param([string]$Src, [string]$Dst)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'robocopy'
    $psi.Arguments = '"' + $Src + '" "' + $Dst + '" /E /COPYALL /DCOPY:DAT /R:2 /W:2 /NFL /NDL /NJH /NJS /NP'
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    $proc.Start() | Out-Null
    while (-not $proc.HasExited) {
        [Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 150
    }
    $rc = $proc.ExitCode
    $proc.Dispose()
    return $rc
}

function Invoke-Migrate {
    param([string]$Src, [string]$Dst, [string]$Backup)
    $log = New-Object System.Collections.Generic.List[string]

    foreach ($c in (Invoke-Check -Src $Src -Dst $Dst -Backup $Backup)) {
        if ($c.StartsWith('ERROR|')) { $log.Add('ERROR|' + $c.Substring(6)); return $log }
        $log.Add('INFO|' + $c.Substring(5))
    }

    Write-GuiLog ('正在复制 ' + $script:BrowserName + ' 数据，数据量较大时可能需要几分钟，请稍候...')
    [Windows.Forms.Application]::DoEvents()
    $rc = Start-RoboCopy -Src $Src -Dst $Dst
    if ($rc -ge 8) { $log.Add('ERROR|数据复制失败，robocopy 返回码 ' + $rc); return $log }
    $log.Add('INFO|数据复制完成。')

    if (-not (Test-Path -LiteralPath (Join-Path $Dst 'Local State'))) {
        $log.Add('ERROR|复制后未发现关键配置文件 Local State，复制不完整。')
        return $log
    }

    Rename-Item -LiteralPath $Src -NewName $script:BackupName -ErrorAction Stop
    $log.Add('INFO|原目录已改名为备份。')

    try {
        New-Item -ItemType Junction -Path $Src -Target $Dst -ErrorAction Stop | Out-Null
    } catch {
        Rename-Item -LiteralPath $Backup -NewName $script:DataFolderName -ErrorAction SilentlyContinue
        $log.Add('ERROR|建立目录联接失败，已回滚。' + $_.Exception.Message)
        return $log
    }

    $item = Get-Item -LiteralPath $Src -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) {
        Remove-Item -LiteralPath $Src -Force -Recurse -ErrorAction SilentlyContinue
        Rename-Item -LiteralPath $Backup -NewName $script:DataFolderName -ErrorAction SilentlyContinue
        $log.Add('ERROR|目录联接验证失败，已回滚。')
        return $log
    }

    $log.Add('SUCCESS|' + $script:BrowserName + ' 迁移完成。')
    $log.Add('INFO|数据实体：' + $Dst)
    $log.Add('INFO|备份目录：' + $Backup)
    $log.Add('INFO|请启动 ' + $script:BrowserName + ' 并打开 ' + $script:VerifyUrl + ' 核对个人资料路径，确认无误后再清理备份。')
    return $log
}

function Invoke-Cleanup {
    param([string]$Src, [string]$Backup)
    if (-not (Test-Path -LiteralPath $Backup)) { return @('ERROR|未找到备份目录：' + $Backup) }
    $item = Get-Item -LiteralPath $Src -Force -ErrorAction SilentlyContinue
    if ($null -eq $item -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) {
        return @('ERROR|未检测到目录联接，为保证数据安全，拒绝清理备份。')
    }
    Remove-Item -LiteralPath $Backup -Recurse -Force -ErrorAction Stop
    return @('SUCCESS|备份目录已删除。')
}

function Run-Task {
    param([string]$Action, [string]$Dst)
    if ($script:Busy) { return }
    $script:Busy = $true
    Set-Buttons $false
    [Windows.Forms.Application]::DoEvents()
    try {
        switch ($Action) {
            'check'   { $res = Invoke-Check -Src $script:SrcDir -Dst $Dst -Backup $script:BackupDir }
            'migrate' { $res = Invoke-Migrate -Src $script:SrcDir -Dst $Dst -Backup $script:BackupDir }
            'cleanup' { $res = Invoke-Cleanup -Src $script:SrcDir -Backup $script:BackupDir }
        }
        foreach ($line in $res) {
            if ($line.StartsWith('ERROR|')) { Write-GuiLog ('错误：' + $line.Substring(6)) }
            elseif ($line.StartsWith('SUCCESS|')) { Write-GuiLog ('完成：' + $line.Substring(8)) }
            else { Write-GuiLog ($line.Substring(5)) }
        }
    } catch {
        Write-GuiLog ('异常：' + $_.Exception.Message)
    } finally {
        $script:Busy = $false
        Set-Buttons $true
    }
}

$form = New-Object System.Windows.Forms.Form
$form.Text = '浏览器用户数据迁移工具（Chrome / Edge）'
$form.Size = New-Object System.Drawing.Size(660, 590)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false
$form.Font = New-Object System.Drawing.Font('Microsoft YaHei', 9)
$form.add_FormClosing({
    param($s, $e)
    if ($script:Busy) {
        $e.Cancel = $true
        [Windows.Forms.MessageBox]::Show('任务正在执行，请等待完成后再关闭。', '提示')
    }
})

$lblHeader = New-Object System.Windows.Forms.Label
$lblHeader.Text = '将浏览器用户数据从 C 盘迁移到自定义位置（目录联接方式）'
$lblHeader.Location = New-Object System.Drawing.Point(16, 14)
$lblHeader.Size = New-Object System.Drawing.Size(620, 26)
$lblHeader.Font = New-Object System.Drawing.Font('Microsoft YaHei', 10, [Drawing.FontStyle]::Bold)
$form.Controls.Add($lblHeader)

$grpPath = New-Object System.Windows.Forms.GroupBox
$grpPath.Text = '浏览器与路径设置'
$grpPath.Location = New-Object System.Drawing.Point(16, 46)
$grpPath.Size = New-Object System.Drawing.Size(620, 128)
$form.Controls.Add($grpPath)

$lblBrowser = New-Object System.Windows.Forms.Label
$lblBrowser.Text = '浏览器'
$lblBrowser.Location = New-Object System.Drawing.Point(12, 26)
$lblBrowser.Size = New-Object System.Drawing.Size(76, 22)
$grpPath.Controls.Add($lblBrowser)

$cmbBrowser = New-Object System.Windows.Forms.ComboBox
$cmbBrowser.Location = New-Object System.Drawing.Point(92, 24)
$cmbBrowser.Size = New-Object System.Drawing.Size(200, 22)
$cmbBrowser.DropDownStyle = [Windows.Forms.ComboBoxStyle]::DropDownList
$cmbBrowser.Items.Add('Chrome') | Out-Null
$cmbBrowser.Items.Add('Edge') | Out-Null
$cmbBrowser.SelectedIndex = 0
$cmbBrowser.add_SelectedIndexChanged({
    if ($script:Busy) { return }
    Set-BrowserConfig -Name $cmbBrowser.SelectedItem
    $txtSrc.Text = $script:SrcDir
    $txtDst.Text = $script:Browsers[$cmbBrowser.SelectedItem].DefaultDst
    Write-GuiLog ('已切换到 ' + $script:BrowserName + '，请重新检查环境。')
})
$grpPath.Controls.Add($cmbBrowser)

$lblSrc = New-Object System.Windows.Forms.Label
$lblSrc.Text = '源路径'
$lblSrc.Location = New-Object System.Drawing.Point(12, 62)
$lblSrc.Size = New-Object System.Drawing.Size(76, 22)
$grpPath.Controls.Add($lblSrc)

$txtSrc = New-Object System.Windows.Forms.TextBox
$txtSrc.Location = New-Object System.Drawing.Point(92, 60)
$txtSrc.Size = New-Object System.Drawing.Size(466, 22)
$txtSrc.ReadOnly = $true
$txtSrc.Text = $script:SrcDir
$grpPath.Controls.Add($txtSrc)

$lblDst = New-Object System.Windows.Forms.Label
$lblDst.Text = '目标路径'
$lblDst.Location = New-Object System.Drawing.Point(12, 96)
$lblDst.Size = New-Object System.Drawing.Size(76, 22)
$grpPath.Controls.Add($lblDst)

$txtDst = New-Object System.Windows.Forms.TextBox
$txtDst.Location = New-Object System.Drawing.Point(92, 94)
$txtDst.Size = New-Object System.Drawing.Size(466, 22)
$txtDst.Text = $script:Browsers['Chrome'].DefaultDst
$grpPath.Controls.Add($txtDst)

$btnBrowse = New-Object System.Windows.Forms.Button
$btnBrowse.Text = '...'
$btnBrowse.Location = New-Object System.Drawing.Point(566, 93)
$btnBrowse.Size = New-Object System.Drawing.Size(40, 24)
$btnBrowse.add_Click({
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = '选择用户数据的目标文件夹'
    if ($dlg.ShowDialog() -eq [Windows.Forms.DialogResult]::OK) {
        $txtDst.Text = $dlg.SelectedPath
    }
})
$grpPath.Controls.Add($btnBrowse)

$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Location = New-Object System.Drawing.Point(16, 182)
$lblStatus.Size = New-Object System.Drawing.Size(620, 42)
$lblStatus.Text = '尚未检查环境。请先点击"检查环境"查看前置条件与数据大小。'
$form.Controls.Add($lblStatus)

$btnCheck = New-Object System.Windows.Forms.Button
$btnCheck.Text = '检查环境'
$btnCheck.Location = New-Object System.Drawing.Point(16, 230)
$btnCheck.Size = New-Object System.Drawing.Size(110, 32)
$btnCheck.add_Click({
    if ($script:Busy) { return }
    $dst = $txtDst.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($dst)) {
        [Windows.Forms.MessageBox]::Show('请填写目标路径。', '提示')
        return
    }
    $lblStatus.Text = '正在检查环境...'
    Write-GuiLog '开始检查环境...'
    Run-Task -Action 'check' -Dst $dst
})
$form.Controls.Add($btnCheck)

$btnMigrate = New-Object System.Windows.Forms.Button
$btnMigrate.Text = '开始迁移'
$btnMigrate.Location = New-Object System.Drawing.Point(134, 230)
$btnMigrate.Size = New-Object System.Drawing.Size(110, 32)
$btnMigrate.add_Click({
    if ($script:Busy) { return }
    $dst = $txtDst.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($dst)) {
        [Windows.Forms.MessageBox]::Show('请填写目标路径。', '提示')
        return
    }
    $msg = '即将执行 ' + $script:BrowserName + ' 迁移：' + [Environment]::NewLine + [Environment]::NewLine
    $msg += '源路径：' + $script:SrcDir + [Environment]::NewLine
    $msg += '目标路径：' + $dst + [Environment]::NewLine + [Environment]::NewLine
    $msg += '请确认已关闭全部窗口，并' + $script:ProcHint + '。' + [Environment]::NewLine + [Environment]::NewLine
    $msg += '确认继续？'
    if ([Windows.Forms.MessageBox]::Show($msg, '确认迁移', [Windows.Forms.MessageBoxButtons]::YesNo, [Windows.Forms.MessageBoxIcon]::Question) -ne [Windows.Forms.DialogResult]::Yes) { return }
    $lblStatus.Text = '正在迁移，请勿关闭窗口或启动 ' + $script:BrowserName + '...'
    Write-GuiLog '开始迁移...'
    Run-Task -Action 'migrate' -Dst $dst
})
$form.Controls.Add($btnMigrate)

$btnCleanup = New-Object System.Windows.Forms.Button
$btnCleanup.Text = '清理备份'
$btnCleanup.Location = New-Object System.Drawing.Point(252, 230)
$btnCleanup.Size = New-Object System.Drawing.Size(110, 32)
$btnCleanup.add_Click({
    if ($script:Busy) { return }
    $msg = '即将永久删除备份目录：' + [Environment]::NewLine + $script:BackupDir + [Environment]::NewLine + [Environment]::NewLine
    $msg += '请在 ' + $script:BrowserName + ' 中确认书签、密码、扩展均正常后再清理。此操作不可恢复。' + [Environment]::NewLine + [Environment]::NewLine
    $msg += '确认删除？'
    if ([Windows.Forms.MessageBox]::Show($msg, '确认清理', [Windows.Forms.MessageBoxButtons]::YesNo, [Windows.Forms.MessageBoxIcon]::Warning) -ne [Windows.Forms.DialogResult]::Yes) { return }
    Write-GuiLog '开始清理备份...'
    Run-Task -Action 'cleanup' -Dst $txtDst.Text.Trim()
})
$form.Controls.Add($btnCleanup)

$btnElevate = New-Object System.Windows.Forms.Button
$btnElevate.Text = '以管理员身份重启'
$btnElevate.Location = New-Object System.Drawing.Point(370, 230)
$btnElevate.Size = New-Object System.Drawing.Size(140, 32)
$btnElevate.add_Click({
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = Join-Path $PSHOME 'powershell.exe'
    $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $script:ScriptPath + '"'
    $psi.Verb = 'RunAs'
    [Diagnostics.Process]::Start($psi) | Out-Null
    $form.Close()
})
$form.Controls.Add($btnElevate)

$btnExit = New-Object System.Windows.Forms.Button
$btnExit.Text = '退出'
$btnExit.Location = New-Object System.Drawing.Point(518, 230)
$btnExit.Size = New-Object System.Drawing.Size(118, 32)
$btnExit.add_Click({ $form.Close() })
$form.Controls.Add($btnExit)

$lblLog = New-Object System.Windows.Forms.Label
$lblLog.Text = '操作日志'
$lblLog.Location = New-Object System.Drawing.Point(16, 274)
$lblLog.Size = New-Object System.Drawing.Size(620, 22)
$form.Controls.Add($lblLog)

$txtLog = New-Object System.Windows.Forms.TextBox
$txtLog.Location = New-Object System.Drawing.Point(16, 296)
$txtLog.Size = New-Object System.Drawing.Size(620, 216)
$txtLog.Multiline = $true
$txtLog.ReadOnly = $true
$txtLog.ScrollBars = [Windows.Forms.ScrollBars]::Vertical
$txtLog.WordWrap = $true
$txtLog.BackColor = [Drawing.Color]::White
$form.Controls.Add($txtLog)

$progress = New-Object System.Windows.Forms.ProgressBar
$progress.Location = New-Object System.Drawing.Point(16, 520)
$progress.Size = New-Object System.Drawing.Size(620, 12)
$progress.Style = [Windows.Forms.ProgressBarStyle]::Marquee
$progress.Visible = $false
$form.Controls.Add($progress)

if (-not $isAdmin) {
    $btnMigrate.Enabled = $false
    $btnCleanup.Enabled = $false
    $btnElevate.Visible = $true
    $lblStatus.Text = '警告：当前不是管理员权限，无法执行迁移。请点击"以管理员身份重启"。'
    $lblStatus.ForeColor = [Drawing.Color]::Red
} else {
    $btnElevate.Visible = $false
    Write-GuiLog '已获取管理员权限，可以执行迁移。'
}

Write-GuiLog ('当前浏览器：' + $script:BrowserName + '  源路径：' + $script:SrcDir)
[Windows.Forms.Application]::Run($form)
