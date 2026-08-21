[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$ScriptRoot = Split-Path -Parent $PSScriptRoot
$SkillRoot = Split-Path -Parent $ScriptRoot
$RepositoryRoot = (Resolve-Path (Join-Path $SkillRoot '..\..\..')).Path
$LauncherPath = Join-Path $ScriptRoot 'Invoke-DeliveryStage.ps1'
$TestRoot = Join-Path ([System.IO.Path]::GetTempPath()) (
	'aetheln-delivery-stage-preflight-tests-' + [guid]::NewGuid().ToString('N')
)
$MissingCodexBin = Join-Path $TestRoot 'missing-codex-bin'
$ChildSentinelPath = Join-Path $TestRoot 'child-launched.txt'
$Results = [System.Collections.Generic.List[object]]::new()
$Cases = [System.Collections.Generic.List[object]]::new()
$FrozenManifests = @{}
$Utf8NoBom = [System.Text.UTF8Encoding]::new($false)

function Add-Result {
	param(
		[Parameter(Mandatory)][string]$Name,
		[Parameter(Mandatory)][bool]$Passed,
		[string]$Detail = ''
	)

	[void]$Results.Add([pscustomobject]@{
		Name = $Name
		Passed = $Passed
		Detail = $Detail
	})
}

function Get-TestSha256 {
	param(
		[Parameter(Mandatory)]
		[AllowEmptyCollection()]
		[byte[]]$Bytes
	)

	$Hasher = [System.Security.Cryptography.SHA256]::Create()
	try {
		return [System.BitConverter]::ToString(
			$Hasher.ComputeHash($Bytes)
		).Replace('-', '').ToLowerInvariant()
	}
	finally {
		$Hasher.Dispose()
	}
}

function New-EvidenceRecord {
	param(
		[Parameter(Mandatory)][string]$Kind,
		[Parameter(Mandatory)][string]$Provenance,
		[Parameter(Mandatory)][string]$Source,
		[Parameter(Mandatory)][AllowEmptyString()][string]$Text
	)

	$Bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
	return [pscustomobject][ordered]@{
		kind = $Kind
		provenance = $Provenance
		encoding = 'utf8'
		source = $Source
		sha256 = Get-TestSha256 -Bytes $Bytes
		content = $Text
	}
}

function New-RequiredEvidenceDeclaration {
	param(
		[Parameter(Mandatory)][string]$Field,
		[Parameter(Mandatory)][object]$Record
	)

	return [pscustomobject][ordered]@{
		field = $Field
		kind = $Record.kind
		provenance = $Record.provenance
		encoding = $Record.encoding
		source = $Record.source
		sha256 = $Record.sha256
	}
}

function New-AuthoritativeEvidenceManifest {
	param(
		[Parameter(Mandatory)]
		[ValidateSet('verifier', 'approver')]
		[string]$Stage,

		[Parameter(Mandatory)][object]$Handoff
	)

	$FieldNames = if ($Stage -eq 'verifier') {
		@('candidate_artifact', 'raw_check_output')
	}
	else {
		@(
			'baseline_status',
			'baseline_diff',
			'final_artifact',
			'raw_check_output'
		)
	}
	$Records = [System.Collections.Generic.List[object]]::new()
	foreach ($FieldName in $FieldNames) {
		$Value = $Handoff.$FieldName
		$FieldRecords = if ($Value -is [System.Array]) {
			@($Value)
		}
		else {
			@($Value)
		}
		foreach ($Record in $FieldRecords) {
			[void]$Records.Add([pscustomobject][ordered]@{
				field = $FieldName
				kind = $Record.kind
				provenance = $Record.provenance
				encoding = $Record.encoding
				source = $Record.source
				sha256 = $Record.sha256
			})
		}
	}

	$Manifest = [pscustomobject][ordered]@{
		format = 'delivery_authoritative_evidence_manifest_v1'
		stage = $Stage
		records = [object[]]@($Records)
	}
	$Json = $Manifest | ConvertTo-Json -Depth 10 -Compress
	$Bytes = $Utf8NoBom.GetBytes($Json)
	return [pscustomobject]@{
		Manifest = $Manifest
		Json = $Json
		Bytes = [byte[]]$Bytes
		Sha256 = Get-TestSha256 -Bytes $Bytes
	}
}

function New-TestJsonBytes {
	param([Parameter(Mandatory)][AllowEmptyString()][string]$Json)

	$Bytes = $Utf8NoBom.GetBytes($Json)
	return [pscustomobject]@{
		Json = $Json
		Bytes = [byte[]]$Bytes
		Sha256 = Get-TestSha256 -Bytes $Bytes
	}
}

function Copy-JsonObject {
	param([Parameter(Mandatory)][object]$Value)

	return ($Value | ConvertTo-Json -Depth 20 -Compress | ConvertFrom-Json)
}

function Add-DuplicateJsonMemberAtFirstMatch {
	param(
		[Parameter(Mandatory)][string]$Json,
		[Parameter(Mandatory)][string]$Fragment,
		[Parameter(Mandatory)][string]$Replacement,
		[int]$StartIndex = 0
	)

	$Index = $Json.IndexOf(
		$Fragment,
		$StartIndex,
		[System.StringComparison]::Ordinal
	)
	if ($Index -lt 0) {
		throw 'Test JSON fragment was not found.'
	}
	return $Json.Substring(0, $Index) + $Replacement +
		$Json.Substring($Index + $Fragment.Length)
}

function New-StageHandoff {
	param(
		[Parameter(Mandatory)]
		[ValidateSet('verifier', 'approver')]
		[string]$Stage,

		[Parameter(Mandatory)][string]$RunId
	)

	$Common = [ordered]@{
		schema_version = 1
		stage = $Stage
		run_id = $RunId
		workspace_root = $RepositoryRoot
		source_commit = '0000000000000000000000000000000000000000'
		ticket = 'Issue #130'
		acceptance_criteria = @(
			'Reject incomplete routed evidence before launch.'
		)
		canonical_sources = @('AGENTS.md')
		output_contract = 'Return a structured stage result.'
	}
	$LauncherLog = New-EvidenceRecord -Kind 'command_log' `
		-Provenance 'launcher' -Source "$Stage-check.log" `
		-Text "$Stage check passed"
	$LinuxLog = New-EvidenceRecord -Kind 'command_log' `
		-Provenance 'launcher' -Source 'linux-server-build-log' `
		-Text 'Linux server build passed.'

	if ($Stage -eq 'verifier') {
		$CandidateArtifact = New-EvidenceRecord -Kind 'artifact' `
			-Provenance 'launcher' -Source 'verifier-candidate.json' `
			-Text 'verifier candidate'
		$Common.candidate_artifact = $CandidateArtifact
		$Common.test_environment = 'local'
		$Common.commands = @('focused verifier check')
		$Common.raw_check_output = @($LauncherLog, $LinuxLog)
		$Common.required_evidence_sources = @(
			(New-RequiredEvidenceDeclaration `
				-Field 'candidate_artifact' -Record $CandidateArtifact),
			(New-RequiredEvidenceDeclaration `
				-Field 'raw_check_output' -Record $LauncherLog),
			(New-RequiredEvidenceDeclaration `
				-Field 'raw_check_output' -Record $LinuxLog)
		)
	}
	else {
		$BaselineStatus = New-EvidenceRecord -Kind 'status' `
			-Provenance 'launcher' -Source 'approver-baseline-status.txt' `
			-Text ''
		$BaselineDiff = New-EvidenceRecord -Kind 'diff' `
			-Provenance 'launcher' -Source 'approver-baseline.diff' `
			-Text ''
		$FinalArtifact = New-EvidenceRecord -Kind 'artifact' `
			-Provenance 'launcher' -Source 'approver-final.json' `
			-Text 'approver candidate'
		$Common.baseline_status = $BaselineStatus
		$Common.baseline_diff = $BaselineDiff
		$Common.allowed_paths = @('AGENTS.md')
		$Common.non_goals = 'No repository mutation.'
		$Common.final_artifact = $FinalArtifact
		$Common.raw_check_output = @($LauncherLog, $LinuxLog)
		$Common.required_evidence_sources = @(
			(New-RequiredEvidenceDeclaration `
				-Field 'baseline_status' -Record $BaselineStatus),
			(New-RequiredEvidenceDeclaration `
				-Field 'baseline_diff' -Record $BaselineDiff),
			(New-RequiredEvidenceDeclaration `
				-Field 'final_artifact' -Record $FinalArtifact),
			(New-RequiredEvidenceDeclaration `
				-Field 'raw_check_output' -Record $LauncherLog),
			(New-RequiredEvidenceDeclaration `
				-Field 'raw_check_output' -Record $LinuxLog)
		)
	}

	return [pscustomobject]$Common
}

function Add-ObjectCase {
	param(
		[Parameter(Mandatory)][string]$Name,
		[Parameter(Mandatory)][string]$Stage,
		[Parameter(Mandatory)][string]$Field,
		[Parameter(Mandatory)][string]$Code,
		[Parameter(Mandatory)][object]$Handoff,
		[Parameter(Mandatory)][string]$PrivateMarker
	)

	[void]$Cases.Add([pscustomobject]@{
		Name = $Name
		Stage = $Stage
		Field = $Field
		Code = $Code
		Handoff = $Handoff
		Json = $null
		PrivateMarker = $PrivateMarker
	})
}

function Add-JsonCase {
	param(
		[Parameter(Mandatory)][string]$Name,
		[Parameter(Mandatory)][string]$Stage,
		[Parameter(Mandatory)][string]$Field,
		[Parameter(Mandatory)][string]$Code,
		[Parameter(Mandatory)][string]$Json,
		[Parameter(Mandatory)][string]$PrivateMarker
	)

	[void]$Cases.Add([pscustomobject]@{
		Name = $Name
		Stage = $Stage
		Field = $Field
		Code = $Code
		Handoff = $null
		Json = $Json
		PrivateMarker = $PrivateMarker
	})
}

function Add-ManifestCase {
	param(
		[Parameter(Mandatory)][string]$Name,
		[Parameter(Mandatory)]
		[ValidateSet('verifier', 'approver')]
		[string]$Stage,
		[Parameter(Mandatory)][string]$Field,
		[Parameter(Mandatory)][string]$Code,
		[Parameter(Mandatory)][object]$Handoff,
		[Parameter(Mandatory)]
		[AllowEmptyCollection()]
		[byte[]]$ManifestBytes,
		[AllowNull()][AllowEmptyString()][string]$ManifestSha256,
		[bool]$SupplyManifestPath = $true,
		[bool]$SupplyManifestSha256 = $true,
		[bool]$WriteManifest = $true,
		[string[]]$PrivateMarkers = @()
	)

	[void]$Cases.Add([pscustomobject]@{
		Name = $Name
		Stage = $Stage
		Field = $Field
		Code = $Code
		Handoff = $Handoff
		Json = $null
		PrivateMarker = ''
		CustomManifest = $true
		ManifestBytes = [byte[]]@($ManifestBytes)
		ManifestSha256 = $ManifestSha256
		SupplyManifestPath = $SupplyManifestPath
		SupplyManifestSha256 = $SupplyManifestSha256
		WriteManifest = $WriteManifest
		PrivateMarkers = [string[]]$PrivateMarkers
	})
}

function Get-RoutedRecord {
	param(
		[Parameter(Mandatory)][object]$Handoff,
		[Parameter(Mandatory)][string]$Field
	)

	if ($Field -eq 'raw_check_output') {
		return @($Handoff.$Field)[0]
	}
	return $Handoff.$Field
}

function Test-NoLaunchArtifacts {
	param([Parameter(Mandatory)][string]$ArtifactRoot)

	if (-not (Test-Path -LiteralPath $ArtifactRoot)) {
		return $true
	}
	return @(
		Get-ChildItem -LiteralPath $ArtifactRoot -Force -Recurse `
			-ErrorAction SilentlyContinue
	).Count -eq 0
}

function Invoke-InvalidPreflightCase {
	param(
		[Parameter(Mandatory)][object]$Case,
		[Parameter(Mandatory)][int]$Ordinal
	)

	$CaseRoot = Join-Path $TestRoot ('case-' + $Ordinal)
	[void][System.IO.Directory]::CreateDirectory($CaseRoot)
	$HandoffPath = Join-Path $CaseRoot 'handoff.json'
	$ManifestPath = Join-Path $CaseRoot 'private-authoritative-manifest.json'
	$ArtifactRoot = Join-Path $CaseRoot 'artifacts'
	$Json = if ($null -ne $Case.Json) {
		[string]$Case.Json
	}
	else {
		$Case.Handoff | ConvertTo-Json -Depth 20 -Compress
	}

	if (@($Case.PSObject.Properties.Name) -ccontains 'CustomManifest') {
		$ManifestBytes = [byte[]]@($Case.ManifestBytes)
		$ManifestSha256 = [string]$Case.ManifestSha256
		$SupplyManifestPath = [bool]$Case.SupplyManifestPath
		$SupplyManifestSha256 = [bool]$Case.SupplyManifestSha256
		$WriteManifest = [bool]$Case.WriteManifest
	}
	else {
		$FrozenManifest = $FrozenManifests[$Case.Stage]
		$ManifestBytes = [byte[]]$FrozenManifest.Bytes
		$ManifestSha256 = [string]$FrozenManifest.Sha256
		$SupplyManifestPath = $true
		$SupplyManifestSha256 = $true
		$WriteManifest = $true
	}

	if ($WriteManifest) {
		[System.IO.File]::WriteAllBytes($ManifestPath, $ManifestBytes)
	}
	[System.IO.File]::WriteAllText($HandoffPath, $Json, $Utf8NoBom)

	$Observed = [System.Collections.Generic.List[object]]::new()
	$CaughtError = $null
	$OriginalPath = $env:PATH
	$OriginalPreference = $ErrorActionPreference
	$OriginalLocation = (Get-Location).Path
	$OriginalProcessDirectory = [Environment]::CurrentDirectory
	try {
		$env:PATH = $MissingCodexBin
		$LauncherParameters = @{
			HandoffPath = $HandoffPath
			ArtifactRoot = $ArtifactRoot
			OutputPath = Join-Path $ArtifactRoot 'output.json'
			AuditPath = Join-Path $ArtifactRoot 'audit.json'
			TelemetryPath = Join-Path $ArtifactRoot 'telemetry.json'
		}
		if ($SupplyManifestPath) {
			$LauncherParameters.AuthoritativeEvidenceManifestPath =
				$ManifestPath
		}
		if ($SupplyManifestSha256) {
			$LauncherParameters.AuthoritativeEvidenceManifestSha256 =
				$ManifestSha256
		}
		& $LauncherPath @LauncherParameters |
			ForEach-Object { [void]$Observed.Add($_) }
	}
	catch {
		$CaughtError = $_
	}
	finally {
		$env:PATH = $OriginalPath
		$ErrorActionPreference = $OriginalPreference
		[Environment]::CurrentDirectory = $OriginalProcessDirectory
		Set-Location -LiteralPath $OriginalLocation
	}

	$Carriers = @($Observed | Where-Object {
		$null -ne $_ -and
		@($_.PSObject.Properties.Name) -ccontains 'phase'
	})
	$Carrier = if ($Carriers.Count -eq 1) { $Carriers[0] } else { $null }
	$ExpectedKeys = @(
		'phase', 'code', 'field', 'child_launched', 'attempt_consumed'
	)
	$ActualKeys = if ($null -ne $Carrier) {
		@($Carrier.PSObject.Properties.Name)
	}
	else {
		@()
	}
	$KeysExact = (
		$ActualKeys.Count -eq $ExpectedKeys.Count -and
		@($ActualKeys | Where-Object {
			$ExpectedKeys -cnotcontains $_
		}).Count -eq 0 -and
		@($ExpectedKeys | Where-Object {
			$ActualKeys -cnotcontains $_
		}).Count -eq 0
	)
	$ObservableText = @(
		@($Observed | ForEach-Object {
			$_ | ConvertTo-Json -Depth 8 -Compress
		})
		if ($null -ne $CaughtError) {
			$CaughtError.Exception.Message
		}
	) -join [Environment]::NewLine
	$ErrorTokens = [string[]]@(
		$ObservableText -csplit '[^a-z0-9_]+' |
			Where-Object { -not [string]::IsNullOrEmpty($_) }
	)
	$PrivateValues = [System.Collections.Generic.List[string]]::new()
	foreach ($Value in @(
		[string]$Case.PrivateMarker,
		$HandoffPath,
		$ManifestPath,
		$(if ($SupplyManifestSha256) { $ManifestSha256 } else { '' })
	)) {
		if (-not [string]::IsNullOrWhiteSpace($Value)) {
			[void]$PrivateValues.Add($Value)
		}
	}
	if (@($Case.PSObject.Properties.Name) -ccontains 'PrivateMarkers') {
		foreach ($Value in @($Case.PrivateMarkers)) {
			if (-not [string]::IsNullOrWhiteSpace([string]$Value)) {
				[void]$PrivateValues.Add([string]$Value)
			}
		}
	}
	$NoPrivateLeak = @($PrivateValues | Where-Object {
		$ObservableText.IndexOf(
			$_,
			[System.StringComparison]::Ordinal
		) -ge 0
	}).Count -eq 0
	$NoHashLeak = $ObservableText -cnotmatch `
		'(?<![0-9a-f])[0-9a-f]{64}(?![0-9a-f])'
	$OutOfBand = (
		$Json.IndexOf(
			$ManifestPath,
			[System.StringComparison]::Ordinal
		) -lt 0 -and
		(
			-not $SupplyManifestSha256 -or
			[string]::IsNullOrEmpty($ManifestSha256) -or
			$Json.IndexOf(
				$ManifestSha256,
				[System.StringComparison]::Ordinal
			) -lt 0
		)
	)
	$EnvironmentRestored = (
		$env:PATH -ceq $OriginalPath -and
		$ErrorActionPreference -ceq $OriginalPreference -and
		(Get-Location).Path -ceq $OriginalLocation -and
		[Environment]::CurrentDirectory -ceq $OriginalProcessDirectory
	)
	$Passed = (
		$Observed.Count -eq 1 -and
		$Carriers.Count -eq 1 -and
		$KeysExact -and
		[string]$Carrier.phase -ceq 'preflight' -and
		[string]$Carrier.code -ceq [string]$Case.Code -and
		[string]$Carrier.field -ceq [string]$Case.Field -and
		$Carrier.child_launched -is [bool] -and
		-not $Carrier.child_launched -and
		$Carrier.attempt_consumed -is [bool] -and
		-not $Carrier.attempt_consumed -and
		$null -ne $CaughtError -and
		$ErrorTokens -ccontains [string]$Case.Code -and
		$ErrorTokens -ccontains [string]$Case.Field -and
		$ObservableText -notmatch '(?i)codex' -and
		$NoPrivateLeak -and
		$NoHashLeak -and
		$OutOfBand -and
		-not (Test-Path -LiteralPath $ChildSentinelPath) -and
		(Test-NoLaunchArtifacts -ArtifactRoot $ArtifactRoot) -and
		$EnvironmentRestored
	)
	$Detail = if ($Passed) {
		''
	}
	else {
		"outputs=$($Observed.Count); carriers=$($Carriers.Count); " +
		"field=$([string]$Carrier.field); code=$([string]$Carrier.code); " +
		"expected_field=$([string]$Case.Field); " +
		"expected_code=$([string]$Case.Code); " +
		"no_private_leak=$NoPrivateLeak; no_hash_leak=$NoHashLeak; " +
		"out_of_band=$OutOfBand; " +
		"environment_restored=$EnvironmentRestored; " +
		"error=$([string]$CaughtError.Exception.Message)"
	}
	Add-Result -Name $Case.Name -Passed $Passed -Detail $Detail
}

function Invoke-ValidResolutionCase {
	param(
		[Parameter(Mandatory)][string]$Stage,
		[Parameter(Mandatory)][int]$Ordinal
	)

	$CaseRoot = Join-Path $TestRoot ('valid-' + $Ordinal)
	[void][System.IO.Directory]::CreateDirectory($CaseRoot)
	$HandoffPath = Join-Path $CaseRoot 'handoff.json'
	$ManifestPath = Join-Path $CaseRoot 'authoritative-manifest.json'
	$ArtifactRoot = Join-Path $CaseRoot 'artifacts'
	$Handoff = New-StageHandoff -Stage $Stage -RunId "valid-$Stage"
	$Manifest = New-AuthoritativeEvidenceManifest `
		-Stage $Stage -Handoff $Handoff
	$HandoffJson = $Handoff | ConvertTo-Json -Depth 20 -Compress
	[System.IO.File]::WriteAllBytes($ManifestPath, $Manifest.Bytes)
	[System.IO.File]::WriteAllText($HandoffPath, $HandoffJson, $Utf8NoBom)

	$Observed = [System.Collections.Generic.List[object]]::new()
	$CaughtError = $null
	$OriginalPath = $env:PATH
	$OriginalPreference = $ErrorActionPreference
	$OriginalLocation = (Get-Location).Path
	$OriginalProcessDirectory = [Environment]::CurrentDirectory
	try {
		$env:PATH = $MissingCodexBin
		& $LauncherPath `
			-HandoffPath $HandoffPath `
			-AuthoritativeEvidenceManifestPath $ManifestPath `
			-AuthoritativeEvidenceManifestSha256 $Manifest.Sha256 `
			-ArtifactRoot $ArtifactRoot `
			-OutputPath (Join-Path $ArtifactRoot 'output.json') `
			-AuditPath (Join-Path $ArtifactRoot 'audit.json') `
			-TelemetryPath (Join-Path $ArtifactRoot 'telemetry.json') |
			ForEach-Object { [void]$Observed.Add($_) }
	}
	catch {
		$CaughtError = $_
	}
	finally {
		$env:PATH = $OriginalPath
		$ErrorActionPreference = $OriginalPreference
		[Environment]::CurrentDirectory = $OriginalProcessDirectory
		Set-Location -LiteralPath $OriginalLocation
	}

	$EnvironmentRestored = (
		$env:PATH -ceq $OriginalPath -and
		$ErrorActionPreference -ceq $OriginalPreference -and
		(Get-Location).Path -ceq $OriginalLocation -and
		[Environment]::CurrentDirectory -ceq $OriginalProcessDirectory
	)
	$OutOfBand = (
		$HandoffJson.IndexOf(
			$ManifestPath,
			[System.StringComparison]::Ordinal
		) -lt 0 -and
		$HandoffJson.IndexOf(
			$Manifest.Sha256,
			[System.StringComparison]::Ordinal
		) -lt 0
	)
	$Passed = (
		$Observed.Count -eq 0 -and
		$null -ne $CaughtError -and
		$CaughtError.Exception.Message -match '(?i)codex' -and
		$CaughtError.Exception.Message -match `
			'(?i)not recognized|not found|could not be found' -and
		$OutOfBand -and
		-not (Test-Path -LiteralPath $ChildSentinelPath) -and
		(Test-NoLaunchArtifacts -ArtifactRoot $ArtifactRoot) -and
		$EnvironmentRestored
	)
	Add-Result `
		-Name "$Stage valid frozen out-of-band manifest reaches codex resolution" `
		-Passed $Passed `
		-Detail $(if ($Passed) { '' } else {
			[string]$CaughtError.Exception.Message
		})
}

try {
	[void][System.IO.Directory]::CreateDirectory($MissingCodexBin)
	foreach ($Stage in @('verifier', 'approver')) {
		$SingularField = if ($Stage -eq 'verifier') {
			'candidate_artifact'
		}
		else {
			'final_artifact'
		}
		$Base = New-StageHandoff -Stage $Stage -RunId "$Stage-preflight"
		$FrozenManifests[$Stage] = New-AuthoritativeEvidenceManifest `
			-Stage $Stage -Handoff $Base

		foreach ($PresenceCase in @(
			@{
				Name = 'omitted singular routed evidence'
				Field = $SingularField
				Apply = { param($H) $H.PSObject.Properties.Remove($SingularField) }
			},
			@{
				Name = 'null singular routed evidence'
				Field = $SingularField
				Apply = { param($H) $H.$SingularField = $null }
			},
			@{
				Name = 'omitted routed evidence array'
				Field = 'raw_check_output'
				Apply = { param($H) $H.PSObject.Properties.Remove('raw_check_output') }
			},
			@{
				Name = 'empty routed evidence array'
				Field = 'raw_check_output'
				Apply = { param($H) $H.raw_check_output = @() }
			},
			@{
				Name = 'null routed evidence array'
				Field = 'raw_check_output'
				Apply = { param($H) $H.raw_check_output = $null }
			}
		)) {
			$Marker = "private-$Stage-$($PresenceCase.Name.Replace(' ', '-'))"
			$Handoff = Copy-JsonObject -Value $Base
			$Handoff.ticket = $Marker
			& $PresenceCase.Apply $Handoff
			Add-ObjectCase -Name "$Stage $($PresenceCase.Name)" `
				-Stage $Stage -Field $PresenceCase.Field `
				-Code 'required_evidence_routed_record_malformed' `
				-Handoff $Handoff -PrivateMarker $Marker
		}

		foreach ($Field in @($SingularField, 'raw_check_output')) {
			$Family = if ($Field -eq 'raw_check_output') {
				'array record'
			}
			else {
				'singular record'
			}
			$Mutations = @(
				@{
					Name = 'missing record key'
					Code = 'neutral_evidence_keys_invalid'
					Apply = {
						param($Record, $PrivateMarker)
						$Record.PSObject.Properties.Remove('encoding')
					}
				},
				@{
					Name = 'extra record key'
					Code = 'neutral_evidence_keys_invalid'
					Apply = {
						param($Record, $PrivateMarker)
						$Record | Add-Member -NotePropertyName private_payload `
							-NotePropertyValue $PrivateMarker
					}
				},
				@{
					Name = 'invalid kind'
					Code = 'neutral_evidence_kind_invalid'
					Apply = { param($Record, $PrivateMarker) $Record.kind = $PrivateMarker }
				},
				@{
					Name = 'invalid provenance'
					Code = 'neutral_evidence_provenance_invalid'
					Apply = { param($Record, $PrivateMarker) $Record.provenance = $PrivateMarker }
				},
				@{
					Name = 'invalid encoding'
					Code = 'neutral_evidence_encoding_invalid'
					Apply = { param($Record, $PrivateMarker) $Record.encoding = $PrivateMarker }
				},
				@{
					Name = 'invalid source'
					Code = 'neutral_evidence_source_invalid'
					Apply = { param($Record, $PrivateMarker) $Record.source = '   ' }
				},
				@{
					Name = 'invalid SHA syntax'
					Code = 'neutral_evidence_sha256_invalid'
					Apply = { param($Record, $PrivateMarker) $Record.sha256 = $PrivateMarker }
				},
				@{
					Name = 'invalid content type'
					Code = 'neutral_evidence_content_invalid'
					Apply = { param($Record, $PrivateMarker) $Record.content = 42 }
				},
				@{
					Name = 'invalid base64'
					Code = 'neutral_evidence_base64_invalid'
					Apply = {
						param($Record, $PrivateMarker)
						$Record.encoding = 'base64'
						$Record.content = $PrivateMarker + '%%%'
					}
				},
				@{
					Name = 'content hash mismatch'
					Code = 'neutral_evidence_hash_mismatch'
					Apply = { param($Record, $PrivateMarker) $Record.content = $PrivateMarker }
				}
			)

			foreach ($Mutation in $Mutations) {
				$Marker = "private-$Stage-$($Field.Replace('_', '-'))-" +
					$Mutation.Name.Replace(' ', '-')
				$Handoff = Copy-JsonObject -Value $Base
				$Handoff.ticket = $Marker
				$Record = Get-RoutedRecord -Handoff $Handoff -Field $Field
				& $Mutation.Apply $Record $Marker
				Add-ObjectCase -Name "$Stage $Family $($Mutation.Name)" `
					-Stage $Stage -Field $Field -Code $Mutation.Code `
					-Handoff $Handoff -PrivateMarker $Marker
			}
		}

		$DeclarationCases = @(
			@{
				Name = 'missing declaration key'
				Code = 'required_evidence_declarations_malformed'
				Field = 'required_evidence_sources'
				Apply = { param($D, $M) $D.PSObject.Properties.Remove('sha256') }
			},
			@{
				Name = 'extra declaration key'
				Code = 'required_evidence_declarations_malformed'
				Field = 'required_evidence_sources'
				Apply = {
					param($D, $M)
					$D | Add-Member -NotePropertyName private_payload `
						-NotePropertyValue $M
				}
			},
			@{
				Name = 'invalid declaration field'
				Code = 'required_evidence_declarations_malformed'
				Field = 'required_evidence_sources'
				Apply = { param($D, $M) $D.field = $M }
			},
			@{
				Name = 'invalid declaration kind'
				Code = 'required_evidence_declarations_malformed'
				Field = 'required_evidence_sources'
				Apply = { param($D, $M) $D.kind = $M }
			},
			@{
				Name = 'invalid declaration provenance'
				Code = 'required_evidence_declarations_malformed'
				Field = 'required_evidence_sources'
				Apply = { param($D, $M) $D.provenance = $M }
			},
			@{
				Name = 'invalid declaration encoding'
				Code = 'required_evidence_declarations_malformed'
				Field = 'required_evidence_sources'
				Apply = { param($D, $M) $D.encoding = $M }
			},
			@{
				Name = 'invalid declaration source'
				Code = 'required_evidence_declarations_malformed'
				Field = 'required_evidence_sources'
				Apply = { param($D, $M) $D.source = '   ' }
			},
			@{
				Name = 'invalid declaration SHA syntax'
				Code = 'required_evidence_declarations_malformed'
				Field = 'required_evidence_sources'
				Apply = { param($D, $M) $D.sha256 = $M }
			},
			@{
				Name = 'declaration hash mismatch'
				Code = 'required_evidence_composition_mismatch'
				Field = $SingularField
				Apply = { param($D, $M) $D.sha256 = '0' * 64 }
			}
		)
		foreach ($DeclarationCase in $DeclarationCases) {
			$Marker = "private-$Stage-" +
				$DeclarationCase.Name.Replace(' ', '-')
			$Handoff = Copy-JsonObject -Value $Base
			$Handoff.ticket = $Marker
			$Declaration = @($Handoff.required_evidence_sources | Where-Object {
				$_.field -ceq $SingularField
			})[0]
			& $DeclarationCase.Apply $Declaration $Marker
			Add-ObjectCase -Name "$Stage $($DeclarationCase.Name)" `
				-Stage $Stage -Field $DeclarationCase.Field `
				-Code $DeclarationCase.Code -Handoff $Handoff `
				-PrivateMarker $Marker
		}

		foreach ($DeclarationPresence in @(
			@{
				Name = 'missing evidence declarations'
				Apply = { param($H) $H.PSObject.Properties.Remove('required_evidence_sources') }
			},
			@{
				Name = 'empty evidence declarations'
				Apply = { param($H) $H.required_evidence_sources = @() }
			},
			@{
				Name = 'null evidence declarations'
				Apply = { param($H) $H.required_evidence_sources = $null }
			},
			@{
				Name = 'non-object evidence declaration'
				Apply = { param($H) $H.required_evidence_sources[0] = 'private-non-object' }
			}
		)) {
			$Marker = "private-$Stage-" +
				$DeclarationPresence.Name.Replace(' ', '-')
			$Handoff = Copy-JsonObject -Value $Base
			$Handoff.ticket = $Marker
			& $DeclarationPresence.Apply $Handoff
			Add-ObjectCase -Name "$Stage $($DeclarationPresence.Name)" `
				-Stage $Stage -Field 'required_evidence_sources' `
				-Code 'required_evidence_declarations_malformed' `
				-Handoff $Handoff -PrivateMarker $Marker
		}

		$Marker = "private-$Stage-duplicate-declaration"
		$Handoff = Copy-JsonObject -Value $Base
		$Handoff.ticket = $Marker
		$Handoff.required_evidence_sources = @(
			$Handoff.required_evidence_sources
		) + @((Copy-JsonObject -Value $Handoff.required_evidence_sources[0]))
		Add-ObjectCase -Name "$Stage duplicate evidence declaration" `
			-Stage $Stage -Field 'required_evidence_sources' `
			-Code 'required_evidence_declaration_duplicate' `
			-Handoff $Handoff -PrivateMarker $Marker

		$Marker = "private-$Stage-consistent-handoff-substitution"
		$Handoff = Copy-JsonObject -Value $Base
		$Handoff.ticket = $Marker
		$RoutedLinux = @($Handoff.raw_check_output | Where-Object {
			$_.source -ceq 'linux-server-build-log'
		})[0]
		$DeclaredLinux = @($Handoff.required_evidence_sources | Where-Object {
			$_.source -ceq 'linux-server-build-log'
		})[0]
		$RoutedLinux.source = $Marker
		$DeclaredLinux.source = $Marker
		Add-ObjectCase -Name "$Stage mutually consistent handoff substitution" `
			-Stage $Stage -Field 'raw_check_output' `
			-Code 'required_evidence_composition_mismatch' `
			-Handoff $Handoff -PrivateMarker $Marker

		$Marker = "private-$Stage-linux-omission"
		$Handoff = Copy-JsonObject -Value $Base
		$Handoff.ticket = $Marker
		$Handoff.raw_check_output = @($Handoff.raw_check_output | Where-Object {
			$_.source -cne 'linux-server-build-log'
		})
		$Handoff.required_evidence_sources = @(
			$Handoff.required_evidence_sources | Where-Object {
				$_.source -cne 'linux-server-build-log'
			}
		)
		Add-ObjectCase -Name "$Stage authoritative Linux evidence omission" `
			-Stage $Stage -Field 'raw_check_output' `
			-Code 'required_evidence_composition_mismatch' `
			-Handoff $Handoff -PrivateMarker $Marker

		$Marker = "private-$Stage-duplicate-routed-record"
		$Handoff = Copy-JsonObject -Value $Base
		$Handoff.ticket = $Marker
		$LinuxRecord = @($Handoff.raw_check_output | Where-Object {
			$_.source -ceq 'linux-server-build-log'
		})[0]
		$Handoff.raw_check_output = @($Handoff.raw_check_output) +
			@((Copy-JsonObject -Value $LinuxRecord))
		Add-ObjectCase -Name "$Stage duplicate authoritative routed record" `
			-Stage $Stage -Field 'raw_check_output' `
			-Code 'required_evidence_routed_record_duplicate' `
			-Handoff $Handoff -PrivateMarker $Marker

		$BaseJson = $Base | ConvertTo-Json -Depth 20 -Compress
		foreach ($DuplicateRoot in @(
			@{ Name = 'stage'; Field = 'stage'; Value = 'private-duplicate-stage' },
			@{
				Name = 'required_evidence_sources'
				Field = 'required_evidence_sources'
				Value = @()
			},
			@{
				Name = 'raw_check_output'
				Field = 'raw_check_output'
				Value = @()
			}
		)) {
			$Marker = "private-$Stage-duplicate-$($DuplicateRoot.Name)"
			$DuplicateValue = if ($DuplicateRoot.Name -eq 'stage') {
				'"' + $Marker + '"'
			}
			else {
				'[]'
			}
			$Json = $BaseJson.Substring(0, $BaseJson.Length - 1) +
				',"' + $DuplicateRoot.Name + '":' + $DuplicateValue + '}'
			Add-JsonCase -Name "$Stage duplicate $($DuplicateRoot.Name) JSON member" `
				-Stage $Stage -Field $DuplicateRoot.Field `
				-Code 'required_evidence_json_member_duplicate' `
				-Json $Json -PrivateMarker $Marker
		}

		$Marker = "private-$Stage-duplicate-declaration-member"
		$DeclarationStart = $BaseJson.IndexOf(
			'"required_evidence_sources":',
			[System.StringComparison]::Ordinal
		)
		$FieldFragment = '"field":"' + $SingularField + '"'
		$Json = Add-DuplicateJsonMemberAtFirstMatch `
			-Json $BaseJson -Fragment $FieldFragment `
			-Replacement ($FieldFragment + ',"field":"' + $Marker + '"') `
			-StartIndex $DeclarationStart
		Add-JsonCase -Name "$Stage duplicate declaration JSON member" `
			-Stage $Stage -Field 'required_evidence_sources' `
			-Code 'required_evidence_json_member_duplicate' `
			-Json $Json -PrivateMarker $Marker

		$Marker = "private-$Stage-duplicate-routed-member"
		$SourceFragment = '"source":"linux-server-build-log"'
		$Json = Add-DuplicateJsonMemberAtFirstMatch `
			-Json $BaseJson -Fragment $SourceFragment `
			-Replacement ($SourceFragment + ',"source":"' + $Marker + '"')
		Add-JsonCase -Name "$Stage duplicate routed record JSON member" `
			-Stage $Stage -Field 'raw_check_output' `
			-Code 'required_evidence_json_member_duplicate' `
			-Json $Json -PrivateMarker $Marker
	}

	$ManifestHandoff = New-StageHandoff -Stage 'verifier' `
		-RunId 'manifest-preflight'
	$ValidManifest = New-AuthoritativeEvidenceManifest `
		-Stage 'verifier' -Handoff $ManifestHandoff

	Add-ManifestCase -Name 'Missing manifest path and hash' -Stage 'verifier' `
		-Field 'authoritative_evidence_manifest' `
		-Code 'authoritative_evidence_manifest_required' `
		-Handoff $ManifestHandoff -ManifestBytes $ValidManifest.Bytes `
		-ManifestSha256 $ValidManifest.Sha256 `
		-SupplyManifestPath $false -SupplyManifestSha256 $false `
		-WriteManifest $false
	Add-ManifestCase -Name 'Manifest hash without path' -Stage 'verifier' `
		-Field 'authoritative_evidence_manifest' `
		-Code 'authoritative_evidence_manifest_required' `
		-Handoff $ManifestHandoff -ManifestBytes $ValidManifest.Bytes `
		-ManifestSha256 $ValidManifest.Sha256 `
		-SupplyManifestPath $false -WriteManifest $false
	Add-ManifestCase -Name 'Manifest path without hash' -Stage 'verifier' `
		-Field 'authoritative_evidence_manifest' `
		-Code 'authoritative_evidence_manifest_required' `
		-Handoff $ManifestHandoff -ManifestBytes $ValidManifest.Bytes `
		-ManifestSha256 $ValidManifest.Sha256 `
		-SupplyManifestSha256 $false
	Add-ManifestCase -Name 'Unreadable authoritative manifest' `
		-Stage 'verifier' -Field 'authoritative_evidence_manifest' `
		-Code 'authoritative_evidence_manifest_required' `
		-Handoff $ManifestHandoff -ManifestBytes $ValidManifest.Bytes `
		-ManifestSha256 $ValidManifest.Sha256 -WriteManifest $false
	Add-ManifestCase -Name 'Empty authoritative manifest' -Stage 'verifier' `
		-Field 'authoritative_evidence_manifest' `
		-Code 'authoritative_evidence_manifest_required' `
		-Handoff $ManifestHandoff -ManifestBytes ([byte[]]@()) `
		-ManifestSha256 (Get-TestSha256 -Bytes ([byte[]]@()))
	Add-ManifestCase -Name 'Empty expected manifest hash' -Stage 'verifier' `
		-Field 'authoritative_evidence_manifest' `
		-Code 'authoritative_evidence_manifest_required' `
		-Handoff $ManifestHandoff -ManifestBytes $ValidManifest.Bytes `
		-ManifestSha256 ''

	$InvalidHash = 'private-invalid-manifest-hash'
	Add-ManifestCase -Name 'Invalid expected manifest hash syntax' `
		-Stage 'verifier' -Field 'authoritative_evidence_manifest' `
		-Code 'authoritative_evidence_manifest_malformed' `
		-Handoff $ManifestHandoff -ManifestBytes $ValidManifest.Bytes `
		-ManifestSha256 $InvalidHash -PrivateMarkers @($InvalidHash)
	Add-ManifestCase -Name 'Exact manifest hash mismatch' -Stage 'verifier' `
		-Field 'authoritative_evidence_manifest' `
		-Code 'authoritative_evidence_manifest_hash_mismatch' `
		-Handoff $ManifestHandoff -ManifestBytes $ValidManifest.Bytes `
		-ManifestSha256 ('0' * 64)

	$MalformedManifest = New-TestJsonBytes -Json '{'
	Add-ManifestCase -Name 'Malformed authoritative manifest JSON' `
		-Stage 'verifier' -Field 'authoritative_evidence_manifest' `
		-Code 'authoritative_evidence_manifest_malformed' `
		-Handoff $ManifestHandoff -ManifestBytes $MalformedManifest.Bytes `
		-ManifestSha256 $MalformedManifest.Sha256

	$WrongStageObject = Copy-JsonObject -Value $ValidManifest.Manifest
	$WrongStageObject.stage = 'approver'
	$WrongStageManifest = New-TestJsonBytes -Json (
		$WrongStageObject | ConvertTo-Json -Depth 10 -Compress
	)
	Add-ManifestCase -Name 'Wrong-stage authoritative manifest' `
		-Stage 'verifier' -Field 'authoritative_evidence_manifest' `
		-Code 'authoritative_evidence_manifest_malformed' `
		-Handoff $ManifestHandoff -ManifestBytes $WrongStageManifest.Bytes `
		-ManifestSha256 $WrongStageManifest.Sha256

	$EmptyRecordsObject = Copy-JsonObject -Value $ValidManifest.Manifest
	$EmptyRecordsObject.records = @()
	$EmptyRecordsManifest = New-TestJsonBytes -Json (
		$EmptyRecordsObject | ConvertTo-Json -Depth 10 -Compress
	)
	Add-ManifestCase -Name 'Empty authoritative manifest record array' `
		-Stage 'verifier' -Field 'authoritative_evidence_manifest' `
		-Code 'authoritative_evidence_manifest_malformed' `
		-Handoff $ManifestHandoff -ManifestBytes $EmptyRecordsManifest.Bytes `
		-ManifestSha256 $EmptyRecordsManifest.Sha256

	$EmptyRecordObject = Copy-JsonObject -Value $ValidManifest.Manifest
	$EmptyRecordObject.records = @([pscustomobject]@{})
	$EmptyRecordManifest = New-TestJsonBytes -Json (
		$EmptyRecordObject | ConvertTo-Json -Depth 10 -Compress
	)
	Add-ManifestCase -Name 'Empty authoritative manifest record' `
		-Stage 'verifier' -Field 'authoritative_evidence_manifest' `
		-Code 'authoritative_evidence_manifest_malformed' `
		-Handoff $ManifestHandoff -ManifestBytes $EmptyRecordManifest.Bytes `
		-ManifestSha256 $EmptyRecordManifest.Sha256

	$PartialRecordObject = Copy-JsonObject -Value $ValidManifest.Manifest
	$PartialRecordObject.records[0].PSObject.Properties.Remove('sha256')
	$PartialRecordManifest = New-TestJsonBytes -Json (
		$PartialRecordObject | ConvertTo-Json -Depth 10 -Compress
	)
	Add-ManifestCase -Name 'Partial authoritative manifest record' `
		-Stage 'verifier' -Field 'authoritative_evidence_manifest' `
		-Code 'authoritative_evidence_manifest_malformed' `
		-Handoff $ManifestHandoff -ManifestBytes $PartialRecordManifest.Bytes `
		-ManifestSha256 $PartialRecordManifest.Sha256

	$DuplicateIdentityObject = Copy-JsonObject -Value $ValidManifest.Manifest
	$DuplicateIdentityObject.records = @($DuplicateIdentityObject.records) +
		@((Copy-JsonObject -Value $DuplicateIdentityObject.records[0]))
	$DuplicateIdentityManifest = New-TestJsonBytes -Json (
		$DuplicateIdentityObject | ConvertTo-Json -Depth 10 -Compress
	)
	Add-ManifestCase -Name 'Duplicate authoritative manifest identity' `
		-Stage 'verifier' -Field 'candidate_artifact' `
		-Code 'authoritative_evidence_source_duplicate' `
		-Handoff $ManifestHandoff -ManifestBytes $DuplicateIdentityManifest.Bytes `
		-ManifestSha256 $DuplicateIdentityManifest.Sha256

	$DuplicateRootMarker = 'private-duplicate-manifest-stage'
	$DuplicateRootJson = $ValidManifest.Json.Substring(
		0,
		$ValidManifest.Json.Length - 1
	) + ',"stage":"' + $DuplicateRootMarker + '"}'
	$DuplicateRootManifest = New-TestJsonBytes -Json $DuplicateRootJson
	Add-ManifestCase -Name 'Duplicate authoritative manifest root member' `
		-Stage 'verifier' -Field 'authoritative_evidence_manifest' `
		-Code 'required_evidence_json_member_duplicate' `
		-Handoff $ManifestHandoff -ManifestBytes $DuplicateRootManifest.Bytes `
		-ManifestSha256 $DuplicateRootManifest.Sha256 `
		-PrivateMarkers @($DuplicateRootMarker)

	$DuplicateRecordMarker = 'private-duplicate-manifest-source'
	$ManifestSourceFragment = '"source":"' +
		[string]$ValidManifest.Manifest.records[0].source + '"'
	$DuplicateRecordJson = Add-DuplicateJsonMemberAtFirstMatch `
		-Json $ValidManifest.Json -Fragment $ManifestSourceFragment `
		-Replacement ($ManifestSourceFragment + ',"source":"' +
			$DuplicateRecordMarker + '"')
	$DuplicateRecordManifest = New-TestJsonBytes -Json $DuplicateRecordJson
	Add-ManifestCase -Name 'Duplicate authoritative manifest record member' `
		-Stage 'verifier' -Field 'authoritative_evidence_manifest' `
		-Code 'required_evidence_json_member_duplicate' `
		-Handoff $ManifestHandoff -ManifestBytes $DuplicateRecordManifest.Bytes `
		-ManifestSha256 $DuplicateRecordManifest.Sha256 `
		-PrivateMarkers @($DuplicateRecordMarker)

	foreach ($Stage in @('verifier', 'approver')) {
		$Handoff = New-StageHandoff -Stage $Stage `
			-RunId "$Stage-wrong-linux-provenance"
		$RoutedLinux = @($Handoff.raw_check_output | Where-Object {
			$_.source -ceq 'linux-server-build-log'
		})[0]
		$DeclaredLinux = @($Handoff.required_evidence_sources | Where-Object {
			$_.source -ceq 'linux-server-build-log'
		})[0]
		$RoutedLinux.provenance = 'repository'
		$DeclaredLinux.provenance = 'repository'
		$Manifest = New-AuthoritativeEvidenceManifest `
			-Stage $Stage -Handoff $Handoff
		Add-ManifestCase `
			-Name "$Stage repository-provenance Linux authority" `
			-Stage $Stage -Field 'authoritative_evidence_manifest' `
			-Code 'authoritative_evidence_manifest_malformed' `
			-Handoff $Handoff -ManifestBytes $Manifest.Bytes `
			-ManifestSha256 $Manifest.Sha256
	}

	$Ordinal = 0
	foreach ($Case in $Cases) {
		$Ordinal++
		Invoke-InvalidPreflightCase -Case $Case -Ordinal $Ordinal
	}
	Invoke-ValidResolutionCase -Stage 'verifier' -Ordinal 1
	Invoke-ValidResolutionCase -Stage 'approver' -Ordinal 2
}
finally {
	if (Test-Path -LiteralPath $TestRoot) {
		Remove-Item -LiteralPath $TestRoot -Recurse -Force
	}
}

$Failures = @($Results | Where-Object { -not $_.Passed })
$Results | Format-Table -AutoSize
if ($Failures.Count -gt 0) {
	throw "Delivery stage preflight tests failed: $($Failures.Name -join '; ')"
}

Write-Output "Delivery stage preflight tests passed ($($Results.Count) cases)."
