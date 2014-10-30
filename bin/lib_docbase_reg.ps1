<#
    Creates the registry key and entries related to the docbase
#>
function Write-DocbaseRegKey( $obj)
{
    if ($null -eq $obj)
    {
        throw "Argument obj cannot be null"
    }

    $dmp = _DumpObjAt $obj 
    Write-Verbose "Reg object=$dmp"

    if (test-path $obj.Path)
    {
        throw "The registry key $($obj.Path) already exists"
    }

    $out = New-Item -Path $obj.Path -type directory -force
    Write-Output "Reg key $out successfully created"
    foreach ($name in $obj.Keys)
    {
        $value = $obj.($name)
        $out = New-ItemProperty -Path $obj.Path -Name $name -PropertyType String -Value $value 
        Write-Output "Reg entry $name = $value successfully created"
    }    
}

<#
    Creates a new Windows service for the docbase
#>
function New-DocbaseService($obj)
{
    if ($null -eq $obj)
    {
       throw "Argument obj cannot be null"
    }

    $dmp = _DumpObjAt $obj
    Write-Verbose "Svc object dump=$dmp"
   
    if (Test-DocbaseService $obj.name)
    {
        throw "The docbase service $($obj.name) already exists"
    }   
    $out = New-Service -Name $obj.name -DisplayName $obj.display -StartupType Automatic -BinaryPathName $obj.commandLine -Credential $obj.credentials
    Write-Verbose $out
    Write-Output "Docbase service $($obj.name) successfully created."
}

<#
    Tests whether or not a new Windows service for the docbase already exists
#>
function Test-DocbaseService($name)
{
    if ($null -eq $name)
    {
        throw "Argument obj cannot be null"
    }
    $out = Get-Service -Name $name -ErrorAction SilentlyContinue -ErrorVariable svcErr
    if ($svcErr)
    {
        return $false
    }
    return $true   
}


<#
    Returns the max port number used in the \etc\services file.
#>
function Get-MaxTcpPort($Path)
{    
    $regEx = '(?i)(?<svcname>[#\w\d]+)\s*(?<svcport>[0-9]+)\/tcp'
    $text = Get-Content $Path -Raw
    [Uint16]$maxTcpPort = 0
    foreach ($m in [regex]::Matches($text, $regEx))
    {
        if ((-not $m.Groups['svcname'].Value.StartsWith('#')) -and ([uint16]::Parse($m.Groups['svcport'].Value) -gt $maxTcpPort))
        {
            $maxTcpPort = $m.Groups['svcport'].Value
        }
    }
    return $maxTcpPort
}

<#
    Tests if install owner has changed
#>
function Test-InstallOwnerChanged($cnx, $cfg)
{
    if ($cfg.env.USERNAME -eq $cfg.resolve('docbase.previous.install.name'))
    {
        $previousUser = $cfg.resolve('docbase.previous.install.name')
        $query = "SELECT user_login_domain, user_source, user_privileges FROM dm_user_s WHERE user_login_name = '$previousUser'"
        [System.Data.DataTable] $result = Select-Table -cnx $cnx -sql $query
        try
        {
            if ($result.Rows.Count -ne 1) {
                    throw "Failed to find user $previousUser in table dm_user_s"     
            }
            $row = $result.Rows[0]
            if ($row['user_privileges'] -ne 16) {
                throw "Previous install owner '$previousUser' does not appear to be a superuser"
            }                       
            if ($row['user_source'] -ne ' ')            {
                throw "Invalid user source for previous install owner: '$($row['user_source'])'"
            }
            if ($row['user_login_domain'] -ne  $cfg.env.USERDOMAIN) {
                return [InstallOwnerChanges]::None
            }
            return [InstallOwnerChanges]::Domain
        }
        finally 
        {
            $result.Dispose()
        }       
    }
    return [InstallOwnerChanges]::Name
}

<#
    Tests if user already exists in dm_user_s
#>
function Test-UserExists($cnx, $cfg)
{
    $query = "SELECT r_object_id FROM dm_user_s 
    WHERE 
    (
        (user_name = '$($cfg.env.USERNAME)') 
        OR (user_os_name = '$($cfg.env.USERNAME)') 
        OR (user_login_name = '$($cfg.env.USERNAME)') 
    )"
   
    $r = Execute-Scalar -cnx $cnx -sql $query
    if ($null -ne $r) {
        throw "User $($cfg.env.USERNAME) from domain $($cfg.env.USERDOMAIN) already exists in dm_user"
    }    
}


function Change-InstallOwner($cnx, $cfg, [InstallOwnerChanges] $scope)
{
    if ($scope -eq [InstallOwnerChanges]::None)
    {
        retun
    }

    $begin =
    "BEGIN TRAN 
    -- records previous user state ...
    SELECT * INTO dbo.mig_user FROM dbo.dm_user_s WHERE user_login_name = '$($cfg.resolve('docbase.previous.install.name'))';
    -- update the user
    UPDATE dm_user_s SET 
     user_name = '$($cfg.env.USERNAME)'
    , user_os_name = '$($cfg.env.USERNAME)'
    , user_os_domain = '$($cfg.env.USERDOMAIN)'
    , user_login_name = '$($cfg.env.USERNAME)'
    , user_login_domain = '$($cfg.env.USERDOMAIN)'
    , user_source = '' 
     , user_privileges = 16
    , user_state = 0 
    WHERE 
     user_login_name = '$($cfg.resolve('docbase.previous.install.name'))';"

    $updateObjects = 
    "-- because we updated the user_name, used as pseudo-key in dctm, we need to update many other rows ...
    UPDATE dbo.dm_sysobject_s SET 
     owner_name = '$($cfg.env.USERNAME)' 
    WHERE owner_name = '$($cfg.resolve('docbase.previous.install.name'))';

    UPDATE dbo.dm_sysobject_s SET 
     acl_domain = '$($cfg.env.USERNAME)'
    WHERE acl_domain = '$($cfg.resolve('docbase.previous.install.name'))';

    UPDATE dbo.dm_sysobject_s SET 
     r_lock_owner = '$($cfg.env.USERNAME)' 
    WHERE r_lock_owner = '$($cfg.resolve('docbase.previous.install.name'))';

    UPDATE dm_acl_s SET 
     owner_name = '$($cfg.env.USERNAME)' 
    WHERE owner_name = '$($cfg.resolve('docbase.previous.install.name'))';

    UPDATE dm_group_r SET 
     users_names = '$($cfg.env.USERNAME)' 
    WHERE users_names = '$($cfg.resolve('docbase.previous.install.name'))';
    "

    $sql = $begin
    if ($scope -eq [InstallOwnerChanges]::Name)
    {
         $sql = $sql + $updateObjects
    }
    $sql = $sql + 'COMMIT TRAN;'

    $r = Execute-NonQuery -cnx $cnx -sql $sql
}

<#
    An enumeration that represents the state of install owner changes
#>
Add-Type -TypeDefinition @"
   public enum InstallOwnerChanges
   {
      None = 0,
      Domain = 1,
      Name = 2,
   }
"@