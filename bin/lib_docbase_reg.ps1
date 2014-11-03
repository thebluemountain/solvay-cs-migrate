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

<#
    Changes the reference to the user name and domain of the install owner in the DB.
#>
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
    Updates the server.ini file with docbroker data located in the migrate.properties file.
#>
function Update-Docbrokers($cfg)
{
    $docbrokers = $cfg.docbase.docbrokers
    foreach($i in $docbrokers.Keys)
    {       
        $db = $docbrokers.($i)    
        $section = "DOCBROKER_PROJECTION_TARGET"
        if  ($i -gt 0)
        {
            $section = $section + "_$i"
        }       
        [iniFile]::WriteValue("$dctmCfgPath\server.ini", $section, "host", $db.host)  
        [iniFile]::WriteValue("$dctmCfgPath\server.ini", $section, "port", $db.port)  

        Write-Output "Updated Docbroker $i host= $($db.host) port= $($db.port)"
    }
}

function Test-LocationMigrated($cnx)
{
    $r = Execute-Scalar -cnx $cnx -sql 'SELECT COUNT(*) FROM dbo.mig_locations'
    if ($null -ne $r) {
        throw "Migration of dm_locations has been attempted before"
    }    
}

<#
    Checks that all used stores are defined and point to a valid path
#> 
function Check-Locations($cnx, $cfg)
{  
    $query = '
        SELECT l.object_name
        FROM dbo.dmr_content_s c, dbo.dm_filestore_sv f, dbo.dm_location_sv l 
        WHERE 
            f.r_object_id = c.storage_id AND f.root = l.object_name 
        GROUP BY l.object_name;'

    [System.Data.DataTable] $result = Select-Table -cnx $cnx -sql $query
    try
    {
        if ($result.Rows.Count -ne 1) {
            throw "Could not indentify and filestore currently in use!"  
        }   

        if (-not $cfg.ContainsKey('location')) {
            throw 'No entries for file store mapping defined in migrate.properties'
        }

        # for each name, there MUST be an entry of the form: cfg.location.${object_name}
        foreach ($r in $result.Rows)
        {
            $loc = $r['object_name']                
            if (-not $cfg.location.ContainsKey($loc)) {
                throw "No entry in migrate.properties for location $loc)"  
            }                    
            Write-Verbose "Entry for location $loc found"                               
        }
    }
    finally 
    {
        $result.Dispose()
    }

    $sql = 'SELECT object_name FROM dm_location_sv WHERE object_name IN (SELECT root FROM dm_filestore_s)'
    [System.Data.DataTable]$result = Select-Table -cnx $cnx -sql $sql
    try
    {
        foreach ($loc in $cfg.location.Keys)
        {
            $a = $result.Select("object_name = '$loc'")
            if ($a.Length -le 0) {
                throw "Location $loc is not in the list of defined dm_location_s of use by a file store"
            }                         

            $hid = docbaseIdAsHex($cfg.resolve('docbase.id'))
            $fsPath = $cfg.location.($loc) + '\' + $hid 

            if (-not (Test-Path($fsPath))) {
                throw "The path defined for location $ is invalid:  $fsPath)"
            }

            Write-Verbose "Valid location $loc found, path = $fsPath)"   
        }           
    
    }
    finally
    {
        $result.Dispose()
    }
}

<#
    Updates locations in the database
#>
function Update-Locations($cnx, $cfg)
{
    $sql =  "BEGIN TRAN;"   
    foreach ($loc in $cfg.location.Keys)
    {
        $sql = $sql +
            "SELECT * INTO dbo.mig_locations FROM dm_location_s 
            WHERE r_object_id IN (SELECT r_object_id FROM dm_location_sv WHERE object_name = '$loc');
            UPDATE dm_location_s SET file_system_path = '$($cfg.location.($loc))' 
            WHERE r_object_id IN (SELECT r_object_id FROM dm_location_sv WHERE object_name = '$loc');"
    }
    $sql = $sql + 'COMMIT TRAN;'

    Execute-NonQuery -cnx $cnx -sql $sql | Out-Null
    Write-Output 'Successfully updated locations' 
}

<#
    Convert the docbase id as a uint value in hex, padded to 8 leading zeroes
#>
function docbaseIdAsHex([Int]$id){

    if ($id -gt [Uint32]::MaxValue) {
        throw "Invalid docbase id $id"
    }

    return [Uint32]::Parse($id).ToString("X8")
}

<#
    Disables all jobs
#>
function Disable-Jobs($cnx, $cfg)
{
    $sql = 'BEGIN TRAN
    SELECT r_object_id INTO dbo.mig_active_jobs FROM dm_job_s WHERE is_inactive = 0;
    UPDATE dm_job_s SET is_inactive = 1 WHERE is_inactive = 0;
    COMMIT TRAN;'
    
    Execute-NonQuery -cnx $cnx -sql $sql | Out-Null
    Write-Output "Jobs successfully disabled"
}

<#
    Fixes mount points
#>
function Fix-MountPoint($cnx, $cfg)
{
    $sql = "
    BEGIN TRAN
    UPDATE dbo.dm_mount_point_s SET host_name = '$($cfg.resolve('env.COMPUTERNAME'))'
    UPDATE dbo.dm_mount_point_s SET file_system_path = '$($cfg.resolve('env.documentum'))\share' 
     WHERE r_object_id IN (SELECT r_object_id FROM dm_mount_point_sv WHERE object_name = 'share')
    COMMIT TRAN"

    Execute-NonQuery -cnx $cnx -sql $sql | Out-Null
    Write-Output "Mount points successfully fixed"
}

function Fix-DmLocations($cnx, $cfg)
{
    $sql = "
    UPDATE dm_location_s SET 
     file_system_path = '$($cfg.resolve('env.dm_home'))convert'
    WHERE r_object_id IN (SELECT r_object_id FROM dm_location_sv WHERE object_name = 'convert'); 
 
    UPDATE dm_location_s SET 
     file_system_path = '$($cfg.resolve('env.dm_home'))\install\external_apps\nls_chartrans'
    WHERE r_object_id IN (SELECT r_object_id FROM dm_location_sv WHERE object_name = 'nls_chartrans');"
      
    Execute-NonQuery -cnx $cnx -sql $sql | Out-Null
    Write-Output "Dm locations successfully fixed"

}





function New-MigrationTables($cnx)
{
    $sql = 
    'CREATE TABLE dbo.mig_active_jobs (
        r_object_id nchar(16) NOT NULL
     )
            
     CREATE TABLE dbo.mig_user(
        r_object_id nchar(16) NOT NULL,
        user_name nvarchar(32) NOT NULL,
        user_os_name nvarchar(32) NOT NULL,
        user_address nvarchar(80) NOT NULL,
        user_group_name nvarchar(32) NOT NULL,
        user_privileges int NOT NULL,
        owner_def_permit int NOT NULL,
        world_def_permit int NOT NULL,
        group_def_permit int NOT NULL,
        default_folder nvarchar(200) NOT NULL,
        r_is_group smallint NOT NULL,
        user_db_name nvarchar(32) NOT NULL,
        description nvarchar(255) NOT NULL,
        acl_domain nvarchar(32) NOT NULL,
        acl_name nvarchar(32) NOT NULL,
        user_os_domain nvarchar(16) NOT NULL,
        home_docbase nvarchar(120) NOT NULL,
        user_state int NOT NULL,
        client_capability int NOT NULL,
        globally_managed smallint NOT NULL,
        r_modify_date datetime NOT NULL,
        user_delegation nvarchar(32) NOT NULL,
        workflow_disabled smallint NOT NULL,
        alias_set_id nchar(16) NOT NULL,
        user_source nvarchar(16) NOT NULL,
        user_ldap_dn nvarchar(255) NOT NULL,
        user_xprivileges int NOT NULL,
        r_has_events smallint NOT NULL,
        failed_auth_attempt int NOT NULL,
        user_admin nvarchar(32) NOT NULL,
        user_global_unique_id nvarchar(255) NOT NULL,
        user_login_name nvarchar(80) NOT NULL,
        user_login_domain nvarchar(255) NOT NULL,
        user_initials nvarchar(16) NOT NULL,
        user_password nvarchar(256) NOT NULL,
        user_web_page nvarchar(255) NOT NULL,
        first_failed_auth_utc_time datetime NOT NULL,
        last_login_utc_time datetime NOT NULL,
        deactivated_utc_time datetime NOT NULL,
        deactivated_ip_addr nvarchar(64) NOT NULL,
        i_is_replica smallint NOT NULL,
        i_vstamp int NOT NULL
    )

    CREATE TABLE dbo.mig_locations(
	    r_object_id nchar(16) NOT NULL,
	    mount_point_name nvarchar(32) NOT NULL,
	    path_type nvarchar(16) NOT NULL,
	    file_system_path nvarchar(255) NOT NULL,
	    security_type nvarchar(32) NOT NULL,
	    no_validation smallint NOT NULL
    )
    
    CREATE TABLE dbo.mig_indexes (
        table_name nvarchar(128) NOT NULL,
        index_name nvarchar(128) NOT NULL,
        ddl nvarchar(4000) NOT NULL
    )
    CREATE UNIQUE NONCLUSTERED INDEX mig_indexes_key 
    ON dbo.mig_indexes (table_name, index_name)'

    Execute-NonQuery -cnx $cnx -sql $sql | Out-Null
    Write-Output "Migration tables created"
}

function Test-MigrationTables($cnx)
{
    $sql = "IF (EXISTS (SELECT * 
                 FROM INFORMATION_SCHEMA.TABLES 
                 WHERE TABLE_SCHEMA = 'dbo' 
                 AND  (
                    TABLE_NAME = 'mig_active_jobs'
                    OR TABLE_NAME = 'mig_user'
                    OR TABLE_NAME = 'mig_indexes' 
                    OR TABLE_NAME = 'mig_locations'
                   )))
            SELECT 1 AS res ELSE SELECT 0 AS res;"

    $r = Execute-Scalar -cnx $cnx -sql $sql
    if ($sql -eq 1) {
        return $true
    }
    return $false
}

function Remove-MigrationTables($cnx)
{
    $sql = "DROP TABLE 'dbo.mig_active_jobs',
                       'dbo.mig_user',
                       'dbo.mig_indexes',
                       'mig_locations'"

    Execute-NonQuery -cnx $cnx -sql $sql | Out-Null       
    Write-Output "Migration tables deleted"
}


