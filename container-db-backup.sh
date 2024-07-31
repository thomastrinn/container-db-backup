#!/bin/bash

# This script backs up all databases running in Docker containers.
# It saves the backups to a backup directory and deletes backups older than a specified number of days.

# Suported databases:
# * PostgreSQL

# This command ensures that the script will exit immediately if any command exits with a non-zero status, any undefined variable is used,
# and the return value of a pipeline is the value of the last command to exit with a non-zero status, or zero if all commands in the
# pipeline exit successfully. 
set -euo pipefail

# Function to handle errors and print a more descriptive error message before exiting
# Syntax: handle_error message exit_code
#
# Arguments:
# * message: The error message to print.
# * exit_code: The exit code to use when exiting the script.
#
# Returns:
# * None. The script will exit with the specified exit code.
function handle_error() {
    local message=$1
    local exit_code=$2
    local line_number=${BASH_LINENO[1]}
    printf "Error: %s (line %d)\n" "$message" "$line_number"
    #logger -t db-container-backup "Error: $message (line $line_number)"
    exit "$exit_code"
}

# Function to get containers by image name
# This function uses the `docker ps` command to list all running containers and their images, then filters the output to only include containers that use the specified image.
# The container names are then extracted from the filtered output and returned as a list.
#
# Sytax: get_containers_by_image image
#
# Arugments:
# * image: The name of the Docker image.
#
# Returns:
# * A list of container names that use the specified image.
function get_containers_by_image() {
    local image=$1
    docker ps --format '{{.Names}}:{{.Image}}' | grep "$image" | cut -d":" -f1
}

# Function to extract environment variable from a container
# This function uses the `docker exec` command to run the `env` command inside the specified Docker container and extract the value of the specified environment variable.
# 
# Sytax: extract_env_var container env_name
# 
# Arguments:
# * container: The name of the Docker container.
# * env_name: The name of the environment variable to extract.
#
# Returns:
# * The value of the environment variable.
function extract_env_var() {
    local container=$1
    local env_name=$2
    local var_value
    
    var_value=$(docker exec "$container" env | grep "$env_name" | cut -d"=" -f2-)

    echo "$var_value"
}

# Function to backup a PostgreSQL database
# This function uses the `pg_dump` command to create a backup of the specified PostgreSQL database running in a Docker container.
# The backup is then compressed using `gzip` and saved to the specified backup directory with a timestamp in the filename.
#
# Syntax: backup_postgres_db BACKUPDIR container postgres_db postgres_user
#
# Arguments:
# * backup_dir: The path to the directory where the backup files will be stored.
# * container: The name of the Docker container running the PostgreSQL database.
# * postgres_db: The name of the PostgreSQL database to be backed up.
# * postgres_user: The username of the PostgreSQL user with sufficient privileges to perform the backup.
function backup_postgres_db() {
    local backup_dir=$1
    local container=$2
    local postgres_db=$3
    local postgres_user=$4

    # Run pg_dummp command inside the Docker container
    docker exec -e POSTGRES_DB="$postgres_db" -e POSTGRES_USER="$postgres_user" "$container" \
         pg_dump -U "$postgres_user" "$postgres_db"  \
        | gzip > "$backup_dir"/"$container"-"$postgres_db"-"$(date +"%Y%m%d%H%M")".sql.gz
}

# Function to clean up old backups
# This function is used to clean up old backups in a specified directory. It deletes backup files that are older than a specified number of days.
#
# Syntax: cleanup_backups BACKUPDIR DAYS container
#
# Arguments:
# * backup_dir: The path to the directory where the backup files are stored.
# * days: The number of days after which a backup file is considered old and should be deleted.
# * container: The name of the container for which the backup files are being managed.
#
# Returns:
# * None
#
# Side effects:
# * Deletes backup files that are older than the specified number of days.
#
function cleanup_backups() {
    # Get the input arguments
    local backup_dir=$1
    local days=$2
    local container=$3

    # Count the number of backup files for the specified container
    local old_backups
    old_backups=$(find "$backup_dir" -maxdepth 1 -type f -name "$container*.gz" | wc -l)

    # If there are more backup files than the specified number of days, delete the oldest ones
    if [[ "$old_backups" -gt $days ]]; then
        find "$backup_dir" -name "$container*.gz" -mtime +"$days" -delete
    fi
}

# Function to backup a PostgreSQL container
# This function is used to backup a PostgreSQL database running in a Docker container. It first extracts the necessary environment variables from the container,
# then uses the `backup_postgres_db` function to create a backup of the database. Finally, it uses the `cleanup_backups` function to delete old backups.
#
# Syntax: backup_postgres_container container backup_dir days
#
# Arguments:
# * container: The name of the Docker container running the PostgreSQL database.
# * backup_dir: The path to the directory where the backup files will be stored.
# * days: The number of days after which a backup file is considered old and should be deleted.
#
function backup_postgres_container() {
    local container=$1
    local backup_dir=$2
    local days=$3

    printf "Backing up %s ...\n" "$container"

    # Get the POSTGRES_DB and POSTGRES_USER environment variables for the container
    local postgres_db
    postgres_db=$(extract_env_var "$container" "POSTGRES_DB")
    local postgres_user
    postgres_user=$(extract_env_var "$container" "POSTGRES_USER")

    # Backup the database and save the backup to the backup directory
    backup_postgres_db "$backup_dir" "$container" "$postgres_db" "$postgres_user"

    # If there are more backups than the specified number of days, delete the oldest ones
    cleanup_backups "$backup_dir" "$days" "$container"

    printf "Backing up %s [DONE]\n" "$container"
}



# Thi function is used to backup all PostgreSQL databases running in Docker containers.
# It first gets a list of all PostgreSQL containers using the `get_containers_by_image` function.
# It then loops through each container and performs the following steps:
# * Extracts the `POSTGRES_DB` and `POSTGRES_USER` environment variables for the container using the `extract_env_var` function.
# * Backs up the database using the `backup_postgres_db` function.
# * Cleans up old backups using the `cleanup_backups` function.
#
# Syntax: backup_postgres_containers backup_dir days
#
# Arguments:
# * backup_dir: The path to the directory where the backup files will be stored.
# * days: The number of days after which a backup file is considered old and should be deleted.
function backup_postgres_containers() {
    local backup_dir=$1
    local days=$2

    # Get a list of all PostgreSQL containers
    local postgres_containers
    postgres_containers=$(get_containers_by_image 'postgres')

    # Loop through each container
    local -i job_count=0
    for container in $postgres_containers; do
        # Start the backup job in the background
        backup_postgres_container "$container" "$backup_dir" "$days" &

        # Increment the job count
        ((job_count++))

        # If we've reached the maximum number of jobs, wait for them to finish
        if ((job_count % MAX_JOBS == 0)); then
            wait
        fi
    done

    # Wait for any remaining jobs to finish
    wait
}

# Function to validate inputs
# This function is used to validate the inputs provided to the script.
# It checks that the backup directory exists and that the number of days is a positive integer.
# If either of these checks fails, it calls the `handle_error` function to display an error message and exit the script.
#
# Syntax: validate_inputs backup_dir days
#
# Arguments:
# * backup_dir: The path to the directory where the backup files will be stored.
# * days: The number of days after which a backup file is considered old and should be deleted.
#
# Returns:
# * None
#
# Side effects:
# * Calls the `handle_error` function if the inputs are invalid.
#
function validate_inputs() {
    local backup_dir=$1
    local days=$2

    if [[ ! -d "$backup_dir" ]]; then
        handle_error "The specified backup directory does not exist. Please ensure the path is correct and try again." 1
    fi

    if ! [[ "$days" =~ ^[0-9]+$ ]] || [[ "$days" -lt 1 ]]; then
        handle_error "The number of days must be a positive integer. Please check your input and try again." 1
    fi
}

# 
function print_usage() {
    printf "Usage: %s [--bakcup-dir BACKUP_DIR] [--retention-days DAYS] [--max-jobs MAX_JOBS]\n" "$0"
    printf "  --backup-dir BACKUP_DIR       Directory to save backups (default: %s)\n" $DEFAULT_BACKUP_DIR
    printf "  --retention-days DAYS         Number of days to keep backups (default: 2)\n"
    printf "  --max-jobs MAX_JOBS           Maximum number of parallel jobs (default: 4)\n"
    printf "  --help                        Display this help message\n"
}

# Main function
function main() {
    local backup_dir=$1
    local days=$2

    validate_inputs "$backup_dir" "$days"

    printf "Backup for Databases [START]\n"

    if ! backup_postgres_containers "$backup_dir" "$days"; then
        handle_error "Backup for Databases [FAILED]" 1
    fi

    printf "Backup for Databases [DONE]\n"
}

DEFAULT_MAX_JOBS=4
DEFAULT_BACKUP_DIR=$HOME/backup
DEFAULT_RETENTION_DAYS=2

# Maximum number of parallel jobs
MAX_JOBS=$DEFAULT_MAX_JOBS
# Directory to save backups (default: $HOME/backup)
BACKUP_DIR=$DEFAULT_BACKUP_DIR
# Number of days to keep backups (default: 2)
RETENTION_DAYS=$DEFAULT_RETENTION_DAYS

while [[ $# -gt 0 ]]; do
    case $1 in
        --backup-dir)
            BACKUP_DIR="$2"
            shift 2
            ;;
        --retention-days)
            RETENTION_DAYS="$2"
            shift 2
            ;;
        --max-jobs)
            if [[ $2 =~ ^[0-9]+$ ]] && [ $2 -gt 0 ]; then
                MAX_JOBS="$2"
                shift 2
            else
                handle_error "--max-jobs must be a positive number" 1
            fi
            ;;
        --help)
            print_usage
            exit 0
            ;;
        *)
            handle_error "Invalid argument: $1" 1
            ;;
    esac
done

# Check if docker command is available
if ! command -v docker &> /dev/null; then
    handle_error "docker command could not be found. Please install docker and try again." 1
fi

# If the backup directory doesn't exist, create it
if [ ! -d "$BACKUP_DIR" ]; then
    mkdir -p "$BACKUP_DIR"
fi

# Call the main function with optional arguments
main "$BACKUP_DIR" "$RETENTION_DAYS"