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
    Log-Verbose "Reg object=$dmp"

    if (test-path $obj.Path)
    {
        throw "The registry key $($obj.Path) already exists"
    }

    $out = New-Item -Path $obj.Path -type directory -force
    Log-Info "Reg key $out successfully created"
    foreach ($name in $obj.Keys)
    {
        $value = $obj.($name)
        $out = New-ItemProperty -Path $obj.Path -Name $name -PropertyType String -Value $value
        Log-Verbose "Reg entry $name = $value successfully created"
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
    $dctmCfgPath = $cfg.resolve('docbase.config_folder')
    $ini = $cfg.resolve('docbase.daemon.ini')
    New-Item -Path $dctmCfgPath -ItemType "directory" -Force | Out-Null
    Copy-Item -Path $cfg.resolve('file.server_ini') -Destination $ini | Out-Null  
    Copy-Item -Path $cfg.resolve('file.dbpasswd_txt') -Destination "$dctmCfgPath\dbpasswd.txt" | Out-Null      
    New-Item -Path $dctmCfgPath -name dbpasswd.tmp.txt -itemtype "file" -value $cfg.resolve('docbase.pwd') | Out-Null  
    
    # updating the server.ini file
    [iniFile]::WriteValue($ini, 'SERVER_STARTUP', 'database_password_file', "$dctmCfgPath\dbpasswd.tmp.txt")
    [iniFile]::WriteValue($ini, 'SERVER_STARTUP', 'install_owner', $cfg.resolve('user.name'))
    [iniFile]::WriteValue($ini, 'SERVER_STARTUP', 'user_auth_target', $cfg.resolve('docbase.auth')) 
    [iniFile]::WriteValue($ini, 'SERVER_STARTUP', 'database_name', $cfg.resolve('docbase.database'))
    [iniFile]::WriteValue($ini, 'SERVER_STARTUP', 'database_conn', $cfg.resolve('docbase.dsn'))
    [iniFile]::WriteValue($ini, 'SERVER_STARTUP', 'database_owner', $cfg.resolve('docbase.user'))
    [iniFile]::WriteValue($ini, 'SERVER_STARTUP', 'start_index_agents', 'F')

    Log-Info("Ini files successfully created in $dctmCfgPath")
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
        user_source = '',
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
            "SELECT * INTO dbo.mig_locations FROM dm_location_s 
            WHERE r_object_id IN (SELECT r_object_id FROM dm_location_sv WHERE object_name = '$loc');
            UPDATE dm_location_s SET file_system_path = '$($cfg.location.($loc))' 
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
            $target = $row['target_server’]
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
    Log-Info "Migration tables deleted"
}

function Get-IndexDDL($cnxStr)
{

    [System.Reflection.Assembly]::LoadWithPartialName("Microsoft.SqlServer.SMO") | out-null
    # get the server connection
    $sc = new-object('Microsoft.SqlServer.Management.Common.ServerConnection')
    $sc.ConnectionString = $cnxStr
    # get the server now
    $s = new-object ('Microsoft.SqlServer.Management.Smo.Server') $sc
    $db = $s.Databases['DM_QUALITY_docbase']
    $t = $db.Tables['dm_audittrail_s']
    $idx = $t.Indexes['IX_rho_dm_audittrail_s_eventname']
    $ddl = $idx.Script()
}


