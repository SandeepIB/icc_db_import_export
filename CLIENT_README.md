# Client Database Import Tool

## Required Files
- `client_import.sh` - Main import script
- `icc_store.sql.tar.gz` - Database archive file

## Prerequisites
Install required packages:
```bash
# Ubuntu/Debian
sudo apt install mysql-client parallel

# CentOS/RHEL
sudo yum install mysql parallel
```

## Usage
```bash
# Basic import (8 threads)
./client_import.sh

# Custom database name and threads
./client_import.sh my_database 12

# With custom MySQL credentials
export MYSQL_USER=admin
export MYSQL_PASSWORD=secret
./client_import.sh
```

## Environment Variables
```bash
export MYSQL_HOST=localhost      # MySQL host
export MYSQL_PORT=3306          # MySQL port  
export MYSQL_USER=root          # MySQL username
export MYSQL_PASSWORD=password  # MySQL password
```

## Performance
- Uses parallel processing for maximum speed
- Optimizes MySQL settings automatically
- Supports both single and multi-file archives
- Typical import time: 5-15 minutes for large databases