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
