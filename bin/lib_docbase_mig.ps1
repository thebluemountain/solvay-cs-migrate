# loading the assembly
try
{
    Add-Type -AssemblyName 'Microsoft.SqlServer.Smo'
}
catch
{
    Add-Type -AssemblyName 'Microsoft.SqlServer.Smo, Version=10.0.0.0, Culture=neutral, PublicKeyToken=89845dcd8080cc91'
}

try
{
    Add-Type -AssemblyName 'Microsoft.SqlServer.ConnectionInfo'
}
catch
{
    Add-Type -AssemblyName 'Microsoft.SqlServer.ConnectionInfo, Version=10.0.0.0, Culture=neutral, PublicKeyToken=89845dcd8080cc91'
}

<#
    Creates the registry key and entries related to the docbase
    As the 'path' key in the object holds special meaning, its content
    is not copied
#>
function Write-DocbaseRegKey( $obj)
{
    if ($null -eq $obj)
    {
        throw "Argument obj cannot be null"
    }

    $dmp = _DumpObjAt $obj
    Log-Verbose "Reg object=$dmp"

    if (test-path $obj.Path)
    {
        throw "The registry key $($obj.Path) already exists"
    }

    $out = New-Item -Path $obj.Path -type directory -force
    Log-Info "Reg key $out successfully created"
    foreach ($name in $obj.Keys)
    {
        if ('path' -ne $name.ToLower())
        {
            $value = $obj.($name)
            $out = New-ItemProperty -Path $obj.Path -Name $name -PropertyType String -Value $value
            Log-Verbose "Reg entry $name = $value successfully created"
        }
    }
    Log-Info 'registry configuration successfully created'
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

    if (Test-DocbaseService $obj.name)
    {
        throw "The docbase service $($obj.name) already exists"
    }
    $out = New-Service -Name $obj.name -DisplayName $obj.display -StartupType Automatic -BinaryPathName $obj.commandLine -Credential $obj.credentials
    Log-Verbose $out
    Log-Info "Docbase service $($obj.name) successfully created."
}


<#
    Creates initialization files 
#> 
function Create-IniFiles($cfg)
{
    $inipath = $cfg.resolve('docbase.config_folder')
    $ini = $cfg.resolve('docbase.daemon.ini')
    New-Item -Path $inipath -ItemType "directory" -Force | Out-Null
    Copy-Item -Path $cfg.resolve('file.server_ini') -Destination $ini | Out-Null
    Log-Verbose ('server.ini file successfully created in ' + $inipath)

    Copy-Item -Path $cfg.resolve('file.dbpasswd_txt') -Destination ($inipath + '\dbpasswd.txt') | Out-Null
    Log-Verbose ('dbpasswd.txt file successfully copied into ' + $inipath)
    New-Item -Path $inipath -name dbpasswd.tmp.txt -itemtype "file" -value $cfg.resolve('docbase.pwd') | Out-Null
    Log-Verbose ('dbpasswd.tmp.txt file successfully created in ' + $inipath)

    Copy-Item -Path "$($cfg.file.config_folder)\*.cnt" -Destination $inipath | Out-Null
    Log-Verbose ('copied .cnt files into ' + $inipath)

    # updating the server.ini file
    [iniFile]::WriteValue($ini, 'SERVER_STARTUP', 'database_password_file', "$inipath\dbpasswd.tmp.txt")
    [iniFile]::WriteValue($ini, 'SERVER_STARTUP', 'install_owner', $cfg.resolve('user.name'))
    [iniFile]::WriteValue($ini, 'SERVER_STARTUP', 'user_auth_target', $cfg.resolve('docbase.auth'))
    [iniFile]::WriteValue($ini, 'SERVER_STARTUP', 'database_name', $cfg.resolve('docbase.database'))
    [iniFile]::WriteValue($ini, 'SERVER_STARTUP', 'database_conn', $cfg.resolve('docbase.dsn'))
    [iniFile]::WriteValue($ini, 'SERVER_STARTUP', 'database_owner', $cfg.resolve('docbase.user'))
    [iniFile]::WriteValue($ini, 'SERVER_STARTUP', 'start_index_agents', 'F')
    Log-Verbose ('configured the server.ini file')

    Log-Info ("initialization files successfully created in $inipath")
}


<#
    Updates service files
#>
function Update-ServiceFile($cfg)
{
    $etcServicesFile = $cfg.resolve('file.services')
    [uint16] $maxTcpPort = Get-MaxTcpPort  -Path $etcServicesFile
    if ($maxTcpPort -eq [uint16]::MaxValue-1)
    {
        throw "Max tcp port number already used in services file"
    }
    add-Content -Path $etcServicesFile -Value "$($cfg.resolve('docbase.service'))    $($maxTcpPort + 1)/tcp   # $($cfg.resolve('docbase.daemon.display'))" | Out-Null
    add-Content -Path $etcServicesFile -Value "$($cfg.resolve('docbase.service'))_s  $($maxTcpPort + 2)/tcp   # $($cfg.resolve('docbase.daemon.display')) (secure)" | Out-Null

    Log-Info("$etcServicesFile successfully updated")
}

<#
    Updates the list of installed docbase
#>
function Update-DocbaseList($cfg)
{
    $dm_dctm_cfg = $cfg.resolve('env.documentum') + '\dba\dm_documentum_config.txt'
    if (-not( Test-Path -Path  $dm_dctm_cfg))
    {
        throw "$dm_dctm_cfg does not exists"
    }
    $section = "DOCBASE_$($cfg.resolve('docbase.name'))"
    [iniFile]::WriteValue($dm_dctm_cfg,  $section, "NAME", $cfg.resolve('docbase.name'))
    [iniFile]::WriteValue($dm_dctm_cfg,  $section, "VERSION", $cfg.resolve('docbase.previous.version'))
    [iniFile]::WriteValue($dm_dctm_cfg,  $section, "DATABASE_CONN", $cfg.resolve('docbase.dsn'))
    [iniFile]::WriteValue($dm_dctm_cfg,  $section, "DATABASE_NAME", $cfg.resolve('docbase.database'))

    Log-Info("List of installed docbase successfully updated in $dm_dctm_cfg")
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
   [System.FlagsAttribute]
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
    $previousUser = $cfg.resolve('docbase.previous.name')
    $query = "SELECT user_login_domain, user_source, user_privileges FROM dm_user_s WHERE user_login_name = '$previousUser'"
    [System.Data.DataTable] $result = Select-Table -cnx $cnx -sql $query
    try
    {
        # NB: [InstallOwnerChanges] is an enumeration with that can be used as a bit field
        # changes initialized to 'None'
        $changes = [InstallOwnerChanges]::None

        # Check proposed install owner validity
        if ($result.Rows.Count -eq 0)
        {
            throw "Failed to find user $previousUser in table dm_user_s"
        }
        $row = $result.Rows[0]
        if ($row['user_privileges'] -ne 16)
        {
            throw "Previous install owner '$previousUser' does not appear to be a superuser"
        }
        if ($row['user_source'] -ne ' ')
        {
            throw "Invalid user source for previous install owner: '$($row['user_source'])'"
        }
         # Has user changed ?
        if ($cfg.resolve('user.name') -ne $cfg.resolve('docbase.previous.name'))
        {
             $changes =  $changes -bor [InstallOwnerChanges]::Name
        }
        if ($row['user_login_domain'] -ne $cfg.resolve('user.domain'))
        {
            $changes =  $changes -bor [InstallOwnerChanges]::Domain
        }
        return $changes
    }
    finally
    {
        $result.Dispose()
    }
}

<#
    Tests if user already exists in dm_user_s
#>
function Test-UserExists($cnx, $cfg)
{
    $newUserName = $($cfg.resolve('user.name'))
    $query = "SELECT r_object_id FROM dm_user_s 
    WHERE 
    (
        (user_name = '$newUserName') 
        OR (user_os_name = '$newUserName') 
        OR (user_login_name = '$newUserName') 
    )"

    $r = Execute-Scalar -cnx $cnx -sql $query
    if ($null -ne $r)
    {
        throw "User $newUserName already exists in dm_user"
    }
}

<#
    Changes the reference to the user name and domain of the install owner in the DB.
#>
function Change-InstallOwner($cnx, $cfg, [InstallOwnerChanges] $scope)
{
    $previousUserName = $($cfg.resolve('docbase.previous.name'))
    $newUserName = $($cfg.resolve('user.name'))
    $newUserDomain = $($cfg.resolve('user.domain'))

    $sql =
    "BEGIN TRAN 
    -- records previous user state ...
    SELECT * INTO dbo.mig_user FROM dbo.dm_user_s WHERE user_login_name = '$previousUserName';
    -- update the user
    UPDATE dm_user_s SET 
        user_name = '$newUserName',
        user_os_name = '$newUserName',
        user_os_domain = '$newUserDomain',
        user_login_name = '$newUserName',
        user_login_domain = '$newUserDomain',
        user_source = ' ',
        user_privileges = 16,
        user_state = 0 
    WHERE 
        user_login_name = '$previousUserName';
        "

    if ($scope -band [InstallOwnerChanges]::Name)
    {
        $sql = $sql + 
        "-- because we updated the user_name, used as pseudo-key in dctm, we need to update many other rows ...
        UPDATE dbo.dm_sysobject_s SET 
            owner_name = '$newUserName' 
        WHERE owner_name = '$previousUserName';

        UPDATE dbo.dm_sysobject_s SET 
            acl_domain = '$newUserName'
        WHERE acl_domain = '$previousUserName';

        UPDATE dbo.dm_sysobject_s SET 
            r_lock_owner = '$newUserName' 
        WHERE r_lock_owner = '$previousUserName';

        UPDATE dm_acl_s SET 
            owner_name = '$newUserName' 
        WHERE owner_name = '$previousUserName';

        UPDATE dm_group_r SET 
            users_names = '$newUserName' 
        WHERE users_names = '$previousUserName)';
        "
    }
    $sql = $sql + 'COMMIT TRAN;'

    $r = Execute-NonQuery -cnx $cnx -sql $sql
    Log-Info "Install owner successfully changed from $previousUserName to $newUserDomain\$newUserName"
}

<#
    Updates the server.ini file with docbroker data located in the migrate.properties file.
#>
function Update-Docbrokers($cfg)
{
    $iniPath = $cfg.resolve('docbase.daemon.ini')
    $docbrokers = $cfg.docbase.docbrokers
    foreach($i in $docbrokers.Keys)
    {
        $section = "DOCBROKER_PROJECTION_TARGET"
        if  ($i -gt 0)
        {
            $section = $section + "_$i"
        }
        $hostname = $cfg.resolve('docbase.docbrokers.' + $i + '.host')
        $port = $cfg.resolve('docbase.docbrokers.' + $i + '.port')
        [iniFile]::WriteValue($iniPath, $section, "host", $hostname)
        [iniFile]::WriteValue($iniPath, $section, "port", $port)

        Log-Verbose "Updated Docbroker $i host= $hostname port= $port"
    }
    Log-Info 'Updated docbrokers'
}

function Test-LocationMigrated($cnx)
{
    $r = Execute-Scalar -cnx $cnx -sql 'SELECT COUNT(*) FROM dbo.mig_locations'
    if ($null -ne $r)
    {
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
        if ($result.Rows.Count -eq 0)
        {
            throw 'Could not identify any filestore currently in use!'
        }

        # for each name, there MUST be an entry of the form: cfg.location.${object_name}
        foreach ($r in $result.Rows)
        {
            $loc = $r['object_name']
            if (-not $cfg.location.ContainsKey($loc))
            {
                throw "No entry in migrate.properties for location $loc)"
            }
            Log-Verbose "Entry for location $loc found"
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
            if ($a.Length -eq 0)
            {
                throw "Location $loc is not in the list of defined dm_location_s of use by a file store"
            }
            $fsPath = $cfg.location.($loc) + '\' + $cfg.docbase.hexid
            if (-not (Test-Path($fsPath)))
            {
                throw "The path defined for location $loc is invalid: $fsPath)"
            }
            Log-Verbose "Valid location $loc found, path = $fsPath)"
        }
    }
    finally
    {
        $result.Dispose()
    }
    Log-Info 'checked locations on DB & file system'

    # performs further check ...
    Check-Contents $cnx $cfg
    # TODO: (SLM-20141105) should warn for other dm_location relating to filestore
    # that will remain unchanged
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
            "UPDATE dm_location_s SET file_system_path = '$($cfg.location.($loc))' 
            WHERE r_object_id IN (SELECT r_object_id FROM dm_location_sv WHERE object_name = '$loc');"
    }
    $sql = $sql + 'COMMIT TRAN;'

    Execute-NonQuery -cnx $cnx -sql $sql | Out-Null
    Log-Info 'Successfully updated locations' 
}

<#
    Disables all jobs and change target_server
#>
function Disable-Jobs($cnx, $cfg)
{
    $sql = 'BEGIN TRAN
    SELECT r_object_id INTO dbo.mig_active_jobs FROM dm_job_s WHERE is_inactive = 0;
    UPDATE dm_job_s SET is_inactive = 1 WHERE is_inactive = 0;
    COMMIT TRAN;'

    Execute-NonQuery -cnx $cnx -sql $sql | Out-Null
    Log-Info "Jobs successfully disabled"
}

function Update-JobsTargetServer($cnx, $cfg)
{
    $result = Select-Table -cnx $cnx -sql "SELECT target_server, r_object_id FROM dm_job_s"
    try
    {
        $newserver = $cfg.resolve('env.COMPUTERNAME')
        $previousHost = $cfg.resolve('docbase.previous.host')
        foreach ($row in $result.Rows)
        {
            $target = $row['target_server']
            $end = '@' + $previousHost.ToLower()
            if ($target.ToLower().EndsWith($end))
            {
                $id = $row['r_object_id']
                $new_target = $target.Substring(0, $target.Length - $previousHost.Length) + $newserver
                $sql = "UPDATE dbo.dm_job_s SET target_server = '$new_target' WHERE r_object_id = '$id'"
                Execute-NonQuery -cnx $cnx -sql $sql | Out-Null
                Log-Verbose "Updated target server for job $id to $new_target"
            }
        }
    }
    finally
    {
        $result.Dispose()
    }
    Log-Info "Target server for jobs successfully updated"
}

<#
    Update mount points
#>
function Update-MountPoint($cnx, $cfg)
{
    $sql = "
    BEGIN TRAN
    UPDATE dbo.dm_mount_point_s SET host_name = '$($cfg.resolve('env.COMPUTERNAME'))'
    UPDATE dbo.dm_mount_point_s SET file_system_path = '$($cfg.resolve('env.documentum'))\share' 
     WHERE r_object_id IN (SELECT r_object_id FROM dm_mount_point_sv WHERE object_name = 'share')
    COMMIT TRAN"

    Execute-NonQuery -cnx $cnx -sql $sql | Out-Null
    Log-Info "Mount points successfully fixed"
}


function Update-DmLocations($cnx, $cfg)
{
    $sql = "
    UPDATE dm_location_s SET 
     file_system_path = '$($cfg.resolve('env.dm_home'))\convert'
    WHERE r_object_id IN (SELECT r_object_id FROM dm_location_sv WHERE object_name = 'convert'); 

    UPDATE dm_location_s SET 
     file_system_path = '$($cfg.resolve('env.dm_home'))\install\external_apps\nls_chartrans'
    WHERE r_object_id IN (SELECT r_object_id FROM dm_location_sv WHERE object_name = 'nls_chartrans');"

    Execute-NonQuery -cnx $cnx -sql $sql | Out-Null
    Log-Info "Dm locations successfully fixed"
}


function Update-ServerConfig($cnx, $cfg)
{
    $sql =
    "UPDATE dm_server_config_s
    SET r_host_name = '$($cfg.resolve('env.COMPUTERNAME'))',
    web_server_loc = '$($cfg.resolve('env.COMPUTERNAME'))'
    WHERE r_object_id IN
    (
        SELECT r_object_id FROM dm_server_config_sv
        WHERE object_name = '$($cfg.resolve('docbase.config'))' AND i_has_folder = 1
    );"
    Execute-NonQuery -cnx $cnx -sql $sql | Out-Null
    Log-Info "Server config successfully fixed"
}

function Update-AppServerURI($cnx, $cfg)
{
    $sql =
    "select r_object_id from dbo.dm_server_config_sv 
     where (object_name = '$($cfg.resolve('docbase.config'))' AND i_has_folder = 1)"

    $id = Execute-Scalar -cnx $cnx -sql $sql

    if ($null -eq $id)
    {
        throw "Could not find the a valid dm_server_config object for docbase $($cfg.resolve('docbase.config'))"
    }

    $sql =
    "UPDATE dbo.dm_server_config_r SET app_server_uri = 'http://$($cfg.resolve('docbase.jms.host')):$($cfg.resolve('docbase.jms.port'))/DmMethods/servlet/DocMethod'
    WHERE r_object_id = '$id' AND app_server_name = 'do_method'"
    Execute-NonQuery -cnx $cnx -sql $sql | Out-Null
    Log-Verbose "app_server_uri successfully updated for 'do_method'"

    $sql =
    "UPDATE dbo.dm_server_config_r SET app_server_uri = 'http://$($cfg.resolve('docbase.jms.host')):$($cfg.resolve('docbase.jms.port'))/DmMail/servlet/DoMail'
    WHERE r_object_id = '$id' AND app_server_name = 'do_mail'"
    Execute-NonQuery -cnx $cnx -sql $sql | Out-Null
    Log-Verbose "app_server_uri successfully updated for 'do_mail'"
 
    $sql =
    "UPDATE dbo.dm_server_config_r SET app_server_uri = 'http://$($cfg.resolve('docbase.jms.host')):$($cfg.resolve('docbase.jms.port'))/bpm/servlet/DoMethod'
    WHERE r_object_id = '$id' AND app_server_name = 'do_bpm'"
    Execute-NonQuery -cnx $cnx -sql $sql | Out-Null
    Log-Verbose "app_server_uri successfully updated for 'do_bpm'"

    Log-Info "app_server_uri updated successfully"
}

<#
 to delete ?
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
    Log-Info "Migration tables created"
}
#>

function Test-MigrationTables($cnx, $cfg)
{
    $catName = $cfg.revolve('docbase.database')
    $sql = "IF (EXISTS (SELECT *
             FROM INFORMATION_SCHEMA.TABLES
             WHERE TABLE_SCHEMA = 'dbo'
             AND  (
                TABLE_NAME = 'mig_active_jobs'
                OR TABLE_NAME = 'mig_user'
                OR TABLE_NAME = 'mig_indexes'
               )
               AND TABLE_CATALOG = '$catName'))
            SELECT 1 AS res ELSE SELECT 0 AS res;"

    $r = Execute-Scalar -cnx $cnx -sql $sql
    if ($r -eq 1) {
        return $true
    }
    return $false
}

function Remove-MigrationTables($cnx)
{
    Execute-NonQuery -cnx $cnx -sql 'DROP TABLE dbo.mig_user' | Out-Null
    Log-Verbose 'Table dbo.mig_user successfully dropped'

    $n = Execute-Scalar -cnx $cnx -sql 'SELECT COUNT(*) FROM dbo.mig_indexes'
    if ($n -eq 0)
    {
        Execute-NonQuery -cnx $cnx -sql 'DROP TABLE dbo.mig_indexes' | Out-Null
        Log-Verbose 'Table dbo.mig_indexes successfully dropped'
    }

    $n = Execute-Scalar -cnx $cnx -sql 'SELECT COUNT(*) FROM dbo.mig_active_jobs'
    if ($n -eq 0)
    {
        Execute-NonQuery -cnx $cnx -sql 'DROP TABLE dbo.mig_active_jobs' | Out-Null
        Log-Verbose 'Table dbo.mig_active_jobs successfully dropped'
    }

    Log-Info "Migration tables deleted"
}

function Create-mig_indexesTable()
{
    $sql =
    'CREATE TABLE dbo.mig_indexes (
        table_name nvarchar(128) NOT NULL,
        index_name nvarchar(128) NOT NULL,
        ddl nvarchar(4000) NOT NULL
    )
    CREATE UNIQUE NONCLUSTERED INDEX mig_indexes_key 
    ON dbo.mig_indexes (table_name, index_name)'

    Execute-NonQuery -cnx $cnx -sql $sql | Out-Null
}


function Save-CustomIndexes($cnx, $cfg)
{
    $dbname = $cnx.database
    $dbuser = $cfg.resolve('docbase.user')
    $dbpwd = $cfg.resolve('docbase.pwd')
    $dbserver = $cnx.Datasource

    $sql =
    "
    SELECT
     o.name AS table_name
     , i.name AS index_name
     , i.is_unique
    from
     $dbname.sys.indexes i
     , $dbname.sys.objects o
     , $dbname.sys.schemas s
    where
    (
     (i.object_id = o.object_id)
     AND (o.schema_id = s.schema_id )
     AND (o.type = 'U')
     AND (s.name = 'dbo')
     AND (i.name IS NOT NULL)
     AND (i.name NOT IN (SELECT name FROM $dbname.dbo.dmi_index_s))
     AND (o.name NOT IN ('dm_dd_root_types', 'dm_dd_special_attrs', 'dm_federation_log', 'dm_message_route', 'dm_replica_catalog', 'dm_replica_delete', 'dm_replica_delete_info', 'dm_replication_events', 'dmi_object_type'))
     AND (LOWER(o.name) IN
      (
       SELECT name + '_s' FROM $dbname.dbo.dm_type_s
       UNION
       SELECT name + '_r' FROM $dbname.dbo.dm_type_s
      )
     )
    )
    ORDER BY
    o.name, i.name
    "

    $result = Select-Table -cnx $cnx -sql $sql
    try
    {
        # get the server connection
        $sc = New-Object Microsoft.SqlServer.Management.Common.ServerConnection
        $sc.ConnectionString = "server=$dbserver; uid=$dbuser; password=$dbpwd; database=$dbname;"
        try
        {
            # get the server now
            $server = New-Object Microsoft.SqlServer.Management.Smo.Server -ArgumentList $sc

             $sql = 'BEGIN TRAN;'

            foreach ($row in $result.Rows)
            {
                $tableName = $row['table_name']
                $indexName = $row['index_name']
                $table = $server.Databases[$dbname].Tables[$tableName]
                $idx = $table.Indexes[$indexName]
                $ddl = $idx.Script()
                $sql =  $sql +
                "INSERT INTO dbo.mig_indexes VALUES (N'$tableName', N'$indexName', N'$ddl');
                DROP INDEX [$indexName] ON [dbo].[$tableName];"
                Log-Verbose "Successfully saved definition for index $indexName of table $tableName"
            }

            $sql = $sql + 'COMMIT TRAN;'
            Execute-NonQuery -cnx $cnx -sql $sql | Out-Null
        }
        finally
        {
            $sc.Disconnect()
        }

        Log-Info "Successfully saved $($result.Rows.Count) custom index(es)"
    }
    finally
    {
        $result.Dispose()
    }
}

function Restore-CustomIndexes($cnx, $cfg)
{
    $results = Select-Table -cnx $cnx -sql 'SELECT * from dbo.mig_indexes'
    try
    {
        $indexRestored = 0   
        foreach($row in $results.Rows)
        {
            $indexName = $row['index_name']
            $tableName = $row['table_name']
            $indexDef = $row['ddl']
            $sql =  "
            BEGIN TRAN; 
            $indexDef
            DELETE FROM dbo.mig_indexes 
             WHERE index_name = '$indexName' 
             AND table_name = '$tableName';
            COMMIT TRAN"
            try
            {
                Execute-NonQuery -cnx $cnx -sql $sql | Out-Null
                $indexRestored = $indexRestored + 1
                Log-Verbose "Successfully restored index $indexName on table $tableName"
            }
            catch
            {
                Log-Warning "Error while restoring index $indexName on table $tableName - $($_.Exception.Message)"
            }
        }
        Log-Info "Successfully restored $indexRestored index(es)"
    }
    finally
    {
        $results.Dispose()
    }
}

function Restore-ActiveJobs($cnx)
{
    $results = Select-Table -cnx $cnx -sql 'SELECT r_object_id FROM dbo.mig_active_jobs'
    try
    {
        foreach ($row in $results)
        {
            $id = $row['r_object_id']
            $sql = "
            BEGIN TRAN
            UPDATE dbo.dm_job_s SET is_inactive = 0 WHERE r_object_id = '$id';
            DELETE FROM dbo.mig_active_jobs
             WHERE r_object_id = '$id';
            COMMIT TRAN;
            "
            Execute-NonQuery -cnx $cnx -sql $sql | Out-Null
            Log-Verbose "Restored active job $id"
        }
        Log-Info "Successfully restored $($results.Rows.Count) active job(s)"
    }
    finally
    {
        $results.Dispose()
    }
}

function Check-Contents ($cnx, $obj)
{
  $servermark = $obj.resolve('docbase.hexid')
  # make sure all contents are here
  # we are retrieving the latest content of each stuff
<#  $sql = 'SELECT f.r_object_id, l.file_system_path, c.data_ticket ' + 
   'FROM dbo.dm_filestore_s f, dbo.dm_location_sv l, ' + 
   '(SELECT storage_id, MAX(data_ticket) AS data_ticket FROM dmr_content_s GROUP BY storage_id) c ' + 
   'WHERE ((c.storage_id = f.r_object_id) AND (l.object_name = f.root))'
#>
  $sql = 'SELECT
 s.root
 , l.file_system_path
 , c.data_ticket
 , f.dos_extension 
FROM
 dbo.dmr_content_s c
 , dbo.dm_format_s f
 , dbo.dm_filestore_s s
 , dbo.dm_location_sv l
 , (
SELECT s.storage_id, MAX(s.data_ticket) AS data_ticket 
FROM 
 dbo.dmr_content_s s 
 , dbo.dmr_content_r r 
WHERE 
 r.r_object_id = s.r_object_id 
 AND r.i_position = -1 
 AND r.parent_id <> ''0000000000000000'' 
 AND s.storage_id <> ''0000000000000000'' 
GROUP BY 
 s.storage_id
) m
WHERE 
(
 (m.data_ticket = c.data_ticket)
 AND (m.storage_id = c.storage_id)
 AND (f.r_object_id = c.format)
 AND (m.storage_id = s.r_object_id)
 AND (s.root = l.object_name)
)'

  $inerror = $false
  $results = Select-Table -cnx $cnx -sql $sql
  try
  {
    foreach ($row in $results)
    {
      # compute the relative path matching the latest document
      [System.Int32] $data_ticket = $row['data_ticket']
      [System.UInt32]$value = 0;
      if (0 -gt $data_ticket)
      {
        $value = [System.UInt32]::MaxValue + $data_ticket
      }
      else
      {
        $value = $data_ticket
      }
      $tmp = $value.ToString('x8')
      $path = $tmp.Substring(0, 2) + '\' + $tmp.Substring(2, 2) + '\' + $tmp.Substring(4, 2) + '\' + $tmp.Substring(6, 2) + '.'
      $ext = $row['dos_extension']
      if ($ext)
      {
       # file might contains own extension
       $path += $ext
      }
      # the top-level folder path: we've got the default from the server ...
      $store = $row['root']

      $top = $row['file_system_path']
      if ($obj.location.ContainsKey($store))
      {
       # ... possibly redefined
       $top = $obj.location.($store)
      }
      # OK, got the complete file name then
      $filepath = $top + '\' + $servermark + '\' + $path
      if (-not (test-path $filepath))
      {
       #$inerror = true
       Log-Warning ('file ' + $path + ' is missing in store ' + $store + ' located in directory ' + $top)
      }
    }
    if ($inerror)
    {
     throw 'database refer to file(s) that cannot be resolved'
    }
    Log-Info 'checked last content in docbase exists on file system'
  }
  finally
  {
    $results.Dispose()
  }
}
