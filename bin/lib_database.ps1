<# ODBC/SQL related methods #>

# The value in second used as time out for ODBC commands
# Should be big enough to cater for long operation such as index creation
$ODBC_COMMAND_TIME_OUT = 3600

<#
 the function that returns an opened connection to the database
 @cnxString: The connection string to the DB
 #>
function New-Connection ($cnxString)
{
    $cnx = new-object System.Data.Odbc.OdbcConnection
    $cnx.ConnectionString = $cnxString
    $cnx.Open()
    if ($cnx.State -ne [System.Data.ConnectionState]::Open)
    {
        throw 'can''t open database ' + $cnx.Database
    }
    return $cnx
}

<#
 the method that retrieves results matching the supplied SQL (select) query
 @returns: the first returned (data)table
 #>
function Select-Table ([System.Data.Odbc.OdbcConnection]$cnx, $sql)
{
    Log-Verbose "Select-Table - SQL Statement: $sql"
    $cmd = new-object System.Data.Odbc.OdbcCommand $sql,$cnx
    try
    {
     $cmd.CommandTimeout = $ODBC_COMMAND_TIME_OUT
     $da = new-object System.Data.Odbc.OdbcDataAdapter $cmd
     try
     {
         $table = new-object System.Data.DataTable
         $da.Fill($table) | out-null
         # be carefull: it's considered as a collection ...
         # therefore returned as an array if not empty
         return ,$table
     }
     finally
     {
         $da.Dispose()
     }
    }
    finally
    {
     $cmd.Dispose()
    }
}

<# 
    Executes an SQL statement against the Connection and returns the number of rows affected.
    For UPDATE, INSERT, and DELETE statements, the return value is the number of rows affected 
    by the command. For all other types of statements, the return value is -1.
#>
function Execute-NonQuery ([System.Data.Odbc.OdbcConnection]$cnx, $sql)
{       
    Log-Verbose "Execute-NonQuery - SQL Statement: $sql"
    $command = $cnx.CreateCommand()
    $command.CommandTimeout = $ODBC_COMMAND_TIME_OUT
    $command.CommandText  = $sql
    $count = $command.ExecuteNonQuery()
    Log-Verbose "$count row(s) affected"
    return $count
}


<# 
    Executes an SQL statement against the Connection and 
    returns the 1st column of the 1st row
#>
function Execute-Scalar ($cnx, $sql)
{  
    Log-Verbose "Execute-Scalar - SQL Statement: $sql"
    $command = $cnx.CreateCommand()
    $command.CommandTimeout = $ODBC_COMMAND_TIME_OUT
    $command.CommandText  = $sql
    $result = $command.ExecuteScalar()
    Log-Verbose "Result = $result"
    return $result  
}

<#
    Checks wether or not a table exists in the current schemas
#>
function Test-TableExists ($cnx, $name)
{
    $sql = 'SELECT t.name FROM sys.tables t, sys.schemas s ' + 
        'WHERE t.name = ''' + $name + ''' AND t.type = ''U'' AND t.schema_id = s.schema_id AND s.name = ''dbo'''
    $r = Execute-Scalar -cnx $cnx -sql $sql
    if ($r)
    {
        return $true
    }
    return $false
}
