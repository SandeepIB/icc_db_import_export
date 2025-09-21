#!/bin/bash
# MySQL Connection Test Script

MYSQL_USER="sgupta"
MYSQL_PASS="secwd&S1lWjnNXIPS198ppn($"
MYSQL_HOST="localhost"
MYSQL_PORT="3306"

echo "=== MySQL Connection Test ==="
echo "User: $MYSQL_USER"
echo "Host: $MYSQL_HOST"
echo "Port: $MYSQL_PORT"
echo ""

# Test 1: Basic connection
echo "Test 1: Basic TCP connection..."
if mysql -u "$MYSQL_USER" -p"$MYSQL_PASS" -h "$MYSQL_HOST" -P "$MYSQL_PORT" -e "SELECT 1;" 2>/dev/null; then
    echo "✓ TCP connection successful"
else
    echo "✗ TCP connection failed"
    echo "Error details:"
    mysql -u "$MYSQL_USER" -p"$MYSQL_PASS" -h "$MYSQL_HOST" -P "$MYSQL_PORT" -e "SELECT 1;" 2>&1
fi

echo ""

# Test 2: Socket connection
echo "Test 2: Socket connections..."
for socket in /var/run/mysqld/mysqld.sock /tmp/mysql.sock /var/lib/mysql/mysql.sock; do
    if [ -S "$socket" ]; then
        echo "Found socket: $socket"
        if mysql -u "$MYSQL_USER" -p"$MYSQL_PASS" -S "$socket" -e "SELECT 1;" 2>/dev/null; then
            echo "✓ Socket connection successful: $socket"
        else
            echo "✗ Socket connection failed: $socket"
        fi
    fi
done

echo ""

# Test 3: Check MySQL process
echo "Test 3: MySQL process check..."
ps aux | grep mysql | grep -v grep || echo "No MySQL processes found"

echo ""

# Test 4: Check listening ports
echo "Test 4: MySQL ports..."
netstat -tlnp 2>/dev/null | grep 3306 || echo "Port 3306 not listening"

echo ""

# Test 5: Check MySQL service
echo "Test 5: MySQL service status..."
if command -v systemctl >/dev/null; then
    systemctl status mysql 2>/dev/null || systemctl status mysqld 2>/dev/null || echo "MySQL service not found"
else
    service mysql status 2>/dev/null || service mysqld status 2>/dev/null || echo "MySQL service not found"
fi