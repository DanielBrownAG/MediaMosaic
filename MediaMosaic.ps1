#requires -Version 5.1
<#
.SYNOPSIS
Creates JPEG contact sheets and a CSV index from a media folder.
.EXAMPLE
.\MediaMosaic.ps1 -RootFolder 'D:\Photos' -OutputFile 'C:\Temp\Project.jpg'
#>
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
Import-Module (Join-Path $PSScriptRoot 'MediaMosaic.psm1') -Force -ErrorAction Stop
Invoke-MediaMosaic @PSBoundParameters
