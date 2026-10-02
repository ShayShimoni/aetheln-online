[CmdletBinding()]
param(
	[ValidateSet('Identity','Aggregate','Gap')] [string] $Mode,
	[string] $SelectorReportPath,
	[string] $WorkflowPath,
	[string] $RequirementsTemplatePath,
	[string] $Repository,
	[string] $Actor,
	[string] $TriggeringActor,
	[string] $BaseRevision,
	[string] $HeadRevision,
	[string] $TestedRevision,
	[string] $WorkflowId,
	[string] $RunId,
	[int] $RunAttempt,
	[string] $ActionItemsJson,
	[string] $SelectorBindingJson,
	[string] $ProducerBindingsJson,
	[string] $IdentityContextOutputPath,
	[string] $AggregateContextOutputPath,
	[string] $RuntimeRequirementsOutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:AggregateContextUtf8Strict = New-Object Text.UTF8Encoding($false, $true)
$script:AggregateContextUtf8NoBom = New-Object Text.UTF8Encoding($false)
$script:AggregateContextMaximumInputBytes = 1MB
$script:AggregateContextMaximumJsonBytes = 512KB
$script:AggregateContextMaximumOutputBytes = 1MB
$script:AggregateContextCheckIds = @(
	'portable',
	'visual-package',
	'native-client-server-compile',
	'unreal-editor-automation',
	'content-reference-validation',
	'controller-contract',
	'controller-operational-proof',
	'clean-package-provenance-smoke'
)

function Initialize-AggregateContextStrictJsonGuard {
	if ('Aetheln.AggregateContextStrictJsonGuard' -as [type]) { return }
	Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Text;
namespace Aetheln {
 public static class AggregateContextStrictJsonGuard {
  sealed class Parser {
   readonly string text; readonly int maxDepth, maxProperties, maxArrayItems;
   int index, properties, arrayItems;
   public Parser(string value, int depth, int propertyLimit, int arrayLimit) { text=value; maxDepth=depth; maxProperties=propertyLimit; maxArrayItems=arrayLimit; }
   void Fail(string reason) { throw new InvalidDataException(reason); }
   void White() { while (index < text.Length && (text[index]==' ' || text[index]=='\t' || text[index]=='\r' || text[index]=='\n')) index++; }
   bool Take(char value) { White(); if (index < text.Length && text[index] == value) { index++; return true; } return false; }
   void Need(char value) { if (!Take(value)) Fail("json_syntax_invalid"); }
   int Hex(char value) { if(value>='0'&&value<='9')return value-'0';if(value>='a'&&value<='f')return value-'a'+10;if(value>='A'&&value<='F')return value-'A'+10;Fail("json_syntax_invalid");return 0; }
   string StringValue() {
    White(); if(index>=text.Length||text[index++]!='"')Fail("json_syntax_invalid"); var result=new StringBuilder();
    while(index<text.Length){char current=text[index++];if(current=='"')return result.ToString();if(current<0x20)Fail("json_syntax_invalid");if(current!='\\'){result.Append(current);continue;}if(index>=text.Length)Fail("json_syntax_invalid");char escape=text[index++];
     switch(escape){case '"':result.Append('"');break;case '\\':result.Append('\\');break;case '/':result.Append('/');break;case 'b':result.Append('\b');break;case 'f':result.Append('\f');break;case 'n':result.Append('\n');break;case 'r':result.Append('\r');break;case 't':result.Append('\t');break;case 'u':if(index+4>text.Length)Fail("json_syntax_invalid");int code=(Hex(text[index])<<12)|(Hex(text[index+1])<<8)|(Hex(text[index+2])<<4)|Hex(text[index+3]);index+=4;result.Append((char)code);break;default:Fail("json_syntax_invalid");break;}}
    Fail("json_syntax_invalid"); return null;
   }
   void Literal(string value){if(index+value.Length>text.Length||String.CompareOrdinal(text,index,value,0,value.Length)!=0)Fail("json_syntax_invalid");index+=value.Length;}
   void Number(){int start=index;if(index<text.Length&&text[index]=='-')index++;if(index>=text.Length)Fail("json_syntax_invalid");if(text[index]=='0')index++;else{if(text[index]<'1'||text[index]>'9')Fail("json_syntax_invalid");while(index<text.Length&&text[index]>='0'&&text[index]<='9')index++;}if(index<text.Length&&text[index]=='.'){index++;int digits=index;while(index<text.Length&&text[index]>='0'&&text[index]<='9')index++;if(index==digits)Fail("json_syntax_invalid");}if(index<text.Length&&(text[index]=='e'||text[index]=='E')){index++;if(index<text.Length&&(text[index]=='+'||text[index]=='-'))index++;int digits=index;while(index<text.Length&&text[index]>='0'&&text[index]<='9')index++;if(index==digits)Fail("json_syntax_invalid");}if(index==start)Fail("json_syntax_invalid");}
   void Value(int depth){White();if(index>=text.Length)Fail("json_syntax_invalid");char current=text[index];if(current=='{'){ObjectValue(depth+1);return;}if(current=='['){ArrayValue(depth+1);return;}if(current=='"'){StringValue();return;}if(current=='t'){Literal("true");return;}if(current=='f'){Literal("false");return;}if(current=='n'){Literal("null");return;}Number();}
   void ObjectValue(int depth){if(depth>maxDepth)Fail("json_depth_limit");Need('{');var names=new HashSet<string>(StringComparer.Ordinal);if(Take('}'))return;while(true){string name=StringValue();if(!names.Add(name))Fail("json_duplicate_property");properties++;if(properties>maxProperties)Fail("json_property_limit");Need(':');Value(depth);if(Take('}'))return;Need(',');}}
   void ArrayValue(int depth){if(depth>maxDepth)Fail("json_depth_limit");Need('[');if(Take(']'))return;while(true){arrayItems++;if(arrayItems>maxArrayItems)Fail("json_array_limit");Value(depth);if(Take(']'))return;Need(',');}}
   public void Parse(){Value(0);White();if(index!=text.Length)Fail("json_syntax_invalid");}
  }
  public static void Validate(string value,int maxDepth,int maxProperties,int maxArrayItems){new Parser(value,maxDepth,maxProperties,maxArrayItems).Parse();}
 }
}
'@
}

function Assert-ClosedAggregateContextObject {
	param($Value, [string[]] $Names, [string] $Reason)
	if ($null -eq $Value -or $Value -isnot [pscustomobject]) { throw $Reason }
	$Actual = @($Value.PSObject.Properties | ForEach-Object { $_.Name })
	if ($Actual.Count -ne $Names.Count) { throw $Reason }
	foreach ($Name in $Names) { if ($Actual -cnotcontains $Name) { throw $Reason } }
}

function ConvertFrom-StrictAggregateContextJson {
	param([string] $Raw, [ValidateSet('Object','Array')] [string] $RootKind)
	if ($null -eq $Raw -or $Raw.Length -eq 0 -or $script:AggregateContextUtf8NoBom.GetByteCount($Raw) -gt $script:AggregateContextMaximumJsonBytes) { throw 'json_size_invalid' }
	if ($Raw[0] -eq [char]0xFEFF -or $Raw.Trim() -cne $Raw) { throw 'json_canonical_bytes_invalid' }
	if (($RootKind -ceq 'Object' -and ($Raw[0] -ne '{' -or $Raw[$Raw.Length-1] -ne '}')) -or
		($RootKind -ceq 'Array' -and ($Raw[0] -ne '[' -or $Raw[$Raw.Length-1] -ne ']'))) { throw 'json_schema_invalid' }
	Initialize-AggregateContextStrictJsonGuard
	try { [Aetheln.AggregateContextStrictJsonGuard]::Validate($Raw, 16, 65536, 32768) }
	catch { if ($_.Exception.InnerException) { throw $_.Exception.InnerException.Message }; throw $_.Exception.Message }
	try { $Value = $Raw | ConvertFrom-Json }
	catch { throw 'json_schema_invalid' }
	if ($RootKind -ceq 'Object' -and $Value -isnot [pscustomobject]) { throw 'json_schema_invalid' }
	return $Value
}

function Test-AggregateContextRevision($Value) { return $Value -is [string] -and $Value -cmatch '\A[0-9a-f]{40}\z' }
function Test-AggregateContextSha256($Value) { return $Value -is [string] -and $Value -cmatch '\A[0-9a-f]{64}\z' }
function Test-AggregateContextDecimal($Value) {
	if ($Value -isnot [string] -or $Value -cnotmatch '\A[1-9][0-9]{0,18}\z') { return $false }
	$Parsed = [long]0
	return [long]::TryParse($Value, [Globalization.NumberStyles]::None, [Globalization.CultureInfo]::InvariantCulture, [ref]$Parsed) -and $Parsed -gt 0
}
function Test-AggregateContextLogin($Value) { return $Value -is [string] -and $Value -cmatch '\A[A-Za-z0-9][A-Za-z0-9_\-\[\]]{0,99}\z' }

function Get-AggregateContextSha256Hex {
	param([byte[]] $Bytes)
	$Hasher = [Security.Cryptography.SHA256]::Create()
	try { return ([BitConverter]::ToString($Hasher.ComputeHash($Bytes))).Replace('-','').ToLowerInvariant() }
	finally { $Hasher.Dispose() }
}

function Assert-NoAggregateContextTraversal {
	param([string] $Path)
	if ([string]::IsNullOrWhiteSpace($Path) -or $Path.IndexOf([char]0) -ge 0 -or $Path.Length -gt 32767) { throw 'path_invalid' }
	if (-not [IO.Path]::IsPathRooted($Path)) { throw 'path_not_rooted' }
	if ($Path.StartsWith('\\?\',[StringComparison]::Ordinal) -or $Path.StartsWith('\\.\',[StringComparison]::Ordinal)) { throw 'path_invalid' }
	$Root = [IO.Path]::GetPathRoot($Path)
	$Relative = $Path.Substring($Root.Length)
	if ($Relative.Contains(':')) { throw 'path_invalid' }
	$Segments = @($Relative -split '[\\/]' | Where-Object { $_.Length -gt 0 })
	foreach ($Segment in $Segments) {
		if ($Segment -ceq '.' -or $Segment -ceq '..') { throw 'path_traversal_rejected' }
		if ($Segment.Length -gt 255 -or $Segment.EndsWith('.') -or $Segment.EndsWith(' ') -or $Segment.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0) { throw 'path_invalid' }
	}
}

function Assert-NoAggregateContextReparsePoint {
	param([string] $FullPath, [switch] $AllowMissingLeaf)
	$Current = $FullPath
	if ($AllowMissingLeaf -and -not (Test-Path -LiteralPath $Current)) { $Current = Split-Path -Parent $Current }
	while (-not [string]::IsNullOrEmpty($Current)) {
		if (Test-Path -LiteralPath $Current) {
			$Item = Get-Item -LiteralPath $Current -Force
			if (($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'input_reparse_rejected' }
		}
		$Parent = Split-Path -Parent $Current
		if ($Parent -ceq $Current) { break }
		$Current = $Parent
	}
}

function Resolve-AggregateContextInputPath {
	param([string] $Path)
	Assert-NoAggregateContextTraversal $Path
	$FullPath = [IO.Path]::GetFullPath($Path)
	if (-not (Test-Path -LiteralPath $FullPath -PathType Leaf)) { throw 'input_missing' }
	Assert-NoAggregateContextReparsePoint $FullPath
	$Length = (Get-Item -LiteralPath $FullPath -Force).Length
	if ($Length -le 0 -or $Length -gt $script:AggregateContextMaximumInputBytes) { throw 'input_size_limit' }
	return $FullPath
}

function Resolve-AggregateContextOutputPath {
	param([string] $Path)
	Assert-NoAggregateContextTraversal $Path
	$FullPath = [IO.Path]::GetFullPath($Path)
	if (Test-Path -LiteralPath $FullPath) { throw 'output_exists' }
	$Parent = Split-Path -Parent $FullPath
	if (-not (Test-Path -LiteralPath $Parent -PathType Container)) { throw 'output_parent_missing' }
	try { Assert-NoAggregateContextReparsePoint $FullPath -AllowMissingLeaf }
	catch { if ($_.Exception.Message -ceq 'input_reparse_rejected') { throw 'output_reparse_rejected' }; throw }
	return $FullPath
}

function Read-BoundedAggregateContextFileBytes {
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'The established internal name describes the exact bounded byte sequence returned; renaming every reviewed call site would add unrelated churn.')]
	param([string] $Path)
	$FullPath=Resolve-AggregateContextInputPath $Path
	$Stream=$null
	try{
		$Stream=New-Object IO.FileStream($FullPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
		if($Stream.Length-le 0 -or $Stream.Length-gt$script:AggregateContextMaximumInputBytes){throw 'input_size_limit'}
		$Bytes=New-Object byte[] ([int]$Stream.Length);$Offset=0
		while($Offset-lt$Bytes.Length){$Read=$Stream.Read($Bytes,$Offset,$Bytes.Length-$Offset);if($Read-le 0){throw 'input_read_incomplete'};$Offset+=$Read}
		if($Stream.ReadByte()-ne -1){throw 'input_size_changed'}
		Assert-NoAggregateContextReparsePoint $FullPath
		return ,$Bytes
	}finally{if($null-ne$Stream){$Stream.Dispose()}}
}

function Read-StrictAggregateContextFileJson {
	param([string] $Path, [ValidateSet('Object','Array')] [string] $RootKind, [switch] $RequireSingleTrailingLf)
	$Bytes = Read-BoundedAggregateContextFileBytes $Path
	try { $Raw = $script:AggregateContextUtf8Strict.GetString($Bytes) }
	catch { throw 'input_utf8_invalid' }
	if ($RequireSingleTrailingLf) {
		if (-not $Raw.EndsWith("`n", [StringComparison]::Ordinal)) { throw 'json_canonical_bytes_invalid' }
		$Raw = $Raw.Substring(0, $Raw.Length - 1)
	}
	return ConvertFrom-StrictAggregateContextJson -Raw $Raw -RootKind $RootKind
}

function Assert-AggregateContextArguments {
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Validates the complete invocation argument set as one closed identity boundary.')]
	param([string] $RepositoryValue,[string] $ActorValue,[string] $TriggeringActorValue,[string] $Base,[string] $Head,[string] $Tested,[string] $WorkflowIdentity,[string] $RunIdentity,[int] $Attempt)
	if ($RepositoryValue -notmatch '\A[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})/[A-Za-z0-9._-]{1,100}\z') { throw 'repository_invalid' }
	if (-not (Test-AggregateContextLogin $ActorValue) -or -not (Test-AggregateContextLogin $TriggeringActorValue)) { throw 'actor_invalid' }
	if (-not (Test-AggregateContextRevision $Base) -or -not (Test-AggregateContextRevision $Head) -or -not (Test-AggregateContextRevision $Tested) -or $Base -ceq $Head) { throw 'revision_invalid' }
	if (-not (Test-AggregateContextDecimal $WorkflowIdentity) -or -not (Test-AggregateContextDecimal $RunIdentity) -or $Attempt -lt 1) { throw 'run_identity_invalid' }
}

function Read-AndAssertAggregateContextSelector {
	param([string] $Path,[string] $Base,[string] $Head,[string] $Tested,[string] $ExpectedRunId,[int] $ExpectedRunAttempt,[switch] $AllowUnavailable)
	$Report = Read-StrictAggregateContextFileJson -Path $Path -RootKind Object -RequireSingleTrailingLf
	Assert-ClosedAggregateContextObject -Value $Report -Names @('schemaVersion','attemptAnchor','policy','source','execution','classification','selection','legacyAuthority','comparison') -Reason 'selector_schema_invalid'
	if ($Report.schemaVersion -isnot [string] -or $Report.schemaVersion -cne 'aetheln.ci-selection/v1') { throw 'selector_schema_invalid' }
	Assert-ClosedAggregateContextObject -Value $Report.attemptAnchor -Names @('schemaVersion','runId','runAttempt','nonce') -Reason 'selector_identity_invalid'
	if ($Report.attemptAnchor.schemaVersion -isnot [string] -or $Report.attemptAnchor.schemaVersion -cne 'aetheln.current-attempt-anchor/v1' -or
		$Report.attemptAnchor.runId -isnot [string] -or -not (Test-AggregateContextDecimal $Report.attemptAnchor.runId) -or
		$Report.attemptAnchor.runAttempt -isnot [int] -or $Report.attemptAnchor.runAttempt -lt 1 -or
		$Report.attemptAnchor.nonce -isnot [string] -or $Report.attemptAnchor.nonce -cnotmatch '\A[0-9a-f]{64}\z' -or $Report.attemptAnchor.nonce -ceq ('0'*64)) { throw 'selector_identity_invalid' }
	if ($Report.attemptAnchor.runId -cne $ExpectedRunId -or $Report.attemptAnchor.runAttempt -ne $ExpectedRunAttempt) { throw 'selector_identity_mismatch' }

	Assert-ClosedAggregateContextObject -Value $Report.policy -Names @('version','digest','checkIds') -Reason 'selector_policy_invalid'
	if ($Report.policy.version -isnot [string] -or $Report.policy.version -cnotmatch '\A[a-z0-9][a-z0-9._-]{0,63}\z' -or -not (Test-AggregateContextSha256 $Report.policy.digest) -or
		$Report.policy.checkIds -isnot [array] -or (@($Report.policy.checkIds)-join "`n") -cne ($script:AggregateContextCheckIds-join "`n")) { throw 'selector_policy_invalid' }

	Assert-ClosedAggregateContextObject -Value $Report.source -Names @('kind','callerKind','baseRevision','headRevision','workflowRevision','revision') -Reason 'selector_identity_invalid'
	if ($Report.source.kind -cne 'pull_request' -or $null -ne $Report.source.callerKind -or $Report.source.baseRevision -cne $Base -or
		$Report.source.headRevision -cne $Head -or $Report.source.workflowRevision -cne $Tested -or $null -ne $Report.source.revision) { throw 'selector_identity_mismatch' }

	Assert-ClosedAggregateContextObject -Value $Report.execution -Names @('mode','controllerRevision','controllerBlobOid','controllerSha256','checkoutAllowed','complete','reason') -Reason 'selector_execution_invalid'
	$Unavailable = $Report.execution.mode -ceq 'accepted_controller_unavailable'
	if ($Unavailable) {
		if (-not $AllowUnavailable) { throw 'selector_execution_invalid' }
		if ($Report.execution.controllerRevision -cne $Base -or $null -ne $Report.execution.controllerBlobOid -or
			$null -ne $Report.execution.controllerSha256 -or $Report.execution.checkoutAllowed -ne $false -or
			$Report.execution.complete -ne $true -or $Report.execution.reason -cne 'accepted_controller_unavailable') { throw 'selector_fallback_invalid' }
	} elseif ($Report.execution.mode -cne 'accepted-base' -or $Report.execution.controllerRevision -cne $Base -or
		-not (Test-AggregateContextRevision $Report.execution.controllerBlobOid) -or -not (Test-AggregateContextSha256 $Report.execution.controllerSha256) -or
		$Report.execution.checkoutAllowed -ne $false -or $Report.execution.complete -ne $true -or $Report.execution.reason -isnot [string] -or $Report.execution.reason -cnotmatch '\A[a-z0-9_]{1,100}\z') { throw 'selector_execution_invalid' }

	Assert-ClosedAggregateContextObject -Value $Report.classification -Names @('changedPaths','entries','uncertainties') -Reason 'selector_schema_invalid'
	Assert-ClosedAggregateContextObject -Value $Report.selection -Names @('shadow','authoritative','obligations') -Reason 'selector_selection_invalid'
	Assert-ClosedAggregateContextObject -Value $Report.legacyAuthority -Names @('authoritative','engineRequired','reason') -Reason 'selector_schema_invalid'
	Assert-ClosedAggregateContextObject -Value $Report.comparison -Names @('status','differences') -Reason 'selector_schema_invalid'
	if ($Report.classification.changedPaths -isnot [array] -or $Report.classification.entries -isnot [array] -or $Report.classification.uncertainties -isnot [array] -or
		$Report.selection.shadow -ne $true -or $Report.selection.authoritative -ne $false -or $Report.selection.obligations -isnot [array] -or
		$Report.legacyAuthority.authoritative -ne $true -or ($null -ne $Report.legacyAuthority.engineRequired -and $Report.legacyAuthority.engineRequired -isnot [bool]) -or
		$Report.legacyAuthority.reason -isnot [string] -or $Report.comparison.status -isnot [string] -or $Report.comparison.differences -isnot [array]) { throw 'selector_schema_invalid' }
	$Obligations = @($Report.selection.obligations)
	if ($Obligations.Count -ne $script:AggregateContextCheckIds.Count) { throw 'selector_selection_invalid' }
	$Selected = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
	for ($Index=0;$Index -lt $Obligations.Count;$Index++) {
		$Obligation=$Obligations[$Index]
		Assert-ClosedAggregateContextObject -Value $Obligation -Names @('id','selected','reasons') -Reason 'selector_selection_invalid'
		if ($Obligation.id -isnot [string] -or $Obligation.id -cne $script:AggregateContextCheckIds[$Index] -or $Obligation.selected -isnot [bool] -or $Obligation.reasons -isnot [array] -or
			@($Obligation.reasons | Where-Object { $_ -isnot [string] -or $_.Length -lt 1 -or $_.Length -gt 4096 }).Count -ne 0 -or
			($Obligation.selected -and @($Obligation.reasons).Count -eq 0) -or (-not $Obligation.selected -and @($Obligation.reasons).Count -ne 0)) { throw 'selector_selection_invalid' }
		if ($Obligation.selected) { [void]$Selected.Add($Obligation.id) }
	}
	if ($Unavailable) {
		if ($Report.policy.version -cne 'shadow-v1' -or $Report.policy.digest -cne ('0'*64) -or
			@($Report.classification.changedPaths).Count -ne 0 -or @($Report.classification.entries).Count -ne 0 -or
			(@($Report.classification.uncertainties) -join ',') -cne 'accepted_controller_unavailable' -or
			$null -ne $Report.legacyAuthority.engineRequired -or $Report.legacyAuthority.reason -cne 'not_observed' -or
			$Report.comparison.status -cne 'unavailable' -or (@($Report.comparison.differences) -join ',') -cne 'accepted_controller_unavailable' -or
			$Selected.Count -ne $script:AggregateContextCheckIds.Count) { throw 'selector_fallback_invalid' }
		foreach ($Obligation in $Obligations) {
			if ((@($Obligation.reasons) -join ',') -cne 'accepted_controller_unavailable') { throw 'selector_fallback_invalid' }
		}
	}
	return [pscustomobject]@{Report=$Report;Selected=$Selected;AcceptedControllerUnavailable=$Unavailable}
}

function Read-AndAssertAggregateContextActions {
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Validates and returns the complete reviewed action manifest.')]
	param([string] $Json)
	$Parsed = ConvertFrom-StrictAggregateContextJson -Raw $Json -RootKind Array
	$Items = @($Parsed)
	if ($Items.Count -lt 1 -or $Items.Count -gt 32) { throw 'actions_count_invalid' }
	$Names = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
	$Lines = New-Object Collections.Generic.List[string]
	$Previous = $null
	foreach ($Item in $Items) {
		Assert-ClosedAggregateContextObject -Value $Item -Names @('uses','revision') -Reason 'actions_schema_invalid'
		if ($Item.uses -isnot [string] -or $Item.uses -cnotmatch '\A[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)*\z' -or
			-not (Test-AggregateContextRevision $Item.revision) -or -not $Names.Add($Item.uses)) { throw 'actions_schema_invalid' }
		if ($null -ne $Previous -and [StringComparer]::Ordinal.Compare($Previous,$Item.uses) -ge 0) { throw 'actions_not_sorted' }
		$Previous=$Item.uses;$Lines.Add($Item.uses+'@'+$Item.revision)
	}
	$Digest=Get-AggregateContextSha256Hex $script:AggregateContextUtf8NoBom.GetBytes(($Lines.ToArray()-join "`n")+"`n")
	return [pscustomobject][ordered]@{manifestSha256=$Digest;items=$Items}
}

function Read-AndAssertAggregateContextTemplate {
	param([string] $Path)
	$Template=Read-StrictAggregateContextFileJson -Path $Path -RootKind Object -RequireSingleTrailingLf
	Assert-ClosedAggregateContextObject -Value $Template -Names @('schemaVersion','jobs') -Reason 'requirements_schema_invalid'
	if ($Template.schemaVersion -cne 'aetheln.ci-acceptance-requirements-template/v1' -or $Template.jobs -isnot [array]) { throw 'requirements_schema_invalid' }
	$Jobs=@($Template.jobs)
	if ($Jobs.Count -lt 1 -or $Jobs.Count -gt 32) { throw 'requirements_count_invalid' }
	$Ids=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
	$Keys=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
	$JobNames=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
	$PreviousKey=$null
	foreach($Job in $Jobs){
		Assert-ClosedAggregateContextObject -Value $Job -Names @('key','jobName','checks') -Reason 'requirements_schema_invalid'
		if($Job.key -isnot [string] -or $Job.key -cnotmatch '\A[a-z0-9][a-z0-9-]{0,63}\z' -or $Job.jobName -isnot [string] -or $Job.jobName.Length -lt 1 -or $Job.jobName.Length -gt 100 -or $Job.checks -isnot [array]){throw 'requirements_identity_invalid'}
		if($null -ne $PreviousKey -and [StringComparer]::Ordinal.Compare($PreviousKey,$Job.key)-ge 0){throw 'requirements_not_sorted'}
		$PreviousKey=$Job.key
		if(-not $Keys.Add($Job.key)-or -not $JobNames.Add($Job.jobName.Normalize([Text.NormalizationForm]::FormC))){throw 'requirements_identity_collision'}
		$PreviousCheck=$null
		foreach($Check in @($Job.checks)){
			if($Check -isnot [string] -or $script:AggregateContextCheckIds -cnotcontains $Check -or -not $Ids.Add($Check)){throw 'requirements_check_invalid'}
			if($null -ne $PreviousCheck -and [StringComparer]::Ordinal.Compare($PreviousCheck,$Check)-ge 0){throw 'requirements_not_sorted'}
			$PreviousCheck=$Check
		}
		if(@($Job.checks).Count-eq 0){throw 'requirements_check_invalid'}
	}
	if($Ids.Count-ne $script:AggregateContextCheckIds.Count -or @($script:AggregateContextCheckIds|Where-Object{-not $Ids.Contains($_)}).Count-ne 0){throw 'requirements_check_coverage_incomplete'}
	return $Jobs
}

function New-AggregateContextRuntimeRequirements {
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Constructs the complete runtime requirements document from the accepted template.')]
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Constructs a bounded in-memory requirements document and changes no external state.')]
	param([array]$TemplateJobs,[string]$CurrentRunId,[int]$CurrentRunAttempt,[string]$Nonce)
	$Jobs=@($TemplateJobs|ForEach-Object{[pscustomobject][ordered]@{key=$_.key;jobName=$_.jobName;artifactName=('ci-receipt-'+$_.key+'-'+$CurrentRunId+'-'+$CurrentRunAttempt+'-'+$Nonce);checks=@($_.checks)}})
	return [pscustomobject][ordered]@{schemaVersion='aetheln.ci-acceptance-requirements/v1';jobs=$Jobs}
}

function Read-AndAssertSelectorBinding {
	param([string]$Json,[string]$CurrentRunId,[int]$CurrentRunAttempt,[string]$Nonce)
	$Binding=ConvertFrom-StrictAggregateContextJson -Raw $Json -RootKind Object
	Assert-ClosedAggregateContextObject -Value $Binding -Names @('jobName','artifactId','artifactName','digest') -Reason 'selector_binding_schema_invalid'
	if($Binding.jobName -cne 'ci-selection-shadow' -or -not(Test-AggregateContextDecimal $Binding.artifactId) -or
		$Binding.artifactName -cne ('ci-selection-shadow-'+$CurrentRunId+'-'+$CurrentRunAttempt+'-'+$Nonce) -or
		$Binding.digest -isnot [string] -or $Binding.digest -cnotmatch '\Asha256:[0-9a-f]{64}\z'){throw 'selector_binding_invalid'}
	return $Binding
}

function Read-AndAssertProducerBindings {
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Validates and returns the complete direct producer binding collection.')]
	param([string]$Json,[array]$RequirementsJobs,$Selected,[string]$CurrentRunId,[int]$CurrentRunAttempt,[string]$Nonce)
	$Parsed=ConvertFrom-StrictAggregateContextJson -Raw $Json -RootKind Array
	$Bindings=@($Parsed)
	$Keys=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
	$Jobs=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
	$Ids=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
	$Names=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
	$Previous=$null
	foreach($Binding in $Bindings){
		Assert-ClosedAggregateContextObject -Value $Binding -Names @('key','jobName','artifactId','artifactName','digest') -Reason 'producer_binding_schema_invalid'
		if($Binding.key -isnot [string] -or $Binding.key -cnotmatch '\A[a-z0-9][a-z0-9-]{0,63}\z' -or $Binding.jobName -isnot [string] -or
			-not(Test-AggregateContextDecimal $Binding.artifactId) -or $Binding.artifactName -cne ('ci-receipt-'+$Binding.key+'-'+$CurrentRunId+'-'+$CurrentRunAttempt+'-'+$Nonce) -or
			$Binding.digest -isnot [string] -or $Binding.digest -cnotmatch '\Asha256:[0-9a-f]{64}\z'){throw 'producer_binding_invalid'}
		if($null-ne$Previous -and [StringComparer]::Ordinal.Compare($Previous,$Binding.key)-ge 0){throw 'producer_bindings_not_sorted'};$Previous=$Binding.key
		if(-not$Keys.Add($Binding.key)-or-not$Jobs.Add($Binding.jobName)-or-not$Ids.Add($Binding.artifactId)-or-not$Names.Add($Binding.artifactName)){throw 'producer_bindings_duplicate'}
		$Requirement=@($RequirementsJobs|Where-Object{$_.key-ceq$Binding.key})
		if($Requirement.Count-ne 1 -or $Requirement[0].jobName-cne$Binding.jobName){throw 'producer_binding_requirement_mismatch'}
		if(@($Requirement[0].checks|Where-Object{$Selected.Contains($_)}).Count-eq 0){throw 'producer_binding_unselected'}
	}
	foreach($Requirement in $RequirementsJobs){if(@($Requirement.checks|Where-Object{$Selected.Contains($_)}).Count-gt 0 -and -not$Keys.Contains($Requirement.key)){throw 'producer_binding_missing'}}
	return ,$Bindings
}

function ConvertTo-BoundedAggregateContextBytes {
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'The established internal name describes the exact bounded byte sequence returned; renaming every reviewed call site would add unrelated churn.')]
	param($Value)
	$Raw=$Value|ConvertTo-Json -Depth 16 -Compress
	$Bytes=$script:AggregateContextUtf8NoBom.GetBytes($Raw)
	if($Bytes.Length-le 0 -or $Bytes.Length-gt$script:AggregateContextMaximumOutputBytes){throw 'output_size_limit'}
	return ,$Bytes
}

function Publish-AggregateContextOutputs {
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Publishes the complete atomic output set for one invocation.')]
	param([hashtable]$Outputs)
	$Temporaries=@{};$Published=New-Object Collections.Generic.List[string]
	try{
		foreach($Path in @($Outputs.Keys|Sort-Object)){
			$Parent=Split-Path -Parent $Path;$Temp=Join-Path $Parent ('.'+[IO.Path]::GetFileName($Path)+'.'+[guid]::NewGuid().ToString('N')+'.tmp')
			$Temporaries[$Path]=$Temp;$Stream=New-Object IO.FileStream($Temp,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
			try{$Bytes=[byte[]]$Outputs[$Path];$Stream.Write($Bytes,0,$Bytes.Length);$Stream.Flush($true)}finally{$Stream.Dispose()}
		}
		foreach($Path in @($Outputs.Keys|Sort-Object)){[IO.File]::Move($Temporaries[$Path],$Path);$Published.Add($Path)}
	}catch{
		foreach($Path in $Published){if(Test-Path -LiteralPath $Path -PathType Leaf){Remove-Item -LiteralPath $Path -Force}}
		throw
	}finally{foreach($Temp in $Temporaries.Values){if(Test-Path -LiteralPath $Temp -PathType Leaf){Remove-Item -LiteralPath $Temp -Force}}}
}

function Invoke-CiAcceptanceAggregateContextMain {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory)][ValidateSet('Identity','Aggregate','Gap')][string]$Mode,
		[Parameter(Mandatory)][string]$SelectorReportPath,[Parameter(Mandatory)][string]$WorkflowPath,[string]$RequirementsTemplatePath,
		[Parameter(Mandatory)][string]$Repository,[Parameter(Mandatory)][string]$Actor,[Parameter(Mandatory)][string]$TriggeringActor,
		[Parameter(Mandatory)][string]$BaseRevision,[Parameter(Mandatory)][string]$HeadRevision,[Parameter(Mandatory)][string]$TestedRevision,
		[Parameter(Mandatory)][string]$WorkflowId,[Parameter(Mandatory)][string]$RunId,[Parameter(Mandatory)][int]$RunAttempt,
		[Parameter(Mandatory)][string]$ActionItemsJson,[string]$SelectorBindingJson,[string]$ProducerBindingsJson,
		[Parameter(Mandatory)][string]$IdentityContextOutputPath,[string]$AggregateContextOutputPath,[string]$RuntimeRequirementsOutputPath
	)
	Assert-AggregateContextArguments -RepositoryValue $Repository -ActorValue $Actor -TriggeringActorValue $TriggeringActor -Base $BaseRevision -Head $HeadRevision -Tested $TestedRevision -WorkflowIdentity $WorkflowId -RunIdentity $RunId -Attempt $RunAttempt
	$Selector=Read-AndAssertAggregateContextSelector -Path $SelectorReportPath -Base $BaseRevision -Head $HeadRevision -Tested $TestedRevision -ExpectedRunId $RunId -ExpectedRunAttempt $RunAttempt -AllowUnavailable:($Mode -ceq 'Gap')
	$Actions=Read-AndAssertAggregateContextActions -Json $ActionItemsJson
	$WorkflowBytes=Read-BoundedAggregateContextFileBytes -Path $WorkflowPath
	if ($Mode -ceq 'Gap') {
		$LiveChecks=@('controller-contract','native-client-server-compile','portable','visual-package')
		$Unsupported=@($script:AggregateContextCheckIds | Where-Object { $Selector.Selected.Contains($_) -and $LiveChecks -cnotcontains $_ })
		if ($Unsupported.Count -eq 0) { throw 'gap_selection_empty' }
		return [pscustomobject][ordered]@{mode='Gap';acceptedControllerUnavailable=$Selector.AcceptedControllerUnavailable;attemptAnchor=$Selector.Report.attemptAnchor;selectedUnsupported=$Unsupported}
	}
	$Identity=[pscustomobject][ordered]@{
		schemaVersion='aetheln.ci-acceptance-context/v1';repository=[pscustomobject][ordered]@{fullName=$Repository}
		event=[pscustomobject][ordered]@{kind='pull_request';classification='pull_request_acceptance';actor=$Actor;triggeringActor=$TriggeringActor}
		source=[pscustomobject][ordered]@{baseRevision=$BaseRevision;headRevision=$HeadRevision;testedRevision=$TestedRevision}
		workflow=[pscustomobject][ordered]@{id=$WorkflowId;revision=$TestedRevision;parents=@($BaseRevision,$HeadRevision);sha256=(Get-AggregateContextSha256Hex $WorkflowBytes)}
		controller=[pscustomobject][ordered]@{revision=$Selector.Report.execution.controllerRevision;blobOid=$Selector.Report.execution.controllerBlobOid;sha256=$Selector.Report.execution.controllerSha256}
		policy=[pscustomobject][ordered]@{version=$Selector.Report.policy.version;digest=$Selector.Report.policy.digest}
		actions=$Actions;run=[pscustomobject][ordered]@{id=$RunId;attempt=$RunAttempt};attemptAnchor=$Selector.Report.attemptAnchor
		selection=[pscustomobject][ordered]@{checks=@($script:AggregateContextCheckIds | Where-Object { $Selector.Selected.Contains($_) })}
	}
	$IdentityPath=Resolve-AggregateContextOutputPath $IdentityContextOutputPath
	$Outputs=@{$IdentityPath=(ConvertTo-BoundedAggregateContextBytes $Identity)}
	if($Mode-ceq'Aggregate'){
		if([string]::IsNullOrWhiteSpace($RequirementsTemplatePath)-or[string]::IsNullOrWhiteSpace($SelectorBindingJson)-or[string]::IsNullOrWhiteSpace($ProducerBindingsJson)-or[string]::IsNullOrWhiteSpace($AggregateContextOutputPath)-or[string]::IsNullOrWhiteSpace($RuntimeRequirementsOutputPath)){throw 'aggregate_arguments_required'}
		$TemplateJobs=Read-AndAssertAggregateContextTemplate -Path $RequirementsTemplatePath
		$Requirements=New-AggregateContextRuntimeRequirements -TemplateJobs $TemplateJobs -CurrentRunId $RunId -CurrentRunAttempt $RunAttempt -Nonce $Selector.Report.attemptAnchor.nonce
		$SelectorBinding=Read-AndAssertSelectorBinding -Json $SelectorBindingJson -CurrentRunId $RunId -CurrentRunAttempt $RunAttempt -Nonce $Selector.Report.attemptAnchor.nonce
		$ProducerBindings=Read-AndAssertProducerBindings -Json $ProducerBindingsJson -RequirementsJobs $Requirements.jobs -Selected $Selector.Selected -CurrentRunId $RunId -CurrentRunAttempt $RunAttempt -Nonce $Selector.Report.attemptAnchor.nonce
		$Aggregate=[pscustomobject][ordered]@{
			schemaVersion=$Identity.schemaVersion;repository=$Identity.repository;event=$Identity.event;source=$Identity.source;workflow=$Identity.workflow;actions=$Identity.actions
			controller=$Identity.controller;policy=$Identity.policy;run=$Identity.run;attemptAnchor=$Identity.attemptAnchor;selectorBinding=$SelectorBinding;producerBindings=$ProducerBindings
		}
		$AggregatePath=Resolve-AggregateContextOutputPath $AggregateContextOutputPath;$RequirementsPath=Resolve-AggregateContextOutputPath $RuntimeRequirementsOutputPath
		$OutputNames=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
		foreach($OutputName in @($IdentityPath,$AggregatePath,$RequirementsPath)){if(-not$OutputNames.Add($OutputName)){throw 'output_path_collision'}}
		$Outputs[$AggregatePath]=ConvertTo-BoundedAggregateContextBytes $Aggregate;$Outputs[$RequirementsPath]=ConvertTo-BoundedAggregateContextBytes $Requirements
	}
	Publish-AggregateContextOutputs -Outputs $Outputs
	return [pscustomobject]@{mode=$Mode;identityContext=$Identity;aggregateContext=$(if($Mode-ceq'Aggregate'){$Aggregate}else{$null});runtimeRequirements=$(if($Mode-ceq'Aggregate'){$Requirements}else{$null})}
}

if($MyInvocation.InvocationName -ne '.'){
	Invoke-CiAcceptanceAggregateContextMain -Mode $Mode -SelectorReportPath $SelectorReportPath -WorkflowPath $WorkflowPath -RequirementsTemplatePath $RequirementsTemplatePath -Repository $Repository -Actor $Actor -TriggeringActor $TriggeringActor -BaseRevision $BaseRevision -HeadRevision $HeadRevision -TestedRevision $TestedRevision -WorkflowId $WorkflowId -RunId $RunId -RunAttempt $RunAttempt -ActionItemsJson $ActionItemsJson -SelectorBindingJson $SelectorBindingJson -ProducerBindingsJson $ProducerBindingsJson -IdentityContextOutputPath $IdentityContextOutputPath -AggregateContextOutputPath $AggregateContextOutputPath -RuntimeRequirementsOutputPath $RuntimeRequirementsOutputPath
}
