﻿<# ODBC/SQL related methods #>

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
    Executes an SQL statement against the Connection and returns ...
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
