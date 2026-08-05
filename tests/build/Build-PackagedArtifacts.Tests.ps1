[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$Script = Join-Path $RepositoryRoot 'scripts/build/Build-PackagedArtifacts.ps1'
$FixtureRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("AethelnPackagingTests-{0}" -f [guid]::NewGuid().ToString('N'))
$OriginalUebpLogFolder = [Environment]::GetEnvironmentVariable('uebp_LogFolder', 'Process')
$OriginalUebpFinalLogFolder = [Environment]::GetEnvironmentVariable('uebp_FinalLogFolder', 'Process')

function Assert-True([bool] $Condition, [string] $Message) { if (-not $Condition) { throw "Assertion failed: $Message" } }

try {
	$RealRevision = (& git -C $RepositoryRoot rev-parse HEAD).Trim()
	$OriginalPath = $env:PATH
	$GitBin = Join-Path $FixtureRoot 'GitBin'
	New-Item -ItemType Directory -Path $GitBin -Force | Out-Null
	$FakeGit = Join-Path $GitBin 'git.bat'
	Set-Content -LiteralPath $FakeGit -Value "@echo off`r`nif `"%3`"==`"rev-parse`" echo $RealRevision`r`nif `"%3`"==`"status`" if not `"%AETHELN_TEST_GIT_STATUS%`"==`"`" echo %AETHELN_TEST_GIT_STATUS%`r`nexit /b 0" -Encoding Ascii
	$env:PATH = "$GitBin;$OriginalPath"
	$env:AETHELN_TEST_GIT_STATUS = ''
	$EngineRoot = Join-Path $FixtureRoot 'UE'
	$ToolchainRoot = Join-Path $FixtureRoot 'v26_clang-20.1.8-rockylinux8'
	$ArchiveRoot = Join-Path $FixtureRoot 'Archive'
	$env:AETHELN_TEST_ARCHIVE_ROOT = $ArchiveRoot
	$LogRoot = Join-Path $FixtureRoot 'Logs'
	$UatDirectory = Join-Path $EngineRoot 'Engine/Build/BatchFiles'
	New-Item -ItemType Directory -Path $UatDirectory -Force | Out-Null
	foreach ($RelativeDirectory in @('Engine/Plugins/Runtime/CommonUI/Content', 'Engine/Plugins/EnhancedInput/Content', 'Engine/Plugins/Interchange/Runtime/Content')) {
		New-Item -ItemType Directory -Path (Join-Path $EngineRoot $RelativeDirectory) -Force | Out-Null
	}
	New-Item -ItemType Directory -Path (Join-Path $ToolchainRoot 'x86_64-unknown-linux-gnu/bin') -Force | Out-Null
	Set-Content -LiteralPath (Join-Path $EngineRoot 'Engine/Build/Build.version') -Value '{"MajorVersion":5,"MinorVersion":8,"PatchVersion":1,"Changelist":123,"CompatibleChangelist":120,"BranchName":"++UE5+Release-5.8"}' -Encoding UTF8
	Set-Content -LiteralPath (Join-Path $ToolchainRoot 'x86_64-unknown-linux-gnu/bin/clang.bat') -Value '@echo clang version 20.1.8' -Encoding Ascii
	$CapturePath = Join-Path $FixtureRoot 'uat-arguments.txt'
	$SelectedCompiler = Join-Path $FixtureRoot 'Visual Studio/MSVC/14.44.35207/bin/Hostx64/x64/cl.exe'
	$SelectedResourceCompiler = Join-Path $FixtureRoot 'Windows Kits/10/bin/10.0.26100.0/x64/rc.exe'
	New-Item -ItemType Directory -Path (Split-Path -Parent $SelectedCompiler), (Split-Path -Parent $SelectedResourceCompiler) -Force | Out-Null
	Set-Content -LiteralPath $SelectedCompiler -Value 'selected compiler' -Encoding Ascii
	Set-Content -LiteralPath $SelectedResourceCompiler -Value 'selected resource compiler' -Encoding Ascii
	$ConflictingCompiler = Join-Path $FixtureRoot 'Visual Studio/MSVC/14.43.34808/bin/Hostx64/x64/cl.exe'
	New-Item -ItemType Directory -Path (Split-Path -Parent $ConflictingCompiler) -Force | Out-Null
	Set-Content -LiteralPath $ConflictingCompiler -Value 'conflicting compiler' -Encoding Ascii
	$PriorLogFolder = Join-Path $FixtureRoot 'PriorAutomationToolLogs'
	$PriorFinalLogFolder = Join-Path $FixtureRoot 'PriorFinalAutomationToolLogs'
	New-Item -ItemType Directory -Path $PriorLogFolder, $PriorFinalLogFolder -Force | Out-Null
	Set-Content -LiteralPath (Join-Path $PriorLogFolder 'UBA-stale.txt') -Value "Compiler: $ConflictingCompiler" -Encoding Ascii
	[Environment]::SetEnvironmentVariable('uebp_LogFolder', $PriorLogFolder, 'Process')
	[Environment]::SetEnvironmentVariable('uebp_FinalLogFolder', $PriorFinalLogFolder, 'Process')
	$FakeUat = Join-Path $UatDirectory 'RunUAT.bat'
	$FakeBody = @"
@echo off
echo %*>>"$CapturePath"
echo %* | findstr /c:"-serverplatform=Linux" >nul
if %errorlevel%==0 (
	mkdir "%AETHELN_TEST_ARCHIVE_ROOT%\LinuxServer" 2>nul
	echo server>"%AETHELN_TEST_ARCHIVE_ROOT%\LinuxServer\AethelnOnlineServer"
) else (
	mkdir "%AETHELN_TEST_ARCHIVE_ROOT%\WindowsClient" 2>nul
	echo client>"%AETHELN_TEST_ARCHIVE_ROOT%\WindowsClient\AethelnOnlineClient.exe"
	mkdir "%uebp_LogFolder%" 2>nul
	>"%uebp_LogFolder%\UBA-client.txt" echo Compiler: $SelectedCompiler
	>>"%uebp_LogFolder%\UBA-client.txt" echo Compiler: $SelectedCompiler
	>>"%uebp_LogFolder%\UBA-client.txt" echo Resource Compiler: $SelectedResourceCompiler
	>>"%uebp_LogFolder%\UBA-client.txt" echo Resource Compiler: $SelectedResourceCompiler
	if "%AETHELN_TEST_CONFLICTING_COMPILER%"=="1" echo Compiler: $ConflictingCompiler>>"%uebp_LogFolder%\UBA-conflict.txt"
)
exit /b 0
"@
	Set-Content -LiteralPath $FakeUat -Value $FakeBody -Encoding Ascii
	$EditorDirectory = Join-Path $EngineRoot 'Engine/Binaries/Win64'
	New-Item -ItemType Directory -Path $EditorDirectory -Force | Out-Null
	$EditorSource = @"
using System;
using System.IO;
public static class FakeEditor {
	public static int Main(string[] args) {
		string outDir = null;
		foreach (string arg in args) if (arg.StartsWith("-OutDir=")) outDir = arg.Substring(8);
		if (outDir == null) return 9;
		Directory.CreateDirectory(outDir);
		string report = outDir.Contains("cooked-inventory")
			? "--- Begin CachedAssetsByPackageName ---\n\t/Game/Maps/StarterMap : 1 item(s)\n\t\t/Game/Maps/StarterMap.StarterMap\n--- End CachedAssetsByPackageName : 1 entries ---\n"
			: "--- Begin CachedAssetsByClass ---\n--- End CachedAssetsByClass : 0 entries ---\n--- Begin CachedDependsNodes ---\n--- End CachedDependsNodes : 0 entries ---\n";
		File.WriteAllText(Path.Combine(outDir, "Page_0.txt"), report);
		return 0;
	}
}
"@
	Add-Type -TypeDefinition $EditorSource -OutputAssembly (Join-Path $EditorDirectory 'UnrealEditor-Cmd.exe') -OutputType ConsoleApplication
	$Revision = $RealRevision

	& $Script -ProjectPath (Join-Path $RepositoryRoot 'AethelnOnline.uproject') -EngineRoot $EngineRoot -LinuxToolchainRoot $ToolchainRoot -ArchiveRoot $ArchiveRoot -LogRoot $LogRoot -SourceRevision $Revision
	$Calls = @(Get-Content -LiteralPath $CapturePath)
	Assert-True ($Calls.Count -eq 2) 'RunUAT should be invoked once per supported artifact.'
	foreach ($Required in @('BuildCookRun', '-build', '-cook', '-clean', '-stage', '-pak', '-archive', '-map=/Game/Maps/StarterMap')) {
		Assert-True ($Calls[1].Contains($Required)) "The server call should include exact required argument '$Required'."
	}
	foreach ($Required in @('-target=AethelnOnlineServer', '-server', '-noclient', '-serverplatform=Linux', '-serverconfig=Development', '-AdditionalCookerOptions=-ini:Input:[/Script/CommonUI.CommonUIInputSettings]:DefaultVirtualPointerClass=None', '-NeverCookDir=', 'Engine\Plugins\Runtime\CommonUI\Content', 'Engine\Plugins\EnhancedInput\Content', 'Engine\Plugins\Interchange\Runtime\Content')) {
		Assert-True ($Calls[1].Contains($Required)) "The server call should include exact proven argument '$Required'."
	}
	Assert-True (-not $Calls[1].Contains('-platform=Linux')) 'The server must use serverplatform rather than the ambiguous platform switch.'
	$Provenance = Get-Content -LiteralPath (Join-Path $ArchiveRoot 'build-provenance.json') -Raw | ConvertFrom-Json
	Assert-True ($Provenance.build.uatInvocations.server.arguments -contains '-serverplatform=Linux') 'Provenance should preserve exact UAT arguments.'
	Assert-True ($Provenance.source.clean -eq $true) 'Provenance should record the clean-worktree gate result.'
	Assert-True ($Provenance.tools.compiler.path -eq $SelectedCompiler) 'Provenance must use the compiler selected in this UBT invocation.'
	Assert-True ($Provenance.tools.compiler.version -eq '14.44.35207') 'The selected MSVC version should be correlated from its exact path.'
	Assert-True ($Provenance.tools.windowsSdk.version -eq '10.0.26100.0') 'The selected Windows SDK version should be correlated from its exact resource compiler path.'
	Assert-True ($Provenance.build.uatInvocations.dependencyRegistryDump.arguments -contains '-DependencyDetails') 'Provenance should preserve exact dependency dump arguments.'
	Assert-True ($Provenance.build.uatInvocations.cookedInventoryDump.arguments -contains '-PackageName') 'Provenance should preserve exact inventory dump arguments.'
	Assert-True (-not ($Provenance.build.uatInvocations.cookedInventoryDump.arguments -contains '-DependencyDetails')) 'Inventory dump should request only the required package-name report.'
	Assert-True (Test-Path -LiteralPath (Join-Path $LogRoot 'server-dependency-registry-dump.log')) 'Dependency dump should have an actionable log.'
	Assert-True (Test-Path -LiteralPath (Join-Path $LogRoot 'server-cooked-inventory-dump.log')) 'Inventory dump should have an actionable log.'
	Assert-True ($Provenance.artifacts.inventory.Count -eq 2) 'Every packaged file should be inventoried.'
	$ProjectDescriptor = Get-Content -LiteralPath (Join-Path $RepositoryRoot 'AethelnOnline.uproject') -Raw | ConvertFrom-Json
	$AndroidFileServer = @($ProjectDescriptor.Plugins | Where-Object { $_.Name -eq 'AndroidFileServer' })
	Assert-True ($AndroidFileServer.Count -eq 1 -and $AndroidFileServer[0].Enabled -eq $false) 'AndroidFileServer must remain explicitly disabled so commandlets cannot write generated settings into tracked project config.'
	Assert-True (Test-Path -LiteralPath (Join-Path $LogRoot 'client-automationtool/UBA-client.txt')) 'Client UBT sidecars should be isolated under the run LogRoot.'
	Assert-True (Test-Path -LiteralPath (Join-Path $LogRoot 'server-automationtool')) 'Server AutomationTool logs should use a distinct isolated directory.'
	Assert-True (-not ((Get-Content -LiteralPath (Join-Path $LogRoot 'client-uat.log') -Raw) -match '(?m)^Compiler:')) 'Toolchain evidence should not depend on UAT stdout.'
	Assert-True ([Environment]::GetEnvironmentVariable('uebp_LogFolder', 'Process') -eq $PriorLogFolder) 'The prior AutomationTool log folder should be restored after success.'
	Assert-True ([Environment]::GetEnvironmentVariable('uebp_FinalLogFolder', 'Process') -eq $PriorFinalLogFolder) 'The prior final AutomationTool log folder should be restored after success.'
	Write-Output 'PASS: proven client/server UAT invocations produce validated executables and exact provenance'

	$env:AETHELN_TEST_CONFLICTING_COMPILER = '1'
	$env:AETHELN_TEST_ARCHIVE_ROOT = Join-Path $FixtureRoot 'ConflictArchive'
	$Failure = $null
	try { & $Script -ProjectPath (Join-Path $RepositoryRoot 'AethelnOnline.uproject') -EngineRoot $EngineRoot -LinuxToolchainRoot $ToolchainRoot -ArchiveRoot (Join-Path $FixtureRoot 'ConflictArchive') -LogRoot (Join-Path $FixtureRoot 'ConflictLogs') -SourceRevision $Revision } catch { $Failure = $_.Exception.Message }
	Assert-True ($Failure -match 'exactly one UBT-selected Compiler.*found 2') 'Conflicting compiler paths from the isolated client sidecars should fail actionably.'
	Assert-True ([Environment]::GetEnvironmentVariable('uebp_LogFolder', 'Process') -eq $PriorLogFolder) 'The prior AutomationTool log folder should be restored after failure.'
	Assert-True ([Environment]::GetEnvironmentVariable('uebp_FinalLogFolder', 'Process') -eq $PriorFinalLogFolder) 'The prior final AutomationTool log folder should be restored after failure.'
	Remove-Item Env:AETHELN_TEST_CONFLICTING_COMPILER
	$env:AETHELN_TEST_ARCHIVE_ROOT = $ArchiveRoot
	Write-Output 'PASS: conflicting isolated UBT toolchain evidence is rejected and environment state is restored'

	$DirtyRoot = Join-Path $FixtureRoot 'DirtyArchive'
	New-Item -ItemType Directory -Path $DirtyRoot | Out-Null
	Set-Content -LiteralPath (Join-Path $DirtyRoot 'old.txt') -Value old
	$Failure = $null
	try { & $Script -ProjectPath (Join-Path $RepositoryRoot 'AethelnOnline.uproject') -EngineRoot $EngineRoot -LinuxToolchainRoot $ToolchainRoot -ArchiveRoot $DirtyRoot -LogRoot (Join-Path $FixtureRoot 'FreshLogs') -SourceRevision $Revision } catch { $Failure = $_.Exception.Message }
	Assert-True ($Failure -match 'must be empty') 'Existing output must not be silently mixed with a new build.'
	Write-Output 'PASS: non-empty output roots are rejected'

	$CallsBeforeDirtyChecks = @(Get-Content -LiteralPath $CapturePath).Count
	foreach ($DirtyCase in @(
		@{ Status = ' M Source/GameCore/Private/Changed.cpp'; Label = 'modified' },
		@{ Status = '?? Source/GameCore/Private/NewInput.cpp'; Label = 'untracked' }
	)) {
		$env:AETHELN_TEST_GIT_STATUS = $DirtyCase.Status
		$Failure = $null
		try { & $Script -ProjectPath (Join-Path $RepositoryRoot 'AethelnOnline.uproject') -EngineRoot $EngineRoot -LinuxToolchainRoot $ToolchainRoot -ArchiveRoot (Join-Path $FixtureRoot "$($DirtyCase.Label)-archive") -LogRoot (Join-Path $FixtureRoot "$($DirtyCase.Label)-logs") -SourceRevision $Revision } catch { $Failure = $_.Exception.Message }
		Assert-True ($Failure -match 'require a clean repository') "$($DirtyCase.Label) build inputs should be rejected actionably."
		Assert-True ($Failure -match [regex]::Escape($DirtyCase.Status.Substring(3))) "$($DirtyCase.Label) input path should be listed."
		Assert-True (-not (Test-Path -LiteralPath (Join-Path $FixtureRoot "$($DirtyCase.Label)-archive"))) 'Dirty source should fail before creating output roots.'
	}
	Assert-True (@(Get-Content -LiteralPath $CapturePath).Count -eq $CallsBeforeDirtyChecks) 'Dirty source should fail before any UAT invocation.'
	Write-Output 'PASS: modified and untracked build inputs fail before UAT'
}
finally {
	if ($null -ne $OriginalPath) { $env:PATH = $OriginalPath }
	Remove-Item Env:AETHELN_TEST_GIT_STATUS -ErrorAction SilentlyContinue
	Remove-Item Env:AETHELN_TEST_CONFLICTING_COMPILER -ErrorAction SilentlyContinue
	Remove-Item Env:AETHELN_TEST_ARCHIVE_ROOT -ErrorAction SilentlyContinue
	[Environment]::SetEnvironmentVariable('uebp_LogFolder', $OriginalUebpLogFolder, 'Process')
	[Environment]::SetEnvironmentVariable('uebp_FinalLogFolder', $OriginalUebpFinalLogFolder, 'Process')
	if (Test-Path -LiteralPath $FixtureRoot) { Remove-Item -LiteralPath $FixtureRoot -Recurse -Force }
}
