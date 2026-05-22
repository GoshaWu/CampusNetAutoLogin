Set-StrictMode -Version 2.0

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

[System.Windows.Forms.Application]::EnableVisualStyles()

$Script:AppName = 'CampusNetAutoLogin'
$Script:DisplayName = '校园网自动登录'
$Script:ConfigDir = Join-Path $env:APPDATA $Script:AppName
$Script:ConfigPath = Join-Path $Script:ConfigDir 'config.json'
$Script:RunKeyPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$Script:RunKeyName = 'CampusNetAutoLogin'
$Script:ScriptPath = if ($PSCommandPath) { $PSCommandPath } else { $MyInvocation.MyCommand.Path }
$Script:Timer = $null
$Script:NotifyIcon = $null
$Script:State = @{
    Running = $false
    InProgress = $false
    LastCheck = $null
    LastStatus = ''
    NextTimedLogin = $null
    PrimaryPasswordVisible = $false
    BackupPasswordVisible = $false
}
$Script:UiFontFamily = 'Microsoft YaHei UI'
$Script:UiColors = @{
    Page = [System.Drawing.Color]::FromArgb(246, 248, 252)
    Header = [System.Drawing.Color]::FromArgb(35, 88, 166)
    HeaderDark = [System.Drawing.Color]::FromArgb(27, 65, 122)
    Card = [System.Drawing.Color]::White
    Border = [System.Drawing.Color]::FromArgb(221, 228, 238)
    Text = [System.Drawing.Color]::FromArgb(31, 41, 55)
    Muted = [System.Drawing.Color]::FromArgb(99, 111, 129)
    Accent = [System.Drawing.Color]::FromArgb(37, 99, 235)
    AccentSoft = [System.Drawing.Color]::FromArgb(235, 242, 255)
    Success = [System.Drawing.Color]::FromArgb(22, 128, 76)
    Warning = [System.Drawing.Color]::FromArgb(190, 102, 0)
    Danger = [System.Drawing.Color]::FromArgb(190, 54, 54)
}

function New-DefaultConfig {
    [pscustomobject]@{
        LoginUrl = 'http://a.stu.edu.cn/ac_portal/login.php'
        TestUrl = 'http://www.msftconnecttest.com/connecttest.txt'
        ExpectedText = 'Microsoft Connect Test'
        TimeoutSeconds = 8
        VerifyDelaySeconds = 5
        MonitorEnabled = $true
        CheckIntervalSeconds = 60
        TimedLoginEnabled = $false
        TimedLoginIntervalMinutes = 30
        PrimaryUsername = ''
        PrimaryPasswordCipher = ''
        PrimaryMaxAttempts = 3
        BackupUsername = ''
        BackupPasswordCipher = ''
        BackupMaxAttempts = 2
        DirectMode = $true
        StartWithWindows = $false
        StartOnLaunch = $false
    }
}

function Get-ConfigValue {
    param(
        [object]$Config,
        [string]$Name,
        [object]$Fallback
    )

    if ($null -ne $Config -and $Config.PSObject.Properties.Name -contains $Name -and $null -ne $Config.$Name) {
        return $Config.$Name
    }

    return $Fallback
}

function Load-AppConfig {
    $defaults = New-DefaultConfig
    $saved = $null

    if (Test-Path -LiteralPath $Script:ConfigPath) {
        try {
            $saved = Get-Content -LiteralPath $Script:ConfigPath -Raw | ConvertFrom-Json
        }
        catch {
            $saved = $null
        }
    }

    [pscustomobject]@{
        LoginUrl = Get-ConfigValue $saved 'LoginUrl' $defaults.LoginUrl
        TestUrl = Get-ConfigValue $saved 'TestUrl' $defaults.TestUrl
        ExpectedText = Get-ConfigValue $saved 'ExpectedText' $defaults.ExpectedText
        TimeoutSeconds = [int](Get-ConfigValue $saved 'TimeoutSeconds' $defaults.TimeoutSeconds)
        VerifyDelaySeconds = [int](Get-ConfigValue $saved 'VerifyDelaySeconds' $defaults.VerifyDelaySeconds)
        MonitorEnabled = [bool](Get-ConfigValue $saved 'MonitorEnabled' $defaults.MonitorEnabled)
        CheckIntervalSeconds = [int](Get-ConfigValue $saved 'CheckIntervalSeconds' $defaults.CheckIntervalSeconds)
        TimedLoginEnabled = [bool](Get-ConfigValue $saved 'TimedLoginEnabled' $defaults.TimedLoginEnabled)
        TimedLoginIntervalMinutes = [int](Get-ConfigValue $saved 'TimedLoginIntervalMinutes' $defaults.TimedLoginIntervalMinutes)
        PrimaryUsername = [string](Get-ConfigValue $saved 'PrimaryUsername' $defaults.PrimaryUsername)
        PrimaryPasswordCipher = [string](Get-ConfigValue $saved 'PrimaryPasswordCipher' $defaults.PrimaryPasswordCipher)
        PrimaryMaxAttempts = [int](Get-ConfigValue $saved 'PrimaryMaxAttempts' $defaults.PrimaryMaxAttempts)
        BackupUsername = [string](Get-ConfigValue $saved 'BackupUsername' $defaults.BackupUsername)
        BackupPasswordCipher = [string](Get-ConfigValue $saved 'BackupPasswordCipher' $defaults.BackupPasswordCipher)
        BackupMaxAttempts = [int](Get-ConfigValue $saved 'BackupMaxAttempts' $defaults.BackupMaxAttempts)
        DirectMode = [bool](Get-ConfigValue $saved 'DirectMode' $defaults.DirectMode)
        StartWithWindows = [bool](Get-ConfigValue $saved 'StartWithWindows' $defaults.StartWithWindows)
        StartOnLaunch = [bool](Get-ConfigValue $saved 'StartOnLaunch' $defaults.StartOnLaunch)
    }
}

function Protect-Password {
    param([string]$PlainText)

    if ([string]::IsNullOrEmpty($PlainText)) {
        return ''
    }

    return (ConvertTo-SecureString -String $PlainText -AsPlainText -Force | ConvertFrom-SecureString)
}

function Unprotect-Password {
    param([string]$CipherText)

    if ([string]::IsNullOrWhiteSpace($CipherText)) {
        return ''
    }

    try {
        $secure = ConvertTo-SecureString -String $CipherText
        $ptr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        try {
            return [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
        }
        finally {
            [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)
        }
    }
    catch {
        return ''
    }
}

function Save-AppConfig {
    param([object]$Config)

    if (-not (Test-Path -LiteralPath $Script:ConfigDir)) {
        New-Item -ItemType Directory -Path $Script:ConfigDir -Force | Out-Null
    }

    $Config | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $Script:ConfigPath -Encoding UTF8
}

function Get-StartupCommand {
    $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    return ('"{0}" -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "{1}"' -f $powershell, $Script:ScriptPath)
}

function Set-Startup {
    param([bool]$Enabled)

    try {
        if ($Enabled) {
            if (-not (Test-Path -LiteralPath $Script:RunKeyPath)) {
                New-Item -Path $Script:RunKeyPath -Force | Out-Null
            }
            New-ItemProperty -Path $Script:RunKeyPath -Name $Script:RunKeyName -Value (Get-StartupCommand) -PropertyType String -Force | Out-Null
        }
        else {
            Remove-ItemProperty -Path $Script:RunKeyPath -Name $Script:RunKeyName -ErrorAction SilentlyContinue
        }
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show("无法更新开机启动设置：$($_.Exception.Message)", $Script:DisplayName, 'OK', 'Warning') | Out-Null
    }
}

function Get-AppFont {
    param(
        [float]$Size = 9,
        [System.Drawing.FontStyle]$Style = [System.Drawing.FontStyle]::Regular
    )

    return New-Object System.Drawing.Font($Script:UiFontFamily, $Size, $Style)
}

function New-AppCard {
    param(
        [System.Windows.Forms.Control]$Parent,
        [string]$Title,
        [string]$Subtitle,
        [int]$X,
        [int]$Y,
        [int]$W,
        [int]$H
    )

    $card = New-Object System.Windows.Forms.Panel
    $card.Location = New-Object System.Drawing.Point($X, $Y)
    $card.Size = New-Object System.Drawing.Size($W, $H)
    $card.BackColor = $Script:UiColors.Card
    $card.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    $card.Anchor = [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
    [void]$Parent.Controls.Add($card)

    $accent = New-Object System.Windows.Forms.Panel
    $accent.Location = New-Object System.Drawing.Point(0, 0)
    $accent.Size = New-Object System.Drawing.Size(5, $H)
    $accent.BackColor = $Script:UiColors.Accent
    [void]$card.Controls.Add($accent)

    $titleLabel = New-Object System.Windows.Forms.Label
    $titleLabel.Text = $Title
    $titleLabel.Location = New-Object System.Drawing.Point(20, 12)
    $titleLabel.Size = New-Object System.Drawing.Size(($W - 40), 24)
    $titleLabel.Font = Get-AppFont 11 ([System.Drawing.FontStyle]::Bold)
    $titleLabel.ForeColor = $Script:UiColors.Text
    $titleLabel.BackColor = $Script:UiColors.Card
    [void]$card.Controls.Add($titleLabel)

    if (-not [string]::IsNullOrWhiteSpace($Subtitle)) {
        $subtitleLabel = New-Object System.Windows.Forms.Label
        $subtitleLabel.Text = $Subtitle
        $subtitleLabel.Location = New-Object System.Drawing.Point(20, 36)
        $subtitleLabel.Size = New-Object System.Drawing.Size(($W - 40), 20)
        $subtitleLabel.Font = Get-AppFont 8.5
        $subtitleLabel.ForeColor = $Script:UiColors.Muted
        $subtitleLabel.BackColor = $Script:UiColors.Card
        [void]$card.Controls.Add($subtitleLabel)
    }

    return $card
}

function New-AppLabel {
    param([System.Windows.Forms.Control]$Parent, [string]$Text, [int]$X, [int]$Y, [int]$W = 120, [int]$H = 22)

    $label = New-Object System.Windows.Forms.Label
    $label.Text = $Text
    $label.Location = New-Object System.Drawing.Point($X, $Y)
    $label.Size = New-Object System.Drawing.Size($W, $H)
    $label.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    $label.Font = Get-AppFont 9
    $label.ForeColor = $Script:UiColors.Muted
    $label.BackColor = $Parent.BackColor
    [void]$Parent.Controls.Add($label)
    return $label
}

function New-AppTextBox {
    param(
        [System.Windows.Forms.Control]$Parent,
        [int]$X,
        [int]$Y,
        [int]$W,
        [string]$Text = '',
        [switch]$Password
    )

    $textBox = New-Object System.Windows.Forms.TextBox
    $textBox.Location = New-Object System.Drawing.Point($X, $Y)
    $textBox.Size = New-Object System.Drawing.Size($W, 25)
    $textBox.Text = $Text
    $textBox.Font = Get-AppFont 9.5
    $textBox.ForeColor = $Script:UiColors.Text
    $textBox.BackColor = [System.Drawing.Color]::White
    $textBox.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    if ($Password) {
        $textBox.UseSystemPasswordChar = $true
    }
    [void]$Parent.Controls.Add($textBox)
    return $textBox
}

function New-AppCheckBox {
    param([System.Windows.Forms.Control]$Parent, [string]$Text, [int]$X, [int]$Y, [int]$W = 220, [bool]$Checked = $false)

    $checkBox = New-Object System.Windows.Forms.CheckBox
    $checkBox.Text = $Text
    $checkBox.Location = New-Object System.Drawing.Point($X, $Y)
    $checkBox.Size = New-Object System.Drawing.Size($W, 24)
    $checkBox.Checked = $Checked
    $checkBox.Font = Get-AppFont 9
    $checkBox.ForeColor = $Script:UiColors.Text
    $checkBox.BackColor = $Parent.BackColor
    [void]$Parent.Controls.Add($checkBox)
    return $checkBox
}

function New-AppButton {
    param([System.Windows.Forms.Control]$Parent, [string]$Text, [int]$X, [int]$Y, [int]$W = 110, [int]$H = 34, [string]$Kind = 'Secondary')

    $button = New-Object System.Windows.Forms.Button
    $button.Text = $Text
    $button.Location = New-Object System.Drawing.Point($X, $Y)
    $button.Size = New-Object System.Drawing.Size($W, $H)
    $button.Font = Get-AppFont 9.5 ([System.Drawing.FontStyle]::Bold)
    $button.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $button.FlatAppearance.BorderSize = 0
    $button.Cursor = [System.Windows.Forms.Cursors]::Hand

    if ($Kind -eq 'Primary') {
        $button.BackColor = $Script:UiColors.Accent
        $button.ForeColor = [System.Drawing.Color]::White
    }
    elseif ($Kind -eq 'Danger') {
        $button.BackColor = $Script:UiColors.Danger
        $button.ForeColor = [System.Drawing.Color]::White
    }
    else {
        $button.BackColor = $Script:UiColors.AccentSoft
        $button.ForeColor = $Script:UiColors.HeaderDark
    }

    [void]$Parent.Controls.Add($button)
    return $button
}

function New-EyeButton {
    param([System.Windows.Forms.Control]$Parent, [int]$X, [int]$Y)

    $button = New-Object System.Windows.Forms.Button
    $button.Text = '👁'
    $button.Location = New-Object System.Drawing.Point($X, $Y)
    $button.Size = New-Object System.Drawing.Size(30, 25)
    $button.Font = New-Object System.Drawing.Font('Segoe UI Symbol', 8.5, [System.Drawing.FontStyle]::Regular)
    $button.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $button.FlatAppearance.BorderSize = 1
    $button.FlatAppearance.BorderColor = $Script:UiColors.Border
    $button.BackColor = [System.Drawing.Color]::White
    $button.ForeColor = $Script:UiColors.Muted
    $button.Cursor = [System.Windows.Forms.Cursors]::Hand
    [void]$Parent.Controls.Add($button)
    return $button
}

function New-AppNumeric {
    param(
        [System.Windows.Forms.Control]$Parent,
        [int]$X,
        [int]$Y,
        [int]$W,
        [int]$Minimum,
        [int]$Maximum,
        [int]$Value
    )

    $numeric = New-Object System.Windows.Forms.NumericUpDown
    $numeric.Location = New-Object System.Drawing.Point($X, $Y)
    $numeric.Size = New-Object System.Drawing.Size($W, 24)
    $numeric.Minimum = $Minimum
    $numeric.Maximum = $Maximum
    $numeric.Font = Get-AppFont 9.5
    $numeric.ForeColor = $Script:UiColors.Text
    $numeric.BackColor = [System.Drawing.Color]::White
    if ($Value -lt $Minimum) { $Value = $Minimum }
    if ($Value -gt $Maximum) { $Value = $Maximum }
    $numeric.Value = $Value
    [void]$Parent.Controls.Add($numeric)
    return $numeric
}

function Wait-WithEvents {
    param([int]$Seconds)

    $loops = [Math]::Max(1, $Seconds * 4)
    for ($i = 0; $i -lt $loops; $i++) {
        Start-Sleep -Milliseconds 250
        [System.Windows.Forms.Application]::DoEvents()
    }
}

function Limit-NotifyText {
    param([string]$Text)

    if ($Text.Length -gt 62) {
        return $Text.Substring(0, 62)
    }
    return $Text
}

$config = Load-AppConfig

$form = New-Object System.Windows.Forms.Form
$form.Text = $Script:DisplayName
$form.StartPosition = 'CenterScreen'
$form.Size = New-Object System.Drawing.Size(900, 780)
$form.MinimumSize = New-Object System.Drawing.Size(820, 680)
$form.BackColor = $Script:UiColors.Page
$form.Font = Get-AppFont 9

$header = New-Object System.Windows.Forms.Panel
$header.Location = New-Object System.Drawing.Point(0, 0)
$header.Size = New-Object System.Drawing.Size(900, 86)
$header.Anchor = [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
$header.BackColor = $Script:UiColors.Header
[void]$form.Controls.Add($header)

$title = New-Object System.Windows.Forms.Label
$title.Text = '校园网自动登录'
$title.Location = New-Object System.Drawing.Point(24, 16)
$title.Size = New-Object System.Drawing.Size(420, 34)
$title.Font = Get-AppFont 20 ([System.Drawing.FontStyle]::Bold)
$title.ForeColor = [System.Drawing.Color]::White
$title.BackColor = $Script:UiColors.Header
[void]$header.Controls.Add($title)

$subtitle = New-Object System.Windows.Forms.Label
$subtitle.Text = '断网检测、自动重登、备用账号切换'
$subtitle.Location = New-Object System.Drawing.Point(27, 52)
$subtitle.Size = New-Object System.Drawing.Size(480, 22)
$subtitle.Font = Get-AppFont 9.5
$subtitle.ForeColor = [System.Drawing.Color]::FromArgb(222, 235, 255)
$subtitle.BackColor = $Script:UiColors.Header
[void]$header.Controls.Add($subtitle)

$portalCard = New-AppCard $form '认证门户' '填写校园网登录接口，以及用于判断外网是否恢复的检测地址。' 18 102 846 156

New-AppLabel $portalCard '登录地址' 24 60 90 | Out-Null
$txtLoginUrl = New-AppTextBox $portalCard 126 58 690 $config.LoginUrl
New-AppLabel $portalCard '检测地址' 24 94 90 | Out-Null
$txtTestUrl = New-AppTextBox $portalCard 126 92 690 $config.TestUrl
New-AppLabel $portalCard '期望内容' 24 128 90 | Out-Null
$txtExpectedText = New-AppTextBox $portalCard 126 126 286 $config.ExpectedText
New-AppLabel $portalCard '超时秒数' 434 128 76 | Out-Null
$numTimeout = New-AppNumeric $portalCard 514 126 70 2 60 $config.TimeoutSeconds
New-AppLabel $portalCard '验证等待' 620 128 76 | Out-Null
$numVerifyDelay = New-AppNumeric $portalCard 700 126 70 1 60 $config.VerifyDelaySeconds
New-AppLabel $portalCard '秒' 776 128 30 | Out-Null

$accountsCard = New-AppCard $form '账号设置' '先尝试主账号；仍无法联网时，再自动尝试备用账号。' 18 270 846 166

New-AppLabel $accountsCard '主账号' 24 62 88 | Out-Null
$txtPrimaryUser = New-AppTextBox $accountsCard 126 60 220 $config.PrimaryUsername
New-AppLabel $accountsCard '密码' 370 62 60 | Out-Null
$txtPrimaryPass = New-AppTextBox $accountsCard 438 60 174 (Unprotect-Password $config.PrimaryPasswordCipher) -Password
$buttonPrimaryEye = New-EyeButton $accountsCard 614 60
New-AppLabel $accountsCard '尝试次数' 674 62 70 | Out-Null
$numPrimaryAttempts = New-AppNumeric $accountsCard 754 60 58 1 20 $config.PrimaryMaxAttempts

New-AppLabel $accountsCard '备用账号' 24 102 88 | Out-Null
$txtBackupUser = New-AppTextBox $accountsCard 126 100 220 $config.BackupUsername
New-AppLabel $accountsCard '密码' 370 102 60 | Out-Null
$txtBackupPass = New-AppTextBox $accountsCard 438 100 174 (Unprotect-Password $config.BackupPasswordCipher) -Password
$buttonBackupEye = New-EyeButton $accountsCard 614 100
New-AppLabel $accountsCard '尝试次数' 674 102 70 | Out-Null
$numBackupAttempts = New-AppNumeric $accountsCard 754 100 58 1 20 $config.BackupMaxAttempts

$automationCard = New-AppCard $form '自动化' '可按固定间隔检查网络，也可定时主动登录。' 18 448 846 118

$chkMonitor = New-AppCheckBox $automationCard '断网检测并自动重登' 24 62 190 $config.MonitorEnabled
New-AppLabel $automationCard '每' 238 64 24 | Out-Null
$numCheckInterval = New-AppNumeric $automationCard 264 62 72 10 3600 $config.CheckIntervalSeconds
New-AppLabel $automationCard '秒检测一次' 344 64 88 | Out-Null

$chkTimedLogin = New-AppCheckBox $automationCard '定时主动登录' 24 92 140 $config.TimedLoginEnabled
New-AppLabel $automationCard '每' 238 94 24 | Out-Null
$numTimedInterval = New-AppNumeric $automationCard 264 92 72 1 1440 $config.TimedLoginIntervalMinutes
New-AppLabel $automationCard '分钟登录一次' 344 94 100 | Out-Null

$chkStartup = New-AppCheckBox $automationCard '开机启动' 510 62 110 $config.StartWithWindows
$chkStartOnLaunch = New-AppCheckBox $automationCard '打开后自动开始' 510 92 150 $config.StartOnLaunch
$chkDirectMode = New-AppCheckBox $automationCard '直连模式' 660 62 110 $config.DirectMode

$buttonStart = New-AppButton $form '开始守护' 18 582 112 36 'Primary'
$buttonStop = New-AppButton $form '停止' 138 582 88 36 'Danger'
$buttonLoginNow = New-AppButton $form '立即登录' 236 582 104 36
$buttonTestNow = New-AppButton $form '测试网络' 350 582 104 36
$buttonSave = New-AppButton $form '保存设置' 464 582 104 36
$buttonOpenConfig = New-AppButton $form '配置目录' 578 582 104 36

$labelStatus = New-Object System.Windows.Forms.Label
$labelStatus.Text = '状态：已停止'
$labelStatus.Location = New-Object System.Drawing.Point(18, 632)
$labelStatus.Size = New-Object System.Drawing.Size(846, 28)
$labelStatus.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
$labelStatus.Font = Get-AppFont 10 ([System.Drawing.FontStyle]::Bold)
$labelStatus.ForeColor = $Script:UiColors.Muted
$labelStatus.BackColor = $Script:UiColors.Page
[void]$form.Controls.Add($labelStatus)

$txtLog = New-Object System.Windows.Forms.TextBox
$txtLog.Location = New-Object System.Drawing.Point(18, 666)
$txtLog.Size = New-Object System.Drawing.Size(846, 70)
$txtLog.Anchor = [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right -bor [System.Windows.Forms.AnchorStyles]::Bottom
$txtLog.Multiline = $true
$txtLog.ScrollBars = 'Vertical'
$txtLog.ReadOnly = $true
$txtLog.Font = New-Object System.Drawing.Font('Consolas', 9)
$txtLog.ForeColor = $Script:UiColors.Text
$txtLog.BackColor = [System.Drawing.Color]::White
$txtLog.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
[void]$form.Controls.Add($txtLog)

function Write-Log {
    param([string]$Message)

    $line = '{0:yyyy-MM-dd HH:mm:ss}  {1}' -f (Get-Date), $Message
    $txtLog.AppendText($line + [Environment]::NewLine)
    if ($txtLog.TextLength -gt 200000) {
        $txtLog.Clear()
        $txtLog.AppendText($line + [Environment]::NewLine)
    }
}

function Set-Status {
    param([string]$Text, [System.Drawing.Color]$Color)

    if ($null -eq $Color) {
        $Color = [System.Drawing.Color]::Black
    }
    $labelStatus.Text = '状态：' + $Text
    $labelStatus.ForeColor = $Color
    if ($null -ne $Script:NotifyIcon) {
        $Script:NotifyIcon.Text = Limit-NotifyText ($Script:DisplayName + ' - ' + $Text)
    }
}

function Update-Buttons {
    $buttonStart.Enabled = -not $Script:State.Running
    $buttonStop.Enabled = $Script:State.Running
    $buttonLoginNow.Enabled = -not $Script:State.InProgress
    $buttonTestNow.Enabled = -not $Script:State.InProgress
}

function Update-PasswordVisibility {
    $txtPrimaryPass.UseSystemPasswordChar = -not [bool]$Script:State.PrimaryPasswordVisible
    $txtBackupPass.UseSystemPasswordChar = -not [bool]$Script:State.BackupPasswordVisible

    if ([bool]$Script:State.PrimaryPasswordVisible) {
        $buttonPrimaryEye.BackColor = $Script:UiColors.AccentSoft
        $buttonPrimaryEye.ForeColor = $Script:UiColors.Accent
    }
    else {
        $buttonPrimaryEye.BackColor = [System.Drawing.Color]::White
        $buttonPrimaryEye.ForeColor = $Script:UiColors.Muted
    }

    if ([bool]$Script:State.BackupPasswordVisible) {
        $buttonBackupEye.BackColor = $Script:UiColors.AccentSoft
        $buttonBackupEye.ForeColor = $Script:UiColors.Accent
    }
    else {
        $buttonBackupEye.BackColor = [System.Drawing.Color]::White
        $buttonBackupEye.ForeColor = $Script:UiColors.Muted
    }
}

function Read-RuntimeConfig {
    [pscustomobject]@{
        LoginUrl = $txtLoginUrl.Text.Trim()
        TestUrl = $txtTestUrl.Text.Trim()
        ExpectedText = $txtExpectedText.Text
        TimeoutSeconds = [int]$numTimeout.Value
        VerifyDelaySeconds = [int]$numVerifyDelay.Value
        MonitorEnabled = $chkMonitor.Checked
        CheckIntervalSeconds = [int]$numCheckInterval.Value
        TimedLoginEnabled = $chkTimedLogin.Checked
        TimedLoginIntervalMinutes = [int]$numTimedInterval.Value
        PrimaryUsername = $txtPrimaryUser.Text.Trim()
        PrimaryPassword = $txtPrimaryPass.Text
        PrimaryMaxAttempts = [int]$numPrimaryAttempts.Value
        BackupUsername = $txtBackupUser.Text.Trim()
        BackupPassword = $txtBackupPass.Text
        BackupMaxAttempts = [int]$numBackupAttempts.Value
        DirectMode = $chkDirectMode.Checked
        StartWithWindows = $chkStartup.Checked
        StartOnLaunch = $chkStartOnLaunch.Checked
    }
}

function Read-SaveConfig {
    [pscustomobject]@{
        LoginUrl = $txtLoginUrl.Text.Trim()
        TestUrl = $txtTestUrl.Text.Trim()
        ExpectedText = $txtExpectedText.Text
        TimeoutSeconds = [int]$numTimeout.Value
        VerifyDelaySeconds = [int]$numVerifyDelay.Value
        MonitorEnabled = $chkMonitor.Checked
        CheckIntervalSeconds = [int]$numCheckInterval.Value
        TimedLoginEnabled = $chkTimedLogin.Checked
        TimedLoginIntervalMinutes = [int]$numTimedInterval.Value
        PrimaryUsername = $txtPrimaryUser.Text.Trim()
        PrimaryPasswordCipher = Protect-Password $txtPrimaryPass.Text
        PrimaryMaxAttempts = [int]$numPrimaryAttempts.Value
        BackupUsername = $txtBackupUser.Text.Trim()
        BackupPasswordCipher = Protect-Password $txtBackupPass.Text
        BackupMaxAttempts = [int]$numBackupAttempts.Value
        DirectMode = $chkDirectMode.Checked
        StartWithWindows = $chkStartup.Checked
        StartOnLaunch = $chkStartOnLaunch.Checked
    }
}

function Test-UriText {
    param([string]$Value)

    $uri = $null
    return [System.Uri]::TryCreate($Value, [System.UriKind]::Absolute, [ref]$uri)
}

function Validate-Settings {
    param([object]$Config, [bool]$RequireAccount)

    if (-not (Test-UriText $Config.LoginUrl)) {
        [System.Windows.Forms.MessageBox]::Show('登录地址不是有效 URL。', $Script:DisplayName, 'OK', 'Warning') | Out-Null
        return $false
    }
    if (-not (Test-UriText $Config.TestUrl)) {
        [System.Windows.Forms.MessageBox]::Show('检测地址不是有效 URL。', $Script:DisplayName, 'OK', 'Warning') | Out-Null
        return $false
    }
    if ($RequireAccount -and ([string]::IsNullOrWhiteSpace($Config.PrimaryUsername) -or [string]::IsNullOrWhiteSpace($Config.PrimaryPassword))) {
        [System.Windows.Forms.MessageBox]::Show('请先填写主账号和主账号密码。', $Script:DisplayName, 'OK', 'Warning') | Out-Null
        return $false
    }

    return $true
}

function Get-CurlPath {
    $curlPath = Join-Path $env:SystemRoot 'System32\curl.exe'
    if (Test-Path -LiteralPath $curlPath) {
        return $curlPath
    }

    return 'curl.exe'
}

function Save-FromUi {
    param([switch]$Silent, [switch]$SkipValidation)

    $runtime = Read-RuntimeConfig
    if (-not $SkipValidation) {
        if (-not (Validate-Settings $runtime $false)) {
            return $false
        }
    }

    $saveConfig = Read-SaveConfig
    Save-AppConfig $saveConfig
    Set-Startup $saveConfig.StartWithWindows
    if (-not $Silent) {
        Write-Log ('设置已保存到 ' + $Script:ConfigPath)
    }
    return $true
}

function Test-Connectivity {
    param([object]$Config)

    $tempFile = $null
    try {
        $tempFile = [System.IO.Path]::GetTempFileName()
        $timeout = [Math]::Max(2, [int]$Config.TimeoutSeconds)
        $args = @(
            '-sS',
            '--http1.1',
            '--connect-timeout', [string]$timeout,
            '--max-time', [string]$timeout,
            '--max-redirs', '8',
            '-L',
            '-o', $tempFile,
            '-w', "%{http_code}`n%{url_effective}`n%{content_type}",
            $Config.TestUrl
        )

        if ($Config.DirectMode) {
            $args = @('--noproxy', '*') + $args
        }

        $output = & (Get-CurlPath) @args 2>$null
        if ($LASTEXITCODE -ne 0) {
            return $false
        }

        $meta = @($output)
        $code = 0
        if ($meta.Count -ge 1 -and $meta[0] -match '^\d{3}$') {
            $code = [int]$meta[0]
        }

        if ($code -lt 200 -or $code -ge 400) {
            return $false
        }

        $content = ''
        if (Test-Path -LiteralPath $tempFile) {
            $content = [System.IO.File]::ReadAllText($tempFile)
        }
        $contentLower = $content.ToLowerInvariant()
        $finalUrl = if ($meta.Count -ge 2) { [string]$meta[1] } else { [string]$Config.TestUrl }
        $contentType = if ($meta.Count -ge 3) { [string]$meta[2] } else { '' }
        $finalUrlLower = $finalUrl.ToLowerInvariant()

        $loginHost = ''
        if (-not [string]::IsNullOrWhiteSpace($Config.LoginUrl)) {
            try {
                $loginHost = ([System.Uri]$Config.LoginUrl).Host.ToLowerInvariant()
            }
            catch {
                $loginHost = ''
            }
        }

        if (-not [string]::IsNullOrWhiteSpace($loginHost) -and $finalUrlLower.Contains($loginHost)) {
            return $false
        }

        $portalSignals = @('a.stu.edu.cn', 'ac_portal', 'portal', 'srun', 'wifidog', '认证', '登录')
        foreach ($signal in $portalSignals) {
            if ($finalUrlLower.Contains($signal.ToLowerInvariant()) -or $contentLower.Contains($signal.ToLowerInvariant())) {
                return $false
            }
        }

        $expected = [string]$Config.ExpectedText
        if (-not [string]::IsNullOrWhiteSpace($expected)) {
            return ($content -like ('*' + $expected + '*'))
        }

        if ($contentType -match 'text/plain' -and $content.Trim().Length -gt 0) {
            return $true
        }

        if ($contentLower -match '<!doctype|<html|</html>') {
            return -not ($contentLower -match 'login|signin|identity|auth|captive')
        }

        return $true
    }
    catch {
        return $false
    }
    finally {
        if (-not [string]::IsNullOrWhiteSpace($tempFile) -and (Test-Path -LiteralPath $tempFile)) {
            Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue
        }
    }
}

function ConvertTo-FormValue {
    param([string]$Value)

    if ($null -eq $Value) {
        return ''
    }

    return [System.Uri]::EscapeDataString($Value)
}

function Test-LoginResponseSuccess {
    param(
        [string]$Content,
        [string]$AccountLabel
    )

    if ([string]::IsNullOrWhiteSpace($Content)) {
        return $true
    }

    $contentLower = $Content.ToLowerInvariant()
    $failureSignals = @(
        '"success":false',
        '"success": false',
        '"result":0',
        '"result": 0',
        '密码错误',
        '密码不正确',
        '用户名或密码',
        '账号或密码',
        '认证失败',
        '登录失败',
        'login failed',
        'login fail',
        'incorrect',
        'invalid password',
        'invalid user',
        'authentication failed',
        '余额不足',
        '流量不足',
        '已欠费',
        '欠费'
    )

    foreach ($signal in $failureSignals) {
        if ($contentLower.Contains($signal.ToLowerInvariant())) {
            Write-Log ('{0}登录返回失败信息：{1}' -f $AccountLabel, $signal)
            return $false
        }
    }

    return $true
}

function Invoke-PortalLogin {
    param(
        [object]$Config,
        [string]$AccountLabel,
        [string]$Username,
        [string]$Password
    )

    $tempFile = $null
    try {
        $body = 'opr=pwdLogin&userName={0}&pwd={1}&rememberPwd=0' -f (ConvertTo-FormValue $Username), (ConvertTo-FormValue $Password)
        $tempFile = [System.IO.Path]::GetTempFileName()
        $timeout = [Math]::Max(2, [int]$Config.TimeoutSeconds)
        $args = @(
            '-sS',
            '--http1.1',
            '--connect-timeout', [string]$timeout,
            '--max-time', [string]$timeout,
            '-o', $tempFile,
            '-w', '%{http_code}',
            '-H', 'Content-Type: application/x-www-form-urlencoded',
            '-X', 'POST',
            '--data', $body,
            $Config.LoginUrl
        )

        if ($Config.DirectMode) {
            $args = @('--noproxy', '*') + $args
        }

        $output = & (Get-CurlPath) @args 2>&1
        $exitCode = $LASTEXITCODE
        $outputText = (($output | Out-String).Trim())
        $httpCode = 0
        if ($outputText -match '(\d{3})$') {
            $httpCode = [int]$Matches[1]
        }

        if ($exitCode -ne 0) {
            Write-Log ('{0}登录请求发送失败：curl 退出码 {1}。{2}' -f $AccountLabel, $exitCode, $outputText)
            return $false
        }

        if ($httpCode -ge 200 -and $httpCode -lt 400) {
            $responseContent = ''
            if (Test-Path -LiteralPath $tempFile) {
                $responseContent = [System.IO.File]::ReadAllText($tempFile)
            }

            if (-not (Test-LoginResponseSuccess $responseContent $AccountLabel)) {
                return $false
            }

            Write-Log ('已使用{0}发送登录请求，HTTP {1}。' -f $AccountLabel, $httpCode)
            return $true
        }

        if ($httpCode -eq 502) {
            Write-Log ('{0}登录请求被认证网关返回 502。已改用 curl 方式提交；若仍出现，通常是校园网认证服务临时异常或登录地址当前不可用。' -f $AccountLabel)
        }
        else {
            Write-Log ('{0}登录请求未成功，HTTP {1}。' -f $AccountLabel, $httpCode)
        }
        return $false
    }
    catch {
        Write-Log ('{0}登录请求失败：{1}' -f $AccountLabel, $_.Exception.Message)
        return $false
    }
    finally {
        if (-not [string]::IsNullOrWhiteSpace($tempFile) -and (Test-Path -LiteralPath $tempFile)) {
            Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue
        }
    }
}

function Try-AccountSequence {
    param(
        [object]$Config,
        [string]$AccountLabel,
        [string]$Username,
        [string]$Password,
        [int]$Attempts
    )

    if ([string]::IsNullOrWhiteSpace($Username) -or [string]::IsNullOrWhiteSpace($Password)) {
        Write-Log ($AccountLabel + '未配置，跳过。')
        return $false
    }

    for ($i = 1; $i -le $Attempts; $i++) {
        Write-Log ('{0}登录尝试 {1}/{2}。' -f $AccountLabel, $i, $Attempts)
        if (Invoke-PortalLogin $Config $AccountLabel $Username $Password) {
            Wait-WithEvents $Config.VerifyDelaySeconds
            if (Test-Connectivity $Config) {
                $Script:State.LastStatus = 'connected'
                Set-Status ($AccountLabel + '已恢复联网') $Script:UiColors.Success
                Write-Log ($AccountLabel + '登录后已确认网络恢复。')
                return $true
            }
            Write-Log ($AccountLabel + '登录后仍未恢复联网。')
        }
    }

    return $false
}

function Start-Recovery {
    param([string]$Reason)

    if ($Script:State.InProgress) {
        return
    }

    $restartTimer = $false
    if ($null -ne $Script:Timer -and $Script:Timer.Enabled) {
        $Script:Timer.Stop()
        $restartTimer = $true
    }

    $Script:State.InProgress = $true
    Update-Buttons

    try {
        $configNow = Read-RuntimeConfig
        if (-not (Validate-Settings $configNow $true)) {
            return
        }

        Set-Status '正在重新登录' $Script:UiColors.Warning
        Write-Log $Reason

        if (Try-AccountSequence $configNow '主账号' $configNow.PrimaryUsername $configNow.PrimaryPassword $configNow.PrimaryMaxAttempts) {
            return
        }

        if (Try-AccountSequence $configNow '备用账号' $configNow.BackupUsername $configNow.BackupPassword $configNow.BackupMaxAttempts) {
            return
        }

        $Script:State.LastStatus = 'offline'
        Set-Status '所有账号尝试后仍离线' $Script:UiColors.Danger
        Write-Log '所有已配置账号都未能恢复联网。'
    }
    finally {
        $Script:State.InProgress = $false
        if ($restartTimer -and $Script:State.Running) {
            $Script:Timer.Start()
        }
        Update-Buttons
    }
}

function Start-Automation {
    $configNow = Read-RuntimeConfig
    if (-not (Validate-Settings $configNow $true)) {
        return
    }
    if (-not (Save-FromUi -Silent)) {
        return
    }

    $Script:State.Running = $true
    $Script:State.LastCheck = $null
    $Script:State.LastStatus = ''
    if ($configNow.TimedLoginEnabled) {
        $Script:State.NextTimedLogin = (Get-Date).AddMinutes([double]$configNow.TimedLoginIntervalMinutes)
    }
    else {
        $Script:State.NextTimedLogin = $null
    }

    $Script:Timer.Start()
    Set-Status '运行中' $Script:UiColors.Success
    Write-Log '自动守护已开始。'
    Update-Buttons
}

function Stop-Automation {
    $Script:State.Running = $false
    $Script:State.InProgress = $false
    if ($null -ne $Script:Timer) {
        $Script:Timer.Stop()
    }
    Set-Status '已停止' $Script:UiColors.Muted
    Write-Log '自动守护已停止。'
    Update-Buttons
}

function Handle-TimerTick {
    if (-not $Script:State.Running -or $Script:State.InProgress) {
        return
    }

    $configNow = Read-RuntimeConfig
    $now = Get-Date

    if ($configNow.TimedLoginEnabled -and $null -ne $Script:State.NextTimedLogin -and $now -ge $Script:State.NextTimedLogin) {
        $Script:State.NextTimedLogin = $now.AddMinutes([double]$configNow.TimedLoginIntervalMinutes)
        Start-Recovery '已触发定时登录。'
        return
    }

    if ($configNow.MonitorEnabled) {
        $due = ($null -eq $Script:State.LastCheck) -or (($now - $Script:State.LastCheck).TotalSeconds -ge [double]$configNow.CheckIntervalSeconds)
        if ($due) {
            $Script:State.LastCheck = $now
            if (Test-Connectivity $configNow) {
                if ($Script:State.LastStatus -ne 'connected') {
                    Write-Log '网络检测正常。'
                }
                $Script:State.LastStatus = 'connected'
                Set-Status '已联网' $Script:UiColors.Success
            }
            else {
                $Script:State.LastStatus = 'offline'
                Set-Status '检测到断网，正在重登' $Script:UiColors.Warning
                Start-Recovery '网络检测失败，开始重新登录。'
            }
        }
    }
}

$Script:Timer = New-Object System.Windows.Forms.Timer
$Script:Timer.Interval = 1000
$Script:Timer.Add_Tick({ Handle-TimerTick })

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$itemOpen = $menu.Items.Add('打开窗口')
$itemStart = $menu.Items.Add('开始守护')
$itemStop = $menu.Items.Add('停止')
[void]$menu.Items.Add('-')
$itemExit = $menu.Items.Add('退出')

$Script:NotifyIcon = New-Object System.Windows.Forms.NotifyIcon
$Script:NotifyIcon.Icon = [System.Drawing.SystemIcons]::Application
$Script:NotifyIcon.Text = $Script:DisplayName
$Script:NotifyIcon.Visible = $true
$Script:NotifyIcon.ContextMenuStrip = $menu

$showWindow = {
    $form.Show()
    $form.WindowState = [System.Windows.Forms.FormWindowState]::Normal
    $form.Activate()
}

$itemOpen.Add_Click($showWindow)
$itemStart.Add_Click({ Start-Automation })
$itemStop.Add_Click({ Stop-Automation })
$itemExit.Add_Click({
    $Script:NotifyIcon.Visible = $false
    $form.Close()
})
$Script:NotifyIcon.Add_DoubleClick($showWindow)

$form.Add_Resize({
    if ($form.WindowState -eq [System.Windows.Forms.FormWindowState]::Minimized) {
        $form.Hide()
    }
})

$buttonStart.Add_Click({ Start-Automation })
$buttonStop.Add_Click({ Stop-Automation })
$buttonSave.Add_Click({ Save-FromUi | Out-Null })
$buttonLoginNow.Add_Click({
    Save-FromUi -Silent | Out-Null
    Start-Recovery '已手动触发登录。'
})
$buttonTestNow.Add_Click({
    $configNow = Read-RuntimeConfig
    if (-not (Validate-Settings $configNow $false)) {
        return
    }
    Set-Status '正在测试网络' $Script:UiColors.Warning
    if (Test-Connectivity $configNow) {
        $Script:State.LastStatus = 'connected'
        Set-Status '已联网' $Script:UiColors.Success
        Write-Log '手动网络测试成功。'
    }
    else {
        $Script:State.LastStatus = 'offline'
        Set-Status '离线或被认证页拦截' $Script:UiColors.Danger
        Write-Log '手动网络测试失败。'
    }
})
$buttonOpenConfig.Add_Click({
    if (-not (Test-Path -LiteralPath $Script:ConfigDir)) {
        New-Item -ItemType Directory -Path $Script:ConfigDir -Force | Out-Null
    }
    Start-Process -FilePath $Script:ConfigDir
})

$txtLoginUrl.Add_TextChanged({ Save-FromUi -Silent -SkipValidation | Out-Null })
$txtTestUrl.Add_TextChanged({ Save-FromUi -Silent -SkipValidation | Out-Null })
$txtExpectedText.Add_TextChanged({ Save-FromUi -Silent -SkipValidation | Out-Null })
$txtPrimaryUser.Add_TextChanged({ Save-FromUi -Silent -SkipValidation | Out-Null })
$txtPrimaryPass.Add_TextChanged({ Save-FromUi -Silent -SkipValidation | Out-Null })
$txtBackupUser.Add_TextChanged({ Save-FromUi -Silent -SkipValidation | Out-Null })
$txtBackupPass.Add_TextChanged({ Save-FromUi -Silent -SkipValidation | Out-Null })
$numTimeout.Add_ValueChanged({ Save-FromUi -Silent -SkipValidation | Out-Null })
$numVerifyDelay.Add_ValueChanged({ Save-FromUi -Silent -SkipValidation | Out-Null })
$numPrimaryAttempts.Add_ValueChanged({ Save-FromUi -Silent -SkipValidation | Out-Null })
$numBackupAttempts.Add_ValueChanged({ Save-FromUi -Silent -SkipValidation | Out-Null })
$numCheckInterval.Add_ValueChanged({ Save-FromUi -Silent -SkipValidation | Out-Null })
$numTimedInterval.Add_ValueChanged({ Save-FromUi -Silent -SkipValidation | Out-Null })
$chkMonitor.Add_CheckedChanged({ Save-FromUi -Silent -SkipValidation | Out-Null })
$chkTimedLogin.Add_CheckedChanged({ Save-FromUi -Silent -SkipValidation | Out-Null })
$chkStartup.Add_CheckedChanged({ Save-FromUi -Silent -SkipValidation | Out-Null })
$chkStartOnLaunch.Add_CheckedChanged({ Save-FromUi -Silent -SkipValidation | Out-Null })
$chkDirectMode.Add_CheckedChanged({ Save-FromUi -Silent -SkipValidation | Out-Null })
$buttonPrimaryEye.Add_Click({
    $Script:State.PrimaryPasswordVisible = -not [bool]$Script:State.PrimaryPasswordVisible
    Update-PasswordVisibility
})
$buttonBackupEye.Add_Click({
    $Script:State.BackupPasswordVisible = -not [bool]$Script:State.BackupPasswordVisible
    Update-PasswordVisibility
})
Update-PasswordVisibility

$form.Add_FormClosing({
    Save-FromUi -Silent -SkipValidation | Out-Null
    if ($null -ne $Script:Timer) {
        $Script:Timer.Stop()
    }
    if ($null -ne $Script:NotifyIcon) {
        $Script:NotifyIcon.Visible = $false
        $Script:NotifyIcon.Dispose()
    }
})

Update-Buttons
Write-Log '就绪。保存设置后点击“开始守护”。'

if ($config.StartOnLaunch) {
    $form.Add_Shown({ Start-Automation })
}

[void][System.Windows.Forms.Application]::Run($form)
