param(
    [string]$Programmer = 'C:\Users\21656\AppData\Local\stm32cube\bundles\programmer\2.23.0\bin\STM32_Programmer_CLI.exe'
)
$ErrorActionPreference = 'Stop'
$projectPath = Split-Path -Parent $PSScriptRoot
$firmwarePath = Join-Path $projectPath 'build\Debug\stm32-car.hex'
$logPath = Join-Path $projectPath 'build\Debug\flash.log'
$backupDirectory = Join-Path (Split-Path -Parent $projectPath) 'backups'
$stamp = [DateTimeOffset]::UtcNow.ToOffset([TimeSpan]::FromHours(8)).ToString('yyyy-MM-dd_HH-mm-ss')
$backupPath = Join-Path $backupDirectory "C10B_before_stm32-car_$stamp.bin"
$connectionArgs = @('-c', 'port=SWD', 'sn=37FF71064E57343647121143', 'freq=100', 'mode=HOTPLUG')
if (!(Test-Path -LiteralPath $Programmer -PathType Leaf)) { throw 'Programmer executable not found' }
if (!(Test-Path -LiteralPath $firmwarePath -PathType Leaf)) { throw 'Build Debug firmware first' }
New-Item -ItemType Directory -Path $backupDirectory -Force | Out-Null

function Invoke-Programmer {
    param([string[]]$ToolArguments)
    $output = @(& $Programmer @ToolArguments 2>&1)
    $toolExitCode = $LASTEXITCODE
    $output | Tee-Object -FilePath $logPath -Append | Out-Host
    if ($toolExitCode -ne 0) { throw "STM32CubeProgrammer failed with exit code $toolExitCode" }
    return ($output -join "`n")
}

"Flash session: $stamp" | Out-File -LiteralPath $logPath -Encoding utf8
$target = Invoke-Programmer -ToolArguments $connectionArgs
if ($target -notmatch 'Device ID\s*:\s*0x414\b' -or
    $target -notmatch 'NVM size\s*:\s*256\s*KBytes') {
    throw 'Expected C10B STM32F103 high-density target with 256 KB Flash'
}
$legacyTool = 'D:\stlink\ST-LINK Utility\ST-LINK_CLI.exe'
if (Test-Path -LiteralPath $legacyTool -PathType Leaf) {
    # This ST-Link/V2 firmware reads full Flash reliably with ST-LINK Utility.
    $backupOutput = @(& $legacyTool -c SWD Freq=100 -Halt -Dump 0x08000000 0x40000 $backupPath 2>&1)
    $backupExitCode = $LASTEXITCODE
    $backupOutput | Tee-Object -FilePath $logPath -Append | Out-Host
    if ($backupExitCode -ne 0 -or ($backupOutput -join "`n") -notmatch 'Dumping memory to .* succeded') {
        throw 'Original Flash backup failed; programming stopped'
    }
} else {
    $null = Invoke-Programmer -ToolArguments ($connectionArgs + @('-u', '0x08000000', '0x40000', $backupPath))
}
if (!(Test-Path -LiteralPath $backupPath) -or (Get-Item -LiteralPath $backupPath).Length -ne 262144) {
    throw 'Original Flash backup is incomplete; programming stopped'
}
"Original Flash backup: $backupPath" | Tee-Object -FilePath $logPath -Append | Out-Host
$result = Invoke-Programmer -ToolArguments ($connectionArgs + @('-w', $firmwarePath, '-v', '-rst'))
if ($result -notmatch 'Download verified successfully') {
    throw 'Download verification success was not reported; inspect flash.log'
}
'PASS: firmware programmed, verified and system reset.' | Tee-Object -FilePath $logPath -Append | Out-Host
