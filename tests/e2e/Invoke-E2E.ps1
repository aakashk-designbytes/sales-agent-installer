#Requires -Version 7.2
<#
.SYNOPSIS
    Functional end-to-end check of a running Sales Agent installation, through
    the gateway exactly like a browser.

.DESCRIPTION
    1. Frontend + gateway reachable
    2. Admin login through the Next.js BFF (/api/login) -> auth cookies (HTTP, SameSite=Lax)
    3. User profile + agent list through /eb-backend
    4. Create a chat session, send a message, receive the AI reply over SSE
       (/eb-backend/sessions/<id>/events?sse=true)
    5. Upload a file (/eb-backend/upload) and download it via the returned /viewer URL
    6. Optional: proposal PDF prompt (-ProposalPrompt), waits for a .pdf link
    7. Restart the stack (Install-SalesAgent.ps1 stop + start) and verify the session events and
       the uploaded file are still there (MongoDB + RustFS persistence)

    The admin password comes from -Password or $env:E2E_ADMIN_PASSWORD.

.EXAMPLE
    $env:E2E_ADMIN_PASSWORD = '...'; pwsh ./tests/e2e/Invoke-E2E.ps1 -BaseUrl http://localhost:8080 -ConfigDir <dir>
#>
[CmdletBinding()]
param(
    [string]$BaseUrl = 'http://localhost:8080',
    [string]$Username = 'admin',
    [securestring]$Password,
    [string]$ConfigDir,
    [string]$Message = 'Hello! In one short sentence, what can you help me with?',
    [string]$ProposalPrompt,
    [int]$ReplyTimeoutSec = 300,
    [switch]$SkipRestart
)

$ErrorActionPreference = 'Stop'
$BaseUrl = $BaseUrl.TrimEnd('/')
$installer = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$plain = if ($Password) { [Net.NetworkCredential]::new('', $Password).Password } else { $env:E2E_ADMIN_PASSWORD }
if (-not $plain) { throw 'Provide -Password or set E2E_ADMIN_PASSWORD.' }

$results = [System.Collections.Generic.List[object]]::new()
function Step([string]$Name, [scriptblock]$Body) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        $detail = & $Body
        $results.Add([pscustomobject]@{ Step = $Name; Result = 'PASS'; Seconds = [math]::Round($sw.Elapsed.TotalSeconds, 1); Detail = "$detail" })
        Write-Host "  [pass] $Name $(if ($detail) { "- $detail" })" -ForegroundColor Green
        return $true
    } catch {
        $results.Add([pscustomobject]@{ Step = $Name; Result = 'FAIL'; Seconds = [math]::Round($sw.Elapsed.TotalSeconds, 1); Detail = $_.Exception.Message })
        Write-Host "  [FAIL] $Name - $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
}

$web = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
function Api([string]$Method, [string]$Path, $Body, [switch]$Raw) {
    $p = @{ Uri = "$BaseUrl$Path"; Method = $Method; WebSession = $web; SkipHttpErrorCheck = $true; TimeoutSec = 120 }
    if ($null -ne $Body) { $p.Body = ($Body | ConvertTo-Json -Depth 10); $p.ContentType = 'application/json' }
    $r = Invoke-WebRequest @p
    if ($Raw) { return $r }
    if ($r.StatusCode -ge 400) { throw "$Method $Path -> HTTP $($r.StatusCode): $($r.Content.Substring(0, [Math]::Min(300, $r.Content.Length)))" }
    if ($r.Content) { return $r.Content | ConvertFrom-Json -Depth 20 }
}

function Read-SseUntil([string]$Path, [scriptblock]$Until, [int]$TimeoutSec) {
    <# Reads an SSE stream through the gateway; returns matching event or throws on timeout. #>
    $handler = [System.Net.Http.HttpClientHandler]::new()
    $handler.CookieContainer = $web.Cookies
    $client = [System.Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromSeconds($TimeoutSec + 10)
    $cts = [System.Threading.CancellationTokenSource]::new([TimeSpan]::FromSeconds($TimeoutSec))
    try {
        $req = [System.Net.Http.HttpRequestMessage]::new('GET', "$BaseUrl$Path")
        $req.Headers.Accept.ParseAdd('text/event-stream')
        $resp = $client.SendAsync($req, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead, $cts.Token).GetAwaiter().GetResult()
        if (-not $resp.IsSuccessStatusCode) { throw "SSE HTTP $([int]$resp.StatusCode)" }
        $ctype = "$($resp.Content.Headers.ContentType)"
        if ($ctype -notmatch 'text/event-stream') { throw "SSE content-type is '$ctype'" }
        $reader = [IO.StreamReader]::new($resp.Content.ReadAsStreamAsync().GetAwaiter().GetResult())
        $events = 0
        while (-not $cts.IsCancellationRequested) {
            $lineTask = $reader.ReadLineAsync()
            if (-not $lineTask.Wait([TimeSpan]::FromSeconds($TimeoutSec))) { break }
            $line = $lineTask.Result
            if ($null -eq $line) { break }
            if (-not $line.StartsWith('data:')) { continue }
            $events++
            $evt = $line.Substring(5).Trim() | ConvertFrom-Json -Depth 30 -ErrorAction SilentlyContinue
            if ($evt -and (& $Until $evt)) { return [pscustomobject]@{ Event = $evt; Count = $events } }
        }
        throw "no matching SSE event within $TimeoutSec s ($events events received)"
    } finally { $cts.Dispose(); $client.Dispose() }
}

function Get-ReplyText($evt) { "$($evt.data.message)" }

Write-Host "Sales Agent E2E against $BaseUrl" -ForegroundColor Cyan
$state = @{}

$null = Step 'gateway + frontend reachable' {
    $r = Invoke-WebRequest "$BaseUrl/" -SkipHttpErrorCheck -MaximumRedirection 0
    if ($r.StatusCode -notin 200, 302, 303, 307) { throw "HTTP $($r.StatusCode)" }
    $h = Invoke-WebRequest "$BaseUrl/eb-backend/healthz" -SkipHttpErrorCheck
    if ($h.StatusCode -ne 200) { throw "/eb-backend/healthz HTTP $($h.StatusCode)" }
    "frontend $($r.StatusCode), backend healthz 200"
}

$loggedIn = Step 'admin login (BFF /api/login, cookies over HTTP)' {
    $r = Api POST '/api/login' @{ username = $Username; password = $plain } -Raw
    if ($r.StatusCode -ne 200) { throw "HTTP $($r.StatusCode): $($r.Content)" }
    $cookies = $web.Cookies.GetCookies([Uri]$BaseUrl)
    if (-not ($cookies | Where-Object Name -eq 'token')) { throw "no 'token' cookie set (got: $(($cookies | ForEach-Object Name) -join ', '))" }
    $bad = Api POST '/api/login' @{ username = $Username; password = 'definitely-wrong-password' } -Raw
    if ($bad.StatusCode -lt 400) { throw 'login with a wrong password was accepted' }
    "token cookie set; wrong password rejected ($($bad.StatusCode))"
}

if ($loggedIn) {
    $null = Step 'user profile + agents' {
        $profile = Api GET '/eb-backend/auth/user-profile'
        $state.customerId = $profile.data.customer_id ?? $profile.customer_id ?? $profile.data.id
        $agents = @(Api GET '/eb-backend/agents')
        if (-not $agents) { throw 'no agents returned' }
        $state.agentId = ($agents | Where-Object { $_.name -match 'sales' } | Select-Object -First 1).id ?? $agents[0].id
        if (-not $state.customerId) { throw "customer id missing in profile: $($profile | ConvertTo-Json -Compress -Depth 5)" }
        "agents=$($agents.Count), customer=$($state.customerId)"
    }

    $null = Step 'chat: send message + AI reply over SSE' {
        $s = Api POST '/eb-backend/sessions' @{ agent_id = $state.agentId; customer_id = $state.customerId; title = 'E2E test'; metadata = @{ source = 'e2e' } }
        $state.sessionId = $s.id
        $null = Api POST "/eb-backend/sessions/$($s.id)/events" @{ kind = 'message'; source = 'customer'; message = $Message }
        $hit = Read-SseUntil "/eb-backend/sessions/$($s.id)/events?sse=true&min_offset=0&kinds=message,status,tool" {
            param($e) $e.kind -eq 'message' -and $e.source -match 'ai_agent|agent' -and (Get-ReplyText $e)
        } $ReplyTimeoutSec
        $state.replyText = Get-ReplyText $hit.Event
        "session $($s.id); $($hit.Count) SSE events; reply: $($state.replyText.Substring(0, [Math]::Min(80, $state.replyText.Length)))"
    }

    $null = Step 'file upload to RustFS + download via /viewer' {
        $tmp = Join-Path ([IO.Path]::GetTempPath()) "e2e-upload-$([guid]::NewGuid().ToString('N').Substring(0,6)).txt"
        Set-Content -LiteralPath $tmp -Value "sales-agent e2e $(Get-Date -Format o)" -NoNewline
        try {
            $form = @{ file = Get-Item -LiteralPath $tmp }
            if ($state.sessionId) { $form.session_id = $state.sessionId }
            $r = Invoke-WebRequest -Uri "$BaseUrl/eb-backend/upload" -Method Post -Form $form -WebSession $web -SkipHttpErrorCheck
            if ($r.StatusCode -ge 400) { throw "upload HTTP $($r.StatusCode): $($r.Content)" }
            $j = $r.Content | ConvertFrom-Json -Depth 10
            $url = $j.url ?? $j.file_url ?? $j.data.url
            if (-not $url) { throw "no url in upload response: $($r.Content)" }
            $state.uploadUrl = $url
            $state.uploadBody = Get-Content -Raw -LiteralPath $tmp
            if ($url -notmatch '/viewer/') { throw "unexpected file URL $url" }
            $local = $url -replace '^https?://[^/]+', $BaseUrl
            $dl = Invoke-WebRequest $local -SkipHttpErrorCheck
            if ($dl.StatusCode -ne 200 -or "$($dl.Content)" -ne $state.uploadBody) { throw "download HTTP $($dl.StatusCode) / content mismatch" }
            "stored and served: $url"
        } finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }

    if ($ProposalPrompt -and $state.sessionId) {
        $null = Step 'proposal PDF generation' {
            $events = Api GET "/eb-backend/sessions/$($state.sessionId)/events?min_offset=0"
            $next = (@($events) | Measure-Object -Property offset -Maximum).Maximum + 1
            $null = Api POST "/eb-backend/sessions/$($state.sessionId)/events" @{ kind = 'message'; source = 'customer'; message = $ProposalPrompt }
            $hit = Read-SseUntil "/eb-backend/sessions/$($state.sessionId)/events?sse=true&min_offset=$next&kinds=message,status,tool" {
                param($e) $e.kind -eq 'message' -and (Get-ReplyText $e) -match '\.pdf'
            } ([Math]::Max($ReplyTimeoutSec, 600))
            $link = [regex]::Match((Get-ReplyText $hit.Event), 'https?://\S+?\.pdf').Value
            if ($link) {
                $pdf = Invoke-WebRequest ($link -replace '^https?://[^/]+', $BaseUrl) -SkipHttpErrorCheck
                if ($pdf.StatusCode -ne 200 -or [Text.Encoding]::ASCII.GetString($pdf.Content[0..3]) -ne '%PDF') { throw "PDF link not downloadable: $link ($($pdf.StatusCode))" }
            }
            "pdf: $link"
        }
    }

    if (-not $SkipRestart -and $ConfigDir) {
        $null = Step 'restart stack (Install-SalesAgent.ps1 stop + start)' {
            $ps1 = Join-Path $installer 'Install-SalesAgent.ps1'
            & pwsh -NoProfile -File $ps1 stop -ConfigDir $ConfigDir | Out-Null
            if ($LASTEXITCODE -ne 0) { throw 'stop failed' }
            & pwsh -NoProfile -File $ps1 start -ConfigDir $ConfigDir -NoBrowser | Out-Null
            if ($LASTEXITCODE -ne 0) { throw 'start failed' }
            'restarted and healthy'
        }
        $null = Step 'persistence after restart (session in MongoDB, file in RustFS, login in PostgreSQL)' {
            $web = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
            Set-Variable -Name web -Value $web -Scope Script
            $r = Api POST '/api/login' @{ username = $Username; password = $plain } -Raw
            if ($r.StatusCode -ne 200) { throw "re-login HTTP $($r.StatusCode)" }
            if ($state.sessionId) {
                $events = @(Api GET "/eb-backend/sessions/$($state.sessionId)/events?min_offset=0")
                if (-not ($events | Where-Object { $_.kind -eq 'message' -and $_.data.message -eq $Message })) { throw 'previous session messages not found' }
            }
            if ($state.uploadUrl) {
                $dl = Invoke-WebRequest ($state.uploadUrl -replace '^https?://[^/]+', $BaseUrl) -SkipHttpErrorCheck
                if ($dl.StatusCode -ne 200 -or "$($dl.Content)" -ne $state.uploadBody) { throw 'uploaded file missing after restart' }
            }
            'session history and uploaded file intact'
        }
    }
}

Write-Host ''
$results | Format-Table Step, Result, Seconds, Detail -AutoSize -Wrap | Out-String -Width 220 | Write-Host
$failed = @($results | Where-Object Result -eq 'FAIL').Count
if ($failed) { Write-Host "$failed step(s) failed" -ForegroundColor Red; exit 1 }
Write-Host 'All E2E steps passed.' -ForegroundColor Green
