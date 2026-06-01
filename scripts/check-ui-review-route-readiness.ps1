param(
    [ValidateSet("rr001", "launcher", "projection", "display")]
    [string]$Preset = "rr001",

    [string]$TargetsFile = "",
    [string]$Only = "",

    [string]$LauncherUrl = "http://127.0.0.1:8799/",
    [string]$AituberUrl = "http://127.0.0.1:18880/",
    [string]$DisplayUrl = "http://127.0.0.1:18889/",

    [int]$TimeoutMs = 1200,

    [switch]$Json,
    [switch]$FailOnNotReady
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Join-ReviewUrl {
    param(
        [Parameter(Mandatory = $true)][string]$BaseUrl,
        [Parameter(Mandatory = $true)][string]$RelativePath
    )

    return ([System.Uri]::new([System.Uri]::new($BaseUrl), $RelativePath)).AbsoluteUri
}

function New-RouteTarget {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$Surface,
        [Parameter(Mandatory = $true)][string]$Url,
        [string]$Viewport = "",
        [ValidateSet("current", "stale", "known-gap")]
        [string]$ExpectedState = "current"
    )

    [pscustomobject]@{
        target_id = $Id
        surface = $Surface
        url = $Url
        viewport = $Viewport
        expected_state = $ExpectedState
    }
}

function Get-PresetTargets {
    param(
        [Parameter(Mandatory = $true)][string]$Name
    )

    $launcherTargets = @(
        New-RouteTarget -Id "launcher-1366x768" -Surface "Launcher" -Url $LauncherUrl -Viewport "1366x768"
        New-RouteTarget -Id "launcher-1920x1080" -Surface "Launcher" -Url $LauncherUrl -Viewport "1920x1080"
    )

    $displayTargets = @(
        New-RouteTarget -Id "aituber-root-1366x768" -Surface "AITuber root" -Url $AituberUrl -Viewport "1366x768"
        New-RouteTarget -Id "display-gui-1366x768" -Surface "Display Runtime GUI" -Url $DisplayUrl -Viewport "1366x768"
    )

    $projectionTargets = @(
        New-RouteTarget -Id "projection-operator-1920x1080" -Surface "Projection Visual operator" -Url (Join-ReviewUrl -BaseUrl $AituberUrl -RelativePath "/projection-visual/") -Viewport "1920x1080"
        New-RouteTarget -Id "projection-passive-1920x1080" -Surface "Passive Projection" -Url (Join-ReviewUrl -BaseUrl $AituberUrl -RelativePath "/projection-visual/?mode=passive") -Viewport "1920x1080"
        New-RouteTarget -Id "projection-passive-hud0-1920x1080" -Surface "Passive Projection HUD hidden" -Url (Join-ReviewUrl -BaseUrl $AituberUrl -RelativePath "/projection-visual/?mode=passive&hud=0") -Viewport "1920x1080"
    )

    switch ($Name) {
        "launcher" { return $launcherTargets }
        "display" { return $displayTargets }
        "projection" { return $projectionTargets }
        "rr001" { return @($launcherTargets + $displayTargets + $projectionTargets) }
    }
}

function Get-RouteExpectedState {
    param(
        [Parameter(Mandatory = $true)]$Item
    )

    foreach ($name in @("expected_state", "review_state", "route_label")) {
        if (($Item.PSObject.Properties.Name -contains $name) -and $Item.$name) {
            $value = ([string]$Item.$name).Trim().ToLowerInvariant().Replace("_", "-")
            if ($value -in @("current", "stale", "known-gap")) {
                return $value
            }
        }
    }

    return "current"
}

function Get-TargetsFromFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path
    )

    $resolvedPath = Resolve-Path -LiteralPath $Path
    $document = Get-Content -LiteralPath $resolvedPath -Raw | ConvertFrom-Json

    $items = @()
    if ($document.PSObject.Properties.Name -contains "targets") {
        $items = @($document.targets)
    }
    elseif ($document -is [array]) {
        $items = @($document)
    }
    else {
        $items = @($document)
    }

    foreach ($item in $items) {
        $id = if ($item.PSObject.Properties.Name -contains "target_id") { $item.target_id } else { $item.id }
        $surface = if ($item.PSObject.Properties.Name -contains "surface") { $item.surface } else { $id }
        $viewport = ""
        if (($item.PSObject.Properties.Name -contains "viewport") -and $item.viewport) {
            $viewport = $item.viewport
        }
        elseif (($item.PSObject.Properties.Name -contains "width") -and ($item.PSObject.Properties.Name -contains "height")) {
            $viewport = "{0}x{1}" -f $item.width, $item.height
        }

        New-RouteTarget -Id $id -Surface $surface -Url $item.url -Viewport $viewport -ExpectedState (Get-RouteExpectedState -Item $item)
    }
}

function Get-ExceptionText {
    param(
        [Parameter(Mandatory = $true)][System.Exception]$Exception
    )

    $parts = New-Object System.Collections.Generic.List[string]
    $cursor = $Exception
    while ($null -ne $cursor) {
        $parts.Add($cursor.GetType().FullName)
        if ($cursor.Message) {
            $parts.Add($cursor.Message)
        }
        $cursor = $cursor.InnerException
    }

    return ($parts -join " ")
}

function Classify-RouteError {
    param(
        [Parameter(Mandatory = $true)][System.Exception]$Exception
    )

    $text = (Get-ExceptionText -Exception $Exception).ToLowerInvariant()

    if ($text -match "timeout|timed out|taskcanceledexception|operationcanceledexception") {
        return [pscustomobject]@{ Status = "timeout"; ErrorClass = "timeout"; Detail = "probe timed out" }
    }

    if ($text -match "connection refused|actively refused|unable to connect|no connection could be made|connectionfailure|nameresolutionfailure") {
        return [pscustomobject]@{ Status = "down"; ErrorClass = "connection"; Detail = "route is not accepting connections" }
    }

    if ($text -match "invalid uri|invaliduri|uriformatexception") {
        return [pscustomobject]@{ Status = "unexpected_http"; ErrorClass = "invalid_url"; Detail = "target url is invalid" }
    }

    return [pscustomobject]@{ Status = "unexpected_http"; ErrorClass = "probe_error"; Detail = "probe failed before headers were received" }
}

function Get-RouteLabel {
    param(
        [Parameter(Mandatory = $true)][string]$Status,
        [Parameter(Mandatory = $true)][string]$ExpectedState
    )

    if ($ExpectedState -eq "known-gap") {
        return "known-gap"
    }
    if ($Status -eq "timeout") {
        return "timeout"
    }
    if ($Status -eq "ready") {
        return $ExpectedState
    }
    return "missing"
}

function Test-RouteTarget {
    param(
        [Parameter(Mandatory = $true)][System.Net.Http.HttpClient]$Client,
        [Parameter(Mandatory = $true)]$Target
    )

    $checkedAt = (Get-Date).ToString("o")
    $httpStatus = $null
    $status = "unexpected_http"
    $errorClass = $null
    $detail = ""
    $expectedState = Get-RouteExpectedState -Item $Target

    try {
        $uri = [System.Uri]::new($Target.url)
        $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Get, $uri)
        $response = $null

        try {
            $response = $Client.SendAsync($request, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
            $httpStatus = [int]$response.StatusCode

            if ($httpStatus -ge 200 -and $httpStatus -lt 400) {
                $status = "ready"
                $detail = "headers received"
            }
            elseif ($httpStatus -eq 404 -or $httpStatus -eq 410) {
                $status = "route_missing"
                $errorClass = "http_not_found"
                $detail = "route returned missing status"
            }
            else {
                $status = "unexpected_http"
                $errorClass = "http_status"
                $detail = "route returned unexpected status"
            }
        }
        finally {
            if ($null -ne $response) {
                $response.Dispose()
            }
            $request.Dispose()
        }
    }
    catch {
        $classification = Classify-RouteError -Exception $_.Exception
        $status = $classification.Status
        $errorClass = $classification.ErrorClass
        $detail = $classification.Detail
    }

    $routeLabel = Get-RouteLabel -Status $status -ExpectedState $expectedState
    $captureReady = ($status -eq "ready" -and $routeLabel -eq "current")

    [pscustomobject]@{
        target_id = $Target.target_id
        surface = $Target.surface
        url = $Target.url
        viewport = $Target.viewport
        expected_state = $expectedState
        status = $status
        route_label = $routeLabel
        http_status = $httpStatus
        capture_ready = $captureReady
        safe_to_capture = $captureReady
        error_class = $errorClass
        detail = $detail
        checked_at = $checkedAt
    }
}

function Get-OverallStatus {
    param(
        [Parameter(Mandatory = $true)][array]$Results
    )

    if ($Results.Count -eq 0) {
        return "unknown"
    }

    $readyCount = @($Results | Where-Object { $_.capture_ready }).Count
    if ($readyCount -eq $Results.Count) {
        return "ready_for_capture"
    }

    if ($readyCount -eq 0) {
        return "blocked_routes_down"
    }

    return "partial_ready"
}

if ($TimeoutMs -lt 1) {
    throw "TimeoutMs must be greater than zero."
}

Add-Type -AssemblyName System.Net.Http

$targets = if ($TargetsFile) {
    @(Get-TargetsFromFile -Path $TargetsFile)
}
else {
    @(Get-PresetTargets -Name $Preset)
}

if ($Only.Trim()) {
    $selectedIds = @($Only -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $targets = @($targets | Where-Object { $selectedIds -contains $_.target_id })
}

$handler = [System.Net.Http.HttpClientHandler]::new()
$handler.AllowAutoRedirect = $false
$client = [System.Net.Http.HttpClient]::new($handler)
$client.Timeout = [TimeSpan]::FromMilliseconds($TimeoutMs)

try {
    $results = @($targets | ForEach-Object { Test-RouteTarget -Client $client -Target $_ })
}
finally {
    $client.Dispose()
    $handler.Dispose()
}

$readyCount = @($results | Where-Object { $_.capture_ready }).Count
$routeLabels = [pscustomobject]@{
    current = @($results | Where-Object { $_.route_label -eq "current" }).Count
    stale = @($results | Where-Object { $_.route_label -eq "stale" }).Count
    missing = @($results | Where-Object { $_.route_label -eq "missing" }).Count
    timeout = @($results | Where-Object { $_.route_label -eq "timeout" }).Count
    known_gap = @($results | Where-Object { $_.route_label -eq "known-gap" }).Count
}
$overall = [pscustomobject]@{
    script_version = "0.2.0"
    checked_at = (Get-Date).ToString("o")
    preset = if ($TargetsFile) { "custom" } else { $Preset }
    timeout_ms = $TimeoutMs
    overall_status = Get-OverallStatus -Results $results
    summary = [pscustomobject]@{
        total = $results.Count
        ready = $readyCount
        not_ready = $results.Count - $readyCount
        route_labels = $routeLabels
    }
    targets = $results
}

if ($Json) {
    $overall | ConvertTo-Json -Depth 6
}
else {
    $results | Format-Table target_id, route_label, status, http_status, capture_ready, error_class, detail -AutoSize
    "overall_status: {0}; ready: {1}/{2}; timeout_ms: {3}" -f $overall.overall_status, $readyCount, $results.Count, $TimeoutMs
}

if ($FailOnNotReady -and $overall.overall_status -ne "ready_for_capture") {
    exit 2
}
