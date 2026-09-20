[CmdletBinding()]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'ContextJson', Justification = 'Consumed by the guarded script entrypoint.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'RequirementsJson', Justification = 'Consumed by the guarded script entrypoint.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'OutputPath', Justification = 'Consumed by the guarded script entrypoint.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'ApiBaseUri', Justification = 'Consumed by the guarded script entrypoint closure.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'DeadlineSeconds', Justification = 'Consumed by the guarded script entrypoint.')]
param(
	[string] $ContextJson,
	[string] $RequirementsJson,
	[string] $OutputPath,
	[string] $ApiBaseUri = 'https://api.github.com',
	[ValidateRange(10, 300)] [int] $DeadlineSeconds = 120
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:AggregateLimits = [ordered]@{
	apiResponseBytes = 8MB
	apiPages = 10
	apiItems = 1000
	archiveBytes = 32MB
	archiveEntries = 64
	archiveEntryBytes = 4MB
	archiveExpandedBytes = 16MB
	archiveCompressionRatio = 100
	jsonBytes = 4MB
	jsonDepth = 16
	jsonProperties = 2048
	jsonArrayItems = 1024
	requirements = 32
	evidencePerReceipt = 16
	pathCharacters = 240
}
$script:StrictUtf8 = New-Object System.Text.UTF8Encoding($false, $true)
$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$script:AcceptanceCheckIds = @('clean-package-provenance-smoke','content-reference-validation','controller-contract','controller-operational-proof','delivery-harness','native-client-server-compile','portable','unreal-editor-automation','visual-package')

function Initialize-StrictJsonGuard {
	if ('Aetheln.StrictJsonGuard' -as [type]) { return }
	$null = Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Text;
namespace Aetheln {
 public static class StrictJsonGuard {
  sealed class Parser {
   readonly string text; readonly int maxDepth, maxProperties, maxArrayItems;
   int index, properties, arrayItems;
   public Parser(string value, int depth, int propertyLimit, int arrayLimit) { text=value; maxDepth=depth; maxProperties=propertyLimit; maxArrayItems=arrayLimit; }
   void Fail(string reason) { throw new InvalidDataException(reason); }
   void White() { while (index < text.Length && (text[index]==' ' || text[index]=='\t' || text[index]=='\r' || text[index]=='\n')) index++; }
   bool Take(char value) { White(); if (index < text.Length && text[index] == value) { index++; return true; } return false; }
   void Need(char value) { if (!Take(value)) Fail("json_syntax_invalid"); }
   int Hex(char value) { if (value>='0'&&value<='9') return value-'0'; if (value>='a'&&value<='f') return value-'a'+10; if (value>='A'&&value<='F') return value-'A'+10; Fail("json_syntax_invalid"); return 0; }
   string StringValue() {
    White(); if (index >= text.Length || text[index++] != '"') Fail("json_syntax_invalid");
    var result = new StringBuilder();
    while (index < text.Length) {
     char current = text[index++];
     if (current == '"') return result.ToString();
     if (current < 0x20) Fail("json_syntax_invalid");
     if (current != '\\') { result.Append(current); continue; }
     if (index >= text.Length) Fail("json_syntax_invalid");
     char escape = text[index++];
     switch (escape) {
      case '"': result.Append('"'); break; case '\\': result.Append('\\'); break; case '/': result.Append('/'); break;
      case 'b': result.Append('\b'); break; case 'f': result.Append('\f'); break; case 'n': result.Append('\n'); break; case 'r': result.Append('\r'); break; case 't': result.Append('\t'); break;
      case 'u':
       if (index + 4 > text.Length) Fail("json_syntax_invalid");
       int code=(Hex(text[index])<<12)|(Hex(text[index+1])<<8)|(Hex(text[index+2])<<4)|Hex(text[index+3]); index+=4; result.Append((char)code); break;
      default: Fail("json_syntax_invalid"); break;
     }
    }
    Fail("json_syntax_invalid"); return null;
   }
   void Literal(string value) { if (index + value.Length > text.Length || String.CompareOrdinal(text,index,value,0,value.Length)!=0) Fail("json_syntax_invalid"); index += value.Length; }
   void Number() {
    int start=index; if (index<text.Length && text[index]=='-') index++;
    if (index>=text.Length) Fail("json_syntax_invalid");
    if (text[index]=='0') index++; else { if (text[index]<'1'||text[index]>'9') Fail("json_syntax_invalid"); while(index<text.Length&&text[index]>='0'&&text[index]<='9') index++; }
    if (index<text.Length&&text[index]=='.') { index++; int digits=index; while(index<text.Length&&text[index]>='0'&&text[index]<='9') index++; if(index==digits) Fail("json_syntax_invalid"); }
    if (index<text.Length&&(text[index]=='e'||text[index]=='E')) { index++; if(index<text.Length&&(text[index]=='+'||text[index]=='-')) index++; int digits=index; while(index<text.Length&&text[index]>='0'&&text[index]<='9') index++; if(index==digits) Fail("json_syntax_invalid"); }
    if (index==start) Fail("json_syntax_invalid");
   }
   void Value(int depth) {
    White(); if (index>=text.Length) Fail("json_syntax_invalid"); char current=text[index];
    if (current=='{') { ObjectValue(depth+1); return; } if(current=='[') { ArrayValue(depth+1); return; }
    if(current=='"') { StringValue(); return; } if(current=='t') { Literal("true"); return; } if(current=='f') { Literal("false"); return; } if(current=='n') { Literal("null"); return; }
    Number();
   }
   void ObjectValue(int depth) {
    if(depth>maxDepth) Fail("json_depth_limit"); Need('{'); var names=new HashSet<string>(StringComparer.Ordinal); if(Take('}')) return;
    while(true) { string name=StringValue(); if(!names.Add(name)) Fail("json_duplicate_property"); properties++; if(properties>maxProperties) Fail("json_property_limit"); Need(':'); Value(depth); if(Take('}')) return; Need(','); }
   }
   void ArrayValue(int depth) {
    if(depth>maxDepth) Fail("json_depth_limit"); Need('['); if(Take(']')) return;
    while(true) { arrayItems++; if(arrayItems>maxArrayItems) Fail("json_array_limit"); Value(depth); if(Take(']')) return; Need(','); }
   }
   public void Parse() { Value(0); White(); if(index!=text.Length) Fail("json_syntax_invalid"); }
  }
  public static void Validate(string value, int maxDepth, int maxProperties, int maxArrayItems) { new Parser(value,maxDepth,maxProperties,maxArrayItems).Parse(); }
 }
}
'@
}

function ConvertFrom-StrictBoundedJson {
	param(
		[Parameter(Mandatory)] [byte[]] $Bytes,
		[int] $MaximumBytes = $script:AggregateLimits.jsonBytes,
		[int] $MaximumDepth = $script:AggregateLimits.jsonDepth,
		[int] $MaximumProperties = $script:AggregateLimits.jsonProperties,
		[int] $MaximumArrayItems = $script:AggregateLimits.jsonArrayItems
	)
	if ($Bytes.Length -eq 0) { throw 'json_empty' }
	if ($Bytes.Length -gt $MaximumBytes) { throw 'json_size_limit' }
	try { $Raw = $script:StrictUtf8.GetString($Bytes) } catch { throw 'json_utf8_invalid' }
	Initialize-StrictJsonGuard
	try { [Aetheln.StrictJsonGuard]::Validate($Raw, $MaximumDepth, $MaximumProperties, $MaximumArrayItems) }
	catch { if ($_.Exception.InnerException) { throw $_.Exception.InnerException.Message }; throw $_.Exception.Message }
	try { return ($Raw | ConvertFrom-Json) } catch { throw 'json_syntax_invalid' }
}

function Assert-ClosedObject {
	param($Value, [string[]] $Names, [string] $Reason)
	if ($null -eq $Value -or $Value -isnot [pscustomobject]) { throw $Reason }
	$Actual = @($Value.PSObject.Properties.Name)
	if ($Actual.Count -ne $Names.Count) { throw $Reason }
	foreach ($Name in $Names) { if ($Actual -cnotcontains $Name) { throw $Reason } }
}

function Test-Revision($Value) { return $Value -is [string] -and $Value -cmatch '^[0-9a-f]{40}$' }
function Test-Sha256($Value) { return $Value -is [string] -and $Value -cmatch '^[0-9a-f]{64}$' }
function Test-DecimalIdentity($Value) {
	if ($Value -isnot [string] -or $Value -cnotmatch '^[1-9][0-9]{0,18}$') { return $false }
	[long] $Parsed = 0
	return [long]::TryParse($Value, [Globalization.NumberStyles]::None, [Globalization.CultureInfo]::InvariantCulture, [ref] $Parsed) -and $Parsed -gt 0
}
function Test-GitHubLogin($Value) { return $Value -is [string] -and $Value -cmatch '^[A-Za-z0-9][A-Za-z0-9_\-\[\]]{0,99}$' }

function Assert-SafeArchivePath {
	param([string] $Path)
	if ([string]::IsNullOrEmpty($Path) -or $Path.Length -gt $script:AggregateLimits.pathCharacters -or $Path -cnotmatch '^[A-Za-z0-9._/-]+$' -or $Path[0] -eq '/' -or $Path[-1] -eq '/' -or $Path.Contains('\') -or $Path.Contains(':')) { throw 'archive_path_invalid' }
	$Segments = @($Path.Split('/'))
	if ($Segments.Count -eq 0 -or @($Segments | Where-Object { $_ -ceq '' -or $_ -ceq '.' -or $_ -ceq '..' }).Count -ne 0) { throw 'archive_path_invalid' }
	if ($Path.Normalize([Text.NormalizationForm]::FormC) -cne $Path) { throw 'archive_path_not_nfc' }
}

function Get-Sha256Hex {
	param([byte[]] $Bytes)
	$Algorithm = [Security.Cryptography.SHA256]::Create()
	try { return ([BitConverter]::ToString($Algorithm.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant() }
	finally { $Algorithm.Dispose() }
}

function Read-StrictCiArchive {
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'The function validates and returns every archive entry.')]
	param(
		[Parameter(Mandatory)] [byte[]] $Bytes,
		[int] $MaximumBytes = $script:AggregateLimits.archiveBytes,
		[int] $MaximumEntries = $script:AggregateLimits.archiveEntries,
		[int] $MaximumEntryBytes = $script:AggregateLimits.archiveEntryBytes,
		[int] $MaximumExpandedBytes = $script:AggregateLimits.archiveExpandedBytes,
		[int] $MaximumCompressionRatio = $script:AggregateLimits.archiveCompressionRatio
	)
	if ($Bytes.Length -eq 0 -or $Bytes.Length -gt $MaximumBytes) { throw 'archive_size_limit' }
	Add-Type -AssemblyName System.IO.Compression
	Add-Type -AssemblyName System.IO.Compression.FileSystem
	$ArchiveStream = New-Object IO.MemoryStream(, $Bytes)
	try { $Archive = New-Object IO.Compression.ZipArchive($ArchiveStream, [IO.Compression.ZipArchiveMode]::Read, $false) }
	catch { $ArchiveStream.Dispose(); throw 'archive_invalid' }
	$Entries = New-Object System.Collections.Generic.List[object]
	$Names = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
	[long] $Expanded = 0
	try {
		if ($Archive.Entries.Count -eq 0 -or $Archive.Entries.Count -gt $MaximumEntries) { throw 'archive_entry_count_limit' }
		foreach ($Entry in $Archive.Entries) {
			$Name = [string] $Entry.FullName
			Assert-SafeArchivePath $Name
			$CollisionKey = $Name.Normalize([Text.NormalizationForm]::FormC)
			if (-not $Names.Add($CollisionKey)) { throw 'archive_path_collision' }
			$Attributes = [BitConverter]::ToUInt32([BitConverter]::GetBytes([int32] $Entry.ExternalAttributes), 0)
			$UnixType = ($Attributes -shr 16) -band 0xF000
			if (($UnixType -ne 0 -and $UnixType -ne 0x8000) -or ($Attributes -band 0x10) -ne 0) { throw 'archive_link_rejected' }
			if ($Entry.Length -lt 0 -or $Entry.Length -gt $MaximumEntryBytes) { throw 'archive_entry_size_limit' }
			if ($Expanded -gt ([long] $MaximumExpandedBytes - [long] $Entry.Length)) { throw 'archive_expanded_size_limit' }
			$Expanded += [long] $Entry.Length
			if ($Entry.Length -gt 0 -and ($Entry.CompressedLength -le 0 -or ([double] $Entry.Length / [double] $Entry.CompressedLength) -gt $MaximumCompressionRatio)) { throw 'archive_compression_ratio_limit' }
			$EntryStream = $Entry.Open()
			$Output = New-Object IO.MemoryStream
			try {
				$Buffer = New-Object byte[] 8192
				while (($Read = $EntryStream.Read($Buffer, 0, $Buffer.Length)) -gt 0) {
					if ($Output.Length + $Read -gt $MaximumEntryBytes -or $Output.Length + $Read -gt $Entry.Length) { throw 'archive_entry_size_limit' }
					$Output.Write($Buffer, 0, $Read)
				}
				if ($Output.Length -ne $Entry.Length) { throw 'archive_entry_size_mismatch' }
				$EntryBytes = $Output.ToArray()
			} finally { $Output.Dispose(); $EntryStream.Dispose() }
			$Entries.Add([pscustomobject][ordered]@{ name = $Name; bytes = $EntryBytes; sizeBytes = [long] $EntryBytes.Length; sha256 = Get-Sha256Hex $EntryBytes })
		}
	} finally { $Archive.Dispose(); $ArchiveStream.Dispose() }
	return [pscustomobject][ordered]@{ sha256 = Get-Sha256Hex $Bytes; sizeBytes = [long] $Bytes.Length; entries = $Entries.ToArray() }
}

function Assert-AcceptanceContext {
	param($Context)
	Assert-ClosedObject -Value $Context -Names @('schemaVersion','repository','event','source','workflow','actions','controller','policy','run') -Reason 'context_schema_invalid'
	if ($Context.schemaVersion -cne 'aetheln.ci-acceptance-context/v1') { throw 'context_schema_invalid' }
	Assert-ClosedObject -Value $Context.repository -Names @('fullName') -Reason 'context_schema_invalid'
	if ($Context.repository.fullName -isnot [string] -or $Context.repository.fullName -cnotmatch '^[A-Za-z0-9_.-]{1,100}/[A-Za-z0-9_.-]{1,100}$') { throw 'context_repository_invalid' }
	Assert-ClosedObject -Value $Context.event -Names @('kind','classification','actor','triggeringActor') -Reason 'context_schema_invalid'
	if (-not (Test-GitHubLogin $Context.event.actor) -or -not (Test-GitHubLogin $Context.event.triggeringActor)) { throw 'context_actor_invalid' }
	if ($Context.event.kind -ceq 'pull_request') { if ($Context.event.classification -cne 'pull_request_acceptance') { throw 'context_event_invalid' } }
	elseif ($Context.event.kind -ceq 'push') { if ($Context.event.classification -cne 'post_merge_hosted_health') { throw 'context_event_invalid' } }
	else { throw 'context_event_invalid' }
	Assert-ClosedObject -Value $Context.source -Names @('baseRevision','headRevision','testedRevision') -Reason 'context_schema_invalid'
	if (-not (Test-Revision $Context.source.baseRevision) -or -not (Test-Revision $Context.source.headRevision) -or -not (Test-Revision $Context.source.testedRevision) -or $Context.source.baseRevision -ceq $Context.source.headRevision) { throw 'context_revision_invalid' }
	Assert-ClosedObject -Value $Context.workflow -Names @('id','revision','parents','sha256') -Reason 'context_schema_invalid'
	if (-not (Test-DecimalIdentity $Context.workflow.id) -or -not (Test-Revision $Context.workflow.revision) -or -not (Test-Sha256 $Context.workflow.sha256) -or $Context.workflow.parents -isnot [array]) { throw 'context_workflow_invalid' }
	$Parents = @($Context.workflow.parents)
	if ($Parents.Count -lt 1 -or $Parents.Count -gt 2 -or @($Parents | Where-Object { -not (Test-Revision $_) }).Count -ne 0 -or @($Parents | Select-Object -Unique).Count -ne $Parents.Count -or $Parents[0] -cne $Context.source.baseRevision) { throw 'context_workflow_invalid' }
	if ($Context.event.kind -ceq 'pull_request' -and $Parents.Count -ne 2) { throw 'context_workflow_invalid' }
	if ($Context.event.kind -ceq 'pull_request' -and ($Parents[0] -cne $Context.source.baseRevision -or $Parents[1] -cne $Context.source.headRevision)) { throw 'context_workflow_invalid' }
	if ($Context.source.testedRevision -cne $Context.workflow.revision) { throw 'context_workflow_invalid' }
	Assert-ClosedObject -Value $Context.actions -Names @('manifestSha256','items') -Reason 'context_schema_invalid'
	if (-not (Test-Sha256 $Context.actions.manifestSha256) -or $Context.actions.items -isnot [array]) { throw 'context_actions_invalid' }
	$ActionItems = @($Context.actions.items)
	if ($ActionItems.Count -eq 0 -or $ActionItems.Count -gt 32) { throw 'context_actions_invalid' }
	$ActionNames = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
	$ActionLines = New-Object System.Collections.Generic.List[string]
	$PreviousAction = $null
	foreach ($Action in $ActionItems) {
		Assert-ClosedObject -Value $Action -Names @('uses','revision') -Reason 'context_schema_invalid'
		if ($Action.uses -isnot [string] -or $Action.uses -cnotmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)*$' -or -not (Test-Revision $Action.revision) -or -not $ActionNames.Add([string] $Action.uses)) { throw 'context_actions_invalid' }
		if ($null -ne $PreviousAction -and [StringComparer]::Ordinal.Compare($PreviousAction, [string] $Action.uses) -ge 0) { throw 'context_actions_not_sorted' }
		$PreviousAction = [string] $Action.uses
		$ActionLines.Add(([string] $Action.uses + '@' + [string] $Action.revision))
	}
	$ManifestBytes = $script:Utf8NoBom.GetBytes(($ActionLines.ToArray() -join "`n") + "`n")
	if ((Get-Sha256Hex $ManifestBytes) -cne $Context.actions.manifestSha256) { throw 'context_actions_manifest_mismatch' }
	Assert-ClosedObject -Value $Context.controller -Names @('revision','blobOid','sha256') -Reason 'context_schema_invalid'
	if (-not (Test-Revision $Context.controller.revision) -or -not (Test-Revision $Context.controller.blobOid) -or -not (Test-Sha256 $Context.controller.sha256)) { throw 'context_controller_invalid' }
	if ($Context.event.kind -ceq 'pull_request' -and $Context.controller.revision -cne $Context.source.baseRevision) { throw 'context_controller_not_accepted_base' }
	if ($Context.event.kind -ceq 'push' -and ($Context.controller.revision -cne $Context.source.headRevision -or $Context.source.testedRevision -cne $Context.source.headRevision -or $Context.workflow.revision -cne $Context.source.headRevision)) { throw 'context_push_identity_invalid' }
	Assert-ClosedObject -Value $Context.policy -Names @('version','digest') -Reason 'context_schema_invalid'
	if ($Context.policy.version -isnot [string] -or $Context.policy.version -cnotmatch '^[a-z0-9][a-z0-9._-]{0,63}$' -or -not (Test-Sha256 $Context.policy.digest)) { throw 'context_policy_invalid' }
	Assert-ClosedObject -Value $Context.run -Names @('id','attempt') -Reason 'context_schema_invalid'
	if (-not (Test-DecimalIdentity $Context.run.id) -or $Context.run.attempt -isnot [int] -or $Context.run.attempt -lt 1) { throw 'context_run_invalid' }
}

function Assert-AcceptanceRequirements {
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'The function validates the complete requirements collection.')]
	param($Requirements)
	Assert-ClosedObject -Value $Requirements -Names @('schemaVersion','jobs') -Reason 'requirements_schema_invalid'
	if ($Requirements.schemaVersion -cne 'aetheln.ci-acceptance-requirements/v1' -or $Requirements.jobs -isnot [array]) { throw 'requirements_schema_invalid' }
	$JobRequirements = @($Requirements.jobs)
	if ($JobRequirements.Count -eq 0 -or $JobRequirements.Count -gt $script:AggregateLimits.requirements) { throw 'requirements_count_invalid' }
	$Ids = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
	$Keys = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
	$Jobs = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
	$Artifacts = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
	$PreviousKey = $null
	foreach ($Job in $JobRequirements) {
		Assert-ClosedObject -Value $Job -Names @('key','jobName','selected','artifactName','checks') -Reason 'requirements_schema_invalid'
		if ($Job.key -isnot [string] -or $Job.key -cnotmatch '^[a-z0-9][a-z0-9-]{0,63}$' -or $Job.jobName -isnot [string] -or $Job.jobName.Length -lt 1 -or $Job.jobName.Length -gt 100 -or $Job.selected -isnot [bool] -or $Job.artifactName -isnot [string] -or $Job.artifactName -cnotmatch '^[A-Za-z0-9._-]{1,200}$' -or $Job.checks -isnot [array]) { throw 'requirements_identity_invalid' }
		if ($null -ne $PreviousKey -and [StringComparer]::Ordinal.Compare($PreviousKey, [string] $Job.key) -ge 0) { throw 'requirements_not_sorted' }
		$PreviousKey = [string] $Job.key
		if (-not $Keys.Add([string] $Job.key) -or -not $Jobs.Add(([string] $Job.jobName).Normalize([Text.NormalizationForm]::FormC)) -or -not $Artifacts.Add(([string] $Job.artifactName).Normalize([Text.NormalizationForm]::FormC))) { throw 'requirements_identity_collision' }
		$PreviousCheck = $null
		foreach ($CheckId in @($Job.checks)) {
			if ($CheckId -isnot [string] -or $script:AcceptanceCheckIds -cnotcontains $CheckId -or -not $Ids.Add($CheckId)) { throw 'requirements_check_invalid' }
			if ($null -ne $PreviousCheck -and [StringComparer]::Ordinal.Compare($PreviousCheck, $CheckId) -ge 0) { throw 'requirements_not_sorted' }
			$PreviousCheck = $CheckId
		}
		if (@($Job.checks).Count -eq 0) { throw 'requirements_check_invalid' }
	}
	if ($Ids.Count -ne $script:AcceptanceCheckIds.Count -or @($script:AcceptanceCheckIds | Where-Object { -not $Ids.Contains($_) }).Count -ne 0) { throw 'requirements_check_coverage_incomplete' }
}

function Assert-IdentityMatch {
	param($Receipt, $Context)
	foreach ($Root in @('repository','event','source','workflow','actions','controller','policy','run')) {
		$ReceiptJson = $Receipt.$Root | ConvertTo-Json -Depth 8 -Compress
		$ContextJson = $Context.$Root | ConvertTo-Json -Depth 8 -Compress
		if ($ReceiptJson -cne $ContextJson) { throw ('receipt_identity_mismatch:' + $Root) }
	}
}

function Assert-CiAcceptanceReceipt {
	param($Receipt, $Context, $Requirement, $Archive)
	Assert-ClosedObject -Value $Receipt -Names @('schemaVersion','repository','event','source','workflow','actions','controller','policy','run','selection','results','acceptance') -Reason 'receipt_schema_invalid'
	if ($Receipt.schemaVersion -cne 'aetheln.ci-acceptance-receipt/v1') { throw 'receipt_schema_invalid' }
	Assert-AcceptanceContext ([pscustomobject][ordered]@{ schemaVersion='aetheln.ci-acceptance-context/v1'; repository=$Receipt.repository; event=$Receipt.event; source=$Receipt.source; workflow=$Receipt.workflow; actions=$Receipt.actions; controller=$Receipt.controller; policy=$Receipt.policy; run=$Receipt.run })
	Assert-IdentityMatch $Receipt $Context
	Assert-ClosedObject -Value $Receipt.selection -Names @('checks') -Reason 'receipt_schema_invalid'
	if ($Receipt.selection.checks -isnot [array] -or (@($Receipt.selection.checks) -join "`n") -cne (@($Requirement.checks) -join "`n")) { throw 'receipt_selection_mismatch' }
	Assert-ClosedObject -Value $Receipt.results -Names @('checks') -Reason 'receipt_schema_invalid'
	if ($Receipt.results.checks -isnot [array] -or @($Receipt.results.checks).Count -ne @($Requirement.checks).Count) { throw 'receipt_results_invalid' }
	$ExpectedNames = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
	[void] $ExpectedNames.Add('ci-acceptance-receipt.json')
	$Results = @($Receipt.results.checks)
	for ($ResultIndex = 0; $ResultIndex -lt $Results.Count; $ResultIndex++) {
		$Result = $Results[$ResultIndex]
		Assert-ClosedObject -Value $Result -Names @('id','jobName','conclusion','nativeExitCode','infrastructureFailure','terminal','cleanupVerified','evidence') -Reason 'receipt_schema_invalid'
		if ($Result.id -cne $Requirement.checks[$ResultIndex] -or $Result.jobName -cne $Requirement.jobName) { throw 'receipt_result_identity_mismatch' }
		if ($Result.conclusion -cne 'success' -or $Result.terminal -isnot [bool] -or -not $Result.terminal -or $null -ne $Result.infrastructureFailure) { throw 'receipt_result_not_success' }
		if ($null -ne $Result.nativeExitCode -and ($Result.nativeExitCode -isnot [int] -or $Result.nativeExitCode -ne 0)) { throw 'receipt_native_exit_invalid' }
		if ($null -ne $Result.cleanupVerified -and $Result.cleanupVerified -isnot [bool]) { throw 'receipt_cleanup_invalid' }
		if ($Result.id -cin @('clean-package-provenance-smoke','native-client-server-compile') -and ($Result.nativeExitCode -ne 0 -or $Result.cleanupVerified -ne $true)) { throw 'receipt_native_proof_incomplete' }
		if ($Result.evidence -isnot [array]) { throw 'receipt_evidence_invalid' }
		$Evidence = @($Result.evidence)
		if ($Evidence.Count -eq 0 -or $Evidence.Count -gt $script:AggregateLimits.evidencePerReceipt) { throw 'receipt_evidence_invalid' }
		foreach ($Item in $Evidence) {
			Assert-ClosedObject -Value $Item -Names @('name','sha256','sizeBytes') -Reason 'receipt_schema_invalid'
			Assert-SafeArchivePath ([string] $Item.name)
			if ($Item.name -ceq 'ci-acceptance-receipt.json' -or -not (Test-Sha256 $Item.sha256) -or $Item.sizeBytes -isnot [long] -and $Item.sizeBytes -isnot [int] -or [long] $Item.sizeBytes -lt 0 -or -not $ExpectedNames.Add([string] $Item.name)) { throw 'receipt_evidence_invalid' }
			$Entry = @($Archive.entries | Where-Object { $_.name -ceq $Item.name })
			if ($Entry.Count -ne 1 -or $Entry[0].sha256 -cne $Item.sha256 -or $Entry[0].sizeBytes -ne [long] $Item.sizeBytes) { throw 'receipt_evidence_mismatch' }
		}
	}
	if ($Archive.entries.Count -ne $ExpectedNames.Count -or @($Archive.entries | Where-Object { -not $ExpectedNames.Contains($_.name) }).Count -ne 0) { throw 'archive_unexpected_entry' }
	Assert-ClosedObject -Value $Receipt.acceptance -Names @('shadow','authoritative','grantsAcceptance','terminal','infrastructureFailure','cleanupVerified') -Reason 'receipt_schema_invalid'
	foreach ($BooleanName in @('shadow','authoritative','grantsAcceptance','terminal','infrastructureFailure')) { if ($Receipt.acceptance.$BooleanName -isnot [bool]) { throw 'receipt_authority_invalid' } }
	if ($null -ne $Receipt.acceptance.cleanupVerified -and $Receipt.acceptance.cleanupVerified -isnot [bool]) { throw 'receipt_cleanup_invalid' }
	if ($Receipt.acceptance.shadow -ne $true -or $Receipt.acceptance.authoritative -ne $false -or $Receipt.acceptance.grantsAcceptance -ne $false -or $Receipt.acceptance.terminal -ne $true -or $Receipt.acceptance.infrastructureFailure -ne $false) { throw 'receipt_authority_invalid' }
	if (@($Requirement.checks | Where-Object { $_ -cin @('clean-package-provenance-smoke','native-client-server-compile') }).Count -ne 0 -and $Receipt.acceptance.cleanupVerified -ne $true) { throw 'receipt_cleanup_invalid' }
	return ,$Results
}

function Invoke-DefaultBoundedApiRequest {
	param([string] $Uri, [int] $RemainingMilliseconds, [int] $MaximumBytes, [string] $ApiBaseUri)
	if ($RemainingMilliseconds -le 0) { throw 'api_deadline_exceeded' }
	$Target = if ($Uri -cmatch '^https://') { $Uri } else { $ApiBaseUri.TrimEnd('/') + $Uri }
	if ($Target -cnotmatch '^https://') { throw 'api_uri_invalid' }
	$Request = [Net.HttpWebRequest]::CreateHttp($Target)
	$Request.Method = 'GET'
	$Request.Accept = 'application/vnd.github+json'
	$Request.UserAgent = 'aetheln-ci-acceptance-aggregate/1'
	$Request.Timeout = $RemainingMilliseconds
	$Request.ReadWriteTimeout = $RemainingMilliseconds
	$Request.AllowAutoRedirect = $true
	$Token = [Environment]::GetEnvironmentVariable('GITHUB_TOKEN')
	if ([string]::IsNullOrWhiteSpace($Token)) { throw 'github_token_unavailable' }
	$Request.Headers['Authorization'] = 'Bearer ' + $Token
	try { $Response = $Request.GetResponse() }
	catch { throw 'api_request_failed' }
	try {
		$Stream = $Response.GetResponseStream()
		$Output = New-Object IO.MemoryStream
		try {
			$Buffer = New-Object byte[] 8192
			while (($Read = $Stream.Read($Buffer, 0, $Buffer.Length)) -gt 0) {
				if ($Output.Length + $Read -gt $MaximumBytes) { throw 'api_response_size_limit' }
				$Output.Write($Buffer, 0, $Read)
			}
			return $Output.ToArray()
		} finally { $Output.Dispose(); $Stream.Dispose() }
	} finally { $Response.Dispose() }
}

function Get-RemainingMilliseconds {
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'The function returns one duration expressed in milliseconds.')]
	param([Diagnostics.Stopwatch] $Clock, [int] $DeadlineSeconds)
	$Remaining = ([long] $DeadlineSeconds * 1000L) - $Clock.ElapsedMilliseconds
	if ($Remaining -le 0) { throw 'api_deadline_exceeded' }
	return [int] [Math]::Min($Remaining, [int]::MaxValue)
}

function Invoke-AggregateApi {
	param([scriptblock] $ApiRequest, [string] $Uri, [Diagnostics.Stopwatch] $Clock, [int] $DeadlineSeconds, [int] $MaximumBytes)
	$Remaining = Get-RemainingMilliseconds $Clock $DeadlineSeconds
	$Bytes = & $ApiRequest $Uri $Remaining $MaximumBytes
	if ($Bytes -isnot [byte[]]) { throw 'api_response_type_invalid' }
	if ($Bytes.Length -gt $MaximumBytes) { throw 'api_response_size_limit' }
	return ,$Bytes
}

function Get-PagedApiItems {
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'The function returns all bounded items across pages.')]
	param([scriptblock] $ApiRequest, [string] $BaseUri, [string] $PropertyName, [Diagnostics.Stopwatch] $Clock, [int] $DeadlineSeconds)
	$Items = New-Object System.Collections.Generic.List[object]
	for ($Page = 1; $Page -le $script:AggregateLimits.apiPages; $Page++) {
		$Separator = if ($BaseUri.Contains('?')) { '&' } else { '?' }
		$Uri = $BaseUri + $Separator + 'per_page=100&page=' + $Page
		$Bytes = Invoke-AggregateApi -ApiRequest $ApiRequest -Uri $Uri -Clock $Clock -DeadlineSeconds $DeadlineSeconds -MaximumBytes $script:AggregateLimits.apiResponseBytes
		$Document = ConvertFrom-StrictBoundedJson -Bytes $Bytes -MaximumBytes $script:AggregateLimits.apiResponseBytes -MaximumDepth 32 -MaximumProperties 8192 -MaximumArrayItems $script:AggregateLimits.apiItems
		if ($null -eq $Document -or $Document.PSObject.Properties.Name -cnotcontains 'total_count' -or $Document.PSObject.Properties.Name -cnotcontains $PropertyName) { throw 'api_schema_invalid' }
		if ($Document.total_count -isnot [int] -and $Document.total_count -isnot [long] -or [long] $Document.total_count -lt 0 -or [long] $Document.total_count -gt $script:AggregateLimits.apiItems) { throw 'api_item_count_limit' }
		$PageItems = @($Document.$PropertyName)
		foreach ($Item in $PageItems) { if ($null -eq $Item -or $Item -isnot [pscustomobject]) { throw 'api_schema_invalid' }; $Items.Add($Item); if ($Items.Count -gt $script:AggregateLimits.apiItems) { throw 'api_item_count_limit' } }
		if ($Items.Count -gt [long] $Document.total_count) { throw 'api_pagination_count_mismatch' }
		if ($Items.Count -ge [long] $Document.total_count) { return ,$Items.ToArray() }
		if ($PageItems.Count -ne 100) { throw 'api_pagination_incomplete' }
	}
	throw 'api_page_limit'
}

function Assert-ApiJob {
	param($Job)
	if ($null -eq $Job -or $Job -isnot [pscustomobject]) { throw 'api_schema_invalid' }
	foreach ($Name in @('id','name','status','conclusion','run_attempt')) { if ($Job.PSObject.Properties.Name -cnotcontains $Name) { throw 'api_schema_invalid' } }
	if (($Job.id -isnot [int] -and $Job.id -isnot [long]) -or [long] $Job.id -le 0 -or $Job.name -isnot [string] -or [string]::IsNullOrWhiteSpace($Job.name) -or $Job.name.Length -gt 256 -or $Job.status -isnot [string] -or $Job.status -cnotin @('queued','in_progress','completed','waiting','requested','pending') -or ($null -ne $Job.conclusion -and $Job.conclusion -isnot [string]) -or $Job.run_attempt -isnot [int] -or $Job.run_attempt -lt 1) { throw 'api_job_schema_invalid' }
}

function New-CiAcceptanceAggregate {
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'The function constructs and returns an in-memory immutable report.')]
	param(
		[Parameter(Mandatory)] $Context,
		[Parameter(Mandatory)] $Requirements,
		[Parameter(Mandatory)] [scriptblock] $ApiRequest,
		[ValidateRange(10, 300)] [int] $DeadlineSeconds = 120
	)
	Assert-AcceptanceContext $Context
	Assert-AcceptanceRequirements $Requirements
	$Clock = [Diagnostics.Stopwatch]::StartNew()
	$RepositoryPath = $Context.repository.fullName
	$RunPath = '/repos/' + $RepositoryPath + '/actions/runs/' + $Context.run.id
	$RunBytes = Invoke-AggregateApi -ApiRequest $ApiRequest -Uri $RunPath -Clock $Clock -DeadlineSeconds $DeadlineSeconds -MaximumBytes $script:AggregateLimits.apiResponseBytes
	$Run = ConvertFrom-StrictBoundedJson -Bytes $RunBytes -MaximumBytes $script:AggregateLimits.apiResponseBytes -MaximumDepth 32 -MaximumProperties 8192 -MaximumArrayItems $script:AggregateLimits.apiItems
	foreach ($Name in @('id','run_attempt','workflow_id','event','head_sha')) { if ($Run.PSObject.Properties.Name -cnotcontains $Name) { throw 'api_schema_invalid' } }
	if ([string] $Run.id -cne $Context.run.id -or [string] $Run.workflow_id -cne $Context.workflow.id -or $Run.event -cne $Context.event.kind -or $Run.head_sha -cne $Context.source.headRevision) { throw 'run_identity_mismatch' }
	if ($Run.run_attempt -isnot [int] -or $Run.run_attempt -gt $Context.run.attempt) { throw 'run_attempt_stale' }
	if ($Run.run_attempt -lt $Context.run.attempt) { throw 'run_attempt_unavailable' }

	$WorkflowRunsBase = '/repos/' + $RepositoryPath + '/actions/workflows/' + $Context.workflow.id + '/runs?event=' + $Context.event.kind + '&head_sha=' + $Context.source.headRevision
	$WorkflowRuns = Get-PagedApiItems -ApiRequest $ApiRequest -BaseUri $WorkflowRunsBase -PropertyName 'workflow_runs' -Clock $Clock -DeadlineSeconds $DeadlineSeconds
	$CurrentIndex = -1
	for ($Index = 0; $Index -lt $WorkflowRuns.Count; $Index++) { if ([string] $WorkflowRuns[$Index].id -ceq $Context.run.id) { $CurrentIndex = $Index; break } }
	if ($CurrentIndex -lt 0) { throw 'workflow_run_not_listed' }
	if ($CurrentIndex -ne 0) { throw 'newer_workflow_run_observed' }

	$AttemptJobsBase = $RunPath + '/attempts/' + $Context.run.attempt + '/jobs'
	$AttemptJobs = Get-PagedApiItems -ApiRequest $ApiRequest -BaseUri $AttemptJobsBase -PropertyName 'jobs' -Clock $Clock -DeadlineSeconds $DeadlineSeconds
	$AllJobs = Get-PagedApiItems -ApiRequest $ApiRequest -BaseUri ($RunPath + '/jobs?filter=all') -PropertyName 'jobs' -Clock $Clock -DeadlineSeconds $DeadlineSeconds
	foreach ($HistoricalJob in $AllJobs) { Assert-ApiJob -Job $HistoricalJob }
	$ObservedJobs = New-Object System.Collections.Generic.List[object]
	foreach ($Requirement in $Requirements.jobs) {
		$JobMatches = @($AttemptJobs | Where-Object { $_.name -ceq $Requirement.jobName })
		if ($JobMatches.Count -eq 0) { throw 'partial_rerun_missing_job' }
		if ($JobMatches.Count -ne 1) { throw 'job_identity_ambiguous' }
		$Job = $JobMatches[0]
		Assert-ApiJob -Job $Job
		if ($Job.run_attempt -ne $Context.run.attempt) { throw 'job_attempt_mismatch' }
		$ExpectedConclusion = if ($Requirement.selected) { 'success' } else { 'skipped' }
		if ($Job.status -cne 'completed' -or $Job.conclusion -cne $ExpectedConclusion) { throw 'job_conclusion_not_expected' }
		$Historical = @($AllJobs | Where-Object { $_.name -ceq $Requirement.jobName })
		if ($Historical.Count -eq 0) { throw 'job_history_missing' }
		$Highest = ($Historical | Measure-Object -Property run_attempt -Maximum).Maximum
		if ($Highest -gt $Context.run.attempt) { throw 'newer_job_attempt_observed' }
		if ($Highest -lt $Context.run.attempt) { throw 'partial_rerun_missing_job' }
		$ObservedJobs.Add([pscustomobject][ordered]@{ key = [string] $Requirement.key; id = [string] $Job.id; name = [string] $Job.name; selected = [bool] $Requirement.selected; checks = @($Requirement.checks); attempt = [int] $Job.run_attempt; conclusion = [string] $Job.conclusion })
	}

	$Artifacts = Get-PagedApiItems -ApiRequest $ApiRequest -BaseUri ($RunPath + '/artifacts') -PropertyName 'artifacts' -Clock $Clock -DeadlineSeconds $DeadlineSeconds
	$Receipts = New-Object System.Collections.Generic.List[object]
	foreach ($Requirement in $Requirements.jobs) {
		$ArtifactMatches = @($Artifacts | Where-Object { $_.name -ceq $Requirement.artifactName })
		if (-not $Requirement.selected) {
			if ($ArtifactMatches.Count -ne 0) { throw 'unselected_artifact_observed' }
			continue
		}
		if ($ArtifactMatches.Count -ne 1) { throw 'artifact_identity_ambiguous' }
		$Artifact = $ArtifactMatches[0]
		foreach ($Name in @('id','name','size_in_bytes','archive_download_url','expired','workflow_run')) { if ($Artifact.PSObject.Properties.Name -cnotcontains $Name) { throw 'api_schema_invalid' } }
		if ($Artifact.expired -ne $false -or $Artifact.workflow_run.id -ne [long] $Context.run.id -or $Artifact.workflow_run.head_sha -cne $Context.source.headRevision) { throw 'artifact_identity_mismatch' }
		if ($Artifact.size_in_bytes -isnot [int] -and $Artifact.size_in_bytes -isnot [long] -or [long] $Artifact.size_in_bytes -le 0 -or [long] $Artifact.size_in_bytes -gt $script:AggregateLimits.archiveBytes) { throw 'artifact_size_invalid' }
		if ($Artifact.archive_download_url -isnot [string] -or $Artifact.archive_download_url -cnotmatch '^https://') { throw 'artifact_url_invalid' }
		$ArchiveBytes = Invoke-AggregateApi -ApiRequest $ApiRequest -Uri ([string] $Artifact.archive_download_url) -Clock $Clock -DeadlineSeconds $DeadlineSeconds -MaximumBytes $script:AggregateLimits.archiveBytes
		$Archive = Read-StrictCiArchive -Bytes $ArchiveBytes
		$ReceiptEntries = @($Archive.entries | Where-Object { $_.name -ceq 'ci-acceptance-receipt.json' })
		if ($ReceiptEntries.Count -ne 1) { throw 'receipt_entry_missing' }
		$Receipt = ConvertFrom-StrictBoundedJson -Bytes $ReceiptEntries[0].bytes
		$Results = Assert-CiAcceptanceReceipt -Receipt $Receipt -Context $Context -Requirement $Requirement -Archive $Archive
		$Receipts.Add([pscustomobject][ordered]@{
			jobKey = [string] $Requirement.key
			checks = @($Requirement.checks)
			artifactId = [string] $Artifact.id
			artifactName = [string] $Artifact.name
			archiveSha256 = [string] $Archive.sha256
			archiveSizeBytes = [long] $Archive.sizeBytes
			receiptSha256 = [string] $ReceiptEntries[0].sha256
			nativeExitCodes = @($Results | ForEach-Object { $_.nativeExitCode })
			cleanupVerified = @($Results | ForEach-Object { $_.cleanupVerified })
		})
	}
	$EvidenceClass = if ($Context.event.kind -ceq 'push') { 'post_merge_hosted_health' } else { 'pull_request_acceptance_candidate' }
	return [pscustomobject][ordered]@{
		schemaVersion = 'aetheln.ci-acceptance-aggregate/v1'
		repository = $Context.repository
		event = $Context.event
		source = $Context.source
		workflow = $Context.workflow
		actions = $Context.actions
		controller = $Context.controller
		policy = $Context.policy
		run = $Context.run
		jobs = $ObservedJobs.ToArray()
		receipts = $Receipts.ToArray()
		decision = [pscustomobject][ordered]@{ evidenceClass = $EvidenceClass; complete = $true; shadow = $true; authoritative = $false; grantsAcceptance = $false; reason = 'shadow_evidence_reconciled' }
	}
}

function Write-BoundedAggregate {
	param($Aggregate, [string] $Path)
	if ([string]::IsNullOrWhiteSpace($Path)) { throw 'output_path_required' }
	$FullPath = [IO.Path]::GetFullPath($Path)
	$Parent = Split-Path -Parent $FullPath
	if (-not (Test-Path -LiteralPath $Parent -PathType Container)) { throw 'output_parent_missing' }
	$Raw = $Aggregate | ConvertTo-Json -Depth 16 -Compress
	$Bytes = $script:Utf8NoBom.GetBytes($Raw)
	if ($Bytes.Length -gt $script:AggregateLimits.jsonBytes) { throw 'aggregate_size_limit' }
	$Stream = New-Object IO.FileStream($FullPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
	try { $Stream.Write($Bytes, 0, $Bytes.Length); $Stream.Flush($true) }
	finally { $Stream.Dispose() }
	return [long] $Bytes.Length
}

function Invoke-CiAcceptanceAggregateMain {
	if ([string]::IsNullOrWhiteSpace($ContextJson) -or [string]::IsNullOrWhiteSpace($RequirementsJson) -or [string]::IsNullOrWhiteSpace($OutputPath)) { throw 'aggregate_arguments_required' }
	$Context = ConvertFrom-StrictBoundedJson -Bytes $script:StrictUtf8.GetBytes($ContextJson)
	$Requirements = ConvertFrom-StrictBoundedJson -Bytes $script:StrictUtf8.GetBytes($RequirementsJson)
	$Request = { param([string] $Uri, [int] $RemainingMilliseconds, [int] $MaximumBytes) Invoke-DefaultBoundedApiRequest -Uri $Uri -RemainingMilliseconds $RemainingMilliseconds -MaximumBytes $MaximumBytes -ApiBaseUri $ApiBaseUri }.GetNewClosure()
	$Aggregate = New-CiAcceptanceAggregate -Context $Context -Requirements $Requirements -ApiRequest $Request -DeadlineSeconds $DeadlineSeconds
	[void] (Write-BoundedAggregate $Aggregate $OutputPath)
	return $Aggregate
}

if ($MyInvocation.InvocationName -ne '.') { Invoke-CiAcceptanceAggregateMain }
