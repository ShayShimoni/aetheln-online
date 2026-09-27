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
	apiRequests = 40
	networkBytes = 64MB
	archiveBytes = 32MB
	archiveCumulativeBytes = 64MB
	archiveEntries = 64
	archiveEntryBytes = 4MB
	archiveExpandedBytes = 16MB
	archiveExpandedCumulativeBytes = 32MB
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
$script:AttemptAnchorSchema = 'aetheln.current-attempt-anchor/v1'
$script:AcceptanceCheckIds = @('clean-package-provenance-smoke','content-reference-validation','controller-contract','controller-operational-proof','delivery-harness','native-client-server-compile','portable','unreal-editor-automation','visual-package')
$script:SelectorCheckIds = @('portable','visual-package','delivery-harness','native-client-server-compile','unreal-editor-automation','content-reference-validation','controller-contract','controller-operational-proof','clean-package-provenance-smoke')
# Opaque hashes and receipt summaries never establish success. Add an
# obligation from here only after its evidence bytes have an exact semantic parser.
$script:AcceptanceUnsupportedCheckIds = @('clean-package-provenance-smoke','content-reference-validation','controller-contract','controller-operational-proof','delivery-harness')
$script:AcceptancePortableCheckNames = @(
	'formatting-policy','markdown-links','source-control-policy','observability-contract','build-packaged-artifacts-tests','packaged-smoke-test-tests','network-authority-spike-tests','engine-runner-gate-tests','unreal-automation-tests','server-cook-reference-tests','target-composition-tests','build-provenance-tests','markdown-link-tests','formatting-policy-tests','observability-contract-tests','ci-suite-tests','engine-runner-post-command-state-tests','prototype-quality-workflow-tests','visual-package-evidence-tests','runner-scheduling-policy-tests','ci-selection-tests','ci-acceptance-receipt-tests','ci-acceptance-aggregate-tests','ci-activation-candidate-tests','compile-workspace-tests','engine-host-lease-tests','managed-compile-registration-tests','managed-compile-workspace-tests','managed-compile-integration-tests','routine-compile-deadline-tests','routine-compile-resources-tests','routine-compile-command-tests','routine-compile-gate-tests','psscriptanalyzer'
)

function New-AggregateBudget {
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Constructs an in-memory accounting object only.')]
	param(
		[long]$MaximumRequests = $script:AggregateLimits.apiRequests,
		[long]$MaximumNetworkBytes = $script:AggregateLimits.networkBytes,
		[long]$MaximumArchiveBytes = $script:AggregateLimits.archiveCumulativeBytes,
		[long]$MaximumExpandedBytes = $script:AggregateLimits.archiveExpandedCumulativeBytes
	)
	foreach($Value in @($MaximumRequests,$MaximumNetworkBytes,$MaximumArchiveBytes,$MaximumExpandedBytes)){if($Value-lt 1){throw 'aggregate_budget_invalid'}}
	return [pscustomobject][ordered]@{maximumRequests=$MaximumRequests;maximumNetworkBytes=$MaximumNetworkBytes;maximumArchiveBytes=$MaximumArchiveBytes;maximumExpandedBytes=$MaximumExpandedBytes;requests=0L;networkBytes=0L;archiveBytes=0L;expandedBytes=0L}
}

function Add-AggregateBudgetUsage {
	param($Budget,[ValidateSet('request','network','archive','expanded')][string]$Kind,[long]$Amount)
	if($null-eq$Budget){return};if($Amount-lt 0){throw 'aggregate_budget_invalid'}
	$Field=switch($Kind){'request'{'requests'}'network'{'networkBytes'}'archive'{'archiveBytes'}'expanded'{'expandedBytes'}}
	$MaximumField=switch($Kind){'request'{'maximumRequests'}'network'{'maximumNetworkBytes'}'archive'{'maximumArchiveBytes'}'expanded'{'maximumExpandedBytes'}}
	$Reason=switch($Kind){'request'{'api_request_budget_exceeded'}'network'{'network_byte_budget_exceeded'}'archive'{'archive_byte_budget_exceeded'}'expanded'{'archive_expanded_byte_budget_exceeded'}}
	if($Budget.PSObject.Properties.Name-cnotcontains$Field-or$Budget.PSObject.Properties.Name-cnotcontains$MaximumField-or$Budget.$Field-gt([long]$Budget.$MaximumField-$Amount)){throw $Reason}
	$Budget.$Field=[long]$Budget.$Field+$Amount
}

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
	try {
		$ConvertCommand = Get-Command -Name ConvertFrom-Json -ErrorAction Stop
		if ($ConvertCommand.Parameters.ContainsKey('DateKind')) { return ConvertFrom-Json -InputObject $Raw -DateKind String }
		return ConvertFrom-Json -InputObject $Raw
	} catch { throw 'json_syntax_invalid' }
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

function Assert-AttemptAnchor {
	param($Anchor, $Run, [string] $Reason)
	Assert-ClosedObject -Value $Anchor -Names @('schemaVersion','runId','runAttempt','nonce') -Reason $Reason
	if ($Anchor.schemaVersion -isnot [string] -or $Anchor.schemaVersion -cne $script:AttemptAnchorSchema -or
		-not (Test-DecimalIdentity $Anchor.runId) -or $Anchor.runAttempt -isnot [int] -or $Anchor.runAttempt -lt 1 -or
		$Anchor.nonce -isnot [string] -or $Anchor.nonce -cnotmatch '^[0-9a-f]{64}$' -or $Anchor.nonce -cmatch '^0{64}$' -or
		$Anchor.runId -cne $Run.id -or $Anchor.runAttempt -ne $Run.attempt) { throw $Reason }
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
		[Diagnostics.Stopwatch] $Clock,
		[int] $DeadlineSeconds = 0,
		$Budget
	)
	Assert-AggregateDeadline -Clock $Clock -DeadlineSeconds $DeadlineSeconds
	if ($Bytes.Length -eq 0 -or $Bytes.Length -gt $MaximumBytes) { throw 'archive_size_limit' }
	Add-AggregateBudgetUsage -Budget $Budget -Kind archive -Amount $Bytes.Length
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
			Assert-AggregateDeadline -Clock $Clock -DeadlineSeconds $DeadlineSeconds
			$Name = [string] $Entry.FullName
			Assert-SafeArchivePath $Name
			$CollisionKey = $Name.Normalize([Text.NormalizationForm]::FormC)
			if (-not $Names.Add($CollisionKey)) { throw 'archive_path_collision' }
			$Attributes = [BitConverter]::ToUInt32([BitConverter]::GetBytes([int32] $Entry.ExternalAttributes), 0)
			$UnixType = ($Attributes -shr 16) -band 0xF000
			if (($UnixType -ne 0 -and $UnixType -ne 0x8000) -or ($Attributes -band 0x10) -ne 0) { throw 'archive_link_rejected' }
			if ($Entry.Length -lt 0 -or $Entry.Length -gt $MaximumEntryBytes) { throw 'archive_entry_size_limit' }
			if ($Expanded -gt ([long] $MaximumExpandedBytes - [long] $Entry.Length)) { throw 'archive_expanded_size_limit' }
			Add-AggregateBudgetUsage -Budget $Budget -Kind expanded -Amount $Entry.Length
			$Expanded += [long] $Entry.Length
			$EntryStream = $Entry.Open()
			$Output = New-Object IO.MemoryStream
			try {
				$Buffer = New-Object byte[] 8192
				while (($Read = $EntryStream.Read($Buffer, 0, $Buffer.Length)) -gt 0) {
					Assert-AggregateDeadline -Clock $Clock -DeadlineSeconds $DeadlineSeconds
					if ($Output.Length + $Read -gt $MaximumEntryBytes -or $Output.Length + $Read -gt $Entry.Length) { throw 'archive_entry_size_limit' }
					$Output.Write($Buffer, 0, $Read)
				}
				if ($Output.Length -ne $Entry.Length) { throw 'archive_entry_size_mismatch' }
				$EntryBytes = $Output.ToArray()
			} finally { $Output.Dispose(); $EntryStream.Dispose() }
			$Entries.Add([pscustomobject][ordered]@{ name = $Name; bytes = $EntryBytes; sizeBytes = [long] $EntryBytes.Length; sha256 = Get-Sha256Hex $EntryBytes })
		}
	} finally { $Archive.Dispose(); $ArchiveStream.Dispose() }
	Assert-AggregateDeadline -Clock $Clock -DeadlineSeconds $DeadlineSeconds
	return [pscustomobject][ordered]@{ sha256 = Get-Sha256Hex $Bytes; sizeBytes = [long] $Bytes.Length; entries = $Entries.ToArray() }
}

function Assert-AcceptanceContext {
	param($Context)
	Assert-ClosedObject -Value $Context -Names @('schemaVersion','repository','event','source','workflow','actions','controller','policy','run','attemptAnchor') -Reason 'context_schema_invalid'
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
	Assert-AttemptAnchor -Anchor $Context.attemptAnchor -Run $Context.run -Reason 'context_attempt_anchor_invalid'
}

function Read-AcceptedSelectorReport {
	param([Parameter(Mandatory)] [byte[]] $ReportBytes, $Context)
	if ($ReportBytes.Length -eq 0 -or $ReportBytes.Length -gt $script:AggregateLimits.jsonBytes) { throw 'selector_evidence_report_invalid' }
	try { $Report = ConvertFrom-StrictBoundedJson -Bytes $ReportBytes -MaximumBytes $script:AggregateLimits.jsonBytes -MaximumDepth 16 -MaximumProperties 65536 -MaximumArrayItems 32768 }
	catch { throw 'selector_evidence_report_invalid' }
	Assert-ClosedObject -Value $Report -Names @('schemaVersion','attemptAnchor','policy','source','execution','classification','selection','legacyAuthority','comparison') -Reason 'selector_evidence_report_invalid'
	Assert-AttemptAnchor -Anchor $Report.attemptAnchor -Run $Context.run -Reason 'selector_attempt_anchor_invalid'
	if ($Report.attemptAnchor.nonce -cne $Context.attemptAnchor.nonce) { throw 'selector_attempt_anchor_mismatch' }
	Assert-ClosedObject -Value $Report.policy -Names @('version','digest','checkIds') -Reason 'selector_evidence_report_invalid'
	Assert-ClosedObject -Value $Report.source -Names @('kind','callerKind','baseRevision','headRevision','workflowRevision','revision') -Reason 'selector_evidence_report_invalid'
	Assert-ClosedObject -Value $Report.execution -Names @('mode','controllerRevision','controllerBlobOid','controllerSha256','checkoutAllowed','complete','reason') -Reason 'selector_evidence_report_invalid'
	Assert-ClosedObject -Value $Report.classification -Names @('changedPaths','entries','uncertainties') -Reason 'selector_evidence_report_invalid'
	Assert-ClosedObject -Value $Report.selection -Names @('shadow','authoritative','obligations') -Reason 'selector_evidence_report_invalid'
	Assert-ClosedObject -Value $Report.legacyAuthority -Names @('authoritative','engineRequired','reason') -Reason 'selector_evidence_report_invalid'
	Assert-ClosedObject -Value $Report.comparison -Names @('status','differences') -Reason 'selector_evidence_report_invalid'
	$ExpectedWorkflowRevision = if ($Context.event.kind -ceq 'pull_request') { $Context.workflow.revision } else { $null }
	if ($Report.schemaVersion -cne 'aetheln.ci-selection/v1' -or
		$Report.policy.version -cne $Context.policy.version -or $Report.policy.digest -cne $Context.policy.digest -or
		$Report.policy.checkIds -isnot [array] -or (@($Report.policy.checkIds) -join "`n") -cne ($script:SelectorCheckIds -join "`n") -or
		$Report.source.kind -cne $Context.event.kind -or $null -ne $Report.source.callerKind -or
		$Report.source.baseRevision -cne $Context.source.baseRevision -or $Report.source.headRevision -cne $Context.source.headRevision -or
		$Report.source.workflowRevision -cne $ExpectedWorkflowRevision -or $null -ne $Report.source.revision -or
		$Report.execution.mode -cne 'accepted-base' -or $Report.execution.controllerRevision -cne $Context.controller.revision -or
		$Report.execution.controllerBlobOid -cne $Context.controller.blobOid -or $Report.execution.controllerSha256 -cne $Context.controller.sha256 -or
		$Report.execution.checkoutAllowed -ne $false -or $Report.execution.complete -ne $true -or
		$Report.execution.reason -isnot [string] -or $Report.execution.reason -cnotmatch '^[a-z0-9_]{1,100}$' -or
		$Report.selection.shadow -ne $true -or $Report.selection.authoritative -ne $false -or $Report.selection.obligations -isnot [array] -or
		$Report.classification.changedPaths -isnot [array] -or $Report.classification.entries -isnot [array] -or $Report.classification.uncertainties -isnot [array] -or
		$Report.legacyAuthority.authoritative -ne $true -or ($null -ne $Report.legacyAuthority.engineRequired -and $Report.legacyAuthority.engineRequired -isnot [bool]) -or
		$Report.legacyAuthority.reason -isnot [string] -or $Report.comparison.status -isnot [string] -or $Report.comparison.differences -isnot [array]) {
		throw 'selector_evidence_report_invalid'
	}
	$Selected = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
	$Obligations = @($Report.selection.obligations)
	if ($Obligations.Count -ne $script:SelectorCheckIds.Count) { throw 'selector_evidence_obligations_invalid' }
	for ($Index = 0; $Index -lt $Obligations.Count; $Index++) {
		$Obligation = $Obligations[$Index]
		Assert-ClosedObject -Value $Obligation -Names @('id','selected','reasons') -Reason 'selector_evidence_obligations_invalid'
		if ($Obligation.id -cne $script:SelectorCheckIds[$Index] -or $Obligation.selected -isnot [bool] -or $Obligation.reasons -isnot [array] -or
			@($Obligation.reasons).Count -gt 64 -or @($Obligation.reasons | Where-Object { $_ -isnot [string] -or $_.Length -eq 0 -or $_.Length -gt 4096 }).Count -ne 0 -or
			($Obligation.selected -and @($Obligation.reasons).Count -eq 0) -or (-not $Obligation.selected -and @($Obligation.reasons).Count -ne 0)) {
			throw 'selector_evidence_obligations_invalid'
		}
		if ($Obligation.selected) { [void] $Selected.Add([string] $Obligation.id) }
	}
	return ,$Selected
}

function Assert-AcceptanceRequirements {
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'The function validates the complete requirements collection.')]
	param($Requirements, $Context)
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
		Assert-ClosedObject -Value $Job -Names @('key','jobName','artifactName','checks') -Reason 'requirements_schema_invalid'
		if ($Job.key -isnot [string] -or $Job.key -cnotmatch '^[a-z0-9][a-z0-9-]{0,63}$' -or $Job.jobName -isnot [string] -or $Job.jobName.Length -lt 1 -or $Job.jobName.Length -gt 100 -or $Job.artifactName -isnot [string] -or $Job.artifactName -cnotmatch '^[A-Za-z0-9._-]{1,200}$' -or $Job.checks -isnot [array]) { throw 'requirements_identity_invalid' }
		if ($Job.jobName -ceq 'ci-selection-shadow' -or $Job.artifactName -ceq ('ci-selection-shadow-' + $Context.run.id + '-' + $Context.run.attempt + '-' + $Context.attemptAnchor.nonce)) { throw 'requirements_selector_identity_reserved' }
		$ExpectedArtifactName = 'ci-receipt-' + $Job.key + '-' + $Context.run.id + '-' + $Context.run.attempt + '-' + $Context.attemptAnchor.nonce
		if ($Job.artifactName -cne $ExpectedArtifactName) { throw 'requirements_artifact_name_invalid' }
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
	foreach ($Root in @('repository','event','source','workflow','actions','controller','policy','run','attemptAnchor')) {
		$ReceiptJson = $Receipt.$Root | ConvertTo-Json -Depth 8 -Compress
		$ContextJson = $Context.$Root | ConvertTo-Json -Depth 8 -Compress
		if ($ReceiptJson -cne $ContextJson) { throw ('receipt_identity_mismatch:' + $Root) }
	}
}

function Test-AggregateBoundedInteger {
	param($Value, [long] $Minimum, [long] $Maximum)
	return ($Value -is [int] -or $Value -is [long]) -and [long] $Value -ge $Minimum -and [long] $Value -le $Maximum
}

function Test-AggregateBoundedNumber {
	param($Value, [double] $Minimum, [double] $Maximum)
	if ($Value -isnot [int] -and $Value -isnot [long] -and $Value -isnot [double] -and $Value -isnot [decimal]) { return $false }
	$Number = [double] $Value
	return -not [double]::IsNaN($Number) -and -not [double]::IsInfinity($Number) -and $Number -ge $Minimum -and $Number -le $Maximum
}

function Assert-AggregateCompileBuildRecord {
	param($Build, [string] $ExpectedCheck, [string] $ExpectedTarget, [string] $ExpectedPlatform)
	$Reason = 'receipt_semantic_evidence_invalid:native-client-server-compile'
	Assert-ClosedObject $Build @('check','target','platform','configuration','intermediateBuildDirectoryPresentBeforeRun','makefilePresentBeforeRun','outputState','lastObservedAction','observedTotalActions','actionCounterState','plannedActionCount','observedTargetNames','makefileObservation','makefileReason','makefileCreationCount','upToDateObserved','executorSummaryCount') $Reason
	if ($Build.check -isnot [string] -or $Build.check -cne $ExpectedCheck -or $Build.target -isnot [string] -or $Build.target -cne $ExpectedTarget -or
		$Build.platform -isnot [string] -or $Build.platform -cne $ExpectedPlatform -or $Build.configuration -isnot [string] -or $Build.configuration -cne 'Development' -or
		$Build.intermediateBuildDirectoryPresentBeforeRun -isnot [bool] -or $Build.makefilePresentBeforeRun -isnot [bool] -or
		$Build.outputState -isnot [string] -or $Build.outputState -cne 'captured' -or $Build.actionCounterState -isnot [string] -or
		$Build.actionCounterState -cnotin @('observed','not_observed') -or $Build.makefileObservation -isnot [string] -or
		$Build.makefileObservation -cnotin @('created','not_observed') -or $Build.upToDateObserved -isnot [bool] -or
		-not (Test-AggregateBoundedInteger $Build.makefileCreationCount 0 10000000) -or -not (Test-AggregateBoundedInteger $Build.executorSummaryCount 0 10000000)) { throw $Reason }
	if ($Build.actionCounterState -ceq 'observed') {
		if (-not (Test-AggregateBoundedInteger $Build.lastObservedAction 1 10000000) -or -not (Test-AggregateBoundedInteger $Build.observedTotalActions 1 10000000) -or $Build.lastObservedAction -gt $Build.observedTotalActions) { throw $Reason }
	} elseif ($null -ne $Build.lastObservedAction -or $null -ne $Build.observedTotalActions) { throw $Reason }
	if ($null -ne $Build.plannedActionCount -and -not (Test-AggregateBoundedInteger $Build.plannedActionCount 0 10000000)) { throw $Reason }
	if ($null -ne $Build.observedTargetNames -and ($Build.observedTargetNames -isnot [string] -or $Build.observedTargetNames.Length -gt 512 -or $Build.observedTargetNames -cnotmatch '^(?:AethelnOnlineClient|AethelnOnlineServer|AethelnOnlineEditor|UnrealEditor|UnrealPak|ShaderCompileWorker|other)(?:,(?:AethelnOnlineClient|AethelnOnlineServer|AethelnOnlineEditor|UnrealEditor|UnrealPak|ShaderCompileWorker|other))*$')) { throw $Reason }
	if ($Build.makefileObservation -ceq 'created') {
		if ($Build.makefileCreationCount -lt 1 -or $Build.makefileReason -isnot [string] -or $Build.makefileReason -cnotmatch '^[a-z0-9_]{1,128}$') { throw $Reason }
	} elseif ($Build.makefileCreationCount -ne 0 -or $null -ne $Build.makefileReason) { throw $Reason }
}

function Assert-AggregateManagedCompileProof {
	param($Report, $Context)
	$Reason = 'receipt_semantic_evidence_invalid:native-client-server-compile'
	Assert-ClosedObject $Report.managedWorkspace @('schemaVersion','registrationId','registrationSha256','preparationReceiptSha256','revision','synchronized') $Reason
	Assert-ClosedObject $Report.compileResources @('schemaVersion','sampleIntervalMilliseconds','recoveryFloorBytes','pressureThresholdBytes','sampleCount','measurementCount','maximumSampleGapMilliseconds','consecutivePressureSamples','maximumConsecutivePressureSamples','minimumAvailableRamBytes','minimumCommitHeadroomBytes','physicalCores','targetAdmissionCount','minimumActionLimit','maximumActionLimit','failureReason','volumes') $Reason
	$Workspace = $Report.managedWorkspace
	if (-not (Test-AggregateBoundedInteger $Workspace.schemaVersion 1 1) -or $Workspace.registrationId -isnot [string] -or $Workspace.registrationId -cnotmatch '^[a-f0-9]{32}$' -or
		-not (Test-Sha256 $Workspace.registrationSha256) -or -not (Test-Sha256 $Workspace.preparationReceiptSha256) -or
		$Workspace.revision -isnot [string] -or $Workspace.revision -cne $Context.source.testedRevision -or $Workspace.synchronized -isnot [bool] -or -not $Workspace.synchronized) { throw $Reason }
	$Resources = $Report.compileResources
	if (-not (Test-AggregateBoundedInteger $Resources.schemaVersion 1 1) -or -not (Test-AggregateBoundedInteger $Resources.sampleIntervalMilliseconds 5000 5000) -or
		-not (Test-AggregateBoundedInteger $Resources.recoveryFloorBytes 20GB 20GB) -or -not (Test-AggregateBoundedInteger $Resources.pressureThresholdBytes 2GB 2GB) -or
		-not (Test-AggregateBoundedInteger $Resources.sampleCount 1 10000000) -or -not (Test-AggregateBoundedInteger $Resources.measurementCount 1 10000000) -or $Resources.measurementCount -lt $Resources.sampleCount -or
		-not (Test-AggregateBoundedInteger $Resources.maximumSampleGapMilliseconds 0 3600000) -or
		-not (Test-AggregateBoundedInteger $Resources.consecutivePressureSamples 0 2) -or -not (Test-AggregateBoundedInteger $Resources.maximumConsecutivePressureSamples 0 2) -or
		$Resources.consecutivePressureSamples -gt $Resources.maximumConsecutivePressureSamples -or -not (Test-AggregateBoundedInteger $Resources.minimumAvailableRamBytes 0 ([long]::MaxValue)) -or
		-not (Test-AggregateBoundedInteger $Resources.minimumCommitHeadroomBytes 0 ([long]::MaxValue)) -or -not (Test-AggregateBoundedInteger $Resources.physicalCores 1 ([int]::MaxValue)) -or
		-not (Test-AggregateBoundedInteger $Resources.targetAdmissionCount 2 2) -or -not (Test-AggregateBoundedInteger $Resources.minimumActionLimit 1 4) -or
		-not (Test-AggregateBoundedInteger $Resources.maximumActionLimit 1 4) -or $Resources.minimumActionLimit -gt $Resources.maximumActionLimit -or
		$null -ne $Resources.failureReason -or $Resources.volumes -isnot [array] -or @($Resources.volumes).Count -lt 1 -or @($Resources.volumes).Count -gt 7) { throw $Reason }
	$VolumeIds = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
	foreach ($Volume in $Resources.volumes) {
		Assert-ClosedObject $Volume @('volumeId','knownAllocationBytes','minimumAvailableBytes') $Reason
		if ($Volume.volumeId -isnot [string] -or $Volume.volumeId -cnotmatch '^[^\x00-\x1f]{1,256}$' -or -not $VolumeIds.Add($Volume.volumeId) -or
			-not (Test-AggregateBoundedInteger $Volume.knownAllocationBytes 0 ([long]::MaxValue - 20GB)) -or
			-not (Test-AggregateBoundedInteger $Volume.minimumAvailableBytes 0 ([long]::MaxValue)) -or
			[decimal] $Volume.minimumAvailableBytes -le ([decimal] $Volume.knownAllocationBytes + 20GB)) { throw $Reason }
	}
}

function Test-AggregateCanonicalValidatorPath {
	param($Value, [string] $Expected)
	if ($Value -isnot [string] -or $Value.Length -gt 4096) { return $false }
	$Normalized = $Value.Replace('\', '/')
	if ($Normalized.StartsWith('./', [StringComparison]::Ordinal)) { $Normalized = $Normalized.Substring(2) }
	return $Normalized -ceq $Expected
}

function Test-AggregateTimestampRange {
	param($StartedValue, $FinishedValue)
	if ($StartedValue -isnot [string] -or $FinishedValue -isnot [string]) { return $false }
	[datetime]$Started=[datetime]::MinValue; [datetime]$Finished=[datetime]::MinValue; $Style=[Globalization.DateTimeStyles]::RoundtripKind
	return [datetime]::TryParseExact($StartedValue,'o',[Globalization.CultureInfo]::InvariantCulture,$Style,[ref]$Started) -and [datetime]::TryParseExact($FinishedValue,'o',[Globalization.CultureInfo]::InvariantCulture,$Style,[ref]$Finished) -and $Finished -ge $Started
}

function Assert-PortableSemanticEvidence {
	param([byte[]]$Bytes,$Context)
	try {
		$Report=ConvertFrom-StrictBoundedJson -Bytes $Bytes -MaximumBytes $script:AggregateLimits.jsonBytes -MaximumDepth 8 -MaximumProperties 1024 -MaximumArrayItems 2048
		Assert-ClosedObject $Report @('schemaVersion','revision','startedUtc','finishedUtc','checks','summary') 'receipt_semantic_evidence_invalid:portable'
		Assert-ClosedObject $Report.summary @('total','passed','failed','skipped','requiredFailed') 'receipt_semantic_evidence_invalid:portable'
	} catch { if($_.Exception.Message -cmatch '^receipt_semantic_evidence_'){throw}; throw 'receipt_semantic_evidence_invalid:portable' }
	if (-not (Test-AggregateBoundedInteger $Report.schemaVersion 1 1) -or $Report.revision -isnot [string] -or $Report.revision -cne $Context.source.testedRevision -or
		-not (Test-AggregateTimestampRange $Report.startedUtc $Report.finishedUtc) -or $Report.checks -isnot [array] -or @($Report.checks).Count -ne $script:AcceptancePortableCheckNames.Count) { throw 'receipt_semantic_evidence_invalid:portable' }
	$Passed=0;$Skipped=0
	for($Index=0;$Index-lt$script:AcceptancePortableCheckNames.Count;$Index++){
		$Check=$Report.checks[$Index]; Assert-ClosedObject $Check @('name','tier','status','durationSeconds','command','message') 'receipt_semantic_evidence_invalid:portable'
		$Expected=$script:AcceptancePortableCheckNames[$Index];$Tier=if($Expected-ceq'psscriptanalyzer'){'advisory'}else{'required'}
		if($Check.name-isnot[string]-or$Check.name-cne$Expected-or$Check.tier-isnot[string]-or$Check.tier-cne$Tier-or$Check.status-isnot[string]-or-not(Test-AggregateBoundedNumber $Check.durationSeconds 0 86400)-or$Check.command-isnot[string]-or$Check.command.Length-gt 32768-or$Check.message-isnot[string]-or$Check.message.Length-gt 131072){throw 'receipt_semantic_evidence_invalid:portable'}
		if($Check.status-cnotin@('passed','skipped')-or($Tier-ceq'required'-and$Check.status-cne'passed')){throw 'receipt_semantic_evidence_failure:portable'}
		if($Check.status-ceq'passed'){$Passed++}else{$Skipped++}
	}
	if(-not(Test-AggregateBoundedInteger $Report.summary.total 0 1024)-or
		-not(Test-AggregateBoundedInteger $Report.summary.passed 0 1024)-or
		-not(Test-AggregateBoundedInteger $Report.summary.failed 0 1024)-or
		-not(Test-AggregateBoundedInteger $Report.summary.skipped 0 1024)-or
		-not(Test-AggregateBoundedInteger $Report.summary.requiredFailed 0 1024)){throw 'receipt_semantic_evidence_invalid:portable'}
	if($Report.summary.total-ne$Report.checks.Count-or$Report.summary.passed-ne$Passed-or$Report.summary.failed-ne 0-or$Report.summary.skipped-ne$Skipped-or$Report.summary.requiredFailed-ne 0){throw 'receipt_semantic_evidence_failure:portable'}
}

function Assert-EngineRunnerSemanticEvidence {
	param([byte[]]$Bytes,$Context,[string]$ExpectedRunnerName)
	$Reason = 'receipt_semantic_evidence_invalid:native-client-server-compile'
	try { $Report = ConvertFrom-StrictBoundedJson -Bytes $Bytes -MaximumBytes $script:AggregateLimits.jsonBytes -MaximumDepth 12 -MaximumProperties 2048 -MaximumArrayItems 2048 }
	catch { throw $Reason }
	$Required = @('schemaVersion','mode','policy','revision','runnerName','startedUtc','finishedUtc','checks','summary','compileEvidence','managedWorkspace','compileResources','supervisor')
	foreach ($Name in $Required) { if ($Report -isnot [pscustomobject] -or $Report.PSObject.Properties.Name -cnotcontains $Name) { throw $Reason } }
	if (@($Report.PSObject.Properties.Name | Where-Object { $Required -cnotcontains $_ }).Count -ne 0) { throw $Reason }
	Assert-ClosedObject $Report.summary @('total','passed','failed','skipped','requiredFailed') $Reason
	Assert-ClosedObject $Report.supervisor @('childExitCode','timedOut','cleanupVerified') $Reason
	if (-not (Test-AggregateBoundedInteger $Report.schemaVersion 1 1) -or $Report.mode -isnot [string] -or $Report.mode -cne 'Compile' -or
		$Report.policy -isnot [string] -or $Report.policy -cne 'incremental-target-compilation' -or $Report.revision -isnot [string] -or
		$Report.revision -cne $Context.source.testedRevision -or $Report.runnerName -isnot [string] -or [string]::IsNullOrWhiteSpace($Report.runnerName) -or $Report.runnerName.Length -gt 128 -or
		(-not [string]::IsNullOrEmpty($ExpectedRunnerName) -and $Report.runnerName -cne $ExpectedRunnerName) -or
		-not (Test-AggregateTimestampRange $Report.startedUtc $Report.finishedUtc) -or $Report.checks -isnot [array] -or @($Report.checks).Count -lt 8 -or @($Report.checks).Count -gt 32 -or
		-not (Test-AggregateBoundedInteger $Report.supervisor.childExitCode 0 0) -or $Report.supervisor.timedOut -isnot [bool] -or $Report.supervisor.timedOut -or
		$Report.supervisor.cleanupVerified -isnot [bool] -or -not $Report.supervisor.cleanupVerified) { throw $Reason }
	$Names = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
	foreach ($Check in $Report.checks) {
		Assert-ClosedObject $Check @('name','tier','status','durationSeconds','command','message') $Reason
		if ($Check.name -isnot [string] -or $Check.name.Length -lt 1 -or $Check.name.Length -gt 128 -or -not $Names.Add($Check.name) -or
			$Check.tier -isnot [string] -or $Check.status -isnot [string] -or -not (Test-AggregateBoundedNumber $Check.durationSeconds 0 86400) -or
			$Check.command -isnot [string] -or $Check.command.Length -gt 32768 -or $Check.message -isnot [string] -or $Check.message.Length -gt 131072) { throw $Reason }
		if ($Check.tier -cne 'required' -or $Check.status -cne 'passed') { throw 'receipt_semantic_evidence_failure:native-client-server-compile' }
	}
	foreach ($Expected in @('runner-input-validation','managed-compile-workspace','repository-state-before-work','incremental-client-build','incremental-client-build-repository-state','incremental-server-build','incremental-server-build-repository-state','repository-state-at-completion')) {
		if (-not $Names.Contains($Expected)) { throw 'receipt_semantic_evidence_failure:native-client-server-compile' }
	}
	if (-not (Test-AggregateBoundedInteger $Report.summary.total 0 32) -or $Report.summary.total -ne $Report.checks.Count -or
		-not (Test-AggregateBoundedInteger $Report.summary.passed 0 32) -or $Report.summary.passed -ne $Report.checks.Count -or
		-not (Test-AggregateBoundedInteger $Report.summary.failed 0 0) -or -not (Test-AggregateBoundedInteger $Report.summary.skipped 0 0) -or
		-not (Test-AggregateBoundedInteger $Report.summary.requiredFailed 0 0)) { throw $Reason }
	Assert-AggregateManagedCompileProof -Report $Report -Context $Context
	if ($Report.compileEvidence -isnot [pscustomobject] -or -not (Test-AggregateBoundedInteger $Report.compileEvidence.schemaVersion 1 1) -or $Report.compileEvidence.builds -isnot [array] -or @($Report.compileEvidence.builds).Count -ne 2) { throw $Reason }
	Assert-ClosedObject $Report.compileEvidence @('schemaVersion','identity','builds') $Reason
	Assert-ClosedObject $Report.compileEvidence.identity @('engineGitRevision','engineGitRevisionStatus','engineBuildVersionSha256','engineBuildVersionSha256Status','linuxToolchainCompilerSha256','linuxToolchainCompilerSha256Status','runnerName','durationSeconds') $Reason
	$CompileIdentity = $Report.compileEvidence.identity
	if ($CompileIdentity.engineGitRevision -isnot [string] -or $CompileIdentity.engineGitRevision -cne '71fe36aac5a8df5ccd66c763ffc902b29b6a9c43' -or
		$CompileIdentity.engineGitRevisionStatus -isnot [string] -or $CompileIdentity.engineGitRevisionStatus -cne 'verified' -or
		-not (Test-Sha256 $CompileIdentity.engineBuildVersionSha256) -or $CompileIdentity.engineBuildVersionSha256Status -isnot [string] -or $CompileIdentity.engineBuildVersionSha256Status -cne 'verified' -or
		-not (Test-Sha256 $CompileIdentity.linuxToolchainCompilerSha256) -or $CompileIdentity.linuxToolchainCompilerSha256Status -isnot [string] -or $CompileIdentity.linuxToolchainCompilerSha256Status -cne 'verified' -or
		$CompileIdentity.runnerName -isnot [string] -or $CompileIdentity.runnerName -cne $Report.runnerName -or -not (Test-AggregateBoundedNumber $CompileIdentity.durationSeconds 0 3600)) { throw $Reason }
	$ExpectedBuilds = @(@('incremental-client-build','AethelnOnlineClient','Win64'),@('incremental-server-build','AethelnOnlineServer','Linux'))
	for ($Index = 0; $Index -lt 2; $Index++) {
		$Build = $Report.compileEvidence.builds[$Index]; $Expected = $ExpectedBuilds[$Index]
		Assert-AggregateCompileBuildRecord -Build $Build -ExpectedCheck $Expected[0] -ExpectedTarget $Expected[1] -ExpectedPlatform $Expected[2]
	}
}

function Assert-UnrealAutomationSemanticEvidence {
	param([byte[]]$Bytes,$Context)
	$Reason = 'receipt_semantic_evidence_invalid:unreal-editor-automation'
	try {
		$Report = ConvertFrom-StrictBoundedJson -Bytes $Bytes -MaximumBytes $script:AggregateLimits.jsonBytes -MaximumDepth 8 -MaximumProperties 256 -MaximumArrayItems 64
		Assert-ClosedObject $Report @('schemaId','schemaVersion','mode','sourceRevision','engineRevision','projectName','filter','timeoutSeconds','startedUtc','finishedUtc','processExitCode','repositoryCleanBefore','repositoryCleanAfter','outputs','tests','summary','result','failureReason') $Reason
		Assert-ClosedObject $Report.outputs @('unrealReport','log') $Reason
		Assert-ClosedObject $Report.summary @('total','passed','passedWithWarnings','failed','notRun','missing','requiredFailed') $Reason
	} catch { if ($_.Exception.Message -cmatch '^receipt_semantic_evidence_') { throw }; throw $Reason }
	if ($Report.schemaId -isnot [string] -or $Report.schemaId -cne 'aetheln.unreal-automation' -or -not (Test-AggregateBoundedInteger $Report.schemaVersion 1 1) -or
		$Report.mode -isnot [string] -or $Report.mode -cne 'production' -or $Report.sourceRevision -isnot [string] -or $Report.sourceRevision -cne $Context.source.testedRevision -or
		$Report.engineRevision -isnot [string] -or $Report.engineRevision -cne '71fe36aac5a8df5ccd66c763ffc902b29b6a9c43' -or
		$Report.projectName -isnot [string] -or $Report.projectName -cne 'AethelnOnline' -or $Report.filter -isnot [string] -or $Report.filter -cne '^Aetheln.Harness.ProjectAndModuleLoad$+^Aetheln.GameCombat.NetworkSpike.Authority$' -or
		-not (Test-AggregateBoundedInteger $Report.timeoutSeconds 1 86400) -or -not (Test-AggregateTimestampRange $Report.startedUtc $Report.finishedUtc) -or
		-not (Test-AggregateBoundedInteger $Report.processExitCode 0 0) -or $Report.repositoryCleanBefore -isnot [bool] -or -not $Report.repositoryCleanBefore -or
		$Report.repositoryCleanAfter -isnot [bool] -or -not $Report.repositoryCleanAfter -or $Report.outputs.unrealReport -isnot [string] -or
		$Report.outputs.unrealReport -cne 'TestResults/UnrealAutomation/index.json' -or $Report.outputs.log -isnot [string] -or $Report.outputs.log -cne 'Saved/Logs/AethelnUnrealAutomation.log' -or
		$Report.result -isnot [string] -or $Report.result -cne 'passed' -or $Report.failureReason -isnot [string] -or $Report.failureReason -cne 'none' -or
		$Report.tests -isnot [array] -or @($Report.tests).Count -ne 2) { throw $Reason }
	$Expected = @('Aetheln.GameCombat.NetworkSpike.Authority','Aetheln.Harness.ProjectAndModuleLoad')
	for ($Index = 0; $Index -lt 2; $Index++) {
		$Test = $Report.tests[$Index]
		Assert-ClosedObject $Test @('fullTestPath','state','status','durationSeconds','warningCount','errorCount') $Reason
		if ($Test.fullTestPath -isnot [string] -or $Test.fullTestPath -cne $Expected[$Index] -or $Test.state -isnot [string] -or $Test.state -cne 'Success' -or
			$Test.status -isnot [string] -or $Test.status -cne 'passed' -or -not (Test-AggregateBoundedNumber $Test.durationSeconds 0 86400) -or
			-not (Test-AggregateBoundedInteger $Test.warningCount 0 0) -or -not (Test-AggregateBoundedInteger $Test.errorCount 0 0)) { throw $Reason }
	}
	if (-not (Test-AggregateBoundedInteger $Report.summary.total 2 2) -or $Report.summary.total -ne $Report.tests.Count -or
		-not (Test-AggregateBoundedInteger $Report.summary.passed 2 2) -or -not (Test-AggregateBoundedInteger $Report.summary.passedWithWarnings 0 0) -or
		-not (Test-AggregateBoundedInteger $Report.summary.failed 0 0) -or -not (Test-AggregateBoundedInteger $Report.summary.notRun 0 0) -or
		-not (Test-AggregateBoundedInteger $Report.summary.missing 0 0) -or -not (Test-AggregateBoundedInteger $Report.summary.requiredFailed 0 0)) { throw $Reason }
}

function Assert-VisualPackageSemanticEvidence {
	param([byte[]] $Bytes, $Context)
	try {
		$Report = ConvertFrom-StrictBoundedJson -Bytes $Bytes -MaximumBytes $script:AggregateLimits.jsonBytes -MaximumDepth 8 -MaximumProperties 256 -MaximumArrayItems 1024
		Assert-ClosedObject -Value $Report -Names @('schemaVersion','repository','revision','run','results','conclusion') -Reason 'receipt_semantic_evidence_invalid:visual-package'
		Assert-ClosedObject -Value $Report.run -Names @('id','attempt') -Reason 'receipt_semantic_evidence_invalid:visual-package'
	} catch {
		if ($_.Exception.Message -cmatch '^receipt_semantic_evidence_') { throw }
		throw 'receipt_semantic_evidence_invalid:visual-package'
	}
	if ($Report.schemaVersion -cne 'aetheln.visual-package-report/v1' -or
		$Report.repository -cne $Context.repository.fullName -or
		$Report.revision -cne $Context.source.testedRevision -or
		$Report.run.id -cne $Context.run.id -or
		-not (Test-AggregateBoundedInteger -Value $Report.run.attempt -Minimum 1 -Maximum ([int]::MaxValue)) -or $Report.run.attempt -ne $Context.run.attempt -or
		$Report.results -isnot [array] -or @($Report.results).Count -ne 2) {
		throw 'receipt_semantic_evidence_invalid:visual-package'
	}

	$ExpectedValidators = @(
		[pscustomobject]@{ id='visual-package'; path='visuals/Test-VisualPackage.ps1' },
		[pscustomobject]@{ id='visual-package-regressions'; path='visuals/tests/Test-VisualPackageValidation.ps1' }
	)
	[long] $TotalCapturedLines = 0
	for ($Index = 0; $Index -lt $ExpectedValidators.Count; $Index++) {
		$Result = $Report.results[$Index]
		Assert-ClosedObject -Value $Result -Names @('id','path','startedUtc','finishedUtc','nativeExitCode','conclusion','capture','output') -Reason 'receipt_semantic_evidence_invalid:visual-package'
		Assert-ClosedObject -Value $Result.capture -Names @('maxLineUtf8Bytes','maxLines','maxAggregateUtf8Bytes','observedLineCount','capturedLineCount','capturedUtf8Bytes','truncatedLineCount','droppedLineCount') -Reason 'receipt_semantic_evidence_invalid:visual-package'
		$Expected = $ExpectedValidators[$Index]
		[datetime] $Started = [datetime]::MinValue
		[datetime] $Finished = [datetime]::MinValue
		$TimestampStyle = [Globalization.DateTimeStyles]::RoundtripKind
		if ($Result.id -cne $Expected.id -or -not (Test-AggregateCanonicalValidatorPath -Value $Result.path -Expected $Expected.path) -or
			$Result.startedUtc -isnot [string] -or $Result.finishedUtc -isnot [string] -or
			-not [datetime]::TryParseExact($Result.startedUtc, 'o', [Globalization.CultureInfo]::InvariantCulture, $TimestampStyle, [ref] $Started) -or
			-not [datetime]::TryParseExact($Result.finishedUtc, 'o', [Globalization.CultureInfo]::InvariantCulture, $TimestampStyle, [ref] $Finished) -or
			$Finished -lt $Started -or -not (Test-AggregateBoundedInteger -Value $Result.nativeExitCode -Minimum 0 -Maximum 0) -or
			$Result.conclusion -cne 'success' -or $Result.output -isnot [array]) {
			throw 'receipt_semantic_evidence_failure:visual-package'
		}
		$Capture = $Result.capture
		if (-not (Test-AggregateBoundedInteger -Value $Capture.maxLineUtf8Bytes -Minimum 1 -Maximum 16384) -or
			-not (Test-AggregateBoundedInteger -Value $Capture.maxLines -Minimum 1 -Maximum 1000) -or
			-not (Test-AggregateBoundedInteger -Value $Capture.maxAggregateUtf8Bytes -Minimum 1 -Maximum 1048576) -or
			-not (Test-AggregateBoundedInteger -Value $Capture.observedLineCount -Minimum 0 -Maximum ([int]::MaxValue)) -or
			-not (Test-AggregateBoundedInteger -Value $Capture.capturedLineCount -Minimum 0 -Maximum $Capture.maxLines) -or
			-not (Test-AggregateBoundedInteger -Value $Capture.capturedUtf8Bytes -Minimum 0 -Maximum $Capture.maxAggregateUtf8Bytes) -or
			-not (Test-AggregateBoundedInteger -Value $Capture.truncatedLineCount -Minimum 0 -Maximum $Capture.capturedLineCount) -or
			-not (Test-AggregateBoundedInteger -Value $Capture.droppedLineCount -Minimum 0 -Maximum $Capture.observedLineCount) -or
			[long] $Capture.observedLineCount -ne ([long] $Capture.capturedLineCount + [long] $Capture.droppedLineCount) -or
			@($Result.output).Count -ne [long] $Capture.capturedLineCount) {
			throw 'receipt_semantic_evidence_invalid:visual-package'
		}
		[long] $CapturedBytes = 0
		foreach ($Line in @($Result.output)) {
			if ($Line -isnot [string]) { throw 'receipt_semantic_evidence_invalid:visual-package' }
			$LineBytes = $script:StrictUtf8.GetByteCount($Line)
			if ($LineBytes -gt [long] $Capture.maxLineUtf8Bytes) { throw 'receipt_semantic_evidence_invalid:visual-package' }
			$CapturedBytes += $LineBytes
		}
		if ($CapturedBytes -ne [long] $Capture.capturedUtf8Bytes) { throw 'receipt_semantic_evidence_invalid:visual-package' }
		$TotalCapturedLines += [long] $Capture.capturedLineCount
		if ($TotalCapturedLines -gt 1000) { throw 'receipt_semantic_evidence_invalid:visual-package' }
	}
	if ($Report.conclusion -cne 'success') { throw 'receipt_semantic_evidence_failure:visual-package' }
}

function Assert-CiAcceptanceReceipt {
	param($Receipt, $Context, $Requirement, $Archive, $ProducerJob)
	Assert-ClosedObject -Value $Receipt -Names @('schemaVersion','repository','event','source','workflow','actions','controller','policy','run','attemptAnchor','selection','results','acceptance') -Reason 'receipt_schema_invalid'
	if ($Receipt.schemaVersion -cne 'aetheln.ci-acceptance-receipt/v1') { throw 'receipt_schema_invalid' }
	Assert-AcceptanceContext ([pscustomobject][ordered]@{ schemaVersion='aetheln.ci-acceptance-context/v1'; repository=$Receipt.repository; event=$Receipt.event; source=$Receipt.source; workflow=$Receipt.workflow; actions=$Receipt.actions; controller=$Receipt.controller; policy=$Receipt.policy; run=$Receipt.run; attemptAnchor=$Receipt.attemptAnchor })
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
		if ($script:AcceptanceUnsupportedCheckIds -ccontains $Result.id) { throw ('receipt_semantic_evidence_unsupported:' + $Result.id) }
		if ($null -ne $Result.nativeExitCode -and ($Result.nativeExitCode -isnot [int] -or $Result.nativeExitCode -ne 0)) { throw 'receipt_native_exit_invalid' }
		if ($Result.id -ceq 'visual-package' -and ($null -ne $Result.nativeExitCode -or $null -ne $Result.cleanupVerified)) { throw 'receipt_semantic_evidence_invalid:visual-package' }
		if ($Result.id -ceq 'portable' -and ($null -ne $Result.nativeExitCode -or $null -ne $Result.cleanupVerified)) { throw 'receipt_semantic_evidence_invalid:portable' }
		if ($Result.id -ceq 'unreal-editor-automation' -and ($Result.nativeExitCode -ne 0 -or $null -ne $Result.cleanupVerified)) { throw 'receipt_semantic_evidence_invalid:unreal-editor-automation' }
		if ($null -ne $Result.cleanupVerified -and $Result.cleanupVerified -isnot [bool]) { throw 'receipt_cleanup_invalid' }
		if ($Result.id -cin @('clean-package-provenance-smoke','native-client-server-compile') -and ($Result.nativeExitCode -ne 0 -or $Result.cleanupVerified -ne $true)) { throw 'receipt_native_proof_incomplete' }
		if ($Result.evidence -isnot [array]) { throw 'receipt_evidence_invalid' }
		$Evidence = @($Result.evidence)
		if ($Evidence.Count -eq 0 -or $Evidence.Count -gt $script:AggregateLimits.evidencePerReceipt) { throw 'receipt_evidence_invalid' }
		if ($Result.id -in @('portable','native-client-server-compile','unreal-editor-automation','visual-package') -and $Evidence.Count -ne 1) { throw ('receipt_semantic_evidence_duplicate:' + $Result.id) }
		$SemanticEvidenceBytes = $null
		$SemanticEvidenceName = switch ($Result.id) { 'portable' {'ci-report.json'} 'native-client-server-compile' {'engine-runner-report.json'} 'unreal-editor-automation' {'unreal-automation-report.json'} 'visual-package' {'visual-package-report.json'} default {$null} }
		foreach ($Item in $Evidence) {
			Assert-ClosedObject -Value $Item -Names @('name','sha256','sizeBytes') -Reason 'receipt_schema_invalid'
			Assert-SafeArchivePath ([string] $Item.name)
			if ($Item.name -ceq 'ci-acceptance-receipt.json' -or -not (Test-Sha256 $Item.sha256) -or $Item.sizeBytes -isnot [long] -and $Item.sizeBytes -isnot [int] -or [long] $Item.sizeBytes -lt 0 -or -not $ExpectedNames.Add([string] $Item.name)) { throw 'receipt_evidence_invalid' }
			$Entry = @($Archive.entries | Where-Object { $_.name -ceq $Item.name })
			if ($Entry.Count -ne 1 -or $Entry[0].sha256 -cne $Item.sha256 -or $Entry[0].sizeBytes -ne [long] $Item.sizeBytes) { throw 'receipt_evidence_mismatch' }
			if ($null -ne $SemanticEvidenceName) {
				if ($Item.name -cne $SemanticEvidenceName) { throw ('receipt_semantic_evidence_missing:' + $Result.id) }
				$SemanticEvidenceBytes = [byte[]] $Entry[0].bytes
			}
		}
		if ($null -ne $SemanticEvidenceName) {
			if ($null -eq $SemanticEvidenceBytes) { throw ('receipt_semantic_evidence_missing:' + $Result.id) }
			switch ($Result.id) { 'portable' {Assert-PortableSemanticEvidence $SemanticEvidenceBytes $Context} 'native-client-server-compile' {Assert-EngineRunnerSemanticEvidence $SemanticEvidenceBytes $Context $(if ($null -eq $ProducerJob) { $null } else { [string] $ProducerJob.runner_name })} 'unreal-editor-automation' {Assert-UnrealAutomationSemanticEvidence $SemanticEvidenceBytes $Context} 'visual-package' {Assert-VisualPackageSemanticEvidence $SemanticEvidenceBytes $Context} }
		}
	}
	if ($Archive.entries.Count -ne $ExpectedNames.Count -or @($Archive.entries | Where-Object { -not $ExpectedNames.Contains($_.name) }).Count -ne 0) { throw 'archive_unexpected_entry' }
	Assert-ClosedObject -Value $Receipt.acceptance -Names @('shadow','authoritative','grantsAcceptance','terminal','infrastructureFailure','cleanupVerified') -Reason 'receipt_schema_invalid'
	foreach ($BooleanName in @('shadow','authoritative','grantsAcceptance','terminal','infrastructureFailure')) { if ($Receipt.acceptance.$BooleanName -isnot [bool]) { throw 'receipt_authority_invalid' } }
	if ($null -ne $Receipt.acceptance.cleanupVerified -and $Receipt.acceptance.cleanupVerified -isnot [bool]) { throw 'receipt_cleanup_invalid' }
	if ($Receipt.acceptance.shadow -ne $true -or $Receipt.acceptance.authoritative -ne $false -or $Receipt.acceptance.grantsAcceptance -ne $false -or $Receipt.acceptance.terminal -ne $true -or $Receipt.acceptance.infrastructureFailure -ne $false) { throw 'receipt_authority_invalid' }
	$CleanupChecks = @($Requirement.checks | Where-Object { $_ -cin @('clean-package-provenance-smoke','native-client-server-compile') })
	if ($CleanupChecks.Count -ne 0 -and $Receipt.acceptance.cleanupVerified -ne $true) { throw 'receipt_cleanup_invalid' }
	if ($CleanupChecks.Count -eq 0 -and $null -ne $Receipt.acceptance.cleanupVerified) { throw 'receipt_cleanup_invalid' }
	return ,$Results
}

function Resolve-AggregateRequestTarget {
	param([string]$Uri,[string]$ApiBaseUri,[ValidateSet('Api','Artifact')][string]$RequestKind,[uri]$RedirectSource)
	$Reason=if($null-eq$RedirectSource){'api_uri_invalid'}else{'api_redirect_invalid'}
	[uri]$Base=$null
	if(-not[uri]::TryCreate($ApiBaseUri,[UriKind]::Absolute,[ref]$Base)-or$Base.Scheme-cne'https'-or$Base.DnsSafeHost-cne'api.github.com'-or-not$Base.IsDefaultPort-or-not[string]::IsNullOrEmpty($Base.UserInfo)-or$Base.AbsolutePath-cne'/'-or-not[string]::IsNullOrEmpty($Base.Query)-or-not[string]::IsNullOrEmpty($Base.Fragment)){throw 'api_base_uri_invalid'}
	[uri]$Target=$null
	if($null-eq$RedirectSource){
		if($RequestKind-ceq'Api'){
			if([string]::IsNullOrEmpty($Uri)-or-not$Uri.StartsWith('/',[StringComparison]::Ordinal)-or$Uri.StartsWith('//',[StringComparison]::Ordinal)-or$Uri.Contains('\')){throw $Reason}
			$Target=[uri]::new($Base,$Uri)
		}else{
			if(-not[uri]::TryCreate($Uri,[UriKind]::Absolute,[ref]$Target)){throw $Reason}
		}
	}else{
		if(-not[uri]::TryCreate($Uri,[UriKind]::Absolute,[ref]$Target)){throw $Reason}
	}
	if($Target.Scheme-cne'https'-or-not$Target.IsDefaultPort-or-not[string]::IsNullOrEmpty($Target.UserInfo)-or-not[string]::IsNullOrEmpty($Target.Fragment)){throw $Reason}
	$TargetHost=$Target.DnsSafeHost.ToLowerInvariant();$IsApi=$TargetHost-ceq'api.github.com';$IsStorage=$TargetHost-cmatch'^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.blob\.core\.windows\.net$'
	if($null-eq$RedirectSource){if(-not$IsApi){throw $Reason}}
	else{
		$SourceHost=$RedirectSource.DnsSafeHost.ToLowerInvariant()
		if($RequestKind-cne'Artifact'-or(-not$IsApi-and-not$IsStorage)-or($SourceHost-cne'api.github.com'-and$TargetHost-cne$SourceHost)){throw $Reason}
	}
	return [pscustomobject][ordered]@{uri=$Target;sendAuthorization=$IsApi}
}

function Invoke-DefaultBoundedApiRequest {
	param([string] $Uri,[int] $RemainingMilliseconds,[int] $MaximumBytes,[string] $ApiBaseUri,[ValidateSet('Api','Artifact')][string]$RequestKind='Api',$Budget)
	if($RemainingMilliseconds-le 0){throw 'api_deadline_exceeded'}
	$RequestClock=[Diagnostics.Stopwatch]::StartNew();$TargetInfo=Resolve-AggregateRequestTarget -Uri $Uri -ApiBaseUri $ApiBaseUri -RequestKind $RequestKind;$Redirects=0
	while($true){
		$RequestRemaining=[long]$RemainingMilliseconds-$RequestClock.ElapsedMilliseconds;if($RequestRemaining-le 0){throw 'api_deadline_exceeded'}
		$Request=[Net.HttpWebRequest]::CreateHttp($TargetInfo.uri);$Request.Method='GET';$Request.Accept='application/vnd.github+json';$Request.UserAgent='aetheln-ci-acceptance-aggregate/1';$Request.Timeout=[int][Math]::Min($RequestRemaining,[int]::MaxValue);$Request.ReadWriteTimeout=$Request.Timeout;$Request.AllowAutoRedirect=$false
		if($TargetInfo.sendAuthorization){$Token=[Environment]::GetEnvironmentVariable('GITHUB_TOKEN');if([string]::IsNullOrWhiteSpace($Token)){throw 'github_token_unavailable'};$Request.Headers['Authorization']='Bearer '+$Token}
		try{$Response=$Request.GetResponse()}catch{if($RequestClock.ElapsedMilliseconds-ge$RemainingMilliseconds){throw 'api_deadline_exceeded'};throw 'api_request_failed'}
		if($RequestClock.ElapsedMilliseconds-ge$RemainingMilliseconds){$Response.Dispose();throw 'api_deadline_exceeded'}
		$Status=[int]$Response.StatusCode
		if($Status-in@(301,302,303,307,308)){
			try{$Location=[string]$Response.Headers['Location']}finally{$Response.Dispose()}
			$Redirects++;if($Redirects-gt 3-or[string]::IsNullOrWhiteSpace($Location)){throw 'api_redirect_invalid'}
			$TargetInfo=Resolve-AggregateRequestTarget -Uri $Location -ApiBaseUri $ApiBaseUri -RequestKind $RequestKind -RedirectSource $TargetInfo.uri
			Add-AggregateBudgetUsage -Budget $Budget -Kind request -Amount 1
			continue
		}
		if($Status-ne 200){$Response.Dispose();throw 'api_request_failed'}
		try{
			$Stream=$Response.GetResponseStream();$Output=New-Object IO.MemoryStream
			try{$Buffer=New-Object byte[] 8192;while($true){$ReadRemaining=[long]$RemainingMilliseconds-$RequestClock.ElapsedMilliseconds;if($ReadRemaining-le 0){throw 'api_deadline_exceeded'};if($Stream.CanTimeout){$Stream.ReadTimeout=[int][Math]::Min($ReadRemaining,[int]::MaxValue)};try{$Read=$Stream.Read($Buffer,0,$Buffer.Length)}catch{if($RequestClock.ElapsedMilliseconds-ge$RemainingMilliseconds){throw 'api_deadline_exceeded'};throw 'api_request_failed'};if($RequestClock.ElapsedMilliseconds-ge$RemainingMilliseconds){throw 'api_deadline_exceeded'};if($Read-le 0){break};if($Output.Length+$Read-gt$MaximumBytes){throw 'api_response_size_limit'};$Output.Write($Buffer,0,$Read)};return $Output.ToArray()}
			finally{$Output.Dispose();$Stream.Dispose()}
		}finally{$Response.Dispose()}
	}
}

function Get-RemainingMilliseconds {
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'The function returns one duration expressed in milliseconds.')]
	param([Diagnostics.Stopwatch] $Clock, [int] $DeadlineSeconds)
	$Remaining = ([long] $DeadlineSeconds * 1000L) - $Clock.ElapsedMilliseconds
	if ($Remaining -le 0) { throw 'api_deadline_exceeded' }
	return [int] [Math]::Min($Remaining, [int]::MaxValue)
}

function Assert-AggregateDeadline {
	param([Diagnostics.Stopwatch] $Clock, [int] $DeadlineSeconds)
	if ($null -ne $Clock -and $DeadlineSeconds -gt 0) {
		[void](Get-RemainingMilliseconds -Clock $Clock -DeadlineSeconds $DeadlineSeconds)
	}
}

function Invoke-AggregateApi {
	param([scriptblock] $ApiRequest,[string] $Uri,[Diagnostics.Stopwatch] $Clock,[int] $DeadlineSeconds,[int] $MaximumBytes,$Budget,[ValidateSet('Api','Artifact')][string]$RequestKind='Api')
	$Remaining = Get-RemainingMilliseconds $Clock $DeadlineSeconds
	Add-AggregateBudgetUsage -Budget $Budget -Kind request -Amount 1
	$Bytes = & $ApiRequest $Uri $Remaining $MaximumBytes $RequestKind $Budget
	Assert-AggregateDeadline -Clock $Clock -DeadlineSeconds $DeadlineSeconds
	if ($Bytes -isnot [byte[]]) { throw 'api_response_type_invalid' }
	if ($Bytes.Length -gt $MaximumBytes) { throw 'api_response_size_limit' }
	Add-AggregateBudgetUsage -Budget $Budget -Kind network -Amount $Bytes.Length
	return ,$Bytes
}

function Get-PagedApiItems {
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'The function returns all bounded items across pages.')]
	param([scriptblock] $ApiRequest,[string] $BaseUri,[string] $PropertyName,[Diagnostics.Stopwatch] $Clock,[int] $DeadlineSeconds,$Budget)
	$Items = New-Object System.Collections.Generic.List[object]
	for ($Page = 1; $Page -le $script:AggregateLimits.apiPages; $Page++) {
		$Separator = if ($BaseUri.Contains('?')) { '&' } else { '?' }
		$Uri = $BaseUri + $Separator + 'per_page=100&page=' + $Page
		$Bytes = Invoke-AggregateApi -ApiRequest $ApiRequest -Uri $Uri -Clock $Clock -DeadlineSeconds $DeadlineSeconds -MaximumBytes $script:AggregateLimits.apiResponseBytes -Budget $Budget -RequestKind Api
		$Document = ConvertFrom-StrictBoundedJson -Bytes $Bytes -MaximumBytes $script:AggregateLimits.apiResponseBytes -MaximumDepth 32 -MaximumProperties 8192 -MaximumArrayItems $script:AggregateLimits.apiItems
		Assert-AggregateDeadline -Clock $Clock -DeadlineSeconds $DeadlineSeconds
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

function ConvertFrom-AggregateApiTimestamp {
	param($Value, [string] $Reason)
	if ($Value -isnot [string] -or $Value.Length -gt 40) { throw $Reason }
	[datetimeoffset] $Parsed = [datetimeoffset]::MinValue
	[string[]] $Formats = @("yyyy-MM-dd'T'HH:mm:ss'Z'", "yyyy-MM-dd'T'HH:mm:ss.FFFFFFF'Z'")
	$Styles = [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal
	$ParsedSuccessfully = $false
	foreach ($Format in $Formats) {
		[datetimeoffset] $Candidate = [datetimeoffset]::MinValue
		if ([datetimeoffset]::TryParseExact($Value, $Format, [Globalization.CultureInfo]::InvariantCulture, $Styles, [ref] $Candidate)) {
			$Parsed = $Candidate
			$ParsedSuccessfully = $true
			break
		}
	}
	if (-not $ParsedSuccessfully) { throw $Reason }
	return $Parsed
}

function Get-CurrentApiJobInterval {
	param($Job, $Context, [string] $ExpectedConclusion)
	$Reason = 'api_job_identity_invalid'
	foreach ($Name in @('run_id','head_sha','started_at','completed_at','labels','runner_id','runner_name')) {
		if ($Job.PSObject.Properties.Name -cnotcontains $Name) { throw $Reason }
	}
	$Labels = @($Job.labels)
	$NormalizedLabels = @($Labels | ForEach-Object { if ($_ -is [string]) { $_.ToLowerInvariant() } else { $_ } } | Select-Object -Unique)
	if (($Job.run_id -isnot [int] -and $Job.run_id -isnot [long]) -or [string] $Job.run_id -cne $Context.run.id) { throw $Reason }
	if ($Job.head_sha -isnot [string] -or $Job.head_sha -cne $Context.source.headRevision -or $Job.run_attempt -isnot [int] -or $Job.run_attempt -ne $Context.run.attempt) { throw $Reason }
	if ($Job.labels -isnot [array] -or $Labels.Count -lt 1 -or $Labels.Count -gt 16) { throw $Reason }
	if (@($Labels | Where-Object { $_ -isnot [string] -or $_ -cnotmatch '^[A-Za-z0-9._-]{1,64}$' }).Count -ne 0 -or $NormalizedLabels.Count -ne $Labels.Count) { throw $Reason }
	$Started = ConvertFrom-AggregateApiTimestamp -Value $Job.started_at -Reason $Reason
	$Completed = ConvertFrom-AggregateApiTimestamp -Value $Job.completed_at -Reason $Reason
	if ($ExpectedConclusion -ceq 'success') {
		if ($Completed -lt $Started) { throw $Reason }
		if (($Job.runner_id -isnot [int] -and $Job.runner_id -isnot [long]) -or [long] $Job.runner_id -le 0 -or
			$Job.runner_name -isnot [string] -or [string]::IsNullOrWhiteSpace($Job.runner_name) -or $Job.runner_name.Length -gt 128) { throw $Reason }
	} elseif (($null -ne $Job.runner_id -and (($Job.runner_id -isnot [int] -and $Job.runner_id -isnot [long]) -or [long] $Job.runner_id -lt 0)) -or
		($null -ne $Job.runner_name -and $Job.runner_name -isnot [string])) { throw $Reason }
	if ($Job.name -ceq 'trusted-candidate-compile' -and $ExpectedConclusion -ceq 'success') {
		$ExpectedLabels = @('self-hosted','Windows','X64','aetheln-engine')
		if (@($Job.labels).Count -ne $ExpectedLabels.Count -or @($ExpectedLabels | Where-Object { $Job.labels -cnotcontains $_ }).Count -ne 0) { throw 'native_job_labels_invalid' }
	}
	return [pscustomobject][ordered]@{ started=$Started; completed=$Completed }
}

function Assert-ArtifactApiProof {
	param($Artifact, $JobInterval, [string] $ReasonPrefix)
	foreach ($Name in @('created_at','digest')) { if ($Artifact.PSObject.Properties.Name -cnotcontains $Name) { throw 'api_schema_invalid' } }
	$Created = ConvertFrom-AggregateApiTimestamp -Value $Artifact.created_at -Reason ($ReasonPrefix + '_created_at_invalid')
	if ($Created -lt $JobInterval.started -or $Created -gt $JobInterval.completed) { throw ($ReasonPrefix + '_created_at_invalid') }
	if ($Artifact.digest -isnot [string] -or $Artifact.digest -cnotmatch '^sha256:[0-9a-f]{64}$') { throw ($ReasonPrefix + '_digest_invalid') }
}

function Assert-ArtifactWorkflowRunIdentity {
	param($WorkflowRun, $Context, [string] $Reason)
	if ($WorkflowRun -isnot [pscustomobject] -or $WorkflowRun.PSObject.Properties.Name -cnotcontains 'id' -or $WorkflowRun.PSObject.Properties.Name -cnotcontains 'head_sha' -or
		($WorkflowRun.id -isnot [int] -and $WorkflowRun.id -isnot [long]) -or [string] $WorkflowRun.id -cne $Context.run.id -or
		$WorkflowRun.head_sha -isnot [string] -or $WorkflowRun.head_sha -cne $Context.source.headRevision) { throw $Reason }
}

function New-CiAcceptanceAggregate {
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'The function constructs and returns an in-memory immutable report.')]
	param(
		[Parameter(Mandatory)] $Context,
		[Parameter(Mandatory)] $Requirements,
		[Parameter(Mandatory)] [scriptblock] $ApiRequest,
		[ValidateRange(10, 300)] [int] $DeadlineSeconds = 120,
		[Diagnostics.Stopwatch] $Clock,
		$Budget
	)
	if ($null -eq $Clock) { $Clock = [Diagnostics.Stopwatch]::StartNew() }
	if ($null -eq $Budget) { $Budget = New-AggregateBudget }
	Assert-AggregateDeadline -Clock $Clock -DeadlineSeconds $DeadlineSeconds
	Assert-AcceptanceContext -Context $Context
	Assert-AggregateDeadline -Clock $Clock -DeadlineSeconds $DeadlineSeconds
	Assert-AcceptanceRequirements -Requirements $Requirements -Context $Context
	Assert-AggregateDeadline -Clock $Clock -DeadlineSeconds $DeadlineSeconds
	$RepositoryPath = $Context.repository.fullName
	$RunPath = '/repos/' + $RepositoryPath + '/actions/runs/' + $Context.run.id
	$RunBytes = Invoke-AggregateApi -ApiRequest $ApiRequest -Uri $RunPath -Clock $Clock -DeadlineSeconds $DeadlineSeconds -MaximumBytes $script:AggregateLimits.apiResponseBytes -Budget $Budget -RequestKind Api
	$Run = ConvertFrom-StrictBoundedJson -Bytes $RunBytes -MaximumBytes $script:AggregateLimits.apiResponseBytes -MaximumDepth 32 -MaximumProperties 8192 -MaximumArrayItems $script:AggregateLimits.apiItems
	Assert-AggregateDeadline -Clock $Clock -DeadlineSeconds $DeadlineSeconds
	foreach ($Name in @('id','run_attempt','workflow_id','event','head_sha','actor','triggering_actor')) { if ($Run.PSObject.Properties.Name -cnotcontains $Name) { throw 'api_schema_invalid' } }
	if ($null -eq $Run.actor -or $Run.actor -isnot [pscustomobject] -or $Run.actor.PSObject.Properties.Name -cnotcontains 'login' -or
		$null -eq $Run.triggering_actor -or $Run.triggering_actor -isnot [pscustomobject] -or $Run.triggering_actor.PSObject.Properties.Name -cnotcontains 'login') { throw 'api_run_actor_invalid' }
	if (-not (Test-GitHubLogin $Run.actor.login) -or -not (Test-GitHubLogin $Run.triggering_actor.login) -or
		$Run.actor.login -cne $Context.event.actor -or $Run.triggering_actor.login -cne $Context.event.triggeringActor) { throw 'run_actor_mismatch' }
	if ([string] $Run.id -cne $Context.run.id -or [string] $Run.workflow_id -cne $Context.workflow.id -or $Run.event -cne $Context.event.kind -or $Run.head_sha -cne $Context.source.headRevision) { throw 'run_identity_mismatch' }
	if ($Run.run_attempt -isnot [int] -or $Run.run_attempt -gt $Context.run.attempt) { throw 'run_attempt_stale' }
	if ($Run.run_attempt -lt $Context.run.attempt) { throw 'run_attempt_unavailable' }

	$WorkflowRunsBase = '/repos/' + $RepositoryPath + '/actions/workflows/' + $Context.workflow.id + '/runs?event=' + $Context.event.kind + '&head_sha=' + $Context.source.headRevision
	$WorkflowRuns = Get-PagedApiItems -ApiRequest $ApiRequest -BaseUri $WorkflowRunsBase -PropertyName 'workflow_runs' -Clock $Clock -DeadlineSeconds $DeadlineSeconds -Budget $Budget
	$CurrentIndex = -1
	for ($Index = 0; $Index -lt $WorkflowRuns.Count; $Index++) { if ([string] $WorkflowRuns[$Index].id -ceq $Context.run.id) { $CurrentIndex = $Index; break } }
	if ($CurrentIndex -lt 0) { throw 'workflow_run_not_listed' }
	if ($CurrentIndex -ne 0) { throw 'newer_workflow_run_observed' }

	$AttemptJobsBase = $RunPath + '/attempts/' + $Context.run.attempt + '/jobs'
	$AttemptJobs = Get-PagedApiItems -ApiRequest $ApiRequest -BaseUri $AttemptJobsBase -PropertyName 'jobs' -Clock $Clock -DeadlineSeconds $DeadlineSeconds -Budget $Budget
	$AllJobs = Get-PagedApiItems -ApiRequest $ApiRequest -BaseUri ($RunPath + '/jobs?filter=all') -PropertyName 'jobs' -Clock $Clock -DeadlineSeconds $DeadlineSeconds -Budget $Budget
	foreach ($HistoricalJob in $AllJobs) { Assert-ApiJob -Job $HistoricalJob }
	$SelectorJobs = @($AttemptJobs | Where-Object { $_.name -ceq 'ci-selection-shadow' })
	if ($SelectorJobs.Count -ne 1) { throw 'selector_job_identity_ambiguous' }
	$SelectorJob = $SelectorJobs[0]
	Assert-ApiJob -Job $SelectorJob
	if ($SelectorJob.run_attempt -ne $Context.run.attempt) { throw 'selector_job_attempt_mismatch' }
	if ($SelectorJob.status -cne 'completed' -or $SelectorJob.conclusion -cne 'success') { throw 'selector_job_not_success' }
	$SelectorHistory = @($AllJobs | Where-Object { $_.name -ceq 'ci-selection-shadow' })
	if ($SelectorHistory.Count -eq 0) { throw 'selector_job_history_missing' }
	if (@($SelectorHistory | Where-Object { $_.run_attempt -eq $Context.run.attempt }).Count -ne 1) { throw 'selector_job_history_ambiguous' }
	$SelectorHighestAttempt = ($SelectorHistory | Measure-Object -Property run_attempt -Maximum).Maximum
	if ($SelectorHighestAttempt -gt $Context.run.attempt) { throw 'newer_selector_attempt_observed' }
	if ($SelectorHighestAttempt -lt $Context.run.attempt) { throw 'selector_job_attempt_missing' }
	$SelectorJobInterval = Get-CurrentApiJobInterval -Job $SelectorJob -Context $Context -ExpectedConclusion 'success'

	$Artifacts = Get-PagedApiItems -ApiRequest $ApiRequest -BaseUri ($RunPath + '/artifacts') -PropertyName 'artifacts' -Clock $Clock -DeadlineSeconds $DeadlineSeconds -Budget $Budget
	Assert-AggregateDeadline -Clock $Clock -DeadlineSeconds $DeadlineSeconds
	$SelectorArtifactPrefix = 'ci-selection-shadow-' + $Context.run.id + '-' + $Context.run.attempt + '-'
	$SelectorArtifactName = 'ci-selection-shadow-' + $Context.run.id + '-' + $Context.run.attempt + '-' + $Context.attemptAnchor.nonce
	$SelectorAttemptArtifacts = @($Artifacts | Where-Object { $_.name -is [string] -and $_.name.StartsWith($SelectorArtifactPrefix, [StringComparison]::Ordinal) })
	if ($SelectorAttemptArtifacts.Count -ne 1 -or $SelectorAttemptArtifacts[0].name -cne $SelectorArtifactName) { throw 'selector_artifact_identity_ambiguous' }
	$SelectorArtifact = $SelectorAttemptArtifacts[0]
	foreach ($Name in @('id','name','size_in_bytes','archive_download_url','expired','workflow_run','created_at','digest')) { if ($SelectorArtifact.PSObject.Properties.Name -cnotcontains $Name) { throw 'api_schema_invalid' } }
	if ($SelectorArtifact.expired -ne $false) { throw 'selector_artifact_identity_mismatch' }
	Assert-ArtifactWorkflowRunIdentity -WorkflowRun $SelectorArtifact.workflow_run -Context $Context -Reason 'selector_artifact_identity_mismatch'
	if (($SelectorArtifact.id -isnot [int] -and $SelectorArtifact.id -isnot [long]) -or [long]$SelectorArtifact.id -le 0 -or
		($SelectorArtifact.size_in_bytes -isnot [int] -and $SelectorArtifact.size_in_bytes -isnot [long]) -or [long]$SelectorArtifact.size_in_bytes -le 0 -or [long]$SelectorArtifact.size_in_bytes -gt $script:AggregateLimits.archiveBytes) { throw 'selector_artifact_size_invalid' }
	if ($SelectorArtifact.archive_download_url -isnot [string] -or $SelectorArtifact.archive_download_url -cnotmatch '^https://') { throw 'selector_artifact_url_invalid' }
	Assert-ArtifactApiProof -Artifact $SelectorArtifact -JobInterval $SelectorJobInterval -ReasonPrefix 'selector_artifact'
	$SelectorArchiveBytes = Invoke-AggregateApi -ApiRequest $ApiRequest -Uri ([string]$SelectorArtifact.archive_download_url) -Clock $Clock -DeadlineSeconds $DeadlineSeconds -MaximumBytes $script:AggregateLimits.archiveBytes -Budget $Budget -RequestKind Artifact
	if ($SelectorArchiveBytes.Length -ne [long]$SelectorArtifact.size_in_bytes) { throw 'selector_artifact_size_mismatch' }
	if ($SelectorArtifact.digest.Substring(7) -cne (Get-Sha256Hex $SelectorArchiveBytes)) { throw 'selector_artifact_digest_mismatch' }
	$SelectorArchive = Read-StrictCiArchive -Bytes $SelectorArchiveBytes -Clock $Clock -DeadlineSeconds $DeadlineSeconds -Budget $Budget
	if ($SelectorArchive.entries.Count -ne 1 -or $SelectorArchive.entries[0].name -cne 'ci-selection-shadow.json') { throw 'selector_archive_entries_invalid' }
	$SelectorReportEntry = $SelectorArchive.entries[0]
	$SelectedChecks = Read-AcceptedSelectorReport -ReportBytes $SelectorReportEntry.bytes -Context $Context
	Assert-AggregateDeadline -Clock $Clock -DeadlineSeconds $DeadlineSeconds
	$SelectedCheckList = @($script:SelectorCheckIds | Where-Object { $SelectedChecks.Contains($_) })

	$ObservedJobs = New-Object System.Collections.Generic.List[object]
	$SelectedByKey = @{}
	$ProducerJobsByKey = @{}
	foreach ($Requirement in $Requirements.jobs) {
		Assert-AggregateDeadline -Clock $Clock -DeadlineSeconds $DeadlineSeconds
		$SelectedSubset = @($Requirement.checks | Where-Object { $SelectedChecks.Contains([string]$_) })
		$SelectedByKey[[string]$Requirement.key] = $SelectedSubset
		$IsSelected = $SelectedSubset.Count -gt 0
		$JobMatches = @($AttemptJobs | Where-Object { $_.name -ceq $Requirement.jobName })
		if ($JobMatches.Count -eq 0) { throw 'partial_rerun_missing_job' }
		if ($JobMatches.Count -ne 1) { throw 'job_identity_ambiguous' }
		$Job = $JobMatches[0]
		Assert-ApiJob -Job $Job
		if ($Job.run_attempt -ne $Context.run.attempt) { throw 'job_attempt_mismatch' }
		$ExpectedConclusion = if ($IsSelected) { 'success' } else { 'skipped' }
		if ($Job.status -cne 'completed' -or $Job.conclusion -cne $ExpectedConclusion) { throw 'job_conclusion_not_expected' }
		$null = Get-CurrentApiJobInterval -Job $Job -Context $Context -ExpectedConclusion $ExpectedConclusion
		$Historical = @($AllJobs | Where-Object { $_.name -ceq $Requirement.jobName })
		if ($Historical.Count -eq 0) { throw 'job_history_missing' }
		$Highest = ($Historical | Measure-Object -Property run_attempt -Maximum).Maximum
		if ($Highest -gt $Context.run.attempt) { throw 'newer_job_attempt_observed' }
		if ($Highest -lt $Context.run.attempt) { throw 'partial_rerun_missing_job' }
		$ProducerJobsByKey[[string]$Requirement.key] = $Job
		$ObservedJobs.Add([pscustomobject][ordered]@{ key = [string] $Requirement.key; id = [string] $Job.id; name = [string] $Job.name; selected = $IsSelected; capabilityChecks = @($Requirement.checks); selectedChecks = $SelectedSubset; attempt = [int] $Job.run_attempt; conclusion = [string] $Job.conclusion })
	}

	$Receipts = New-Object System.Collections.Generic.List[object]
	foreach ($Requirement in $Requirements.jobs) {
		Assert-AggregateDeadline -Clock $Clock -DeadlineSeconds $DeadlineSeconds
		$SelectedSubset = @($SelectedByKey[[string]$Requirement.key])
		$ArtifactPrefix = 'ci-receipt-' + $Requirement.key + '-' + $Context.run.id + '-' + $Context.run.attempt + '-'
		$ArtifactMatches = @($Artifacts | Where-Object { $_.name -is [string] -and $_.name.StartsWith($ArtifactPrefix, [StringComparison]::Ordinal) })
		if ($SelectedSubset.Count -eq 0) {
			if ($ArtifactMatches.Count -ne 0) { throw 'unselected_artifact_observed' }
			continue
		}
		if ($ArtifactMatches.Count -ne 1 -or $ArtifactMatches[0].name -cne $Requirement.artifactName) { throw 'artifact_identity_ambiguous' }
		$Artifact = $ArtifactMatches[0]
		$ProducerJob = $ProducerJobsByKey[[string]$Requirement.key]
		$ProducerJobInterval = Get-CurrentApiJobInterval -Job $ProducerJob -Context $Context -ExpectedConclusion 'success'
		foreach ($Name in @('id','name','size_in_bytes','archive_download_url','expired','workflow_run','created_at','digest')) { if ($Artifact.PSObject.Properties.Name -cnotcontains $Name) { throw 'api_schema_invalid' } }
		if ($Artifact.expired -ne $false) { throw 'artifact_identity_mismatch' }
		Assert-ArtifactWorkflowRunIdentity -WorkflowRun $Artifact.workflow_run -Context $Context -Reason 'artifact_identity_mismatch'
		if ($Artifact.size_in_bytes -isnot [int] -and $Artifact.size_in_bytes -isnot [long] -or [long] $Artifact.size_in_bytes -le 0 -or [long] $Artifact.size_in_bytes -gt $script:AggregateLimits.archiveBytes) { throw 'artifact_size_invalid' }
		if ($Artifact.archive_download_url -isnot [string] -or $Artifact.archive_download_url -cnotmatch '^https://') { throw 'artifact_url_invalid' }
		Assert-ArtifactApiProof -Artifact $Artifact -JobInterval $ProducerJobInterval -ReasonPrefix 'artifact'
		$ArchiveBytes = Invoke-AggregateApi -ApiRequest $ApiRequest -Uri ([string] $Artifact.archive_download_url) -Clock $Clock -DeadlineSeconds $DeadlineSeconds -MaximumBytes $script:AggregateLimits.archiveBytes -Budget $Budget -RequestKind Artifact
		if ($ArchiveBytes.Length -ne [long]$Artifact.size_in_bytes) { throw 'artifact_size_mismatch' }
		if ($Artifact.digest.Substring(7) -cne (Get-Sha256Hex $ArchiveBytes)) { throw 'artifact_digest_mismatch' }
		$Archive = Read-StrictCiArchive -Bytes $ArchiveBytes -Clock $Clock -DeadlineSeconds $DeadlineSeconds -Budget $Budget
		$ReceiptEntries = @($Archive.entries | Where-Object { $_.name -ceq 'ci-acceptance-receipt.json' })
		if ($ReceiptEntries.Count -ne 1) { throw 'receipt_entry_missing' }
		$Receipt = ConvertFrom-StrictBoundedJson -Bytes $ReceiptEntries[0].bytes
		Assert-AggregateDeadline -Clock $Clock -DeadlineSeconds $DeadlineSeconds
		$SelectedRequirement = [pscustomobject][ordered]@{ key=[string]$Requirement.key; jobName=[string]$Requirement.jobName; artifactName=[string]$Requirement.artifactName; checks=$SelectedSubset }
		$Results = Assert-CiAcceptanceReceipt -Receipt $Receipt -Context $Context -Requirement $SelectedRequirement -Archive $Archive -ProducerJob $ProducerJob
		Assert-AggregateDeadline -Clock $Clock -DeadlineSeconds $DeadlineSeconds
		$Receipts.Add([pscustomobject][ordered]@{
			jobKey = [string] $Requirement.key
			capabilityChecks = @($Requirement.checks)
			selectedChecks = $SelectedSubset
			artifactId = [string] $Artifact.id
			artifactName = [string] $Artifact.name
			artifactCreatedAt = [string] $Artifact.created_at
			artifactApiDigest = [string] $Artifact.digest
			archiveSha256 = [string] $Archive.sha256
			archiveSizeBytes = [long] $Archive.sizeBytes
			receiptSha256 = [string] $ReceiptEntries[0].sha256
			nativeExitCodes = @($Results | ForEach-Object { $_.nativeExitCode })
			cleanupVerified = @($Results | ForEach-Object { $_.cleanupVerified })
		})
	}
	Assert-AggregateDeadline -Clock $Clock -DeadlineSeconds $DeadlineSeconds
	$EvidenceClass = if ($Context.event.kind -ceq 'push') { 'post_merge_hosted_health' } else { 'pull_request_acceptance_candidate' }
	$Aggregate = [pscustomobject][ordered]@{
		schemaVersion = 'aetheln.ci-acceptance-aggregate/v1'
		repository = $Context.repository
		event = $Context.event
		source = $Context.source
		workflow = $Context.workflow
		actions = $Context.actions
		controller = $Context.controller
		policy = $Context.policy
		selectorEvidence = [pscustomobject][ordered]@{
			job=[pscustomobject][ordered]@{id=[string]$SelectorJob.id;name=[string]$SelectorJob.name;attempt=[int]$SelectorJob.run_attempt;conclusion=[string]$SelectorJob.conclusion}
			artifact=[pscustomobject][ordered]@{id=[string]$SelectorArtifact.id;name=[string]$SelectorArtifact.name;createdAt=[string]$SelectorArtifact.created_at;apiDigest=[string]$SelectorArtifact.digest;archiveSha256=[string]$SelectorArchive.sha256;archiveSizeBytes=[long]$SelectorArchive.sizeBytes}
			reportSha256=[string]$SelectorReportEntry.sha256
			selectedChecks=$SelectedCheckList
		}
		run = $Context.run
		attemptAnchor = $Context.attemptAnchor
		jobs = $ObservedJobs.ToArray()
		receipts = $Receipts.ToArray()
		decision = [pscustomobject][ordered]@{ evidenceClass = $EvidenceClass; complete = $true; shadow = $true; authoritative = $false; grantsAcceptance = $false; reason = 'shadow_evidence_reconciled' }
	}
	Assert-AggregateDeadline -Clock $Clock -DeadlineSeconds $DeadlineSeconds
	return $Aggregate
}

function Write-BoundedAggregate {
	param($Aggregate, [string] $Path, [Diagnostics.Stopwatch] $Clock, [int] $DeadlineSeconds = 0, [scriptblock] $FileWriter)
	Assert-AggregateDeadline -Clock $Clock -DeadlineSeconds $DeadlineSeconds
	if ([string]::IsNullOrWhiteSpace($Path)) { throw 'output_path_required' }
	$FullPath = [IO.Path]::GetFullPath($Path)
	$Parent = Split-Path -Parent $FullPath
	if (-not (Test-Path -LiteralPath $Parent -PathType Container)) { throw 'output_parent_missing' }
	if (Test-Path -LiteralPath $FullPath) { throw 'output_exists' }
	$Raw = $Aggregate | ConvertTo-Json -Depth 16 -Compress
	Assert-AggregateDeadline -Clock $Clock -DeadlineSeconds $DeadlineSeconds
	$Bytes = $script:Utf8NoBom.GetBytes($Raw)
	if ($Bytes.Length -gt $script:AggregateLimits.jsonBytes) { throw 'aggregate_size_limit' }
	Assert-AggregateDeadline -Clock $Clock -DeadlineSeconds $DeadlineSeconds
	$TemporaryPath = Join-Path $Parent ('.' + [IO.Path]::GetFileName($FullPath) + '.' + [guid]::NewGuid().ToString('N') + '.tmp')
	$Published = $false
	try {
		if ($null -eq $FileWriter) {
			$Stream = New-Object IO.FileStream($TemporaryPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
			try { $Stream.Write($Bytes, 0, $Bytes.Length); $Stream.Flush($true) }
			finally { $Stream.Dispose() }
		} else { & $FileWriter $TemporaryPath $Bytes }
		Assert-AggregateDeadline -Clock $Clock -DeadlineSeconds $DeadlineSeconds
		[IO.File]::Move($TemporaryPath, $FullPath)
		$Published = $true
		Assert-AggregateDeadline -Clock $Clock -DeadlineSeconds $DeadlineSeconds
	} catch {
		if ($Published -and (Test-Path -LiteralPath $FullPath -PathType Leaf)) { Remove-Item -LiteralPath $FullPath -Force }
		throw
	} finally {
		if (Test-Path -LiteralPath $TemporaryPath -PathType Leaf) { Remove-Item -LiteralPath $TemporaryPath -Force }
	}
	return [long] $Bytes.Length
}

function Invoke-CiAcceptanceAggregateMain {
	param(
		[scriptblock] $ApiRequest,
		[Diagnostics.Stopwatch] $Clock,
		[scriptblock] $AfterWrite,
		[int] $OperationDeadlineSeconds = $DeadlineSeconds
	)
	if ([string]::IsNullOrWhiteSpace($ContextJson) -or [string]::IsNullOrWhiteSpace($RequirementsJson) -or [string]::IsNullOrWhiteSpace($OutputPath)) { throw 'aggregate_arguments_required' }
	if ($OperationDeadlineSeconds -le 0) { throw 'api_deadline_invalid' }
	$OperationClock = if ($null -eq $Clock) { [Diagnostics.Stopwatch]::StartNew() } else { $Clock }
	Assert-AggregateDeadline -Clock $OperationClock -DeadlineSeconds $OperationDeadlineSeconds
	$Context = ConvertFrom-StrictBoundedJson -Bytes $script:StrictUtf8.GetBytes($ContextJson)
	Assert-AggregateDeadline -Clock $OperationClock -DeadlineSeconds $OperationDeadlineSeconds
	$Requirements = ConvertFrom-StrictBoundedJson -Bytes $script:StrictUtf8.GetBytes($RequirementsJson)
	Assert-AggregateDeadline -Clock $OperationClock -DeadlineSeconds $OperationDeadlineSeconds
	$Request = if ($null -eq $ApiRequest) { { param([string] $Uri,[int] $RemainingMilliseconds,[int] $MaximumBytes,[string]$RequestKind,$Budget) Invoke-DefaultBoundedApiRequest -Uri $Uri -RemainingMilliseconds $RemainingMilliseconds -MaximumBytes $MaximumBytes -ApiBaseUri $ApiBaseUri -RequestKind $RequestKind -Budget $Budget }.GetNewClosure() } else { $ApiRequest }
	$Aggregate = New-CiAcceptanceAggregate -Context $Context -Requirements $Requirements -ApiRequest $Request -DeadlineSeconds $OperationDeadlineSeconds -Clock $OperationClock
	Assert-AggregateDeadline -Clock $OperationClock -DeadlineSeconds $OperationDeadlineSeconds
	$OutputPublished = $false
	try {
		[void] (Write-BoundedAggregate -Aggregate $Aggregate -Path $OutputPath -Clock $OperationClock -DeadlineSeconds $OperationDeadlineSeconds)
		$OutputPublished = $true
		if ($null -ne $AfterWrite) { & $AfterWrite }
		Assert-AggregateDeadline -Clock $OperationClock -DeadlineSeconds $OperationDeadlineSeconds
	} catch {
		if ($OutputPublished -and (Test-Path -LiteralPath $OutputPath -PathType Leaf)) { Remove-Item -LiteralPath $OutputPath -Force }
		throw
	}
	return $Aggregate
}

if ($MyInvocation.InvocationName -ne '.') { Invoke-CiAcceptanceAggregateMain }
