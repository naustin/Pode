$path = Split-Path -Parent -Path (Split-Path -Parent -Path $MyInvocation.MyCommand.Path)
Import-Module "$($path)/src/Pode.psm1" -Force -ErrorAction Stop

# or just:
# Import-Module Pode

# create a server, and start listening on port 8085
Server -Threads 2 {

    # listen on localhost:8085
    listen *:8085 http

    # log requests to the terminal
    logger terminal

    # import the EPS module to each runspace
    import eps

    # set view engine to EPS renderer
    engine eps {
        param($path, $data)

        if ($null -eq $data) {
            return (Invoke-EpsTemplate -Path $path)
        }
        else {
            return (Invoke-EpsTemplate -Path $path -Binding $data)
        }
    }

    # GET request for web page on "localhost:8085/"
    route 'get' '/' {
        view 'index' -Data @{ 'numbers' = @(1, 2, 3); 'date' = [DateTime]::UtcNow; }
    }

} -FileMonitor