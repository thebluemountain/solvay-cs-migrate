<# 
 the script to call to migrate docbase
 it accepts the following parameters:
 
 #>

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
  $sub = @{}
  $obj.($name) = $sub
  return $sub;
 }
 throw "there is no object for key $name"
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
   #$ini.($currentkey) = 
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
 $type = $obj.GetType().FullName
 if ('System.String' -eq $type)
 {
  $result = '"' + $obj + '"'
 }
 elseif ('System.Collections.Hashtable' -eq $type)
 {
  $result = _DumpHashTableAt $obj $left
 }
 elseif ('System.Boolean' -eq $type)
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
 elseif ($obj.GetType().IsArray)
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
 @obj: the alias for current object
 @file: the alias for files
 #>
function createDocbaseProps ($ini, $env, $docbase)
{
 $obj = createObj
 $obj.auth = '${'+ $env + '.USERDOMAIN}'
 $obj.config = '${' + $ini + '.SERVER_STARTUP.server_config_name}'
 $obj.database = '${' + $ini + '.SERVER_STARTUP.database_name}'
 $obj.dsn = '${' + $ini + '.SERVER_STARTUP.database_conn}'
 $obj.id = '${' + $ini + '.SERVER_STARTUP.docbase_id}'
 $obj.name = '${' + $ini + '.SERVER_STARTUP.docbase_name}'
 $obj.pwd = 'demo.demo'
 $obj.rdbms = 'SQLServer'
 $obj.service = '${' + $ini + '.SERVER_STARTUP.service}'
 $obj.user = '${' + $ini + '.SERVER_STARTUP.database_owner}'

 $obj.previous = @{}
 $obj.previous.install = @{}
 $obj.previous.install.name = '${' + $ini + '.SERVER_STARTUP.install_owner}'
 $obj.previous.version = '6.5.SP3'

 $obj.daemon = @{}
 $obj.daemon.name = 'DmServer${ini.SERVER_STARTUP.docbase_name}'
 $obj.daemon.display = 'Docbase Service ${ini.SERVER_STARTUP.docbase_name}'
 $obj.daemon.ini = 
  '${' + $env + '.DOCUMENTUM}\dba\config\${' + $docbase + '.name}\server.ini'
 $obj.daemon.logname = '${' + $docbase + '.name}.log'
 $obj.daemon.log = 
  '${' + $env + '.DOCUMENTUM}\dba\log\${' + $docbase + '.daemon.logname}'
 
 $obj.daemon.cmd = '"${' + $env + '.DM_HOME}\bin\documentum.exe "' + 
  '-docbase_name "${' + $docbase + '.name}" ' + 
  '-security acl ' + 
  '-init_file "${' + $docbase + '.daemon.ini}" ' + 
  '-run_as_service ' + 
  '-install_owner "${' + $env + '.USERNAME}" ' + 
  '-logfile "${' + $docbase + '.daemon.log}"'

 $obj.docbroker = @{}
 $obj.docbroker.host = '${' + $env + '.COMPUTERNAME}'
 $obj.docbroker.port = 1489
 return $obj
}

function GetDocbaseProps ($ini, $env, $obj, $path)
{
 $docbase = createDocbaseProps $ini $env $obj
 LoadPropertiesFile $docbase $path
 return $docbase
}

function GetEnvironment ()
{
 $env = createObj
 foreach ($item in Get-Childitem env:*)
 {
  $env.($item.key) = $item.value
 }
 return $env
}

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
 return $obj
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
 $file.server_ini = $path + '\server.ini'
 $file.dbpasswd_txt = $path + '\dbpasswd.txt'
 $file.migrate = $path + '\migrate.properties'
 $file.services = '${env.WINDIR}\System32\Drivers\etc\services.'

 # loads the environment variables
 $env = getEnvironment
 
 # loads the server.ini into an object
 $ini = getServerIni 'ini' $file.server_ini
 # loads the migration stuff as well
 $docbase = getDocbaseProps 'ini' 'env' 'docbase' $file.migrate

 $obj = createDynaObj
 $obj.env = $env
 $obj.file = $file
 $obj.ini = $ini
 $obj.docbase = $docbase
 return $obj
}

<# ODBC/SQL related methods #>
<#
 the function that returns an opened connection to the database
 @dsn: identifies an ODBC data source's name
 @user: holds the name of the user to connect as
 @pwd: holds the password to use
 #>
function getConnect ($dsn, $user, $pwd)
{
 $cnx = new-object System.Data.Odbc.OdbcConnection
 $cnx.ConnectionString = 'dsn=' + $dsn + ';uid=' + $user + ';pwd=' + $pwd
 $cnx.Open()
 if ($cnx.State -ne [System.Data.ConnectionState]::Open)
 {
  throw 'can''t open database ' + $dsn
 }
 return $cnx
}

<#
 the method that retrieves results matching the supplied SQL (select) query
 @returns: the first returned (data)table
 #>
function selectTable ($cnx, $sql)
{
 $da = new-object System.Data.Odbc.OdbcDataAdapter $sql,$cnx
 try
 {
  $table = new-object System.Data.DataTable
  $da.Fill($table) | out-null
  # be carefull: it's considered as a collection ...
  # therefore returned as an array is not empty
  return ,$table
 }
 finally
 {
  $da.Dispose()
 }
}

<#
 the method that ensures the environment is OK for further processing
 #>
function checkObj ($obj)
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
 # ... TODO: make other tests: the more we make here, 
 # the faster user will know about mistakes
 return $obj
}

function checkEnv ($obj)
{
<#
- make sure there i can connect to ${cfg.docbase.dsn} in database ${cfg.docbase.database} with 
  login ${cfg.docbase.user} using password ${cfg.docbase.pwd} 
  and: SELECT r_object_id, docbase_id FROM dm_docbase_config_sv WHERE i_hasfolder = 1 AND object_name = '${cfg.docbase.name}'   
  returns 1 line only with docbase_id matching ${cfg.docbase.id}.
  ${cfg.docbase.hexid} is set to SUBSTR (r_object_id, 2, 8)
#>
 # make sure there is no directory ${cfg.env.documentum}\dba\config\${cfg.docbase.name}
 $val = $obj.resolve('env.DOCUMENTUM') + '\dba\config\' + $obj.resolve('docbase.name')
 if (test-path $val)
 {
  throw 'configuration directory ''' + $val + ''' for docbase ''' + 
   $obj.resolve('docbase.name') + ''' already exists'
 }

 # make sure there is no registry entry 
 # HKEY_LOCAL_MACHINE\SOFTWARE\Documentum\DOCBASES\${cfg.docbase.name} 
 $val = 'HKLM:\Software\Documentum\DOCBASES'
 if (!(test-path $val))
 {
  throw 'registry key ''' + $val + ''' for documentum docbases does not exist'
 }
 $val += '\' + $obj.resolve('docbase.name')
 if (test-path $val)
 {
  throw 'registry key ''' + $val + ''' for docbase ''' + 
   $obj.resolve('docbase.name') + ''' already exists'
 }
 # make sure there is no line starting with ${cfg.docbase.service} in cfg.file.services
 # ... and make sure there is no line starting with ${cfg.docbase.service}_s in cfg.file.services
 # the first case is enough
 $pattern = '^' + $obj.resolve('docbase.service')
 $val = select-string -pattern ($pattern) -path ($obj.resolve('file.services'))
 if (0 -lt $val.length)
 {
  throw 'service ' + $obj.resolve('docbase.service') + 
   ' already exists in file ' + $obj.resolve('file.services') + 
   ' (at line ' + $val[0].linenumber + ')'
 }
 # make sure there is an DSN named ${cfg.docbase.dsn}
 $val = 'HKLM:\Software\ODBC\ODBC.INI\ODBC Data Sources\' + $obj.resolve('docbase.dsn')
 if (!(test-path $val))
 {
  throw 'ODBC source ''' + $obj.resolve('docbase.dsn') + ''' for docbase ''' + 
   $obj.resolve('docbase.name') + ''' does not exists yet'
 }
 # make sure there is no service named ${cfg.docbase.daemon.name}
 $val = 'Name=''' + $obj.resolve('docbase.daemon.name') + ''''
 $val = Get-WmiObject -Class Win32_Service -Filter ('Name=''' + $obj.resolve('docbase.daemon.name') + '''')
 if ($val)
 {
  throw 'a service named ' + $obj.resolve('docbase.daemon.name') + ' already exists'
 }
 <#
 # make sure docbroker is running on ${cfg.docbroker.host}:${cfg.docbroker.port}
 $val = & 'dmqdocbroker'  '-t',$obj.resolve('docbase.docbroker.host'),'-p',$obj.resolve('docbase.docbroker.port'),'-c','ping' 2>&1 | select-string -pattern '^Successful reply from docbroker at host'
 if ((!$val) -or (0 -eq $val.length))
 {
  throw 'there is no docbroker running on host ' + 
   $obj.resolve('env.COMPUTERNAME') + 
   '. make sure the service is installed and runnning'
 }
 else
 {
  # make sure there is no server for name ${cfg.docbase.name} on docbroker
  $val = & 'dmqdocbroker' '-t',$obj.resolve('docbase.docbroker.host'),'-p',$obj.resolve('docbase.docbroker.port'),'-c','isaserveropen',$obj.resolve('docbase.name') 2>&1 | select-string -pattern '^Open servers for docbase:'
  if (($val) -and (0 -lt $val.length))
  {
   throw 'there is already a docbase ' + 
   $obj.resolve('docbase.name') + 
   '. registered on the docbroker'
  }
 }
 #>
 return $obj
}

function check ($obj)
{
 # checks at the meta-data
 $obj = checkObj $obj
 # check at the environment
 $obj = checkEnv $obj
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
 $reg.DM_AUTH_LOCATION = $obj.resolve('docbase.auth')
 $reg.DM_DATABASE_NAME = $obj.resolve('docbase.database')
 $reg.DM_DOCBASE_CONNECTION = $obj.resolve('docbase.dsn')
 $reg.DM_DATABASE_USER = $obj.resolve('docbase.user')
 $reg.DM_DATABASE_ID = $obj.resolve('docbase.id')
 $reg.DM_SERVICE_NAME = $obj.resolve('docbase.service')
 $reg.DM_RDBMS = $obj.resolve('docbase.rdbms')
 $reg.DM_HOME = $obj.resolve('env.DM_HOME')
 #$reg.CONFIGURE_TIME = 
}


<#
 starting the method then
#>

# 1: get the path to scan info
$path = ''
if (0 -lt $args.length)
{
 $path = $args[0]
}
else
{
 $path = $pwd.ToString()
}
# change it for the test
#$path = 'C:\Users\nguyed1\Documents\sample1'

write-host ('current path: ' + $path)

# 2: initialize the environment
$obj = Initialize $path
$obj.docbase.rdbms = 'SQLServer'
if (! $obj.env.Contains('DOCUMENTUM'))
{
 $obj.env.DOCUMENTUM = '${env.HOMEDRIVE}${env.HOMEPATH}\Documents\Documentum'
}
if (! $obj.env.Contains('DM_HOME'))
{
 $obj.env.DM_HOME = '${env.DOCUMENTUM}\prog\7.1'
}

# 3: make sure the environment seems OK
$obj = check $obj

# that's just for playing ....
<#
write-host ($obj.dump())
write-host ('-----------')
write-host ($obj.show())
write-host ('-----------')
#>

write-host ('>' + $obj.resolve('docbase.id') + '<')
write-host ('>' + $obj.docbase.daemon.cmd + '<')
write-host ('>' + $obj.resolve('docbase.daemon.cmd') + '<')
write-host ('>' + $obj.resolve('docbase.toto.titi.tutu') + '<')
#showResolved $obj $obj ''
#'docbase.daemon.cmd: >' + $obj.docbase.daemon.cmd + '<'
#'resolved.docbase.daemon.cmd: >' + $obj.resolve('docbase.daemon.cmd') + '<'

$cnx = GetConnect 'db1' 'postgres' 'password'
try
{
 write-host ('connected...')
 $sql = 'SELECT r_object_id, r_docbase_id FROM dm_docbase_config_sv ' + 
  'WHERE i_has_folder = 1 AND object_name = ''' + $obj.resolve('docbase.name') +''''
 $table = selectTable $cnx $sql
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
 }
 write-host 'done'
}

finally
{
 $cnx.Close()
 $cnx = $null
}
