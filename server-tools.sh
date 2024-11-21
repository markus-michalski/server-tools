#!/bin/bash

# Pfade zu den Funktions-Skripten
SCRIPT_DIR="/root/server-tools"
source "${SCRIPT_DIR}/common-functions.sh"
source "${SCRIPT_DIR}/vhost-functions.sh"
source "${SCRIPT_DIR}/ssl-functions.sh"
source "${SCRIPT_DIR}/db-functions.sh"
source "${SCRIPT_DIR}/ssh-functions.sh"
source "${SCRIPT_DIR}/cron-functions.sh"

# Hauptmenü
main_menu() {
    local running=true

    while $running; do
        clear
        echo "=== Server Management Tool ==="
        echo "1. Virtual Host Management"
        echo "2. SSL Management"
        echo "3. Datenbank Management"
        echo "4. SSH User Management"
        echo "5. Cron Management"
        echo "6. Beenden"

        read -p "Wähle eine Option (1-6): " choice

        case $choice in
            1)
                vhost_menu
                ;;
            2)
                ssl_menu
                ;;
            3)
                database_menu
                ;;
            4)
                ssh_menu
                ;;
            5)
                cron_menu
                ;;
            6)
                echo "Beende Programm..."
                running=false
                break
                ;;
            *)
                echo "Ungültige Option!"
                read -p "Enter drücken zum Fortfahren..."
                ;;
        esac
    done
}

# Prüfe Root-Rechte und starte Hauptmenü
check_root
main_menu