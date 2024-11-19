#!/bin/bash

source /root/server-tools/common-functions.sh

# Virtual Host erstellen
create_vhost() {
    local domain=$1
    local aliases=$2
    local php_version=$3
    local custom_docroot=$4
    local ssh_user=$5
    local docroot

    # Prüfe ob SSH-User existiert
    if ! id "$ssh_user" >/dev/null 2>&1; then
        echo "Fehler: SSH-User $ssh_user existiert nicht!"
        echo "Bitte zuerst SSH-User anlegen mit create_ssh_user"
        return 1
    fi

    # Prüfe ACL Installation
    if ! check_acl; then
        echo "FEHLER: ACL-Setup fehlgeschlagen."
        return 1
    fi

    if [ -z "$custom_docroot" ]; then
        docroot="/var/www/${domain}/html"
    else
        docroot="${custom_docroot}/html"
    fi

    echo "Erstelle Virtual Host für ${domain}..."
    echo "DocumentRoot: ${docroot}"
    echo "SSH-User: ${ssh_user}"

    # Erstelle übergeordnetes Verzeichnis und setze Berechtigungen
    parent_dir=$(dirname "$docroot")
    mkdir -p "$parent_dir"
    chown "${ssh_user}:www-data" "$parent_dir"
    chmod 775 "$parent_dir"
    setfacl -m u:${ssh_user}:rwx,g:www-data:rwx "$parent_dir"
    setfacl -d -m u:${ssh_user}:rwx,g:www-data:rwx "$parent_dir"

    # Erstelle DocRoot
    mkdir -p "${docroot}"

    # Willkommens-Seite erstellen
    cat > "${docroot}/index.html" <<EOF
<!DOCTYPE html>
<html lang="de">
<head>
    <meta charset="UTF-8">
    <title>Willkommen auf ${domain}</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 40px auto; max-width: 800px; }
    </style>
</head>
<body>
    <h1>Willkommen auf ${domain}!</h1>
    <p>Die Erstellung des vHosts hat erfolgreich funktioniert!</p>
    <p>PHP Version: ${php_version}</p>
    <p>Erstellt am: $(date +"%d.%m.%Y um %H:%M Uhr")</p>
</body>
</html>
EOF

    # Setze Basis-Besitzer und Berechtigungen für DocRoot
    chown "${ssh_user}:www-data" "${docroot}"
    chmod 775 "${docroot}"

    # ACL für bestehende Dateien im DocRoot
    setfacl -R -m u:${ssh_user}:rwx,g:www-data:rwx "${docroot}"
    # Default-ACL für neue Dateien im DocRoot
    setfacl -R -d -m u:${ssh_user}:rwx,g:www-data:rwx "${docroot}"

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

    # Security Headers
    Header always set X-Content-Type-Options "nosniff"
    Header always set X-Frame-Options "SAMEORIGIN"
    Header always set X-XSS-Protection "1; mode=block"
    Header always set Referrer-Policy "strict-origin-when-cross-origin"

    # Logging
    ErrorLog \${APACHE_LOG_DIR}/${domain}_error.log
    CustomLog \${APACHE_LOG_DIR}/${domain}_access.log combined

    # Optional: PHP-FPM Status
    <Location /fpm-status>
        Require local
        SetHandler "proxy:unix:/run/php/php${php_version}-fpm.sock|fcgi://localhost"
    </Location>
</VirtualHost>
EOF

    a2ensite "${domain}.conf"
    systemctl reload apache2

    echo "Virtual Host für ${domain} wurde erfolgreich erstellt!"
    echo "Berechtigungen: ${ssh_user}:www-data (775/664) mit ACL"

    # Zeige finale Berechtigungen
    echo -e "\nAktuelle Berechtigungen für ${parent_dir}:"
    ls -la "${parent_dir}"
    getfacl "${parent_dir}"

    echo -e "\nAktuelle Berechtigungen für ${docroot}:"
    ls -la "${docroot}"
    getfacl "${docroot}"
}

# Virtual Host löschen
delete_vhost() {
    local domain=$1
    local docroot

    if [ ! -f "/etc/apache2/sites-available/${domain}.conf" ]; then
        echo "Fehler: Virtual Host für ${domain} existiert nicht!"
        return 1
    fi

    # DocRoot aus der Konfiguration extrahieren
    docroot=$(grep -i "DocumentRoot" "/etc/apache2/sites-available/${domain}.conf" | head -n1 | awk '{print $2}')

    echo "ACHTUNG: Virtual Host wird gelöscht!"
    read -p "Fortfahren? (j/N): " confirm
    if [[ "$confirm" != "j" && "$confirm" != "J" ]]; then
        echo "Abbruch."
        return 1
    fi

    # Deaktiviere und lösche Konfigurationen
    a2dissite "${domain}.conf"
    a2dissite "${domain}-le-ssl.conf" 2>/dev/null || true
    rm -f "/etc/apache2/sites-available/${domain}.conf"
    rm -f "/etc/apache2/sites-available/${domain}-le-ssl.conf"

    # Optional: DocRoot löschen
    if [ ! -z "$docroot" ] && [ -d "$docroot" ]; then
        read -p "DocumentRoot ($docroot) auch löschen? (j/N): " confirm_docroot
        if [[ "$confirm_docroot" == "j" || "$confirm_docroot" == "J" ]]; then
            rm -rf "$docroot" && echo "DocumentRoot wurde gelöscht."
            rmdir --ignore-fail-on-non-empty "$(dirname "$docroot")" 2>/dev/null
        fi
    fi

    systemctl reload apache2
    echo "Virtual Host ${domain} wurde gelöscht!"
}

# Virtual Hosts auflisten
list_vhosts() {
    echo "=== Virtual Hosts ==="
    echo "Aktive vHosts:"
    ls -l /etc/apache2/sites-enabled/ | grep -v '^total' | awk '{print "- " $9}'
    echo -e "\nAlle konfigurierten vHosts:"
    ls -l /etc/apache2/sites-available/ | grep -v '^total' | awk '{print "- " $9}'
}

# PHP Version eines vHosts ändern
change_php_version() {
    local domain=$1
    local php_version=$2

    if [ ! -f "/etc/apache2/sites-available/${domain}.conf" ]; then
        echo "Fehler: Virtual Host ${domain} existiert nicht!"
        return 1
    fi

    # Prüfe ob PHP-Version installiert ist
    if [ ! -S "/run/php/php${php_version}-fpm.sock" ]; then
        echo "Fehler: PHP ${php_version} ist nicht installiert oder FPM nicht aktiv!"
        return 1
    fi

    sed -i "s|proxy:unix:/run/php/php.*-fpm.sock|proxy:unix:/run/php/php${php_version}-fpm.sock|g" \
        "/etc/apache2/sites-available/${domain}.conf"

    systemctl reload apache2
    echo "PHP Version für ${domain} wurde auf ${php_version} geändert!"
}

# DocumentRoot eines vHosts ändern
change_docroot() {
    local domain=$1
    local new_docroot=$2
    local ssh_user=$3  # Optional: SSH User für neue Berechtigungen
    local old_docroot
    local ssl_conf="${domain}-le-ssl.conf"

    if [ ! -f "/etc/apache2/sites-available/${domain}.conf" ]; then
        echo "Fehler: Virtual Host für ${domain} existiert nicht!"
        return 1
    fi

    old_docroot=$(grep -i "DocumentRoot" "/etc/apache2/sites-available/${domain}.conf" | head -n1 | awk '{print $2}')

    # Prüfe ob neuer DocumentRoot existiert
    if [ ! -d "${new_docroot}" ]; then
        read -p "Der DocumentRoot ${new_docroot} existiert nicht. Soll er erstellt werden? (j/N): " create_dir
        if [[ "$create_dir" == "j" || "$create_dir" == "J" ]]; then
            mkdir -p "${new_docroot}"
        else
            echo "Abbruch: Neuer DocumentRoot wurde nicht erstellt."
            return 1
        fi
    fi

    # Dateien vom alten in den neuen DocumentRoot kopieren
    if [ -d "$old_docroot" ] && [ "$(ls -A $old_docroot)" ]; then
        read -p "Sollen die Dateien vom alten DocumentRoot kopiert werden? (j/N): " copy_files
        if [[ "$copy_files" == "j" || "$copy_files" == "J" ]]; then
            cp -r "${old_docroot}/." "${new_docroot}/"
        fi
    fi

    # Berechtigungen setzen
    if [ ! -z "$ssh_user" ]; then
        chown -R "${ssh_user}:www-data" "${new_docroot}"
    else
        chown -R www-data:www-data "${new_docroot}"
    fi
    find "${new_docroot}" -type d -exec chmod 775 {} \;
    find "${new_docroot}" -type f -exec chmod 664 {} \;

    # HTTP vHost Konfiguration aktualisieren
    sed -i "s|DocumentRoot ${old_docroot}|DocumentRoot ${new_docroot}|g" \
        "/etc/apache2/sites-available/${domain}.conf"
    sed -i "s|<Directory ${old_docroot}|<Directory ${new_docroot}|g" \
        "/etc/apache2/sites-available/${domain}.conf"

    # HTTPS/SSL vHost Konfiguration aktualisieren wenn vorhanden
    if [ -f "/etc/apache2/sites-available/${ssl_conf}" ]; then
        sed -i "s|DocumentRoot ${old_docroot}|DocumentRoot ${new_docroot}|g" \
            "/etc/apache2/sites-available/${ssl_conf}"
        sed -i "s|<Directory ${old_docroot}|<Directory ${new_docroot}|g" \
            "/etc/apache2/sites-available/${ssl_conf}"
    fi

    systemctl reload apache2
    echo "DocumentRoot für ${domain} wurde auf ${new_docroot} geändert!"
    echo "Neue Berechtigungen wurden gesetzt."
}

# Menü für Virtual Host Management
vhost_menu() {
    local submenu=true

    while $submenu; do
        echo "=== Virtual Host Management ==="
        echo "1. Virtual Host erstellen (SSH-User erforderlich)"
        echo "2. Virtual Host löschen"
        echo "3. Virtual Hosts anzeigen"
        echo "4. PHP Version ändern"
        echo "5. DocumentRoot ändern"
        echo "6. Zurück zum Hauptmenü"

        read -p "Wähle eine Option (1-6): " choice

        case $choice in
            1)
                # Zeige verfügbare SSH-User
                echo "Verfügbare SSH-User:"
                awk -F: '$7 ~ /\/bin\/bash/ || $7 ~ /\/bin\/rbash/ {print "- " $1}' /etc/passwd

                read -p "SSH-User: " ssh_user
                if ! id "$ssh_user" >/dev/null 2>&1; then
                    echo "Fehler: SSH-User existiert nicht! Bitte zuerst SSH-User anlegen."
                    continue
                fi

                read -p "Domain: " domain
                read -p "Aliases (space-separated): " aliases
                read -p "PHP Version (z.B. 8.2): " php_version
                read -p "Custom DocumentRoot (leer für Standard): " custom_docroot
                create_vhost "$domain" "$aliases" "$php_version" "$custom_docroot" "$ssh_user"
                ;;
            2)
                list_vhosts
                read -p "Domain zum Löschen (oder 'q' für zurück): " domain
                [ "$domain" = "q" ] && continue
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
                read -p "Neuer DocumentRoot: " new_docroot
                echo "Verfügbare SSH-User:"
                awk -F: '$7 ~ /\/bin\/bash/ || $7 ~ /\/bin\/rbash/ {print "- " $1}' /etc/passwd
                read -p "SSH-User für neue Berechtigungen (oder Enter für www-data): " ssh_user
                change_docroot "$domain" "$new_docroot" "$ssh_user"
                ;;
            6)
                submenu=false
                ;;
            *)
                echo "Ungültige Option!"
                ;;
        esac

        if [ "$choice" != "6" ]; then
            read -p "Enter drücken zum Fortfahren..."
            clear
        fi
    done
}