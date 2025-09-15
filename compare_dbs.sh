#!/bin/bash
# Usage: ./compare_dbs.sh source_db target_db

SOURCE_DB=$1; TARGET_DB=$2
MYSQL_HOST=${MYSQL_HOST:-localhost}; MYSQL_PORT=${MYSQL_PORT:-3306}
MYSQL_USER=${MYSQL_USER:-root}; MYSQL_PASS=${MYSQL_PASSWORD:-YourPassword}

[[ -z "$SOURCE_DB" || -z "$TARGET_DB" ]] && { echo "Usage: $0 <source_db> <target_db>"; exit 1; }

MYSQL_CONFIG=$(mktemp); trap "rm -f $MYSQL_CONFIG" EXIT
cat > "$MYSQL_CONFIG" << EOF
[client]
host=$MYSQL_HOST
port=$MYSQL_PORT
user=$MYSQL_USER
password=$MYSQL_PASS
EOF

echo "Comparing $SOURCE_DB vs $TARGET_DB:"
echo "=================================="

TABLES=$(mysql --defaults-file="$MYSQL_CONFIG" -N -e "SHOW TABLES IN $SOURCE_DB;")

for table in $TABLES; do
  source_count=$(mysql --defaults-file="$MYSQL_CONFIG" -N -e "SELECT COUNT(*) FROM $SOURCE_DB.$table;" 2>/dev/null || echo "0")
  target_count=$(mysql --defaults-file="$MYSQL_CONFIG" -N -e "SELECT COUNT(*) FROM $TARGET_DB.$table;" 2>/dev/null || echo "0")
  
  if [[ $source_count -eq $target_count ]]; then
    echo "✓ $table: $source_count rows (match)"
  else
    echo "✗ $table: $source_count → $target_count rows (MISMATCH)"
  fi
done