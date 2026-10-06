[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$Script = Join-Path $RepositoryRoot 'scripts/build/Build-PackagedArtifacts.ps1'
$FixtureRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("AethelnPackagingTests-{0}" -f [guid]::NewGuid().ToString('N'))
$OriginalUebpLogFolder = [Environment]::GetEnvironmentVariable('uebp_LogFolder', 'Process')
$OriginalUebpFinalLogFolder = [Environment]::GetEnvironmentVariable('uebp_FinalLogFolder', 'Process')
$OriginalAdditionalPluginPaths = [Environment]::GetEnvironmentVariable('UE_ADDITIONAL_PLUGIN_PATHS', 'Process')

function Assert-True([bool] $Condition, [string] $Message) { if (-not $Condition) { throw "Assertion failed: $Message" } }

try {
	# Prebuilt packaging refuses a set private-plugin path (issue #267), so the
	# fixture runs with it cleared and restores the caller's value afterwards.
	[Environment]::SetEnvironmentVariable('UE_ADDITIONAL_PLUGIN_PATHS', $null, 'Process')
	$RealRevision = (& git -C $RepositoryRoot rev-parse HEAD).Trim()
	# Packaging writes cooked registries under the project's Saved/Cooked, so the
	# fake UAT targets an isolated project copy and never touches a real checkout.
	$FixtureProjectRoot = Join-Path $FixtureRoot 'Project'
	New-Item -ItemType Directory -Path $FixtureProjectRoot -Force | Out-Null
	foreach ($ProjectItem in @('AethelnOnline.uproject', 'Source', 'Config')) { Copy-Item -LiteralPath (Join-Path $RepositoryRoot $ProjectItem) -Destination $FixtureProjectRoot -Recurse }
	$FixtureProject = Join-Path $FixtureProjectRoot 'AethelnOnline.uproject'
	$env:AETHELN_TEST_PROJECT_ROOT = $FixtureProjectRoot
	$env:AETHELN_TEST_REGISTRY_NONCE = 'fixture'
	function Assert-RegistryReceipt($Actual, [string] $Kind, [string] $Context) {
		$CookPlatform = if ($Kind -ceq 'client') { 'WindowsClient' } else { 'LinuxServer' }
		$RelativePath = "Saved/Cooked/$CookPlatform/AethelnOnline/AssetRegistry.bin"
		$RegistryPath = Join-Path $FixtureProjectRoot $RelativePath
		$Expected = [ordered]@{
			relativePath = $RelativePath
			sizeBytes = (Get-Item -LiteralPath $RegistryPath).Length
			sha256 = (Get-FileHash -LiteralPath $RegistryPath -Algorithm SHA256).Hash.ToLowerInvariant()
			target = if ($Kind -ceq 'client') { 'AethelnOnlineClient' } else { 'AethelnOnlineServer' }
			platform = if ($Kind -ceq 'client') { 'Win64' } else { 'Linux' }
			cookPlatform = $CookPlatform
			sourceRevision = $Revision
		}
		Assert-True ($null -ne $Actual) "$Context must carry the producer $Kind cooked-registry receipt."
		Assert-True ((@($Actual.PSObject.Properties.Name) -join ',') -ceq (@($Expected.Keys) -join ',')) "$Context $Kind receipt must use the closed field set."
		foreach ($Field in $Expected.Keys) { Assert-True ($Actual.$Field -eq $Expected[$Field]) "$Context $Kind receipt $Field must bind the exact cooked registry." }
	}
	$OriginalPath = $env:PATH
	$GitBin = Join-Path $FixtureRoot 'GitBin'
	New-Item -ItemType Directory -Path $GitBin -Force | Out-Null
	$FakeGit = Join-Path $GitBin 'git.bat'
	$EngineRoot = Join-Path $FixtureRoot 'UE'
	$ToolchainRoot = Join-Path $FixtureRoot 'v26_clang-20.1.8-rockylinux8'
	$CanonicalEnginePin = '71fe36aac5a8df5ccd66c763ffc902b29b6a9c43'
	$FakeGitBody = @(
		'@echo off',
		'if not "%3"=="rev-parse" goto notrevparse',
		"if /I `"%~2`"==`"$EngineRoot`" goto enginehead",
		"echo $RealRevision",
		'exit /b 0',
		':enginehead',
		"if not `"%AETHELN_TEST_ENGINE_HEAD%`"==`"`" (echo %AETHELN_TEST_ENGINE_HEAD%) else (echo $CanonicalEnginePin)",
		'exit /b 0',
		':notrevparse',
		"if `"%3`"==`"rev-list`" echo $RealRevision",
		'if not "%3"=="status" exit /b 0',
		"if /I `"%~2`"==`"$EngineRoot`" goto enginestatus",
		'if not "%AETHELN_TEST_GIT_STATUS%"=="" echo %AETHELN_TEST_GIT_STATUS%',
		'exit /b 0',
		':enginestatus',
		'if not "%AETHELN_TEST_ENGINE_GIT_STATUS%"=="" echo %AETHELN_TEST_ENGINE_GIT_STATUS%',
		'exit /b 0'
	) -join "`r`n"
	Set-Content -LiteralPath $FakeGit -Value $FakeGitBody -Encoding Ascii
	$env:PATH = "$GitBin;$OriginalPath"
	$env:AETHELN_TEST_GIT_STATUS = ''
	$env:AETHELN_TEST_ENGINE_GIT_STATUS = ''
	$env:AETHELN_TEST_ENGINE_HEAD = ''
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
	$OrderPath = Join-Path $FixtureRoot 'build-order.txt'
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
echo uat>>"$OrderPath"
if defined AETHELN_TEST_DDC_CAPTURE echo %UE-LocalDataCachePath%>>"%AETHELN_TEST_DDC_CAPTURE%"
echo ********** BUILD COMMAND STARTED **********
echo ********** BUILD COMMAND COMPLETED **********
echo ********** COOK COMMAND STARTED **********
echo ********** COOK COMMAND COMPLETED **********
echo %* | findstr /c:"-serverplatform=Linux" >nul
if %errorlevel%==0 (
	mkdir "%AETHELN_TEST_ARCHIVE_ROOT%\LinuxServer" 2>nul
	echo server>"%AETHELN_TEST_ARCHIVE_ROOT%\LinuxServer\AethelnOnlineServer"
	mkdir "%AETHELN_TEST_PROJECT_ROOT%\Saved\Cooked\LinuxServer\AethelnOnline" 2>nul
	echo server registry %AETHELN_TEST_REGISTRY_NONCE%>"%AETHELN_TEST_PROJECT_ROOT%\Saved\Cooked\LinuxServer\AethelnOnline\AssetRegistry.bin"
) else (
	mkdir "%AETHELN_TEST_ARCHIVE_ROOT%\WindowsClient" 2>nul
	echo client>"%AETHELN_TEST_ARCHIVE_ROOT%\WindowsClient\AethelnOnlineClient.exe"
	mkdir "%AETHELN_TEST_PROJECT_ROOT%\Saved\Cooked\WindowsClient\AethelnOnline" 2>nul
	del "%AETHELN_TEST_PROJECT_ROOT%\Saved\Cooked\WindowsClient\AethelnOnline\AssetRegistry.bin" 2>nul
	if not "%AETHELN_TEST_SKIP_CLIENT_REGISTRY%"=="1" echo client registry %AETHELN_TEST_REGISTRY_NONCE%>"%AETHELN_TEST_PROJECT_ROOT%\Saved\Cooked\WindowsClient\AethelnOnline\AssetRegistry.bin"
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
	$EditorVersionPath = Join-Path $EditorDirectory 'UnrealEditor.version'
	$MatchingEditorVersion = '{"MajorVersion":5,"MinorVersion":8,"PatchVersion":1,"Changelist":123,"CompatibleChangelist":120,"BranchName":"++UE5+Release-5.8","BuildId":"fixture"}'
	Set-Content -LiteralPath $EditorVersionPath -Value $MatchingEditorVersion -Encoding UTF8
	Set-Content -LiteralPath (Join-Path $EditorDirectory 'UnrealEditor.exe') -Value 'fixture editor' -Encoding Ascii
	Set-Content -LiteralPath (Join-Path $EditorDirectory 'UnrealPak.exe') -Value 'fixture unrealpak' -Encoding Ascii
	Set-Content -LiteralPath (Join-Path $EditorDirectory 'ShaderCompileWorker.exe') -Value 'fixture shadercompileworker' -Encoding Ascii
	# Schema-2 closure (issue #267): the editor is built through the project
	# target, so its receipt lives in the project's Binaries/Win64 and is written
	# by the in-phase project editor build (the fake Build.bat below copies the
	# selected receipt template there). Its $(EngineDir) products plus the
	# ShaderCompileWorker receipt and products are attested; UnrealPak stays on
	# disk outside the closure. UnrealEditor.pdb is listed but never created:
	# symbol files must stay excluded.
	$PluginBinariesDirectory = Join-Path $EngineRoot 'Engine/Plugins/FixturePlugin/Binaries/Win64'
	New-Item -ItemType Directory -Path $PluginBinariesDirectory -Force | Out-Null
	$FixtureBuildId = 'b0f4d9c2-6a1e-4f3b-9d7a-2c5e8f1a3b6d'
	$EditorCoreDllPath = Join-Path $EditorDirectory 'UnrealEditor-Core.dll'
	$NetCoreDllPath = Join-Path $EditorDirectory 'UnrealEditor-NetCore.dll'
	$PluginDllPath = Join-Path $PluginBinariesDirectory 'UnrealEditor-FixturePlugin.dll'
	$RootManifestPath = Join-Path $EditorDirectory 'UnrealEditor.modules'
	$PluginManifestPath = Join-Path $PluginBinariesDirectory 'UnrealEditor.modules'
	$ScwExecutablePath = Join-Path $EditorDirectory 'ShaderCompileWorker.exe'
	$ScwReceiptPath = Join-Path $EditorDirectory 'ShaderCompileWorker.target'
	Set-Content -LiteralPath $EditorCoreDllPath -Value 'fixture editor core module' -Encoding Ascii
	Set-Content -LiteralPath $NetCoreDllPath -Value 'fixture netcore module' -Encoding Ascii
	Set-Content -LiteralPath $PluginDllPath -Value 'fixture plugin module' -Encoding Ascii
	Set-Content -LiteralPath $RootManifestPath -Value ('{"BuildId":"' + $FixtureBuildId + '","Modules":{"Core":"UnrealEditor-Core.dll","NetCore":"UnrealEditor-NetCore.dll"}}') -Encoding UTF8
	Set-Content -LiteralPath $PluginManifestPath -Value ('{"BuildId":"' + $FixtureBuildId + '","Modules":{"FixturePlugin":"UnrealEditor-FixturePlugin.dll"}}') -Encoding UTF8
	Set-Content -LiteralPath (Join-Path $EditorDirectory 'ShaderCompileWorker.modules') -Value '{"BuildId":"scw-fixture","Modules":{}}' -Encoding UTF8
	Set-Content -LiteralPath (Join-Path $EditorDirectory 'UnrealPak.modules') -Value '{"BuildId":"unrealpak-fixture","Modules":{"PakFile":"UnrealPak-PakFile.dll"}}' -Encoding UTF8
	Set-Content -LiteralPath (Join-Path $EditorDirectory 'UnrealPak-PakFile.dll') -Value 'fixture unrealpak module' -Encoding Ascii
	$EditorReceiptBody = @'
{"TargetName":"AethelnOnlineEditor","Platform":"Win64","Configuration":"Development","TargetType":"Editor","Launch":"$(EngineDir)/Binaries/Win64/UnrealEditor.exe","LaunchCmd":"$(EngineDir)/Binaries/Win64/UnrealEditor-Cmd.exe","BuildProducts":[
{"Path":"$(EngineDir)/Binaries/Win64/UnrealEditor.exe","Type":"Executable"},
{"Path":"$(EngineDir)/Binaries/Win64/UnrealEditor-Cmd.exe","Type":"Executable"},
{"Path":"$(EngineDir)/Binaries/Win64/UnrealEditor-Core.dll","Type":"DynamicLibrary"},
{"Path":"$(EngineDir)/Binaries/Win64/UnrealEditor-NetCore.dll","Type":"DynamicLibrary"},
{"Path":"$(EngineDir)/Plugins/FixturePlugin/Binaries/Win64/UnrealEditor-FixturePlugin.dll","Type":"DynamicLibrary"},
{"Path":"$(EngineDir)/Binaries/Win64/UnrealEditor.modules","Type":"RequiredResource"},
{"Path":"$(EngineDir)/Plugins/FixturePlugin/Binaries/Win64/UnrealEditor.modules","Type":"RequiredResource"},
{"Path":"$(EngineDir)/Binaries/Win64/UnrealEditor.version","Type":"RequiredResource"},
{"Path":"$(EngineDir)/Binaries/Win64/UnrealEditor.pdb","Type":"SymbolFile"},
{"Path":"$(ProjectDir)/Binaries/Win64/UnrealEditor-GameCore.dll","Type":"DynamicLibrary"},
{"Path":"$(ProjectDir)/Binaries/Win64/UnrealEditor-GameCore.pdb","Type":"SymbolFile"},
{"Path":"$(ProjectDir)/Binaries/Win64/UnrealEditor.modules","Type":"RequiredResource"}]}
'@
	$ReceiptTemplates = Join-Path $FixtureRoot 'ReceiptTemplates'
	New-Item -ItemType Directory -Path $ReceiptTemplates | Out-Null
	function Write-EditorReceipt([string] $Name, [string] $Body) {
		$TemplatePath = Join-Path $ReceiptTemplates ($Name + '.target')
		Set-Content -LiteralPath $TemplatePath -Value $Body -Encoding UTF8
		return $TemplatePath
	}
	$GoodEditorReceipt = Write-EditorReceipt 'good' $EditorReceiptBody
	$env:AETHELN_TEST_EDITOR_RECEIPT = $GoodEditorReceipt
	Set-Content -LiteralPath (Join-Path $EditorDirectory 'UnrealPak.target') -Value '{"TargetName":"UnrealPak","Platform":"Win64","Configuration":"Development","TargetType":"Program","BuildProducts":[{"Path":"$(EngineDir)/Binaries/Win64/UnrealPak.exe","Type":"Executable"},{"Path":"$(EngineDir)/Binaries/Win64/UnrealPak-PakFile.dll","Type":"DynamicLibrary"},{"Path":"$(EngineDir)/Binaries/Win64/UnrealPak.modules","Type":"RequiredResource"},{"Path":"$(EngineDir)/Binaries/Win64/UnrealPak.pdb","Type":"SymbolFile"}]}' -Encoding UTF8
	Set-Content -LiteralPath $ScwReceiptPath -Value '{"TargetName":"ShaderCompileWorker","Platform":"Win64","Configuration":"Development","TargetType":"Program","BuildProducts":[{"Path":"$(EngineDir)/Binaries/Win64/ShaderCompileWorker.exe","Type":"Executable"},{"Path":"$(EngineDir)/Binaries/Win64/ShaderCompileWorker.modules","Type":"RequiredResource"}]}' -Encoding UTF8
	# The reviewed wrapper (InitialPreparation.BuildInvocation.ps1) runs this fake
	# engine Build.bat with the bundled dotnet present. It records its arguments
	# and build order, writes one planted build.log line (an engine path and the
	# word error) that must never reach the controller's output, replaces the
	# project receipt from AETHELN_TEST_EDITOR_RECEIPT (unset: writes none), can
	# mutate a closure file after "building" (AETHELN_TEST_EDITOR_POST), and
	# exits with AETHELN_TEST_EDITOR_EXIT (default 0).
	$EditorCapturePath = Join-Path $FixtureRoot 'editor-build-arguments.txt'
	$FakeDotnetPath = Join-Path $EngineRoot 'Engine/Binaries/ThirdParty/DotNet/10.0/win-x64/dotnet.exe'
	New-Item -ItemType Directory -Path (Split-Path -Parent $FakeDotnetPath) -Force | Out-Null
	Set-Content -LiteralPath $FakeDotnetPath -Value 'fixture dotnet' -Encoding Ascii
	$PlantedBuildLogLine = 'planted build log line'
	$FakeBuildBody = @"
@echo off
echo %*>>"$EditorCapturePath"
echo editor>>"$OrderPath"
echo error: $PlantedBuildLogLine for $EngineRoot\Engine\Source\Planted.cpp
del "%AETHELN_TEST_PROJECT_ROOT%\Binaries\Win64\AethelnOnlineEditor.target" 2>nul
if not "%AETHELN_TEST_EDITOR_RECEIPT%"=="" (
	mkdir "%AETHELN_TEST_PROJECT_ROOT%\Binaries\Win64" 2>nul
	copy /y "%AETHELN_TEST_EDITOR_RECEIPT%" "%AETHELN_TEST_PROJECT_ROOT%\Binaries\Win64\AethelnOnlineEditor.target" >nul
)
if "%AETHELN_TEST_EDITOR_POST%"=="dll" >"$NetCoreDllPath" echo netcore relinked after the build
if "%AETHELN_TEST_EDITOR_POST%"=="manifest" >"$RootManifestPath" echo {"BuildId":"rewritten-after-the-build","Modules":{"Core":"UnrealEditor-Core.dll","NetCore":"UnrealEditor-NetCore.dll"}}
if "%AETHELN_TEST_EDITOR_POST%"=="flood" powershell.exe -NoProfile -NonInteractive -Command "[Console]::Out.Write(('x' * 17000000))"
if not "%AETHELN_TEST_EDITOR_EXIT%"=="" exit /b %AETHELN_TEST_EDITOR_EXIT%
exit /b 0
"@
	Set-Content -LiteralPath (Join-Path $UatDirectory 'Build.bat') -Value $FakeBuildBody -Encoding Ascii
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

	& $Script -ProjectPath $FixtureProject -EngineRoot $EngineRoot -LinuxToolchainRoot $ToolchainRoot -ArchiveRoot $ArchiveRoot -LogRoot $LogRoot -SourceRevision $Revision -HostToolsBoundary Rebuild -RunnerName 'fixture-runner'
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
	Assert-RegistryReceipt -Actual $Provenance.build.cookedRegistries.client -Kind 'client' -Context 'Build provenance'
	Assert-RegistryReceipt -Actual $Provenance.build.cookedRegistries.server -Kind 'server' -Context 'Build provenance'
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
	try { & $Script -ProjectPath $FixtureProject -EngineRoot $EngineRoot -LinuxToolchainRoot $ToolchainRoot -ArchiveRoot (Join-Path $FixtureRoot 'ConflictArchive') -LogRoot (Join-Path $FixtureRoot 'ConflictLogs') -SourceRevision $Revision -HostToolsBoundary Rebuild } catch { $Failure = $_.Exception.Message }
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
	try { & $Script -ProjectPath $FixtureProject -EngineRoot $EngineRoot -LinuxToolchainRoot $ToolchainRoot -ArchiveRoot $DirtyRoot -LogRoot (Join-Path $FixtureRoot 'FreshLogs') -SourceRevision $Revision -HostToolsBoundary Rebuild } catch { $Failure = $_.Exception.Message }
	Assert-True ($Failure -match 'must be empty') 'Existing output must not be silently mixed with a new build.'
	Write-Output 'PASS: non-empty output roots are rejected'

	$CallsBeforeDirtyChecks = @(Get-Content -LiteralPath $CapturePath).Count
	foreach ($DirtyCase in @(
		@{ Status = ' M Source/GameCore/Private/Changed.cpp'; Label = 'modified' },
		@{ Status = '?? Source/GameCore/Private/NewInput.cpp'; Label = 'untracked' }
	)) {
		$env:AETHELN_TEST_GIT_STATUS = $DirtyCase.Status
		$Failure = $null
		try { & $Script -ProjectPath $FixtureProject -EngineRoot $EngineRoot -LinuxToolchainRoot $ToolchainRoot -ArchiveRoot (Join-Path $FixtureRoot "$($DirtyCase.Label)-archive") -LogRoot (Join-Path $FixtureRoot "$($DirtyCase.Label)-logs") -SourceRevision $Revision -HostToolsBoundary Rebuild } catch { $Failure = $_.Exception.Message }
		Assert-True ($Failure -match 'require a clean repository') "$($DirtyCase.Label) build inputs should be rejected actionably."
		Assert-True ($Failure -match [regex]::Escape($DirtyCase.Status.Substring(3))) "$($DirtyCase.Label) input path should be listed."
		Assert-True (-not (Test-Path -LiteralPath (Join-Path $FixtureRoot "$($DirtyCase.Label)-archive"))) 'Dirty source should fail before creating output roots.'
	}
	Assert-True (@(Get-Content -LiteralPath $CapturePath).Count -eq $CallsBeforeDirtyChecks) 'Dirty source should fail before any UAT invocation.'
	Write-Output 'PASS: modified and untracked build inputs fail before UAT'

	$env:AETHELN_TEST_GIT_STATUS = ''
	$StagedClientRoot = Join-Path $FixtureRoot 'StagedClient'
	$StagedServerRoot = Join-Path $FixtureRoot 'StagedServer'
	$StagedProvenanceRoot = Join-Path $FixtureRoot 'StagedProvenance'

	$env:AETHELN_TEST_ARCHIVE_ROOT = $StagedClientRoot
	& $Script -ProjectPath $FixtureProject -EngineRoot $EngineRoot -LinuxToolchainRoot $ToolchainRoot -ArchiveRoot $StagedClientRoot -LogRoot (Join-Path $FixtureRoot 'StagedClientLogs') -SourceRevision $Revision -HostToolsBoundary Rebuild -Stage Client
	$ClientRecord = Get-Content -LiteralPath (Join-Path $StagedClientRoot 'phase-client.json') -Raw | ConvertFrom-Json
	Assert-True ($ClientRecord.schemaVersion -eq 1 -and $ClientRecord.stage -eq 'client' -and $ClientRecord.sourceRevision -eq $Revision) 'The client stage record must bind schema, stage, and source revision.'
	Assert-True ($ClientRecord.compilerPath -eq $SelectedCompiler -and $ClientRecord.resourceCompilerPath -eq $SelectedResourceCompiler) 'The client stage record must carry the exact UBT-selected toolchain.'
	Assert-True ((@($ClientRecord.clientArguments) -contains '-target=AethelnOnlineClient') -and (@($ClientRecord.clientArguments) -contains '-clean')) 'The client stage record must preserve the exact clean client UAT arguments.'
	Assert-True (-not (Test-Path -LiteralPath (Join-Path $StagedClientRoot 'LinuxServer'))) 'The client stage must not produce server output.'
	Assert-RegistryReceipt -Actual $ClientRecord.cookedRegistry -Kind 'client' -Context 'The client stage record'

	$env:AETHELN_TEST_ARCHIVE_ROOT = $StagedServerRoot
	& $Script -ProjectPath $FixtureProject -EngineRoot $EngineRoot -LinuxToolchainRoot $ToolchainRoot -ArchiveRoot $StagedServerRoot -LogRoot (Join-Path $FixtureRoot 'StagedServerLogs') -SourceRevision $Revision -HostToolsBoundary Rebuild -Stage Server
	$ServerRecord = Get-Content -LiteralPath (Join-Path $StagedServerRoot 'phase-server.json') -Raw | ConvertFrom-Json
	Assert-True ($ServerRecord.stage -eq 'server' -and (@($ServerRecord.serverArguments) -contains '-serverplatform=Linux')) 'The server stage record must preserve the exact server UAT arguments.'
	Assert-True (Test-Path -LiteralPath (Join-Path $StagedServerRoot 'RegistryDumps/server-dependency-registry-dump/Page_0.txt')) 'The server stage must publish its dependency registry dump as payload.'
	Assert-True (Test-Path -LiteralPath (Join-Path $StagedServerRoot 'RegistryDumps/server-cooked-inventory-dump/Page_0.txt')) 'The server stage must publish its cooked inventory dump as payload.'
	Assert-True (-not (Test-Path -LiteralPath (Join-Path $StagedServerRoot 'WindowsClient'))) 'The server stage must not produce client output.'
	Assert-RegistryReceipt -Actual $ServerRecord.cookedRegistry -Kind 'server' -Context 'The server stage record'

	& $Script -ProjectPath $FixtureProject -EngineRoot $EngineRoot -LinuxToolchainRoot $ToolchainRoot -ArchiveRoot $StagedProvenanceRoot -LogRoot (Join-Path $FixtureRoot 'StagedProvenanceLogs') -SourceRevision $Revision -Stage Provenance -ClientStageRoot $StagedClientRoot -ServerStageRoot $StagedServerRoot
	$StagedProvenance = Get-Content -LiteralPath (Join-Path $StagedProvenanceRoot 'build-provenance.json') -Raw | ConvertFrom-Json
	Assert-True ($StagedProvenance.tools.compiler.path -eq $SelectedCompiler -and $StagedProvenance.tools.compiler.version -eq '14.44.35207') 'Staged provenance must use the client stage record toolchain.'
	Assert-True ($StagedProvenance.build.uatInvocations.server.arguments -contains '-serverplatform=Linux') 'Staged provenance must preserve the exact recorded server UAT arguments.'
	Assert-True ($StagedProvenance.artifacts.inventory.Count -eq 2) 'Staged provenance must inventory every packaged file from both stage payloads.'

	$Failure = $null
	try { & $Script -ProjectPath $FixtureProject -EngineRoot $EngineRoot -LinuxToolchainRoot $ToolchainRoot -ArchiveRoot (Join-Path $FixtureRoot 'StagedProvenanceMismatch') -LogRoot (Join-Path $FixtureRoot 'StagedProvenanceMismatchLogs') -SourceRevision ('1' * 40) -Stage Provenance -ClientStageRoot $StagedClientRoot -ServerStageRoot $StagedServerRoot } catch { $Failure = $_.Exception.Message }
	Assert-True ($Failure -match 'produced from source revision') 'Provenance over stage records from a different revision must fail closed.'
	Write-Output 'PASS: staged client, server, and provenance phases exchange exact records and fail closed on revision mismatch'

	Assert-RegistryReceipt -Actual $StagedProvenance.build.cookedRegistries.client -Kind 'client' -Context 'Staged build provenance'
	Assert-RegistryReceipt -Actual $StagedProvenance.build.cookedRegistries.server -Kind 'server' -Context 'Staged build provenance'
	foreach ($ReceiptCase in @(
		@{ name = 'CrossTarget'; field = 'cookPlatform'; value = 'LinuxServer' },
		@{ name = 'CrossRevision'; field = 'sourceRevision'; value = ('1' * 40) },
		@{ name = 'ForeignTarget'; field = 'target'; value = 'AethelnOnlineServer' }
	)) {
		$TamperedClientRoot = Join-Path $FixtureRoot "StagedClient$($ReceiptCase.name)"
		Copy-Item -LiteralPath $StagedClientRoot -Destination $TamperedClientRoot -Recurse
		$TamperedRecordPath = Join-Path $TamperedClientRoot 'phase-client.json'
		$TamperedRecord = Get-Content -LiteralPath $TamperedRecordPath -Raw | ConvertFrom-Json
		$TamperedRecord.cookedRegistry.($ReceiptCase.field) = $ReceiptCase.value
		$TamperedRecord | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $TamperedRecordPath -Encoding UTF8
		$Failure = $null
		try { & $Script -ProjectPath $FixtureProject -EngineRoot $EngineRoot -LinuxToolchainRoot $ToolchainRoot -ArchiveRoot (Join-Path $FixtureRoot "StagedProvenance$($ReceiptCase.name)") -LogRoot (Join-Path $FixtureRoot "StagedProvenance$($ReceiptCase.name)Logs") -SourceRevision $Revision -Stage Provenance -ClientStageRoot $TamperedClientRoot -ServerStageRoot $StagedServerRoot } catch { $Failure = $_.Exception.Message }
		Assert-True ($null -ne $Failure -and $Failure -match 'client cooked-registry receipt') "A $($ReceiptCase.name) client stage receipt must fail provenance closed; observed '$Failure'."
		Assert-True (-not (Test-Path -LiteralPath (Join-Path $FixtureRoot "StagedProvenance$($ReceiptCase.name)/build-provenance.json"))) "A $($ReceiptCase.name) client stage receipt must not produce provenance."
	}
	$env:AETHELN_TEST_SKIP_CLIENT_REGISTRY = '1'
	$env:AETHELN_TEST_ARCHIVE_ROOT = Join-Path $FixtureRoot 'MissingRegistryClient'
	$Failure = $null
	try { & $Script -ProjectPath $FixtureProject -EngineRoot $EngineRoot -LinuxToolchainRoot $ToolchainRoot -ArchiveRoot (Join-Path $FixtureRoot 'MissingRegistryClient') -LogRoot (Join-Path $FixtureRoot 'MissingRegistryClientLogs') -SourceRevision $Revision -HostToolsBoundary Rebuild -Stage Client } catch { $Failure = $_.Exception.Message }
	Remove-Item Env:AETHELN_TEST_SKIP_CLIENT_REGISTRY
	$env:AETHELN_TEST_ARCHIVE_ROOT = $ArchiveRoot
	Assert-True ($null -ne $Failure -and $Failure -match 'client cooked registry') "A cook that leaves no client registry must fail closed; observed '$Failure'."
	Assert-True (-not (Test-Path -LiteralPath (Join-Path $FixtureRoot 'MissingRegistryClient/phase-client.json'))) 'A cook without a registry must not publish a client stage record.'
	Write-Output 'PASS: producer-owned registry receipts bind stage records and provenance, and missing, cross-target, and cross-revision receipts fail closed'

	# Issue #226: -BuildNumber is a Provenance-stage input forwarded to the writer.
	$ReleaseProjectRoot = Join-Path $FixtureRoot 'ReleaseProject'
	New-Item -ItemType Directory -Path (Join-Path $ReleaseProjectRoot 'Config') -Force | Out-Null
	Copy-Item -LiteralPath (Join-Path $RepositoryRoot 'AethelnOnline.uproject') -Destination $ReleaseProjectRoot
	Set-Content -LiteralPath (Join-Path $ReleaseProjectRoot 'Config/DefaultGame.ini') -Value "[/Script/EngineSettings.GeneralProjectSettings]`nProjectVersion=1.0.0-alpha.1" -Encoding Ascii
	$ReleaseProject = Join-Path $ReleaseProjectRoot 'AethelnOnline.uproject'
	$ReleaseArchive = Join-Path $FixtureRoot 'ReleaseProvenance'
	& $Script -ProjectPath $ReleaseProject -EngineRoot $EngineRoot -LinuxToolchainRoot $ToolchainRoot -ArchiveRoot $ReleaseArchive -LogRoot (Join-Path $FixtureRoot 'ReleaseProvenanceLogs') -SourceRevision $Revision -Stage Provenance -ClientStageRoot $StagedClientRoot -ServerStageRoot $StagedServerRoot -BuildNumber 7
	$ReleaseProvenance = Get-Content -LiteralPath (Join-Path $ReleaseArchive 'build-provenance.json') -Raw | ConvertFrom-Json
	Assert-True ($ReleaseProvenance.release.projectVersion -ceq '1.0.0-alpha.1' -and $ReleaseProvenance.release.buildNumber -eq 7 -and $ReleaseProvenance.release.buildVersion -ceq '1.0.0-alpha.1+7') 'The Provenance stage must forward -BuildNumber so the writer records the release block.'
	$UnnumberedArchive = Join-Path $FixtureRoot 'UnnumberedProvenance'
	& $Script -ProjectPath $ReleaseProject -EngineRoot $EngineRoot -LinuxToolchainRoot $ToolchainRoot -ArchiveRoot $UnnumberedArchive -LogRoot (Join-Path $FixtureRoot 'UnnumberedProvenanceLogs') -SourceRevision $Revision -Stage Provenance -ClientStageRoot $StagedClientRoot -ServerStageRoot $StagedServerRoot
	$UnnumberedProvenance = Get-Content -LiteralPath (Join-Path $UnnumberedArchive 'build-provenance.json') -Raw | ConvertFrom-Json
	Assert-True (-not ($UnnumberedProvenance.PSObject.Properties.Name -contains 'release')) 'Without -BuildNumber the provenance writer must receive no build number, even for a project that declares ProjectVersion.'

	$CallsBeforeBuildNumberChecks = @(Get-Content -LiteralPath $CapturePath).Count
	foreach ($BadNumber in @('0', '01', 'abc', '12345678901', '')) {
		$BadArchive = Join-Path $FixtureRoot 'BadNumberArchive'
		$Failure = $null
		try { & $Script -ProjectPath $ReleaseProject -EngineRoot $EngineRoot -LinuxToolchainRoot $ToolchainRoot -ArchiveRoot $BadArchive -LogRoot (Join-Path $FixtureRoot 'BadNumberLogs') -SourceRevision $Revision -Stage Provenance -ClientStageRoot $StagedClientRoot -ServerStageRoot $StagedServerRoot -BuildNumber $BadNumber } catch { $Failure = $_.Exception.Message }
		Assert-True ($Failure -match '^build_number_invalid') "Build number '$BadNumber' must fail closed as build_number_invalid. Failure: $Failure"
		Assert-True (-not (Test-Path -LiteralPath $BadArchive)) 'An invalid build number must fail before any output root is created.'
	}
	foreach ($RejectedStage in @('Client', 'Server', 'All', 'AttestHostTools')) {
		$StageArchive = Join-Path $FixtureRoot ('BuildNumberStage' + $RejectedStage)
		$StageArguments = @{ ProjectPath = $ReleaseProject; EngineRoot = $EngineRoot; LinuxToolchainRoot = $ToolchainRoot; ArchiveRoot = $StageArchive; LogRoot = (Join-Path $FixtureRoot ('BuildNumberStageLogs' + $RejectedStage)); SourceRevision = $Revision; HostToolsBoundary = 'Rebuild'; BuildNumber = '7' }
		if ($RejectedStage -ne 'All') { $StageArguments['Stage'] = $RejectedStage }
		$Failure = $null
		try { & $Script @StageArguments } catch { $Failure = $_.Exception.Message }
		Assert-True ($Failure -match '^build_number_stage_invalid') "-BuildNumber must be rejected for stage '$RejectedStage' as build_number_stage_invalid. Failure: $Failure"
		Assert-True (-not (Test-Path -LiteralPath $StageArchive)) "A rejected -BuildNumber for stage '$RejectedStage' must fail before any output root is created."
	}
	Assert-True (@(Get-Content -LiteralPath $CapturePath).Count -eq $CallsBeforeBuildNumberChecks) 'A rejected build number must fail before any UAT invocation.'
	Write-Output 'PASS: -BuildNumber is validated, accepted only for the Provenance stage, and forwarded to the provenance writer'

	$Timing = Get-Content -LiteralPath (Join-Path $LogRoot 'build-timing.json') -Raw | ConvertFrom-Json
	Assert-True ($Timing.schemaVersion -eq 3 -and $Timing.stage -eq 'all' -and $Timing.sourceRevision -eq $Revision -and $Timing.configuration -eq 'Development') 'The timing record must bind schema, stage, source revision, and configuration.'
	Assert-True ($Timing.derivedDataCache.mode -eq 'engine-default' -and $Timing.derivedDataCache.status -eq 'not_configured') 'Without a configured cache the timing record must state the engine-default mode explicitly.'
	Assert-True ($Timing.hostTools.mode -eq 'rebuild' -and $Timing.hostTools.status -eq 'authorized_rebuild') 'An explicit Rebuild selection must be recorded as the operator-authorized rebuild.'
	Assert-True ($Timing.identity.engineGitRevision -eq $CanonicalEnginePin -and $Timing.identity.engineGitRevisionStatus -eq 'verified') 'The timing record must bind the verified engine Git identity.'
	Assert-True ($Timing.identity.engineBuildVersionSha256 -eq (Get-FileHash -LiteralPath (Join-Path $EngineRoot 'Engine/Build/Build.version') -Algorithm SHA256).Hash.ToLowerInvariant() -and $Timing.identity.engineBuildVersionSha256Status -eq 'verified') 'The timing record must bind the engine Build.version content hash.'
	Assert-True ($Timing.identity.linuxToolchainCompilerSha256 -eq (Get-FileHash -LiteralPath (Join-Path $ToolchainRoot 'x86_64-unknown-linux-gnu/bin/clang.bat') -Algorithm SHA256).Hash.ToLowerInvariant() -and $Timing.identity.linuxToolchainCompilerSha256Status -eq 'verified') 'The timing record must bind the Linux compiler content identity.'
	Assert-True ($Timing.identity.targets -eq 'AethelnOnlineClient:Win64+AethelnOnlineServer:Linux' -and $Timing.identity.runnerName -eq 'fixture-runner') 'The timing record must bind the target contract and the forwarded runner name.'
	foreach ($IdentityProperty in $Timing.identity.PSObject.Properties) {
		$IdentityValue = [string] $IdentityProperty.Value
		Assert-True (-not ($IdentityValue -match '^[A-Za-z]:' -or $IdentityValue.Contains('\'))) 'Identity evidence must carry normalized identifiers only, never machine paths.'
	}
	$SubstepNames = @($Timing.substeps | ForEach-Object { $_.name })
	foreach ($Required in @('evidence-identity-resolution', 'host-tools-boundary', 'derived-data-cache-resolution', 'target-composition-gate', 'client-uat-build-cook-package', 'client-output-validation', 'server-uat-build-cook-package', 'server-output-validation', 'server-dependency-registry-dump', 'server-cooked-inventory-dump', 'server-cook-reference-gate', 'provenance-write')) {
		Assert-True ($SubstepNames -contains $Required) "The timing record must carry substep '$Required'."
	}
	foreach ($Substep in @($Timing.substeps)) { Assert-True ($Substep.status -eq 'passed' -and [double] $Substep.durationSeconds -ge 0 -and -not [string]::IsNullOrWhiteSpace([string] $Substep.startedUtc)) 'Every successful substep must record its status, start, and duration.' }
	$UatSteps = @($Timing.uatSteps)
	Assert-True ($UatSteps.Count -eq 4) 'Both UAT invocations must attribute their BUILD and COOK step boundaries.'
	foreach ($UatStep in $UatSteps) { Assert-True ($UatStep.step -in @('BUILD', 'COOK') -and [double] $UatStep.durationSeconds -ge 0 -and $UatStep.invocation -match 'build/cook/package') 'Every UAT step must pair its start and completion markers under its invocation.' }
	$ConflictTiming = Get-Content -LiteralPath (Join-Path $FixtureRoot 'ConflictLogs/build-timing.json') -Raw | ConvertFrom-Json
	Assert-True (@($ConflictTiming.substeps | Where-Object { $_.name -eq 'client-output-validation' -and $_.status -eq 'failed' }).Count -eq 1) 'A failing substep must still be recorded in the timing record.'
	Write-Output 'PASS: every run writes a bounded machine-readable substep timing and cache-state record'

	$DdcRoot = Join-Path $FixtureRoot 'DdcCache'
	$DdcCapture = Join-Path $FixtureRoot 'ddc-env.txt'
	$env:AETHELN_TEST_DDC_CAPTURE = $DdcCapture
	$PreRunLocalDdc = [Environment]::GetEnvironmentVariable('UE-LocalDataCachePath', 'Process')
	$env:AETHELN_TEST_ARCHIVE_ROOT = Join-Path $FixtureRoot 'DdcArchive1'
	& $Script -ProjectPath $FixtureProject -EngineRoot $EngineRoot -LinuxToolchainRoot $ToolchainRoot -ArchiveRoot (Join-Path $FixtureRoot 'DdcArchive1') -LogRoot (Join-Path $FixtureRoot 'DdcLogs1') -SourceRevision $Revision -HostToolsBoundary Rebuild -DerivedDataCachePath $DdcRoot
	$IdentityPath = Join-Path $DdcRoot 'cache-identity.json'
	$Identity = Get-Content -LiteralPath $IdentityPath -Raw | ConvertFrom-Json
	$ExpectedEngineHash = (Get-FileHash -LiteralPath (Join-Path $EngineRoot 'Engine/Build/Build.version') -Algorithm SHA256).Hash.ToLowerInvariant()
	$ExpectedClangHash = (Get-FileHash -LiteralPath (Join-Path $ToolchainRoot 'x86_64-unknown-linux-gnu/bin/clang.bat') -Algorithm SHA256).Hash.ToLowerInvariant()
	Assert-True ($Identity.schemaVersion -eq 2 -and $Identity.engineGitRevision -eq $CanonicalEnginePin -and $Identity.engineBuildVersionSha256 -eq $ExpectedEngineHash) 'The identity record must bind the exact verified engine Git revision and Build.version content.'
	Assert-True ($Identity.linuxToolchain -eq 'v26_clang-20.1.8-rockylinux8' -and $Identity.linuxToolchainCompilerSha256 -eq $ExpectedClangHash) 'The identity record must bind the toolchain name and compiler content identity.'
	Assert-True ($Identity.projectRepository -eq $RealRevision -and $Identity.project -eq 'AethelnOnline.uproject' -and $Identity.configuration -eq 'Development' -and $Identity.targets -eq 'AethelnOnlineClient:Win64+AethelnOnlineServer:Linux') 'The identity record must bind repository identity, project, configuration, and targets.'
	$Timing1 = Get-Content -LiteralPath (Join-Path $FixtureRoot 'DdcLogs1/build-timing.json') -Raw | ConvertFrom-Json
	Assert-True ($Timing1.derivedDataCache.mode -eq 'persistent' -and $Timing1.derivedDataCache.status -eq 'initialized') 'A fresh cache root must be recorded as persistent/initialized.'
	$DdcEnvLines = @(Get-Content -LiteralPath $DdcCapture)
	Assert-True ($DdcEnvLines.Count -eq 2 -and @($DdcEnvLines | Where-Object { $_ -ne $DdcRoot }).Count -eq 0) 'Both UAT invocations must run with UE-LocalDataCachePath pointed at the validated cache root.'
	Assert-True ([Environment]::GetEnvironmentVariable('UE-LocalDataCachePath', 'Process') -eq $PreRunLocalDdc) 'The prior UE-LocalDataCachePath value must be restored after the run.'
	$env:AETHELN_TEST_ARCHIVE_ROOT = Join-Path $FixtureRoot 'DdcArchive2'
	& $Script -ProjectPath $FixtureProject -EngineRoot $EngineRoot -LinuxToolchainRoot $ToolchainRoot -ArchiveRoot (Join-Path $FixtureRoot 'DdcArchive2') -LogRoot (Join-Path $FixtureRoot 'DdcLogs2') -SourceRevision $Revision -HostToolsBoundary Rebuild -DerivedDataCachePath $DdcRoot
	$Timing2 = Get-Content -LiteralPath (Join-Path $FixtureRoot 'DdcLogs2/build-timing.json') -Raw | ConvertFrom-Json
	Assert-True ($Timing2.derivedDataCache.mode -eq 'persistent' -and $Timing2.derivedDataCache.status -eq 'reused') 'A matching identity record must be recorded as persistent/reused.'
	Write-Output 'PASS: the persistent cache initializes and reuses only under a matching explicit identity'

	$IdentityRaw = Get-Content -LiteralPath $IdentityPath -Raw
	($IdentityRaw -replace 'v26_clang-20\.1\.8-rockylinux8', 'v25_clang-18.1.0-rockylinux8') | Set-Content -LiteralPath $IdentityPath -Encoding UTF8
	$CallsBeforeDdcMismatch = @(Get-Content -LiteralPath $CapturePath).Count
	$Failure = $null
	try { & $Script -ProjectPath $FixtureProject -EngineRoot $EngineRoot -LinuxToolchainRoot $ToolchainRoot -ArchiveRoot (Join-Path $FixtureRoot 'DdcArchive3') -LogRoot (Join-Path $FixtureRoot 'DdcLogs3') -SourceRevision $Revision -HostToolsBoundary Rebuild -DerivedDataCachePath $DdcRoot } catch { $Failure = $_.Exception.Message }
	Assert-True ($Failure -match 'failed identity validation') 'A mismatched cache identity must fail closed by default.'
	Assert-True (@(Get-Content -LiteralPath $CapturePath).Count -eq $CallsBeforeDdcMismatch) 'A mismatched cache identity must stop before any UAT invocation.'
	$env:AETHELN_TEST_ARCHIVE_ROOT = Join-Path $FixtureRoot 'DdcArchive4'
	& $Script -ProjectPath $FixtureProject -EngineRoot $EngineRoot -LinuxToolchainRoot $ToolchainRoot -ArchiveRoot (Join-Path $FixtureRoot 'DdcArchive4') -LogRoot (Join-Path $FixtureRoot 'DdcLogs4') -SourceRevision $Revision -HostToolsBoundary Rebuild -DerivedDataCachePath $DdcRoot -CacheFallback CleanIsolated
	$Timing4 = Get-Content -LiteralPath (Join-Path $FixtureRoot 'DdcLogs4/build-timing.json') -Raw | ConvertFrom-Json
	Assert-True ($Timing4.derivedDataCache.mode -eq 'clean-isolated-fallback' -and $Timing4.derivedDataCache.status -eq 'fallback_mismatch') 'The clean fallback must be recorded with its mismatch reason.'
	$IsolatedPath = Join-Path (Join-Path $FixtureRoot 'DdcLogs4') 'ddc-clean-isolated'
	$FallbackEnvLines = @(Get-Content -LiteralPath $DdcCapture | Select-Object -Last 2)
	Assert-True (@($FallbackEnvLines | Where-Object { $_ -ne $IsolatedPath }).Count -eq 0) 'The clean fallback must re-derive into a fresh run-scoped cache, never the mismatched root.'
	Set-Content -LiteralPath $IdentityPath -Value 'not-json' -Encoding UTF8
	$env:AETHELN_TEST_ARCHIVE_ROOT = Join-Path $FixtureRoot 'DdcArchive5'
	& $Script -ProjectPath $FixtureProject -EngineRoot $EngineRoot -LinuxToolchainRoot $ToolchainRoot -ArchiveRoot (Join-Path $FixtureRoot 'DdcArchive5') -LogRoot (Join-Path $FixtureRoot 'DdcLogs5') -SourceRevision $Revision -HostToolsBoundary Rebuild -DerivedDataCachePath $DdcRoot -CacheFallback CleanIsolated
	$Timing5 = Get-Content -LiteralPath (Join-Path $FixtureRoot 'DdcLogs5/build-timing.json') -Raw | ConvertFrom-Json
	Assert-True ($Timing5.derivedDataCache.mode -eq 'clean-isolated-fallback' -and $Timing5.derivedDataCache.status -eq 'fallback_corrupt') 'A corrupt identity record must take the clean fallback with its corrupt reason.'
	$ForeignDdc = Join-Path $FixtureRoot 'ForeignDdc'
	New-Item -ItemType Directory -Path $ForeignDdc | Out-Null
	Set-Content -LiteralPath (Join-Path $ForeignDdc 'entry.bin') -Value 'foreign' -Encoding Ascii
	$CallsBeforeForeign = @(Get-Content -LiteralPath $CapturePath).Count
	$Failure = $null
	try { & $Script -ProjectPath $FixtureProject -EngineRoot $EngineRoot -LinuxToolchainRoot $ToolchainRoot -ArchiveRoot (Join-Path $FixtureRoot 'DdcArchive6') -LogRoot (Join-Path $FixtureRoot 'DdcLogs6') -SourceRevision $Revision -HostToolsBoundary Rebuild -DerivedDataCachePath $ForeignDdc } catch { $Failure = $_.Exception.Message }
	Assert-True ($Failure -match 'failed identity validation' -and @(Get-Content -LiteralPath $CapturePath).Count -eq $CallsBeforeForeign) 'A non-empty cache without an identity record is unverifiable and must fail closed before UAT.'
	$FileDdc = Join-Path $FixtureRoot 'ddc-as-file.txt'
	Set-Content -LiteralPath $FileDdc -Value 'blocking' -Encoding Ascii
	$Failure = $null
	try { & $Script -ProjectPath $FixtureProject -EngineRoot $EngineRoot -LinuxToolchainRoot $ToolchainRoot -ArchiveRoot (Join-Path $FixtureRoot 'DdcArchive7') -LogRoot (Join-Path $FixtureRoot 'DdcLogs7') -SourceRevision $Revision -HostToolsBoundary Rebuild -DerivedDataCachePath $FileDdc } catch { $Failure = $_.Exception.Message }
	Assert-True ($Failure -match 'failed identity validation') 'An unavailable cache path must fail closed by default.'
	Remove-Item Env:AETHELN_TEST_DDC_CAPTURE
	Write-Output 'PASS: cache identity mismatch, corruption, unverifiable, and unavailable states fail closed or take the recorded clean fallback'

	$MismatchTiming = Get-Content -LiteralPath (Join-Path $FixtureRoot 'DdcLogs3/build-timing.json') -Raw | ConvertFrom-Json
	Assert-True ($MismatchTiming.derivedDataCache.mode -eq 'persistent' -and $MismatchTiming.derivedDataCache.status -eq 'failed_mismatch') 'A fail-closed identity mismatch must record its failed cache state in the timing record.'
	Assert-True (@($MismatchTiming.substeps | Where-Object { $_.name -eq 'derived-data-cache-resolution' -and $_.status -eq 'failed' }).Count -eq 1) 'The failed cache-resolution substep must be recorded.'
	Assert-True (@($MismatchTiming.uatSteps).Count -eq 0) 'A fail-closed identity mismatch must record no UAT step because no UAT process started.'
	Assert-True ($MismatchTiming.identity.engineGitRevision -eq $CanonicalEnginePin -and $MismatchTiming.identity.engineGitRevisionStatus -eq 'verified') 'A failed post-LogRoot run must retain the identity fields that were verified.'
	Write-Output 'PASS: a fail-closed cache identity mismatch starts no UAT process but still emits bounded failed timing evidence'

	# Case 9 (issue #267): Rebuild and Provenance never run the in-phase project
	# editor build and never skip the host editor/engine build.
	Assert-True (-not $Calls[0].Contains('-nocompileeditor') -and -not $Calls[1].Contains('-nocompileeditor')) 'Without the prebuilt boundary the editor/engine host build must not be skipped.'
	Assert-True (-not (Test-Path -LiteralPath $EditorCapturePath)) 'Rebuild and Provenance stages must never run the in-phase project editor build.'
	$CallsBeforeUnsetBoundary = @(Get-Content -LiteralPath $CapturePath).Count
	$Failure = $null
	try { & $Script -ProjectPath $FixtureProject -EngineRoot $EngineRoot -LinuxToolchainRoot $ToolchainRoot -ArchiveRoot (Join-Path $FixtureRoot 'UnsetBoundaryArchive') -LogRoot (Join-Path $FixtureRoot 'UnsetBoundaryLogs') -SourceRevision $Revision } catch { $Failure = $_.Exception.Message }
	Assert-True ($Failure -match 'host_tools_configuration_required') 'A build without an explicit host-tools selection must fail closed, never rebuild implicitly.'
	Assert-True (@(Get-Content -LiteralPath $CapturePath).Count -eq $CallsBeforeUnsetBoundary) 'A missing host-tools selection must stop before any UAT invocation.'
	Write-Output 'PASS: a missing host-tools selection fails closed instead of launching an implicit rebuild'

	function Get-CaptureCount([string] $Path) {
		if (-not (Test-Path -LiteralPath $Path)) { return 0 }
		return @(Get-Content -LiteralPath $Path).Count
	}
	function Invoke-PackagingCase([string] $Name, [hashtable] $Arguments, [hashtable] $Override = @{}) {
		# Runs the controller on unique roots and keeps its whole output stream,
		# including a terminating error, so leakage checks see what a caller logs.
		$CaseArguments = @{ ProjectPath = $FixtureProject; EngineRoot = $EngineRoot; LinuxToolchainRoot = $ToolchainRoot; ArchiveRoot = (Join-Path $FixtureRoot ($Name + 'Archive')); LogRoot = (Join-Path $FixtureRoot ($Name + 'Logs')); SourceRevision = $Revision }
		foreach ($ArgumentSet in @($Arguments, $Override)) { foreach ($Key in $ArgumentSet.Keys) { $CaseArguments[$Key] = $ArgumentSet[$Key] } }
		$env:AETHELN_TEST_ARCHIVE_ROOT = $CaseArguments.ArchiveRoot
		$Output = New-Object System.Collections.ArrayList
		$CaseFailure = $null
		try { & $Script @CaseArguments *>&1 | ForEach-Object { [void] $Output.Add([string] $_) } } catch { $CaseFailure = $_.Exception.Message; [void] $Output.Add($CaseFailure) }
		$TimingPath = Join-Path $CaseArguments.LogRoot 'build-timing.json'
		$CaseTiming = if (Test-Path -LiteralPath $TimingPath) { Get-Content -LiteralPath $TimingPath -Raw | ConvertFrom-Json } else { $null }
		return @{ Failure = $CaseFailure; Output = ($Output -join "`n"); Timing = $CaseTiming }
	}
	function Assert-ReasonFailure($Run, [string] $Code, [string] $Context) {
		# Case 22 (SF7): each new failure code reaches the caller with the word
		# 'failed', which the gate's keep-line filter retains, and nothing else
		# from the host: no fixture path and no line of the wrapper's build.log.
		# The gate's diagnostic redacts every token of 32 or more characters, so a
		# reason code must stay a shorter lowercase identifier to reach the report.
		Assert-True ($Code.Length -lt 32 -and $Code -cmatch '^[a-z0-9_]+$') "Reason code $Code must be a lowercase identifier shorter than 32 characters so the gate's token redaction keeps it."
		Assert-True ($null -ne $Run.Failure -and ([string] $Run.Failure).StartsWith($Code + ':', [StringComparison]::Ordinal)) "$Context must fail closed with $Code; observed '$($Run.Failure)'."
		Assert-True ($Run.Failure -match '\bfailed\b') "$Context must say 'failed' so the gate keeps the reason."
		foreach ($Form in @($FixtureRoot, $FixtureRoot.Replace('\', '/'))) {
			Assert-True ($Run.Output.IndexOf($Form, [StringComparison]::OrdinalIgnoreCase) -lt 0) "$Context output must not disclose a fixture path."
		}
		Assert-True ($Run.Output.IndexOf($PlantedBuildLogLine, [StringComparison]::OrdinalIgnoreCase) -lt 0) "$Context output must not repeat any build.log line."
	}
	function Assert-HostEditorBuildStep($Run, [string] $Status, [string] $Context) {
		Assert-True ($null -ne $Run.Timing -and @($Run.Timing.substeps | Where-Object { $_.name -eq 'host-editor-modules-build' -and $_.status -eq $Status }).Count -eq 1) "$Context must record the host-editor-modules-build step as $Status."
	}

	# Case 2: the attestation step builds only the project editor modules, then
	# writes schema 2 from the receipt that build wrote.
	$AttestationDirectory = Join-Path $FixtureRoot 'Attestation'
	New-Item -ItemType Directory -Path $AttestationDirectory | Out-Null
	$AttestationPath = Join-Path $AttestationDirectory 'host-tools-attestation.json'
	$UatBeforeAttest = Get-CaptureCount $CapturePath
	$Run = Invoke-PackagingCase 'Attest' @{ Stage = 'AttestHostTools'; HostToolsAttestationPath = $AttestationPath; ProvisioningEvidence = 'issue-267 fixture provisioning note, retained runner evidence 2026-10-06' }
	Assert-True ($null -eq $Run.Failure) "The attestation step must succeed on a fresh fixture checkout; observed '$($Run.Failure)'."
	Assert-True ((Get-CaptureCount $CapturePath) -eq $UatBeforeAttest) 'The attestation step must never run UAT.'
	Assert-True ((Get-CaptureCount $EditorCapturePath) -eq 1) 'The attestation step must run exactly one in-phase project editor build.'
	Assert-HostEditorBuildStep $Run 'passed' -Context 'The attestation step'
	$Attestation = Get-Content -LiteralPath $AttestationPath -Raw | ConvertFrom-Json
	Assert-True ($Attestation.schemaVersion -eq 2 -and $Attestation.engineGitRevision -eq $CanonicalEnginePin -and $Attestation.projectRevision -ceq $Revision) 'A schema-2 attestation must bind the canonical engine pin and the attesting project HEAD.'
	$RequiredToolPaths = @(
		'Engine/Binaries/Win64/UnrealEditor.exe',
		'Engine/Binaries/Win64/UnrealEditor-Cmd.exe',
		'Engine/Binaries/Win64/UnrealEditor-Core.dll',
		'Engine/Binaries/Win64/UnrealEditor-NetCore.dll',
		'Engine/Plugins/FixturePlugin/Binaries/Win64/UnrealEditor-FixturePlugin.dll',
		'Engine/Binaries/Win64/UnrealEditor.modules',
		'Engine/Plugins/FixturePlugin/Binaries/Win64/UnrealEditor.modules',
		'Engine/Binaries/Win64/UnrealEditor.version',
		'Engine/Binaries/Win64/ShaderCompileWorker.target',
		'Engine/Binaries/Win64/ShaderCompileWorker.exe',
		'Engine/Binaries/Win64/ShaderCompileWorker.modules'
	)
	$AttestedPaths = @($Attestation.files | ForEach-Object { [string] $_.path } | Sort-Object)
	Assert-True (($AttestedPaths -join ';') -eq (@($RequiredToolPaths | Sort-Object) -join ';')) "The attestation must record exactly the project receipt's engine-side products plus the ShaderCompileWorker receipt and products, with no UnrealPak, project, or symbol entries. Observed: $($AttestedPaths -join ';')"
	foreach ($AttestedFile in @($Attestation.files)) {
		$OnDisk = Join-Path $EngineRoot ([string] $AttestedFile.path)
		Assert-True (([string] $AttestedFile.sha256) -ceq (Get-FileHash -LiteralPath $OnDisk -Algorithm SHA256).Hash.ToLowerInvariant() -and [long] $AttestedFile.sizeBytes -eq (Get-Item -LiteralPath $OnDisk).Length) "Attested file '$($AttestedFile.path)' must carry its byte-exact SHA-256 and size."
	}
	Assert-True ($Attestation.provisioningEvidence -match 'retained runner evidence') 'The attestation must record the explicit provisioning evidence reference.'
	Assert-True ($Run.Timing.hostTools.mode -eq 'attest' -and $Run.Timing.hostTools.status -eq 'written') 'The attestation step must record its state in the timing record.'
	Write-Output 'PASS: the attestation step builds only the project editor modules and writes schema 2 from the engine-side receipt closure, ShaderCompileWorker, and the project HEAD'

	# Cases 1 and 10: a verified prebuilt phase runs the reviewed wrapper build
	# first, verifies the record whose hash the gate reported, then runs UAT. The
	# wrapper owns the per-target UBT flags (TA-020), pinned by
	# tests/ci/InitialPreparation.Build.Tests.ps1; this test pins what the
	# controller passes and the order.
	$PrebuiltArguments = @{ HostToolsBoundary = 'Prebuilt'; EngineRevision = $CanonicalEnginePin; HostToolsAttestationPath = $AttestationPath }
	$AttestationSha256 = (Get-FileHash -LiteralPath $AttestationPath -Algorithm SHA256).Hash.ToLowerInvariant()
	$EditorBefore = Get-CaptureCount $EditorCapturePath
	$UatBefore = Get-CaptureCount $CapturePath
	$Run = Invoke-PackagingCase 'PrebuiltClient' $PrebuiltArguments -Override @{ Stage = 'Client'; HostToolsAttestationSha256 = $AttestationSha256; RunnerName = 'fixture-runner' }
	Assert-True ($null -eq $Run.Failure) "A verified prebuilt client phase must pass; observed '$($Run.Failure)'."
	$EditorCalls = @(Get-Content -LiteralPath $EditorCapturePath)
	Assert-True ($EditorCalls.Count -eq $EditorBefore + 1) 'The prebuilt phase must run the project editor build exactly once.'
	Assert-True ($EditorCalls[-1].Contains('AethelnOnlineEditor Win64 Development') -and $EditorCalls[-1].Contains($FixtureProject) -and $EditorCalls[-1].Contains('-WaitMutex')) 'The in-phase build must be the wrapper invocation of AethelnOnlineEditor Win64 Development for this project with -WaitMutex.'
	Assert-True (-not $EditorCalls[-1].Contains('-Compiler=') -and -not $EditorCalls[-1].Contains('-clean')) 'The in-phase editor build must keep the TA-020 compiler selection and never clean.'
	$UatCalls = @(Get-Content -LiteralPath $CapturePath)
	Assert-True ($UatCalls.Count -eq $UatBefore + 1 -and $UatCalls[-1].Contains('-nocompileeditor') -and $UatCalls[-1].Contains('-clean')) 'After verification UAT must run once with -nocompileeditor and -clean.'
	Assert-True ((@(Get-Content -LiteralPath $OrderPath | Select-Object -Last 2) -join ',') -ceq 'editor,uat') 'The project editor build must run before UAT.'
	Assert-HostEditorBuildStep $Run 'passed' -Context 'A verified prebuilt phase'
	$HostTools = $Run.Timing.hostTools
	Assert-True ($HostTools.mode -eq 'prebuilt' -and $HostTools.status -eq 'verified' -and $HostTools.engineRevision -eq $CanonicalEnginePin) 'The verified prebuilt boundary must be recorded in the timing record.'
	Assert-True ($HostTools.attestationSha256 -ceq $AttestationSha256 -and [string] $HostTools.attestationCreatedUtc -ceq [string] $Attestation.createdUtc -and $HostTools.attestationSchemaVersion -eq 2 -and $HostTools.attestedProjectRevision -ceq $Revision) 'The timing record must bind the verified record hash, creation time, schema, and attested project revision.'
	Assert-True ($Run.Timing.identity.runnerName -eq 'fixture-runner') 'The forwarded runner name must be bound into the timing identity.'
	$UatBefore = Get-CaptureCount $CapturePath
	$Run = Invoke-PackagingCase 'PrebuiltAll' $PrebuiltArguments
	Assert-True ($null -eq $Run.Failure) "A local prebuilt run without the gate hash must pass; observed '$($Run.Failure)'."
	$UatCalls = @(Get-Content -LiteralPath $CapturePath)
	Assert-True ($UatCalls.Count -eq $UatBefore + 2) 'The verified prebuilt boundary must still run both UAT invocations.'
	foreach ($PrebuiltCall in @($UatCalls | Select-Object -Last 2)) {
		Assert-True ($PrebuiltCall.Contains('-nocompileeditor') -and $PrebuiltCall.Contains('-clean')) 'A verified prebuilt boundary must pass -nocompileeditor and keep -clean for the client and server project targets.'
	}
	Write-Output 'PASS: a prebuilt phase builds the project editor modules first, verifies the hashed record, and then runs UAT with -nocompileeditor'

	# Case 3 (AC2): what UAT rebuilds in every package phase, and unreceipted
	# non-manifest engine binaries, are outside the closure.
	foreach ($Relinked in @('UnrealPak.exe', 'UnrealPak.target', 'UnrealPak.modules', 'UnrealPak-PakFile.dll')) {
		Set-Content -LiteralPath (Join-Path $EditorDirectory $Relinked) -Value 'relinked by the previous package phase' -Encoding Ascii
	}
	Set-Content -LiteralPath (Join-Path $EditorDirectory 'UnrealEditor-Extra.dll') -Value 'unreceipted engine module' -Encoding Ascii
	Set-Content -LiteralPath (Join-Path $EditorDirectory 'BootstrapPackagedGame-Win64-Shipping.exe') -Value 'rebuilt bootstrap' -Encoding Ascii
	foreach ($PhaseStage in @('Client', 'Server')) {
		$Run = Invoke-PackagingCase ('OutOfClosure' + $PhaseStage) $PrebuiltArguments -Override @{ Stage = $PhaseStage; HostToolsAttestationSha256 = $AttestationSha256 }
		Assert-True ($null -eq $Run.Failure) "A $PhaseStage phase after UnrealPak and BootstrapPackagedGame rebuilds must pass; observed '$($Run.Failure)'."
	}
	Write-Output 'PASS: UnrealPak, BootstrapPackagedGame, and unreceipted engine binaries rebuilt outside the closure no longer fail a later package phase'

	# Case 4 (AC2): every in-closure change before the run fails closed.
	$EditorCmdPath = Join-Path $EditorDirectory 'UnrealEditor-Cmd.exe'
	$UatBefore = Get-CaptureCount $CapturePath
	foreach ($Mutation in @(
		@{ Label = 'NetCoreByte'; Path = $NetCoreDllPath; From = 'netcore'; To = 'netcorf' },
		@{ Label = 'ManifestModule'; Path = $RootManifestPath; From = 'UnrealEditor-Core.dll'; To = 'UnrealEditor-Evil.dll' },
		@{ Label = 'ManifestBuildId'; Path = $PluginManifestPath; From = $FixtureBuildId; To = $FixtureBuildId.Replace('b0f4', 'b0f5') },
		@{ Label = 'VersionBuildId'; Path = $EditorVersionPath; From = '"BuildId":"fixture"'; To = '"BuildId":"fixturf"' },
		@{ Label = 'ScwExecutable'; Path = $ScwExecutablePath; From = 'fixture'; To = 'mixture' },
		@{ Label = 'ScwReceipt'; Path = $ScwReceiptPath; From = '"BuildProducts":['; To = '"BuildProducts": [' },
		@{ Label = 'EditorCmd'; Path = $EditorCmdPath; From = $null; To = $null }
	)) {
		$OriginalBytes = [System.IO.File]::ReadAllBytes($Mutation.Path)
		try {
			if ($null -eq $Mutation.From) {
				[System.IO.File]::WriteAllBytes($Mutation.Path, [byte[]] ($OriginalBytes + [byte] 0))
			} else {
				$Text = [System.IO.File]::ReadAllText($Mutation.Path)
				Assert-True ($Text.Contains($Mutation.From)) "In-closure mutation $($Mutation.Label) must find its anchor."
				[System.IO.File]::WriteAllText($Mutation.Path, $Text.Replace($Mutation.From, $Mutation.To))
			}
			$Run = Invoke-PackagingCase ('InClosure' + $Mutation.Label) $PrebuiltArguments -Override @{ Stage = 'Client' }
		} finally { [System.IO.File]::WriteAllBytes($Mutation.Path, $OriginalBytes) }
		Assert-True ($null -ne $Run.Failure -and $Run.Failure -match 'does not match its attest') "An in-closure change ($($Mutation.Label)) must fail closed on content; observed '$($Run.Failure)'."
	}
	Assert-True ((Get-CaptureCount $CapturePath) -eq $UatBefore) 'Every in-closure change must stop before UAT.'
	Write-Output 'PASS: NetCore, manifest module and BuildId, version file, ShaderCompileWorker, and editor executable changes fail closed before UAT'

	# Case 5: the in-phase receipt's engine-side set must equal the record's set.
	$UatBefore = Get-CaptureCount $CapturePath
	foreach ($SetCase in @(
		@{ Label = 'ExtraProduct'; Body = $EditorReceiptBody.Replace('{"Path":"$(EngineDir)/Binaries/Win64/UnrealEditor-Core.dll","Type":"DynamicLibrary"},', '{"Path":"$(EngineDir)/Binaries/Win64/UnrealEditor-Core.dll","Type":"DynamicLibrary"},{"Path":"$(EngineDir)/Binaries/Win64/UnrealEditor-Extra.dll","Type":"DynamicLibrary"},') },
		@{ Label = 'OmittedProduct'; Body = $EditorReceiptBody.Replace('{"Path":"$(EngineDir)/Binaries/Win64/UnrealEditor-NetCore.dll","Type":"DynamicLibrary"},', '') }
	)) {
		Assert-True ($SetCase.Body -cne $EditorReceiptBody) "Receipt variant $($SetCase.Label) must differ from the good receipt."
		$env:AETHELN_TEST_EDITOR_RECEIPT = Write-EditorReceipt $SetCase.Label $SetCase.Body
		try { $Run = Invoke-PackagingCase ('SetEquality' + $SetCase.Label) $PrebuiltArguments -Override @{ Stage = 'Client' } } finally { $env:AETHELN_TEST_EDITOR_RECEIPT = $GoodEditorReceipt }
		Assert-True ($null -ne $Run.Failure -and $Run.Failure -match 'receipt-derived host build products; found') "An in-phase receipt with $($SetCase.Label) must fail set equality; observed '$($Run.Failure)'."
	}
	Assert-True ((Get-CaptureCount $CapturePath) -eq $UatBefore) 'A set-equality failure must stop before UAT.'
	Write-Output 'PASS: an extra or omitted engine-side receipt product fails set equality before UAT'

	# Cases 6 and 10: the in-phase build's outcome maps to one fixed reason and
	# stops the phase before verification and UAT.
	$UatBefore = Get-CaptureCount $CapturePath
	foreach ($BuildCase in @(
		@{ Label = 'EngineChanges'; Exit = '5'; Post = $null; Code = 'host_editor_engine_changes' },
		@{ Label = 'Failed'; Exit = '2'; Post = $null; Code = 'host_editor_build_failed' },
		@{ Label = 'CaptureOverflow'; Exit = $null; Post = 'flood'; Code = 'host_editor_capture_failed' },
		@{ Label = 'ResultMissing'; Exit = $null; Post = 'nodotnet'; Code = 'host_editor_capture_failed' }
	)) {
		if ($null -ne $BuildCase.Exit) { $env:AETHELN_TEST_EDITOR_EXIT = $BuildCase.Exit }
		if ($BuildCase.Post -ceq 'flood') { $env:AETHELN_TEST_EDITOR_POST = 'flood' }
		if ($BuildCase.Post -ceq 'nodotnet') { Rename-Item -LiteralPath $FakeDotnetPath -NewName 'dotnet.exe.hidden' }
		try { $Run = Invoke-PackagingCase ('Build' + $BuildCase.Label) $PrebuiltArguments -Override @{ Stage = 'Client' } }
		finally {
			Remove-Item -Path Env:AETHELN_TEST_EDITOR_EXIT, Env:AETHELN_TEST_EDITOR_POST -ErrorAction SilentlyContinue
			if ($BuildCase.Post -ceq 'nodotnet') { Rename-Item -LiteralPath ($FakeDotnetPath + '.hidden') -NewName 'dotnet.exe' }
		}
		Assert-ReasonFailure $Run $BuildCase.Code -Context "An in-phase editor build ($($BuildCase.Label))"
		Assert-HostEditorBuildStep $Run 'failed' -Context "An in-phase editor build ($($BuildCase.Label))"
	}
	Assert-True ((Get-CaptureCount $CapturePath) -eq $UatBefore) 'A failed in-phase editor build must stop before verification and UAT.'
	Write-Output 'PASS: exit 5, other build failures, and capture failures of the in-phase build fail closed with fixed path-free reasons'

	# Case 7: receipt products outside $(EngineDir) and $(ProjectDir)/Binaries/Win64.
	foreach ($PrefixCase in @(
		@{ Label = 'ForeignPrefix'; To = '"$(PluginDir)/Binaries/Win64/UnrealEditor-GameCore.dll"' },
		@{ Label = 'ProjectEscape'; To = '"$(ProjectDir)/../UnrealEditor-GameCore.dll"' },
		@{ Label = 'ProjectOutsideBinaries'; To = '"$(ProjectDir)/Source/UnrealEditor-GameCore.dll"' }
	)) {
		$env:AETHELN_TEST_EDITOR_RECEIPT = Write-EditorReceipt $PrefixCase.Label ($EditorReceiptBody.Replace('"$(ProjectDir)/Binaries/Win64/UnrealEditor-GameCore.dll"', $PrefixCase.To))
		try { $Run = Invoke-PackagingCase ('Prefix' + $PrefixCase.Label) $PrebuiltArguments -Override @{ Stage = 'Client' } } finally { $env:AETHELN_TEST_EDITOR_RECEIPT = $GoodEditorReceipt }
		Assert-ReasonFailure $Run 'host_tools_receipt_invalid' -Context "A receipt product with $($PrefixCase.Label)"
	}
	Write-Output 'PASS: foreign prefixes, project escapes, and project products outside Binaries/Win64 fail closed'

	# Case 8: a schema-1 record is rejected before any build.
	$V1AttestationPath = Join-Path $AttestationDirectory 'v1-attestation.json'
	$V1Record = Get-Content -LiteralPath $AttestationPath -Raw | ConvertFrom-Json
	$V1Record.schemaVersion = 1
	$V1Record.PSObject.Properties.Remove('projectRevision')
	$V1Record | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $V1AttestationPath -Encoding UTF8
	$EditorBefore = Get-CaptureCount $EditorCapturePath
	$Run = Invoke-PackagingCase 'V1Record' $PrebuiltArguments -Override @{ Stage = 'Client'; HostToolsAttestationPath = $V1AttestationPath }
	Assert-True ($null -ne $Run.Failure -and $Run.Failure -match "missing required property 'projectRevision'") "A schema-1 record must be rejected; observed '$($Run.Failure)'."
	Assert-True ((Get-CaptureCount $EditorCapturePath) -eq $EditorBefore) 'A rejected record must stop before the in-phase build.'
	Write-Output 'PASS: a schema-1 attestation record is rejected before any build'

	# Cases 11-13 (B2): verification runs after the build, so a build that exits
	# 0 and still changed the closure, or wrote no valid receipt, fails closed.
	$UatBefore = Get-CaptureCount $CapturePath
	foreach ($PostCase in @(
		@{ Label = 'Dll'; Post = 'dll'; Path = $NetCoreDllPath },
		@{ Label = 'Manifest'; Post = 'manifest'; Path = $RootManifestPath }
	)) {
		$OriginalBytes = [System.IO.File]::ReadAllBytes($PostCase.Path)
		$OriginalHash = (Get-FileHash -LiteralPath $PostCase.Path -Algorithm SHA256).Hash
		$EditorBefore = Get-CaptureCount $EditorCapturePath
		$env:AETHELN_TEST_EDITOR_POST = $PostCase.Post
		try {
			$Run = Invoke-PackagingCase ('PostBuild' + $PostCase.Label) $PrebuiltArguments -Override @{ Stage = 'Client' }
			$PostBuildHash = (Get-FileHash -LiteralPath $PostCase.Path -Algorithm SHA256).Hash
		} finally {
			Remove-Item -Path Env:AETHELN_TEST_EDITOR_POST -ErrorAction SilentlyContinue
			[System.IO.File]::WriteAllBytes($PostCase.Path, $OriginalBytes)
		}
		Assert-True ((Get-CaptureCount $EditorCapturePath) -eq $EditorBefore + 1 -and $PostBuildHash -cne $OriginalHash) "The fake build must have run and changed the closure $($PostCase.Label)."
		Assert-True ($null -ne $Run.Failure -and $Run.Failure -match 'does not match its attest') "A closure $($PostCase.Label) change by a build that exits 0 must fail closed; observed '$($Run.Failure)'."
	}
	foreach ($ReceiptCase in @(
		@{ Label = 'Missing'; Receipt = $null },
		@{ Label = 'OtherTarget'; Receipt = (Write-EditorReceipt 'other-target' $EditorReceiptBody.Replace('"TargetName":"AethelnOnlineEditor"', '"TargetName":"UnrealEditor"')) },
		@{ Label = 'OtherType'; Receipt = (Write-EditorReceipt 'other-type' $EditorReceiptBody.Replace('"TargetType":"Editor"', '"TargetType":"Program"')) }
	)) {
		if ($null -eq $ReceiptCase.Receipt) { Remove-Item -Path Env:AETHELN_TEST_EDITOR_RECEIPT } else { $env:AETHELN_TEST_EDITOR_RECEIPT = $ReceiptCase.Receipt }
		try { $Run = Invoke-PackagingCase ('Receipt' + $ReceiptCase.Label) $PrebuiltArguments -Override @{ Stage = 'Client' } } finally { $env:AETHELN_TEST_EDITOR_RECEIPT = $GoodEditorReceipt }
		Assert-ReasonFailure $Run 'host_tools_receipt_invalid' -Context "A build that exits 0 with receipt case $($ReceiptCase.Label)"
	}
	Assert-True ((Get-CaptureCount $CapturePath) -eq $UatBefore) 'A post-build closure change or receipt failure must stop before UAT.'
	Write-Output 'PASS: build-then-verify order holds: post-build DLL and manifest changes and missing or foreign receipts fail closed before UAT'

	# Cases 14-16 (B1): any UnrealEditor.modules or ShaderCompileWorker.modules
	# in the scanned engine trees must be a closure member, whatever its BuildId,
	# and no reparse-point directory may sit in those trees.
	$UatBefore = Get-CaptureCount $CapturePath
	foreach ($ManifestCase in @(
		@{ Label = 'Subdirectory'; Path = 'Engine/Binaries/Win64/Extra/UnrealEditor.modules'; Cleanup = 'Engine/Binaries/Win64/Extra'; Body = ('{"BuildId":"' + $FixtureBuildId + '","Modules":{"Core":"UnrealEditor-Extra.dll"}}') },
		@{ Label = 'CaseVariant'; Path = 'Engine/Binaries/Win64/Extra/UNREALEDITOR.MODULES'; Cleanup = 'Engine/Binaries/Win64/Extra'; Body = ('{"BuildId":"' + $FixtureBuildId + '","Modules":{"Core":"UnrealEditor-Extra.dll"}}') },
		@{ Label = 'Bridge'; Path = 'Engine/Plugins/Bridge/Binaries/Win64/Extra/UnrealEditor.modules'; Cleanup = 'Engine/Plugins/Bridge'; Body = '{"BuildId":"foreign-build-id","Modules":{"Core":"UnrealEditor-Extra.dll"}}' },
		@{ Label = 'ShaderCompileWorker'; Path = 'Engine/Binaries/Win64/Extra/ShaderCompileWorker.modules'; Cleanup = 'Engine/Binaries/Win64/Extra'; Body = '{"BuildId":"scw-fixture","Modules":{"ShaderCore":"UnrealEditor-Extra.dll"}}' }
	)) {
		$ExtraManifest = Join-Path $EngineRoot $ManifestCase.Path
		New-Item -ItemType Directory -Path (Split-Path -Parent $ExtraManifest) -Force | Out-Null
		Set-Content -LiteralPath $ExtraManifest -Value $ManifestCase.Body -Encoding UTF8
		try { $Run = Invoke-PackagingCase ('ExtraManifest' + $ManifestCase.Label) $PrebuiltArguments -Override @{ Stage = 'Client' } } finally { Remove-Item -LiteralPath (Join-Path $EngineRoot $ManifestCase.Cleanup) -Recurse -Force }
		Assert-ReasonFailure $Run 'host_tools_manifest_set_invalid' -Context "An extra engine module manifest ($($ManifestCase.Label))"
	}
	$ManifestJunctionTarget = Join-Path $FixtureRoot 'ManifestJunctionTarget'
	New-Item -ItemType Directory -Path $ManifestJunctionTarget | Out-Null
	$PluginJunction = Join-Path $EngineRoot 'Engine/Plugins/JunctionPlugin'
	New-Item -ItemType Junction -Path $PluginJunction -Value $ManifestJunctionTarget | Out-Null
	try { $Run = Invoke-PackagingCase 'ManifestJunction' $PrebuiltArguments -Override @{ Stage = 'Client' } } finally { [System.IO.Directory]::Delete($PluginJunction) }
	Assert-ReasonFailure $Run 'host_tools_manifest_set_invalid' -Context 'A directory junction under Engine/Plugins'
	Assert-True ((Get-CaptureCount $CapturePath) -eq $UatBefore) 'A manifest-set failure must stop before UAT.'
	Write-Output 'PASS: extra engine module manifests (subdirectory, case variant, Bridge, ShaderCompileWorker) and reparse-point directories fail the manifest-set check'

	# Case 17 (S2): the receipt's LaunchCmd and Launch must name the attested
	# engine editor executables, because UAT runs LaunchCmd for the cook.
	foreach ($LaunchCase in @(
		@{ Label = 'LaunchCmd'; From = '"LaunchCmd":"$(EngineDir)/Binaries/Win64/UnrealEditor-Cmd.exe"'; To = '"LaunchCmd":"$(ProjectDir)/Binaries/Win64/UnrealEditor-Cmd.exe"' },
		@{ Label = 'Launch'; From = '"Launch":"$(EngineDir)/Binaries/Win64/UnrealEditor.exe"'; To = '"Launch":"$(EngineDir)/Binaries/Win64/UnrealEditor-Extra.exe"' }
	)) {
		Assert-True ($EditorReceiptBody.Contains($LaunchCase.From)) "Launch variant $($LaunchCase.Label) must find its anchor."
		$env:AETHELN_TEST_EDITOR_RECEIPT = Write-EditorReceipt ('launch-' + $LaunchCase.Label) $EditorReceiptBody.Replace($LaunchCase.From, $LaunchCase.To)
		try { $Run = Invoke-PackagingCase ('Launch' + $LaunchCase.Label) $PrebuiltArguments -Override @{ Stage = 'Client' } } finally { $env:AETHELN_TEST_EDITOR_RECEIPT = $GoodEditorReceipt }
		Assert-ReasonFailure $Run 'host_tools_launch_invalid' -Context "A receipt whose $($LaunchCase.Label) is not the engine editor executable"
	}
	Write-Output 'PASS: a receipt LaunchCmd or Launch outside the attested engine editor executables fails closed'

	# Case 18 (S3): a set UE_ADDITIONAL_PLUGIN_PATHS stops prebuilt packaging and
	# attestation before the build; Rebuild is unaffected.
	$EditorBefore = Get-CaptureCount $EditorCapturePath
	$PluginPathsAttestation = Join-Path $AttestationDirectory 'plugin-paths-attestation.json'
	[Environment]::SetEnvironmentVariable('UE_ADDITIONAL_PLUGIN_PATHS', (Join-Path $FixtureRoot 'PrivateArtPlugins'), 'Process')
	try {
		$PrebuiltRun = Invoke-PackagingCase 'PluginPathsPrebuilt' $PrebuiltArguments -Override @{ Stage = 'Client' }
		$AttestRun = Invoke-PackagingCase 'PluginPathsAttest' @{ Stage = 'AttestHostTools'; HostToolsAttestationPath = $PluginPathsAttestation; ProvisioningEvidence = 'fixture evidence' }
		$RebuildRun = Invoke-PackagingCase 'PluginPathsRebuild' @{ Stage = 'Client'; HostToolsBoundary = 'Rebuild' }
	} finally { [Environment]::SetEnvironmentVariable('UE_ADDITIONAL_PLUGIN_PATHS', $null, 'Process') }
	Assert-ReasonFailure $PrebuiltRun 'host_tools_plugin_paths_set' -Context 'Prebuilt packaging with UE_ADDITIONAL_PLUGIN_PATHS set'
	Assert-ReasonFailure $AttestRun 'host_tools_plugin_paths_set' -Context 'Attestation with UE_ADDITIONAL_PLUGIN_PATHS set'
	Assert-True (-not (Test-Path -LiteralPath $PluginPathsAttestation)) 'A refused attestation must write no record.'
	Assert-True ((Get-CaptureCount $EditorCapturePath) -eq $EditorBefore) 'A set private-plugin path must stop before the in-phase build.'
	Assert-True ($null -eq $RebuildRun.Failure) "The plugin-path refusal must not affect Rebuild; observed '$($RebuildRun.Failure)'."
	Write-Output 'PASS: a set UE_ADDITIONAL_PLUGIN_PATHS stops prebuilt packaging and attestation before the build and leaves Rebuild unchanged'

	# Cases 19-21 (SF1): the record whose bytes are verified is the record whose
	# hash the gate reported; the hash is a prebuilt-only input; the attest step
	# binds projectRevision to the checked-out HEAD.
	$EditorBefore = Get-CaptureCount $EditorCapturePath
	$UatBefore = Get-CaptureCount $CapturePath
	$Run = Invoke-PackagingCase 'AttestationChanged' $PrebuiltArguments -Override @{ Stage = 'Client'; HostToolsAttestationSha256 = ('0' * 64) }
	Assert-ReasonFailure $Run 'host_tools_attestation_changed' -Context 'A record that differs from the gate-reported hash'
	foreach ($MisuseCase in @(
		@{ Label = 'Rebuild'; Arguments = @{ Stage = 'Client'; HostToolsBoundary = 'Rebuild'; HostToolsAttestationSha256 = $AttestationSha256 }; Expect = 'only accepted with -HostToolsBoundary Prebuilt' },
		@{ Label = 'Provenance'; Arguments = @{ Stage = 'Provenance'; ClientStageRoot = $StagedClientRoot; ServerStageRoot = $StagedServerRoot; HostToolsAttestationSha256 = $AttestationSha256 }; Expect = 'does not accept host-tools parameters' },
		@{ Label = 'Attest'; Arguments = @{ Stage = 'AttestHostTools'; HostToolsAttestationPath = (Join-Path $AttestationDirectory 'hash-misuse-attestation.json'); ProvisioningEvidence = 'fixture evidence'; HostToolsAttestationSha256 = $AttestationSha256 }; Expect = 'does not accept -HostToolsAttestationSha256' },
		@{ Label = 'Malformed'; Arguments = ($PrebuiltArguments + @{ Stage = 'Client'; HostToolsAttestationSha256 = 'not-a-sha256' }); Expect = 'Cannot validate argument on parameter .HostToolsAttestationSha256.' }
	)) {
		$Run = Invoke-PackagingCase ('HashMisuse' + $MisuseCase.Label) $MisuseCase.Arguments
		Assert-True ($null -ne $Run.Failure -and $Run.Failure -match $MisuseCase.Expect) "-HostToolsAttestationSha256 with $($MisuseCase.Label) must be rejected; observed '$($Run.Failure)'."
	}
	$MismatchAttestation = Join-Path $AttestationDirectory 'revision-mismatch-attestation.json'
	$Run = Invoke-PackagingCase 'AttestRevisionMismatch' @{ Stage = 'AttestHostTools'; HostToolsAttestationPath = $MismatchAttestation; ProvisioningEvidence = 'fixture evidence'; SourceRevision = ('1' * 40) }
	Assert-ReasonFailure $Run 'host_tools_revision_mismatch' -Context 'Attestation with -SourceRevision other than the project HEAD'
	Assert-True (-not (Test-Path -LiteralPath $MismatchAttestation)) 'A revision-mismatched attestation must write no record.'
	Assert-True ((Get-CaptureCount $EditorCapturePath) -eq $EditorBefore -and (Get-CaptureCount $CapturePath) -eq $UatBefore) 'Hash and revision binding failures must stop before any build.'
	Write-Output 'PASS: the gate-reported record hash, its prebuilt-only scope, and the attested project revision are enforced before any build'

	$CallsBeforeInvalidBoundary = @(Get-Content -LiteralPath $CapturePath).Count
	$Failure = $null
	try { & $Script -ProjectPath $FixtureProject -EngineRoot $EngineRoot -LinuxToolchainRoot $ToolchainRoot -ArchiveRoot (Join-Path $FixtureRoot 'PrebuiltNoAttestArchive') -LogRoot (Join-Path $FixtureRoot 'PrebuiltNoAttestLogs') -SourceRevision $Revision -HostToolsBoundary Prebuilt -EngineRevision $CanonicalEnginePin } catch { $Failure = $_.Exception.Message }
	Assert-True ($Failure -match 'requires -HostToolsAttestationPath') 'The prebuilt boundary without an attestation record must fail closed.'

	$env:AETHELN_TEST_ENGINE_HEAD = ('5' * 40)
	$Failure = $null
	try { & $Script -ProjectPath $FixtureProject -EngineRoot $EngineRoot -LinuxToolchainRoot $ToolchainRoot -ArchiveRoot (Join-Path $FixtureRoot 'PrebuiltWrongPinArchive') -LogRoot (Join-Path $FixtureRoot 'PrebuiltWrongPinLogs') -SourceRevision $Revision -HostToolsBoundary Prebuilt -EngineRevision ('5' * 40) -HostToolsAttestationPath $AttestationPath } catch { $Failure = $_.Exception.Message }
	Assert-True ($Failure -match 'canonical pinned engine revision') 'A wrong-but-checkout-matching engine SHA must fail closed as noncanonical.'
	$Failure = $null
	try { & $Script -ProjectPath $FixtureProject -EngineRoot $EngineRoot -LinuxToolchainRoot $ToolchainRoot -ArchiveRoot (Join-Path $FixtureRoot 'PrebuiltWrongHeadArchive') -LogRoot (Join-Path $FixtureRoot 'PrebuiltWrongHeadLogs') -SourceRevision $Revision -HostToolsBoundary Prebuilt -EngineRevision $CanonicalEnginePin -HostToolsAttestationPath $AttestationPath } catch { $Failure = $_.Exception.Message }
	Assert-True ($Failure -match 'not the canonical pinned') 'An engine checkout away from the canonical pin must fail the prebuilt boundary closed.'
	$WrongHeadTiming = Get-Content -LiteralPath (Join-Path $FixtureRoot 'PrebuiltWrongHeadLogs/build-timing.json') -Raw | ConvertFrom-Json
	Assert-True (@($WrongHeadTiming.substeps | Where-Object { $_.name -eq 'host-tools-boundary' -and $_.status -eq 'failed' }).Count -eq 1) 'A failed prebuilt boundary must still emit bounded failed timing evidence.'
	Assert-True ($WrongHeadTiming.identity.engineGitRevision -eq ('5' * 40) -and $WrongHeadTiming.identity.engineGitRevisionStatus -eq 'verified') 'Failed-boundary timing evidence must retain the engine identity that was actually observed.'
	$env:AETHELN_TEST_ENGINE_HEAD = ''

	$env:AETHELN_TEST_ENGINE_GIT_STATUS = ' M Engine/Source/Runtime/Core/Private/Core.cpp'
	$Failure = $null
	try { & $Script -ProjectPath $FixtureProject -EngineRoot $EngineRoot -LinuxToolchainRoot $ToolchainRoot -ArchiveRoot (Join-Path $FixtureRoot 'PrebuiltDirtyArchive') -LogRoot (Join-Path $FixtureRoot 'PrebuiltDirtyLogs') -SourceRevision $Revision -HostToolsBoundary Prebuilt -EngineRevision $CanonicalEnginePin -HostToolsAttestationPath $AttestationPath } catch { $Failure = $_.Exception.Message }
	Assert-True ($Failure -match 'clean canonical pinned engine checkout') 'A dirty engine checkout must fail the prebuilt boundary closed.'
	$env:AETHELN_TEST_ENGINE_GIT_STATUS = ''

	$BadAttestation = Join-Path $AttestationDirectory 'bad-attestation.json'
	$Manipulated = Get-Content -LiteralPath $AttestationPath -Raw | ConvertFrom-Json
	$Manipulated.files[0].path = '..\GitBin\git.bat'
	$Manipulated | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $BadAttestation -Encoding UTF8
	$Failure = $null
	try { & $Script -ProjectPath $FixtureProject -EngineRoot $EngineRoot -LinuxToolchainRoot $ToolchainRoot -ArchiveRoot (Join-Path $FixtureRoot 'PrebuiltEscapeArchive') -LogRoot (Join-Path $FixtureRoot 'PrebuiltEscapeLogs') -SourceRevision $Revision -HostToolsBoundary Prebuilt -EngineRevision $CanonicalEnginePin -HostToolsAttestationPath $BadAttestation } catch { $Failure = $_.Exception.Message }
	Assert-True ($Failure -match 'safe engine-relative path') 'An attestation path escape must fail closed.'
	$Manipulated = Get-Content -LiteralPath $AttestationPath -Raw | ConvertFrom-Json
	$Manipulated.files[1].path = ([string] $Manipulated.files[0].path).ToUpperInvariant()
	$Manipulated | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $BadAttestation -Encoding UTF8
	$Failure = $null
	try { & $Script -ProjectPath $FixtureProject -EngineRoot $EngineRoot -LinuxToolchainRoot $ToolchainRoot -ArchiveRoot (Join-Path $FixtureRoot 'PrebuiltCollideArchive') -LogRoot (Join-Path $FixtureRoot 'PrebuiltCollideLogs') -SourceRevision $Revision -HostToolsBoundary Prebuilt -EngineRevision $CanonicalEnginePin -HostToolsAttestationPath $BadAttestation } catch { $Failure = $_.Exception.Message }
	Assert-True ($Failure -match 'duplicates or case-collides') 'A case-colliding attestation entry must fail closed.'
	$Manipulated = Get-Content -LiteralPath $AttestationPath -Raw | ConvertFrom-Json
	$Manipulated | Add-Member -NotePropertyName note -NotePropertyValue 'injected'
	$Manipulated | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $BadAttestation -Encoding UTF8
	$Failure = $null
	try { & $Script -ProjectPath $FixtureProject -EngineRoot $EngineRoot -LinuxToolchainRoot $ToolchainRoot -ArchiveRoot (Join-Path $FixtureRoot 'PrebuiltExtraPropArchive') -LogRoot (Join-Path $FixtureRoot 'PrebuiltExtraPropLogs') -SourceRevision $Revision -HostToolsBoundary Prebuilt -EngineRevision $CanonicalEnginePin -HostToolsAttestationPath $BadAttestation } catch { $Failure = $_.Exception.Message }
	Assert-True ($Failure -match 'unexpected property') 'An attestation record with extra properties must fail closed.'
	$Manipulated = Get-Content -LiteralPath $AttestationPath -Raw | ConvertFrom-Json
	$Manipulated.files = @($Manipulated.files | Select-Object -Skip 1)
	$Manipulated | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $BadAttestation -Encoding UTF8
	$Failure = $null
	try { & $Script -ProjectPath $FixtureProject -EngineRoot $EngineRoot -LinuxToolchainRoot $ToolchainRoot -ArchiveRoot (Join-Path $FixtureRoot 'PrebuiltMissingEntryArchive') -LogRoot (Join-Path $FixtureRoot 'PrebuiltMissingEntryLogs') -SourceRevision $Revision -HostToolsBoundary Prebuilt -EngineRevision $CanonicalEnginePin -HostToolsAttestationPath $BadAttestation } catch { $Failure = $_.Exception.Message }
	Assert-True ($Failure -match 'receipt-derived host build products; found') 'An attestation record missing a required entry must fail closed.'
	$Oversized = Join-Path $AttestationDirectory 'oversized-attestation.json'
	Set-Content -LiteralPath $Oversized -Value ((Get-Content -LiteralPath $AttestationPath -Raw) + (' ' * 8400000)) -Encoding UTF8
	$Failure = $null
	try { & $Script -ProjectPath $FixtureProject -EngineRoot $EngineRoot -LinuxToolchainRoot $ToolchainRoot -ArchiveRoot (Join-Path $FixtureRoot 'PrebuiltOversizedArchive') -LogRoot (Join-Path $FixtureRoot 'PrebuiltOversizedLogs') -SourceRevision $Revision -HostToolsBoundary Prebuilt -EngineRevision $CanonicalEnginePin -HostToolsAttestationPath $Oversized } catch { $Failure = $_.Exception.Message }
	Assert-True ($Failure -match 'exceeds the 8388608-byte') 'An oversized attestation record must fail closed before parsing.'
	Assert-True (@(Get-Content -LiteralPath $CapturePath).Count -eq $CallsBeforeInvalidBoundary) 'Every invalid boundary or attestation must stop before any UAT invocation.'
	Write-Output 'PASS: noncanonical revisions, dirty checkouts, and manipulated attestation records all fail the boundary closed'

	$CallsBeforeReceiptClosure = @(Get-Content -LiteralPath $CapturePath).Count
	Set-Content -LiteralPath $EditorCoreDllPath -Value 'FIXTURE EDITOR CORE MODULE' -Encoding Ascii
	$Failure = $null
	try { & $Script -ProjectPath $FixtureProject -EngineRoot $EngineRoot -LinuxToolchainRoot $ToolchainRoot -ArchiveRoot (Join-Path $FixtureRoot 'ReceiptRootDllArchive') -LogRoot (Join-Path $FixtureRoot 'ReceiptRootDllLogs') -SourceRevision $Revision -HostToolsBoundary Prebuilt -EngineRevision $CanonicalEnginePin -HostToolsAttestationPath $AttestationPath } catch { $Failure = $_.Exception.Message }
	Assert-True ($Failure -match 'does not match its attested SHA-256') 'A mutated receipt-listed root editor module DLL must fail the boundary closed.'
	Set-Content -LiteralPath $EditorCoreDllPath -Value 'fixture editor core module' -Encoding Ascii
	Set-Content -LiteralPath $PluginDllPath -Value 'FIXTURE PLUGIN MODULE' -Encoding Ascii
	$Failure = $null
	try { & $Script -ProjectPath $FixtureProject -EngineRoot $EngineRoot -LinuxToolchainRoot $ToolchainRoot -ArchiveRoot (Join-Path $FixtureRoot 'ReceiptPluginDllArchive') -LogRoot (Join-Path $FixtureRoot 'ReceiptPluginDllLogs') -SourceRevision $Revision -HostToolsBoundary Prebuilt -EngineRevision $CanonicalEnginePin -HostToolsAttestationPath $AttestationPath } catch { $Failure = $_.Exception.Message }
	Assert-True ($Failure -match 'does not match its attested SHA-256') 'A mutated receipt-listed engine-plugin module DLL must fail the boundary closed.'
	Set-Content -LiteralPath $PluginDllPath -Value 'fixture plugin module' -Encoding Ascii
	foreach ($ReceiptCase in @(
		@{ Label = 'WrongConfiguration'; Body = $EditorReceiptBody.Replace('"Configuration":"Development"', '"Configuration":"Shipping"'); Expect = '^host_tools_receipt_invalid: .*exact expected AethelnOnlineEditor Win64 Development' },
		@{ Label = 'MissingMetadata'; Body = $EditorReceiptBody.Replace('"TargetType":"Editor",', ''); Expect = '^host_tools_receipt_invalid: .*missing required metadata' },
		@{ Label = 'EngineEscape'; Body = $EditorReceiptBody.Replace('"Path":"$(EngineDir)/Binaries/Win64/UnrealEditor-Core.dll"', '"Path":"$(EngineDir)/../GitBin/git.bat"'); Expect = 'safe engine-relative path' },
		@{ Label = 'CaseCollision'; Body = $EditorReceiptBody.Replace('{"Path":"$(EngineDir)/Binaries/Win64/UnrealEditor-Core.dll","Type":"DynamicLibrary"},', '{"Path":"$(EngineDir)/Binaries/Win64/UnrealEditor-Core.dll","Type":"DynamicLibrary"},{"Path":"$(EngineDir)/Binaries/Win64/UNREALEDITOR-CORE.DLL","Type":"DynamicLibrary"},'); Expect = 'duplicates or case-collides' }
	)) {
		Assert-True ($ReceiptCase.Body -cne $EditorReceiptBody) "Receipt variant $($ReceiptCase.Label) must differ from the good receipt."
		$env:AETHELN_TEST_EDITOR_RECEIPT = Write-EditorReceipt ('closure-' + $ReceiptCase.Label) $ReceiptCase.Body
		try { $Run = Invoke-PackagingCase ('ReceiptClosure' + $ReceiptCase.Label) $PrebuiltArguments -Override @{ Stage = 'Client' } } finally { $env:AETHELN_TEST_EDITOR_RECEIPT = $GoodEditorReceipt }
		Assert-True ($null -ne $Run.Failure -and $Run.Failure -match $ReceiptCase.Expect) "A receipt with $($ReceiptCase.Label) must fail closed; observed '$($Run.Failure)'."
	}
	$env:AETHELN_TEST_EDITOR_RECEIPT = Write-EditorReceipt 'closure-missing-product' $EditorReceiptBody.Replace('{"Path":"$(EngineDir)/Binaries/Win64/UnrealEditor-Core.dll","Type":"DynamicLibrary"},', '{"Path":"$(EngineDir)/Binaries/Win64/UnrealEditor-Core.dll","Type":"DynamicLibrary"},{"Path":"$(EngineDir)/Binaries/Win64/UnrealEditor-Missing.dll","Type":"DynamicLibrary"},')
	try { $Run = Invoke-PackagingCase 'ReceiptMissingProduct' @{ Stage = 'AttestHostTools'; HostToolsAttestationPath = (Join-Path $AttestationDirectory 'missing-product-attestation.json'); ProvisioningEvidence = 'fixture evidence' } } finally { $env:AETHELN_TEST_EDITOR_RECEIPT = $GoodEditorReceipt }
	Assert-True ($null -ne $Run.Failure -and $Run.Failure -match 'does not exist under the engine root') "A missing receipt-listed build product must fail the attestation step closed; observed '$($Run.Failure)'."
	Assert-True (@(Get-Content -LiteralPath $CapturePath).Count -eq $CallsBeforeReceiptClosure) 'Every receipt-closure failure must stop before any UAT invocation.'
	Write-Output 'PASS: the receipt-derived closure covers editor and plugin modules and fails closed on tampered, escaping, colliding, or missing receipt products'

	$Failure = $null
	try { & $Script -ProjectPath $FixtureProject -EngineRoot $EngineRoot -LinuxToolchainRoot $ToolchainRoot -ArchiveRoot (Join-Path $FixtureRoot 'AttestOverwriteArchive') -LogRoot (Join-Path $FixtureRoot 'AttestOverwriteLogs') -SourceRevision $Revision -Stage AttestHostTools -HostToolsAttestationPath $AttestationPath -ProvisioningEvidence 'fixture evidence' } catch { $Failure = $_.Exception.Message }
	Assert-True ($Failure -match 'already exists') 'The attestation step must never overwrite an existing record.'
	$AttestationRaw = Get-Content -LiteralPath $AttestationPath -Raw
	foreach ($StrictCase in @(
		@{ Label = 'duplicate top-level property'; Content = ($AttestationRaw -replace '"schemaVersion":\s*2', '"schemaVersion": 2, "schemaVersion": 2'); Expect = 'duplicate or case-colliding JSON property' },
		@{ Label = 'duplicate nested entry property'; Content = ($AttestationRaw -replace '"sha256":', '"path": "dup", "sha256":'); Expect = 'duplicate or case-colliding JSON property' },
		@{ Label = 'case-colliding property'; Content = ($AttestationRaw -replace '"createdUtc":', '"CREATEDUTC": "x", "createdUtc":'); Expect = 'duplicate or case-colliding JSON property' },
		@{ Label = 'unicode-escaped duplicate property'; Content = ($AttestationRaw -replace '"createdUtc":\s*"[^"]*"', '"createdUtc": "2026-09-04T12:00:00Z", "createdUtc": "2026-09-04T12:00:00Z"'); Expect = 'duplicate or case-colliding JSON property' },
		@{ Label = 'string schema version'; Content = ($AttestationRaw -replace '"schemaVersion":\s*2', '"schemaVersion": "2"'); Expect = 'JSON integer 2' },
		@{ Label = 'invalid project revision'; Content = ($AttestationRaw -replace '"projectRevision":\s*"[^"]*"', '"projectRevision": "HEAD"'); Expect = 'projectRevision must be' },
		@{ Label = 'null provisioning evidence'; Content = ($AttestationRaw -replace '"provisioningEvidence":\s*"[^"]*"', '"provisioningEvidence": null'); Expect = 'nonempty bounded string' },
		@{ Label = 'empty provisioning evidence'; Content = ($AttestationRaw -replace '"provisioningEvidence":\s*"[^"]*"', '"provisioningEvidence": ""'); Expect = 'nonempty bounded string' },
		@{ Label = 'invalid timestamp'; Content = ($AttestationRaw -replace '"createdUtc":\s*"[^"]*"', '"createdUtc": "not-a-timestamp"'); Expect = 'round-trip UTC timestamp' },
		@{ Label = 'unspecified timestamp'; Content = ($AttestationRaw -replace '"createdUtc":\s*"[^"]*"', '"createdUtc": "2026-09-04T12:00:00"'); Expect = 'round-trip UTC timestamp' },
		@{ Label = 'offset timestamp'; Content = ($AttestationRaw -replace '"createdUtc":\s*"[^"]*"', '"createdUtc": "2026-09-04T12:00:00+02:00"'); Expect = 'round-trip UTC timestamp' }
	)) {
		Assert-True ([string] $StrictCase.Content -cne $AttestationRaw) "Strict case '$($StrictCase.Label)' must change the record."
		Set-Content -LiteralPath $BadAttestation -Value ([string] $StrictCase.Content) -Encoding UTF8
		$Failure = $null
		try { & $Script -ProjectPath $FixtureProject -EngineRoot $EngineRoot -LinuxToolchainRoot $ToolchainRoot -ArchiveRoot (Join-Path $FixtureRoot ("StrictArchive-{0}" -f ($StrictCase.Label -replace '[^a-z]', ''))) -LogRoot (Join-Path $FixtureRoot ("StrictLogs-{0}" -f ($StrictCase.Label -replace '[^a-z]', ''))) -SourceRevision $Revision -HostToolsBoundary Prebuilt -EngineRevision $CanonicalEnginePin -HostToolsAttestationPath $BadAttestation } catch { $Failure = $_.Exception.Message }
		Assert-True ($null -ne $Failure -and $Failure -match [string] $StrictCase.Expect) "An attestation with a $($StrictCase.Label) must fail closed."
	}
	foreach ($SizeCase in @(
		@{ Label = 'nonarrayfiles'; Value = 'not-an-array'; Wholesale = $true; Expect = 'must be a JSON array' },
		@{ Label = 'fractionalsize'; Value = 12.5; Wholesale = $false; Expect = 'nonnegative JSON integer' },
		@{ Label = 'negativesize'; Value = -5; Wholesale = $false; Expect = 'must be nonnegative' },
		@{ Label = 'perfilecap'; Value = [long] 8589934592; Wholesale = $false; Expect = 'per-file bound' },
		@{ Label = 'aggregatecap'; Value = [long] 214748364800; Wholesale = $false; Expect = 'aggregate bound' },
		@{ Label = 'aggregateoverflow'; Value = [long] 9223372036854775000; Wholesale = $false; Expect = 'overflow the aggregate size bound' }
	)) {
		$Manipulated = Get-Content -LiteralPath $AttestationPath -Raw | ConvertFrom-Json
		if ($SizeCase.Wholesale) {
			$Manipulated.files = $SizeCase.Value
		} else {
			$Manipulated.files[0].sizeBytes = $SizeCase.Value
			if ($SizeCase.Label -eq 'aggregateoverflow') { $Manipulated.files[1].sizeBytes = $SizeCase.Value }
		}
		$Manipulated | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $BadAttestation -Encoding UTF8
		$Failure = $null
		try { & $Script -ProjectPath $FixtureProject -EngineRoot $EngineRoot -LinuxToolchainRoot $ToolchainRoot -ArchiveRoot (Join-Path $FixtureRoot ("SizeArchive-{0}" -f $SizeCase.Label)) -LogRoot (Join-Path $FixtureRoot ("SizeLogs-{0}" -f $SizeCase.Label)) -SourceRevision $Revision -HostToolsBoundary Prebuilt -EngineRevision $CanonicalEnginePin -HostToolsAttestationPath $BadAttestation } catch { $Failure = $_.Exception.Message }
		Assert-True ($null -ne $Failure -and $Failure -match [string] $SizeCase.Expect) "An attestation with $($SizeCase.Label) must fail closed."
	}
	Assert-True (@(Get-Content -LiteralPath $CapturePath).Count -eq $CallsBeforeReceiptClosure) 'Every strict-contract rejection must stop before any UAT invocation.'
	Write-Output 'PASS: the attestation JSON contract rejects duplicate/case-colliding properties, non-integer schema versions, invalid project revisions, evidence and timestamps, malformed files arrays, and out-of-bound sizes'

	$IdentityDdc = Join-Path $FixtureRoot 'IdentityDdc'
	$env:AETHELN_TEST_ARCHIVE_ROOT = Join-Path $FixtureRoot 'IdentityArchive1'
	& $Script -ProjectPath $FixtureProject -EngineRoot $EngineRoot -LinuxToolchainRoot $ToolchainRoot -ArchiveRoot (Join-Path $FixtureRoot 'IdentityArchive1') -LogRoot (Join-Path $FixtureRoot 'IdentityLogs1') -SourceRevision $Revision -HostToolsBoundary Rebuild -DerivedDataCachePath $IdentityDdc
	$IdentityPath2 = Join-Path $IdentityDdc 'cache-identity.json'
	$CallsBeforeIdentityRegressions = @(Get-Content -LiteralPath $CapturePath).Count
	$IdentityObject = Get-Content -LiteralPath $IdentityPath2 -Raw | ConvertFrom-Json
	$IdentityObject.engineGitRevision = ('3' * 40)
	$IdentityObject | ConvertTo-Json | Set-Content -LiteralPath $IdentityPath2 -Encoding UTF8
	$Failure = $null
	try { & $Script -ProjectPath $FixtureProject -EngineRoot $EngineRoot -LinuxToolchainRoot $ToolchainRoot -ArchiveRoot (Join-Path $FixtureRoot 'IdentityArchive2') -LogRoot (Join-Path $FixtureRoot 'IdentityLogs2') -SourceRevision $Revision -HostToolsBoundary Rebuild -DerivedDataCachePath $IdentityDdc } catch { $Failure = $_.Exception.Message }
	Assert-True ($Failure -match 'failed identity validation') 'A cache bound to a different engine Git revision must fail closed.'
	$IdentityObject.engineGitRevision = $RealRevision
	$IdentityObject.projectRepository = ('4' * 40)
	$IdentityObject | ConvertTo-Json | Set-Content -LiteralPath $IdentityPath2 -Encoding UTF8
	$Failure = $null
	try { & $Script -ProjectPath $FixtureProject -EngineRoot $EngineRoot -LinuxToolchainRoot $ToolchainRoot -ArchiveRoot (Join-Path $FixtureRoot 'IdentityArchive3') -LogRoot (Join-Path $FixtureRoot 'IdentityLogs3') -SourceRevision $Revision -HostToolsBoundary Rebuild -DerivedDataCachePath $IdentityDdc } catch { $Failure = $_.Exception.Message }
	Assert-True ($Failure -match 'failed identity validation') 'A colliding project name from a different repository identity must fail closed.'
	$IdentityObject.projectRepository = $RealRevision
	$IdentityObject.schemaVersion = 1
	$IdentityObject | ConvertTo-Json | Set-Content -LiteralPath $IdentityPath2 -Encoding UTF8
	$env:AETHELN_TEST_ARCHIVE_ROOT = Join-Path $FixtureRoot 'IdentityArchive4'
	& $Script -ProjectPath $FixtureProject -EngineRoot $EngineRoot -LinuxToolchainRoot $ToolchainRoot -ArchiveRoot (Join-Path $FixtureRoot 'IdentityArchive4') -LogRoot (Join-Path $FixtureRoot 'IdentityLogs4') -SourceRevision $Revision -HostToolsBoundary Rebuild -DerivedDataCachePath $IdentityDdc -CacheFallback CleanIsolated
	$OldSchemaTiming = Get-Content -LiteralPath (Join-Path $FixtureRoot 'IdentityLogs4/build-timing.json') -Raw | ConvertFrom-Json
	Assert-True ($OldSchemaTiming.derivedDataCache.status -eq 'fallback_corrupt') 'An older identity schema must never be reused; it takes the recorded clean fallback or fails closed.'
	Assert-True (@(Get-Content -LiteralPath $CapturePath).Count -eq $CallsBeforeIdentityRegressions + 2) 'Fail-closed identity regressions must stop before UAT; only the clean fallback run may invoke UAT.'
	$env:AETHELN_TEST_ENGINE_GIT_STATUS = ' M Engine/Source/Runtime/Core/Private/Core.cpp'
	$env:AETHELN_TEST_ARCHIVE_ROOT = Join-Path $FixtureRoot 'IdentityArchive5'
	& $Script -ProjectPath $FixtureProject -EngineRoot $EngineRoot -LinuxToolchainRoot $ToolchainRoot -ArchiveRoot (Join-Path $FixtureRoot 'IdentityArchive5') -LogRoot (Join-Path $FixtureRoot 'IdentityLogs5') -SourceRevision $Revision -HostToolsBoundary Rebuild -DerivedDataCachePath (Join-Path $FixtureRoot 'IdentityDdcDirtyEngine') -CacheFallback CleanIsolated
	$DirtyEngineTiming = Get-Content -LiteralPath (Join-Path $FixtureRoot 'IdentityLogs5/build-timing.json') -Raw | ConvertFrom-Json
	Assert-True ($DirtyEngineTiming.derivedDataCache.status -eq 'fallback_engine_identity_unverifiable') 'A dirty engine checkout must make the cache identity unverifiable.'
	$env:AETHELN_TEST_ENGINE_GIT_STATUS = ''
	Write-Output 'PASS: engine-revision, repository-collision, older-schema, and dirty-engine identity states never reuse the cache'

	$CallsBeforePathContract = @(Get-Content -LiteralPath $CapturePath).Count
	$Failure = $null
	try { & $Script -ProjectPath $FixtureProject -EngineRoot $EngineRoot -LinuxToolchainRoot $ToolchainRoot -ArchiveRoot (Join-Path $FixtureRoot 'PathRelArchive') -LogRoot (Join-Path $FixtureRoot 'PathRelLogs') -SourceRevision $Revision -HostToolsBoundary Rebuild -DerivedDataCachePath 'relative\ddc' } catch { $Failure = $_.Exception.Message }
	Assert-True ($Failure -match 'absolute local path') 'A relative DDC path must be rejected by the build entry point.'
	$PathTiming = Get-Content -LiteralPath (Join-Path $FixtureRoot 'PathRelLogs/build-timing.json') -Raw | ConvertFrom-Json
	Assert-True ($PathTiming.derivedDataCache.status -eq 'failed_path_invalid') 'A rejected DDC path must be recorded as failed_path_invalid in the timing record.'
	$Failure = $null
	try { & $Script -ProjectPath $FixtureProject -EngineRoot $EngineRoot -LinuxToolchainRoot $ToolchainRoot -ArchiveRoot (Join-Path $FixtureRoot 'PathUncArchive') -LogRoot (Join-Path $FixtureRoot 'PathUncLogs') -SourceRevision $Revision -HostToolsBoundary Rebuild -DerivedDataCachePath '\\server\share\ddc' } catch { $Failure = $_.Exception.Message }
	Assert-True ($Failure -match 'must not be a UNC path') 'A UNC DDC path must be rejected by the build entry point.'
	$Failure = $null
	try { & $Script -ProjectPath $FixtureProject -EngineRoot $EngineRoot -LinuxToolchainRoot $ToolchainRoot -ArchiveRoot (Join-Path $FixtureRoot 'PathOverlapArchive') -LogRoot (Join-Path $FixtureRoot 'PathOverlapLogs') -SourceRevision $Revision -HostToolsBoundary Rebuild -DerivedDataCachePath (Join-Path $FixtureRoot 'PathOverlapLogs/ddc') } catch { $Failure = $_.Exception.Message }
	Assert-True ($Failure -match 'must be disjoint') 'A DDC path inside the log root must be rejected by the build entry point.'
	$Failure = $null
	try { & $Script -ProjectPath $FixtureProject -EngineRoot $EngineRoot -LinuxToolchainRoot $ToolchainRoot -ArchiveRoot (Join-Path $FixtureRoot 'PathRepoArchive') -LogRoot (Join-Path $FixtureRoot 'PathRepoLogs') -SourceRevision $Revision -HostToolsBoundary Rebuild -DerivedDataCachePath (Join-Path $FixtureProjectRoot 'ddc-under-repo') } catch { $Failure = $_.Exception.Message }
	Assert-True ($Failure -match 'must be disjoint') 'A DDC path inside the repository must be rejected on a direct call, matching the CI gate contract.'
	$JunctionTarget = Join-Path $FixtureRoot 'DdcJunctionTarget'
	New-Item -ItemType Directory -Path $JunctionTarget | Out-Null
	$Junction = Join-Path $FixtureRoot 'DdcJunction'
	New-Item -ItemType Junction -Path $Junction -Value $JunctionTarget | Out-Null
	$Failure = $null
	try { & $Script -ProjectPath $FixtureProject -EngineRoot $EngineRoot -LinuxToolchainRoot $ToolchainRoot -ArchiveRoot (Join-Path $FixtureRoot 'PathReparseArchive') -LogRoot (Join-Path $FixtureRoot 'PathReparseLogs') -SourceRevision $Revision -HostToolsBoundary Rebuild -DerivedDataCachePath (Join-Path $Junction 'ddc') } catch { $Failure = $_.Exception.Message }
	Assert-True ($Failure -match 'reparse point') 'A reparse-mediated DDC path must be rejected by the build entry point.'
	[IO.Directory]::Delete($Junction)
	Assert-True (@(Get-Content -LiteralPath $CapturePath).Count -eq $CallsBeforePathContract) 'Every rejected DDC path must stop before any UAT invocation.'
	Write-Output 'PASS: the build entry point enforces the full DDC path contract on direct calls'
}
finally {
	if ($null -ne $OriginalPath) { $env:PATH = $OriginalPath }
	Remove-Item Env:AETHELN_TEST_GIT_STATUS -ErrorAction SilentlyContinue
	Remove-Item Env:AETHELN_TEST_ENGINE_GIT_STATUS -ErrorAction SilentlyContinue
	Remove-Item Env:AETHELN_TEST_ENGINE_HEAD -ErrorAction SilentlyContinue
	Remove-Item Env:AETHELN_TEST_CONFLICTING_COMPILER -ErrorAction SilentlyContinue
	Remove-Item Env:AETHELN_TEST_ARCHIVE_ROOT -ErrorAction SilentlyContinue
	Remove-Item Env:AETHELN_TEST_DDC_CAPTURE -ErrorAction SilentlyContinue
	Remove-Item Env:AETHELN_TEST_PROJECT_ROOT -ErrorAction SilentlyContinue
	Remove-Item Env:AETHELN_TEST_REGISTRY_NONCE -ErrorAction SilentlyContinue
	Remove-Item Env:AETHELN_TEST_SKIP_CLIENT_REGISTRY -ErrorAction SilentlyContinue
	Remove-Item Env:AETHELN_TEST_EDITOR_RECEIPT -ErrorAction SilentlyContinue
	Remove-Item Env:AETHELN_TEST_EDITOR_POST -ErrorAction SilentlyContinue
	Remove-Item Env:AETHELN_TEST_EDITOR_EXIT -ErrorAction SilentlyContinue
	[Environment]::SetEnvironmentVariable('UE_ADDITIONAL_PLUGIN_PATHS', $OriginalAdditionalPluginPaths, 'Process')
	[Environment]::SetEnvironmentVariable('uebp_LogFolder', $OriginalUebpLogFolder, 'Process')
	[Environment]::SetEnvironmentVariable('uebp_FinalLogFolder', $OriginalUebpFinalLogFolder, 'Process')
	if (Test-Path -LiteralPath $FixtureRoot) { Remove-Item -LiteralPath $FixtureRoot -Recurse -Force }
}
