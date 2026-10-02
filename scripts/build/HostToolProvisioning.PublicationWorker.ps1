param(
	[Parameter(Mandatory)][string] $MapName,
	[Parameter(Mandatory)][string] $SupervisorRoot,
	[Parameter(Mandatory)][string] $EvidenceRoot,
	[Parameter(Mandatory)][long] $DeadlineTicks,
	[Parameter(Mandatory)][string] $ResultPath
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'HostToolProvisioning.Policy.ps1')
. (Join-Path $PSScriptRoot 'HostToolProvisioning.Publication.ps1')

try {
	$Map = [IO.MemoryMappedFiles.MemoryMappedFile]::OpenExisting($MapName)
	try {
		$View = $Map.CreateViewAccessor(0, 65540, [IO.MemoryMappedFiles.MemoryMappedFileAccess]::Read)
		try {
			$Length = $View.ReadInt32(0)
			if ($Length -lt 1 -or $Length -gt 65536) { throw 'publication_input_invalid' }
			$Bytes = New-Object byte[] $Length
			$null = $View.ReadArray(4, $Bytes, 0, $Length)
		} finally { $View.Dispose() }
	} finally { $Map.Dispose() }
	$InputReceipt = [Text.Encoding]::UTF8.GetString($Bytes) | ConvertFrom-Json
	if ($InputReceipt.schemaVersion -ne 2 -or $InputReceipt.scope -cne 'bounded_host_tool_provisioning') { throw 'publication_input_invalid' }
	$Receipt = [ordered]@{}
	foreach ($Property in $InputReceipt.PSObject.Properties) { $Receipt[$Property.Name] = $Property.Value }
	$Proof = Publish-HostToolProvisioningReceipts -SupervisorRoot $SupervisorRoot -EvidenceRoot $EvidenceRoot -Receipt $Receipt -DeadlineTicks $DeadlineTicks -ResultPath $ResultPath
	Assert-HostToolPublishedReceiptBytes -SupervisorRoot $SupervisorRoot -EvidenceRoot $EvidenceRoot -DReceiptSha256 $Proof.dReceiptSha256 -FReceiptSha256 $Proof.fReceiptSha256
	$Result = [ordered]@{ schemaVersion = 1; success = $true; dReceiptSha256 = $Proof.dReceiptSha256;
		fReceiptSha256 = $Proof.fReceiptSha256; completedTicks = (Get-InitialPreparationTick);
		deadlineTicks = $DeadlineTicks }
	if ($Result.completedTicks -ge $DeadlineTicks) { throw 'publication_deadline' }
	$null = Write-HostToolProvisioningReceipt -Path $ResultPath -Receipt $Result
	if ((Get-InitialPreparationTick) -ge $DeadlineTicks) { throw 'publication_deadline' }
} catch {
	try {
		$FailurePath = Join-Path $SupervisorRoot 'publication-failed.json'
		if (-not (Test-Path -LiteralPath $FailurePath -PathType Leaf)) {
			$null = Write-HostToolProvisioningReceipt -Path $FailurePath -Receipt ([ordered]@{
				schemaVersion = 1; scope = 'host_tool_receipt_publication'; complete = $false;
				reason = $_.Exception.Message })
		}
	} catch { Write-Warning 'Could not write the D: publication-failed marker.' }
	Write-Error ('publication_worker_failed:' + $_.Exception.Message)
	exit 1
}
