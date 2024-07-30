This shell script backs up all PostgreSQL databases running in Docker containers. It saves the backups to a backup directory and deletes backups older than a specified number of days.

## Dependencies

* Docker
* gzip

## Usage

To use the script, simply run it with the desired command-line options. For example, to backup all PostgreSQL databases running in Docker containers to the /backups directory and keep backups for 7 days, you could run the following command:

```
./db-container-backup.sh --backup-dir /backups --retention-days 7
```

The script supports the following command-line options:

* `--backup-dir`: Directory to save backups (default: $HOME/backup).
* `--retention-days`: Number of days to keep backups (default: 2).
* `--max-jobs`: Maximum number of parallel jobs (default: 4).
* `--help`: Display the usage message.