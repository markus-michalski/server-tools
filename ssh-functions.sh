#!/bin/bash

source /root/server-tools/common-functions.sh


# Hilfsfunktion zur Validierung von SSH-Keys
validate_ssh_key() {
    local key=$1

    # Prüfe ob der Key das richtige Format hat (ssh-rsa/ssh-ed25519 + Base64 + Kommentar)
    if [[ "$key" =~ ^(ssh-rsa|ssh-ed25519)[[:space:]]+[A-Za-z0-9+/]+[=]{0,2}[[:space:]]+[^[:space:]]+$ ]]; then
        return 0
    else
        return 1
    fi
}

# DocRoot Funktionen
add_docroot() {
    local username=$1
    local docroot=$2
    local is_developer=$3

    if [ -z "$username" ]; then
        echo "Fehler: Username muss angegeben werden!"
        return 1
    fi

    # Wenn kein DocRoot angegeben, erstelle Standard-DocRoot
    if [ -z "$docroot" ]; then
        docroot="/var/www/${username}"
        echo "Kein DocRoot angegeben, verwende Standard-Pfad: $docroot"
    fi

    # Erstelle DocRoot falls nicht vorhanden
    if [ ! -d "$docroot" ]; then
        echo "Erstelle DocRoot: $docroot"
        mkdir -p "$docroot"
    fi

    # Setze Basis-Berechtigungen
    chown "${username}:www-data" "$docroot"
    chmod 750 "$docroot"
    chmod g+s "$docroot"  # SGID-Bit setzen

    # Erstelle symbolischen Link mit sinnvollem Namen
    local base_name=$(basename "$docroot")
    # Falls basename leer ist oder nur aus Sonderzeichen besteht
    if [ -z "$base_name" ] || ! echo "$base_name" | grep -q "[a-zA-Z0-9]"; then
        base_name="www"
    fi

    local count=0
    local final_link_name="${base_name}"

    # Prüfe auf existierende Links und füge Zähler hinzu wenn nötig
    while [ -L "/home/$username/www-${final_link_name}" ]; do
        count=$((count + 1))
        final_link_name="${base_name}${count}"
    done

    local symlink_path="/home/$username/www-${final_link_name}"
    ln -s "$docroot" "$symlink_path"

    # Erstelle .htaccess falls nicht vorhanden
    if [ ! -f "${docroot}/.htaccess" ]; then
        cat > "${docroot}/.htaccess" << EOF
# Basis-Sicherheitseinstellungen
Options -Indexes
ServerSignature Off

# PHP-Einstellungen
php_flag display_errors off
php_value upload_max_filesize 64M
php_value post_max_size 64M
php_value max_execution_time 300
php_value max_input_time 300

# Schutz vor XSS, Clickjacking etc.
Header set X-Content-Type-Options "nosniff"
Header set X-Frame-Options "SAMEORIGIN"
Header set X-XSS-Protection "1; mode=block"
EOF

        chown "${username}:www-data" "${docroot}/.htaccess"
        chmod 640 "${docroot}/.htaccess"
    fi

    echo "DocRoot Setup abgeschlossen:"
    echo "- Pfad: $docroot"
    echo "- Link: www-${final_link_name}"
    echo "- Berechtigungen: ${username}:www-data (750 + SGID)"
    echo "- .htaccess: Basiskonfiguration erstellt"

    return 0
}

# Berechtigungen reparieren
fix_permissions() {
    local docroot=$1
    local username=$2

    if [ -z "$docroot" ] || [ -z "$username" ]; then
        echo "Fehler: DocRoot und Username müssen angegeben werden!"
        return 1
    fi

    echo "Korrigiere Berechtigungen für $docroot..."

    # Setze Verzeichnisberechtigungen
    find "$docroot" -type d -exec chmod 750 {} \;
    find "$docroot" -type d -exec chmod g+s {} \;

    # Setze Dateiberechtigungen
    find "$docroot" -type f -exec chmod 640 {} \;

    # Setze Eigentümer
    chown -R "${username}:www-data" "$docroot"

    echo "Berechtigungen wurden korrigiert:"
    echo "- Verzeichnisse: 750 + SGID (${username}:www-data)"
    echo "- Dateien: 640 (${username}:www-data)"

    # Prüfe .htaccess
    if [ -f "${docroot}/.htaccess" ]; then
        chown "${username}:www-data" "${docroot}/.htaccess"
        chmod 640 "${docroot}/.htaccess"
        echo "- .htaccess Berechtigungen korrigiert"
    fi
}

# Berechtigungen prüfen
check_permissions() {
    local docroot=$1
    local username=$2

    if [ -z "$docroot" ] || [ -z "$username" ]; then
        echo "Fehler: DocRoot und Username müssen angegeben werden!"
        return 1
    fi

    echo "Überprüfe Berechtigungen für $docroot..."

    local has_errors=0

    # Prüfe Verzeichnisberechtigungen
    echo "Prüfe Verzeichnisse..."
    while IFS= read -r dir; do
        local perms=$(stat -c "%a" "$dir")
        local owner=$(stat -c "%U" "$dir")
        local group=$(stat -c "%G" "$dir")
        if [ "$perms" != "750" ] || [ "$owner" != "$username" ] || [ "$group" != "www-data" ]; then
            echo "Falsche Berechtigungen für $dir:"
            echo "  Aktuell: $owner:$group ($perms)"
            echo "  Erwartet: $username:www-data (750)"
            has_errors=1
        fi
        # Prüfe SGID-Bit
        if ! [ -g "$dir" ]; then
            echo "SGID-Bit fehlt für $dir"
            has_errors=1
        fi
    done < <(find "$docroot" -type d)

    # Prüfe Dateiberechtigungen
    echo "Prüfe Dateien..."
    while IFS= read -r file; do
        local perms=$(stat -c "%a" "$file")
        local owner=$(stat -c "%U" "$file")
        local group=$(stat -c "%G" "$file")
        if [ "$perms" != "640" ] || [ "$owner" != "$username" ] || [ "$group" != "www-data" ]; then
            echo "Falsche Berechtigungen für $file:"
            echo "  Aktuell: $owner:$group ($perms)"
            echo "  Erwartet: $username:www-data (640)"
            has_errors=1
        fi
    done < <(find "$docroot" -type f)

    if [ $has_errors -eq 1 ]; then
        echo "Es wurden Probleme gefunden."
        read -p "Möchten Sie die Berechtigungen automatisch korrigieren? (j/N) " fix_it
        if [[ "$fix_it" == "j" || "$fix_it" == "J" ]]; then
            fix_permissions "$docroot" "$username"
        fi
    else
        echo "Alle Berechtigungen sind korrekt!"
    fi
}

# Liste alle DocRoots eines Users auf
list_docroots() {
    local username=$1

    if [ -z "$username" ]; then
        echo "Fehler: Username muss angegeben werden!"
        return 1
    fi

    echo "DocRoots für User $username:"
    echo "Symbolische Links:"
    ls -la "/home/$username/" | grep "^l.*www-" | awk '{print $9 " -> " $11}'

    echo -e "\nTatsächliche DocRoot-Verzeichnisse:"
    for link in /home/$username/www-*; do
        if [ -L "$link" ]; then
            local target=$(readlink -f "$link")
            echo "$(basename "$link") -> $target"
        fi
    done
}

# Entferne einen DocRoot
remove_docroot() {
    local username=$1
    local docroot=$2

    if [ -z "$username" ] || [ -z "$docroot" ]; then
        echo "Fehler: Username und DocRoot müssen angegeben werden!"
        return 1
    fi

    # Finde alle Links die auf diesen DocRoot zeigen
    local found=0
    for link in /home/$username/www-*; do
        if [ -L "$link" ] && [ "$(readlink -f "$link")" = "$docroot" ]; then
            rm "$link"
            echo "DocRoot-Link entfernt: $(basename "$link")"
            found=1
        fi
    done

    if [ $found -eq 0 ]; then
        echo "Keine Links zu diesem DocRoot gefunden!"
    fi

    # Optional: DocRoot-Verzeichnis auch löschen?
    if [ -d "$docroot" ]; then
        read -p "Soll das DocRoot-Verzeichnis auch gelöscht werden? (j/N) " delete_dir
        if [[ "$delete_dir" == "j" || "$delete_dir" == "J" ]]; then
            rm -rf "$docroot"
            echo "DocRoot-Verzeichnis gelöscht: $docroot"
        fi
    fi
}

# DocRoot Management Menü
manage_docroots() {
    local username=$1
    local submenu=true

    while $submenu; do
        clear
        echo "=== DocRoot Management für $username ==="
        echo "1. DocRoot hinzufügen"
        echo "2. DocRoots anzeigen"
        echo "3. DocRoot entfernen"
        echo "4. Berechtigungen prüfen"
        echo "5. Berechtigungen reparieren"
        echo "6. Zurück"
        echo
        read -p "Wähle eine Option (1-6): " choice

        case $choice in
            1)
                read -p "Pfad zum neuen DocRoot (oder Enter für Standard): " new_docroot
                add_docroot "$username" "$new_docroot" "$is_developer"
                ;;
            2)
                list_docroots "$username"
                ;;
            3)
                echo "Verfügbare DocRoots:"
                list_docroots "$username"
                echo
                read -p "Pfad zum zu entfernenden DocRoot: " remove_path
                if [ ! -z "$remove_path" ]; then
                    remove_docroot "$username" "$remove_path"
                fi
                ;;
            4)
                echo "Verfügbare DocRoots:"
                list_docroots "$username"
                echo
                read -p "Zu prüfender DocRoot: " check_path
                if [ ! -z "$check_path" ]; then
                    check_permissions "$check_path" "$username"
                fi
                ;;
            5)
                echo "Verfügbare DocRoots:"
                list_docroots "$username"
                echo
                read -p "Zu reparierender DocRoot: " fix_path
                if [ ! -z "$fix_path" ]; then
                    fix_permissions "$fix_path" "$username"
                fi
                ;;
            6)
                submenu=false
                continue
                ;;
            *)
                echo "Ungültige Option!"
                ;;
        esac

        if [ "$choice" != "6" ]; then
            echo
            read -p "Enter drücken zum Fortfahren..."
        fi
    done
}

# SSH User erstellen
create_ssh_user() {
    local username=$1
    local use_key=$2
    local ssh_key=$3
    local password=$4
    local is_developer=$7

    if [ -z "$username" ]; then
        echo "Fehler: Kein Username angegeben!"
        return 1
    fi

    # Prüfe ob User bereits existiert
    if id "$username" &>/dev/null; then
        echo "WARNUNG: User ${username} existiert bereits!"
        read -p "Möchten Sie den bestehenden User überschreiben? (j/N): " overwrite
        if [[ "$overwrite" == "j" || "$overwrite" == "J" ]]; then
            echo "Lösche bestehenden User..."
            delete_ssh_user "$username"
            sleep 2
        else
            echo "Abbruch durch Benutzer."
            return 1
        fi
    fi

    # Erstelle User
    useradd -m -s /bin/bash "$username"

    # Basis-Verzeichnisstruktur
    if [ "$is_developer" = "true" ]; then
        # Entwickler-Verzeichnisstruktur
        mkdir -p "/home/${username}/"{bin,dev,logs}

        # Entwickler-Tools verlinken
        DEV_COMMANDS=(
            "git" "composer" "php" "mysql" "npm" "node"
            "curl" "wget" "tar" "gzip" "unzip" "ssh"
            "rsync" "scp" "sftp" "ls" "cp" "mv" "rm"
            "mkdir" "rmdir" "grep" "nano" "vi" "chmod"
            "chown" "cat" "less"
        )

        for cmd in "${DEV_COMMANDS[@]}"; do
            if [ -f "/usr/bin/${cmd}" ]; then
                ln -sf "/usr/bin/${cmd}" "/home/${username}/bin/${cmd}"
            elif [ -f "/bin/${cmd}" ]; then
                ln -sf "/bin/${cmd}" "/home/${username}/bin/${cmd}"
            fi
        done

        # Entwickler .bashrc
        cat > "/home/${username}/.bashrc" << EOF
# Entwickler PATH-Setup
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/home/${username}/bin"

# Entwickler-Aliase
alias ll='ls -la'

# Logging von Befehlen
export PROMPT_COMMAND='if [ "$(id -u)" -ne 0 ]; then echo "\$(date "+%Y-%m-%d.%H:%M:%S") \$(pwd) \$(history 1)" >> "/home/${username}/logs/bash_history.log"; fi'

# Entwicklungsumgebung
export COMPOSER_HOME="/home/${username}/.composer"
export NODE_ENV="development"
export PHP_ENV="development"
EOF

        # PHP-FPM Pool für Entwickler
        cat > "/etc/php/8.2/fpm/pool.d/${username}.conf" << EOF
[${username}]
user = ${username}
group = www-data
listen = /run/php/php8.2-fpm.${username}.sock
listen.owner = www-data
listen.group = www-data
pm = dynamic
pm.max_children = 5
pm.start_servers = 2
pm.min_spare_servers = 1
pm.max_spare_servers = 3
EOF

        # Logrotation für Entwickler
        cat > "/etc/logrotate.d/${username}" << EOF
/home/${username}/logs/bash_history.log {
    weekly
    rotate 12
    compress
    delaycompress
    missingok
    notifempty
    create 640 ${username} ${username}
}
EOF

    else
        # Standard-User Verzeichnisstruktur
        mkdir -p "/home/${username}/bin"

        # Standard-Befehle
        ALLOWED_COMMANDS=("ls" "cp" "mv" "rm" "mkdir" "rmdir" "grep" "nano" "vi" "chmod" "chown" "cat" "less" "sftp" "scp")
        for cmd in "${ALLOWED_COMMANDS[@]}"; do
            if [ -f "/bin/${cmd}" ]; then
                ln -sf "/bin/${cmd}" "/home/${username}/bin/${cmd}"
            elif [ -f "/usr/bin/${cmd}" ]; then
                ln -sf "/usr/bin/${cmd}" "/home/${username}/bin/${cmd}"
            fi
        done

        # Standard .bashrc
        cat > "/home/${username}/.bashrc" << EOF
# Standard PATH-Setup
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/home/${username}/bin"
EOF
    fi
# DocRoot Setup
    echo "DocRoot Setup"
    local add_more="j"
    while [[ "$add_more" == "j" || "$add_more" == "J" ]]; do
        read -p "DocRoot-Pfad (oder Enter für Standard): " docroot
        if [ ! -z "$docroot" ]; then
            if [ "$is_developer" = "true" ]; then
                add_docroot "$username" "$docroot" "true"
            else
                add_docroot "$username" "$docroot" "false"
            fi
        else
            # Standard-DocRoot
            add_docroot "$username" "/var/www/${username}" "$is_developer"
        fi
        read -p "Weiteren DocRoot hinzufügen? (j/N): " add_more
    done

    # SSH Konfiguration
    sed -i "/Match User ${username}/,+10d" /etc/ssh/sshd_config
    cat >> /etc/ssh/sshd_config << EOF

# SSH-Konfiguration für ${username}
Match User ${username}
    X11Forwarding no
    AllowTcpForwarding no
    PermitTunnel no
    AllowAgentForwarding no
EOF

    # SSH Key oder Passwort Setup
    if [ "$use_key" = "true" ]; then
        if [ "$generate_key" = "true" ]; then
            generate_ssh_key "$username"
        elif [ ! -z "$ssh_key" ]; then
            add_ssh_key "$username" "$ssh_key"
        else
            echo "Fehler: Weder SSH-Key angegeben noch Generierung gewählt!"
            return 1
        fi
    else
        if [ -z "$password" ]; then
            echo "Fehler: Kein Passwort angegeben!"
            return 1
        fi
        echo "${username}:${password}" | chpasswd
    fi

    # Setze finale Berechtigungen
    chown -R "${username}:${username}" "/home/${username}"
    chmod 750 "/home/${username}"
    chmod 755 "/home/${username}/bin"

    # Services neustarten
    systemctl restart sshd
    [ "$is_developer" = "true" ] && systemctl restart php8.2-fpm

    # Erfolgsausgabe
    echo "SSH-User ${username} wurde erstellt!"
    if [ "$is_developer" = "true" ]; then
        echo "Entwickler-Account wurde konfiguriert mit:"
        echo "- Eigener PHP-FPM Pool"
        echo "- Entwickler-Tools (git, composer, etc.)"
        echo "- Command Logging"
        echo "- Erweiterte Berechtigungen"
    fi
    echo "SSH-Zugriff: ssh -p 62954 ${username}@$(hostname -f)"
    echo "SFTP-Zugriff: sftp -P 62954 ${username}@$(hostname -f)"
    list_docroots "$username"

    return 0
}

# SSH User löschen
delete_ssh_user() {
    local username=$1

    if [ -z "$username" ]; then
        echo "Fehler: Kein Username angegeben!"
        return 1
    fi

    if ! id "$username" &>/dev/null; then
        echo "Fehler: User ${username} existiert nicht!"
        return 1
    fi

    echo "ACHTUNG: User ${username} wird gelöscht!"
    read -p "Fortfahren? (j/N): " confirm
    if [[ "$confirm" != "j" && "$confirm" != "J" ]]; then
        echo "Abbruch durch Benutzer."
        return 1
    fi

    # Beende alle Prozesse des Users
    pkill -u "$username"

    # Entferne SFTP/SSH-Konfiguration
    sed -i "/Match User ${username}/,+10d" /etc/ssh/sshd_config

    # Backup des Home-Verzeichnisses
    if [ -d "/home/${username}" ]; then
        read -p "Backup des Home-Verzeichnisses erstellen? (j/N): " backup
        if [[ "$backup" == "j" || "$backup" == "J" ]]; then
            backup_dir="/root/user_backups"
            mkdir -p "$backup_dir"
            timestamp=$(date +%Y%m%d_%H%M%S)
            tar czf "${backup_dir}/${username}_backup_${timestamp}.tar.gz" "/home/${username}" 2>/dev/null
            echo "Backup erstellt unter: ${backup_dir}/${username}_backup_${timestamp}.tar.gz"
        fi
    fi

    # Entferne PHP-FPM Pool falls vorhanden
    if [ -f "/etc/php/8.2/fpm/pool.d/${username}.conf" ]; then
        rm "/etc/php/8.2/fpm/pool.d/${username}.conf"
        systemctl restart php8.2-fpm
    fi

    # Entferne Logrotation falls vorhanden
    if [ -f "/etc/logrotate.d/${username}" ]; then
        rm "/etc/logrotate.d/${username}"
    fi

    # Lösche User und Home-Verzeichnis
    userdel -r "$username" 2>/dev/null || {
        echo "Standard-Löschung fehlgeschlagen, versuche forcierte Löschung..."
        userdel "$username" 2>/dev/null
        rm -rf "/home/${username}" 2>/dev/null
    }

    # Neustart SSH Service
    systemctl restart sshd

    echo "User ${username} wurde gelöscht!"
}
# SSH Key für User generieren
generate_ssh_key() {
    local username=$1
    local key_type=${2:-"ed25519"}
    local key_comment=${3:-"${username}@$(hostname)"}

    if [ -z "$username" ]; then
        echo "Fehler: Kein Username angegeben!"
        return 1
    fi

    if ! id "$username" &>/dev/null; then
        echo "Fehler: User ${username} existiert nicht!"
        return 1
    fi

    local ssh_dir="/home/${username}/.ssh"
    mkdir -p "$ssh_dir"

    if [ "$key_type" = "ed25519" ]; then
        ssh-keygen -t ed25519 -C "$key_comment" -f "${ssh_dir}/id_ed25519" -N ""
    else
        ssh-keygen -t rsa -b 4096 -C "$key_comment" -f "${ssh_dir}/id_rsa" -N ""
    fi

    chmod 700 "$ssh_dir"
    chmod 600 "${ssh_dir}/id_${key_type}"
    chmod 644 "${ssh_dir}/id_${key_type}.pub"
    chown -R "${username}:${username}" "$ssh_dir"

    echo "SSH-Key wurde generiert!"
    echo "Öffentlicher Schlüssel:"
    cat "${ssh_dir}/id_${key_type}.pub"
}

# SSH Key zu bestehendem User hinzufügen
add_ssh_key() {
    local username=$1
    local ssh_key=$2

    if [ -z "$username" ] || [ -z "$ssh_key" ]; then
        echo "Fehler: Username und SSH-Key müssen angegeben werden!"
        return 1
    fi

    if ! id "$username" &>/dev/null; then
        echo "Fehler: User ${username} existiert nicht!"
        return 1
    fi

    if ! validate_ssh_key "$ssh_key"; then
        echo "Fehler: Ungültiges SSH-Key Format!"
        return 1
    fi

    local ssh_dir="/home/${username}/.ssh"
    local auth_keys="${ssh_dir}/authorized_keys"

    mkdir -p "$ssh_dir"

    if ! grep -q "$ssh_key" "$auth_keys" 2>/dev/null; then
        echo "$ssh_key" >> "$auth_keys"
    else
        echo "SSH-Key existiert bereits!"
        return 1
    fi

    chmod 700 "$ssh_dir"
    chmod 600 "$auth_keys"
    chown -R "${username}:${username}" "$ssh_dir"

    echo "SSH-Key wurde hinzugefügt!"
}

# SSH Keys eines Users anzeigen
list_ssh_keys() {
    local username=$1

    if [ -z "$username" ]; then
        echo "Fehler: Kein Username angegeben!"
        return 1
    fi

    if ! id "$username" &>/dev/null; then
        echo "Fehler: User ${username} existiert nicht!"
        return 1
    fi

    local auth_keys="/home/${username}/.ssh/authorized_keys"

    if [ -f "$auth_keys" ]; then
        echo "SSH-Keys für User ${username}:"
        cat "$auth_keys"
    else
        echo "Keine SSH-Keys für User ${username} gefunden."
    fi
}

list_ssh_users() {
    echo "=== SSH User ==="
    echo "Folgende SSH-User sind konfiguriert:"
    echo "Standard User:"
    awk -F: '$7 ~ /\/bin\/bash/ && $3 >= 1000 && $3 < 65534 {print "- " $1}' /etc/passwd
    echo -e "\nEntwickler:"
    grep -l "NODE_ENV=\"development\"" /home/*/.*rc 2>/dev/null | cut -d'/' -f3 | sed 's/^/- /'
}

# SSH User Management Menü
ssh_menu() {
    local submenu=true

    while $submenu; do
        clear
        echo "=== SSH User Management ==="
        echo "1. Standard SSH-User erstellen"
        echo "2. Entwickler SSH-User erstellen"
        echo "3. SSH-User löschen"
        echo "4. SSH-User anzeigen"
        echo "5. SSH-Key zu bestehendem User hinzufügen"
        echo "6. Neuen SSH-Key für User generieren"
        echo "7. SSH-Keys eines Users anzeigen"
        echo "8. DocRoots verwalten"
        echo "9. Zurück zum Hauptmenü"
        echo
        read -p "Wähle eine Option (1-9): " choice

        case $choice in
            1)
                echo
                read -p "Username (oder 'q' für abbrechen): " username
                [ "$username" = "q" ] && continue

                read -p "SSH-Key verwenden? (j/N): " use_key

                if [[ "$use_key" == "j" || "$use_key" == "J" ]]; then
                    read -p "SSH-Key generieren? (j/N): " generate_key
                    if [[ "$generate_key" == "j" || "$generate_key" == "J" ]]; then
                        create_ssh_user "$username" "true" "" "" "" "true" "false"
                    else
                        echo "Bitte SSH Public Key eingeben (Format: ssh-rsa/ssh-ed25519 AAAA... user@host):"
                        read ssh_key
                        create_ssh_user "$username" "true" "$ssh_key" "" "" "false" "false"
                    fi
                else
                    read -s -p "Passwort: " password
                    echo
                    create_ssh_user "$username" "false" "" "$password" "" "false" "false"
                fi
                ;;
            2)
                echo
                read -p "Username (oder 'q' für abbrechen): " username
                [ "$username" = "q" ] && continue

                read -p "SSH-Key verwenden? (j/N): " use_key
                if [[ "$use_key" == "j" || "$use_key" == "J" ]]; then
                    read -p "SSH-Key generieren? (j/N): " generate_key
                    if [[ "$generate_key" == "j" || "$generate_key" == "J" ]]; then
                        create_ssh_user "$username" "true" "" "" "" "true" "true"
                    else
                        echo "Bitte SSH Public Key eingeben (Format: ssh-rsa/ssh-ed25519 AAAA... user@host):"
                        read ssh_key
                        create_ssh_user "$username" "true" "$ssh_key" "" "" "false" "true"
                    fi
                else
                    read -s -p "Passwort: " password
                    echo
                    create_ssh_user "$username" "false" "" "$password" "" "false" "true"
                fi
                ;;
            3)
                echo
                list_ssh_users
                echo
                read -p "Username zum Löschen (oder 'q' für abbrechen): " username
                [ "$username" = "q" ] && continue
                delete_ssh_user "$username"
                ;;
            4)
                echo
                list_ssh_users
                ;;
            5)
                echo
                list_ssh_users
                echo
                read -p "Username (oder 'q' für abbrechen): " username
                [ "$username" = "q" ] && continue
                echo "Bitte SSH Public Key eingeben (Format: ssh-rsa/ssh-ed25519 AAAA... user@host):"
                read ssh_key
                add_ssh_key "$username" "$ssh_key"
                ;;
            6)
                echo
                list_ssh_users
                echo
                read -p "Username (oder 'q' für abbrechen): " username
                [ "$username" = "q" ] && continue
                read -p "Key-Typ (ed25519/rsa) [Standard: ed25519]: " key_type
                [ -z "$key_type" ] && key_type="ed25519"
                generate_ssh_key "$username" "$key_type"
                ;;
            7)
                echo
                list_ssh_users
                echo
                read -p "Username (oder 'q' für abbrechen): " username
                [ "$username" = "q" ] && continue
                list_ssh_keys "$username"
                ;;
            8)
                echo
                list_ssh_users
                echo
                read -p "Username für DocRoot-Management (oder 'q' für abbrechen): " username
                [ "$username" = "q" ] && continue
                if id "$username" &>/dev/null; then
                    manage_docroots "$username"
                else
                    echo "User existiert nicht!"
                fi
                ;;
            9)
                submenu=false
                continue
                ;;
            *)
                echo "Ungültige Option!"
                ;;
        esac

        if [ "$choice" != "9" ]; then
            echo
            read -p "Enter drücken zum Fortfahren..."
        fi
    done
}
