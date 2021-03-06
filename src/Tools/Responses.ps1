# write data to main http response
function Write-ToResponse
{
    param (
        [Parameter()]
        $Value,

        [Parameter()]
        [string]
        $ContentType = $null
    )

    if (Test-Empty $Value) {
        return
    }

    $res = $WebEvent.Response
    if ($null -eq $res -or $null -eq $res.OutputStream -or !$res.OutputStream.CanWrite) {
        return
    }

    if (!(Test-Empty $ContentType)) {
        $res.ContentType = $ContentType
    }

    if ((Get-Type $Value).Name -ieq 'string') {
        $Value = [System.Text.Encoding]::UTF8.GetBytes($Value)
    }

    $res.ContentLength64 = $Value.Length

    try {
        $memory = New-Object -TypeName System.IO.MemoryStream
        $memory.Write($Value, 0, $Value.Length)
        $memory.WriteTo($res.OutputStream)
        $memory.Close()
    }
    catch {
        if (Test-ValidNetworkFailure $_.Exception) {
            return
        }

        $Error[0] | Out-Default
        throw $_.Exception
    }
}

function Write-ToResponseFromFile
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNull()]
        $Path
    )

    # test the file path, and set status accordingly
    if (!(Test-PodePath $Path -FailOnDirectory)) {
        return
    }

    # are we dealing with a dynamic file for the view engine?
    $ext = Get-FileExtension -Path $Path -TrimPeriod

    if ((Test-Empty $ext) -or $ext -ine $PodeSession.Server.ViewEngine.Extension) {
        $content = Get-ContentAsBytes -Path $Path
        Write-ToResponse -Value $content -ContentType (Get-PodeContentType -Extension $ext)
        return
    }

    # generate dynamic content
    $content = [string]::Empty

    switch ($PodeSession.Server.ViewEngine.Engine)
    {
        'pode' {
            $content = Get-Content -Path $Path -Raw -Encoding utf8
            $content = ConvertFrom-PodeFile -Content $content
        }

        default {
            if ($null -ne $PodeSession.Server.ViewEngine.Script) {
                $content = (Invoke-ScriptBlock -ScriptBlock $PodeSession.Server.ViewEngine.Script -Arguments $Path -Return)
            }
        }
    }

    $ext = Get-FileExtension -Path (Get-FileName -Path $Path -WithoutExtension) -TrimPeriod
    Write-ToResponse -Value $content -ContentType (Get-PodeContentType -Extension $ext)
}

function Attach
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [Alias('p')]
        [string]
        $Path
    )

    # only download files from public/static-route directories
    $Path = Get-PodeStaticRoutePath -Path $Path


    # test the file path, and set status accordingly
    if (!(Test-PodePath $Path)) {
        return
    }

    $filename = Get-FileName -Path $Path
    $ext = Get-FileExtension -Path $Path -TrimPeriod

    # open up the file as a stream
    $fs = [System.IO.File]::OpenRead($Path)

    # setup the response details and headers
    $WebEvent.Response.ContentLength64 = $fs.Length
    $WebEvent.Response.SendChunked = $false
    $WebEvent.Response.ContentType = (Get-PodeContentType -Extension $ext)
    $WebEvent.Response.AddHeader('Content-Disposition', "attachment; filename=$($filename)")

    # set file as an attachment on the response
    $buffer = [byte[]]::new(64 * 1024)
    $read = 0

    while (($read = $fs.Read($buffer, 0, $buffer.Length)) -gt 0) {
        $WebEvent.Response.OutputStream.Write($buffer, 0, $read)
    }

    dispose $fs
}

function Status
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNull()]
        [Alias('c')]
        [int]
        $Code,

        [Parameter()]
        [Alias('d')]
        [string]
        $Description
    )

    $WebEvent.Response.StatusCode = $Code

    if (!(Test-Empty $Description)) {
        $WebEvent.Response.StatusDescription = $Description
    }
}

function Redirect
{
    param (
        [Parameter()]
        [Alias('u')]
        [string]
        $Url,

        [Parameter()]
        [Alias('p')]
        [int]
        $Port = 0,

        [Parameter()]
        [ValidateSet('', 'HTTP', 'HTTPS')]
        [Alias('pr')]
        [string]
        $Protocol,

        [switch]
        [Alias('m')]
        $Moved
    )

    if (Test-Empty $Url) {
        $uri = $WebEvent.Request.Url

        $Protocol = $Protocol.ToLowerInvariant()
        if (Test-Empty $Protocol) {
            $Protocol = $uri.Scheme
        }

        if ($Port -le 0) {
            $Port = $uri.Port
        }

        $PortStr = [string]::Empty
        if ($Port -ne 80 -and $Port -ne 443) {
            $PortStr = ":$($Port)"
        }

        $Url = "$($Protocol)://$($uri.Host)$($PortStr)$($uri.PathAndQuery)"
    }

    $WebEvent.Response.RedirectLocation = $Url

    if ($Moved) {
        status 301 'Moved'
    }
    else {
        status 302 'Redirect'
    }
}

function Json
{
    param (
        [Parameter()]
        $Value,

        [switch]
        $File
    )

    if ($File) {
        # test the file path, and set status accordingly
        if (!(Test-PodePath $Path)) {
            return
        }
        else {
            $Value = Get-Content -Path $Value -Raw -Encoding utf8
        }
    }
    elseif (Test-Empty $Value) {
        $Value = '{}'
    }
    elseif ((Get-Type $Value).Name -ine 'string') {
        $Value = ($Value | ConvertTo-Json -Depth 10 -Compress)
    }

    Write-ToResponse -Value $Value -ContentType 'application/json; charset=utf-8'
}

function Csv
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNull()]
        $Value,

        [switch]
        $File
    )

    if ($File) {
        # test the file path, and set status accordingly
        if (!(Test-PodePath $Path)) {
            return
        }
        else {
            $Value = Get-Content -Path $Value -Raw -Encoding utf8
        }
    }
    elseif (Test-Empty $Value) {
        $Value = [string]::Empty
    }
    elseif ((Get-Type $Value).Name -ine 'string') {
        $Value = ($Value | ForEach-Object {
            New-Object psobject -Property $_
        })

        if (Test-IsPSCore) {
            $Value = ($Value | ConvertTo-Csv -Delimiter ',' -IncludeTypeInformation:$false)
        }
        else {
            $Value = ($Value | ConvertTo-Csv -Delimiter ',' -NoTypeInformation)
        }
    }

    Write-ToResponse -Value $Value -ContentType 'text/csv; charset=utf-8'
}

function Xml
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNull()]
        $Value,

        [switch]
        $File
    )

    if ($File) {
        # test the file path, and set status accordingly
        if (!(Test-PodePath $Path)) {
            return
        }
        else {
            $Value = Get-Content -Path $Value -Raw -Encoding utf8
        }
    }
    elseif (Test-Empty $value) {
        $Value = [string]::Empty
    }
    elseif ((Get-Type $Value).Name -ine 'string') {
        $Value = ($value | ForEach-Object {
            New-Object psobject -Property $_
        })

        $Value = ($Value | ConvertTo-Xml -Depth 10 -As String -NoTypeInformation)
    }

    Write-ToResponse -Value $Value -ContentType 'application/xml; charset=utf-8'
}

function Html
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNull()]
        $Value,

        [switch]
        $File
    )

    if ($File) {
        # test the file path, and set status accordingly
        if (!(Test-PodePath $Path)) {
            return
        }
        else {
            $Value = Get-Content -Path $Value -Raw -Encoding utf8
        }
    }
    elseif (Test-Empty $value) {
        $Value = [string]::Empty
    }
    elseif ((Get-Type $Value).Name -ine 'string') {
        $Value = ($Value | ConvertTo-Html)
    }

    Write-ToResponse -Value $Value -ContentType 'text/html; charset=utf-8'
}

# include helper to import the content of a view into another view
function Include
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [Alias('p')]
        [string]
        $Path,

        [Parameter()]
        [Alias('d')]
        $Data = @{}
    )

    # default data if null
    if ($null -eq $Data) {
        $Data = @{}
    }

    # add view engine extension
    $ext = Get-FileExtension -Path $Path
    $hasExt = ![string]::IsNullOrWhiteSpace($ext)
    if (!$hasExt) {
        $Path += ".$($PodeSession.Server.ViewEngine.Extension)"
    }

    # only look in the view directory
    $Path = Join-ServerRoot 'views' $Path

    # test the file path, and set status accordingly
    if (!(Test-PodePath $Path -NoStatus)) {
        throw "File not found at path: $($Path)"
    }

    # run any engine logic
    $engine = $PodeSession.Server.ViewEngine.Engine
    if ($hasExt) {
        $engine = $ext.Trim('.')
    }

    $content = [string]::Empty

    switch ($engine.ToLowerInvariant())
    {
        'html' {
            $content = Get-Content -Path $Path -Raw -Encoding utf8
        }

        'pode' {
            $content = Get-Content -Path $Path -Raw -Encoding utf8
            $content = ConvertFrom-PodeFile -Content $content -Data $Data
        }

        default {
            if ($null -ne $PodeSession.Server.ViewEngine.Script) {
                $content = (Invoke-ScriptBlock -ScriptBlock $PodeSession.Server.ViewEngine.Script -Arguments @($Path, $Data) -Return -Splat)
            }
        }
    }

    return $content
}

function View
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNull()]
        [Alias('p')]
        $Path,

        [Parameter()]
        [Alias('d')]
        $Data = @{}
    )

    # default data if null
    if ($null -eq $Data) {
        $Data = @{}
    }

    # add path to data as "pagename" - unless key already exists
    if (!$Data.ContainsKey('pagename')) {
        $Data['pagename'] = $Path
    }

    # add view engine extension
    $ext = Get-FileExtension -Path $Path
    $hasExt = ![string]::IsNullOrWhiteSpace($ext)
    if (!$hasExt) {
        $Path += ".$($PodeSession.Server.ViewEngine.Extension)"
    }

    # only look in the view directory
    $Path = Join-ServerRoot 'views' $Path

    # test the file path, and set status accordingly
    if (!(Test-PodePath $Path)) {
        return
    }

    # run any engine logic
    $engine = $PodeSession.Server.ViewEngine.Engine
    if ($hasExt) {
        $engine = $ext.Trim('.')
    }

    $content = [string]::Empty

    switch ($engine.ToLowerInvariant())
    {
        'html' {
            $content = Get-Content -Path $Path -Raw -Encoding utf8
        }

        'pode' {
            $content = Get-Content -Path $Path -Raw -Encoding utf8
            $content = ConvertFrom-PodeFile -Content $content -Data $Data
        }

        default {
            if ($null -ne $PodeSession.Server.ViewEngine.Script) {
                $content = (Invoke-ScriptBlock -ScriptBlock $PodeSession.Server.ViewEngine.Script -Arguments @($Path, $Data) -Return -Splat)
            }
        }
    }

    html -Value $content
}

function Tcp
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateSet('write', 'read')]
        [Alias('a')]
        [string]
        $Action,

        [Parameter()]
        [Alias('m')]
        [string]
        $Message,

        [Parameter()]
        [Alias('c')]
        $Client
    )

    if ($null -eq $Client) {
        $Client = $TcpEvent.Client
    }

    switch ($Action.ToLowerInvariant())
    {
        'write' {
            $stream = $Client.GetStream()
            $encoder = New-Object System.Text.ASCIIEncoding
            $buffer = $encoder.GetBytes("$($Message)`r`n")
            $stream.Write($buffer, 0, $buffer.Length)
            $stream.Flush()
        }

        'read' {
            $bytes = New-Object byte[] 8192
            $stream = $Client.GetStream()
            $encoder = New-Object System.Text.ASCIIEncoding
            $bytesRead = $stream.Read($bytes, 0, 8192)
            $message = $encoder.GetString($bytes, 0, $bytesRead)
            return $message
        }
    }
}