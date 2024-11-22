#!/bin/bash

# Zeigt alle Cronjobs eines Users an
list_user_crons() {
    local user=$1
    if [ -z "$user" ]; then
        echo "Systemweite Cronjobs (root):"
        for crondir in /etc/cron.d /etc/cron.daily /etc/cron.hourly /etc/cron.monthly /etc/cron.weekly /etc/cron.yearly; do
            if [ -d "$crondir" ]; then
                echo -e "\nInhalt von $crondir:"
                ls -l "$crondir"
            fi
        done
        crontab -l 2>/dev/null || echo "Keine Cronjobs für root definiert."
    else
        echo "Cronjobs für Benutzer $user:"
        crontab -u "$user" -l 2>/dev/null || echo "Keine Cronjobs für $user definiert."
    fi
}

# Fügt einen neuen Cronjob hinzu
add_cron() {
    local user="$1"
    local schedule="$2"
    local command="$3"
    local cron_type="$4"
    local name="$5"

    # Validiere Schedule-Format
    if ! validate_cron_schedule "$schedule"; then
        echo "Ungültiges Cron-Schedule-Format!"
        return 1
    fi

    if [ "$cron_type" = "system" ]; then
        # Systemweiter Cronjob in /etc/cron.d mit benutzerdefiniertem Namen
        local cron_file="/etc/cron.d/${name:-custom_$(date +%s)}"
        echo "$schedule root $command" > "$cron_file"
        chmod 644 "$cron_file"
    else
        # User-spezifischer Cronjob
        (crontab -u "$user" -l 2>/dev/null; echo "$schedule $command") | crontab -u "$user" -
    fi
}

# Validiert das Cron-Schedule-Format
validate_cron_schedule() {
    # Schedule in ein Array aufteilen und Leerzeichen als Trennzeichen verwenden
    IFS=' ' read -r -a parts <<< "$1"

    # Debug-Ausgabe
    echo "Schedule: $1"
    echo "Teile: ${parts[*]}"
    echo "Anzahl Teile: ${#parts[@]}"

    if [ ${#parts[@]} -ne 5 ]; then
        echo "Fehler: Benötige 5 Teile, gefunden: ${#parts[@]}"
        return 1
    fi

    for part in "${parts[@]}"; do
        if ! [[ "$part" =~ ^[0-9*,/-]+$ ]]; then
            echo "Fehler: Ungültiges Format in Teil: $part"
            return 1
        fi
    done
    
    return 0
}

# Löscht einen Cronjob
remove_cron() {
    local user=$1
    local job_pattern=$2
    local cron_type=$3  # "user" oder "system"

    if [ "$cron_type" = "system" ]; then
        # Suche und lösche in /etc/cron.d
        for file in /etc/cron.d/*; do
            if grep -q "$job_pattern" "$file"; then
                rm -f "$file"
                echo "Systemweiter Cronjob in $file gelöscht."
            fi
        done
    else
        # Lösche aus User-Crontab
        crontab -u "$user" -l 2>/dev/null | grep -v "$job_pattern" | crontab -u "$user" -
        echo "Cronjob für Benutzer $user gelöscht."
    fi
}

# Menü für Cron-Management
cron_menu() {
    local running=true

    while $running; do
        clear
        echo "=== Cron Management ==="
        echo "1. Cronjobs anzeigen"
        echo "2. Neuen Cronjob erstellen"
        echo "3. Cronjob löschen"
        echo "4. Zurück zum Hauptmenü"

        read -p "Wähle eine Option (1-4): " choice

        case $choice in
            1)
                read -p "Benutzer (leer für root): " user
                list_user_crons "$user"
                read -p "Enter drücken zum Fortfahren..."
                ;;
           2)
               read -p "Systemweit (s) oder Benutzer-spezifisch (u)? " cron_scope
               if [ "$cron_scope" = "u" ]; then
                   read -p "Benutzer: " user
                   cron_type="user"
               else
                   user="root"
                   cron_type="system"
               fi
               read -r -p "Schedule (z.B. '0 4 * * *' für täglich um 4 Uhr): " schedule
               read -r -p "Befehl: " command
               read -r -p "Name für den Cronjob (Enter für automatischen Namen): " name

               if add_cron "$user" "$schedule" "$command" "$cron_type" "$name"; then
                   echo "Cronjob erfolgreich hinzugefügt!"
               else
                   echo "Fehler beim Hinzufügen des Cronjobs!"
               fi
               read -p "Enter drücken zum Fortfahren..."
               ;;
            3)
                read -p "Systemweit (s) oder Benutzer-spezifisch (u)? " cron_scope
                if [ "$cron_scope" = "u" ]; then
                    read -p "Benutzer: " user
                    cron_type="user"
                else
                    user="root"
                    cron_type="system"
                fi
                read -p "Suchbegriff für zu löschenden Job: " pattern
                remove_cron "$user" "$pattern" "$cron_type"
                read -p "Enter drücken zum Fortfahren..."
                ;;
            4)
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
