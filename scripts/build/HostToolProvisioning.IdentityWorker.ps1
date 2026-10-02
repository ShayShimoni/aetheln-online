[CmdletBinding()]
param([Parameter(Mandatory)][ValidateSet('Controller','Engine','Fresh','Receipt','Product','Git','ReusedLog')][string] $Mode,
	[Parameter(Mandatory)][string] $Root,
	[Parameter(Mandatory)][string] $ResultPath,
	[ValidateSet('AethelnOnlineEditor','UnrealPak','ShaderCompileWorker')][string] $Target,
	[string] $ExpectedLogSha256,
	[switch] $IgnoreUntrackedGenerated,
	[string] $ProjectRoot,
	[ValidatePattern('^[A-Z]$')][string] $RequiredResultDrive = 'D')
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'HostToolProvisioning.Policy.ps1')
$Success = $false; $Reason = $null; $Proof = $null
try {
	if ($Root -cnotmatch '^[A-Za-z]:\\' -or $ResultPath -notmatch ('^' + $RequiredResultDrive + ':\\') -or
		(Test-Path -LiteralPath $ResultPath)) { throw 'identity_worker_input_invalid' }
	Assert-InitialPreparationPlainPath -Path $Root -Reason 'identity_worker_input_invalid'
	Assert-InitialPreparationPlainPath -Path $ResultPath -Reason 'identity_worker_input_invalid'
	if (-not [string]::IsNullOrWhiteSpace($ProjectRoot)) {
		if ($ProjectRoot -cnotmatch '^[A-Za-z]:\\') { throw 'identity_worker_input_invalid' }
		Assert-InitialPreparationPlainPath -Path $ProjectRoot -Reason 'identity_worker_input_invalid'
	}
	if ($Mode -ceq 'Controller') { $null = Assert-HostToolControllerInputIdentity -ControllerRoot $Root }
	elseif ($Mode -ceq 'Engine') { $null = Assert-HostToolEngineInputIdentity -EngineRoot $Root }
	elseif ($Mode -ceq 'Receipt') {
		$Targets = if ([string]::IsNullOrWhiteSpace($Target)) { $script:HostToolTargets } else { @($Target) }
		$Proof = Assert-HostToolReceiptSet -EngineRoot $Root -Targets $Targets -ProjectRoot $ProjectRoot
	}
	elseif ($Mode -ceq 'Product') {
		if ([string]::IsNullOrWhiteSpace($Target)) { throw 'identity_worker_input_invalid' }
		$Proof = Get-HostToolProductState -EngineRoot $Root -Target $Target -ProjectRoot $ProjectRoot
	}
	elseif ($Mode -ceq 'ReusedLog') {
		if ([string]::IsNullOrWhiteSpace($Target) -or $ExpectedLogSha256 -cnotmatch '^[0-9a-f]{64}$') { throw 'reused_log_invalid' }
		$LogPath = Join-Path (Join-Path $Root $Target) 'build.log'
		Assert-InitialPreparationPlainPath -Path $LogPath -Reason 'reused_log_invalid'
		if (-not (Test-Path -LiteralPath $LogPath -PathType Leaf)) { throw 'reused_log_invalid' }
		$LogStream = [IO.File]::Open($LogPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
		try {
			$LogSize = [long] $LogStream.Length
			if ($LogSize -lt 1 -or $LogSize -gt 16777216) { throw 'reused_log_invalid' }
			$Hasher = [Security.Cryptography.SHA256]::Create()
			try { $ActualSha = ([BitConverter]::ToString($Hasher.ComputeHash($LogStream))).Replace('-', '').ToLowerInvariant() }
			finally { $Hasher.Dispose() }
		} finally { $LogStream.Dispose() }
		if ($ActualSha -cne $ExpectedLogSha256) { throw 'reused_log_hash_mismatch' }
		$Proof = [pscustomobject]@{ path = $LogPath; sha256 = $ActualSha; sizeBytes = $LogSize }
	}
	elseif ($Mode -ceq 'Git') {
		$Safe = 'safe.directory=' + $Root.Replace('\', '/')
		$Head = @(& git -c $Safe -C $Root rev-parse HEAD 2>$null)
		if ($LASTEXITCODE -ne 0 -or $Head.Count -ne 1) { throw 'git_identity_unavailable' }
		$Status = @(& git -c $Safe -C $Root status --porcelain=v1 --untracked-files=all 2>$null)
		if ($LASTEXITCODE -ne 0 -or $Status.Count -gt 100000) { throw 'git_identity_unavailable' }
		if ($IgnoreUntrackedGenerated) {
			$Status = @($Status | Where-Object {
				$_ -cnotmatch '^\?\? Engine/(Binaries/Win64|Intermediate/Build|Binaries/DotNET/UnrealBuildTool)/' -and
				$_ -cnotmatch '^\?\? Engine/Plugins/.+/(Binaries/Win64|Intermediate/Build|bin|obj)/' -and
				$_ -cnotmatch '^\?\? Engine/Source/Programs/.+/(bin|obj)/'
			})
		}
		$Proof = [pscustomobject]@{ head = [string] $Head[0]; status = ($Status -join "`n") }
	}
	else {
		$Safe = 'safe.directory=' + $Root.Replace('\', '/')
		$Tracked = @(& git -c $Safe -C $Root ls-files --cached -- 'Engine/Build' 'Engine/Binaries/Win64' 'Engine/Binaries/DotNET/UnrealBuildTool' 'Engine/Intermediate/Build' 'Engine/Plugins' 'Engine/Source/Programs' ':(glob)**/*.gitdeps.xml' 2>$null)
		if ($LASTEXITCODE -ne 0 -or $Tracked.Count -lt 1 -or $Tracked.Count -gt 100000) { throw 'fresh_output_unproven' }
		foreach ($Relative in $Tracked) {
			if ($Relative -cnotmatch '^[^/]+/Build/[^/]+\.gitdeps\.xml$' -and
				$Relative -cnotmatch '^[^/]+/Plugins/.+/Build/[^/]+\.gitdeps\.xml$') { continue }
			$ExpectedBlob = [string] (& git -c $Safe -C $Root rev-parse ('HEAD:' + $Relative) 2>$null)
			if ($LASTEXITCODE -ne 0) { throw 'gitdeps_manifest_identity_mismatch' }
			$ActualBlob = [string] (& git -c $Safe -C $Root hash-object -- $Relative 2>$null)
			if ($LASTEXITCODE -ne 0) { throw 'gitdeps_manifest_identity_mismatch' }
			$null = Assert-HostToolGitDependencyManifestIdentity -ExpectedBlob $ExpectedBlob -ActualBlob $ActualBlob
		}
		$Proof = Assert-HostToolFreshOutputState -EngineRoot $Root -TrackedPaths $Tracked
	}
	$Success = $true
} catch { $Reason = $_.Exception.Message }
finally {
	try {
		$Bytes = [Text.Encoding]::UTF8.GetBytes(([ordered]@{ schemaVersion = 1; mode = $Mode; success = $Success; failure = $Reason; proof = $Proof } | ConvertTo-Json -Depth 9 -Compress))
		$Stream = [IO.File]::Open($ResultPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
		try { $Stream.Write($Bytes, 0, $Bytes.Length); $Stream.Flush($true) } finally { $Stream.Dispose() }
	} catch { exit 2 }
}
if (-not $Success) { exit 1 }
exit 0
