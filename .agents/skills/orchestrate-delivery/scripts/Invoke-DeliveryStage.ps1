[CmdletBinding()]
param(
	[Parameter(Mandatory)]
	[string]$HandoffPath,

	[string]$OutputPath,

	[string]$AuditPath,

	[string]$TelemetryPath,

	[string]$ArtifactRoot,

	[AllowNull()]
	[AllowEmptyString()]
	[string]$AuthoritativeEvidenceManifestPath,

	[AllowNull()]
	[AllowEmptyString()]
	[string]$AuthoritativeEvidenceManifestSha256,

	[switch]$DryRun,

	[switch]$PassThru
)

$ErrorActionPreference = 'Stop'

$SkillRoot = Split-Path -Parent $PSScriptRoot
$RepositoryRoot = (Resolve-Path (Join-Path $SkillRoot '..\..\..')).Path
$ValidateScript = Join-Path $PSScriptRoot 'Validate-DeliveryHandoff.ps1'
$HandoffSchemaPath = Join-Path $SkillRoot 'references\handoff-schemas.json'
$OutputSchemaPath = Join-Path $SkillRoot 'references\stage-output-schema.json'
$ProducerOutputSchemaPath = Join-Path (
	$SkillRoot
) 'references\stage-output-producer-schema.json'
$SnapshotScript = Join-Path $PSScriptRoot 'Get-DeliveryRepositorySnapshot.ps1'
$PatchValidationScript = Join-Path $PSScriptRoot 'Validate-DeliveryPatch.ps1'
$BundleConversionScript = Join-Path (
	$PSScriptRoot
) 'Convert-DeliveryFileBundleToPatch.ps1'
$EvidenceProtectionScript = Join-Path $PSScriptRoot 'Protect-DeliveryEvidence.ps1'
$EventTelemetryScript = Join-Path $PSScriptRoot 'Get-DeliveryEventTelemetry.ps1'
$EvidenceValidationScript = Join-Path $PSScriptRoot 'Test-DeliveryEvidence.ps1'
$NeutralEvidenceFieldAllowlist = @(
	'artifact_change_summary',
	'artifact_state',
	'authoritative_evidence_manifest',
	'baseline_diff',
	'baseline_status',
	'board_export',
	'candidate_artifact',
	'candidate_artifacts',
	'conflict_locations',
	'final_artifact',
	'final_diff',
	'raw_check_output',
	'raw_evidence',
	'raw_runtime_evidence',
	'required_evidence_sources',
	'repository_state',
	'repository_tree',
	'stage'
)
$NeutralEvidenceValidationCodeAllowlist = @(
	'neutral_evidence_record_required',
	'neutral_evidence_array_required',
	'neutral_evidence_keys_invalid',
	'neutral_evidence_kind_invalid',
	'neutral_evidence_provenance_invalid',
	'neutral_evidence_encoding_invalid',
	'neutral_evidence_source_invalid',
	'neutral_evidence_sha256_invalid',
	'neutral_evidence_content_invalid',
	'neutral_evidence_base64_invalid',
	'neutral_evidence_hash_mismatch',
	'neutral_evidence_field_contract_invalid',
	'authoritative_evidence_manifest_required',
	'authoritative_evidence_manifest_hash_mismatch',
	'authoritative_evidence_manifest_malformed',
	'authoritative_evidence_source_duplicate',
	'required_evidence_json_member_duplicate',
	'required_evidence_declarations_malformed',
	'required_evidence_routed_record_malformed',
	'required_evidence_routed_record_duplicate',
	'required_evidence_composition_mismatch',
	'required_evidence_sources_array_required',
	'required_evidence_declaration_required',
	'required_evidence_declaration_keys_invalid',
	'required_evidence_declaration_field_invalid',
	'required_evidence_declaration_kind_invalid',
	'required_evidence_declaration_provenance_invalid',
	'required_evidence_declaration_encoding_invalid',
	'required_evidence_declaration_source_invalid',
	'required_evidence_declaration_sha256_invalid',
	'required_evidence_declaration_duplicate',
	'required_evidence_authoritative_cardinality_invalid',
	'required_evidence_record_cardinality_invalid',
	'required_evidence_record_mismatch',
	'required_evidence_record_undeclared'
)

$AuthoritativeEvidenceManifestBytes = $null
try {
	$ManifestPathSupplied = -not [string]::IsNullOrWhiteSpace(
		$AuthoritativeEvidenceManifestPath
	)
	$ManifestSha256Supplied = -not [string]::IsNullOrWhiteSpace(
		$AuthoritativeEvidenceManifestSha256
	)
	if ($ManifestPathSupplied -or $ManifestSha256Supplied) {
		if (-not $ManifestPathSupplied -or -not $ManifestSha256Supplied) {
			throw (
				"Required evidence field 'authoritative_evidence_manifest' " +
				'failed validation: authoritative_evidence_manifest_required.'
			)
		}
		if ($AuthoritativeEvidenceManifestSha256 -cnotmatch '^[0-9a-f]{64}$') {
			throw (
				"Required evidence field 'authoritative_evidence_manifest' " +
				'failed validation: authoritative_evidence_manifest_malformed.'
			)
		}

		try {
			$AuthoritativeEvidenceManifestBytes = [System.IO.File]::ReadAllBytes(
				$AuthoritativeEvidenceManifestPath
			)
		}
		catch {
			throw (
				"Required evidence field 'authoritative_evidence_manifest' " +
				'failed validation: authoritative_evidence_manifest_required.'
			)
		}
		if ($AuthoritativeEvidenceManifestBytes.Count -eq 0) {
			throw (
				"Required evidence field 'authoritative_evidence_manifest' " +
				'failed validation: authoritative_evidence_manifest_required.'
			)
		}

		$ManifestHasher = [System.Security.Cryptography.SHA256]::Create()
		try {
			$ActualAuthoritativeEvidenceManifestSha256 = (
				[System.BitConverter]::ToString(
					$ManifestHasher.ComputeHash(
						$AuthoritativeEvidenceManifestBytes
					)
				).Replace('-', '').ToLowerInvariant()
			)
		}
		finally {
			$ManifestHasher.Dispose()
		}
		if ($ActualAuthoritativeEvidenceManifestSha256 -cne
			$AuthoritativeEvidenceManifestSha256) {
			throw (
				"Required evidence field 'authoritative_evidence_manifest' " +
				'failed validation: authoritative_evidence_manifest_hash_mismatch.'
			)
		}
	}

	$Validation = & $ValidateScript `
		-HandoffPath $HandoffPath `
		-SchemaPath $HandoffSchemaPath `
		-AuthoritativeEvidenceManifestBytes $AuthoritativeEvidenceManifestBytes `
		-ExpectedAuthoritativeEvidenceManifestSha256 (
			$AuthoritativeEvidenceManifestSha256
		)
}
catch {
	$ValidationMessage = [string]$_.Exception.Message
	$ValidationTokens = [string[]]@(
		$ValidationMessage -csplit '[^a-z0-9_]+' |
			Where-Object { -not [string]::IsNullOrEmpty($_) }
	)
	$MatchedFields = @(
		$NeutralEvidenceFieldAllowlist | Where-Object {
			$ValidationTokens -ccontains $_
		}
	)
	$MatchedCodes = @(
		$NeutralEvidenceValidationCodeAllowlist | Where-Object {
			$ValidationTokens -ccontains $_
		}
	)

	if ($MatchedFields.Count -eq 1 -and $MatchedCodes.Count -eq 1) {
		Write-Output -NoEnumerate ([pscustomobject][ordered]@{
			phase = 'preflight'
			code = $MatchedCodes[0]
			field = $MatchedFields[0]
			child_launched = $false
			attempt_consumed = $false
		})
	}

	throw
}
$CodexCommand = (Get-Command codex -ErrorAction Stop).Source
$Stage = $Validation.Stage
$WorkspaceRoot = $Validation.WorkspaceRoot
$Handoff = $Validation.Handoff
$ArtifactProducerStages = @('worker', 'integrator', 'fixer')
$IsArtifactProducer = $ArtifactProducerStages -contains $Stage
$SelectedOutputSchemaPath = if ($IsArtifactProducer) {
	$ProducerOutputSchemaPath
}
else {
	$OutputSchemaPath
}
$SandboxMode = 'read-only'
$ExternalIngestRequired = $false
$ExternalEvidence = $null

if (-not ([System.IO.Path]::GetFullPath($WorkspaceRoot).TrimEnd('\', '/')).Equals(
		[System.IO.Path]::GetFullPath($RepositoryRoot).TrimEnd('\', '/'),
		[System.StringComparison]::OrdinalIgnoreCase
	)) {
	throw (
		"Stage workspace_root must equal the configured repository " +
		"'$RepositoryRoot'."
	)
}

if ($Stage -ceq 'worker' -and
	@($Handoff.PSObject.Properties.Name) -ccontains 'consumes_external_files') {
	$ExternalIngestRequired = $true
	$ExternalIngestLibrary = Join-Path `
		$PSScriptRoot 'DeliveryExternalFileIngest.Common.ps1'
	if (-not (Test-Path -LiteralPath $ExternalIngestLibrary -PathType Leaf)) {
		throw 'External-ingest validation library is missing.'
	}
	. $ExternalIngestLibrary
	$ExternalEvidence = $Handoff.external_ingest_evidence
	$null = Test-DeliveryAcceptedIngestEvidence `
		-EvidenceManifestPath ([string]$ExternalEvidence.evidence_manifest_path) `
		-ExpectedEvidenceManifestSha256 ([string]$ExternalEvidence.evidence_manifest_sha256) `
		-ExternalManifestPath ([string]$ExternalEvidence.external_manifest_path) `
		-ExpectedExternalManifestSha256 ([string]$ExternalEvidence.external_manifest_sha256) `
		-PreparedJournalPath ([string]$ExternalEvidence.prepared_journal_path) `
		-ExpectedPreparedJournalSha256 ([string]$ExternalEvidence.prepared_journal_sha256) `
		-ExpectedSourceCommit ([string]$ExternalEvidence.source_commit) `
		-RepositoryRoot $WorkspaceRoot
}

function Test-PathWithin {
	param(
		[Parameter(Mandatory)]
		[string]$Path,

		[Parameter(Mandatory)]
		[string]$Root
	)

	$NormalizedPath = [System.IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
	$NormalizedRoot = [System.IO.Path]::GetFullPath($Root).TrimEnd('\', '/')

	return $NormalizedPath.Equals(
		$NormalizedRoot,
		[System.StringComparison]::OrdinalIgnoreCase
	) -or $NormalizedPath.StartsWith(
		$NormalizedRoot + [System.IO.Path]::DirectorySeparatorChar,
		[System.StringComparison]::OrdinalIgnoreCase
	)
}

function Test-DeliveryRelativePathAllowed {
	param(
		[Parameter(Mandatory)]
		[string]$RelativePath,

		[Parameter(Mandatory)]
		[string[]]$AllowedPaths
	)

	$Normalized = $RelativePath.Replace('\', '/')
	$PathSegments = @($Normalized -split '/')
	foreach ($AllowedPath in $AllowedPaths) {
		$Allowed = $AllowedPath.Replace('\', '/').TrimEnd('/')
		$ScopeSegments = @($Allowed -split '/')
		$HasWildcard = @(
			$ScopeSegments | Where-Object { $_ -in @('*', '**') }
		).Count -gt 0
		if (-not $HasWildcard) {
			if ($Normalized.Equals(
					$Allowed,
					[System.StringComparison]::OrdinalIgnoreCase
				) -or $Normalized.StartsWith(
					$Allowed + '/',
					[System.StringComparison]::OrdinalIgnoreCase
				)) {
				return $true
			}
			continue
		}

		$Memo = @{}
		function Test-SegmentMatch {
			param([int]$PathIndex, [int]$ScopeIndex)

			$Key = "$PathIndex,$ScopeIndex"
			if ($Memo.ContainsKey($Key)) {
				return $Memo[$Key]
			}

			$Result = $false
			if ($ScopeIndex -eq $ScopeSegments.Count) {
				$Result = $PathIndex -eq $PathSegments.Count
			}
			elseif ($ScopeSegments[$ScopeIndex] -eq '**') {
				$Result = (Test-SegmentMatch $PathIndex ($ScopeIndex + 1)) -or
					($PathIndex -lt $PathSegments.Count -and
						(Test-SegmentMatch ($PathIndex + 1) $ScopeIndex))
			}
			elseif ($PathIndex -lt $PathSegments.Count -and
				($ScopeSegments[$ScopeIndex] -eq '*' -or
					$PathSegments[$PathIndex].Equals(
						$ScopeSegments[$ScopeIndex],
						[System.StringComparison]::OrdinalIgnoreCase
					))) {
				$Result = Test-SegmentMatch ($PathIndex + 1) ($ScopeIndex + 1)
			}

			$Memo[$Key] = $Result
			return $Result
		}

		if (Test-SegmentMatch 0 0) {
			return $true
		}
	}

	return $false
}

function Assert-NoReparsePoint {
	param(
		[Parameter(Mandatory)]
		[string]$Path
	)

	$Current = Get-Item -LiteralPath $Path -Force
	while ($null -ne $Current) {
		if (($Current.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
			throw "Artifact path '$Path' traverses reparse point '$($Current.FullName)'."
		}

		$Current = $Current.Parent
	}
}

function Resolve-ArtifactTarget {
	param(
		[string]$RequestedPath,

		[Parameter(Mandatory)]
		[string]$DefaultFileName,

		[Parameter(Mandatory)]
		[string]$Root
	)

	$Candidate = if ([string]::IsNullOrWhiteSpace($RequestedPath)) {
		Join-Path $Root $DefaultFileName
	}
	elseif ([System.IO.Path]::IsPathRooted($RequestedPath)) {
		[System.IO.Path]::GetFullPath($RequestedPath)
	}
	else {
		[System.IO.Path]::GetFullPath((Join-Path $Root $RequestedPath))
	}

	$Candidate = [System.IO.Path]::GetFullPath($Candidate)
	$CandidateParent = [System.IO.Path]::GetFullPath(
		(Split-Path -Parent $Candidate)
	).TrimEnd('\', '/')
	$NormalizedRoot = [System.IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
	if (-not $CandidateParent.Equals(
			$NormalizedRoot,
			[System.StringComparison]::OrdinalIgnoreCase
		)) {
		throw "Artifact path '$Candidate' is outside dedicated artifact root '$Root'."
	}

	if (Test-Path -LiteralPath $Candidate) {
		throw "Artifact path '$Candidate' already exists; use a fresh run_id or filename."
	}

	return $Candidate
}

function Write-CandidatePatchArtifact {
	param(
		[Parameter(Mandatory)]
		[string]$Path,

		[Parameter(Mandatory)]
		[string]$Content
	)

	[System.IO.File]::WriteAllText($Path, $Content, [System.Text.UTF8Encoding]::new($false))
}

function ConvertTo-DeliveryTomlLiteralString {
	param(
		[Parameter(Mandatory)]
		[string]$Value
	)

	if ($Value.IndexOfAny([char[]]@("'", "`r", "`n")) -ge 0) {
		throw "Value '$Value' cannot be encoded as a TOML literal string."
	}

	return "'" + $Value + "'"
}

function ConvertFrom-DeliveryNeutralEvidenceBytes {
	param(
		[Parameter(Mandatory)]
		[string]$FieldName,

		[Parameter(Mandatory)]
		[object]$Record
	)

	try {
		if ([string]$Record.encoding -ceq 'utf8') {
			return ,([System.Text.UTF8Encoding]::new($false, $true).GetBytes(
				[string]$Record.content
			))
		}

		if ([string]$Record.encoding -ceq 'base64') {
			return ,([System.Convert]::FromBase64String([string]$Record.content))
		}

		throw 'Unexpected neutral evidence encoding.'
	}
	catch {
		throw "Neutral evidence field '$FieldName' could not be decoded."
	}
}

function ConvertFrom-DeliveryNeutralEvidenceText {
	param(
		[Parameter(Mandatory)]
		[string]$FieldName,

		[Parameter(Mandatory)]
		[object]$Record
	)

	try {
		$Bytes = ConvertFrom-DeliveryNeutralEvidenceBytes `
			-FieldName $FieldName `
			-Record $Record
		return [System.Text.UTF8Encoding]::new($false, $true).GetString($Bytes)
	}
	catch {
		throw "Neutral evidence field '$FieldName' could not be decoded."
	}
}

function Invoke-DeliveryGitBytes {
	param(
		[Parameter(Mandatory)]
		[string]$Arguments,

		[hashtable]$Environment = @{}
	)

	$StartInfo = [System.Diagnostics.ProcessStartInfo]::new()
	$StartInfo.FileName = (Get-Command git -ErrorAction Stop).Source
	$StartInfo.WorkingDirectory = $WorkspaceRoot
	$StartInfo.Arguments = $Arguments
	$StartInfo.UseShellExecute = $false
	$StartInfo.CreateNoWindow = $true
	$StartInfo.RedirectStandardOutput = $true
	$StartInfo.RedirectStandardError = $true
	foreach ($Name in $Environment.Keys) {
		$StartInfo.EnvironmentVariables[[string]$Name] = [string]$Environment[$Name]
	}
	$Process = [System.Diagnostics.Process]::new()
	$Process.StartInfo = $StartInfo
	$Output = [System.IO.MemoryStream]::new()
	try {
		if (-not $Process.Start()) {
			throw "Could not start Git command '$Arguments'."
		}
		$OutputTask = $Process.StandardOutput.BaseStream.CopyToAsync($Output)
		$ErrorTask = $Process.StandardError.ReadToEndAsync()
		$Process.WaitForExit()
		[void]$OutputTask.GetAwaiter().GetResult()
		$StandardError = $ErrorTask.GetAwaiter().GetResult()
		$ExitCode = $Process.ExitCode
		$Result = $Output.ToArray()
	}
	finally {
		$Output.Dispose()
		$Process.Dispose()
	}

	if ($ExitCode -ne 0) {
		throw "Git command '$Arguments' failed: $StandardError"
	}

	return ,$Result
}

function Invoke-DeliveryGitText {
	param(
		[Parameter(Mandatory)]
		[string]$Arguments,

		[hashtable]$Environment = @{}
	)

	$Bytes = Invoke-DeliveryGitBytes `
		-Arguments $Arguments `
		-Environment $Environment
	return [System.Text.UTF8Encoding]::new($false, $true).GetString($Bytes)
}

function Test-DeliveryByteArrayEqual {
	param(
		[Parameter(Mandatory)]
		[AllowEmptyCollection()]
		[byte[]]$Left,

		[Parameter(Mandatory)]
		[AllowEmptyCollection()]
		[byte[]]$Right
	)

	if ($Left.Length -ne $Right.Length) {
		return $false
	}

	for ($Index = 0; $Index -lt $Left.Length; $Index++) {
		if ($Left[$Index] -ne $Right[$Index]) {
			return $false
		}
	}

	return $true
}

$CodexCommand = (Resolve-Path -LiteralPath $CodexCommand).Path
if ((Test-PathWithin -Path $CodexCommand -Root $RepositoryRoot) -or
	[System.IO.Path]::GetFileNameWithoutExtension($CodexCommand) -ne 'codex') {
	throw "Resolved Codex executable '$CodexCommand' is not an allowed production command."
}

if ($IsArtifactProducer) {
	$AllowedPaths = [string[]]@($Handoff.allowed_paths)
	foreach ($AllowedPath in $AllowedPaths) {
		$NormalizedAllowedPath = $AllowedPath.Replace('\', '/').TrimEnd('/')
		$AllowedPathSegments = @($NormalizedAllowedPath -split '/')
		if ([string]::IsNullOrWhiteSpace($NormalizedAllowedPath) -or
			[System.IO.Path]::IsPathRooted($AllowedPath) -or
			$NormalizedAllowedPath.StartsWith('/') -or
			$AllowedPathSegments -contains '..') {
			throw "Allowed path '$AllowedPath' escapes the isolated workspace."
		}

		foreach ($AllowedPathSegment in $AllowedPathSegments) {
			if ([string]::IsNullOrEmpty($AllowedPathSegment) -or
				$AllowedPathSegment -eq '.' -or
				($AllowedPathSegment.Contains('*') -and
					$AllowedPathSegment -notin @('*', '**')) -or
				$AllowedPathSegment.IndexOfAny([char[]]'?[]') -ge 0) {
				throw "Allowed path '$AllowedPath' contains an unsupported segment."
			}
		}
	}
}

$PreviousErrorActionPreference = $ErrorActionPreference
try {
	$ErrorActionPreference = 'Continue'
	$GitTopLevel = @(& git -C $WorkspaceRoot rev-parse --show-toplevel 2>&1)
	$GitTopLevelExitCode = $LASTEXITCODE
	$ResolvedSourceCommit = @(
		& git -C $WorkspaceRoot rev-parse --verify "$($Handoff.source_commit)^{commit}" 2>&1
	)
	$SourceCommitExitCode = $LASTEXITCODE
	$HeadCommit = @(& git -C $WorkspaceRoot rev-parse HEAD 2>&1)
	$HeadCommitExitCode = $LASTEXITCODE
}
finally {
	$ErrorActionPreference = $PreviousErrorActionPreference
}
if ($GitTopLevelExitCode -ne 0 -or $SourceCommitExitCode -ne 0 -or
	$HeadCommitExitCode -ne 0) {
	throw "Stage '$Stage' requires a valid Git repository and source_commit."
}

$GitTopLevel = [System.IO.Path]::GetFullPath([string]$GitTopLevel[0]).TrimEnd('\', '/')
if (-not $GitTopLevel.Equals(
		[System.IO.Path]::GetFullPath($WorkspaceRoot).TrimEnd('\', '/'),
		[System.StringComparison]::OrdinalIgnoreCase
	)) {
	throw "Stage workspace_root must be the repository top level '$GitTopLevel'."
}

$ResolvedSourceCommit = ([string]$ResolvedSourceCommit[0]).Trim()
$HeadCommit = ([string]$HeadCommit[0]).Trim()
if (-not $HeadCommit.Equals(
		$ResolvedSourceCommit,
		[System.StringComparison]::OrdinalIgnoreCase
	)) {
	throw (
		"Stage source_commit '$ResolvedSourceCommit' does not match " +
		"workspace HEAD '$HeadCommit'."
	)
}

$HandoffSchema = Get-Content -Raw -LiteralPath $HandoffSchemaPath | ConvertFrom-Json
$StageSchema = $HandoffSchema.stages.$Stage
$NeutralEvidenceFields = @($StageSchema.neutral_evidence_fields.PSObject.Properties.Name)

$BeforeSnapshot = & $SnapshotScript -RepositoryRoot $WorkspaceRoot
$Before = $BeforeSnapshot.Files
$BeforeSnapshotHash = $BeforeSnapshot.Hash
if ($ExternalIngestRequired) {
	$null = Test-DeliveryAcceptedIngestEvidence `
		-EvidenceManifestPath ([string]$ExternalEvidence.evidence_manifest_path) `
		-ExpectedEvidenceManifestSha256 ([string]$ExternalEvidence.evidence_manifest_sha256) `
		-ExternalManifestPath ([string]$ExternalEvidence.external_manifest_path) `
		-ExpectedExternalManifestSha256 ([string]$ExternalEvidence.external_manifest_sha256) `
		-PreparedJournalPath ([string]$ExternalEvidence.prepared_journal_path) `
		-ExpectedPreparedJournalSha256 ([string]$ExternalEvidence.prepared_journal_sha256) `
		-ExpectedSourceCommit ([string]$ExternalEvidence.source_commit) `
		-RepositoryRoot $WorkspaceRoot
}
$AttestedExistingPathSha256Json = '{}'
if ($IsArtifactProducer) {
	$AttestedExistingPathSha256 = [ordered]@{}
	$SortedSnapshotPaths = [string[]]@($Before.Keys)
	[System.Array]::Sort(
		$SortedSnapshotPaths,
		[System.StringComparer]::Ordinal
	)
	foreach ($SnapshotPath in $SortedSnapshotPaths) {
		if (-not (Test-DeliveryRelativePathAllowed `
				-RelativePath $SnapshotPath `
				-AllowedPaths $AllowedPaths)) {
			continue
		}

		$SnapshotFingerprint = [string]$Before[$SnapshotPath]
		$FingerprintMatch = [regex]::Match(
			$SnapshotFingerprint,
			'^([0-9a-f]{64})\|attributes=-?[0-9]+$',
			[System.Text.RegularExpressions.RegexOptions]::CultureInvariant
		)
		if (-not $FingerprintMatch.Success) {
			throw (
				"Attested snapshot fingerprint for allowed path " +
				"'$SnapshotPath' is malformed."
			)
		}

		$AttestedExistingPathSha256[$SnapshotPath.Replace('\', '/')] = (
			$FingerprintMatch.Groups[1].Value.ToLowerInvariant()
		)
	}

	$AttestedExistingPathSha256Json = (
		[pscustomobject]$AttestedExistingPathSha256 |
			ConvertTo-Json -Compress
	)
}

$ActualBaselines = [ordered]@{
	baseline_status = Invoke-DeliveryGitText `
		-Arguments 'status --short --untracked-files=all'
	baseline_diff = Invoke-DeliveryGitText `
		-Arguments 'diff --binary --no-ext-diff'
}
foreach ($PropertyName in $ActualBaselines.Keys) {
	$BaselineValue = $Handoff.$PropertyName

	if ($NeutralEvidenceFields -ccontains $PropertyName) {
		$BaselineValue = ConvertFrom-DeliveryNeutralEvidenceText `
			-FieldName $PropertyName `
			-Record $BaselineValue
	}

	if ($Handoff.PSObject.Properties.Name -contains $PropertyName -and
		-not [string]::Equals(
			[string]$BaselineValue,
			[string]$ActualBaselines[$PropertyName],
			[System.StringComparison]::Ordinal
		)) {
		throw "Stage handoff $PropertyName does not match the current Git state."
	}
}

if ($Stage -ceq 'reviewer') {
	$TemporaryRoot = [System.IO.Path]::GetFullPath(
		(Join-Path ([System.IO.Path]::GetTempPath()) (
			'aetheln-delivery-review-' + [guid]::NewGuid().ToString('N')
		))
	)
	$TemporaryRootCreated = $false
	try {
		[void][System.IO.Directory]::CreateDirectory($TemporaryRoot)
		$TemporaryRootCreated = $true
		Assert-NoReparsePoint -Path $TemporaryRoot

		$TemporaryIndex = Join-Path $TemporaryRoot 'index'
		$TemporaryObjects = Join-Path $TemporaryRoot 'objects'
		[void][System.IO.Directory]::CreateDirectory($TemporaryObjects)
		Assert-NoReparsePoint -Path $TemporaryObjects

		$RealObjectPath = (
			Invoke-DeliveryGitText -Arguments 'rev-parse --git-path objects'
		).Trim()
		if (-not [System.IO.Path]::IsPathRooted($RealObjectPath)) {
			$RealObjectPath = Join-Path $WorkspaceRoot $RealObjectPath
		}
		$RealObjectDirectory = (Resolve-Path -LiteralPath $RealObjectPath).Path

		$ReviewerGitEnvironment = @{
			GIT_INDEX_FILE = $TemporaryIndex
			GIT_OBJECT_DIRECTORY = $TemporaryObjects
			GIT_ALTERNATE_OBJECT_DIRECTORIES = $RealObjectDirectory
			GIT_OPTIONAL_LOCKS = '0'
		}

		$null = Invoke-DeliveryGitBytes `
			-Arguments "read-tree $ResolvedSourceCommit" `
			-Environment $ReviewerGitEnvironment
		$null = Invoke-DeliveryGitBytes `
			-Arguments 'add --all -- .' `
			-Environment $ReviewerGitEnvironment

		$ActualFinalDiff = Invoke-DeliveryGitBytes `
			-Arguments 'diff --cached --binary --full-index --no-ext-diff' `
			-Environment $ReviewerGitEnvironment
		$ExpectedFinalDiff = ConvertFrom-DeliveryNeutralEvidenceBytes `
			-FieldName 'final_diff' `
			-Record $Handoff.final_diff
		if (-not (Test-DeliveryByteArrayEqual `
				-Left $ExpectedFinalDiff `
				-Right $ActualFinalDiff)) {
			throw 'Stage handoff final_diff does not match the staged worktree.'
		}

		$ActualArtifactState = Invoke-DeliveryGitBytes `
			-Arguments 'status --porcelain=v1 -z --untracked-files=all'
		$ExpectedArtifactState = ConvertFrom-DeliveryNeutralEvidenceBytes `
			-FieldName 'artifact_state' `
			-Record $Handoff.artifact_state
		if (-not (Test-DeliveryByteArrayEqual `
				-Left $ExpectedArtifactState `
				-Right $ActualArtifactState)) {
			throw 'Stage handoff artifact_state does not match the worktree.'
		}
	}
	finally {
		if ($TemporaryRootCreated -and
			[System.IO.Directory]::Exists($TemporaryRoot)) {
			$ResolvedTemporaryRoot = (Resolve-Path -LiteralPath $TemporaryRoot).Path
			$ResolvedSystemTempRoot = [System.IO.Path]::GetFullPath(
				[System.IO.Path]::GetTempPath()
			).TrimEnd('\', '/')
			$TemporaryRootName = Split-Path -Leaf $ResolvedTemporaryRoot

			if (-not (Test-PathWithin `
					-Path $ResolvedTemporaryRoot `
					-Root $ResolvedSystemTempRoot) -or
				-not $TemporaryRootName.Equals(
					(Split-Path -Leaf $TemporaryRoot),
					[System.StringComparison]::Ordinal
				) -or
				$TemporaryRootName -cnotmatch `
					'^aetheln-delivery-review-[0-9a-f]{32}$') {
				throw (
					"Refusing to remove unsafe reviewer attestation temporary " +
					"directory '$ResolvedTemporaryRoot'."
				)
			}

			Assert-NoReparsePoint -Path $ResolvedTemporaryRoot
			Remove-Item -LiteralPath $ResolvedTemporaryRoot -Recurse -Force
		}
	}
}

$AgentFile = Join-Path (
	Join-Path $RepositoryRoot '.codex\agents'
) ("delivery-$Stage.toml")
if (-not (Test-Path -LiteralPath $AgentFile)) {
	throw "Missing custom agent profile '$AgentFile'."
}

$AgentConfig = Get-Content -Raw -LiteralPath $AgentFile
$InstructionMatch = [regex]::Match(
	$AgentConfig,
	'(?s)developer_instructions\s*=\s*"""\r?\n?(.*?)\r?\n?"""'
)
if (-not $InstructionMatch.Success) {
	throw "Could not read developer instructions from '$AgentFile'."
}

if ([string]::IsNullOrWhiteSpace($ArtifactRoot)) {
	$ArtifactRoot = Join-Path (
		[System.IO.Path]::GetTempPath()
	) 'aetheln-delivery-stage-artifacts'
}

$ArtifactRoot = [System.IO.Path]::GetFullPath($ArtifactRoot).TrimEnd('\', '/')
$SystemTempRoot = [System.IO.Path]::GetFullPath(
	[System.IO.Path]::GetTempPath()
).TrimEnd('\', '/')
$ArtifactDriveRoot = [System.IO.Path]::GetPathRoot($ArtifactRoot).TrimEnd('\', '/')
if ($ArtifactRoot.Equals(
		$ArtifactDriveRoot,
		[System.StringComparison]::OrdinalIgnoreCase
	)) {
	throw "Artifact root '$ArtifactRoot' must not be a filesystem root."
}

if ($ArtifactRoot.Equals(
		$SystemTempRoot,
		[System.StringComparison]::OrdinalIgnoreCase
	) -or -not (Test-PathWithin -Path $ArtifactRoot -Root $SystemTempRoot)) {
	throw "Artifact root '$ArtifactRoot' must be a dedicated directory under '$SystemTempRoot'."
}

if (Test-PathWithin -Path $ArtifactRoot -Root $RepositoryRoot) {
	throw "Artifact root '$ArtifactRoot' must be outside the repository."
}

if (-not (Test-Path -LiteralPath $ArtifactRoot)) {
	New-Item -ItemType Directory -Path $ArtifactRoot | Out-Null
}
elseif (-not (Get-Item -LiteralPath $ArtifactRoot -Force).PSIsContainer) {
	throw "Artifact root '$ArtifactRoot' is not a directory."
}

$ArtifactRoot = (Resolve-Path -LiteralPath $ArtifactRoot).Path
Assert-NoReparsePoint -Path $ArtifactRoot

$OutputPath = Resolve-ArtifactTarget `
	-RequestedPath $OutputPath `
	-DefaultFileName "delivery-stage-$($Validation.RunId)-output.json" `
	-Root $ArtifactRoot
$AuditPath = Resolve-ArtifactTarget `
	-RequestedPath $AuditPath `
	-DefaultFileName "delivery-stage-$($Validation.RunId)-audit.json" `
	-Root $ArtifactRoot
$TelemetryPath = Resolve-ArtifactTarget `
	-RequestedPath $TelemetryPath `
	-DefaultFileName "delivery-stage-$($Validation.RunId)-telemetry.json" `
	-Root $ArtifactRoot
$EventLogPath = Resolve-ArtifactTarget `
	-DefaultFileName "delivery-stage-$($Validation.RunId)-events.jsonl" `
	-Root $ArtifactRoot
$StandardErrorPath = Resolve-ArtifactTarget `
	-DefaultFileName "delivery-stage-$($Validation.RunId)-stderr.log" `
	-Root $ArtifactRoot
$EvidenceManifestPath = Resolve-ArtifactTarget `
	-DefaultFileName "delivery-stage-$($Validation.RunId)-evidence.json" `
	-Root $ArtifactRoot
$PatchPath = if ($IsArtifactProducer) {
	Resolve-ArtifactTarget `
		-DefaultFileName "delivery-stage-$($Validation.RunId)-candidate.patch" `
		-Root $ArtifactRoot
}
else {
	$null
}
$SourceAttestationPath = if ($IsArtifactProducer) {
	Resolve-ArtifactTarget `
		-DefaultFileName (
			"delivery-stage-$($Validation.RunId)-source-attestation.json"
		) `
		-Root $ArtifactRoot
}
else {
	$null
}

$ArtifactTargets = [ordered]@{
	Output = $OutputPath
	Audit = $AuditPath
	Event = $EventLogPath
	StandardError = $StandardErrorPath
	Telemetry = $TelemetryPath
	EvidenceManifest = $EvidenceManifestPath
	CandidatePatch = $PatchPath
	SourceAttestation = $SourceAttestationPath
}
$ResolvedArtifactTargetNames = @(
	$ArtifactTargets.Keys | Where-Object {
		-not [string]::IsNullOrWhiteSpace([string]$ArtifactTargets[$_])
	}
)
for ($LeftIndex = 0; $LeftIndex -lt $ResolvedArtifactTargetNames.Count; $LeftIndex++) {
	for ($RightIndex = $LeftIndex + 1; $RightIndex -lt $ResolvedArtifactTargetNames.Count; $RightIndex++) {
		$LeftName = $ResolvedArtifactTargetNames[$LeftIndex]
		$RightName = $ResolvedArtifactTargetNames[$RightIndex]
		if ([System.IO.Path]::GetFullPath($ArtifactTargets[$LeftName]).Equals(
				[System.IO.Path]::GetFullPath($ArtifactTargets[$RightName]),
				[System.StringComparison]::OrdinalIgnoreCase
			)) {
			throw "Artifact targets '$LeftName' and '$RightName' resolve to the same path."
		}
	}
}

$ToolConfigurationArguments = @(
	'-c',
	'mcp_servers={}'
)
if ($IsArtifactProducer) {
	$SourceInspectionServerScript = Join-Path (
		$PSScriptRoot
	) 'Invoke-DeliverySourceInspectionServer.ps1'
	if (-not (Test-Path -LiteralPath $SourceInspectionServerScript -PathType Leaf)) {
		throw 'Source-inspection server script is missing.'
	}

	$SourceInspectionHost = Get-Command pwsh -ErrorAction SilentlyContinue
	if ($null -eq $SourceInspectionHost) {
		$SourceInspectionHost = Get-Command powershell -ErrorAction SilentlyContinue
	}
	if ($null -eq $SourceInspectionHost -or
		[string]::IsNullOrWhiteSpace([string]$SourceInspectionHost.Source)) {
		throw (
			'Could not resolve an absolute PowerShell host for the ' +
			'source-inspection server.'
		)
	}
	$SourceInspectionHostCommand = [string]$SourceInspectionHost.Source

	$SourceAttestationJson = [pscustomobject][ordered]@{
		workspace_root = $WorkspaceRoot
		allowed_paths = [string[]]@($AllowedPaths)
		attested_files = [pscustomobject]$AttestedExistingPathSha256
	} | ConvertTo-Json -Depth 4
	$SourceAttestationBytes = [System.Text.UTF8Encoding]::new($false).GetBytes(
		$SourceAttestationJson
	)
	$SourceAttestationHasher = [System.Security.Cryptography.SHA256]::Create()
	try {
		$SourceAttestationSha256 = [System.BitConverter]::ToString(
			$SourceAttestationHasher.ComputeHash($SourceAttestationBytes)
		).Replace('-', '').ToLowerInvariant()
	}
	finally {
		$SourceAttestationHasher.Dispose()
	}
	if (-not $DryRun) {
		[System.IO.File]::WriteAllBytes(
			$SourceAttestationPath,
			$SourceAttestationBytes
		)
	}

	$SourceInspectionServerArguments = @(
		'-NoLogo',
		'-NoProfile',
		'-NonInteractive',
		'-File',
		$SourceInspectionServerScript,
		'-AttestationPath',
		$SourceAttestationPath,
		'-AttestationSha256',
		$SourceAttestationSha256,
		'-WorkspaceRoot',
		$WorkspaceRoot
	)
	$SourceInspectionArgsToml = '[' + (@(
		$SourceInspectionServerArguments | ForEach-Object {
			ConvertTo-DeliveryTomlLiteralString -Value $_
		}
	) -join ', ') + ']'
	$ToolConfigurationArguments = @(
		'-c',
		'features.shell_tool=false',
		'-c',
		('mcp_servers.source_inspection.command=' + (
			ConvertTo-DeliveryTomlLiteralString -Value $SourceInspectionHostCommand
		)),
		'-c',
		('mcp_servers.source_inspection.args=' + $SourceInspectionArgsToml),
		'-c',
		'mcp_servers.source_inspection.required=true',
		'-c',
		'mcp_servers.source_inspection.enabled_tools=[''read_allowed_source_file'']'
	)
}

$Prompt = @"
You are the fresh delivery stage '$Stage'.

Stage instructions:
$($InstructionMatch.Groups[1].Value)

Validated handoff SHA-256: $($Validation.HandoffHash)
Treat the following JSON as the complete stage input. Do not infer hidden context.
Repository snapshot SHA-256 before launch: $BeforeSnapshotHash

$($Validation.HandoffJson)
"@
if ($IsArtifactProducer) {
	$Prompt += @"

Your artifact must be a delivery_file_bundle_v1 object containing complete
create/replace file results. Do not hand-author a unified diff. The launcher
will convert the validated bundle to a strict Git patch after confirming that
the repository snapshot remained unchanged.

Attested existing allowed-path SHA-256 map:
$AttestedExistingPathSha256Json

For every replace record, use the exact lowercase SHA-256 value for its path
from that map as base_sha256. For every create record, base_sha256 must be null.
Do not calculate or re-derive these hashes.
Return the schema-defined outer stage object as your structured final output.
It must contain stage, status, summary, evidence, changed_paths, findings, and
artifact.
Put the delivery_file_bundle_v1 object under artifact; do not return the bundle
directly or omit the outer stage object.
Inspect allowed source files only with the required read_allowed_source_file tool.
Do not use commands, scripts, shells, interpreters, executables, or temporary files
for hashing, bundle construction, or bundle serialization. Do not write the
bundle to an intermediate file.
"@
}

$Arguments = @(
	'exec',
	'--ephemeral',
	'--ignore-user-config',
	'--strict-config',
	'--disable',
	'apps',
	'--sandbox',
	$SandboxMode,
	'-C',
	$WorkspaceRoot,
	'--skip-git-repo-check'
) + $ToolConfigurationArguments + @(
	'-c',
	'web_search="disabled"',
	'-c',
	'approval_policy="never"',
	'--output-schema',
	$SelectedOutputSchemaPath,
	'--output-last-message',
	$OutputPath,
	'--json',
	'-'
)

$LaunchPlan = [pscustomobject]@{
	Stage = $Stage
	RunId = $Validation.RunId
	WorkspaceRoot = $WorkspaceRoot
	SandboxMode = $SandboxMode
	HandoffHash = $Validation.HandoffHash
	Command = $CodexCommand
	Arguments = $Arguments
	OutputPath = [System.IO.Path]::GetFullPath($OutputPath)
	EventLogPath = $EventLogPath
	StandardErrorPath = $StandardErrorPath
	AuditPath = [System.IO.Path]::GetFullPath($AuditPath)
	TelemetryPath = [System.IO.Path]::GetFullPath($TelemetryPath)
	ArtifactRoot = $ArtifactRoot
	PatchPath = $PatchPath
	EvidenceManifestPath = $EvidenceManifestPath
}

if ($DryRun) {
	if ($PassThru) {
		return $LaunchPlan
	}

	$LaunchPlan | Format-List
	return
}

$Events = @()
$ExitCode = $null
$LaunchException = $null
$PreviousErrorActionPreference = $ErrorActionPreference
try {
	$ErrorActionPreference = 'Continue'
	$StartedAt = [datetime]::UtcNow
	$StartedAtUtc = $StartedAt.ToString('o')
	if ($ExternalIngestRequired) {
		$null = Test-DeliveryAcceptedIngestEvidence `
			-EvidenceManifestPath ([string]$ExternalEvidence.evidence_manifest_path) `
			-ExpectedEvidenceManifestSha256 ([string]$ExternalEvidence.evidence_manifest_sha256) `
			-ExternalManifestPath ([string]$ExternalEvidence.external_manifest_path) `
			-ExpectedExternalManifestSha256 ([string]$ExternalEvidence.external_manifest_sha256) `
			-PreparedJournalPath ([string]$ExternalEvidence.prepared_journal_path) `
			-ExpectedPreparedJournalSha256 ([string]$ExternalEvidence.prepared_journal_sha256) `
			-ExpectedSourceCommit ([string]$ExternalEvidence.source_commit) `
			-RepositoryRoot $WorkspaceRoot
	}
	$Events = @($Prompt | & $CodexCommand @Arguments 2> $StandardErrorPath)
	$ExitCode = $LASTEXITCODE
}
catch {
	$LaunchException = $_
}
finally {
	$EndedAt = [datetime]::UtcNow
	$EndedAtUtc = $EndedAt.ToString('o')
	$ErrorActionPreference = $PreviousErrorActionPreference
}
[System.IO.File]::WriteAllLines(
	$EventLogPath,
	[string[]]@($Events | ForEach-Object { [string]$_ })
)

$AfterSnapshotError = $null
try {
	$AfterSnapshot = & $SnapshotScript -RepositoryRoot $WorkspaceRoot
	$After = $AfterSnapshot.Files
	$AfterSnapshotHash = $AfterSnapshot.Hash
}
catch {
	$AfterSnapshotError = $_
	$After = @{}
	$AfterSnapshotHash = $null
}
$ChangedPaths = @()
if ($null -eq $AfterSnapshotError) {
	foreach ($Path in @($Before.Keys) + @($After.Keys) | Sort-Object -Unique) {
		if ($Before[$Path] -ne $After[$Path]) {
			$ChangedPaths += $Path
		}
	}
}
$ProposedPaths = @()
$ArtifactFormat = $null
$ArtifactValidationError = $null
$OutputMissing = $false
$StageStatusError = $null
$CanConsumeStageOutput = (
	$null -eq $AfterSnapshotError -and
	$ChangedPaths.Count -eq 0 -and
	$null -eq $LaunchException -and
	$ExitCode -eq 0
)
if ($CanConsumeStageOutput) {
	try {
		if (-not (Test-Path -LiteralPath $OutputPath)) {
			$OutputMissing = $true
			throw "Stage output artifact '$OutputPath' was not created."
		}

		$StageOutput = Get-Content -Raw -LiteralPath $OutputPath | ConvertFrom-Json
		if ([string]$StageOutput.stage -ne $Stage) {
			throw "Stage output reports '$($StageOutput.stage)' instead of '$Stage'."
		}

		if ([string]$StageOutput.status -ne 'passed') {
			$StageStatusError = (
				"Stage '$Stage' reported status '$($StageOutput.status)': " +
				[string]$StageOutput.summary
			)
		}

		if ($IsArtifactProducer -and [string]$StageOutput.status -eq 'passed') {
			if ($StageOutput.artifact -is [string]) {
				if ([string]::IsNullOrWhiteSpace([string]$StageOutput.artifact)) {
					throw (
						"Passed artifact-producing stage '$Stage' returned no " +
						'candidate artifact.'
					)
				}

				$ArtifactFormat = 'legacy_unified_diff'
				Write-CandidatePatchArtifact `
					-Path $PatchPath `
					-Content ([string]$StageOutput.artifact)
			}
			elseif ($null -ne $StageOutput.artifact) {
				$BundleConversion = & $BundleConversionScript `
					-Bundle $StageOutput.artifact `
					-WorkspaceRoot $WorkspaceRoot `
					-AllowedPaths ([string[]]@($Handoff.allowed_paths)) `
					-DeclaredPaths ([string[]]@($StageOutput.changed_paths)) `
					-SnapshotFiles $Before `
					-PatchPath $PatchPath
				$ArtifactFormat = [string]$BundleConversion.Format
			}
			else {
				throw (
					"Passed artifact-producing stage '$Stage' returned no " +
					'candidate artifact.'
				)
			}

			$PatchValidation = & $PatchValidationScript `
				-PatchPath $PatchPath `
				-WorkspaceRoot $WorkspaceRoot `
				-AllowedPaths ([string[]]@($Handoff.allowed_paths))
			$ProposedPaths = [string[]]@($PatchValidation.ProposedPaths)
		}
	}
	catch {
		$ArtifactValidationError = $_
	}
}

$ObservedTelemetry = $null
$TelemetryError = $null
try {
	$ObservedTelemetry = & $EventTelemetryScript -EventLogPath $EventLogPath
}
catch {
	$TelemetryError = 'The event log could not be parsed as bounded telemetry.'
}

$ExitClass = if ($null -ne $AfterSnapshotError -or $ChangedPaths.Count -gt 0) {
	'repository_mutation'
}
elseif ($null -ne $LaunchException) {
	'launch_exception'
}
elseif ($ExitCode -ne 0) {
	'child_exit_nonzero'
}
elseif ($null -ne $ArtifactValidationError -and $OutputMissing) {
	'output_missing'
}
elseif ($null -ne $ArtifactValidationError) {
	'output_invalid'
}
elseif ($null -ne $StageStatusError) {
	'stage_not_passed'
}
elseif ($null -ne $TelemetryError) {
	'telemetry_invalid'
}
else {
	'completed'
}
$EvidenceDisposition = if ($ExitClass -ceq 'completed') {
	'accepted'
}
else {
	'rejected'
}

$StageStatus = if ($null -ne $StageOutput) {
	[string]$StageOutput.status
}
else {
	$null
}
$OutputBytes = if (Test-Path -LiteralPath $OutputPath -PathType Leaf) {
	(Get-Item -LiteralPath $OutputPath -Force).Length
}
else {
	$null
}
$PatchBytes = if ($null -ne $PatchPath -and
	(Test-Path -LiteralPath $PatchPath -PathType Leaf)) {
	(Get-Item -LiteralPath $PatchPath -Force).Length
}
else {
	$null
}
$ArtifactFailureKind = if ($null -ne $ArtifactValidationError) {
	$FailureKindMatch = [regex]::Match(
		$ArtifactValidationError.Exception.Message,
		'\[(patch|bundle)_[a-z_]+\]'
	)
	if ($FailureKindMatch.Success) {
		$FailureKindMatch.Value.Trim('[', ']')
	}
	else {
		'output_invalid'
	}
}
else {
	$null
}
$ExecutionPolicy = $Validation.ExecutionPolicy
$Telemetry = [ordered]@{
	SchemaVersion = 1
	RunId = $Validation.RunId
	Ticket = [string]$Handoff.ticket
	Stage = $Stage
	SourceCommit = $ResolvedSourceCommit
	HandoffHash = $Validation.HandoffHash
	BeforeSnapshotHash = $BeforeSnapshotHash
	AfterSnapshotHash = $AfterSnapshotHash
	StartedAtUtc = $StartedAtUtc
	EndedAtUtc = $EndedAtUtc
	DurationMilliseconds = [long][math]::Max(0, ($EndedAt - $StartedAt).TotalMilliseconds)
	AttemptOrdinal = $ExecutionPolicy.AttemptOrdinal
	AttemptClass = $ExecutionPolicy.AttemptClass
	CapabilityClass = $ExecutionPolicy.CapabilityClass
	RetryCause = $ExecutionPolicy.RetryCause
	Limits = [ordered]@{
		TotalTokens = $ExecutionPolicy.Limits.TotalTokens
		ElapsedMilliseconds = $ExecutionPolicy.Limits.ElapsedMilliseconds
		ConcurrentStages = $ExecutionPolicy.Limits.ConcurrentStages
		ExecutionRetries = $ExecutionPolicy.Limits.ExecutionRetries
		FixCycles = $ExecutionPolicy.Limits.FixCycles
		Provenance = $ExecutionPolicy.Limits.Provenance
		ApprovedAtUtc = $ExecutionPolicy.Limits.ApprovedAtUtc
	}
	SessionId = if ($null -ne $ObservedTelemetry) { $ObservedTelemetry.SessionId } else { $null }
	Model = if ($null -ne $ObservedTelemetry) { $ObservedTelemetry.Model } else { $null }
	ReasoningTier = if ($null -ne $ObservedTelemetry) { $ObservedTelemetry.ReasoningTier } else { $null }
	InputTokens = if ($null -ne $ObservedTelemetry) { $ObservedTelemetry.InputTokens } else { $null }
	CachedInputTokens = if ($null -ne $ObservedTelemetry) { $ObservedTelemetry.CachedInputTokens } else { $null }
	CacheWriteInputTokens = if ($null -ne $ObservedTelemetry) { $ObservedTelemetry.CacheWriteInputTokens } else { $null }
	OutputTokens = if ($null -ne $ObservedTelemetry) { $ObservedTelemetry.OutputTokens } else { $null }
	ReasoningOutputTokens = if ($null -ne $ObservedTelemetry) { $ObservedTelemetry.ReasoningOutputTokens } else { $null }
	TotalTokens = if ($null -ne $ObservedTelemetry) { $ObservedTelemetry.TotalTokens } else { $null }
	ExitClass = $ExitClass
	ChangedPathCount = [long]$ChangedPaths.Count
	ProposedPathCount = [long]$ProposedPaths.Count
	OutputBytes = $OutputBytes
	PatchBytes = $PatchBytes
	StageStatus = $StageStatus
	EvidenceManifestPath = $EvidenceManifestPath
	EvidenceManifestHash = $null
	TelemetryError = $TelemetryError
}
$Telemetry | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $TelemetryPath -Encoding UTF8

$Audit = [ordered]@{
	Stage = $Stage
	RunId = $Validation.RunId
	HandoffHash = $Validation.HandoffHash
	SourceCommit = $ResolvedSourceCommit
	HeadCommit = $HeadCommit
	BeforeSnapshotHash = $BeforeSnapshotHash
	AfterSnapshotHash = $AfterSnapshotHash
	AfterSnapshotError = if ($null -ne $AfterSnapshotError) {
		$AfterSnapshotError.Exception.Message
	}
	else {
		$null
	}
	ExitCode = $ExitCode
	LaunchException = if ($null -ne $LaunchException) {
		$LaunchException.Exception.Message
	}
	else {
		$null
	}
	ArtifactValidationError = if ($null -ne $ArtifactValidationError) {
		$ArtifactValidationError.Exception.Message
	}
	else {
		$null
	}
	ArtifactFailureKind = $ArtifactFailureKind
	ArtifactFormat = $ArtifactFormat
	StageStatusError = $StageStatusError
	EventLogPath = $EventLogPath
	StandardErrorPath = $StandardErrorPath
	TelemetryPath = $TelemetryPath
	ChangedPaths = [string[]]$ChangedPaths
	ProposedPaths = [string[]]$ProposedPaths
	PatchPath = if ($null -ne $PatchPath -and (Test-Path -LiteralPath $PatchPath -PathType Leaf)) {
		$PatchPath
	}
	else {
		$null
	}
	EvidenceManifestPath = $EvidenceManifestPath
}
$Audit | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $AuditPath -Encoding UTF8
$EvidencePaths = @(
	@($OutputPath, $EventLogPath, $StandardErrorPath, $AuditPath, $TelemetryPath, $PatchPath) |
		Where-Object {
			-not [string]::IsNullOrWhiteSpace([string]$_) -and
			(Test-Path -LiteralPath $_ -PathType Leaf)
		}
)
$EvidenceProtection = & $EvidenceProtectionScript `
	-EvidencePaths $EvidencePaths `
	-ManifestPath $EvidenceManifestPath `
	-HandoffHash $Validation.HandoffHash `
	-Disposition $EvidenceDisposition
$null = & $EvidenceValidationScript `
	-ManifestPath $EvidenceProtection.ManifestPath `
	-ExpectedManifestHash $EvidenceProtection.ManifestHash `
	-ExpectedHandoffHash $Validation.HandoffHash `
	-IntegrityOnly

if ($null -ne $AfterSnapshotError) {
	throw (
		"Restricted stage '$Stage' could not attest its post-stage snapshot: " +
		"$($AfterSnapshotError.Exception.Message). Audit: $AuditPath"
	)
}

if ($ChangedPaths.Count -gt 0) {
	throw (
		"Restricted stage '$Stage' changed repository paths: " +
		"$($ChangedPaths -join ', '). Audit: $AuditPath"
	)
}

if ($null -ne $LaunchException) {
	throw (
		"Restricted stage '$Stage' could not launch: " +
		"$($LaunchException.Exception.Message). Audit: $AuditPath"
	)
}

if ($null -ne $ArtifactValidationError) {
	throw (
		"Restricted stage '$Stage' returned an invalid artifact: " +
		"$($ArtifactValidationError.Exception.Message). Audit: $AuditPath"
	)
}

if ($null -ne $StageStatusError) {
	throw (
		"Restricted stage '$Stage' did not pass: $StageStatusError. " +
		"Audit: $AuditPath"
	)
}

if ($ExitCode -ne 0) {
	throw (
		"Restricted stage '$Stage' failed with exit code $ExitCode. " +
		"Events: $EventLogPath. Audit: $AuditPath"
	)
}

if ($null -ne $TelemetryError) {
	throw (
		"Restricted stage '$Stage' returned invalid telemetry. Audit: $AuditPath"
	)
}

$null = & $EvidenceValidationScript `
	-ManifestPath $EvidenceProtection.ManifestPath `
	-ExpectedManifestHash $EvidenceProtection.ManifestHash `
	-ExpectedHandoffHash $Validation.HandoffHash

$SessionId = $null
foreach ($Event in $Events) {
	$Match = [regex]::Match(
		[string]$Event,
		'"(?:thread_id|session_id)"\s*:\s*"([^"]+)"'
	)
	if ($Match.Success) {
		$SessionId = $Match.Groups[1].Value
		break
	}
}

$Result = [pscustomobject]@{
	Stage = $Stage
	RunId = $Validation.RunId
	SessionId = $SessionId
	HandoffHash = $Validation.HandoffHash
	OutputPath = [System.IO.Path]::GetFullPath($OutputPath)
	EventLogPath = $EventLogPath
	AuditPath = [System.IO.Path]::GetFullPath($AuditPath)
	TelemetryPath = [System.IO.Path]::GetFullPath($TelemetryPath)
	PatchPath = $PatchPath
	EvidenceManifestPath = $EvidenceProtection.ManifestPath
	EvidenceManifestHash = $EvidenceProtection.ManifestHash
	ChangedPaths = $ChangedPaths
	ProposedPaths = $ProposedPaths
	ArtifactFormat = $ArtifactFormat
}

if ($PassThru) {
	return $Result
}

$Result | Format-List
