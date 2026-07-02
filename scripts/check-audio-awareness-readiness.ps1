param(
  [switch]$Json,
  [switch]$ListRows
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$RepoRoot = Split-Path -Parent $PSScriptRoot

function Resolve-RepoPath {
  param([Parameter(Mandatory = $true)][string]$Path)
  return Join-Path $RepoRoot ($Path -replace "/", [System.IO.Path]::DirectorySeparatorChar)
}

function Read-JsonFile {
  param([Parameter(Mandatory = $true)][string]$Path)
  return Get-Content -Raw -LiteralPath (Resolve-RepoPath $Path) | ConvertFrom-Json
}

function Get-ObjectProperty {
  param(
    [AllowNull()]$Object,
    [Parameter(Mandatory = $true)][string]$Name,
    [object]$Default = $null
  )
  if ($null -eq $Object) {
    return $Default
  }
  $property = $Object.PSObject.Properties[$Name]
  if ($null -eq $property) {
    return $Default
  }
  return $property.Value
}

function Test-FalseProperty {
  param(
    [AllowNull()]$Object,
    [Parameter(Mandatory = $true)][string]$Name
  )
  return (Get-ObjectProperty -Object $Object -Name $Name -Default "__missing__") -eq $false
}

function New-ReadinessRow {
  param(
    [Parameter(Mandatory = $true)][string]$Id,
    [Parameter(Mandatory = $true)][string]$Status,
    [Parameter(Mandatory = $true)][string]$PassClass,
    [Parameter(Mandatory = $true)][string]$HoldClass,
    [Parameter(Mandatory = $true)][string]$Detail,
    [string]$Layer = "source_static"
  )

  [PSCustomObject]@{
    id = $Id
    status = $Status
    pass_class = $PassClass
    hold_class = $HoldClass
    layer = $Layer
    detail = $Detail
  }
}

function Join-ShortList {
  param([string[]]$Values)
  if ($Values.Count -eq 0) {
    return "none"
  }
  return ($Values -join ",")
}

$rowCatalog = @(
  [PSCustomObject]@{
    id = "source_static_files"
    pass = "all_expected_files_present"
    hold = "missing_audio_awareness_source_static_file"
    detail = "contract, fixture, runtime, organ, manifest, docs, and readiness files are present"
  },
  [PSCustomObject]@{
    id = "summary_contract_boundary"
    pass = "audio_awareness_summary_contract_no_live_source_static"
    hold = "audio_awareness_summary_contract_boundary_missing"
    detail = "summary schema separates pc_output, microphone, speech-input VAD adapter, redaction, transcript, and no-live source/static flags"
  },
  [PSCustomObject]@{
    id = "summary_fixture_no_live"
    pass = "audio_awareness_fixture_summary_only"
    hold = "audio_awareness_fixture_unsafe_or_incomplete"
    detail = "example fixture is source/static summary-only and carries no raw audio, transcript, provider, or authority claim"
  },
  [PSCustomObject]@{
    id = "consumer_routes_boundary"
    pass = "consumer_routes_observation_only"
    hold = "consumer_routes_boundary_missing"
    detail = "route map exposes source/static readers and keeps future live adapters behind reviewed routes"
  },
  [PSCustomObject]@{
    id = "hearing_organ_binding"
    pass = "sense_hearing_primary_audio_awareness_scaffold"
    hold = "sense_hearing_primary_binding_missing"
    detail = "audio awareness remains under speech-input hearing organ ownership"
  },
  [PSCustomObject]@{
    id = "body_plan_contract_refs"
    pass = "body_plan_declares_audio_awareness_contracts"
    hold = "body_plan_audio_awareness_contract_refs_missing"
    detail = "body plan compatible_contracts include audio awareness result and consumer route contracts"
  },
  [PSCustomObject]@{
    id = "driver_manifest_observer"
    pass = "hearing_observer_compat_driver_no_actions"
    hold = "hearing_observer_compat_driver_missing_or_actionable"
    detail = "driver manifest exposes hearing observer status keys without actions"
  },
  [PSCustomObject]@{
    id = "docs_and_preflight_refs"
    pass = "docs_and_preflight_reference_source_static_audio_awareness"
    hold = "docs_or_preflight_audio_awareness_refs_missing"
    detail = "contracts, runtime, reference-surface, module index, and visible-demo preflight docs reference the source/static surface"
  },
  [PSCustomObject]@{
    id = "no_live_self_tests"
    pass = "node_audio_awareness_tests_pass"
    hold = "node_audio_awareness_tests_failed"
    detail = "node --test runtime/audio-awareness/tests/audio-awareness.test.mjs passes without endpoint, device, capture, provider, browser, or Home Assistant operations"
  }
)

if ($ListRows) {
  $rows = @(
    $rowCatalog | ForEach-Object {
      New-ReadinessRow `
        -Id $_.id `
        -Status "not_evaluated" `
        -PassClass $_.pass `
        -HoldClass $_.hold `
        -Detail $_.detail
    }
  )
}
else {
  $rows = @()

  $expectedFiles = @(
    "contracts/audio_awareness_summary/audio_awareness_summary.v0.schema.json",
    "contracts/audio_awareness_summary/examples/pc-output-voicevox-correlated.example.json",
    "contracts/audio_awareness_consumer_routes/audio_awareness_consumer_routes.v0.schema.json",
    "runtime/audio-awareness/audio-awareness.mjs",
    "runtime/audio-awareness/tests/audio-awareness.test.mjs",
    "runtime/audio-awareness/audio-awareness-consumer-routes.json",
    "runtime/audio-awareness/README.md",
    "organs/speech-input/audio-awareness/README.md",
    "scripts/check-audio-awareness-readiness.ps1",
    "manifests/body-plans/system-cell-v0.json",
    "manifests/driver-manifests/system-cell-v0.json",
    "scripts/run-visible-demo-preflight.ps1",
    "contracts/README.md",
    "docs/audio-awareness.md",
    "docs/reference-surfaces.md",
    "docs/module-usage-index.md",
    "runtime/README.md"
  )
  $missingFiles = @(
    $expectedFiles | Where-Object {
      -not (Test-Path -LiteralPath (Resolve-RepoPath $_) -PathType Leaf)
    }
  )
  $rows += New-ReadinessRow `
    -Id "source_static_files" `
    -Status $(if ($missingFiles.Count -eq 0) { "pass" } else { "hold" }) `
    -PassClass "all_expected_files_present" `
    -HoldClass "missing_audio_awareness_source_static_file" `
    -Detail $(if ($missingFiles.Count -eq 0) { "files={0}" -f $expectedFiles.Count } else { "missing={0}" -f (Join-ShortList $missingFiles) })

  try {
    $summarySchema = Read-JsonFile -Path "contracts/audio_awareness_summary/audio_awareness_summary.v0.schema.json"
    $summaryDefs = $summarySchema.PSObject.Properties["`$defs"].Value
    $channelKinds = @($summaryDefs.channel_summary.properties.channel_kind.enum | ForEach-Object { [string]$_ })
    $speechSources = @($summaryDefs.channel_summary.properties.speech_presence_source.enum | ForEach-Object { [string]$_ })
    $nonClaimConsts = @($summarySchema.properties.non_claims.allOf | ForEach-Object { [string]$_.contains.const })
    $captureProps = $summarySchema.properties.capture_permissions.properties
    $transcriptProps = $summarySchema.properties.transcript.properties
    $safetyProps = $summarySchema.properties.safety.properties
    $sourceStaticCaptureProps = $summarySchema.allOf[0].then.properties.capture_permissions.properties
    $safeRefPattern = [string]$summaryDefs.safe_ref.pattern
    $failures = @()
    if ([string]$summarySchema.properties.schema_version.const -ne "audio_awareness_summary.v0") { $failures += "schema_version" }
    foreach ($kind in @("pc_output", "microphone", "speech_input_vad_adapter")) {
      if ($kind -notin $channelKinds) { $failures += "channel_kind:$kind" }
    }
    foreach ($source in @("speech_input_vad_adapter", "synthetic_fixture")) {
      if ($source -notin $speechSources) { $failures += "speech_source:$source" }
    }
    foreach ($field in @("provider_network_stt_enabled", "raw_audio_retained", "raw_audio_persisted")) {
      if ((Get-ObjectProperty -Object $captureProps.$field -Name "const" -Default $true) -ne $false) { $failures += "capture:$field" }
    }
    foreach ($field in @("pc_output_capture_enabled", "microphone_capture_enabled", "live_capture_used")) {
      if ((Get-ObjectProperty -Object $sourceStaticCaptureProps.$field -Name "const" -Default $true) -ne $false) { $failures += "source_static_capture:$field" }
    }
    foreach ($field in @("full_transcript_saved", "raw_transcript_included", "provider_payload_included")) {
      if ((Get-ObjectProperty -Object $transcriptProps.$field -Name "const" -Default $true) -ne $false) { $failures += "transcript:$field" }
    }
    if ([string]$transcriptProps.transcript_summary_ref.type -ne "null") { $failures += "transcript:transcript_summary_ref" }
    if ($safeRefPattern -match "\btts\b|\bplayback\b") { $failures += "safe_ref:legacy_prefix" }
    foreach ($field in @("command_authority", "home_assistant_action", "provider_network_authority", "user_heard_audio_authority")) {
      if ((Get-ObjectProperty -Object $safetyProps.$field -Name "const" -Default $true) -ne $false) { $failures += "safety:$field" }
    }
    foreach ($claim in @("not_user_heard_audio", "not_browser_audio_playback", "not_microphone_content", "not_raw_audio_publication", "not_full_transcript_publication")) {
      if ($claim -notin $nonClaimConsts) { $failures += "non_claim:$claim" }
    }
    $rows += New-ReadinessRow `
      -Id "summary_contract_boundary" `
      -Status $(if ($failures.Count -eq 0) { "pass" } else { "hold" }) `
      -PassClass "audio_awareness_summary_contract_no_live_source_static" `
      -HoldClass "audio_awareness_summary_contract_boundary_missing" `
      -Detail $(if ($failures.Count -eq 0) { "schema=audio_awareness_summary.v0; channels=pc_output,microphone,speech_input_vad_adapter" } else { "failed={0}" -f (Join-ShortList $failures) })
  }
  catch {
    $rows += New-ReadinessRow -Id "summary_contract_boundary" -Status "hold" -PassClass "audio_awareness_summary_contract_no_live_source_static" -HoldClass "audio_awareness_summary_contract_boundary_missing" -Detail "schema_unreadable_or_invalid_json"
  }

  try {
    $fixture = Read-JsonFile -Path "contracts/audio_awareness_summary/examples/pc-output-voicevox-correlated.example.json"
    $permissions = $fixture.capture_permissions
    $fixtureChannelKinds = @($fixture.channels | ForEach-Object { [string]$_.channel_kind })
    $failures = @()
    if ([string]$fixture.schema_version -ne "audio_awareness_summary.v0") { $failures += "schema_version" }
    if ([string]$fixture.source_mode -notin @("source_static", "synthetic_fixture")) { $failures += "source_mode" }
    foreach ($field in @("pc_output_capture_enabled", "microphone_capture_enabled", "live_capture_used", "provider_network_stt_enabled", "raw_audio_retained", "raw_audio_persisted")) {
      if (-not (Test-FalseProperty -Object $permissions -Name $field)) { $failures += "capture:$field" }
    }
    foreach ($kind in @("pc_output", "microphone")) {
      if ($kind -notin $fixtureChannelKinds) { $failures += "channel:$kind" }
    }
    foreach ($field in @("raw_audio_shared", "raw_audio_persisted", "raw_transcript_shared", "provider_payload_shared")) {
      if (-not (Test-FalseProperty -Object $fixture.redaction -Name $field)) { $failures += "redaction:$field" }
    }
    foreach ($field in @("full_transcript_saved", "raw_transcript_included", "provider_payload_included")) {
      if (-not (Test-FalseProperty -Object $fixture.transcript -Name $field)) { $failures += "transcript:$field" }
    }
    if ($null -ne $fixture.correlation.self_output_event_ref) { $failures += "correlation:self_output_event_ref" }
    if ($null -ne $fixture.correlation.playback_event_ref) { $failures += "correlation:playback_event_ref" }
    if ($null -ne $fixture.transcript.transcript_summary_ref) { $failures += "transcript:transcript_summary_ref" }
    foreach ($field in @("command_authority", "home_assistant_action", "browser_visible_audio_authority", "user_heard_audio_authority", "release_or_final_rr003_authority")) {
      if (-not (Test-FalseProperty -Object $fixture.safety -Name $field)) { $failures += "safety:$field" }
    }
    foreach ($claim in @("not_user_heard_audio", "not_browser_audio_playback", "not_microphone_content", "not_home_assistant_action")) {
      if ($claim -notin @($fixture.non_claims)) { $failures += "non_claim:$claim" }
    }
    $rows += New-ReadinessRow `
      -Id "summary_fixture_no_live" `
      -Status $(if ($failures.Count -eq 0) { "pass" } else { "hold" }) `
      -PassClass "audio_awareness_fixture_summary_only" `
      -HoldClass "audio_awareness_fixture_unsafe_or_incomplete" `
      -Detail $(if ($failures.Count -eq 0) { "fixture=pc-output-voicevox-correlated; capture=false; raw_audio=false; transcript=false" } else { "failed={0}" -f (Join-ShortList $failures) })
  }
  catch {
    $rows += New-ReadinessRow -Id "summary_fixture_no_live" -Status "hold" -PassClass "audio_awareness_fixture_summary_only" -HoldClass "audio_awareness_fixture_unsafe_or_incomplete" -Detail "fixture_unreadable_or_invalid_json"
  }

  try {
    $routes = Read-JsonFile -Path "runtime/audio-awareness/audio-awareness-consumer-routes.json"
    $routesSchema = Read-JsonFile -Path "contracts/audio_awareness_consumer_routes/audio_awareness_consumer_routes.v0.schema.json"
    $routeIds = @($routes.routes | ForEach-Object { [string]$_.route_id })
    $failures = @()
    if ([string]$routes.schema_version -ne "audio_awareness_consumer_routes.v0") { $failures += "schema_version" }
    if ([string]$routes.contract_ref -ne "contracts/audio_awareness_consumer_routes/audio_awareness_consumer_routes.v0.schema.json") { $failures += "contract_ref" }
    if ([string]$routes.result_contract_ref -ne "contracts/audio_awareness_summary/audio_awareness_summary.v0.schema.json") { $failures += "result_contract_ref" }
    if ([string]$routes.organ_readme -ne "organs/speech-input/audio-awareness/README.md") { $failures += "organ_readme" }
    foreach ($field in @("command_authority", "action_authority", "provider_call", "default_live_microphone_capture", "default_pc_output_capture", "raw_audio_shared", "raw_transcript_shared", "home_assistant_identifier_shared", "user_heard_audio_authority", "physical_device_proof")) {
      if (-not (Test-FalseProperty -Object $routes.global_boundaries -Name $field)) { $failures += "global:$field" }
    }
    foreach ($routeId in @("audio_awareness.source_static.synthetic_summary_fixture", "audio_awareness.source_static.speech_input_vad_adapter")) {
      if ($routeId -notin $routeIds) { $failures += "route:$routeId" }
    }
    foreach ($field in @("provider_call", "default_live_microphone_capture", "default_pc_output_capture", "raw_audio_shared")) {
      $schemaField = $routesSchema.properties.global_boundaries.properties.$field
      if ((Get-ObjectProperty -Object $schemaField -Name "const" -Default $true) -ne $false) { $failures += "schema_global:$field" }
    }
    $rows += New-ReadinessRow `
      -Id "consumer_routes_boundary" `
      -Status $(if ($failures.Count -eq 0) { "pass" } else { "hold" }) `
      -PassClass "consumer_routes_observation_only" `
      -HoldClass "consumer_routes_boundary_missing" `
      -Detail $(if ($failures.Count -eq 0) { "routes=source_static_fixture,speech_input_vad_adapter; default_live_capture=false" } else { "failed={0}" -f (Join-ShortList $failures) })
  }
  catch {
    $rows += New-ReadinessRow -Id "consumer_routes_boundary" -Status "hold" -PassClass "consumer_routes_observation_only" -HoldClass "consumer_routes_boundary_missing" -Detail "routes_unreadable_or_invalid_json"
  }

  try {
    $bodyPlan = Read-JsonFile -Path "manifests/body-plans/system-cell-v0.json"
    $organReadme = Get-Content -Raw -LiteralPath (Resolve-RepoPath "organs/speech-input/audio-awareness/README.md")
    $hearingOrgan = @($bodyPlan.organs | Where-Object { [string]$_.organ_id -eq "sense.hearing.primary" }) | Select-Object -First 1
    $driverRefs = @()
    if ($null -ne $hearingOrgan) {
      $driverRefs = @($hearingOrgan.driver_manifest_refs | ForEach-Object { [string]$_ })
    }
    $failures = @()
    if ($null -eq $hearingOrgan) { $failures += "sense.hearing.primary" }
    if ("browser_speech_input_driver" -notin $driverRefs) { $failures += "browser_speech_input_driver" }
    if ("hearing_audio_awareness_observer_driver" -notin $driverRefs) { $failures += "hearing_audio_awareness_observer_driver" }
    foreach ($text in @("sense.hearing.primary", "runtime/audio-awareness", "contracts/audio_awareness_summary")) {
      if ($organReadme -notmatch [regex]::Escape($text)) { $failures += "readme:$text" }
    }
    $rows += New-ReadinessRow `
      -Id "hearing_organ_binding" `
      -Status $(if ($failures.Count -eq 0) { "pass" } else { "hold" }) `
      -PassClass "sense_hearing_primary_audio_awareness_scaffold" `
      -HoldClass "sense_hearing_primary_binding_missing" `
      -Detail $(if ($failures.Count -eq 0) { "organ=sense.hearing.primary; driver_refs=browser_speech_input_driver,hearing_audio_awareness_observer_driver" } else { "failed={0}" -f (Join-ShortList $failures) })
  }
  catch {
    $rows += New-ReadinessRow -Id "hearing_organ_binding" -Status "hold" -PassClass "sense_hearing_primary_audio_awareness_scaffold" -HoldClass "sense_hearing_primary_binding_missing" -Detail "body_plan_or_organ_readme_unreadable"
  }

  try {
    $bodyPlan = Read-JsonFile -Path "manifests/body-plans/system-cell-v0.json"
    $contractValues = @($bodyPlan.compatible_contracts.PSObject.Properties | ForEach-Object { [string]$_.Value })
    $failures = @()
    foreach ($contract in @("audio_awareness_summary.v0", "audio_awareness_consumer_routes.v0")) {
      if ($contract -notin $contractValues) { $failures += $contract }
    }
    $rows += New-ReadinessRow `
      -Id "body_plan_contract_refs" `
      -Status $(if ($failures.Count -eq 0) { "pass" } else { "hold" }) `
      -PassClass "body_plan_declares_audio_awareness_contracts" `
      -HoldClass "body_plan_audio_awareness_contract_refs_missing" `
      -Detail $(if ($failures.Count -eq 0) { "contracts=audio_awareness_summary.v0,audio_awareness_consumer_routes.v0" } else { "missing={0}" -f (Join-ShortList $failures) })
  }
  catch {
    $rows += New-ReadinessRow -Id "body_plan_contract_refs" -Status "hold" -PassClass "body_plan_declares_audio_awareness_contracts" -HoldClass "body_plan_audio_awareness_contract_refs_missing" -Detail "body_plan_unreadable_or_invalid_json"
  }

  try {
    $driverManifest = Read-JsonFile -Path "manifests/driver-manifests/system-cell-v0.json"
    $driver = @($driverManifest.drivers | Where-Object { [string]$_.driver_id -eq "hearing_audio_awareness_observer_driver" }) | Select-Object -First 1
    $statusKeys = @()
    $actions = @()
    if ($null -ne $driver) {
      $statusKeys = @($driver.status_keys | ForEach-Object { [string]$_ })
      $actions = @($driver.provides_actions)
    }
    $failures = @()
    if ($null -eq $driver) { $failures += "driver_missing" }
    elseif ([string]$driver.driver_kind -ne "compat_adapter") { $failures += "driver_kind" }
    if ($null -ne $driver -and [string]$driver.organ_id -ne "sense.hearing.primary") { $failures += "organ_id" }
    if ($actions.Count -ne 0) { $failures += "provides_actions" }
    foreach ($key in @("sense.hearing.primary.audio_awareness.summary", "sense.hearing.primary.audio_awareness.pc_output", "sense.hearing.primary.audio_awareness.microphone")) {
      if ($key -notin $statusKeys) { $failures += "status_key:$key" }
    }
    $rows += New-ReadinessRow `
      -Id "driver_manifest_observer" `
      -Status $(if ($failures.Count -eq 0) { "pass" } else { "hold" }) `
      -PassClass "hearing_observer_compat_driver_no_actions" `
      -HoldClass "hearing_observer_compat_driver_missing_or_actionable" `
      -Detail $(if ($failures.Count -eq 0) { "driver=hearing_audio_awareness_observer_driver; provides_actions=0" } else { "failed={0}" -f (Join-ShortList $failures) })
  }
  catch {
    $rows += New-ReadinessRow -Id "driver_manifest_observer" -Status "hold" -PassClass "hearing_observer_compat_driver_no_actions" -HoldClass "hearing_observer_compat_driver_missing_or_actionable" -Detail "driver_manifest_unreadable_or_invalid_json"
  }

  try {
    $contractsReadme = Get-Content -Raw -LiteralPath (Resolve-RepoPath "contracts/README.md")
    $audioAwarenessDoc = Get-Content -Raw -LiteralPath (Resolve-RepoPath "docs/audio-awareness.md")
    $referenceSurfaces = Get-Content -Raw -LiteralPath (Resolve-RepoPath "docs/reference-surfaces.md")
    $moduleUsage = Get-Content -Raw -LiteralPath (Resolve-RepoPath "docs/module-usage-index.md")
    $runtimeReadme = Get-Content -Raw -LiteralPath (Resolve-RepoPath "runtime/README.md")
    $preflight = Get-Content -Raw -LiteralPath (Resolve-RepoPath "scripts/run-visible-demo-preflight.ps1")
    $failures = @()
    if ($contractsReadme -notmatch "audio_awareness_summary/audio_awareness_summary\.v0\.schema\.json") { $failures += "contracts_readme:summary" }
    if ($contractsReadme -notmatch "audio_awareness_consumer_routes/audio_awareness_consumer_routes\.v0\.schema\.json") { $failures += "contracts_readme:routes" }
    if ($contractsReadme -notmatch "audio_self_output_observation\.v0") { $failures += "contracts_readme:self_output_split" }
    if ($audioAwarenessDoc -notmatch "sense\.hearing\.primary") { $failures += "audio_awareness_doc:body_role" }
    if ($audioAwarenessDoc -notmatch "PC-output loopback summary") { $failures += "audio_awareness_doc:proof_layers" }
    if ($audioAwarenessDoc -notmatch "audio_self_output_observation\.v0") { $failures += "audio_awareness_doc:self_output_split" }
    if ($audioAwarenessDoc -notmatch "raw\s+audio[\s\S]{0,80}transcript bodies[\s\S]{0,80}private paths") { $failures += "audio_awareness_doc:raw_private" }
    if ($referenceSurfaces -notmatch "Audio Awareness Example") { $failures += "reference_surfaces" }
    if ($referenceSurfaces -notmatch "audio_self_output_observation\.v0") { $failures += "reference_surfaces:self_output_split" }
    if ($moduleUsage -notmatch "Audio Awareness") { $failures += "module_usage" }
    if ($moduleUsage -notmatch "audio_self_output_observation\.v0") { $failures += "module_usage:self_output_split" }
    if ($runtimeReadme -notmatch "audio-awareness") { $failures += "runtime_readme" }
    if ($preflight -notmatch "audio_awareness_source_static") { $failures += "visible_demo_preflight" }
    $rows += New-ReadinessRow `
      -Id "docs_and_preflight_refs" `
      -Status $(if ($failures.Count -eq 0) { "pass" } else { "hold" }) `
      -PassClass "docs_and_preflight_reference_source_static_audio_awareness" `
      -HoldClass "docs_or_preflight_audio_awareness_refs_missing" `
      -Detail $(if ($failures.Count -eq 0) { "docs=contracts,reference-surfaces,module-usage,runtime; preflight=source_static_row" } else { "failed={0}" -f (Join-ShortList $failures) })
  }
  catch {
    $rows += New-ReadinessRow -Id "docs_and_preflight_refs" -Status "hold" -PassClass "docs_and_preflight_reference_source_static_audio_awareness" -HoldClass "docs_or_preflight_audio_awareness_refs_missing" -Detail "docs_or_preflight_unreadable"
  }

  $previousErrorActionPreference = $ErrorActionPreference
  try {
    $ErrorActionPreference = "Continue"
    $testOutput = & node --test (Resolve-RepoPath "runtime/audio-awareness/tests/audio-awareness.test.mjs") 2>&1
    $nodeExitCode = $LASTEXITCODE
  }
  finally {
    $ErrorActionPreference = $previousErrorActionPreference
  }
  $testLines = @($testOutput | ForEach-Object { [string]$_ })
  $passLine = @($testLines | Where-Object { $_ -match "pass\s+[0-9]+" } | Select-Object -Last 1)
  $testDetail = "exit_code={0}" -f $nodeExitCode
  if ($nodeExitCode -eq 0) {
    $testSummary = "tests_passed"
    if ($passLine.Count -gt 0) {
      $testSummary = $passLine[0].Trim()
    }
    $testDetail = "exit_code=0; {0}" -f $testSummary
  }
  $rows += New-ReadinessRow `
    -Id "no_live_self_tests" `
    -Status $(if ($nodeExitCode -eq 0) { "pass" } else { "hold" }) `
    -PassClass "node_audio_awareness_tests_pass" `
    -HoldClass "node_audio_awareness_tests_failed" `
    -Detail $testDetail
}

$holds = @($rows | Where-Object { $_.status -eq "hold" })
$passes = @($rows | Where-Object { $_.status -eq "pass" })
$infos = @($rows | Where-Object { $_.status -eq "info" -or $_.status -eq "not_evaluated" })

$result = [PSCustomObject]@{
  route_id = "HEARING-ORGAN-PC-OUTPUT-MIC-AWARENESS-01"
  entrypoint_class = "audio_awareness_source_static_readiness"
  default_safety = [PSCustomObject]@{
    live_pc_output_capture = $false
    live_microphone_capture = $false
    provider_network_stt_tts = $false
    browser_device_home_assistant_operations = $false
    raw_audio_transcript_log_media_handling = $false
  }
  status = if ($ListRows) { "rows_listed" } elseif ($holds.Count -gt 0) { "hold" } else { "pass" }
  counts = [PSCustomObject]@{
    rows = $rows.Count
    pass = $passes.Count
    hold = $holds.Count
    info_or_not_evaluated = $infos.Count
  }
  rows = @($rows)
  proof_ceiling = "audio_awareness_source_static_summary_only"
  proof_layer_notes = [PSCustomObject]@{
    source_static = "contract, docs, manifests, fixture, and no-live self-tests only"
    pc_output = "pc-output channel summary shape only; no live loopback capture"
    microphone = "microphone channel summary shape only; no live microphone capture"
    speech_input_vad_adapter = "speech-input VAD metadata mapping only; nested ai-talk-core is not refactored here"
  }
  raw_private_publication_flags = $false
  non_claims = @(
    "no live PC-output capture",
    "no live microphone capture",
    "no provider/network STT/TTS",
    "no browser/device/Home Assistant/Home Control operation",
    "no raw audio/transcript/log/media handling",
    "no user-heard audio proof",
    "no browser audio playback proof",
    "no physical/device proof",
    "no release/readiness/final RR003 pass"
  )
}

if ($Json) {
  $result | ConvertTo-Json -Depth 8
  return
}

Write-Host "Audio awareness source/static readiness"
Write-Host ("status={0}" -f $result.status)
Write-Host ("rows={0} pass={1} hold={2}" -f $result.counts.rows, $result.counts.pass, $result.counts.hold)
foreach ($row in $rows) {
  Write-Host ("{0}: {1} pass={2} hold={3} detail={4}" -f $row.id, $row.status, $row.pass_class, $row.hold_class, $row.detail)
}
Write-Host "proof_ceiling=audio_awareness_source_static_summary_only"
Write-Host "raw_private_publication_flags=false"
Write-Host "non_claims=no_live_pc_output_capture,no_live_microphone_capture,no_provider_network_stt_tts,no_browser_device_home_assistant_operation,no_raw_audio_transcript_log_media_handling,no_user_heard_audio_proof,no_browser_audio_playback_proof,no_physical_device_proof,no_final_rr003_pass"
