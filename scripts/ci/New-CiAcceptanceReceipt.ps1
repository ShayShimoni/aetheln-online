[CmdletBinding()]
param(
	[string] $InputPath,
	[string] $EvidenceRoot,
	[string] $OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:AcceptanceReceiptSchema = 'aetheln.ci-acceptance-receipt/v1'
$script:AcceptanceInputLimit = 64KB
$script:AcceptanceReceiptLimit = 64KB
$script:AcceptanceEvidenceFileLimit = 4MB
$script:AcceptanceEvidenceAggregateLimit = 16MB
$script:AcceptanceResultLimit = 32
$script:AcceptanceEvidenceLimit = 63
$script:AcceptanceEvidencePerResultLimit = 16
$script:AcceptanceUtf8 = New-Object System.Text.UTF8Encoding($false, $true)
$script:AcceptanceUtf8NoBom = New-Object System.Text.UTF8Encoding($false)
$script:AcceptanceCheckIds = @(
	'clean-package-provenance-smoke',
	'content-reference-validation',
	'controller-contract',
	'controller-operational-proof',
	'delivery-harness',
	'native-client-server-compile',
	'portable',
	'unreal-editor-automation',
	'visual-package'
)

function Assert-AcceptanceClosedObject {
	param($Value, [string[]] $PropertyNames)
	if ($null -eq $Value -or $Value -isnot [System.Management.Automation.PSCustomObject]) { throw 'receipt_invalid' }
	$Actual = @($Value.PSObject.Properties | ForEach-Object { $_.Name })
	if ($Actual.Count -ne $PropertyNames.Count) { throw 'receipt_invalid' }
	foreach ($Name in $PropertyNames) { if ($Actual -cnotcontains $Name) { throw 'receipt_invalid' } }
}

function Assert-AcceptanceUniqueJsonProperties {
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'The function validates every property scope in one JSON document.')]
	param([string] $Raw)
	$Scopes = New-Object System.Collections.Stack
	$PendingName = $null
	$Index = 0
	while ($Index -lt $Raw.Length) {
		$Character = $Raw[$Index]
		if ($Character -eq '"') {
			$Builder = New-Object System.Text.StringBuilder
			$Index++
			while ($Index -lt $Raw.Length -and $Raw[$Index] -ne '"') {
				if ($Raw[$Index] -eq '\') {
					[void] $Builder.Append($Raw[$Index]); $Index++
					if ($Index -ge $Raw.Length) { throw 'receipt_json_invalid' }
				}
				[void] $Builder.Append($Raw[$Index]); $Index++
			}
			if ($Index -ge $Raw.Length) { throw 'receipt_json_invalid' }
			try { $PendingName = [string] (ConvertFrom-Json -InputObject ('"' + $Builder.ToString() + '"')) } catch { throw 'receipt_json_invalid' }
			$Index++; continue
		}
		if ($Character -eq '{') {
			$Scopes.Push((New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)))
			$PendingName = $null
		} elseif ($Character -eq '}') {
			if ($Scopes.Count -eq 0) { throw 'receipt_json_invalid' }
			[void] $Scopes.Pop(); $PendingName = $null
		} elseif ($Character -eq ':') {
			if ($null -ne $PendingName -and $Scopes.Count -gt 0 -and -not $Scopes.Peek().Add($PendingName)) { throw 'receipt_json_duplicate_property' }
			$PendingName = $null
		} elseif ($Character -eq ',' -or $Character -eq '[' -or $Character -eq ']') {
			$PendingName = $null
		}
		$Index++
	}
	if ($Scopes.Count -ne 0) { throw 'receipt_json_invalid' }
}

function Read-AcceptanceJson {
	param([string] $Path)
	if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw 'receipt_input_missing' }
	$Item = Get-Item -LiteralPath $Path
	if ($Item.Length -gt $script:AcceptanceInputLimit) { throw 'receipt_input_limit' }
	if (($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'receipt_input_invalid' }
	try {
		$RawBytes = [IO.File]::ReadAllBytes($Item.FullName)
		if ($RawBytes.Length -gt $script:AcceptanceInputLimit) { throw 'receipt_input_limit' }
		$Raw = $script:AcceptanceUtf8.GetString($RawBytes)
	} catch {
		if ($_.Exception.Message -ceq 'receipt_input_limit') { throw }
		throw 'receipt_json_invalid'
	}
	Assert-AcceptanceUniqueJsonProperties -Raw $Raw
	try { return ConvertFrom-Json -InputObject $Raw } catch { throw 'receipt_json_invalid' }
}

function Test-AcceptanceRevision($Value) {
	return $Value -is [string] -and $Value -cmatch '^[0-9a-f]{40}$'
}

function Test-AcceptanceDigest($Value) {
	return $Value -is [string] -and $Value -cmatch '^[0-9a-f]{64}$'
}

function Test-AcceptanceDecimalIdentity($Value) {
	if ($Value -isnot [string] -or $Value -cnotmatch '^[1-9][0-9]{0,18}$') { return $false }
	[long] $Parsed = 0
	return [long]::TryParse($Value, [Globalization.NumberStyles]::None, [Globalization.CultureInfo]::InvariantCulture, [ref] $Parsed) -and $Parsed -gt 0
}

function Get-AcceptanceSha256 {
	param([byte[]] $Bytes)
	$Hash = [Security.Cryptography.SHA256]::Create()
	try { return ([BitConverter]::ToString($Hash.ComputeHash($Bytes))).Replace('-','').ToLowerInvariant() }
	finally { $Hash.Dispose() }
}

function Assert-AcceptanceOrderedUniqueStringSet {
	param($Value, [string[]] $Allowed = $null)
	if ($Value -isnot [Array] -or $Value.Count -lt 1) { throw 'receipt_invalid' }
	$Previous = $null
	foreach ($Entry in $Value) {
		if ($Entry -isnot [string] -or $Entry.Length -lt 1 -or $Entry.Length -gt 128) { throw 'receipt_invalid' }
		if ($null -ne $Allowed -and $Allowed -cnotcontains $Entry) { throw 'receipt_invalid' }
		if ($null -ne $Previous -and [StringComparer]::Ordinal.Compare($Previous, $Entry) -ge 0) { throw 'receipt_invalid' }
		$Previous = $Entry
	}
}

function Test-AcceptanceEvidenceName {
	param($Value)
	if ($Value -isnot [string] -or $Value.Length -lt 1 -or $Value.Length -gt 240 -or
		$Value -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._/-]*$' -or $Value.Contains('//') -or
		$Value.Contains('\') -or $Value.Contains(':') -or $Value.StartsWith('/') -or $Value.EndsWith('/')) { return $false }
	foreach ($Segment in $Value.Split('/')) {
		if ($Segment -in @('.', '..') -or $Segment.EndsWith('.') -or $Segment.EndsWith(' ')) { return $false }
	}
	return $true
}

function Get-AcceptanceEvidenceFile {
	param([string] $Root, [string] $Name)
	if (-not (Test-AcceptanceEvidenceName -Value $Name)) { throw 'receipt_invalid' }
	if (-not (Test-Path -LiteralPath $Root -PathType Container)) { throw 'receipt_evidence_root_invalid' }
	$RootItem = Get-Item -LiteralPath $Root
	if (($RootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'receipt_evidence_root_invalid' }
	$RootFull = [IO.Path]::GetFullPath($RootItem.FullName).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
	$Current = $RootFull
	foreach ($Segment in $Name.Split('/')) {
		$Current = Join-Path -Path $Current -ChildPath $Segment
		if (Test-Path -LiteralPath $Current) {
			$CurrentItem = Get-Item -LiteralPath $Current
			if (($CurrentItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'receipt_evidence_path_invalid' }
		}
	}
	$Full = [IO.Path]::GetFullPath($Current)
	if (-not $Full.StartsWith($RootFull + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -or -not (Test-Path -LiteralPath $Full -PathType Leaf)) { throw 'receipt_evidence_path_invalid' }
	return Get-Item -LiteralPath $Full
}

function New-CiAcceptanceReceipt {
	[CmdletBinding(SupportsShouldProcess)]
	param(
		[Parameter(Mandatory)] [string] $InputPath,
		[Parameter(Mandatory)] [string] $EvidenceRoot,
		[Parameter(Mandatory)] [string] $OutputPath
	)
	if (Test-Path -LiteralPath $OutputPath) { throw 'receipt_exists' }
	if ((Split-Path -Path $OutputPath -Leaf) -cne 'ci-acceptance-receipt.json') { throw 'receipt_output_name_invalid' }
	$ReceiptInput = Read-AcceptanceJson -Path $InputPath
	Assert-AcceptanceClosedObject -Value $ReceiptInput -PropertyNames @('repository','event','source','workflow','controller','policy','actions','run','selection','results')
	Assert-AcceptanceClosedObject -Value $ReceiptInput.repository -PropertyNames @('fullName')
	Assert-AcceptanceClosedObject -Value $ReceiptInput.event -PropertyNames @('kind','classification','actor','triggeringActor')
	Assert-AcceptanceClosedObject -Value $ReceiptInput.source -PropertyNames @('baseRevision','headRevision','testedRevision')
	Assert-AcceptanceClosedObject -Value $ReceiptInput.workflow -PropertyNames @('id','revision','parents','sha256')
	Assert-AcceptanceClosedObject -Value $ReceiptInput.controller -PropertyNames @('revision','blobOid','sha256')
	Assert-AcceptanceClosedObject -Value $ReceiptInput.policy -PropertyNames @('version','digest')
	Assert-AcceptanceClosedObject -Value $ReceiptInput.actions -PropertyNames @('manifestSha256','items')
	Assert-AcceptanceClosedObject -Value $ReceiptInput.run -PropertyNames @('id','attempt')
	Assert-AcceptanceClosedObject -Value $ReceiptInput.selection -PropertyNames @('checks')
	Assert-AcceptanceClosedObject -Value $ReceiptInput.results -PropertyNames @('checks')

	if ($ReceiptInput.repository.fullName -isnot [string] -or $ReceiptInput.repository.fullName -cnotmatch '^[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})/[A-Za-z0-9._-]{1,100}$') { throw 'receipt_invalid' }
	if ($ReceiptInput.event.kind -isnot [string] -or $ReceiptInput.event.classification -isnot [string]) { throw 'receipt_invalid' }
	if (($ReceiptInput.event.kind -ceq 'pull_request' -and $ReceiptInput.event.classification -cne 'pull_request_acceptance') -or
		($ReceiptInput.event.kind -ceq 'push' -and $ReceiptInput.event.classification -cne 'post_merge_hosted_health') -or
		$ReceiptInput.event.kind -cnotin @('pull_request','push')) { throw 'receipt_invalid' }
	foreach ($ActorName in @('actor','triggeringActor')) {
		$Actor = $ReceiptInput.event.$ActorName
		if ($Actor -isnot [string] -or $Actor -cnotmatch '^[A-Za-z0-9][A-Za-z0-9_\-\[\]]{0,99}$') { throw 'receipt_invalid' }
	}
	foreach ($Name in @('baseRevision','headRevision','testedRevision')) { if (-not (Test-AcceptanceRevision -Value $ReceiptInput.source.$Name)) { throw 'receipt_invalid' } }
	if ($ReceiptInput.source.baseRevision -ceq $ReceiptInput.source.headRevision) { throw 'receipt_invalid' }
	if (-not (Test-AcceptanceDecimalIdentity -Value $ReceiptInput.workflow.id) -or
		-not (Test-AcceptanceRevision -Value $ReceiptInput.workflow.revision) -or -not (Test-AcceptanceDigest -Value $ReceiptInput.workflow.sha256)) { throw 'receipt_invalid' }
	if ($ReceiptInput.workflow.parents -isnot [Array] -or $ReceiptInput.workflow.parents.Count -lt 1 -or $ReceiptInput.workflow.parents.Count -gt 2) { throw 'receipt_invalid' }
	foreach ($Parent in $ReceiptInput.workflow.parents) { if (-not (Test-AcceptanceRevision -Value $Parent)) { throw 'receipt_invalid' } }
	if (@($ReceiptInput.workflow.parents | Select-Object -Unique).Count -ne $ReceiptInput.workflow.parents.Count) { throw 'receipt_invalid' }
	if (-not (Test-AcceptanceRevision -Value $ReceiptInput.controller.revision) -or -not (Test-AcceptanceRevision -Value $ReceiptInput.controller.blobOid) -or -not (Test-AcceptanceDigest -Value $ReceiptInput.controller.sha256)) { throw 'receipt_invalid' }
	if ($ReceiptInput.policy.version -isnot [string] -or $ReceiptInput.policy.version -cnotmatch '^[a-z0-9][a-z0-9._-]{0,63}$' -or -not (Test-AcceptanceDigest -Value $ReceiptInput.policy.digest)) { throw 'receipt_invalid' }
	if (-not (Test-AcceptanceDigest -Value $ReceiptInput.actions.manifestSha256) -or $ReceiptInput.actions.items -isnot [Array] -or $ReceiptInput.actions.items.Count -lt 1 -or $ReceiptInput.actions.items.Count -gt 32) { throw 'receipt_invalid' }
	$ActionCopies = New-Object System.Collections.Generic.List[object]
	$ActionLines = New-Object System.Text.StringBuilder
	$PreviousAction = $null
	foreach ($Action in $ReceiptInput.actions.items) {
		Assert-AcceptanceClosedObject -Value $Action -PropertyNames @('uses','revision')
		if ($Action.uses -isnot [string] -or $Action.uses -cnotmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)*$' -or
			-not (Test-AcceptanceRevision -Value $Action.revision) -or
			($null -ne $PreviousAction -and [StringComparer]::Ordinal.Compare($PreviousAction, [string] $Action.uses) -ge 0)) { throw 'receipt_invalid' }
		$PreviousAction = [string] $Action.uses
		[void] $ActionLines.Append([string] $Action.uses).Append('@').Append([string] $Action.revision).Append("`n")
		$ActionCopies.Add([pscustomobject][ordered]@{ uses=[string]$Action.uses; revision=[string]$Action.revision })
	}
	if ((Get-AcceptanceSha256 -Bytes $script:AcceptanceUtf8NoBom.GetBytes($ActionLines.ToString())) -cne $ReceiptInput.actions.manifestSha256) { throw 'receipt_invalid' }
	if (-not (Test-AcceptanceDecimalIdentity -Value $ReceiptInput.run.id) -or $ReceiptInput.run.attempt -isnot [int] -or $ReceiptInput.run.attempt -lt 1) { throw 'receipt_invalid' }

	if ($ReceiptInput.event.kind -ceq 'pull_request') {
		if ($ReceiptInput.source.testedRevision -cne $ReceiptInput.workflow.revision -or $ReceiptInput.controller.revision -cne $ReceiptInput.source.baseRevision -or
			$ReceiptInput.workflow.parents.Count -ne 2 -or $ReceiptInput.workflow.parents[0] -cne $ReceiptInput.source.baseRevision -or $ReceiptInput.workflow.parents[1] -cne $ReceiptInput.source.headRevision) { throw 'receipt_invalid' }
	} else {
		if ($ReceiptInput.source.testedRevision -cne $ReceiptInput.source.headRevision -or $ReceiptInput.workflow.revision -cne $ReceiptInput.source.headRevision -or
			$ReceiptInput.controller.revision -cne $ReceiptInput.source.headRevision -or $ReceiptInput.workflow.parents[0] -cne $ReceiptInput.source.baseRevision) { throw 'receipt_invalid' }
	}

	Assert-AcceptanceOrderedUniqueStringSet -Value $ReceiptInput.selection.checks -Allowed $script:AcceptanceCheckIds
	if ($ReceiptInput.selection.checks.Count -gt $script:AcceptanceCheckIds.Count -or $ReceiptInput.results.checks -isnot [Array] -or
		$ReceiptInput.results.checks.Count -ne $ReceiptInput.selection.checks.Count -or $ReceiptInput.results.checks.Count -gt $script:AcceptanceResultLimit) { throw 'receipt_invalid' }

	$EvidenceNames = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
	$ReceiptJobName = $null
	$EvidenceCount = 0
	$EvidenceBytes = 0L
	$CleanupApplicable = $false
	$ResultCopies = New-Object System.Collections.Generic.List[object]
	for ($Index = 0; $Index -lt $ReceiptInput.results.checks.Count; $Index++) {
		$Result = $ReceiptInput.results.checks[$Index]
		Assert-AcceptanceClosedObject -Value $Result -PropertyNames @('id','jobName','conclusion','nativeExitCode','infrastructureFailure','terminal','cleanupVerified','evidence')
		if ($Result.id -isnot [string] -or $Result.id -cne $ReceiptInput.selection.checks[$Index] -or
			$Result.jobName -isnot [string] -or $Result.jobName.Length -lt 1 -or $Result.jobName.Length -gt 100 -or $Result.jobName -cnotmatch '^[\x20-\x7e]+$' -or
			$Result.conclusion -cne 'success' -or $Result.terminal -isnot [bool] -or -not $Result.terminal -or $null -ne $Result.infrastructureFailure) { throw 'receipt_invalid' }
		if ($null -eq $ReceiptJobName) { $ReceiptJobName = [string] $Result.jobName }
		elseif ([string] $Result.jobName -cne $ReceiptJobName) { throw 'receipt_invalid' }
		if ($null -ne $Result.nativeExitCode -and ($Result.nativeExitCode -isnot [int] -or $Result.nativeExitCode -ne 0)) { throw 'receipt_invalid' }
		$RequiresCleanup = $Result.id -in @('native-client-server-compile','clean-package-provenance-smoke')
		if ($Result.id -in @('native-client-server-compile','clean-package-provenance-smoke') -and ($Result.nativeExitCode -isnot [int] -or $Result.nativeExitCode -ne 0)) { throw 'receipt_invalid' }
		if ($RequiresCleanup) {
			if ($Result.cleanupVerified -isnot [bool] -or -not $Result.cleanupVerified) { throw 'receipt_invalid' }
			$CleanupApplicable = $true
		} elseif ($null -ne $Result.cleanupVerified) { throw 'receipt_invalid' }
		if ($Result.evidence -isnot [Array] -or $Result.evidence.Count -lt 1 -or $Result.evidence.Count -gt $script:AcceptanceEvidencePerResultLimit) { throw 'receipt_invalid' }
		$EvidenceCopies = New-Object System.Collections.Generic.List[object]
		$PreviousEvidenceName = $null
		foreach ($Evidence in $Result.evidence) {
			Assert-AcceptanceClosedObject -Value $Evidence -PropertyNames @('name','sha256','sizeBytes')
			if (-not (Test-AcceptanceEvidenceName -Value $Evidence.name) -or -not (Test-AcceptanceDigest -Value $Evidence.sha256) -or
				$Evidence.sizeBytes -isnot [long] -and $Evidence.sizeBytes -isnot [int]) { throw 'receipt_invalid' }
			$DeclaredSize = [long] $Evidence.sizeBytes
			if ($DeclaredSize -lt 0 -or $DeclaredSize -gt $script:AcceptanceEvidenceFileLimit -or -not $EvidenceNames.Add([string] $Evidence.name)) { throw 'receipt_invalid' }
			if ($null -ne $PreviousEvidenceName -and [StringComparer]::Ordinal.Compare($PreviousEvidenceName, [string] $Evidence.name) -ge 0) { throw 'receipt_invalid' }
			$PreviousEvidenceName = [string] $Evidence.name
			$EvidenceCount++
			$EvidenceBytes += $DeclaredSize
			if ($EvidenceCount -gt $script:AcceptanceEvidenceLimit -or $EvidenceBytes -gt $script:AcceptanceEvidenceAggregateLimit) { throw 'receipt_invalid' }
			$File = Get-AcceptanceEvidenceFile -Root $EvidenceRoot -Name $Evidence.name
			if ($File.Length -ne $DeclaredSize) { throw 'receipt_invalid' }
			$ActualDigest = (Get-FileHash -LiteralPath $File.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
			$After = Get-Item -LiteralPath $File.FullName
			if ($After.Length -ne $DeclaredSize -or $ActualDigest -cne $Evidence.sha256) { throw 'receipt_invalid' }
			$EvidenceCopies.Add([pscustomobject][ordered]@{ name=[string]$Evidence.name; sha256=[string]$Evidence.sha256; sizeBytes=$DeclaredSize })
		}
		$ResultCopies.Add([pscustomobject][ordered]@{
			id=[string]$Result.id; jobName=[string]$Result.jobName; conclusion='success'; nativeExitCode=$Result.nativeExitCode
			infrastructureFailure=$null; terminal=$true; cleanupVerified=$Result.cleanupVerified; evidence=$EvidenceCopies.ToArray()
		})
	}

	$Receipt = [pscustomobject][ordered]@{
		schemaVersion = $script:AcceptanceReceiptSchema
		repository = [pscustomobject][ordered]@{ fullName=[string]$ReceiptInput.repository.fullName }
		event = [pscustomobject][ordered]@{ kind=[string]$ReceiptInput.event.kind; classification=[string]$ReceiptInput.event.classification; actor=[string]$ReceiptInput.event.actor; triggeringActor=[string]$ReceiptInput.event.triggeringActor }
		source = [pscustomobject][ordered]@{ baseRevision=[string]$ReceiptInput.source.baseRevision; headRevision=[string]$ReceiptInput.source.headRevision; testedRevision=[string]$ReceiptInput.source.testedRevision }
		workflow = [pscustomobject][ordered]@{ id=[string]$ReceiptInput.workflow.id; revision=[string]$ReceiptInput.workflow.revision; parents=@($ReceiptInput.workflow.parents); sha256=[string]$ReceiptInput.workflow.sha256 }
		controller = [pscustomobject][ordered]@{ revision=[string]$ReceiptInput.controller.revision; blobOid=[string]$ReceiptInput.controller.blobOid; sha256=[string]$ReceiptInput.controller.sha256 }
		policy = [pscustomobject][ordered]@{ version=[string]$ReceiptInput.policy.version; digest=[string]$ReceiptInput.policy.digest }
		actions = [pscustomobject][ordered]@{ manifestSha256=[string]$ReceiptInput.actions.manifestSha256; items=$ActionCopies.ToArray() }
		run = [pscustomobject][ordered]@{ id=[string]$ReceiptInput.run.id; attempt=[int]$ReceiptInput.run.attempt }
		selection = [pscustomobject][ordered]@{ checks=@($ReceiptInput.selection.checks) }
		results = [pscustomobject][ordered]@{ checks=$ResultCopies.ToArray() }
		acceptance = [pscustomobject][ordered]@{ shadow=$true; authoritative=$false; grantsAcceptance=$false; terminal=$true; infrastructureFailure=$false; cleanupVerified=$(if ($CleanupApplicable) { $true } else { $null }) }
	}
	$Json = ConvertTo-Json -InputObject $Receipt -Depth 12 -Compress
	$Bytes = $script:AcceptanceUtf8NoBom.GetBytes($Json + "`n")
	if ($Bytes.Length -gt $script:AcceptanceReceiptLimit) { throw 'receipt_output_limit' }
	if (-not $PSCmdlet.ShouldProcess($OutputPath, 'Create CI acceptance receipt')) { throw 'receipt_publication_declined' }
	$Parent = Split-Path -Path $OutputPath -Parent
	if ([string]::IsNullOrWhiteSpace($Parent)) { $Parent = (Get-Location).Path }
	if (-not (Test-Path -LiteralPath $Parent -PathType Container)) { [void] (New-Item -ItemType Directory -Path $Parent -Force) }
	$Temporary = Join-Path -Path $Parent -ChildPath ('.ci-acceptance-receipt-' + [guid]::NewGuid().ToString('N') + '.tmp')
	try {
		[IO.File]::WriteAllBytes($Temporary, $Bytes)
		[IO.File]::Move($Temporary, [IO.Path]::GetFullPath($OutputPath))
	} finally {
		if (Test-Path -LiteralPath $Temporary) { Remove-Item -LiteralPath $Temporary -Force }
	}
	return $Receipt
}

if ($InputPath -or $EvidenceRoot -or $OutputPath) {
	if (-not $InputPath -or -not $EvidenceRoot -or -not $OutputPath) { throw 'InputPath, EvidenceRoot, and OutputPath are required together.' }
	New-CiAcceptanceReceipt -InputPath $InputPath -EvidenceRoot $EvidenceRoot -OutputPath $OutputPath | Out-Null
}
