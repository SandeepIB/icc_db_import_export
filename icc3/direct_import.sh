#!/bin/bash
# MySQL Database Import Script with Parallel Processing and Error Recovery
# Usage: ./direct_import.sh

#=============================================================================
# CONFIGURATION SECTION
#=============================================================================
DB_NAME="icc_store_sep_19"
MYSQL_USER="sgupta"
MYSQL_PASS="secwd&S1lWjnNXIPS198ppn($"
MYSQL_HOST="localhost"
MYSQL_PORT="3306"
IMPORT_PATH="$(pwd)/backup"
SOURCE_FILE="icc_store.sql.tar.gz"
MAX_THREADS=4
RETRY_LIMIT=3

#=============================================================================
# GLOBAL VARIABLES
#=============================================================================
SCRIPT_NAME="direct_import.sh"
LOG_FILE="$IMPORT_PATH/direct_import.log"
ERROR_LOG="$IMPORT_PATH/direct_import_error.log"
SOURCE_PATH="$IMPORT_PATH/$SOURCE_FILE"
EXTRACTED_SQL="$IMPORT_PATH/icc_store.sql"
PROGRESS_FILE="$IMPORT_PATH/.import_progress"
MYSQL_CONFIG=$(mktemp)

# Counters
SUCCESSFUL_TABLES=0
FAILED_TABLES=0
RETRIED_TABLES=0

#=============================================================================
# UTILITY FUNCTIONS
#=============================================================================
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

error_log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $1" | tee -a "$LOG_FILE" "$ERROR_LOG"
}

cleanup() {
    rm -f "$MYSQL_CONFIG" 2>/dev/null
    log "Cleanup completed"
}

trap cleanup EXIT

#=============================================================================
# MYSQL CONFIGURATION
#=============================================================================
setup_mysql_config() {
    cat > "$MYSQL_CONFIG" << EOF
[client]
user=$MYSQL_USER
password=$MYSQL_PASS
host=$MYSQL_HOST
port=$MYSQL_PORT
max_allowed_packet=1G
connect_timeout=60
EOF
}

#=============================================================================
# CONNECTION TESTING AND RECOVERY
#=============================================================================
test_mysql_connection() {
    local retries=0
    while [ $retries -lt 3 ]; do
        local error_output=$(mysql --defaults-file="$MYSQL_CONFIG" -e "SELECT 1;" 2>&1)
        if [ $? -eq 0 ]; then
            return 0
        fi
        retries=$((retries + 1))
        log "Connection attempt $retries failed: $error_output"
        if [ $retries -lt 3 ]; then
            log "Retrying in 5 seconds..."
            sleep 5
        fi
    done
    
    # Try to find MySQL socket if TCP connection fails
    log "TCP connection failed, trying socket connections..."
    for socket in /var/run/mysqld/mysqld.sock /tmp/mysql.sock /var/lib/mysql/mysql.sock; do
        if [ -S "$socket" ]; then
            log "Found MySQL socket: $socket"
            echo "socket=$socket" >> "$MYSQL_CONFIG"
            local socket_error=$(mysql --defaults-file="$MYSQL_CONFIG" -e "SELECT 1;" 2>&1)
            if [ $? -eq 0 ]; then
                log "Socket connection successful"
                return 0
            else
                log "Socket connection failed: $socket_error"
            fi
        fi
    done
    
    # Debug: show config file contents
    log "MySQL config file contents:"
    cat "$MYSQL_CONFIG" | while read line; do log "  $line"; done
    
    return 1
}

wait_for_connection() {
    log "Waiting for MySQL connection to be restored..."
    while ! test_mysql_connection; do
        log "Connection still down, waiting 10 seconds..."
        sleep 10
    done
    log "MySQL connection restored"
}

#=============================================================================
# SQL FILE PROCESSING
#=============================================================================
extract_sql_file() {
    # Check if SQL file already exists
    if [ -f "$EXTRACTED_SQL" ]; then
        log "SQL file already exists, skipping extraction: $EXTRACTED_SQL"
        return 0
    fi
    
    log "Extracting SQL file from $SOURCE_PATH"
    if tar -xzf "$SOURCE_PATH" -C "$IMPORT_PATH"; then
        log "SQL file extracted successfully"
        return 0
    else
        error_log "Failed to extract SQL file"
        return 1
    fi
}

split_sql_by_tables() {
    # Check if table chunks already exist
    if [ -d "$IMPORT_PATH/table_chunks" ] && [ "$(ls -A $IMPORT_PATH/table_chunks 2>/dev/null)" ]; then
        log "Table chunks already exist, skipping split: $IMPORT_PATH/table_chunks"
        return 0
    fi
    
    log "Splitting SQL file by tables for parallel import"
    mkdir -p "$IMPORT_PATH/table_chunks"
    
    # Split SQL file by CREATE TABLE statements
    awk '/^-- Table structure for table/ {
        if (file) close(file)
        gsub(/[^a-zA-Z0-9_]/, "", $6)
        file = "'$IMPORT_PATH'/table_chunks/" $6 ".sql"
        print > file
        next
    }
    file { print > file }
    ' "$EXTRACTED_SQL"
}

#=============================================================================
# IMPORT FUNCTIONS
#=============================================================================
import_table_chunk() {
    local chunk_file=$1
    local table_name=$(basename "$chunk_file" .sql)
    local attempt=$2
    
    log "Importing table: $table_name (attempt $attempt)"
    
    # Test connection before import
    if ! test_mysql_connection; then
        wait_for_connection
    fi
    
    # Import table chunk with optimized settings
    if mysql --defaults-file="$MYSQL_CONFIG" \
        --init-command="SET SESSION FOREIGN_KEY_CHECKS=0; SET SESSION UNIQUE_CHECKS=0; SET SESSION AUTOCOMMIT=0;" \
        "$DB_NAME" < "$chunk_file" 2>/dev/null; then
        
        # Mark as completed
        echo "$table_name" >> "$PROGRESS_FILE.completed"
        SUCCESSFUL_TABLES=$((SUCCESSFUL_TABLES + 1))
        log "Successfully imported table: $table_name"
        return 0
    else
        error_log "Failed to import table: $table_name (attempt $attempt)"
        return 1
    fi
}

import_table_with_retry() {
    local chunk_file=$1
    local table_name=$(basename "$chunk_file" .sql)
    local attempt=1
    
    while [ $attempt -le $RETRY_LIMIT ]; do
        if import_table_chunk "$chunk_file" "$table_name" "$attempt"; then
            return 0
        fi
        
        if [ $attempt -lt $RETRY_LIMIT ]; then
            RETRIED_TABLES=$((RETRIED_TABLES + 1))
            log "Retrying table $table_name in 5 seconds..."
            sleep 5
        fi
        
        attempt=$((attempt + 1))
    done
    
    # Final failure
    echo "$table_name" >> "$PROGRESS_FILE.failed"
    FAILED_TABLES=$((FAILED_TABLES + 1))
    error_log "Table $table_name failed after $RETRY_LIMIT attempts"
    return 1
}

#=============================================================================
# PARALLEL PROCESSING
#=============================================================================
import_tables_parallel() {
    local chunk_files=("$@")
    local pids=()
    local active_jobs=0
    
    log "Starting parallel import with $MAX_THREADS threads"
    
    for chunk_file in "${chunk_files[@]}"; do
        local table_name=$(basename "$chunk_file" .sql)
        
        # Check if already completed
        if grep -q "^$table_name$" "$PROGRESS_FILE.completed" 2>/dev/null; then
            log "Skipping already completed table: $table_name"
            continue
        fi
        
        # Wait if max threads reached
        while [ $active_jobs -ge $MAX_THREADS ]; do
            wait -n
            active_jobs=$((active_jobs - 1))
        done
        
        # Start import in background
        import_table_with_retry "$chunk_file" &
        pids+=($!)
        active_jobs=$((active_jobs + 1))
    done
    
    # Wait for all jobs to complete
    for pid in "${pids[@]}"; do
        wait "$pid"
    done
}

#=============================================================================
# MAIN IMPORT PROCESS
#=============================================================================
perform_import() {
    log "Starting MySQL database import for: $DB_NAME"
    
    # Check if source file exists
    if [ ! -f "$SOURCE_PATH" ]; then
        error_log "Source file not found: $SOURCE_PATH"
        return 1
    fi
    
    # Initialize progress files (only if they don't exist - for resume capability)
    if [ ! -f "$PROGRESS_FILE.completed" ]; then
        > "$PROGRESS_FILE.completed"
        log "Starting fresh import - no previous progress found"
    else
        local completed_count=$(wc -l < "$PROGRESS_FILE.completed" 2>/dev/null || echo 0)
        log "Resuming import - found $completed_count previously completed tables"
    fi
    
    if [ ! -f "$PROGRESS_FILE.failed" ]; then
        > "$PROGRESS_FILE.failed"
    fi
    
    # Create database if not exists
    log "Creating database: $DB_NAME"
    mysql --defaults-file="$MYSQL_CONFIG" -e "CREATE DATABASE IF NOT EXISTS \`$DB_NAME\`;"
    
    # Optimize MySQL for import
    log "Optimizing MySQL settings for import..."
    mysql --defaults-file="$MYSQL_CONFIG" -e "
        SET GLOBAL FOREIGN_KEY_CHECKS=0;
        SET GLOBAL UNIQUE_CHECKS=0;
        SET GLOBAL AUTOCOMMIT=0;
        SET GLOBAL innodb_flush_log_at_trx_commit=0;
    " 2>/dev/null || true
    
    # Extract SQL file
    if ! extract_sql_file; then
        return 1
    fi
    
    # Check if we can do parallel import
    if [ $MAX_THREADS -gt 1 ]; then
        # Split SQL file for parallel processing
        split_sql_by_tables
        
        # Get chunk files
        mapfile -t chunk_files < <(find "$IMPORT_PATH/table_chunks" -name "*.sql" 2>/dev/null)
        
        if [ ${#chunk_files[@]} -gt 0 ]; then
            log "Found ${#chunk_files[@]} table chunks for parallel import"
            import_tables_parallel "${chunk_files[@]}"
        else
            log "No table chunks found, falling back to single-threaded import"
            import_single_file
        fi
    else
        # Single-threaded import
        import_single_file
    fi
    
    # Restore MySQL settings
    log "Restoring MySQL settings..."
    mysql --defaults-file="$MYSQL_CONFIG" -e "
        SET GLOBAL FOREIGN_KEY_CHECKS=1;
        SET GLOBAL UNIQUE_CHECKS=1;
        SET GLOBAL AUTOCOMMIT=1;
        SET GLOBAL innodb_flush_log_at_trx_commit=1;
        COMMIT;
    " 2>/dev/null || true
    
    # Cleanup (but preserve progress files for potential resume)
    #rm -rf "$IMPORT_PATH/table_chunks" 2>/dev/null
    # Only remove SQL file if import was successful
    if [ $FAILED_TABLES -eq 0 ]; then
        #rm -f "$EXTRACTED_SQL" 2>/dev/null
        log "Import successful - cleaned up temporary files"
    else
        log "Import had failures - keeping SQL file for potential retry"
    fi
}

import_single_file() {
    log "Performing single-threaded import"
    
    if mysql --defaults-file="$MYSQL_CONFIG" \
        --init-command="SET SESSION FOREIGN_KEY_CHECKS=0; SET SESSION UNIQUE_CHECKS=0; SET SESSION AUTOCOMMIT=0;" \
        "$DB_NAME" < "$EXTRACTED_SQL"; then
        SUCCESSFUL_TABLES=1
        log "Single-file import completed successfully"
    else
        FAILED_TABLES=1
        error_log "Single-file import failed"
    fi
}

#=============================================================================
# SUMMARY AND REPORTING
#=============================================================================
show_summary() {
    local end_time=$(date)
    local source_size=""
    
    if [ -f "$SOURCE_PATH" ]; then
        source_size=$(du -h "$SOURCE_PATH" | cut -f1)
    fi
    
    log "=========================================="
    log "IMPORT SUMMARY"
    log "=========================================="
    log "Database: $DB_NAME"
    log "Import completed: $end_time"
    log "Successfully imported tables: $SUCCESSFUL_TABLES"
    log "Failed tables: $FAILED_TABLES"
    log "Retried tables: $RETRIED_TABLES"
    log "Source file: $SOURCE_PATH ($source_size)"
    log "Log file: $LOG_FILE"
    log "Error log: $ERROR_LOG"
    
    # Show database stats
    local stats=$(mysql --defaults-file="$MYSQL_CONFIG" -N -e "
        SELECT CONCAT(COUNT(*), ' tables, ', 
               COALESCE(SUM(table_rows), 0), ' rows, ',
               ROUND(SUM(data_length + index_length) / 1024 / 1024 / 1024, 2), ' GB')
        FROM information_schema.tables 
        WHERE table_schema='$DB_NAME';
    " 2>/dev/null || echo "Stats unavailable")
    
    log "Database stats: $stats"
    log "=========================================="
    
    # Show failed tables if any
    if [ -f "$PROGRESS_FILE.failed" ] && [ -s "$PROGRESS_FILE.failed" ]; then
        log "Failed tables:"
        while read -r table; do
            log "  - $table"
        done < "$PROGRESS_FILE.failed"
    fi
    
    # Final status
    if [ $FAILED_TABLES -eq 0 ]; then
        log "FINAL STATUS: Import completed successfully"
    else
        log "FINAL STATUS: Import completed with $FAILED_TABLES failures"
    fi
}

#=============================================================================
# PROCESS MANAGEMENT
#=============================================================================
check_running_process() {
    echo "Checking for running $SCRIPT_NAME processes:"
    ps -u sgupta -f | grep "$SCRIPT_NAME" | grep -v grep || echo "No running processes found"
}

quit_screen_session() {
    echo "Quitting screen session 'importjob'..."
    screen -S importjob -X quit 2>/dev/null || echo "No screen session found"
}

#=============================================================================
# MAIN EXECUTION
#=============================================================================
main() {
    local start_time=$(date)
    local start_seconds=$(date +%s)
    
    # Setup
    setup_mysql_config
    log "Import started: $start_time"
    log "Configuration: DB=$DB_NAME, Threads=$MAX_THREADS, Source=$SOURCE_FILE"
    
    # Test initial connection with diagnostics
    if ! test_mysql_connection; then
        error_log "Cannot establish initial MySQL connection"
        log "Troubleshooting steps:"
        log "1. Check if MySQL is running: sudo systemctl status mysql"
        log "2. Start MySQL if needed: sudo systemctl start mysql"
        log "3. Verify credentials in script configuration"
        log "4. Check MySQL port: netstat -tlnp | grep 3306"
        exit 1
    fi
    log "MySQL connection verified"
    
    # Perform import
    if perform_import; then
        log "Import process completed"
    else
        error_log "Import process failed"
    fi
    
    # Calculate total time
    local end_time=$(date)
    local end_seconds=$(date +%s)
    local total_seconds=$((end_seconds - start_seconds))
    local hours=$((total_seconds / 3600))
    local minutes=$(((total_seconds % 3600) / 60))
    local seconds=$((total_seconds % 60))
    
    log "Import completed: $end_time"
    log "Total execution time: ${hours}h ${minutes}m ${seconds}s ($total_seconds seconds)"
    
    # Show summary
    show_summary
    
    # Cleanup progress files only on successful completion
    if [ $FAILED_TABLES -eq 0 ]; then
        #rm -f "$PROGRESS_FILE.completed" "$PROGRESS_FILE.failed" 2>/dev/null
        log "All tables imported successfully - cleaned up progress files"
    else
        log "Keeping progress files for potential resume - $FAILED_TABLES tables failed"
    fi
    
    # Auto-quit screen session
    if [ -n "${STY:-}" ]; then
        log "Auto-quitting screen session..."
        sleep 2
        screen -S importjob -X quit 2>/dev/null || true
    fi
}

#=============================================================================
# COMMAND LINE HANDLING
#=============================================================================
case "${1:-}" in
    "check")
        check_running_process
        ;;
    "quit")
        quit_screen_session
        ;;
    *)
        # Run in screen if not already in one
        if [ -z "${STY:-}" ]; then
            echo "Starting import in screen session 'importjob'..."
            screen -dmS importjob bash -c "cd '$PWD' && ./$SCRIPT_NAME main > direct_import.log 2>&1"
            echo "Import started in background. Monitor with:"
            echo "  tail -f direct_import.log"
            echo "  screen -r importjob"
            echo "Use './$SCRIPT_NAME check' to check if process is running."
            echo "Use './$SCRIPT_NAME quit' to quit the screen session."
        else
            main
        fi
        ;;
esac