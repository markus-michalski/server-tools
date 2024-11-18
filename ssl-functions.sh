#!/bin/bash

source /root/server-tools/common-functions.sh

# Konfiguration prüfen und anpassen
check_and_fix_vhost() {
    local domain=$1
    local base_conf="/etc/apache2/sites-available/${domain}.conf"
    local ssl_conf="/etc/apache2/sites-available/${domain}-le-ssl.conf"

    # Prüfe ob Basis-Konfig existiert
    if [ ! -f "$base_conf" ]; then
        echo "Fehler: Virtual Host ${base_conf} existiert nicht!"
        return 1
    fi

    # Backup erstellen
    local timestamp=$(date +%Y%m%d_%H%M%S)
    cp "$base_conf" "${base_conf}.backup_${timestamp}"
    [ -f "$ssl_conf" ] && cp "$ssl_conf" "${ssl_conf}.backup_${timestamp}"

    # Prüfe/Korrigiere HTTP-Konfiguration
    if ! grep -q "Redirect permanent" "$base_conf"; then
        echo "Passe HTTP-Konfiguration an..."
        # Sichere temporär den DocumentRoot und ServerAlias
        local docroot=$(grep -i "DocumentRoot" "$base_conf" | awk '{print $2}')
        local server_alias=$(grep -i "ServerAlias" "$base_conf" | sed 's/ServerAlias//')

        # Erstelle neue HTTP-Konfiguration
        cat > "$base_conf" << EOF
<VirtualHost *:80>
    ServerAdmin webmaster@${domain}
    ServerName ${domain}
    ServerAlias ${server_alias}
    DocumentRoot ${docroot}

    # Redirect all HTTP traffic to HTTPS
    RewriteEngine On
    RewriteCond %{HTTPS} off
    RewriteRule ^(.*)$ https://%{HTTP_HOST}%{REQUEST_URI} [L,R=301]

    ErrorLog \${APACHE_LOG_DIR}/${domain}_error.log
    CustomLog \${APACHE_LOG_DIR}/${domain}_access.log combined
</VirtualHost>
EOF
    fi

    # Wenn SSL-Konfig existiert, prüfe/korrigiere diese
    if [ -f "$ssl_conf" ]; then
        echo "Prüfe SSL-Konfiguration..."
        # Füge wichtige SSL-Header hinzu falls nicht vorhanden
        if ! grep -q "Header always set Strict-Transport-Security" "$ssl_conf"; then
            sed -i '/<VirtualHost/a\    # SSL Security Headers\n    Header always set Strict-Transport-Security "max-age=31536000; includeSubDomains"\n    Header always set X-Frame-Options "SAMEORIGIN"\n    Header always set X-Content-Type-Options "nosniff"\n    Header always set X-XSS-Protection "1; mode=block"\n    Header always set Referrer-Policy "strict-origin-when-cross-origin"' "$ssl_conf"
        fi

        # Prüfe SSL-Einstellungen
        if ! grep -q "SSLProtocol" "$ssl_conf"; then
            sed -i '/<VirtualHost/a\    # SSL Configuration\n    SSLProtocol all -SSLv3 -TLSv1 -TLSv1.1\n    SSLCipherSuite ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384\n    SSLHonorCipherOrder off\n    SSLSessionTickets off' "$ssl_conf"
        fi
    fi

    echo "VHost-Konfigurationen wurden überprüft und angepasst."
    systemctl reload apache2
}

# SSL-Zertifikat erstellen
setup_ssl() {
    local domain=$1

    if [ ! -f "/etc/apache2/sites-available/${domain}.conf" ]; then
        echo "Fehler: Virtual Host für ${domain} existiert nicht!"
        return 1
    fi

    # Certbot Installation prüfen/durchführen
    if ! command -v certbot &> /dev/null || ! dpkg -l | grep -q python3-certbot-apache; then
        install_certbot
        if [ $? -ne 0 ]; then
            echo "Fehler bei der Installation von Certbot!"
            return 1
        fi
    fi

    echo "Erstelle SSL-Zertifikat für ${domain}..."

    # Certbot ausführen
    certbot --apache -d "${domain}" --non-interactive --agree-tos --email webmaster@${domain}

    if [ $? -eq 0 ]; then
        echo "SSL-Zertifikat erfolgreich erstellt!"
        # Überprüfe und korrigiere VHost-Konfigurationen
        check_and_fix_vhost "$domain"
    else
        echo "Fehler beim Erstellen des SSL-Zertifikats!"
        return 1
    fi
}

# SSL-Zertifikat löschen
delete_ssl() {
    local domain=$1
    local base_conf="/etc/apache2/sites-available/${domain}.conf"
    local ssl_conf="/etc/apache2/sites-available/${domain}-le-ssl.conf"

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

    # Backup erstellen
    local timestamp=$(date +%Y%m%d_%H%M%S)
    [ -f "$base_conf" ] && cp "$base_conf" "${base_conf}.backup_${timestamp}"
    [ -f "$ssl_conf" ] && cp "$ssl_conf" "${ssl_conf}.backup_${timestamp}"

    # Zertifikat löschen
    certbot delete --cert-name "$domain" --non-interactive

    if [ $? -eq 0 ]; then
        echo "SSL-Zertifikat wurde gelöscht!"

        # Entferne SSL-spezifische Konfiguration aus HTTP-VHost
        if [ -f "$base_conf" ]; then
            sed -i '/RewriteEngine On/d' "$base_conf"
            sed -i '/RewriteCond %{HTTPS}/d' "$base_conf"
            sed -i '/RewriteRule \^/d' "$base_conf"
        fi

        # Entferne SSL-VHost wenn vorhanden
        [ -f "$ssl_conf" ] && rm "$ssl_conf"

        systemctl reload apache2
        echo "Apache-Konfiguration wurde bereinigt."
    else
        echo "Fehler beim Löschen des SSL-Zertifikats!"
        return 1
    fi
}

# SSL-Konfiguration prüfen
check_ssl() {
    local domain=$1

    echo "Prüfe SSL-Konfiguration für ${domain}..."

    # Prüfe ob Zertifikat existiert
    if ! certbot certificates | grep -q "$domain"; then
        echo "Kein SSL-Zertifikat für ${domain} gefunden!"
        return 1
    fi

    # Prüfe VHost-Konfigurationen
    check_and_fix_vhost "$domain"

    # Teste SSL-Konfiguration
    local ssl_check=$(curl -sI "https://${domain}" | head -n 1)
    if [[ "$ssl_check" == *"200 OK"* || "$ssl_check" == *"301 Moved"* ]]; then
        echo "SSL-Konfiguration ist aktiv und funktioniert."
    else
        echo "WARNUNG: SSL-Konfiguration könnte Probleme haben!"
        echo "HTTP-Response: $ssl_check"
    fi
}

# SSL Management Menü
ssl_menu() {
    local submenu=true

    while $submenu; do
        clear
        echo "=== SSL Management ==="
        echo "1. SSL-Zertifikat erstellen"
        echo "2. SSL-Zertifikat löschen"
        echo "3. SSL-Zertifikate anzeigen"
        echo "4. SSL-Konfiguration prüfen"
        echo "5. Zurück zum Hauptmenü"
        echo
        read -p "Wähle eine Option (1-5): " choice

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
                read -p "Domain: " domain
                check_ssl "$domain"
                ;;
            5)
                submenu=false
                ;;
            *)
                echo "Ungültige Option!"
                ;;
        esac

        if [ "$choice" != "5" ]; then
            read -p "Enter drücken zum Fortfahren..."
            clear
        fi
    done
}