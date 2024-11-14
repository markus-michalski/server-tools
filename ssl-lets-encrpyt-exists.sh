#!/bin/bash

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
    ServerAlias www.$domain
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

# Hauptfunktion
main() {
    local domain=$1
    
    check_root
    
    # Prüfen ob das Zertifikat existiert
    if [ ! -f "/etc/letsencrypt/live/$domain/fullchain.pem" ]; then
        echo -e "${RED}Fehler: Kein SSL-Zertifikat für $domain gefunden!${NC}"
        echo -e "Das Webmin-Zertifikat sollte bereits unter /etc/letsencrypt/live/$domain/ existieren."
        exit 1
    fi
    
    configure_apache "$domain"
    echo -e "${GREEN}SSL-Konfiguration für Apache erfolgreich abgeschlossen!${NC}"
    echo -e "${YELLOW}Wichtige Hinweise:${NC}"
    echo "1. Die SSL-Zertifikate werden bereits durch Webmin automatisch erneuert"
    echo "2. Backup der original Apache-Konfiguration wurde erstellt: $domain.conf.backup"
    echo "3. Die Website ist nun über HTTPS erreichbar"
}

# Skript-Ausführung
if [ $# -ne 1 ]; then
    echo "Verwendung: $0 domain.de"
    exit 1
fi

main "$1"
