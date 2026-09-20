# Definitions only. The enclosing compile supervisor owns descendant cleanup.
function Initialize-RoutineCompileCommandType {
	if ('Aetheln.RoutineCommandCapture' -as [type]) { return }
	Add-Type -TypeDefinition @'
using System;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
namespace Aetheln {
    public sealed class RoutineCommandCapture : IDisposable {
        public const long OutputLimit = 16L * 1024 * 1024;
        private long total;
        private int overflow;
        private int stopped;
        private bool started;
        private Process process;
        private Task<string> stdout;
        private Task<string> stderr;
        public bool Overflow { get { return Volatile.Read(ref overflow) != 0; } }
        public bool StreamsComplete { get { return stdout.IsCompleted && stderr.IsCompleted; } }
        public bool StreamFailed { get { return stdout.IsFaulted || stdout.IsCanceled || stderr.IsFaulted || stderr.IsCanceled; } }
        public bool Exited { get { return process.HasExited; } }
        public int ExitCode { get { return process.ExitCode; } }
        public string Stdout { get { return stdout.Result; } }
        public string Stderr { get { return stderr.Result; } }
        public static string Quote(string argument) {
            var result = new StringBuilder("\"");
            int slashes = 0;
            foreach(char value in argument) {
                if(value == '\\') { slashes++; continue; }
                if(value == '"') { result.Append('\\', slashes * 2 + 1); result.Append(value); }
                else { result.Append('\\', slashes); result.Append(value); }
                slashes = 0;
            }
            result.Append('\\', slashes * 2);
            result.Append('"');
            return result.ToString();
        }
        public void Start(string executable, string arguments, string directory) {
            process = new Process();
            process.StartInfo = new ProcessStartInfo(executable, arguments) {
                UseShellExecute = false, CreateNoWindow = true,
                WindowStyle = ProcessWindowStyle.Hidden,
                WorkingDirectory = directory,
                RedirectStandardOutput = true, RedirectStandardError = true,
                StandardOutputEncoding = new UTF8Encoding(false), StandardErrorEncoding = new UTF8Encoding(false)
            };
            if(!process.Start()) throw new InvalidOperationException("routine_command_start_failed");
            started = true;
            stdout = Pump(process.StandardOutput.BaseStream);
            stderr = Pump(process.StandardError.BaseStream);
        }
        private async Task<string> Pump(Stream input) {
            using(var output = new MemoryStream()) {
                byte[] buffer = new byte[8192];
                while(Volatile.Read(ref stopped) == 0) {
                    int count = await input.ReadAsync(buffer, 0, buffer.Length).ConfigureAwait(false);
                    if(count == 0) break;
                    if(Interlocked.Add(ref total, count) > OutputLimit) {
                        Interlocked.Exchange(ref overflow, 1);
                        return String.Empty;
                    }
                    output.Write(buffer, 0, count);
                }
                return Encoding.UTF8.GetString(output.GetBuffer(), 0, checked((int)output.Length));
            }
        }
        public void Dispose() {
            Interlocked.Exchange(ref stopped, 1);
            if(process == null) return;
            // Kill only our retained direct process handle. The outer Job Object
            // must independently terminate and verify any descendants.
            try {
                if(started && !process.HasExited) {
                    process.Kill();
                    if(!process.WaitForExit(2000)) throw new InvalidOperationException("routine_command_cleanup_failed");
                }
            } catch(InvalidOperationException) {
                // Kill races with natural exit. Suppress only that benign case;
                // never return while the direct child is still running.
                if(started && !process.HasExited) throw;
            }
            finally {
                try { if(stdout != null) process.StandardOutput.Close(); }
                finally {
                    try { if(stderr != null) process.StandardError.Close(); }
                    finally { process.Dispose(); }
                }
            }
        }
    }
}
'@
}

function Invoke-RoutineCompileCommand {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)][string] $Executable,
		[Parameter(Mandatory = $true)][AllowEmptyCollection()][AllowEmptyString()][string[]] $Arguments,
		[Parameter(Mandatory = $true)][string] $WorkingDirectory,
		[Parameter(Mandatory = $true)][scriptblock] $OnProgress
	)
	$null = & $OnProgress
	try { Initialize-RoutineCompileCommandType } catch { throw 'routine_command_initialization_failed' }
	if (-not [IO.Path]::IsPathRooted($Executable) -or -not [IO.File]::Exists($Executable) -or
		-not [IO.Path]::IsPathRooted($WorkingDirectory) -or -not [IO.Directory]::Exists($WorkingDirectory)) {
		throw 'routine_command_start_failed'
	}
	foreach ($Argument in $Arguments) {
		if ($null -eq $Argument -or $Argument.IndexOf([char]0) -ge 0) { throw 'routine_command_arguments_invalid' }
	}
	$ActualExecutable = $Executable
	$Extension = [IO.Path]::GetExtension($Executable).ToLowerInvariant()
	if ($Extension -eq '.exe') {
		$CommandLine = (@($Arguments | ForEach-Object { [Aetheln.RoutineCommandCapture]::Quote($_) }) -join ' ')
	} elseif ($Extension -eq '.ps1') {
		# PowerShell script invocation uses language literals, not native argv
		# interpolation. EncodedCommand also preserves Unicode on Windows 5.1.
		# The script argument contract is positional strings and -Name value
		# scalar pairs, not PowerShell source syntax. Array splatting alone does
		# NOT bind dash-prefixed strings as parameter names. Named values are
		# always consumed literally (including values beginning with a dash).
		# Switch-only, colon/expression syntax and duplicate names fail closed.
		$LiteralExecutable = "'" + $Executable.Replace("'", "''") + "'"
		$NamedArguments = @{}
		$NamedLiterals = [Collections.Generic.List[string]]::new()
		$PositionalLiterals = [Collections.Generic.List[string]]::new()
		for ($ArgumentIndex = 0; $ArgumentIndex -lt $Arguments.Count; $ArgumentIndex++) {
			$ScriptArgument = $Arguments[$ArgumentIndex]
			if ($ScriptArgument -match '\A-([A-Za-z][A-Za-z0-9_]*)\z') {
				$ParameterName = $Matches[1]
				if ($NamedArguments.ContainsKey($ParameterName) -or $ArgumentIndex + 1 -ge $Arguments.Count) { throw 'routine_command_arguments_invalid' }
				$ArgumentIndex++
				$NamedArguments[$ParameterName] = $true
				$NamedLiterals.Add("'" + $ParameterName + "'='" + $Arguments[$ArgumentIndex].Replace("'", "''") + "'")
			} else {
				if ($ScriptArgument -match '\A-[A-Za-z?]') { throw 'routine_command_arguments_invalid' }
				$PositionalLiterals.Add("'" + $ScriptArgument.Replace("'", "''") + "'")
			}
		}
		$Driver = '[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false); $ErrorActionPreference = ''Stop''; $LASTEXITCODE = 0; try { $NamedArguments = @{' + ($NamedLiterals -join ';') + '}; $CommandArguments = @(' + ($PositionalLiterals -join ',') + '); & ' + $LiteralExecutable + ' @NamedArguments @CommandArguments; $Succeeded = $?; if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }; if (-not $Succeeded) { exit 1 }; exit 0 } catch { [Console]::Error.WriteLine(''routine_command_script_failed''); exit 1 }'
		$ActualExecutable = Join-Path ([Environment]::GetFolderPath('System')) 'WindowsPowerShell/v1.0/powershell.exe'
		$CommandLine = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand ' + [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Driver))
	} elseif ($Extension -eq '.bat' -or $Extension -eq '.cmd') {
		# cmd.exe has shell expansion unlike executable argv. Reject ambiguous
		# values instead of silently changing arguments or allowing injection.
		foreach ($Value in @($Executable) + $Arguments) {
			if ($Value -match '["%!' + [char]0 + '\r\n&|<>^]') { throw 'routine_command_arguments_invalid' }
		}
		$BatchArguments = (@($Arguments | ForEach-Object { '"' + $_ + '"' }) -join ' ')
		$ActualExecutable = Join-Path ([Environment]::GetFolderPath('System')) 'cmd.exe'
		$CommandLine = '/d /s /v:off /c ""' + $Executable + '" ' + $BatchArguments + '"'
	} else { throw 'routine_command_executable_invalid' }
	$Capture = [Aetheln.RoutineCommandCapture]::new()
	try {
		$null = & $OnProgress
		try { $Capture.Start($ActualExecutable, $CommandLine, $WorkingDirectory) } catch { throw 'routine_command_start_failed' }
		while ($true) {
			$null = & $OnProgress
			if ($Capture.Overflow) { throw 'routine_command_output_limit' }
			if ($Capture.StreamFailed) { throw 'routine_command_capture_failed' }
			if ($Capture.Exited -and $Capture.StreamsComplete) { break }
			Start-Sleep -Milliseconds 50
		}
		$null = & $OnProgress
		$Lines = [Collections.Generic.List[string]]::new()
		foreach ($CapturedText in @($Capture.Stdout, $Capture.Stderr)) {
			if ($CapturedText.Length -eq 0) { continue }
			# Bound record overhead too: a newline flood must not allocate millions
			# of strings despite fitting inside the 16 MiB byte ceiling.
			$Reader = [IO.StringReader]::new($CapturedText)
			try {
				while ($null -ne ($Line = $Reader.ReadLine())) {
					if ($Lines.Count -ge 65536) { throw 'routine_command_output_limit' }
					$Lines.Add($Line)
					if (($Lines.Count % 256) -eq 0) { $null = & $OnProgress }
				}
			} finally { $Reader.Dispose() }
		}
		$null = & $OnProgress
		return [pscustomobject][ordered]@{ exitCode = [int] $Capture.ExitCode; output = [string[]] $Lines.ToArray() }
	} finally {
		try { $Capture.Dispose() } catch { throw 'routine_command_dispose_failed' }
	}
}
