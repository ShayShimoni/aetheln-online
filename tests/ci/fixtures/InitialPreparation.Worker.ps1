param([string] $AttemptPath, [string] $EvidenceRoot, [string] $RequestPath, [string] $ControllerManifestSha256, [string] $BuildInvocationSha256)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$Attempt = Get-Content -LiteralPath $AttemptPath -Raw | ConvertFrom-Json
$Marker = [IO.File]::Open((Join-Path $EvidenceRoot 'worker-started'), [IO.FileMode]::CreateNew)
$Marker.Dispose()
if ($Attempt.attemptId -ceq 'native-failure') { exit 7 }
if ($Attempt.attemptId -in @('controller', 'controller-death')) {
	if ($ControllerManifestSha256 -cnotmatch '^[0-9a-f]{64}$') { exit 10 }
	$InvocationPath = Join-Path $PSScriptRoot '../../../scripts/ci/InitialPreparation.BuildInvocation.ps1'
	if ((Get-FileHash -LiteralPath $InvocationPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $BuildInvocationSha256) { exit 14 }
	$Core = Join-Path $PSScriptRoot '../../../scripts/ci/InitialPreparation.Core.ps1'
	$Denied = $false
	try { $Writable = [IO.File]::Open($Core, [IO.FileMode]::Open, [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite); $Writable.Dispose() }
	catch [IO.IOException] { $Denied = $true }
	if (-not $Denied) { exit 11 }
	if ($Attempt.attemptId -ceq 'controller-death') {
		$RequestDirectory = Join-Path (Split-Path -Parent $EvidenceRoot) 'request-source'
		$MovedDirectory = Join-Path (Split-Path -Parent $EvidenceRoot) 'request-source-moved'
		$RenameDenied = $false
		try { [IO.Directory]::Move($RequestDirectory, $MovedDirectory) }
		catch [IO.IOException] { $RenameDenied = $true }
		if (-not $RenameDenied) {
			[IO.Directory]::Move($MovedDirectory, $RequestDirectory)
			exit 12
		}
		[Environment]::Exit(13)
	}
}
if ($Attempt.attemptId -ceq 'request') {
	$Request = Get-Content -LiteralPath $RequestPath -Raw | ConvertFrom-Json
	if ($Request.fixtureValue -ne 42) { exit 8 }
	$Denied = $false
	try { $Writable = [IO.File]::Open($RequestPath, [IO.FileMode]::Open, [IO.FileAccess]::Write); $Writable.Dispose() }
	catch [IO.IOException] { $Denied = $true }
	if (-not $Denied) { exit 9 }
}
if ($Attempt.attemptId -ceq 'deadline') { Start-Sleep -Seconds 60 }
if ($Attempt.attemptId -ceq 'descendant') {
	$Child = Start-Process -FilePath powershell.exe -ArgumentList @('-NoProfile', '-Command', 'Start-Sleep -Seconds 60') -WindowStyle Hidden -PassThru
	try {
		$Identity = [pscustomobject]@{ processId = $Child.Id; creationTicks = $Child.StartTime.ToUniversalTime().Ticks }
		$Bytes = [Text.Encoding]::UTF8.GetBytes(($Identity | ConvertTo-Json -Compress))
		$Stream = [IO.File]::Open((Join-Path $EvidenceRoot 'descendant.json'), [IO.FileMode]::CreateNew)
		try { $Stream.Write($Bytes, 0, $Bytes.Length) } finally { $Stream.Dispose() }
	} finally { $Child.Dispose() }
}
exit 0
