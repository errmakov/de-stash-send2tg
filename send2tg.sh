#!/bin/bash
# Get the directory where the script is located
SCRIPT_DIR=$(dirname "$0")

# Function to display usage information
show_usage() {
    echo "Usage: $0 [message]"
    echo "       $0 -h | -? | --help"
    echo
    echo "Options:"
    echo "  -h, -?, --help    Show this help message and exit."
    echo
    echo "Description:"
    echo "  This script sends a message to a specified Telegram chat using the Telegram Bot API."
    echo "  The message can be provided as an argument or through stdin."
}

# Handle help options
if [[ "$1" == "-h" || "$1" == "-?" || "$1" == "--help" ]]; then
    show_usage
    exit 0
fi

# Load environment variables from .env.send2tg file located in the same directory as the script
if [ -f "$SCRIPT_DIR/.env.send2tg" ]; then
    set -a
    source "$SCRIPT_DIR/.env.send2tg"
    set +a
else
    echo ".env.send2tg file not found in $SCRIPT_DIR."
    exit 1
fi

# Generate a unique ID for this script call
UNIQUE_ID=$(date +%s%N)-$$-$(od -vAn -N4 -tu4 < /dev/urandom | tr -d ' ')

log_message() {
    local status=$1
    local message=$2
    local log_entry=$(jq -n \
        --arg timestamp "$(date --iso-8601=seconds)" \
        --arg unique_id "$UNIQUE_ID" \
        --arg status "$status" \
        --arg message "$message" \
        '{timestamp: $timestamp, unique_id: $unique_id, status: $status, message: $message}')
    # Use flock to ensure exclusive access to the log file
    {
        flock -x 200
        echo "$log_entry" | tee -a "$SEND2TG_LOG_FILE"
    } 200>"$SEND2TG_LOCK_FILE"
}

# Check if a message is passed as an argument
if [ -n "$1" ]; then
    MESSAGE="$1"
else
    # Read from stdin if no argument is provided
    if [ -t 0 ]; then
        # stdin is not being redirected, provide a helpful message
        show_usage
        exit 1
    else
        # Read from stdin
        MESSAGE=$(cat)
    fi
fi

# Check if the message is empty
if [ -z "$MESSAGE" ]; then
    log_message "warning" "Message is empty"
    exit 0
fi

MESSAGE="${SEND2TG_INSTANCE_ID}\n${MESSAGE}"
log_message "info" "Message to be sent: ${MESSAGE}"

# Replace all newline characters with %0A using sed
MESSAGE_ENCODED=$(echo "$MESSAGE" | sed -e 's/\\n/%0A/g')

send_message() {
    local text=$1
    response=$(curl -s -w "%{http_code}" -o /dev/null -X POST "https://api.telegram.org/bot$SEND2TG_BOT_TOKEN/sendMessage" -d chat_id=$SEND2TG_CHAT_ID -d text="$text")
    return $response
}

ERROR=0
# Split and send the message in parts
while [ ${#MESSAGE_ENCODED} -gt $SEND2TG_MAX_LENGTH ]; do
    PART="${MESSAGE_ENCODED:0:$SEND2TG_MAX_LENGTH}"
    MESSAGE_ENCODED="${MESSAGE_ENCODED:$SEND2TG_MAX_LENGTH}"
    send_message "$PART"
    RESPONSE=$?
    if [ $RESPONSE -ne 200 ]; then
        ERROR=1
        log_message "error" "Failed to send message part: $PART"
    else
        log_message "info" "Successfully sent message part: $PART"
    fi
done

# Send the remaining part
if [ -n "$MESSAGE_ENCODED" ]; then
    send_message "$MESSAGE_ENCODED"
    RESPONSE=$?
    if [ $RESPONSE -ne 200 ]; then
        ERROR=1
        log_message "error" "Failed to send message part: $MESSAGE_ENCODED"
    else
        log_message "info" "Successfully sent message part: $MESSAGE_ENCODED"
    fi
fi

echo -e ""

exit $ERROR
