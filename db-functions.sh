#!/bin/bash

source /root/server-tools/common-functions.sh

# MySQL Credentials
MYSQL_USER="root"
MYSQL_PASS=""  # Wird aus der Konfigurationsdatei geladen

# Lade MySQL Root Passwort
load_mysql_credentials() {
    if [ -f "/root/.my.cnf" ]; then
        MYSQL_PASS=$(grep password /root/.my.cnf | sed 's/password=//' | sed 's/"//g')
    else
        echo "Fehler: MySQL Konfigurationsdatei nicht gefunden!"
        exit 1
    fi
}

# MySQL Befehl mit Credentials
mysql_cmd() {
    mysql -u"${MYSQL_USER}" -p"${MYSQL_PASS}" -e "$1"
}

# Betroffene User einer Datenbank finden
find_database_users() {
    local db_name=$1
    local users=""

    # Hole alle User (außer System-User)
    while read -r user host; do
        if [[ -n "$user" && "$host" == "localhost" ]]; then
            # Prüfe nur auf spezifische Datenbankrechte
            if mysql_cmd "SHOW GRANTS FOR '${user}'@'localhost'" 2>/dev/null | grep -qi "ON \`${db_name}\`\."; then
                users="${users}${user}\n"
            fi
        fi
    done < <(mysql_cmd "SELECT user, host FROM mysql.user WHERE user NOT IN ('root', 'debian-sys-maint', 'mysql.sys', 'mysql.session', 'mariadb.sys', 'mysql', 'phpmyadmin', 'pma')")

    if [[ -n "$users" ]]; then
        echo -e "$users" | sort | uniq
    fi
}

# Datenbank und User erstellen
create_db() {
    local db_name=$1
    local db_user=$2
    local db_pass=$3
    local credentials_file="/root/db-credentials/${db_name}.txt"

    if [[ ! "${db_name}" =~ ^[a-zA-Z0-9_]+$ ]]; then
        echo "Ungültiger Datenbankname!"
        return 1
    fi

    # Erstelle Verzeichnis für Credentials falls nicht vorhanden
    mkdir -p /root/db-credentials
    chmod 700 /root/db-credentials

    echo "Erstelle Datenbank und User..."

    # Erstelle die Datenbank
    mysql_cmd "CREATE DATABASE IF NOT EXISTS ${db_name} CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"

    # Erstelle den User mit dem übergebenen Passwort
    mysql_cmd "CREATE USER IF NOT EXISTS '${db_user}'@'localhost' IDENTIFIED BY '${db_pass}';"

    # Prüfe, ob der User erfolgreich erstellt wurde
    if ! mysql_cmd "SELECT user FROM mysql.user WHERE user='${db_user}'" | grep -q "${db_user}"; then
        echo "❌ Fehler beim Erstellen des Users!"
        return 1
    fi

    # Vergebe Rechte
    mysql_cmd "GRANT ALL PRIVILEGES ON ${db_name}.* TO '${db_user}'@'localhost';"
    mysql_cmd "FLUSH PRIVILEGES;"

    # Teste den Zugriff
    if mysql -u"${db_user}" -p"${db_pass}" -e "USE ${db_name};" 2>/dev/null; then
        echo "✅ Datenbank ${db_name} und User ${db_user} wurden erfolgreich erstellt!"

        # Speichere Credentials in Datei
        {
            echo "=== Datenbank Zugangsdaten ==="
            echo "Erstellt am: $(date '+%Y-%m-%d %H:%M:%S')"
            echo "Datenbank: ${db_name}"
            echo "User: ${db_user}"
            echo "Passwort: ${db_pass}"
            echo "Host: localhost"
            echo ""
            echo "MySQL Kommandozeilen-Login:"
            echo "mysql -u ${db_user} -p${db_pass} ${db_name}"
            echo ""
            echo "PHP PDO Connection String:"
            echo "mysql:host=localhost;dbname=${db_name};charset=utf8mb4"
            echo ""
            echo "PHP mysqli Connection:"
            echo "\$mysqli = new mysqli('localhost', '${db_user}', '${db_pass}', '${db_name}');"
        } > "${credentials_file}"

        chmod 600 "${credentials_file}"

        echo ""
        echo "Zugangsdaten:"
        echo "User: ${db_user}"
        echo "Passwort: ${db_pass}"
        echo "Datenbank: ${db_name}"
        echo ""
        echo "Die vollständigen Zugangsdaten wurden gespeichert in:"
        echo "${credentials_file}"
    else
        echo "❌ Warnung: Datenbank und User wurden erstellt, aber der Zugriffs-Test ist fehlgeschlagen!"
        return 1
    fi
}

# Neue DB für existierenden User
assign_db_to_user() {
    local db_name=$1
    local db_user=$2

    if [[ ! "${db_name}" =~ ^[a-zA-Z0-9_]+$ ]]; then
        echo "Ungültiger Datenbankname!"
        return 1
    fi

    # Prüfe ob User existiert
    if ! mysql_cmd "SELECT user FROM mysql.user WHERE user='${db_user}'" | grep -q "${db_user}"; then
        echo "User ${db_user} existiert nicht!"
        return 1
    fi

    # Prüfe ob Datenbank bereits existiert
    if mysql_cmd "SHOW DATABASES LIKE '${db_name}'" | grep -q "${db_name}"; then
        echo "Datenbank ${db_name} existiert bereits!"
        return 1
    fi

    mysql_cmd "CREATE DATABASE ${db_name} CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
    mysql_cmd "GRANT ALL PRIVILEGES ON ${db_name}.* TO '${db_user}'@'localhost';"
    mysql_cmd "FLUSH PRIVILEGES;"

    echo "✅ Datenbank ${db_name} wurde ${db_user} zugewiesen!"
}

# Nur User löschen
delete_user() {
    local db_user=$1

    echo "⚠️  ACHTUNG: Datenbankbenutzer ${db_user} wird gelöscht!"
    echo "Alle Zugriffsrechte des Users werden entfernt."
    read -p "Fortfahren? (j/N): " confirm
    if [[ "$confirm" != "j" && "$confirm" != "J" ]]; then
        return 1
    fi

    # Prüfe ob User existiert
    if ! mysql_cmd "SELECT user FROM mysql.user WHERE user='${db_user}'" | grep -q "${db_user}"; then
        echo "User ${db_user} existiert nicht!"
        return 1
    fi

    # Liste alle Datenbanken, auf die der User Zugriff hat
    echo "User hat Zugriff auf folgende Datenbanken:"

    # Hole alle GRANT-Statements und extrahiere Datenbanknamen
    mysql_cmd "SHOW GRANTS FOR '${db_user}'@'localhost'" 2>/dev/null | while read -r grant; do
        # Überspringe Globale Rechte (USAGE)
        if echo "$grant" | grep -q "USAGE ON \*\.\*"; then
            continue
        fi

        # Extrahiere Datenbanknamen zwischen Backticks
        if echo "$grant" | grep -q "ON \`.*\`\."; then
            db_name=$(echo "$grant" | sed -n "s/.*ON \`\(.*\)\`\..*/\1/p")
            if [ -n "$db_name" ]; then
                # Prüfe ob die Datenbank noch existiert
                if mysql_cmd "SHOW DATABASES LIKE '${db_name}'" | grep -q "${db_name}"; then
                    echo "- ${db_name} (existiert)"
                else
                    echo "- ${db_name} (existiert nicht mehr)"
                fi
            fi
        fi
    done

    mysql_cmd "DROP USER '${db_user}'@'localhost';"
    mysql_cmd "FLUSH PRIVILEGES;"

    echo "✅ Datenbankbenutzer wurde erfolgreich gelöscht!"
}

# Datenbank und User löschen
delete_db() {
    local db_name=$1
    local db_user=$2
    local credentials_file="/root/db-credentials/${db_name}.txt"

    echo "⚠️  ACHTUNG: Datenbank ${db_name} und User ${db_user} werden gelöscht!"
    read -p "Fortfahren? (j/N): " confirm
    if [[ "$confirm" != "j" && "$confirm" != "J" ]]; then
        return 1
    fi

    if ! mysql_cmd "SHOW DATABASES LIKE '${db_name}'" | grep -q "${db_name}"; then
        echo "Datenbank ${db_name} existiert nicht!"
        return 1
    fi

    mysql_cmd "DROP DATABASE IF EXISTS ${db_name};"
    mysql_cmd "DROP USER IF EXISTS '${db_user}'@'localhost';"
    mysql_cmd "FLUSH PRIVILEGES;"

    # Lösche die Credentials-Datei wenn vorhanden
    if [ -f "${credentials_file}" ]; then
        rm "${credentials_file}"
        echo "Credentials-Datei wurde gelöscht."
    fi

    echo "✅ Datenbank und User wurden erfolgreich gelöscht!"
}

# Nur Datenbank löschen
delete_db_only() {
    local db_name=$1
    local credentials_file="/root/db-credentials/${db_name}.txt"

    echo "⚠️  ACHTUNG: Datenbank ${db_name} wird gelöscht!"
    echo "Der zugehörige Datenbankbenutzer bleibt erhalten."
    read -p "Fortfahren? (j/N): " confirm
    if [[ "$confirm" != "j" && "$confirm" != "J" ]]; then
        return 1
    fi

    if ! mysql_cmd "SHOW DATABASES LIKE '${db_name}'" | grep -q "${db_name}"; then
        echo "Datenbank ${db_name} existiert nicht!"
        return 1
    fi

    # Finde alle User mit Rechten auf dieser Datenbank
    echo "Betroffene Datenbankbenutzer:"
    users=$(find_database_users "${db_name}")
    if [[ -n "$users" ]]; then
        echo "$users"
    else
        echo "Keine User mit spezifischen Rechten gefunden."
    fi

    # Lösche nur die Datenbank
    mysql_cmd "DROP DATABASE IF EXISTS ${db_name};"

    # Aktualisiere die Credentials-Datei falls vorhanden
    if [ -f "${credentials_file}" ]; then
        echo "Credentials-Datei gefunden. Folgende Optionen:"
        echo "1. Datei löschen"
        echo "2. Als Backup behalten (wird um einen Zeitstempel ergänzt)"
        read -p "Wähle eine Option (1-2): " file_option

        case $file_option in
            1)
                rm "${credentials_file}"
                echo "Credentials-Datei wurde gelöscht."
                ;;
            2)
                mv "${credentials_file}" "${credentials_file}.$(date +%Y%m%d_%H%M%S).bak"
                echo "Credentials-Datei wurde als Backup gespeichert."
                ;;
            *)
                echo "Ungültige Option - Credentials-Datei bleibt unverändert."
                ;;
        esac
    fi

    echo "✅ Datenbank wurde erfolgreich gelöscht!"
}

# Datenbanken auflisten
list_databases() {
    echo "=== 📊 Datenbanken ==="
    mysql_cmd "SHOW DATABASES;" | grep -v "Database\|information_schema\|performance_schema\|mysql\|sys"

    echo -e "\n=== 👤 Datenbank-User ==="
    mysql_cmd "SELECT user, host FROM mysql.user WHERE user NOT IN ('root', 'debian-sys-maint', 'mysql.sys', 'mysql.session');"
}

# Datenbank Management Menü
database_menu() {
    # Lade MySQL Credentials beim Start
    load_mysql_credentials

    local submenu=true

    while $submenu; do
        clear
        echo "=== 🗄️  Datenbank Management ==="
        echo "1. Datenbank & User erstellen"
        echo "2. Datenbank & User löschen"
        echo "3. Datenbanken & User anzeigen"
        echo "4. Neue Datenbank für existierenden User"
        echo "5. Nur Datenbank löschen (User behalten)"
        echo "6. Nur User löschen"
        echo "7. Zurück zum Hauptmenü"

        read -p "Wähle eine Option (1-7): " choice

        case $choice in
            1)
                read -p "Datenbankname: " db_name
                read -p "Datenbank-User: " db_user
                read -s -p "Datenbank-Passwort (leer lassen für auto-generiertes Passwort): " db_pass
                echo
                if [ -z "$db_pass" ]; then
                    db_pass=$(openssl rand -base64 12)
                fi
                create_db "$db_name" "$db_user" "$db_pass"
                ;;
            2)
                list_databases
                read -p "Datenbankname zum Löschen: " db_name
                read -p "Datenbank-User zum Löschen: " db_user
                delete_db "$db_name" "$db_user"
                ;;
            3)
                list_databases
                ;;
            4)
                list_databases
                read -p "Name der neuen Datenbank: " db_name
                read -p "Existierender Datenbank-User: " db_user
                assign_db_to_user "$db_name" "$db_user"
                ;;
            5)
                list_databases
                read -p "Datenbankname zum Löschen: " db_name
                delete_db_only "$db_name"
                ;;
            6)
                list_databases
                read -p "Datenbank-User zum Löschen: " db_user
                delete_user "$db_user"
                ;;
            7)
                submenu=false
                ;;
            *)
                echo "❌ Ungültige Option!"
                ;;
        esac

        if [ "$choice" != "7" ]; then
            read -p "Enter drücken zum Fortfahren..."
            clear
        fi
    done
}