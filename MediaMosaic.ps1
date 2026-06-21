Add-Type -AssemblyName System.Drawing

# ======================================
# SETTINGS
# ======================================

$RootFolder = "C:\Path\To\Images"
$OutputFile = "C:\Temp\ContactImageSheet.jpg"

$FFmpeg = "C:\Tools\ffmpeg\ffmpeg.exe"

$FilesPerSheet = 200

$HeaderHeight = 60
$ThumbWidth = 250
$ThumbHeight = 180
$TextHeight = 30
$Padding = 15
$Columns = 4

# ======================================
# IMAGE ORIENTATION FIX
# ======================================

function Get-RotatedImage {

    param (
        [string]$Path
    )

    $img = [System.Drawing.Image]::FromFile($Path)

    try {

        $orientationId = 274

        if ($img.PropertyIdList -contains $orientationId) {

            $orientation = $img.GetPropertyItem($orientationId).Value[0]

            switch ($orientation) {
                2 { $img.RotateFlip([System.Drawing.RotateFlipType]::RotateNoneFlipX) }
                3 { $img.RotateFlip([System.Drawing.RotateFlipType]::Rotate180FlipNone) }
                4 { $img.RotateFlip([System.Drawing.RotateFlipType]::Rotate180FlipX) }
                5 { $img.RotateFlip([System.Drawing.RotateFlipType]::Rotate90FlipX) }
                6 { $img.RotateFlip([System.Drawing.RotateFlipType]::Rotate90FlipNone) }
                7 { $img.RotateFlip([System.Drawing.RotateFlipType]::Rotate270FlipX) }
                8 { $img.RotateFlip([System.Drawing.RotateFlipType]::Rotate270FlipNone) }
            }
        }
    }
    catch {
    }

    return $img
}

# ======================================
# VIDEO THUMBNAILS
# ======================================

function Get-VideoThumbnail {

    param(
        [string]$VideoPath
    )

    $TempThumb = Join-Path $env:TEMP "$([guid]::NewGuid()).jpg"

    try {

        & $FFmpeg `
            -y `
            -hide_banner `
            -loglevel error `
            -ss 00:00:03 `
            -i $VideoPath `
            -frames:v 1 `
            $TempThumb | Out-Null

        if (Test-Path $TempThumb) {

            $Img = [System.Drawing.Image]::FromFile($TempThumb)

            $Clone = New-Object System.Drawing.Bitmap $Img

            $Img.Dispose()

            Remove-Item $TempThumb -Force

            return $Clone
        }
    }
    catch {
    }

    return $null
}

# ======================================
# PREVIEW IMAGE SELECTOR
# ======================================

function Get-PreviewImage {

    param(
        [string]$Path
    )

    $Ext = [IO.Path]::GetExtension($Path).ToLower()

    switch ($Ext) {

        ".jpg"  { return Get-RotatedImage $Path }
        ".jpeg" { return Get-RotatedImage $Path }
        ".png"  { return Get-RotatedImage $Path }
        ".bmp"  { return Get-RotatedImage $Path }
        ".gif"  { return Get-RotatedImage $Path }
        ".webp" { return Get-RotatedImage $Path }

        ".mp4"  { return Get-VideoThumbnail $Path }
        ".mov"  { return Get-VideoThumbnail $Path }
        ".avi"  { return Get-VideoThumbnail $Path }
        ".mkv"  { return Get-VideoThumbnail $Path }

        default { return $null }
    }
}

# ======================================
# GET FILES
# ======================================

$Files = Get-ChildItem -Path $RootFolder -Recurse -File |
    Where-Object {
        $_.Extension -match '\.(jpg|jpeg|png|bmp|gif|webp|mp4|mov|avi|mkv)$'
    }

if ($Files.Count -eq 0) {
    Write-Host "No media files found."
    exit
}

$BaseName = [System.IO.Path]::GetFileNameWithoutExtension($OutputFile)
$OutputFolder = Split-Path $OutputFile

$TotalSheets = [Math]::Ceiling([double]$Files.Count / $FilesPerSheet)

Write-Host "Creating $TotalSheets sheet(s)..."

# ======================================
# CANVAS SIZE
# ======================================

for ($Sheet = 1; $Sheet -le $TotalSheets; $Sheet++) {

    $SheetFiles = $Files |
        Select-Object -Skip (($Sheet - 1) * $FilesPerSheet) `
                      -First $FilesPerSheet

    Write-Host ""
    Write-Host "Processing Sheet $Sheet of $TotalSheets"

    $ActualFiles = $SheetFiles.Count
$Rows = [Math]::Ceiling([double]$ActualFiles / $Columns)

$CellWidth = $ThumbWidth + ($Padding * 2)
$CellHeight = $ThumbHeight + $TextHeight + ($Padding * 2)

$CanvasWidth = $Columns * $CellWidth
$CanvasHeight = ($Rows * $CellHeight) + $HeaderHeight

# ======================================
# CREATE CANVAS
# ======================================

$Bitmap = New-Object System.Drawing.Bitmap $CanvasWidth, $CanvasHeight
$Graphics = [System.Drawing.Graphics]::FromImage($Bitmap)

$Graphics.Clear([System.Drawing.Color]::White)
$Graphics.SmoothingMode = 'HighQuality'
$Graphics.InterpolationMode = 'HighQualityBicubic'
$Graphics.TextRenderingHint = 'ClearTypeGridFit'

$Font = New-Object System.Drawing.Font("Arial",10)
$Brush = [System.Drawing.Brushes]::Black

# Header

$TitleFont = New-Object System.Drawing.Font(
    "Arial",
    20,
    [System.Drawing.FontStyle]::Bold
)

$TitleText = "$BaseName-$Sheet.jpg - $($SheetFiles.Count) Files"

$TitleRect = New-Object System.Drawing.RectangleF(
    0,
    10,
    $CanvasWidth,
    40
)

$TitleFormat = New-Object System.Drawing.StringFormat
$TitleFormat.Alignment = "Center"

$Graphics.DrawString(
    $TitleText,
    $TitleFont,
    [System.Drawing.Brushes]::Black,
    $TitleRect,
    $TitleFormat
)

$Index = 0

# ======================================
# PROCESS FILES
# ======================================

foreach ($File in $SheetFiles) {

    try {

        $Image = Get-PreviewImage $File.FullName

        if ($null -eq $Image) {
            continue
        }

        $Col = $Index % $Columns
        $Row = [Math]::Floor($Index / $Columns)

        $X = ($Col * $CellWidth) + $Padding
        $Y = ($Row * $CellHeight) + $Padding + $HeaderHeight

        $RatioX = $ThumbWidth / $Image.Width
        $RatioY = $ThumbHeight / $Image.Height

        $Ratio = [Math]::Min($RatioX,$RatioY)

        $NewWidth = [int]($Image.Width * $Ratio)
        $NewHeight = [int]($Image.Height * $Ratio)

        $OffsetX = $X + (($ThumbWidth - $NewWidth) / 2)
        $OffsetY = $Y + (($ThumbHeight - $NewHeight) / 2)

        $Graphics.DrawImage(
            $Image,
            $OffsetX,
            $OffsetY,
            $NewWidth,
            $NewHeight
        )

        if ($File.Extension -match '\.(mp4|mov|avi|mkv)$') {

            $VideoFont = New-Object System.Drawing.Font(
                "Arial",
                8,
                [System.Drawing.FontStyle]::Bold
            )

            $Graphics.DrawString(
                "VIDEO",
                $VideoFont,
                [System.Drawing.Brushes]::Red,
                $X + 5,
                $Y + 5
            )

            $VideoFont.Dispose()
        }

        $TextRect = New-Object System.Drawing.RectangleF(
            $X,
            ($Y + $ThumbHeight + 5),
            $ThumbWidth,
            $TextHeight
        )

        $StringFormat = New-Object System.Drawing.StringFormat
        $StringFormat.Alignment = "Center"

        $Graphics.DrawString(
            $File.Name,
            $Font,
            $Brush,
            $TextRect,
            $StringFormat
        )

        $Image.Dispose()

        Write-Host "Added: $($File.Name)"

        $Index++
    }
    catch {
        Write-Warning "Failed: $($File.FullName)"
    }
}

# ======================================
# SAVE
# ======================================

# ======================================
# SAVE
# ======================================

$SheetOutput = Join-Path `
    $OutputFolder `
    "$BaseName-$Sheet.jpg"
$UsedRows = [Math]::Ceiling([double]$Index / $Columns)

$ActualHeight =
    ($UsedRows * $CellHeight) +
    $HeaderHeight +
    $Padding

if ($ActualHeight -lt $Bitmap.Height) {

    $Cropped = New-Object System.Drawing.Bitmap(
        $Bitmap.Width,
        $ActualHeight
    )

    $CropGraphics = [System.Drawing.Graphics]::FromImage($Cropped)

    $CropGraphics.DrawImage(
        $Bitmap,
        0,
        0
    )

    $CropGraphics.Dispose()
    $Bitmap.Dispose()

    $Bitmap = $Cropped
}
$Bitmap.Save(
    $SheetOutput,
    [System.Drawing.Imaging.ImageFormat]::Jpeg
)

$Graphics.Dispose()
$Bitmap.Dispose()
$Font.Dispose()
$TitleFont.Dispose()

Write-Host ""
Write-Host "Contact sheet created:"
Write-Host $SheetOutput

}