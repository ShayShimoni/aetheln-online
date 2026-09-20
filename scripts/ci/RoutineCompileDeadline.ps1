# The workflow captures both anchors before checkout on this same Windows host.
# UTC is evidence only. No operation, child, or wall-clock adjustment starts a
# new useful-work window; every observation charges the original QPC anchor.
if (-not ('Aetheln.RoutineCompileDeadline' -as [type])) {
	Add-Type -TypeDefinition @'
using System;
namespace Aetheln {
    public sealed class RoutineCompileDeadline {
        public DateTime StartedUtc { get; private set; }
        public long StartedTimestamp { get; private set; }
        public long TimestampFrequency { get; private set; }
        public double TimeoutMinutes { get; private set; }
        private long lastTimestamp;
        private readonly object sync = new object();
        public RoutineCompileDeadline(DateTime utc, long timestamp, long frequency, double minutes) {
            if (utc.Kind != DateTimeKind.Utc || timestamp <= 0 || frequency <= 0 ||
                Double.IsNaN(minutes) || Double.IsInfinity(minutes) || minutes <= 0 || minutes > 30)
                throw new InvalidOperationException("compile_deadline_invalid");
            StartedUtc = utc; StartedTimestamp = timestamp;
            TimestampFrequency = frequency; TimeoutMinutes = minutes;
            lastTimestamp = timestamp;
        }
        public long Observe(long timestamp, int graceMilliseconds) {
            lock (sync) {
                if (graceMilliseconds < 0 || graceMilliseconds > 2000) throw new InvalidOperationException("compile_deadline_invalid");
                if (timestamp < lastTimestamp || timestamp < StartedTimestamp)
                    throw new InvalidOperationException("compile_clock_invalid");
                lastTimestamp = timestamp;
                decimal elapsed = ((decimal)timestamp - StartedTimestamp) * 1000 / TimestampFrequency;
                decimal remaining = (decimal)TimeoutMinutes * 60000 + graceMilliseconds - elapsed;
                if (remaining <= 0) throw new InvalidOperationException("compile_timeout");
                return (long)Decimal.Ceiling(remaining);
            }
        }
    }
}
'@
}
if ($null -eq (Get-Variable -Name RoutineCompileDeadlineReaders -Scope Script -ErrorAction SilentlyContinue)) {
	$script:RoutineCompileDeadlineReaders = New-Object 'System.Runtime.CompilerServices.ConditionalWeakTable[System.Object,System.Object]'
}

function New-RoutineCompileDeadline {
	[CmdletBinding(SupportsShouldProcess)]
	[OutputType([object])]
	param(
		[AllowEmptyString()][string] $StartedUtc,
		[long] $StartedTimestamp,
		[double] $TimeoutMinutes,
		[scriptblock] $ReadTimestamp = { [Diagnostics.Stopwatch]::GetTimestamp() },
		[scriptblock] $ReadUtcNow = { [DateTime]::UtcNow },
		[long] $TimestampFrequency = [Diagnostics.Stopwatch]::Frequency
	)
	if ([double]::IsNaN($TimeoutMinutes) -or [double]::IsInfinity($TimeoutMinutes) -or $TimeoutMinutes -le 0 -or $TimeoutMinutes -gt 30) { throw 'compile_timeout_invalid' }
	$ParsedUtc = [DateTime]::MinValue
	if ($StartedUtc -cnotmatch '\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{7}Z\z' -or
		-not [DateTime]::TryParseExact($StartedUtc, 'o', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref] $ParsedUtc) -or $ParsedUtc.Kind -ne [DateTimeKind]::Utc) { throw 'compile_deadline_invalid' }
	if ($StartedTimestamp -le 0 -or $TimestampFrequency -le 0 -or $null -eq $ReadTimestamp -or $null -eq $ReadUtcNow) { throw 'compile_clock_invalid' }
	if (-not $PSCmdlet.ShouldProcess('immutable routine compile deadline', 'Create')) { return }
	$Deadline = [Aetheln.RoutineCompileDeadline]::new($ParsedUtc, $StartedTimestamp, $TimestampFrequency, $TimeoutMinutes)
	$Readers = @{ Timestamp = $ReadTimestamp; Utc = $ReadUtcNow }
	$script:RoutineCompileDeadlineReaders.Add($Deadline, $Readers)
	[void] (Get-RoutineCompileRemainingMillisecondCount -Deadline $Deadline)
	return $Deadline
}

function Get-RoutineCompileRemainingMillisecondCount {
	[CmdletBinding()]
	[OutputType([long])]
	param([Parameter(Mandatory)] $Deadline, [int] $GraceMilliseconds = 0)
	$Readers = $null
	if ($Deadline -isnot [Aetheln.RoutineCompileDeadline] -or -not $script:RoutineCompileDeadlineReaders.TryGetValue($Deadline, [ref] $Readers) -or $GraceMilliseconds -lt 0 -or $GraceMilliseconds -gt 2000) { throw 'compile_deadline_invalid' }
	try { $Tick = & $Readers.Timestamp } catch { throw 'compile_clock_invalid' }
	if ($Tick -isnot [long] -and $Tick -isnot [int]) { throw 'compile_clock_invalid' }
	try { return $Deadline.Observe([long] $Tick, $GraceMilliseconds) }
	catch {
		$Cause = $_.Exception.InnerException
		if ($null -ne $Cause -and $Cause.Message -cin @('compile_timeout', 'compile_clock_invalid', 'compile_deadline_invalid')) { throw $Cause.Message }
		throw 'compile_clock_invalid'
	}
}

function Get-RoutineCompileDeadlineUtc {
	[CmdletBinding()]
	[OutputType([DateTime])]
	param([Parameter(Mandatory)] $Deadline, [int] $GraceMilliseconds = 0)
	$Readers = $null
	if ($Deadline -isnot [Aetheln.RoutineCompileDeadline] -or -not $script:RoutineCompileDeadlineReaders.TryGetValue($Deadline, [ref] $Readers)) { throw 'compile_deadline_invalid' }
	try { $Now = & $Readers.Utc } catch { throw 'compile_clock_invalid' }
	if ($Now -isnot [DateTime] -or $Now.Kind -ne [DateTimeKind]::Utc) { throw 'compile_clock_invalid' }
	$Remaining = Get-RoutineCompileRemainingMillisecondCount -Deadline $Deadline -GraceMilliseconds $GraceMilliseconds
	try { return $Now.AddMilliseconds($Remaining) } catch { throw 'compile_clock_invalid' }
}
