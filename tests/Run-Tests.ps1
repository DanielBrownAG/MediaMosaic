#requires -Version 5.1
<# Dependency-free regression suite. FFmpeg tests require ffmpeg on PATH. #>
[CmdletBinding()]
param([switch]$RequireFFmpeg)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Add-Type -AssemblyName System.Drawing
$repo = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $repo 'MediaMosaic.psm1') -Force
$module = Get-Module MediaMosaic
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('MediaMosaic-tests-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($testRoot) | Out-Null
$script:passed = 0
$script:failed = 0

function Assert-True($Condition, [string]$Message) {
    if (-not $Condition) { throw "Assertion failed: $Message" }
}
function Assert-Throws([scriptblock]$Action, [string]$Pattern = '.') {
    $caught = $null
    try { & $Action | Out-Null } catch { $caught = $_ }
    Assert-True ($null -ne $caught) 'Expected an exception'
    Assert-True ($caught.Exception.Message -match $Pattern) "Unexpected error: $caught"
}
function Test-Case([string]$Name, [scriptblock]$Action) {
    try { & $Action; $script:passed++; Write-Host "PASS $Name" }
    catch { $script:failed++; Write-Host "FAIL $Name`n$_`n$($_.ScriptStackTrace)" -ForegroundColor Red }
}
function New-TestFolder([string]$Name) {
    $path = Join-Path $testRoot $Name
    [IO.Directory]::CreateDirectory($path) | Out-Null
    return $path
}
function New-TestImage([string]$Path, [int]$Width = 40, [int]$Height = 20) {
    $bitmap = [Drawing.Bitmap]::new($Width, $Height)
    $graphics = $null
    try {
        $graphics = [Drawing.Graphics]::FromImage($bitmap)
        $graphics.Clear([Drawing.Color]::CornflowerBlue)
        $bitmap.Save($Path, [Drawing.Imaging.ImageFormat]::Jpeg)
    }
    finally { if ($graphics) { $graphics.Dispose() }; $bitmap.Dispose() }
}
function Assert-Unlocked([string]$Path) {
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    $stream.Dispose()
}
function Invoke-TestMosaic([string]$InputPath, [string]$OutputPath, [hashtable]$Options = @{}) {
    Invoke-MediaMosaic -RootFolder $InputPath -OutputFile $OutputPath @Options
}
function New-FFmpegFixture([string[]]$Arguments) {
    $messages = & $script:ffmpeg.Source -hide_banner -loglevel error @Arguments 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { throw "Fixture creation failed: $messages" }
}

try {
    Test-Case 'JPEG renders, nested output is created, and resources are released' {
        $inputPath = New-TestFolder 'basic'
        $source = Join-Path $inputPath 'photo.jpg'; New-TestImage $source
        $result = Invoke-TestMosaic $inputPath (Join-Path $testRoot 'new\nested\sheet.jpg')
        Assert-True ($result.Discovered -eq 1 -and $result.Rendered -eq 1 -and $result.Failed -eq 0) 'Accurate summary'
        Assert-True ($result.Sheets.Count -eq 1) 'One sheet'
        $image = [Drawing.Image]::FromFile($result.Sheets[0])
        try { Assert-True ($image.Width -eq 1120 -and $image.Height -eq 300) 'Canvas contains exactly one row' }
        finally { $image.Dispose() }
        Assert-Unlocked $source; Assert-Unlocked $result.Sheets[0]
    }
    Test-Case 'brackets, spaces, apostrophes and Unicode use literal paths' {
        $inputPath = New-TestFolder "photos[2026] O'Brien $([char]0x03A9)"
        New-TestImage (Join-Path $inputPath 'photo[1].jpg')
        $result = Invoke-TestMosaic $inputPath (Join-Path $inputPath 'out[1].jpg')
        Assert-True ($result.Rendered -eq 1) 'Literal source/output names work'
    }
    Test-Case 'native image formats render while unrelated extensions are ignored' {
        $inputPath = New-TestFolder 'native-formats'
        $bitmap = [Drawing.Bitmap]::new(40, 20)
        try {
            $bitmap.Save((Join-Path $inputPath 'image.png'), [Drawing.Imaging.ImageFormat]::Png)
            $bitmap.Save((Join-Path $inputPath 'image.gif'), [Drawing.Imaging.ImageFormat]::Gif)
            $bitmap.Save((Join-Path $inputPath 'image.bmp'), [Drawing.Imaging.ImageFormat]::Bmp)
            $bitmap.Save((Join-Path $inputPath 'image.jpeg'), [Drawing.Imaging.ImageFormat]::Jpeg)
        }
        finally { $bitmap.Dispose() }
        Set-Content -LiteralPath (Join-Path $inputPath 'ignored.jpg.backup') -Value 'text'
        $result = Invoke-TestMosaic $inputPath (Join-Path $inputPath 'sheet.jpg')
        Assert-True ($result.Discovered -eq 4 -and $result.Rendered -eq 4) 'All native formats render'
    }
    Test-Case 'relative output filenames resolve against the current filesystem location' {
        $inputPath = New-TestFolder 'relative'
        New-TestImage (Join-Path $inputPath 'photo.jpg')
        Push-Location -LiteralPath $inputPath
        try {
            $result = Invoke-MediaMosaic -RootFolder '.' -OutputFile 'sheet.jpeg'
            Assert-True ($result.Rendered -eq 1 -and (Test-Path -LiteralPath $result.Sheets[0])) 'Relative output succeeds'
        }
        finally { Pop-Location }
    }
    Test-Case 'corrupt files retain cells and report the underlying error' {
        $inputPath = New-TestFolder 'corrupt'
        New-TestImage (Join-Path $inputPath 'valid.jpg')
        Set-Content -LiteralPath (Join-Path $inputPath 'broken.jpg') -Value 'not an image'
        $warnings = @()
        $result = Invoke-MediaMosaic -RootFolder $inputPath -OutputFile (Join-Path $inputPath 'sheet.jpg') -WarningAction SilentlyContinue -WarningVariable warnings
        $records = @(Import-Csv -LiteralPath $result.IndexPath)
        Assert-True ($result.Rendered -eq 1 -and $result.Failed -eq 1 -and $records.Count -eq 2) 'No silently omitted input'
        Assert-True ($records[0].Status -eq 'Failed' -and $records[0].Error.Length -gt 0) 'Detailed failure in CSV'
        Assert-True ($warnings.Count -eq 1 -and "$($warnings[0])" -match 'broken.jpg') 'Detailed warning'
        Assert-True ($records[0].Cell -eq 1 -and $records[1].Cell -eq 2) 'Stable placeholder positions'
    }
    Test-Case 'entirely failed sheets still have a thumbnail row' {
        $inputPath = New-TestFolder 'all-failed'
        Set-Content -LiteralPath (Join-Path $inputPath 'broken.jpg') -Value 'not an image'
        $result = Invoke-MediaMosaic -RootFolder $inputPath -OutputFile (Join-Path $inputPath 'sheet.jpg') -WarningAction SilentlyContinue
        $image = [Drawing.Image]::FromFile($result.Sheets[0])
        try { Assert-True ($image.Height -eq 300 -and $result.Failed -eq 1) 'Failed input has a visible cell' }
        finally { $image.Dispose() }
    }
    Test-Case 'reruns exclude generated sheets and remove only manifest-owned surplus pages' {
        $inputPath = New-TestFolder 'rerun'
        1..5 | ForEach-Object { New-TestImage (Join-Path $inputPath "$_.jpg") }
        $output = Join-Path $inputPath 'sheet.jpg'
        $first = Invoke-TestMosaic $inputPath $output @{ FilesPerSheet = 2 }
        Assert-True ($first.Sheets.Count -eq 3) 'Three initial pages'
        # A similarly named pre-existing file was never recorded as our output.
        $unowned = Join-Path $inputPath 'sheet-99.jpg'; New-TestImage $unowned
        $second = Invoke-TestMosaic $inputPath $output
        Assert-True ($second.Discovered -eq 5 -and $second.Sheets.Count -eq 1) 'Outputs never become inputs'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $inputPath 'sheet-2.jpg'))) 'Obsolete page two removed'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $inputPath 'sheet-3.jpg'))) 'Obsolete page three removed'
        Assert-True (Test-Path -LiteralPath $unowned) 'Unowned matching filename preserved'
    }
    Test-Case 'empty input returns zero counts and reconciles previous outputs' {
        $inputPath = New-TestFolder 'empty'
        $source = Join-Path $inputPath 'photo.jpg'; New-TestImage $source
        $first = Invoke-TestMosaic $inputPath (Join-Path $inputPath 'sheet.jpg')
        Remove-Item -LiteralPath $source
        $empty = Invoke-TestMosaic $inputPath (Join-Path $inputPath 'sheet.jpg')
        Assert-True ($empty.Discovered -eq 0 -and $empty.Sheets.Count -eq 0) 'Empty summary'
        Assert-True (-not (Test-Path -LiteralPath $first.Sheets[0])) 'Owned stale page removed'
        Assert-True (@(Import-Csv -LiteralPath $empty.IndexPath).Count -eq 0) 'Empty CSV retains its schema'
    }
    Test-Case 'abandoned private staging files never become media inputs' {
        $inputPath = New-TestFolder 'abandoned'
        New-TestImage (Join-Path $inputPath 'photo.jpg')
        $staging = Join-Path $inputPath ('.mediamosaic-' + [guid]::NewGuid().ToString('N'))
        [IO.Directory]::CreateDirectory($staging) | Out-Null
        New-TestImage (Join-Path $staging 'sheet-1.jpg')
        $result = Invoke-TestMosaic $inputPath (Join-Path $inputPath 'sheet.jpg')
        Assert-True ($result.Discovered -eq 1) 'Private staging excluded'
        Assert-True (Test-Path -LiteralPath $staging) 'Abandoned files are not deleted automatically'
    }
    Test-Case 'missing and non-directory roots throw' {
        Assert-Throws { Invoke-TestMosaic (Join-Path $testRoot 'missing') (Join-Path $testRoot 'missing.jpg') }
        $file = Join-Path $testRoot 'file.txt'; Set-Content -LiteralPath $file -Value 'text'
        Assert-Throws { Invoke-TestMosaic $file (Join-Path $testRoot 'file.jpg') } 'directory'
    }
    Test-Case 'invalid numeric options and output extensions are rejected' {
        $inputPath = New-TestFolder 'invalid-options'
        foreach ($option in @('FilesPerSheet', 'Columns', 'ThumbWidth', 'ThumbHeight', 'HeaderHeight', 'TextHeight')) {
            $options = @{}; $options[$option] = 0
            Assert-Throws { Invoke-TestMosaic $inputPath (Join-Path $inputPath 'sheet.jpg') $options }
        }
        Assert-Throws { Invoke-TestMosaic $inputPath (Join-Path $inputPath 'sheet.jpg') @{ Padding = -1 } }
        Assert-Throws { Invoke-TestMosaic $inputPath (Join-Path $inputPath 'sheet.png') } 'extension'
    }
    Test-Case 'relative CSV captions distinguish duplicate filenames and pagination keeps the last file' {
        $inputPath = New-TestFolder 'duplicates'
        foreach ($folder in @('a', 'b', 'c')) {
            $sub = Join-Path $inputPath $folder; [IO.Directory]::CreateDirectory($sub) | Out-Null
            New-TestImage (Join-Path $sub 'photo.jpg')
        }
        $result = Invoke-TestMosaic $inputPath (Join-Path $inputPath 'sheet.jpg') @{ FilesPerSheet = 2 }
        $records = @(Import-Csv -LiteralPath $result.IndexPath)
        Assert-True ($records.Count -eq 3 -and $result.Sheets.Count -eq 2) 'Last singleton page retained'
        Assert-True (($records.RelativePath -join '|') -eq 'a\photo.jpg|b\photo.jpg|c\photo.jpg') 'Deterministic relative names'
        Assert-True ($records[2].Sheet -eq 2 -and $records[2].Cell -eq 1) 'Correct final page mapping'
    }
    Test-Case 'oversized canvas fails without replacing existing output or leaking staging files' {
        $inputPath = New-TestFolder 'oversized'
        New-TestImage (Join-Path $inputPath 'photo.jpg')
        $output = Join-Path $inputPath 'sheet.jpg'
        $first = Invoke-TestMosaic $inputPath $output
        $before = (Get-FileHash -LiteralPath $first.Sheets[0]).Hash
        Assert-Throws { Invoke-TestMosaic $inputPath $output @{ Columns = 1000; ThumbWidth = 10000 } } 'Canvas is too large'
        Assert-True ((Get-FileHash -LiteralPath $first.Sheets[0]).Hash -eq $before) 'Previous sheet preserved'
        Assert-True (@(Get-ChildItem -LiteralPath $inputPath -Directory -Force | Where-Object Name -like '.mediamosaic-*').Count -eq 0) 'No staging directories leaked'
    }
    Test-Case 'manifest cannot delete paths outside its numbered sheet namespace' {
        $inputPath = New-TestFolder 'manifest'
        $protected = Join-Path $inputPath 'keep.jpg'; New-TestImage $protected
        $manifest = Join-Path $inputPath 'sheet.mediamosaic.json'
        foreach ($entry in @('..\keep.jpg', 'keep.jpg', 'sheet-*.jpg', 'sheet-1.jpg\child')) {
            @{ Version = 1; Sheets = @($entry) } | ConvertTo-Json | Set-Content -LiteralPath $manifest
            Assert-Throws { Invoke-TestMosaic $inputPath (Join-Path $inputPath 'sheet.jpg') } 'Invalid sheet name'
            Assert-True (Test-Path -LiteralPath $protected) 'Unrelated input preserved'
        }
    }
    Test-Case 'save failure releases the source image and drawing resources' {
        $inputPath = New-TestFolder 'save-failure'
        $source = Join-Path $inputPath 'photo.jpg'; New-TestImage $source
        Assert-Throws {
            & $module {
                param($Source, $Root, $Destination)
                Write-ContactSheet -Files @(Get-Item -LiteralPath $Source) -Root $Root -Path $Destination -Title 'test' -Sheet 1 -FFmpeg 'ffmpeg' -Columns 1 -ThumbWidth 40 -ThumbHeight 20 -HeaderHeight 60 -TextHeight 30 -Padding 5
            } $source $inputPath (Join-Path $inputPath 'missing\sheet.jpg')
        }
        Assert-Unlocked $source
    }
    Test-Case 'EXIF rotation and mirroring handle all eight orientations' {
        $inputPath = New-TestFolder 'orientation'
        $source = Join-Path $inputPath 'source.jpg'
        $bitmap = [Drawing.Bitmap]::new(80, 60)
        $graphics = [Drawing.Graphics]::FromImage($bitmap)
        try {
            $graphics.FillRectangle([Drawing.Brushes]::Red, 0, 0, 40, 30)
            $graphics.FillRectangle([Drawing.Brushes]::Lime, 40, 0, 40, 30)
            $graphics.FillRectangle([Drawing.Brushes]::Blue, 0, 30, 40, 30)
            $graphics.FillRectangle([Drawing.Brushes]::Yellow, 40, 30, 40, 30)
            $bitmap.Save($source, [Drawing.Imaging.ImageFormat]::Jpeg)
        }
        finally { $graphics.Dispose(); $bitmap.Dispose() }
        $expectedCorners = @('Red,Lime,Blue,Yellow', 'Lime,Red,Yellow,Blue',
            'Yellow,Blue,Lime,Red', 'Blue,Yellow,Red,Lime', 'Red,Blue,Lime,Yellow',
            'Blue,Red,Yellow,Lime', 'Yellow,Lime,Blue,Red', 'Lime,Yellow,Red,Blue')
        for ($orientation = 1; $orientation -le 8; $orientation++) {
            $image = [Drawing.Image]::FromFile($source)
            $destination = Join-Path $inputPath "$orientation.jpg"
            try {
                $property = [Runtime.Serialization.FormatterServices]::GetUninitializedObject([Drawing.Imaging.PropertyItem])
                $property.Id = 274; $property.Type = 3; $property.Len = 2; $property.Value = [byte[]]@($orientation, 0)
                $image.SetPropertyItem($property)
                $image.Save($destination, [Drawing.Imaging.ImageFormat]::Jpeg)
            }
            finally { $image.Dispose() }
            $rotated = & $module { param($Path) Get-RotatedImage $Path } $destination
            try {
                $expectedWidth = if ($orientation -ge 5) { 60 } else { 80 }
                Assert-True ($rotated.Width -eq $expectedWidth) "Orientation $orientation dimensions"
                $corners = @($rotated.GetPixel(5, 5), $rotated.GetPixel($rotated.Width - 6, 5),
                    $rotated.GetPixel(5, $rotated.Height - 6), $rotated.GetPixel($rotated.Width - 6, $rotated.Height - 6))
                $colors = $expectedCorners[$orientation - 1].Split(',')
                for ($corner = 0; $corner -lt 4; $corner++) {
                    $expected = [Drawing.Color]::FromName($colors[$corner])
                    $actual = $corners[$corner]
                    Assert-True (([Math]::Abs([int]$expected.R - $actual.R) -lt 30) -and
                        ([Math]::Abs([int]$expected.G - $actual.G) -lt 30) -and
                        ([Math]::Abs([int]$expected.B - $actual.B) -lt 30)) "Orientation $orientation corner $corner"
                }
            }
            finally { $rotated.Dispose() }
        }
    }
    Test-Case 'CLI returns a nonzero process exit code for an invalid source' {
        $executable = (Get-Process -Id $PID).Path
        $previousPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            $messages = & $executable -NoProfile -File (Join-Path $repo 'MediaMosaic.ps1') -RootFolder (Join-Path $testRoot 'does-not-exist') 2>&1 | Out-String
            $exitCode = $LASTEXITCODE
        }
        finally { $ErrorActionPreference = $previousPreference }
        Assert-True ($exitCode -ne 0) "Expected nonzero exit: $messages"
    }
    Test-Case 'missing FFmpeg reports failures while ordinary images still render' {
        $inputPath = New-TestFolder 'missing-ffmpeg'
        New-TestImage (Join-Path $inputPath 'valid.jpg')
        Set-Content -LiteralPath (Join-Path $inputPath 'clip.mp4') -Value 'not a video'
        $result = Invoke-MediaMosaic -RootFolder $inputPath -OutputFile (Join-Path $inputPath 'sheet.jpg') -FFmpeg 'mediamosaic-nonexistent-ffmpeg' -WarningAction SilentlyContinue
        Assert-True ($result.Rendered -eq 1 -and $result.Failed -eq 1) 'Failure isolated to video'
    }
    $script:ffmpeg = Get-Command ffmpeg -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($script:ffmpeg) {
        Test-Case 'short videos fall back to their first frame; WebP and regular video render' {
            $inputPath = New-TestFolder 'video [fixtures]'
            New-FFmpegFixture @('-f', 'lavfi', '-i', 'color=c=red:s=64x48:d=1', '-c:v', 'mpeg4', (Join-Path $inputPath 'short.mp4'))
            New-FFmpegFixture @('-f', 'lavfi', '-i', 'color=c=blue:s=64x48:d=5', '-c:v', 'mpeg4', (Join-Path $inputPath 'long.mp4'))
            $jpeg = Join-Path $testRoot 'webp-source.jpg'; New-TestImage $jpeg
            New-FFmpegFixture @('-i', $jpeg, '-frames:v', '1', (Join-Path $inputPath 'image.webp'))
            $result = Invoke-TestMosaic $inputPath (Join-Path $inputPath 'sheet.jpg') @{ FFmpeg = $script:ffmpeg.Source }
            Assert-True ($result.Rendered -eq 3 -and $result.Failed -eq 0) 'All video/WebP previews rendered'
        }
        Test-Case 'FFmpeg preview clones release temporary PNGs on success and extraction failure' {
            $inputPath = New-TestFolder 'ffmpeg-cleanup'
            $video = Join-Path $inputPath 'short.mp4'
            New-FFmpegFixture @('-f', 'lavfi', '-i', 'color=c=red:s=64x48:d=1', '-c:v', 'mpeg4', $video)
            $preview = & $module { param($Path, $FFmpeg, $TemporaryFolder)
                Get-FFmpegPreview -Path $Path -FFmpeg $FFmpeg -Video -TemporaryFolder $TemporaryFolder
            } $video $script:ffmpeg.Source $inputPath
            try { Assert-True ($preview.Width -eq 64) 'Returned clone remains usable after temporary file deletion' }
            finally { $preview.Dispose() }
            Assert-Unlocked $video
            $invalid = Join-Path $inputPath 'invalid.mp4'; Set-Content -LiteralPath $invalid -Value 'not video'
            Assert-Throws { & $module { param($Path, $FFmpeg, $TemporaryFolder)
                Get-FFmpegPreview -Path $Path -FFmpeg $FFmpeg -Video -TemporaryFolder $TemporaryFolder
            } $invalid $script:ffmpeg.Source $inputPath } 'FFmpeg'
            Assert-True (@(Get-ChildItem -LiteralPath $inputPath -File -Filter '*.png').Count -eq 0) 'No preview temporary files leaked'
        }
        Test-Case 'invalid videos retain FFmpeg diagnostics in the CSV' {
            $inputPath = New-TestFolder 'invalid-video'
            Set-Content -LiteralPath (Join-Path $inputPath 'broken.mp4') -Value 'not a video'
            $result = Invoke-MediaMosaic -RootFolder $inputPath -OutputFile (Join-Path $inputPath 'sheet.jpg') -WarningAction SilentlyContinue
            $record = Import-Csv -LiteralPath $result.IndexPath
            Assert-True ($result.Failed -eq 1 -and $record.Error -match 'FFmpeg.*exit') 'Diagnostic retained'
        }
    }
    elseif ($RequireFFmpeg) { throw 'FFmpeg is required for this test run but was not found on PATH.' }
    else { Write-Host 'SKIP FFmpeg integration tests (ffmpeg is not on PATH).' }
}
finally {
    # Resolve and verify the unique test directory before recursive cleanup.
    $resolved = [IO.Path]::GetFullPath($testRoot)
    $parent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
    if ([IO.Path]::GetDirectoryName($resolved) -ne $parent -or
        [IO.Path]::GetFileName($resolved) -notmatch '^MediaMosaic-tests-[0-9a-f]{32}$') {
        throw "Refusing cleanup outside the test directory: $resolved"
    }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
Write-Host "$script:passed passed; $script:failed failed. PowerShell $($PSVersionTable.PSVersion)"
if ($script:failed) { exit 1 }
