$ErrorActionPreference = 'Stop'

$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$tempRoot = [System.IO.Path]::GetFullPath($env:TEMP)

Push-Location $projectRoot
try {
    $env:PYTHONPATH = Join-Path $projectRoot 'src'
    & py -3.12 -m jarvis_assistant.smoke --temp-root $tempRoot --live
    if ($LASTEXITCODE -ne 0) {
        throw "Jarvis smoke test failed with exit code $LASTEXITCODE"
    }
}
finally {
    Pop-Location
}
