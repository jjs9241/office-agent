<#
.SYNOPSIS
  NAVER WORKS API helper for the naver-works skill (Windows PowerShell 5.1+, no external deps).

.DESCRIPTION
  Extracted from yjcho9317/nworks v1.3.1. Credential/token files are compatible with nworks
  (~/.config/nworks/credentials.json, token.json, user-token.json).

  Commands:
    setup      -ClientId <id> [-ServiceAccount <sa>] [-PrivateKeyPath <pem>] [-BotId <id>] [-DomainId <id>]
               Client Secret comes from $env:NWORKS_CLIENT_SECRET or an interactive prompt.
    login      [-Preset readonly|all]       User OAuth via browser (callback http://localhost:9876/callback)
    whoami                                   Auth status + /users/me
    logout                                   Revoke tokens and delete local credentials
    api        <METHOD> <PATH> [-Body <json> | -BodyFile <file>]   Call API with the user OAuth token
    bot        <METHOD> <PATH> [-Body <json> | -BodyFile <file>]   Call API with the service-account (bot) token
    message    (-To <userId> | -Channel <channelId>) -Text <text>  Send a bot text message
    upload     -File <local path> [-FolderId <id>] [-Overwrite]     Upload to my drive
    download   <PATH ending in /download> -OutDir <dir>             Drive / shared-drive file download
    attachment <PATH /users/me/mail/{mailId}/attachments/{attId}> -OutDir <dir>

  PATH is relative to https://www.worksapis.com/v1.0 (e.g. /users/me/mail/mailfolders/0/children?count=10).
  Success: response body (UTF-8 JSON) on stdout. Failure: "HTTP <status>: <body>" on stderr, exit 1.
#>
[CmdletBinding()]
param(
  [Parameter(Position = 0, Mandatory = $true)][string]$Command,
  [Parameter(Position = 1)][string]$Method,
  [Parameter(Position = 2)][string]$Path,
  [string]$Body,
  [string]$BodyFile,
  [ValidateSet('readonly', 'all')][string]$Preset = 'readonly',
  [string]$ClientId,
  [string]$ServiceAccount,
  [string]$PrivateKeyPath,
  [string]$BotId,
  [string]$DomainId,
  [string]$File,
  [string]$FolderId,
  [switch]$Overwrite,
  [string]$OutDir,
  [string]$To,
  [string]$Channel,
  [string]$Text,
  [ValidatePattern('^[\w.-]+$')][string]$ProfileName = 'default'
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
Add-Type -AssemblyName System.Net.Http
Add-Type -AssemblyName System.Web
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$BaseUrl = 'https://www.worksapis.com/v1.0'
$AuthBase = 'https://auth.worksmobile.com/oauth2/v2.0'
$RedirectPort = 9876
$RedirectUri = "http://localhost:$RedirectPort/callback"
$ConfigDir = Join-Path $HOME '.config\nworks'
$CredPath = Join-Path $ConfigDir 'credentials.json'
$BotTokenPath = Join-Path $ConfigDir 'token.json'
$UserTokenPath = Join-Path $ConfigDir 'user-token.json'
$Utf8NoBom = New-Object Text.UTF8Encoding $false

# 다운로드 302 Location·업로드 URL은 이 호스트로만 따라간다(토큰 유출 방지).
$AllowedHosts = @('storage.worksmobile.com', 'apis-storage.worksmobile.com', 'www.worksapis.com', 'worksapis.com')

# LINE WORKS scope는 도메인 단위다. 쓰기 scope 하나가 생성·수정·삭제를 모두 준다.
$ReadScopes = @('calendar.read', 'file.read', 'mail.read', 'task.read', 'user.read', 'board.read', 'contact.read')
$AllScopes = $ReadScopes + @('calendar', 'file', 'mail', 'task', 'board', 'contact')

$Handler = New-Object System.Net.Http.HttpClientHandler
$Handler.AllowAutoRedirect = $false
$Http = New-Object System.Net.Http.HttpClient($Handler)
$Http.Timeout = [TimeSpan]::FromSeconds(120)

function Fail([string]$Message) {
  [Console]::Error.WriteLine($Message)
  exit 1
}

function Now { [int64][DateTimeOffset]::UtcNow.ToUnixTimeSeconds() }

# ---------- local store (nworks-compatible, keyed by profile) ----------

function Read-Store([string]$StorePath) {
  if (-not (Test-Path $StorePath)) { return New-Object psobject }
  $raw = [IO.File]::ReadAllText($StorePath, [Text.Encoding]::UTF8)
  if (-not $raw.Trim()) { return New-Object psobject }
  return $raw | ConvertFrom-Json
}

function Write-Store([string]$StorePath, $Store) {
  if (-not (Test-Path $ConfigDir)) { New-Item -ItemType Directory -Path $ConfigDir | Out-Null }
  $temp = "$StorePath.$PID.tmp"
  [IO.File]::WriteAllText($temp, ($Store | ConvertTo-Json -Depth 5), $Utf8NoBom)
  Move-Item -Path $temp -Destination $StorePath -Force
}

function Get-Entry([string]$StorePath) {
  $store = Read-Store $StorePath
  return $store.$ProfileName
}

function Set-Entry([string]$StorePath, $Value) {
  $store = Read-Store $StorePath
  $store | Add-Member -NotePropertyName $ProfileName -NotePropertyValue $Value -Force
  Write-Store $StorePath $store
}

function Remove-Entry([string]$StorePath) {
  if (-not (Test-Path $StorePath)) { return }
  $store = Read-Store $StorePath
  $store.PSObject.Properties.Remove($ProfileName)
  Write-Store $StorePath $store
}

function Get-Creds {
  if ($env:NWORKS_CLIENT_ID -and $env:NWORKS_CLIENT_SECRET) {
    return [pscustomobject]@{
      clientId       = $env:NWORKS_CLIENT_ID
      clientSecret   = $env:NWORKS_CLIENT_SECRET
      serviceAccount = $env:NWORKS_SERVICE_ACCOUNT
      privateKeyPath = $env:NWORKS_PRIVATE_KEY_PATH
      botId          = $env:NWORKS_BOT_ID
      domainId       = $env:NWORKS_DOMAIN_ID
    }
  }
  $creds = Get-Entry $CredPath
  if (-not $creds -or -not $creds.clientId -or -not $creds.clientSecret) {
    Fail "Not configured. Run: nworks.ps1 setup -ClientId <id>  (secret via `$env:NWORKS_CLIENT_SECRET)"
  }
  return $creds
}

# ---------- HTTP ----------

function New-FormContent([hashtable]$Fields) {
  $dict = New-Object 'System.Collections.Generic.Dictionary[string,string]'
  foreach ($k in $Fields.Keys) { $dict.Add($k, [string]$Fields[$k]) }
  return New-Object System.Net.Http.FormUrlEncodedContent($dict)
}

function Send-Http([string]$Verb, [string]$Url, [string]$Token, $Content) {
  $req = New-Object System.Net.Http.HttpRequestMessage((New-Object System.Net.Http.HttpMethod($Verb.ToUpper())), $Url)
  if ($Token) { $req.Headers.Authorization = New-Object System.Net.Http.Headers.AuthenticationHeaderValue('Bearer', $Token) }
  if ($Content) { $req.Content = $Content }
  $res = $Http.SendAsync($req).GetAwaiter().GetResult()
  $bytes = $res.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
  $retryAfter = 5
  if ($res.Headers.RetryAfter -and $res.Headers.RetryAfter.Delta) { $retryAfter = [int]$res.Headers.RetryAfter.Delta.Value.TotalSeconds }
  $location = $null
  if ($res.Headers.Location) { $location = $res.Headers.Location.OriginalString }
  $disposition = $null
  if ($res.Content.Headers.ContentDisposition) { $disposition = $res.Content.Headers.ContentDisposition }
  return [pscustomobject]@{
    Status      = [int]$res.StatusCode
    Bytes       = $bytes
    Text        = [Text.Encoding]::UTF8.GetString($bytes)
    Location    = $location
    RetryAfter  = [Math]::Min($retryAfter, 60)
    Disposition = $disposition
  }
}

function Post-TokenEndpoint([string]$Endpoint, [hashtable]$Fields) {
  $r = Send-Http 'POST' "$AuthBase/$Endpoint" $null (New-FormContent $Fields)
  if ($r.Status -lt 200 -or $r.Status -ge 300) {
    # 응답 전체 대신 표준 OAuth 오류 필드만 노출한다.
    $summary = $r.Text
    try { $e = $r.Text | ConvertFrom-Json; if ($e.error) { $summary = "$($e.error): $($e.error_description)" } } catch {}
    if ($summary.Length -gt 200) { $summary = $summary.Substring(0, 200) + '...' }
    Fail "Token request failed (HTTP $($r.Status)): $summary"
  }
  return $r.Text | ConvertFrom-Json
}

# ---------- tokens ----------

function Get-UserToken([switch]$Force) {
  $cached = Get-Entry $UserTokenPath
  if (-not $cached) { Fail 'User OAuth token not found. Run: nworks.ps1 login' }
  if (-not $Force -and [int64]$cached.expiresAt -gt (Now) + 300) { return $cached.accessToken }

  $creds = Get-Creds
  $data = Post-TokenEndpoint 'token' @{
    grant_type    = 'refresh_token'
    refresh_token = $cached.refreshToken
    client_id     = $creds.clientId
    client_secret = $creds.clientSecret
  }
  $refresh = $cached.refreshToken
  if ($data.refresh_token) { $refresh = $data.refresh_token }
  $scope = $cached.scope
  if ($data.scope) { $scope = $data.scope }
  Set-Entry $UserTokenPath ([pscustomobject]@{
      accessToken  = $data.access_token
      refreshToken = $refresh
      expiresAt    = (Now) + [int64]$data.expires_in
      scope        = $scope
    })
  return $data.access_token
}

function ConvertTo-Base64Url([byte[]]$Bytes) {
  return [Convert]::ToBase64String($Bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function New-ServiceAccountJwt($Creds) {
  if (-not $Creds.serviceAccount -or -not $Creds.privateKeyPath) {
    Fail 'Service account not configured. Run setup with -ServiceAccount and -PrivateKeyPath.'
  }
  $pem = [IO.File]::ReadAllText($Creds.privateKeyPath)
  if ($pem -match 'BEGIN RSA PRIVATE KEY') {
    Fail 'PKCS#1 key not supported. Use the PKCS#8 key ("BEGIN PRIVATE KEY") downloaded from the Developer Console.'
  }
  $der = [Convert]::FromBase64String(($pem -replace '-----[^-]+-----', '' -replace '\s', ''))
  $cng = [Security.Cryptography.CngKey]::Import($der, [Security.Cryptography.CngKeyBlobFormat]::Pkcs8PrivateBlob)
  $rsa = New-Object Security.Cryptography.RSACng($cng)

  $now = Now
  $header = ConvertTo-Base64Url ([Text.Encoding]::UTF8.GetBytes('{"alg":"RS256","typ":"JWT"}'))
  $payloadJson = [pscustomobject]@{ iss = $Creds.clientId; sub = $Creds.serviceAccount; iat = $now; exp = $now + 3600 } | ConvertTo-Json -Compress
  $payload = ConvertTo-Base64Url ([Text.Encoding]::UTF8.GetBytes($payloadJson))
  $signature = $rsa.SignData([Text.Encoding]::ASCII.GetBytes("$header.$payload"),
    [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pkcs1)
  return "$header.$payload.$(ConvertTo-Base64Url $signature)"
}

function Get-BotToken([switch]$Force) {
  $cached = Get-Entry $BotTokenPath
  if (-not $Force -and $cached -and [int64]$cached.expiresAt -gt (Now) + 300) { return $cached.accessToken }

  $creds = Get-Creds
  $scope = 'bot bot.read user.read'
  if ($env:NWORKS_SCOPE) { $scope = $env:NWORKS_SCOPE }
  $data = Post-TokenEndpoint 'token' @{
    grant_type    = 'urn:ietf:params:oauth:grant-type:jwt-bearer'
    assertion     = (New-ServiceAccountJwt $creds)
    client_id     = $creds.clientId
    client_secret = $creds.clientSecret
    scope         = $scope
  }
  Set-Entry $BotTokenPath ([pscustomobject]@{ accessToken = $data.access_token; expiresAt = (Now) + [int64]$data.expires_in })
  return $data.access_token
}

# 401이면 토큰을 한 번 갱신해 재시도, 429면 Retry-After만큼 쉬고 최대 3회 재시도한다.
function Invoke-Api([string]$Kind, [string]$Verb, [string]$Target, [scriptblock]$MakeContent) {
  $url = $Target
  if ($Target -notmatch '^https://') { $url = $BaseUrl + $Target }
  $refreshed = $false
  for ($attempt = 0; ; $attempt++) {
    if ($Kind -eq 'bot') { $token = Get-BotToken -Force:$refreshed } else { $token = Get-UserToken -Force:$refreshed }
    $content = $null
    if ($MakeContent) { $content = & $MakeContent }
    $r = Send-Http $Verb $url $token $content
    if ($r.Status -eq 401 -and -not $refreshed) { $refreshed = $true; continue }
    if ($r.Status -eq 429 -and $attempt -lt 3) { Start-Sleep -Seconds $r.RetryAfter; continue }
    return $r
  }
}

function Assert-Ok($Response) {
  if ($Response.Status -ge 200 -and $Response.Status -lt 300) { return }
  $hint = ''
  if ($Response.Status -eq 401) { $hint = ' (token expired or revoked: run login again)' }
  if ($Response.Status -eq 403) { $hint = ' (missing scope? run login -Preset all, or check app permissions)' }
  Fail "HTTP $($Response.Status)$hint`: $($Response.Text)"
}

function Write-Result($Response) {
  Assert-Ok $Response
  if ($Response.Text) { Write-Output $Response.Text } else { Write-Output ('{"status":' + $Response.Status + '}') }
}

function Get-JsonBody {
  if ($BodyFile) { return [IO.File]::ReadAllText((Resolve-Path $BodyFile), [Text.Encoding]::UTF8) }
  return $Body
}

function New-JsonContentBlock([string]$Json) {
  if (-not $Json) { return $null }
  return { New-Object System.Net.Http.StringContent($Json, [Text.Encoding]::UTF8, 'application/json') }.GetNewClosure()
}

function Assert-AllowedHost([string]$Url) {
  $u = [Uri]$Url
  if ($u.Scheme -ne 'https') { Fail "Refusing non-HTTPS URL: $Url" }
  foreach ($h in $AllowedHosts) { if ($u.Host -eq $h -or $u.Host.EndsWith(".$h")) { return } }
  Fail "Refusing untrusted host: $($u.Host)"
}

function Get-SafeFileName([string]$Name) {
  $leaf = ($Name -split '[\\/]' | Where-Object { $_ })[-1]
  if (-not $leaf) { $leaf = 'download.bin' }
  foreach ($c in [IO.Path]::GetInvalidFileNameChars()) { $leaf = $leaf.Replace([string]$c, '_') }
  return $leaf
}

function Save-Bytes([byte[]]$Bytes, [string]$FileName) {
  if (-not $OutDir) { Fail '-OutDir is required.' }
  if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir | Out-Null }
  $target = Join-Path (Resolve-Path $OutDir) (Get-SafeFileName $FileName)
  [IO.File]::WriteAllBytes($target, $Bytes)
  Write-Output (([pscustomobject]@{ saved = $target; size = $Bytes.Length }) | ConvertTo-Json -Compress)
}

# ---------- commands ----------

function Invoke-Setup {
  $id = $ClientId
  if (-not $id) { $id = $env:NWORKS_CLIENT_ID }
  if (-not $id) { Fail '-ClientId is required.' }
  $secret = $env:NWORKS_CLIENT_SECRET
  if (-not $secret) {
    $secure = Read-Host 'Client Secret' -AsSecureString
    $secret = [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure))
  }
  if (-not $secret) { Fail 'Client Secret is required ($env:NWORKS_CLIENT_SECRET or prompt).' }
  $keyPath = $PrivateKeyPath
  if (-not $keyPath) { $keyPath = $env:NWORKS_PRIVATE_KEY_PATH }
  if ($keyPath) { $keyPath = (Resolve-Path $keyPath).Path }
  Set-Entry $CredPath ([pscustomobject]@{
      clientId = $id; clientSecret = $secret; serviceAccount = $ServiceAccount
      privateKeyPath = $keyPath; botId = $BotId; domainId = $DomainId
    })
  Write-Output "Saved credentials to $CredPath (profile: $ProfileName). Next: nworks.ps1 login"
}

function Invoke-Login {
  $creds = Get-Creds
  # 기존 토큰 scope와 합쳐 재로그인으로 권한이 줄지 않게 한다.
  $requested = $ReadScopes
  if ($Preset -eq 'all') { $requested = $AllScopes }
  $existing = @()
  $old = Get-Entry $UserTokenPath
  if ($old -and $old.scope) { $existing = $old.scope -split ' ' | Where-Object { $_ } }
  $scope = (@($existing) + @($requested) | Select-Object -Unique) -join ' '

  $stateBytes = New-Object byte[] 32
  [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($stateBytes)
  $state = -join ($stateBytes | ForEach-Object { $_.ToString('x2') })
  $query = "client_id=$([Uri]::EscapeDataString($creds.clientId))&redirect_uri=$([Uri]::EscapeDataString($RedirectUri))" +
    "&scope=$([Uri]::EscapeDataString($scope))&response_type=code&state=$state"
  $authorizeUrl = "$AuthBase/authorize?$query"

  $listener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, $RedirectPort)
  try { $listener.Start() } catch { Fail "Port $RedirectPort is busy: $($_.Exception.Message)" }
  try {
    Start-Process $authorizeUrl
    [Console]::Error.WriteLine("Browser opened for NAVER WORKS login (120s). If not, open:`n$authorizeUrl")
    $deadline = (Get-Date).AddSeconds(120)
    $code = $null
    while (-not $code) {
      if ((Get-Date) -gt $deadline) { Fail 'OAuth login timed out (120s).' }
      if (-not $listener.Pending()) { Start-Sleep -Milliseconds 200; continue }
      $client = $listener.AcceptTcpClient()
      try {
        $stream = $client.GetStream()
        $reader = New-Object IO.StreamReader($stream)
        $requestLine = $reader.ReadLine()
        $target = ($requestLine -split ' ')[1]
        $uri = New-Object Uri("http://localhost:$RedirectPort$target")
        $params = [Web.HttpUtility]::ParseQueryString($uri.Query)
        $status = '200 OK'; $html = '<h2>로그인 성공</h2><p>이 창을 닫고 돌아가세요.</p>'
        $oauthError = $null
        if ($uri.AbsolutePath -ne '/callback') { $status = '404 Not Found'; $html = 'Not found' }
        elseif ($params['state'] -ne $state) {
          # state가 다른 요청은 거부하되 계속 대기한다(잘못된 요청 하나로 로그인이 끊기지 않게).
          $status = '403 Forbidden'; $html = '<h2>보안 오류</h2><p>state 불일치</p>'
        }
        elseif ($params['error']) { $html = '<h2>로그인 실패</h2>'; $oauthError = $params['error'] }
        elseif (-not $params['code']) { $status = '400 Bad Request'; $html = '<h2>code 없음</h2>'; $oauthError = 'missing code' }
        else { $code = $params['code'] }
        $bodyBytes = [Text.Encoding]::UTF8.GetBytes("<!doctype html><meta charset=utf-8>$html")
        $head = [Text.Encoding]::ASCII.GetBytes("HTTP/1.1 $status`r`nContent-Type: text/html; charset=utf-8`r`nContent-Length: $($bodyBytes.Length)`r`nConnection: close`r`n`r`n")
        $stream.Write($head, 0, $head.Length); $stream.Write($bodyBytes, 0, $bodyBytes.Length); $stream.Flush()
        if ($oauthError) { Fail "OAuth error: $oauthError" }
      } finally { $client.Close() }
    }
  } finally { $listener.Stop() }

  $data = Post-TokenEndpoint 'token' @{
    grant_type = 'authorization_code'; code = $code; client_id = $creds.clientId
    client_secret = $creds.clientSecret; redirect_uri = $RedirectUri
  }
  Set-Entry $UserTokenPath ([pscustomobject]@{
      accessToken = $data.access_token; refreshToken = $data.refresh_token
      expiresAt = (Now) + [int64]$data.expires_in; scope = $data.scope
    })
  Write-Output "Login OK. scope: $($data.scope)"
}

function Invoke-Whoami {
  $creds = Get-Creds
  $user = Get-Entry $UserTokenPath
  $bot = Get-Entry $BotTokenPath
  $mask = { param($s) if (-not $s) { $null } elseif ($s.Length -le 4) { '****' } else { '****' + $s.Substring($s.Length - 4) } }
  $info = [ordered]@{
    profile        = $ProfileName
    clientId       = & $mask $creds.clientId
    serviceAccount = $creds.serviceAccount
    botId          = $creds.botId
    botTokenValid  = [bool]($bot -and [int64]$bot.expiresAt -gt (Now))
    userOAuth      = $null
    me             = $null
  }
  if ($user) {
    $info.userOAuth = [ordered]@{ valid = [int64]$user.expiresAt -gt (Now); scope = $user.scope }
    $r = Invoke-Api 'user' 'GET' '/users/me' $null
    if ($r.Status -eq 200) {
      $me = $r.Text | ConvertFrom-Json
      $info.me = [ordered]@{ userId = $me.userId; email = $me.email; name = "$($me.userName.lastName)$($me.userName.firstName)" }
    } else { $info.me = "HTTP $($r.Status)" }
  }
  Write-Output ($info | ConvertTo-Json -Depth 4)
}

function Invoke-Logout {
  $creds = $null
  try { $creds = Get-Entry $CredPath } catch {}
  if ($creds) {
    $user = Get-Entry $UserTokenPath
    $bot = Get-Entry $BotTokenPath
    foreach ($t in @($(if ($user) { $user.refreshToken }), $(if ($bot) { $bot.accessToken }))) {
      if (-not $t) { continue }
      try { Send-Http 'POST' "$AuthBase/revoke" $null (New-FormContent @{ token = $t; client_id = $creds.clientId; client_secret = $creds.clientSecret }) | Out-Null } catch {}
    }
  }
  Remove-Entry $CredPath; Remove-Entry $BotTokenPath; Remove-Entry $UserTokenPath
  Write-Output "Logged out (profile: $ProfileName)."
}

function Invoke-Message {
  $creds = Get-Creds
  if (-not $creds.botId) { Fail 'botId not configured (setup -BotId).' }
  if (-not $Text) { Fail '-Text is required.' }
  if ($To) { $target = "/bots/$([Uri]::EscapeDataString($creds.botId))/users/$([Uri]::EscapeDataString($To))/messages" }
  elseif ($Channel) { $target = "/bots/$([Uri]::EscapeDataString($creds.botId))/channels/$([Uri]::EscapeDataString($Channel))/messages" }
  else { Fail '-To or -Channel is required.' }
  $json = [pscustomobject]@{ content = [pscustomobject]@{ type = 'text'; text = $Text } } | ConvertTo-Json -Compress
  Write-Result (Invoke-Api 'bot' 'POST' $target (New-JsonContentBlock $json))
}

function Invoke-Upload {
  if (-not $File) { Fail '-File is required.' }
  $full = (Resolve-Path $File).Path
  # 인증 정보·SSH 키 등 민감 위치는 업로드 대상에서 차단한다.
  foreach ($blocked in @($ConfigDir, (Join-Path $HOME '.ssh'), (Join-Path $HOME '.aws'), (Join-Path $HOME '.claude'))) {
    if ($full.StartsWith($blocked, [StringComparison]::OrdinalIgnoreCase)) { Fail "Refusing to upload from sensitive location: $blocked" }
  }
  $bytes = [IO.File]::ReadAllBytes($full)
  if ($bytes.Length -gt 100MB) { Fail 'File exceeds 100MB.' }
  $name = [IO.Path]::GetFileName($full)

  $createPath = '/users/me/drive/files'
  if ($FolderId) { $createPath += '/' + [Uri]::EscapeDataString($FolderId) }
  $meta = [pscustomobject]@{ fileName = $name; fileSize = $bytes.Length; overwrite = [bool]$Overwrite } | ConvertTo-Json -Compress
  $r = Invoke-Api 'user' 'POST' $createPath (New-JsonContentBlock $meta)
  Assert-Ok $r
  $uploadUrl = ($r.Text | ConvertFrom-Json).uploadUrl
  Assert-AllowedHost $uploadUrl

  $boundary = "----nworks$([DateTime]::UtcNow.Ticks)"
  $safeName = $name -replace '["\r\n]', '_'
  $head = [Text.Encoding]::UTF8.GetBytes("--$boundary`r`nContent-Disposition: form-data; name=`"Filedata`"; filename=`"$safeName`"`r`nContent-Type: application/octet-stream`r`n`r`n")
  $tail = [Text.Encoding]::UTF8.GetBytes("`r`n--$boundary--`r`n")
  $payload = New-Object byte[] ($head.Length + $bytes.Length + $tail.Length)
  [Array]::Copy($head, 0, $payload, 0, $head.Length)
  [Array]::Copy($bytes, 0, $payload, $head.Length, $bytes.Length)
  [Array]::Copy($tail, 0, $payload, $head.Length + $bytes.Length, $tail.Length)
  $make = {
    $c = New-Object System.Net.Http.ByteArrayContent(, $payload)
    $c.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::Parse("multipart/form-data; boundary=$boundary")
    $c
  }.GetNewClosure()
  Write-Result (Invoke-Api 'user' 'POST' $uploadUrl $make)
}

function Invoke-Download {
  if (-not $Path) { Fail 'Usage: download <PATH ending in /download> -OutDir <dir>' }
  # download 엔드포인트는 302로 스토리지 URL을 준다. 호스트 검증 후에만 토큰을 실어 따라간다.
  $r = Invoke-Api 'user' 'GET' $Path $null
  if (-not $r.Location) { Assert-Ok $r; Fail "No download URL returned (HTTP $($r.Status))." }
  Assert-AllowedHost $r.Location
  $file = Invoke-Api 'user' 'GET' $r.Location $null
  Assert-Ok $file
  $name = 'download.bin'
  if ($file.Disposition) {
    if ($file.Disposition.FileNameStar) { $name = $file.Disposition.FileNameStar }
    elseif ($file.Disposition.FileName) { $name = [Uri]::UnescapeDataString($file.Disposition.FileName.Trim('"')) }
  }
  Save-Bytes $file.Bytes $name
}

function Invoke-Attachment {
  if (-not $Path) { Fail 'Usage: attachment /users/me/mail/{mailId}/attachments/{attachmentId} -OutDir <dir>' }
  # 메일 첨부 API는 바이너리가 아니라 base64 문자열을 JSON으로 돌려준다.
  $r = Invoke-Api 'user' 'GET' $Path $null
  Assert-Ok $r
  $data = $r.Text | ConvertFrom-Json
  Save-Bytes ([Convert]::FromBase64String($data.data)) $data.filename
}

switch ($Command.ToLower()) {
  'setup' { Invoke-Setup }
  'login' { Invoke-Login }
  'whoami' { Invoke-Whoami }
  'logout' { Invoke-Logout }
  'api' {
    if (-not $Method -or -not $Path) { Fail 'Usage: api <METHOD> <PATH> [-Body <json> | -BodyFile <file>]' }
    Write-Result (Invoke-Api 'user' $Method $Path (New-JsonContentBlock (Get-JsonBody)))
  }
  'bot' {
    if (-not $Method -or -not $Path) { Fail 'Usage: bot <METHOD> <PATH> [-Body <json> | -BodyFile <file>]' }
    Write-Result (Invoke-Api 'bot' $Method $Path (New-JsonContentBlock (Get-JsonBody)))
  }
  'message' { Invoke-Message }
  'upload' { Invoke-Upload }
  'download' { $Path = $Method; Invoke-Download }
  'attachment' { $Path = $Method; Invoke-Attachment }
  default { Fail "Unknown command: $Command (setup|login|whoami|logout|api|bot|message|upload|download|attachment)" }
}
