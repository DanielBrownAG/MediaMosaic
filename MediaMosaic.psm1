#requires -Version 5.1
Set-StrictMode -Version Latest

function Get-RotatedImage {
    param([string]$Path)
    $image = [Drawing.Image]::FromFile($Path)
    try {
        if ($image.PropertyIdList -contains 274) {
            $rotation = switch ($image.GetPropertyItem(274).Value[0]) {
                2 { 'RotateNoneFlipX' }
                3 { 'Rotate180FlipNone' }
                4 { 'Rotate180FlipX' }
                5 { 'Rotate90FlipX' }
                6 { 'Rotate90FlipNone' }
                7 { 'Rotate270FlipX' }
                8 { 'Rotate270FlipNone' }
            }
            if ($rotation) { $image.RotateFlip([Drawing.RotateFlipType]$rotation) }
        }
        return $image
    }
    catch { $image.Dispose(); throw }
}

function Write-MediaProgress {
    param([hashtable]$Context, [switch]$Completed)
    if (-not $Context -or $Context.Suppress) { return }
    if ($Completed) {
        Write-Progress -Id $Context.Id -Activity 'MediaMosaic' -Completed
        return
    }
    $percent = if ($Context.Total -gt 0) {
        [Math]::Min(99, [int](100.0 * $Context.Processed / $Context.Total))
    }
    else { -1 }
    $status = '{0} | {1}/{2} processed | {3}s elapsed' -f $Context.Status,
        $Context.Processed, $Context.Total, [int]$Context.Clock.Elapsed.TotalSeconds
    Write-Progress -Id $Context.Id -Activity 'MediaMosaic' -Status $status `
        -CurrentOperation $Context.CurrentFile -PercentComplete $percent
    $Context.LastUpdate = $Context.Clock.Elapsed.TotalSeconds
}

function Invoke-FFmpegProcess {
    param([string]$Executable, [string[]]$Arguments,
        [ValidateRange(1, 3600000)][int]$TimeoutMilliseconds, [hashtable]$ProgressContext)
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $Executable
    # Quote each argument using Windows native argument escaping, including
    # embedded quotes and trailing backslashes. ArgumentList is unavailable in 5.1.
    $startInfo.Arguments = (@(foreach ($argument in $Arguments) {
        '"' + [regex]::Replace([regex]::Replace($argument, '(\\*)"', '$1$1\"'), '(\\+)$', '$1$1') + '"'
    })) -join ' '
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.RedirectStandardOutput = $true
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    $started = $false
    $clock = [Diagnostics.Stopwatch]::StartNew()
    try {
        $started = $process.Start()
        # Drain both pipes concurrently so verbose native output cannot deadlock.
        $stderr = $process.StandardError.ReadToEndAsync()
        $stdout = $process.StandardOutput.ReadToEndAsync()
        while (-not $process.HasExited) {
            $remaining = $TimeoutMilliseconds - [int]$clock.ElapsedMilliseconds
            if ($remaining -le 0) {
                throw [TimeoutException]::new('FFmpeg preview timed out; the decoder was terminated.')
            }
            [void]$process.WaitForExit([Math]::Min(100, $remaining))
            if ($ProgressContext -and $ProgressContext.Clock.Elapsed.TotalSeconds - $ProgressContext.LastUpdate -ge 1) {
                Write-MediaProgress -Context $ProgressContext
            }
        }
        [pscustomobject]@{
            ExitCode = $process.ExitCode
            Diagnostic = ($stderr.Result + [Environment]::NewLine + $stdout.Result).Trim()
        }
    }
    finally {
        # FFmpeg is launched directly, so its process can also be stopped in
        # Windows PowerShell 5.1, which lacks Process.Kill(entireProcessTree).
        if ($started -and -not $process.HasExited) {
            $process.Kill()
            [void]$process.WaitForExit(5000)
        }
        $process.Dispose()
    }
}

function Get-FFmpegPreview {
    param([string]$Path, [string]$FFmpeg, [switch]$Video,
        [string]$TemporaryFolder = [IO.Path]::GetTempPath(),
        [int]$FFmpegTimeoutSeconds = 30, [hashtable]$ProgressContext)
    if (Test-Path -LiteralPath $FFmpeg -PathType Leaf) {
        $executable = (Get-Item -LiteralPath $FFmpeg -ErrorAction Stop).FullName
    }
    else {
        $command = Get-Command -Name $FFmpeg -CommandType Application -ErrorAction Stop | Select-Object -First 1
        $executable = $command.Source
    }
    $temporaryFile = Join-Path $TemporaryFolder (([guid]::NewGuid().ToString('N')) + '.png')
    $image = $null
    $diagnostic = ''
    $clock = [Diagnostics.Stopwatch]::StartNew()
    # A successful FFmpeg exit does not guarantee that a frame was written.
    $positions = if ($Video) { @(3, 0) } else { @(0) }
    try {
        foreach ($position in $positions) {
            if (Test-Path -LiteralPath $temporaryFile) {
                Remove-Item -LiteralPath $temporaryFile -Force -ErrorAction Stop
            }
            $arguments = @('-nostdin', '-y', '-hide_banner', '-loglevel', 'error', '-ss', "$position",
                '-i', $Path, '-map', '0:v:0', '-frames:v', '1', '-c:v', 'png', '-threads', '1', $temporaryFile)
            # The first-frame fallback shares the same per-file time budget.
            $remaining = $FFmpegTimeoutSeconds * 1000 - [int]$clock.ElapsedMilliseconds
            if ($remaining -le 0) { throw [TimeoutException]::new('FFmpeg preview timed out before the fallback frame could be extracted.') }
            $result = Invoke-FFmpegProcess -Executable $executable -Arguments $arguments `
                -TimeoutMilliseconds $remaining -ProgressContext $ProgressContext
            $exitCode = $result.ExitCode
            $diagnostic = $result.Diagnostic
            if ($exitCode -eq 0 -and (Test-Path -LiteralPath $temporaryFile) -and
                (Get-Item -LiteralPath $temporaryFile).Length -gt 0) {
                $image = [Drawing.Image]::FromFile($temporaryFile)
                return [Drawing.Bitmap]::new($image)
            }
        }
        throw "FFmpeg could not extract a frame (exit $exitCode). $diagnostic"
    }
    finally {
        if ($image) { $image.Dispose() }
        if (Test-Path -LiteralPath $temporaryFile) {
            Remove-Item -LiteralPath $temporaryFile -Force -ErrorAction Stop
        }
    }
}

function Get-PreviewImage {
    param([string]$Path, [string]$FFmpeg, [int]$FFmpegTimeoutSeconds = 30, [hashtable]$ProgressContext)
    if ([IO.Path]::GetExtension($Path) -match '^\.(mp4|mov|avi|mkv)$') {
        return Get-FFmpegPreview -Path $Path -FFmpeg $FFmpeg -Video -FFmpegTimeoutSeconds $FFmpegTimeoutSeconds -ProgressContext $ProgressContext
    }
    if ([IO.Path]::GetExtension($Path) -ieq '.webp') {
        return Get-FFmpegPreview -Path $Path -FFmpeg $FFmpeg -FFmpegTimeoutSeconds $FFmpegTimeoutSeconds -ProgressContext $ProgressContext
    }
    return Get-RotatedImage -Path $Path
}

function Get-MediaFiles {
    param([string]$Root, [string]$OutputFolder, [string]$BaseName)
    $outputPattern = '^' + [regex]::Escape($BaseName) + '-[1-9][0-9]*\.jpg$'
    $stagingPattern = '^' + [regex]::Escape($OutputFolder.TrimEnd('\', '/')) +
        '[\\/]\.mediamosaic-[0-9a-f]{32}[\\/]'
    Get-ChildItem -LiteralPath $Root -Recurse -File -ErrorAction Stop |
        Where-Object {
            $_.Extension -match '^\.(jpg|jpeg|png|bmp|gif|webp|mp4|mov|avi|mkv)$' -and
            $_.FullName -notmatch $stagingPattern -and
            -not ($_.DirectoryName -ieq $OutputFolder -and $_.Name -match $outputPattern)
        } | Sort-Object -Property FullName
}

function Write-ContactSheet {
    param([IO.FileInfo[]]$Files, [string]$Root, [string]$Path, [string]$Title,
        [int]$Sheet, [string]$FFmpeg, [int]$Columns, [int]$ThumbWidth,
        [int]$ThumbHeight, [int]$HeaderHeight, [int]$TextHeight, [int]$Padding,
        [int]$FFmpegTimeoutSeconds = 30, [hashtable]$ProgressContext)
    $cellWidth = $ThumbWidth + 2 * $Padding
    $cellHeight = $ThumbHeight + $TextHeight + 2 * $Padding
    $rows = [int][Math]::Ceiling($Files.Count / [double]$Columns)
    $width = [long]$Columns * $cellWidth
    $height = [long]$rows * $cellHeight + $HeaderHeight
    if ($width -gt 65500 -or $height -gt 65500 -or $width * $height -gt 100000000) {
        throw 'Canvas is too large. Reduce FilesPerSheet, Columns, or thumbnail dimensions (maximum 100 million pixels and 65,500 pixels per side).'
    }
    $resources = [Collections.Generic.List[IDisposable]]::new()
    $records = [Collections.Generic.List[object]]::new()
    try {
        $bitmap = [Drawing.Bitmap]::new([int]$width, [int]$height); $resources.Add($bitmap)
        $graphics = [Drawing.Graphics]::FromImage($bitmap); $resources.Add($graphics)
        $font = [Drawing.Font]::new('Arial', 10); $resources.Add($font)
        $titleFont = [Drawing.Font]::new('Arial', 20, [Drawing.FontStyle]::Bold); $resources.Add($titleFont)
        $videoFont = [Drawing.Font]::new('Arial', 8, [Drawing.FontStyle]::Bold); $resources.Add($videoFont)
        $format = [Drawing.StringFormat]::new(); $resources.Add($format)
        $format.Alignment = [Drawing.StringAlignment]::Center
        $format.Trimming = [Drawing.StringTrimming]::EllipsisPath
        $graphics.Clear([Drawing.Color]::White)
        $graphics.InterpolationMode = [Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $graphics.TextRenderingHint = [Drawing.Text.TextRenderingHint]::ClearTypeGridFit
        for ($index = 0; $index -lt $Files.Count; $index++) {
            $file = $Files[$index]
            $relativePath = $file.FullName.Substring($Root.TrimEnd('\', '/').Length + 1)
            if ($ProgressContext) {
                $ProgressContext.CurrentFile = $relativePath
                Write-MediaProgress -Context $ProgressContext
            }
            $x = ($index % $Columns) * $cellWidth + $Padding
            $y = [int][Math]::Floor($index / [double]$Columns) * $cellHeight + $Padding + $HeaderHeight
            $image = $null
            $status = 'Rendered'
            $failure = ''
            try {
                $image = Get-PreviewImage -Path $file.FullName -FFmpeg $FFmpeg `
                    -FFmpegTimeoutSeconds $FFmpegTimeoutSeconds -ProgressContext $ProgressContext
                $ratio = [Math]::Min($ThumbWidth / [double]$image.Width, $ThumbHeight / [double]$image.Height)
                $newWidth = [Math]::Max(1, [int]($image.Width * $ratio))
                $newHeight = [Math]::Max(1, [int]($image.Height * $ratio))
                $rectangle = [Drawing.RectangleF]::new(
                    [single]($x + ($ThumbWidth - $newWidth) / 2),
                    [single]($y + ($ThumbHeight - $newHeight) / 2), [single]$newWidth, [single]$newHeight)
                $graphics.DrawImage($image, $rectangle)
            }
            catch {
                $status = 'Failed'
                $failure = $_.Exception.Message
                Write-Warning "Failed: $($file.FullName): $failure"
                $graphics.FillRectangle([Drawing.Brushes]::White, $x, $y, $ThumbWidth, $ThumbHeight)
                $graphics.DrawString('PREVIEW FAILED', $font, [Drawing.Brushes]::DarkRed,
                    [Drawing.RectangleF]::new($x, $y, $ThumbWidth, $ThumbHeight), $format)
            }
            finally { if ($image) { $image.Dispose() } }
            if ($file.Extension -match '^\.(mp4|mov|avi|mkv)$') {
                $graphics.DrawString('VIDEO', $videoFont, [Drawing.Brushes]::Red, [single]($x + 5), [single]($y + 5))
            }
            $graphics.DrawString($relativePath, $font, [Drawing.Brushes]::Black,
                [Drawing.RectangleF]::new($x, ($y + $ThumbHeight + 5), $ThumbWidth, $TextHeight), $format)
            $records.Add([pscustomobject]@{
                RelativePath = $relativePath; Sheet = $Sheet; Cell = $index + 1
                Status = $status; Error = $failure
            })
            if ($ProgressContext) {
                $ProgressContext.Processed++
                Write-MediaProgress -Context $ProgressContext
            }
        }
        $failed = @($records | Where-Object Status -eq 'Failed').Count
        $header = "$Title - $($Files.Count - $failed) rendered, $failed failed"
        $graphics.DrawString($header, $titleFont, [Drawing.Brushes]::Black,
            [Drawing.RectangleF]::new(0, 10, $width, [Math]::Max(1, $HeaderHeight - 10)), $format)
        $bitmap.Save($Path, [Drawing.Imaging.ImageFormat]::Jpeg)
        return $records.ToArray()
    }
    finally {
        # Graphics must be disposed before its underlying bitmap.
        for ($i = $resources.Count - 1; $i -ge 0; $i--) { $resources[$i].Dispose() }
    }
}

function Invoke-MediaMosaic {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$RootFolder,
        [ValidateNotNullOrEmpty()][string]$OutputFile = 'MediaMosaic.jpg',
        [ValidateNotNullOrEmpty()][string]$FFmpeg = 'ffmpeg',
        [ValidateRange(1, 3600)][int]$FFmpegTimeoutSeconds = 30,
        [switch]$NoProgress,
        [ValidateRange(1, 100000)][int]$FilesPerSheet = 200,
        [ValidateRange(1, 1000)][int]$Columns = 4,
        [ValidateRange(1, 10000)][int]$ThumbWidth = 250,
        [ValidateRange(1, 10000)][int]$ThumbHeight = 180,
        [ValidateRange(1, 10000)][int]$HeaderHeight = 60,
        [ValidateRange(1, 10000)][int]$TextHeight = 30,
        [ValidateRange(0, 1000)][int]$Padding = 15
    )
    $ErrorActionPreference = 'Stop'
    $progressContext = @{
        Id = (Get-Random -Minimum 1 -Maximum 2147483647); Suppress = [bool]$NoProgress
        Total = 0; Processed = 0; Clock = [Diagnostics.Stopwatch]::StartNew()
        Status = 'Scanning media'; CurrentFile = $RootFolder; LastUpdate = 0
    }
    try {
        Write-MediaProgress -Context $progressContext
        if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
            throw 'MediaMosaic requires Windows and System.Drawing.'
        }
        Add-Type -AssemblyName System.Drawing
        $root = Get-Item -LiteralPath $RootFolder -ErrorAction Stop
        if (-not $root.PSIsContainer -or $root.PSProvider.Name -ne 'FileSystem') {
            throw 'RootFolder must be a filesystem directory.'
        }
        $outputPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputFile)
        if ([IO.Path]::GetExtension($outputPath) -notmatch '^\.jpe?g$') {
            throw 'OutputFile must have a .jpg or .jpeg extension.'
        }
        $outputFolder = [IO.Path]::GetDirectoryName($outputPath)
        $baseName = [IO.Path]::GetFileNameWithoutExtension($outputPath)
        if (-not (Test-Path -LiteralPath $outputFolder)) { [IO.Directory]::CreateDirectory($outputFolder) | Out-Null }
        $files = @(Get-MediaFiles -Root $root.FullName -OutputFolder $outputFolder -BaseName $baseName)
        $progressContext.Total = $files.Count
        $manifestPath = Join-Path $outputFolder "$baseName.mediamosaic.json"
        $oldSheets = @()
        if (Test-Path -LiteralPath $manifestPath) {
            $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
            if ($manifest.Version -ne 1) { throw "Unsupported manifest: $manifestPath" }
            $pattern = '^' + [regex]::Escape($baseName) + '-[1-9][0-9]*\.jpg$'
            foreach ($name in $manifest.Sheets) {
                # Never accept paths, wildcards, or arbitrary files from a manifest.
                if ($name -isnot [string] -or $name -notmatch $pattern) { throw "Invalid sheet name in manifest: $manifestPath" }
                $oldSheets += $name
            }
        }
        $staging = Join-Path $outputFolder ('.mediamosaic-' + [guid]::NewGuid().ToString('N'))
        [IO.Directory]::CreateDirectory($staging) | Out-Null
        try {
            $records = [Collections.Generic.List[object]]::new()
            $sheets = [Collections.Generic.List[string]]::new()
            $sheetNumber = 0
            for ($offset = 0; $offset -lt $files.Count; $offset += $FilesPerSheet) {
                $sheetNumber++
                $progressContext.Status = 'Sheet {0}/{1}' -f $sheetNumber, [int][Math]::Ceiling($files.Count / [double]$FilesPerSheet)
                $last = [Math]::Min($offset + $FilesPerSheet, $files.Count) - 1
                $name = "$baseName-$sheetNumber.jpg"
                $batch = @($files[$offset..$last])
                $sheetOptions = @{
                    Files = $batch; Root = $root.FullName; Path = (Join-Path $staging $name)
                    Title = $name; Sheet = $sheetNumber; FFmpeg = $FFmpeg; Columns = $Columns
                    ThumbWidth = $ThumbWidth; ThumbHeight = $ThumbHeight; HeaderHeight = $HeaderHeight
                    TextHeight = $TextHeight; Padding = $Padding
                    FFmpegTimeoutSeconds = $FFmpegTimeoutSeconds; ProgressContext = $progressContext
                }
                foreach ($record in (Write-ContactSheet @sheetOptions)) { $records.Add($record) }
                $sheets.Add($name)
            }
            $indexName = "$baseName-index.csv"
            $indexPath = Join-Path $staging $indexName
            if ($records.Count) { $records.ToArray() | Export-Csv -LiteralPath $indexPath -NoTypeInformation -Encoding UTF8 }
            else { Set-Content -LiteralPath $indexPath -Value '"RelativePath","Sheet","Cell","Status","Error"' -Encoding UTF8 }
            $manifestName = [IO.Path]::GetFileName($manifestPath)
            @{ Version = 1; Sheets = @($sheets.ToArray()) } | ConvertTo-Json |
                Set-Content -LiteralPath (Join-Path $staging $manifestName) -Encoding UTF8
            # Publish only after every sheet has been generated successfully.
            $progressContext.Status = 'Publishing outputs'
            $progressContext.CurrentFile = $outputFolder
            Write-MediaProgress -Context $progressContext
            foreach ($name in @($sheets.ToArray()) + @($indexName)) {
                Move-Item -LiteralPath (Join-Path $staging $name) -Destination (Join-Path $outputFolder $name) -Force
            }
            foreach ($name in $oldSheets) {
                if (-not $sheets.Contains($name)) {
                    $obsolete = Join-Path $outputFolder $name
                    if (Test-Path -LiteralPath $obsolete -PathType Leaf) { Remove-Item -LiteralPath $obsolete -Force }
                }
            }
            Move-Item -LiteralPath (Join-Path $staging $manifestName) -Destination $manifestPath -Force
            $failed = @($records | Where-Object Status -eq 'Failed').Count
            [pscustomobject]@{
                Discovered = $files.Count; Rendered = $files.Count - $failed; Failed = $failed
                Sheets = @($sheets | ForEach-Object { Join-Path $outputFolder $_ })
                IndexPath = Join-Path $outputFolder $indexName
                ManifestPath = $manifestPath
            }
        }
        finally {
            # Delete only immediate files in the exact private staging directory we created.
            foreach ($file in (Get-ChildItem -LiteralPath $staging -File)) {
                Remove-Item -LiteralPath $file.FullName -Force
            }
            Remove-Item -LiteralPath $staging -Force
        }
    }
    finally { Write-MediaProgress -Context $progressContext -Completed }
}

Export-ModuleMember -Function Invoke-MediaMosaic
