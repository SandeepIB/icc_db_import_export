# MySQL Parallel Dump & Restore

Optimized MySQL database backup and restore using parallel processing with compression.

## Purpose

This script performs MySQL database operations in parallel to significantly reduce backup/restore time for large databases by processing multiple tables simultaneously with automatic compression and MySQL optimization.

## Prerequisites

- `mysql` and `mysqldump` commands
- GNU `parallel` package
- `gzip` for compression
- Bash shell

Install on Ubuntu/Debian:
```bash
sudo apt install mysql-client parallel gzip
```

## Configuration

### Default Credentials
- Host: `localhost`
- Port: `3306`
- User: `root`
- Password: `YourPassword`

### Environment Variables
Override defaults:
```bash
export MYSQL_HOST=your_host
export MYSQL_PORT=3306
export MYSQL_USER=your_user
export MYSQL_PASSWORD=your_password
```

## Usage

### Export Database
```bash
./mysql_parallel_dump_restore.sh export <database> <threads> <backup_dir>
```

### Import Database
```bash
./mysql_parallel_dump_restore.sh import <database> <threads> <backup_dir>
```

### Copy Database (Export + Import)
```bash
./mysql_parallel_dump_restore.sh both <source_db> <target_db> <threads> <backup_dir>
```

## Examples

Export with compression:
```bash
./mysql_parallel_dump_restore.sh export mydb 8 /backup/mydb
```

Copy database:
```bash
./mysql_parallel_dump_restore.sh both prod_db staging_db 6 /tmp/backup
```

Import with custom credentials:
```bash
export MYSQL_USER=admin
export MYSQL_PASSWORD=secret123
./mysql_parallel_dump_restore.sh import mydb 4 /backup/mydb
```

## Parameters

- `<database>`: Database name
- `<source_db>`: Source database (for 'both' action)
- `<target_db>`: Target database (for 'both' action)
- `<threads>`: Number of parallel processes (recommended: 4-8)
- `<backup_dir>`: Directory for SQL files

## Large Table Configuration

For very large tables, create `large_tables.conf` in the script directory:
```
# Format: table_name:primary_key_column:chunk_size
wp_posts:ID:500000
wp_postmeta:meta_id:1000000
wp_term_relationships:object_id:500000
```

Large tables are automatically split into chunks and processed in parallel for faster performance.

## Features

- **Parallel Processing**: Multiple tables processed simultaneously
- **Large Table Chunking**: Automatically splits large tables by primary key ranges
- **Automatic Compression**: Gzip compression reduces file size by 70-80%
- **MySQL Optimization**: Disables constraints during import for speed
- **Secure Authentication**: Uses config files to avoid password warnings
- **Mixed File Support**: Handles both compressed (.sql.gz) and uncompressed (.sql) files
- **Progress Tracking**: Real-time timing for each table and total operation
- **Database Copying**: Direct database-to-database transfer with 'both' action
- **Configurable**: No hardcoded table names, all via configuration file

## Performance Tips

- Use 4-8 threads for optimal performance
- Ensure adequate MySQL buffer pool size
- Use SSD storage for backup directory
- Run on local network to minimize latency

## SSH Remote Transfer

For transferring databases from remote servers via SSH, use `ssh_mysql_transfer.sh`:

### Environment Variables for SSH Transfer
```bash
export REMOTE_HOST=10.100.23.56
export REMOTE_USER=sgupta
export REMOTE_MYSQL_USER=sgupta
export LOCAL_MYSQL_USER=root
export LOCAL_MYSQL_PASSWORD=YourPassword
```

### SSH Transfer Examples

Direct remote to local transfer:
```bash
./ssh_mysql_transfer.sh remote_to_local icc_store icc_store_local
```

Export from remote server only:
```bash
./ssh_mysql_transfer.sh export icc_store icc_store.sql
```

Import to local database only:
```bash
./ssh_mysql_transfer.sh import icc_store_local icc_store.sql
```

# icc_db_import_export
