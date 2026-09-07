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
	# The controller is pointed at a fixture copy of the project descriptor,
	# target rules, and config: the fake UnrealBuildTool writes project build
	# products under the project directory, which must never be the repository.
	$ProjectRoot = Join-Path $FixtureRoot 'Project'
	New-Item -ItemType Directory -Path (Join-Path $ProjectRoot 'Source'), (Join-Path $ProjectRoot 'Config') -Force | Out-Null
	Copy-Item -LiteralPath (Join-Path $RepositoryRoot 'AethelnOnline.uproject') -Destination $ProjectRoot
	Copy-Item -Path (Join-Path $RepositoryRoot 'Source/*.Target.cs') -Destination (Join-Path $ProjectRoot 'Source')
	Copy-Item -Path (Join-Path $RepositoryRoot 'Config/*.ini') -Destination (Join-Path $ProjectRoot 'Config')
	$ProjectFile = Join-Path $ProjectRoot 'AethelnOnline.uproject'
	$env:AETHELN_TEST_PROJECT_ROOT = $ProjectRoot
	$EditorDirectory = Join-Path $EngineRoot 'Engine\Binaries\Win64'
	New-Item -ItemType Directory -Path $EditorDirectory -Force | Out-Null
	$CapturePath = Join-Path $FixtureRoot 'uat-arguments.txt'
	$UbtCapturePath = Join-Path $FixtureRoot 'ubt-arguments.txt'
	$SequencePath = Join-Path $FixtureRoot 'tool-sequence.txt'
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
	# The fake UAT models the pinned BuildCookRun agenda: with -build it runs
	# the BUILD command and relinks the engine UnrealPak (the agenda always
	# cleans and rebuilds that program), and only then does UBT emit the
	# compiler sidecar lines; with -skipbuild it builds nothing and, like real
	# staging, requires the project target receipt to exist.
	$FakeBody = @"
@echo off
echo %*>>"$CapturePath"
if defined AETHELN_TEST_DDC_CAPTURE echo %UE-LocalDataCachePath%>>"%AETHELN_TEST_DDC_CAPTURE%"
echo %* | findstr /c:"-serverplatform=Linux" >nul
if %errorlevel%==0 (set AETHELN_FAKE_KIND=server) else (set AETHELN_FAKE_KIND=client)
echo UAT %AETHELN_FAKE_KIND%>>"$SequencePath"
echo %* | findstr /r /c:" -build " >nul
if %errorlevel%==0 (
	echo ********** BUILD COMMAND STARTED **********
	echo relinked unrealpak %RANDOM%>"$EditorDirectory\UnrealPak.exe"
	mkdir "%uebp_LogFolder%" 2>nul
	>"%uebp_LogFolder%\UBA-client.txt" echo Compiler: $SelectedCompiler
	>>"%uebp_LogFolder%\UBA-client.txt" echo Compiler: $SelectedCompiler
	>>"%uebp_LogFolder%\UBA-client.txt" echo Resource Compiler: $SelectedResourceCompiler
	>>"%uebp_LogFolder%\UBA-client.txt" echo Resource Compiler: $SelectedResourceCompiler
	if "%AETHELN_TEST_CONFLICTING_COMPILER%"=="1" echo Compiler: $ConflictingCompiler>>"%uebp_LogFolder%\UBA-conflict.txt"
	echo ********** BUILD COMMAND COMPLETED **********
)
echo %* | findstr /c:"-skipbuild" >nul
if %errorlevel%==0 (
	if "%AETHELN_FAKE_KIND%"=="server" (
		if not exist "%AETHELN_TEST_PROJECT_ROOT%\Binaries\Linux\AethelnOnlineServer.target" exit /b 7
	) else (
		if not exist "%AETHELN_TEST_PROJECT_ROOT%\Binaries\Win64\AethelnOnlineClient.target" exit /b 7
	)
)
echo ********** COOK COMMAND STARTED **********
echo ********** COOK COMMAND COMPLETED **********
if "%AETHELN_TEST_UAT_TAMPER%"=="1" echo tampered during UAT>>"$EditorDirectory\UnrealEditor-Core.dll"
if "%AETHELN_FAKE_KIND%"=="server" (
	mkdir "%AETHELN_TEST_ARCHIVE_ROOT%\LinuxServer" 2>nul
	echo server>"%AETHELN_TEST_ARCHIVE_ROOT%\LinuxServer\AethelnOnlineServer"
) else (
	mkdir "%AETHELN_TEST_ARCHIVE_ROOT%\WindowsClient" 2>nul
	echo client>"%AETHELN_TEST_ARCHIVE_ROOT%\WindowsClient\AethelnOnlineClient.exe"
)
exit /b 0
"@
	Set-Content -LiteralPath $FakeUat -Value $FakeBody -Encoding Ascii
	# The fake UnrealBuildTool entry point (Build.bat) records every call to a
	# separate capture file plus the shared tool-sequence file, deletes the
	# target's products on -Clean, and otherwise writes the receipt, products,
	# and a UBT log with the toolchain lines. Environment switches select the
	# failure behaviors the controller must fail closed on.
	$FakeUbtScript = Join-Path $FixtureRoot 'FakeUbt.ps1'
	$FakeUbtBody = @"
Set-StrictMode -Version Latest
`$ErrorActionPreference = 'Stop'
`$Target = `$args[0]; `$Platform = `$args[1]; `$Configuration = `$args[2]
`$Mode = if (`$args -contains '-Clean') { 'clean' } else { 'build' }
Add-Content -LiteralPath '$UbtCapturePath' -Value (`$args -join ' ') -Encoding Ascii
Add-Content -LiteralPath '$SequencePath' -Value "UBT `$Target `$Platform `$Configuration `$Mode" -Encoding Ascii
`$ProjectPaths = @(`$args | Where-Object { `$_ -like '*.uproject' })
`$ProjectDirectory = if (`$ProjectPaths.Count -eq 1) { Split-Path -Parent `$ProjectPaths[0] } else { `$null }
`$LogPaths = @(`$args | Where-Object { `$_ -like '-Log=*' } | ForEach-Object { `$_.Substring(5) })
if (`$env:AETHELN_TEST_UBT_FAIL -eq ('{0}:{1}' -f `$Target, `$Mode)) { Write-Output "fixture UnrealBuildTool failure for `$Target `$Mode"; exit 1 }
`$EngineBinaries = '$EditorDirectory'
if (`$Mode -eq 'clean') {
	if (`$Target -eq 'BootstrapPackagedGame') {
		Remove-Item -LiteralPath (Join-Path `$EngineBinaries 'BootstrapPackagedGame-Win64-Shipping.exe') -Force -ErrorAction SilentlyContinue
	} elseif (`$null -ne `$ProjectDirectory) {
		# Models UnrealBuildTool clean-mode prefixes: the target name plus the
		# shared application name (UnrealEditor for an Editor target), under
		# the project and, for the Shared-environment editor, the engine too.
		`$Prefixes = @("`$Target*")
		if (`$Target -eq 'AethelnOnlineEditor') {
			`$Prefixes += 'UnrealEditor*'
			Get-ChildItem -LiteralPath `$EngineBinaries -File | Where-Object { `$_.Name -like 'UnrealEditor*' } | Remove-Item -Force
		}
		`$Binaries = Join-Path `$ProjectDirectory "Binaries/`$Platform"
		if (Test-Path -LiteralPath `$Binaries) { Get-ChildItem -LiteralPath `$Binaries -File | Where-Object { `$Name = `$_.Name; @(`$Prefixes | Where-Object { `$Name -like `$_ }).Count -gt 0 } | Remove-Item -Force }
	}
	exit 0
}
if (`$LogPaths.Count -eq 1) {
	New-Item -ItemType Directory -Path (Split-Path -Parent `$LogPaths[0]) -Force | Out-Null
	`$LogLines = @("Running UnrealBuildTool fixture for `$Target `$Platform `$Configuration")
	if (`$Platform -eq 'Win64') { `$LogLines += @('Compiler: $SelectedCompiler', 'Resource Compiler: $SelectedResourceCompiler') }
	Set-Content -LiteralPath `$LogPaths[0] -Value `$LogLines -Encoding Ascii
}
if (@(([string] `$env:AETHELN_TEST_UBT_NO_PRODUCTS) -split ',') -contains `$Target) { exit 0 }
if (`$Target -eq 'BootstrapPackagedGame') {
	Set-Content -LiteralPath (Join-Path `$EngineBinaries 'BootstrapPackagedGame-Win64-Shipping.exe') -Value 'fixture bootstrap' -Encoding Ascii
	exit 0
}
`$Binaries = Join-Path `$ProjectDirectory "Binaries/`$Platform"
New-Item -ItemType Directory -Path `$Binaries -Force | Out-Null
`$Products = New-Object System.Collections.ArrayList
if (`$Target -eq 'AethelnOnlineEditor') {
	if (`$env:AETHELN_TEST_UBT_TAMPER_ENGINE -eq '1') { Add-Content -LiteralPath (Join-Path `$EngineBinaries 'UnrealEditor-Core.dll') -Value 'relinked by the project editor build' -Encoding Ascii }
	`$Modules = [ordered]@{}
	if (`$env:AETHELN_TEST_UBT_EMPTY_MANIFEST -ne '1') {
		foreach (`$Module in @('GameCore', 'GameCombat', 'GameUI', 'GameNet', 'GameServer', 'GameTests')) {
			if (`$Module -eq `$env:AETHELN_TEST_UBT_OMIT_MODULE) { continue }
			`$Dll = "UnrealEditor-`$Module.dll"
			`$Modules[`$Module] = `$Dll
			if (`$Module -ne `$env:AETHELN_TEST_UBT_OMIT_DLL) {
				Set-Content -LiteralPath (Join-Path `$Binaries `$Dll) -Value "fixture `$Module" -Encoding Ascii
				[void] `$Products.Add(@{ Path = ('`$(ProjectDir)/Binaries/Win64/' + `$Dll); Type = 'DynamicLibrary' })
			}
		}
	}
	`$BuildId = if ([string]::IsNullOrEmpty(`$env:AETHELN_TEST_PROJECT_BUILDID)) { 'fixture' } else { `$env:AETHELN_TEST_PROJECT_BUILDID }
	[ordered]@{ BuildId = `$BuildId; Modules = `$Modules } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path `$Binaries 'UnrealEditor.modules') -Encoding UTF8
	`$TargetType = 'Editor'
} else {
	`$Executable = if (`$Platform -eq 'Win64') { "`$Target.exe" } else { `$Target }
	Set-Content -LiteralPath (Join-Path `$Binaries `$Executable) -Value "fixture `$Target" -Encoding Ascii
	[void] `$Products.Add(@{ Path = ('`$(ProjectDir)/Binaries/' + `$Platform + '/' + `$Executable); Type = 'Executable' })
	`$TargetType = if (`$Target -like '*Server') { 'Server' } else { 'Client' }
}
[ordered]@{ TargetName = `$Target; Platform = `$Platform; Configuration = `$Configuration; TargetType = `$TargetType; BuildProducts = @(`$Products) } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path `$Binaries "`$Target.target") -Encoding UTF8
exit 0
"@
	Set-Content -LiteralPath $FakeUbtScript -Value $FakeUbtBody -Encoding Ascii
	Set-Content -LiteralPath (Join-Path $UatDirectory 'Build.bat') -Value "@echo off`r`npowershell -NoProfile -ExecutionPolicy Bypass -File `"$FakeUbtScript`" %*`r`nexit /b %errorlevel%" -Encoding Ascii
	$EditorVersionPath = Join-Path $EditorDirectory 'UnrealEditor.version'
	$MatchingEditorVersion = '{"MajorVersion":5,"MinorVersion":8,"PatchVersion":1,"Changelist":123,"CompatibleChangelist":120,"BranchName":"++UE5+Release-5.8","BuildId":"fixture"}'
	Set-Content -LiteralPath $EditorVersionPath -Value $MatchingEditorVersion -Encoding UTF8
	Set-Content -LiteralPath (Join-Path $EditorDirectory 'UnrealEditor.exe') -Value 'fixture editor' -Encoding Ascii
	Set-Content -LiteralPath (Join-Path $EditorDirectory 'UnrealPak.exe') -Value 'fixture unrealpak' -Encoding Ascii
	Set-Content -LiteralPath (Join-Path $EditorDirectory 'ShaderCompileWorker.exe') -Value 'fixture shadercompileworker' -Encoding Ascii
	# The fixture engine models the receipt-derived closure: one root editor
	# module DLL, one engine-plugin module DLL, the module manifest, and the
	# three generated Unreal target receipts. UnrealEditor.pdb is listed in the
	# receipt but deliberately never created: symbol files must stay excluded.
	$PluginBinariesDirectory = Join-Path $EngineRoot 'Engine/Plugins/FixturePlugin/Binaries/Win64'
	New-Item -ItemType Directory -Path $PluginBinariesDirectory -Force | Out-Null
	$EditorCoreDllPath = Join-Path $EditorDirectory 'UnrealEditor-Core.dll'
	$PluginDllPath = Join-Path $PluginBinariesDirectory 'UnrealEditor-FixturePlugin.dll'
	Set-Content -LiteralPath $EditorCoreDllPath -Value 'fixture editor core module' -Encoding Ascii
	Set-Content -LiteralPath $PluginDllPath -Value 'fixture plugin module' -Encoding Ascii
	Set-Content -LiteralPath (Join-Path $EditorDirectory 'UnrealEditor.modules') -Value '{"BuildId":"fixture","Modules":{"Core":"UnrealEditor-Core.dll"}}' -Encoding UTF8
	$EditorReceiptPath = Join-Path $EditorDirectory 'UnrealEditor.target'
	$EditorReceiptBody = @'
{"TargetName":"UnrealEditor","Platform":"Win64","Configuration":"Development","TargetType":"Editor","BuildProducts":[
{"Path":"$(EngineDir)/Binaries/Win64/UnrealEditor.exe","Type":"Executable"},
{"Path":"$(EngineDir)/Binaries/Win64/UnrealEditor-Cmd.exe","Type":"Executable"},
{"Path":"$(EngineDir)/Binaries/Win64/UnrealEditor-Core.dll","Type":"DynamicLibrary"},
{"Path":"$(EngineDir)/Plugins/FixturePlugin/Binaries/Win64/UnrealEditor-FixturePlugin.dll","Type":"DynamicLibrary"},
{"Path":"$(EngineDir)/Binaries/Win64/UnrealEditor.modules","Type":"RequiredResource"},
{"Path":"$(EngineDir)/Binaries/Win64/UnrealEditor.version","Type":"BuildResource"},
{"Path":"$(EngineDir)/Binaries/Win64/UnrealEditor.pdb","Type":"SymbolFile"}]}
'@
	Set-Content -LiteralPath $EditorReceiptPath -Value $EditorReceiptBody -Encoding UTF8
	Set-Content -LiteralPath (Join-Path $EditorDirectory 'UnrealPak.target') -Value '{"TargetName":"UnrealPak","Platform":"Win64","Configuration":"Development","TargetType":"Program","BuildProducts":[{"Path":"$(EngineDir)/Binaries/Win64/UnrealPak.exe","Type":"Executable"},{"Path":"$(EngineDir)/Binaries/Win64/UnrealPak.pdb","Type":"SymbolFile"}]}' -Encoding UTF8
	Set-Content -LiteralPath (Join-Path $EditorDirectory 'ShaderCompileWorker.target') -Value '{"TargetName":"ShaderCompileWorker","Platform":"Win64","Configuration":"Development","TargetType":"Program","BuildProducts":[{"Path":"$(EngineDir)/Binaries/Win64/ShaderCompileWorker.exe","Type":"Executable"}]}' -Encoding UTF8
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

	& $Script -ProjectPath $ProjectFile -EngineRoot $EngineRoot -LinuxToolchainRoot $ToolchainRoot -ArchiveRoot $ArchiveRoot -LogRoot $LogRoot -SourceRevision $Revision -HostToolsBoundary Rebuild -RunnerName 'fixture-runner'
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
	$ProjectDescriptor = Get-Content -LiteralPath $ProjectFile -Raw | ConvertFrom-Json
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
	try { & $Script -ProjectPath $ProjectFile -EngineRoot $EngineRoot -LinuxToolchainRoot $ToolchainRoot -ArchiveRoot (Join-Path $FixtureRoot 'ConflictArchive') -LogRoot (Join-Path $FixtureRoot 'ConflictLogs') -SourceRevision $Revision -HostToolsBoundary Rebuild } catch { $Failure = $_.Exception.Message }
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
	try { & $Script -ProjectPath $ProjectFile -EngineRoot $EngineRoot -LinuxToolchainRoot $ToolchainRoot -ArchiveRoot $DirtyRoot -LogRoot (Join-Path $FixtureRoot 'FreshLogs') -SourceRevision $Revision -HostToolsBoundary Rebuild } catch { $Failure = $_.Exception.Message }
	Assert-True ($Failure -match 'must be empty') 'Existing output must not be silently mixed with a new build.'
	Write-Output 'PASS: non-empty output roots are rejected'

	$CallsBeforeDirtyChecks = @(Get-Content -LiteralPath $CapturePath).Count
	foreach ($DirtyCase in @(
		@{ Status = ' M Source/GameCore/Private/Changed.cpp'; Label = 'modified' },
		@{ Status = '?? Source/GameCore/Private/NewInput.cpp'; Label = 'untracked' }
	)) {
		$env:AETHELN_TEST_GIT_STATUS = $DirtyCase.Status
		$Failure = $null
		try { & $Script -ProjectPath $ProjectFile -EngineRoot $EngineRoot -LinuxToolchainRoot $ToolchainRoot -ArchiveRoot (Join-Path $FixtureRoot "$($DirtyCase.Label)-archive") -LogRoot (Join-Path $FixtureRoot "$($DirtyCase.Label)-logs") -SourceRevision $Revision -HostToolsBoundary Rebuild } catch { $Failure = $_.Exception.Message }
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
	& $Script -ProjectPath $ProjectFile -EngineRoot $EngineRoot -LinuxToolchainRoot $ToolchainRoot -ArchiveRoot $StagedClientRoot -LogRoot (Join-Path $FixtureRoot 'StagedClientLogs') -SourceRevision $Revision -HostToolsBoundary Rebuild -Stage Client
	$ClientRecord = Get-Content -LiteralPath (Join-Path $StagedClientRoot 'phase-client.json') -Raw | ConvertFrom-Json
	Assert-True ($ClientRecord.schemaVersion -eq 2 -and $ClientRecord.stage -eq 'client' -and $ClientRecord.sourceRevision -eq $Revision) 'The client stage record must bind schema, stage, and source revision.'
	Assert-True ($ClientRecord.hostToolsMode -eq 'rebuild' -and @($ClientRecord.buildInvocations).Count -eq 0) 'A Rebuild client stage record must state that UAT built everything and record no controller build invocation.'
	Assert-True ($ClientRecord.compilerPath -eq $SelectedCompiler -and $ClientRecord.resourceCompilerPath -eq $SelectedResourceCompiler) 'The client stage record must carry the exact UBT-selected toolchain.'
	Assert-True ((@($ClientRecord.clientArguments) -contains '-target=AethelnOnlineClient') -and (@($ClientRecord.clientArguments) -contains '-clean')) 'The client stage record must preserve the exact clean client UAT arguments.'
	Assert-True (-not (Test-Path -LiteralPath (Join-Path $StagedClientRoot 'LinuxServer'))) 'The client stage must not produce server output.'

	$env:AETHELN_TEST_ARCHIVE_ROOT = $StagedServerRoot
	& $Script -ProjectPath $ProjectFile -EngineRoot $EngineRoot -LinuxToolchainRoot $ToolchainRoot -ArchiveRoot $StagedServerRoot -LogRoot (Join-Path $FixtureRoot 'StagedServerLogs') -SourceRevision $Revision -HostToolsBoundary Rebuild -Stage Server
	$ServerRecord = Get-Content -LiteralPath (Join-Path $StagedServerRoot 'phase-server.json') -Raw | ConvertFrom-Json
	Assert-True ($ServerRecord.stage -eq 'server' -and (@($ServerRecord.serverArguments) -contains '-serverplatform=Linux')) 'The server stage record must preserve the exact server UAT arguments.'
	Assert-True (Test-Path -LiteralPath (Join-Path $StagedServerRoot 'RegistryDumps/server-dependency-registry-dump/Page_0.txt')) 'The server stage must publish its dependency registry dump as payload.'
	Assert-True (Test-Path -LiteralPath (Join-Path $StagedServerRoot 'RegistryDumps/server-cooked-inventory-dump/Page_0.txt')) 'The server stage must publish its cooked inventory dump as payload.'
	Assert-True (-not (Test-Path -LiteralPath (Join-Path $StagedServerRoot 'WindowsClient'))) 'The server stage must not produce client output.'

	& $Script -ProjectPath $ProjectFile -EngineRoot $EngineRoot -LinuxToolchainRoot $ToolchainRoot -ArchiveRoot $StagedProvenanceRoot -LogRoot (Join-Path $FixtureRoot 'StagedProvenanceLogs') -SourceRevision $Revision -Stage Provenance -ClientStageRoot $StagedClientRoot -ServerStageRoot $StagedServerRoot
	$StagedProvenance = Get-Content -LiteralPath (Join-Path $StagedProvenanceRoot 'build-provenance.json') -Raw | ConvertFrom-Json
	Assert-True ($StagedProvenance.tools.compiler.path -eq $SelectedCompiler -and $StagedProvenance.tools.compiler.version -eq '14.44.35207') 'Staged provenance must use the client stage record toolchain.'
	Assert-True ($StagedProvenance.build.uatInvocations.server.arguments -contains '-serverplatform=Linux') 'Staged provenance must preserve the exact recorded server UAT arguments.'
	Assert-True ($StagedProvenance.artifacts.inventory.Count -eq 2) 'Staged provenance must inventory every packaged file from both stage payloads.'

	$Failure = $null
	try { & $Script -ProjectPath $ProjectFile -EngineRoot $EngineRoot -LinuxToolchainRoot $ToolchainRoot -ArchiveRoot (Join-Path $FixtureRoot 'StagedProvenanceMismatch') -LogRoot (Join-Path $FixtureRoot 'StagedProvenanceMismatchLogs') -SourceRevision ('1' * 40) -Stage Provenance -ClientStageRoot $StagedClientRoot -ServerStageRoot $StagedServerRoot } catch { $Failure = $_.Exception.Message }
	Assert-True ($Failure -match 'produced from source revision') 'Provenance over stage records from a different revision must fail closed.'
	Write-Output 'PASS: staged client, server, and provenance phases exchange exact records and fail closed on revision mismatch'

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
	& $Script -ProjectPath $ProjectFile -EngineRoot $EngineRoot -LinuxToolchainRoot $ToolchainRoot -ArchiveRoot (Join-Path $FixtureRoot 'DdcArchive1') -LogRoot (Join-Path $FixtureRoot 'DdcLogs1') -SourceRevision $Revision -HostToolsBoundary Rebuild -DerivedDataCachePath $DdcRoot
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
	& $Script -ProjectPath $ProjectFile -EngineRoot $EngineRoot -LinuxToolchainRoot $ToolchainRoot -ArchiveRoot (Join-Path $FixtureRoot 'DdcArchive2') -LogRoot (Join-Path $FixtureRoot 'DdcLogs2') -SourceRevision $Revision -HostToolsBoundary Rebuild -DerivedDataCachePath $DdcRoot
	$Timing2 = Get-Content -LiteralPath (Join-Path $FixtureRoot 'DdcLogs2/build-timing.json') -Raw | ConvertFrom-Json
	Assert-True ($Timing2.derivedDataCache.mode -eq 'persistent' -and $Timing2.derivedDataCache.status -eq 'reused') 'A matching identity record must be recorded as persistent/reused.'
	Write-Output 'PASS: the persistent cache initializes and reuses only under a matching explicit identity'

	$IdentityRaw = Get-Content -LiteralPath $IdentityPath -Raw
	($IdentityRaw -replace 'v26_clang-20\.1\.8-rockylinux8', 'v25_clang-18.1.0-rockylinux8') | Set-Content -LiteralPath $IdentityPath -Encoding UTF8
	$CallsBeforeDdcMismatch = @(Get-Content -LiteralPath $CapturePath).Count
	$Failure = $null
	try { & $Script -ProjectPath $ProjectFile -EngineRoot $EngineRoot -LinuxToolchainRoot $ToolchainRoot -ArchiveRoot (Join-Path $FixtureRoot 'DdcArchive3') -LogRoot (Join-Path $FixtureRoot 'DdcLogs3') -SourceRevision $Revision -HostToolsBoundary Rebuild -DerivedDataCachePath $DdcRoot } catch { $Failure = $_.Exception.Message }
	Assert-True ($Failure -match 'failed identity validation') 'A mismatched cache identity must fail closed by default.'
	Assert-True (@(Get-Content -LiteralPath $CapturePath).Count -eq $CallsBeforeDdcMismatch) 'A mismatched cache identity must stop before any UAT invocation.'
	$env:AETHELN_TEST_ARCHIVE_ROOT = Join-Path $FixtureRoot 'DdcArchive4'
	& $Script -ProjectPath $ProjectFile -EngineRoot $EngineRoot -LinuxToolchainRoot $ToolchainRoot -ArchiveRoot (Join-Path $FixtureRoot 'DdcArchive4') -LogRoot (Join-Path $FixtureRoot 'DdcLogs4') -SourceRevision $Revision -HostToolsBoundary Rebuild -DerivedDataCachePath $DdcRoot -CacheFallback CleanIsolated
	$Timing4 = Get-Content -LiteralPath (Join-Path $FixtureRoot 'DdcLogs4/build-timing.json') -Raw | ConvertFrom-Json
	Assert-True ($Timing4.derivedDataCache.mode -eq 'clean-isolated-fallback' -and $Timing4.derivedDataCache.status -eq 'fallback_mismatch') 'The clean fallback must be recorded with its mismatch reason.'
	$IsolatedPath = Join-Path (Join-Path $FixtureRoot 'DdcLogs4') 'ddc-clean-isolated'
	$FallbackEnvLines = @(Get-Content -LiteralPath $DdcCapture | Select-Object -Last 2)
	Assert-True (@($FallbackEnvLines | Where-Object { $_ -ne $IsolatedPath }).Count -eq 0) 'The clean fallback must re-derive into a fresh run-scoped cache, never the mismatched root.'
	Set-Content -LiteralPath $IdentityPath -Value 'not-json' -Encoding UTF8
	$env:AETHELN_TEST_ARCHIVE_ROOT = Join-Path $FixtureRoot 'DdcArchive5'
	& $Script -ProjectPath $ProjectFile -EngineRoot $EngineRoot -LinuxToolchainRoot $ToolchainRoot -ArchiveRoot (Join-Path $FixtureRoot 'DdcArchive5') -LogRoot (Join-Path $FixtureRoot 'DdcLogs5') -SourceRevision $Revision -HostToolsBoundary Rebuild -DerivedDataCachePath $DdcRoot -CacheFallback CleanIsolated
	$Timing5 = Get-Content -LiteralPath (Join-Path $FixtureRoot 'DdcLogs5/build-timing.json') -Raw | ConvertFrom-Json
	Assert-True ($Timing5.derivedDataCache.mode -eq 'clean-isolated-fallback' -and $Timing5.derivedDataCache.status -eq 'fallback_corrupt') 'A corrupt identity record must take the clean fallback with its corrupt reason.'
	$ForeignDdc = Join-Path $FixtureRoot 'ForeignDdc'
	New-Item -ItemType Directory -Path $ForeignDdc | Out-Null
	Set-Content -LiteralPath (Join-Path $ForeignDdc 'entry.bin') -Value 'foreign' -Encoding Ascii
	$CallsBeforeForeign = @(Get-Content -LiteralPath $CapturePath).Count
	$Failure = $null
	try { & $Script -ProjectPath $ProjectFile -EngineRoot $EngineRoot -LinuxToolchainRoot $ToolchainRoot -ArchiveRoot (Join-Path $FixtureRoot 'DdcArchive6') -LogRoot (Join-Path $FixtureRoot 'DdcLogs6') -SourceRevision $Revision -HostToolsBoundary Rebuild -DerivedDataCachePath $ForeignDdc } catch { $Failure = $_.Exception.Message }
	Assert-True ($Failure -match 'failed identity validation' -and @(Get-Content -LiteralPath $CapturePath).Count -eq $CallsBeforeForeign) 'A non-empty cache without an identity record is unverifiable and must fail closed before UAT.'
	$FileDdc = Join-Path $FixtureRoot 'ddc-as-file.txt'
	Set-Content -LiteralPath $FileDdc -Value 'blocking' -Encoding Ascii
	$Failure = $null
	try { & $Script -ProjectPath $ProjectFile -EngineRoot $EngineRoot -LinuxToolchainRoot $ToolchainRoot -ArchiveRoot (Join-Path $FixtureRoot 'DdcArchive7') -LogRoot (Join-Path $FixtureRoot 'DdcLogs7') -SourceRevision $Revision -HostToolsBoundary Rebuild -DerivedDataCachePath $FileDdc } catch { $Failure = $_.Exception.Message }
	Assert-True ($Failure -match 'failed identity validation') 'An unavailable cache path must fail closed by default.'
	Remove-Item Env:AETHELN_TEST_DDC_CAPTURE
	Write-Output 'PASS: cache identity mismatch, corruption, unverifiable, and unavailable states fail closed or take the recorded clean fallback'

	$MismatchTiming = Get-Content -LiteralPath (Join-Path $FixtureRoot 'DdcLogs3/build-timing.json') -Raw | ConvertFrom-Json
	Assert-True ($MismatchTiming.derivedDataCache.mode -eq 'persistent' -and $MismatchTiming.derivedDataCache.status -eq 'failed_mismatch') 'A fail-closed identity mismatch must record its failed cache state in the timing record.'
	Assert-True (@($MismatchTiming.substeps | Where-Object { $_.name -eq 'derived-data-cache-resolution' -and $_.status -eq 'failed' }).Count -eq 1) 'The failed cache-resolution substep must be recorded.'
	Assert-True (@($MismatchTiming.uatSteps).Count -eq 0) 'A fail-closed identity mismatch must record no UAT step because no UAT process started.'
	Assert-True ($MismatchTiming.identity.engineGitRevision -eq $CanonicalEnginePin -and $MismatchTiming.identity.engineGitRevisionStatus -eq 'verified') 'A failed post-LogRoot run must retain the identity fields that were verified.'
	Write-Output 'PASS: a fail-closed cache identity mismatch starts no UAT process but still emits bounded failed timing evidence'

	Assert-True (-not $Calls[0].Contains('-nocompileeditor') -and -not $Calls[1].Contains('-nocompileeditor') -and -not $Calls[0].Contains('-skipbuild') -and $Calls[0].Contains('-build') -and $Calls[1].Contains('-build')) 'Without the prebuilt boundary the UAT build agenda (host editor/engine tools included) must run.'
	Assert-True (-not (Test-Path -LiteralPath $UbtCapturePath)) 'The explicit Rebuild selection must never start controller-owned UnrealBuildTool builds.'
	$CallsBeforeUnsetBoundary = @(Get-Content -LiteralPath $CapturePath).Count
	$Failure = $null
	try { & $Script -ProjectPath $ProjectFile -EngineRoot $EngineRoot -LinuxToolchainRoot $ToolchainRoot -ArchiveRoot (Join-Path $FixtureRoot 'UnsetBoundaryArchive') -LogRoot (Join-Path $FixtureRoot 'UnsetBoundaryLogs') -SourceRevision $Revision } catch { $Failure = $_.Exception.Message }
	Assert-True ($Failure -match 'host_tools_configuration_required') 'A build without an explicit host-tools selection must fail closed, never rebuild implicitly.'
	Assert-True (@(Get-Content -LiteralPath $CapturePath).Count -eq $CallsBeforeUnsetBoundary) 'A missing host-tools selection must stop before any UAT invocation.'
	Write-Output 'PASS: a missing host-tools selection fails closed instead of launching an implicit rebuild'

	$AttestationDirectory = Join-Path $FixtureRoot 'Attestation'
	New-Item -ItemType Directory -Path $AttestationDirectory | Out-Null
	$AttestationPath = Join-Path $AttestationDirectory 'host-tools-attestation.json'
	$CallsBeforeAttest = @(Get-Content -LiteralPath $CapturePath).Count
	& $Script -ProjectPath $ProjectFile -EngineRoot $EngineRoot -LinuxToolchainRoot $ToolchainRoot -ArchiveRoot (Join-Path $FixtureRoot 'AttestArchive') -LogRoot (Join-Path $FixtureRoot 'AttestLogs') -SourceRevision $Revision -Stage AttestHostTools -HostToolsAttestationPath $AttestationPath -ProvisioningEvidence 'legacy scheduled milestone build, retained runner evidence 2026-09-04'
	Assert-True (@(Get-Content -LiteralPath $CapturePath).Count -eq $CallsBeforeAttest -and -not (Test-Path -LiteralPath $UbtCapturePath)) 'The attestation step must build nothing, through UAT or UnrealBuildTool.'
	$Attestation = Get-Content -LiteralPath $AttestationPath -Raw | ConvertFrom-Json
	Assert-True ($Attestation.schemaVersion -eq 1 -and $Attestation.engineGitRevision -eq $CanonicalEnginePin) 'The attestation must bind the canonical pinned engine revision.'
	$RequiredToolPaths = @(
		'Engine/Binaries/Win64/UnrealEditor.target',
		'Engine/Binaries/Win64/UnrealEditor.exe',
		'Engine/Binaries/Win64/UnrealEditor-Cmd.exe',
		'Engine/Binaries/Win64/UnrealEditor-Core.dll',
		'Engine/Plugins/FixturePlugin/Binaries/Win64/UnrealEditor-FixturePlugin.dll',
		'Engine/Binaries/Win64/UnrealEditor.modules',
		'Engine/Binaries/Win64/UnrealEditor.version',
		'Engine/Binaries/Win64/UnrealPak.target',
		'Engine/Binaries/Win64/UnrealPak.exe',
		'Engine/Binaries/Win64/ShaderCompileWorker.target',
		'Engine/Binaries/Win64/ShaderCompileWorker.exe'
	)
	$AttestedPaths = @($Attestation.files | ForEach-Object { [string] $_.path } | Sort-Object)
	Assert-True (($AttestedPaths -join ';') -eq (@($RequiredToolPaths | Sort-Object) -join ';')) 'The attestation must record exactly the receipt-derived host build-product closure, receipts included.'
	Assert-True (@($AttestedPaths | Where-Object { $_ -match '\.pdb$' }).Count -eq 0) 'Symbol files listed in a receipt must never enter the attested closure.'
	foreach ($AttestedFile in @($Attestation.files)) { Assert-True (([string] $AttestedFile.sha256) -cmatch '^[0-9a-f]{64}$' -and [long] $AttestedFile.sizeBytes -gt 0) 'Every attested tool must carry a lowercase SHA-256 and its exact size.' }
	Assert-True ($Attestation.provisioningEvidence -match 'retained runner evidence') 'The attestation must record the explicit provisioning evidence reference.'
	$AttestTiming = Get-Content -LiteralPath (Join-Path $FixtureRoot 'AttestLogs/build-timing.json') -Raw | ConvertFrom-Json
	Assert-True ($AttestTiming.hostTools.mode -eq 'attest' -and $AttestTiming.hostTools.status -eq 'written') 'The attestation step must record its state in the timing record.'
	Write-Output 'PASS: the explicit attestation step records the canonical pin and content identity of every required host tool'

	$CallsBeforePrebuilt = @(Get-Content -LiteralPath $CapturePath).Count
	$UnrealPakPath = Join-Path $EditorDirectory 'UnrealPak.exe'
	$AttestedUnrealPakHash = (Get-FileHash -LiteralPath $UnrealPakPath -Algorithm SHA256).Hash
	$ProjectEditorManifestPath = Join-Path $ProjectRoot 'Binaries/Win64/UnrealEditor.modules'
	$env:AETHELN_TEST_ARCHIVE_ROOT = Join-Path $FixtureRoot 'PrebuiltArchive'
	& $Script -ProjectPath $ProjectFile -EngineRoot $EngineRoot -LinuxToolchainRoot $ToolchainRoot -ArchiveRoot (Join-Path $FixtureRoot 'PrebuiltArchive') -LogRoot (Join-Path $FixtureRoot 'PrebuiltLogs') -SourceRevision $Revision -HostToolsBoundary Prebuilt -EngineRevision $CanonicalEnginePin -HostToolsAttestationPath $AttestationPath -RunnerName 'fixture-runner'
	$PrebuiltCalls = @(Get-Content -LiteralPath $CapturePath)
	Assert-True ($PrebuiltCalls.Count -eq $CallsBeforePrebuilt + 2) 'The verified prebuilt boundary must still run both UAT invocations.'
	foreach ($PrebuiltCall in @($PrebuiltCalls | Select-Object -Last 2)) {
		Assert-True ($PrebuiltCall.Contains('-skipbuild') -and -not ($PrebuiltCall -match '(^|\s)-build(\s|$)')) 'A verified attested boundary must invoke UAT without its build agenda so no host tool can be cleaned or rebuilt by UAT.'
		foreach ($Required in @('-cook', '-clean', '-stage', '-pak', '-archive')) { Assert-True ($PrebuiltCall.Contains($Required)) "The prebuilt UAT invocation must keep clean cooking, staging, packaging, and archiving ('$Required')." }
	}
	$PrebuiltTiming = Get-Content -LiteralPath (Join-Path $FixtureRoot 'PrebuiltLogs/build-timing.json') -Raw | ConvertFrom-Json
	Assert-True ($PrebuiltTiming.hostTools.mode -eq 'prebuilt' -and $PrebuiltTiming.hostTools.status -eq 'verified' -and $PrebuiltTiming.hostTools.engineRevision -eq $CanonicalEnginePin) 'The verified prebuilt boundary must be recorded in the timing record.'
	Assert-True ($PrebuiltTiming.identity.runnerName -eq 'fixture-runner') 'The forwarded runner name must be bound into the timing identity.'
	# Defect 1: the cook loads every project module the .uproject declares for
	# the editor target; -nocompileeditor removed their only producer.
	Assert-True (Test-Path -LiteralPath $ProjectEditorManifestPath -PathType Leaf) 'The prebuilt run must produce the project editor module manifest the cook loads.'
	$ProjectEditorManifest = Get-Content -LiteralPath $ProjectEditorManifestPath -Raw | ConvertFrom-Json
	Assert-True ($ProjectEditorManifest.BuildId -eq 'fixture') 'The project editor manifest must carry the attested engine BuildId.'
	foreach ($Module in @('GameCore', 'GameCombat', 'GameUI', 'GameNet', 'GameServer', 'GameTests')) {
		Assert-True (Test-Path -LiteralPath (Join-Path $ProjectRoot "Binaries/Win64/UnrealEditor-$Module.dll") -PathType Leaf) "The prebuilt run must produce the project editor module '$Module' the cook loads."
	}
	# Defect 2: the UAT build agenda cleaned and relinked the attested UnrealPak
	# on every run, so the next prebuilt run failed closed.
	Assert-True ((Get-FileHash -LiteralPath $UnrealPakPath -Algorithm SHA256).Hash -eq $AttestedUnrealPakHash) 'A prebuilt packaging run must leave the attested UnrealPak byte-identical.'
	$Sequence = @(Get-Content -LiteralPath $SequencePath | Select-Object -Last 9)
	Assert-True (($Sequence -join ';') -eq 'UBT AethelnOnlineEditor Win64 Development build;UBT AethelnOnlineClient Win64 Development clean;UBT AethelnOnlineClient Win64 Development build;UBT BootstrapPackagedGame Win64 Shipping clean;UBT BootstrapPackagedGame Win64 Shipping build;UAT client;UBT AethelnOnlineServer Linux Development clean;UBT AethelnOnlineServer Linux Development build;UAT server') "The prebuilt run must prepare the project editor, then clean and build each selected project target (plus the client bootstrap) before its UAT invocation; observed: $($Sequence -join ';')"
	$UbtCalls = @(Get-Content -LiteralPath $UbtCapturePath)
	$EditorCalls = @($UbtCalls | Where-Object { $_ -like 'AethelnOnlineEditor Win64 Development *' })
	Assert-True ($EditorCalls.Count -eq 1 -and $EditorCalls[0].Contains($ProjectFile) -and $EditorCalls[0].Contains('-NoEngineChanges') -and $EditorCalls[0].Contains('-WaitMutex') -and $EditorCalls[0].Contains('-NoHotReloadFromIDE') -and -not $EditorCalls[0].Contains('-Clean') -and -not $EditorCalls[0].Contains('-remoteini=')) 'The project editor preparation must build AethelnOnlineEditor Win64 Development against the project with -NoEngineChanges, never -Clean, and without the cooked-target -remoteini argument.'
	foreach ($ProjectTarget in @(@{ Name = 'AethelnOnlineClient'; Platform = 'Win64' }, @{ Name = 'AethelnOnlineServer'; Platform = 'Linux' })) {
		$TargetPrefix = "$($ProjectTarget.Name) $($ProjectTarget.Platform) Development "
		$CleanCalls = @($UbtCalls | Where-Object { $_ -like "$TargetPrefix*" -and $_.Contains('-Clean') })
		$BuildCalls = @($UbtCalls | Where-Object { $_ -like "$TargetPrefix*" -and -not $_.Contains('-Clean') })
		Assert-True ($CleanCalls.Count -eq 1 -and $CleanCalls[0].Contains($ProjectFile) -and $CleanCalls[0].Contains("-remoteini=$ProjectRoot") -and $CleanCalls[0].Contains('-NoHotReload') -and $CleanCalls[0].Contains('-NoUBTMakefiles')) "The $($ProjectTarget.Name) clean must be a separate UnrealBuildTool -Clean invocation with the pinned UAT clean shape."
		Assert-True ($BuildCalls.Count -eq 1 -and $BuildCalls[0].Contains($ProjectFile) -and $BuildCalls[0].Contains("-remoteini=$ProjectRoot") -and $BuildCalls[0] -match "-Log=\S+UBT-$($ProjectTarget.Name)-$($ProjectTarget.Platform)-Development\.txt") "The $($ProjectTarget.Name) build must be a separate UnrealBuildTool build with the pinned UAT build shape and its own log."
	}
	$BootstrapCalls = @($UbtCalls | Where-Object { $_ -like 'BootstrapPackagedGame Win64 Shipping *' })
	Assert-True ($BootstrapCalls.Count -eq 2 -and @($BootstrapCalls | Where-Object { $_.Contains('.uproject') }).Count -eq 0) 'The client bootstrap launcher formerly built by the UAT agenda must be cleaned and built explicitly as an engine program.'
	Assert-True (Test-Path -LiteralPath (Join-Path $EditorDirectory 'BootstrapPackagedGame-Win64-Shipping.exe') -PathType Leaf) 'The bootstrap launcher executable must exist before staging.'
	$SubstepNames = @($PrebuiltTiming.substeps | ForEach-Object { $_.name })
	foreach ($Required in @('project-editor-preparation', 'project-editor-identity', 'host-tools-postpreparation-verification', 'client-project-clean', 'client-project-build', 'client-bootstrap-clean', 'client-bootstrap-build', 'client-uat-build-cook-package', 'server-project-clean', 'server-project-build', 'server-uat-build-cook-package', 'host-tools-final-verification')) {
		Assert-True ($SubstepNames -contains $Required) "The prebuilt timing record must carry substep '$Required'."
	}
	Assert-True ($SubstepNames.IndexOf('host-tools-postpreparation-verification') -lt $SubstepNames.IndexOf('client-project-clean') -and $SubstepNames.IndexOf('host-tools-final-verification') -gt $SubstepNames.IndexOf('server-uat-build-cook-package') -and $SubstepNames.IndexOf('host-tools-final-verification') -lt $SubstepNames.IndexOf('provenance-write')) 'The attestation must be re-verified after preparation and again after packaging, before provenance is written.'
	Assert-True (@($PrebuiltTiming.uatSteps | Where-Object { $_.step -eq 'BUILD' }).Count -eq 0 -and @($PrebuiltTiming.uatSteps | Where-Object { $_.step -eq 'COOK' }).Count -eq 2) 'Under the prebuilt boundary UAT must report no BUILD step while the cook still runs in both invocations.'
	$PrebuiltProvenance = Get-Content -LiteralPath (Join-Path $FixtureRoot 'PrebuiltArchive/build-provenance.json') -Raw | ConvertFrom-Json
	Assert-True ($PrebuiltProvenance.schemaVersion -eq 3 -and $PrebuiltProvenance.build.hostToolsMode -eq 'prebuilt') 'Provenance must record the host-tools mode that produced the binaries.'
	$ExplicitBuilds = @($PrebuiltProvenance.build.explicitBuildInvocations)
	Assert-True ($ExplicitBuilds.Count -eq 7) 'Provenance must record every explicit controller build invocation (editor preparation, client clean/build, bootstrap clean/build, server clean/build).'
	foreach ($ExplicitBuild in $ExplicitBuilds) { Assert-True ((@($ExplicitBuild.arguments).Count -ge 3) -and ([string] $ExplicitBuild.executable).EndsWith('Build.bat') -and -not [string]::IsNullOrWhiteSpace([string] $ExplicitBuild.log) -and [double] $ExplicitBuild.durationSeconds -ge 0 -and $ExplicitBuild.exitCode -eq 0) 'Every explicit build invocation must record its executable, exact arguments, log, duration, and exit code.' }
	Assert-True ($PrebuiltProvenance.tools.compiler.path -eq $SelectedCompiler -and $PrebuiltProvenance.tools.windowsSdk.resourceCompilerPath -eq $SelectedResourceCompiler) 'Under the prebuilt boundary the compiler evidence must come from the controller-owned client build log, not from a UAT build that never ran.'
	Assert-True (-not (Test-Path -LiteralPath (Join-Path $FixtureRoot 'PrebuiltLogs/client-automationtool/UBA-client.txt'))) 'The fixture must not supply UAT compiler sidecars when UAT builds nothing.'
	Write-Output 'PASS: the attested prebuilt boundary prepares the project editor, cleans and builds the project targets and bootstrap itself, packages without the UAT build agenda, and leaves the attested host tools byte-identical'

	$UbtCallsBeforeSecondPrebuilt = $UbtCalls.Count
	$env:AETHELN_TEST_ARCHIVE_ROOT = Join-Path $FixtureRoot 'PrebuiltClientArchive'
	& $Script -ProjectPath $ProjectFile -EngineRoot $EngineRoot -LinuxToolchainRoot $ToolchainRoot -ArchiveRoot (Join-Path $FixtureRoot 'PrebuiltClientArchive') -LogRoot (Join-Path $FixtureRoot 'PrebuiltClientLogs') -SourceRevision $Revision -HostToolsBoundary Prebuilt -EngineRevision $CanonicalEnginePin -HostToolsAttestationPath $AttestationPath -Stage Client
	Assert-True (@(Get-Content -LiteralPath $UbtCapturePath).Count -eq $UbtCallsBeforeSecondPrebuilt + 5) 'A second prebuilt run must pass against the unchanged attestation and run exactly the editor preparation plus client clean/build and bootstrap clean/build.'
	$PrebuiltClientRecord = Get-Content -LiteralPath (Join-Path $FixtureRoot 'PrebuiltClientArchive/phase-client.json') -Raw | ConvertFrom-Json
	Assert-True ($PrebuiltClientRecord.schemaVersion -eq 2 -and $PrebuiltClientRecord.hostToolsMode -eq 'prebuilt' -and @($PrebuiltClientRecord.buildInvocations).Count -eq 5 -and $PrebuiltClientRecord.compilerPath -eq $SelectedCompiler) 'The client stage record must carry the host-tools mode, the explicit build invocations, and the UBT-log-derived toolchain.'
	Assert-True (@($PrebuiltClientRecord.clientArguments) -contains '-skipbuild') 'The client stage record must preserve the exact UAT arguments without the build agenda.'
	$env:AETHELN_TEST_ARCHIVE_ROOT = Join-Path $FixtureRoot 'PrebuiltServerArchive'
	& $Script -ProjectPath $ProjectFile -EngineRoot $EngineRoot -LinuxToolchainRoot $ToolchainRoot -ArchiveRoot (Join-Path $FixtureRoot 'PrebuiltServerArchive') -LogRoot (Join-Path $FixtureRoot 'PrebuiltServerLogs') -SourceRevision $Revision -HostToolsBoundary Prebuilt -EngineRevision $CanonicalEnginePin -HostToolsAttestationPath $AttestationPath -Stage Server
	$ServerSequence = @(Get-Content -LiteralPath $SequencePath | Select-Object -Last 4)
	Assert-True (($ServerSequence -join ';') -eq 'UBT AethelnOnlineEditor Win64 Development build;UBT AethelnOnlineServer Linux Development clean;UBT AethelnOnlineServer Linux Development build;UAT server') "The server stage must prepare the editor and clean/build only the server target, without the client bootstrap; observed: $($ServerSequence -join ';')"
	$PrebuiltServerRecord = Get-Content -LiteralPath (Join-Path $FixtureRoot 'PrebuiltServerArchive/phase-server.json') -Raw | ConvertFrom-Json
	Assert-True ($PrebuiltServerRecord.schemaVersion -eq 2 -and $PrebuiltServerRecord.hostToolsMode -eq 'prebuilt' -and @($PrebuiltServerRecord.buildInvocations).Count -eq 3) 'The server stage record must carry the host-tools mode and its explicit build invocations.'
	$UbtCallsBeforeProvenance = @(Get-Content -LiteralPath $UbtCapturePath).Count
	$UatCallsBeforeProvenance = @(Get-Content -LiteralPath $CapturePath).Count
	& $Script -ProjectPath $ProjectFile -EngineRoot $EngineRoot -LinuxToolchainRoot $ToolchainRoot -ArchiveRoot (Join-Path $FixtureRoot 'PrebuiltProvenanceArchive') -LogRoot (Join-Path $FixtureRoot 'PrebuiltProvenanceLogs') -SourceRevision $Revision -Stage Provenance -ClientStageRoot (Join-Path $FixtureRoot 'PrebuiltClientArchive') -ServerStageRoot (Join-Path $FixtureRoot 'PrebuiltServerArchive')
	Assert-True (@(Get-Content -LiteralPath $UbtCapturePath).Count -eq $UbtCallsBeforeProvenance -and @(Get-Content -LiteralPath $CapturePath).Count -eq $UatCallsBeforeProvenance) 'The provenance stage must start no build.'
	$SplitProvenance = Get-Content -LiteralPath (Join-Path $FixtureRoot 'PrebuiltProvenanceArchive/build-provenance.json') -Raw | ConvertFrom-Json
	Assert-True ($SplitProvenance.build.hostToolsMode -eq 'prebuilt' -and @($SplitProvenance.build.explicitBuildInvocations).Count -eq 8 -and $SplitProvenance.tools.compiler.path -eq $SelectedCompiler) 'Split-stage provenance must consume the host-tools mode, explicit build invocations, and toolchain from both stage records.'
	Write-Output 'PASS: split client, server, and provenance stages carry the explicit build evidence under the prebuilt boundary'

	$OriginalEditorCoreDll = [System.IO.File]::ReadAllBytes($EditorCoreDllPath)
	foreach ($PrebuiltFailure in @(
		@{ Label = 'editor-preparation-failure'; Variable = 'AETHELN_TEST_UBT_FAIL'; Value = 'AethelnOnlineEditor:build'; Expect = 'project editor preparation failed with exit code 1'; UbtCalls = 1; FailedSubstep = 'project-editor-preparation' },
		@{ Label = 'editor-buildid-mismatch'; Variable = 'AETHELN_TEST_PROJECT_BUILDID'; Value = 'other'; Expect = 'does not match the attested engine manifest BuildId'; UbtCalls = 1; FailedSubstep = 'project-editor-identity' },
		@{ Label = 'editor-empty-manifest'; Variable = 'AETHELN_TEST_UBT_EMPTY_MANIFEST'; Value = '1'; Expect = 'lists no modules'; UbtCalls = 1; FailedSubstep = 'project-editor-identity' },
		@{ Label = 'editor-missing-required-module'; Variable = 'AETHELN_TEST_UBT_OMIT_MODULE'; Value = 'GameServer'; Expect = "required project editor module 'GameServer'"; UbtCalls = 1; FailedSubstep = 'project-editor-identity' },
		@{ Label = 'editor-missing-module-product'; Variable = 'AETHELN_TEST_UBT_OMIT_DLL'; Value = 'GameCore'; Expect = 'does not exist under the project'; UbtCalls = 1; FailedSubstep = 'project-editor-identity' },
		@{ Label = 'editor-engine-mutation'; Variable = 'AETHELN_TEST_UBT_TAMPER_ENGINE'; Value = '1'; Expect = "Host tool 'Engine/Binaries/Win64/UnrealEditor-Core.dll'"; UbtCalls = 1; FailedSubstep = 'host-tools-postpreparation-verification' },
		@{ Label = 'client-clean-failure'; Variable = 'AETHELN_TEST_UBT_FAIL'; Value = 'AethelnOnlineClient:clean'; Expect = 'client project clean failed with exit code 1'; UbtCalls = 2; FailedSubstep = 'client-project-clean' },
		@{ Label = 'client-build-failure'; Variable = 'AETHELN_TEST_UBT_FAIL'; Value = 'AethelnOnlineClient:build'; Expect = 'client project build failed with exit code 1'; UbtCalls = 3; FailedSubstep = 'client-project-build' },
		@{ Label = 'client-build-without-products'; Variable = 'AETHELN_TEST_UBT_NO_PRODUCTS'; Value = 'AethelnOnlineClient'; Expect = 'did not produce its target receipt'; UbtCalls = 3; FailedSubstep = 'client-project-build' },
		@{ Label = 'bootstrap-build-failure'; Variable = 'AETHELN_TEST_UBT_FAIL'; Value = 'BootstrapPackagedGame:build'; Expect = 'client bootstrap build failed with exit code 1'; UbtCalls = 5; FailedSubstep = 'client-bootstrap-build' },
		@{ Label = 'bootstrap-build-without-product'; Variable = 'AETHELN_TEST_UBT_NO_PRODUCTS'; Value = 'BootstrapPackagedGame'; Expect = 'did not produce'; UbtCalls = 5; FailedSubstep = 'client-bootstrap-build' }
	)) {
		# Each case starts from the milestone's clean-checkout state: no project
		# build products survive from the previous run.
		Remove-Item -LiteralPath (Join-Path $ProjectRoot 'Binaries') -Recurse -Force -ErrorAction SilentlyContinue
		$UbtCallsBeforeFailure = @(Get-Content -LiteralPath $UbtCapturePath).Count
		$UatCallsBeforeFailure = @(Get-Content -LiteralPath $CapturePath).Count
		Set-Item -Path "Env:$($PrebuiltFailure.Variable)" -Value ([string] $PrebuiltFailure.Value)
		$FailureArchive = Join-Path $FixtureRoot "PrebuiltFail-$($PrebuiltFailure.Label)"
		$FailureLogs = Join-Path $FixtureRoot "PrebuiltFailLogs-$($PrebuiltFailure.Label)"
		$Failure = $null
		try { & $Script -ProjectPath $ProjectFile -EngineRoot $EngineRoot -LinuxToolchainRoot $ToolchainRoot -ArchiveRoot $FailureArchive -LogRoot $FailureLogs -SourceRevision $Revision -HostToolsBoundary Prebuilt -EngineRevision $CanonicalEnginePin -HostToolsAttestationPath $AttestationPath -Stage Client } catch { $Failure = $_.Exception.Message }
		Remove-Item -Path "Env:$($PrebuiltFailure.Variable)"
		[System.IO.File]::WriteAllBytes($EditorCoreDllPath, $OriginalEditorCoreDll)
		Assert-True ($null -ne $Failure -and $Failure -match [regex]::Escape([string] $PrebuiltFailure.Expect)) "The $($PrebuiltFailure.Label) case must fail closed with an actionable message; observed: $Failure"
		Assert-True (@(Get-Content -LiteralPath $UbtCapturePath).Count -eq $UbtCallsBeforeFailure + $PrebuiltFailure.UbtCalls) "The $($PrebuiltFailure.Label) case must stop immediately after the failing UnrealBuildTool step ($($PrebuiltFailure.UbtCalls) call(s))."
		Assert-True (@(Get-Content -LiteralPath $CapturePath).Count -eq $UatCallsBeforeFailure) "The $($PrebuiltFailure.Label) case must start no UAT invocation."
		Assert-True (-not (Test-Path -LiteralPath (Join-Path $FailureArchive 'phase-client.json'))) "The $($PrebuiltFailure.Label) case must publish no stage record."
		$FailureTiming = Get-Content -LiteralPath (Join-Path $FailureLogs 'build-timing.json') -Raw | ConvertFrom-Json
		Assert-True (@($FailureTiming.substeps | Where-Object { $_.name -eq $PrebuiltFailure.FailedSubstep -and $_.status -eq 'failed' }).Count -eq 1) "The $($PrebuiltFailure.Label) case must record '$($PrebuiltFailure.FailedSubstep)' as the failed substep."
		Assert-True (@($FailureTiming.substeps | Where-Object { $_.name -in @('client-uat-build-cook-package', 'client-output-validation', 'host-tools-final-verification', 'provenance-write') }).Count -eq 0) "The $($PrebuiltFailure.Label) case must run no downstream substep."
	}
	$env:AETHELN_TEST_UAT_TAMPER = '1'
	$env:AETHELN_TEST_ARCHIVE_ROOT = Join-Path $FixtureRoot 'PrebuiltUatTamperArchive'
	Remove-Item -LiteralPath (Join-Path $ProjectRoot 'Binaries') -Recurse -Force -ErrorAction SilentlyContinue
	$UatCallsBeforeUatTamper = @(Get-Content -LiteralPath $CapturePath).Count
	$Failure = $null
	try { & $Script -ProjectPath $ProjectFile -EngineRoot $EngineRoot -LinuxToolchainRoot $ToolchainRoot -ArchiveRoot (Join-Path $FixtureRoot 'PrebuiltUatTamperArchive') -LogRoot (Join-Path $FixtureRoot 'PrebuiltUatTamperLogs') -SourceRevision $Revision -HostToolsBoundary Prebuilt -EngineRevision $CanonicalEnginePin -HostToolsAttestationPath $AttestationPath -Stage Client } catch { $Failure = $_.Exception.Message }
	Remove-Item Env:AETHELN_TEST_UAT_TAMPER
	[System.IO.File]::WriteAllBytes($EditorCoreDllPath, $OriginalEditorCoreDll)
	Assert-True ($null -ne $Failure -and $Failure -match "Host tool 'Engine/Binaries/Win64/UnrealEditor-Core.dll' (size|content) does not match") "An attested host tool mutated during UAT must fail the final verification closed; observed: $Failure"
	Assert-True (@(Get-Content -LiteralPath $CapturePath).Count -eq $UatCallsBeforeUatTamper + 1) 'The UAT tamper case runs exactly the client UAT invocation before the final verification stops it.'
	Assert-True (-not (Test-Path -LiteralPath (Join-Path $FixtureRoot 'PrebuiltUatTamperArchive/phase-client.json'))) 'A failed final verification must publish no stage record.'
	$UatTamperTiming = Get-Content -LiteralPath (Join-Path $FixtureRoot 'PrebuiltUatTamperLogs/build-timing.json') -Raw | ConvertFrom-Json
	Assert-True (@($UatTamperTiming.substeps | Where-Object { $_.name -eq 'host-tools-final-verification' -and $_.status -eq 'failed' }).Count -eq 1 -and @($UatTamperTiming.substeps | Where-Object { $_.name -eq 'client-output-validation' -and $_.status -eq 'passed' }).Count -eq 1) 'The final verification must run after output validation and be recorded as the failed substep.'
	Write-Output 'PASS: preparation, identity, clean, build, bootstrap, and in-UAT tampering failures stop the prebuilt run closed with no downstream execution and no regenerated attestation'
	# Every later case is either a boundary rejection or a Rebuild run; none may
	# start a controller-owned UnrealBuildTool build (asserted at the end).
	$UbtCallsAfterPrebuiltCoverage = @(Get-Content -LiteralPath $UbtCapturePath).Count

	$CallsBeforeInvalidBoundary = @(Get-Content -LiteralPath $CapturePath).Count
	$Failure = $null
	try { & $Script -ProjectPath $ProjectFile -EngineRoot $EngineRoot -LinuxToolchainRoot $ToolchainRoot -ArchiveRoot (Join-Path $FixtureRoot 'PrebuiltNoAttestArchive') -LogRoot (Join-Path $FixtureRoot 'PrebuiltNoAttestLogs') -SourceRevision $Revision -HostToolsBoundary Prebuilt -EngineRevision $CanonicalEnginePin } catch { $Failure = $_.Exception.Message }
	Assert-True ($Failure -match 'requires -HostToolsAttestationPath') 'The prebuilt boundary without an attestation record must fail closed.'

	$env:AETHELN_TEST_ENGINE_HEAD = ('5' * 40)
	$Failure = $null
	try { & $Script -ProjectPath $ProjectFile -EngineRoot $EngineRoot -LinuxToolchainRoot $ToolchainRoot -ArchiveRoot (Join-Path $FixtureRoot 'PrebuiltWrongPinArchive') -LogRoot (Join-Path $FixtureRoot 'PrebuiltWrongPinLogs') -SourceRevision $Revision -HostToolsBoundary Prebuilt -EngineRevision ('5' * 40) -HostToolsAttestationPath $AttestationPath } catch { $Failure = $_.Exception.Message }
	Assert-True ($Failure -match 'canonical pinned engine revision') 'A wrong-but-checkout-matching engine SHA must fail closed as noncanonical.'
	$Failure = $null
	try { & $Script -ProjectPath $ProjectFile -EngineRoot $EngineRoot -LinuxToolchainRoot $ToolchainRoot -ArchiveRoot (Join-Path $FixtureRoot 'PrebuiltWrongHeadArchive') -LogRoot (Join-Path $FixtureRoot 'PrebuiltWrongHeadLogs') -SourceRevision $Revision -HostToolsBoundary Prebuilt -EngineRevision $CanonicalEnginePin -HostToolsAttestationPath $AttestationPath } catch { $Failure = $_.Exception.Message }
	Assert-True ($Failure -match 'not the canonical pinned') 'An engine checkout away from the canonical pin must fail the prebuilt boundary closed.'
	$WrongHeadTiming = Get-Content -LiteralPath (Join-Path $FixtureRoot 'PrebuiltWrongHeadLogs/build-timing.json') -Raw | ConvertFrom-Json
	Assert-True (@($WrongHeadTiming.substeps | Where-Object { $_.name -eq 'host-tools-boundary' -and $_.status -eq 'failed' }).Count -eq 1) 'A failed prebuilt boundary must still emit bounded failed timing evidence.'
	Assert-True ($WrongHeadTiming.identity.engineGitRevision -eq ('5' * 40) -and $WrongHeadTiming.identity.engineGitRevisionStatus -eq 'verified') 'Failed-boundary timing evidence must retain the engine identity that was actually observed.'
	$env:AETHELN_TEST_ENGINE_HEAD = ''

	$env:AETHELN_TEST_ENGINE_GIT_STATUS = ' M Engine/Source/Runtime/Core/Private/Core.cpp'
	$Failure = $null
	try { & $Script -ProjectPath $ProjectFile -EngineRoot $EngineRoot -LinuxToolchainRoot $ToolchainRoot -ArchiveRoot (Join-Path $FixtureRoot 'PrebuiltDirtyArchive') -LogRoot (Join-Path $FixtureRoot 'PrebuiltDirtyLogs') -SourceRevision $Revision -HostToolsBoundary Prebuilt -EngineRevision $CanonicalEnginePin -HostToolsAttestationPath $AttestationPath } catch { $Failure = $_.Exception.Message }
	Assert-True ($Failure -match 'clean canonical pinned engine checkout') 'A dirty engine checkout must fail the prebuilt boundary closed.'
	$env:AETHELN_TEST_ENGINE_GIT_STATUS = ''

	$AttestedUnrealPakBytes = [System.IO.File]::ReadAllBytes($UnrealPakPath)
	# Same size, different content: the size check must not be what catches it.
	$TamperedUnrealPakBytes = [byte[]] $AttestedUnrealPakBytes.Clone()
	$TamperedUnrealPakBytes[0] = $TamperedUnrealPakBytes[0] -bxor 1
	[System.IO.File]::WriteAllBytes($UnrealPakPath, $TamperedUnrealPakBytes)
	$Failure = $null
	try { & $Script -ProjectPath $ProjectFile -EngineRoot $EngineRoot -LinuxToolchainRoot $ToolchainRoot -ArchiveRoot (Join-Path $FixtureRoot 'PrebuiltTamperArchive') -LogRoot (Join-Path $FixtureRoot 'PrebuiltTamperLogs') -SourceRevision $Revision -HostToolsBoundary Prebuilt -EngineRevision $CanonicalEnginePin -HostToolsAttestationPath $AttestationPath } catch { $Failure = $_.Exception.Message }
	Assert-True ($Failure -match 'does not match its attested SHA-256') 'An arbitrary binary with an intact version JSON must fail the content attestation closed.'
	[System.IO.File]::WriteAllBytes($UnrealPakPath, $AttestedUnrealPakBytes)

	$BadAttestation = Join-Path $AttestationDirectory 'bad-attestation.json'
	$Manipulated = Get-Content -LiteralPath $AttestationPath -Raw | ConvertFrom-Json
	$Manipulated.files[0].path = '..\GitBin\git.bat'
	$Manipulated | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $BadAttestation -Encoding UTF8
	$Failure = $null
	try { & $Script -ProjectPath $ProjectFile -EngineRoot $EngineRoot -LinuxToolchainRoot $ToolchainRoot -ArchiveRoot (Join-Path $FixtureRoot 'PrebuiltEscapeArchive') -LogRoot (Join-Path $FixtureRoot 'PrebuiltEscapeLogs') -SourceRevision $Revision -HostToolsBoundary Prebuilt -EngineRevision $CanonicalEnginePin -HostToolsAttestationPath $BadAttestation } catch { $Failure = $_.Exception.Message }
	Assert-True ($Failure -match 'safe engine-relative path') 'An attestation path escape must fail closed.'
	$Manipulated = Get-Content -LiteralPath $AttestationPath -Raw | ConvertFrom-Json
	$Manipulated.files[1].path = ([string] $Manipulated.files[0].path).ToUpperInvariant()
	$Manipulated | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $BadAttestation -Encoding UTF8
	$Failure = $null
	try { & $Script -ProjectPath $ProjectFile -EngineRoot $EngineRoot -LinuxToolchainRoot $ToolchainRoot -ArchiveRoot (Join-Path $FixtureRoot 'PrebuiltCollideArchive') -LogRoot (Join-Path $FixtureRoot 'PrebuiltCollideLogs') -SourceRevision $Revision -HostToolsBoundary Prebuilt -EngineRevision $CanonicalEnginePin -HostToolsAttestationPath $BadAttestation } catch { $Failure = $_.Exception.Message }
	Assert-True ($Failure -match 'duplicates or case-collides') 'A case-colliding attestation entry must fail closed.'
	$Manipulated = Get-Content -LiteralPath $AttestationPath -Raw | ConvertFrom-Json
	$Manipulated | Add-Member -NotePropertyName note -NotePropertyValue 'injected'
	$Manipulated | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $BadAttestation -Encoding UTF8
	$Failure = $null
	try { & $Script -ProjectPath $ProjectFile -EngineRoot $EngineRoot -LinuxToolchainRoot $ToolchainRoot -ArchiveRoot (Join-Path $FixtureRoot 'PrebuiltExtraPropArchive') -LogRoot (Join-Path $FixtureRoot 'PrebuiltExtraPropLogs') -SourceRevision $Revision -HostToolsBoundary Prebuilt -EngineRevision $CanonicalEnginePin -HostToolsAttestationPath $BadAttestation } catch { $Failure = $_.Exception.Message }
	Assert-True ($Failure -match 'unexpected property') 'An attestation record with extra properties must fail closed.'
	$Manipulated = Get-Content -LiteralPath $AttestationPath -Raw | ConvertFrom-Json
	$Manipulated.files = @($Manipulated.files | Select-Object -Skip 1)
	$Manipulated | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $BadAttestation -Encoding UTF8
	$Failure = $null
	try { & $Script -ProjectPath $ProjectFile -EngineRoot $EngineRoot -LinuxToolchainRoot $ToolchainRoot -ArchiveRoot (Join-Path $FixtureRoot 'PrebuiltMissingEntryArchive') -LogRoot (Join-Path $FixtureRoot 'PrebuiltMissingEntryLogs') -SourceRevision $Revision -HostToolsBoundary Prebuilt -EngineRevision $CanonicalEnginePin -HostToolsAttestationPath $BadAttestation } catch { $Failure = $_.Exception.Message }
	Assert-True ($Failure -match 'receipt-derived host build products; found') 'An attestation record missing a required entry must fail closed.'
	$Oversized = Join-Path $AttestationDirectory 'oversized-attestation.json'
	Set-Content -LiteralPath $Oversized -Value ((Get-Content -LiteralPath $AttestationPath -Raw) + (' ' * 8400000)) -Encoding UTF8
	$Failure = $null
	try { & $Script -ProjectPath $ProjectFile -EngineRoot $EngineRoot -LinuxToolchainRoot $ToolchainRoot -ArchiveRoot (Join-Path $FixtureRoot 'PrebuiltOversizedArchive') -LogRoot (Join-Path $FixtureRoot 'PrebuiltOversizedLogs') -SourceRevision $Revision -HostToolsBoundary Prebuilt -EngineRevision $CanonicalEnginePin -HostToolsAttestationPath $Oversized } catch { $Failure = $_.Exception.Message }
	Assert-True ($Failure -match 'exceeds the 8388608-byte') 'An oversized attestation record must fail closed before parsing.'
	Assert-True (@(Get-Content -LiteralPath $CapturePath).Count -eq $CallsBeforeInvalidBoundary) 'Every invalid boundary or attestation must stop before any UAT invocation.'
	Write-Output 'PASS: tampered tools, noncanonical revisions, dirty checkouts, and manipulated attestation records all fail the boundary closed'

	$CallsBeforeReceiptClosure = @(Get-Content -LiteralPath $CapturePath).Count
	Set-Content -LiteralPath $EditorCoreDllPath -Value 'FIXTURE EDITOR CORE MODULE' -Encoding Ascii
	$Failure = $null
	try { & $Script -ProjectPath $ProjectFile -EngineRoot $EngineRoot -LinuxToolchainRoot $ToolchainRoot -ArchiveRoot (Join-Path $FixtureRoot 'ReceiptRootDllArchive') -LogRoot (Join-Path $FixtureRoot 'ReceiptRootDllLogs') -SourceRevision $Revision -HostToolsBoundary Prebuilt -EngineRevision $CanonicalEnginePin -HostToolsAttestationPath $AttestationPath } catch { $Failure = $_.Exception.Message }
	Assert-True ($Failure -match 'does not match its attested SHA-256') 'A mutated receipt-listed root editor module DLL must fail the boundary closed even when the legacy five files are untouched.'
	Set-Content -LiteralPath $EditorCoreDllPath -Value 'fixture editor core module' -Encoding Ascii
	Set-Content -LiteralPath $PluginDllPath -Value 'FIXTURE PLUGIN MODULE' -Encoding Ascii
	$Failure = $null
	try { & $Script -ProjectPath $ProjectFile -EngineRoot $EngineRoot -LinuxToolchainRoot $ToolchainRoot -ArchiveRoot (Join-Path $FixtureRoot 'ReceiptPluginDllArchive') -LogRoot (Join-Path $FixtureRoot 'ReceiptPluginDllLogs') -SourceRevision $Revision -HostToolsBoundary Prebuilt -EngineRevision $CanonicalEnginePin -HostToolsAttestationPath $AttestationPath } catch { $Failure = $_.Exception.Message }
	Assert-True ($Failure -match 'does not match its attested SHA-256') 'A mutated receipt-listed engine-plugin module DLL must fail the boundary closed.'
	Set-Content -LiteralPath $PluginDllPath -Value 'fixture plugin module' -Encoding Ascii
	Set-Content -LiteralPath $EditorReceiptPath -Value ($EditorReceiptBody.Replace('"Configuration":"Development"', '"Configuration":"Shipping"')) -Encoding UTF8
	$Failure = $null
	try { & $Script -ProjectPath $ProjectFile -EngineRoot $EngineRoot -LinuxToolchainRoot $ToolchainRoot -ArchiveRoot (Join-Path $FixtureRoot 'ReceiptWrongConfigArchive') -LogRoot (Join-Path $FixtureRoot 'ReceiptWrongConfigLogs') -SourceRevision $Revision -HostToolsBoundary Prebuilt -EngineRevision $CanonicalEnginePin -HostToolsAttestationPath $AttestationPath } catch { $Failure = $_.Exception.Message }
	Assert-True ($Failure -match 'exact expected UnrealEditor Win64 Development') 'A receipt with tampered target metadata must fail closed.'
	Set-Content -LiteralPath $EditorReceiptPath -Value ($EditorReceiptBody.Replace('"TargetType":"Editor",', '')) -Encoding UTF8
	$Failure = $null
	try { & $Script -ProjectPath $ProjectFile -EngineRoot $EngineRoot -LinuxToolchainRoot $ToolchainRoot -ArchiveRoot (Join-Path $FixtureRoot 'ReceiptMissingMetaArchive') -LogRoot (Join-Path $FixtureRoot 'ReceiptMissingMetaLogs') -SourceRevision $Revision -HostToolsBoundary Prebuilt -EngineRevision $CanonicalEnginePin -HostToolsAttestationPath $AttestationPath } catch { $Failure = $_.Exception.Message }
	Assert-True ($Failure -match 'missing required metadata') 'A receipt missing required target metadata must fail closed.'
	Set-Content -LiteralPath $EditorReceiptPath -Value ($EditorReceiptBody.Replace('"Path":"$(EngineDir)/Binaries/Win64/UnrealEditor-Core.dll"', '"Path":"$(EngineDir)/../GitBin/git.bat"')) -Encoding UTF8
	$Failure = $null
	try { & $Script -ProjectPath $ProjectFile -EngineRoot $EngineRoot -LinuxToolchainRoot $ToolchainRoot -ArchiveRoot (Join-Path $FixtureRoot 'ReceiptEscapeArchive') -LogRoot (Join-Path $FixtureRoot 'ReceiptEscapeLogs') -SourceRevision $Revision -HostToolsBoundary Prebuilt -EngineRevision $CanonicalEnginePin -HostToolsAttestationPath $AttestationPath } catch { $Failure = $_.Exception.Message }
	Assert-True ($Failure -match 'safe engine-relative path') 'A receipt build product escaping the engine root must fail closed.'
	Set-Content -LiteralPath $EditorReceiptPath -Value ($EditorReceiptBody.Replace('{"Path":"$(EngineDir)/Binaries/Win64/UnrealEditor-Core.dll","Type":"DynamicLibrary"},', '{"Path":"$(EngineDir)/Binaries/Win64/UnrealEditor-Core.dll","Type":"DynamicLibrary"},{"Path":"$(EngineDir)/Binaries/Win64/UNREALEDITOR-CORE.DLL","Type":"DynamicLibrary"},')) -Encoding UTF8
	$Failure = $null
	try { & $Script -ProjectPath $ProjectFile -EngineRoot $EngineRoot -LinuxToolchainRoot $ToolchainRoot -ArchiveRoot (Join-Path $FixtureRoot 'ReceiptDupArchive') -LogRoot (Join-Path $FixtureRoot 'ReceiptDupLogs') -SourceRevision $Revision -HostToolsBoundary Prebuilt -EngineRevision $CanonicalEnginePin -HostToolsAttestationPath $AttestationPath } catch { $Failure = $_.Exception.Message }
	Assert-True ($Failure -match 'duplicates or case-collides') 'Duplicate or case-colliding receipt build products must fail closed.'
	Set-Content -LiteralPath $EditorReceiptPath -Value ($EditorReceiptBody.Replace('{"Path":"$(EngineDir)/Binaries/Win64/UnrealEditor-Core.dll","Type":"DynamicLibrary"},', '{"Path":"$(EngineDir)/Binaries/Win64/UnrealEditor-Core.dll","Type":"DynamicLibrary"},{"Path":"$(EngineDir)/Binaries/Win64/UnrealEditor-Missing.dll","Type":"DynamicLibrary"},')) -Encoding UTF8
	$Failure = $null
	try { & $Script -ProjectPath $ProjectFile -EngineRoot $EngineRoot -LinuxToolchainRoot $ToolchainRoot -ArchiveRoot (Join-Path $FixtureRoot 'ReceiptMissingProductArchive') -LogRoot (Join-Path $FixtureRoot 'ReceiptMissingProductLogs') -SourceRevision $Revision -Stage AttestHostTools -HostToolsAttestationPath (Join-Path $AttestationDirectory 'missing-product-attestation.json') -ProvisioningEvidence 'fixture evidence' } catch { $Failure = $_.Exception.Message }
	Assert-True ($Failure -match 'does not exist under the engine root') 'A missing receipt-listed build product must fail the attestation step closed.'
	Set-Content -LiteralPath $EditorReceiptPath -Value $EditorReceiptBody -Encoding UTF8
	Assert-True (@(Get-Content -LiteralPath $CapturePath).Count -eq $CallsBeforeReceiptClosure) 'Every receipt-closure failure must stop before any UAT invocation.'
	Write-Output 'PASS: the receipt-derived closure covers editor and plugin modules and fails closed on tampered, escaping, colliding, or missing receipt products'

	$Failure = $null
	try { & $Script -ProjectPath $ProjectFile -EngineRoot $EngineRoot -LinuxToolchainRoot $ToolchainRoot -ArchiveRoot (Join-Path $FixtureRoot 'AttestOverwriteArchive') -LogRoot (Join-Path $FixtureRoot 'AttestOverwriteLogs') -SourceRevision $Revision -Stage AttestHostTools -HostToolsAttestationPath $AttestationPath -ProvisioningEvidence 'fixture evidence' } catch { $Failure = $_.Exception.Message }
	Assert-True ($Failure -match 'already exists') 'The attestation step must never overwrite an existing record.'
	$AttestationRaw = Get-Content -LiteralPath $AttestationPath -Raw
	foreach ($StrictCase in @(
		@{ Label = 'duplicate top-level property'; Content = ($AttestationRaw -replace '"schemaVersion":\s*1', '"schemaVersion": 1, "schemaVersion": 1'); Expect = 'duplicate or case-colliding JSON property' },
		@{ Label = 'duplicate nested entry property'; Content = ($AttestationRaw -replace '"sha256":', '"path": "dup", "sha256":'); Expect = 'duplicate or case-colliding JSON property' },
		@{ Label = 'case-colliding property'; Content = ($AttestationRaw -replace '"createdUtc":', '"CREATEDUTC": "x", "createdUtc":'); Expect = 'duplicate or case-colliding JSON property' },
		@{ Label = 'unicode-escaped duplicate property'; Content = ($AttestationRaw -replace '"createdUtc":\s*"[^"]*"', '"createdUtc": "2026-09-04T12:00:00Z", "cr\u0065atedUtc": "2026-09-04T12:00:00Z"'); Expect = 'duplicate or case-colliding JSON property' },
		@{ Label = 'string schema version'; Content = ($AttestationRaw -replace '"schemaVersion":\s*1', '"schemaVersion": "1"'); Expect = 'JSON integer 1' },
		@{ Label = 'null provisioning evidence'; Content = ($AttestationRaw -replace '"provisioningEvidence":\s*"[^"]*"', '"provisioningEvidence": null'); Expect = 'nonempty bounded string' },
		@{ Label = 'empty provisioning evidence'; Content = ($AttestationRaw -replace '"provisioningEvidence":\s*"[^"]*"', '"provisioningEvidence": ""'); Expect = 'nonempty bounded string' },
		@{ Label = 'invalid timestamp'; Content = ($AttestationRaw -replace '"createdUtc":\s*"[^"]*"', '"createdUtc": "not-a-timestamp"'); Expect = 'round-trip UTC timestamp' },
		@{ Label = 'unspecified timestamp'; Content = ($AttestationRaw -replace '"createdUtc":\s*"[^"]*"', '"createdUtc": "2026-09-04T12:00:00"'); Expect = 'round-trip UTC timestamp' },
		@{ Label = 'offset timestamp'; Content = ($AttestationRaw -replace '"createdUtc":\s*"[^"]*"', '"createdUtc": "2026-09-04T12:00:00+02:00"'); Expect = 'round-trip UTC timestamp' }
	)) {
		Set-Content -LiteralPath $BadAttestation -Value ([string] $StrictCase.Content) -Encoding UTF8
		$Failure = $null
		try { & $Script -ProjectPath $ProjectFile -EngineRoot $EngineRoot -LinuxToolchainRoot $ToolchainRoot -ArchiveRoot (Join-Path $FixtureRoot ("StrictArchive-{0}" -f ($StrictCase.Label -replace '[^a-z]', ''))) -LogRoot (Join-Path $FixtureRoot ("StrictLogs-{0}" -f ($StrictCase.Label -replace '[^a-z]', ''))) -SourceRevision $Revision -HostToolsBoundary Prebuilt -EngineRevision $CanonicalEnginePin -HostToolsAttestationPath $BadAttestation } catch { $Failure = $_.Exception.Message }
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
		try { & $Script -ProjectPath $ProjectFile -EngineRoot $EngineRoot -LinuxToolchainRoot $ToolchainRoot -ArchiveRoot (Join-Path $FixtureRoot ("SizeArchive-{0}" -f $SizeCase.Label)) -LogRoot (Join-Path $FixtureRoot ("SizeLogs-{0}" -f $SizeCase.Label)) -SourceRevision $Revision -HostToolsBoundary Prebuilt -EngineRevision $CanonicalEnginePin -HostToolsAttestationPath $BadAttestation } catch { $Failure = $_.Exception.Message }
		Assert-True ($null -ne $Failure -and $Failure -match [string] $SizeCase.Expect) "An attestation with $($SizeCase.Label) must fail closed."
	}
	Assert-True (@(Get-Content -LiteralPath $CapturePath).Count -eq $CallsBeforeReceiptClosure) 'Every strict-contract rejection must stop before any UAT invocation.'
	Write-Output 'PASS: the attestation JSON contract rejects duplicate/case-colliding properties, non-integer schema versions, invalid evidence and timestamps, malformed files arrays, and out-of-bound sizes'

	$IdentityDdc = Join-Path $FixtureRoot 'IdentityDdc'
	$env:AETHELN_TEST_ARCHIVE_ROOT = Join-Path $FixtureRoot 'IdentityArchive1'
	& $Script -ProjectPath $ProjectFile -EngineRoot $EngineRoot -LinuxToolchainRoot $ToolchainRoot -ArchiveRoot (Join-Path $FixtureRoot 'IdentityArchive1') -LogRoot (Join-Path $FixtureRoot 'IdentityLogs1') -SourceRevision $Revision -HostToolsBoundary Rebuild -DerivedDataCachePath $IdentityDdc
	$IdentityPath2 = Join-Path $IdentityDdc 'cache-identity.json'
	$CallsBeforeIdentityRegressions = @(Get-Content -LiteralPath $CapturePath).Count
	$IdentityObject = Get-Content -LiteralPath $IdentityPath2 -Raw | ConvertFrom-Json
	$IdentityObject.engineGitRevision = ('3' * 40)
	$IdentityObject | ConvertTo-Json | Set-Content -LiteralPath $IdentityPath2 -Encoding UTF8
	$Failure = $null
	try { & $Script -ProjectPath $ProjectFile -EngineRoot $EngineRoot -LinuxToolchainRoot $ToolchainRoot -ArchiveRoot (Join-Path $FixtureRoot 'IdentityArchive2') -LogRoot (Join-Path $FixtureRoot 'IdentityLogs2') -SourceRevision $Revision -HostToolsBoundary Rebuild -DerivedDataCachePath $IdentityDdc } catch { $Failure = $_.Exception.Message }
	Assert-True ($Failure -match 'failed identity validation') 'A cache bound to a different engine Git revision must fail closed.'
	$IdentityObject.engineGitRevision = $RealRevision
	$IdentityObject.projectRepository = ('4' * 40)
	$IdentityObject | ConvertTo-Json | Set-Content -LiteralPath $IdentityPath2 -Encoding UTF8
	$Failure = $null
	try { & $Script -ProjectPath $ProjectFile -EngineRoot $EngineRoot -LinuxToolchainRoot $ToolchainRoot -ArchiveRoot (Join-Path $FixtureRoot 'IdentityArchive3') -LogRoot (Join-Path $FixtureRoot 'IdentityLogs3') -SourceRevision $Revision -HostToolsBoundary Rebuild -DerivedDataCachePath $IdentityDdc } catch { $Failure = $_.Exception.Message }
	Assert-True ($Failure -match 'failed identity validation') 'A colliding project name from a different repository identity must fail closed.'
	$IdentityObject.projectRepository = $RealRevision
	$IdentityObject.schemaVersion = 1
	$IdentityObject | ConvertTo-Json | Set-Content -LiteralPath $IdentityPath2 -Encoding UTF8
	$env:AETHELN_TEST_ARCHIVE_ROOT = Join-Path $FixtureRoot 'IdentityArchive4'
	& $Script -ProjectPath $ProjectFile -EngineRoot $EngineRoot -LinuxToolchainRoot $ToolchainRoot -ArchiveRoot (Join-Path $FixtureRoot 'IdentityArchive4') -LogRoot (Join-Path $FixtureRoot 'IdentityLogs4') -SourceRevision $Revision -HostToolsBoundary Rebuild -DerivedDataCachePath $IdentityDdc -CacheFallback CleanIsolated
	$OldSchemaTiming = Get-Content -LiteralPath (Join-Path $FixtureRoot 'IdentityLogs4/build-timing.json') -Raw | ConvertFrom-Json
	Assert-True ($OldSchemaTiming.derivedDataCache.status -eq 'fallback_corrupt') 'An older identity schema must never be reused; it takes the recorded clean fallback or fails closed.'
	Assert-True (@(Get-Content -LiteralPath $CapturePath).Count -eq $CallsBeforeIdentityRegressions + 2) 'Fail-closed identity regressions must stop before UAT; only the clean fallback run may invoke UAT.'
	$env:AETHELN_TEST_ENGINE_GIT_STATUS = ' M Engine/Source/Runtime/Core/Private/Core.cpp'
	$env:AETHELN_TEST_ARCHIVE_ROOT = Join-Path $FixtureRoot 'IdentityArchive5'
	& $Script -ProjectPath $ProjectFile -EngineRoot $EngineRoot -LinuxToolchainRoot $ToolchainRoot -ArchiveRoot (Join-Path $FixtureRoot 'IdentityArchive5') -LogRoot (Join-Path $FixtureRoot 'IdentityLogs5') -SourceRevision $Revision -HostToolsBoundary Rebuild -DerivedDataCachePath (Join-Path $FixtureRoot 'IdentityDdcDirtyEngine') -CacheFallback CleanIsolated
	$DirtyEngineTiming = Get-Content -LiteralPath (Join-Path $FixtureRoot 'IdentityLogs5/build-timing.json') -Raw | ConvertFrom-Json
	Assert-True ($DirtyEngineTiming.derivedDataCache.status -eq 'fallback_engine_identity_unverifiable') 'A dirty engine checkout must make the cache identity unverifiable.'
	$env:AETHELN_TEST_ENGINE_GIT_STATUS = ''
	Write-Output 'PASS: engine-revision, repository-collision, older-schema, and dirty-engine identity states never reuse the cache'

	$CallsBeforePathContract = @(Get-Content -LiteralPath $CapturePath).Count
	$Failure = $null
	try { & $Script -ProjectPath $ProjectFile -EngineRoot $EngineRoot -LinuxToolchainRoot $ToolchainRoot -ArchiveRoot (Join-Path $FixtureRoot 'PathRelArchive') -LogRoot (Join-Path $FixtureRoot 'PathRelLogs') -SourceRevision $Revision -HostToolsBoundary Rebuild -DerivedDataCachePath 'relative\ddc' } catch { $Failure = $_.Exception.Message }
	Assert-True ($Failure -match 'absolute local path') 'A relative DDC path must be rejected by the build entry point.'
	$PathTiming = Get-Content -LiteralPath (Join-Path $FixtureRoot 'PathRelLogs/build-timing.json') -Raw | ConvertFrom-Json
	Assert-True ($PathTiming.derivedDataCache.status -eq 'failed_path_invalid') 'A rejected DDC path must be recorded as failed_path_invalid in the timing record.'
	$Failure = $null
	try { & $Script -ProjectPath $ProjectFile -EngineRoot $EngineRoot -LinuxToolchainRoot $ToolchainRoot -ArchiveRoot (Join-Path $FixtureRoot 'PathUncArchive') -LogRoot (Join-Path $FixtureRoot 'PathUncLogs') -SourceRevision $Revision -HostToolsBoundary Rebuild -DerivedDataCachePath '\\server\share\ddc' } catch { $Failure = $_.Exception.Message }
	Assert-True ($Failure -match 'must not be a UNC path') 'A UNC DDC path must be rejected by the build entry point.'
	$Failure = $null
	try { & $Script -ProjectPath $ProjectFile -EngineRoot $EngineRoot -LinuxToolchainRoot $ToolchainRoot -ArchiveRoot (Join-Path $FixtureRoot 'PathOverlapArchive') -LogRoot (Join-Path $FixtureRoot 'PathOverlapLogs') -SourceRevision $Revision -HostToolsBoundary Rebuild -DerivedDataCachePath (Join-Path $FixtureRoot 'PathOverlapLogs/ddc') } catch { $Failure = $_.Exception.Message }
	Assert-True ($Failure -match 'must be disjoint') 'A DDC path inside the log root must be rejected by the build entry point.'
	$Failure = $null
	try { & $Script -ProjectPath $ProjectFile -EngineRoot $EngineRoot -LinuxToolchainRoot $ToolchainRoot -ArchiveRoot (Join-Path $FixtureRoot 'PathRepoArchive') -LogRoot (Join-Path $FixtureRoot 'PathRepoLogs') -SourceRevision $Revision -HostToolsBoundary Rebuild -DerivedDataCachePath (Join-Path $ProjectRoot 'ddc-under-repo') } catch { $Failure = $_.Exception.Message }
	Assert-True ($Failure -match 'must be disjoint') 'A DDC path inside the repository must be rejected on a direct call, matching the CI gate contract.'
	$JunctionTarget = Join-Path $FixtureRoot 'DdcJunctionTarget'
	New-Item -ItemType Directory -Path $JunctionTarget | Out-Null
	$Junction = Join-Path $FixtureRoot 'DdcJunction'
	New-Item -ItemType Junction -Path $Junction -Value $JunctionTarget | Out-Null
	$Failure = $null
	try { & $Script -ProjectPath $ProjectFile -EngineRoot $EngineRoot -LinuxToolchainRoot $ToolchainRoot -ArchiveRoot (Join-Path $FixtureRoot 'PathReparseArchive') -LogRoot (Join-Path $FixtureRoot 'PathReparseLogs') -SourceRevision $Revision -HostToolsBoundary Rebuild -DerivedDataCachePath (Join-Path $Junction 'ddc') } catch { $Failure = $_.Exception.Message }
	Assert-True ($Failure -match 'reparse point') 'A reparse-mediated DDC path must be rejected by the build entry point.'
	[IO.Directory]::Delete($Junction)
	Assert-True (@(Get-Content -LiteralPath $CapturePath).Count -eq $CallsBeforePathContract) 'Every rejected DDC path must stop before any UAT invocation.'
	Write-Output 'PASS: the build entry point enforces the full DDC path contract on direct calls'
	Assert-True (@(Get-Content -LiteralPath $UbtCapturePath).Count -eq $UbtCallsAfterPrebuiltCoverage) 'Boundary rejections and Rebuild runs must never start a controller-owned UnrealBuildTool build.'
	Write-Output 'PASS: only verified prebuilt runs start controller-owned UnrealBuildTool builds'
}
finally {
	if ($null -ne $OriginalPath) { $env:PATH = $OriginalPath }
	Remove-Item Env:AETHELN_TEST_GIT_STATUS -ErrorAction SilentlyContinue
	Remove-Item Env:AETHELN_TEST_ENGINE_GIT_STATUS -ErrorAction SilentlyContinue
	Remove-Item Env:AETHELN_TEST_ENGINE_HEAD -ErrorAction SilentlyContinue
	Remove-Item Env:AETHELN_TEST_CONFLICTING_COMPILER -ErrorAction SilentlyContinue
	Remove-Item Env:AETHELN_TEST_ARCHIVE_ROOT -ErrorAction SilentlyContinue
	Remove-Item Env:AETHELN_TEST_DDC_CAPTURE -ErrorAction SilentlyContinue
	foreach ($FixtureVariable in @('AETHELN_TEST_PROJECT_ROOT', 'AETHELN_TEST_UBT_FAIL', 'AETHELN_TEST_PROJECT_BUILDID', 'AETHELN_TEST_UBT_EMPTY_MANIFEST', 'AETHELN_TEST_UBT_OMIT_MODULE', 'AETHELN_TEST_UBT_OMIT_DLL', 'AETHELN_TEST_UBT_TAMPER_ENGINE', 'AETHELN_TEST_UBT_NO_PRODUCTS', 'AETHELN_TEST_UAT_TAMPER')) {
		Remove-Item -Path "Env:$FixtureVariable" -ErrorAction SilentlyContinue
	}
	[Environment]::SetEnvironmentVariable('uebp_LogFolder', $OriginalUebpLogFolder, 'Process')
	[Environment]::SetEnvironmentVariable('uebp_FinalLogFolder', $OriginalUebpFinalLogFolder, 'Process')
	if (Test-Path -LiteralPath $FixtureRoot) { Remove-Item -LiteralPath $FixtureRoot -Recurse -Force }
}
