[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$RepositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $PSScriptRoot 'PinnedPreparationYaml.ps1')
$PinnedYaml = Get-PinnedPreparationYaml
Write-Output "Pinned preparation YAML archive=$($PinnedYaml.PackageSha256) assembly=$($PinnedYaml.AssemblySha256)"

# Separate File invocations preserve the preparation test's timing and assembly
# isolation. The existing suite owns these descendants through its CheckJob.
foreach ($Fixture in @(
	@{ Name = 'Test-RunnerSchedulingPolicy.Tests.ps1'; Arguments = '' },
	@{ Name = 'PinnedPreparationYaml.Tests.ps1'; Arguments = (' -PackagePath "' + $PinnedYaml.PackagePath + '"') },
	@{ Name = 'InitialPreparation.GitHub.Tests.ps1'; Arguments = (' -YamlAssemblyPath "' + $PinnedYaml.AssemblyPath + '"') }
)) {
	$FixturePath = Join-Path $PSScriptRoot $Fixture.Name
	$StartInfo = [Diagnostics.ProcessStartInfo]::new()
	$StartInfo.FileName = Join-Path $PSHOME 'powershell.exe'
	$StartInfo.Arguments = '-NoProfile -File "' + $FixturePath + '"' + $Fixture.Arguments
	$StartInfo.WorkingDirectory = $RepositoryRoot
	$StartInfo.UseShellExecute = $false
	$StartInfo.CreateNoWindow = $true
	$StartInfo.RedirectStandardOutput = $true
	$StartInfo.RedirectStandardError = $true
	$Child = [Diagnostics.Process]::new()
	$Child.StartInfo = $StartInfo
	try {
		if (-not $Child.Start()) { throw 'preparation_fixture_launch_failed' }
		$StandardOutput = $Child.StandardOutput.ReadToEndAsync()
		$StandardError = $Child.StandardError.ReadToEndAsync()
		if (-not $Child.WaitForExit(300000)) {
			$Child.Kill()
			[void] $Child.WaitForExit(5000)
			throw 'preparation_fixture_timeout'
		}
		$ExitCode = $Child.ExitCode
		# A descendant holding an output pipe must not make reporting wait forever.
		if (-not $StandardOutput.Wait(5000) -or -not $StandardError.Wait(5000)) { throw 'preparation_fixture_output_timeout' }
		[Console]::Out.Write($StandardOutput.GetAwaiter().GetResult())
		[Console]::Error.Write($StandardError.GetAwaiter().GetResult())
		if ($ExitCode -ne 0) { exit $ExitCode }
	} finally { $Child.Dispose() }
}
Write-Output 'PASS: scheduling policy and pinned preparation GitHub fixtures'
