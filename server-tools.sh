#!/bin/bash

# Gemeinsame Funktionen
check_root() {
    if [ "$EUID" -ne 0 ]; then 
        echo "Dieses Skript muss als root ausgeführt werden!"
        exit 1
    fi
}

# Certbot und Abhängigkeiten installieren
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

# 1. Virtual Host erstellen
create_vhost() {
    local domain=$1
    local aliases=$2
    local php_version=$3
    local custom_docroot=$4
    local docroot
    
    # Wenn kein custom_docroot angegeben, Standard-Pfad verwenden
    if [ -z "$custom_docroot" ]; then
        docroot="/var/www/${domain}"
    else
        docroot="${custom_docroot}"
    fi
    
    echo "Erstelle Virtual Host für ${domain}..."
    echo "DocumentRoot: ${docroot}"
    
    # DocRoot erstellen
    mkdir -p "${docroot}"
    
    # Willkommens-Seite erstellen
    cat > "${docroot}/index.html" <<EOF
<!DOCTYPE html>
<html lang="de">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Willkommen auf ${domain}</title>
    <style>
        body {
            font-family: Arial, sans-serif;
            line-height: 1.6;
            max-width: 800px;
            margin: 40px auto;
            padding: 20px;
            text-align: center;
            color: #333;
        }
        h1 {
            color: #2c3e50;
        }
        .success {
            color: #27ae60;
            font-weight: bold;
        }
        .info {
            background: #f8f9fa;
            padding: 15px;
            border-radius: 5px;
            margin-top: 20px;
        }
    </style>
</head>
<body>
    <h1>Willkommen auf ${domain}!</h1>
    <p class="success">Die Erstellung des vHosts hat erfolgreich funktioniert!</p>
    <div class="info">
        <p>Server Setup Details:</p>
        <p>Document Root: ${docroot}</p>
        <p>PHP Version: ${php_version}</p>
        <p>Erstellt am: $(date +"%d.%m.%Y um %H:%M Uhr")</p>
    </div>
</body>
</html>
EOF
    
    # Berechtigungen setzen
    chown -R www-data:www-data "${docroot}"
    chmod -R 755 "${docroot}"
    
    # Apache vHost Config erstellen
    cat > "/etc/apache2/sites-available/${domain}.conf" <<EOF
<VirtualHost *:80>
    ServerName ${domain}
    ServerAlias ${aliases}
    DocumentRoot ${docroot}
    
    <Directory ${docroot}>
        Options Indexes FollowSymLinks MultiViews
        AllowOverride All
        Require all granted
    </Directory>
    
    <FilesMatch \.php$>
        SetHandler "proxy:unix:/run/php/php${php_version}-fpm.sock|fcgi://localhost"
    </FilesMatch>
    
    ErrorLog \${APACHE_LOG_DIR}/${domain}_error.log
    CustomLog \${APACHE_LOG_DIR}/${domain}_access.log combined
</VirtualHost>
EOF

    # vHost aktivieren
    a2ensite "${domain}.conf"
    systemctl reload apache2
    
    echo "Virtual Host für ${domain} wurde erfolgreich erstellt!"
    echo "Die Willkommensseite ist unter http://${domain} erreichbar (sobald DNS konfiguriert ist)"
}

# Funktion zum Löschen eines Virtual Hosts
delete_vhost() {
    local domain=$1
    local docroot
    
    # Prüfe ob vHost existiert
    if [ ! -f "/etc/apache2/sites-available/${domain}.conf" ]; then
        echo "Fehler: Virtual Host für ${domain} existiert nicht!"
        return 1
    fi
    
    # Hole DocRoot aus der Konfiguration
    docroot=$(grep -i "DocumentRoot" "/etc/apache2/sites-available/${domain}.conf" | awk '{print $2}')
    
    echo "ACHTUNG: Folgende Aktionen werden durchgeführt:"
    echo "1. Deaktivierung des Virtual Hosts: ${domain}"
    echo "2. Löschen der Konfigurationsdatei"
    if [ ! -z "$docroot" ]; then
        echo "3. Löschen des Document Root: ${docroot}"
    fi
    echo "4. Löschen eventuell vorhandener SSL-Zertifikate"
    
    read -p "Möchtest du fortfahren? (j/N): " confirm
    if [[ "$confirm" != "j" && "$confirm" != "J" ]]; then
        echo "Abbruch durch Benutzer."
        return 1
    fi
    
    # Deaktiviere vHost
    a2dissite "${domain}.conf"
    
    # Entferne SSL-Zertifikate falls vorhanden
    if command -v certbot &> /dev/null; then
        certbot delete --cert-name "$domain" --non-interactive || true
    fi
    
    # Lösche Konfigurationsdatei
    rm -f "/etc/apache2/sites-available/${domain}.conf"
    rm -f "/etc/apache2/sites-available/${domain}-le-ssl.conf"
    
    # Lösche DocRoot wenn bestätigt
    if [ ! -z "$docroot" ]; then
        read -p "Soll der DocumentRoot ($docroot) wirklich gelöscht werden? (j/N): " confirm_docroot
        if [[ "$confirm_docroot" == "j" || "$confirm_docroot" == "J" ]]; then
            rm -rf "$docroot"
            echo "DocumentRoot wurde gelöscht."
        fi
    fi
    
    # Apache neu laden
    systemctl reload apache2
    
    echo "Virtual Host für ${domain} wurde erfolgreich entfernt!"
}

# PHP Version für vHost ändern
change_php_version() {
    local domain=$1
    local php_version=$2
    
    sed -i "s|proxy:unix:/run/php/php.*-fpm.sock|proxy:unix:/run/php/php${php_version}-fpm.sock|g" \
        "/etc/apache2/sites-available/${domain}.conf"
    
    systemctl reload apache2
}

# SSL-Zertifikat erstellen und konfigurieren
setup_ssl() {
    local domain=$1
    
    # Prüfe ob Apache vHost existiert
    if [ ! -f "/etc/apache2/sites-available/${domain}.conf" ]; then
        echo "Fehler: Virtual Host für ${domain} existiert nicht!"
        echo "Bitte erstelle zuerst einen Virtual Host."
        return 1
    fi
    
    # Installiere Certbot und Plugin falls nicht vorhanden
    if ! command -v certbot &> /dev/null || ! dpkg -l | grep -q python3-certbot-apache; then
        install_certbot
        if [ $? -ne 0 ]; then
            echo "Fehler bei der Installation der benötigten Pakete!"
            return 1
        fi
    fi
    
    echo "Erstelle SSL-Zertifikat für ${domain}..."
    certbot --apache -d "${domain}" --non-interactive --agree-tos --email webmaster@${domain}
    
    if [ $? -eq 0 ]; then
        echo "SSL-Zertifikat erfolgreich erstellt und konfiguriert!"
        systemctl reload apache2
    else
        echo "Fehler beim Erstellen des SSL-Zertifikats!"
        return 1
    fi
}

# Funktion zum Löschen von SSL-Zertifikaten
delete_ssl() {
    local domain=$1
    
    # Prüfe ob Certbot installiert ist
    if ! command -v certbot &> /dev/null; then
        echo "Certbot ist nicht installiert!"
        return 1
    fi
    
    # Zeige aktuelle Zertifikate
    echo "Vorhandene Zertifikate:"
    certbot certificates
    
    echo -e "\nACHTUNG: SSL-Zertifikat für ${domain} wird gelöscht!"
    read -p "Möchtest du fortfahren? (j/N): " confirm
    if [[ "$confirm" != "j" && "$confirm" != "J" ]]; then
        echo "Abbruch durch Benutzer."
        return 1
    fi
    
    # Lösche Zertifikat
    certbot delete --cert-name "$domain" --non-interactive
    
    if [ $? -eq 0 ]; then
        echo "SSL-Zertifikat für ${domain} wurde erfolgreich gelöscht!"
        
        # Prüfe ob HTTP vHost noch existiert
        if [ -f "/etc/apache2/sites-available/${domain}.conf" ]; then
            echo "HTTP Virtual Host existiert noch. Apache wird neu geladen..."
            systemctl reload apache2
        fi
    else
        echo "Fehler beim Löschen des SSL-Zertifikats!"
        return 1
    fi
}

# Datenbank und User erstellen
create_db() {
    local db_name=$1
    local db_user=$2
    local db_pass=$3
    
    # Sicherheitscheck für Datenbankname und User
    if [[ ! "${db_name}" =~ ^[a-zA-Z0-9_]+$ ]]; then
        echo "Ungültiger Datenbankname!"
        return 1
    fi
    
    # MariaDB-Befehle
    mysql -e "CREATE DATABASE IF NOT EXISTS ${db_name};"
    mysql -e "CREATE USER IF NOT EXISTS '${db_user}'@'localhost' IDENTIFIED BY '${db_pass}';"
    mysql -e "GRANT ALL PRIVILEGES ON ${db_name}.* TO '${db_user}'@'localhost';"
    mysql -e "FLUSH PRIVILEGES;"
}

# Funktion zum Löschen einer Datenbank und des zugehörigen Users
delete_db() {
    local db_name=$1
    local db_user=$2
    
    echo "ACHTUNG: Folgende Aktionen werden durchgeführt:"
    echo "1. Löschen der Datenbank: ${db_name}"
    echo "2. Löschen des Datenbank-Users: ${db_user}"
    
    read -p "Möchtest du fortfahren? (j/N): " confirm
    if [[ "$confirm" != "j" && "$confirm" != "J" ]]; then
        echo "Abbruch durch Benutzer."
        return 1
    fi
    
    # Prüfe ob Datenbank existiert
    if ! mysql -e "SHOW DATABASES LIKE '${db_name}'" | grep -q "${db_name}"; then
        echo "Fehler: Datenbank ${db_name} existiert nicht!"
        return 1
    fi
    
    # Lösche Datenbank und User
    mysql -e "DROP DATABASE IF EXISTS ${db_name};"
    mysql -e "DROP USER IF EXISTS '${db_user}'@'localhost';"
    mysql -e "FLUSH PRIVILEGES;"
    
    echo "Datenbank ${db_name} und User ${db_user} wurden erfolgreich gelöscht!"
}

# Liste alle Virtual Hosts
list_vhosts() {
    echo "=== Verfügbare Virtual Hosts ==="
    echo "Aktive vHosts:"
    ls -l /etc/apache2/sites-enabled/ | grep -v '^total' | awk '{print "- " $9}'
    echo -e "\nAlle konfigurierten vHosts:"
    ls -l /etc/apache2/sites-available/ | grep -v '^total' | awk '{print "- " $9}'
}

# Liste alle Datenbanken und User
list_databases() {
    echo "=== Verfügbare Datenbanken ==="
    mysql -e "SHOW DATABASES;" | grep -v "Database\|information_schema\|performance_schema\|mysql\|sys"
    
    echo -e "\n=== Datenbank-User ==="
    mysql -e "SELECT user, host FROM mysql.user WHERE user NOT IN ('root', 'debian-sys-maint', 'mysql.sys', 'mysql.session');"
}

# Hauptskript mit Menü
main_menu() {
    local running=true
    
    while $running; do
        echo "=== Server Management Tool ==="
        echo "1. Virtual Host erstellen"
        echo "2. Virtual Host löschen"
        echo "3. Virtual Hosts anzeigen"
        echo "4. PHP Version für vHost ändern"
        echo "5. SSL-Zertifikat erstellen"
        echo "6. SSL-Zertifikat löschen"
        echo "7. SSL-Zertifikate anzeigen"
        echo "8. Datenbank & User erstellen"
        echo "9. Datenbank & User löschen"
        echo "10. Datenbanken & User anzeigen"
        echo "11. Beenden"
        
        read -p "Wähle eine Option (1-11): " choice
        
        case $choice in
            1)
                read -p "Domain: " domain
                read -p "Aliases (space-separated): " aliases
                read -p "PHP Version (z.B. 8.2): " php_version
                read -p "Custom DocumentRoot (leer lassen für /var/www/${domain}): " custom_docroot
                create_vhost "$domain" "$aliases" "$php_version" "$custom_docroot"
                ;;
            2)
                list_vhosts
                read -p "Domain zum Löschen: " domain
                delete_vhost "$domain"
                ;;
            3)
                list_vhosts
                ;;
            4)
                read -p "Domain: " domain
                read -p "Neue PHP Version (z.B. 8.2): " php_version
                change_php_version "$domain" "$php_version"
                ;;
            5)
                read -p "Domain: " domain
                setup_ssl "$domain"
                ;;
            6)
                certbot certificates
                read -p "Domain für SSL-Löschung: " domain
                delete_ssl "$domain"
                ;;
            7)
                echo "=== Installierte SSL-Zertifikate ==="
                certbot certificates
                ;;
            8)
                read -p "Datenbankname: " db_name
                read -p "Datenbank-User: " db_user
                read -p "Datenbank-Passwort: " db_pass
                create_db "$db_name" "$db_user" "$db_pass"
                ;;
            9)
                list_databases
                read -p "Datenbankname zum Löschen: " db_name
                read -p "Datenbank-User zum Löschen: " db_user
                delete_db "$db_name" "$db_user"
                ;;
            10)
                list_databases
                ;;
            11)
                echo "Beende Programm..."
                running=false
                break
                ;;
            *)
                echo "Ungültige Option!"
                ;;
        esac
        
        if [ "$choice" != "11" ]; then
            echo -e "\nDrücke Enter um fortzufahren..."
            read
        fi
    done
}

# Rootcheck und Hauptmenü starten
check_root
main_menu
exit 0