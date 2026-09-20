Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../../scripts/ci/InitialPreparation.Core.ps1')
$Module = Join-Path $PSScriptRoot '../../scripts/ci/InitialPreparation.Controller.ps1'
if (-not (Test-Path -LiteralPath $Module)) { throw 'Controller dependency proof missing' }
. $Module
function Write-ControllerFixtureFile {
	param([string] $Path, [string] $Text)
	$Bytes = [Text.Encoding]::UTF8.GetBytes($Text)
	$Stream = [IO.File]::Open($Path, [IO.FileMode]::CreateNew)
	try { $Stream.Write($Bytes, 0, $Bytes.Length) } finally { $Stream.Dispose() }
}
$Root = Join-Path ([IO.Path]::GetTempPath()) ('AethelnController-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path (Join-Path $Root 'scripts/ci')
$Attempt = New-InitialPreparationAttempt -Repository owner/repository -ControllerRevision ('a' * 40) -TargetRevision ('b' * 40) -AttemptId controller-fixture
$Entries = @()
foreach ($Relative in (Get-InitialPreparationControllerPath)) {
	$Path = Join-Path $Root $Relative
	Write-ControllerFixtureFile -Path $Path -Text '# fixture'
	$Entries += [pscustomobject]@{ path = $Relative; sha256 = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant(); bytes = [long] (Get-Item -LiteralPath $Path).Length }
}
foreach ($Mode in @('valid', 'digest', 'missing', 'extra', 'duplicate', 'wrong_revision', 'wrong_size', 'wrong_hash', 'array_hash', 'duplicate_key')) {
	$Manifest = [pscustomobject]@{ schemaVersion = 1; repository = $Attempt.repository; controllerRevision = $Attempt.controllerRevision; files = @($Entries | ForEach-Object { $_.PSObject.Copy() }) }
	if ($Mode -ceq 'missing') { $Manifest.files = @($Manifest.files | Select-Object -Skip 1) }
	if ($Mode -ceq 'extra') { $Manifest.files += [pscustomobject]@{ path = 'scripts/ci/extra.ps1'; sha256 = ('c' * 64); bytes = 1L } }
	if ($Mode -ceq 'duplicate') { $Manifest.files[1] = $Manifest.files[0] }
	if ($Mode -ceq 'wrong_revision') { $Manifest.controllerRevision = 'c' * 40 }
	if ($Mode -ceq 'wrong_size') { $Manifest.files[0].bytes = 1L }
	if ($Mode -ceq 'wrong_hash') { $Manifest.files[0].sha256 = 'c' * 64 }
	if ($Mode -ceq 'array_hash') { $Manifest.files[0].sha256 = @($Manifest.files[0].sha256) }
	$Json = $Manifest | ConvertTo-Json -Depth 5 -Compress
	if ($Mode -ceq 'duplicate_key') { $Json = $Json.Replace('"schemaVersion":1', '"schemaVersion":1,"schemaVersion":1') }
	$ManifestPath = Join-Path $Root ($Mode + '.json')
	Write-ControllerFixtureFile -Path $ManifestPath -Text $Json
	$Digest = (Get-FileHash -LiteralPath $ManifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
	if ($Mode -ceq 'digest') { $Digest = '0' * 64 }
	$Proof = $null; $Failure = $null
	try {
		$Proof = Get-InitialPreparationControllerProof -Root $Root -ManifestPath $ManifestPath -ManifestSha256 $Digest -Attempt $Attempt
		if ($Mode -ceq 'valid') {
			if ($Proof.files.Count -ne $Entries.Count -or $Proof.manifestSha256 -cne $Digest) { throw 'Wrong retained controller identity' }
			foreach ($Protected in @($ManifestPath, (Join-Path $Root $Entries[0].path))) {
				$Denied = $false
				try { $Writer = [IO.File]::Open($Protected, [IO.FileMode]::Open, [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite); $Writer.Dispose() } catch { $Denied = $true }
				if (-not $Denied) { throw 'Controller source writer was not denied' }
			}
		}
	} catch { $Failure = $_.Exception.Message }
	finally { if ($null -ne $Proof) { Close-InitialPreparationControllerProof -Proof $Proof } }
	if ($Mode -ceq 'valid' -and $null -ne $Failure) { throw $Failure }
	if ($Mode -cne 'valid' -and $Failure -cne 'controller_proof_invalid') { throw ('Controller negative case accepted or wrong failure: ' + $Mode + '/' + $Failure) }
	# Failed proof construction must release every handle it acquired.
	$Writer = [IO.File]::Open((Join-Path $Root $Entries[0].path), [IO.FileMode]::Open, [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite)
	$Writer.Dispose()
}
Write-Output ('PASS: complete retained controller dependency proof; evidence ' + $Root)
