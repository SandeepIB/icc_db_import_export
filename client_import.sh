#!/bin/bash
# Client Database Import Tool - Optimized for maximum performance

DB_NAME=${1:-icc_store_local}
THREADS=${2:-8}
ARCHIVE_FILE="icc_store.sql.tar.gz"
TEMP_DIR="/tmp/mysql_import_$$"

# MySQL configuration
MYSQL_USER=${MYSQL_USER:-root}
MYSQL_PASS=${MYSQL_PASSWORD:-YourPassword}
MYSQL_HOST=${MYSQL_HOST:-localhost}
MYSQL_PORT=${MYSQL_PORT:-3306}

# Create optimized MySQL config
MYSQL_CONFIG=$(mktemp); trap "rm -f $MYSQL_CONFIG; rm -rf $TEMP_DIR" EXIT
cat > "$MYSQL_CONFIG" << EOF
[client]
user=$MYSQL_USER
password=$MYSQL_PASS
host=$MYSQL_HOST
port=$MYSQL_PORT
max_allowed_packet=1G
net_buffer_length=1M
connect_timeout=300
wait_timeout=28800
interactive_timeout=28800
EOF

echo "=== Client Database Import Tool ==="
echo "[INFO] Importing $ARCHIVE_FILE to database: $DB_NAME"
echo "[INFO] Using $THREADS parallel threads"

# Check dependencies
for cmd in mysql parallel tar; do
    if ! command -v $cmd >/dev/null; then
        echo "[ERROR] Required command '$cmd' not found"
        echo "[INFO] Install with: sudo apt install mysql-client parallel"
        exit 1
    fi
done

if [ ! -f "$ARCHIVE_FILE" ]; then
    echo "[ERROR] Archive file $ARCHIVE_FILE not found in current directory"
    exit 1
fi

mkdir -p "$TEMP_DIR"

# Create database
echo "[INFO] Creating database..."
mysql --defaults-file="$MYSQL_CONFIG" -e "CREATE DATABASE IF NOT EXISTS \`$DB_NAME\`;" || {
    echo "[ERROR] Failed to create database. Check MySQL credentials."
    exit 1
}

# Apply performance optimizations
echo "[INFO] Optimizing MySQL for import..."
mysql --defaults-file="$MYSQL_CONFIG" -e "
    SET GLOBAL FOREIGN_KEY_CHECKS=0;
    SET GLOBAL UNIQUE_CHECKS=0;
    SET GLOBAL AUTOCOMMIT=0;
    SET GLOBAL innodb_flush_log_at_trx_commit=0;
    SET GLOBAL innodb_doublewrite=0;
    SET GLOBAL bulk_insert_buffer_size=256M;
    SET GLOBAL sort_buffer_size=16M;
    SET GLOBAL read_buffer_size=8M;
    SET GLOBAL max_heap_table_size=256M;
    SET GLOBAL tmp_table_size=256M;
    SET GLOBAL query_cache_size=0;
    SET GLOBAL sync_binlog=0;
" 2>/dev/null || true

START=$(date +%s)

# Analyze archive
echo "[INFO] Analyzing archive..."
FILE_COUNT=$(tar -tzf "$ARCHIVE_FILE" | wc -l)

if [ "$FILE_COUNT" -eq 1 ]; then
    # Single file - split for parallel processing
    echo "[INFO] Processing single file with parallel chunks..."
    
    TEMP_SQL="$TEMP_DIR/dump.sql"
    tar -xzf "$ARCHIVE_FILE" -C "$TEMP_DIR"
    mv "$TEMP_DIR"/*.sql "$TEMP_SQL" 2>/dev/null || true
    
    if [ -f "$TEMP_SQL" ]; then
        split -l 10000 --numeric-suffixes=1 "$TEMP_SQL" "$TEMP_DIR/chunk_"
        echo "[INFO] Importing $(ls $TEMP_DIR/chunk_* | wc -l) chunks..."
        ls "$TEMP_DIR"/chunk_* | parallel -j"$THREADS" --bar \
            "mysql --defaults-file='$MYSQL_CONFIG' '$DB_NAME' < {}"
    else
        echo "[ERROR] Could not extract SQL file"
        exit 1
    fi
else
    # Multiple files
    echo "[INFO] Processing $FILE_COUNT files in parallel..."
    tar -xzf "$ARCHIVE_FILE" -C "$TEMP_DIR"
    
    find "$TEMP_DIR" -name "*.sql" -o -name "*.sql.gz" | parallel -j"$THREADS" --bar '
        if [[ {} == *.gz ]]; then
            zcat "{}" | mysql --defaults-file="'$MYSQL_CONFIG'" "'$DB_NAME'"
        else
            mysql --defaults-file="'$MYSQL_CONFIG'" "'$DB_NAME'" < "{}"
        fi
    '
fi

# Finalize
echo "[INFO] Finalizing import..."
mysql --defaults-file="$MYSQL_CONFIG" "$DB_NAME" -e "COMMIT;"

# Restore settings
mysql --defaults-file="$MYSQL_CONFIG" -e "
    SET GLOBAL FOREIGN_KEY_CHECKS=1;
    SET GLOBAL UNIQUE_CHECKS=1;
    SET GLOBAL AUTOCOMMIT=1;
    SET GLOBAL innodb_flush_log_at_trx_commit=1;
    SET GLOBAL innodb_doublewrite=1;
    SET GLOBAL sync_binlog=1;
    COMMIT;
" 2>/dev/null || true

END=$(date +%s)
TOTAL_TIME=$((END-START))
echo "=== Import Complete ==="
echo "[SUCCESS] Database '$DB_NAME' imported in ${TOTAL_TIME}s ($((TOTAL_TIME/60))m $((TOTAL_TIME%60))s)"
echo "[INFO] Ready to use!"