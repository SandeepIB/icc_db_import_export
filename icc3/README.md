# MySQL Database Import Script - README

## Overview
Fast and resilient MySQL database import script that runs in a screen session with parallel processing, automatic error recovery, and comprehensive logging.

## Prerequisites
- MySQL client tools installed
- `screen` command available
- Source file `icc_store.sql.tar.gz` in the script directory
- Sufficient disk space for extraction and import

## Quick Start

### 1. Make Script Executable
```bash
chmod +x direct_import.sh
```

### 2. Configure Settings
Edit the configuration section in `direct_import.sh`:
```bash
DB_NAME="icc_store_sep_19"          # Target database name
MYSQL_USER="sgupta"                 # MySQL username
MYSQL_PASS="your_password"          # MySQL password
MYSQL_HOST="localhost"              # MySQL host
MYSQL_PORT="3306"                   # MySQL port
IMPORT_PATH="/var/www/html/icc/icc3" # Working directory
SOURCE_FILE="icc_store.sql.tar.gz"  # Source archive file
MAX_THREADS=4                       # Parallel import threads
RETRY_LIMIT=3                       # Retry attempts for failed tables
```

### 3. Start Import
```bash
./direct_import.sh
```

## Usage Commands

| Command | Description |
|---------|-------------|
| `./direct_import.sh` | Start import in screen session |
| `./direct_import.sh check` | Check if import process is running |
| `./direct_import.sh quit` | Stop the screen session |

## Monitoring Progress

### View Live Logs
```bash
tail -f direct_import.log
```

### Attach to Screen Session
```bash
screen -r importjob
```

### Detach from Screen (Ctrl+A, D)
```bash
# Press Ctrl+A, then D to detach
# Script continues running in background
```

### Check Process Status
```bash
./direct_import.sh check
# or
ps -u sgupta -f | grep direct_import.sh | grep -v grep
```

## Persistent Execution

The script is designed to run persistently and survive:
- **Terminal closure**: Runs in detached screen session
- **SSH disconnection**: Screen session continues on server
- **VPN drops**: Script waits for MySQL reconnection automatically
- **Network interruptions**: Built-in connection recovery

### What happens when you:
- **Close terminal**: Script keeps running in screen session
- **Disconnect VPN**: Script pauses and waits for MySQL connection
- **Kill screen session**: Use `./direct_import.sh quit` to stop safely
- **Server reboot**: Script stops, but can resume from last completed table

## Features

### Speed Optimization
- **Parallel Processing**: Imports multiple tables simultaneously
- **Optimized MySQL Settings**: Disables foreign key checks, unique checks during import
- **Buffer Optimization**: Configured for large data transfers

### Resilience & Recovery
- **Auto-Resume**: Continues from last successful table if interrupted
- **Connection Recovery**: Waits indefinitely for MySQL/VPN reconnection
- **Retry Logic**: Retries failed tables up to 3 times
- **Progress Tracking**: Maintains state between runs
- **Persistent Execution**: Survives terminal closure and network drops

### Error Handling
- **Comprehensive Logging**: All operations logged to `direct_import.log`
- **Error Isolation**: Failed tables logged separately to `direct_import_error.log`
- **Non-Blocking**: Continues processing even if some tables fail

## Output Files

- `direct_import.log` - Main execution log
- `direct_import_error.log` - Error-specific log
- `.import_progress.completed` - Successfully imported tables (temporary)
- `.import_progress.failed` - Failed tables (temporary)

## Expected Output

```
Starting import in screen session 'importjob'...
Import started in background. Monitor with:
  tail -f direct_import.log
  screen -r importjob
Use './direct_import.sh check' to check if process is running.
Use './direct_import.sh quit' to quit the screen session.
```

### Sample Log Output
```
[2024-01-15 10:30:00] Import started: Mon Jan 15 10:30:00 UTC 2024
[2024-01-15 10:30:00] Configuration: DB=icc_store_sep_19, Threads=4, Source=icc_store.sql.tar.gz
[2024-01-15 10:30:01] MySQL connection verified
[2024-01-15 10:30:01] Starting MySQL database import for: icc_store_sep_19
[2024-01-15 10:30:02] Extracting SQL file from /var/www/html/icc/icc3/icc_store.sql.tar.gz
[2024-01-15 10:30:05] Found 45 table chunks for parallel import
[2024-01-15 10:30:05] Starting parallel import with 4 threads
...
[2024-01-15 10:45:30] ==========================================
[2024-01-15 10:45:30] IMPORT SUMMARY
[2024-01-15 10:45:30] ==========================================
[2024-01-15 10:45:30] Successfully imported tables: 43
[2024-01-15 10:45:30] Failed tables: 2
[2024-01-15 10:45:30] Retried tables: 5
[2024-01-15 10:45:30] Database stats: 45 tables, 2847392 rows, 2.34 GB
[2024-01-15 10:45:30] FINAL STATUS: Import completed with 2 failures
```

## Troubleshooting

### Connection Issues
- Script automatically waits for MySQL reconnection
- Check MySQL service: `sudo systemctl status mysql`
- Verify credentials in configuration section

### Import Failures
- Check `direct_import_error.log` for specific errors
- Failed tables are retried automatically up to 3 times
- **Resume**: Simply restart script - it automatically skips completed tables
- Progress files are preserved until successful completion

### Performance Tuning
- Increase `MAX_THREADS` for faster import (recommended: 2-8)
- Ensure sufficient RAM and disk I/O capacity
- Monitor system resources during import

### Disk Space
- Ensure 2x source file size available (for extraction + import)
- Script cleans up temporary files automatically

## Recovery & Resume

The script automatically resumes from the last successful table if interrupted:
1. Connection drops are detected and waited for
2. Progress is tracked in hidden files
3. Completed tables are skipped on restart
4. Only failed/incomplete tables are processed

## Recovery & Resume

The script automatically resumes from the last successful table if interrupted:
1. **Progress Tracking**: Completed tables are saved in `.import_progress.completed`
2. **Auto-Resume**: Restart the script - it will skip already imported tables
3. **Connection Recovery**: Waits for MySQL/VPN reconnection automatically
4. **File Preservation**: SQL file and progress files are kept on failure for resume

### Resume Process
```bash
# If script was interrupted, simply restart it
./direct_import.sh

# The script will automatically:
# - Skip extraction if SQL file exists
# - Skip completed tables from previous run
# - Continue from where it left off
```

## Manual Cleanup

Clean up only after successful completion or when starting fresh:
```bash
# Force clean start (removes all progress)
rm -f .import_progress.* table_chunks/ icc_store.sql
screen -S importjob -X quit

# Check what would be resumed
ls -la .import_progress.*
wc -l .import_progress.completed  # Shows completed table count
```