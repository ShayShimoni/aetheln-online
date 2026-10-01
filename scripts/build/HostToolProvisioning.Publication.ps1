# Definition-only publication helpers used by the D: supervisor and its bounded child.
function Write-HostToolProvisioningReceipt {
	param([string] $Path, $Receipt, [switch] $PassThruSha256)
	$Bytes = [Text.Encoding]::UTF8.GetBytes(($Receipt | ConvertTo-Json -Depth 9 -Compress))
	if ($Bytes.Length -lt 1 -or $Bytes.Length -gt 65536) { throw 'receipt_limit' }
	$Stream = [IO.File]::Open($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
	try { $Stream.Write($Bytes, 0, $Bytes.Length); $Stream.Flush($true) } finally { $Stream.Dispose() }
	if ($PassThruSha256) {
		$Hasher = [Security.Cryptography.SHA256]::Create()
		try { return ([BitConverter]::ToString($Hasher.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant() }
		finally { $Hasher.Dispose() }
	}
}

function Write-HostToolResourceFailureReceipt {
	[CmdletBinding()]
	param([Parameter(Mandatory)][string] $Path, [Parameter(Mandatory)][string] $StartedUtc,
		[Parameter(Mandatory)][ValidateSet('resource_pressure')][string] $ResourceFailure,
		[AllowNull()][string] $PrePublicationFailure,
		[Parameter(Mandatory)] $ResourceMonitor, [bool] $CleanupVerified, [bool] $LeaseReleased)
	if (Test-Path -LiteralPath $Path) { throw 'resource_failure_receipt_exists' }
	Assert-InitialPreparationPlainPath -Path $Path -Reason 'resource_failure_receipt_path_invalid'
	$Proof = Get-RoutineCompileResourceProof -Monitor $ResourceMonitor
	$Receipt = [ordered]@{ schemaVersion = 1; scope = 'host_tool_resource_failure';
		startedUtc = $StartedUtc; finishedUtc = [DateTime]::UtcNow.ToString('o');
		resourceFailure = $ResourceFailure; prePublicationFailure = $PrePublicationFailure;
		monitorFailure = $Proof.failureReason;
		cleanupVerified = $CleanupVerified; leaseReleased = $LeaseReleased;
		resumeAuthorized = $false; sampleCount = $Proof.sampleCount;
		lastAvailableRamBytes = $ResourceMonitor.lastAvailableRamBytes;
		lastCommitHeadroomBytes = $ResourceMonitor.lastCommitHeadroomBytes;
		minimumAvailableRamBytes = $Proof.minimumAvailableRamBytes;
		minimumCommitHeadroomBytes = $Proof.minimumCommitHeadroomBytes }
	$null = Write-HostToolProvisioningReceipt -Path $Path -Receipt $Receipt
	return [pscustomobject] $Receipt
}

function Write-HostToolResourceFailureReceiptIfNeeded {
	[CmdletBinding()]
	[OutputType([bool])]
	param([Parameter(Mandatory)][string] $Path, [Parameter(Mandatory)][string] $StartedUtc,
		[AllowNull()][string] $PrePublicationFailure, $ResourceMonitor,
		[bool] $CleanupVerified, [bool] $LeaseReleased)
	if ($null -eq $ResourceMonitor -or $ResourceMonitor.failureReason -cne 'resource_pressure') { return $false }
	$null = Write-HostToolResourceFailureReceipt -Path $Path -StartedUtc $StartedUtc `
		-ResourceFailure 'resource_pressure' -PrePublicationFailure $PrePublicationFailure `
		-ResourceMonitor $ResourceMonitor -CleanupVerified $CleanupVerified -LeaseReleased $LeaseReleased
	return $true
}

function Assert-HostToolPublicationDeadline {
	param([long] $DeadlineTicks, [scriptblock] $ReadTicks)
	if ((& $ReadTicks) -ge $DeadlineTicks) { throw 'publication_deadline' }
}

function Assert-HostToolPublishedReceiptBytes {
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'The publication worker calls this existing function name.')]
	param([string] $SupervisorRoot, [string] $EvidenceRoot, [string] $DReceiptSha256, [string] $FReceiptSha256)
	try {
		$DPublished = Read-HostToolPublicationJson -Path (Join-Path $SupervisorRoot 'host-tool-provisioning-receipt.json') -ExpectedSha256 $DReceiptSha256
		$FPublished = Read-HostToolPublicationJson -Path (Join-Path $EvidenceRoot 'host-tool-provisioning-receipt.json') -ExpectedSha256 $FReceiptSha256
		if ($DPublished.data.schemaVersion -ne 2 -or $DPublished.data.scope -cne 'bounded_host_tool_provisioning' -or
			$FPublished.data.schemaVersion -ne 2 -or $FPublished.data.scope -cne 'bounded_host_tool_provisioning' -or
			$FPublished.data.dReceiptSha256 -cne $DReceiptSha256) { throw 'publication_receipt_mismatch' }
	} catch { throw 'publication_receipt_mismatch' }
}

function Publish-HostToolProvisioningReceipts {
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'The publication worker calls this existing function name.')]
	param([string] $SupervisorRoot, [string] $EvidenceRoot, [Collections.IDictionary] $Receipt,
		[long] $DeadlineTicks = [long]::MaxValue, [scriptblock] $ReadTicks = { Get-InitialPreparationTick },
		[string] $ResultPath)
	Assert-HostToolPublicationDeadline -DeadlineTicks $DeadlineTicks -ReadTicks $ReadTicks
	$null = Write-HostToolProvisioningReceipt -Path (Join-Path $SupervisorRoot 'publication-pending.json') -Receipt ([ordered]@{
		schemaVersion = 1; scope = 'host_tool_receipt_publication'; complete = $false;
		startedUtc = $Receipt.startedUtc; reason = 'publication_not_yet_confirmed' })
	$Receipt.publicationRequiresFReceipt = $true
	$DReceiptPath = Join-Path $SupervisorRoot 'host-tool-provisioning-receipt.json'
	$FReceiptPath = Join-Path $EvidenceRoot 'host-tool-provisioning-receipt.json'
	$DSha = $null; $FSha = $null
	try {
		Assert-HostToolPublicationDeadline -DeadlineTicks $DeadlineTicks -ReadTicks $ReadTicks
		$DSha = Write-HostToolProvisioningReceipt -Path $DReceiptPath -Receipt $Receipt -PassThruSha256
		Assert-HostToolPublicationDeadline -DeadlineTicks $DeadlineTicks -ReadTicks $ReadTicks
		$FReceipt = [ordered]@{}
		foreach ($Key in $Receipt.Keys) { $FReceipt[$Key] = $Receipt[$Key] }
		$FReceipt.dReceiptSha256 = $DSha
		$FSha = Write-HostToolProvisioningReceipt -Path $FReceiptPath -Receipt $FReceipt -PassThruSha256
		Assert-HostToolPublicationDeadline -DeadlineTicks $DeadlineTicks -ReadTicks $ReadTicks
		$null = Write-HostToolProvisioningReceipt -Path (Join-Path $SupervisorRoot 'publication-complete.json') -Receipt ([ordered]@{
			schemaVersion = 1; scope = 'host_tool_receipt_publication'; complete = $true;
			dReceiptSha256 = $DSha; fReceiptSha256 = $FSha; fReceiptPath = $FReceiptPath;
			resultPath = $ResultPath; deadlineTicks = $DeadlineTicks })
		Assert-HostToolPublicationDeadline -DeadlineTicks $DeadlineTicks -ReadTicks $ReadTicks
	} catch {
		$Reason = if ($_.Exception.Message -ceq 'publication_deadline') { 'publication_deadline' }
			elseif ($null -eq $DSha) { 'd_receipt_publication_failed' }
			elseif ($null -eq $FSha) { 'f_receipt_publication_failed' }
			else { 'publication_completion_failed' }
		try {
			$null = Write-HostToolProvisioningReceipt -Path (Join-Path $SupervisorRoot 'publication-failed.json') -Receipt ([ordered]@{
				schemaVersion = 1; scope = 'host_tool_receipt_publication'; complete = $false;
				reason = $Reason; dReceiptSha256 = $DSha; fReceiptSha256 = $FSha })
		} catch { Write-Warning 'Could not write the D: publication-failed marker; the pending marker still denies completion.' }
		throw $Reason
	}
	return [pscustomobject]@{ dReceiptSha256 = $DSha; fReceiptSha256 = $FSha }
}

function Assert-HostToolPublicationResult {
	param([string] $SupervisorRoot, [string] $ResultPath, [long] $DeadlineTicks)
	if ((Test-Path -LiteralPath (Join-Path $SupervisorRoot 'publication-failed.json') -PathType Leaf) -or
		-not (Test-Path -LiteralPath $ResultPath -PathType Leaf) -or
		-not (Test-Path -LiteralPath (Join-Path $SupervisorRoot 'publication-complete.json') -PathType Leaf)) { throw 'publication_proof_invalid' }
	try {
		$PinnedResult = Read-HostToolPublicationJson -Path $ResultPath -MaxBytes 4096
		$Result = $PinnedResult.data
		$Complete = (Read-HostToolPublicationJson -Path (Join-Path $SupervisorRoot 'publication-complete.json') -MaxBytes 4096).data
	} catch { throw 'publication_proof_invalid' }
	if ($Result.schemaVersion -ne 1 -or $Result.success -ne $true -or
		$Result.deadlineTicks -ne $DeadlineTicks -or $Result.completedTicks -ge $DeadlineTicks -or
		$Complete.complete -ne $true -or $Complete.deadlineTicks -ne $DeadlineTicks -or
		$Complete.resultPath -cne $ResultPath -or
		$Complete.dReceiptSha256 -cne $Result.dReceiptSha256 -or
		$Complete.fReceiptSha256 -cne $Result.fReceiptSha256) { throw 'publication_proof_invalid' }
	$Result | Add-Member -NotePropertyName resultSha256 -NotePropertyValue $PinnedResult.sha256 -Force
	return $Result
}
