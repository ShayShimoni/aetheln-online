[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$SourceRunner = Join-Path $RepositoryRoot 'scripts\content\Invoke-ContentValidation.ps1'
$BuildRules = Join-Path $RepositoryRoot 'Source\GameTests\GameTests.Build.cs'
$ScannerHeader = Join-Path $RepositoryRoot 'Source\GameTests\Private\AethelnContentValidationScanner.h'
$ScannerSource = Join-Path $RepositoryRoot 'Source\GameTests\Private\AethelnContentValidationScanner.cpp'
$CommandletHeader = Join-Path $RepositoryRoot 'Source\GameTests\Private\AethelnContentValidationCommandlet.h'
$CommandletSource = Join-Path $RepositoryRoot 'Source\GameTests\Private\AethelnContentValidationCommandlet.cpp'
$FixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ("AethelnContentCommandTests-{0}" -f [guid]::NewGuid().ToString('N'))
$PowerShell = (Get-Command powershell.exe -ErrorAction Stop).Source
$PinnedEngineTag = '5.8.1-release'
$PinnedEngineRevision = '71fe36aac5a8df5ccd66c763ffc902b29b6a9c43'
$SourceRevision = '1111111111111111111111111111111111111111'

function Assert-True([bool] $Condition, [string] $Message) {
	if (-not $Condition) { throw "Assertion failed: $Message" }
}

function Write-Utf8([string] $Path, [string] $Content) {
	$Parent = Split-Path -Parent $Path
	if ($Parent -and -not (Test-Path -LiteralPath $Parent)) {
		New-Item -ItemType Directory -Path $Parent -Force | Out-Null
	}
	[IO.File]::WriteAllText($Path, $Content, (New-Object Text.UTF8Encoding($false)))
}

function Get-Sha256([string] $Path) {
	return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-TextSha256([string] $Value) {
	$Bytes = [Text.Encoding]::UTF8.GetBytes($Value)
	$Hasher = [Security.Cryptography.SHA256]::Create()
	try {
		return ([BitConverter]::ToString($Hasher.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant()
	}
	finally {
		$Hasher.Dispose()
	}
}

function Build-Fakes {
	param([string] $FakeBin)

	New-Item -ItemType Directory -Path $FakeBin -Force | Out-Null
	$GitSource = @"
using System;
using System.IO;
public static class FakeGitForContentValidation {
 public static int Main(string[] args) {
  string joined=string.Join(" ",args), root=args.Length>1&&args[0]=="-C"?args[1]:"";
  bool engine=string.Equals(Path.GetFileName(root.TrimEnd(Path.DirectorySeparatorChar,Path.AltDirectorySeparatorChar)),"engine",StringComparison.OrdinalIgnoreCase);
  string scenario=Environment.GetEnvironmentVariable("AETHELN_CONTENT_FAKE_GIT_CASE")??"clean";
  string pinned="$PinnedEngineRevision", source="$SourceRevision", alternate="2222222222222222222222222222222222222222";
  if(joined.IndexOf("status --porcelain",StringComparison.Ordinal)>=0) {
   if(!engine&&scenario=="dirty") Console.WriteLine(" M tracked.txt");
   return 0;
  }
  if(joined.IndexOf("rev-parse",StringComparison.Ordinal)>=0) {
   if(engine) {
    if(joined.IndexOf("refs/tags/$PinnedEngineTag",StringComparison.Ordinal)>=0&&scenario=="tag-mismatch") Console.WriteLine(alternate);
    else if(joined.IndexOf("refs/tags/$PinnedEngineTag",StringComparison.Ordinal)<0&&scenario=="engine-head-mismatch") Console.WriteLine(alternate);
    else Console.WriteLine(pinned);
   } else {
    string drift=Environment.GetEnvironmentVariable("AETHELN_CONTENT_FAKE_DRIFT")??"";
    Console.WriteLine(drift.Length>0&&File.Exists(drift)?alternate:source);
   }
   return 0;
  }
  Console.Error.WriteLine("unsupported fake git invocation: "+joined);
  return 17;
 }
}
"@
	Add-Type -TypeDefinition $GitSource -OutputAssembly (Join-Path $FakeBin 'git.exe') -OutputType ConsoleApplication

	$BuildSource = @'
using System;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Threading;
public static class FakeEditorBuildForContentValidation {
 static string Escape(string value) { return value.Replace("\\","\\\\").Replace("\"","\\\""); }
 static string Q(string value) { return "\""+Escape(value)+"\""; }
 static void Write(string path,string content) {
  Directory.CreateDirectory(Path.GetDirectoryName(path));
  File.WriteAllText(path,content,new UTF8Encoding(false));
 }
 public static int Main(string[] args) {
  if(args.Length==1&&args[0].StartsWith("--child-",StringComparison.Ordinal)) {
   string pidPath=Environment.GetEnvironmentVariable("AETHELN_CONTENT_FAKE_BUILD_CHILD_PID")??"";
   string latePath=Environment.GetEnvironmentVariable("AETHELN_CONTENT_FAKE_BUILD_LATE_MARKER")??"";
   if(pidPath.Length>0) File.WriteAllText(pidPath,Process.GetCurrentProcess().Id.ToString());
   if(args[0]=="--child-flood") {
    byte[] chunk=new byte[8192];
    for(int i=0;i<chunk.Length;i++) chunk[i]=(byte)'Z';
    using(Stream output=Console.OpenStandardOutput()) for(int i=0;i<2176;i++) output.Write(chunk,0,chunk.Length);
   }
   Thread.Sleep(30000);
   if(latePath.Length>0) File.WriteAllText(latePath,"late child write");
   return 0;
  }
  string capture=Environment.GetEnvironmentVariable("AETHELN_CONTENT_FAKE_BUILD_CAPTURE")??"";
  if(capture.Length>0) File.WriteAllLines(capture,args);
  string scenario=Environment.GetEnvironmentVariable("AETHELN_CONTENT_FAKE_BUILD_CASE")??"success";
  string compilerRoot=Environment.GetEnvironmentVariable("AETHELN_CONTENT_FAKE_COMPILER_ROOT")??"";
  string sdkRoot=Environment.GetEnvironmentVariable("AETHELN_CONTENT_FAKE_SDK_ROOT")??"";
  if(scenario=="missing-compiler") compilerRoot=Path.Combine(compilerRoot,"missing");
  if(scenario=="missing-resource-compiler") sdkRoot=Path.Combine(sdkRoot,"missing");
  string compilerVersion="14.44.35228", sdkVersion="10.0.26100.0";
  if(scenario=="silent-success") { }
  else if(scenario=="missing-toolchain") Console.WriteLine("No toolchain identity was emitted.");
  else {
   Console.WriteLine("Using Visual Studio "+compilerVersion+" toolchain ("+compilerRoot+") and Windows "+sdkVersion+" SDK ("+sdkRoot+").");
   if(scenario=="duplicate-toolchain") Console.WriteLine("Using Visual Studio 14.50.99999 toolchain ("+compilerRoot+") and Windows 10.0.30000.0 SDK ("+sdkRoot+").");
  }
  if(scenario=="nonzero") return 41;
  if(scenario=="child-flood"||scenario=="child-timeout"||scenario=="child-pump-fault") {
   string parentPidPath=Environment.GetEnvironmentVariable("AETHELN_CONTENT_FAKE_BUILD_PARENT_PID")??"";
   if(parentPidPath.Length>0) File.WriteAllText(parentPidPath,Process.GetCurrentProcess().Id.ToString());
   ProcessStartInfo childInfo=new ProcessStartInfo(Process.GetCurrentProcess().MainModule.FileName,scenario=="child-timeout"?"--child-timeout":"--child-flood");
   childInfo.UseShellExecute=false; childInfo.CreateNoWindow=true; childInfo.RedirectStandardOutput=true;
   using(Process child=Process.Start(childInfo))
   using(Stream output=Console.OpenStandardOutput()) child.StandardOutput.BaseStream.CopyTo(output);
   return 0;
  }
  if(scenario=="output-flood") {
   byte[] chunk=new byte[8192];
   for(int i=0;i<chunk.Length;i++) chunk[i]=(byte)'X';
   using(Stream output=Console.OpenStandardOutput()) {
    for(int i=0;i<2176;i++) output.Write(chunk,0,chunk.Length); // 17 MiB: must exceed the bounded capture limit.
   }
   return 41;
  }
  if(args.Length<4) { Console.Error.WriteLine("missing fixed build arguments"); return 42; }
  string repository=Path.GetDirectoryName(Path.GetFullPath(args[3]));
  string binaries=Path.Combine(repository,"Binaries","Win64");
  Directory.CreateDirectory(binaries);
  string buildId="fixture-build-id";
  string receiptBuildId=scenario=="receipt-build-id-mismatch"?"other-receipt-id":buildId;
  string manifestBuildId=scenario=="manifest-build-id-mismatch"?"other-manifest-id":buildId;
  string receipt=Path.Combine(binaries,"AethelnOnlineEditor.target");
  string manifest=Path.Combine(binaries,"UnrealEditor.modules");
  string gameCore=Path.Combine(binaries,"UnrealEditor-GameCore.dll");
  string gameTests=Path.Combine(binaries,"UnrealEditor-GameTests.dll");
  if(scenario!="missing-receipt") {
   if(scenario=="corrupt-receipt") Write(receipt,"{broken");
   else {
    string target=scenario=="wrong-receipt-target"?"OtherEditor":"AethelnOnlineEditor";
    Write(receipt,"{\"TargetName\":"+Q(target)+",\"Platform\":\"Win64\",\"Configuration\":\"Development\",\"TargetType\":\"Editor\",\"Project\":\"../../AethelnOnline.uproject\",\"LaunchCmd\":\"$(EngineDir)/Binaries/Win64/UnrealEditor-Cmd.exe\",\"Version\":{\"BuildId\":"+Q(receiptBuildId)+"}}");
   }
  }
  if(scenario!="missing-manifest") {
   if(scenario=="corrupt-manifest") Write(manifest,"{broken");
   else {
    string gameTestsEntry=scenario=="missing-game-tests-entry"?"":",\"GameTests\":\"UnrealEditor-GameTests.dll\"";
    string gameCoreEntry=scenario=="escaping-module-path"?"../outside.dll":"UnrealEditor-GameCore.dll";
    Write(manifest,"{\"BuildId\":"+Q(manifestBuildId)+",\"Modules\":{\"GameCore\":"+Q(gameCoreEntry)+gameTestsEntry+"}}");
   }
  }
  if(scenario!="missing-game-core") Write(gameCore,scenario=="zero-game-core"?"":"fixture GameCore module");
  Write(gameTests,"fixture GameTests module");
  if(scenario=="build-project-drift") File.AppendAllText(Path.Combine(repository,"AethelnOnline.uproject")," ");
  return 0;
 }
}
'@
	Add-Type -TypeDefinition $BuildSource -OutputAssembly (Join-Path $FakeBin 'FakeEditorBuild.exe') -OutputType ConsoleApplication

	$EditorSource = @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using Microsoft.Win32.SafeHandles;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
public static class FakeUnrealEditorForContentValidation {
 static string Escape(string value) { return value.Replace("\\","\\\\").Replace("\"","\\\""); }
 static string Get(Dictionary<string,string> values,string name) { return values.ContainsKey(name)?values[name]:""; }
 static string Q(string value) { return "\""+Escape(value)+"\""; }
 static void WriteReport(Dictionary<string,string> values,string content) {
  long raw=long.Parse(Get(values,"ReportHandle"));
  using(SafeFileHandle handle=new SafeFileHandle(new IntPtr(raw),false))
  using(FileStream stream=new FileStream(handle,FileAccess.Write)) {
   byte[] bytes=new UTF8Encoding(false).GetBytes(content); stream.Position=0; stream.SetLength(0); stream.Write(bytes,0,bytes.Length); stream.Flush();
  }
 }
 static string Hash(string path) {
  using(SHA256 sha=SHA256.Create()) using(FileStream stream=File.OpenRead(path))
   return BitConverter.ToString(sha.ComputeHash(stream)).Replace("-","").ToLowerInvariant();
 }
 static string Module(string name,string relativePath,string absolutePath,string buildId) {
  FileInfo file=new FileInfo(absolutePath);
  return "{\"name\":"+Q(name)+",\"path\":"+Q(relativePath)+",\"size_bytes\":"+file.Length+",\"sha256\":"+Q(Hash(absolutePath))+",\"build_id\":"+Q(buildId)+"}";
 }
 public static int Main(string[] args) {
  string capture=Environment.GetEnvironmentVariable("AETHELN_CONTENT_FAKE_CAPTURE")??"";
  if(capture.Length>0) File.WriteAllLines(capture,args);
  string scenario=Environment.GetEnvironmentVariable("AETHELN_CONTENT_FAKE_EDITOR_CASE")??"success";
  Dictionary<string,string> values=new Dictionary<string,string>(StringComparer.Ordinal);
  foreach(string arg in args) {
   if(!arg.StartsWith("-",StringComparison.Ordinal)) continue;
   int split=arg.IndexOf('=');
   if(split>1) values[arg.Substring(1,split-1)]=arg.Substring(split+1);
   else values[arg.Substring(1)]="true";
  }
  if(scenario=="snapshot-swap-restore") {
   string snapshot=Get(values,"RegistrySnapshot"), expected=Get(values,"RegistrySnapshotSha256");
   byte[] original=File.ReadAllBytes(snapshot);
   try {
    File.WriteAllText(snapshot,"{\"schema_id\":\"aetheln.asset-registry-snapshot\",\"schema_version\":1,\"packages\":[{\"swapped\":true}]}",new UTF8Encoding(false));
    if(expected.Length==64&&!string.Equals(Hash(snapshot),expected,StringComparison.Ordinal)) {
     Console.Error.WriteLine("Registry snapshot bytes do not match their supplied SHA-256 provenance.");
     return 33;
    }
   } finally { File.WriteAllBytes(snapshot,original); }
  }
  string output=Get(values,"Report");
  Console.WriteLine("fixture commandlet log");
  if(scenario=="commandlet-log-flood") {
   byte[] chunk=new byte[8192];
   for(int i=0;i<chunk.Length;i++) chunk[i]=(byte)'Y';
   using(Stream standard=Console.OpenStandardOutput()) {
    for(int i=0;i<2176;i++) standard.Write(chunk,0,chunk.Length);
   }
   return 9;
  }
  if(scenario=="timeout") {
   ProcessStartInfo childInfo=new ProcessStartInfo("powershell.exe","-NoProfile -Command \"Start-Sleep -Seconds 30\"");
   childInfo.UseShellExecute=false; childInfo.CreateNoWindow=true;
   Process child=Process.Start(childInfo);
   string childPid=Environment.GetEnvironmentVariable("AETHELN_CONTENT_FAKE_CHILD_PID")??"";
   if(childPid.Length>0) File.WriteAllText(childPid,child.Id.ToString());
   Thread.Sleep(30000);
   return 8;
  }
  if(scenario=="nonzero-no-report") return 9;
  if(scenario=="missing-report") return 0;
  if(scenario=="report-flood") { WriteReport(values,new string('X',17*1024*1024)); return 0; }
  Directory.CreateDirectory(Path.GetDirectoryName(output));
  if(scenario=="corrupt") { WriteReport(values,"{broken"); return 0; }
   string policy=Get(values,"PolicySha256"), intake=Get(values,"IntakeSha256"), revision=Get(values,"Revision");
   if(scenario=="policy-mismatch") policy=new string('f',64);
   if(scenario=="intake-mismatch") intake=new string('e',64);
   string registrySource=Get(values,"RegistrySource");
   string repository=Path.GetDirectoryName(Path.GetFullPath(args[0]));
   string binaries=Path.Combine(repository,"Binaries","Win64");
   string buildId=Get(values,"TargetReceiptBuildId");
   string receipt="{\"path\":"+Q(Get(values,"TargetReceiptPath"))+",\"size_bytes\":"+Get(values,"TargetReceiptSizeBytes")+",\"sha256\":"+Q(Get(values,"TargetReceiptSha256"))+",\"build_id\":"+Q(buildId)+"}";
   string manifest="{\"path\":"+Q(Get(values,"ModuleManifestPath"))+",\"size_bytes\":"+Get(values,"ModuleManifestSizeBytes")+",\"sha256\":"+Q(Get(values,"ModuleManifestSha256"))+",\"build_id\":"+Q(Get(values,"ModuleManifestBuildId"))+"}";
   string core=Module("GameCore","Binaries/Win64/UnrealEditor-GameCore.dll",Path.Combine(binaries,"UnrealEditor-GameCore.dll"),buildId);
   string tests=Module("GameTests","Binaries/Win64/UnrealEditor-GameTests.dll",Path.Combine(binaries,"UnrealEditor-GameTests.dll"),buildId);
   if(scenario=="module-report-hash-mismatch") core=core.Replace(Hash(Path.Combine(binaries,"UnrealEditor-GameCore.dll")),new string('d',64));
   if(scenario=="module-report-build-id-mismatch") tests=tests.Replace(Q(buildId),Q("other-module-id"));
   string loaded=scenario=="module-report-order-mismatch"?"["+tests+","+core+"]":"["+core+","+tests+"]";
   if(scenario=="receipt-report-extra-field") receipt=receipt.Insert(receipt.Length-1,",\"extra\":true");
   string execution="{\"repository_clean\":true,\"engine_revision\":"+Q(Get(values,"EngineRevision"))+",\"engine_tag\":"+Q(Get(values,"EngineTag"))+",\"engine_binary_sha256\":"+Q(Get(values,"EngineBinarySha256"))+",\"build_version_sha256\":"+Q(Get(values,"BuildVersionSha256"))+",\"target\":\"AethelnOnlineEditor\",\"platform\":\"Win64\",\"configuration\":\"Development\",\"editor_build_command_sha256\":"+Q(Get(values,"EditorBuildCommandSha256"))+",\"editor_build_log_sha256\":"+Q(Get(values,"EditorBuildLogSha256"))+",\"compiler_version\":"+Q(Get(values,"CompilerVersion"))+",\"compiler_sha256\":"+Q(Get(values,"CompilerSha256"))+",\"resource_compiler_version\":"+Q(Get(values,"ResourceCompilerVersion"))+",\"resource_compiler_sha256\":"+Q(Get(values,"ResourceCompilerSha256"))+",\"target_receipt\":"+receipt+",\"module_manifest\":"+manifest+",\"loaded_project_modules\":"+loaded+",\"project_sha256\":"+Q(Get(values,"ProjectSha256"))+",\"policy_sha256\":"+Q(policy)+",\"intake_sha256\":"+Q(intake)+",\"invocation_sha256\":"+Q(Get(values,"InvocationSha256"))+",\"registry_source\":"+Q(registrySource)+"}";
   string provenance="{\"author_or_provider\":\"fixture provider\",\"source_record\":\"fixture record\",\"source_version\":\"fixture version\",\"license_or_permission_evidence\":\"fixture permission\",\"modifications\":\"none\",\"generation_metadata_when_applicable\":\"not_applicable\",\"content_sha256\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"reviewer\":\"fixture reviewer\",\"approval_state\":\"temporary_prototype_only\"}";
   string lifecycle="{\"content_identity\":{\"stable_id\":\"content.fixtures.governed_fixture\",\"content_version\":1,\"content_sha256\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"},\"temporary_prototype\":[{\"owner\":\"Issue #100\",\"approval_record\":\"Issue #100\",\"recovery_trigger\":\"replace fixture\",\"may_be_runtime_candidate\":false}],\"runtime_candidate\":[],\"production_approval\":[]}";
  if(scenario=="provenance-mismatch") provenance=provenance.Replace("fixture record","different record");
  if(scenario=="lifecycle-mismatch") lifecycle=lifecycle.Replace("replace fixture","different trigger");
  if(scenario=="failed-eligible") {
   provenance=provenance.Replace("temporary_prototype_only","runtime_candidate_approved");
   lifecycle="{\"content_identity\":{\"stable_id\":\"content.fixtures.governed_fixture\",\"content_version\":1,\"content_sha256\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"},\"temporary_prototype\":[],\"runtime_candidate\":[{\"review_revision\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"reviewer\":\"fixture reviewer\",\"approval_record\":\"fixture approval\",\"stable_id\":\"content.fixtures.governed_fixture\",\"content_version\":1,\"content_sha256\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"}],\"production_approval\":[]}";
  }
   string[] families={"collision","rendering_suitability","texture","material","skeletal_animation","map_world","navigation","reference_boundary"};
   string[][] checks={
    new[]{"profile","simple_complex_policy","presentation_equivalence"},
    new[]{"lod","hlod","nanite_suitability","streaming"},
    new[]{"pbr_channels","tiling","compression","mips","streaming"},
    new[]{"material_instance_policy","shader_complexity_evidence"},
    new[]{"rig_compatibility","morph_policy","influences","socket_ownership","animation_complexity"},
    new[]{"map_identity","data_layers","pcg_authority","runtime_editor_boundary"},
    new[]{"navigation_data_audience","streaming_boundaries","runtime_rebuild_policy"},
    new[]{"stable_id_unique","redirectors","broken_references","compatible_content_version","audience_reachability","hard_reference_exceptions"}
   };
   StringBuilder familyJson=new StringBuilder("[");
   for(int i=0;i<families.Length;i++) {
    if(i>0) familyJson.Append(',');
   bool applicable=families[i]=="reference_boundary";
   string deterministic=applicable?"passed":"not_applicable";
   if(scenario=="failed-eligible"&&applicable) deterministic="failed";
   if(scenario=="family-aggregate-mismatch"&&i==0) deterministic="passed";
    familyJson.Append("{\"policy_id\":").Append(Q(families[i])).Append(",\"applicability\":").Append(Q(applicable?"applicable":"not_applicable")).Append(",\"deterministic_status\":").Append(Q(deterministic)).Append(",\"promotion_status\":").Append(Q(applicable?(scenario=="failed-eligible"?"eligible":"non_promotion"):"not_applicable")).Append(",\"evidence\":").Append(Q(applicable?"Fixture package identity and dependencies were observed.":"policy:"+families[i]+":not_applicable:no_observed_checks")).Append(",\"check_results\":[");
    for(int j=0;j<checks[i].Length;j++) {
     if(j>0) familyJson.Append(',');
     string checkDeterministic=applicable?(scenario=="failed-eligible"&&j==0?"failed":"passed"):"not_applicable";
     familyJson.Append("{\"check_id\":").Append(Q(checks[i][j])).Append(",\"applicability\":").Append(Q(applicable?"applicable":"not_applicable")).Append(",\"deterministic_status\":").Append(Q(checkDeterministic)).Append(",\"promotion_status\":").Append(Q(applicable?(scenario=="failed-eligible"?"eligible":"non_promotion"):"not_applicable")).Append(",\"evidence\":").Append(Q("fixture:"+families[i]+"."+checks[i][j]));
     if(scenario=="check-report-extra-field"&&i==0&&j==0) familyJson.Append(",\"extra\":true");
     familyJson.Append('}');
    }
    familyJson.Append("]}");
   }
  familyJson.Append(']');
  string finding="{\"policy_id\":\"reference_boundary\",\"code\":\"content.reference_boundary.non_promotion\",\"asset_path\":\"/Game/Fixtures/DA_GovernedFixture\",\"severity\":\"non_promotion\",\"reason\":\"Quantitative policy remains TBD.\",\"remediation\":\"Resolve the owned threshold and rerun.\",\"evidence_field\":\"thresholds.unresolved_budgets\"}";
  if(scenario=="failed-eligible") finding="{\"policy_id\":\"reference_boundary\",\"code\":\"content.reference_boundary.failed\",\"asset_path\":\"/Game/Fixtures/DA_GovernedFixture\",\"severity\":\"error\",\"reason\":\"Deterministic reference fact failed.\",\"remediation\":\"Correct the fact and rerun.\",\"evidence_field\":\"family_results.reference_boundary.check_results\"}";
  if(scenario=="finding-code-mismatch") finding=finding.Replace("content.reference_boundary.non_promotion","content.reference_boundary.failed");
   string report="{\"schema_id\":\"aetheln.content-validation-report\",\"schema_version\":2,\"revision\":"+Q(revision)+",\"engine_identity\":"+Q(Get(values,"EngineTag")+"@"+Get(values,"EngineRevision")) +",\"policy_sha256\":"+Q(policy)+",\"intake_sha256\":"+Q(intake)+",\"execution_provenance\":"+execution+",\"audience\":\"all\",\"started_utc\":"+Q(Get(values,"StartedUtc"))+",\"finished_utc\":"+Q(Get(values,"StartedUtc"))+",\"command\":"+Q("GameTests.AethelnContentValidation invocation_sha256="+Get(values,"InvocationSha256"))+",\"counts\":"+(scenario=="failed-eligible"?"{\"assets\":1,\"findings\":1,\"errors\":1,\"non_promotion\":0}":"{\"assets\":1,\"findings\":1,\"errors\":0,\"non_promotion\":1}")+",\"assets\":[{\"asset_path\":\"/Game/Fixtures/DA_GovernedFixture\",\"stable_id\":\"content.fixtures.governed_fixture\",\"content_version\":1,\"audience\":\"shared\",\"lifecycle_state\":"+Q(scenario=="failed-eligible"?"runtime_candidate":"temporary_prototype")+",\"provenance\":"+provenance+",\"lifecycle_evidence\":"+lifecycle+",\"family_results\":"+familyJson.ToString()+"}],\"findings\":["+finding+"],\"result\":"+Q(scenario=="failed-eligible"?"failed":"non_promotion")+"}";
  if(scenario=="unknown-report-field") report=report.Insert(1,"\"unsupported\":true,");
  if(scenario=="result-mismatch") report=report.Replace("\"result\":\"non_promotion\"","\"result\":\"passed\"");
   WriteReport(values,report);
   if(scenario=="policy-file-drift") File.AppendAllText(Get(values,"Policy")," ");
   if(scenario=="module-file-drift") File.AppendAllText(Path.Combine(binaries,"UnrealEditor-GameCore.dll"),"changed");
   if(scenario=="manifest-file-drift") File.AppendAllText(Path.Combine(binaries,"UnrealEditor.modules")," ");
   if(scenario=="build-log-drift") {
    try {
     string[] buildLogs=Directory.GetFiles(Path.GetDirectoryName(output),".editor-build.*.pending");
     if(buildLogs.Length!=1) throw new IOException("expected one retained pending build log");
     File.AppendAllText(buildLogs[0],"changed");
    }
    catch(IOException) { Console.Error.WriteLine("output_guard_blocked_build_log_drift"); return 34; }
   }
   if(scenario=="snapshot-file-drift") File.AppendAllText(Get(values,"RegistrySnapshot")," ");
  string drift=Environment.GetEnvironmentVariable("AETHELN_CONTENT_FAKE_DRIFT")??"";
  if(scenario=="repository-drift"&&drift.Length>0) File.WriteAllText(drift,"changed");
   return scenario=="nonzero-with-report"?9:0;
 }
}
'@
	Add-Type -TypeDefinition $EditorSource -OutputAssembly (Join-Path $FakeBin 'UnrealEditor-Cmd.exe') -OutputType ConsoleApplication
}

function New-Case([string] $Name, [string] $FakeBin) {
	$Root = Join-Path $FixtureRoot $Name
	$Repository = Join-Path $Root 'repo'
	$Engine = Join-Path $Root 'engine'
	$EditorDirectory = Join-Path $Engine 'Engine\Binaries\Win64'
	$BuildDirectory = Join-Path $Engine 'Engine\Build'
	$BuildBatchDirectory = Join-Path $BuildDirectory 'BatchFiles'
	$CompilerRoot = Join-Path $Root 'VS\MSVC\14.44.35207'
	$SdkRoot = Join-Path $Root 'Windows Kits\10'
	$Compiler = Join-Path $CompilerRoot 'bin\Hostx64\x64\cl.exe'
	$ResourceCompiler = Join-Path $SdkRoot 'bin\10.0.26100.0\x64\rc.exe'
	foreach ($Directory in @((Join-Path $Repository 'scripts\content'), (Join-Path $Repository 'Config\ContentValidation'), $EditorDirectory, $BuildBatchDirectory, (Split-Path -Parent $Compiler), (Split-Path -Parent $ResourceCompiler))) {
		New-Item -ItemType Directory -Path $Directory -Force | Out-Null
	}
	Copy-Item -LiteralPath $SourceRunner -Destination (Join-Path $Repository 'scripts\content\Invoke-ContentValidation.ps1')
	Copy-Item -LiteralPath (Join-Path $FakeBin 'UnrealEditor-Cmd.exe') -Destination (Join-Path $EditorDirectory 'UnrealEditor-Cmd.exe')
	Copy-Item -LiteralPath (Join-Path $FakeBin 'FakeEditorBuild.exe') -Destination (Join-Path $BuildBatchDirectory 'FakeEditorBuild.exe')
	$BuildBatch = @'
@echo off
"%~dp0FakeEditorBuild.exe" %*
exit /b %ERRORLEVEL%
'@
	Write-Utf8 (Join-Path $BuildBatchDirectory 'Build.bat') $BuildBatch
	Write-Utf8 (Join-Path $Repository 'AethelnOnline.uproject') '{}'
	Write-Utf8 (Join-Path $Engine 'Engine\Build\Build.version') '{"MajorVersion":5,"MinorVersion":8,"PatchVersion":1,"BranchName":"++UE5+Release-5.8"}'
	Write-Utf8 $Compiler 'fixture compiler'
	Write-Utf8 $ResourceCompiler 'fixture resource compiler'
	$FamilyIds = @('collision','rendering_suitability','texture','material','skeletal_animation','map_world','navigation','reference_boundary')
	$FamilyChecks = [ordered]@{
		collision = @('profile','simple_complex_policy','presentation_equivalence')
		rendering_suitability = @('lod','hlod','nanite_suitability','streaming')
		texture = @('pbr_channels','tiling','compression','mips','streaming')
		material = @('material_instance_policy','shader_complexity_evidence')
		skeletal_animation = @('rig_compatibility','morph_policy','influences','socket_ownership','animation_complexity')
		map_world = @('map_identity','data_layers','pcg_authority','runtime_editor_boundary')
		navigation = @('navigation_data_audience','streaming_boundaries','runtime_rebuild_policy')
		reference_boundary = @('stable_id_unique','redirectors','broken_references','compatible_content_version','audience_reachability','hard_reference_exceptions')
	}
	$FixturePolicy = [ordered]@{
		schema_id = 'aetheln.asset-intake-policy'
		schema_version = 2
		policy_families = @($FamilyIds | ForEach-Object { [ordered]@{ id = $_; failure_code = "content.$_.failed"; checks = @($FamilyChecks[$_]) } })
		report = [ordered]@{
			schema_id = 'aetheln.content-validation-report'
			schema_version = 2
			required_fields = @('schema_id','schema_version','revision','engine_identity','policy_sha256','intake_sha256','execution_provenance','audience','started_utc','finished_utc','command','counts','assets','findings','result')
			finding_required_fields = @('policy_id','code','asset_path','severity','reason','remediation','evidence_field')
			asset_required_fields = @('asset_path','stable_id','content_version','audience','lifecycle_state','provenance','lifecycle_evidence','family_results')
			provenance_required_fields = @('author_or_provider','source_record','source_version','license_or_permission_evidence','modifications','generation_metadata_when_applicable','content_sha256','reviewer','approval_state')
			lifecycle_evidence_required_fields = @('content_identity','temporary_prototype','runtime_candidate','production_approval')
			execution_provenance_required_fields = @('repository_clean','engine_revision','engine_tag','engine_binary_sha256','build_version_sha256','target','platform','configuration','editor_build_command_sha256','editor_build_log_sha256','compiler_version','compiler_sha256','resource_compiler_version','resource_compiler_sha256','target_receipt','module_manifest','loaded_project_modules','project_sha256','policy_sha256','intake_sha256','invocation_sha256','registry_source')
			family_result_required_fields = @('policy_id','applicability','deterministic_status','promotion_status','evidence','check_results')
			check_result_required_fields = @('check_id','applicability','deterministic_status','promotion_status','evidence')
			artifact_descriptor_required_fields = @('path','size_bytes','sha256','build_id')
			loaded_project_module_required_fields = @('name','path','size_bytes','sha256','build_id')
			loaded_project_module_names = @('GameCore','GameTests')
			counts_required_fields = @('assets','findings','errors','non_promotion')
			allowed_results = @('passed','failed','non_promotion')
			allowed_deterministic_statuses = @('passed','failed','evidence_unavailable','not_applicable')
			allowed_promotion_statuses = @('eligible','non_promotion','not_applicable')
			allowed_severities = @('error','non_promotion')
			allowed_registry_sources = @('live_asset_registry','test_snapshot')
		}
	} | ConvertTo-Json -Depth 8
	Write-Utf8 (Join-Path $Repository 'Config\ContentValidation\asset-intake-policy.json') $FixturePolicy
	$Intake = @{
		schema_id = 'aetheln.runtime-asset-intake'
		schema_version = 1
		policy_schema_id = 'aetheln.asset-intake-policy'
		policy_schema_version = 2
		content_root = 'Content/'
		package_root = '/Game'
		expected_asset_count = 1
		source_groups = @([ordered]@{
			id = 'fixture'
			author_or_provider = 'fixture provider'
			source_record = 'fixture record'
			source_version = 'fixture version'
			license_or_permission_evidence = 'fixture permission'
			modifications = 'none'
			generation_metadata_when_applicable = 'not_applicable'
			reviewer = 'fixture reviewer'
			approval_state = 'temporary_prototype_only'
			naming_owner = 'fixture owner'
			import_settings_record = 'fixture import record'
			reimport_settings_record = 'fixture reimport record'
		})
		assets = @(@{
			asset_path = '/Game/Fixtures/DA_GovernedFixture'
			repository_path = 'Content/Fixtures/DA_GovernedFixture.uasset'
			stable_id = 'content.fixtures.governed_fixture'
			content_version = 1
			audience = 'shared'
			lifecycle_state = 'temporary_prototype'
			source_group_id = 'fixture'
			content_sha256 = ('a' * 64)
			lifecycle_evidence = [ordered]@{
				content_identity = [ordered]@{ stable_id = 'content.fixtures.governed_fixture'; content_version = 1; content_sha256 = ('a' * 64) }
				temporary_prototype = @([ordered]@{ owner = 'Issue #100'; approval_record = 'Issue #100'; recovery_trigger = 'replace fixture'; may_be_runtime_candidate = $false })
				runtime_candidate = @()
				production_approval = @()
			}
		})
	} | ConvertTo-Json -Depth 8
	Write-Utf8 (Join-Path $Repository 'Config\ContentValidation\runtime-asset-intake.json') $Intake
	$ResultDirectory = Join-Path $Repository 'TestResults'
	New-Item -ItemType Directory -Path $ResultDirectory -Force | Out-Null
	Write-Utf8 (Join-Path $ResultDirectory 'content-validation-report.json') '{"stale":true}'
	Write-Utf8 (Join-Path $ResultDirectory 'content-validation.log') 'stale commandlet log'
	Write-Utf8 (Join-Path $ResultDirectory 'editor-build.log') 'stale build log'
	return [ordered]@{
		root = $Root
		repository = $Repository
		engine = $Engine
		runner = Join-Path $Repository 'scripts\content\Invoke-ContentValidation.ps1'
		build = Join-Path $BuildBatchDirectory 'Build.bat'
		buildCapture = Join-Path $Root 'build-arguments.txt'
		editorCapture = Join-Path $Root 'editor-arguments.txt'
		compilerRoot = $CompilerRoot
		sdkRoot = $SdkRoot
		compiler = $Compiler
		resourceCompiler = $ResourceCompiler
		childPid = Join-Path $Root 'child-pid.txt'
		buildChildPid = Join-Path $Root 'build-child-pid.txt'
		buildParentPid = Join-Path $Root 'build-parent-pid.txt'
		buildLateMarker = Join-Path $Root 'build-late.marker'
		drift = Join-Path $Root 'drift.marker'
		report = Join-Path $Repository 'TestResults\content-validation-report.json'
		buildLog = Join-Path $Repository 'TestResults\editor-build.log'
		commandletLog = Join-Path $Repository 'TestResults\content-validation.log'
		receipt = Join-Path $Repository 'Binaries\Win64\AethelnOnlineEditor.target'
		manifest = Join-Path $Repository 'Binaries\Win64\UnrealEditor.modules'
		gameCore = Join-Path $Repository 'Binaries\Win64\UnrealEditor-GameCore.dll'
		gameTests = Join-Path $Repository 'Binaries\Win64\UnrealEditor-GameTests.dll'
	}
}

function Invoke-Case([string] $Name, [string] $FakeBin, [string] $EditorCase = 'success', [string] $GitCase = 'clean', [bool] $UseSnapshot = $false, [bool] $AllowSnapshot = $false, [int] $TimeoutSeconds = 5, [string] $BuildCase = 'success', [string] $OutputAttack = 'none', [int] $BuildTimeoutSeconds = 10) {
	$Fixture = New-Case $Name $FakeBin
	$AttackJob = $null
	$AttackResult = $null
	$SecondExitCode = $null
	$SecondOutput = $null
	$SecondStartedBuild = $null
	$CanonicalBeforeRelease = $null
	$ProtectedHashBefore = $null
	$ProtectedHashAfter = $null
	if ($OutputAttack -cin @('swap-before-directory-create','missing-output-directory')) {
		$Fixture.report = Join-Path $Fixture.repository 'TestResults\new\content-validation-report.json'
		$Fixture.commandletLog = Join-Path $Fixture.repository 'TestResults\new\content-validation.log'
		$Fixture.buildLog = Join-Path $Fixture.repository 'TestResults\new\editor-build.log'
	}
	if ($OutputAttack -ceq 'publish-fail-first-run') {
		foreach ($Path in @($Fixture.report, $Fixture.commandletLog, $Fixture.buildLog)) { Remove-Item -LiteralPath $Path -Force }
	}
	if ($OutputAttack -cin @('retention-cap','retention-reserve-six')) {
		$ArtifactCount = if ($OutputAttack -ceq 'retention-cap') { 129 } else { 123 }
		for ($Index = 1; $Index -le $ArtifactCount; $Index++) {
			$Token = $Index.ToString('x32')
			Write-Utf8 (Join-Path (Split-Path -Parent $Fixture.report) ".previous.$Token.content-validation.log") 'retained fixture log'
		}
	}
	if ($OutputAttack -ceq 'retention-backup-byte-cap') {
		$RunnerText = [IO.File]::ReadAllText($Fixture.runner)
		Assert-True ($RunnerText.Contains('const long MaxRetainedBytes=1073741824L;')) 'The byte-cap fixture must locate the production retention constant.'
		[IO.File]::WriteAllText($Fixture.runner, $RunnerText.Replace('const long MaxRetainedBytes=1073741824L;', 'const long MaxRetainedBytes=256L;'), [Text.UTF8Encoding]::new($false))
		Write-Utf8 $Fixture.report ('{"stale":"' + ('x' * 300) + '"}')
	}
	if ($EditorCase -ceq 'failed-eligible') {
		$IntakePath = Join-Path $Fixture.repository 'Config\ContentValidation\runtime-asset-intake.json'
		$Intake = Get-Content -LiteralPath $IntakePath -Raw | ConvertFrom-Json
		$Intake.source_groups[0].approval_state = 'runtime_candidate_approved'
		$Intake.assets[0].lifecycle_state = 'runtime_candidate'
		$Intake.assets[0].lifecycle_evidence.temporary_prototype = @()
		$Intake.assets[0].lifecycle_evidence.runtime_candidate = @([ordered]@{
			review_revision = ('a' * 40)
			reviewer = 'fixture reviewer'
			approval_record = 'fixture approval'
			stable_id = 'content.fixtures.governed_fixture'
			content_version = 1
			content_sha256 = ('a' * 64)
		})
		Write-Utf8 $IntakePath ($Intake | ConvertTo-Json -Depth 8)
	}
	if ($OutputAttack -ceq 'reparse') {
		$ResultDirectory = Split-Path -Parent $Fixture.report
		Remove-Item -LiteralPath $ResultDirectory -Recurse -Force
		$RealDirectory = Join-Path $Fixture.root 'aliased-results'
		New-Item -ItemType Directory -Path $RealDirectory | Out-Null
		New-Item -ItemType Junction -Path $ResultDirectory -Target $RealDirectory | Out-Null
	}
	elseif ($OutputAttack -ceq 'policy-hardlink') {
		Remove-Item -LiteralPath $Fixture.report -Force
		& fsutil.exe hardlink create $Fixture.report (Join-Path $Fixture.repository 'Config\ContentValidation\asset-intake-policy.json') | Out-Null
		if ($LASTEXITCODE -ne 0) { throw 'Could not create the owned hard-link attack fixture.' }
	}
	elseif ($OutputAttack -ceq 'mount-during-held-directory') {
		foreach ($Path in @($Fixture.report, $Fixture.commandletLog, $Fixture.buildLog)) { Remove-Item -LiteralPath $Path -Force }
		$SeamRoot = Join-Path $Fixture.root 'held-directory-seam'
		$VictimDirectory = Join-Path $Fixture.root 'outside-victim'
		New-Item -ItemType Directory -Path $SeamRoot,$VictimDirectory | Out-Null
		$ProtectedPath = Join-Path $VictimDirectory 'sentinel.txt'
		Write-Utf8 $ProtectedPath 'outside victim bytes'
		$ProtectedHashBefore = Get-Sha256 $ProtectedPath
		$ReadyPath = Join-Path $SeamRoot 'held.ready'
		$ContinuePath = Join-Path $SeamRoot 'held.continue'
		$ResultPath = Join-Path $SeamRoot 'held.result'
		$TargetPath = Split-Path -Parent $Fixture.report
		$RunnerText = [IO.File]::ReadAllText($Fixture.runner)
		$Marker = 'AssertRetentionBudget(outputDirectory);'
		Assert-True ($RunnerText.Contains($Marker)) 'The fixture must find the post-admission held-ancestor seam before pending-file creation.'
		$Injected = @'
string heldSeam=Environment.GetEnvironmentVariable("AETHELN_CONTENT_TEST_HELD_SEAM_ROOT");
if(!String.IsNullOrEmpty(heldSeam)) {
 File.WriteAllText(Path.Combine(heldSeam,"held.ready"),"ready");
 DateTime deadline=DateTime.UtcNow.AddSeconds(10);
 while(!File.Exists(Path.Combine(heldSeam,"held.continue"))&&DateTime.UtcNow<deadline) System.Threading.Thread.Sleep(10);
 if(!File.Exists(Path.Combine(heldSeam,"held.continue"))) throw new InvalidOperationException("held_directory_fixture_timeout");
}
'@
		[IO.File]::WriteAllText($Fixture.runner, $RunnerText.Replace($Marker, $Marker + "`n" + $Injected), [Text.UTF8Encoding]::new($false))
		$AttackJob = Start-Job -ArgumentList $ReadyPath,$ContinuePath,$ResultPath,$TargetPath,$VictimDirectory -ScriptBlock {
			param($Ready,$Continue,$Result,$Target,$Victim)
			try {
				$Deadline = [DateTime]::UtcNow.AddSeconds(10)
				while (-not (Test-Path -LiteralPath $Ready -PathType Leaf) -and [DateTime]::UtcNow -lt $Deadline) { Start-Sleep -Milliseconds 10 }
				if (-not (Test-Path -LiteralPath $Ready -PathType Leaf)) { throw 'held_directory_ready_timeout' }
				Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
public static class AethelnContentFixtureMountPoint {
 [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
 public static extern SafeFileHandle CreateFileW(string name,uint access,uint share,IntPtr security,uint disposition,uint flags,IntPtr template);
 [DllImport("kernel32.dll", SetLastError=true)]
 public static extern bool DeviceIoControl(SafeFileHandle handle,uint code,byte[] input,int inputSize,IntPtr output,int outputSize,out int returned,IntPtr overlapped);
}
'@
				$Substitute = [Text.Encoding]::Unicode.GetBytes('\??\' + $Victim.TrimEnd('\') + '\')
				$Print = [Text.Encoding]::Unicode.GetBytes($Victim)
				$DataLength = 8 + $Substitute.Length + 2 + $Print.Length + 2
				$Buffer = New-Object byte[] (8 + $DataLength)
				[BitConverter]::GetBytes([uint32] 2684354563).CopyTo($Buffer, 0)
				[BitConverter]::GetBytes([uint16] $DataLength).CopyTo($Buffer, 4)
				[BitConverter]::GetBytes([uint16] 0).CopyTo($Buffer, 8)
				[BitConverter]::GetBytes([uint16] $Substitute.Length).CopyTo($Buffer, 10)
				[BitConverter]::GetBytes([uint16] ($Substitute.Length + 2)).CopyTo($Buffer, 12)
				[BitConverter]::GetBytes([uint16] $Print.Length).CopyTo($Buffer, 14)
				$Substitute.CopyTo($Buffer, 16)
				$Print.CopyTo($Buffer, 16 + $Substitute.Length + 2)
				$Handle = [AethelnContentFixtureMountPoint]::CreateFileW($Target, 0x100, 0x7, [IntPtr]::Zero, 3, 0x02200000, [IntPtr]::Zero)
				$Returned = 0
				$Converted = (-not $Handle.IsInvalid) -and [AethelnContentFixtureMountPoint]::DeviceIoControl($Handle, 0x900A4, $Buffer, $Buffer.Length, [IntPtr]::Zero, 0, [ref] $Returned, [IntPtr]::Zero)
				$ErrorCode = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
				$Handle.Dispose()
				[IO.File]::WriteAllText($Result, $(if ($Converted) { 'swapped' } else { "blocked:$ErrorCode" }))
			}
			catch { [IO.File]::WriteAllText($Result, "fixture_error:$($_.Exception.Message)") }
			finally { [IO.File]::WriteAllText($Continue, 'continue') }
		}
		$env:AETHELN_CONTENT_TEST_HELD_SEAM_ROOT = $SeamRoot
	}
	elseif ($OutputAttack -ceq 'concurrent-directory') {
		$SeamRoot = Join-Path $Fixture.root 'concurrent-seam'
		New-Item -ItemType Directory -Path $SeamRoot | Out-Null
		$ReadyPath = Join-Path $SeamRoot 'pre-build-open.ready'
		$ContinuePath = Join-Path $SeamRoot 'pre-build-open.continue'
		$env:AETHELN_CONTENT_TEST_OUTPUT_OPEN_SEAM_ROOT = $SeamRoot
		$env:AETHELN_CONTENT_TEST_OUTPUT_OPEN_SEAM_PHASE = 'pre-build-open'
	}
	elseif ($OutputAttack -cin @('swap-build-log','swap-report','swap-commandlet-log','swap-output-directory','swap-pre-cleanup-directory','swap-before-directory-create')) {
		$SeamRoot = Join-Path $Fixture.root 'output-open-seam'
		New-Item -ItemType Directory -Path $SeamRoot | Out-Null
		$Phase = if ($OutputAttack -ceq 'swap-before-directory-create') { 'pre-output-directory-create' } elseif ($OutputAttack -ceq 'swap-pre-cleanup-directory') { 'pre-output-cleanup' } elseif ($OutputAttack -cin @('swap-build-log','swap-output-directory')) { 'pre-build-open' } else { 'pre-editor-open' }
		$TargetPath = if ($OutputAttack -ceq 'swap-build-log') { $Fixture.buildLog } elseif ($OutputAttack -ceq 'swap-report') { $Fixture.report } elseif ($OutputAttack -ceq 'swap-commandlet-log') { $Fixture.commandletLog } elseif ($OutputAttack -ceq 'swap-before-directory-create') { Join-Path $Fixture.repository 'TestResults' } else { Split-Path -Parent $Fixture.report }
		$DirectoryAttack = $OutputAttack -cin @('swap-output-directory','swap-pre-cleanup-directory','swap-before-directory-create')
		$ProtectedPath = if ($OutputAttack -cin @('swap-pre-cleanup-directory','swap-before-directory-create')) {
			$VictimDirectory = Join-Path $Fixture.root 'outside-victim'
			New-Item -ItemType Directory -Path $VictimDirectory | Out-Null
			Write-Utf8 (Join-Path $VictimDirectory 'content-validation-report.json') 'outside previous report'
			Write-Utf8 (Join-Path $VictimDirectory 'content-validation.log') 'outside previous commandlet log'
			Write-Utf8 (Join-Path $VictimDirectory 'editor-build.log') 'outside previous build log'
			Join-Path $VictimDirectory 'content-validation-report.json'
		} else { Join-Path $Fixture.repository 'Config\ContentValidation\asset-intake-policy.json' }
		$ProtectedHashBefore = Get-Sha256 $ProtectedPath
		$ReadyPath = Join-Path $SeamRoot "$Phase.ready"
		$ContinuePath = Join-Path $SeamRoot "$Phase.continue"
		$ResultPath = Join-Path $SeamRoot "$Phase.result"
		$AttackJob = Start-Job -ArgumentList $ReadyPath,$ContinuePath,$ResultPath,$TargetPath,$ProtectedPath,$DirectoryAttack -ScriptBlock {
			param($Ready,$Continue,$Result,$Target,$Protected,$AttackDirectory)
			$Deadline = [DateTime]::UtcNow.AddSeconds(10)
			while (-not (Test-Path -LiteralPath $Ready -PathType Leaf) -and [DateTime]::UtcNow -lt $Deadline) { Start-Sleep -Milliseconds 10 }
			try {
				if ($AttackDirectory) {
					$Moved = "$Target.moved"
					Move-Item -LiteralPath $Target -Destination $Moved -ErrorAction Stop
					New-Item -ItemType Junction -Path $Target -Target (Split-Path -Parent $Protected) -ErrorAction Stop | Out-Null
				}
				else {
					if (Test-Path -LiteralPath $Target) { Remove-Item -LiteralPath $Target -Force -ErrorAction Stop }
					New-Item -ItemType HardLink -Path $Target -Target $Protected -ErrorAction Stop | Out-Null
				}
				[IO.File]::WriteAllText($Result, 'alias_installed')
			}
			catch { [IO.File]::WriteAllText($Result, "alias_blocked:$($_.Exception.Message)") }
			finally { [IO.File]::WriteAllText($Continue, 'continue') }
		}
		$env:AETHELN_CONTENT_TEST_OUTPUT_OPEN_SEAM_ROOT = $SeamRoot
		$env:AETHELN_CONTENT_TEST_OUTPUT_OPEN_SEAM_PHASE = $Phase
	}
	$Snapshot = Join-Path $Fixture.root 'registry-snapshot.json'
	if ($UseSnapshot) { Write-Utf8 $Snapshot '{"schema_id":"aetheln.asset-registry-snapshot","schema_version":1,"assets":[]}' }
	$SnapshotSha256 = if ($UseSnapshot) { Get-Sha256 $Snapshot } else { $null }
	$env:AETHELN_CONTENT_FAKE_BUILD_CAPTURE = $Fixture.buildCapture
	$env:AETHELN_CONTENT_FAKE_BUILD_CASE = $BuildCase
	if ($BuildCase -ceq 'child-pump-fault') { $env:AETHELN_CONTENT_TEST_BUILD_PUMP_FAULT = '1' }
	$env:AETHELN_CONTENT_FAKE_BUILD_CHILD_PID = $Fixture.buildChildPid
	$env:AETHELN_CONTENT_FAKE_BUILD_PARENT_PID = $Fixture.buildParentPid
	$env:AETHELN_CONTENT_FAKE_BUILD_LATE_MARKER = $Fixture.buildLateMarker
	$env:AETHELN_CONTENT_FAKE_COMPILER_ROOT = $Fixture.compilerRoot
	$env:AETHELN_CONTENT_FAKE_SDK_ROOT = $Fixture.sdkRoot
	$env:AETHELN_CONTENT_FAKE_CAPTURE = $Fixture.editorCapture
	$env:AETHELN_CONTENT_FAKE_CHILD_PID = $Fixture.childPid
	$env:AETHELN_CONTENT_FAKE_EDITOR_CASE = $EditorCase
	$env:AETHELN_CONTENT_FAKE_GIT_CASE = $GitCase
	$env:AETHELN_CONTENT_FAKE_DRIFT = $Fixture.drift
	$env:AETHELN_CONTENT_FAKE_OUTPUT_ATTACK = $OutputAttack
	if ($OutputAttack -cin @('publish-fail-after-first','publish-fail-first-run')) { $env:AETHELN_CONTENT_TEST_PUBLISH_FAIL_AFTER_FIRST = '1' }
	$Arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Fixture.runner, '-EngineRoot', $Fixture.engine, '-OutputPath', $Fixture.report, '-TimeoutSeconds', [string]$TimeoutSeconds)
	if ($BuildTimeoutSeconds -ne 86400) { $Arguments += @('-BuildTimeoutSeconds', [string]$BuildTimeoutSeconds) }
	if ($UseSnapshot) { $Arguments += @('-AssetRegistrySnapshotPath', $Snapshot) }
	if ($AllowSnapshot) { $Arguments += '-AllowTestRegistrySnapshot' }
	$Info = New-Object Diagnostics.ProcessStartInfo
	$Info.FileName = $PowerShell
	$Info.Arguments = ($Arguments | ForEach-Object { '"' + $_.Replace('"', '\"') + '"' }) -join ' '
	$Info.WorkingDirectory = $Fixture.repository
	$Info.UseShellExecute = $false
	$Info.CreateNoWindow = $true
	$Info.RedirectStandardOutput = $true
	$Info.RedirectStandardError = $true
	$Process = New-Object Diagnostics.Process
	$Process.StartInfo = $Info
	try {
		Assert-True ($Process.Start()) "$Name runner must start."
		$StandardOutput = $Process.StandardOutput.ReadToEndAsync()
		$StandardError = $Process.StandardError.ReadToEndAsync()
		if ($OutputAttack -ceq 'concurrent-directory') {
			try {
				$Deadline = [DateTime]::UtcNow.AddSeconds(8)
				while (-not (Test-Path -LiteralPath $ReadyPath -PathType Leaf) -and [DateTime]::UtcNow -lt $Deadline) { Start-Sleep -Milliseconds 10 }
				Assert-True (Test-Path -LiteralPath $ReadyPath -PathType Leaf) 'The first invocation must reach the held pre-build seam.'
				$SecondInfo = New-Object Diagnostics.ProcessStartInfo
				$SecondInfo.FileName = $Info.FileName
				$SecondInfo.Arguments = $Info.Arguments
				$SecondInfo.WorkingDirectory = $Info.WorkingDirectory
				$SecondInfo.UseShellExecute = $false
				$SecondInfo.CreateNoWindow = $true
				$SecondInfo.RedirectStandardOutput = $true
				$SecondInfo.RedirectStandardError = $true
				$SecondInfo.EnvironmentVariables.Remove('AETHELN_CONTENT_TEST_OUTPUT_OPEN_SEAM_ROOT')
				$SecondInfo.EnvironmentVariables.Remove('AETHELN_CONTENT_TEST_OUTPUT_OPEN_SEAM_PHASE')
				$SecondProcess = New-Object Diagnostics.Process
				$SecondProcess.StartInfo = $SecondInfo
				try {
					Assert-True ($SecondProcess.Start()) 'The second invocation must start.'
					$SecondStdout = $SecondProcess.StandardOutput.ReadToEndAsync()
					$SecondStderr = $SecondProcess.StandardError.ReadToEndAsync()
					Assert-True ($SecondProcess.WaitForExit(7000)) 'The second invocation must fail closed within seven seconds.'
					$SecondExitCode = $SecondProcess.ExitCode
					$SecondOutput = $SecondStdout.GetAwaiter().GetResult() + $SecondStderr.GetAwaiter().GetResult()
				}
				finally {
					if (-not $SecondProcess.HasExited) { $SecondProcess.Kill() }
					$SecondProcess.Dispose()
				}
				$SecondStartedBuild = Test-Path -LiteralPath $Fixture.buildCapture
				$CanonicalBeforeRelease = Get-Content -LiteralPath $Fixture.report -Raw
			}
			finally { Write-Utf8 $ContinuePath 'continue' }
		}
		$FinishedWithinFixtureBound = $Process.WaitForExit(20000)
		if (-not $FinishedWithinFixtureBound) {
			$PendingBuild = @(Get-ChildItem -LiteralPath (Split-Path -Parent $Fixture.buildLog) -Filter '.editor-build.*.pending' -File -ErrorAction SilentlyContinue)
			$PendingLengths = @($PendingBuild | ForEach-Object { $_.Length }) -join ','
			throw "$Name runner must finish within the fixture bound. buildStarted=$(Test-Path -LiteralPath $Fixture.buildCapture); pendingBuildLengths=$PendingLengths"
		}
		$Output = $StandardOutput.GetAwaiter().GetResult() + $StandardError.GetAwaiter().GetResult()
		$ExitCode = $Process.ExitCode
	}
	finally {
		if (-not $Process.HasExited) { $Process.Kill() }
		$Process.Dispose()
	}
	if ($null -ne $AttackJob) {
		[void](Wait-Job -Job $AttackJob -Timeout 10)
		[void](Receive-Job -Job $AttackJob)
		Remove-Job -Job $AttackJob -Force
		$AttackResult = if (Test-Path -LiteralPath $ResultPath -PathType Leaf) { Get-Content -LiteralPath $ResultPath -Raw } else { 'missing_result' }
		$ProtectedHashAfter = if (Test-Path -LiteralPath $ProtectedPath -PathType Leaf) { Get-Sha256 $ProtectedPath } else { $null }
		if ($OutputAttack -ceq 'mount-during-held-directory' -and $AttackResult -ceq 'swapped') { $script:KeepUnsafeFixtureRoot = $true }
	}
	Remove-Item Env:AETHELN_CONTENT_TEST_OUTPUT_OPEN_SEAM_ROOT -ErrorAction SilentlyContinue
	Remove-Item Env:AETHELN_CONTENT_TEST_OUTPUT_OPEN_SEAM_PHASE -ErrorAction SilentlyContinue
	Remove-Item Env:AETHELN_CONTENT_FAKE_OUTPUT_ATTACK -ErrorAction SilentlyContinue
	Remove-Item Env:AETHELN_CONTENT_TEST_BUILD_PUMP_FAULT -ErrorAction SilentlyContinue
	Remove-Item Env:AETHELN_CONTENT_TEST_PUBLISH_FAIL_AFTER_FIRST -ErrorAction SilentlyContinue
	Remove-Item Env:AETHELN_CONTENT_TEST_HELD_SEAM_ROOT -ErrorAction SilentlyContinue
	$Report = $null
	if (Test-Path -LiteralPath $Fixture.report -PathType Leaf) {
		try { $Report = Get-Content -LiteralPath $Fixture.report -Raw | ConvertFrom-Json } catch { }
	}
	return [ordered]@{ fixture = $Fixture; snapshot = $Snapshot; snapshotSha256 = $SnapshotSha256; exitCode = $ExitCode; output = $Output; report = $Report; attackResult = $AttackResult; protectedHashBefore = $ProtectedHashBefore; protectedHashAfter = $ProtectedHashAfter; secondExitCode = $SecondExitCode; secondOutput = $SecondOutput; secondStartedBuild = $SecondStartedBuild; canonicalBeforeRelease = $CanonicalBeforeRelease }
}

$script:KeepUnsafeFixtureRoot = $false
try {
	foreach ($RequiredPath in @($SourceRunner, $BuildRules, $ScannerHeader, $ScannerSource, $CommandletHeader, $CommandletSource)) {
		Assert-True (Test-Path -LiteralPath $RequiredPath -PathType Leaf) "Required implementation '$RequiredPath' must exist."
	}

	$Tokens = $null
	$Errors = $null
	$Ast = [Management.Automation.Language.Parser]::ParseFile($SourceRunner, [ref]$Tokens, [ref]$Errors)
	Assert-True ($Errors.Count -eq 0) 'The local content-validation runner must parse under Windows PowerShell.'
	$ParameterNames = @($Ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
	$ExpectedParameters = @('EngineRoot', 'OutputPath', 'TimeoutSeconds', 'BuildTimeoutSeconds', 'AssetRegistrySnapshotPath', 'AllowTestRegistrySnapshot')
	Assert-True (($ParameterNames -join ',') -ceq ($ExpectedParameters -join ',')) 'The runner public parameter contract changed unexpectedly.'
	$RunnerText = Get-Content -LiteralPath $SourceRunner -Raw
	Assert-True ($RunnerText -match 'Engine[\\/]Build[\\/]BatchFiles[\\/]Build\.bat' -and $RunnerText -match "'AethelnOnlineEditor','Win64','Development'" -and $RunnerText -match "'-WaitMutex','-NoHotReloadFromIDE'") 'The wrapper must own the exact approved AethelnOnlineEditor Win64 Development build invocation.'
	$CreateIndex = $RunnerText.IndexOf('if(!CreateProcess(')
	$AssignIndex = $RunnerText.IndexOf('Assign(information.process)')
	$ResumeIndex = $RunnerText.IndexOf('ResumeThread(information.thread)')
	Assert-True ($CreateIndex -ge 0 -and $CreateIndex -lt $AssignIndex -and $AssignIndex -lt $ResumeIndex) 'The commandlet must remain suspended until assignment to its kill-on-close job succeeds.'
	Assert-True ($RunnerText -notmatch '\$Process\.Start\(' -and $RunnerText -match 'JOB_OBJECT_LIMIT_KILL_ON_CLOSE|KillOnJobClose') 'The wrapper must not launch the editor before process-tree ownership is established.'
	Assert-True ($RunnerText -match 'Assert-OutputBoundary' -and $RunnerText -match 'output_path_reparse' -and $RunnerText -match 'output_path_alias') 'The wrapper must reject reparse traversal and same-file output aliases before mutation and report consumption.'
	Assert-True ($RunnerText -match 'class OutputGuard' -and $RunnerText -match 'NtCreateFile' -and $RunnerText -match 'FlagOpenReparsePoint' -and $RunnerText -match 'ReportFileIdentity' -and $RunnerText -notmatch 'CreateDirectoryW') 'The wrapper must create pending files relative to retained output handles and never create a missing output directory.'
	Assert-True ($RunnerText -match 'BackupExisting' -and $RunnerText -match 'output_publication_test_failure_after_first_rename' -and $RunnerText -match 'prior outputs were restored') 'The wrapper must retain prior output bytes for recoverable publication.'
	Assert-True ($RunnerText -match 'New-JsonFileState' -and $RunnerText -notmatch 'Get-Content -LiteralPath \$PolicyPath -Raw \| ConvertFrom-Json') 'Policy and intake parsing must use the same bounded bytes that are hashed.'

	$ScannerText = Get-Content -LiteralPath $ScannerSource -Raw
	$ScannerHeaderText = Get-Content -LiteralPath $ScannerHeader -Raw
	$BuildRulesText = Get-Content -LiteralPath $BuildRules -Raw
	$HeaderText = Get-Content -LiteralPath $CommandletHeader -Raw
	$CommandletText = Get-Content -LiteralPath $CommandletSource -Raw
	Assert-True ($HeaderText -match 'UCLASS\(\)' -and $HeaderText -match 'public UCommandlet' -and $HeaderText -match 'generated\.h') 'The scanner entry point must be a reflected Unreal commandlet.'
	Assert-True ($CommandletText -match 'FParse::Value' -and $CommandletText -match 'AllowTestRegistrySnapshot') 'The commandlet must parse explicit inputs and guard test snapshots.'
	Assert-True ($RunnerText -match 'RegistrySnapshotSha256=\$\(\$SnapshotState\.Sha256\)' -and $ScannerHeaderText -match 'RegistrySnapshotSha256' -and $CommandletText -match 'RegistrySnapshotSha256=' -and $CommandletText -match 'bAllSnapshotMembers') 'The captured snapshot digest must flow through wrapper, commandlet, and scanner run arguments.'
	Assert-True ($ScannerText -match 'LoadVerifiedRegistrySnapshot\(Arguments\.RegistrySnapshotPath, Arguments\.RegistrySnapshotSha256' -and $ScannerText -notmatch 'Serialize\(SnapshotRoot') 'The scanner must hash and parse the original snapshot byte buffer without object serialization and reparsing.'
	Assert-True ($ScannerText -match 'SearchAllAssets\(true\)' -and $ScannerText -match 'GetAllAssets' -and $ScannerText -match 'GetDependencies') 'The live scanner must use the read-only Asset Registry and dependency graph.'
	Assert-True ($ScannerText -match 'IsRedirector' -and $ScannerText -match 'content\.%s\.failed' -and $ScannerText -match 'reference_boundary') 'Redirectors and reference boundaries must fail closed.'
	Assert-True ($ScannerText -notmatch 'GetSHA256Signature' -and $ScannerText -match 'SHA256\(' -and $BuildRulesText -match 'AddEngineThirdPartyPrivateStaticDependencies\(Target, "OpenSSL"\)') 'Byte verification must use the available desktop SHA-256 implementation, not Unreal generic platform stub.'
	foreach ($Family in @('collision','rendering_suitability','texture','material','skeletal_animation','map_world','navigation','reference_boundary')) {
		Assert-True ($ScannerText -match [regex]::Escape($Family)) "Scanner must derive and report family '$Family'."
	}
	Assert-True ($ScannerText -notmatch 'GetMutableDefault|SavePackage|DeleteAsset|RenameAsset|Checkout|SourceControl') 'The scanner must remain read-only.'

	New-Item -ItemType Directory -Path $FixtureRoot -Force | Out-Null
	$FakeBin = Join-Path $FixtureRoot 'fake-bin'
	Build-Fakes $FakeBin
	$OriginalPath = $env:PATH
	$env:PATH = $FakeBin + [IO.Path]::PathSeparator + $OriginalPath

	$ReparseOutput = Invoke-Case -Name 'reparse-output' -FakeBin $FakeBin -OutputAttack 'reparse'
	Assert-True ($ReparseOutput.exitCode -ne 0 -and $ReparseOutput.output -match 'output_path_reparse' -and -not (Test-Path -LiteralPath $ReparseOutput.fixture.buildCapture)) 'A reparse-point output traversal must fail before cleanup or build launch.'
	$HardLinkOutput = Invoke-Case -Name 'hardlink-output' -FakeBin $FakeBin -OutputAttack 'policy-hardlink'
	Assert-True ($HardLinkOutput.exitCode -ne 0 -and $HardLinkOutput.output -match 'output_path_alias' -and -not (Test-Path -LiteralPath $HardLinkOutput.fixture.buildCapture)) 'A same-file output alias to a protected input must fail before cleanup or build launch.'
	$RetentionCap = Invoke-Case -Name 'retention-cap' -FakeBin $FakeBin -OutputAttack 'retention-cap'
	Assert-True ($RetentionCap.exitCode -ne 0 -and $RetentionCap.output -match 'output_guard_retention_budget_exceeded' -and
		(Get-Content -LiteralPath $RetentionCap.fixture.report -Raw) -ceq '{"stale":true}' -and
		-not (Test-Path -LiteralPath $RetentionCap.fixture.buildCapture)) "Retained artifact admission must fail before producer launch without erasing prior output. Output: $($RetentionCap.output)"
	$RetentionReserve = Invoke-Case -Name 'retention-reserve-six' -FakeBin $FakeBin -OutputAttack 'retention-reserve-six'
	Assert-True ($RetentionReserve.exitCode -ne 0 -and $RetentionReserve.output -match 'output_guard_retention_budget_exceeded' -and
		(Get-Content -LiteralPath $RetentionReserve.fixture.report -Raw) -ceq '{"stale":true}' -and
		-not (Test-Path -LiteralPath $RetentionReserve.fixture.buildCapture)) "Admission must reserve six retained entries for failed publication after all backups. Output: $($RetentionReserve.output)"
	$BackupByteCap = Invoke-Case -Name 'retention-backup-byte-cap' -FakeBin $FakeBin -OutputAttack 'retention-backup-byte-cap'
	Assert-True ($BackupByteCap.exitCode -ne 0 -and $BackupByteCap.output -match 'output_guard_retention_budget_exceeded' -and
		(Get-Content -LiteralPath $BackupByteCap.fixture.report -Raw) -ceq ('{"stale":"' + ('x' * 300) + '"}') -and
		-not (Test-Path -LiteralPath $BackupByteCap.fixture.buildCapture)) "Oversized prior canonical output must fail admission before build or backup copying. Output: $($BackupByteCap.output)"
	$MissingOutputDirectory = Invoke-Case -Name 'missing-output-directory' -FakeBin $FakeBin -OutputAttack 'missing-output-directory'
	Assert-True ($MissingOutputDirectory.exitCode -ne 0 -and $MissingOutputDirectory.output -match 'output_guard_directory_missing' -and
		-not (Test-Path -LiteralPath (Split-Path -Parent $MissingOutputDirectory.fixture.report)) -and
		-not (Test-Path -LiteralPath $MissingOutputDirectory.fixture.buildCapture)) "A missing output directory must fail closed without creating directories or launching the producer. Output: $($MissingOutputDirectory.output)"
	$RelativeOpenNormal = Invoke-Case -Name 'relative-open-normal' -FakeBin $FakeBin
	Assert-True ($RelativeOpenNormal.exitCode -eq 0 -and $null -ne $RelativeOpenNormal.report) "Relative pending-file creation must succeed without an attack. Output: $($RelativeOpenNormal.output)"
	$SpacedBuildPath = Invoke-Case -Name 'build path with spaces' -FakeBin $FakeBin
	$SpacedBuildArguments = if (Test-Path -LiteralPath $SpacedBuildPath.fixture.buildCapture) { [IO.File]::ReadAllLines($SpacedBuildPath.fixture.buildCapture) } else { @() }
	Assert-True ($SpacedBuildPath.exitCode -eq 0 -and $null -ne $SpacedBuildPath.report -and
		$SpacedBuildArguments.Count -eq 6 -and $SpacedBuildArguments[3] -ceq (Join-Path $SpacedBuildPath.fixture.repository 'AethelnOnline.uproject')) "The suspended cmd.exe launch must preserve exact Build.bat arguments when engine and project paths contain spaces. Output: $($SpacedBuildPath.output)"
	$Concurrent = Invoke-Case -Name 'concurrent-directory' -FakeBin $FakeBin -OutputAttack 'concurrent-directory'
	Assert-True ($Concurrent.secondExitCode -ne 0 -and $Concurrent.secondOutput -match 'output_guard_directory_busy' -and
		-not $Concurrent.secondStartedBuild -and $Concurrent.canonicalBeforeRelease -ceq '{"stale":true}' -and
		$Concurrent.exitCode -eq 0 -and $null -ne $Concurrent.report) "A second same-directory invocation must fail before build/publication while the first retains exclusive admission. second=$($Concurrent.secondExitCode) output=$($Concurrent.secondOutput) first=$($Concurrent.exitCode)"
	$HeldMount = Invoke-Case -Name 'mount-during-held-directory' -FakeBin $FakeBin -OutputAttack 'mount-during-held-directory'
	$HeldMountVictim = Join-Path $HeldMount.fixture.root 'outside-victim'
	$MountFailedClosed = $HeldMount.attackResult -ceq 'swapped' -and $HeldMount.exitCode -ne 0 -and $HeldMount.output -match 'output_guard_relative_create_failed' -and -not (Test-Path -LiteralPath $HeldMount.fixture.buildCapture)
	$MountBlocked = $HeldMount.attackResult -match '^blocked:' -and $HeldMount.exitCode -eq 0 -and $null -ne $HeldMount.report
	Assert-True (($MountFailedClosed -or $MountBlocked) -and
		$HeldMount.protectedHashAfter -ceq $HeldMount.protectedHashBefore -and
		@(Get-ChildItem -LiteralPath $HeldMountVictim -Force).Count -eq 1) "An in-place mount-point conversion after ancestor retention must be blocked or fail relative creation without outside mutation. attack=$($HeldMount.attackResult) output=$($HeldMount.output)"
	if ($HeldMount.attackResult -ceq 'swapped') { [IO.Directory]::Delete((Split-Path -Parent $HeldMount.fixture.report)) }
	Assert-True ($HeldMount.protectedHashAfter -ceq (Get-Sha256 (Join-Path $HeldMountVictim 'sentinel.txt'))) 'Removing the test-owned mount-point link must leave its outside victim intact.'
	$script:KeepUnsafeFixtureRoot = $false
	$PreCreateSwap = Invoke-Case -Name 'swap-before-directory-create' -FakeBin $FakeBin -OutputAttack 'swap-before-directory-create'
	Assert-True ($PreCreateSwap.exitCode -ne 0 -and $PreCreateSwap.attackResult -ceq 'alias_installed' -and $PreCreateSwap.output -match 'output_path_reparse' -and
		-not (Test-Path -LiteralPath (Join-Path $PreCreateSwap.fixture.root 'outside-victim\new')) -and
		$PreCreateSwap.protectedHashAfter -ceq $PreCreateSwap.protectedHashBefore -and -not (Test-Path -LiteralPath $PreCreateSwap.fixture.buildCapture)) "A synchronized parent swap before missing output-directory creation must not create outside directories. attack=$($PreCreateSwap.attackResult) output=$($PreCreateSwap.output)"
	$PreCleanupSwap = Invoke-Case -Name 'swap-pre-cleanup-directory' -FakeBin $FakeBin -OutputAttack 'swap-pre-cleanup-directory'
	$VictimDirectory = Join-Path $PreCleanupSwap.fixture.root 'outside-victim'
	$VictimLogsIntact = (Get-Content -LiteralPath (Join-Path $VictimDirectory 'content-validation.log') -Raw) -ceq 'outside previous commandlet log' -and
		(Get-Content -LiteralPath (Join-Path $VictimDirectory 'editor-build.log') -Raw) -ceq 'outside previous build log'
	Assert-True ($PreCleanupSwap.exitCode -ne 0 -and $PreCleanupSwap.attackResult -ceq 'alias_installed' -and $PreCleanupSwap.protectedHashAfter -ceq $PreCleanupSwap.protectedHashBefore -and $VictimLogsIntact -and -not (Test-Path -LiteralPath $PreCleanupSwap.fixture.buildCapture)) "A synchronized pre-cleanup directory swap must preserve all outside victim bytes and fail before build launch. attack=$($PreCleanupSwap.attackResult) output=$($PreCleanupSwap.output)"
	foreach ($OutputAttack in @('swap-build-log','swap-report','swap-commandlet-log','swap-output-directory')) {
		$Swap = Invoke-Case -Name $OutputAttack -FakeBin $FakeBin -OutputAttack $OutputAttack
		$RejectedAlias = $Swap.exitCode -ne 0 -and $Swap.attackResult -ceq 'alias_installed' -and $Swap.output -match 'output_path_alias'
		$BlockedSwap = $Swap.exitCode -eq 0 -and $Swap.attackResult -match '^alias_blocked:'
		Assert-True (($RejectedAlias -or $BlockedSwap) -and $Swap.protectedHashAfter -ceq $Swap.protectedHashBefore) "Synchronized $OutputAttack must be rejected or blocked while preserving protected bytes. exit=$($Swap.exitCode) attack=$($Swap.attackResult) output=$($Swap.output)"
	}

	$Success = Invoke-Case 'success' $FakeBin
	Assert-True ($Success.exitCode -eq 0) "Valid content scan wrapper failed: $($Success.output)"
	Assert-True ($null -ne $Success.report -and [int]$Success.report.schema_version -eq 2 -and $Success.report.result -ceq 'non_promotion') 'A valid report-v2 scan with TBD budgets must preserve non_promotion.'
	$ReferenceFamily = @($Success.report.assets[0].family_results | Where-Object { $_.policy_id -ceq 'reference_boundary' })[0]
	Assert-True (($ReferenceFamily.PSObject.Properties.Name -join ',') -ceq 'policy_id,applicability,deterministic_status,promotion_status,evidence,check_results' -and $ReferenceFamily.deterministic_status -ceq 'passed' -and $ReferenceFamily.promotion_status -ceq 'non_promotion') 'Family results must use the closed deterministic and promotion report-v2 contract.'
	Assert-True (@($ReferenceFamily.check_results).Count -eq 6 -and ($ReferenceFamily.check_results[0].PSObject.Properties.Name -join ',') -ceq 'check_id,applicability,deterministic_status,promotion_status,evidence') 'Family results must contain one closed result per policy check.'
	Assert-True ($Success.report.revision -ceq $SourceRevision) 'The report must bind the exact repository revision.'
	Assert-True ($Success.report.execution_provenance.repository_clean -eq $true) 'The report must attest a clean repository boundary.'
	Assert-True ($Success.report.execution_provenance.engine_revision -ceq $PinnedEngineRevision -and $Success.report.execution_provenance.engine_tag -ceq $PinnedEngineTag) 'The report must bind the pinned engine revision and tag.'
	Assert-True ($Success.report.policy_sha256 -ceq (Get-Sha256 (Join-Path $Success.fixture.repository 'Config\ContentValidation\asset-intake-policy.json'))) 'The report must bind the exact policy bytes.'
	Assert-True ($Success.report.intake_sha256 -ceq (Get-Sha256 (Join-Path $Success.fixture.repository 'Config\ContentValidation\runtime-asset-intake.json'))) 'The report must bind the exact intake bytes.'
	Assert-True ($Success.report.execution_provenance.compiler_version -ceq '14.44.35228' -and $Success.report.execution_provenance.compiler_sha256 -ceq (Get-Sha256 $Success.fixture.compiler)) 'The report must bind the compiler identity derived from the exact UBT build log.'
	Assert-True ($Success.report.execution_provenance.resource_compiler_version -ceq '10.0.26100.0' -and $Success.report.execution_provenance.resource_compiler_sha256 -ceq (Get-Sha256 $Success.fixture.resourceCompiler)) 'The report must bind the resource-compiler identity derived from the exact UBT build log.'
	$BuildArguments = [IO.File]::ReadAllLines($Success.fixture.buildCapture)
	$ExpectedBuildArguments = @('AethelnOnlineEditor','Win64','Development',(Join-Path $Success.fixture.repository 'AethelnOnline.uproject'),'-WaitMutex','-NoHotReloadFromIDE')
	Assert-True (($BuildArguments -join [char]0) -ceq ($ExpectedBuildArguments -join [char]0)) 'The wrapper must run the exact approved Editor build argument vector before validation.'
	$ExpectedBuildCommandSha256 = Get-TextSha256 ([string]::Join([char]0, @($Success.fixture.build) + $ExpectedBuildArguments))
	Assert-True ($Success.report.execution_provenance.editor_build_command_sha256 -ceq $ExpectedBuildCommandSha256) 'The report must bind the exact Editor build command.'
	Assert-True ($Success.report.execution_provenance.editor_build_log_sha256 -ceq (Get-Sha256 $Success.fixture.buildLog) -and (Get-Content -LiteralPath $Success.fixture.buildLog -Raw) -notmatch 'stale build log') 'The report must bind the fresh exact Editor build log.'

	$ReceiptEvidence = $Success.report.execution_provenance.target_receipt
	$ManifestEvidence = $Success.report.execution_provenance.module_manifest
	Assert-True (($ReceiptEvidence.PSObject.Properties.Name -join ',') -ceq 'path,size_bytes,sha256,build_id') 'The target receipt evidence must be a closed object.'
	Assert-True (($ManifestEvidence.PSObject.Properties.Name -join ',') -ceq 'path,size_bytes,sha256,build_id') 'The module manifest evidence must be a closed object.'
	Assert-True ($ReceiptEvidence.path -ceq 'Binaries/Win64/AethelnOnlineEditor.target' -and [int64]$ReceiptEvidence.size_bytes -eq (Get-Item -LiteralPath $Success.fixture.receipt).Length -and $ReceiptEvidence.sha256 -ceq (Get-Sha256 $Success.fixture.receipt)) 'The report must bind the exact canonical target receipt.'
	Assert-True ($ManifestEvidence.path -ceq 'Binaries/Win64/UnrealEditor.modules' -and [int64]$ManifestEvidence.size_bytes -eq (Get-Item -LiteralPath $Success.fixture.manifest).Length -and $ManifestEvidence.sha256 -ceq (Get-Sha256 $Success.fixture.manifest)) 'The report must bind the exact canonical project module manifest.'
	$LoadedModules = @($Success.report.execution_provenance.loaded_project_modules)
	Assert-True ($LoadedModules.Count -eq 2 -and $LoadedModules[0].name -ceq 'GameCore' -and $LoadedModules[1].name -ceq 'GameTests') 'Loaded project modules must be exactly GameCore then GameTests.'
	Assert-True (($LoadedModules[0].PSObject.Properties.Name -join ',') -ceq 'name,path,size_bytes,sha256,build_id' -and ($LoadedModules[1].PSObject.Properties.Name -join ',') -ceq 'name,path,size_bytes,sha256,build_id') 'Loaded project module evidence must use closed objects.'
	Assert-True ($LoadedModules[0].path -ceq 'Binaries/Win64/UnrealEditor-GameCore.dll' -and [int64]$LoadedModules[0].size_bytes -eq (Get-Item -LiteralPath $Success.fixture.gameCore).Length -and $LoadedModules[0].sha256 -ceq (Get-Sha256 $Success.fixture.gameCore)) 'GameCore evidence must bind the exact built module.'
	Assert-True ($LoadedModules[1].path -ceq 'Binaries/Win64/UnrealEditor-GameTests.dll' -and [int64]$LoadedModules[1].size_bytes -eq (Get-Item -LiteralPath $Success.fixture.gameTests).Length -and $LoadedModules[1].sha256 -ceq (Get-Sha256 $Success.fixture.gameTests)) 'GameTests evidence must bind the exact built module.'
	$BuildIds = @($ReceiptEvidence.build_id,$ManifestEvidence.build_id,$LoadedModules[0].build_id,$LoadedModules[1].build_id)
	Assert-True (@($BuildIds | Select-Object -Unique).Count -eq 1 -and -not [string]::IsNullOrWhiteSpace($BuildIds[0])) 'Receipt, manifest, and loaded modules must share one nonblank build ID.'

	$CapturedArguments = [IO.File]::ReadAllLines($Success.fixture.editorCapture)
	Assert-True ($CapturedArguments[1] -ceq '-run=GameTests.AethelnContentValidation') 'The wrapper must invoke the project commandlet explicitly.'
	foreach ($Prefix in @('-Report=', '-ReportFileIdentity=', '-ReportHandle=', '-Policy=', '-Intake=', '-Revision=', '-EngineRevision=', '-EngineTag=', '-EngineBinarySha256=', '-BuildVersionSha256=', '-EditorBuildCommandSha256=', '-EditorBuildLogSha256=', '-CompilerVersion=', '-CompilerSha256=', '-ResourceCompilerVersion=', '-ResourceCompilerSha256=', '-TargetReceiptPath=', '-TargetReceiptSizeBytes=', '-TargetReceiptSha256=', '-TargetReceiptBuildId=', '-ModuleManifestPath=', '-ModuleManifestSizeBytes=', '-ModuleManifestSha256=', '-ModuleManifestBuildId=', '-ProjectSha256=', '-PolicySha256=', '-IntakeSha256=', '-InvocationSha256=', '-StartedUtc=', '-RegistrySource=live_asset_registry')) {
		Assert-True (@($CapturedArguments | Where-Object { $_.StartsWith($Prefix, [StringComparison]::Ordinal) }).Count -eq 1) "The commandlet argument '$Prefix' must occur exactly once."
	}

	$Snapshot = Invoke-Case 'snapshot' $FakeBin 'success' 'clean' $true $true
	Assert-True ($Snapshot.exitCode -eq 0 -and $Snapshot.report.execution_provenance.registry_source -ceq 'test_snapshot') "Explicitly authorized test snapshot failed: $($Snapshot.output)"
	$SnapshotArguments = [IO.File]::ReadAllLines($Snapshot.fixture.editorCapture)
	Assert-True (@($SnapshotArguments | Where-Object { $_ -ceq '-AllowTestRegistrySnapshot' }).Count -eq 1) 'The guarded snapshot marker must reach the commandlet.'
	Assert-True (@($SnapshotArguments | Where-Object { $_.StartsWith('-RegistrySnapshot=', [StringComparison]::Ordinal) }).Count -eq 1) 'The exact snapshot path must reach the commandlet.'
	$SwapRestore = Invoke-Case 'snapshot-swap-restore' $FakeBin 'snapshot-swap-restore' 'clean' $true $true
	Assert-True ($SwapRestore.exitCode -ne 0 -and $SwapRestore.output -match 'exit code 33' -and (Get-Content -LiteralPath $SwapRestore.fixture.report -Raw) -ceq '{"stale":true}' -and (Get-Sha256 $SwapRestore.snapshot) -ceq $SwapRestore.snapshotSha256) "A synchronized snapshot swap must fail on digest mismatch while preserving the previous report. exit=$($SwapRestore.exitCode) output=$($SwapRestore.output)"
	$SnapshotDigestArguments = @($SnapshotArguments | Where-Object { $_.StartsWith('-RegistrySnapshotSha256=', [StringComparison]::Ordinal) })
	Assert-True ($SnapshotDigestArguments.Count -eq 1 -and $SnapshotDigestArguments[0].Substring('-RegistrySnapshotSha256='.Length) -ceq $Snapshot.snapshotSha256) 'The guarded snapshot invocation must bind the captured lowercase snapshot SHA-256 exactly once.'
	$InvocationArgument = @($SnapshotArguments | Where-Object { $_.StartsWith('-InvocationSha256=', [StringComparison]::Ordinal) })[0]
	$InvocationIndex = [Array]::IndexOf($SnapshotArguments, $InvocationArgument)
	Assert-True ($InvocationIndex -gt 0 -and $InvocationArgument.Substring('-InvocationSha256='.Length) -ceq (Get-TextSha256 ([string]::Join([char]0, $SnapshotArguments[0..($InvocationIndex - 1)])))) 'InvocationSha256 must cover the snapshot digest argument.'
	$LiveArguments = [IO.File]::ReadAllLines($Success.fixture.editorCapture)
	Assert-True (@($LiveArguments | Where-Object { $_.StartsWith('-RegistrySnapshot=', [StringComparison]::Ordinal) -or $_.StartsWith('-RegistrySnapshotSha256=', [StringComparison]::Ordinal) -or $_ -ceq '-AllowTestRegistrySnapshot' }).Count -eq 0) 'Live-registry mode must emit no snapshot-only invocation members.'

	$UnguardedSnapshot = Invoke-Case 'unguarded-snapshot' $FakeBin 'success' 'clean' $true $false
	Assert-True ($UnguardedSnapshot.exitCode -ne 0 -and -not (Test-Path -LiteralPath $UnguardedSnapshot.fixture.buildCapture) -and -not (Test-Path -LiteralPath $UnguardedSnapshot.fixture.editorCapture)) 'A snapshot path without explicit test authorization must fail before build or editor launch.'

	foreach ($Case in @(@('dirty','success','dirty','clean repository'), @('tag-mismatch','success','tag-mismatch','engine tag'), @('head-mismatch','success','engine-head-mismatch','engine revision'))) {
		$Run = Invoke-Case $Case[0] $FakeBin $Case[1] $Case[2]
		Assert-True ($Run.exitCode -ne 0 -and $Run.output -match $Case[3]) "$($Case[0]) must fail closed with an actionable diagnostic. Output: $($Run.output)"
		Assert-True (-not (Test-Path -LiteralPath $Run.fixture.buildCapture) -and -not (Test-Path -LiteralPath $Run.fixture.editorCapture)) "$($Case[0]) must fail before build or editor launch."
	}

	foreach ($Case in @(
		@('build-nonzero','nonzero','Editor build failed'),
		@('silent-build-log','silent-success','positive size'),
		@('missing-toolchain','missing-toolchain','toolchain identity'),
		@('duplicate-toolchain','duplicate-toolchain','toolchain identity'),
		@('missing-compiler','missing-compiler','compiler'),
		@('missing-resource-compiler','missing-resource-compiler','resource compiler'),
		@('missing-receipt','missing-receipt','target receipt'),
		@('corrupt-receipt','corrupt-receipt','target receipt.*valid JSON'),
		@('wrong-receipt-target','wrong-receipt-target','target receipt identity'),
		@('missing-manifest','missing-manifest','module manifest'),
		@('corrupt-manifest','corrupt-manifest','module manifest.*valid JSON'),
		@('receipt-build-id','receipt-build-id-mismatch','build ID'),
		@('manifest-build-id','manifest-build-id-mismatch','build ID'),
		@('missing-game-tests-entry','missing-game-tests-entry','GameTests'),
		@('escaping-module-path','escaping-module-path','canonical'),
		@('missing-game-core','missing-game-core','GameCore'),
		@('zero-game-core','zero-game-core','positive size'))) {
		$Run = Invoke-Case -Name $Case[0] -FakeBin $FakeBin -BuildCase $Case[1]
		Assert-True ($Run.exitCode -ne 0 -and $Run.output -match $Case[2]) "$($Case[0]) must fail closed before editor launch. Output: $($Run.output)"
		Assert-True (-not (Test-Path -LiteralPath $Run.fixture.editorCapture)) "$($Case[0]) must not launch the editor."
	}
	$BuildFailure = Invoke-Case -Name 'stale-build-failure' -FakeBin $FakeBin -BuildCase 'nonzero'
	Assert-True ($BuildFailure.exitCode -ne 0 -and (Get-Content -LiteralPath $BuildFailure.fixture.report -Raw) -ceq '{"stale":true}' -and (Get-Content -LiteralPath $BuildFailure.fixture.commandletLog -Raw) -ceq 'stale commandlet log' -and (Get-Content -LiteralPath $BuildFailure.fixture.buildLog -Raw) -ceq 'stale build log') 'A failed build must leave previous report and logs intact, never accepting them as new evidence.'
	$BuildFlood = Invoke-Case -Name 'build-output-flood' -FakeBin $FakeBin -BuildCase 'output-flood'
	$FloodLogs = @(Get-ChildItem -LiteralPath (Split-Path -Parent $BuildFlood.fixture.buildLog) -Filter '.editor-build.*.pending' -File)
	Assert-True ($BuildFlood.exitCode -ne 0 -and $BuildFlood.output -match 'build_output_limit_exceeded' -and
		$FloodLogs.Count -eq 1 -and $FloodLogs[0].Length -gt 0 -and $FloodLogs[0].Length -le 16MB -and
		(Get-Content -LiteralPath $BuildFlood.fixture.report -Raw) -ceq '{"stale":true}' -and
		(Get-Content -LiteralPath $BuildFlood.fixture.commandletLog -Raw) -ceq 'stale commandlet log' -and
		(Get-Content -LiteralPath $BuildFlood.fixture.buildLog -Raw) -ceq 'stale build log') "A verbose build must be stopped at the bounded captured-log budget and preserve previous evidence. Output: $($BuildFlood.output)"
	$BuildChildFlood = $null
	$BuildChildFixtureRoot = Join-Path $FixtureRoot 'build-child-flood'
	try {
		$BuildChildFlood = Invoke-Case -Name 'build-child-flood' -FakeBin $FakeBin -BuildCase 'child-flood'
		$BuildChildPid = if (Test-Path -LiteralPath $BuildChildFlood.fixture.buildChildPid) { [int](Get-Content -LiteralPath $BuildChildFlood.fixture.buildChildPid -Raw) } else { 0 }
		$ChildGone = $BuildChildPid -gt 0 -and $null -eq (Get-Process -Id $BuildChildPid -ErrorAction SilentlyContinue)
		$BuildChildLogs = @(Get-ChildItem -LiteralPath (Split-Path -Parent $BuildChildFlood.fixture.buildLog) -Filter '.editor-build.*.pending' -File)
		Assert-True ($BuildChildFlood.exitCode -ne 0 -and $BuildChildFlood.output -match 'build_output_limit_exceeded' -and
			$ChildGone -and -not (Test-Path -LiteralPath $BuildChildFlood.fixture.buildLateMarker) -and
			$BuildChildLogs.Count -eq 1 -and $BuildChildLogs[0].Length -le 16MB -and
			(Get-Content -LiteralPath $BuildChildFlood.fixture.report -Raw) -ceq '{"stale":true}' -and
			(Get-Content -LiteralPath $BuildChildFlood.fixture.commandletLog -Raw) -ceq 'stale commandlet log' -and
			(Get-Content -LiteralPath $BuildChildFlood.fixture.buildLog -Raw) -ceq 'stale build log') "Overflow must terminate a child-bearing build tree before returning. ChildGone=$ChildGone Output=$($BuildChildFlood.output)"
	}
	finally {
		foreach ($PidFile in @((Join-Path $BuildChildFixtureRoot 'build-child-pid.txt'), (Join-Path $BuildChildFixtureRoot 'build-parent-pid.txt'))) {
				if (Test-Path -LiteralPath $PidFile) {
					$OwnedTestProcessId = [int](Get-Content -LiteralPath $PidFile -Raw)
					$OwnedTestProcess = Get-Process -Id $OwnedTestProcessId -ErrorAction SilentlyContinue
					if ($null -ne $OwnedTestProcess) {
						Stop-Process -Id $OwnedTestProcessId -Force -ErrorAction SilentlyContinue
						try { $OwnedTestProcess.WaitForExit(2000) | Out-Null } catch { }
					}
				}
			}
	}
	$BuildChildTimeout = $null
	$BuildTimeoutFixtureRoot = Join-Path $FixtureRoot 'build-child-timeout'
	try {
		$BuildChildTimeout = Invoke-Case -Name 'build-child-timeout' -FakeBin $FakeBin -BuildCase 'child-timeout' -BuildTimeoutSeconds 2
		$BuildTimeoutChildId = if (Test-Path -LiteralPath $BuildChildTimeout.fixture.buildChildPid) { [int](Get-Content -LiteralPath $BuildChildTimeout.fixture.buildChildPid -Raw) } else { 0 }
		$TimeoutChildGone = $BuildTimeoutChildId -gt 0 -and $null -eq (Get-Process -Id $BuildTimeoutChildId -ErrorAction SilentlyContinue)
		$TimeoutBuildLogs = @(Get-ChildItem -LiteralPath (Split-Path -Parent $BuildChildTimeout.fixture.buildLog) -Filter '.editor-build.*.pending' -File)
		Assert-True ($BuildChildTimeout.exitCode -ne 0 -and $BuildChildTimeout.output -match 'build_timeout_exceeded' -and
			$TimeoutChildGone -and -not (Test-Path -LiteralPath $BuildChildTimeout.fixture.buildLateMarker) -and
			$TimeoutBuildLogs.Count -eq 1 -and $TimeoutBuildLogs[0].Length -le 16MB -and
			(Get-Content -LiteralPath $BuildChildTimeout.fixture.report -Raw) -ceq '{"stale":true}' -and
			(Get-Content -LiteralPath $BuildChildTimeout.fixture.commandletLog -Raw) -ceq 'stale commandlet log' -and
			(Get-Content -LiteralPath $BuildChildTimeout.fixture.buildLog -Raw) -ceq 'stale build log') "Build timeout must terminate a child-bearing build tree before returning. ChildGone=$TimeoutChildGone Output=$($BuildChildTimeout.output)"
	}
	finally {
		foreach ($PidFile in @((Join-Path $BuildTimeoutFixtureRoot 'build-child-pid.txt'), (Join-Path $BuildTimeoutFixtureRoot 'build-parent-pid.txt'))) {
			if (Test-Path -LiteralPath $PidFile) {
				$OwnedTestProcessId = [int](Get-Content -LiteralPath $PidFile -Raw)
				$OwnedTestProcess = Get-Process -Id $OwnedTestProcessId -ErrorAction SilentlyContinue
				if ($null -ne $OwnedTestProcess) {
					Stop-Process -Id $OwnedTestProcessId -Force -ErrorAction SilentlyContinue
					try { $OwnedTestProcess.WaitForExit(2000) | Out-Null } catch { }
				}
			}
		}
	}
	$BuildPumpFault = $null
	$BuildPumpFixtureRoot = Join-Path $FixtureRoot 'build-child-pump-fault'
	$OrdinaryPumpFixtureRoot = Join-Path $FixtureRoot 'ambient-pump-fault-ignored'
	try {
		$OrdinaryPump = Invoke-Case -Name 'ambient-pump-fault-ignored' -FakeBin $FakeBin -BuildCase 'child-pump-fault'
		Assert-True ($OrdinaryPump.exitCode -ne 0 -and $OrdinaryPump.output -match 'build_output_limit_exceeded' -and
			$OrdinaryPump.output -notmatch 'fixture_capture_pump_fault|build_cleanup_unproven') "An ambient test fault must be ignored without explicit snapshot authorization. Output=$($OrdinaryPump.output)"
		$BuildPumpFault = Invoke-Case -Name 'build-child-pump-fault' -FakeBin $FakeBin -BuildCase 'child-pump-fault' -UseSnapshot $true -AllowSnapshot $true
		$BuildPumpChildId = if (Test-Path -LiteralPath $BuildPumpFault.fixture.buildChildPid) { [int](Get-Content -LiteralPath $BuildPumpFault.fixture.buildChildPid -Raw) } else { 0 }
		$PumpChildGone = $BuildPumpChildId -gt 0 -and $null -eq (Get-Process -Id $BuildPumpChildId -ErrorAction SilentlyContinue)
		Assert-True ($BuildPumpFault.exitCode -ne 0 -and $BuildPumpFault.output -match 'build_capture_incomplete.*fixture_capture_pump_fault' -and
			$BuildPumpFault.output -notmatch 'build_cleanup_unproven' -and $PumpChildGone -and
			-not (Test-Path -LiteralPath $BuildPumpFault.fixture.buildLateMarker) -and
			(Get-Content -LiteralPath $BuildPumpFault.fixture.report -Raw) -ceq '{"stale":true}' -and
			(Get-Content -LiteralPath $BuildPumpFault.fixture.buildLog -Raw) -ceq 'stale build log') "A capture pump failure must terminate and prove the child-bearing job empty, then report capture failure without claiming cleanup unproven. ChildGone=$PumpChildGone Output=$($BuildPumpFault.output)"
	}
	finally {
		foreach ($PidFile in @((Join-Path $BuildPumpFixtureRoot 'build-child-pid.txt'), (Join-Path $BuildPumpFixtureRoot 'build-parent-pid.txt'), (Join-Path $OrdinaryPumpFixtureRoot 'build-child-pid.txt'), (Join-Path $OrdinaryPumpFixtureRoot 'build-parent-pid.txt'))) {
			if (Test-Path -LiteralPath $PidFile) {
				$OwnedTestProcessId = [int](Get-Content -LiteralPath $PidFile -Raw)
				$OwnedTestProcess = Get-Process -Id $OwnedTestProcessId -ErrorAction SilentlyContinue
				if ($null -ne $OwnedTestProcess) {
					Stop-Process -Id $OwnedTestProcessId -Force -ErrorAction SilentlyContinue
					try { $OwnedTestProcess.WaitForExit(2000) | Out-Null } catch { }
				}
			}
		}
	}
	$CommandletFlood = Invoke-Case -Name 'commandlet-log-flood' -FakeBin $FakeBin -EditorCase 'commandlet-log-flood'
	Assert-True ($CommandletFlood.exitCode -ne 0 -and $CommandletFlood.output -match 'commandlet_output_limit_exceeded|commandlet_log_limit_exceeded' -and
		(Get-Content -LiteralPath $CommandletFlood.fixture.report -Raw) -ceq '{"stale":true}' -and
		(Get-Content -LiteralPath $CommandletFlood.fixture.commandletLog -Raw) -ceq 'stale commandlet log') "Oversized commandlet logs must fail before unbounded read and preserve previous evidence. Output: $($CommandletFlood.output)"
	$ReportFlood = Invoke-Case -Name 'commandlet-report-flood' -FakeBin $FakeBin -EditorCase 'report-flood'
	Assert-True ($ReportFlood.exitCode -ne 0 -and $ReportFlood.output -match 'commandlet_output_limit_exceeded|content_report_limit_exceeded' -and
		(Get-Content -LiteralPath $ReportFlood.fixture.report -Raw) -ceq '{"stale":true}' -and
		(Get-Content -LiteralPath $ReportFlood.fixture.commandletLog -Raw) -ceq 'stale commandlet log') "Oversized commandlet reports must fail before unbounded read and preserve previous evidence. Output: $($ReportFlood.output)"
	$PublishFailure = Invoke-Case -Name 'publication-rollback' -FakeBin $FakeBin -OutputAttack 'publish-fail-after-first'
	Assert-True ($PublishFailure.exitCode -ne 0 -and $PublishFailure.output -match 'prior outputs were restored' -and
		(Get-Content -LiteralPath $PublishFailure.fixture.report -Raw) -ceq '{"stale":true}' -and
		(Get-Content -LiteralPath $PublishFailure.fixture.commandletLog -Raw) -ceq 'stale commandlet log' -and
		(Get-Content -LiteralPath $PublishFailure.fixture.buildLog -Raw) -ceq 'stale build log') "A failure after the first rename must restore all prior published report and log bytes. Output: $($PublishFailure.output)"
	$FirstRunPublicationFailure = Invoke-Case -Name 'publication-first-run-rollback' -FakeBin $FakeBin -OutputAttack 'publish-fail-first-run'
	Assert-True ($FirstRunPublicationFailure.exitCode -ne 0 -and $FirstRunPublicationFailure.output -match 'prior outputs were restored' -and
		-not (Test-Path -LiteralPath $FirstRunPublicationFailure.fixture.report) -and
		-not (Test-Path -LiteralPath $FirstRunPublicationFailure.fixture.commandletLog) -and
		-not (Test-Path -LiteralPath $FirstRunPublicationFailure.fixture.buildLog)) "A first-run failure after the first rename must remove only its own published entry and leave no canonical output. Output: $($FirstRunPublicationFailure.output)"

	foreach ($Case in @(@('missing-report','missing-report','did not produce'), @('corrupt','corrupt','valid JSON'), @('policy-mismatch','policy-mismatch','policy_sha256'), @('intake-mismatch','intake-mismatch','intake_sha256'), @('nonzero','nonzero-no-report','exit code'), @('nonzero-with-report','nonzero-with-report','exit code'))) {
		$Run = Invoke-Case $Case[0] $FakeBin $Case[1]
		Assert-True ($Run.exitCode -ne 0 -and $Run.output -match $Case[2]) "$($Case[0]) must fail closed with an actionable diagnostic. Output: $($Run.output)"
	}
	foreach ($Case in @(@('unknown-field','unknown-report-field','unsupported field'), @('provenance','provenance-mismatch','provenance.source_record'), @('lifecycle','lifecycle-mismatch','lifecycle_evidence does not match'), @('check-field','check-report-extra-field','check contains unsupported\s+field'), @('family-aggregate','family-aggregate-mismatch','deterministic_status does not\s+aggregate'), @('failed-eligible','failed-eligible','failed check.*must be non_promotion'), @('finding-code','finding-code-mismatch','policy code'), @('result','result-mismatch','result is inconsistent'))) {
		$Run = Invoke-Case $Case[0] $FakeBin $Case[1]
		Assert-True ($Run.exitCode -ne 0 -and $Run.output -match $Case[2]) "$($Case[0]) malformed report must fail closed. Output: $($Run.output)"
	}
	foreach ($Case in @(@('receipt-extra','receipt-report-extra-field','target_receipt contains unsupported field'), @('module-order','module-report-order-mismatch','loaded_project_modules'), @('module-hash','module-report-hash-mismatch','GameCore'), @('module-build-id','module-report-build-id-mismatch','build ID'))) {
		$Run = Invoke-Case $Case[0] $FakeBin $Case[1]
		Assert-True ($Run.exitCode -ne 0 -and $Run.output -match $Case[2]) "$($Case[0]) report provenance must fail closed. Output: $($Run.output)"
	}

	$Drift = Invoke-Case 'repository-drift' $FakeBin 'repository-drift'
	Assert-True ($Drift.exitCode -ne 0 -and $Drift.output -match 'changed during') "Repository drift must invalidate the report. Output: $($Drift.output)"
	$PolicyDrift = Invoke-Case 'policy-file-drift' $FakeBin 'policy-file-drift'
	Assert-True ($PolicyDrift.exitCode -ne 0 -and $PolicyDrift.output -match 'Asset intake policy changed during') "Policy byte drift must invalidate the report. Output: $($PolicyDrift.output)"
	$BuildInputDrift = Invoke-Case -Name 'build-project-drift' -FakeBin $FakeBin -BuildCase 'build-project-drift'
	Assert-True ($BuildInputDrift.exitCode -ne 0 -and $BuildInputDrift.output -match 'project descriptor changed during the editor build' -and -not (Test-Path -LiteralPath $BuildInputDrift.fixture.editorCapture)) "Same-path build-input drift must fail before editor launch. Output: $($BuildInputDrift.output)"
	foreach ($Case in @(@('module-file-drift','module-file-drift','GameCore.*changed during'), @('manifest-file-drift','manifest-file-drift','module manifest changed during'), @('build-log-drift','build-log-drift','output_guard_blocked_build_log_drift'))) {
		$Run = Invoke-Case $Case[0] $FakeBin $Case[1]
		Assert-True ($Run.exitCode -ne 0 -and $Run.output -match $Case[2]) "$($Case[0]) same-path launch drift must invalidate the report. Output: $($Run.output)"
	}
	$SnapshotDrift = Invoke-Case 'snapshot-file-drift' $FakeBin 'snapshot-file-drift' 'clean' $true $true
	Assert-True ($SnapshotDrift.exitCode -ne 0 -and $SnapshotDrift.output -match 'registry snapshot changed during') "Same-path snapshot drift must invalidate the report. Output: $($SnapshotDrift.output)"

	$Timeout = Invoke-Case 'timeout' $FakeBin 'timeout' 'clean' $false $false 1
	Assert-True ($Timeout.exitCode -ne 0 -and $Timeout.output -match 'timed out') "A commandlet timeout must fail closed. Output: $($Timeout.output)"
	Assert-True (Test-Path -LiteralPath $Timeout.fixture.childPid -PathType Leaf) 'The timeout fixture child process was not observed.'
	$ChildProcessId = [int](Get-Content -LiteralPath $Timeout.fixture.childPid -Raw)
	for ($Attempt = 0; $Attempt -lt 30 -and $null -ne (Get-Process -Id $ChildProcessId -ErrorAction SilentlyContinue); $Attempt++) { Start-Sleep -Milliseconds 100 }
	Assert-True ($null -eq (Get-Process -Id $ChildProcessId -ErrorAction SilentlyContinue)) 'The commandlet child process survived timeout cleanup.'

	Write-Output 'PASS: content-validation commandlet and wrapper contracts are fail closed'
}
finally {
	if ($null -ne (Get-Variable OriginalPath -ErrorAction SilentlyContinue)) { $env:PATH = $OriginalPath }
	foreach ($Name in @('AETHELN_CONTENT_FAKE_BUILD_CAPTURE','AETHELN_CONTENT_FAKE_BUILD_CASE','AETHELN_CONTENT_FAKE_COMPILER_ROOT','AETHELN_CONTENT_FAKE_SDK_ROOT','AETHELN_CONTENT_FAKE_CAPTURE','AETHELN_CONTENT_FAKE_CHILD_PID','AETHELN_CONTENT_FAKE_EDITOR_CASE','AETHELN_CONTENT_FAKE_GIT_CASE','AETHELN_CONTENT_FAKE_DRIFT','AETHELN_CONTENT_TEST_BUILD_PUMP_FAULT')) {
		Remove-Item ("Env:$Name") -ErrorAction SilentlyContinue
	}
	if (-not $script:KeepUnsafeFixtureRoot -and (Test-Path -LiteralPath $FixtureRoot)) { Remove-Item -LiteralPath $FixtureRoot -Recurse -Force }
}
