#!/bin/bash
# ssl-setup-subdomain.sh - SSL Setup für (Sub)Domains

# Farben für die Ausgabe
CYAN='\033[1;36m'
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Funktion zum Prüfen der Root-Rechte
check_root() {
    if [ "$EUID" -ne 0 ]; then 
        echo -e "${RED}Dieses Script muss als root ausgeführt werden!${NC}"
        exit 1
    fi
}

# Funktion zum Prüfen und Installieren von certbot
ensure_certbot() {
    if ! command -v certbot &> /dev/null; then
        echo -e "${YELLOW}Certbot wird installiert...${NC}"
        apt update
        apt install -y certbot
    fi
}

# Funktion zum Erstellen des SSL-Zertifikats
create_certificate() {
    local domain=$1
    local email=$2
    local is_subdomain=$3
    
    echo -e "${CYAN}Erstelle SSL-Zertifikat für $domain${NC}"
    
    # Apache temporär stoppen
    systemctl stop apache2
    
    if [ "$is_subdomain" = true ]; then
        # Nur für die Subdomain selbst
        certbot certonly --standalone \
            -d "$domain" \
            --agree-tos \
            --email "$email" \
            --preferred-challenges http
    else
        # Für Hauptdomain mit www
        certbot certonly --standalone \
            -d "$domain" \
            -d "www.$domain" \
            --agree-tos \
            --email "$email" \
            --preferred-challenges http
    fi
        
    local certbot_exit=$?
    
    # Apache wieder starten
    systemctl start apache2
    
    return $certbot_exit
}

# Funktion zum Konfigurieren des Apache VirtualHost
configure_apache() {
    local domain=$1
    local config_file="/etc/apache2/sites-available/$domain.conf"
    
    echo -e "${CYAN}Konfiguriere Apache für SSL...${NC}"
    
    # Backup erstellen
    cp "$config_file" "$config_file.backup"
    
    # SSL-VirtualHost hinzufügen
    cat >> "$config_file" << EOF

<VirtualHost *:443>
    ServerName $domain
    DocumentRoot /var/www/$domain/html
    
    SSLEngine on
    SSLCertificateFile /etc/letsencrypt/live/$domain/fullchain.pem
    SSLCertificateKeyFile /etc/letsencrypt/live/$domain/privkey.pem
    
    <Directory /var/www/$domain/html>
        Options -Indexes +FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>
    
    ErrorLog \${APACHE_LOG_DIR}/$domain-error.log
    CustomLog \${APACHE_LOG_DIR}/$domain-access.log combined
</VirtualHost>
EOF
    
    # HTTP auf HTTPS umleiten
    sed -i '/<VirtualHost \*:80>/a\    Redirect permanent / https://'$domain'/' "$config_file"
    
    # Apache Module aktivieren
    a2enmod ssl
    a2enmod headers
    
    # Konfiguration testen
    apache2ctl configtest
    
    # Apache neu laden
    systemctl restart apache2
}

# Funktion zum Erstellen des Auto-Renewal Skripts
create_renewal_script() {
    local domain=$1
    
    echo -e "${CYAN}Erstelle Auto-Renewal Skript...${NC}"
    
    # Nur erstellen, wenn noch nicht vorhanden
    if [ ! -f "/usr/local/bin/renew-ssl.sh" ]; then
        cat > /usr/local/bin/renew-ssl.sh << EOF
#!/bin/bash

# SSL-Zertifikate erneuern
certbot renew --quiet --no-self-upgrade

# Apache neu laden, wenn Zertifikate erneuert wurden
if [ -f /var/log/letsencrypt/renew.log ] && grep -q "Congratulations" /var/log/letsencrypt/renew.log; then
    systemctl reload apache2
fi
EOF
        
        chmod +x /usr/local/bin/renew-ssl.sh
        
        # Cronjob einrichten, wenn noch nicht vorhanden
        if ! crontab -l | grep -q "renew-ssl.sh"; then
            (crontab -l 2>/dev/null; echo "0 3 * * * /usr/local/bin/renew-ssl.sh") | crontab -
        fi
    fi
}

# Verzeichnisstruktur erstellen
create_directory_structure() {
    local domain=$1
    
    echo -e "${CYAN}Erstelle Verzeichnisstruktur...${NC}"
    
    # Verzeichnis erstellen, wenn es noch nicht existiert
    if [ ! -d "/var/www/$domain/html" ]; then
        mkdir -p "/var/www/$domain/html"
        chown -R www-data:www-data "/var/www/$domain"
        chmod -R 755 "/var/www/$domain"
    fi
}

# Hauptfunktion
main() {
    local domain=$1
    local email=$2
    local is_subdomain=$3
    
    check_root
    ensure_certbot
    create_directory_structure "$domain"
    
    if create_certificate "$domain" "$email" "$is_subdomain"; then
        configure_apache "$domain"
        create_renewal_script "$domain"
        echo -e "${GREEN}SSL-Setup für $domain erfolgreich abgeschlossen!${NC}"
        echo -e "${YELLOW}Wichtige Hinweise:${NC}"
        echo "1. Die Zertifikate werden automatisch jeden Tag um 3 Uhr morgens überprüft"
        echo "2. Apache wird automatisch neu geladen, wenn Zertifikate erneuert wurden"
        echo "3. Backup der original Apache-Konfiguration wurde erstellt: $domain.conf.backup"
        echo "4. Webroot Verzeichnis: /var/www/$domain/html"
    else
        echo -e "${RED}Fehler beim Erstellen des SSL-Zertifikats!${NC}"
        exit 1
    fi
}

# Skript-Ausführung
if [ $# -lt 2 ]; then
    echo "Verwendung für Hauptdomain: $0 domain.de email@domain.de"
    echo "Verwendung für Subdomain: $0 subdomain.domain.de email@domain.de subdomain"
    exit 1
fi

# Prüfe ob es sich um eine Subdomain handelt
is_subdomain=false
if [ "$3" = "subdomain" ]; then
    is_subdomain=true
fi

main "$1" "$2" "$is_subdomain"
