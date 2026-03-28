#! /usr/bin/env bash

###########################################################################
# Script Name	: server-setup                                            #
# Description	: This script check services and start them               #
# Author       	: Ali Kalbasi                                             #
# Email         : ali9kalbasi@gmail.com                                   #
###########################################################################

# Variables
SERVICES=(
    docker.service
)

# functions
service_health() {
    systemctl status "$1" | awk 'NR==3 {print $2}'
}

# main
for SERVICE in "${SERVICES[@]}"; do
    if [[ $(service_health "$SERVICE") == "inactive" ]]; then
        systemctl start "$SERVICE"
    fi
done