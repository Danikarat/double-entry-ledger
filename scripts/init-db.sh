
#!/bin/bash
set -e

echo "Waiting for SQL Server..."

until SQLCMDPASSWORD="$MSSQL_SA_PASSWORD" \
  /opt/mssql-tools18/bin/sqlcmd \
  -S mssql -U sa -C -Q "SELECT 1" \
  >/dev/null 2>&1
do
  sleep 2
done

echo "Checking database: $MSSQL_DATABASE"

SQLCMDPASSWORD="$MSSQL_SA_PASSWORD" \
  /opt/mssql-tools18/bin/sqlcmd \
  -S mssql -U sa -C \
  -Q "IF DB_ID(N'$MSSQL_DATABASE') IS NULL
      BEGIN
        EXEC(N'CREATE DATABASE [$MSSQL_DATABASE]');
      END"

echo "Database initialization complete."