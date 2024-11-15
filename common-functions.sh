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
