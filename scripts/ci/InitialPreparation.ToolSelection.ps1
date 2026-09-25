# Local final-evidence parser, not a build runner or aggregate acceptance gate.
. (Join-Path $PSScriptRoot 'InitialPreparation.Core.ps1')

function Get-InitialPreparationToolSelection {
	[CmdletBinding()]
	param([Parameter(Mandatory)] $Attempt, [Parameter(Mandatory)][object[]] $Builds,
		[Parameter(Mandatory)][string] $EvidenceRoot, [Parameter(Mandatory)][string] $CompilerPath,
		[Parameter(Mandatory)][string] $ResourceCompilerPath,
		[Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{64}$')][string] $InputDigest,
		[scriptblock] $OnProgress = {})
	Assert-InitialPreparationAttempt -Attempt $Attempt
	$CallerSelectionProgress = $OnProgress
	$Progress = {
		# Parsing/freeze is evidence work inside the ORIGINAL publication window.
		if ((Get-InitialPreparationTick) -ge $Attempt.publicationDeadlineTicks) { throw 'tool_selection_deadline' }
		& $CallerSelectionProgress | Out-Null
	}
	& $Progress
	if ($Builds.Count -ne 6) { throw 'tool_selection_build_invalid' }
	for ($Index = 0; $Index -lt 6; $Index++) {
		$Build = $Builds[$Index]
		foreach ($Name in @('ordinal', 'pair', 'target', 'platform', 'configuration', 'targetRevision', 'inputDigest', 'nativeExitCode', 'cleanupVerified')) {
			if ($null -eq $Build -or $Build.PSObject.Properties.Name -cnotcontains $Name) { throw 'tool_selection_build_invalid' }
		}
		foreach ($Name in @('ordinal', 'pair', 'nativeExitCode')) {
			if ($Build.$Name -isnot [int] -and $Build.$Name -isnot [long]) { throw 'tool_selection_build_invalid' }
		}
		foreach ($Name in @('target', 'platform', 'configuration', 'targetRevision', 'inputDigest')) {
			if ($Build.$Name -isnot [string]) { throw 'tool_selection_build_invalid' }
		}
		$ExpectedTarget = if ($Index % 2 -eq 0) { 'AethelnOnlineClient' } else { 'AethelnOnlineServer' }
		$ExpectedPlatform = if ($Index % 2 -eq 0) { 'Win64' } else { 'Linux' }
		if ($Build.ordinal -ne $Index + 1 -or $Build.pair -ne [Math]::Floor($Index / 2) + 1 -or
			$Build.target -cne $ExpectedTarget -or $Build.platform -cne $ExpectedPlatform -or $Build.configuration -cne 'Development' -or
			$Build.targetRevision -cne $Attempt.targetRevision -or $Build.inputDigest -cne $InputDigest -or
			$Build.nativeExitCode -ne 0 -or $Build.cleanupVerified -isnot [bool] -or -not $Build.cleanupVerified) { throw 'tool_selection_build_invalid' }
		if ($Build.PSObject.Properties.Name -ccontains 'status' -and ($Build.status -isnot [string] -or $Build.status -cne 'passed')) { throw 'tool_selection_build_invalid' }
		foreach ($Name in @('infrastructureFailure', 'failureCode')) {
			if ($Build.PSObject.Properties.Name -ccontains $Name -and $null -ne $Build.$Name) { throw 'tool_selection_build_invalid' }
		}
		foreach ($Name in @('skipped', 'cancelled')) {
			if ($Build.PSObject.Properties.Name -ccontains $Name -and ($Build.$Name -isnot [bool] -or $Build.$Name)) { throw 'tool_selection_build_invalid' }
		}
	}
	foreach ($Path in @($EvidenceRoot, $CompilerPath, $ResourceCompilerPath)) {
		if ($Path -notmatch '^[A-Za-z]:[\\/]' -or $Path.Length -gt 4096 -or $Path.Substring(2).Contains(':') -or $Path -match '["\x00-\x1f]') { throw 'tool_selection_path_invalid' }
	}
	$CompilerPath = [IO.Path]::GetFullPath($CompilerPath)
	$ResourceCompilerPath = [IO.Path]::GetFullPath($ResourceCompilerPath)
	if ($CompilerPath -notmatch '^(?<root>.+[\\/]MSVC[\\/]14\.44\.35207)[\\/]bin[\\/]Hostx64[\\/]x64[\\/]cl\.exe$') { throw 'tool_selection_path_invalid' }
	$ToolDirectory = $Matches.root.TrimEnd('\', '/')
	if ($ResourceCompilerPath -notmatch '^(?<root>.+)[\\/]bin[\\/]10\.0\.26100\.0[\\/]x64[\\/]rc\.exe$') { throw 'tool_selection_path_invalid' }
	$SdkDirectory = $Matches.root.TrimEnd('\', '/')
	Initialize-InitialPreparationJob
	if (-not ('Aetheln.ToolSelectionLog' -as [type])) {
		Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;
using System.Security.Cryptography;
namespace Aetheln {
 public sealed class ToolSelectionLog {
  public string Sha256, ToolDirectory, SdkDirectory, CompilerVersion;
  public long Bytes;
  public int SelectionCount, NoActionsCount;
  public bool PositiveActions;
  // The selected installation directory is 14.44.35207; its pinned compiler
  // product reports 14.44.35228. Do not substitute one identity for the other.
  static readonly Regex Selection = new Regex(@"^Using Visual Studio 2022 (?<version>14\.44\.35228) toolchain \((?<tool>[^\r\n]{1,4096})\) and Windows 10\.0\.26100\.0 SDK \((?<sdk>[^\r\n]{1,4096})\)\.$", RegexOptions.CultureInvariant, TimeSpan.FromMilliseconds(100));
  // ISPC is a separate auxiliary diagnostic, not evidence of primary C++
  // compiler selection or an attestation of the auxiliary executable.
  static readonly Regex AuxiliaryIspc = new Regex(@"^Using ISPC compiler \([A-Za-z]:[\\/][^\r\n<>:""|?*\x00-\x1f]{1,4096}[\\/]Engine[\\/]Source[\\/]ThirdParty[\\/]Intel[\\/]ISPC[\\/]bin[\\/]Windows[\\/]ispc\.exe\)$", RegexOptions.CultureInvariant, TimeSpan.FromMilliseconds(100));
  static readonly Regex Actions = new Regex(@"^Using .{1,512} executor to run (?<count>[0-9]{1,10}) action\(s\)$", RegexOptions.CultureInvariant, TimeSpan.FromMilliseconds(100));
  void Line(string line) {
   line=line.TrimEnd('\r');
   Match selection=Selection.Match(line);
   if(selection.Success) {
    SelectionCount++;
    ToolDirectory=selection.Groups["tool"].Value;
    SdkDirectory=selection.Groups["sdk"].Value;
    CompilerVersion=selection.Groups["version"].Value;
   } else if(line.StartsWith("Using ",StringComparison.Ordinal) && !AuxiliaryIspc.IsMatch(line) &&
      (line.Contains(" toolchain (") || line.Contains(" compiler (") || line.Contains(" runtime (") || line.Contains(" SDK ("))) {
    throw new InvalidDataException("tool_selection_contradictory");
   }
   if(line=="Target is up to date") NoActionsCount++;
   Match actions=Actions.Match(line);
   if(line.StartsWith("Using ",StringComparison.Ordinal) && line.Contains(" executor to run ")) {
    int actionCount;
    if(!actions.Success || !Int32.TryParse(actions.Groups["count"].Value,
      System.Globalization.NumberStyles.None, System.Globalization.CultureInfo.InvariantCulture, out actionCount))
     throw new InvalidDataException("tool_selection_actions_invalid");
    if(actionCount>0) PositiveActions=true;
   }
   if(SelectionCount>1 || NoActionsCount>1) throw new InvalidDataException("tool_selection_duplicate");
  }
  public static ToolSelectionLog Parse(Stream source, Action progress) {
   if(source.Length<1 || source.Length>16777216) throw new InvalidDataException("tool_selection_log_limit");
   ToolSelectionLog result=new ToolSelectionLog();
   byte[] bytes=new byte[65536]; char[] chars=new char[65537];
   Decoder decoder=new UTF8Encoding(false,true).GetDecoder();
   StringBuilder line=new StringBuilder(); bool first=true;
   using(SHA256 hash=SHA256.Create()) {
    int count;
    do {
     progress(); count=source.Read(bytes,0,bytes.Length);
     result.Bytes+=count;
     if(result.Bytes>16777216) throw new InvalidDataException("tool_selection_log_limit");
     if(count>0) hash.TransformBlock(bytes,0,count,bytes,0);
     int characters=decoder.GetChars(bytes,0,count,chars,0,count==0);
     for(int index=0;index<characters;index++) {
      char ch=chars[index];
      if(first) { first=false; if(ch=='\uFEFF') continue; }
      if(ch=='\n') { result.Line(line.ToString()); line.Clear(); }
      else { if(line.Length>=16384) throw new InvalidDataException("tool_selection_line_limit"); line.Append(ch); }
     }
    } while(count>0);
    if(line.Length>0) result.Line(line.ToString());
    hash.TransformFinalBlock(new byte[0],0,0);
    result.Sha256=BitConverter.ToString(hash.Hash).Replace("-","").ToLowerInvariant();
   }
   progress(); return result;
  }
 }
}
'@
	}
	$Records = New-Object Collections.ArrayList
	$Pins = New-Object Collections.ArrayList
	$Streams = New-Object Collections.ArrayList
	try {
		foreach ($Pair in @(1, 2, 3)) {
			& $Progress
			$Relative = 'builds/build-' + $Pair + '-Win64/build.log'
			$LogPath = Join-Path $EvidenceRoot $Relative
			Assert-InitialPreparationPlainPath -Path $LogPath -Reason 'tool_selection_path_invalid'
			foreach ($Pin in (Get-InitialPreparationDirectoryPin -Directory (Split-Path -Parent $LogPath))) { [void] $Pins.Add($Pin) }
			$Stream = New-Object IO.FileStream([Aetheln.PreparationDirectory]::OpenSource($LogPath), [IO.FileAccess]::Read)
			[void] $Streams.Add($Stream)
			$Parsed = [Aetheln.ToolSelectionLog]::Parse($Stream, [Action] $Progress)
			$Basis = 'observed'
			if ($Parsed.SelectionCount -eq 1) {
				foreach ($Directory in @($Parsed.ToolDirectory, $Parsed.SdkDirectory)) {
					if ($Directory -notmatch '^[A-Za-z]:[\\/]' -or $Directory.Substring(2).Contains(':')) { throw 'tool_selection_mismatch' }
				}
				if ($Parsed.NoActionsCount -ne 0 -or
					-not [string]::Equals([IO.Path]::GetFullPath($Parsed.ToolDirectory).TrimEnd('\', '/'), $ToolDirectory, [StringComparison]::OrdinalIgnoreCase) -or
					-not [string]::Equals([IO.Path]::GetFullPath($Parsed.SdkDirectory).TrimEnd('\', '/'), $SdkDirectory, [StringComparison]::OrdinalIgnoreCase)) { throw 'tool_selection_mismatch' }
			} else {
				# Pinned BuildMode prints diagnostics only for nonempty action sets;
				# ActionGraph prints this exact marker for zero actions. A repeat can
				# reference the first observed selection, never invent new consumption.
				if ($Pair -eq 1 -or $Parsed.NoActionsCount -ne 1 -or $Parsed.PositiveActions) { throw 'tool_selection_unproven' }
				$Basis = 'no_actions_same_input'
			}
			[void] $Records.Add([pscustomobject]@{ ordinal = 2 * $Pair - 1; pair = $Pair; target = 'AethelnOnlineClient'; platform = 'Win64';
				basis = $Basis; toolchainObserved = ($Basis -ceq 'observed'); anchorOrdinal = 1;
				toolchainDirectory = $ToolDirectory; selectionDirectoryVersion = '14.44.35207'; windowsSdkDirectory = $SdkDirectory;
				compilerVersion = $(if ($Basis -ceq 'observed') { $Parsed.CompilerVersion } else { $null }); windowsSdkVersion = '10.0.26100.0';
				log = $Relative; logSha256 = $Parsed.Sha256; logBytes = $Parsed.Bytes })
		}
		$Manifest = [ordered]@{ schemaVersion = 1; scope = 'windows_primary_tool_selection'; attemptId = $Attempt.attemptId;
			targetRevision = $Attempt.targetRevision; inputDigest = $InputDigest; verified = $true; baselineVerified = $false;
			compilerPath = $CompilerPath; resourceCompilerPath = $ResourceCompilerPath; records = @($Records) }
		$Bytes = [Text.Encoding]::UTF8.GetBytes(($Manifest | ConvertTo-Json -Depth 5 -Compress))
		if ($Bytes.Length -gt 65536) { throw 'tool_selection_manifest_limit' }
		$Hasher = [Security.Cryptography.SHA256]::Create()
		try { $Manifest['digest'] = ([BitConverter]::ToString($Hasher.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant() } finally { $Hasher.Dispose() }
		& $Progress
		return [pscustomobject] $Manifest
	} finally {
		foreach ($Stream in $Streams) { $Stream.Dispose() }
		foreach ($Pin in $Pins) { $Pin.Dispose() }
	}
}
