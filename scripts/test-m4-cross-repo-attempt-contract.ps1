param(
  [switch]$ParentOnly,
  [string]$VectorPath = ""
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$RepoRoot = Split-Path -Parent $PSScriptRoot
$ExamplesRoot = Join-Path $RepoRoot "contracts\accepted_user_speech_candidate_input_gate\examples"
$ExpectedVectorPath = Join-Path $ExamplesRoot "m4_cross_repo_attempt_vectors.v0.json"
$CanonicalRefPattern = '^m4\.prepared_sample_attempt:[a-f0-9]{32}$'
$RequiredRowNames = @(
  "recognition",
  "input_gate",
  "thought_core_turninput",
  "canonical_assistant_response",
  "bubble",
  "tts",
  "bubble_tts_parity",
  "self_mirror_observation",
  "self_output_session_correlation",
  "user_heard"
)

function Assert-True {
  param([Parameter(Mandatory = $true)][bool]$Condition, [Parameter(Mandatory = $true)][string]$Message)
  if (-not $Condition) { throw $Message }
}

function Get-RequiredProperty {
  param([Parameter(Mandatory = $true)]$Object, [Parameter(Mandatory = $true)][string]$Name)
  $property = $Object.PSObject.Properties[$Name]
  if ($null -eq $property) { throw "fixture property missing: $Name" }
  return $property.Value
}

function Resolve-VectorPath {
  param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$RequestedPath)
  $candidate = if ([string]::IsNullOrWhiteSpace($RequestedPath)) { $ExpectedVectorPath } else { $RequestedPath }
  $resolvedExamplesRoot = [System.IO.Path]::GetFullPath($ExamplesRoot).TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
  $resolved = [System.IO.Path]::GetFullPath($candidate)
  Assert-True ($resolved.StartsWith($resolvedExamplesRoot, [System.StringComparison]::OrdinalIgnoreCase)) "fixture must resolve beneath Parent contract examples area"
  Assert-True ([string]::Equals($resolved, [System.IO.Path]::GetFullPath($ExpectedVectorPath), [System.StringComparison]::OrdinalIgnoreCase)) "only the owned M4 fixture is accepted"
  Assert-True (Test-Path -LiteralPath $resolved -PathType Leaf) "fixture missing: $resolved"
  return $resolved
}

function Test-JoinCase {
  param([Parameter(Mandatory = $true)]$Rows, [Parameter(Mandatory = $true)][string]$CanonicalRef)
  $actualNames = @($Rows | ForEach-Object { [string](Get-RequiredProperty $_ "row_name") })
  if ($actualNames.Count -ne $RequiredRowNames.Count) { return $false }
  if (@(Compare-Object $actualNames $RequiredRowNames -CaseSensitive).Count -ne 0) { return $false }
  foreach ($row in @($Rows)) {
    if ((Get-RequiredProperty $row "conversation_attempt_ref") -cne $CanonicalRef) { return $false }
  }
  return $true
}

function Invoke-Consumer {
  param([Parameter(Mandatory = $true)][string]$Name, [Parameter(Mandatory = $true)][string]$WorkingDirectory, [Parameter(Mandatory = $true)][string[]]$Command)
  Write-Host "[m4-contract] consumer=$Name"
  Push-Location $WorkingDirectory
  try {
    & $Command[0] @($Command | Select-Object -Skip 1)
    if ($LASTEXITCODE -ne 0) { throw "$Name consumer failed with exit code $LASTEXITCODE" }
  }
  finally {
    Pop-Location
  }
}

$resolvedVectorPath = Resolve-VectorPath -RequestedPath $VectorPath
$vectors = Get-Content -Raw -LiteralPath $resolvedVectorPath | ConvertFrom-Json

Assert-True ((Get-RequiredProperty $vectors "schema_version") -ceq "m4_cross_repo_attempt_vectors.v0") "fixture schema_version must be the M4 test-vector identifier"
Assert-True ((Get-RequiredProperty $vectors "fixture_kind") -ceq "non_schema_test_vectors") "fixture must remain non-schema test vectors"
$canonicalRef = [string](Get-RequiredProperty $vectors "canonical_conversation_attempt_ref")
Assert-True ($canonicalRef -cmatch $CanonicalRefPattern) "canonical conversation attempt ref is invalid"

$invalidRefs = Get-RequiredProperty $vectors "invalid_conversation_attempt_refs"
foreach ($name in @("colonless", "uppercase", "wrong_prefix", "short", "long", "unsafe", "whitespace")) {
  $value = [string](Get-RequiredProperty $invalidRefs $name)
  Assert-True ($value -cnotmatch $CanonicalRefPattern) "invalid ref unexpectedly accepted: $name"
}

$candidate = Get-RequiredProperty $vectors "accepted_user_speech_candidate"
Assert-True ((Get-RequiredProperty $candidate "schema_version") -ceq "accepted_user_speech_candidate_input_gate.v0") "candidate schema version is invalid"
Assert-True ((Get-RequiredProperty $candidate "candidate_route") -ceq "prepared_sample_browser_stt") "candidate must remain prepared-sample based"
Assert-True ((Get-RequiredProperty $candidate "raw_private_publication_flags") -eq $false) "candidate must not publish private data"
$privateTurn = Get-RequiredProperty $vectors "private_turn"
Assert-True ((Get-RequiredProperty $privateTurn "text") -eq $null) "Parent fixture must not invent a legacy private placeholder"
Assert-True ((Get-RequiredProperty $privateTurn "text_representation") -ceq "legacy_no_speech_placeholder_not_publicly_representable_in_parent_fixture") "private turn placeholder status is invalid"
Assert-True ((Get-RequiredProperty (Get-RequiredProperty $privateTurn "context_refs") "conversation_attempt_ref") -ceq $canonicalRef) "private turn ref must be canonical"

$assistantEvent = Get-RequiredProperty $vectors "assistant_event"
Assert-True ((Get-RequiredProperty (Get-RequiredProperty $assistantEvent "data") "conversation_attempt_ref") -ceq "injected:not_authoritative") "assistant event must carry the hostile injected ref vector"
Assert-True ((Get-RequiredProperty $assistantEvent "expected_conversation_attempt_ref") -ceq $canonicalRef) "assistant event replacement ref must be canonical"
Assert-True ((Get-RequiredProperty $assistantEvent "injected_ref_must_be_stripped_or_replaced") -eq $true) "assistant event must require hostile ref removal"

$joinContract = Get-RequiredProperty $vectors "join_contract"
$fixtureRows = @((Get-RequiredProperty $joinContract "required_row_names"))
Assert-True ($fixtureRows.Count -eq 10) "join contract must contain exactly ten required rows"
Assert-True (@(Compare-Object $fixtureRows $RequiredRowNames -CaseSensitive).Count -eq 0) "join contract row names do not match the exact required set"
Assert-True ((Get-RequiredProperty $joinContract "correlation_basis") -ceq "conversation_attempt_ref_only") "join correlation must be attempt-ref only"
$prohibited = @((Get-RequiredProperty $joinContract "correlation_inference_prohibited_from"))
Assert-True (@(Compare-Object $prohibited @("text", "message_id", "turn_id", "session_id") -CaseSensitive).Count -eq 0) "join inference prohibition is incomplete"
$cases = Get-RequiredProperty $joinContract "cases"
$validCase = Get-RequiredProperty $cases "valid_all_rows"
$validRows = @(Get-RequiredProperty $validCase "rows")
Assert-True (Test-JoinCase -Rows $validRows -CanonicalRef $canonicalRef) "valid all-row join must pass exactly"
$missingCase = Get-RequiredProperty $cases "missing_row"
Assert-True ((Get-RequiredProperty $missingCase "expected_result") -ceq "fail") "missing-row case must fail"
$missingRowName = [string](Get-RequiredProperty $missingCase "missing_row_name")
Assert-True ($missingRowName -ceq "user_heard") "missing-row vector must hold user_heard"
$missingRows = @($validRows | Where-Object { (Get-RequiredProperty $_ "row_name") -cne $missingRowName })
Assert-True (-not (Test-JoinCase -Rows $missingRows -CanonicalRef $canonicalRef)) "missing required row must fail without identifier inference"
$mismatchedCase = Get-RequiredProperty $cases "mismatched_ref"
Assert-True ((Get-RequiredProperty $mismatchedCase "expected_result") -ceq "fail") "mismatched-ref case must fail"
$mismatchedRowName = [string](Get-RequiredProperty $mismatchedCase "row_name")
$mismatchedRef = [string](Get-RequiredProperty $mismatchedCase "conversation_attempt_ref")
Assert-True ($mismatchedRef -cne $canonicalRef) "mismatched-ref case must differ from canonical"
$mismatchedRows = @($validRows | ForEach-Object {
  [PSCustomObject]@{
    row_name = Get-RequiredProperty $_ "row_name"
    conversation_attempt_ref = if ((Get-RequiredProperty $_ "row_name") -ceq $mismatchedRowName) { $mismatchedRef } else { Get-RequiredProperty $_ "conversation_attempt_ref" }
  }
})
Assert-True (-not (Test-JoinCase -Rows $mismatchedRows -CanonicalRef $canonicalRef)) "mismatched attempt ref must fail without text, message, turn, or session inference"

$aitSources = Get-RequiredProperty $vectors "ait_source_vectors"
foreach ($sourceName in @("chat", "passive", "operator")) {
  $source = Get-RequiredProperty $aitSources $sourceName
  Assert-True ((Get-RequiredProperty $source "source_kind") -ceq $sourceName) "AIT source vector kind mismatch: $sourceName"
  Assert-True ((Get-RequiredProperty $source "conversation_attempt_ref") -ceq $canonicalRef) "AIT source vector ref mismatch: $sourceName"
}

Write-Host "[m4-contract] parent vectors: ok"
if ($ParentOnly) {
  Write-Host "[m4-contract] ParentOnly: consumer tests skipped"
  exit 0
}

$previousVectorPath = [Environment]::GetEnvironmentVariable("SWORD_M4_SHARED_VECTOR_PATH", "Process")
try {
  [Environment]::SetEnvironmentVariable("SWORD_M4_SHARED_VECTOR_PATH", $resolvedVectorPath, "Process")
  Invoke-Consumer -Name "Core" -WorkingDirectory (Join-Path $RepoRoot "control-plane\core") -Command @(
    "uv", "--cache-dir", ".uv-cache", "run", "python", "-m", "unittest",
    "tests.test_no_provider_child_provenance",
    "tests.test_watch_handoff_to_thought_core"
  )
  Invoke-Consumer -Name "AIT" -WorkingDirectory (Join-Path $RepoRoot "organs\expression\aituber-kit") -Command @(
    "npm", "test", "--", "--runInBand",
    "src/__tests__/utils/preparedSampleBrowserStt.test.ts",
    "src/__tests__/pages/operator/prepared-sample-stt.test.tsx",
    "src/__tests__/utils/speechOutputParitySummary.test.ts",
    "src/__tests__/worker2ProjectionVisualOrganContract.test.ts"
  )
}
finally {
  [Environment]::SetEnvironmentVariable("SWORD_M4_SHARED_VECTOR_PATH", $previousVectorPath, "Process")
}

Write-Host "[m4-contract] consumers: ok"
