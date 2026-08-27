param(
    [string]$Executable = ".\dist\JarvisDesktopAssistant.exe"
)

$ErrorActionPreference = "Stop"
$source = (Resolve-Path -LiteralPath $Executable).Path
$safeTemp = Join-Path ([Environment]::GetFolderPath("LocalApplicationData")) "Temp"
$probeRoot = Join-Path $safeTemp ("jarvis-standalone-" + [guid]::NewGuid().ToString("N"))
$probeExe = Join-Path $probeRoot "JarvisDesktopAssistant.exe"
$process = $null

try {
    New-Item -ItemType Directory -Path $probeRoot | Out-Null
    Copy-Item -LiteralPath $source -Destination $probeExe
    $process = Start-Process -FilePath $probeExe -WorkingDirectory $probeRoot -PassThru
    Start-Sleep -Seconds 5
    $running = Get-Process -Id $process.Id -ErrorAction SilentlyContinue
    if (-not $running) {
        throw "Standalone executable exited during startup with code $($process.ExitCode)."
    }
    $running.Refresh()
    if ($running.MainWindowTitle -eq "Error") {
        throw "Standalone executable opened the PyInstaller error dialog."
    }
    Write-Output "STANDALONE STARTUP PASSED"
}
finally {
    if ($process) {
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $probeRoot) {
        $resolvedProbe = (Resolve-Path -LiteralPath $probeRoot).Path
        if (-not $resolvedProbe.StartsWith($safeTemp + [IO.Path]::DirectorySeparatorChar)) {
            throw "Refusing to remove a probe directory outside the system temp directory."
        }
        $deadline = [DateTime]::UtcNow.AddSeconds(5)
        do {
            $probeProcesses = Get-Process -Name "JarvisDesktopAssistant" -ErrorAction SilentlyContinue |
                Where-Object {
                    $_.Path -and $_.Path.StartsWith(
                        $resolvedProbe + [IO.Path]::DirectorySeparatorChar,
                        [System.StringComparison]::OrdinalIgnoreCase
                    )
                }
            $probeProcesses | Stop-Process -Force -ErrorAction SilentlyContinue
            if (-not $probeProcesses) { break }
            Start-Sleep -Milliseconds 200
        } while ([DateTime]::UtcNow -lt $deadline)
        Remove-Item -LiteralPath $resolvedProbe -Recurse -Force
    }
}
