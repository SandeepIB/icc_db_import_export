#!/bin/bash
# Test MySQL connection exactly like the import script

MYSQL_USER="sgupta"
MYSQL_PASS="secwd&S1lWjnNXIPS198ppn($"
MYSQL_HOST="localhost"
MYSQL_PORT="3306"

# Create temp config file like the script does
MYSQL_CONFIG=$(mktemp)
echo "Created temp config: $MYSQL_CONFIG"

cat > "$MYSQL_CONFIG" << EOF
[client]
user=$MYSQL_USER
password=$MYSQL_PASS
host=$MYSQL_HOST
port=$MYSQL_PORT
max_allowed_packet=1G
connect_timeout=60
EOF

echo "Config file contents:"
cat "$MYSQL_CONFIG"

echo ""
echo "Testing connection..."
error_output=$(mysql --defaults-file="$MYSQL_CONFIG" -e "SELECT 1;" 2>&1)
exit_code=$?

echo "Exit code: $exit_code"
echo "Output: $error_output"

if [ $exit_code -eq 0 ]; then
    echo "✓ Connection successful"
else
    echo "✗ Connection failed"
fi

# Cleanup
rm -f "$MYSQL_CONFIG"