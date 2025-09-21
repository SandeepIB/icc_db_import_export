# MySQL Database Export Guide - direct_import.sh

## Quick Start

1. **Configure the script** (edit top section of `direct_import.sh`):
   ```bash
   DB_NAME="icc_store_sep_19"
   MYSQL_USER="sgupta"
   MYSQL_PASS="your_password"
   EXPORT_PATH="/var/www/html/icc/icc3"
   MAX_THREADS=4
   ```

2. **Start export**:
   ```bash
   ./direct_import.sh
   ```

3. **Monitor progress**:
   ```bash
   ./direct_import.sh check
   screen -r importjob
   tail -f direct_import.log
   ```

4. **Stop if needed**:
   ```bash
   ./direct_import.sh quit
   ```

## Step-by-Step Process

### 1. Pre-Export Setup
- Script creates MySQL config file with credentials
- Tests database connection (retries if failed)
- Initializes log files and progress tracking

### 2. Export Process
- Exports database structure first (tables, routines, triggers)
- Gets list of all tables in database
- Exports tables in parallel using configured thread count
- Each table export includes retry logic (up to 3 attempts)

### 3. Error Handling
- Detects MySQL connection drops/VPN issues
- Waits for connection restoration
- Retries failed tables automatically
- Logs all errors to separate files

### 4. Compression & Cleanup
- Compresses SQL dump to `.tar.gz` format
- Removes temporary files
- Generates final summary report

## Commands Reference

| Command | Purpose |
|---------|---------|
| `./direct_import.sh` | Start export in screen session |
| `./direct_import.sh check` | Check if process is running |
| `./direct_import.sh quit` | Stop screen session |
| `screen -r importjob` | Attach to running session |
| `screen -d importjob` | Detach from session |

## Files Generated

- `icc_store.sql.tar.gz` - Final compressed database dump
- `direct_import.log` - Main execution log
- `failed_tables.log` - Failed operations log

## Troubleshooting

**Connection Issues:**
- Script auto-detects and waits for MySQL reconnection
- Check MySQL service: `sudo systemctl status mysql`

**Resume Export:**
- Script automatically resumes from last successful table
- Progress tracked in hidden files

**Performance Tuning:**
- Increase `MAX_THREADS` for faster export
- Ensure sufficient disk space for dump file

## Expected Output

```
Export started: 2024-01-15 10:30:00
Configuration: DB=icc_store, Threads=4, Path=/var/www/html/icc/icc3
MySQL connection verified
Starting MySQL database export for: icc_store
Found 45 tables to export
Starting parallel export with 4 threads
...
==========================================
EXPORT SUMMARY
==========================================
Successfully exported tables: 43
Failed tables: 2
Retried tables: 5
Compressed file: /var/www/html/icc/icc3/icc_store.sql.tar.gz (2.1G)
==========================================
```