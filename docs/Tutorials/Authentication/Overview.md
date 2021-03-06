# Authentication Overview

Authentication can either be sessionless (requiring validation on every request), or session-persistent (only requiring validation once, and then checks against a session signed-cookie).

!!! info
    To use session-persistent authentication you will also need to use [`session`](../../../Functions/Middleware/Sessions) middleware.

To setup and use authentication in Pode you need to use the [`auth`](../../../Functions/Middleware/Auth) function and middleware. The `auth` function has two actions: `use` and `check` which are detailed below:

## Actions

### Use

The `auth use` action allows you to specify and configure which authentication methods your server will use; you can have many methods configured, defining which one to validate against on the `auth check` action.

The make-up of the `use` action is:

```powershell
auth use <name> -validator {} [-options @{}] [-parser {}] [-custom]

# or shorthand:
auth use <name> -v {} [-o @{}] [-p {}] [-c]
```

A quick example of using the `use` action for Basic authentication is as follows:

```powershell
Server {
    auth use basic -v {
        param($username, $pass)
        # logic to check user
        return @{ 'user' = $user }
    }
}
```

The `<name>` of the authentication method specified should be a valid inbuilt method (such as Basic or Form), unless you have stated that the method is custom (`-c`).

The validator (`-v`) script is used to find a user, checking if they exist and the password is correct (or checking if they exist in some data store). If the validator passes, then a `user` needs to be returned from the script via `@{ 'user' = $user }` - if `$null` or a null user is returned then the validator script is assumed to have failed.

Some auth methods also have options (`-o`) that can be supplied as a hashtable, such as field name or encoding overrides. Available options will vary between authentication methods, and can be seen on their tutorial pages, such as [`Basic`](../Basic).

If a custom (`-c`) authentication method is used, you *must* supply a parser (`-p`) script which will parse payloads/headers for credentials and then return this data as an array - which will then be supplied to the validator (`-v`) script.

### Check

The `auth check` action allows you to define which authentication method to validate a request against. The action returns a valid middleware script, meaning you can either use this action on specific `route` definitions, or globally for all routes as `middleware`. If this action fails, then a 401 response is returned.

The make-up of the `check` action is:

```powershell
auth check <name> [-options @{}]

# or shorthand:
auth check <name> [-o @{}]
```

A quick example of using the `check` action against Basic authentication is as follows. The first example sets up the `check` as global middleware, whereas the second example sets up the `check` as custom [`route`](../../../Functions/Core/Route) middleware:

```powershell
Server {
    # 1. apply the auth check as global middleware
    middleware (auth check basic)

    # 2. or, apply auth check as custom route middleware
    route get '/users' (auth check basic) {
        # route logic
    }
}
```

On success, this action will then allow the `route` logic to be invoked. If [`session`](../../../Functions/Middleware/Session) [`middleware`](../../../Functions/Core/Middleware) has been configured then an authenticated session is also created for future requests, using a signed session-cookie.

When the user makes another call using the same authenticated session and that cookie is passed, then the `auth check` action will detect the already authenticated session and skip the validator script. If you're using sessions and you don't want the `auth check` to check the session, or store the user against the session, then pass `-o @{ 'Session' = $false }` to the `auth check` call.

## Check Parameters

The following table contains options that you can supply to an `auth check -o @{}` call - these are all optional:

| Name | Description | Default |
| ---- | ----------- | ------- |
| FailureUrl | The URL to redirect to should authentication fail | empty |
| SuccessUrl | The URL to redirect to should authenticationh succeed | empty |
| Session | If true, check if the session already has an authenticated user; storing the user in the session if they are authenticated | true |
| Login | If true, check the authentication status in the session and redirect to the SuccessUrl if the user is authenticated. Otherwise proceed to the page with no authentication required | false |
| Logout | If true, purge the session and redirect to the FailureUrl | false |

!!! info
    The `Login` option allows you to have authentication on your login pages, such that if there is no user in a current session then the login page displays - rather then being 401'd. Whereas if there is an authenticated user in the session it will auto-redirect to the `SuccessUrl`.