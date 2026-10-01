$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot '../../scripts/build/HostToolProvisioning.Policy.ps1')
function Assert-Checkpoint([bool] $Condition, [string] $Message) { if (-not $Condition) { throw $Message } }
function Assert-CheckpointFailure([scriptblock] $Action, [string] $Reason) {
	$Failure = $null
	try { & $Action | Out-Null } catch { $Failure = $_.Exception.Message; $Stack = $_.ScriptStackTrace }
	Assert-Checkpoint ($Failure -ceq $Reason) "Expected $Reason, observed $Failure at $Stack"
}
$Parent = [IO.Path]::GetTempPath().TrimEnd('\')
$Root = Join-Path $Parent ('AethelnHostCheckpointFixture-' + [guid]::NewGuid().ToString('N'))
$Drive = [IO.Path]::GetPathRoot($Root).Substring(0, 1).ToUpperInvariant()
try {
	$Engine = Join-Path $Root 'engine'
	$Output = Join-Path $Engine 'Engine/Intermediate/Build/Win64'
	$Evidence = Join-Path $Root 'evidence'
	$null = New-Item -ItemType Directory -Path $Output, $Evidence -Force
	$File = Join-Path $Output 'ActionHistory.bin'
	[IO.File]::WriteAllBytes($File, [byte[]] @(1, 2, 3, 4))
	$Header = [pscustomobject]@{ schemaVersion = 2; engineRoot = $Engine; engineRevision = ('a' * 40);
		controllerRevision = ('b' * 40); compilerSha256 = ('c' * 64); resourceCompilerSha256 = ('d' * 64);
		volumeId = 'test-volume'; configurationSha256 = ('e' * 64); attemptOrdinal = 1;
		priorUsefulSeconds = 0; completedTargets = @() }
	$Manifest = Join-Path $Evidence 'generated-output-checkpoint.jsonl'
	$Created = Invoke-HostToolCheckpointFile -Mode Create -EngineRoot $Engine -ManifestPath $Manifest -Header $Header -RequiredDrive $Drive
	Assert-Checkpoint ($Created.fileCount -eq 1 -and $Created.manifestSha256 -cmatch '^[0-9a-f]{64}$') 'Checkpoint creation failed.'
	$Worker = Join-Path $PSScriptRoot '../../scripts/build/HostToolProvisioning.CheckpointWorker.ps1'
	$HeaderBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($Header | ConvertTo-Json -Compress -Depth 15)))
	$WorkerResultPath = Join-Path $Root 'worker-result.json'
	& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Worker -Mode Verify -EngineRoot $Engine -ManifestPath $Manifest -HeaderBase64 $HeaderBase64 -ResultPath $WorkerResultPath -ExpectedManifestSha256 $Created.manifestSha256 -RequiredExternalDrive $Drive -RequiredResultDrive $Drive
	Assert-Checkpoint ($LASTEXITCODE -eq 0) 'Checkpoint worker exit must report verification success.'
	$WorkerResult = Get-Content -LiteralPath $WorkerResultPath -Raw | ConvertFrom-Json
	Assert-Checkpoint ($WorkerResult.success -eq $true -and $WorkerResult.mode -ceq 'Verify' -and
		$WorkerResult.verifiedHeader.engineRevision -ceq $Header.engineRevision) 'Checkpoint worker must return the verified header without a second F: read.'
	$BadWorkerResultPath = Join-Path $Root 'bad-worker-result.json'
	& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Worker -Mode Verify -EngineRoot $Engine -ManifestPath $Manifest -HeaderBase64 $HeaderBase64 -ResultPath $BadWorkerResultPath -ExpectedManifestSha256 ('0' * 64) -RequiredExternalDrive $Drive -RequiredResultDrive $Drive
	Assert-Checkpoint ($LASTEXITCODE -eq 1) 'Changed checkpoint hash must fail in the supervised worker.'
	$BadWorkerResult = Get-Content -LiteralPath $BadWorkerResultPath -Raw | ConvertFrom-Json
	Assert-Checkpoint ($BadWorkerResult.failure -ceq 'resume_checkpoint_hash_mismatch') 'Hash mismatch reason must be retained on the supervisor volume.'
	$IdentityRoot = Join-Path $Root 'identity-engine'
	$IdentitySource = Join-Path $IdentityRoot 'Engine/README.txt'
	$null = New-Item -ItemType Directory -Path (Split-Path -Parent $IdentitySource) -Force
	[IO.File]::WriteAllText($IdentitySource, 'tracked fixture', (New-Object Text.UTF8Encoding($false)))
	& git -C $IdentityRoot init -q
	& git -C $IdentityRoot add -- Engine/README.txt
	& git -C $IdentityRoot -c user.name=Fixture -c user.email=fixture@example.invalid commit -q -m fixture
	Assert-Checkpoint ($LASTEXITCODE -eq 0) 'Identity fixture commit failed.'
	$IdentityWorker = Join-Path $PSScriptRoot '../../scripts/build/HostToolProvisioning.IdentityWorker.ps1'
	$IdentityResultPath = Join-Path $Root 'identity-result.json'
	& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $IdentityWorker -Mode Engine -Root $IdentityRoot -ResultPath $IdentityResultPath -RequiredResultDrive $Drive
	Assert-Checkpoint ($LASTEXITCODE -eq 0) 'Tracked-source identity worker must accept matching bytes.'
	[IO.File]::WriteAllText($IdentitySource, 'tampered fixture', (New-Object Text.UTF8Encoding($false)))
	$IdentityTamperResultPath = Join-Path $Root 'identity-tamper-result.json'
	& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $IdentityWorker -Mode Engine -Root $IdentityRoot -ResultPath $IdentityTamperResultPath -RequiredResultDrive $Drive
	Assert-Checkpoint ($LASTEXITCODE -eq 1) 'Tracked-source identity worker must reject changed bytes.'
	$IdentityTamperResult = Get-Content -LiteralPath $IdentityTamperResultPath -Raw | ConvertFrom-Json
	Assert-Checkpoint ($IdentityTamperResult.failure -ceq 'engine_input_identity_mismatch') 'Identity worker must retain the mismatch reason.'
	$ProductDir = Join-Path $IdentityRoot 'Engine/Binaries/Win64'
	$null = New-Item -ItemType Directory -Path $ProductDir -Force
	[IO.File]::WriteAllBytes((Join-Path $ProductDir 'UnrealPak.exe'), [byte[]] @(1, 2))
	$ProductResultPath = Join-Path $Root 'product-result.json'
	& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $IdentityWorker -Mode Product -Target UnrealPak -Root $IdentityRoot -ResultPath $ProductResultPath -RequiredResultDrive $Drive
	Assert-Checkpoint ($LASTEXITCODE -eq 0) 'Product worker must hash generated products.'
	$ProductResult = Get-Content -LiteralPath $ProductResultPath -Raw | ConvertFrom-Json
	Assert-Checkpoint ($ProductResult.proof.'Engine/Binaries/Win64/UnrealPak.exe'.sha256 -cmatch '^[0-9a-f]{64}$') 'Product worker hash missing.'
	$GitResultPath = Join-Path $Root 'git-result.json'
	& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $IdentityWorker -Mode Git -Root $IdentityRoot -ResultPath $GitResultPath -RequiredResultDrive $Drive
	Assert-Checkpoint ($LASTEXITCODE -eq 0) 'Git state must run in the supervised identity worker.'
	$GitResult = Get-Content -LiteralPath $GitResultPath -Raw | ConvertFrom-Json
	Assert-Checkpoint ($GitResult.proof.head -cmatch '^[0-9a-f]{40}$' -and $GitResult.proof.status -match 'Engine/README.txt') 'Git worker must return head and dirty status.'
	$PriorLogDir = Join-Path $Evidence 'UnrealPak'
	$null = New-Item -ItemType Directory -Path $PriorLogDir
	$PriorLogPath = Join-Path $PriorLogDir 'build.log'
	[IO.File]::WriteAllText($PriorLogPath, 'verified build output', (New-Object Text.UTF8Encoding($false)))
	$PriorLogSha = (Get-FileHash -LiteralPath $PriorLogPath -Algorithm SHA256).Hash.ToLowerInvariant()
	$LogResultPath = Join-Path $Root 'reused-log-result.json'
	& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $IdentityWorker -Mode ReusedLog -Root $Evidence -Target UnrealPak -ExpectedLogSha256 $PriorLogSha -ResultPath $LogResultPath -RequiredResultDrive $Drive
	Assert-Checkpoint ($LASTEXITCODE -eq 0) 'Reused target log must hash in supervised worker.'
	$LogResult = Get-Content -LiteralPath $LogResultPath -Raw | ConvertFrom-Json
	Assert-Checkpoint ($LogResult.proof.path -ceq $PriorLogPath -and $LogResult.proof.sha256 -ceq $PriorLogSha) 'Reused log provenance must be exact.'
	$MissingLog = Join-Path $PriorLogDir 'build.log.missing'
	Move-Item -LiteralPath $PriorLogPath -Destination $MissingLog
	$MissingLogResultPath = Join-Path $Root 'missing-log-result.json'
	& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $IdentityWorker -Mode ReusedLog -Root $Evidence -Target UnrealPak -ExpectedLogSha256 $PriorLogSha -ResultPath $MissingLogResultPath -RequiredResultDrive $Drive
	Assert-Checkpoint ($LASTEXITCODE -eq 1) 'Missing reused log must fail closed.'
	Assert-Checkpoint ((Get-Content -LiteralPath $MissingLogResultPath -Raw | ConvertFrom-Json).failure -ceq 'reused_log_invalid') 'Missing log failure reason must be recorded.'
	Move-Item -LiteralPath $MissingLog -Destination $PriorLogPath
	[IO.File]::WriteAllText($PriorLogPath, 'tampered build output', (New-Object Text.UTF8Encoding($false)))
	$TamperedLogResultPath = Join-Path $Root 'tampered-log-result.json'
	& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $IdentityWorker -Mode ReusedLog -Root $Evidence -Target UnrealPak -ExpectedLogSha256 $PriorLogSha -ResultPath $TamperedLogResultPath -RequiredResultDrive $Drive
	Assert-Checkpoint ($LASTEXITCODE -eq 1) 'Tampered reused log must fail closed.'
	Assert-Checkpoint ((Get-Content -LiteralPath $TamperedLogResultPath -Raw | ConvertFrom-Json).failure -ceq 'reused_log_hash_mismatch') 'Tampered log failure reason must be recorded.'
	[IO.File]::WriteAllText($PriorLogPath, 'verified build output', (New-Object Text.UTF8Encoding($false)))
	$Verified = Invoke-HostToolCheckpointFile -Mode Verify -EngineRoot $Engine -ManifestPath $Manifest -ExpectedHeader $Header -ExpectedManifestSha256 $Created.manifestSha256 -RequiredDrive $Drive
	Assert-Checkpoint ($Verified.engineRevision -ceq $Header.engineRevision) 'Checkpoint verification failed.'
	& {
		function Get-FileHash {
			[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '', Justification = 'Scoped fixture proves checkpoint hashing does not depend on the built-in cmdlet.')]
			param()
			throw 'get_file_hash_unavailable'
		}
		$ModuleFreeManifest = Join-Path $Evidence 'module-free-checkpoint.jsonl'
		$ModuleFreeCreated = Invoke-HostToolCheckpointFile -Mode Create -EngineRoot $Engine -ManifestPath $ModuleFreeManifest -Header $Header -RequiredDrive $Drive
		$ModuleFreeVerified = Invoke-HostToolCheckpointFile -Mode Verify -EngineRoot $Engine -ManifestPath $ModuleFreeManifest -ExpectedHeader $Header -ExpectedManifestSha256 $ModuleFreeCreated.manifestSha256 -RequiredDrive $Drive
		Assert-Checkpoint ($ModuleFreeCreated.fileCount -eq 1 -and $ModuleFreeVerified.engineRevision -ceq $Header.engineRevision) 'Checkpoint Create and Verify must not depend on Get-FileHash module discovery.'
	}
	$Pinned = Invoke-HostToolCheckpointFile -Mode Verify -EngineRoot $Engine -ManifestPath $Manifest -ExpectedHeader $Header -ExpectedManifestSha256 $Created.manifestSha256 -RequiredDrive $Drive
	Assert-Checkpoint ($Pinned.engineRevision -ceq $Header.engineRevision) 'Pinned checkpoint verification failed.'
	Assert-CheckpointFailure { Invoke-HostToolCheckpointFile -Mode Verify -EngineRoot $Engine -ManifestPath $Manifest -ExpectedHeader $Header -ExpectedManifestSha256 ('0' * 64) -RequiredDrive $Drive } 'resume_checkpoint_hash_mismatch'
	$CompletedHeader = $Header.PSObject.Copy()
	$CompletedHeader.completedTargets = @([pscustomobject]@{ target = 'UnrealPak'; result = [pscustomobject]@{
		nativeExitCode = 0; actionCount = 1; progressCount = 1; cleanupVerified = $true;
		productsVerified = $true; logPath = $PriorLogPath; logSha256 = $PriorLogSha }; productState = [ordered]@{} })
	$CompletedManifest = Join-Path $Evidence 'completed-checkpoint.jsonl'
	$CompletedCreated = Invoke-HostToolCheckpointFile -Mode Create -EngineRoot $Engine -ManifestPath $CompletedManifest -Header $CompletedHeader -RequiredDrive $Drive
	$CompletedVerified = Invoke-HostToolCheckpointFile -Mode Verify -EngineRoot $Engine -ManifestPath $CompletedManifest -ExpectedHeader $CompletedHeader -ExpectedManifestSha256 $CompletedCreated.manifestSha256 -RequiredDrive $Drive
	Assert-Checkpoint ($CompletedVerified.completedTargets.Count -eq 1 -and $CompletedVerified.completedTargets[0].target -ceq 'UnrealPak') 'Completed-target prefix must survive checkpoint serialization.'
	$Config1 = Get-HostToolConfigurationSha256 -EngineRoot 'F:\Engine' -UbaRootDir 'F:\UBA' -TempRoot 'F:\Temp' -NativeLogRoot 'F:\Logs'
	$Config2 = Get-HostToolConfigurationSha256 -EngineRoot 'F:\Engine' -UbaRootDir 'F:\UBA' -TempRoot 'F:\Temp' -NativeLogRoot 'F:\OtherLogs'
	Assert-Checkpoint ($Config1 -cmatch '^[0-9a-f]{64}$' -and $Config1 -cne $Config2) 'Native log routing must be bound by configuration identity.'
	$ReceiptPath = Join-Path $Root 'prior-receipt.json'
	$Receipt = [ordered]@{ schemaVersion = 2; scope = 'bounded_host_tool_provisioning'; success = $false;
		failure = 'useful_work_deadline'; leaseReleased = $true; cleanupVerified = $true;
		attemptOrdinal = 1; usefulDeadlineSeconds = 86400; checkpointPath = $Manifest; evidenceRoot = $Evidence;
		checkpointSha256 = $Created.manifestSha256; checkpointFileCount = 1;
		invocations = @([pscustomobject]@{ target = 'UnrealPak'; progressCount = 1 });
		engineRevision = $Header.engineRevision; controllerRevision = $Header.controllerRevision;
		compilerSha256 = $Header.compilerSha256; resourceCompilerSha256 = $Header.resourceCompilerSha256;
		configurationSha256 = $Header.configurationSha256; engineRoot = $Engine; volumeId = $Header.volumeId }
	[IO.File]::WriteAllText($ReceiptPath, ($Receipt | ConvertTo-Json -Compress), (New-Object Text.UTF8Encoding($false)))
	$ReceiptSha = (Get-FileHash -LiteralPath $ReceiptPath -Algorithm SHA256).Hash.ToLowerInvariant()
	$FReceiptPath = Join-Path $Evidence 'host-tool-provisioning-receipt.json'
	$FReceipt = [ordered]@{}
	foreach ($Key in $Receipt.Keys) { $FReceipt[$Key] = $Receipt[$Key] }
	$FReceipt.dReceiptSha256 = $ReceiptSha
	[IO.File]::WriteAllText($FReceiptPath, ($FReceipt | ConvertTo-Json -Compress), (New-Object Text.UTF8Encoding($false)))
	$FReceiptSha = (Get-FileHash -LiteralPath $FReceiptPath -Algorithm SHA256).Hash.ToLowerInvariant()
	$CompletionPath = Join-Path $Root 'publication-complete.json'
	$ResultPath = Join-Path $Root ('publication-result-' + [guid]::NewGuid().ToString('N') + '.json')
	$Result = [ordered]@{ schemaVersion = 1; success = $true; dReceiptSha256 = $ReceiptSha;
		fReceiptSha256 = $FReceiptSha; completedTicks = 900L; deadlineTicks = 1000L }
	[IO.File]::WriteAllText($ResultPath, ($Result | ConvertTo-Json -Compress), (New-Object Text.UTF8Encoding($false)))
	$ResultSha = (Get-FileHash -LiteralPath $ResultPath -Algorithm SHA256).Hash.ToLowerInvariant()
	$ConfirmationPath = Join-Path $Root 'publication-confirmed.json'
	$Confirmation = [ordered]@{ schemaVersion = 1; scope = 'host_tool_supervisor_confirmation'; confirmed = $true;
		resultPath = $ResultPath; resultSha256 = $ResultSha; dReceiptSha256 = $ReceiptSha;
		fReceiptSha256 = $FReceiptSha; confirmedTicks = 950L; deadlineTicks = 1000L }
	[IO.File]::WriteAllText($ConfirmationPath, ($Confirmation | ConvertTo-Json -Compress), (New-Object Text.UTF8Encoding($false)))
	$Completion = [ordered]@{ schemaVersion = 1; scope = 'host_tool_receipt_publication'; complete = $true;
		dReceiptSha256 = $ReceiptSha; fReceiptSha256 = $FReceiptSha; fReceiptPath = $FReceiptPath;
		resultPath = $ResultPath; deadlineTicks = 1000L }
	[IO.File]::WriteAllText($CompletionPath, ($Completion | ConvertTo-Json -Compress), (New-Object Text.UTF8Encoding($false)))
	$Prior = Get-HostToolResumeReceipt -ReceiptPath $ReceiptPath -ExpectedSha256 $ReceiptSha -ExpectedHeader $Header -RequiredReceiptDrive $Drive -RequiredExternalDrive $Drive
	Assert-Checkpoint ($Prior.checkpointSha256 -ceq $Created.manifestSha256) 'Valid first-attempt deadline receipt must be accepted.'
	$MissingConfirmationPath = Join-Path $Root 'publication-confirmed.missing'
	Move-Item -LiteralPath $ConfirmationPath -Destination $MissingConfirmationPath
	[IO.File]::WriteAllText((Join-Path $Root 'publication-confirmed-fixture.tmp'), ($Confirmation | ConvertTo-Json -Compress), (New-Object Text.UTF8Encoding($false)))
	Assert-CheckpointFailure { Get-HostToolResumeReceipt -ReceiptPath $ReceiptPath -ExpectedSha256 $ReceiptSha -ExpectedHeader $Header -RequiredReceiptDrive $Drive -RequiredExternalDrive $Drive } 'resume_publication_invalid'
	Move-Item -LiteralPath $MissingConfirmationPath -Destination $ConfirmationPath
	$Confirmation.confirmedTicks = 1000L
	[IO.File]::WriteAllText($ConfirmationPath, ($Confirmation | ConvertTo-Json -Compress), (New-Object Text.UTF8Encoding($false)))
	Assert-CheckpointFailure { Get-HostToolResumeReceipt -ReceiptPath $ReceiptPath -ExpectedSha256 $ReceiptSha -ExpectedHeader $Header -RequiredReceiptDrive $Drive -RequiredExternalDrive $Drive } 'resume_publication_invalid'
	$Confirmation.confirmedTicks = 950L
	[IO.File]::WriteAllText($ConfirmationPath, ($Confirmation | ConvertTo-Json -Compress), (New-Object Text.UTF8Encoding($false)))
	$MissingResultPath = Join-Path $Root 'publication-result.missing'
	Move-Item -LiteralPath $ResultPath -Destination $MissingResultPath
	Assert-CheckpointFailure { Get-HostToolResumeReceipt -ReceiptPath $ReceiptPath -ExpectedSha256 $ReceiptSha -ExpectedHeader $Header -RequiredReceiptDrive $Drive -RequiredExternalDrive $Drive } 'resume_publication_invalid'
	Move-Item -LiteralPath $MissingResultPath -Destination $ResultPath
	$Result.completedTicks = 1000L
	[IO.File]::WriteAllText($ResultPath, ($Result | ConvertTo-Json -Compress), (New-Object Text.UTF8Encoding($false)))
	Assert-CheckpointFailure { Get-HostToolResumeReceipt -ReceiptPath $ReceiptPath -ExpectedSha256 $ReceiptSha -ExpectedHeader $Header -RequiredReceiptDrive $Drive -RequiredExternalDrive $Drive } 'resume_publication_invalid'
	$Result.completedTicks = 900L
	[IO.File]::WriteAllText($ResultPath, '{invalid', (New-Object Text.UTF8Encoding($false)))
	Assert-CheckpointFailure { Get-HostToolResumeReceipt -ReceiptPath $ReceiptPath -ExpectedSha256 $ReceiptSha -ExpectedHeader $Header -RequiredReceiptDrive $Drive -RequiredExternalDrive $Drive } 'resume_publication_invalid'
	[IO.File]::WriteAllText($ResultPath, ($Result | ConvertTo-Json -Compress), (New-Object Text.UTF8Encoding($false)))
	$Completion.resultPath = Join-Path $Evidence (Split-Path -Leaf $ResultPath)
	[IO.File]::WriteAllText($CompletionPath, ($Completion | ConvertTo-Json -Compress), (New-Object Text.UTF8Encoding($false)))
	Assert-CheckpointFailure { Get-HostToolResumeReceipt -ReceiptPath $ReceiptPath -ExpectedSha256 $ReceiptSha -ExpectedHeader $Header -RequiredReceiptDrive $Drive -RequiredExternalDrive $Drive } 'resume_publication_invalid'
	$Completion.resultPath = $ResultPath
	[IO.File]::WriteAllText($CompletionPath, ($Completion | ConvertTo-Json -Compress), (New-Object Text.UTF8Encoding($false)))
	$MissingCompletionPath = Join-Path $Root 'publication-complete.missing'
	Move-Item -LiteralPath $CompletionPath -Destination $MissingCompletionPath
	Assert-CheckpointFailure { Get-HostToolResumeReceipt -ReceiptPath $ReceiptPath -ExpectedSha256 $ReceiptSha -ExpectedHeader $Header -RequiredReceiptDrive $Drive -RequiredExternalDrive $Drive } 'resume_publication_invalid'
	Move-Item -LiteralPath $MissingCompletionPath -Destination $CompletionPath
	[IO.File]::AppendAllText($FReceiptPath, 'tampered')
	Assert-CheckpointFailure { Get-HostToolResumeReceipt -ReceiptPath $ReceiptPath -ExpectedSha256 $ReceiptSha -ExpectedHeader $Header -RequiredReceiptDrive $Drive -RequiredExternalDrive $Drive } 'resume_publication_invalid'
	[IO.File]::WriteAllText($FReceiptPath, ($FReceipt | ConvertTo-Json -Compress), (New-Object Text.UTF8Encoding($false)))
	$CheckpointSource = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../../scripts/build/HostToolProvisioning.Checkpoint.ps1') -Raw
	$ReceiptVerifierSource = $CheckpointSource.Substring($CheckpointSource.IndexOf('function Get-HostToolResumeReceipt', [StringComparison]::Ordinal))
	Assert-Checkpoint ($ReceiptVerifierSource.Contains('ComputeHash($ReceiptStream)') -and
		$ReceiptVerifierSource.Contains('$ReceiptStream.Position = 0') -and
		-not $ReceiptVerifierSource.Contains('Get-Content -LiteralPath $ReceiptPath')) 'Prior receipt hash and parse must share one pinned read handle.'
	$Receipt.engineRevision = ('9' * 40)
	[IO.File]::WriteAllText($ReceiptPath, ($Receipt | ConvertTo-Json -Compress), (New-Object Text.UTF8Encoding($false)))
	Assert-CheckpointFailure { Get-HostToolResumeReceipt -ReceiptPath $ReceiptPath -ExpectedSha256 $ReceiptSha -ExpectedHeader $Header -RequiredReceiptDrive $Drive -RequiredExternalDrive $Drive } 'resume_receipt_invalid'
	$Receipt.engineRevision = $Header.engineRevision
	[IO.File]::WriteAllText($ReceiptPath, ($Receipt | ConvertTo-Json -Compress), (New-Object Text.UTF8Encoding($false)))
	$Receipt.evidenceRoot = Join-Path $Root 'wrong-evidence'
	[IO.File]::WriteAllText($ReceiptPath, ($Receipt | ConvertTo-Json -Compress), (New-Object Text.UTF8Encoding($false)))
	$WrongEvidenceSha = (Get-FileHash -LiteralPath $ReceiptPath -Algorithm SHA256).Hash.ToLowerInvariant()
	Assert-CheckpointFailure { Get-HostToolResumeReceipt -ReceiptPath $ReceiptPath -ExpectedSha256 $WrongEvidenceSha -ExpectedHeader $Header -RequiredReceiptDrive $Drive -RequiredExternalDrive $Drive } 'resume_receipt_invalid'
	$Receipt.evidenceRoot = $Evidence
	[IO.File]::WriteAllText($ReceiptPath, ($Receipt | ConvertTo-Json -Compress), (New-Object Text.UTF8Encoding($false)))
	$ReceiptSha = (Get-FileHash -LiteralPath $ReceiptPath -Algorithm SHA256).Hash.ToLowerInvariant()
	Assert-CheckpointFailure { Get-HostToolResumeReceipt -ReceiptPath $ReceiptPath -ExpectedSha256 ('0' * 64) -ExpectedHeader $Header -RequiredReceiptDrive $Drive -RequiredExternalDrive $Drive } 'resume_receipt_invalid'
	$WrongReceiptHeader = $Header.PSObject.Copy(); $WrongReceiptHeader.configurationSha256 = ('f' * 64)
	Assert-CheckpointFailure { Get-HostToolResumeReceipt -ReceiptPath $ReceiptPath -ExpectedSha256 $ReceiptSha -ExpectedHeader $WrongReceiptHeader -RequiredReceiptDrive $Drive -RequiredExternalDrive $Drive } 'resume_identity_mismatch'
	$Receipt.invocations = @([pscustomobject]@{ target = 'UnrealPak'; progressCount = 0 })
	[IO.File]::WriteAllText($ReceiptPath, ($Receipt | ConvertTo-Json -Compress), (New-Object Text.UTF8Encoding($false)))
	$NoProgressSha = (Get-FileHash -LiteralPath $ReceiptPath -Algorithm SHA256).Hash.ToLowerInvariant()
	Assert-CheckpointFailure { Get-HostToolResumeReceipt -ReceiptPath $ReceiptPath -ExpectedSha256 $NoProgressSha -ExpectedHeader $Header -RequiredReceiptDrive $Drive -RequiredExternalDrive $Drive } 'resume_no_native_progress'
	$Receipt.invocations = @([pscustomobject]@{ target = 'UnrealPak'; progressCount = 1 })
	foreach ($InvalidState in @(
		@{ attemptOrdinal = 2; failure = 'useful_work_deadline'; cleanupVerified = $true },
		@{ attemptOrdinal = 1; failure = 'native_build_failed'; cleanupVerified = $true },
		@{ attemptOrdinal = 1; failure = 'useful_work_deadline'; cleanupVerified = $false })) {
		$Receipt.attemptOrdinal = $InvalidState.attemptOrdinal
		$Receipt.failure = $InvalidState.failure
		$Receipt.cleanupVerified = $InvalidState.cleanupVerified
		[IO.File]::WriteAllText($ReceiptPath, ($Receipt | ConvertTo-Json -Compress), (New-Object Text.UTF8Encoding($false)))
		$InvalidSha = (Get-FileHash -LiteralPath $ReceiptPath -Algorithm SHA256).Hash.ToLowerInvariant()
		Assert-CheckpointFailure { Get-HostToolResumeReceipt -ReceiptPath $ReceiptPath -ExpectedSha256 $InvalidSha -ExpectedHeader $Header -RequiredReceiptDrive $Drive -RequiredExternalDrive $Drive } 'resume_receipt_invalid'
	}
	$WrongHeader = $Header.PSObject.Copy(); $WrongHeader.volumeId = 'other-volume'
	Assert-CheckpointFailure { Invoke-HostToolCheckpointFile -Mode Verify -EngineRoot $Engine -ManifestPath $Manifest -ExpectedHeader $WrongHeader -ExpectedManifestSha256 $Created.manifestSha256 -RequiredDrive $Drive } 'checkpoint_identity_mismatch'
	[IO.File]::WriteAllBytes($File, [byte[]] @(1, 2, 3, 5))
	Assert-CheckpointFailure { Invoke-HostToolCheckpointFile -Mode Verify -EngineRoot $Engine -ManifestPath $Manifest -ExpectedHeader $Header -ExpectedManifestSha256 $Created.manifestSha256 -RequiredDrive $Drive } 'checkpoint_manifest_mismatch'
	[IO.File]::WriteAllBytes($File, [byte[]] @(1, 2, 3, 4))
	$Extra = Join-Path $Output 'unexpected.obj'
	[IO.File]::WriteAllBytes($Extra, [byte[]] @(9))
	Assert-CheckpointFailure { Invoke-HostToolCheckpointFile -Mode Verify -EngineRoot $Engine -ManifestPath $Manifest -ExpectedHeader $Header -ExpectedManifestSha256 $Created.manifestSha256 -RequiredDrive $Drive } 'checkpoint_manifest_mismatch'
	Remove-Item -LiteralPath $Extra -Force
	foreach ($ProtectedName in @('.env', 'secrets')) {
		$ProtectedDirectory = Join-Path $Output $ProtectedName
		$null = [IO.Directory]::CreateDirectory($ProtectedDirectory)
		try {
			$ProtectedCreateManifest = Join-Path $Evidence ('protected-' + $ProtectedName.TrimStart('.') + '.jsonl')
			Assert-CheckpointFailure { Invoke-HostToolCheckpointFile -Mode Create -EngineRoot $Engine -ManifestPath $ProtectedCreateManifest -Header $Header -RequiredDrive $Drive } 'checkpoint_protected_name'
			Assert-Checkpoint (-not (Test-Path -LiteralPath $ProtectedCreateManifest)) "Protected directory $ProtectedName must be rejected before creating a manifest."
			Assert-CheckpointFailure { Invoke-HostToolCheckpointFile -Mode Verify -EngineRoot $Engine -ManifestPath $Manifest -ExpectedHeader $Header -ExpectedManifestSha256 $Created.manifestSha256 -RequiredDrive $Drive } 'checkpoint_protected_name'
		} finally {
			[IO.Directory]::Delete($ProtectedDirectory)
		}
	}
	$Protected = Join-Path $Output 'signing.pem'
	[IO.File]::WriteAllBytes($Protected, [byte[]] @(9))
	Assert-CheckpointFailure { Invoke-HostToolCheckpointFile -Mode Verify -EngineRoot $Engine -ManifestPath $Manifest -ExpectedHeader $Header -ExpectedManifestSha256 $Created.manifestSha256 -RequiredDrive $Drive } 'checkpoint_protected_name'
} finally {
	if ([IO.Path]::GetFileName($Root) -cnotmatch '^AethelnHostCheckpointFixture-[0-9a-f]{32}$' -or
		-not $Root.StartsWith($Parent + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'checkpoint_fixture_cleanup_invalid' }
	if (Test-Path -LiteralPath $Root) { Remove-Item -LiteralPath $Root -Recurse -Force }
}
'PASS HostToolCheckpoint fixtures'
