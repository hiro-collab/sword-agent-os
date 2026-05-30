param(
  [ValidateSet("isolated_override", "manifest_default")]
  [string]$PortMode = "isolated_override",

  [int]$TimeoutMs = 2500,

  [string]$ReportPath = ""
)

$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.Net.Http

$repoRoot = Split-Path -Parent $PSScriptRoot
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
if ([string]::IsNullOrWhiteSpace($ReportPath)) {
  $reportDir = Join-Path $repoRoot ".cache\agent-os\fuzz"
  New-Item -ItemType Directory -Force -Path $reportDir | Out-Null
  $ReportPath = Join-Path $reportDir "communication-fuzz-$timestamp.json"
}

$portsByMode = @{
  isolated_override = @{
    Aituber = 18880
    Environment = 18890
    Home = 18887
    Thought = 18888
    Display = 18889
  }
  manifest_default = @{
    Aituber = 3000
    Environment = 8790
    Home = 8787
    Thought = 18787
    Display = 8788
  }
}

$ports = $portsByMode[$PortMode]
$cases = New-Object System.Collections.Generic.List[object]

function New-Url([int]$Port, [string]$Path) {
  return "http://127.0.0.1:$Port$Path"
}

function Add-Case {
  param(
    [string]$Id,
    [string]$Service,
    [string]$Method,
    [string]$Url,
    [int[]]$ExpectedStatus,
    [AllowNull()]
    [object]$Body = $null,
    [AllowNull()]
    [string]$RawBody = $null,
    [hashtable]$Headers = @{},
    [string]$ContentType = "application/json",
    [string]$Intent = ""
  )

  $bodyKind = "none"
  $bodyChars = 0
  $bodyText = $null
  if ($PSBoundParameters.ContainsKey("Body")) {
    $bodyKind = "json"
    $bodyText = $Body | ConvertTo-Json -Depth 20 -Compress
    $bodyChars = ($bodyText | Measure-Object -Character).Characters
  } elseif ($PSBoundParameters.ContainsKey("RawBody")) {
    $bodyKind = "raw"
    $bodyText = [string]$RawBody
    $bodyChars = ($bodyText | Measure-Object -Character).Characters
  }

  $cases.Add([pscustomobject]@{
    id = $Id
    service = $Service
    method = $Method
    url = $Url
    expected_status = $ExpectedStatus
    body_text = $bodyText
    body_kind = $bodyKind
    body_chars = $bodyChars
    headers = $Headers
    content_type = $ContentType
    intent = $Intent
  }) | Out-Null
}

$fuzzClient = "fuzz-$([guid]::NewGuid().ToString('N').Substring(0, 12))"
$longClientId = "a" * 129
$tooManyMessages = @(1..21 | ForEach-Object { "msg-$_" })
$largeThoughtCoreBody = "{`"text`":`"$("x" * 70000)`"}"

Add-Case -Id "aituber.messages.get.empty_queue" -Service "aituber_kit" -Method "GET" `
  -Url (New-Url $ports.Aituber "/api/messages/?clientId=$fuzzClient&type=direct_send") `
  -ExpectedStatus @(200) -Intent "safe queue read"

Add-Case -Id "aituber.messages.post.missing_client_id" -Service "aituber_kit" -Method "POST" `
  -Url (New-Url $ports.Aituber "/api/messages/?type=direct_send") `
  -ExpectedStatus @(400) -Body @{ messages = @("hello") } -Intent "missing required query"

Add-Case -Id "aituber.messages.post.reserved_client_id" -Service "aituber_kit" -Method "POST" `
  -Url (New-Url $ports.Aituber "/api/messages/?clientId=__proto__&type=direct_send") `
  -ExpectedStatus @(400) -Body @{ messages = @("hello") } -Intent "prototype pollution guard"

Add-Case -Id "aituber.messages.post.long_client_id" -Service "aituber_kit" -Method "POST" `
  -Url (New-Url $ports.Aituber "/api/messages/?clientId=$longClientId&type=direct_send") `
  -ExpectedStatus @(400) -Body @{ messages = @("hello") } -Intent "client id length guard"

Add-Case -Id "aituber.messages.post.invalid_type" -Service "aituber_kit" -Method "POST" `
  -Url (New-Url $ports.Aituber "/api/messages/?clientId=$fuzzClient&type=../../x") `
  -ExpectedStatus @(400) -Body @{ messages = @("hello") } -Intent "enum guard"

Add-Case -Id "aituber.messages.post.messages_not_array" -Service "aituber_kit" -Method "POST" `
  -Url (New-Url $ports.Aituber "/api/messages/?clientId=$fuzzClient&type=direct_send") `
  -ExpectedStatus @(400) -Body @{ messages = "hello" } -Intent "shape guard"

Add-Case -Id "aituber.messages.post.too_many_messages" -Service "aituber_kit" -Method "POST" `
  -Url (New-Url $ports.Aituber "/api/messages/?clientId=$fuzzClient&type=direct_send") `
  -ExpectedStatus @(413) -Body @{ messages = $tooManyMessages } -Intent "queue batch limit"

Add-Case -Id "aituber.messages.post.blank_message" -Service "aituber_kit" -Method "POST" `
  -Url (New-Url $ports.Aituber "/api/messages/?clientId=$fuzzClient&type=direct_send") `
  -ExpectedStatus @(400) -Body @{ messages = @("   ") } -Intent "empty text guard"

Add-Case -Id "aituber.messages.post.system_prompt_not_string" -Service "aituber_kit" -Method "POST" `
  -Url (New-Url $ports.Aituber "/api/messages/?clientId=$fuzzClient&type=direct_send") `
  -ExpectedStatus @(400) -Body @{ messages = @("hello"); systemPrompt = @{ nested = $true } } `
  -Intent "system prompt type guard"

Add-Case -Id "aituber.messages.post.invalid_image_data_uri" -Service "aituber_kit" -Method "POST" `
  -Url (New-Url $ports.Aituber "/api/messages/?clientId=$fuzzClient&type=direct_send") `
  -ExpectedStatus @(400) -Body @{ messages = @("hello"); image = "not-an-image" } `
  -Intent "image data uri guard"

Add-Case -Id "aituber.thought_core_chat.get_disallowed" -Service "aituber_kit" -Method "GET" `
  -Url (New-Url $ports.Aituber "/api/thoughtCoreChat/") `
  -ExpectedStatus @(405) -Intent "method guard"

Add-Case -Id "aituber.thought_core_chat.empty_query" -Service "aituber_kit" -Method "POST" `
  -Url (New-Url $ports.Aituber "/api/thoughtCoreChat/") `
  -ExpectedStatus @(400) -Body @{ query = " " } -Intent "empty query guard"

Add-Case -Id "aituber.thought_core_chat.query_not_string" -Service "aituber_kit" -Method "POST" `
  -Url (New-Url $ports.Aituber "/api/thoughtCoreChat/") `
  -ExpectedStatus @(400) -Body @{ query = @{ text = "test" }; url = "https://example.com" } `
  -Intent "query type guard without downstream call"

Add-Case -Id "aituber.thought_core_chat.query_array" -Service "aituber_kit" -Method "POST" `
  -Url (New-Url $ports.Aituber "/api/thoughtCoreChat/") `
  -ExpectedStatus @(400) -Body @{ query = @("test"); url = "http://user:pass@127.0.0.1:$($ports.Thought)" } `
  -Intent "query type guard without downstream call"

Add-Case -Id "environment.health" -Service "environment_state_server" -Method "GET" `
  -Url (New-Url $ports.Environment "/health") -ExpectedStatus @(200) `
  -Intent "baseline health"

Add-Case -Id "environment.indicators.current" -Service "environment_state_server" -Method "GET" `
  -Url (New-Url $ports.Environment "/indicators/current") -ExpectedStatus @(200) `
  -Intent "safe local read"

Add-Case -Id "environment.indicators.options" -Service "environment_state_server" -Method "OPTIONS" `
  -Url (New-Url $ports.Environment "/indicators/current") -ExpectedStatus @(204) `
  -Headers @{ Origin = "http://127.0.0.1:$($ports.Aituber)" } -Intent "CORS preflight"

Add-Case -Id "environment.current.unauthorized" -Service "environment_state_server" -Method "GET" `
  -Url (New-Url $ports.Environment "/environment/current") -ExpectedStatus @(401) `
  -Intent "auth guard"

Add-Case -Id "environment.feedback.summary.unauthorized" -Service "environment_state_server" -Method "GET" `
  -Url (New-Url $ports.Environment "/feedback/state-query/summary?target=room_light&limit=bad") `
  -ExpectedStatus @(401) -Intent "auth guard before query parsing"

Add-Case -Id "home.health" -Service "home_assistant_bridge" -Method "GET" `
  -Url (New-Url $ports.Home "/health") -ExpectedStatus @(200, 503) `
  -Intent "baseline health; HA may be degraded"

Add-Case -Id "home.actions.unauthorized" -Service "home_assistant_bridge" -Method "GET" `
  -Url (New-Url $ports.Home "/actions") -ExpectedStatus @(401) `
  -Intent "auth guard"

Add-Case -Id "home.preview.unauthorized" -Service "home_assistant_bridge" -Method "POST" `
  -Url (New-Url $ports.Home "/actions/not-allowlisted/preview") -ExpectedStatus @(401) `
  -Body @{ dry_run = $true; request_id = "fuzz-no-auth" } -Intent "auth guard before action lookup"

Add-Case -Id "thought.health" -Service "thought_core_api" -Method "GET" `
  -Url (New-Url $ports.Thought "/health") -ExpectedStatus @(200) `
  -Intent "baseline health"

Add-Case -Id "thought.turn_stream.get_disallowed" -Service "thought_core_api" -Method "GET" `
  -Url (New-Url $ports.Thought "/turn/stream") -ExpectedStatus @(405) `
  -Intent "method guard"

Add-Case -Id "thought.turn.empty_body" -Service "thought_core_api" -Method "POST" `
  -Url (New-Url $ports.Thought "/turn") -ExpectedStatus @(400) `
  -RawBody "" -Intent "empty JSON guard"

Add-Case -Id "thought.turn.invalid_json" -Service "thought_core_api" -Method "POST" `
  -Url (New-Url $ports.Thought "/turn") -ExpectedStatus @(400) `
  -RawBody "{not-json" -Intent "JSON parse guard"

Add-Case -Id "thought.turn.array_body" -Service "thought_core_api" -Method "POST" `
  -Url (New-Url $ports.Thought "/turn") -ExpectedStatus @(400) `
  -RawBody "[]" -Intent "object shape guard"

Add-Case -Id "thought.turn.oversized_body" -Service "thought_core_api" -Method "POST" `
  -Url (New-Url $ports.Thought "/turn") -ExpectedStatus @(413) `
  -RawBody $largeThoughtCoreBody -Intent "body size guard"

Add-Case -Id "thought.turn.untrusted_origin" -Service "thought_core_api" -Method "POST" `
  -Url (New-Url $ports.Thought "/turn") -ExpectedStatus @(403) `
  -RawBody "{}" -Headers @{ Origin = "https://evil.example" } -Intent "origin guard"

Add-Case -Id "display.root" -Service "touchdesigner_control_gui" -Method "GET" `
  -Url (New-Url $ports.Display "/") -ExpectedStatus @(200) `
  -Intent "baseline UI"

Add-Case -Id "display.status" -Service "touchdesigner_control_gui" -Method "GET" `
  -Url (New-Url $ports.Display "/api/status") -ExpectedStatus @(200) `
  -Intent "safe status read"

Add-Case -Id "display.status.post_disallowed" -Service "touchdesigner_control_gui" -Method "POST" `
  -Url (New-Url $ports.Display "/api/status") -ExpectedStatus @(405) `
  -RawBody "{}" -Intent "method guard"

Add-Case -Id "display.status.untrusted_origin" -Service "touchdesigner_control_gui" -Method "GET" `
  -Url (New-Url $ports.Display "/api/status") -ExpectedStatus @(403) `
  -Headers @{ Origin = "https://evil.example" } -Intent "origin guard"

Add-Case -Id "display.static.path_traversal_like" -Service "touchdesigner_control_gui" -Method "GET" `
  -Url (New-Url $ports.Display "/%2e%2e/tools/server.js") -ExpectedStatus @(403, 404) `
  -Intent "static file traversal guard"

function ConvertTo-RequestBodyText($Case) {
  return $Case.body_text
}

function ConvertTo-RedactedErrorDetail($ErrorRecord) {
  $exception = $ErrorRecord.Exception
  $typeName = "UnknownException"
  if ($null -ne $exception) {
    $typeName = $exception.GetType().Name
  }

  $category = "NotSpecified"
  if ($null -ne $ErrorRecord.CategoryInfo) {
    $category = [string]$ErrorRecord.CategoryInfo.Category
  }

  return ("{0}:{1}" -f $typeName, $category)
}

function Invoke-FuzzCase($Client, $Case) {
  $started = Get-Date
  $request = [System.Net.Http.HttpRequestMessage]::new(
    [System.Net.Http.HttpMethod]::new($Case.method),
    [Uri]$Case.url
  )
  $request.Headers.TryAddWithoutValidation("User-Agent", "sword-agent-os-communication-fuzz/0.1") | Out-Null
  foreach ($header in $Case.headers.GetEnumerator()) {
    $request.Headers.TryAddWithoutValidation([string]$header.Key, [string]$header.Value) | Out-Null
  }

  $bodyText = ConvertTo-RequestBodyText $Case
  if ($null -ne $bodyText) {
    $contentBytes = [System.Text.Encoding]::UTF8.GetBytes($bodyText)
    $request.Content = [System.Net.Http.ByteArrayContent]::new($contentBytes)
    $request.Content.Headers.TryAddWithoutValidation("Content-Type", $Case.content_type) | Out-Null
  }

  try {
    $response = $Client.SendAsync($request).GetAwaiter().GetResult()
    $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    $statusCode = [int]$response.StatusCode
    $expected = @($Case.expected_status)
    $result = if ($expected -contains $statusCode) { "pass" } else { "fail" }
    return [pscustomobject]@{
      id = $Case.id
      service = $Case.service
      result = $result
      method = $Case.method
      status = $statusCode
      expected_status = $expected
      latency_ms = [int]((Get-Date) - $started).TotalMilliseconds
      body_kind = $Case.body_kind
      body_chars = $Case.body_chars
      response_chars = ($body | Measure-Object -Character).Characters
      intent = $Case.intent
    }
  } catch {
    return [pscustomobject]@{
      id = $Case.id
      service = $Case.service
      result = "blocked"
      method = $Case.method
      status = $null
      expected_status = @($Case.expected_status)
      latency_ms = [int]((Get-Date) - $started).TotalMilliseconds
      body_kind = $Case.body_kind
      body_chars = $Case.body_chars
      response_chars = 0
      intent = $Case.intent
      detail = ConvertTo-RedactedErrorDetail $_
    }
  } finally {
    $request.Dispose()
  }
}

$client = [System.Net.Http.HttpClient]::new()
$client.Timeout = [TimeSpan]::FromMilliseconds($TimeoutMs)

try {
  $results = foreach ($case in $cases) {
    Invoke-FuzzCase -Client $client -Case $case
  }
} finally {
  $client.Dispose()
}

$summary = [ordered]@{
  pass = @($results | Where-Object { $_.result -eq "pass" }).Count
  fail = @($results | Where-Object { $_.result -eq "fail" }).Count
  blocked = @($results | Where-Object { $_.result -eq "blocked" }).Count
  total = @($results).Count
}

$report = [ordered]@{
  schema_version = "communication-fuzz.report.v0"
  generated_at = (Get-Date).ToUniversalTime().ToString("o")
  port_mode = $PortMode
  safety = @{
    side_effects = "disabled"
    websocket_strict = "disabled"
    udp = "disabled"
    raw_bodies_in_report = $false
    blocked_error_detail = "redacted_class_only"
  }
  summary = $summary
  results = $results
}

$report | ConvertTo-Json -Depth 12 | Set-Content -Encoding UTF8 -Path $ReportPath

Write-Output "communication fuzz report: $ReportPath"
Write-Output "pass=$($summary.pass) fail=$($summary.fail) blocked=$($summary.blocked) total=$($summary.total)"

if ($summary.fail -gt 0) {
  $results |
    Where-Object { $_.result -eq "fail" } |
    Select-Object id, service, status, expected_status, intent |
    Format-Table -AutoSize | Out-String | Write-Output
  exit 1
}
