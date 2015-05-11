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
    $inipath = $cfg.resolve('docbase.daemon.dir')
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
    [iniFile]::WriteValue($ini, 'SERVER_STARTUP', 'docbase_name', $cfg.resolve('docbase.name'))
    [iniFile]::WriteValue($ini, 'SERVER_STARTUP', 'server_config_name', $cfg.resolve('docbase.config'))
    [iniFile]::WriteValue($ini, 'SERVER_STARTUP', 'database_password_file', "$inipath\dbpasswd.tmp.txt")
    [iniFile]::WriteValue($ini, 'SERVER_STARTUP', 'install_owner', $cfg.resolve('user.name'))
    [iniFile]::WriteValue($ini, 'SERVER_STARTUP', 'user_auth_target', $cfg.resolve('docbase.auth'))
    [iniFile]::WriteValue($ini, 'SERVER_STARTUP', 'database_name', $cfg.resolve('docbase.database'))
    [iniFile]::WriteValue($ini, 'SERVER_STARTUP', 'database_conn', $cfg.resolve('docbase.dsn'))
    [iniFile]::WriteValue($ini, 'SERVER_STARTUP', 'database_owner', $cfg.resolve('docbase.user'))
    [iniFile]::WriteValue($ini, 'SERVER_STARTUP', 'start_index_agents', 'F')
    [iniFile]::WriteValue($ini, 'SERVER_STARTUP', 'return_top_results_row_based', 'false')
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
    $section = 'DOCBASE_' + $cfg.resolve('docbase.name')
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
<#    $regEx = '(?i)(?<svcname>[#\w\d]+)\s*(?<svcport>[0-9]+)\/tcp'
    $text = Get-Content $Path -Raw
    [Uint16]$maxTcpPort = 0
    foreach ($m in [regex]::Matches($text, $regEx))
    {
        if ((-not $m.Groups['svcname'].Value.StartsWith('#')) -and ([uint16]::Parse($m.Groups['svcport'].Value) -gt $maxTcpPort))
        {
            $maxTcpPort = $m.Groups['svcport'].Value
        }
    }
#>
 $exp = [regex]'^[ \t]*([#\wd]+)+[ \t]+([0-9]+)/(tc|ud)p([ \t]+.*)?$'
 [Uint16]$maxTcpPort = 0
 $lines = Get-Content $Path
 foreach ($line in $lines)
 {
  $match = $exp.Match($line)
  if ($match.Success)
  {
   # service name is #1 and port is #2
   if ((-not $match.Groups[1].Value.StartsWith('#')) -and 
    ([uint16]::Parse($match.Groups[2].Value) -gt $maxTcpPort))
   {
    $maxTcpPort = [uint16]::Parse($match.Groups[2].Value)
   }
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
    "BEGIN TRAN; 
    -- records previous user state ...
    SELECT * INTO dbo.mig_user FROM dbo.dm_user_s WHERE user_login_name = '$previousUserName';
    -- update the user
    UPDATE dm_user_s SET 
        user_name = '$newUserName',
        user_os_name = '$newUserName',
        user_os_domain = '$newUserDomain',
        user_login_name = '$newUserName',
        user_login_domain = '$newUserDomain',
        acl_domain = '$newUserName',
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
        $proximity = $cfg.resolve('docbase.docbrokers.' + $i + '.proximity')
        [iniFile]::WriteValue($iniPath, $section, "host", $hostname)
        [iniFile]::WriteValue($iniPath, $section, "port", $port)
        [iniFile]::WriteValue($iniPath, $section, "proximity", $proximity)

        Log-Verbose "Updated Docbroker $i host= $hostname port= $port proximity $proximity"
    }
    Log-Info 'Updated docbrokers'
}

<# 
    Checks wether the migration of location has been done already or not
#>
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

<#
    Updates the target server for jobs
#>
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
    Updates mount points with the new host name and the file system path match $DOCUMENTUM/share 
    for the 'share' mount-point
    The actual directories are then checked by calling Sync-SharedMountPoint
#>
function Update-MountPoint($cnx, $cfg)
{
    # updates the mount-point definition
    $sharepath = $cfg.resolve('env.documentum') + '\share'
    $sql = "
    BEGIN TRAN
    UPDATE dbo.dm_mount_point_s SET host_name = '$($cfg.resolve('env.COMPUTERNAME'))'
    UPDATE dbo.dm_mount_point_s SET file_system_path = '" + $sharepath + "' 
     WHERE r_object_id IN (SELECT r_object_id FROM dm_mount_point_sv WHERE object_name = 'share')
    COMMIT TRAN"

    Execute-NonQuery -cnx $cnx -sql $sql | Out-Null
    Log-Info 'Mount points successfully fixed'

    Sync-SharedMountPoint $cfg
}

<#
    for the 'share' mount-point $DOCUMENTUM/share, ensure sub-folders 
    data/events/${docbase.hexid}, data/common/${docbase.hexid} and temp are created 
    if not found
#>
function Sync-SharedMountPoint ($cfg)
{
    $sharepath = $cfg.resolve('env.documentum') + '\share'
    # make sure the sub-directory exists
    $path = $sharepath + '\data\events\' + $cfg.docbase.hexid
    New-Item -ItemType Directory -Force -Path $path

    $path = $sharepath + '\data\common\' + $cfg.docbase.hexid
    New-Item -ItemType Directory -Force -Path $path

    $path = $sharepath + '\temp'
    New-Item -ItemType Directory -Force -Path $path

    $path = $sharepath + '\temp\dm_ca_store'
    New-Item -ItemType Directory -Force -Path $path

    Log-Info 'directories for shared mount-point were checked'
}

<#
    Updates specific locations (convert, nls_chartrans) with new dm_home path.
#>
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

<#
    Updates the server config with the new host name
#>
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

<#
    Updates the server config app server uri
#>
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
    "UPDATE dbo.dm_server_config_r SET app_server_uri = 'http://$($cfg.resolve('docbase.jms.host')):$($cfg.resolve('docbase.jms.port'))/DmMethods/servlet/DoMethod'
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

function Test-DocbaseConfig ($cnx, $conf)
{
    $sql =
    "select r_object_id from dbo.dm_server_config_sv 
     where (object_name = '$($cfg.resolve('docbase.config'))' AND i_has_folder = 1)"
    $id = Execute-Scalar -cnx $cnx -sql $sql
    if ($null -eq $id)
    {
        throw "There is no dm_server_config object named $($cfg.resolve('docbase.config'))"
    }
    $sql =
    "select r_object_id from dbo.dm_jms_config_sv 
     where (object_name = '$($cfg.resolve('docbase.config'))' AND i_has_folder = 1)"

}

<#
 the method that checks that datamodel is currently marked as a 
 7.1 docbase.
 The method just checks that the r_server_version of default server config 
 matches 7.1.xxx
#>
function Test-Running71 ($cnx, $conf)
{
 $sql = 'SELECT r_server_version FROM dbo.dm_server_config_sv ' + 
  'WHERE i_has_folder = 1 AND object_name = ''' + 
 $conf.resolve('docbase.name') + ''''
 $version = Execute-Scalar -cnx $cnx -sql $sql
 # $version should match something like: '7.1.0000.0151  Win64.SQLServer'
 # just get the 3 first characters to ensure it matches
 if (!$version)
 {
  throw 'cannot get current content server version from database'
 }
 if (!$version.StartsWith('7.1'))
 {
  throw 'unexpected content server version: ''' + $version + ''''
 }
}

<#
    Tests wether the temporary migration tables are already present in the db.
#>
function Test-MigrationTables($cnx, $cfg)
{
 $sql = 'SELECT t.name FROM sys.tables t, sys.schemas s ' + 
  'WHERE t.name IN (''mig_active_jobs'', ''mig_user'', ''mig_indexes'') AND ' + 
   't.type = ''U'' AND t.schema_id = s.schema_id AND s.name = ''dbo'''
    $r = Execute-Scalar -cnx $cnx -sql $sql
    if ($r)
    {
        # there is at least one table
        return $true
    }
    return $false
}

<#
    Drops temporary migration tables.
#>
function Remove-MigrationTables($cnx)
{
    if (Test-TableExists -cnx $cnx -name 'mig_user')
    {
        Execute-NonQuery -cnx $cnx -sql 'DROP TABLE dbo.mig_user' | Out-Null
        Log-Verbose 'Table dbo.mig_user successfully dropped'
    }

    if (Test-TableExists -cnx $cnx -name 'mig_indexes')
    {
        $n = Execute-Scalar -cnx $cnx -sql 'SELECT COUNT(*) FROM dbo.mig_indexes'
        if ($n -eq 0)
        {
            Execute-NonQuery -cnx $cnx -sql 'DROP TABLE dbo.mig_indexes' | Out-Null
            Log-Verbose 'Table dbo.mig_indexes successfully dropped'
        }
    }

    if (Test-TableExists -cnx $cnx -name 'mig_active_jobs')
    {
        $n = Execute-Scalar -cnx $cnx -sql 'SELECT COUNT(*) FROM dbo.mig_active_jobs'
        if ($n -eq 0)
        {
            Execute-NonQuery -cnx $cnx -sql 'DROP TABLE dbo.mig_active_jobs' | Out-Null
            Log-Verbose 'Table dbo.mig_active_jobs successfully dropped'
        }
    }
    Log-Info "Migration tables deleted"
}

<#
    Creates temporary migration table for storing custom indexes.
#>
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

<#
    Stores the custom indexes definition in temp table and drop the indexes from dm tables
#>
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

<#
    Restores the custom indexes saved in temp table to dm tables 
#>
function Restore-CustomIndexes($cnx, $cfg)
{
    if (Test-TableExists -cnx $cnx -name 'mig_indexes')
    {
        # OK, go for it now !
        $results = Select-Table -cnx $cnx -sql 'SELECT * from dbo.mig_indexes'
        $errors = 0
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
                    $errors += 1
                    Log-Error "Error (Non-blocking) while restoring index $indexName on table $tableName - $($_.Exception.Message)"
                }
            }
            if (0 -lt $errors)
            {
                Log-Info "Successfully restored $indexRestored index(es)"
            }
            else
            {
                Log-Info "Successfully restored $indexRestored index(es) with $errors errors preventing from re-creation"
            }
        }
        finally
        {
            $results.Dispose()
        }
    }
}

<#
    Reactivates jobs status after migration
#>
function Restore-ActiveJobs($cnx)
{
    if (Test-TableExists -cnx $cnx -name 'mig_active_jobs')
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
}

<#
   Make sure all contents are here
   we are retrieving the latest content of each stuff
#>
function Check-Contents ($cnx, $obj)
{
  $servermark = $obj.resolve('docbase.hexid')
  
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
        $value = [System.UInt32]::MaxValue + $data_ticket + 1
      }
      else
      {
        $value = $data_ticket
      }
      $tmp = $value.ToString('x8')
      $p1 = $tmp.Substring(0, 2)
      $p2 = $tmp.Substring(2, 2)
      $p3 = $tmp.Substring(4, 2)
      $p4 = $tmp.Substring(6, 2)
      $path = $p1 + '\' + $p2 + '\' + $p3 + '\' + $p4 + '.'
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
      $base = $top + '\' + $servermark
      $filepath = $base + '\' + $path
      Log-Info "last file in store '$base' is '$path'"

      # but is there other files after ?
      # do it again in grand-parent
      $search = $base + '\' + $p1
      $file = (Get-LastFile $search)
      if ($file)
      {
       if ($p2 -ne $file.BaseName)
       {
        Log-Warning("unexpected directory '$file' in '$search': expected '$p2'")
        $inerror = $true
       }
       else
       {
        # do it again in parent path
        $search = $base + '\' + $p1 + '\' + $p2
        $file = (Get-LastFile $search)
        if ($file)
        {
         if ($p3 -ne $file.BaseName)
         {
          Log-Warning("unexpected directory '$file' in '$search': expected '$p3'")
          $inerror = $true
         }
         else
         {
          if (-not (test-path $filepath))
          {
           Log-Warning ('file ' + $path + ' is missing in store ' + $store + ' located in directory ' + $top)
           $inerror = $true
          }
          else
          {
           $search = $base + '\' + $p1 + '\' + $p2 + '\' + $p3
           $file = (Get-LastFile $search)
           if ($file)
           {
            if ($p4 -ne $file.BaseName)
            {
             Log-Warning("unexpected file '$file' in '$search': expected '$p4'")
             $inerror = $true
            }
            else
            {
             # the only case that is OK
             Log-Info("storage $store seems OK")
            }
           }
           else
           {
            Log-Warning("cannot find any file in '$search'")
            $inerror = $true
           }
          }
         }
        }
        else
        {
         Log-Warning("cannot find any file in '$search'")
         $inerror = $true
        }
       }
      }
      else
      {
       Log-Warning("cannot find any file in '$search'")
       $inerror = $true
      }

    }
    if ($inerror)
    {
     throw 'database refer to file(s) that cannot be resolved'
    }
    Log-Info 'file system contents checked'
  }
  finally
  {
    $results.Dispose()
  }
}

<#
 The function that returns the last file eligible in a path of a store
#>
function Get-LastFile ($dir)
{
 $files = (get-childitem $dir | Where-Object {$_.Name -like '??.*' -or  $_.Name -like '??'} | sort)
 if ($null -eq $files)
 {
  Log-Warning ("unexpected empty directory: '$dir'")
 }
 elseif ('FileInfo' -eq $files.GetType().Name)
 {
  return $files
 }
 elseif ('DirectoryInfo' -eq $files.GetType().Name)
 {
  return $files
 }
 elseif (0 -lt $files.Length)
 {
  return $files[$files.Length-1]
 }
}

<#
    Disables docbroker projections (set projection_enable to 0)
#>
function Disable-Projections ($cnx, $name)
{
  $sql ="
   UPDATE dm_server_config_r 
   SET projection_enable = 0
   WHERE 
   (
    (r_object_id IN
     (SELECT r_object_id FROM dbo.dm_server_config_sv
      WHERE i_has_folder = 1 AND object_name = '$name'
     )
    )
    AND (projection_enable <> 0)
    AND (projection_enable IS NOT NULL)
    AND (projection_proxval > 0)
   )"

  $count = Execute-NonQuery -cnx $cnx -sql $sql
  if (0 -lt $count)
  {
    Log-Info "$count projections to docbroker disabled in server config"
  }
  else
  {
    Log-Info 'there is no docbroker projection to disable in server config'
  }
}

<#
    the method that retrieves dynamic data from the instance for use by the upgrade
    namely, the email address, the SMTP server's name, the locale and the connection mode 
    are retrieved.
    the following configuration entries are upated:
    docbase.email ('')
    docbase.locale ('en')
    docbase.smtp ('localhost')
    docbase.connection_mode ('native')
#>
function Read-Dynamic-Conf ($cnx, $conf)
{

    # we need to have a 'location.storage_01' (= \\LABAD01\shares\RCSEHS\content_storage_01)
    # value to build the docbase.datahome 
    # (get-item '\\LABAD01\shares\RCSEHS\content_storage_01' ).Parent.Parent.FullName
    $primarystore = $cfg.resolve('location.storage_01')
    if ($null -eq $primarystore)
    {
        throw 'Missing required ''location.storage_01 path'''
    }
    $datahome = (get-item $primarystore ).parent.parent.fullname
    if ($null -eq $datahome)
    {
        throw "location path for storage_01 ($primarystore) does not have any grand-parent"
    }
    $cfg.docbase.datahome = $datahome
    Log-Verbose "computed datahome to match: '$datahome'"

    # the email address to use by default ...
    $email = Execute-Scalar -cnx $cnx -sql ('SELECT user_address FROM dm_user_s WHERE user_name= ''' + $conf.resolve('docbase.previous.name') + '''')
    if ($null -eq $cfg.email)
    {
        $conf.docbase.email = ''
        Log-Warning 'Failed to identify email address'
    }
    else
    {
        $conf.docbase.email = $email
        Log-Verbose "using the following email address: '$email'"
    }

    # data from the server's configuration
    $result = Select-Table -cnx $cnx -sql ('SELECT locale_name, smtp_server, secure_connect_mode FROM dm_server_config_sv WHERE object_name = ''' + $conf.resolve('docbase.config') + ''' AND i_has_folder = 1')
    try 
    {
        if ($result.Rows.Count -eq 0)
        {
            throw 'Failed to find server config named ''' + $conf.resolve('docbase.config') + ''''
        }
        $row = $result.Rows[0]
        $locale = $row['locale_name']
        $smtp = $row['smtp_server']
        $mode = $row['secure_connect_mode']
        if ($locale)
        {
            $conf.docbase.locale = $locale
            Log-Verbose "server's locale name set to '$locale'"
        }
        else
        {
            $locale = $conf.resolve('docbase.locale')
            if ($locale)
            {
                Log-Warning "there is no locale associated to the server, using '$locale'"
            }
            else
            {
                $conf.docbase.locale = 'en'
                Log-Warning 'there is no locale associated to the server nor any default, using ''en'''
            }
        }
        if ($smtp)
        {
            $conf.docbase.smtp = $smtp
        }
        else
        {
            $smtp = $conf.resolve('docbase.smtp')
            if ($smtp)
            {
                Log-Warning "there is no SMTP server associated to the server, using '$smtp'"
            }
            else
            {
                $conf.docbase.smtp = 'localhost'
                Log-Warning 'there is no SMTP server associated to current server configuration nor any default, using ''localhost'''
            }
        }
        if ($mode)
        {
            $conf.docbase.connect_mode = $mode
            Log-Verbose "connection model set to '$mode'"
        }
        else
        {
            $mode = $conf.resolve('docbase.connect_mode')
            if ($mode)
            {
                Log-Warning "there is no connection mode associated to the server, using '$mode'"
            }
            else
            {
                $conf.docbase.connect_mode = 'native'
                Log-Warning 'there is no connection mode associated to the server configuration nor any default, using ''native'''
            }
        }
    }
    finally
    {
        $result.Dispose()
    }

    # figure whether docbase is a global registry
    $result = Execute-Scalar -cnx $cnx -sql (
     'SELECT r.docbase_roles ' + 
     'FROM dbo.dm_docbase_config_r r ' + 
     'JOIN dbo.dm_docbase_config_sv s ON (s.r_object_id = r.r_object_id) ' + 
     'WHERE r.docbase_roles IS NOT NULL ' + 
     'AND s.i_has_folder = 1 ' + 
     'AND s.object_name = ''' + $conf.resolve('docbase.config') + '''')
    if ($null -eq $result) 
    {
     $conf.docbase.globalregistry = $false    
    }
    else
    {
     $conf.docbase.globalregistry = $true    
    }

    # computes the hexid for the docbase: 8 digits representation
    $id = $conf.resolve('docbase.id')
    [System.UInt32] $val = [Convert]::ToUInt32($id, 10)
    $hex = $val.ToString('x8')
    $conf.docbase.hexid = $hex

    Log-Info ('fetched dynamic data from install owner user and current server configuration')
}

<# 
    Starts the Content Server service.
    Throws an exception if the service is already started.
#>
function Start-ContentServerService($Name)
{
    $csService = Get-Service $Name -ErrorAction Stop
    if ($csService.Status -ne [System.ServiceProcess.ServiceControllerStatus]::Stopped)
    {
        throw 'Content server is not stopped.'
    }
    Log-Info "Starting Content Server service '$Name'. This may take a while..."
    Start-Service -InputObject $csService -ErrorAction Stop
    Log-Info "Content Server service '$Name' successfully started"
}

<# 
    Starts the Content Server service.
    Warns if the service is already started.
#>
function Start-ContentServerServiceIf($Name)
{
    $csService = Get-Service $Name -ErrorAction Stop
    if ($csService.Status -ne [System.ServiceProcess.ServiceControllerStatus]::Running)
    {
        Log-Info "Starting Content Server service '$Name'. This may take a while..."
        Start-Service -InputObject $csService -ErrorAction Stop
        Log-Info "Content Server service '$Name' successfully started"
    }
    else
    {
        Log-Verbose "Content Server service '$Name' not already running"
    }
}

<# 
    Stops the Content Server service.
    Warns if the service is already stopped.
#>
function Stop-ContentServerServiceIf($Name)
{
    $csService = Get-Service $Name -ErrorAction SilentlyContinue
    if ($null -ne $csService)
    {
        if ($csService.Status -ne [System.ServiceProcess.ServiceControllerStatus]::Stopped)
        {
            Log-Info "Stopping Content Server service '$Name'. This may take a while..."
            Stop-Service -InputObject $csService -ErrorAction Stop
            Log-Info "Content Server service '$Name' successfully stopped"
        }
        else
        {
            Log-Verbose "Content Server service '$Name' is already stopped"
        }
    }
}

<# 
    Removes the Content Server service.
    Warns if the service doesn't exists.
#>
function Remove-ContentServerServiceIf($name)
{
    $csService = Get-Service $Name -ErrorAction SilentlyContinue
    if ($null -ne $csService)
    {
        if ($csService.Status -eq [System.ServiceProcess.ServiceControllerStatus]::Stopped)
        {
            (gwmi win32_service -filter "name='$name'").delete()
            Log-Info "Content Server service '$name' successfully deleted"
        }
        else
        {
            Log-Warning "Cannot delete service '$Name': service is not stopped"
        }
    }
    else
    {
        Log-Verbose "Service $name does not exist (may have been deleted aready)"
    }
}

<#
    Executes the dm basic script and throws if an error in execution is detected.
#>
function Start-DmbasicScript($cfg, $scriptname)
{
    Log-Info "Executing dmbasic script $script..."
    $args = $cfg.resolve("docbase.upgrade.dmbasic.scripts.$scriptname.Arguments")
    $exitcode = $cfg.resolve("docbase.upgrade.dmbasic.scripts.$scriptname.ExitCode")
    $dmbasic = $cfg.resolve('docbase.tools.dmbasic')
    $outPath = $cfg.resolve('docbase.daemon.dir') + '\'+ $scriptname + '.out'
    $ErrPath = $cfg.resolve('docbase.daemon.dir') + '\'+ $scriptname + '.err'

    $noentrypointpattern = 'dmbasic: The entry point .+ does not exist'
    if (Test-Path($outPath))
    {
        throw "Script $scriptname appears to have been run already"
    }
    Log-Verbose "$scriptname expected exit code=$exitcode, args=$args"
    $proc = Start-Process -FilePath $dmbasic -ArgumentList $args -NoNewWindow -Wait -ErrorAction Stop -RedirectStandardOutput $outPath -RedirectStandardError $ErrPath -Passthru
    try 
    {          
        if ($proc.ExitCode -ne $exitcode)
        {
            $out = gc $outPath -Tail 5
            throw "Script $scriptname exited with error code $($proc.ExitCode)`r`n------ Script output excerpt ---------`r`n...$out`r`n----------------------------------`r`nSee $outPath for complete logs.`r`n"       
        }
        elseif (0 -ne (Get-ItemProperty -Path $ErrPath).length)
        {
            $err = gc $ErrPath
            throw "Script $scriptname exited with the following message in error log`r`n------ Script error  excerpt ---------`r`n...$err`r`n----------------------------------`r`nSee $errPath for complete logs.`r`n"
        }
        elseif($null -ne (gc $outPath | Select-String -Pattern $noentrypointpattern))
        {
            $out = gc $outPath
            throw "Script $scriptname exited with the following error: $out"
        }
        else 
        {
            Log-Verbose "Execution of script $scriptname completed"
        }
    }
    finally
    {
        # Cleanup .err file if it doesn't contain anything.        
        if  (0 -eq (Get-ItemProperty -Path $ErrPath).length)
        {
            Remove-Item $ErrPath 
        }
    }
}

<#
    Runs a collection of dm basic scripts
#>
function Start-DmbasicStep($cfg, $step)
{
    $all = $cfg.resolve('docbase.upgrade.dmbasic.steps.' + $step)
    $scripts = $all.Split(',', [System.StringSplitOptions]::RemoveEmptyEntries)
    log-info ('found ' + $scripts.length + ' docbasic scripts for step ' + $step)

    foreach ($script in $scripts)
    {
        $script = $script.Trim()
        Start-DMbasicScript -scriptname $script -cfg $cfg
    }
}

<#
    Updates the the ACS config with the new JMS and new Docbroker projections.
#>
function Update-AcsConfig($cnx, $cfg)
{
    $docbase = $cfg.resolve('docbase.config') 
    $newurl = "http://$($cfg.resolve('docbase.jms.host')):$($cfg.resolve('docbase.jms.port'))/ACS/servlet/ACS"
    $sql =
    "UPDATE dbo.dm_acs_config_r 
     SET acs_base_url = '$newurl'
      WHERE acs_base_url IS NOT NULL
       AND acs_base_url <>''
       AND r_object_id IN
        (SELECT r_object_id  FROM [dbo].[dm_acs_config_sv]
          WHERE i_has_folder = 1
          AND svr_config_id IN
           (SELECT r_object_id FROM dbo.dm_server_config_sv
            WHERE i_has_folder = 1
            AND object_name = '$docbase'))"

    Execute-NonQuery -cnx $cnx -sql $sql | Out-Null
    Log-Verbose "acs_base_url successfully updated in 'dm_acs_config_r'"

    $newtarget = $cfg.resolve('docbase.docbrokers.0.host')
    $newport = $cfg.resolve('docbase.docbrokers.0.port')
    $sql =
    "UPDATE dbo.dm_acs_config_r 
     SET projection_targets = '$newtarget', projection_ports = $newport
      WHERE projection_targets IS NOT NULL 
       AND projection_targets <> ''
       AND r_object_id IN 
        (SELECT r_object_id  FROM [dbo].[dm_acs_config_sv]
          WHERE i_has_folder = 1
          AND svr_config_id IN
           (SELECT r_object_id FROM dbo.dm_server_config_sv
            WHERE i_has_folder = 1
            AND object_name = '$docbase'))"

    Execute-NonQuery -cnx $cnx -sql $sql | Out-Null
    Log-Verbose "projection_targets and projection_ports successfully updated in 'dm_acs_config_r'"

    Log-Info "ACS Config updated successfully"
}

<#
    Register a docbase to its JMS (adds an entry to the web.xml of webapp)
#>
function Register-DocbaseToJms($cfg)
{    
    $name = $cfg.resolve('docbase.name')
    $jmsconf = New-JmsConf($cfg.resolve('docbase.jms.web_inf') + '\web.xml')
    $jmsconf.Register($name)
    $jmsconf.Save()
    log-info "Docbase successfully registered to JMS"
}

<# 
    reset the crypto keys related to the aek.key
 #>
function Reset-AEK ($cnx)
{
  $sql =
    "BEGIN TRAN 
    -- reset the docbase config
    UPDATE dbo.dm_docbase_config_s SET 
    i_crypto_key = ''
    , i_ticket_crypto_key = '';

    -- remove the marks for the dmi_object_type
    DELETE dbo.dmi_object_type 
    WHERE r_object_id IN 
    (
     SELECT r_object_id 
     FROM dbo.dmi_vstamp_s 
     WHERE i_application IN ('dm_docbase_config_crypto_key_init', 'dm_docbase_config_ticket_crypto_key_init')
    );

    -- remove the stamps
    DELETE dbo.dmi_vstamp_s 
    WHERE i_application IN ('dm_docbase_config_crypto_key_init', 'dm_docbase_config_ticket_crypto_key_init');

    -- remove the publick key certificates
    DELETE dbo.dm_sysobject_s WHERE r_object_id IN (SELECT r_object_id FROM dbo.dm_public_key_certificate_s WHERE key_type= 1);
    DELETE dbo.dm_sysobject_r WHERE r_object_id IN (SELECT r_object_id FROM dbo.dm_public_key_certificate_s WHERE key_type= 1);
    DELETE dbo.dm_public_key_certificate_s WHERE key_type= 1;

    -- remove the crypto keys
    DELETE dbo.dm_sysobject_s WHERE r_object_id IN (SELECT r_object_id FROM dbo.dm_cryptographic_key_s WHERE key_type= 1);
    DELETE dbo.dm_sysobject_r WHERE r_object_id IN (SELECT r_object_id FROM dbo.dm_cryptographic_key_s WHERE key_type= 1);
    DELETE dbo.dm_cryptographic_key_s WHERE key_type= 1;

    -- OK, commit then
    COMMIT TRAN;"

  $r = Execute-NonQuery -cnx $cnx -sql $sql
  Log-Info "Crypto configuration successfully reset"
}