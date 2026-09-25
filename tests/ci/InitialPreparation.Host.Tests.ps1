Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$Module = Join-Path $PSScriptRoot '../../scripts/ci/InitialPreparation.Host.ps1'
if (-not (Test-Path -LiteralPath $Module)) { throw 'Compile host proof implementation missing' }
. $Module
function Assert-HostFixture {
	param([bool] $Condition, [string] $Message)
	if (-not $Condition) { throw $Message }
}
function Test-PublishedNativeAsset {
	$Attempt = New-InitialPreparationAttempt -Repository 'ShayShimoni/aetheln-online' -ControllerRevision ('a' * 40) -TargetRevision ('b' * 40) -AttemptId ('host-assets-' + [guid]::NewGuid().ToString('N'))
	$Failures = New-Object Collections.ArrayList
	foreach ($Case in @(
		@{ path = 'runtimes/browser-wasm/nativeassets/net9.0/e_sqlite3.a'; allowed = $true },
		@{ path = 'runtimes/linux-x64/native/UbaStaticStub.bin'; allowed = $true },
		@{ path = 'runtimes/browser-wasm/nativeassets/net9.0/unknown.a'; allowed = $false },
		@{ path = 'runtimes/linux-x64/native/unknown.bin'; allowed = $false },
		@{ path = 'elsewhere/e_sqlite3.a'; allowed = $false },
		@{ path = 'elsewhere/UbaStaticStub.bin'; allowed = $false })) {
		$Root = Join-Path ([IO.Path]::GetTempPath()) ('AethelnHostAsset-' + [guid]::NewGuid().ToString('N'))
		$Path = Join-Path $Root $Case.path
		$null = New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force
		$Stream = [IO.File]::Open($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write)
		try { $Stream.WriteByte(1) } finally { $Stream.Dispose() }
		$Failure = $null; $Inventory = $null
		try { $Inventory = Get-InitialPreparationHostInventory -PublishRoot $Root -Attempt $Attempt -OnProgress {} } catch { $Failure = $_.Exception.Message }
		if ($Case.allowed) {
			if ($null -ne $Failure -or @($Inventory).Count -ne 1 -or $Inventory[0] -cne [IO.Path]::GetFullPath($Path)) { [void] $Failures.Add($Case.path + ': ' + $Failure) }
		} elseif ($Failure -cne 'host_input_path_invalid') { [void] $Failures.Add('Unexpected asset accepted: ' + $Case.path) }
	}
	Assert-HostFixture -Condition ($Failures.Count -eq 0) -Message ('Native published asset policy failed: ' + ($Failures -join '; '))
}
Test-PublishedNativeAsset
function Test-HostProof {
	function Assert-InitialPreparationInputLease { param($Attempt, $Lease) if ($Lease.leaseId -cne 'fixture' -or $Attempt.attemptId -cne 'fixture') { throw 'input_lease_invalid' } }
	function Invoke-InitialPreparationInputProgress { param($Attempt, $OnProgress) if ($Attempt.attemptId -cne 'fixture') { throw 'fixture_attempt_invalid' }; & $OnProgress | Out-Null }
	function Get-InitialPreparationCheckoutIdentity { param($Root, $ExpectedRevision) if (-not (Test-Path -LiteralPath $Root)) { throw 'fixture_root_missing' }; return [pscustomobject]@{ revision = $ExpectedRevision; clean = $State.clean } }
	$Root = Join-Path ([IO.Path]::GetTempPath()) ('AethelnHostFixture-' + [guid]::NewGuid().ToString('N'))
	$Engine = Join-Path $Root 'engine'
	$Linux = Join-Path $Root 'v26_clang-20.1.8-rockylinux8'
	$Compiler = Join-Path $Root 'VS/VC/Tools/MSVC/14.44.35207/bin/Hostx64/x64/cl.exe'
	$ResourceCompiler = Join-Path $Root 'SDK/bin/10.0.26100.0/x64/rc.exe'
	$Names = @('Engine/Binaries/DotNET/UnrealBuildTool/UnrealBuildTool.dll', 'Engine/Binaries/DotNET/UnrealBuildTool/EpicGames.UHT.dll',
		'Engine/Binaries/DotNET/UnrealBuildTool/UnrealBuildTool.deps.json', 'Engine/Binaries/DotNET/UnrealBuildTool/UnrealBuildTool.runtimeconfig.json',
		'Engine/Binaries/DotNET/UnrealBuildTool/runtimes/win-x64/native/fixture.dll', 'Engine/Binaries/ThirdParty/DotNet/10.0/win-x64/dotnet.exe',
		'Engine/Binaries/DotNET/UnrealBuildTool/runtimes/browser-wasm/nativeassets/net9.0/e_sqlite3.a', 'Engine/Binaries/DotNET/UnrealBuildTool/runtimes/linux-x64/native/UbaStaticStub.bin',
		'Engine/Build/BatchFiles/Build.bat', 'Engine/Build/BatchFiles/BuildUBT.bat', 'Engine/Build/BatchFiles/GetDotnetPath.bat', 'Engine/Build/BatchFiles/DotnetDepends.bat')
	$Files = @($Names | ForEach-Object { Join-Path $Engine $_ }) + @($Compiler, (Join-Path (Split-Path -Parent $Compiler) 'link.exe'), $ResourceCompiler,
		(Join-Path $Linux 'ToolchainVersion.txt'), (Join-Path $Linux 'x86_64-unknown-linux-gnu/bin/clang++.exe'),
		(Join-Path $Linux 'x86_64-unknown-linux-gnu/bin/ld.lld.exe'), (Join-Path $Linux 'x86_64-unknown-linux-gnu/usr/include/stdio.h'))
	foreach ($File in $Files) {
		$null = New-Item -ItemType Directory -Path (Split-Path -Parent $File) -Force
		$Stream = [IO.File]::Open($File, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
		try {
			$Content = if ([IO.Path]::GetFileName($File) -ceq 'ToolchainVersion.txt') { 'v26_clang-20.1.8-rockylinux8' } else { 'fixture' }
			$Bytes = [Text.Encoding]::UTF8.GetBytes($Content); $Stream.Write($Bytes, 0, $Bytes.Length)
		} finally { $Stream.Dispose() }
	}
	$State = @{ clean = $true; ticks = 0 }
	$HostParameters = @{ Attempt = [pscustomobject]@{ attemptId = 'fixture'; targetRevision = ('a' * 40) }; Lease = [pscustomobject]@{ leaseId = 'fixture' };
		EngineRoot = $Engine; LinuxToolchainRoot = $Linux; CompilerPath = $Compiler; ResourceCompilerPath = $ResourceCompiler;
		OnProgress = { $State.ticks++ } }
	$Proof = Get-InitialPreparationHostProof @HostParameters
	try {
		Assert-HostFixture -Condition ($Proof.scope -ceq 'compile_host_file_identity' -and $Proof.consumptionVerified -eq $false -and $Proof.baselineVerified -eq $false) -Message 'Overclaimed readiness'
		Assert-HostFixture -Condition ($Proof.records.Count -eq $Files.Count + 1 -and $Proof.digest -cmatch '^[0-9a-f]{64}$' -and $State.ticks -gt 0) -Message 'Incomplete closure or progress'
		Assert-HostFixture -Condition ((Assert-InitialPreparationHostProof -Proof $Proof -OnProgress $HostParameters.OnProgress) -ceq $Proof.digest) -Message 'Valid proof rejected'
		Assert-HostFixture -Condition (Assert-InitialPreparationHostReadiness -Proof $Proof -ExpectedInvocationSha256 $Proof.invocationSha256 -OnProgress $HostParameters.OnProgress) -Message 'Reviewed invocation was not usable for prelaunch gate'
		$Caught = $false
		try { $null = Assert-InitialPreparationHostReadiness -Proof $Proof -ExpectedInvocationSha256 ('0' * 64) -OnProgress $HostParameters.OnProgress } catch { $Caught = $_.Exception.Message -ceq 'host_invocation_identity_mismatch' }
		Assert-HostFixture -Condition $Caught -Message 'Different reviewed invocation accepted'
		$Denied = $false
		try { $Write = [IO.File]::Open($Files[0], [IO.FileMode]::Open, [IO.FileAccess]::Write); $Write.Dispose() } catch [IO.IOException] { $Denied = $true }
		Assert-HostFixture -Condition $Denied -Message 'Published input write not denied'
		$Extra = Join-Path $Engine 'Engine/Binaries/DotNET/UnrealBuildTool/added.dll'
		$Stream = [IO.File]::Open($Extra, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write); $Stream.WriteByte(1); $Stream.Dispose()
		$Caught = $false
		try { $null = Assert-InitialPreparationHostProof -Proof $Proof -OnProgress $HostParameters.OnProgress } catch { $Caught = $_.Exception.Message -ceq 'host_input_inventory_changed' }
		Assert-HostFixture -Condition $Caught -Message 'New published file accepted'
	} finally { Close-InitialPreparationHostProof -Proof $Proof }
	$Caught = $false
	try { $null = Assert-InitialPreparationHostProof -Proof $Proof -OnProgress $HostParameters.OnProgress } catch { $Caught = $_.Exception.Message -ceq 'host_proof_closed' }
	Assert-HostFixture -Condition $Caught -Message 'Closed proof accepted'
	$State.clean = $false
	$Caught = $false
	try { $null = Get-InitialPreparationHostProof @HostParameters } catch { $Caught = $_.Exception.Message -ceq 'host_engine_identity_invalid' }
	Assert-HostFixture -Condition $Caught -Message 'Dirty engine accepted'
	$State.clean = $true
	$WrongArgs = $HostParameters.Clone(); $WrongArgs.CompilerPath = $Compiler.Replace('14.44.35207', '14.43.00000')
	$Caught = $false
	try { $null = Get-InitialPreparationHostProof @WrongArgs } catch { $Caught = $_.Exception.Message -ceq 'host_tool_path_invalid' }
	Assert-HostFixture -Condition $Caught -Message 'Wrong compiler family accepted'
	$WrongArgs = $HostParameters.Clone(); $WrongArgs.LinuxToolchainRoot = Join-Path $Root 'different-linux'
	$Caught = $false
	try { $null = Get-InitialPreparationHostProof @WrongArgs } catch { $Caught = $_.Exception.Message -ceq 'host_tool_path_invalid' }
	Assert-HostFixture -Condition $Caught -Message 'Wrong Linux toolchain accepted'
	# Failure while streaming must dispose every previously retained handle.
	$FixtureProgressCounter = @{ n = 0 }; $WrongArgs = $HostParameters.Clone(); $WrongArgs.OnProgress = { $FixtureProgressCounter.n++; if ($FixtureProgressCounter.n -eq 15) { throw 'fixture_progress_stop' } }
	$Caught = $false
	$ProgressFailure = $null
	try { $null = Get-InitialPreparationHostProof @WrongArgs } catch { $ProgressFailure = $_.Exception.Message; $Caught = $ProgressFailure -ceq 'fixture_progress_stop' }
	Assert-HostFixture -Condition $Caught -Message "Progress failure ignored: $ProgressFailure"
	$Write = [IO.File]::Open($Files[0], [IO.FileMode]::Open, [IO.FileAccess]::Write); $Write.Dispose()
	$VersionPath = Join-Path $Linux 'ToolchainVersion.txt'
	$Write = [IO.File]::Open($VersionPath, [IO.FileMode]::Open, [IO.FileAccess]::Write)
	try { $Write.WriteByte(120) } finally { $Write.Dispose() }
	$Caught = $false
	try { $null = Get-InitialPreparationHostProof @HostParameters } catch { $Caught = $_.Exception.Message -ceq 'host_linux_version_invalid' }
	Assert-HostFixture -Condition $Caught -Message 'Mismatched Linux version content accepted'
	Write-Output "PASS compile host retained-input fixtures: $Root"
}
Test-HostProof
