[CmdletBinding()]
param (  
    [Parameter(Mandatory=$True)]
    [string]$configPath
    )
     
#check for configuration path validity
$configPath = Resolve-Path $configPath -ErrorAction Stop
Write-Output "Configuration path: $configPath"

# Include config functions
. "$PSScriptRoot\lib_config.ps1"

# Include database functions
. "$PSScriptRoot\lib_database.ps1"

# initialize the environment
$cfg = Initialize $configPath

# remove registry entries
Remove-Item -Path "HKLM:\SOFTWARE\Documentum\DOCBASES\$($cfg.resolve('docbase.name'))" -ErrorAction Continue

# Remove Docbase folder
$dctmCfgPath = $cfg.resolve('env.documentum') + '\dba\config\' + $cfg.resolve('docbase.name')
Remove-Item -Path $dctmCfgPath -Recurse -Force -ErrorAction Continue

# Remove Docbase service
sc.exe DELETE DmServerQUALITY

# Remove docbase ports definitions
$svcPath = $cfg.resolve('file.services')
$svcBak = $svcPath + '.bak'
$svctmp = $svcPath +'.tmp'
$pattern = '^' + $cfg.resolve('docbase.service')
get-content $svcPath | select-string -pattern $pattern -NotMatch | Out-File $svctmp -Encoding ascii -Force
if (Test-Path $svcBak)
{
    Remove-Item $svcBak -Force
}
Rename-Item -Path $svcPath -NewName $svcBak -Force
Rename-Item -Path $svctmp -NewName $svcPath -Force

# Rollback install owner changes
$sql = "
BEGIN TRAN	
	-- save current install owner
	SELECT * INTO dbo.restore_user FROM dbo.dm_user_s WHERE r_object_id = (SELECT r_object_id FROM dbo.mig_user)
	
	-- restore users from mig_user to dm_user_s
    UPDATE usr SET
		 usr.user_name = mig.user_name,
		 usr.user_os_name = mig.user_os_name,
		 usr.user_os_domain = mig.user_os_domain,
		 usr.user_login_name = mig.user_login_name,
		 usr.user_login_domain = mig.user_login_domain,
		 usr.user_source = mig.user_source,
		 usr.user_privileges = mig.user_privileges,
		 usr.user_state = mig.user_state
	FROM 
		dbo.dm_user_s usr, dbo.mig_user mig
	WHERE
		usr.r_object_id = mig.r_object_id
		          
    --Rollback user_name on sysobjects.
    UPDATE so SET 
     so.owner_name = mig.user_name 
    FROM 
		dm_sysobject_s so, dbo.mig_user mig
    WHERE 
		so.owner_name = (SELECT user_name FROM dbo.restore_user);
       
    UPDATE so SET 
     so.acl_domain = mig.user_name 
    FROM 
		dm_sysobject_s so, dbo.mig_user mig
    WHERE 
		so.acl_domain = (SELECT user_name FROM dbo.restore_user);
	
	UPDATE so SET 
     so.r_lock_owner = mig.user_name 
    FROM 
		dm_sysobject_s so, dbo.mig_user mig
    WHERE 
		so.r_lock_owner = (SELECT user_name FROM dbo.restore_user);

	UPDATE acl SET 
		acl.owner_name = mig.user_name 
    FROM 
		dbo.dm_acl_s acl, dbo.mig_user mig
    WHERE 
		acl.owner_name = (SELECT user_name FROM dbo.restore_user);
		
	UPDATE grp SET 
		grp.users_names = mig.user_name 
    FROM 
		dbo.dm_group_r grp, dbo.mig_user mig
    WHERE 
		grp.users_names = (SELECT user_name FROM dbo.restore_user);

	-- Drop 
	DROP TABLE dbo.restore_user, dbo.mig_user, dbo.mig_locations, mig_active_jobs
	
COMMIT TRAN;
"

$cnx = New-Connection $cfg.ToDbConnectionString()
try
{    
    Execute-NonQuery -cnx $cnx -sql $sql        
}
finally
{
    if ($null -ne $cnx)
    {
        $cnx.Close()
    }
}
