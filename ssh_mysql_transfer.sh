#!/bin/bash
# Usage:
#   Remote export to local import: ./ssh_mysql_transfer.sh remote_to_local <remote_db> <local_db> <threads> <backup_dir>
#   Remote export only: ./ssh_mysql_transfer.sh export <remote_db> <threads> <backup_dir>
#   Local import only: ./ssh_mysql_transfer.sh import <local_db> <threads> <backup_dir>

ACTION=$1; DB_NAME=$2; THREADS=${3:-6}; BACKUP_DIR=${4:-/tmp/ssh_backup}

# Remote SSH configuration
REMOTE_HOST=${REMOTE_HOST:-10.100.23.56}
REMOTE_USER=${REMOTE_USER:-sgupta}
REMOTE_MYSQL_USER=${REMOTE_MYSQL_USER:-sgupta}

# Local MySQL configuration
LOCAL_MYSQL_HOST=${LOCAL_MYSQL_HOST:-localhost}
LOCAL_MYSQL_USER=${LOCAL_MYSQL_USER:-root}
LOCAL_MYSQL_PASS=${LOCAL_MYSQL_PASSWORD:-YourPassword}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LARGE_TABLES_CONF="$SCRIPT_DIR/large_tables.conf"

# Create local MySQL config
LOCAL_CONFIG=$(mktemp); trap "rm -f $LOCAL_CONFIG" EXIT
cat > "$LOCAL_CONFIG" << EOF
[client]
host=$LOCAL_MYSQL_HOST
user=$LOCAL_MYSQL_USER
password=$LOCAL_MYSQL_PASS
max_allowed_packet=1G
net_buffer_length=32K
EOF

get_large_tables() {
  [[ -f "$LARGE_TABLES_CONF" ]] && grep -v '^#' "$LARGE_TABLES_CONF" | grep -v '^$' || echo ""
}

remote_export_large_table() {
  local remote_db=$1 table=$2 pk_col=$3 chunk_size=$4
  
  # Get min/max values from remote table
  local min_max=$(ssh $REMOTE_USER@$REMOTE_HOST "mysql -u $REMOTE_MYSQL_USER -p -N -e \"SELECT COALESCE(MIN($pk_col), 0), COALESCE(MAX($pk_col), 0), COUNT(*) FROM $remote_db.$table;\"")
  local min_id=$(echo $min_max | cut -d' ' -f1)
  local max_id=$(echo $min_max | cut -d' ' -f2)
  local row_count=$(echo $min_max | cut -d' ' -f3)
  
  [[ $row_count -eq 0 ]] && { echo "[INFO] Remote table $table is empty, skipping"; return; }
  
  echo "[INFO] Remote splitting $table ($row_count rows, ID range: $min_id-$max_id) into chunks of $chunk_size"
  
  # Export table structure first
  echo "[INFO] Exporting remote $table structure..."
  ssh $REMOTE_USER@$REMOTE_HOST "mysqldump -u $REMOTE_MYSQL_USER -p --no-data $remote_db $table" | gzip > "$BACKUP_DIR/${table}_structure.sql.gz"
  
  # Export chunks in parallel
  for ((start=min_id; start<=max_id; start+=chunk_size)); do
    end=$((start + chunk_size - 1))
    [[ $end -gt $max_id ]] && end=$max_id
    echo "[INFO] Exporting remote $table chunk $start-$end..."
    ssh $REMOTE_USER@$REMOTE_HOST "mysqldump -u $REMOTE_MYSQL_USER -p --single-transaction --extended-insert --quick --lock-tables=false --no-create-info --where=\"$pk_col >= $start AND $pk_col <= $end\" $remote_db $table" | gzip > "$BACKUP_DIR/${table}_chunk_$start.sql.gz" &
    
    # Limit concurrent processes
    (($(jobs -r | wc -l) >= THREADS)) && wait
  done
  wait
}

remote_export() {
  local remote_db=$1
  echo "[INFO] Exporting $remote_db from $REMOTE_USER@$REMOTE_HOST with $THREADS threads..."
  START=$(date +%s)
  mkdir -p "$BACKUP_DIR"
  
  # Get all tables from remote
  ALL_TABLES=$(ssh $REMOTE_USER@$REMOTE_HOST "mysql -u $REMOTE_MYSQL_USER -p -N -e \"SHOW TABLES IN $remote_db;\"")
  LARGE_TABLE_NAMES=$(get_large_tables | cut -d: -f1)
  
  # Export large tables with chunking
  while IFS=: read -r table pk_col chunk_size; do
    if echo "$ALL_TABLES" | grep -q "^$table$"; then
      echo "[INFO] Processing remote large table: $table"
      remote_export_large_table "$remote_db" "$table" "$pk_col" "$chunk_size"
    fi
  done < <(get_large_tables)
  
  # Export regular tables in parallel
  REGULAR_TABLES=$(echo "$ALL_TABLES" | grep -v -x -F "$(echo "$LARGE_TABLE_NAMES" | tr ' ' '\n')")
  if [[ -n "$REGULAR_TABLES" ]]; then
    echo "$REGULAR_TABLES" | parallel -j $THREADS "
      echo '[INFO] Exporting remote {1}...'
      ssh $REMOTE_USER@$REMOTE_HOST \"mysqldump -u $REMOTE_MYSQL_USER -p --single-transaction --extended-insert --quick --lock-tables=false $remote_db {1}\" | gzip > $BACKUP_DIR/{1}.sql.gz
    "
  fi
  
  echo "[INFO] Remote export completed in $(($(date +%s)-START)) seconds."
}

local_import() {
  local local_db=$1
  echo "[INFO] Importing to local database $local_db with $THREADS threads..."
  START=$(date +%s)
  
  # Create database if it doesn't exist
  mysql --defaults-file="$LOCAL_CONFIG" -e "CREATE DATABASE IF NOT EXISTS \`$local_db\`;"
  
  # Optimize MySQL for import
  mysql --defaults-file="$LOCAL_CONFIG" -e "
    SET GLOBAL FOREIGN_KEY_CHECKS=0;
    SET GLOBAL UNIQUE_CHECKS=0;
    SET GLOBAL AUTOCOMMIT=0;
    SET GLOBAL innodb_flush_log_at_trx_commit=0;
  " 2>/dev/null || true
  
  # Import table structures first
  echo "[INFO] Creating table structures..."
  if ls "$BACKUP_DIR"/*_structure.sql.gz &>/dev/null; then
    for structure_file in "$BACKUP_DIR"/*_structure.sql.gz; do
      echo "[INFO] Creating structure from $(basename $structure_file)..."
      zcat "$structure_file" | mysql --defaults-file="$LOCAL_CONFIG" $local_db
    done
  fi
  
  # Import regular tables and data chunks in parallel
  if ls "$BACKUP_DIR"/*.sql.gz &>/dev/null; then
    ls "$BACKUP_DIR"/*.sql.gz | grep -v '_structure.sql.gz' | parallel -j $THREADS "
      echo '[INFO] Importing '\$(basename {1} .sql.gz)'...'
      zcat {1} | mysql --defaults-file=$LOCAL_CONFIG $local_db
    "
  elif ls "$BACKUP_DIR"/*.sql &>/dev/null; then
    ls "$BACKUP_DIR"/*.sql | parallel -j $THREADS "
      echo '[INFO] Importing '\$(basename {1} .sql)'...'
      mysql --defaults-file=$LOCAL_CONFIG $local_db < {1}
    "
  else
    echo "[ERROR] No SQL files found in $BACKUP_DIR"; exit 1
  fi
  
  # Restore MySQL settings
  mysql --defaults-file="$LOCAL_CONFIG" -e "
    SET GLOBAL FOREIGN_KEY_CHECKS=1;
    SET GLOBAL UNIQUE_CHECKS=1;
    SET GLOBAL AUTOCOMMIT=1;
    COMMIT;
  " 2>/dev/null || true
  
  echo "[INFO] Local import completed in $(($(date +%s)-START)) seconds."
}

remote_to_local() {
  local remote_db=$1
  local local_db=$2
  
  echo "[INFO] Starting multithreaded remote export and local import: $remote_db -> $local_db"
  TOTAL_START=$(date +%s)
  
  # Export from remote with chunking
  remote_export "$remote_db"
  
  # Import to local with parallel processing
  local_import "$local_db"
  
  echo "[INFO] Total transfer completed in $(($(date +%s)-TOTAL_START)) seconds."
}

case "$ACTION" in
  remote_to_local)
    TARGET=$3; THREADS=${4:-6}; BACKUP_DIR=${5:-/tmp/ssh_backup}
    [[ -z "$DB_NAME" || -z "$TARGET" ]] && { echo "Usage: $0 remote_to_local <remote_db> <local_db> [threads] [backup_dir]"; exit 1; }
    remote_to_local "$DB_NAME" "$TARGET"
    ;;
  export)
    [[ -z "$DB_NAME" ]] && { echo "Usage: $0 export <remote_db> [threads] [backup_dir]"; exit 1; }
    remote_export "$DB_NAME"
    ;;
  import)
    TARGET=$3; THREADS=${4:-6}; BACKUP_DIR=${5:-/tmp/ssh_backup}
    [[ -z "$DB_NAME" ]] && { echo "Usage: $0 import <local_db> [threads] [backup_dir]"; exit 1; }
    local_import "$DB_NAME"
    ;;
  *)
    echo "Usage: $0 {remote_to_local|export|import} <database> [target] [threads] [backup_dir]"
    echo "Examples:"
    echo "  $0 remote_to_local icc_store icc_store_local 6 /tmp/backup"
    echo "  $0 export icc_store 6 /tmp/backup"
    echo "  $0 import icc_store_local 6 /tmp/backup"
    exit 1
    ;;
esac