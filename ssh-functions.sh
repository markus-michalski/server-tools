#!/bin/bash

# Gemeinsame Funktionen laden
source /root/server-tools/common-functions.sh

# DocRoot Funktionen
add_docroot() {
    local username=$1
    local docroot=$2
    local is_developer=$3

    if [ -z "$username" ] || [ -z "$docroot" ]; then
        echo "Fehler: Username und DocRoot müssen angegeben werden!"
        return 1
    fi

    # Prüfe und installiere ACL wenn nötig
    if ! check_acl; then
        echo "FEHLER: ACL-Setup fehlgeschlagen."
        return 1
    fi

    # Normalisiere den Pfad
    docroot=$(echo "$docroot" | sed 's#/\+#/#g' | sed 's#/$##')

    echo "Erstelle/Aktualisiere DocRoot: $docroot"

    # Erstelle DocRoot falls nicht vorhanden
    if [ ! -d "$docroot" ]; then
        mkdir -p "$docroot"
    fi

    echo "Setze ACL-Berechtigungen..."

    # Setze Basis-Besitzer
    chown "${username}:www-data" "$docroot"
    chmod 775 "$docroot"

    # Setze ACL für bestehende Dateien
    setfacl -R -m u:${username}:rwx,g:www-data:rwx "$docroot"
    # Setze Default-ACL für neue Dateien
    setfacl -R -d -m u:${username}:rwx,g:www-data:rwx "$docroot"

    # Erstelle symbolischen Link
    local link_name=$(basename "$docroot")
    local count=0
    local final_link_name="${link_name}"

    while [ -L "/home/$username/www-${final_link_name}" ]; do
        count=$((count + 1))
        final_link_name="${link_name}-${count}"
    done

    ln -s "$docroot" "/home/$username/www-${final_link_name}"

    echo "DocRoot Setup abgeschlossen"
    return 0
}

repair_acl_permissions() {
    local docroot=$1
    local username=$2

    if [ -z "$docroot" ] || [ -z "$username" ]; then
        echo "Fehler: DocRoot und Username müssen angegeben werden!"
        return 1
    fi

    if [ ! -d "$docroot" ]; then
        echo "Fehler: DocRoot existiert nicht!"
        return 1
    fi

    if ! check_acl; then
        echo "FEHLER: ACL-Setup fehlgeschlagen."
        return 1
    fi

    echo "Repariere ACL-Berechtigungen für $docroot..."

    # Setze ACL für bestehende Dateien
    setfacl -R -m u:${username}:rwx,g:www-data:rwx "$docroot"
    # Setze Default-ACL für neue Dateien
    setfacl -R -d -m u:${username}:rwx,g:www-data:rwx "$docroot"

    echo "ACL-Berechtigungen repariert!"
    getfacl "$docroot"
}

repair_docroot_permissions() {
    local username=$1
    local is_developer=$2

    if [ -z "$username" ]; then
        echo "Fehler: Kein Username angegeben!"
        return 1
    fi

    echo "Repariere DocRoot-Berechtigungen für User ${username}..."

    # Prüfe ob es ein Chroot-User ist
    if [ -d "/var/www/jails/${username}" ]; then
        local docroot="/var/www/${username}"
        chown -R "${username}:www-data" "$docroot"
        chmod 750 "$docroot"
        return 0
    fi

    # Für Standard/Entwickler-User
    for link in /home/${username}/www-*; do
        if [ -L "$link" ]; then
            local docroot=$(readlink -f "$link")
            if [ -d "$docroot" ]; then
                echo "Verarbeite: $docroot"

                echo "1/3 Setze Basis-Berechtigungen..."
                chown www-data:www-data "$docroot"
                chmod 775 "$docroot"
                chmod g+s "$docroot"

                echo "2/3 Verarbeite Verzeichnisse..."
                find "$docroot" -type d -print0 | while IFS= read -r -d $'\0' dir; do
                    echo -ne "   Verarbeite: $dir\r"
                    chown www-data:www-data "$dir"
                    chmod 775 "$dir"
                done
                echo

                echo "3/3 Verarbeite Dateien..."
                find "$docroot" -type f -print0 | while IFS= read -r -d $'\0' file; do
                    echo -ne "   Verarbeite: $file\r"
                    chown www-data:www-data "$file"
                    chmod 664 "$file"
                done
                echo

                echo "DocRoot $docroot wurde verarbeitet"
                echo "----------------------------------------"
            fi
        fi
    done

    echo "DocRoot-Berechtigungen wurden aktualisiert!"
}

# Chroot User Funktionen
create_secure_chroot_user() {
    local username=$1
    local password=$2
    local web_root=${3:-"/var/www/${username}"}

    echo "Erstelle Chroot-User: $username"

    # Basis-Verzeichnisstruktur
    local jail_root="/var/www/jails/${username}"

    # Erstelle notwendige Verzeichnisse
    mkdir -p "${web_root}"
    mkdir -p "${jail_root}"

    # Erstelle User mit chroot Shell
    useradd -d "${jail_root}" \
            -g www-data \
            -s /usr/sbin/jk_chrootsh \
            "${username}"

    # Setze Passwort
    echo "${username}:${password}" | chpasswd

    # Installiere jailkit falls nicht vorhanden
    if ! command -v jk_init &> /dev/null; then
        apt-get update && apt-get install -y jailkit
    fi

    # Initialisiere chroot mit benötigten Tools
    jk_init -v "${jail_root}" basicshell editors extendedshell git ssh sftp scp rsync

    # Kopiere zusätzliche Bibliotheken
    mkdir -p "${jail_root}/usr/lib/x86_64-linux-gnu/"
    cp /usr/lib/x86_64-linux-gnu/libssl.so* "${jail_root}/usr/lib/x86_64-linux-gnu/"
    cp /usr/lib/x86_64-linux-gnu/libcrypto.so* "${jail_root}/usr/lib/x86_64-linux-gnu/"

    # Web-Verzeichnis Berechtigungen
    chown -R "${username}:www-data" "${web_root}"
    chmod 750 "${web_root}"

    # SSH Setup im Jail
    mkdir -p "${jail_root}/.ssh"
    chmod 700 "${jail_root}/.ssh"
    touch "${jail_root}/.ssh/authorized_keys"
    chmod 600 "${jail_root}/.ssh/authorized_keys"
    chown -R "${username}:www-data" "${jail_root}/.ssh"

    # Erstelle Web-Verzeichnis Link im Jail
    ln -s "${web_root}" "${jail_root}/web"

    # SSH Konfiguration
    cat >> /etc/ssh/sshd_config << EOF

# Secure Chroot Config für ${username}
Match User ${username}
    ChrootDirectory ${jail_root}
    X11Forwarding no
    AllowTcpForwarding no
    ForceCommand internal-sftp
EOF

    # .bashrc im Jail
    cat > "${jail_root}/.bashrc" << EOF
export PS1='\u@\h:\w\$ '
export PATH=/usr/local/bin:/usr/bin:/bin
alias ll='ls -la'
cd /web
EOF

    # Finale Berechtigungen
    chown root:root "${jail_root}"
    chmod 755 "${jail_root}"

    # Neustart SSH
    systemctl restart sshd

    echo "=== Chroot-User Setup abgeschlossen ==="
    echo "Web-Verzeichnis: ${web_root}"
    echo "Jail-Verzeichnis: ${jail_root}"
    echo "SSH-Zugriff: ssh -p 62954 ${username}@domain"
    echo "SFTP-Zugriff: sftp -P 62954 ${username}@domain"
}

# Standard SSH User erstellen
create_ssh_user() {
    local username=$1
    local password=$2
    local is_developer=$3

    if [ -z "$username" ]; then
        echo "Fehler: Kein Username angegeben!"
        return 1
    fi

    if [ -z "$password" ]; then
        echo "Fehler: Kein Passwort angegeben!"
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

    # Erstelle User mit www-data als Gruppe
    useradd -m -g www-data -s /bin/bash "$username"
    echo "${username}:${password}" | chpasswd

    # Basis-Verzeichnisstruktur
    if [ "$is_developer" = "true" ]; then
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

    else
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

    # Setze finale Berechtigungen
    chown -R "${username}:www-data" "/home/${username}"
    chmod 750 "/home/${username}"
    chmod 755 "/home/${username}/bin"

    echo "SSH-User ${username} wurde erstellt!"
}

# User löschen
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

    # Lösche User und Home-Verzeichnis
    userdel -r "$username" 2>/dev/null || {
        echo "Standard-Löschung fehlgeschlagen, versuche forcierte Löschung..."
        userdel "$username" 2>/dev/null
        rm -rf "/home/${username}" 2>/dev/null
    }

    echo "User ${username} wurde gelöscht!"
}

# Chroot User löschen
delete_chroot_user() {
    local username=$1

    echo "Lösche Chroot-User: $username"

    # Pfade
    local web_root="/var/www/${username}"
    local jail_root="/var/www/jails/${username}"

    # Backup erstellen
    local backup_dir="/root/user_backups"
    mkdir -p "${backup_dir}"
    local timestamp=$(date +%Y%m%d_%H%M%S)

    echo "Erstelle Backup..."
    tar czf "${backup_dir}/${username}_backup_${timestamp}.tar.gz" "${web_root}" "${jail_root}" 2>/dev/null

    # User und Verzeichnisse entfernen
    userdel -f "${username}" 2>/dev/null
    rm -rf "${web_root}" "${jail_root}"

    # SSH-Config entfernen
    sed -i "/# Secure Chroot Config für ${username}/,+5d" /etc/ssh/sshd_config

    # SSH neu starten
    systemctl restart sshd

    echo "Chroot-User wurde gelöscht!"
    echo "Backup erstellt: ${backup_dir}/${username}_backup_${timestamp}.tar.gz"
}

# Hilfsfunktionen für SSH Key Management
list_ssh_users() {
    echo "=== SSH User ==="
    echo "Standard und Entwickler User:"
    awk -F: '$7 ~ /\/bin\/bash/ {print "- " $1}' /etc/passwd
    echo
    echo "Chroot User:"
    find "/var/www/jails" -maxdepth 1 -mindepth 1 -type d -exec basename {} \; | while read user; do
        echo "- $user (chroot)"
    done
}

add_ssh_key() {
    local username=$1
    local ssh_key=$2

    if [ -z "$username" ] || [ -z "$ssh_key" ]; then
        echo "Fehler: Username und SSH-Key müssen angegeben werden!"
        return 1
    fi

    # Prüfe ob es ein Chroot-User ist
    if [ -d "/var/www/jails/$username" ]; then
        local ssh_dir="/var/www/jails/${username}/.ssh"
    else
        local ssh_dir="/home/${username}/.ssh"
    fi

    mkdir -p "$ssh_dir"
    echo "$ssh_key" >> "${ssh_dir}/authorized_keys"
    chmod 700 "$ssh_dir"
    chmod 600 "${ssh_dir}/authorized_keys"
    chown -R "${username}:www-data" "$ssh_dir"

    echo "SSH-Key wurde hinzugefügt!"
}

generate_ssh_key() {
    local username=$1
    local key_type=${2:-"ed25519"}

    if [ -z "$username" ]; then
        echo "Fehler: Kein Username angegeben!"
        return 1
    fi

    # Prüfe ob es ein Chroot-User ist
    if [ -d "/var/www/jails/$username" ]; then
        local ssh_dir="/var/www/jails/${username}/.ssh"
    else
        local ssh_dir="/home/${username}/.ssh"
    fi

    mkdir -p "$ssh_dir"

    if [ "$key_type" = "ed25519" ]; then
        ssh-keygen -t ed25519 -f "${ssh_dir}/id_ed25519" -N "" -C "${username}@$(hostname)"
    else
        ssh-keygen -t rsa -b 4096 -f "${ssh_dir}/id_rsa" -N "" -C "${username}@$(hostname)"
    fi

    chmod 700 "$ssh_dir"
    chown -R "${username}:www-data" "$ssh_dir"

    echo "SSH-Key wurde generiert!"
}

list_ssh_keys() {
    local username=$1

    if [ -z "$username" ]; then
        echo "Fehler: Kein Username angegeben!"
        return 1
    fi

    # Prüfe ob es ein Chroot-User ist
    if [ -d "/var/www/jails/$username" ]; then
        local auth_keys="/var/www/jails/${username}/.ssh/authorized_keys"
    else
        local auth_keys="/home/${username}/.ssh/authorized_keys"
    fi

    if [ -f "$auth_keys" ]; then
        echo "SSH-Keys für User ${username}:"
        cat "$auth_keys"
    else
        echo "Keine SSH-Keys für User ${username} gefunden."
    fi
}

upgrade_to_dev() {
    local username=$1

    if [ -z "$username" ]; then
        echo "Fehler: Kein Username angegeben!"
        return 1
    fi

    if [ -d "/var/www/jails/$username" ]; then
        echo "Chroot-User können nicht zu Entwickler-Accounts upgegradet werden!"
        return 1
    fi

    echo "ACHTUNG: User ${username} wird zu einem Entwickler-Account geändert!"
    read -p "Fortfahren? (j/N): " confirm
    if [[ "$confirm" != "j" && "$confirm" != "J" ]]; then
        echo "Abbruch durch Benutzer."
        return 1
    fi

    # Backup der SSH-Keys
    local temp_keys=""
    if [ -f "/home/${username}/.ssh/authorized_keys" ]; then
        temp_keys=$(cat "/home/${username}/.ssh/authorized_keys")
    fi

    # User neu erstellen als Entwickler
    delete_ssh_user "$username"
    sleep 2
    create_ssh_user "$username" "" "true"

    # SSH-Keys wiederherstellen
    if [ ! -z "$temp_keys" ]; then
        echo "$temp_keys" > "/home/${username}/.ssh/authorized_keys"
        chmod 600 "/home/${username}/.ssh/authorized_keys"
        chown "${username}:www-data" "/home/${username}/.ssh/authorized_keys"
    fi

    echo "User wurde zu einem Entwickler-Account upgegradet!"
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
        echo "4. DocRoot-Berechtigungen reparieren"
        echo "5. Zurück"
        echo
        read -p "Wähle eine Option (1-5): " choice

        case $choice in
            1)
                read -p "Pfad zum neuen DocRoot (oder 'q' für abbrechen): " new_docroot
                if [ "$new_docroot" != "q" ] && [ ! -z "$new_docroot" ]; then
                    if grep -q "/bin/bash" <(getent passwd "$username"); then
                        add_docroot "$username" "$new_docroot" "true"
                    else
                        add_docroot "$username" "$new_docroot" "false"
                    fi
                fi
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
                if grep -q "/bin/bash" <(getent passwd "$username"); then
                    repair_docroot_permissions "$username" "true"
                else
                    repair_docroot_permissions "$username" "false"
                fi
                echo "Berechtigungen wurden repariert!"
                ;;
            5)
                submenu=false
                continue
                ;;
            *)
                echo "Ungültige Option!"
                ;;
        esac

        if [ "$choice" != "5" ]; then
            echo
            read -p "Enter drücken zum Fortfahren..."
        fi
    done
}

# Hauptmenü-Funktion
ssh_menu() {
    local submenu=true

    while $submenu; do
        clear
        echo "=== SSH User Management ==="
        echo "1. Standard SSH-User erstellen"
        echo "2. Entwickler SSH-User erstellen"
        echo "3. Secure Chroot-User erstellen (ISPConfig-Style)"
        echo "4. SSH-User löschen"
        echo "5. SSH-User anzeigen"
        echo "6. SSH-Key zu bestehendem User hinzufügen"
        echo "7. Neuen SSH-Key für User generieren"
        echo "8. SSH-Keys eines Users anzeigen"
        echo "9. User zu Entwickler-Account upgraden"
        echo "10. DocRoots verwalten"
        echo "11. DocRoot-Berechtigungen reparieren"
        echo "12. ACL-Berechtigungen reparieren"
        echo "13. Zurück zum Hauptmenü"
        echo
        read -r -p "Wähle eine Option (1-13): " choice

        case $choice in
            1)
                echo
                read -p "Username (oder 'q' für abbrechen): " username
                [ "$username" = "q" ] && continue
                read -s -p "Passwort: " password
                echo
                create_ssh_user "$username" "$password" "false"
                ;;
            2)
                echo
                read -p "Username (oder 'q' für abbrechen): " username
                [ "$username" = "q" ] && continue
                read -s -p "Passwort: " password
                echo
                create_ssh_user "$username" "$password" "true"
                ;;
            3)
                echo
                read -p "Username (oder 'q' für abbrechen): " username
                [ "$username" = "q" ] && continue
                read -s -p "Passwort: " password
                echo
                read -p "Web-Verzeichnis [/var/www/$username]: " web_root
                web_root=${web_root:-"/var/www/$username"}
                create_secure_chroot_user "$username" "$password" "$web_root"
                ;;
            4)
                echo
                list_ssh_users
                echo
                read -p "Username zum Löschen (oder 'q' für abbrechen): " username
                [ "$username" = "q" ] && continue

                # Prüfe ob es ein Chroot-User ist
                if [ -d "/var/www/jails/$username" ]; then
                    delete_chroot_user "$username"
                else
                    delete_ssh_user "$username"
                fi
                ;;
            5)
                echo
                list_ssh_users
                ;;
            6)
                echo
                list_ssh_users
                echo
                read -p "Username (oder 'q' für abbrechen): " username
                [ "$username" = "q" ] && continue
                echo "Bitte SSH Public Key eingeben (Format: ssh-rsa/ssh-ed25519 AAAA... user@host):"
                read ssh_key
                add_ssh_key "$username" "$ssh_key"
                ;;
            7)
                echo
                list_ssh_users
                echo
                read -p "Username (oder 'q' für abbrechen): " username
                [ "$username" = "q" ] && continue
                read -p "Key-Typ (ed25519/rsa) [Standard: ed25519]: " key_type
                [ -z "$key_type" ] && key_type="ed25519"
                generate_ssh_key "$username" "$key_type"
                ;;
            8)
                echo
                list_ssh_users
                echo
                read -p "Username (oder 'q' für abbrechen): " username
                [ "$username" = "q" ] && continue
                list_ssh_keys "$username"
                ;;
            9)
                echo
                list_ssh_users
                echo
                read -p "Username zum Upgrade (oder 'q' für abbrechen): " username
                [ "$username" = "q" ] && continue
                upgrade_to_dev "$username"
                ;;
            10)
                echo
                list_ssh_users
                echo
                read -p "Username für DocRoot-Management (oder 'q' für abbrechen): " username
                [ "$username" = "q" ] && continue
                if id "$username" &>/dev/null; then
                    manage_docroots "$username"
                else
                    echo "User existiert nicht!"
                    read -p "Enter drücken zum Fortfahren..."
                fi
                ;;
            11)
                echo
                list_ssh_users
                echo
                read -p "Username für Berechtigungsreparatur (oder 'q' für abbrechen): " username
                [ "$username" = "q" ] && continue
                if id "$username" &>/dev/null; then
                    if grep -q "/bin/bash" <(getent passwd "$username"); then
                        repair_docroot_permissions "$username" "true"
                    else
                        repair_docroot_permissions "$username" "false"
                    fi
                    echo "Berechtigungen wurden repariert!"
                else
                    echo "User existiert nicht!"
                fi
                read -p "Enter drücken zum Fortfahren..."
                ;;
            12)
                echo
                list_ssh_users
                echo
                read -p "Username für ACL-Reparatur (oder 'q' für abbrechen): " username
                [ "$username" = "q" ] && continue
                if id "$username" &>/dev/null; then
                    read -p "DocRoot-Pfad: " docroot
                    repair_acl_permissions "$docroot" "$username"
                else
                    echo "User existiert nicht!"
                fi
                read -p "Enter drücken zum Fortfahren..."
                ;;
            13)
                submenu=false
                continue
                ;;
            *)
                echo "Ungültige Option!"
                ;;
        esac

        if [ "$choice" != "13" ]; then
            echo
            read -p "Enter drücken zum Fortfahren..."
            clear
        fi
    done
}

# Hauptprogramm
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [ "$EUID" -ne 0 ]; then
        echo "Dieses Script muss als root ausgeführt werden!"
        exit 1
    fi
    ssh_menu
fi