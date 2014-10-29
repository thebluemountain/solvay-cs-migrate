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


function Test-InstallOwnerChanged($cfg)
{
    if ($cfg.env.USERNAME -eq $cfg.resolve('docbase.previous.install.name'))
    {
        $cnx = New-Connection $cfg.ToDbConnectionString()
        try
        {
            $previousUser = $cfg.resolve('docbase.previous.install.name')
            $query = "SELECT user_login_domain, user_source, user_privileges FROM dm_user_s WHERE user_login_name = '$previousUser'"
            [System.Data.DataTable] $result = Select-Table -cnx $cnx -sql $query
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
            $cnx.close()
        }
    }
    return [InstallOwnerChanges]::Name
}

Add-Type -TypeDefinition "
   public enum InstallOwnerChanges
   {
      None,
      Name,
      Domain,
   }
"