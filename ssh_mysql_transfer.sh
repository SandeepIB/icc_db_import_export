#!/bin/bash
# Usage:
#   Remote export to local import: ./ssh_mysql_transfer.sh remote_to_local <remote_db> <local_db>
#   Remote export only: ./ssh_mysql_transfer.sh export <remote_db> <output_file>
#   Local import only: ./ssh_mysql_transfer.sh import <local_db> <input_file>

ACTION=$1; DB_NAME=$2; TARGET=$3

# Remote SSH configuration
REMOTE_HOST=${REMOTE_HOST:-10.100.23.56}
REMOTE_USER=${REMOTE_USER:-sgupta}
REMOTE_MYSQL_USER=${REMOTE_MYSQL_USER:-sgupta}

# Local MySQL configuration
LOCAL_MYSQL_HOST=${LOCAL_MYSQL_HOST:-localhost}
LOCAL_MYSQL_USER=${LOCAL_MYSQL_USER:-root}
LOCAL_MYSQL_PASS=${LOCAL_MYSQL_PASSWORD:-YourPassword}

# Create local MySQL config
LOCAL_CONFIG=$(mktemp); trap "rm -f $LOCAL_CONFIG" EXIT
cat > "$LOCAL_CONFIG" << EOF
[client]
host=$LOCAL_MYSQL_HOST
user=$LOCAL_MYSQL_USER
password=$LOCAL_MYSQL_PASS
EOF

remote_export() {
  local remote_db=$1
  local output_file=${2:-${remote_db}.sql}
  
  echo "[INFO] Exporting $remote_db from $REMOTE_USER@$REMOTE_HOST..."
  START=$(date +%s)
  
  ssh $REMOTE_USER@$REMOTE_HOST "mysqldump -u $REMOTE_MYSQL_USER -p $remote_db" > "$output_file"
  
  if [[ $? -eq 0 ]]; then
    echo "[INFO] Remote export completed in $(($(date +%s)-START)) seconds."
    echo "[INFO] Database exported to: $output_file"
  else
    echo "[ERROR] Remote export failed"
    exit 1
  fi
}

local_import() {
  local local_db=$1
  local input_file=$2
  
  echo "[INFO] Importing $input_file to local database $local_db..."
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
  
  # Import the database
  mysql --defaults-file="$LOCAL_CONFIG" "$local_db" < "$input_file"
  
  # Restore MySQL settings
  mysql --defaults-file="$LOCAL_CONFIG" -e "
    SET GLOBAL FOREIGN_KEY_CHECKS=1;
    SET GLOBAL UNIQUE_CHECKS=1;
    SET GLOBAL AUTOCOMMIT=1;
    COMMIT;
  " 2>/dev/null || true
  
  if [[ $? -eq 0 ]]; then
    echo "[INFO] Local import completed in $(($(date +%s)-START)) seconds."
  else
    echo "[ERROR] Local import failed"
    exit 1
  fi
}

remote_to_local() {
  local remote_db=$1
  local local_db=$2
  local temp_file=$(mktemp --suffix=.sql)
  
  echo "[INFO] Starting remote export and local import: $remote_db -> $local_db"
  TOTAL_START=$(date +%s)
  
  # Export from remote
  remote_export "$remote_db" "$temp_file"
  
  # Import to local
  local_import "$local_db" "$temp_file"
  
  # Cleanup
  rm -f "$temp_file"
  
  echo "[INFO] Total transfer completed in $(($(date +%s)-TOTAL_START)) seconds."
}

case "$ACTION" in
  remote_to_local)
    [[ -z "$DB_NAME" || -z "$TARGET" ]] && { echo "Usage: $0 remote_to_local <remote_db> <local_db>"; exit 1; }
    remote_to_local "$DB_NAME" "$TARGET"
    ;;
  export)
    [[ -z "$DB_NAME" ]] && { echo "Usage: $0 export <remote_db> [output_file]"; exit 1; }
    remote_export "$DB_NAME" "$TARGET"
    ;;
  import)
    [[ -z "$DB_NAME" || -z "$TARGET" ]] && { echo "Usage: $0 import <local_db> <input_file>"; exit 1; }
    local_import "$DB_NAME" "$TARGET"
    ;;
  *)
    echo "Usage: $0 {remote_to_local|export|import} <database> [target]"
    echo "Examples:"
    echo "  $0 remote_to_local icc_store icc_store_local"
    echo "  $0 export icc_store icc_store.sql"
    echo "  $0 import icc_store_local icc_store.sql"
    exit 1
    ;;
esac