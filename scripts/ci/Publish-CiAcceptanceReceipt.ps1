[CmdletBinding(SupportsShouldProcess)]
param(
	[string] $ContextPath,
	[string] $ProducerKey,
	[string] $JobName,
	[string] $EvidenceRoot,
	[string] $ExpectedEvidenceSha256,
	[long] $ExpectedEvidenceSizeBytes = -1,
	[string] $OutputRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:PublisherContextSchema = 'aetheln.ci-acceptance-context/v1'
$script:PublisherContextLimit = 64KB
$script:PublisherEvidenceLimit = 4MB
$script:PublisherReceiptLimit = 64KB
$script:PublisherUtf8 = New-Object Text.UTF8Encoding($false, $true)
$script:PublisherUtf8NoBom = New-Object Text.UTF8Encoding($false)
$script:PublisherCheckIds = @('clean-package-provenance-smoke','content-reference-validation','controller-contract','controller-operational-proof','native-client-server-compile','portable','unreal-editor-automation','visual-package')
# Each producer key publishes one typed report; Checks are the ordinal-sorted obligations that report can prove.
$script:PublisherContracts = @{
	'portable' = [pscustomobject]@{ EvidenceName='ci-report.json'; Checks=@('controller-contract','portable'); NativeExitCode=$null; CleanupVerified=$null }
	'native' = [pscustomobject]@{ EvidenceName='engine-runner-report.json'; Checks=@('controller-operational-proof','native-client-server-compile'); NativeExitCode=0; CleanupVerified=$true }
	'visual' = [pscustomobject]@{ EvidenceName='visual-package-report.json'; Checks=@('visual-package'); NativeExitCode=$null; CleanupVerified=$null }
}

function Assert-PublisherClosedObject {
	param($Value, [string[]] $PropertyNames)
	if ($null -eq $Value -or $Value -isnot [Management.Automation.PSCustomObject]) { throw 'receipt_publisher_context_invalid' }
	$Actual = @($Value.PSObject.Properties | ForEach-Object { $_.Name })
	if ($Actual.Count -ne $PropertyNames.Count) { throw 'receipt_publisher_context_invalid' }
	foreach ($Name in $PropertyNames) {
		if ($Actual -cnotcontains $Name) { throw 'receipt_publisher_context_invalid' }
	}
}

function Assert-PublisherUniqueJsonProperties {
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'The function validates every property scope in one JSON document.')]
	param([string] $Raw)
	$Scopes = New-Object Collections.Stack
	$PendingName = $null
	$Index = 0
	while ($Index -lt $Raw.Length) {
		$Character = $Raw[$Index]
		if ($Character -eq '"') {
			$Builder = New-Object Text.StringBuilder
			$Index++
			while ($Index -lt $Raw.Length -and $Raw[$Index] -ne '"') {
				if ($Raw[$Index] -eq '\') {
					[void] $Builder.Append($Raw[$Index])
					$Index++
					if ($Index -ge $Raw.Length) { throw 'receipt_publisher_context_json_invalid' }
				}
				[void] $Builder.Append($Raw[$Index])
				$Index++
			}
			if ($Index -ge $Raw.Length) { throw 'receipt_publisher_context_json_invalid' }
			try { $PendingName = [string] (ConvertFrom-Json -InputObject ('"' + $Builder.ToString() + '"')) }
			catch { throw 'receipt_publisher_context_json_invalid' }
			$Index++
			continue
		}
		if ($Character -eq '{') {
			$Scopes.Push((New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)))
			$PendingName = $null
		} elseif ($Character -eq '}') {
			if ($Scopes.Count -eq 0) { throw 'receipt_publisher_context_json_invalid' }
			[void] $Scopes.Pop()
			$PendingName = $null
		} elseif ($Character -eq ':') {
			if ($null -ne $PendingName -and $Scopes.Count -gt 0 -and -not $Scopes.Peek().Add($PendingName)) {
				throw 'receipt_publisher_context_json_duplicate_property'
			}
			$PendingName = $null
		} elseif ($Character -eq ',' -or $Character -eq '[' -or $Character -eq ']') {
			$PendingName = $null
		}
		$Index++
	}
	if ($Scopes.Count -ne 0) { throw 'receipt_publisher_context_json_invalid' }
}

function Assert-PublisherInputPathSyntax {
	param([string] $Path)
	if ([string]::IsNullOrWhiteSpace($Path) -or $Path.Length -gt 4096 -or -not [IO.Path]::IsPathRooted($Path) -or
		$Path.StartsWith('\\?\', [StringComparison]::Ordinal) -or $Path.StartsWith('\\.\', [StringComparison]::Ordinal)) {
		throw 'receipt_publisher_path_invalid'
	}
	$Comparable = $Path.Replace([IO.Path]::AltDirectorySeparatorChar, [IO.Path]::DirectorySeparatorChar)
	foreach ($Segment in $Comparable.Split([IO.Path]::DirectorySeparatorChar)) {
		if ($Segment -ceq '.' -or $Segment -ceq '..') { throw 'receipt_publisher_path_traversal' }
	}
	$WithoutDrive = if ($Path.Length -ge 2 -and $Path[1] -eq ':') { $Path.Substring(2) } else { $Path }
	if ($WithoutDrive.Contains(':')) { throw 'receipt_publisher_path_invalid' }
}

function Assert-PublisherPathWithoutReparse {
	param([string] $Path, [string] $RequiredType, [string] $Reason)
	Assert-PublisherInputPathSyntax -Path $Path
	$PathType = if ($RequiredType -ceq 'Leaf') { 'Leaf' } elseif ($RequiredType -ceq 'Container') { 'Container' } else { throw 'receipt_publisher_internal_path_type_invalid' }
	if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType $PathType)) { throw $Reason }
	try { $Current = Get-Item -LiteralPath $Path -Force }
	catch { throw $Reason }
	while ($null -ne $Current) {
		if (($Current.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'receipt_publisher_reparse_path_invalid' }
		$ParentPath = Split-Path -Path $Current.FullName -Parent
		if ([string]::IsNullOrWhiteSpace($ParentPath) -or $ParentPath -ceq $Current.FullName) { break }
		try { $Current = Get-Item -LiteralPath $ParentPath -Force }
		catch { throw $Reason }
	}
}

function Test-PublisherPathWithin {
	param([string] $Candidate, [string] $Boundary)
	$CandidateFull = [IO.Path]::GetFullPath($Candidate).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
	$BoundaryFull = [IO.Path]::GetFullPath($Boundary).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
	return $CandidateFull -ceq $BoundaryFull -or $CandidateFull.StartsWith($BoundaryFull + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)
}

function Get-ReceiptPublisherSha256 {
	param([byte[]] $Bytes)
	$Hasher = [Security.Cryptography.SHA256]::Create()
	try { return ([BitConverter]::ToString($Hasher.ComputeHash($Bytes))).Replace('-','').ToLowerInvariant() }
	finally { $Hasher.Dispose() }
}

function Read-PublisherContext {
	param([string] $Path)
	Assert-PublisherPathWithoutReparse -Path $Path -RequiredType Leaf -Reason 'receipt_publisher_context_missing'
	$ContextItem = Get-Item -LiteralPath $Path -Force
	if ($ContextItem.Length -le 0 -or $ContextItem.Length -gt $script:PublisherContextLimit) { throw 'receipt_publisher_context_limit' }
	try {
		$Bytes = [IO.File]::ReadAllBytes($ContextItem.FullName)
		if ($Bytes.Length -le 0 -or $Bytes.Length -gt $script:PublisherContextLimit) { throw 'receipt_publisher_context_limit' }
		$Raw = $script:PublisherUtf8.GetString($Bytes)
	} catch {
		if ($_.Exception.Message -ceq 'receipt_publisher_context_limit') { throw }
		throw 'receipt_publisher_context_json_invalid'
	}
	Assert-PublisherUniqueJsonProperties -Raw $Raw
	try { $Context = ConvertFrom-Json -InputObject $Raw }
	catch { throw 'receipt_publisher_context_json_invalid' }
	Assert-PublisherClosedObject -Value $Context -PropertyNames @('schemaVersion','repository','event','source','workflow','controller','policy','actions','run','attemptAnchor','selection')
	if ($Context.schemaVersion -isnot [string] -or $Context.schemaVersion -cne $script:PublisherContextSchema) { throw 'receipt_publisher_context_invalid' }
	Assert-PublisherClosedObject -Value $Context.selection -PropertyNames @('checks')
	$SelectedChecks = $Context.selection.checks
	if ($SelectedChecks -isnot [array] -or $SelectedChecks.Count -lt 1 -or $SelectedChecks.Count -gt $script:PublisherCheckIds.Count) { throw 'receipt_publisher_context_invalid' }
	$SeenChecks = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
	foreach ($Check in $SelectedChecks) {
		if ($Check -isnot [string] -or $script:PublisherCheckIds -cnotcontains $Check -or -not $SeenChecks.Add($Check)) { throw 'receipt_publisher_context_invalid' }
	}
	return $Context
}

function Read-PublisherEvidence {
	param(
		[string] $Root,
		[string] $ExpectedName,
		[string] $ExpectedSha256,
		[long] $ExpectedSizeBytes
	)
	if ($ExpectedSha256 -cnotmatch '^[0-9a-f]{64}$') { throw 'receipt_publisher_evidence_digest_invalid' }
	if ($ExpectedSizeBytes -le 0 -or $ExpectedSizeBytes -gt $script:PublisherEvidenceLimit) { throw 'receipt_publisher_evidence_size_invalid' }
	Assert-PublisherPathWithoutReparse -Path $Root -RequiredType Container -Reason 'receipt_publisher_evidence_root_invalid'
	$Items = @(Get-ChildItem -LiteralPath $Root -Force)
	if ($Items.Count -ne 1 -or $Items[0].PSIsContainer -or $Items[0].Name -cne $ExpectedName -or
		($Items[0].Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
		throw 'receipt_publisher_evidence_inventory_invalid'
	}
	$EvidencePath = $Items[0].FullName
	Assert-PublisherPathWithoutReparse -Path $EvidencePath -RequiredType Leaf -Reason 'receipt_publisher_evidence_inventory_invalid'
	$Stream = $null
	try {
		$Stream = New-Object IO.FileStream($EvidencePath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
		if ($Stream.Length -ne $ExpectedSizeBytes) { throw 'receipt_publisher_evidence_size_mismatch' }
		$Bytes = New-Object byte[] ([int] $ExpectedSizeBytes)
		$Offset = 0
		while ($Offset -lt $Bytes.Length) {
			$Read = $Stream.Read($Bytes, $Offset, $Bytes.Length - $Offset)
			if ($Read -le 0) { throw 'receipt_publisher_evidence_read_incomplete' }
			$Offset += $Read
		}
		if ($Stream.ReadByte() -ne -1) { throw 'receipt_publisher_evidence_size_mismatch' }
	} finally {
		if ($null -ne $Stream) { $Stream.Dispose() }
	}
	if ((Get-ReceiptPublisherSha256 -Bytes $Bytes) -cne $ExpectedSha256) { throw 'receipt_publisher_evidence_digest_mismatch' }
	return $Bytes
}

function Publish-CiAcceptanceReceipt {
	[CmdletBinding(SupportsShouldProcess)]
	param(
		[Parameter(Mandatory)] [string] $ContextPath,
		[Parameter(Mandatory)] [string] $ProducerKey,
		[Parameter(Mandatory)] [string] $JobName,
		[Parameter(Mandatory)] [string] $EvidenceRoot,
		[Parameter(Mandatory)] [string] $ExpectedEvidenceSha256,
		[Parameter(Mandatory)] [long] $ExpectedEvidenceSizeBytes,
		[Parameter(Mandatory)] [string] $OutputRoot
	)
	if (@($script:PublisherContracts.Keys) -cnotcontains $ProducerKey) { throw ('receipt_publisher_key_unsupported:' + $ProducerKey) }
	$Contract = $script:PublisherContracts[$ProducerKey]
	$Context = Read-PublisherContext -Path $ContextPath
	# Selection comes only from the selector-derived identity context; checks this producer cannot prove are dropped.
	$Checks = @($Contract.Checks | Where-Object { @($Context.selection.checks) -ccontains $_ })
	if ($Checks.Count -eq 0) { throw 'receipt_publisher_selection_empty' }
	if ([string]::IsNullOrWhiteSpace($JobName)) { throw 'receipt_publisher_job_invalid' }
	try {
		Assert-PublisherClosedObject -Value $Context.run -PropertyNames @('id','attempt')
		Assert-PublisherClosedObject -Value $Context.attemptAnchor -PropertyNames @('schemaVersion','runId','runAttempt','nonce')
		if ($Context.run.id -isnot [string] -or $Context.run.id -cnotmatch '^[1-9][0-9]{0,18}$' -or
			($Context.run.attempt -isnot [int] -and $Context.run.attempt -isnot [long]) -or [long]$Context.run.attempt -lt 1 -or [long]$Context.run.attempt -gt [int]::MaxValue -or
			$Context.attemptAnchor.runId -isnot [string] -or $Context.attemptAnchor.runId -cne $Context.run.id -or
			($Context.attemptAnchor.runAttempt -isnot [int] -and $Context.attemptAnchor.runAttempt -isnot [long]) -or [long]$Context.attemptAnchor.runAttempt -ne [long]$Context.run.attempt -or
			$Context.attemptAnchor.nonce -isnot [string] -or $Context.attemptAnchor.nonce -cnotmatch '^[0-9a-f]{64}$' -or $Context.attemptAnchor.nonce -cmatch '^0{64}$') {
			throw 'receipt_publisher_context_invalid'
		}
	} catch {
		if ($_.Exception.Message -ceq 'receipt_publisher_context_invalid') { throw }
		throw 'receipt_publisher_context_invalid'
	}
	$NormalizedRun = [pscustomobject][ordered]@{ id=[string]$Context.run.id; attempt=[int]$Context.run.attempt }
	$NormalizedAttemptAnchor = [pscustomobject][ordered]@{
		schemaVersion=[string]$Context.attemptAnchor.schemaVersion
		runId=[string]$Context.attemptAnchor.runId
		runAttempt=[int]$Context.attemptAnchor.runAttempt
		nonce=[string]$Context.attemptAnchor.nonce
	}

	Assert-PublisherInputPathSyntax -Path $OutputRoot
	try { $FullOutputRoot = [IO.Path]::GetFullPath($OutputRoot).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) }
	catch { throw 'receipt_publisher_output_path_invalid' }
	if ([string]::IsNullOrWhiteSpace($FullOutputRoot) -or (Test-Path -LiteralPath $FullOutputRoot)) { throw 'receipt_publisher_output_exists' }
	$ExpectedArtifactName = 'ci-receipt-' + $ProducerKey + '-' + $NormalizedRun.id + '-' + $NormalizedRun.attempt + '-' + $NormalizedAttemptAnchor.nonce
	if ((Split-Path -Path $FullOutputRoot -Leaf) -cne $ExpectedArtifactName) { throw 'receipt_publisher_output_name_invalid' }
	$OutputParent = Split-Path -Path $FullOutputRoot -Parent
	Assert-PublisherPathWithoutReparse -Path $OutputParent -RequiredType Container -Reason 'receipt_publisher_output_parent_invalid'
	$EvidenceBytes = Read-PublisherEvidence -Root $EvidenceRoot -ExpectedName $Contract.EvidenceName `
		-ExpectedSha256 $ExpectedEvidenceSha256 -ExpectedSizeBytes $ExpectedEvidenceSizeBytes
	$FullEvidenceRoot = [IO.Path]::GetFullPath((Get-Item -LiteralPath $EvidenceRoot).FullName)
	if (Test-PublisherPathWithin -Candidate $FullOutputRoot -Boundary $FullEvidenceRoot) { throw 'receipt_publisher_path_overlap' }
	if (-not $PSCmdlet.ShouldProcess($FullOutputRoot, 'Create bounded CI acceptance receipt upload root')) { throw 'receipt_publisher_publication_declined' }

	$ReceiptInput = [pscustomobject][ordered]@{
		repository = $Context.repository
		event = $Context.event
		source = $Context.source
		workflow = $Context.workflow
		controller = $Context.controller
		policy = $Context.policy
		actions = $Context.actions
		run = $NormalizedRun
		attemptAnchor = $NormalizedAttemptAnchor
		selection = [pscustomobject][ordered]@{ checks=$Checks }
		results = [pscustomobject][ordered]@{ checks=@($Checks | ForEach-Object {
			[pscustomobject][ordered]@{
				id=$_
				jobName=$JobName
				conclusion='success'
				nativeExitCode=$Contract.NativeExitCode
				infrastructureFailure=$null
				terminal=$true
				cleanupVerified=$Contract.CleanupVerified
				evidence=@([pscustomobject][ordered]@{ name=$Contract.EvidenceName; sha256=$ExpectedEvidenceSha256; sizeBytes=[long]$ExpectedEvidenceSizeBytes })
			}
		}) }
	}

	$WorkRoot = Join-Path $OutputParent ('.ci-acceptance-publisher-' + [guid]::NewGuid().ToString('N') + '.tmp')
	$ArtifactRoot = Join-Path $WorkRoot 'artifact'
	$InputPath = Join-Path $WorkRoot 'input.json'
	$ReceiptPath = Join-Path $ArtifactRoot 'ci-acceptance-receipt.json'
	try {
		[void] (New-Item -ItemType Directory -Path $ArtifactRoot)
		[IO.File]::WriteAllBytes((Join-Path $ArtifactRoot $Contract.EvidenceName), $EvidenceBytes)
		$InputJson = ConvertTo-Json -InputObject $ReceiptInput -Depth 12 -Compress
		[IO.File]::WriteAllText($InputPath, $InputJson + "`n", $script:PublisherUtf8NoBom)

		$ReceiptScriptPath = Join-Path $PSScriptRoot 'New-CiAcceptanceReceipt.ps1'
		Assert-PublisherPathWithoutReparse -Path $ReceiptScriptPath -RequiredType Leaf -Reason 'receipt_publisher_receipt_script_missing'
		& {
			$WhatIfPreference = $false
			$ConfirmPreference = 'None'
			$PSDefaultParameterValues = @{}
			& $ReceiptScriptPath -InputPath $InputPath -EvidenceRoot $ArtifactRoot -OutputPath $ReceiptPath
		}

		if (-not (Test-Path -LiteralPath $ReceiptPath -PathType Leaf)) { throw 'receipt_publisher_receipt_missing' }
		$ReceiptBytes = [IO.File]::ReadAllBytes($ReceiptPath)
		if ($ReceiptBytes.Length -le 0 -or $ReceiptBytes.Length -gt $script:PublisherReceiptLimit) { throw 'receipt_publisher_receipt_limit' }
		try { $Receipt = ConvertFrom-Json -InputObject $script:PublisherUtf8.GetString($ReceiptBytes) }
		catch { throw 'receipt_publisher_receipt_invalid' }
		if ($null -eq $Receipt.acceptance -or $Receipt.acceptance.shadow -isnot [bool] -or -not $Receipt.acceptance.shadow -or
			$Receipt.acceptance.authoritative -isnot [bool] -or $Receipt.acceptance.authoritative -or
			$Receipt.acceptance.grantsAcceptance -isnot [bool] -or $Receipt.acceptance.grantsAcceptance) {
			throw 'receipt_publisher_authority_invalid'
		}
		$PublishedEntries = @(Get-ChildItem -LiteralPath $ArtifactRoot -Force)
		$PublishedNames = (@($PublishedEntries.Name | Sort-Object) -join ',')
		$ExpectedPublishedNames = (@('ci-acceptance-receipt.json', [string] $Contract.EvidenceName) | Sort-Object) -join ','
		if ($PublishedEntries.Count -ne 2 -or @($PublishedEntries | Where-Object { $_.PSIsContainer }).Count -ne 0 -or
			$PublishedNames -cne $ExpectedPublishedNames) {
			throw 'receipt_publisher_output_inventory_invalid'
		}
		[IO.Directory]::Move($ArtifactRoot, $FullOutputRoot)
		return [pscustomobject][ordered]@{
			artifactName=$ExpectedArtifactName
			outputRoot=$FullOutputRoot
			receiptPath=(Join-Path $FullOutputRoot 'ci-acceptance-receipt.json')
			checks=$Checks
			evidenceName=[string]$Contract.EvidenceName
			evidenceSha256=$ExpectedEvidenceSha256
			evidenceSizeBytes=[long]$ExpectedEvidenceSizeBytes
			shadow=$true
			authoritative=$false
			grantsAcceptance=$false
		}
	} finally {
		if (Test-Path -LiteralPath $WorkRoot) { Remove-Item -LiteralPath $WorkRoot -Recurse -Force }
	}
}

if ($ContextPath -or $ProducerKey -or $JobName -or $EvidenceRoot -or $ExpectedEvidenceSha256 -or $ExpectedEvidenceSizeBytes -ge 0 -or $OutputRoot) {
	if (-not $ContextPath -or -not $ProducerKey -or -not $JobName -or -not $EvidenceRoot -or -not $ExpectedEvidenceSha256 -or $ExpectedEvidenceSizeBytes -lt 0 -or -not $OutputRoot) {
		throw 'ContextPath, ProducerKey, JobName, EvidenceRoot, ExpectedEvidenceSha256, ExpectedEvidenceSizeBytes, and OutputRoot are required together.'
	}
	Publish-CiAcceptanceReceipt -ContextPath $ContextPath -ProducerKey $ProducerKey -JobName $JobName -EvidenceRoot $EvidenceRoot `
		-ExpectedEvidenceSha256 $ExpectedEvidenceSha256 -ExpectedEvidenceSizeBytes $ExpectedEvidenceSizeBytes -OutputRoot $OutputRoot | Out-Null
}
