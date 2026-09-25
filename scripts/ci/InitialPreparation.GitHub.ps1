[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Initialize-PreparationGitHubTransport {
	if ($null -ne ('Aetheln.PreparationGitHubTransport' -as [type])) { return }
	Add-Type -Language CSharp -TypeDefinition @'
using System;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
namespace Aetheln {
 public sealed class PreparationGitHubFailure : Exception {
  public readonly string Category;
  public readonly int? HttpStatus, NativeExitCode;
  public readonly long? RetryAfterSeconds, RateLimitRemaining, RateLimitReset;
  // This transport owns a process, not a Job Object descendant proof. Never
  // represent timeout cleanup as proven merely because the root has exited.
  public bool CleanupVerified { get { return false; } }
  public PreparationGitHubFailure(string category,int? status,int? nativeExit,long? retryAfter,long? remaining,long? reset)
   : base("github_api_failed") {
   switch(category) {
    case "http_transient": case "http_rate_limit": case "http_rejected":
    case "native_timeout": case "native_failure": case "native_cleanup_unproven":
    case "response_invalid": case "response_limit": case "delay_invalid":
    case "budget_exhausted": case "transport_failure": break;
    default: throw new ArgumentException("failure_category_invalid");
   }
   if((status.HasValue && (status.Value<100 || status.Value>599)) ||
      (retryAfter.HasValue && (retryAfter.Value<0 || retryAfter.Value>2147483647L)) ||
      (remaining.HasValue && (remaining.Value<0 || remaining.Value>2147483647L)) ||
      (reset.HasValue && (reset.Value<0 || reset.Value>253402300799L))) throw new ArgumentException("failure_value_invalid");
   Category=category; HttpStatus=status; NativeExitCode=nativeExit;
   RetryAfterSeconds=retryAfter; RateLimitRemaining=remaining; RateLimitReset=reset;
  }
 }
 public sealed class PreparationGitHubResult {
  public string Output; public int ExitCode;
 }
 public static class PreparationGitHubTransport {
  static readonly object StartGate = new object();
  public static string QuoteArgument(string value) {
   var result = new StringBuilder("\""); int slashes=0;
   foreach(char c in value) {
    if(c=='\\') { slashes++; continue; }
    if(c=='"') { result.Append('\\',slashes*2+1); result.Append(c); }
    else { result.Append('\\',slashes); result.Append(c); }
    slashes=0;
   }
   result.Append('\\',slashes*2); return result.Append('"').ToString();
  }
  static async Task Send(Stream stream, byte[] bytes) {
   try { if (bytes.Length > 0) await stream.WriteAsync(bytes,0,bytes.Length).ConfigureAwait(false); }
   finally { stream.Close(); }
  }
  sealed class Capture {
   public readonly StringBuilder Text = new StringBuilder();
   public volatile bool Overflow;
   public async Task Read(StreamReader reader, int limit) {
    char[] buffer = new char[4096]; int count;
    while ((count = await reader.ReadAsync(buffer,0,buffer.Length).ConfigureAwait(false)) > 0) {
     if (Text.Length > limit - count) { Overflow = true; return; }
     Text.Append(buffer,0,count);
    }
   }
  }
  public static PreparationGitHubResult Run(string executable,string arguments,string body,int milliseconds) {
   byte[] request = body == null ? new byte[0] : new UTF8Encoding(false,true).GetBytes(body);
   if (request.Length > 1048576) throw new InvalidOperationException("github_request_limit");
   var timer = Stopwatch.StartNew();
   using (var process = new Process()) {
    process.StartInfo = new ProcessStartInfo(executable,arguments) {
     UseShellExecute=false,CreateNoWindow=true,RedirectStandardOutput=true,
     RedirectStandardError=true,RedirectStandardInput=true,StandardOutputEncoding=Encoding.UTF8
    };
    bool started = false;
    try {
    // .NET Framework has no ProcessStartInfo.StandardInputEncoding. Process
    // creates an autoflushing writer from Console.InputEncoding at Start and
    // can emit its BOM before our first write. Scope the process-local setting
    // to serialized transport creation and restore it even when Start fails.
    int startRemaining = Math.Max(0,milliseconds-(int)timer.ElapsedMilliseconds);
    if (!Monitor.TryEnter(StartGate,startRemaining)) throw new TimeoutException("github_api_timeout");
    try {
     Encoding previous = Console.InputEncoding;
     try {
      Console.InputEncoding = new UTF8Encoding(false,true);
      started = process.Start();
      if (!started) throw new InvalidOperationException("github_cli_start_failed");
     } finally { Console.InputEncoding = previous; }
    } finally { Monitor.Exit(StartGate); }
    if (timer.ElapsedMilliseconds >= milliseconds) throw new TimeoutException("github_api_timeout");
    var output = new Capture(); var error = new Capture();
    Task stdout = output.Read(process.StandardOutput,1048576);
    Task stderr = error.Read(process.StandardError,65536);
     // Write exact BOM-free bytes. An unread stdin pipe must remain inside the
     // same timeout as the child and both output streams, not block this thread.
     Task stdin = Send(process.StandardInput.BaseStream,request);
     while (!process.WaitForExit(20)) {
      if (timer.ElapsedMilliseconds >= milliseconds) throw new TimeoutException("github_api_timeout");
      if (output.Overflow || error.Overflow) throw new InvalidOperationException("github_response_limit");
     }
     int remaining = Math.Max(0,milliseconds-(int)timer.ElapsedMilliseconds);
     if (!Task.WaitAll(new Task[]{stdin,stdout,stderr},remaining)) throw new TimeoutException("github_api_timeout");
     if (output.Overflow || error.Overflow) throw new InvalidOperationException("github_response_limit");
     return new PreparationGitHubResult {Output=output.Text.ToString(),ExitCode=process.ExitCode};
    } finally {
     if (started && !process.HasExited) { process.Kill(); if(!process.WaitForExit(2000)) throw new InvalidOperationException("github_cli_cleanup_failed"); }
    }
   }
  }
 }
}
'@
}

function Get-InitialPreparationCheckoutIdentity {
	[CmdletBinding()]
	param([Parameter(Mandatory)][string] $Root, [Parameter(Mandatory)][string] $ExpectedRevision)
	try {
		if ($Root -notmatch '^[A-Za-z]:[\\/]' -or $Root.Length -gt 4096 -or $Root -match '[\x00-\x1f"]' -or
			$ExpectedRevision -cnotmatch '^[0-9a-f]{40}$') { throw 'checkout_identity_invalid' }
		$Full = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
		Assert-InitialPreparationPlainPath -Path $Full -Reason 'checkout_identity_invalid'
		if (-not (Test-Path -LiteralPath $Full -PathType Container)) { throw 'checkout_identity_invalid' }
		Initialize-PreparationGitHubTransport
		$Git = (Get-Command git -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
		# Reuse the bounded native transport: no shell, 1 MiB response ceiling,
		# separate bounded stderr, 15-second native timeout. No index refresh writes.
		$Prefix = '--no-optional-locks -C "' + $Full + '" '
		$Head = [Aetheln.PreparationGitHubTransport]::Run($Git, $Prefix + 'rev-parse --verify HEAD', $null, 15000)
		$Top = [Aetheln.PreparationGitHubTransport]::Run($Git, $Prefix + 'rev-parse --show-toplevel', $null, 15000)
		$Status = [Aetheln.PreparationGitHubTransport]::Run($Git, $Prefix + 'status --porcelain=v1 --untracked-files=all', $null, 15000)
		if ($Head.ExitCode -ne 0 -or $Top.ExitCode -ne 0 -or $Status.ExitCode -ne 0 -or
			$Head.Output.Trim() -cne $ExpectedRevision -or
			-not [string]::Equals([IO.Path]::GetFullPath($Top.Output.Trim()).TrimEnd('\', '/'), $Full, [StringComparison]::OrdinalIgnoreCase)) { throw 'checkout_identity_invalid' }
		return [pscustomobject]@{ root = $Full; revision = $ExpectedRevision; clean = [string]::IsNullOrEmpty($Status.Output) }
	} catch { throw [InvalidOperationException]::new('checkout_identity_invalid', $_.Exception) }
}

function ConvertFrom-PreparationGitHubJson {
	[CmdletBinding()]
	[OutputType([object[]])]
	param([Parameter(Mandatory)][string] $Json)
	# A property preserves empty/singleton arrays on both PowerShell 5.1 and 7.
	# Pipeline-wrapping ConvertFrom-Json nests arrays on Windows PowerShell 5.1.
	try {
		if ($Json.Length -gt 1048576) { throw 'github_response_invalid' }
		$null = ConvertFrom-Json -InputObject $Json
		$Envelope = ('{"data":' + $Json + '}') | ConvertFrom-Json
	}
	catch { throw 'github_response_invalid' }
	return ,$Envelope.data
}

function Invoke-PreparationGitHubApi {
	[CmdletBinding()]
	param([Parameter(Mandatory)] $Request,
		[ValidateRange(1, 30000)][int] $TimeoutMilliseconds = 30000)
	if ($Request.method -cnotin @('GET', 'POST', 'DELETE') -or
		$Request.path -cnotmatch '^repos/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_./?=&%-]+)?$') { throw 'github_request_invalid' }
	# Only one exact label endpoint may mutate. No replace-all, runner deletion,
	# job cancellation, authentication inspection, or shell interpolation.
	if ($Request.method -ceq 'DELETE' -and $Request.path -cnotmatch '/actions/runners/[1-9][0-9]*/labels/aetheln-engine$') { throw 'github_request_invalid' }
	if ($Request.method -ceq 'POST' -and $Request.path -cnotmatch '/actions/runners/[1-9][0-9]*/labels$') { throw 'github_request_invalid' }
	$Body = $null
	if ($Request.method -ceq 'POST') {
		if ($Request.body.labels.Count -ne 1 -or $Request.body.labels[0] -cne 'aetheln-engine') { throw 'github_request_invalid' }
		$Body = '{"labels":["aetheln-engine"]}'
	}
	Initialize-PreparationGitHubTransport
	$Executable = (Get-Command gh -CommandType Application -ErrorAction Stop).Source
	$Arguments = 'api --hostname github.com --include --method ' + $Request.method +
		' --header "Accept: application/vnd.github+json" --header "X-GitHub-Api-Version: 2026-03-10" ' + $Request.path
	$Validator = $null
	if ($Request.PSObject.Properties.Name -ccontains 'ifNoneMatch') {
		if (-not (Test-PreparationConditionalPath -Request $Request) -or -not (Test-PreparationEntityTag -Value $Request.ifNoneMatch)) { throw 'github_request_invalid' }
		$Validator = $Request.ifNoneMatch
		$Arguments += ' --header ' + [Aetheln.PreparationGitHubTransport]::QuoteArgument('If-None-Match: ' + $Validator)
	}
	if ($null -ne $Body) { $Arguments += ' --input -' }
	# Run's exceptional cleanup has a two-second allowance. Reserve it inside
	# the caller's original timeout rather than extending a retry's deadline.
	if ($TimeoutMilliseconds -le 2000) { throw [Aetheln.PreparationGitHubFailure]::new('budget_exhausted', $null, $null, $null, $null, $null) }
	try { $Result = [Aetheln.PreparationGitHubTransport]::Run($Executable, $Arguments, $Body, ($TimeoutMilliseconds - 2000)) }
	catch { throw (Get-PreparationGitHubNativeFailure -Exception $_.Exception) }
	return ConvertFrom-PreparationGitHubNativeResult -Result $Result -ExpectedEntityTag $Validator
}

function Get-PreparationGitHubNativeFailure {
	[CmdletBinding()]
	param([Parameter(Mandatory)][Exception] $Exception)
	Initialize-PreparationGitHubTransport
	$Cause = $Exception.GetBaseException()
	$Category = if ($Cause -is [TimeoutException]) { 'native_timeout' }
		elseif ($Cause -is [InvalidOperationException] -and $Cause.Message -ceq 'github_response_limit') { 'response_limit' }
		elseif ($Cause -is [InvalidOperationException] -and $Cause.Message -ceq 'github_cli_cleanup_failed') { 'native_cleanup_unproven' }
		else { 'native_failure' }
	return [Aetheln.PreparationGitHubFailure]::new($Category, $null, $null, $null, $null, $null)
}

function Get-PreparationGitHubFailure {
	[CmdletBinding()]
	[OutputType([Exception])]
	param([Parameter(Mandatory)][Exception] $Exception)
	Initialize-PreparationGitHubTransport
	$Cause = $Exception
	for ($Depth = 0; $Depth -lt 8 -and $null -ne $Cause; $Depth++) {
		if ($Cause -is [Aetheln.PreparationGitHubFailure]) { return $Cause }
		$Cause = $Cause.InnerException
	}
	return [Aetheln.PreparationGitHubFailure]::new('transport_failure', $null, $null, $null, $null, $null)
}

function Get-PreparationGitHubHttpFailure {
	[CmdletBinding()]
	param([Parameter(Mandatory)][int] $StatusCode, [Parameter(Mandatory)] $Headers, [Nullable[int]] $NativeExitCode)
	Initialize-PreparationGitHubTransport
	$Numbers = @{}
	try {
		if ($StatusCode -lt 100 -or $StatusCode -gt 599 -or $Headers -isnot [Collections.IDictionary]) { throw 'invalid' }
		foreach ($Header in @('Retry-After', 'X-RateLimit-Remaining', 'X-RateLimit-Reset')) {
			$Value = $null
			if ($Headers.Contains($Header)) {
				$Raw = $Headers[$Header]
				$Parsed = 0L
				$Maximum = if ($Header -ceq 'X-RateLimit-Reset') { 253402300799L } else { 2147483647L }
				if ($Raw -isnot [string] -or $Raw -cnotmatch '^[0-9]{1,12}$' -or
					-not [long]::TryParse($Raw, [Globalization.NumberStyles]::None, [Globalization.CultureInfo]::InvariantCulture, [ref] $Parsed) -or $Parsed -gt $Maximum) { throw 'invalid' }
				$Value = $Parsed
			}
			$Numbers[$Header] = $Value
		}
	} catch { return [Aetheln.PreparationGitHubFailure]::new('delay_invalid', $(if ($StatusCode -ge 100 -and $StatusCode -le 599) { $StatusCode } else { $null }), $NativeExitCode, $null, $null, $null) }
	$Category = if ($StatusCode -in @(500, 502, 503, 504)) { 'http_transient' }
		elseif ($StatusCode -eq 429 -or ($StatusCode -eq 403 -and ($null -ne $Numbers['Retry-After'] -or $Numbers['X-RateLimit-Remaining'] -eq 0))) { 'http_rate_limit' }
		else { 'http_rejected' }
	return [Aetheln.PreparationGitHubFailure]::new($Category, $StatusCode, $NativeExitCode, $Numbers['Retry-After'], $Numbers['X-RateLimit-Remaining'], $Numbers['X-RateLimit-Reset'])
}

function ConvertFrom-PreparationGitHubNativeResult {
	[CmdletBinding()]
	param([Parameter(Mandatory)] $Result, [AllowNull()][string] $ExpectedEntityTag)
	Initialize-PreparationGitHubTransport
	$StatusCode = $null; $NativeExit = $null
	try {
		if ($Result.ExitCode -isnot [int] -or $Result.Output -isnot [string]) { throw 'invalid' }
		$NativeExit = $Result.ExitCode
		if ($Result.Output.Length -gt 1048576) { throw [Aetheln.PreparationGitHubFailure]::new('response_limit', $null, $NativeExit, $null, $null, $null) }
		$Sections = ([regex] '\r?\n\r?\n').Split($Result.Output, 2)
		if ($Sections.Count -ne 2 -or $Sections[0].Length -gt 16384 -or $Sections[0] -cnotmatch '^HTTP/[^\s]+ ([1-5][0-9]{2})(?: [^\r\n]*)?(?:\r?\n|$)') { throw 'invalid' }
		$StatusCode = [int] $Matches[1]
		$Headers = @{}
		foreach ($Line in ($Sections[0] -split '\r?\n')) {
			if ($Line -match '^(Link|ETag|X-RateLimit-Remaining|X-RateLimit-Reset|Retry-After):[ \t]*(.*)$') {
				if ($Headers.ContainsKey($Matches[1])) { throw [Aetheln.PreparationGitHubFailure]::new('delay_invalid', $StatusCode, $NativeExit, $null, $null, $null) }
				$Headers[$Matches[1]] = $Matches[2]
			}
		}
		if ($Headers.ContainsKey('ETag') -and -not (Test-PreparationEntityTag -Value $Headers['ETag'])) { throw 'invalid' }
		# gh 2.96 reports a live 304 as native exit 1. This closed exception is
		# valid only for a weak-comparison match to the validator sent; it never
		# accepts a 2xx failure. Wire/cache identity remains exact, not normalized.
		if ($StatusCode -eq 304) {
			if ($NativeExit -ne 1 -or -not (Test-PreparationEntityTag -Value $ExpectedEntityTag) -or
				-not $Headers.ContainsKey('ETag') -or -not (Test-PreparationWeakEntityTag -Left $Headers['ETag'] -Right $ExpectedEntityTag) -or $Sections[1].Length -ne 0) { throw 'invalid' }
			return [pscustomobject]@{ statusCode = 304; headers = $Headers; data = $null; bodyJson = ''; nativeExitCode = 1 }
		}
		# HTTP failure metadata remains useful when gh exits nonzero. Never parse
		# or retain its potentially sensitive error body; 2xx/nonzero is not success.
		if ($StatusCode -lt 200 -or $StatusCode -ge 300) { throw (Get-PreparationGitHubHttpFailure -StatusCode $StatusCode -Headers $Headers -NativeExitCode $NativeExit) }
		if ($NativeExit -ne 0) { throw [Aetheln.PreparationGitHubFailure]::new('native_failure', $StatusCode, $NativeExit, $null, $null, $null) }
		$Data = ConvertFrom-PreparationGitHubJson -Json $Sections[1]
		return [pscustomobject]@{ statusCode = $StatusCode; headers = $Headers; data = $Data; bodyJson = $Sections[1]; nativeExitCode = 0 }
	} catch {
		$Failure = Get-PreparationGitHubFailure -Exception $_.Exception
		if ($Failure.Category -cne 'transport_failure') { throw $Failure }
		$Category = if ($null -ne $NativeExit -and $NativeExit -ne 0 -and $null -eq $StatusCode) { 'native_failure' } else { 'response_invalid' }
		throw [Aetheln.PreparationGitHubFailure]::new($Category, $StatusCode, $NativeExit, $null, $null, $null)
	}
}

function Invoke-PreparationGitHubRequest {
	[CmdletBinding()]
	param([string] $Method, [string] $Path, $Body, [scriptblock] $Transport)
	try {
		$Response = & $Transport ([pscustomobject]@{ method = $Method; path = $Path; body = $Body })
		if ($Response.statusCode -isnot [int] -or $Response.statusCode -lt 200 -or $Response.statusCode -ge 300 -or
			$Response.headers -isnot [Collections.IDictionary] -or $null -eq $Response.data) { throw 'github_api_failed' }
		return $Response
	} catch { throw (Get-PreparationGitHubFailure -Exception $_.Exception) }
}

function Get-PreparationLabelSet {
	[CmdletBinding()]
	[OutputType([object[]])]
	param([Parameter(Mandatory)] $RunnerData)
	$Names = @($RunnerData.labels | ForEach-Object { $_.name })
	if ($Names.Count -lt 1 -or $Names.Count -gt 100) { throw 'runner_labels_ambiguous' }
	foreach ($Name in $Names) {
		if ($Name -isnot [string] -or [string]::IsNullOrWhiteSpace($Name)) { throw 'runner_labels_ambiguous' }
	}
	if (@($Names | Sort-Object -Unique).Count -ne $Names.Count) { throw 'runner_labels_ambiguous' }
	return ,$Names
}

function Test-PreparationLabelSet {
	[OutputType([bool])]
	param([string[]] $Actual, [string[]] $Expected)
	if ($Actual.Count -ne $Expected.Count) { return $false }
	foreach ($Name in $Expected) { if ($Actual -cnotcontains $Name) { return $false } }
	return $true
}

function Get-InitialPreparationRunner {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory)][string] $Repository,
		[Parameter(Mandatory)][long] $RunnerId,
		[Parameter(Mandatory)][string] $ExpectedName,
		[scriptblock] $Transport = { param($Request) Invoke-PreparationGitHubApi -Request $Request }
	)
	if ($Repository -cnotmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' -or $RunnerId -lt 1) { throw 'runner_identity_mismatch' }
	$Path = "repos/$Repository/actions/runners/$RunnerId"
	$Response = Invoke-PreparationGitHubRequest -Method GET -Path $Path -Body $null -Transport $Transport
	$Data = $Response.data
	if ($Data.id -ne $RunnerId -or $Data.name -cne $ExpectedName -or $Data.busy -isnot [bool]) { throw 'runner_identity_mismatch' }
	if ($Data.status -cne 'online') { throw 'runner_offline' }
	$Labels = Get-PreparationLabelSet -RunnerData $Data
	return [pscustomobject]@{ repository = $Repository; id = $RunnerId; name = $ExpectedName; originalLabels = $Labels; busy = $Data.busy }
}

function Get-PreparationRunnerLabel {
	[CmdletBinding()]
	[OutputType([object[]])]
	param($Runner, [scriptblock] $Transport)
	$Response = Invoke-PreparationGitHubRequest -Method GET -Path "repos/$($Runner.repository)/actions/runners/$($Runner.id)/labels?per_page=100" -Body $null -Transport $Transport
	$Labels = Get-PreparationLabelSet -RunnerData $Response.data
	if ($Response.data.total_count -ne $Labels.Count -or $Response.headers.Contains('Link')) { throw 'inventory_incomplete' }
	return ,$Labels
}

function Set-InitialPreparationQuarantine {
	[CmdletBinding(SupportsShouldProcess)]
	param([Parameter(Mandatory)] $Runner,
		[scriptblock] $Transport = { param($Request) Invoke-PreparationGitHubApi -Request $Request })
	$Current = Get-PreparationRunnerLabel -Runner $Runner -Transport $Transport
	if (-not (Test-PreparationLabelSet -Actual $Current -Expected $Runner.originalLabels) -or $Current -cnotcontains 'aetheln-engine') { throw 'label_set_changed' }
	if (-not $PSCmdlet.ShouldProcess("$($Runner.repository)/runner/$($Runner.id)", 'Remove only aetheln-engine routing label')) { throw 'label_removal_declined' }
	try { $null = Invoke-PreparationGitHubRequest -Method DELETE -Path "repos/$($Runner.repository)/actions/runners/$($Runner.id)/labels/aetheln-engine" -Body $null -Transport $Transport }
	catch { throw 'label_removal_failed' }
	$Expected = @($Runner.originalLabels | Where-Object { $_ -cne 'aetheln-engine' })
	$After = Get-PreparationRunnerLabel -Runner $Runner -Transport $Transport
	if (-not (Test-PreparationLabelSet -Actual $After -Expected $Expected)) { throw 'label_readback_mismatch' }
	return [pscustomobject]@{ runnerId = $Runner.id; labelAbsent = $true; labels = $After }
}

function Restore-InitialPreparationRouting {
	[CmdletBinding(SupportsShouldProcess)]
	param([Parameter(Mandatory)] $Runner,
		[scriptblock] $Transport = { param($Request) Invoke-PreparationGitHubApi -Request $Request })
	$Current = Get-PreparationRunnerLabel -Runner $Runner -Transport $Transport
	$WithoutRouting = @($Runner.originalLabels | Where-Object { $_ -cne 'aetheln-engine' })
	if ($Runner.originalLabels -cnotcontains 'aetheln-engine') { throw 'label_restoration_readback_mismatch' }
	if (-not (Test-PreparationLabelSet -Actual $Current -Expected $Runner.originalLabels)) {
		if (-not (Test-PreparationLabelSet -Actual $Current -Expected $WithoutRouting)) { throw 'label_restoration_readback_mismatch' }
		if (-not $PSCmdlet.ShouldProcess("$($Runner.repository)/runner/$($Runner.id)", 'Restore only aetheln-engine routing label')) { throw 'label_restoration_declined' }
		try { $null = Invoke-PreparationGitHubRequest -Method POST -Path "repos/$($Runner.repository)/actions/runners/$($Runner.id)/labels" -Body @{ labels = @('aetheln-engine') } -Transport $Transport }
		catch { throw 'label_restoration_failed' }
	}
	$After = Get-PreparationRunnerLabel -Runner $Runner -Transport $Transport
	if (-not (Test-PreparationLabelSet -Actual $After -Expected $Runner.originalLabels)) { throw 'label_restoration_readback_mismatch' }
	$Online = Get-InitialPreparationRunner -Repository $Runner.repository -RunnerId $Runner.id -ExpectedName $Runner.name -Transport $Transport
	return [pscustomobject]@{ runnerId = $Online.id; online = $true; labels = $After }
}

function Wait-InitialPreparationAdmission {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory)] $Attempt,
		[Parameter(Mandatory)] $Runner,
		[Parameter(Mandatory)][scriptblock] $InventoryProbe,
		[Parameter(Mandatory)][scriptblock] $LocalWorkerProbe,
		[scriptblock] $ReadTicks = { [Diagnostics.Stopwatch]::GetTimestamp() },
		[scriptblock] $DelayMilliseconds = { param($Milliseconds) Start-Sleep -Milliseconds $Milliseconds }
	)
	Assert-InitialPreparationAttempt -Attempt $Attempt
	$QuietSince = $null
	$PreviousActivity = $null
	$ExpectedLabels = @($Runner.originalLabels | Where-Object { $_ -cne 'aetheln-engine' })
	while ((& $ReadTicks) -lt $Attempt.admissionDeadlineTicks) {
		try {
			$Observed = & $InventoryProbe
			$LocalState = & $LocalWorkerProbe
			foreach ($Field in @('complete', 'routesSafe', 'online', 'busy')) {
				if ($Observed.$Field -isnot [bool]) { throw 'inventory_incomplete' }
			}
			if (-not $Observed.complete -or -not $Observed.routesSafe -or -not $Observed.online -or
				$Observed.runnerId -ne $Runner.id -or $Observed.runnerName -cne $Runner.name -or
				$LocalState.complete -isnot [bool] -or -not $LocalState.complete -or
				($LocalState.activeProcessCount -isnot [int] -and $LocalState.activeProcessCount -isnot [long]) -or
				$LocalState.activeProcessCount -lt 0 -or [string]::IsNullOrWhiteSpace($Observed.activityKey)) { throw 'inventory_incomplete' }
			if (-not (Test-PreparationLabelSet -Actual $Observed.labels -Expected $ExpectedLabels)) { throw 'quarantine_invariant_changed' }
			$Idle = -not $Observed.busy -and @($Observed.activeJobs).Count -eq 0 -and $LocalState.activeProcessCount -eq 0
		} catch {
			$Reason = if ($_.Exception.Message -ceq 'quarantine_invariant_changed') { 'quarantine_invariant_changed' } else { 'inventory_incomplete' }
			return [pscustomobject]@{ admitted = $false; code = 'maintenance_not_admitted'; reason = $Reason; observedTicks = (& $ReadTicks) }
		}
		$Now = & $ReadTicks
		if ($Now -ge $Attempt.admissionDeadlineTicks) { break }
		if (-not $Idle) { $QuietSince = $null }
		elseif ($null -eq $QuietSince -or $PreviousActivity -cne $Observed.activityKey) { $QuietSince = $Now }
		$PreviousActivity = $Observed.activityKey
		if ($Idle -and $null -ne $QuietSince -and ($Now - $QuietSince) -ge 120L * $Attempt.monotonicFrequency) {
			return [pscustomobject]@{ admitted = $true; code = 'maintenance_admitted'; reason = 'quiet_period_verified'; observedTicks = $Now; observation = $Observed }
		}
		$Delay = [int] [Math]::Min(5000, [Math]::Max(0, [Math]::Floor(
			($Attempt.admissionDeadlineTicks - $Now) * 1000.0 / $Attempt.monotonicFrequency)))
		& $DelayMilliseconds $Delay
	}
	return [pscustomobject]@{ admitted = $false; code = 'maintenance_not_admitted'; reason = 'admission_deadline'; observedTicks = (& $ReadTicks) }
}

function Invoke-InitialPreparationMaintenance {
	[CmdletBinding(SupportsShouldProcess)]
	param([Parameter(Mandatory)] $Attempt,
		[Parameter(Mandatory)] $Runner,
		[Parameter(Mandatory)][string] $LeasePath,
		[Parameter(Mandatory)][scriptblock] $InventoryProbe,
		[Parameter(Mandatory)][scriptblock] $LocalWorkerProbe,
		[Parameter(Mandatory)][scriptblock] $Work,
		[Parameter(Mandatory)][scriptblock] $FreezeEvidence,
		[Parameter(Mandatory)][scriptblock] $PersistQuarantineIntent,
		[scriptblock] $Transport = { param($Request) Invoke-PreparationGitHubApi -Request $Request },
		[scriptblock] $ReadTicks = { [Diagnostics.Stopwatch]::GetTimestamp() },
		[scriptblock] $DelayMilliseconds = { param($Milliseconds) Start-Sleep -Milliseconds $Milliseconds })
	# This lifecycle runs INSIDE the parent-owned operation supervisor. Callbacks
	# are mandatory production integrations, not simulated defaults. Completion
	# of this cycle does not certify targets or the six-invocation warm baseline.
	Assert-InitialPreparationAttempt -Attempt $Attempt
	if ($Runner.repository -cne $Attempt.repository -or $Runner.originalLabels -cnotcontains 'aetheln-engine') { throw 'maintenance_identity_invalid' }
	if (-not $PSCmdlet.ShouldProcess("$($Runner.repository)/runner/$($Runner.id)", 'Run authorized temporary routing maintenance')) { throw 'maintenance_declined' }
	$State = [pscustomobject]@{ cycleCompleted = $false; admitted = $false; leaseReleased = $false; routingRestored = $false;
		workResult = $null; cleanup = $null; errors = (New-Object Collections.ArrayList) }
	$Lease = $null
	$QuarantineAttempted = $false
	$Phase = 'preflight'
	try {
		$Before = & $InventoryProbe
		if ($Before.complete -isnot [bool] -or -not $Before.complete -or $Before.routesSafe -isnot [bool] -or -not $Before.routesSafe -or
			$Before.online -isnot [bool] -or -not $Before.online -or $Before.runnerId -ne $Runner.id -or $Before.runnerName -cne $Runner.name -or
			-not (Test-PreparationLabelSet -Actual $Before.labels -Expected $Runner.originalLabels) -or
			(& $ReadTicks) -ge $Attempt.admissionDeadlineTicks) { throw 'maintenance_preflight_failed' }
		$Phase = 'quarantine_intent'
		$IntentPersisted = & $PersistQuarantineIntent $Attempt $Runner
		if ($IntentPersisted -isnot [bool] -or -not $IntentPersisted) { throw 'quarantine_intent_unproven' }
		$Phase = 'quarantine'
		# DELETE can succeed even if its response/readback is lost. Restoration
		# remains obligatory after this point unless owned cleanup is unproven.
		# Durable evidence can consume the remaining admission allowance. Preserve
		# it, but do not begin a routing outage after the original admission bound.
		if ((& $ReadTicks) -ge $Attempt.admissionDeadlineTicks) { throw 'maintenance_not_admitted' }
		$QuarantineAttempted = $true
		$null = Set-InitialPreparationQuarantine -Runner $Runner -Transport $Transport
		$Phase = 'admission'
		$Admission = Wait-InitialPreparationAdmission -Attempt $Attempt -Runner $Runner -InventoryProbe $InventoryProbe -LocalWorkerProbe $LocalWorkerProbe -ReadTicks $ReadTicks -DelayMilliseconds $DelayMilliseconds
		if (-not $Admission.admitted) { throw 'maintenance_not_admitted' }
		$State.admitted = $true
		$Phase = 'lease'
		$Lease = Enter-InitialPreparationLease -Attempt $Attempt -LeasePath $LeasePath
		$Phase = 'work'
		$Context = [pscustomobject]@{ attempt = $Attempt; runner = $Runner; lease = $Lease; admission = $Admission }
		$State.workResult = & $Work $Context
		if ($null -eq $State.workResult -or ($State.workResult.nativeExitCode -isnot [int] -and $State.workResult.nativeExitCode -isnot [long]) -or
			$State.workResult.nativeExitCode -ne 0) { throw 'work_native_failed' }
	} catch { [void] $State.errors.Add($Phase + '_failed') }
	finally {
		if ($null -ne $Lease) {
			try { $null = & $FreezeEvidence ([pscustomobject]@{ attempt = $Attempt; runner = $Runner; lease = $Lease; workResult = $State.workResult }) }
			catch { [void] $State.errors.Add('evidence_freeze_failed') }
			try {
				$State.cleanup = Stop-InitialPreparationOwnedTree -Lease $Lease -DeadlineTicks $Attempt.cleanupDeadlineTicks
				Exit-InitialPreparationLease -Lease $Lease
				$State.leaseReleased = $true
			} catch { [void] $State.errors.Add('cleanup_or_release_unproven') }
		}
		if ($QuarantineAttempted -and ($null -eq $Lease -or $State.leaseReleased)) {
			try {
				if ((& $ReadTicks) -ge $Attempt.publicationDeadlineTicks) { throw 'restoration_deadline_exceeded' }
				$null = Restore-InitialPreparationRouting -Runner $Runner -Transport $Transport
				$State.routingRestored = $true
			} catch { [void] $State.errors.Add('routing_restoration_failed') }
		}
	}
	$State.cycleCompleted = $State.admitted -and $State.leaseReleased -and $State.routingRestored -and $State.errors.Count -eq 0
	return $State
}

function Get-PreparationGitHubPageSet {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory)][string] $Path,
		[AllowEmptyString()][string] $CollectionName = '',
		[string] $IdentityField = 'id',
		[ValidateRange(1, 10)][int] $MaximumPages = 10,
		[scriptblock] $Transport = { param($Request) Invoke-PreparationGitHubApi -Request $Request }
	)
	if ($Path -match '(?:[?&])(?:page|per_page)=' -or $Path -cnotmatch '^repos/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/[A-Za-z0-9_./?=&%-]+$') { throw 'inventory_incomplete' }
	$Separator = if ($Path.Contains('?')) { '&' } else { '?' }
	$Items = New-Object Collections.ArrayList
	$Seen = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
	$ExpectedTotal = $null
	for ($Page = 1; $Page -le $MaximumPages; $Page++) {
		$Response = Invoke-PreparationGitHubRequest -Method GET -Path ($Path + $Separator + "per_page=100&page=$Page") -Body $null -Transport $Transport
		try {
			if ($CollectionName) {
				$Total = $Response.data.total_count
				if (($Total -isnot [int] -and $Total -isnot [long]) -or $Total -lt 0 -or $Total -gt 100 * $MaximumPages) { throw 'inventory_incomplete' }
				if ($null -eq $ExpectedTotal) { $ExpectedTotal = $Total }
				if ($ExpectedTotal -ne $Total) { throw 'inventory_incomplete' }
				if ($null -eq $Response.data.$CollectionName) { throw 'inventory_incomplete' }
				$Rows = @($Response.data.$CollectionName)
			} else {
				if ($Response.data -isnot [array]) { throw 'inventory_incomplete' }
				$Rows = @($Response.data)
			}
			if ($Rows.Count -gt 100) { throw 'inventory_incomplete' }
			foreach ($Row in $Rows) {
				$Identity = $Row.$IdentityField
				if ($IdentityField -ceq 'id' -and (($Identity -isnot [int] -and $Identity -isnot [long]) -or $Identity -lt 1)) { throw 'inventory_incomplete' }
				if ($null -eq $Identity -or [string]::IsNullOrWhiteSpace([string] $Identity) -or -not $Seen.Add([string] $Identity)) { throw 'inventory_incomplete' }
				[void] $Items.Add($Row)
			}
			$Next = $false
			if ($Response.headers.Contains('Link')) {
				$Link = [string] $Response.headers['Link']
				if ($Link.Length -gt 8192) { throw 'inventory_incomplete' }
				if ($Link -cnotmatch '^<[^>]+>;\s*rel="(?:next|prev|first|last)"(?:,\s*<[^>]+>;\s*rel="(?:next|prev|first|last)")*$') { throw 'inventory_incomplete' }
				$NextLinks = [regex]::Matches($Link, '<([^>]+)>;\s*rel="next"', [Text.RegularExpressions.RegexOptions]::None, [TimeSpan]::FromMilliseconds(100))
				if ($NextLinks.Count -gt 1) { throw 'inventory_incomplete' }
				if ($NextLinks.Count -eq 1) {
					$NextUri = [uri] $NextLinks[0].Groups[1].Value
					if ($NextUri.Scheme -cne 'https' -or $NextUri.Host -cne 'api.github.com' -or $NextUri.Port -ne 443 -or $NextUri.UserInfo -or $NextUri.Fragment) { throw 'inventory_incomplete' }
					$NextPage = [regex]::Matches($NextUri.Query, '(?:[?&])page=([0-9]+)(?:&|$)')
					if ($NextPage.Count -ne 1 -or [int] $NextPage[0].Groups[1].Value -ne ($Page + 1)) { throw 'inventory_incomplete' }
					$Next = $true
				}
			}
			if ($null -ne $ExpectedTotal) {
				if ($Items.Count -gt $ExpectedTotal -or ($Next -ne ($Items.Count -lt $ExpectedTotal))) { throw 'inventory_incomplete' }
			}
			if (-not $Next) { return [pscustomobject]@{ items = @($Items); pageCount = $Page; complete = $true } }
			if ($Rows.Count -ne 100) { throw 'inventory_incomplete' }
		} catch { throw 'inventory_incomplete' }
	}
	throw 'inventory_incomplete'
}

function Get-InitialPreparationQueueInventory {
	[CmdletBinding()]
	param([Parameter(Mandatory)][string] $Repository,
		[Parameter(Mandatory)][long] $ExpectedRunnerId,
		[Parameter(Mandatory)][string] $ExpectedRunnerName,
		[scriptblock] $Transport = { param($Request) Invoke-PreparationGitHubApi -Request $Request })
	$RunnerPage = Get-PreparationGitHubPageSet -Path "repos/$Repository/actions/runners" -CollectionName runners -Transport $Transport
	$Selected = @($RunnerPage.items | Where-Object { $_.id -eq $ExpectedRunnerId -and $_.name -ceq $ExpectedRunnerName })
	if ($Selected.Count -ne 1) { throw 'runner_identity_mismatch' }
	foreach ($Other in $RunnerPage.items) {
		if ($Other.id -ne $ExpectedRunnerId -and @($Other.labels | ForEach-Object { $_.name }) -ccontains 'aetheln-engine') { throw 'unexpected_shared_engine_runner' }
	}
	$Runs = New-Object Collections.ArrayList
	$Jobs = New-Object Collections.ArrayList
	$RunIds = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
	foreach ($Status in @('queued', 'in_progress', 'requested', 'waiting', 'pending')) {
		$RunPage = Get-PreparationGitHubPageSet -Path "repos/$Repository/actions/runs?status=$Status" -CollectionName workflow_runs -Transport $Transport
		foreach ($Run in $RunPage.items) {
			if ($Runs.Count -ge 1000) { throw 'inventory_limit' }
			if (-not $RunIds.Add([string] $Run.id) -or $Run.status -cne $Status -or
				$Run.head_sha -cnotmatch '^[0-9a-f]{40}$' -or $Run.run_attempt -lt 1) { throw 'inventory_incomplete' }
			$JobPage = Get-PreparationGitHubPageSet -Path "repos/$Repository/actions/runs/$($Run.id)/attempts/$($Run.run_attempt)/jobs" -CollectionName jobs -Transport $Transport
			foreach ($Job in $JobPage.items) {
				if ($Jobs.Count -ge 5000) { throw 'inventory_limit' }
				if ($Job.run_id -ne $Run.id -or $Job.head_sha -cne $Run.head_sha -or
					$Job.status -cnotin @('queued', 'in_progress', 'completed', 'waiting', 'pending', 'requested')) { throw 'inventory_incomplete' }
				if ($Job.runner_id -gt 0 -and $Job.runner_id -ne $ExpectedRunnerId -and @($Job.labels) -ccontains 'aetheln-engine') { throw 'unexpected_shared_engine_runner' }
				[void] $Jobs.Add([pscustomobject]@{ runId = $Run.id; runAttempt = $Run.run_attempt; headSha = $Run.head_sha; job = $Job })
			}
			# A concurrent rerun or completion changes the authoritative attempt.
			$Recheck = Invoke-PreparationGitHubRequest -Method GET -Path "repos/$Repository/actions/runs/$($Run.id)" -Body $null -Transport $Transport
			if ($Recheck.data.run_attempt -ne $Run.run_attempt -or $Recheck.data.head_sha -cne $Run.head_sha -or $Recheck.data.status -cne $Run.status) { throw 'inventory_incomplete' }
			[void] $Runs.Add($Run)
		}
	}
	$Active = @($Jobs | Where-Object { $_.job.runner_id -eq $ExpectedRunnerId -and $_.job.status -cne 'completed' })
	return [pscustomobject]@{ complete = $true; runner = $Selected[0]; runners = @($RunnerPage.items); runs = @($Runs); jobs = @($Jobs); activeJobs = $Active }
}

function Get-PreparationRevisionInventory {
	[CmdletBinding()]
	param([Parameter(Mandatory)][string] $Repository,
		[scriptblock] $Transport = { param($Request) Invoke-PreparationGitHubApi -Request $Request })
	if ($Repository -cnotmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') { throw 'revision_inventory_invalid' }
	$Metadata = Invoke-PreparationGitHubRequest -Method GET -Path "repos/$Repository" -Body $null -Transport $Transport
	try {
		$Branch = $Metadata.data.default_branch
		if ($Metadata.data.full_name -cne $Repository -or $Branch -isnot [string] -or
			[string]::IsNullOrWhiteSpace($Branch) -or $Branch.Length -gt 255) { throw 'revision_inventory_invalid' }
	} catch { throw 'revision_inventory_invalid' }
	$RefPath = 'repos/' + $Repository + '/git/ref/heads/' + [uri]::EscapeDataString($Branch)
	$DefaultRef = Invoke-PreparationGitHubRequest -Method GET -Path $RefPath -Body $null -Transport $Transport
	try {
		if ($DefaultRef.data.ref -cne ('refs/heads/' + $Branch) -or $DefaultRef.data.object.type -cne 'commit' -or
			$DefaultRef.data.object.sha -cnotmatch '^[0-9a-f]{40}$') { throw 'revision_inventory_invalid' }
		$DefaultSha = $DefaultRef.data.object.sha
	} catch { throw 'revision_inventory_invalid' }
	$Revisions = New-Object Collections.ArrayList
	$PullRequests = New-Object Collections.ArrayList
	[void] $Revisions.Add([pscustomobject]@{ repository = $Repository; revision = $DefaultSha; role = 'default'; pullNumber = 0 })
	$Page = Get-PreparationGitHubPageSet -Path "repos/$Repository/pulls?state=open&sort=created&direction=asc" -Transport $Transport
	foreach ($Row in ($Page.items | Sort-Object -Property number)) {
		if (($Row.number -isnot [int] -and $Row.number -isnot [long]) -or $Row.number -lt 1) { throw 'revision_inventory_invalid' }
		$Response = Invoke-PreparationGitHubRequest -Method GET -Path "repos/$Repository/pulls/$($Row.number)" -Body $null -Transport $Transport
		try {
			$Pull = $Response.data
			if ($Pull.id -ne $Row.id -or $Pull.number -ne $Row.number -or $Pull.state -cne 'open' -or
				$Pull.base.repo.full_name -cne $Repository -or $Pull.head.repo.full_name -cnotmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' -or
				$Pull.base.sha -cnotmatch '^[0-9a-f]{40}$' -or $Pull.head.sha -cnotmatch '^[0-9a-f]{40}$' -or
				$Pull.base.ref -isnot [string] -or [string]::IsNullOrWhiteSpace($Pull.base.ref) -or $Pull.base.ref.Length -gt 255 -or
				$Pull.mergeable -isnot [bool]) { throw 'revision_inventory_invalid' }
			$MergeSha = $null
			$MergeBaseSha = $null
		} catch { throw 'revision_inventory_invalid' }
		$BaseRefPath = 'repos/' + $Repository + '/git/ref/heads/' + [uri]::EscapeDataString($Pull.base.ref)
		$BaseRef = Invoke-PreparationGitHubRequest -Method GET -Path $BaseRefPath -Body $null -Transport $Transport
		try {
			if ($BaseRef.data.ref -cne ('refs/heads/' + $Pull.base.ref) -or $BaseRef.data.object.type -cne 'commit' -or
				$BaseRef.data.object.sha -cnotmatch '^[0-9a-f]{40}$') { throw 'revision_inventory_invalid' }
			$CurrentBaseSha = $BaseRef.data.object.sha
		} catch { throw 'revision_inventory_invalid' }
		if ($Pull.mergeable) {
			# API 2026-03-10 removed merge_commit_sha from pull responses.
			$MergeRef = Invoke-PreparationGitHubRequest -Method GET -Path "repos/$Repository/git/ref/pull/$($Pull.number)/merge" -Body $null -Transport $Transport
			try {
				if ($MergeRef.data.ref -cne "refs/pull/$($Pull.number)/merge" -or $MergeRef.data.object.type -cne 'commit' -or
					$MergeRef.data.object.sha -cnotmatch '^[0-9a-f]{40}$') { throw 'revision_inventory_invalid' }
				$MergeSha = $MergeRef.data.object.sha
			} catch { throw 'revision_inventory_invalid' }
		}
		if ($null -ne $MergeSha) {
			$Merge = Invoke-PreparationGitHubRequest -Method GET -Path "repos/$Repository/git/commits/$MergeSha" -Body $null -Transport $Transport
			try {
				if ($Merge.data.sha -cne $MergeSha -or $Merge.data.parents -isnot [array] -or $Merge.data.parents.Count -ne 2 -or
					$Merge.data.parents[0].sha -cnotmatch '^[0-9a-f]{40}$' -or $Merge.data.parents[1].sha -cne $Pull.head.sha) { throw 'revision_inventory_invalid' }
				$MergeBaseSha = $Merge.data.parents[0].sha
			} catch { throw 'revision_inventory_invalid' }
		}
		[void] $Revisions.Add([pscustomobject]@{ repository = $Pull.head.repo.full_name; revision = $Pull.head.sha; role = 'head'; pullNumber = $Pull.number })
		[void] $Revisions.Add([pscustomobject]@{ repository = $Repository; revision = $Pull.base.sha; role = 'base'; pullNumber = $Pull.number })
		if ($CurrentBaseSha -cne $Pull.base.sha) { [void] $Revisions.Add([pscustomobject]@{ repository = $Repository; revision = $CurrentBaseSha; role = 'current_base'; pullNumber = $Pull.number }) }
		if ($null -ne $MergeBaseSha -and $MergeBaseSha -cne $Pull.base.sha -and $MergeBaseSha -cne $CurrentBaseSha) {
			[void] $Revisions.Add([pscustomobject]@{ repository = $Repository; revision = $MergeBaseSha; role = 'merge_base'; pullNumber = $Pull.number })
		}
		if ($null -ne $MergeSha) { [void] $Revisions.Add([pscustomobject]@{ repository = $Repository; revision = $MergeSha; role = 'test_merge'; pullNumber = $Pull.number }) }
		# GitHub can retain an older test merge and an older reported base SHA.
		# Cover all those exact sources; none is a final-candidate acceptance claim.
		[void] $PullRequests.Add([pscustomobject]@{ number = $Pull.number; id = $Pull.id; headRepository = $Pull.head.repo.full_name; headSha = $Pull.head.sha; baseSha = $Pull.base.sha; baseRef = $Pull.base.ref; currentBaseSha = $CurrentBaseSha; mergeSha = $MergeSha; mergeBaseSha = $MergeBaseSha; mergeable = $Pull.mergeable })
	}
	# This is one observation, not an atomic snapshot or permission to quarantine.
	# The admission controller must re-enumerate after reading immutable sources.
	$Identity = [pscustomobject]@{ repository = $Repository; defaultBranch = $Branch; defaultSha = $DefaultSha; pullRequests = @($PullRequests) }
	$Bytes = [Text.Encoding]::UTF8.GetBytes(($Identity | ConvertTo-Json -Depth 5 -Compress))
	$Hasher = [Security.Cryptography.SHA256]::Create()
	try { $Key = ([BitConverter]::ToString($Hasher.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant() }
	finally { $Hasher.Dispose() }
	return [pscustomobject]@{ repository = $Repository; defaultBranch = $Branch; defaultSha = $DefaultSha; revisions = @($Revisions); pullRequests = @($PullRequests); activityKey = $Key }
}

function Get-PreparationReferenceRouting {
	[CmdletBinding()]
	param([Parameter(Mandatory)][string] $Repository,
		[Parameter(Mandatory)][string[]] $RunnerLabels,
		[Parameter(Mandatory)][string] $YamlAssemblyPath,
		[hashtable] $Cache = @{},
		[scriptblock] $Transport = { param($Request) Invoke-PreparationGitHubApi -Request $Request })
	$Before = Get-PreparationRevisionInventory -Repository $Repository -Transport $Transport
	$Sources = New-Object Collections.ArrayList
	$Seen = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
	foreach ($Revision in $Before.revisions) {
		$Key = $Revision.repository + ':' + $Revision.revision
		if (-not $Seen.Add($Key)) { continue }
		$Workflows = Get-PreparationCachedWorkflowSource -Repository $Revision.repository -Revision $Revision.revision -RunnerLabels $RunnerLabels -YamlAssemblyPath $YamlAssemblyPath -Cache $Cache -Transport $Transport
		[void] $Sources.Add([pscustomobject]@{ repository = $Revision.repository; revision = $Revision.revision; workflows = $Workflows })
	}
	$After = Get-PreparationRevisionInventory -Repository $Repository -Transport $Transport
	if ($Before.activityKey -cne $After.activityKey) { throw 'revision_inventory_changed' }
	# Active run revisions, local worker state and the quiet interval are separate
	# mandatory admission inputs. Stable references alone never admit maintenance.
	return [pscustomobject]@{ referencesStable = $true; activityKey = $After.activityKey; inventory = $After; sources = @($Sources) }
}

function Get-PreparationCachedWorkflowSource {
	[CmdletBinding()]
	[OutputType([object[]])]
	param([string] $Repository, [string] $Revision, [string[]] $RunnerLabels, [string] $YamlAssemblyPath,
		[hashtable] $Cache, [scriptblock] $Transport)
	Initialize-PreparationYaml -AssemblyPath $YamlAssemblyPath
	$Context = (@($RunnerLabels | Sort-Object -CaseSensitive) | ConvertTo-Json -Compress) + '|' + [IO.Path]::GetFullPath($YamlAssemblyPath)
	if ($Cache.Count -eq 0) { $Cache.context = $Context; $Cache.entries = @{}; $Cache.bytes = 0L }
	if ($Cache.context -cne $Context -or $Cache.entries -isnot [hashtable] -or $Cache.bytes -isnot [long] -or
		$Cache.bytes -lt 0 -or $Cache.bytes -gt 16777216) { throw 'routing_cache_invalid' }
	$Key = $Repository + ':' + $Revision
	if (-not $Cache.entries.ContainsKey($Key)) {
		if ($Cache.entries.Count -ge 256) { throw 'routing_cache_limit' }
		$Workflows = Get-PreparationWorkflowSource -Repository $Repository -Revision $Revision -RunnerLabels $RunnerLabels -YamlAssemblyPath $YamlAssemblyPath -Transport $Transport
		$Json = ConvertTo-Json -InputObject @($Workflows) -Depth 10 -Compress
		$Bytes = [Text.Encoding]::UTF8.GetByteCount($Json)
		if ($Bytes -gt 1048576 -or $Cache.bytes + $Bytes -gt 16777216) { throw 'routing_cache_limit' }
		# Store serialized immutable proof, not a mutable object returned to callers.
		$Cache.entries[$Key] = $Json
		$Cache.bytes += $Bytes
	}
	$Decoded = ConvertFrom-PreparationGitHubJson -Json $Cache.entries[$Key]
	if ($Decoded -isnot [array]) { throw 'routing_cache_invalid' }
	return ,$Decoded
}

function Get-PreparationQueueDigest {
	[CmdletBinding()]
	param([Parameter(Mandatory)] $Inventory)
	$Identity = [ordered]@{
		runner = [ordered]@{ id = $Inventory.runner.id; name = $Inventory.runner.name; status = $Inventory.runner.status;
			busy = $Inventory.runner.busy; labels = @((Get-PreparationLabelSet -RunnerData $Inventory.runner) | Sort-Object -CaseSensitive) }
		runs = @($Inventory.runs | Sort-Object -Property id | Select-Object id, run_attempt, head_sha, status, event, path)
		jobs = @($Inventory.jobs | Sort-Object -Property runId, runAttempt | ForEach-Object {
			[pscustomobject]@{ runId = $_.runId; runAttempt = $_.runAttempt; headSha = $_.headSha; job = $_.job }
		})
	}
	$Bytes = [Text.Encoding]::UTF8.GetBytes(($Identity | ConvertTo-Json -Depth 12 -Compress))
	if ($Bytes.Length -gt 1048576) { throw 'inventory_limit' }
	$Hasher = [Security.Cryptography.SHA256]::Create()
	try { return ([BitConverter]::ToString($Hasher.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant() }
	finally { $Hasher.Dispose() }
}

function Get-InitialPreparationAdmissionInventory {
	[CmdletBinding()]
	param([Parameter(Mandatory)] $Runner, [Parameter(Mandatory)][string] $YamlAssemblyPath,
		[Parameter(Mandatory)][hashtable] $Cache,
		[scriptblock] $Transport = { param($Request) Invoke-PreparationGitHubApi -Request $Request })
	$Routing = Get-PreparationReferenceRouting -Repository $Runner.repository -RunnerLabels $Runner.originalLabels -YamlAssemblyPath $YamlAssemblyPath -Cache $Cache -Transport $Transport
	$Before = Get-InitialPreparationQueueInventory -Repository $Runner.repository -ExpectedRunnerId $Runner.id -ExpectedRunnerName $Runner.name -Transport $Transport
	$BeforeKey = Get-PreparationQueueDigest -Inventory $Before
	foreach ($Run in $Before.runs) {
		# REST head_sha does not alone prove the executed workflow revision for
		# pull_request/target/reusable or unknown events. Refuse unresolved sources;
		# never guess the present merge ref for an older active run.
		try {
			if ($Run.event -isnot [string] -or $Run.event -cnotin @('push', 'workflow_dispatch', 'schedule') -or
				$Run.head_repository.full_name -cne $Runner.repository -or $Run.path -isnot [string] -or
				$Run.path -cnotmatch '^\.github/workflows/[A-Za-z0-9_.-]+\.ya?ml$') { throw 'active_run_source_unresolved' }
		} catch { throw 'active_run_source_unresolved' }
		$Source = Get-PreparationCachedWorkflowSource -Repository $Runner.repository -Revision $Run.head_sha -RunnerLabels $Runner.originalLabels -YamlAssemblyPath $YamlAssemblyPath -Cache $Cache -Transport $Transport
		if (@($Source | Where-Object { $_.path -ceq $Run.path }).Count -ne 1) { throw 'active_run_source_unresolved' }
	}
	foreach ($Item in $Before.jobs) {
		$Labels = $Item.job.labels
		if ($Labels -isnot [array] -or $Labels.Count -lt 1 -or $Labels.Count -gt 100) { throw 'inventory_incomplete' }
		$Eligible = $true
		foreach ($Label in $Labels) {
			if ($Label -isnot [string] -or [string]::IsNullOrWhiteSpace($Label)) { throw 'inventory_incomplete' }
			if ($Runner.originalLabels -notcontains $Label) { $Eligible = $false }
		}
		if (($Eligible -or $Item.job.runner_id -eq $Runner.id) -and $Labels -notcontains 'aetheln-engine') { throw 'eligible_route_bypasses_label' }
	}
	$After = Get-InitialPreparationQueueInventory -Repository $Runner.repository -ExpectedRunnerId $Runner.id -ExpectedRunnerName $Runner.name -Transport $Transport
	$AfterKey = Get-PreparationQueueDigest -Inventory $After
	$References = Get-PreparationRevisionInventory -Repository $Runner.repository -Transport $Transport
	if ($BeforeKey -cne $AfterKey -or $References.activityKey -cne $Routing.activityKey) { throw 'inventory_changed' }
	if ($After.runner.busy -isnot [bool] -or $After.runner.status -isnot [string]) { throw 'inventory_incomplete' }
	return [pscustomobject]@{ complete = $true; routesSafe = $true; runnerId = $Runner.id; runnerName = $Runner.name;
		online = ($After.runner.status -ceq 'online'); busy = $After.runner.busy;
		labels = (Get-PreparationLabelSet -RunnerData $After.runner); activeJobs = $After.activeJobs;
		activityKey = ($References.activityKey + ':' + $AfterKey); observedTicks = (Get-InitialPreparationTick);
		referenceSourceCount = $Routing.sources.Count; activeRunCount = $After.runs.Count;
		runtimeProof = (Get-InitialPreparationRuntimeProof -Runner $Runner -ReferenceKey $References.activityKey -Cache $Cache) }
}

function Get-InitialPreparationRuntimeProof {
	[CmdletBinding()]
	param([Parameter(Mandatory)] $Runner, [Parameter(Mandatory)][string] $ReferenceKey,
		[Parameter(Mandatory)][hashtable] $Cache)
	$Sources = @($Cache.entries.Keys | Sort-Object -CaseSensitive | ForEach-Object {
		$Parts = $_.Split(':')
		if ($Parts.Count -ne 2) { throw 'runtime_proof_invalid' }
		[pscustomobject]@{ repository = $Parts[0]; revision = $Parts[1];
			workflows = (ConvertFrom-PreparationGitHubJson -Json $Cache.entries[$_]) }
	})
	$Proof = [pscustomobject][ordered]@{ schemaVersion = 1; repository = $Runner.repository;
		runnerId = $Runner.id; runnerName = $Runner.name; originalLabels = @($Runner.originalLabels);
		referenceKey = $ReferenceKey; sources = $Sources }
	Assert-InitialPreparationRuntimeProof -Proof $Proof -Runner $Runner
	return $Proof
}

function Assert-InitialPreparationRuntimeProof {
	[CmdletBinding()]
	param([Parameter(Mandatory)] $Proof, [Parameter(Mandatory)] $Runner)
	try {
		$Fields = @('schemaVersion', 'repository', 'runnerId', 'runnerName', 'originalLabels', 'referenceKey', 'sources')
		if (@($Proof.PSObject.Properties).Count -ne $Fields.Count) { throw 'invalid' }
		foreach ($Field in $Fields) { if ($Proof.PSObject.Properties.Name -cnotcontains $Field) { throw 'invalid' } }
		if ($Proof.schemaVersion -isnot [int] -or $Proof.schemaVersion -ne 1 -or
			($Proof.runnerId -isnot [int] -and $Proof.runnerId -isnot [long]) -or
			$Proof.runnerId -ne $Runner.id -or $Proof.repository -isnot [string] -or $Proof.repository -cne $Runner.repository -or
			$Proof.runnerName -isnot [string] -or $Proof.runnerName -cne $Runner.name -or
			$Proof.referenceKey -isnot [string] -or $Proof.referenceKey -cnotmatch '^[0-9a-f]{64}$' -or
			$Proof.originalLabels -isnot [array] -or $Proof.originalLabels.Count -lt 1 -or $Proof.originalLabels.Count -gt 100 -or
			$Proof.originalLabels -cnotcontains 'aetheln-engine' -or
			-not (Test-PreparationLabelSet -Actual $Proof.originalLabels -Expected $Runner.originalLabels) -or
			$Proof.sources -isnot [array] -or $Proof.sources.Count -lt 1 -or $Proof.sources.Count -gt 256) { throw 'invalid' }
		$SourceKeys = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
		foreach ($Source in $Proof.sources) {
			if (@($Source.PSObject.Properties).Count -ne 3 -or $Source.repository -isnot [string] -or
				$Source.repository -cnotmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' -or $Source.revision -isnot [string] -or
				$Source.revision -cnotmatch '^[0-9a-f]{40}$' -or -not $SourceKeys.Add($Source.repository + ':' + $Source.revision) -or
				$Source.workflows -isnot [array] -or $Source.workflows.Count -gt 100) { throw 'invalid' }
			$Paths = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
			foreach ($Workflow in $Source.workflows) {
				if (@($Workflow.PSObject.Properties).Count -ne 6 -or $Workflow.revision -isnot [string] -or $Workflow.revision -cne $Source.revision -or
					$Workflow.path -isnot [string] -or $Workflow.path -cnotmatch '^\.github/workflows/[A-Za-z0-9_.-]+\.ya?ml$' -or
					-not $Paths.Add($Workflow.path) -or $Workflow.blobId -isnot [string] -or $Workflow.blobId -cnotmatch '^[0-9a-f]{40}$' -or
					$Workflow.sha256 -isnot [string] -or $Workflow.sha256 -cnotmatch '^[0-9a-f]{64}$' -or
					($Workflow.bytes -isnot [int] -and $Workflow.bytes -isnot [long]) -or $Workflow.bytes -lt 1 -or $Workflow.bytes -gt 262144 -or
					$Workflow.routes -isnot [array] -or $Workflow.routes.Count -lt 1 -or $Workflow.routes.Count -gt 100) { throw 'invalid' }
				$Jobs = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
				foreach ($Route in $Workflow.routes) {
					if (@($Route.PSObject.Properties).Count -ne 3 -or $Route.jobId -isnot [string] -or
						$Route.jobId -cnotmatch '^[A-Za-z_][A-Za-z0-9_-]*$' -or -not $Jobs.Add($Route.jobId) -or
						$Route.eligible -isnot [bool] -or $Route.labels -isnot [array] -or $Route.labels.Count -lt 1 -or $Route.labels.Count -gt 100) { throw 'invalid' }
					$Eligible = $true
					foreach ($Label in $Route.labels) {
						if ($Label -isnot [string] -or [string]::IsNullOrWhiteSpace($Label) -or $Label.Length -gt 100 -or $Label.Contains('${{')) { throw 'invalid' }
						if ($Runner.originalLabels -notcontains $Label) { $Eligible = $false }
					}
					if ($Route.eligible -ne $Eligible -or ($Eligible -and $Route.labels -notcontains 'aetheln-engine')) { throw 'invalid' }
				}
			}
		}
		if ([Text.Encoding]::UTF8.GetByteCount(($Proof | ConvertTo-Json -Depth 12 -Compress)) -gt 16777216) { throw 'invalid' }
	} catch { throw 'runtime_proof_invalid' }
}

function Get-PreparationGitHubRetryDelay {
	[CmdletBinding()]
	[OutputType([long])]
	param([Parameter(Mandatory)] $Failure, [Parameter(Mandatory)][long] $UtcNowSeconds)
	if ($Failure -isnot [Aetheln.PreparationGitHubFailure] -or
		$Failure.Category -cnotin @('http_transient', 'http_rate_limit')) { return $null }
	$Wait = 1000L
	if ($null -ne $Failure.RetryAfterSeconds) { $Wait = [Math]::Max($Wait, $Failure.RetryAfterSeconds * 1000L) }
	if ($null -ne $Failure.RateLimitRemaining -and $Failure.RateLimitRemaining -eq 0) {
		# A primary-limit response requires its reset observation, even if another
		# header suggests a shorter delay. Neither wait may be silently shortened.
		if ($null -eq $Failure.RateLimitReset) { return $null }
		$Wait = [Math]::Max($Wait, [Math]::Max(0L, $Failure.RateLimitReset - $UtcNowSeconds) * 1000L)
	} elseif ($Failure.Category -ceq 'http_rate_limit' -and $null -eq $Failure.RetryAfterSeconds) {
		# A secondary limit without a usable server wait needs at least a minute;
		# this cannot fit a 55-second cycle and therefore fails without retrying.
		$Wait = [Math]::Max($Wait, 60000L)
	}
	return [long] $Wait
}

function Test-PreparationEntityTag {
	[CmdletBinding()]
	[OutputType([bool])]
	param([AllowNull()] $Value)
	return ($Value -is [string] -and $Value -cmatch '^(?:W/)?"[\x21\x23-\x7e]{1,256}"$')
}

function Test-PreparationWeakEntityTag {
	[CmdletBinding()]
	[OutputType([bool])]
	param([AllowNull()] $Left, [AllowNull()] $Right)
	if (-not (Test-PreparationEntityTag -Value $Left) -or -not (Test-PreparationEntityTag -Value $Right)) { return $false }
	# RFC9110 sections8.8.3.2/13.1.2: If-None-Match compares opaque tags
	# character-for-character, ignoring only the optional validated W/ prefix.
	$LeftOpaque = if ($Left.StartsWith('W/', [StringComparison]::Ordinal)) { $Left.Substring(2) } else { $Left }
	$RightOpaque = if ($Right.StartsWith('W/', [StringComparison]::Ordinal)) { $Right.Substring(2) } else { $Right }
	return [string]::Equals($LeftOpaque, $RightOpaque, [StringComparison]::Ordinal)
}

function Test-PreparationConditionalPath {
	[CmdletBinding()]
	[OutputType([bool])]
	param([Parameter(Mandatory)] $Request)
	# Never condition collections or query-bearing pages: an unchanged body
	# validator alone cannot establish current pagination Link completeness.
	return ($Request.method -ceq 'GET' -and $Request.path -is [string] -and
		$Request.path -cmatch '^repos/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(?:/git/ref/heads/[A-Za-z0-9_.%/-]+|/git/ref/pull/[1-9][0-9]*/merge|/pulls/[1-9][0-9]*|/git/commits/[0-9a-f]{40}|/actions/runs/[1-9][0-9]*)?$')
}

function New-PreparationConditionalCache {
	[CmdletBinding()]
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Pure in-memory cache factory; no external state change.')]
	[OutputType([hashtable])]
	param([Parameter(Mandatory)] $Attempt)
	Assert-InitialPreparationAttempt -Attempt $Attempt
	$AttemptDigest = Get-PreparationBodyDigest -Json (ConvertTo-Json -InputObject $Attempt -Depth 4 -Compress)
	return @{ identity = ($AttemptDigest.sha256 + '|' + $Attempt.repository + '|github.com|GET|application/vnd.github+json|2026-03-10'); entries = @{}; bytes = 0L }
}

function Get-PreparationBodyDigest {
	[CmdletBinding()]
	param([Parameter(Mandatory)][string] $Json)
	$Bytes = [Text.UTF8Encoding]::new($false, $true).GetBytes($Json)
	if ($Bytes.Length -gt 1048576) { throw 'conditional_response_invalid' }
	$Hasher = [Security.Cryptography.SHA256]::Create()
	try { return [pscustomobject]@{ bytes = $Bytes.Length; sha256 = ([BitConverter]::ToString($Hasher.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant() } }
	finally { $Hasher.Dispose() }
}

function Invoke-PreparationConditionalRequest {
	[CmdletBinding()]
	param([Parameter(Mandatory)] $Request, [Parameter(Mandatory)][hashtable] $Cache,
		[Parameter(Mandatory)][scriptblock] $Transport, [Parameter(Mandatory)] $State)
	$TransportFailed = $false
	try {
		if ($Request.PSObject.Properties.Name -ccontains 'ifNoneMatch') { throw 'invalid' }
		$Eligible = Test-PreparationConditionalPath -Request $Request
		$Key = $Cache.identity + '|' + $Request.path
		$Entry = $null
		$SentJson = $null; $SentHash = $null; $SentBytes = 0; $SentTag = $null
		$Wire = [pscustomobject]@{ method = $Request.method; path = $Request.path; body = $Request.body; timeoutMilliseconds = $Request.timeoutMilliseconds }
		if ($Eligible -and $Cache.entries.ContainsKey($Key)) {
			$Entry = $Cache.entries[$Key]
			$Digest = Get-PreparationBodyDigest -Json $Entry.json
			if ($Entry.key -cne $Key -or -not (Test-PreparationEntityTag -Value $Entry.etag) -or
				$Digest.bytes -ne $Entry.bytes -or $Digest.sha256 -cne $Entry.sha256) { throw 'invalid' }
			$SentJson = [string] $Entry.json; $SentHash = [string] $Entry.sha256; $SentBytes = [int] $Entry.bytes; $SentTag = [string] $Entry.etag
			$Wire | Add-Member -NotePropertyName ifNoneMatch -NotePropertyValue $SentTag
		}
		# Always perform the network observation. No error path returns cached data.
		$TransportFailed = $true
		$Response = & $Transport $Wire
		$TransportFailed = $false
		if ($Response.statusCode -isnot [int] -or $Response.headers -isnot [Collections.IDictionary] -or
			($Response.PSObject.Properties.Name -ccontains 'nativeExitCode' -and $Response.nativeExitCode -isnot [int])) { throw 'invalid' }
		if ($Response.statusCode -eq 304) {
			if ($null -eq $Entry -or -not [object]::ReferenceEquals($Cache.entries[$Key], $Entry) -or
				$Response.headers -isnot [Collections.IDictionary] -or -not $Response.headers.Contains('ETag') -or
				-not (Test-PreparationWeakEntityTag -Left $Response.headers['ETag'] -Right $SentTag) -or
				$Wire.ifNoneMatch -isnot [string] -or $Wire.ifNoneMatch -cne $SentTag -or $Response.nativeExitCode -ne 1 -or
				$Response.bodyJson -isnot [string] -or $Response.bodyJson.Length -ne 0) { throw 'invalid' }
			$Digest = Get-PreparationBodyDigest -Json $Entry.json
			if ($Entry.key -cne $Key -or $Digest.bytes -ne $SentBytes -or $Entry.bytes -ne $SentBytes -or
				$Digest.sha256 -cne $SentHash -or $Entry.sha256 -cne $SentHash -or $Entry.json -cne $SentJson -or $Entry.etag -cne $SentTag) { throw 'invalid' }
			$State.notModifiedCount++
			return [pscustomobject]@{ statusCode = 200; headers = @{}; data = (ConvertFrom-PreparationGitHubJson -Json $SentJson) }
		}
		if ($Response.statusCode -eq 200) {
			if ($Response.PSObject.Properties.Name -ccontains 'nativeExitCode' -and $Response.nativeExitCode -ne 0) { throw 'invalid' }
			$State.okCount++
			if ($Eligible) {
				if ($null -ne $Entry) { $Cache.bytes -= $Entry.bytes; $Cache.entries.Remove($Key) }
				if ($Response.headers.Contains('ETag')) {
					if (-not (Test-PreparationEntityTag -Value $Response.headers['ETag']) -or $Response.bodyJson -isnot [string]) { throw 'invalid' }
					$Digest = Get-PreparationBodyDigest -Json $Response.bodyJson
					$Data = ConvertFrom-PreparationGitHubJson -Json $Response.bodyJson
					if ($null -eq $Data) { throw 'invalid' }
					if ($Cache.entries.Count -lt 128 -and $Cache.bytes + $Digest.bytes -le 16777216) {
						$Cache.entries[$Key] = [pscustomobject]@{ key = $Key; etag = $Response.headers['ETag']; json = $Response.bodyJson; bytes = $Digest.bytes; sha256 = $Digest.sha256 }
						$Cache.bytes += $Digest.bytes
					}
					return [pscustomobject]@{ statusCode = 200; headers = $Response.headers; data = $Data }
				}
			}
		}
		return $Response
	} catch {
		$Failure = Get-PreparationGitHubFailure -Exception $_.Exception
		if ($TransportFailed -or $Failure.Category -cne 'transport_failure') { throw $Failure }
		throw [Aetheln.PreparationGitHubFailure]::new('response_invalid', $null, $null, $null, $null, $null)
	}
}

function Get-PreparationMonitorDelayMilliseconds {
	[CmdletBinding()]
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Milliseconds is the explicit integer unit returned by this pure delay calculation.')]
	[OutputType([int])]
	param([Parameter(Mandatory)] $Attempt, [Parameter(Mandatory)][long] $StartedTicks, [Parameter(Mandatory)][long] $NowTicks)
	if ($NowTicks -lt $StartedTicks -or $Attempt.monotonicFrequency -le 0) { throw 'monitor_clock_invalid' }
	$Remaining = [Math]::Floor(($Attempt.stopUsefulWorkTicks - $NowTicks) * 1000.0 / $Attempt.monotonicFrequency)
	if ($Remaining -le 0) { throw 'useful_work_deadline' }
	$Delay = [Math]::Max(5000, [Math]::Ceiling(30000 - ($NowTicks - $StartedTicks) * 1000.0 / $Attempt.monotonicFrequency))
	return [int] [Math]::Min($Delay, $Remaining)
}

function Invoke-PreparationRuntimeRequest {
	[CmdletBinding()]
	param([Parameter(Mandatory)] $Request, [Parameter(Mandatory)] $Budget,
		[Parameter(Mandatory)][scriptblock] $Transport, [Parameter(Mandatory)][scriptblock] $ReadTicks,
		[Parameter(Mandatory)][scriptblock] $ReadUtcSeconds, [Parameter(Mandatory)][scriptblock] $DelayMilliseconds)
	$CallStart = & $ReadTicks
	$CallDeadline = [long] [Math]::Min($Budget.deadline, $CallStart + [long] (30 * $Budget.frequency))
	for ($NativeAttempt = 0; $NativeAttempt -lt 2; $NativeAttempt++) {
		$Remaining = [Math]::Floor(($CallDeadline - (& $ReadTicks)) * 1000.0 / $Budget.frequency)
		if ($Remaining -lt 1 -or $Budget.state.requestCount -ge 1000) { throw 'runtime_cycle_deadline' }
		$Request | Add-Member -NotePropertyName timeoutMilliseconds -NotePropertyValue ([int] [Math]::Min(30000, $Remaining)) -Force
		$Budget.state.requestCount++
		try {
			$Response = & $Transport $Request
			if ((& $ReadTicks) -ge $CallDeadline) { throw 'runtime_cycle_deadline' }
			if ($Response.statusCode -isnot [int]) { throw 'invalid' }
			if ($Response.statusCode -lt 200 -or $Response.statusCode -ge 300) {
				throw (Get-PreparationGitHubHttpFailure -StatusCode $Response.statusCode -Headers $Response.headers -NativeExitCode $null)
			}
			return $Response
		} catch {
			$Failure = Get-PreparationGitHubFailure -Exception $_.Exception
			$Diagnostic = [pscustomobject][ordered]@{ category = $Failure.Category; httpStatus = $Failure.HttpStatus;
				nativeExitCode = $Failure.NativeExitCode; timedOut = ($Failure.Category -ceq 'native_timeout');
				cleanupVerified = $Failure.CleanupVerified; retryAfterSeconds = $Failure.RetryAfterSeconds;
				rateLimitRemaining = $Failure.RateLimitRemaining; rateLimitResetUnixSeconds = $Failure.RateLimitReset;
				retryDelayMilliseconds = $null; retryDecision = 'not_retryable' }
			$Budget.state.lastFailure = $Diagnostic
			if ((& $ReadTicks) -ge $CallDeadline) { $Diagnostic.retryDecision = 'budget_exhausted'; throw $Failure }
			$Wait = Get-PreparationGitHubRetryDelay -Failure $Failure -UtcNowSeconds (& $ReadUtcSeconds)
			if ($Request.method -cne 'GET' -or $null -eq $Wait) { throw $Failure }
			$Diagnostic.retryDelayMilliseconds = $Wait
			if ($NativeAttempt -gt 0 -or $Budget.state.retryCount -ge 1) { $Diagnostic.retryDecision = 'retry_limit'; throw $Failure }
			$Remaining = [Math]::Floor(($CallDeadline - (& $ReadTicks)) * 1000.0 / $Budget.frequency)
			# Leave at least the transport's cleanup reserve and one millisecond
			# of request time. This is the SAME call deadline, never a new 30s.
			if ($Wait -gt [int]::MaxValue -or $Wait + 2000 -ge $Remaining) { $Diagnostic.retryDecision = 'budget_exhausted'; throw $Failure }
			$Diagnostic.retryDecision = 'retry_scheduled'
			$Budget.state.retryCount++
			& $DelayMilliseconds ([int] $Wait)
			if ((& $ReadTicks) -ge $CallDeadline) { $Diagnostic.retryDecision = 'budget_exhausted'; throw $Failure }
		}
	}
	throw 'github_api_failed'
}

function Get-InitialPreparationRuntimeInventory {
	[CmdletBinding()]
	param([Parameter(Mandatory)] $Runner, [Parameter(Mandatory)] $Proof,
		[Parameter(Mandatory)] $Attempt, [Parameter(Mandatory)][long] $DeadlineTicks,
		[Parameter(Mandatory)] $CycleState,
		[hashtable] $ConditionalCache,
		[scriptblock] $ReadTicks = { Get-InitialPreparationTick },
		[scriptblock] $ReadUtcSeconds = { [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() },
		[scriptblock] $DelayMilliseconds = { param($Milliseconds) Start-Sleep -Milliseconds $Milliseconds },
		[scriptblock] $Transport = { param($Request) Invoke-PreparationGitHubApi -Request $Request -TimeoutMilliseconds $Request.timeoutMilliseconds })
	# Runtime never resolves/adopts a new source. Admission alone establishes the
	# immutable proof; two live reference and queue observations must still agree.
	$CycleState.startedTicks = & $ReadTicks
	$CycleState.finishedTicks = $null
	$CycleState.requestCount = 0
	$CycleState.phase = 'proof'
	$CycleState.failureCode = $null
	$CycleState | Add-Member -NotePropertyName retryCount -NotePropertyValue 0 -Force
	$CycleState | Add-Member -NotePropertyName lastFailure -NotePropertyValue $null -Force
	$CycleState | Add-Member -NotePropertyName okCount -NotePropertyValue 0 -Force
	$CycleState | Add-Member -NotePropertyName notModifiedCount -NotePropertyValue 0 -Force
	if ($null -eq $ConditionalCache) { $ConditionalCache = New-PreparationConditionalCache -Attempt $Attempt }
	$ExpectedCache = New-PreparationConditionalCache -Attempt $Attempt
	if ($ConditionalCache.identity -cne $ExpectedCache.identity -or $ConditionalCache.entries -isnot [hashtable] -or
		$ConditionalCache.entries.Count -gt 128 -or $ConditionalCache.bytes -lt 0 -or $ConditionalCache.bytes -gt 16777216) { throw 'runtime_proof_invalid' }
	$RuntimeClock = $ReadTicks; $ConditionalTransport = $Transport
	$RuntimeTransport = { param($Request) Invoke-PreparationConditionalRequest -Request $Request -Cache $ConditionalCache -Transport $ConditionalTransport -State $CycleState }.GetNewClosure()
	$RuntimeUtc = $ReadUtcSeconds; $RuntimeDelay = $DelayMilliseconds
	$Budget = [pscustomobject]@{ deadline = $DeadlineTicks; frequency = $Attempt.monotonicFrequency; state = $CycleState }
	$BoundedTransport = {
		param($Request)
		return Invoke-PreparationRuntimeRequest -Request $Request -Budget $Budget -Transport $RuntimeTransport -ReadTicks $RuntimeClock -ReadUtcSeconds $RuntimeUtc -DelayMilliseconds $RuntimeDelay
	}.GetNewClosure()
	try {
		Assert-InitialPreparationAttempt -Attempt $Attempt
		if ($DeadlineTicks -gt $Attempt.stopUsefulWorkTicks -or
			$DeadlineTicks -gt $CycleState.startedTicks + [long] (55 * $Attempt.monotonicFrequency) -or
			$DeadlineTicks -le $CycleState.startedTicks) { throw 'runtime_cycle_deadline' }
		Assert-InitialPreparationRuntimeProof -Proof $Proof -Runner $Runner
		$CycleState.phase = 'references_before'
		$ReferencesBefore = Get-PreparationRevisionInventory -Repository $Runner.repository -Transport $BoundedTransport
		if ($ReferencesBefore.activityKey -cne $Proof.referenceKey) { throw 'runtime_references_changed' }
		$CycleState.phase = 'queue_before'
		$Before = Get-InitialPreparationQueueInventory -Repository $Runner.repository -ExpectedRunnerId $Runner.id -ExpectedRunnerName $Runner.name -Transport $BoundedTransport
		$BeforeKey = Get-PreparationQueueDigest -Inventory $Before
		$CycleState.phase = 'active_sources'
		foreach ($Run in $Before.runs) {
			if ($Run.event -isnot [string] -or $Run.event -cnotin @('push', 'workflow_dispatch', 'schedule') -or
				$Run.head_repository.full_name -cne $Runner.repository -or $Run.path -isnot [string] -or
				$Run.path -cnotmatch '^\.github/workflows/[A-Za-z0-9_.-]+\.ya?ml$') { throw 'active_run_source_unresolved' }
			$Source = @($Proof.sources | Where-Object { $_.repository -ceq $Runner.repository -and $_.revision -ceq $Run.head_sha })
			if ($Source.Count -ne 1 -or @($Source[0].workflows | Where-Object { $_.path -ceq $Run.path }).Count -ne 1) { throw 'active_run_source_unresolved' }
		}
		foreach ($Item in $Before.jobs) {
			$Labels = $Item.job.labels
			if ($Labels -isnot [array] -or $Labels.Count -lt 1 -or $Labels.Count -gt 100) { throw 'inventory_incomplete' }
			$Eligible = $true
			foreach ($Label in $Labels) {
				if ($Label -isnot [string] -or [string]::IsNullOrWhiteSpace($Label)) { throw 'inventory_incomplete' }
				if ($Runner.originalLabels -notcontains $Label) { $Eligible = $false }
			}
			if (($Eligible -or $Item.job.runner_id -eq $Runner.id) -and $Labels -notcontains 'aetheln-engine') { throw 'eligible_route_bypasses_label' }
		}
		$CycleState.phase = 'queue_after'
		$After = Get-InitialPreparationQueueInventory -Repository $Runner.repository -ExpectedRunnerId $Runner.id -ExpectedRunnerName $Runner.name -Transport $BoundedTransport
		$AfterKey = Get-PreparationQueueDigest -Inventory $After
		if ($BeforeKey -cne $AfterKey) { throw 'inventory_changed' }
		$CycleState.phase = 'references_after'
		$ReferencesAfter = Get-PreparationRevisionInventory -Repository $Runner.repository -Transport $BoundedTransport
		if ($ReferencesAfter.activityKey -cne $Proof.referenceKey) { throw 'runtime_references_changed' }
		if ((& $ReadTicks) -ge $DeadlineTicks) { throw 'runtime_cycle_deadline' }
		if ($After.runner.busy -isnot [bool] -or $After.runner.status -isnot [string]) { throw 'inventory_incomplete' }
		$CycleState.phase = 'complete'
		return [pscustomobject]@{ complete = $true; routesSafe = $true; runnerId = $Runner.id; runnerName = $Runner.name;
			online = ($After.runner.status -ceq 'online'); busy = $After.runner.busy;
			labels = (Get-PreparationLabelSet -RunnerData $After.runner); activeJobs = $After.activeJobs;
			observedTicks = (& $ReadTicks) }
	} catch {
		$Known = @('runtime_proof_invalid', 'runtime_references_changed', 'runtime_cycle_deadline', 'active_run_source_unresolved',
			'inventory_changed', 'inventory_incomplete', 'runner_identity_mismatch', 'unexpected_shared_engine_runner',
			'eligible_route_bypasses_label', 'revision_inventory_invalid', 'github_api_failed')
		$Code = if ((& $ReadTicks) -ge $DeadlineTicks) { 'runtime_cycle_deadline' }
			elseif ($Known -ccontains $_.Exception.Message) { $_.Exception.Message } else { 'runtime_observation_failed' }
		$CycleState.failureCode = $Code
		$TypedFailure = Get-PreparationGitHubFailure -Exception $_.Exception
		if ($Code -ceq 'github_api_failed' -and $TypedFailure.Category -cne 'transport_failure') { throw $TypedFailure }
		throw $Code
	} finally { $CycleState.finishedTicks = & $ReadTicks }
}

function Get-PreparationSourceTree {
	[CmdletBinding()]
	[OutputType([object[]])]
	param([string] $Repository, [string] $TreeId, [scriptblock] $Transport)
	if ($TreeId -cnotmatch '^[0-9a-f]{40}$') { throw 'workflow_source_invalid' }
	$Response = Invoke-PreparationGitHubRequest -Method GET -Path "repos/$Repository/git/trees/$TreeId" -Body $null -Transport $Transport
	try {
		$Tree = $Response.data
		if ($Tree.sha -cne $TreeId -or $Tree.truncated -isnot [bool] -or $Tree.truncated -or
			$Tree.tree -isnot [array] -or $Tree.tree.Count -gt 10000) { throw 'workflow_source_invalid' }
		$Names = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
		foreach ($Entry in $Tree.tree) {
			if ($Entry.path -isnot [string] -or [string]::IsNullOrEmpty($Entry.path) -or
				$Entry.path.Contains('/') -or $Entry.path -in @('.', '..') -or -not $Names.Add($Entry.path) -or
				$Entry.sha -cnotmatch '^[0-9a-f]{40}$') { throw 'workflow_source_invalid' }
		}
		return ,$Tree.tree
	} catch { throw 'workflow_source_invalid' }
}

function Get-PreparationWorkflowSource {
	[CmdletBinding()]
	[OutputType([object[]])]
	param([Parameter(Mandatory)][string] $Repository,
		[Parameter(Mandatory)][string] $Revision,
		[Parameter(Mandatory)][string[]] $RunnerLabels,
		[Parameter(Mandatory)][string] $YamlAssemblyPath,
		[scriptblock] $Transport = { param($Request) Invoke-PreparationGitHubApi -Request $Request })
	if ($Repository -cnotmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' -or $Revision -cnotmatch '^[0-9a-f]{40}$') { throw 'workflow_source_invalid' }
	$Commit = Invoke-PreparationGitHubRequest -Method GET -Path "repos/$Repository/git/commits/$Revision" -Body $null -Transport $Transport
	try {
		if ($Commit.data.sha -cne $Revision) { throw 'workflow_source_invalid' }
		$TreeId = $Commit.data.tree.sha
	} catch { throw 'workflow_source_invalid' }
	foreach ($Directory in @('.github', 'workflows')) {
		$Entries = Get-PreparationSourceTree -Repository $Repository -TreeId $TreeId -Transport $Transport
		$Selected = @($Entries | Where-Object { $_.path -ceq $Directory })
		if ($Selected.Count -eq 0) { return ,@() }
		if ($Selected.Count -ne 1 -or $Selected[0].mode -cne '040000' -or $Selected[0].type -cne 'tree') { throw 'workflow_source_invalid' }
		$TreeId = $Selected[0].sha
	}
	$Entries = Get-PreparationSourceTree -Repository $Repository -TreeId $TreeId -Transport $Transport
	$Workflows = @($Entries | Where-Object { $_.path -match '\.ya?ml$' })
	if ($Workflows.Count -gt 100) { throw 'workflow_source_invalid' }
	$Sources = New-Object Collections.ArrayList
	$TotalBytes = 0
	foreach ($Entry in $Workflows) {
		if ($Entry.type -cne 'blob' -or $Entry.mode -cnotin @('100644', '100755')) { throw 'workflow_source_invalid' }
		$Response = Invoke-PreparationGitHubRequest -Method GET -Path "repos/$Repository/git/blobs/$($Entry.sha)" -Body $null -Transport $Transport
		try {
			$Blob = $Response.data
			if ($Blob.sha -cne $Entry.sha -or $Blob.encoding -cne 'base64' -or
				($Blob.size -isnot [int] -and $Blob.size -isnot [long]) -or $Blob.size -lt 1 -or $Blob.size -gt 262144 -or
				$Blob.content -isnot [string] -or $Blob.content.Length -gt 524288) { throw 'workflow_source_invalid' }
			$Bytes = [Convert]::FromBase64String($Blob.content)
			$TotalBytes += $Bytes.Length
			if ($Bytes.Length -ne $Blob.size -or $TotalBytes -gt 4194304) { throw 'workflow_source_invalid' }
			# SHA-1 is the Git object identifier, not an evidence security digest.
			$GitHasher = [Security.Cryptography.SHA1]::Create()
			try {
				$Header = [Text.Encoding]::ASCII.GetBytes(('blob ' + $Bytes.Length + [char]0))
				$BlobId = ([BitConverter]::ToString($GitHasher.ComputeHash([byte[]] ($Header + $Bytes)))).Replace('-', '').ToLowerInvariant()
			} finally { $GitHasher.Dispose() }
			if ($BlobId -cne $Entry.sha) { throw 'workflow_source_invalid' }
			$Hasher = [Security.Cryptography.SHA256]::Create()
			try { $Digest = ([BitConverter]::ToString($Hasher.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant() }
			finally { $Hasher.Dispose() }
			$Decoder = New-Object Text.UTF8Encoding $false, $true
			$Yaml = $Decoder.GetString($Bytes)
		} catch { throw 'workflow_source_invalid' }
		$Routes = Get-PreparationWorkflowRoute -Yaml $Yaml -RunnerLabels $RunnerLabels -YamlAssemblyPath $YamlAssemblyPath
		[void] $Sources.Add([pscustomobject]@{ revision = $Revision; path = ('.github/workflows/' + $Entry.path); blobId = $BlobId; sha256 = $Digest; bytes = $Bytes.Length; routes = $Routes })
	}
	return ,@($Sources)
}

function Initialize-PreparationYaml {
	[CmdletBinding()]
	param([Parameter(Mandatory)][string] $AssemblyPath)
	# YamlDotNet net47 bytes distributed with powershell-yaml 0.4.12 from PSGallery.
	# No automatic download or module-path search runs inside privileged admission.
	$ExpectedHash = 'd35c770d92632bd94bba4203db05eee5ebce6e6ea6d92e7ebe8997a942b5321c'
	if ([IO.Path]::GetFileName($AssemblyPath) -cne 'YamlDotNet.dll' -or -not [IO.Path]::IsPathRooted($AssemblyPath)) { throw 'yaml_dependency_invalid' }
	Assert-InitialPreparationPlainPath -Path $AssemblyPath -Reason 'yaml_dependency_invalid'
	if ((Get-Item -LiteralPath $AssemblyPath).Length -ne 288256 -or
		(Get-FileHash -Algorithm SHA256 -LiteralPath $AssemblyPath).Hash.ToLowerInvariant() -cne $ExpectedHash) { throw 'yaml_dependency_invalid' }
	$Loaded = 'YamlDotNet.Core.Parser' -as [type]
	if ($null -eq $Loaded) { Add-Type -Path $AssemblyPath -ErrorAction Stop }
	elseif ((Get-FileHash -Algorithm SHA256 -LiteralPath $Loaded.Assembly.Location).Hash.ToLowerInvariant() -cne $ExpectedHash) { throw 'yaml_dependency_invalid' }
}

function Get-PreparationYamlValue {
	param($Mapping, [string] $Name)
	if ($Mapping -isnot [YamlDotNet.RepresentationModel.YamlMappingNode]) { throw 'workflow_yaml_invalid' }
	foreach ($Pair in $Mapping.Children.GetEnumerator()) {
		if ($Pair.Key -isnot [YamlDotNet.RepresentationModel.YamlScalarNode]) { throw 'workflow_yaml_invalid' }
		if ($Pair.Key.Value -ceq $Name) { return ,$Pair.Value }
	}
	return $null
}

function Get-PreparationWorkflowRoute {
	[CmdletBinding()]
	[OutputType([object[]])]
	param([Parameter(Mandatory)][string] $Yaml,
		[Parameter(Mandatory)][string[]] $RunnerLabels,
		[Parameter(Mandatory)][string] $YamlAssemblyPath)
	Initialize-PreparationYaml -AssemblyPath $YamlAssemblyPath
	if ([Text.Encoding]::UTF8.GetByteCount($Yaml) -gt 262144) { throw 'workflow_yaml_invalid' }
	try {
		$Reader = New-Object IO.StringReader $Yaml
		try {
			$Parser = New-Object YamlDotNet.Core.Parser $Reader
			$Depth = 0
			$Events = 0
			while ($Parser.MoveNext()) {
				$YamlEvent = $Parser.Current
				$Events++
				$Depth += $YamlEvent.NestingIncrease
				if ($Events -gt 10000 -or $Depth -gt 32 -or $YamlEvent -is [YamlDotNet.Core.Events.AnchorAlias]) { throw 'workflow_yaml_invalid' }
				if ($YamlEvent -is [YamlDotNet.Core.Events.NodeEvent] -and (-not $YamlEvent.Anchor.IsEmpty -or -not $YamlEvent.Tag.IsEmpty)) { throw 'workflow_yaml_invalid' }
			}
		} finally { $Reader.Dispose() }
		$Reader = New-Object IO.StringReader $Yaml
		try {
			$Stream = New-Object YamlDotNet.RepresentationModel.YamlStream
			$Stream.Load($Reader)
		} finally { $Reader.Dispose() }
		if ($Stream.Documents.Count -ne 1) { throw 'workflow_yaml_invalid' }
		$JobsNode = Get-PreparationYamlValue -Mapping $Stream.Documents[0].RootNode -Name jobs
		if ($JobsNode -isnot [YamlDotNet.RepresentationModel.YamlMappingNode] -or $JobsNode.Children.Count -lt 1 -or $JobsNode.Children.Count -gt 100) { throw 'workflow_yaml_invalid' }
	} catch { throw [InvalidOperationException]::new('workflow_yaml_invalid', $_.Exception) }
	$Routes = New-Object Collections.ArrayList
	foreach ($JobPair in $JobsNode.Children.GetEnumerator()) {
		if ($JobPair.Key -isnot [YamlDotNet.RepresentationModel.YamlScalarNode] -or $JobPair.Key.Value -cnotmatch '^[A-Za-z_][A-Za-z0-9_-]*$') { throw 'workflow_yaml_invalid' }
		if ($null -ne (Get-PreparationYamlValue -Mapping $JobPair.Value -Name uses)) { throw 'routing_dynamic_unresolved' }
		$RunsOn = Get-PreparationYamlValue -Mapping $JobPair.Value -Name 'runs-on'
		if ($RunsOn -is [YamlDotNet.RepresentationModel.YamlScalarNode]) { $LabelNodes = @($RunsOn) }
		elseif ($RunsOn -is [YamlDotNet.RepresentationModel.YamlSequenceNode]) { $LabelNodes = @($RunsOn.Children) }
		else { throw 'routing_dynamic_unresolved' }
		$Labels = @()
		foreach ($LabelNode in $LabelNodes) {
			if ($LabelNode -isnot [YamlDotNet.RepresentationModel.YamlScalarNode] -or
				[string]::IsNullOrWhiteSpace($LabelNode.Value) -or $LabelNode.Value.Contains('${{')) { throw 'routing_dynamic_unresolved' }
			$Labels += $LabelNode.Value
		}
		if ($Labels.Count -lt 1) { throw 'routing_dynamic_unresolved' }
		$Eligible = $true
		foreach ($Label in $Labels) { if ($RunnerLabels -notcontains $Label) { $Eligible = $false } }
		if ($Eligible -and $Labels -notcontains 'aetheln-engine') { throw 'eligible_route_bypasses_label' }
		[void] $Routes.Add([pscustomobject]@{ jobId = $JobPair.Key.Value; labels = $Labels; eligible = $Eligible })
	}
	return ,@($Routes)
}
