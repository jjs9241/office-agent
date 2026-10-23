<#
.SYNOPSIS
  Register (or remove) a Task Scheduler task that starts nworks-traffic-watch.ps1 at logon.
.DESCRIPTION
  The task runs as the current user with highest privileges (pktmon needs admin) so no UAC prompt
  appears at logon. It only starts the watcher; the watcher itself loops until logoff.
  Run this script once as administrator.
.EXAMPLE
  .\install-watch-task.ps1             # register and start now
  .\install-watch-task.ps1 -Uninstall  # stop and remove
#>
param([switch]$Uninstall)

$taskName = 'nworks-traffic-watch'

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { Write-Error 'Run this script as administrator.'; exit 1 }

if ($Uninstall) {
    if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
        Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
        Write-Host "Removed task '$taskName'."
    } else {
        Write-Host "Task '$taskName' is not registered."
    }
    & pktmon stop 2>&1 | Out-Null
    & pktmon filter remove 2>&1 | Out-Null
    exit 0
}

$watcher = Join-Path $PSScriptRoot 'nworks-traffic-watch.ps1'
if (-not (Test-Path $watcher)) { Write-Error "Not found: $watcher"; exit 1 }
$user = [Security.Principal.WindowsIdentity]::GetCurrent().Name

$action = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
    -Argument "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$watcher`""
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
$principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries

Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings `
    -Description 'Desktop notification when the NAVER WORKS app receives server-pushed traffic.' -Force | Out-Null
Start-ScheduledTask -TaskName $taskName
Write-Host "Registered and started task '$taskName' for $user."
