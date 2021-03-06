function Auth
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateSet('use', 'check')]
        [Alias('a')]
        [string]
        $Action,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [Alias('n')]
        [string]
        $Name,

        [Parameter()]
        [Alias('v')]
        [scriptblock]
        $Validator,

        [Parameter()]
        [Alias('p')]
        [scriptblock]
        $Parser,

        [Parameter()]
        [Alias('o')]
        [hashtable]
        $Options,

        [switch]
        [Alias('c')]
        $Custom
    )

    if ($Action -ieq 'use') {
        if (Test-Empty $Validator) {
            throw "Authentication method '$($Name)' is missing required Validator script"
        }

        if ($Custom -and (Test-Empty $Parser)) {
            throw "Custom authentication method '$($Name)' is missing required Parser script"
        }
    }

    switch ($Action.ToLowerInvariant())
    {
        'use' {
            Invoke-AuthUse -Name $Name -Validator $Validator -Parser $Parser -Options $Options
        }

        'check' {
            return (Invoke-AuthCheck -Name $Name -Options $Options)
        }
    }
}

function Invoke-AuthUse
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Name,

        [Parameter(Mandatory=$true)]
        [scriptblock]
        $Validator,

        [Parameter()]
        [scriptblock]
        $Parser,

        [Parameter()]
        [hashtable]
        $Options,

        [switch]
        $Custom
    )

    # get the auth data
    $AuthData = (Get-PodeAuthMethod -Name $Name -Validator $Validator -Parser $Parser -Custom:$Custom)

    # ensure the name doesn't already exist
    if ($PodeSession.Server.Authentications.ContainsKey($AuthData.Name)) {
        throw "Authentication method '$($AuthData.Name)' already defined"
    }

    # ensure the parser/validators aren't just empty scriptblocks
    if (Test-Empty $AuthData.Parser) {
        throw "Authentication method '$($AuthData.Name)' is has no Parser ScriptBlock logic defined"
    }

    if (Test-Empty $AuthData.Validator) {
        throw "Authentication method '$($AuthData.Name)' is has no Validator ScriptBlock logic defined"
    }

    # setup object for auth method
    $obj = @{
        'Options' = $Options;
        'Parser' = $AuthData.Parser;
        'Validator' = $AuthData.Validator;
        'Custom' = $AuthData.Custom;
    }

    # apply auth method to session
    $PodeSession.Server.Authentications[$AuthData.Name] = $obj
}

function Invoke-AuthCheck
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Name,

        [Parameter()]
        [hashtable]
        $Options
    )

    # ensure the auth type exists
    if (!$PodeSession.Server.Authentications.ContainsKey($Name)) {
        throw "Authentication method '$($Name)' is not defined"
    }

    # coalesce the options, and set auth type for middleware
    $Options = (coalesce $Options @{})
    $Options.AuthType = $Name

    # setup the middleware logic
    $logic = {
        param($s)

        # Route options for using sessions
        $storeInSession = ($s.Middleware.Options.Session -ne $false)
        $usingSessions = (!(Test-Empty $s.Session))

        # check for logout command
        if ($s.Middleware.Options.Logout -eq $true) {
            Remove-PodeAuth -Session $s
            return (Set-PodeAuthStatus -StatusCode 302 -Options $s.Middleware.Options)
        }

        # if the session already has a user/isAuth'd, then setup method and return
        if ($usingSessions -and !(Test-Empty $s.Session.Data.Auth.User) -and $s.Session.Data.Auth.IsAuthenticated) {
            $s.Auth = $s.Session.Data.Auth
            return (Set-PodeAuthStatus -Options $s.Middleware.Options)
        }

        # check if the login flag is set, in which case just return
        if ($s.Middleware.Options.Login -eq $true) {
            Remove-PodeSessionCookie -Response $s.Response -Session $s.Session
            return $true
        }

        # get the auth type
        $auth = $PodeSession.Server.Authentications[$s.Middleware.Options.AuthType]

        # validate the request and get a user
        try {
            # if it's a custom type the parser will return the dat for use to pass to the validator
            if ($auth.Custom) {
                $data = (Invoke-ScriptBlock -ScriptBlock $auth.Parser -Arguments @($s, $auth.Options) -Return -Splat)
                $result = (Invoke-ScriptBlock -ScriptBlock $auth.Validator -Arguments $data -Return -Splat)
            }
            else {
                $result = (Invoke-ScriptBlock -ScriptBlock $auth.Parser -Arguments @($s, $auth) -Return -Splat)
            }
        }
        catch {
            $_.Exception | Out-Default
            return (Set-PodeAuthStatus -StatusCode 500 -Options $s.Middleware.Options)
        }

        # if there is no result return false (failed auth)
        if ((Test-Empty $result) -or (Test-Empty $result.User)) {
            return (Set-PodeAuthStatus -StatusCode (coalesce $result.Code 401) `
                -Description $result.Message -Options $s.Middleware.Options)
        }

        # assign the user to the session, and wire up a quick method
        $s.Auth = @{}
        $s.Auth.User = $result.User
        $s.Auth.IsAuthenticated = $true
        $s.Auth.Store = $storeInSession

        # continue
        return (Set-PodeAuthStatus -Options $s.Middleware.Options)
    }

    # return the middleware
    return @{
        'Logic' = $logic;
        'Options' = $Options;
    }
}

function Get-PodeAuthMethod
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Name,

        [Parameter(Mandatory=$true)]
        [scriptblock]
        $Validator,

        [Parameter()]
        [scriptblock]
        $Parser,

        [switch]
        $Custom
    )

    # first, is it just a custom type?
    if ($Custom) {
        return @{
            'Name' = $Name;
            'Custom' = $true;
            'Parser' = $Parser;
            'Validator' = $Validator;
        }
    }

    # otherwise, check the inbuilt ones
    switch ($Name.ToLowerInvariant())
    {
        'basic' {
            return (Get-PodeAuthBasic -ScriptBlock $Validator)
        }

        'form' {
            return (Get-PodeAuthForm -ScriptBlock $Validator)
        }
    }

    # if we get here, check if a parser was passed for custom type
    if (Test-Empty $Parser) {
        throw "Authentication method '$($Name)' does not exist as an inbuilt type, nor has a Parser been passed for a custom type"
    }

    # a parser was passed, so it is a custom type
    return @{
        'Name' = $Name;
        'Custom' = $true;
        'Parser' = $Parser;
        'Validator' = $Validator;
    }
}

function Remove-PodeAuth
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNull()]
        $Session
    )

    # blank out the auth
    $Session.Auth = @{}

    # if a session auth is found, blank it
    if (!(Test-Empty $Session.Session.Data.Auth)) {
        $Session.Session.Data.Remove('Auth')
    }

    # redirect to a failure url, or onto the current path?
    if (Test-Empty $Session.Middleware.Options.FailureUrl) {
        $Session.Middleware.Options.FailureUrl = $Session.Request.Url.AbsolutePath
    }

    # Delete the session (remove from store, blank it, and remove from Response)
    Remove-PodeSessionCookie -Response $Session.Response -Session $Session.Session
}

function Set-PodeAuthStatus
{
    param (
        [Parameter()]
        [int]
        $StatusCode = 0,

        [Parameter()]
        [string]
        $Description,

        [Parameter()]
        [hashtable]
        $Options
    )

    # if a statuscode supplied, assume failure
    if ($StatusCode -gt 0)
    {
        # check if we have a failure url redirect
        if (!(Test-Empty $Options.FailureUrl)) {
            redirect $Options.FailureUrl
        }
        else {
            status $StatusCode $Description
        }

        return $false
    }

    # if no statuscode, success
    else
    {
        # check if we have a success url redirect
        if (!(Test-Empty $Options.SuccessUrl)) {
            redirect $Options.SuccessUrl
            return $false
        }

        return $true
    }
}

function Get-PodeAuthBasic
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNull()]
        [scriptblock]
        $ScriptBlock
    )

    $parser = {
        param($s, $auth)

        # get the auth header
        $header = $s.Request.Headers['Authorization']
        if ($null -eq $header) {
            return @{
                'User' = $null;
                'Message' = 'No Authorization header found';
                'Code' = 401;
            }
        }

        # ensure the first atom is basic (or opt override)
        $atoms = $header -isplit '\s+'
        $authType = (coalesce $auth.Options.Name 'Basic')

        if ($atoms[0] -ine $authType) {
            return @{
                'User' = $null;
                'Message' = "Header is not $($authType) Authorization";
            }
        }

        # decode the aut header
        $encType = (coalesce $auth.Options.Encoding 'ISO-8859-1')

        try {
            $enc = [System.Text.Encoding]::GetEncoding($encType)
        }
        catch {
            return @{
                'User' = $null;
                'Message' = 'Invalid encoding specified for Authorization';
                'Code' = 400;
            }
        }

        try {
            $decoded = $enc.GetString([System.Convert]::FromBase64String($atoms[1]))
        }
        catch {
            return @{
                'User' = $null;
                'Message' = 'Invalid Base64 string found in Authorization header';
                'Code' = 400;
            }
        }

        # validate and return user/result
        $index = $decoded.IndexOf(':')
        $u = $decoded.Substring(0, $index)
        $p = $decoded.Substring($index + 1)

        return (Invoke-ScriptBlock -ScriptBlock $auth.Validator -Arguments @($u, $p) -Return -Splat)
    }

    return @{
        'Name' = 'Basic';
        'Custom' = $false;
        'Parser' = $parser;
        'Validator' = $ScriptBlock;
    }
}

function Get-PodeAuthForm
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNull()]
        [scriptblock]
        $ScriptBlock
    )

    $parser = {
        param($s, $auth)

        # get user/pass keys to get from payload
        $userField = (coalesce $auth.Options.UsernameField 'username')
        $passField = (coalesce $auth.Options.PasswordField 'password')

        # get the user/pass
        $username = $s.Data.$userField
        $password = $s.Data.$passField

        # if either are empty, deny
        if ((Test-Empty $username) -or (Test-Empty $password)) {
            return @{
                'User' = $null;
                'Message' = 'Username or Password not supplied';
                'Code' = 401;
            }
        }

        # validate and return
        return (Invoke-ScriptBlock -ScriptBlock $auth.Validator -Arguments @($username, $password) -Return -Splat)
    }

    return @{
        'Name' = 'Form';
        'Custom' = $false;
        'Parser' = $parser;
        'Validator' = $ScriptBlock;
    }
}