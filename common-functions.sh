#!/bin/bash

# Prüft ob Script als root ausgeführt wird
check_root() {
    if [ "$EUID" -ne 0 ]; then 
        echo "Dieses Skript muss als root ausgeführt werden!"
        exit 1
    fi
}

# Installiert Certbot und Abhängigkeiten
install_certbot() {
    echo "Installiere Certbot und Apache-Plugin..."
    apt-get update
    apt-get install -y certbot python3-certbot-apache
    
    if ! command -v certbot &> /dev/null; then
        echo "Fehler: Certbot konnte nicht installiert werden!"
        return 1
    fi
    
    if ! dpkg -l | grep -q python3-certbot-apache; then
        echo "Fehler: Apache-Plugin konnte nicht installiert werden!"
        return 1
    fi
    
    return 0
}

# Validiert SSH-Keys
validate_ssh_key() {
    local key="$1"

    if ! echo "$key" | grep -qE "^(ssh-rsa|ssh-ed25519|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521) "; then
        return 1
    fi

    if [ "$(echo "$key" | awk '{print NF}')" -lt 2 ]; then
        return 1
    fi

    return 0
}

# Funktion zur Prüfung und Installation von ACL
check_acl() {
    # Prüfe ob setfacl verfügbar ist
    if ! command -v setfacl &> /dev/null; then
        echo "ACL ist nicht installiert. Installation wird gestartet..."

        # Prüfe ob wir root sind
        if [ "$EUID" -ne 0 ]; then
            echo "Fehler: Root-Rechte werden für die Installation benötigt!"
            return 1
        fi

        # Prüfe ob apt verfügbar ist
        if ! command -v apt-get &> /dev/null; then
            echo "Fehler: apt-get nicht gefunden. Bitte installieren Sie ACL manuell!"
            return 1
        fi

        # Aktualisiere apt und installiere acl
        apt-get update -qq
        apt-get install -y acl

        # Prüfe ob Installation erfolgreich war
        if ! command -v setfacl &> /dev/null; then
            echo "Fehler: ACL-Installation fehlgeschlagen!"
            return 1
        fi

        echo "ACL wurde erfolgreich installiert!"
    fi

    # Prüfe ob ACL im Filesystem aktiviert ist
    if ! mount | grep -q "acl"; then
        echo "Warnung: ACL scheint im Filesystem nicht aktiviert zu sein."
        echo "Prüfe /etc/fstab Einträge..."

        # Prüfe ob ACL in fstab aktiviert ist
        if ! grep -q "acl" /etc/fstab; then
            echo "ACL ist nicht in /etc/fstab konfiguriert."
            echo "Möchten Sie ACL automatisch in /etc/fstab aktivieren? (j/N)"
            read -r response
            if [[ "$response" =~ ^[Jj]$ ]]; then
                # Backup von fstab erstellen
                cp /etc/fstab /etc/fstab.backup
                # Füge acl Option hinzu
                sed -i 's/defaults/defaults,acl/g' /etc/fstab
                echo "ACL wurde in /etc/fstab aktiviert. Ein Neustart wird empfohlen!"
                echo "Backup wurde erstellt unter /etc/fstab.backup"
            else
                echo "Bitte aktivieren Sie ACL manuell in /etc/fstab"
                return 1
            fi
        fi
    fi

    return 0
}

# Überprüft die Chroot-Struktur eines Users
verify_chroot_structure() {
    local username=$1

    if [ -z "$username" ]; then
        echo "Fehler: Kein Username angegeben!"
        return 1
    fi

    local jail_root="/var/www/jails/${username}"
    local web_root="/var/www/${username}"

    # Prüfe Hauptverzeichnisse
    local error=0

    # Prüfe Web-Verzeichnis
    if [ ! -d "$web_root" ]; then
        echo "FEHLER: Web-Verzeichnis ${web_root} existiert nicht!"
        error=1
    else
        if [ ! -d "${web_root}/html" ]; then
            echo "FEHLER: HTML-Verzeichnis fehlt!"
            error=1
        fi
        if [ ! -d "${web_root}/logs" ]; then
            echo "FEHLER: Logs-Verzeichnis fehlt!"
            error=1
        fi
    fi

    # Prüfe Jail-Verzeichnis
    if [ ! -d "$jail_root" ]; then
        echo "FEHLER: Jail-Verzeichnis ${jail_root} existiert nicht!"
        error=1
    else
        if [ ! -L "${jail_root}/web" ]; then
            echo "FEHLER: Web-Symlink im Jail fehlt!"
            error=1
        else
            local link_target=$(readlink "${jail_root}/web")
            local expected_target="var/www/${username}"  # Relativ, ohne führenden Slash

            if [ "$link_target" != "$expected_target" ]; then
                echo "FEHLER: Web-Symlink zeigt auf falsches Ziel!"
                echo "Aktuell: $link_target"
                echo "Erwartet: $expected_target"
                error=1
            fi
        fi
    fi

    # Prüfe Berechtigungen
    if [ -d "$web_root" ]; then
        local web_owner=$(stat -c '%U:%G' "$web_root")
        if [ "$web_owner" != "${username}:www-data" ]; then
            echo "FEHLER: Falsche Berechtigungen auf ${web_root}"
            echo "Aktuell: $web_owner"
            echo "Erwartet: ${username}:www-data"
            error=1
        fi
    fi

    if [ $error -eq 0 ]; then
        return 0
    else
        echo "Fehler in der Chroot-Struktur gefunden!"
        return 1
    fi
}

# Repariert eine beschädigte Chroot-Struktur
repair_chroot_setup() {
    local username=$1

    if [ -z "$username" ]; then
        echo "Fehler: Kein Username angegeben!"
        return 1
    fi

    local jail_root="/var/www/jails/${username}"
    local web_root="/var/www/${username}"

    echo "Repariere Chroot-Setup für ${username}..."

    # 1. Backup erstellen
    echo "1/5 Erstelle Backup..."
    local backup_dir="/root/chroot_backups"
    local timestamp=$(date +%Y%m%d_%H%M%S)
    mkdir -p "$backup_dir"

    if [ -d "$web_root" ]; then
        tar czf "${backup_dir}/${username}_web_${timestamp}.tar.gz" "$web_root"
    fi
    if [ -d "$jail_root" ]; then
        tar czf "${backup_dir}/${username}_jail_${timestamp}.tar.gz" "$jail_root"
    fi

    # 2. Web-Verzeichnisstruktur korrigieren
    echo "2/5 Korrigiere Web-Verzeichnisstruktur..."
    mkdir -p "${web_root}/html"
    mkdir -p "${web_root}/logs"
    mkdir -p "${web_root}/tmp"

    # 3. Jail-Verzeichnis reparieren
    echo "3/5 Korrigiere Jail-Verzeichnis..."
    # Erstelle var/www Struktur
    mkdir -p "${jail_root}/var/www"

    # 4. Symlink neu erstellen
    echo "4/5 Erstelle Symlink neu..."
    # Entferne alten Symlink
    rm -f "${jail_root}/web"
    # Erstelle neuen relativen Symlink
    ln -sfn "var/www/${username}" "${jail_root}/web"

    # 5. Berechtigungen korrigieren
    echo "5/5 Korrigiere Berechtigungen..."
    chown -R "${username}:www-data" "$web_root"
    find "$web_root" -type d -exec chmod 750 {} \;
    find "$web_root" -type f -exec chmod 640 {} \;
    chown -h "${username}:www-data" "${jail_root}/web"

    echo "Reparatur abgeschlossen. Überprüfe Struktur..."
    verify_chroot_structure "$username"

    return $?
}