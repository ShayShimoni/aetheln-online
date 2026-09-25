[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$Script = Join-Path $RepositoryRoot 'scripts/build/Write-BuildProvenance.ps1'
$FixtureRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("AethelnProvenanceTests-{0}" -f [guid]::NewGuid().ToString('N'))
function Assert-True([bool] $Condition, [string] $Message) { if (-not $Condition) { throw "Assertion failed: $Message" } }

try {
	$RealRevision = (& git -C $RepositoryRoot rev-parse HEAD).Trim()
	$OriginalPath = $env:PATH
	$GitBin = Join-Path $FixtureRoot 'GitBin'
	New-Item -ItemType Directory -Path $GitBin -Force | Out-Null
	Set-Content -LiteralPath (Join-Path $GitBin 'git.bat') -Value "@echo off`r`nif `"%3`"==`"rev-parse`" echo $RealRevision`r`nexit /b 0" -Encoding Ascii
	$env:PATH = "$GitBin;$OriginalPath"
	$EngineRoot = Join-Path $FixtureRoot 'UE'
	$ToolchainRoot = Join-Path $FixtureRoot 'v26_clang-20.1.8-rockylinux8'
	$Client = Join-Path $FixtureRoot 'Client'
	$Server = Join-Path $FixtureRoot 'Server'
	New-Item -ItemType Directory -Path (Join-Path $EngineRoot 'Engine/Build'), $ToolchainRoot, $Client, $Server -Force | Out-Null
	Set-Content -LiteralPath (Join-Path $EngineRoot 'Engine/Build/Build.version') -Value '{"MajorVersion":5,"MinorVersion":8,"PatchVersion":1,"Changelist":123,"CompatibleChangelist":120,"BranchName":"++UE5+Release-5.8"}' -Encoding UTF8
	$ToolchainX64Bin = Join-Path $ToolchainRoot 'x86_64-unknown-linux-gnu/bin'
	$ToolchainDecoyBin = Join-Path $ToolchainRoot 'aarch64-unknown-linux-gnueabi/bin'
	New-Item -ItemType Directory -Path $ToolchainX64Bin, $ToolchainDecoyBin -Force | Out-Null
	Set-Content -LiteralPath (Join-Path $ToolchainX64Bin 'clang.bat') -Value '@echo clang version 20.1.8' -Encoding Ascii
	Set-Content -LiteralPath (Join-Path $ToolchainDecoyBin 'clang.bat') -Value '@echo clang version 20.1.8' -Encoding Ascii
	Set-Content -LiteralPath (Join-Path $Client 'AethelnOnlineClient.exe') -Value client
	Set-Content -LiteralPath (Join-Path $Server 'AethelnOnlineServer') -Value server
	$Compiler = Join-Path $FixtureRoot 'VS/MSVC/14.44.35207/bin/Hostx64/x64/cl.exe'
	$DecoyCompiler = Join-Path $FixtureRoot 'VS/MSVC/14.50.99999/bin/Hostx64/x64/cl.exe'
	$ResourceCompiler = Join-Path $FixtureRoot 'Windows Kits/10/bin/10.0.26100.0/x64/rc.exe'
	$DecoyResourceCompiler = Join-Path $FixtureRoot 'Windows Kits/10/bin/10.0.30000.0/x64/rc.exe'
	foreach ($Tool in @($Compiler, $DecoyCompiler, $ResourceCompiler, $DecoyResourceCompiler)) { New-Item -ItemType Directory -Path (Split-Path -Parent $Tool) -Force | Out-Null; Set-Content -LiteralPath $Tool -Value $Tool -Encoding Ascii }
	$Revision = $RealRevision
	$UatArguments = [ordered]@{ client = @('BuildCookRun', '-platform=Win64'); server = @('BuildCookRun', '-serverplatform=Linux'); dependencyRegistryDump = @('-run=DumpAssetRegistry', '-DependencyDetails'); cookedInventoryDump = @('-run=DumpAssetRegistry', '-PackageName') } | ConvertTo-Json -Compress
	$OutputPath = Join-Path $FixtureRoot 'provenance/build.json'

	& $Script -OutputPath $OutputPath -ProjectPath (Join-Path $RepositoryRoot 'AethelnOnline.uproject') -EngineRoot $EngineRoot -LinuxToolchainRoot $ToolchainRoot -SourceRevision $Revision -BuildConfiguration Development -ClientArchivePath $Client -ServerArchivePath $Server -CompilerPath $Compiler -ResourceCompilerPath $ResourceCompiler -UatArgumentsJson $UatArguments
	$Provenance = Get-Content -LiteralPath $OutputPath -Raw | ConvertFrom-Json
	Assert-True ($Provenance.schemaVersion -eq 2) 'Schema version should identify complete provenance.'
	Assert-True ($Provenance.source.revision -eq $Revision) 'Verified repository HEAD should be recorded.'
	Assert-True ($Provenance.source.clean -eq $true) 'Verified clean source state should be recorded.'
	Assert-True (($Provenance.source.statusCommand -join ' ') -match 'status --porcelain=v1 --untracked-files=all') 'Exact clean-worktree command should be recorded.'
	Assert-True ($Provenance.tools.unreal.build.branchName -eq '++UE5+Release-5.8') 'Exact Unreal build identity should be recorded.'
	Assert-True ($Provenance.tools.linuxCrossToolchain.identity -eq 'v26_clang-20.1.8-rockylinux8') 'Versioned cross-toolchain root identity should be recorded.'
	Assert-True ($Provenance.tools.linuxCrossToolchain.compilerBanner -match '20\.1\.8') 'Cross-toolchain compiler identity should be recorded.'
	Assert-True ($Provenance.tools.linuxCrossToolchain.compilerPath.Replace('\', '/') -like '*/x86_64-unknown-linux-gnu/bin/clang.bat') 'Cross-toolchain compiler path must resolve under the x86_64 architecture directory.'
	Assert-True ($Provenance.tools.compiler.path -eq $Compiler) 'Pinned compiler must win when multiple installations exist.'
	Assert-True ($Provenance.tools.compiler.version -eq '14.44.35207') 'Exactly one pinned MSVC version should be recorded.'
	Assert-True ($Provenance.tools.windowsSdk.resourceCompilerPath -eq $ResourceCompiler) 'Pinned SDK tool must win when multiple SDKs exist.'
	Assert-True ($Provenance.tools.windowsSdk.version -eq '10.0.26100.0') 'Exactly one pinned Windows SDK version should be recorded.'
	Assert-True ($Provenance.source.plugins.Count -eq 4) 'Project plugin descriptors and state should be recorded.'
	$AndroidFileServer = @($Provenance.source.plugins | Where-Object { $_.name -eq 'AndroidFileServer' })
	Assert-True ($AndroidFileServer.Count -eq 1 -and $AndroidFileServer[0].enabled -eq $false) 'Disabled plugins should remain explicit in provenance.'
	Assert-True ($Provenance.build.uatInvocations.server.arguments[1] -eq '-serverplatform=Linux') 'Exact UAT argument order should be recorded.'
	Assert-True ($Provenance.artifacts.inventory.Count -eq 2) 'Complete artifact file inventory should be recorded.'
	Assert-True ($Provenance.artifacts.inventory[0].sha256.Length -eq 64) 'Artifact SHA256 should be recorded.'
	Assert-True ($Provenance.artifacts.inventory[0].sizeBytes -gt 0) 'Artifact byte size should be recorded.'
	Assert-True ($Provenance.host.PSObject.Properties.Name -contains 'buildIdentity') 'Host/build identity should be recorded.'
	Assert-True (-not ($Provenance.PSObject.Properties.Name -contains 'environment')) 'Process environment must not be captured.'
	Write-Output 'PASS: provenance records verified revisions, exact tools/arguments/plugins/host, and hashed inventory'

	$Failure = $null
	try { & $Script -OutputPath (Join-Path $FixtureRoot 'bad.json') -ProjectPath (Join-Path $RepositoryRoot 'AethelnOnline.uproject') -EngineRoot $EngineRoot -LinuxToolchainRoot $ToolchainRoot -SourceRevision ('0' * 40) -BuildConfiguration Development -ClientArchivePath $Client -ServerArchivePath $Server -CompilerPath $Compiler -ResourceCompilerPath $ResourceCompiler -UatArgumentsJson $UatArguments } catch { $Failure = $_.Exception.Message }
	Assert-True ($Failure -match 'does not match repository HEAD') 'A requested revision not matching actual HEAD must fail.'
	Write-Output 'PASS: provenance refuses an unproven source revision'
}
finally {
	if ($null -ne $OriginalPath) { $env:PATH = $OriginalPath }
	if (Test-Path -LiteralPath $FixtureRoot) { Remove-Item -LiteralPath $FixtureRoot -Recurse -Force }
}
