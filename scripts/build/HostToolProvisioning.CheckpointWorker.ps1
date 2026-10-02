[CmdletBinding()]
param(
	[Parameter(Mandatory)][ValidateSet('Create', 'Verify')][string] $Mode,
	[Parameter(Mandatory)][string] $EngineRoot,
	[Parameter(Mandatory)][string] $ManifestPath,
	[Parameter(Mandatory)][string] $HeaderBase64,
	[Parameter(Mandatory)][string] $ResultPath,
	[string] $ExpectedManifestSha256,
	[ValidatePattern('^[A-Z]$')][string] $RequiredExternalDrive = 'F',
	[ValidatePattern('^[A-Z]$')][string] $RequiredResultDrive = 'D'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'HostToolProvisioning.Policy.ps1')
$Success = $false
$Reason = $null
try {
	if ((Test-Path -LiteralPath $ResultPath) -or $ResultPath -notmatch ('^' + $RequiredResultDrive + ':\\') -or
		$HeaderBase64.Length -gt 24000) { throw 'checkpoint_worker_input_invalid' }
	Assert-InitialPreparationPlainPath -Path $ResultPath -Reason 'checkpoint_worker_input_invalid'
	$HeaderText = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($HeaderBase64))
	$Header = $HeaderText | ConvertFrom-Json
	if ($Mode -ceq 'Create') {
		if (-not [string]::IsNullOrWhiteSpace($ExpectedManifestSha256)) { throw 'checkpoint_worker_input_invalid' }
		$Proof = Invoke-HostToolCheckpointFile -Mode Create -EngineRoot $EngineRoot -ManifestPath $ManifestPath -Header $Header -RequiredDrive $RequiredExternalDrive
	} else {
		$Proof = Invoke-HostToolCheckpointFile -Mode Verify -EngineRoot $EngineRoot -ManifestPath $ManifestPath -ExpectedHeader $Header -ExpectedManifestSha256 $ExpectedManifestSha256 -RequiredDrive $RequiredExternalDrive
	}
	$Success = $true
} catch { $Reason = $_.Exception.Message }
finally {
	try {
		$Bytes = [Text.Encoding]::UTF8.GetBytes(([ordered]@{ schemaVersion = 1; mode = $Mode; success = $Success;
			failure = $Reason; fileCount = $(if ($Success -and $Mode -ceq 'Create') { $Proof.fileCount } else { $null });
			manifestSha256 = $(if ($Success -and $Mode -ceq 'Create') { $Proof.manifestSha256 } else { $null });
			verifiedHeader = $(if ($Success -and $Mode -ceq 'Verify') { $Proof } else { $null }) } | ConvertTo-Json -Depth 15 -Compress))
		$Stream = [IO.File]::Open($ResultPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
		try { $Stream.Write($Bytes, 0, $Bytes.Length); $Stream.Flush($true) } finally { $Stream.Dispose() }
	} catch { exit 2 }
}
if (-not $Success) { exit 1 }
exit 0
