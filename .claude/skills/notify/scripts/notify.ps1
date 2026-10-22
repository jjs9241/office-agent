<#
.SYNOPSIS
  Show a Windows toast notification (Windows PowerShell 5.1, no installs).
.EXAMPLE
  & .\notify.ps1 -Title "Claude Code" -Message "Done"
#>
param(
    [string]$Title = 'Claude Code',
    [Parameter(Mandatory = $true)][string]$Message,
    [switch]$Silent
)

$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSEdition -eq 'Core') {
    # WinRT type loading is not available in PowerShell 7; re-run under Windows PowerShell.
    $argsList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath, '-Title', $Title, '-Message', $Message)
    if ($Silent) { $argsList += '-Silent' }
    & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" @argsList
    exit $LASTEXITCODE
}

[Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
[Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime] | Out-Null

$t = [System.Security.SecurityElement]::Escape($Title)
$m = [System.Security.SecurityElement]::Escape($Message)
$audio = if ($Silent) { '<audio silent="true"/>' } else { '' }

$xml = New-Object Windows.Data.Xml.Dom.XmlDocument
$xml.LoadXml("<toast><visual><binding template=`"ToastGeneric`"><text>$t</text><text>$m</text></binding></visual>$audio</toast>")

# Borrow the AppUserModelID that Windows already registers for Windows PowerShell.
$appId = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
[Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($appId).Show(
    [Windows.UI.Notifications.ToastNotification]::new($xml))
