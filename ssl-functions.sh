#!/bin/bash

source /root/server-tools/common-functions.sh

# SSL-Zertifikat erstellen
setup_ssl() {
    local domain=$1

    if [ ! -f "/etc/apache2/sites-available/${domain}.conf" ]; then
        echo "Fehler: Virtual Host für ${domain} existiert nicht!"
        return 1
    fi

    if ! command -v certbot &> /dev/null || ! dpkg -l | grep -q python3-certbot-apache; then
        install_certbot
        if [ $? -ne 0 ]; then
            echo "Fehler bei der Installation!"
            return 1
        fi
    fi

    echo "Erstelle SSL-Zertifikat für ${domain}..."
    certbot --apache -d "${domain}" --non-interactive --agree-tos --email webmaster@${domain}

    if [ $? -eq 0 ]; then
        echo "SSL-Zertifikat erfolgreich erstellt!"
        systemctl reload apache2
    else
        echo "Fehler beim Erstellen des SSL-Zertifikats!"
        return 1
    fi
}

# SSL-Zertifikat löschen
delete_ssl() {
    local domain=$1

    if ! command -v certbot &> /dev/null; then
        echo "Certbot ist nicht installiert!"
        return 1
    fi

    echo "Vorhandene Zertifikate:"
    certbot certificates

    echo -e "\nACHTUNG: SSL-Zertifikat für ${domain} wird gelöscht!"
    read -p "Fortfahren? (j/N): " confirm
    if [[ "$confirm" != "j" && "$confirm" != "J" ]]; then
        return 1
    fi

    certbot delete --cert-name "$domain" --non-interactive
    
    if [ $? -eq 0 ]; then
        echo "SSL-Zertifikat für ${domain} wurde gelöscht!"
        [ -f "/etc/apache2/sites-available/${domain}.conf" ] && systemctl reload apache2
    else
        echo "Fehler beim Löschen des SSL-Zertifikats!"
        return 1
    fi
}

# SSL Management Menü
ssl_menu() {
    local submenu=true

    while $submenu; do
        echo "=== SSL Management ==="
        echo "1. SSL-Zertifikat erstellen"
        echo "2. SSL-Zertifikat löschen"
        echo "3. SSL-Zertifikate anzeigen"
        echo "4. Zurück zum Hauptmenü"

        read -p "Wähle eine Option (1-4): " choice

        case $choice in
            1)
                read -p "Domain: " domain
                setup_ssl "$domain"
                ;;
            2)
                certbot certificates
                read -p "Domain: " domain
                delete_ssl "$domain"
                ;;
            3)
                echo "=== SSL-Zertifikate ==="
                certbot certificates
                ;;
            4)
                submenu=false
                ;;
            *)
                echo "Ungültige Option!"
                ;;
        esac

        if [ "$choice" != "4" ]; then
            read -p "Enter drücken zum Fortfahren..."
            clear
        fi
    done
}
