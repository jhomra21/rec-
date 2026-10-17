# Shared helpers for the Windows E2E scripts.

function Find-CMake {
    $onPath = Get-Command cmake -ErrorAction SilentlyContinue
    if ($onPath) { return $onPath.Source }
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (Test-Path $vswhere) {
        foreach ($vs in & $vswhere -products * -property installationPath) {
            $bundled = Join-Path $vs 'Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe'
            if (Test-Path $bundled) { return $bundled }
        }
    }
    throw 'cmake not found: install Visual Studio Build Tools with the C++ workload'
}

function Build-Rec([string]$source, [string]$build) {
    $cmake = Find-CMake
    # Out-Host keeps build output out of the function's return value.
    & $cmake -S $source -B $build | Out-Host
    if ($LASTEXITCODE -ne 0) { throw 'cmake configure failed' }
    & $cmake --build $build --config Release --parallel | Out-Host
    if ($LASTEXITCODE -ne 0) { throw 'build failed' }
    foreach ($candidate in @((Join-Path $build 'Release\rec.exe'), (Join-Path $build 'rec.exe'))) {
        if (Test-Path $candidate) { return $candidate }
    }
    throw "rec.exe not found under $build"
}

# Runs rec and returns its exit code and combined output. Windows PowerShell turns native
# stderr into error records, so the caller's error preference must not apply here.
function Invoke-Rec([string]$rec, [string[]]$arguments) {
    $ErrorActionPreference = 'Continue'
    $lines = & $rec @arguments 2>&1 | ForEach-Object { "$_" }
    return @{ Code = $LASTEXITCODE; Text = ($lines -join "`n") }
}

function Get-Probe([string]$rec, [string]$movie, [string]$report) {
    $run = Invoke-Rec $rec @('probe', $movie)
    Set-Content -Path $report -Value $run.Text
    Write-Host ($run.Text -replace "`n", ' ')
    if ($run.Code -ne 0) { throw "rec probe $movie failed: $($run.Text)" }
    $fields = @{}
    foreach ($line in $run.Text -split "`n") {
        $pair = $line.Split('=', 2)
        if ($pair.Count -eq 2) { $fields[$pair[0].Trim()] = $pair[1].Trim() }
    }
    return $fields
}

function Expect-Field($probe, [string]$key, [string]$expected) {
    if ($probe[$key] -ne $expected) { throw "$key=$($probe[$key]), expected $expected" }
}

function Expect-Within($probe, [string]$key, [double]$low, [double]$high) {
    $value = $probe[$key]
    if (-not $value) { throw "$key is missing" }
    $number = [double]::Parse($value, [Globalization.CultureInfo]::InvariantCulture)
    if ($number -lt $low -or $number -gt $high) { throw "$key=$value is outside [$low, $high]" }
}

function Expect-Text([string]$text, [string]$expected) {
    if (-not $text.Contains($expected)) { throw "expected '$expected' in: $text" }
}

# Starts rec with a writable stdin, for pause/resume/stop commands. Read the result with
# Stop-RecProcess.
function Start-RecProcess([string]$rec, [string[]]$arguments) {
    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = $rec
    $info.Arguments = ($arguments | ForEach-Object { if ($_ -match '\s') { "`"$_`"" } else { $_ } }) -join ' '
    $info.UseShellExecute = $false
    $info.RedirectStandardInput = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $process = [System.Diagnostics.Process]::Start($info)
    # Read both pipes asynchronously so a full pipe can never stall the recorder.
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    return @{ Process = $process; Stdout = $stdout; Stderr = $stderr }
}

function Send-RecCommand($run, [string]$command) {
    $run.Process.StandardInput.WriteLine($command)
    $run.Process.StandardInput.Flush()
}

function Stop-RecProcess($run, [int]$timeoutSeconds = 60) {
    if (-not $run.Process.WaitForExit($timeoutSeconds * 1000)) { $run.Process.Kill(); throw 'rec did not exit' }
    $run.Process.WaitForExit()
    return @{ Code = $run.Process.ExitCode; Text = ($run.Stdout.Result + $run.Stderr.Result).Trim() }
}
