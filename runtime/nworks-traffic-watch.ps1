<#
.SYNOPSIS
  Notify when the NAVER WORKS desktop app receives server-initiated traffic (likely a new message).
.DESCRIPTION
  Watches packets between WORKS.exe and its servers with the built-in pktmon (real-time mode).
  Only long-lived connections are watched; the app also opens short-lived API connections whose
  responses and close alerts would otherwise look like pushes.
  The app sends a ~31-byte keepalive every 60s per connection and the server answers within a few ms.
  Any server -> PC payload that is NOT a reply to a recent PC -> server packet is treated as an event.
  Only packet sizes and timing are used; payloads are TLS-encrypted and never inspected.
  Requires administrator rights (pktmon). Only one instance runs at a time.
.EXAMPLE
  .\nworks-traffic-watch.ps1 -DurationSec 300 -Verbose
#>
param(
    [int]$DurationSec = 0,          # 0 = run until stopped
    [int]$MinConnAgeSec = 300,      # only watch connections at least this old
    [double]$ReplyWindowSec = 1.0,  # Rx within this time after our Tx is treated as a reply
    [int]$MinPushBytes = 64,        # smaller server pushes (~31-byte server keepalives) are ignored
    [int]$CooldownSec = 10,         # minimum gap between notifications
    [int]$RefreshSec = 60,          # how often to re-check the app's connections
    [string]$LogDir = (Join-Path $env:LOCALAPPDATA 'nworks-watch')
)

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { Write-Error 'Administrator rights are required (pktmon).'; exit 1 }

$notify = Join-Path $PSScriptRoot '..\.claude\skills\notify\scripts\notify.ps1'
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$eventLog = Join-Path $LogDir 'events.log'

function Write-Log([string]$msg) {
    $line = '{0:yyyy-MM-dd HH:mm:ss.fff} [{1}] {2}' -f (Get-Date), $PID, $msg
    Add-Content -Path $eventLog -Value $line -Encoding utf8
    Write-Host $line
}

# Single instance: a second copy would stop this one's pktmon session and double the notifications.
$mutex = New-Object System.Threading.Mutex($false, 'Global\nworks-traffic-watch')
try { $owned = $mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $owned = $true }
if (-not $owned) { Write-Log 'already running; exiting'; exit 0 }

# Long-lived WORKS.exe connections to external servers: local port -> remote IP.
function Get-WatchConns {
    $map = @{}
    $procs = @(Get-Process WORKS -ErrorAction SilentlyContinue)
    if (-not $procs) { return $map }
    $cutoff = (Get-Date).AddSeconds(-$MinConnAgeSec)
    Get-NetTCPConnection -OwningProcess $procs.Id -State Established -ErrorAction SilentlyContinue |
        Where-Object { $_.RemoteAddress -notmatch '^(127\.|::1$|0\.0\.0\.0$)' -and $_.CreationTime -le $cutoff } |
        ForEach-Object { $map[[string]$_.LocalPort] = $_.RemoteAddress }
    $map
}

function Get-IpKey($conns) { (@($conns.Values) | Sort-Object -Unique) -join ',' }

function Start-Capture($conns) {
    & pktmon stop 2>&1 | Out-Null
    & pktmon filter remove 2>&1 | Out-Null
    foreach ($ip in (@($conns.Values) | Sort-Object -Unique)) { & pktmon filter add NW -i $ip 2>&1 | Out-Null }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'pktmon.exe'
    $psi.Arguments = 'start --capture --comp nics --pkt-size 128 -m real-time'
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    [System.Diagnostics.Process]::Start($psi)
}

function Stop-Capture($proc) {
    & pktmon stop 2>&1 | Out-Null
    & pktmon filter remove 2>&1 | Out-Null
    if ($proc -and -not $proc.HasExited) { try { $proc.Kill() } catch {} }
}

$conns = @{}
$proc = $null
$task = $null
$lastTx = @{}          # local port -> last PC->server payload time
$seen = @{}            # dedupe key -> time (pktmon logs each packet at several components)
$lastNotify = [datetime]::MinValue
$lastRefresh = [datetime]::MinValue
$started = Get-Date
$pattern = '(\d+\.\d+\.\d+\.\d+)\.(\d+) > (\d+\.\d+\.\d+\.\d+)\.(\d+): Flags \[[^\]]+\](?:, seq (\d+)(?::\d+)?)?.*length (\d+)\s*$'

Write-Log 'started'
try {
    while ($true) {
        $now = Get-Date
        if ($DurationSec -gt 0 -and ($now - $started).TotalSeconds -ge $DurationSec) { break }

        if (($now - $lastRefresh).TotalSeconds -ge $RefreshSec) {
            $lastRefresh = $now
            $newConns = Get-WatchConns
            $portsChanged = ((@($newConns.Keys) | Sort-Object) -join ',') -ne ((@($conns.Keys) | Sort-Object) -join ',')
            $ipsChanged = (Get-IpKey $newConns) -ne (Get-IpKey $conns)
            if ($portsChanged) {
                $desc = if ($newConns.Count) { ($newConns.GetEnumerator() | ForEach-Object { "$($_.Key)->$($_.Value)" }) -join ', ' } else { 'none' }
                Write-Log "watching connections: $desc"
            }
            $conns = $newConns
            if ($ipsChanged -or ($conns.Count -and -not $proc)) {
                if ($proc) { Stop-Capture $proc; $proc = $null; $task = $null }
                if ($conns.Count) {
                    $proc = Start-Capture $conns
                    $task = $proc.StandardOutput.ReadLineAsync()
                } else {
                    Write-Log "no long-lived connections yet (app not running or connected < ${MinConnAgeSec}s)"
                }
            }
            foreach ($k in @($seen.Keys)) { if (($now - $seen[$k]).TotalSeconds -gt 30) { $seen.Remove($k) } }
        }

        if (-not $task) { Start-Sleep -Milliseconds 500; continue }
        if (-not $task.Wait(500)) { continue }
        $line = $task.Result
        if ($null -eq $line) {
            Write-Log 'pktmon output ended; restarting capture'
            Stop-Capture $proc
            $proc = Start-Capture $conns
            $task = $proc.StandardOutput.ReadLineAsync()
            continue
        }
        $task = $proc.StandardOutput.ReadLineAsync()

        if ($line -notmatch $pattern) { continue }
        $src = $Matches[1]; $sport = $Matches[2]; $dst = $Matches[3]; $dport = $Matches[4]
        $seq = $Matches[5]; $len = [int]$Matches[6]
        if ($len -le 0) { continue }

        $key = "$src.$sport>$dst.$dport|$seq|$len"
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $now

        if ($conns.ContainsKey($sport) -and $conns[$sport] -eq $dst) {
            $lastTx[$sport] = $now
            Write-Verbose "Tx port=$sport len=$len"
            continue
        }
        if (-not ($conns.ContainsKey($dport) -and $conns[$dport] -eq $src)) { continue }

        $since = if ($lastTx.ContainsKey($dport)) { ($now - $lastTx[$dport]).TotalSeconds } else { [double]::MaxValue }
        if ($since -le $ReplyWindowSec) {
            Write-Verbose "Rx reply port=$dport len=$len"
            continue
        }
        if ($len -lt $MinPushBytes) {
            Write-Verbose "Rx small push ignored port=$dport len=$len"
            continue
        }
        Write-Log "server push port=$dport len=$len"
        if (($now - $lastNotify).TotalSeconds -ge $CooldownSec) {
            $lastNotify = $now
            try { & $notify -Title 'NAVER WORKS' -Message '새 알림이 도착했어요' } catch { Write-Log "notify failed: $_" }
        }
    }
} finally {
    if ($proc) { Stop-Capture $proc }
    Write-Log 'stopped'
    $mutex.ReleaseMutex()
    $mutex.Dispose()
}
