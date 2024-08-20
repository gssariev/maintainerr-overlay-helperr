# Define your Plex server and Maintainerr details
$PLEX_URL = $env:PLEX_URL
$PLEX_TOKEN = $env:PLEX_TOKEN
$MAINTAINERR_URL = $env:MAINTAINERR_URL
$IMAGE_SAVE_PATH = $env:IMAGE_SAVE_PATH
$ORIGINAL_IMAGE_PATH = $env:ORIGINAL_IMAGE_PATH
$TEMP_IMAGE_PATH = $env:TEMP_IMAGE_PATH
$FONT_PATH = $env:FONT_PATH
$FONT_COLOR = $env:FONT_COLOR
$BACK_COLOR = $env:BACK_COLOR
$FONT_SIZE = [int]$env:FONT_SIZE
$PADDING = [int]$env:PADDING
$BACK_RADIUS = [int]$env:BACK_RADIUS
$HORIZONTAL_OFFSET = [int]$env:HORIZONTAL_OFFSET
$HORIZONTAL_ALIGN = $env:HORIZONTAL_ALIGN
$VERTICAL_OFFSET = [int]$env:VERTICAL_OFFSET
$VERTICAL_ALIGN = $env:VERTICAL_ALIGN
$RUN_INTERVAL = [int]$env:RUN_INTERVAL

if (-not $RUN_INTERVAL) {
    $RUN_INTERVAL = 8 * 60 * 60 # Default to 8 hours in seconds
} else {
    $RUN_INTERVAL = $RUN_INTERVAL * 60 # Convert minutes to seconds
}

# Function to get data from Maintainerr
function Get-MaintainerrData {
    $response = Invoke-RestMethod -Uri $MAINTAINERR_URL -Method Get
    return $response
}

# Function to calculate the calendar date
function Calculate-Date {
    param (
        [Parameter(Mandatory=$true)]
        [datetime]$addDate,

        [Parameter(Mandatory=$true)]
        [int]$deleteAfterDays
    )

    Write-Host "Attempting to parse date: $addDate"
    $deleteDate = $addDate.AddDays($deleteAfterDays)
    $daySuffix = switch ($deleteDate.Day) {
        1  { "st" }
        2  { "nd" }
        3  { "rd" }
        21 { "st" }
        22 { "nd" }
        23 { "rd" }
        31 { "st" }
        default { "th" }
    }
    $formattedDate = $deleteDate.ToString("MMM d") + $daySuffix
    return $formattedDate
}

# Function to download the current poster
function Download-Poster {
    param (
        [string]$posterUrl,
        [string]$savePath
    )
    Invoke-WebRequest -Uri $posterUrl -OutFile $savePath -Headers @{"X-Plex-Token"=$PLEX_TOKEN}
}

# Function to add overlay text to the poster
function Add-Overlay {
    param (
        [string]$imagePath,
        [string]$text,
        [string]$fontColor = $FONT_COLOR,
        [string]$backColor = $BACK_COLOR,
        [string]$fontPath = $FONT_PATH,
        [int]$fontSize = $FONT_SIZE,
        [int]$padding = $PADDING,
        [int]$backRadius = $BACK_RADIUS,
        [int]$horizontalOffset = $HORIZONTAL_OFFSET,
        [string]$horizontalAlign = $HORIZONTAL_ALIGN,
        [int]$verticalOffset = $VERTICAL_OFFSET,
        [string]$verticalAlign = $VERTICAL_ALIGN
    )

    Add-Type -AssemblyName System.Drawing

    $image = [System.Drawing.Image]::FromFile($imagePath)
    $graphics = [System.Drawing.Graphics]::FromImage($image)

    # Get image dimensions
    $imageWidth = $image.Width
    $imageHeight = $image.Height

    # Calculate scaling factors based on the image dimensions
    $scaleFactor = $imageWidth / 1000  # Use a reference width of 1000px
    $scaledFontSize = [int]($fontSize * $scaleFactor)
    $scaledPadding = [int]($padding * $scaleFactor)
    $scaledBackRadius = [int]($backRadius * $scaleFactor)
    $scaledHorizontalOffset = [int]($horizontalOffset * $scaleFactor)
    $scaledVerticalOffset = [int]($verticalOffset * $scaleFactor)

    # Load the custom font
    $privateFontCollection = New-Object System.Drawing.Text.PrivateFontCollection
    $privateFontCollection.AddFontFile($fontPath)
    $fontFamily = $privateFontCollection.Families[0]
    $font = New-Object System.Drawing.Font($fontFamily, $scaledFontSize, [System.Drawing.FontStyle]::Bold)

    $brush = New-Object System.Drawing.SolidBrush([System.Drawing.ColorTranslator]::FromHtml($fontColor))
    $backBrush = New-Object System.Drawing.SolidBrush([System.Drawing.ColorTranslator]::FromHtml($backColor))

    # Measure the text size
    $size = $graphics.MeasureString($text, $font)

    # Calculate background dimensions based on text size and padding
    $backWidth = [int]($size.Width + $scaledPadding * 2)
    $backHeight = [int]($size.Height + $scaledPadding * 2)

    switch ($horizontalAlign) {
        "right" { $x = $image.Width - $backWidth - $scaledHorizontalOffset }
        "center" { $x = ($image.Width - $backWidth) / 2 }
        "left" { $x = $scaledHorizontalOffset }
        default { $x = $image.Width - $backWidth - $scaledHorizontalOffset }
    }

    switch ($verticalAlign) {
        "bottom" { $y = $image.Height - $backHeight - $scaledVerticalOffset }
        "center" { $y = ($image.Height - $backHeight) / 2 }
        "top" { $y = $scaledVerticalOffset }
        default { $y = $image.Height - $backHeight - $scaledVerticalOffset }
    }

    # Draw the rounded rectangle background
    $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $path.AddArc($x, $y, $scaledBackRadius, $scaledBackRadius, 180, 90)
    $path.AddArc($x + $backWidth - $scaledBackRadius, $y, $scaledBackRadius, $scaledBackRadius, 270, 90)
    $path.AddArc($x + $backWidth - $scaledBackRadius, $y + $backHeight - $scaledBackRadius, $scaledBackRadius, $scaledBackRadius, 0, 90)
    $path.AddArc($x, $y + $backHeight - $scaledBackRadius, $scaledBackRadius, $scaledBackRadius, 90, 90)
    $path.CloseFigure()
    $graphics.FillPath($backBrush, $path)

    # Adjust the text position to account for ascent and descent
    $textX = $x + ($backWidth - $size.Width) / 2
    $textY = $y + ($backHeight - $size.Height) / 2

    $graphics.DrawString($text, $font, $brush, $textX, $textY)

    $outputImagePath = [System.IO.Path]::Combine($TEMP_IMAGE_PATH, [System.IO.Path]::GetFileName($imagePath))

    try {
        $image.Save($outputImagePath)
    } catch {
        Write-Error "Failed to save image: $_"
    } finally {
        $graphics.Dispose()
        $image.Dispose()
    }
    return $outputImagePath
}

# Function to upload the modified poster back to Plex
function Upload-Poster {
    param (
        [string]$posterPath,
        [string]$metadataId
    )
    $uploadUrl = "$PLEX_URL/library/metadata/$metadataId/posters?X-Plex-Token=$PLEX_TOKEN"
    $posterBytes = [System.IO.File]::ReadAllBytes($posterPath)
    Invoke-RestMethod -Uri $uploadUrl -Method Post -Body $posterBytes -ContentType "image/jpeg"

    # Delete the temp image after upload
    try {
        Remove-Item -Path $posterPath -ErrorAction Stop
        Write-Host "Deleted temporary file: $posterPath"
    } catch {
        Write-Error "Failed to delete temporary file ${posterPath}: $_"
    }
}

# Main function to process the media items
function Process-MediaItems {
    $maintainerrData = Get-MaintainerrData

    foreach ($collection in $maintainerrData) {
        $deleteAfterDays = $collection.deleteAfterDays

        foreach ($item in $collection.media) {
            $plexId = $item.plexId
            $addDate = $item.addDate
            
            try {
                $formattedDate = Calculate-Date -addDate $addDate -deleteAfterDays $deleteAfterDays
            } catch {
                Write-Error "Failed to parse date for media item ${plexId}: $_"
                continue
            }
            
            $posterUrl = "$PLEX_URL/library/metadata/$plexId/thumb?X-Plex-Token=$PLEX_TOKEN"
            $originalImagePath = "$ORIGINAL_IMAGE_PATH/$plexId.jpg"
            $tempImagePath = "$TEMP_IMAGE_PATH/$plexId.jpg"

            try {
                # Check if original image already exists
                if (-not (Test-Path -Path $originalImagePath)) {
                    Download-Poster -posterUrl $posterUrl -savePath $originalImagePath
                }

                # Copy the original image to the temp directory
                Copy-Item -Path $originalImagePath -Destination $tempImagePath -Force

                # Apply overlay to the temp copy and get the updated path
                $tempImagePath = Add-Overlay -imagePath $tempImagePath -text "Leaving $formattedDate" -fontColor $FONT_COLOR -backColor $BACK_COLOR -fontPath $FONT_PATH -fontSize $FONT_SIZE -padding $PADDING -backRadius $BACK_RADIUS -horizontalOffset $HORIZONTAL_OFFSET -horizontalAlign $HORIZONTAL_ALIGN -verticalOffset $VERTICAL_OFFSET -verticalAlign $VERTICAL_ALIGN
                
                # Upload the modified poster to Plex
                Upload-Poster -posterPath $tempImagePath -metadataId $plexId
            } catch {
                Write-Error "Failed to process media item ${plexId}: $_"
            }
        }
    }
}

# Ensure the images directories exist
if (-not (Test-Path -Path $IMAGE_SAVE_PATH)) {
    New-Item -ItemType Directory -Path $IMAGE_SAVE_PATH
}
if (-not (Test-Path -Path $ORIGINAL_IMAGE_PATH)) {
    New-Item -ItemType Directory -Path $ORIGINAL_IMAGE_PATH
}
if (-not (Test-Path -Path $TEMP_IMAGE_PATH)) {
    New-Item -ItemType Directory -Path $TEMP_IMAGE_PATH
}

# Run the main function in a loop with the specified interval
while ($true) {
    Process-MediaItems
    Write-Host "Waiting for $RUN_INTERVAL seconds before the next run."
    Start-Sleep -Seconds $RUN_INTERVAL
}
