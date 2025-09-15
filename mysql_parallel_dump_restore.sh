#!/bin/bash
# Usage:
#   Export: ./mysql_parallel_dump_restore.sh export db 6 /backup/dir
#   Import: ./mysql_parallel_dump_restore.sh import db 6 /backup/dir
#   Both:   ./mysql_parallel_dump_restore.sh both source_db target_db 6 /backup/dir

ACTION=$1; DB_NAME=$2; THREADS=$3; BACKUP_DIR=$4
MYSQL_HOST=${MYSQL_HOST:-localhost}; MYSQL_PORT=${MYSQL_PORT:-3306}
MYSQL_USER=${MYSQL_USER:-root}; MYSQL_PASS=${MYSQL_PASSWORD:-YourPassword}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LARGE_TABLES_CONF="$SCRIPT_DIR/large_tables.conf"

MYSQL_CONFIG=$(mktemp); trap "rm -f $MYSQL_CONFIG" EXIT
cat > "$MYSQL_CONFIG" << EOF
[client]
host=$MYSQL_HOST
port=$MYSQL_PORT
user=$MYSQL_USER
password=$MYSQL_PASS
max_allowed_packet=1G
net_buffer_length=32K
EOF

if [[ "$ACTION" == "both" ]]; then
  SOURCE_DB=$2; TARGET_DB=$3; THREADS=$4; BACKUP_DIR=$5
  [[ -z "$SOURCE_DB" || -z "$TARGET_DB" || -z "$THREADS" || -z "$BACKUP_DIR" ]] && { echo "Usage: $0 both <source_db> <target_db> <threads> <backup_dir>"; exit 1; }
else
  [[ -z "$ACTION" || -z "$DB_NAME" || -z "$THREADS" || -z "$BACKUP_DIR" ]] && { echo "Usage: $0 <export|import|both> <database> <threads> <backup_dir>"; exit 1; }
fi

mkdir -p "$BACKUP_DIR"

optimize_mysql() {
  mysql --defaults-file="$MYSQL_CONFIG" -e "SET GLOBAL FOREIGN_KEY_CHECKS=0; SET GLOBAL UNIQUE_CHECKS=0; SET GLOBAL AUTOCOMMIT=0; SET GLOBAL innodb_flush_log_at_trx_commit=0;" 2>/dev/null || true
}

restore_mysql() {
  mysql --defaults-file="$MYSQL_CONFIG" -e "SET GLOBAL FOREIGN_KEY_CHECKS=1; SET GLOBAL UNIQUE_CHECKS=1; SET GLOBAL AUTOCOMMIT=1; COMMIT;" 2>/dev/null || true
}

get_large_tables() {
  [[ -f "$LARGE_TABLES_CONF" ]] && grep -v '^#' "$LARGE_TABLES_CONF" | grep -v '^$' || echo ""
}

export_large_table() {
  local db=$1 table=$2 pk_col=$3 chunk_size=$4
  
  # Get actual min/max values from the table
  local min_max=$(mysql --defaults-file="$MYSQL_CONFIG" -N -e "SELECT COALESCE(MIN($pk_col), 0), COALESCE(MAX($pk_col), 0), COUNT(*) FROM $db.$table;")
  local min_id=$(echo $min_max | cut -d' ' -f1)
  local max_id=$(echo $min_max | cut -d' ' -f2)
  local row_count=$(echo $min_max | cut -d' ' -f3)
  
  [[ $row_count -eq 0 ]] && { echo "[INFO] Table $table is empty, skipping"; return; }
  
  echo "[INFO] Splitting $table ($row_count rows, ID range: $min_id-$max_id) into chunks of $chunk_size"
  
  # Export table structure first
  echo "[INFO] Exporting $table structure..."
  mysqldump --defaults-file="$MYSQL_CONFIG" --no-data $db $table | gzip > "$BACKUP_DIR/${table}_structure.sql.gz"
  
  # Simple range-based chunking
  for ((start=min_id; start<=max_id; start+=chunk_size)); do
    end=$((start + chunk_size - 1))
    [[ $end -gt $max_id ]] && end=$max_id
    echo "[INFO] Exporting $table chunk $start-$end..."
    mysqldump --defaults-file="$MYSQL_CONFIG" --single-transaction --extended-insert --quick --lock-tables=false --no-create-info --where="$pk_col >= $start AND $pk_col <= $end" $db $table | gzip > "$BACKUP_DIR/${table}_chunk_$start.sql.gz" &
    
    # Limit concurrent processes
    (($(jobs -r | wc -l) >= THREADS)) && wait
  done
  wait  # Wait for all background jobs to complete
}

export_db() {
  local db=$1
  echo "[INFO] Exporting $db with $THREADS threads..."
  START=$(date +%s)
  
  # Get all tables and large table configs
  ALL_TABLES=$(mysql --defaults-file="$MYSQL_CONFIG" -N -e "SHOW TABLES IN $db;")
  LARGE_TABLE_NAMES=$(get_large_tables | cut -d: -f1)
  
  # Export large tables with chunking
  while IFS=: read -r table pk_col chunk_size; do
    if echo "$ALL_TABLES" | grep -q "^$table$"; then
      echo "[INFO] Processing large table: $table"
      export_large_table "$db" "$table" "$pk_col" "$chunk_size"
    fi
  done < <(get_large_tables)
  
  # Export regular tables (exclude large tables)
  REGULAR_TABLES=$(echo "$ALL_TABLES" | grep -v -x -F "$(echo "$LARGE_TABLE_NAMES" | tr ' ' '\n')")
  if [[ -n "$REGULAR_TABLES" ]]; then
    echo "$REGULAR_TABLES" | parallel -j $THREADS "
      echo '[INFO] Exporting {1}...'
      mysqldump --defaults-file=$MYSQL_CONFIG --single-transaction --extended-insert --quick --lock-tables=false $db {1} | gzip > $BACKUP_DIR/{1}.sql.gz
    "
  fi
  
  echo "[INFO] Export completed in $(($(date +%s)-START)) seconds."
}

import_db() {
  local db=$1
  echo "[INFO] Importing to $db with $THREADS threads..."
  START=$(date +%s)
  mysql --defaults-file="$MYSQL_CONFIG" -e "CREATE DATABASE IF NOT EXISTS \`$db\`;"
  optimize_mysql
  
  # Import table structures first
  echo "[INFO] Creating table structures..."
  if ls "$BACKUP_DIR"/*_structure.sql.gz &>/dev/null; then
    for structure_file in "$BACKUP_DIR"/*_structure.sql.gz; do
      echo "[INFO] Creating structure from $(basename $structure_file)..."
      zcat "$structure_file" | mysql --defaults-file="$MYSQL_CONFIG" $db
    done
  fi
  
  # Import regular tables and data chunks
  if ls "$BACKUP_DIR"/*.sql.gz &>/dev/null; then
    ls "$BACKUP_DIR"/*.sql.gz | grep -v '_structure.sql.gz' | parallel -j $THREADS "
      echo '[INFO] Importing '\$(basename {1} .sql.gz)'...'
      zcat {1} | mysql --defaults-file=$MYSQL_CONFIG $db
    "
  elif ls "$BACKUP_DIR"/*.sql &>/dev/null; then
    ls "$BACKUP_DIR"/*.sql | parallel -j $THREADS "
      echo '[INFO] Importing '\$(basename {1} .sql)'...'
      mysql --defaults-file=$MYSQL_CONFIG $db < {1}
    "
  else
    echo "[ERROR] No SQL files found in $BACKUP_DIR"; exit 1
  fi
  
  restore_mysql
  echo "[INFO] Import completed in $(($(date +%s)-START)) seconds."
}

case "$ACTION" in
  export) export_db "$DB_NAME" ;;
  import) import_db "$DB_NAME" ;;
  both)
    TOTAL_START=$(date +%s)
    export_db "$SOURCE_DB"
    import_db "$TARGET_DB"
    echo "[INFO] Total operation completed in $(($(date +%s)-TOTAL_START)) seconds."
    ;;
esac