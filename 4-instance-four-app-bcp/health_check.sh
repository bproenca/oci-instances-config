#!/bin/bash

LOG_FILE="/home/ubuntu/wks/log_health_check.log"
TIMESTAMP=$(date "+%Y-%m-%d %H:%M:%S")
printf "\n$TIMESTAMP - Health check running\n" | tee --append $LOG_FILE

DOCKER_COMPOSE_PATH="/home/ubuntu/wks/oci-docker-compose.yml"
URLS=(
    "localhost:8787/mysql/actuator/health"
    "localhost:8686/db/actuator/health"
)

for URL in "${URLS[@]}"; do
    echo ">> Calling URL: $URL"
    RESPONSE=$(curl --max-time 10 --silent "$URL")
    echo ">> Reponse: $RESPONSE"
    STATUS=$(echo "$RESPONSE" | grep -o '"status":"[^"]*"' | cut -d':' -f2 | tr -d '"')
    echo ">> Status: $STATUS"

    if [[ "$STATUS" != "UP" ]]; then
        echo "$TIMESTAMP - health check failed or timed out - $URL - $RESPONSE. Restarting..." | tee --append $LOG_FILE
        docker compose -f $DOCKER_COMPOSE_PATH down >> $LOG_FILE 2>&1
	docker compose -f $DOCKER_COMPOSE_PATH up -d >> $LOG_FILE 2>&1
	exit 0
    else
	echo "$TIMESTAMP - health ok - $URL - $RESPONSE" | tee --append $LOG_FILE
    fi
done
