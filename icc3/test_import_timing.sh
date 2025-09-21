#!/bin/bash
# Test import timing for icc_store.sql.tar.gz

# Make script screen/nohup compatible
trap '' HUP
set -e

DB_NAME="icc_store_sep_19"
ARCHIVE_FILE="icc_store.sql.tar.gz"

# MySQL configuration
MYSQL_USER='sgupta'
MYSQL_PASS='secwd&S1lWjnNXIPS198ppn($'
MYSQL_HOST=${MYSQL_HOST:-localhost}
MYSQL_PORT=${MYSQL_PORT:-3306}

MYSQL_CONFIG=$(mktemp); trap "rm -f $MYSQL_CONFIG" EXIT
cat > "$MYSQL_CONFIG" << EOF
[client]
user=$MYSQL_USER
password=$MYSQL_PASS
host=$MYSQL_HOST
port=$MYSQL_PORT
max_allowed_packet=1G
connect_timeout=60
wait_timeout=28800
EOF

echo "[INFO] Testing import timing for $ARCHIVE_FILE"
echo "[INFO] Target database: $DB_NAME"
echo "[INFO] Archive size: $(du -h $ARCHIVE_FILE | cut -f1)"
echo "[INFO] MySQL connection: $MYSQL_HOST:$MYSQL_PORT"

# Test MySQL connection
echo "[INFO] Testing MySQL connection..."
if ! mysql --defaults-file="$MYSQL_CONFIG" -e "SELECT 1;" >/dev/null 2>&1; then
    echo "[ERROR] Cannot connect to MySQL server"
    echo "[INFO] Trying common socket locations..."
    for socket in /var/run/mysqld/mysqld.sock /tmp/mysql.sock /var/lib/mysql/mysql.sock; do
        if [ -S "$socket" ]; then
            echo "[INFO] Found MySQL socket: $socket"
            echo "socket=$socket" >> "$MYSQL_CONFIG"
            break
        fi
    done
    
    if ! mysql --defaults-file="$MYSQL_CONFIG" -e "SELECT 1;" >/dev/null 2>&1; then
        echo "[ERROR] Still cannot connect to MySQL. Check if MySQL is running:"
        echo "sudo systemctl status mysql"
        echo "sudo systemctl start mysql"
        exit 1
    fi
fi
echo "[INFO] MySQL connection successful"

# Drop database if exists
mysql --defaults-file="$MYSQL_CONFIG" -e "DROP DATABASE IF EXISTS \`$DB_NAME\`;"

# Start timing
echo "[INFO] Starting import at $(date)"
TOTAL_START=$(date +%s)

# Create database
mysql --defaults-file="$MYSQL_CONFIG" -e "CREATE DATABASE IF NOT EXISTS \`$DB_NAME\`;"

# Optimize MySQL
mysql --defaults-file="$MYSQL_CONFIG" -e "
    SET GLOBAL FOREIGN_KEY_CHECKS=0;
    SET GLOBAL UNIQUE_CHECKS=0;
    SET GLOBAL AUTOCOMMIT=0;
    SET GLOBAL innodb_flush_log_at_trx_commit=0;
" 2>/dev/null || true

# Import with timing and progress
echo "[INFO] Extracting and importing..."
IMPORT_START=$(date +%s)

# Use pv for progress if available, otherwise regular import
if command -v pv >/dev/null 2>&1; then
    tar -xzOf "$ARCHIVE_FILE" | pv -p -t -e -r -b | mysql --defaults-file="$MYSQL_CONFIG" "$DB_NAME"
else
    tar -xzOf "$ARCHIVE_FILE" | mysql --defaults-file="$MYSQL_CONFIG" "$DB_NAME"
fi

IMPORT_END=$(date +%s)

# Restore MySQL settings
mysql --defaults-file="$MYSQL_CONFIG" -e "
    SET GLOBAL FOREIGN_KEY_CHECKS=1;
    SET GLOBAL UNIQUE_CHECKS=1;
    SET GLOBAL AUTOCOMMIT=1;
    COMMIT;
" 2>/dev/null || true

TOTAL_END=$(date +%s)

# Show results
echo ""
echo "========================================================================"
echo "IMPORT TIMING RESULTS"
echo "========================================================================"
echo "Archive file: $ARCHIVE_FILE ($(du -h $ARCHIVE_FILE | cut -f1))"
echo "Target database: $DB_NAME"
echo "Import time: $((IMPORT_END-IMPORT_START)) seconds"
echo "Total time: $((TOTAL_END-TOTAL_START)) seconds"
echo "Completed at: $(date)"

# Show database stats
STATS=$(mysql --defaults-file="$MYSQL_CONFIG" -N -e "
SELECT 
    COUNT(*) as tables,
    SUM(table_rows) as total_rows,
    ROUND(SUM(data_length + index_length) / 1024 / 1024 / 1024, 2) as size_gb
FROM information_schema.tables 
WHERE table_schema='$DB_NAME';")

echo "Database stats: $STATS"
echo "========================================================================"