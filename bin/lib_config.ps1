<#
 Contains functions to store, manage and verify the configuration settings for the migration
#>

<#
 creates an object with a dump() method that displays as json object
 #>
function createObj ()
{
 $obj = @{}
 $obj = Add-Member -InputObject $obj -MemberType ScriptMethod -Name dump -Value {
  .{
   $result = (_DumpObjAt $this '') + [Environment]::NewLine
   return $result
  } @args
 } -Passthru
 return $obj
}

<#
 creates an object with a dump() method that displays as json object,
 a resolve($key) that resolves the key value replacing any ${xx} with 
 resolved value and a show() method that displays the list of all resolved 
 properties
 #>
function createDynaObj ()
{
 $obj = createObj

 # adds both methods: resolve ($key) and show ()
 $obj = Add-Member -InputObject $obj -MemberType ScriptMethod -Name resolve -Value {
 .{
   param (
    [Parameter(Mandatory=$true)]
    [ValidateNotNullOrEmpty()]
    [string]$key
   )
   $value = Resolve $this $key
   return ResolveValue $this $value
  } @args
 } -Passthru
 # adds method 'show'
 $obj = Add-Member -InputObject $obj -MemberType ScriptMethod -Name show -Value {
  .{
   $result = (_showResolved $this $this '')
   return $result
  } @args
 } -Passthru

  # adds method 'ToDocbaseRegistry'
 $obj = Add-Member -InputObject $obj -MemberType ScriptMethod -Name ToDocbaseRegistry -Value {
  .{
   $result = (asDocbaseRegistry $this)
   return $result
  } @args
 } -Passthru

  # adds method 'ToDocbaseService'
 $obj = Add-Member -InputObject $obj -MemberType ScriptMethod -Name ToDocbaseService -Value {
  .{
   $result = (asDocbaseService $this)
   return $result
  } @args
 } -Passthru

   # adds method 'ToDbConnectionString'
 $obj = Add-Member -InputObject $obj -MemberType ScriptMethod -Name ToDbConnectionString -Value {
  .{
   $result = (asDbConnectionString $this)
   return $result
  } @args
 } -Passthru

 return $obj
}

<#
 the function that returns the object matching the . (dot) separated value in the 
 supplied object
 #>
function GetObjOf ($obj, $name, $create)
{
 if ($obj.Contains($name))
 {
  $sub = $obj.($name)
  if ($null -eq $sub)
  {
   throw 'null value for entry ' + $name + ' in ' + $obj.dump()
  }
  if('System.Collections.Hashtable' -eq $sub.GetType().FullName)
  {
   return $sub;
  }
  throw 'invalid value for entry $name in ' + $obj.dump()
 }
 if ($true -eq $create)
 {
  # ok: adds a new object to the supplied object
  $sub = createObj
  $obj.($name) = $sub
  return $sub;
 }
 throw "there is no object for key $name"
}

<#
 unencrypts a ...'crypted' password
 #>
<#
function _decrypt ($crypt)
{
 $tmp = convertfrom-securestring $crypt
 $decrypt = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR( (convertto-securestring $tmp) ))
 return $decrypt
}
#>

<#
 the method that checks at the password for a user
 #>
function checkPassword ($user, $domain, $pwd)
{
 add-type -AssemblyName System.DirectoryServices.AccountManagement
 $machine = (get-childitem -path env:computername).value
 if ($machine -eq $domain)
 {
  $ct = [System.DirectoryServices.AccountManagement.ContextType]::Machine
 }
 else
 {
  $ct = [System.DirectoryServices.AccountManagement.ContextType]::Domain
 }
 $cred = new-object System.Management.Automation.PSCredential $user, $pwd
 $nc = $cred.GetNetworkCredential()
 $pc = new-object System.DirectoryServices.AccountManagement.PrincipalContext $ct
 try
 {
  return $pc.validatecredentials($nc.username, $nc.password)
 }
 finally
 {
  $pc.dispose()
 }
}

<#
 the method that reads the password for a given user
 #>
function readPwd ($domain, $user)
{
  $msg = 'enter password for user ' + $domain + '\' + $user + ' (empty to cancels)'
  $msg2 = 'wrong password.\n' + $msg
  $pwd = ''
  while (0 -eq $pwd.length)
  {
   $pwd = read-host -assecurestring $msg
   # TODO: should check then
   if (0 -lt $pwd.Length)
   {
    if (!(checkPassword $user $domain $pwd))
    {
     $msg = $msg2
     $pwd = ''
    }
   }
  }
  return $pwd
}

<#
 the function that reads an .INI file and stores 
 all sections as an object and each entry as a key:value pair
 #>
function LoadIniFile ($ini, $filePath)
{
 $lines = Get-Content $filepath
 $count = $lines.Length
 $currentkey = $null
 for ($index = 0; $index -lt $count; $index++)
 {
  $line = $lines[$index].TrimEnd()
  if ($line -match '^#|;.*')
  {
   # does nothing
  }
  elseif ($line -match '^\[(.*)\]$')
  {
   $currentkey = $matches[1]
   $tmp = getObjOf $ini $currentkey $true
  }
  elseif ($line -match '^(.*)=(.*)$')
  {
   if ($null -eq $currentkey)
   {
    throw 'invalid line ' + $index + ' in ' + $filepath + 
     ': section is missing (' + $line + ')'
   }
   $entry = $matches[1].Trim()
   $value = $matches[2].Trim()
   $ini.($currentkey).($entry) = $value
  }
 }
}

<#
 the function that handles the addition of value identified by the key in 
 supplied object.
 if the key contains a . (dot), the function gets the object identified by the 
 left-side of the key and recursively calls self using the found object as 
 parent and the right-side of the key as key
 #>
function Write-KeyValue ($parent, $key, $value)
{
 $index = $key.IndexOf('.')
 if (-1 -eq $index)
 {
  $parent.($key) = $value
 }
 else
 {
  # creates the object for 1st level and recursively calls self
  # supplying object as parent, remaining of key and value
  $objname = $key.SubString(0, $index)
  $name = $key.SubString($index + 1)
  $obj = GetObjOf $parent $objname $true
  Write-KeyValue $obj $name $value
 }
}
<# 
 the function that fills an existing object with the values found in 
 properties file.
 when . (dot) separated property names are encountered, each part of the 
 property between . (dot) will be resoved as another object
 #>
function LoadPropertiesFile ($obj, $filePath)
{
 $lines = Get-Content $filepath
 $count = $lines.Length
 # currentkey and currentvalue goes together
 $currentkey = $null
 $currentvalue = $null
 for ($index = 0; $index -lt $count; $index++)
 {
  if ($currentvalue -eq $null)
  {
   $line = $lines[$index].TrimEnd()
   # is this a comment ?
   if ($line.StartsWith('#'))
   {
    # just a comment: forgets about it ...
    #"comment: " + $line
   }
   elseif (0 -lt $line.Length)
   {
    # if an empty line ... leaves it
    # should match ${key}=${value}
    $pos = $line.IndexOf('=')
    if (-1 -eq $pos)
    {
     throw 'invalid line ' + ($index + 1) + ' encountered: ' + $line
    }
    $key = $line.SubString(0, $pos).Trim()
    $value = $line.SubString($pos+1).Trim()
    if ($value.EndsWith("\"))
    {
     $currentkey = $key
     $currentvalue = $value.SubString(0,$value.Length - 1)
    }
    else
    {
     Write-KeyValue $obj $key $value
    }
   }
  }
  else
  {
   # continuation of a value then
   if ($line.Length -eq 0)
   {
    throw 'empty text encountered at line ' + 
     ($index + 1) + ' while expecting a continuation'
   }
   elseif (! $line.StartsWith(' '))
   {
    throw 'line ' + ($index + 1) + 
     ' is expected to be a continuation line starting with space character: ''' + 
     $line + ''''
   }
   $value = $line.SubString(1)
   if ($value.EndsWith('\'))
   {
    $currentvalue = $currentvalue + $value.SubString(0,$value.Length - 1)
   }
   else
   {
    $currentvalue = $currentvalue + $value
    Write-KeyValue $obj $currentkey $currentvalue
    $currentkey = $null
    $currentvalue = $null
   }
  }
 }
}

function SaveFlatPropertiesFile ($obj, $filePath)
{
 $stream = [System.IO.StreamWriter] $filepath
 try
 {
  foreach ($key in $obj.Keys)
  {
   $value = $obj.($key)
   $line = $key + '=' + $value
   $stream.writeline($line)
  }
 }
 finally
 {
  $stream.Close()
 }
}

function LoadFlatPropertiesFile ($obj, $filePath)
{
 $lines = Get-Content $filepath
 $count = $lines.Length
 # currentkey and currentvalue goes together
 $currentkey = $null
 $currentvalue = $null
 for ($index = 0; $index -lt $count; $index++)
 {
  if ($currentvalue -eq $null)
  {
   $line = $lines[$index].TrimEnd()
   # is this a comment ?
   if ($line.StartsWith('#'))
   {
    # just a comment: forgets about it ...
    #"comment: " + $line
   }
   elseif (0 -lt $line.Length)
   {
    # if an empty line ... leaves it
    # should match ${key}=${value}
    $pos = $line.IndexOf('=')
    if (-1 -eq $pos)
    {
     throw 'invalid line ' + ($index + 1) + ' encountered: ' + $line
    }
    $key = $line.SubString(0, $pos).Trim()
    $value = $line.SubString($pos+1).Trim()
    if ($value.EndsWith("\"))
    {
     $currentkey = $key
     $currentvalue = $value.SubString(0,$value.Length - 1)
    }
    else
    {
     $obj.($key) = $value
    }
   }
  }
  else
  {
   # continuation of a value then
   if ($line.Length -eq 0)
   {
    throw 'empty text encountered at line ' + 
     ($index + 1) + ' while expecting a continuation'
   }
   elseif (! $line.StartsWith(' '))
   {
    throw 'line ' + ($index + 1) + 
     ' is expected to be a continuation line starting with space character: ''' + 
     $line + ''''
   }
   $value = $line.SubString(1)
   if ($value.EndsWith('\'))
   {
    $currentvalue = $currentvalue + $value.SubString(0,$value.Length - 1)
   }
   else
   {
    $currentvalue = $currentvalue + $value
    $obj.($currentkey) = $currentvalue
    $currentkey = $null
    $currentvalue = $null
   }
  }
 }
}

<# 
 the function that resolves a value from an object.
 the supplied key is splitted using the . (dot) separator. 
 for all parts except the last one, it is assumed to match an object
 #>
function Resolve ($obj, $key)
{
 $names = $key.Split('.')
 $current = $obj
 $count = $names.Length
 for ($index = 0; $index -lt ($count - 1); $index++)
 {
  $name = $names[$index]
  $msg = 'getting ''' + $name + ''' from ' + $current
  write-debug $msg
  $current = GetObjOf $current $name $false
 }
 $request = $names[$count -1]
 $value = $current.($request)

 if ($null -eq $value)
 {
  throw 'there is no value with key ''' + $key + ''' in object ' + $obj.dump()
 }
 return $value
}

<#
 the function that resolves found value matching the supplied key by 
 replacing, if any is found, expressions surrounded by ${ and } by 
 actual values
 #>
function ResolveDynamic ($obj, $key)
{
 $value = Resolve $obj $key
 if ((! $value) -or ('System.String' -ne $value.GetType().FullName))
 {
  return $value
 }
 # figure whether the value holds any part matching ${...}
 $start = $value.IndexOf('${', 0)
 if (-1 -eq $start)
 {
  return $value
 }

 $computed = ''
 $max = $value.Length
 if ($start -gt 0)
 {
  $computed += $value.Substring(0, $start)
 }

 While (($start -le $max) -and ($start -gt -1))
 {
  $end = $value.IndexOf('}', ($start + 2))
  if (-1 -eq $end)
  {
   throw 'invalid value expression (' + $value + 
    '): found starting ${ at position ' + $start + 
    ' with no closing bracket'
  }
  $part = $value.Substring( $start+2 , $end - ($start + 2));
  if (0 -eq $part.Length)
  {
   throw 'invalid value expression (' + $value + 
    '): found ${} matching empty expression at ' + $start
  }
  $dyn = ResolveDynamic $obj $part
  $computed += $dyn
  if (($end + 1) -lt $max)
  {
   # there is more to parse then
   $start = $value.IndexOf('${', $end + 1)
   if ($start -gt -1)
   {
    # adds the part between last foung token and current start
    $part = $value.Substring($end+1, $start - ($end + 1))
    $computed += $part
   }
   else
   {
    # that's finished then ...
    $computed += $value.Substring($end + 1)
   }
  }
  else
  {
   $start = -1
  }
 }
 return $computed
}

<#
 the actual method that resolves a value in a object
 #>
function ResolveValue ($obj, $value)
{
 if ((! $value) -or ('System.String' -ne $value.GetType().FullName))
 {
  return $value
 }
 # figure whether the value holds any part matching ${...}
 $start = $value.IndexOf('${', 0)
 if (-1 -eq $start)
 {
  return $value
 }

 $computed = ''
 $max = $value.Length
 if ($start -gt 0)
 {
  $computed += $value.Substring(0, $start)
 }

 While (($start -le $max) -and ($start -gt -1))
 {
  $end = $value.IndexOf('}', ($start + 2))
  if (-1 -eq $end)
  {
   throw 'invalid value expression (' + $value + 
    '): found starting ${ at position ' + $start + 
    ' with no closing bracket'
  }
  $part = $value.Substring( $start+2 , $end - ($start + 2));
  if (0 -eq $part.Length)
  {
   throw 'invalid value expression (' + $value + 
    '): found ${} matching empty expression at ' + $start
  }
  $dyn = ResolveDynamic $obj $part
  $computed += $dyn
  if (($end + 1) -lt $max)
  {
   # there is more to parse then
   $start = $value.IndexOf('${', $end + 1)
   if ($start -gt -1)
   {
    # adds the part between last foung token and current start
    $part = $value.Substring($end+1, $start - ($end + 1))
    $computed += $part
   }
   else
   {
    # that's finished then ...
    $computed += $value.Substring($end + 1)
   }
  }
  else
  {
   $start = -1
  }
 }
 return $computed
}

<#
 internal function used to dump object
 #>
function _DumpObjAt ($obj, $left)
{
 if ($null -eq $obj)
 {
  return 'null'
 }
 $result = ''
 if ($obj -is [System.String])
 {
  $result = '"' + $obj + '"'
 }
 elseif ($obj -is [System.Collections.Hashtable])
 {
  $result = _DumpHashTableAt $obj $left
 }
 elseif ($obj -is [System.Boolean])
 {
  if ($true -eq $obj)
  {
   $result = "true"
  }
  else
  {
   $result = "false"
  }
 }
 elseif ($obj -is [System.Array])
 {
  $result = _DumpArrayAt $obj $left
 }
 else
 {
  $result = [string]$obj
 }
 return $result
}


<#
 internal function used to dump array
 #>
function _DumpArrayAt ($arr, $left)
{
 $nl = [Environment]::NewLine
 $sb = new-object System.Text.StringBuilder
 [void]$sb.Append('[')
 $count = $arr.Length
 if (0 -lt $count)
 {
  $next = $left + ' '
  for ($index = 0; $index -lt $count; $index++)
  {
   if (0 -lt $index)
   {
    [void]$sb.Append(',')
   }
   [void]$sb.Append($nl).Append($next)
   $value = $arr[$index]
   $in = _DumpObjAt $value $next
   [void]$sb.Append($in)
  }
  [void]$sb.Append($nl)
  [void]$sb.Append($left)
 }
 [void]$sb.Append(']')
 $result = $sb.ToString()
 return $result
}

<#
 internal function used to dump .. hash table
 #>
function _DumpHashTableAt ($obj, $left)
{
 $nl = [Environment]::NewLine
 $sb = new-object System.Text.StringBuilder
 [void]$sb.Append('{')
 $next = $left + ' '
 $first = $true
 foreach ($name in $obj.Keys)
 {
  $value = $obj.($name)
  if ($first)
  {
   $first = $false
  }
  else
  {
   [void]$sb.Append(',')
  }
  [void]$sb.Append($nl)
  [void]$sb.Append($next)
  [void]$sb.Append('"')
  [void]$sb.Append($name)
  [void]$sb.Append('": ')
  $in = _DumpObjAt $value $next
  [void]$sb.Append($in)
 }
 if (!$first)
 {
  [void]$sb.Append($nl)
  [void]$sb.Append($left)
 }
 [void]$sb.Append('}')
 $result = $sb.ToString()
 return $result
}

<#
 internal function used to enumerate all resolved proproperties in an object
 #top: is the top object that allows for resolving each value
 #obj: is the object to dump resolved values
 #name: is the key of the supplied object if any
 #>
function _showResolved ($top, $obj, $name)
{
 $show = ''
 foreach ($key in $obj.Keys)
 {
  $value = $obj.($key)
  $current = $key
  if (0 -lt $name.Length)
  {
   $current = $name + '.' + $key
  }
  $part = $null
  if (($null -ne $value) -and ('System.Collections.Hashtable' -eq $value.GetType().FullName))
  {
   $part = _showResolved $top $value $current
  }
  else
  {
   $part = $current + ': ' + $top.resolve($current)
  }
  if (0 -lt $part.length)
  {
   if (0 -lt $show.length)
   {
    $show += [Environment]::NewLine
   }
   $show += $part
  }
 }
 return $show
}

<# 
 the function that returns a new object holding data for a server.ini 
 representation.
 the only thing that is performed is to add '${name}.${ini.'config' value
 @name: the alias that will identify the ini object returned
 #>
function createServerIni ($name)
{
 $ini = createObj
 $ini.SERVER_STARTUP = @{}
 $alias = '${' + $name + '.SERVER_STARTUP.docbase_name}'
 $ini.SERVER_STARTUP.server_config_name = $alias
 return $ini
}

<#
 the function that loads the server.ini file into an object
 @name: is the name that will identify the ini object returned
 @path: the full path of the .INI file to load
 #>
function getServerIni ($name, $path)
{
 $ini = createServerIni ($name)
 LoadIniFile $ini $path
 return $ini
}

<# 
 the method that creates the object that holds properties relating to the 
 docbase to migrate.
 It contains all defaults to use
 @ini: the alias for server.INI
 @env: the alias for environment variables
 @db the alias for docbase in the object to return
 @return: the created object with dynamic resolution
 #>
function createDocbaseProps ($ini, $env, $db)
{
 $docbase = createObj
 $docbase.auth = '${'+ $env + '.USERDOMAIN}'
 $docbase.config = '${' + $ini + '.SERVER_STARTUP.server_config_name}'
 $docbase.database = '${' + $ini + '.SERVER_STARTUP.database_name}'
 $docbase.dsn = '${' + $ini + '.SERVER_STARTUP.database_conn}'
 $docbase.id = '${' + $ini + '.SERVER_STARTUP.docbase_id}'
 $docbase.name = '${' + $ini + '.SERVER_STARTUP.docbase_name}'
 $docbase.pwd = 'demo.demo'
 $docbase.rdbms = 'SQLServer'
 $docbase.service = '${' + $ini + '.SERVER_STARTUP.service}'
 $docbase.user = '${' + $ini + '.SERVER_STARTUP.database_owner}'

 $docbase.datahome = ''
 $docbase.smtp = 'localhost'
 $docbase.email = ''
 $docbase.connect_mode = 'native'
 $docbase.locale = 'native'

 # the configuration for daemon
 $docbase.daemon = createObj
 $docbase.daemon.dir = '${' + $env + '.DOCUMENTUM}\dba\config\${' + $db + '.name}'
 $docbase.daemon.name = 'DmServer${ini.SERVER_STARTUP.docbase_name}'
 $docbase.daemon.display = 'Docbase Service ${ini.SERVER_STARTUP.docbase_name}'
 $docbase.daemon.ini = '${' + $db + '.daemon.dir}\server.ini'
 #$docbase.daemon.ini = 
 # '${' + $env + '.DOCUMENTUM}\dba\config\${' + $db + '.name}\server.ini'
 $docbase.daemon.logname = '${' + $db + '.name}.log'
 $docbase.daemon.log = 
  '${' + $env + '.DOCUMENTUM}\dba\log\${' + $db + '.daemon.logname}'
 $docbase.daemon.cmd = '"${' + $env + '.DM_HOME}\bin\documentum.exe" ' + 
  '-docbase_name "${' + $db + '.name}" ' + 
  '-security acl ' + 
  '-init_file "${' + $db + '.daemon.ini}" ' + 
  '-run_as_service ' + 
  '-install_owner "${' + $env + '.USERNAME}" ' + 
  '-logfile "${' + $db + '.daemon.log}"'

 # for the docbrokers: there is at least 1
 $docbase.docbrokers = createObj
 $docbase.docbrokers.'0' = createObj
 $docbase.docbrokers.'0'.host = '${' + $env + '.COMPUTERNAME}'
 $docbase.docbrokers.'0'.port = 1489

 # for the JMS
 $docbase.jms = createObj
 $docbase.jms.host = '${' + $env + '.COMPUTERNAME}'
 $docbase.jms.port = 9080

 # JMS Jboss path
 $docbase.jms.web_inf = '${' + $db + '.tools.jms}\deployments\ServerApps.ear\DmMethods.war\WEB-INF'

 # regarding previous state
 $docbase.previous = createObj
 $docbase.previous.name = '${' + $ini + '.SERVER_STARTUP.install_owner}'
 $docbase.previous.version = '6.5.SP3'
 $docbase.previous.jms = createObj
 $docbase.previous.jms.host = '${' + $db + '.previous.host}'
 $docbase.previous.jms.port = 9080

 # regarding the tools: we've got some for docbasic, composer & dars
 $docbase.tools = createObj
 $docbase.tools.install = '${' + $env + '.DM_HOME}\install'
 $docbase.tools.bin = '${' + $env + '.DM_HOME}\bin'
 $docbase.tools.dba = '${' + $env + '.DOCUMENTUM}\dba'
 $docbase.tools.config = '${' + $env + '.DOCUMENTUM}\config'
 $docbase.tools.share = '${' + $env + '.DOCUMENTUM}\share'
 $docbase.tools.fulltext = '${' + $env + '.DOCUMENTUM}\fulltext'
 $docbase.tools.dmbasic = '${' + $env + '.DM_HOME}\bin\dmbasic.exe'
 $docbase.tools.dmscripts = '${' + $db + '.tools.install}\admin'
 $docbase.tools.tools = '${' + $db + '.tools.install}\tools'
 $docbase.tools.darstore = '${' + $db + '.tools.install}\DARsInternal'
 $docbase.tools.dfc = '${' + $db + '.tools.config}\dfc.properties'
 $docbase.tools.log4j = '${' + $db + '.tools.config}\config\log4j.properties'
 $docbase.tools.composer = createObj
 $docbase.tools.composer.dir = '${' + $db + '.tools.install}\composer'
 $docbase.tools.composer.workspace = '${' + $db + '.tools.composer.dir}\workspace'
 $docbase.tools.composer.headless = '${' + $db + '.tools.composer.dir}\ComposerHeadless'
 $docbase.tools.jms = '${' + $env + '.DOCUMENTUM}\jboss7.1.1\server\DctmServer_MethodServer'

 # the configuration for the upgrade
 $docbase.upgrade = createObj

 # the docbasic scripts
 $docbase.upgrade.dmbasic = createObj
 $docbase.upgrade.dmbasic.steps = createObj
 # TODO: the invocation of the toolset.ebs normally generates the the file 'applyadmin.out'
 $docbase.upgrade.dmbasic.steps.before = 'headstart,dm_apply_formats,dm_cas_install,csec_plugin,dm_routerConv_install,templates,replicate_bootstrap,desktop_client,disable_fulltext_jobs,dfc,dfc_javadbexpr,dm_bpmmodules_install,createMethodServerObject,csec_plugin_upgrade_53,toolset,dm_bpm_install,dm_wfTimer_upgrade,create_fulltext_objects,dm_ldap_install,dm_storageservices_install,dm_emailTemplate_install'
 $docbase.upgrade.dmbasic.steps.after = 'dm_defaultevent_set,dm_jms_config_setup,dm_gr_config,javaAdminMethodInstall'

 $docbase.upgrade.dmbasic.scripts = createObj
 $docbase.upgrade.dmbasic.scripts.headstart = '-f "${docbase.tools.dmscripts}\headstart.ebs" "${docbase.tools.dmscripts}\headstart2.ebs" -P "${docbase.name}.${docbase.config}" "${env.USERNAME}" "" "" "${env.DM_HOME}" "${docbase.datahome}" "${docbase.tools.dba}" "${docbase.tools.install}" "${docbase.tools.share}" "${docbase.tools.fulltext}\dsearch" "${env.COMPUTERNAME}" "Windows" "en" "${docbase.smtp}" "${docbase.email}" "${env.USERNAME}" "${docbase.connect_mode}" "${docbase.jms.port}" "" "TRUE" dsearch -e Install'
 $docbase.upgrade.dmbasic.scripts.dm_apply_formats = '-f "${docbase.tools.bin}\dm_apply_formats.ebs" -P "noreport" "${docbase.name}.${docbase.config}" ${env.USERNAME} "" "${docbase.tools.tools}\formats.csv" trace -e testmain'
 $docbase.upgrade.dmbasic.scripts.dm_cas_install = '-f "${docbase.tools.dmscripts}\dm_cas_install.ebs" -P "${docbase.name}.${docbase.config}" ${env.USERNAME} "" "${env.DM_HOME}" "Windows"'
 $docbase.upgrade.dmbasic.scripts.csec_plugin  = '-f "${docbase.tools.dmscripts}\csec_pluging.ebs" -P "${docbase.name}.${docbase.config}" ${env.USERNAME} "" "${env.DM_HOME}" "Windows"'
 $docbase.upgrade.dmbasic.scripts.dm_routerConv_install = '-f "${docbase.tools.dmscripts}\dm_routerConv_install.ebs" -P "${docbase.name}.${docbase.config}" ${env.USERNAME} "" "NONE" -e Install'
 $docbase.upgrade.dmbasic.scripts.templates = '-f "${docbase.tools.dmscripts}\templates.ebs" -P "${docbase.name}.${docbase.config}" ${env.USERNAME} "" "${env.DM_HOME}" "${docbase.tools.install}" -e Install'
 $docbase.upgrade.dmbasic.scripts.replicate_bootstrap = '-f "${docbase.tools.bin}\dm_apply_formats.ebs" -P "${docbase.name}.${docbase.config}" "${docbase.tools.bin}" "FALSE" -e rmain'
 $docbase.upgrade.dmbasic.scripts.desktop_client = '-f "${docbase.tools.install}\desktop_client\desktop_client.ebs" -P "${docbase.name}.${docbase.config}" ${env.USERNAME} "" "${env.DM_HOME}"'
 $docbase.upgrade.dmbasic.scripts.disable_fulltext_jobs = '-f "${docbase.tools.dmscripts}\disable_fulltext_jobs.ebs" -P "${docbase.name}.${docbase.config}" ${env.USERNAME} "" -e Install'
 $docbase.upgrade.dmbasic.scripts.dfc = '-f "${docbase.tools.dmscripts}\dfc.ebs" -P "${docbase.name}.${docbase.config}" ${env.USERNAME} "" -e Install'
 $docbase.upgrade.dmbasic.scripts.dfc_javadbexpr = '-f "${docbase.tools.dmscripts}\dfc_javadbexpr.ebs" -P "${docbase.name}.${docbase.config}" ${env.USERNAME} ""'
 $docbase.upgrade.dmbasic.scripts.dm_bpmmodules_install = '-f "${docbase.tools.dmscripts}\dm_bpmodules_install.ebs" -P "${docbase.name}.${docbase.config}" ${env.USERNAME} "" "${env.DM_HOME}\lib" -e Install'
 $docbase.upgrade.dmbasic.scripts.createMethodServerObject = '-f "${docbase.tools.dmscripts}\createMethodServerObject.ebs" -P "${docbase.name}.${docbase.config}" ${env.USERNAME} ""'
 $docbase.upgrade.dmbasic.scripts.csec_plugin_upgrade_53  = '-f "${docbase.tools.dmscripts}\csec_plugin_upgrade_53.ebs" -P "${docbase.name}.${docbase.config}" ${env.USERNAME} "" "${env.DM_HOME}" -e Install'
 $docbase.upgrade.dmbasic.scripts.toolset = '-f "${docbase.tools.dmscripts}\toolset.ebs" -P "${docbase.name}.${docbase.config}" "{docbase.tools.dmscripts}" "${docbase.config}" -e ToolSet'
 $docbase.upgrade.dmbasic.scripts.dm_bpm_install = '-f "${docbase.tools.dmscripts}\dm_bpm_install.ebs" -P "${docbase.name}.${docbase.config}" ${env.USERNAME} "" -e Install'
 $docbase.upgrade.dmbasic.scripts.dm_wfTimer_upgrade = '-f "${docbase.tools.dmscripts}\dm_wfTimer_upgrade.ebs" -P "${docbase.name}.${docbase.config}" ${env.USERNAME} "" -e Install'
 $docbase.upgrade.dmbasic.scripts.create_fulltext_objects = '-f "${docbase.tools.dmscripts}\create_fulltext_objects.ebs" -P "${docbase.name}.${docbase.config}" ${env.USERNAME} "" "dsearch" -e Install'
 $docbase.upgrade.dmbasic.scripts.dm_ldap_install = '-f "${docbase.tools.dmscripts}\dm_ldap_install.ebs -P "${docbase.name}" "${docbase.tools.bin}" -e Install'
 $docbase.upgrade.dmbasic.scripts.dm_storageservices_install = '-f "${docbase.tools.dmscripts}\dm_storageservices_install.ebs -P "${docbase.name}" "${docbase.tools.bin}" "F" -e Install'
 $docbase.upgrade.dmbasic.scripts.dm_emailTemplate_install = '-f "${docbase.tools.dmscripts}\dm_emailTemplate_install.ebs" -P "${docbase.name}.${docbase.config}" ${env.USERNAME} "" -e Install'
 $docbase.upgrade.dmbasic.scripts.dm_defaultevent_set = '-e Install -- "${docbase.name}.${docbase.config}" ${env.USERNAME} ""'
 $docbase.upgrade.dmbasic.scripts.dm_jms_config_setup = '-e install -- "${docbase.name}.${docbase.config}" ${env.USERNAME} "" "${env.COMPUTERNAME}" ${docbase.jms.port}'
 $docbase.upgrade.dmbasic.scripts.dm_gr_config = '-e Install -- "${docbase.name}.${docbase.config}" ${env.USERNAME} ""'
 $docbase.upgrade.dmbasic.scripts.javaAdminMethodInstall = '-e EntryPoint -- "${docbase.name}.${docbase.config}" ${env.USERNAME} ""'


 # the dars to run
 $docbase.upgrade.dars = createObj
 # OK, registers our dars then
 $docbase.upgrade.dars.smartcontainer = createObj
 $docbase.upgrade.dars.smartcontainer.label = 'Smart Container'
 $docbase.upgrade.dars.smartcontainer.file = '${' + $db + '.tools.darstore}\Smart Container.dar'

 $docbase.upgrade.dars.webtop = createObj
 $docbase.upgrade.dars.webtop.label = 'Webtop'
 $docbase.upgrade.dars.webtop.file = '${' + $db + '.tools.darstore}\Webtop.dar'

 $docbase.upgrade.dars.workflow = createObj
 $docbase.upgrade.dars.workflow.label = 'Workflow'
 $docbase.upgrade.dars.workflow.file = '${' + $db + '.tools.darstore}\Workflow.dar'

 $docbase.upgrade.dars.presets = createObj
 $docbase.upgrade.dars.presets.label = 'Presets'
 $docbase.upgrade.dars.presets.file = '${' + $db + '.tools.darstore}\Presets.dar'

 $docbase.upgrade.dars.webtopexpress = createObj
 $docbase.upgrade.dars.webtopexpress.label = 'WebtopExpress'
 $docbase.upgrade.dars.webtopexpress.file = '${' + $db + '.tools.darstore}\Webtop Express.dar'

 $docbase.upgrade.dars.adminaccess = createObj
 $docbase.upgrade.dars.adminaccess.label = 'AdminAccess'
 $docbase.upgrade.dars.adminaccess.file = '${' + $db + '.tools.darstore}\AdminAccess.dar'

 $docbase.upgrade.dars.rar = createObj
 $docbase.upgrade.dars.rar.label = 'Resource Agents Registry'
 $docbase.upgrade.dars.rar.file = '${' + $db + '.tools.darstore}\ResourceAgentsRegistry.dar'

 $docbase.upgrade.dars.ldap = createObj
 $docbase.upgrade.dars.ldap.label = 'LDAP'
 $docbase.upgrade.dars.ldap.file = '${' + $db + '.tools.darstore}\LDAP.dar'

 $docbase.upgrade.dars.dcs = createObj
 $docbase.upgrade.dars.dcs.label = 'DCS Attachments'
 $docbase.upgrade.dars.dcs.file = '${' + $db + '.tools.darstore}\DCS Attachments.dar'

 $docbase.upgrade.dars.messaging = createObj
 $docbase.upgrade.dars.messaging.label = 'Messaging Application'
 $docbase.upgrade.dars.messaging.file = '${' + $db + '.tools.darstore}\MessagingApp.dar'

 $docbase.upgrade.dars.lc = createObj
 $docbase.upgrade.dars.lc.label = 'Java Lifecycle'
 $docbase.upgrade.dars.lc.file = '${' + $db + '.tools.darstore}\Lifecycle.dar'

 $docbase.upgrade.dars.atmos = createObj
 $docbase.upgrade.dars.atmos.label = 'ATMOS'
 $docbase.upgrade.dars.atmos.file = '${' + $db + '.tools.darstore}\ATMOS Plugin.dar'

 $docbase.upgrade.dars.esc = createObj
 $docbase.upgrade.dars.esc.label = 'Extended Search - Clustering'
 $docbase.upgrade.dars.esc.file = '${' + $db + '.tools.darstore}\Extended Search - Clustering.dar'

 $docbase.upgrade.dars.est = createObj
 $docbase.upgrade.dars.est.label = 'Extended Search - SearchTemplates'
 $docbase.upgrade.dars.est.file = '${' + $db + '.tools.darstore}\Extended Search - SearchTemplates.dar'

 $docbase.upgrade.dars.iafilter = createObj
 $docbase.upgrade.dars.iafilter.label = 'Index Agent Default Filters'
 $docbase.upgrade.dars.iafilter.file = '${' + $db + '.tools.darstore}\IndexAgentDefaultFilters.dar'

 $docbase.upgrade.dars.qbs = createObj
 $docbase.upgrade.dars.qbs.label = 'xPlore Query Base Subscription'
 $docbase.upgrade.dars.qbs.file = '${' + $db + '.tools.darstore}\qbs.dar'

 $docbase.upgrade.dars.dms = createObj
 $docbase.upgrade.dars.dms.label = 'DMS Client'
 $docbase.upgrade.dars.dms.file = '${' + $db + '.tools.darstore}\DmsClient.dar'
 # the default (main) list of dars to run
 $docbase.upgrade.dars.sets = createObj
 $docbase.upgrade.dars.sets.main='smartcontainer,webtop,workflow,presets,webtopexpress,adminaccess,rar,ldap,dcs,messaging,lc,atmos,esc,est,iafilter,qbs,dms'

 $obj = createDynaObj
 $obj.($db) = $docbase
 return $obj
}

function createUserProps ($env)
{
    $user = createObj
    $user.name = '${' + $env + '.USERNAME}'
    $user.domain = '${'+ $env + '.USERDOMAIN}'
    return $user
}

function GetDocbaseProps ($obj, $path)
{
 LoadPropertiesFile $obj $path | out-null
 return $obj
}

function GetEnvironment ()
{
 $env = createObj
 foreach ($item in Get-Childitem env:*)
 {
  $safeKey = $item.key.Replace('.', '_') 
  $env.($safeKey) = $item.value
 }
 return $env
}

<#
 the function that initializes all data of use 
 #>
function Initialize ($path)
{
 if (-not(Test-Path ($path + '\server.ini')))
 {
  throw 'missing file server.ini in ' + $path
 }
 if (-not(Test-Path ($path + '\dbpasswd.txt')))
 {
  throw 'missing file dbpasswd.txt in ' + $path
 }
 if (-not(Test-Path ($path + '\migrate.properties')))
 {
  throw 'missing file migrate.properties in ' + $path
 }
 # builds the file
 $file = createObj
 $file.config_folder = $path
 $file.server_ini = $path + '\server.ini'
 $file.dbpasswd_txt = $path + '\dbpasswd.txt'
 $file.migrate = $path + '\migrate.properties'
 $file.services = '${env.WINDIR}\System32\Drivers\etc\services'

 # loads the environment variables
 $env = getEnvironment

 $user = createUserProps('env')

 # loads the server.ini into an object
 $ini = getServerIni 'ini' $file.server_ini
 # loads the migration stuff as well
 $config = createDocbaseProps 'ini' 'env' 'docbase'
 $config.env = $env
 $config.file = $file
 $config.ini = $ini
 $config.user = $user
 $config = getDocbaseProps $config $file.migrate

 return $config
}


<#
 the method that ensures the environment is OK for further processing
 #>
function checkObj ($obj, $action)
{
 # should have a docbase id
 $val = $obj.resolve('docbase.id')
 if ($null -eq $val)
 {
  throw 'docbase.id cannot be resolved'
 }
 if (! $val -match '^[0-9]+$')
 {
  throw 'unexpected value for docbase.id: ''' + $val + ''''
 }
 # should have a docbase name
 $val = $obj.resolve('docbase.name')
 if ($null -eq $val)
 {
  throw 'docbase.name cannot be resolved'
 }
 if ($val -ne $val.Trim())
 {
  throw 'leading or trailing spaces in value for docbase.name: ''' + $val + ''''
 }
 # should have a docbase authentication server/domain
 $val = $obj.resolve('docbase.auth')
 if ($null -eq $val)
 {
  throw 'docbase.auth cannot be resolved'
 }
 if ($val -ne $val.Trim())
 {
  throw 'leading or trailing spaces in value for docbase.auth: ''' + $val + ''''
 }
 # should have a database name (schema ?)
 $val = $obj.resolve('docbase.database')
 if ($null -eq $val)
 {
  throw 'docbase.database cannot be resolved'
 }
 if ($val -ne $val.Trim())
 {
  throw 'leading or trailing spaces in value for docbase.database: ''' + $val + ''''
 }
 # should have a dsn (tns ?)
 $val = $obj.resolve('docbase.dsn')
 if ($null -eq $val)
 {
  throw 'docbase.dns cannot be resolved'
 }
 if ($val -ne $val.Trim())
 {
  throw 'leading or trailing spaces in value for docbase.dns: ''' + $val + ''''
 }
 # should have a database user login name
 $val = $obj.resolve('docbase.user')
 if ($null -eq $val)
 {
  throw 'docbase.user cannot be resolved'
 }
 if ($val -ne $val.Trim())
 {
  throw 'leading or trailing spaces in value for docbase.user: ''' + $val + ''''
 }
 # should have a service name
 $val = $obj.resolve('docbase.service')
 if ($null -eq $val)
 {
  throw 'docbase.service cannot be resolved'
 }
 if ($val -ne $val.Trim())
 {
  throw 'leading or trailing spaces in value for docbase.service: ''' + $val + ''''
 }
 # should have a previous host
 $val = $obj.resolve('docbase.previous.host')
 if ($null -eq $val)
 {
  throw 'docbase.previous.host cannot be resolved'
 }
 if ($val -ne $val.Trim())
 {
  throw 'leading or trailing spaces in value for docbase.previous.host: ''' + $val + ''''
 }
 # make sure we have location (re)definition
 if (-not $obj.ContainsKey('location')) {
  throw 'No entries for file store mapping defined in migrate.properties'
 }
 # ... TODO: make other tests: the more we make here, 
 # the faster user will know about mistakes
 return $obj
}

<#
 # the method ensure there is no trace of the server on the environment for 
 # an 'install' action or that there is a server already configured when 
 # attempting to upgrade it
 #>
function checkEnv ($obj, $action)
{
 if (($action -ne 'install') -and ($action -ne 'upgrade'))
 {
  # don't go any further
  return $obj
 }

 # make sure there is no directory ${cfg.env.documentum}\dba\config\${cfg.docbase.name}
 $val = $obj.resolve('env.DOCUMENTUM') + '\dba\config\' + $obj.resolve('docbase.name')
 $exists = test-path $val
 if ($exists)
 {
  if ($action -eq 'install')
  {
   throw 'configuration directory ''' + $val + ''' for docbase ''' + 
    $obj.resolve('docbase.name') + ''' already exists'
  }
 }
 else
 {
  if ($action -eq 'upgrade')
  {
   throw 'there is no configuration directory ' + $val
  }
 }
 Write-Host 'target config directory existence checked...'

 # make sure there is no registry entry 
 # HKEY_LOCAL_MACHINE\SOFTWARE\Documentum\DOCBASES\${cfg.docbase.name} 
 $val = 'HKLM:\Software\Documentum\DOCBASES' + '\' + $obj.resolve('docbase.name')
 $exists = test-path $val
 if ($exists)
 {
  if ($action -eq 'install')
  {
   throw 'registry key ''' + $val + ''' for docbase ''' + 
    $obj.resolve('docbase.name') + ''' already exists'
  }
 }
 else
 {
  if ($action -eq 'upgrade')
  {
   throw 'registry key ''' + $val + ''' for docbase ''' + 
    $obj.resolve('docbase.name') + ''' is not found'
  }
 }
 Write-Host 'target config registry existence checked...'

 # make sure there is no line starting with ${cfg.docbase.service} in cfg.file.services
 # ... and make sure there is no line starting with ${cfg.docbase.service}_s in cfg.file.services
 # the first case is enough
 $pattern = '^' + $obj.resolve('docbase.service') + '(_s)?.*$'
 $val = select-string -pattern ($pattern) -path ($obj.resolve('file.services'))
 $count = $val.length
 if (($action -eq 'install') -and (0 -ne $count))
 {
  throw 'service ' + $obj.resolve('docbase.service') + 
   ' already exists in file ' + $obj.resolve('file.services') + 
   ' (at line ' + $val[0].linenumber + ')'
 }
 elseif (($action -eq 'upgrade') -and (2 -ne $count))
 {
  throw '2 services ' + $obj.resolve('docbase.service') + 
   ' are not recorded in file ' + $obj.resolve('file.services')
 }
 Write-Host 'services entry checked...'

 # make sure there is an DSN named ${cfg.docbase.dsn}
 $val = 'HKLM:\Software\ODBC\ODBC.INI\' + $obj.resolve('docbase.dsn')
 if (!(test-path $val))
 {
  throw 'ODBC source ''' + $obj.resolve('docbase.dsn') + ''' for docbase ''' + 
   $obj.resolve('docbase.name') + ''' does not exists yet'
 }
 Write-Host 'ODBC configuration existence checked...'
 # make sure there is no service named ${cfg.docbase.daemon.name}
 $val = 'Name=''' + $obj.resolve('docbase.daemon.name') + ''''
 $val = Get-WmiObject -Class Win32_Service -Filter ('Name=''' + $obj.resolve('docbase.daemon.name') + '''')
 if (($action -eq 'install') -and ($val))
 {
  throw 'a service named ' + $obj.resolve('docbase.daemon.name') + ' already exists'
 }
 elseif (($action -eq 'upgrade') -and ($null -eq $val))
 {
  throw 'there is no service named ' + $obj.resolve('docbase.daemon.name')
 }
 Write-Host 'windows service existence checked...'
 # make sure we have a docbase.dsn, docbase.user and docbase.pwd
 if (!$obj.resolve('docbase.dsn'))
 {
  throw 'missing docbase.dsn property'
 }
 if (!$obj.resolve('docbase.user'))
 {
  throw 'missing docbase.user property'
 }
 if (!$obj.resolve('docbase.pwd'))
 {
  throw 'missing docbase.pwd property'
 }

 # make sure docbroker is running on ${cfg.docbroker.host}:${cfg.docbroker.port}
 $params = @('-t',$obj.resolve('docbase.docbrokers.0.host'),'-p',$obj.resolve('docbase.docbrokers.0.port'),'-c','ping')
 Log-Verbose $params
 $res = & 'dmqdocbroker'  $params 2>&1
 $val = $res | select-string -pattern '^Successful reply from docbroker at host' -quiet
 if (!$val)
 {
  throw 'there is no docbroker running on host ' + 
   $obj.resolve('env.COMPUTERNAME') + 
   '. make sure the service is installed and runnning'
 }
 elseif ($action -eq 'install')
 {
  # make sure there is no server for name ${cfg.docbase.name} on docbroker
  $params = @('-t',$obj.resolve('docbase.docbrokers.0.host'),'-p',$obj.resolve('docbase.docbrokers.0.port'),'-c','getservermap',$obj.resolve('docbase.name'))
  Log-Verbose $params
  $res = & 'dmqdocbroker'  $params 2>&1
  $val = $res | select-string -simplematch '[DM_DOCBROKER_E_NO_SERVERS_FOR_DOCBASE]error:' -quiet
  if (!$val)
  {
   throw 'there is already a docbase ' + 
    $obj.resolve('docbase.name') + 
    '. registered on the docbroker'
  } 
 }
 Write-Host 'docbroker access checked...'
 return $obj
}

function checkDB ($obj, $action)
{
 if (($action -ne 'install') -and ($action -ne 'upgrade'))
 {
  # don't go any further
  return $obj
 }
 $cnx = New-Connection $obj.ToDbConnectionString()
 try
 {
  Write-Host 'database connection checked...'
<#
- make sure there i can connect to $obj.docbase.dsn (in database $obj.docbase.database ?) with 
  login $obj.docbase.user using password $obj.docbase.pwd 
  and: SELECT r_object_id, docbase_id FROM dm_docbase_config_sv WHERE i_hasfolder = 1 AND object_name = '${cfg.docbase.name}' 
  returns 1 line only with docbase_id matching ${cfg.docbase.id}.
  ${cfg.docbase.hexid} is set to SUBSTR (r_object_id, 2, 8)
#>
  # make sure there is a config matching the docbase name and id
  $sql = 'SELECT r_object_id, r_docbase_id FROM dm_docbase_config_sv ' + 
   'WHERE i_has_folder = 1 AND object_name = ''' + $obj.resolve('docbase.name') +''''
  $table = Select-Table $cnx $sql
  if (0 -eq $table.rows.count)
  {
   throw 'cannot locate docbase config for docbase ' + 
    $obj.resolve('docbase.name') + 
    ': are we accessing it through the correct database dsn (' + 
    $obj.resolve('docbase.dsn') + ')?'
  }
  elseif (1 -lt $table.rows.count)
  {
   throw 'too many (' + $table.rows.count + ') docbase configs for docbase ' + 
    $obj.resolve('docbase.name')
  }
  else
  {
   $id = $table.rows[0].r_docbase_id
   if ($obj.resolve('docbase.id') -ne $id)
   {
    throw 'unexpected docbase id (' + $id + ') found in database for docbase ' + 
     $obj.resolve('docbase.name') + ': expected ' + $obj.resolve('docbase.id')
   }
   Write-Host 'docbase config checked...'
  }
 }
 finally
 {
  $cnx.Close()
 }
 return $obj;
}

<#
 # the method that checks the supplied object holding the configuration 
 # is compliant with the action to perform
 #>
function check ($obj, $action)
{
 # checks at the meta-data
 $obj = checkObj $obj $action
 # check at the environment
 $obj = checkEnv $obj $action
 # check against db
 $obj = checkDB $obj $action
 return $obj
}

<#
 the method that takes and object to build a registry for the 
 #>
function asDocbaseRegistry ($obj)
{
<#
"DM_AUTH_LOCATION"="${cfg.docbase.auth}"
"DM_DATABASE_NAME"="${cfg.docbase.database}"
"DM_DOCBASE_CONNECTION"="${cfg.docbase.dsn}"
"DM_DATABASE_USER"="${cfg.docbase.user}"
"DM_DATABASE_ID"="${cfg.docbase.id}"
"DM_SERVICE_NAME"="${cfg.docbase.service}"
"DM_RDBMS"="SQLServer"
"DM_HOME"="${cfg.env.dm_home}"
"DM_CONFIGURE_TIME"="${cfg.current.date}"
"DM_SERVER_VERSION"="${cfg.docbase.previous.version}"
"DOCUMENTUM"="${cfg.env.documentum}"
#>

 $reg = createObj

 # the path should not be copied !!!
 $reg.Path = 'hklm:\SOFTWARE\Documentum\DOCBASES\' + $obj.resolve('docbase.name')

 $reg.DM_AUTH_LOCATION = $obj.resolve('docbase.auth')
 $reg.DM_DATABASE_NAME = $obj.resolve('docbase.database')
 $reg.DM_DOCBASE_CONNECTION = $obj.resolve('docbase.dsn')
 $reg.DM_DATABASE_USER = $obj.resolve('docbase.user')
 $reg.DM_DATABASE_ID = $obj.resolve('docbase.id')
 $reg.DM_SERVICE_NAME = $obj.resolve('docbase.service')
 $reg.DM_RDBMS = $obj.resolve('docbase.rdbms')
 $reg.DM_HOME = $obj.resolve('env.DM_HOME')
 $now = get-date
 $culture = new-object -Type System.Globalization.CultureInfo -ArgumentList 'en-US'
 $currentDate = $now.ToString('ddd MMM dd HH:mm:ss CEST yyyy', $culture)
 $reg.DM_CONFIGURE_TIME = $currentDate
 $reg.DM_SERVER_VERSION=$obj.resolve('docbase.previous.version')
 $reg.DOCUMENTUM=$obj.resolve('env.documentum')

 return $reg
}


function asDocbaseService($obj)
{
    $svc = createObj
    $svc.name = $obj.resolve('docbase.daemon.name')
    $svc.display = $obj.resolve('docbase.daemon.display')
    $svc.commandLine = $obj.resolve('docbase.daemon.cmd')
    $usr = $obj.resolve('user.domain') + '\'+ $obj.resolve('user.name')
    $svc.credentials = New-Object System.Management.Automation.PSCredential ( $usr, $obj.user.pwd)
    return $svc
}

<#

#>
function asDbConnectionString($obj)
{
    $cnxstring = 'dsn=' + $obj.resolve('docbase.dsn') + ';uid=' + $obj.resolve('docbase.user') + ';pwd=' + $obj.resolve('docbase.pwd')
    return $cnxstring
}


$iniClassSrc = "
    public class IniFile
    {
        [System.Runtime.InteropServices.DllImport(""kernel32"")]
        private static extern long WritePrivateProfileString(string section, string key, string val, string filePath);
        [System.Runtime.InteropServices.DllImport(""kernel32"")]
        private static extern int GetPrivateProfileString(string section, string key, string def, System.Text.StringBuilder retVal, int size, string filePath);
        public static void WriteValue(string path, string Section, string Key, string Value)
        {
            WritePrivateProfileString(Section, Key, Value, path);
        }
        public static string ReadValue(string path, string Section, string Key)
        {
            System.Text.StringBuilder temp = new System.Text.StringBuilder(255);
            int i = GetPrivateProfileString(Section, Key, """", temp, 255, path);
            return temp.ToString();
        }
    }"
Add-Type -TypeDefinition $iniClassSrc | Out-Null


function Log-Info($msg)
{
    Write-Host ('' + $msg)
}

function Log-Warning($msg)
{
    Write-Warning ('' + $msg)
}

function Log-Error($msg)
{
    Write-Error ('' + $msg)
}


function Log-Verbose($msg)
{
    Write-Verbose ('' + $msg)
}
