[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../../scripts/ci/InitialPreparation.Core.ps1')
. (Join-Path $PSScriptRoot '../../scripts/ci/InitialPreparation.GitHub.ps1')
. (Join-Path $PSScriptRoot '../../scripts/ci/InitialPreparation.Input.ps1')
function Assert-InputTest {
	param([bool] $Condition, [string] $Message)
	if (-not $Condition) { throw $Message }
}
function Assert-InputRejected {
	param([scriptblock] $Action, [string] $Reason)
	$Failure = $null
	try { & $Action | Out-Null } catch { $Failure = $_.Exception.GetBaseException().Message }
	Assert-InputTest -Condition ($Failure -ceq $Reason) -Message "Expected $Reason; received $Failure"
}
function Invoke-FixtureGit {
	param([string] $Root, [string[]] $Arguments, [AllowNull()][string] $InputText = $null)
	if ([string]::IsNullOrEmpty($InputText)) { $Output = & git -c core.autocrlf=false -C $Root @Arguments 2>&1 } else { $Output = $InputText | & git -c core.autocrlf=false -C $Root @Arguments 2>&1 }
	if ($LASTEXITCODE -ne 0) { throw "Fixture Git failed: $Output" }
	return $Output
}
function Test-InputSizeBatch {
	$BatchAttempt = New-InitialPreparationAttempt -Repository 'owner/repository' -ControllerRevision ('a' * 40) -TargetRevision ('b' * 40) -AttemptId ([guid]::NewGuid().ToString('N'))
	$Ids = @(1..130 | ForEach-Object { '{0:x40}' -f $_ })
	function Invoke-InitialPreparationInputGit {
		param($Root, $Arguments, $Attempt, $OnProgress, $Body)
		Assert-InputTest -Condition ($Root -ceq 'fixture' -and $Arguments -ceq 'cat-file --batch-check' -and $Attempt.attemptId -ceq $BatchAttempt.attemptId -and $OnProgress -is [scriptblock]) -Message 'Batch command contract changed'
		$Requested = $Body.Substring(0, $Body.Length - 1).Split([char]10)
		[void] $BatchState.counts.Add($Requested.Count)
		$Lines = @($Requested | ForEach-Object { $_ + ' blob 12' })
		switch ($BatchState.mode) {
			'type' { $Lines[0] = $Requested[0] + ' tree 12' }
			'missing' { $Lines = @($Lines | Select-Object -Skip 1) }
			'duplicate' { $Lines[-1] = $Lines[0] }
			'extra' { $Lines += ('f' * 40) + ' blob 12' }
			'unknown' { $Lines[0] = ('f' * 40) + ' blob 12' }
			'size' { $Lines[0] = $Requested[0] + ' blob -1' }
		}
		return ($Lines -join "`n") + "`n"
	}
	foreach ($BatchMode in @('valid', 'type', 'missing', 'duplicate', 'extra', 'unknown', 'size')) {
		$BatchState = @{ mode = $BatchMode; counts = (New-Object Collections.ArrayList) }
		if ($BatchMode -ceq 'valid') {
			$Result = Get-InitialPreparationInputBlobSizeMap -Root fixture -BlobIds $Ids -Attempt $BatchAttempt -OnProgress {}
			Assert-InputTest -Condition ($Result.Count -eq 130 -and ($BatchState.counts -join ',') -ceq '128,2') -Message 'Sizes must use exact bounded batches'
		} else {
			Assert-InputRejected -Action { Get-InitialPreparationInputBlobSizeMap -Root fixture -BlobIds $Ids -Attempt $BatchAttempt -OnProgress {} } -Reason 'input_blob_invalid'
		}
	}
}
Test-InputSizeBatch
$FixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('AethelnInputFixture-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $FixtureRoot
foreach ($PathCase in @('Source/.env', 'Source/private.key', 'Config/.gitmodules', 'Content/.lfsconfig')) {
	Assert-InputRejected -Action { Test-InitialPreparationInputPath -Path $PathCase } -Reason 'input_sensitive_or_external_path'
}
foreach ($PathCase in @('Source/CON.cpp', 'Source/trailing.', 'Source/a:b', 'Source/../bad')) {
	Assert-InputRejected -Action { Test-InitialPreparationInputPath -Path $PathCase } -Reason 'input_path_invalid'
}
# Git for Windows refuses reserved-device index entries itself; those path
# cases exercise the production path validator directly above, without
# weakening Git's protections to manufacture the fixture.
foreach ($Case in @('normal', 'tampered', 'missing', 'lfs-pointer', 'lfs-valid', 'symlink-mode', 'case-collision', 'external-root')) {
	$Root = Join-Path $FixtureRoot $Case
	$null = New-Item -ItemType Directory -Path (Join-Path $Root 'Source')
	[IO.File]::WriteAllText((Join-Path $Root 'AethelnOnline.uproject'), '{}', (New-Object Text.UTF8Encoding($false)))
	[IO.File]::WriteAllText((Join-Path $Root 'Source/input.cpp'), "// fixture`n", (New-Object Text.UTF8Encoding($false)))
	$null = Invoke-FixtureGit -Root $Root -Arguments @('init', '--quiet')
	$null = Invoke-FixtureGit -Root $Root -Arguments @('add', '--', 'AethelnOnline.uproject', 'Source/input.cpp')
	if ($Case -in @('lfs-pointer', 'lfs-valid')) {
		$Payload = [Text.Encoding]::UTF8.GetBytes('fixture materialized payload')
		$Hasher = [Security.Cryptography.SHA256]::Create()
		try { $Oid = ([BitConverter]::ToString($Hasher.ComputeHash($Payload))).Replace('-', '').ToLowerInvariant() } finally { $Hasher.Dispose() }
		$Pointer = "version https://git-lfs.github.com/spec/v1`noid sha256:$Oid`nsize $($Payload.Length)`n"
		[IO.File]::WriteAllText((Join-Path $Root 'Source/input.cpp'), $Pointer, (New-Object Text.UTF8Encoding($false)))
		$null = Invoke-FixtureGit -Root $Root -Arguments @('add', '--', 'Source/input.cpp')
	}
	if ($Case -eq 'external-root') {
		[IO.File]::WriteAllText((Join-Path $Root 'AethelnOnline.uproject'), '{"AdditionalRootDirectories":["../outside"]}', (New-Object Text.UTF8Encoding($false)))
		$null = Invoke-FixtureGit -Root $Root -Arguments @('add', '--', 'AethelnOnline.uproject')
	}
	if ($Case -in @('symlink-mode', 'case-collision')) {
		$Blob = [string](Invoke-FixtureGit -Root $Root -Arguments @('hash-object', 'Source/input.cpp'))
		$Mode = if ($Case -eq 'symlink-mode') { '120000' } else { '100644' }
		$TreePath = switch ($Case) { 'symlink-mode' { 'Source/link' }; 'case-collision' { 'Source/INPUT.cpp' } }
		$null = Invoke-FixtureGit -Root $Root -Arguments @('update-index', '--add', '--cacheinfo', "$Mode,$Blob,$TreePath")
	}
	$null = Invoke-FixtureGit -Root $Root -Arguments @('-c', 'user.name=Preparation Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '--quiet', '-m', 'fixture')
	$Revision = [string](Invoke-FixtureGit -Root $Root -Arguments @('rev-parse', 'HEAD'))
	if ($Case -eq 'tampered') { [IO.File]::AppendAllText((Join-Path $Root 'Source/input.cpp'), 'tampered') }
	# Missing fixture keeps its content as a recoverable renamed sibling, not deletion.
	if ($Case -eq 'missing') { [IO.File]::Move((Join-Path $Root 'Source/input.cpp'), (Join-Path $Root 'retained-original.cpp')) }
	if ($Case -eq 'lfs-valid') { [IO.File]::WriteAllBytes((Join-Path $Root 'Source/input.cpp'), $Payload) }
	$Attempt = New-InitialPreparationAttempt -Repository 'owner/repository' -ControllerRevision ('a' * 40) -TargetRevision $Revision -AttemptId ([guid]::NewGuid().ToString('N'))
	$Lease = Enter-InitialPreparationLease -Attempt $Attempt -LeasePath (Join-Path $FixtureRoot ($Case + '.lease'))
	$Proof = $null
	$Progress = @{ count = 0 }
	try {
		$Parameters = @{ Attempt = $Attempt; Lease = $Lease; TargetRoot = $Root; OnProgress = { $Progress.count++ } }
		if ($Case -in @('normal', 'lfs-valid')) {
			$Proof = Get-InitialPreparationInputProof @Parameters
			$Digest = Assert-InitialPreparationInputProof -Proof $Proof -OnProgress { $Progress.count++ }
			Assert-InputTest -Condition ($Digest -ceq $Proof.digest -and $Progress.count -gt 10 -and $Proof.files.Count -eq 2) -Message 'Stable identity/progress missing'
			$WriteDenied = $false
			try { $Writer = [IO.File]::OpenWrite((Join-Path $Root 'Source/input.cpp')); $Writer.Dispose() } catch [IO.IOException] { $WriteDenied = $true }
			Assert-InputTest -Condition $WriteDenied -Message 'Retained input allowed writing'
			$RenameDenied = $false
			try { [IO.Directory]::Move((Join-Path $Root 'Source'), (Join-Path $Root 'renamed-source')) } catch [IO.IOException] { $RenameDenied = $true }
			Assert-InputTest -Condition $RenameDenied -Message 'Retained ancestor allowed rename'
		} elseif ($Case -eq 'missing') {
			Assert-InputRejected -Action { Get-InitialPreparationInputProof @Parameters } -Reason 'input_file_unavailable'
		} else {
			$Reason = @{ tampered = 'input_content_mismatch'; 'lfs-pointer' = 'input_lfs_unhydrated'; 'symlink-mode' = 'input_tree_invalid'; 'case-collision' = 'input_path_collision'; 'external-root' = 'input_external_descriptor_root' }[$Case]
			Assert-InputRejected -Action { Get-InitialPreparationInputProof @Parameters } -Reason $Reason
		}
	} finally {
		if ($null -ne $Proof) {
			Close-InitialPreparationInputProof -Proof $Proof
			Assert-InputRejected -Action { Assert-InitialPreparationInputProof -Proof $Proof -OnProgress {} } -Reason 'input_proof_closed'
		}
		# A successful close AND any failed acquisition must release only their
		# own retained handles; opening without writing checks this directly.
		$Writer = [IO.File]::OpenWrite((Join-Path $Root 'AethelnOnline.uproject'))
		$Writer.Dispose()
		$null = Stop-InitialPreparationOwnedTree -Lease $Lease -DeadlineTicks $Attempt.cleanupDeadlineTicks
		Exit-InitialPreparationLease -Lease $Lease
	}
}
Write-Output "PASS: input proof fixtures; retained $FixtureRoot"
