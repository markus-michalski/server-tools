#!/bin/bash

source /root/server-tools/common-functions.sh

# DocRoot-Funktion für Chroot-Setup
add_chroot_docroot() {
    local username=$1
    local domain=$2

    if [ -z "$username" ] || [ -z "$domain" ]; then
        echo "Fehler: Username und Domain müssen angegeben werden!"
        return 1
    fi

    # Prüfe ob es ein Chroot-User ist
    if [ ! -d "/var/www/jails/${username}" ]; then
        echo "Fehler: ${username} ist kein Chroot-User!"
        return 1
    fi

    local web_root="/var/www/${username}"
    local docroot="${web_root}/html/${domain}"

    echo "Erstelle DocRoot für ${domain}..."

    # Erstelle Domain-Verzeichnis
    mkdir -p "${docroot}"
    chown "${username}:www-data" "${docroot}"
    chmod 750 "${docroot}"

    # Der Link wird automatisch durch den existierenden /web Symlink aufgelöst
    echo "DocRoot Setup abgeschlossen"
    echo "Realer Pfad: ${docroot}"
    echo "Im Chroot sichtbar als: /web/html/${domain}"

    return 0
}

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
        return 1
    fi

    # Prüfe ob es ein Chroot-User ist
    local is_chroot=false
    if [ -d "/var/www/jails/${ssh_user}" ]; then
        is_chroot=true
        echo "Info: ${ssh_user} ist ein Chroot-User"

        # Prüfe Chroot-Struktur
        if ! verify_chroot_structure "$ssh_user"; then
            echo "Fehler: Chroot-Struktur ist beschädigt!"
            read -p "Soll versucht werden, die Struktur zu reparieren? (j/N): " repair
            if [[ "$repair" == "j" || "$repair" == "J" ]]; then
                repair_chroot_setup "$ssh_user"
            else
                return 1
            fi
        fi
    fi

    if [ "$is_chroot" = true ]; then
        # Für Chroot-User: DocRoot ist in der festgelegten Struktur
        docroot="/var/www/${ssh_user}/html/${domain}"
        if [ ! -z "$custom_docroot" ]; then
            echo "WARNUNG: Custom DocRoot wird für Chroot-User ignoriert"
        fi
    else
        # Für normale User: Standard oder Custom DocRoot
        if [ -z "$custom_docroot" ]; then
            docroot="/var/www/${domain}/html"
        else
            docroot="${custom_docroot}/html"
        fi
    fi

    echo "Erstelle Virtual Host für ${domain}..."
    echo "DocumentRoot: ${docroot}"
    echo "PHP Version: ${php_version}"
    echo "SSH-User: ${ssh_user}"

    # Erstelle DocRoot-Struktur
    if [ "$is_chroot" = true ]; then
        add_chroot_docroot "$ssh_user" "$domain"
    else
        mkdir -p "${docroot}"
        chown "${ssh_user}:www-data" "${docroot}"
        chmod 750 "${docroot}"

        # Setze ACLs für normale User
        setfacl -R -m u:${ssh_user}:rwx,g:www-data:rwx "${docroot}"
        setfacl -R -d -m u:${ssh_user}:rwx,g:www-data:rwx "${docroot}"
    fi

    # Willkommens-Seite erstellen
    cat > "${docroot}/index.html" <<EOF
<!DOCTYPE html>
<html lang="de">
<head>
    <meta charset="UTF-8">
    <title>Willkommen auf ${domain}</title>
    <style>
        body {
            font-family: Arial, sans-serif;
            margin: 40px auto;
            max-width: 800px;
            line-height: 1.6;
            padding: 0 20px;
        }
        pre {
            background: #f4f4f4;
            border: 1px solid #ddd;
            padding: 15px;
            border-radius: 4px;
        }
    </style>
</head>
<body>
    <h1>Willkommen auf ${domain}!</h1>
    <p>Die Erstellung des vHosts hat erfolgreich funktioniert!</p>

    <h2>Server-Informationen</h2>
    <ul>
        <li>PHP Version: ${php_version}</li>
        <li>User-Typ: $([ "$is_chroot" = true ] && echo "Chroot" || echo "Standard")</li>
        <li>Erstellt am: $(date +"%d.%m.%Y um %H:%M Uhr")</li>
    </ul>

    <h2>Verzeichnis-Informationen</h2>
    <pre>
DocumentRoot: ${docroot}
$([ "$is_chroot" = true ] && echo "Im Chroot sichtbar als: /web/html/${domain}" || echo "")
Berechtigungen: ${ssh_user}:www-data (750/640)
    </pre>
</body>
</html>
EOF

    # Setze Berechtigungen für index.html
    chown "${ssh_user}:www-data" "${docroot}/index.html"
    chmod 640 "${docroot}/index.html"

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

        # Verbesserte Sicherheit für Chroot-User
        $([ "$is_chroot" = true ] && echo "php_admin_value open_basedir ${docroot}:/tmp")
    </Directory>

    <FilesMatch \.php$>
        SetHandler "proxy:unix:/run/php/php${php_version}-fpm.sock|fcgi://localhost"
    </FilesMatch>

    # Security Headers
    Header always set X-Content-Type-Options "nosniff"
    Header always set X-Frame-Options "SAMEORIGIN"
    Header always set X-XSS-Protection "1; mode=block"
    Header always set Referrer-Policy "strict-origin-when-cross-origin"
    Header always set Permissions-Policy "geolocation=(),midi=(),sync-xhr=(),microphone=(),camera=(),magnetometer=(),gyroscope=(),fullscreen=(self),payment=()"

    # Content Security Policy
    Header always set Content-Security-Policy "default-src 'self'; script-src 'self' 'unsafe-inline' 'unsafe-eval'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self'; frame-ancestors 'none'; form-action 'self'"

    # Logging
    ErrorLog \${APACHE_LOG_DIR}/${domain}_error.log
    CustomLog \${APACHE_LOG_DIR}/${domain}_access.log combined

    # PHP-FPM Status (nur lokal erreichbar)
    <Location /fpm-status>
        Require local
        SetHandler "proxy:unix:/run/php/php${php_version}-fpm.sock|fcgi://localhost"
    </Location>
</VirtualHost>
EOF

    # Aktiviere vHost und Apache Module
    a2enmod headers
    a2ensite "${domain}.conf"
    systemctl reload apache2

    echo "Virtual Host für ${domain} wurde erfolgreich erstellt!"
    if [ "$is_chroot" = true ]; then
        echo "Chroot-User Setup:"
        echo "- Echtes Verzeichnis: ${docroot}"
        echo "- Im Chroot sichtbar als: /web/html/${domain}"
    fi
    echo "Berechtigungen: ${ssh_user}:www-data (750/640)"

    # Zeige finale Berechtigungen
    echo -e "\nAktuelle Berechtigungen für ${docroot}:"
    ls -ld "${docroot}"
    ls -la "${docroot}/"

    if [ "$is_chroot" = true ]; then
        echo -e "\nZugriff im Chroot:"
        ls -la "/var/www/jails/${ssh_user}/web/html/${domain}/"
    fi
}

# Virtual Host löschen
delete_vhost() {
    local domain=$1
    local docroot
    local parent_dir

    if [ ! -f "/etc/apache2/sites-available/${domain}.conf" ]; then
        echo "Fehler: Virtual Host für ${domain} existiert nicht!"
        return 1
    fi

    # DocRoot sauberer aus der Konfiguration extrahieren
    docroot=$(grep -i "DocumentRoot" "/etc/apache2/sites-available/${domain}.conf" |
              head -n1 |
              sed 's/^[[:space:]]*DocumentRoot[[:space:]]*//i' |
              sed 's/[[:space:]]*$//g' |
              sed 's/^"//;s/"$//' |
              sed "s/^'//;s/'$//")

    # Validiere den extrahierten Pfad
    if [ -z "$docroot" ] || [ "$docroot" = "/" ]; then
        echo "Fehler: Ungültiger DocumentRoot gefunden!"
        return 1
    fi

    echo "ACHTUNG: Virtual Host wird gelöscht!"
    echo "Domain: ${domain}"
    echo "DocumentRoot: ${docroot}"
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

    # DocRoot löschen wenn vorhanden
    if [ ! -z "$docroot" ] && [ -d "$docroot" ]; then
        read -p "DocumentRoot ($docroot) auch löschen? (j/N): " confirm_docroot
        if [[ "$confirm_docroot" == "j" || "$confirm_docroot" == "J" ]]; then
            if rm -rf "$docroot"; then
                echo "DocumentRoot wurde erfolgreich gelöscht."

                # Versuche das übergeordnete Verzeichnis zu löschen, falls es leer ist
                parent_dir=$(dirname "$docroot")
                if [ "$parent_dir" != "/" ] && [ "$parent_dir" != "/var/www" ]; then
                    if rmdir --ignore-fail-on-non-empty "$parent_dir" 2>/dev/null; then
                        echo "Übergeordnetes Verzeichnis wurde auch gelöscht, da es leer war."
                    fi
                fi
            else
                echo "Fehler: Konnte DocumentRoot nicht löschen. Überprüfe die Berechtigungen."
                return 1
            fi
        fi
    fi

    systemctl reload apache2
    echo "Virtual Host ${domain} wurde erfolgreich gelöscht!"
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
    local config_file="/etc/apache2/sites-available/${domain}.conf"

    if [ ! -f "$config_file" ]; then
        echo "Fehler: Virtual Host ${domain} existiert nicht!"
        return 1
    fi

    # Extrahiere DocumentRoot und User aus der Apache-Konfiguration
    local docroot=$(grep -i "DocumentRoot" "$config_file" | head -n1 | awk '{print $2}')
    local user=$(stat -c '%U' "$docroot" 2>/dev/null)

    # Prüfe ob PHP-Version installiert ist
    if [ ! -S "/run/php/php${php_version}-fpm.sock" ]; then
        echo "Fehler: PHP ${php_version} ist nicht installiert oder FPM nicht aktiv!"
        return 1
    fi

    # Prüfe ob es ein Chroot-User ist
    local is_chroot=false
    if [ -d "/var/www/jails/${user}" ]; then
        is_chroot=true
        echo "Info: Erkenne Chroot-User ${user}"
    fi

    # Apache Konfiguration aktualisieren
    sed -i "s|proxy:unix:/run/php/php.*-fpm.sock|proxy:unix:/run/php/php${php_version}-fpm.sock|g" "$config_file"

    # Wenn es ein Chroot-User ist, aktualisiere die PHP-Umgebung im Chroot
    if [ "$is_chroot" = true ]; then
        echo "Aktualisiere PHP-Umgebung im Chroot..."
        local jail_root="/var/www/jails/${user}"

        # PHP-Binaries und Extensions kopieren
        echo "1/3 Kopiere PHP-Binaries..."
        cp "/usr/bin/php${php_version}" "${jail_root}/usr/bin/" 2>/dev/null || true
        ln -sf "/usr/bin/php${php_version}" "${jail_root}/usr/bin/php" 2>/dev/null || true

        echo "2/3 Kopiere PHP-Extensions..."
        # Erstelle Verzeichnisse falls sie nicht existieren
        mkdir -p "${jail_root}/usr/lib/php/${php_version}"
        cp -r "/usr/lib/php/${php_version}"/* "${jail_root}/usr/lib/php/${php_version}/" 2>/dev/null || true

        echo "3/3 Aktualisiere Composer..."
        if [ -f "${jail_root}/usr/local/bin/composer" ]; then
            # Composer im Chroot aktualisieren
            chroot "${jail_root}" /usr/local/bin/composer self-update
        fi

        echo "PHP-Umgebung im Chroot wurde aktualisiert!"
    fi

    systemctl reload apache2
    echo "PHP Version für ${domain} wurde auf ${php_version} geändert!"

    if [ "$is_chroot" = true ]; then
        echo
        echo "HINWEIS: Für Chroot-User wurde auch die PHP-Umgebung aktualisiert."
        echo "Neue PHP-Version ist jetzt im Chroot verfügbar."
    fi
}

# DocumentRoot eines vHosts ändern
change_docroot() {
    local domain=$1
    local new_docroot=$2
    local ssh_user=$3
    local old_docroot
    local ssl_conf="${domain}-le-ssl.conf"

    if [ ! -f "/etc/apache2/sites-available/${domain}.conf" ]; then
        echo "Fehler: Virtual Host für ${domain} existiert nicht!"
        return 1
    fi

    old_docroot=$(grep -i "DocumentRoot" "/etc/apache2/sites-available/${domain}.conf" | head -n1 | awk '{print $2}')
    old_docroot=$(realpath -m "$old_docroot")
    new_docroot=$(realpath -m "$new_docroot")

    # Prüfe ob der neue Pfad ein Unterordner des alten ist
    if [[ "$new_docroot" == "$old_docroot"/* ]]; then
        echo "WARNUNG: Der neue DocRoot ist ein Unterverzeichnis des alten DocRoot."
        echo "Das Kopieren der Dateien wird übersprungen, um Rekursion zu vermeiden."
    else
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

        # Frage nach Kopieren nur wenn es sich nicht um ein Unterverzeichnis handelt
        if [ -d "$old_docroot" ] && [ "$(ls -A $old_docroot)" ]; then
            read -p "Sollen die Dateien vom alten DocumentRoot kopiert werden? (j/N): " copy_files
            if [[ "$copy_files" == "j" || "$copy_files" == "J" ]]; then
                cp -r "${old_docroot}/." "${new_docroot}/"
                echo "Dateien wurden kopiert."
            fi
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

    # Apache Konfigurationen aktualisieren
    sed -i "s|DocumentRoot ${old_docroot}|DocumentRoot ${new_docroot}|g" \
        "/etc/apache2/sites-available/${domain}.conf"
    sed -i "s|<Directory ${old_docroot}|<Directory ${new_docroot}|g" \
        "/etc/apache2/sites-available/${domain}.conf"

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
                echo "Verfügbare SSH-User:"
                echo "Standard-User:"
                # Zeige nur nicht-Chroot User
                awk -F: '$7 ~ /\/bin\/bash/ && $6 !~ /\/var\/www\/jails/ {print "- " $1}' /etc/passwd

                echo -e "\nChroot-User:"
                # Zeige nur existierende Chroot-User
                if [ -d "/var/www/jails" ]; then
                    find "/var/www/jails" -maxdepth 1 -mindepth 1 -type d -exec basename {} \; | while read user; do
                        if id "$user" &>/dev/null; then
                            echo "- $user (chroot)"
                        fi
                    done
                fi

                read -p "SSH-User: " ssh_user
                if ! id "$ssh_user" >/dev/null 2>&1; then
                    echo "Fehler: SSH-User existiert nicht! Bitte zuerst SSH-User anlegen."
                    continue
                fi

                read -p "Domain: " domain
                read -p "Aliases (space-separated): " aliases
                read -p "PHP Version (z.B. 8.2): " php_version

                if [ ! -d "/var/www/jails/${ssh_user}" ]; then
                    read -p "Custom DocumentRoot (leer für Standard): " custom_docroot
                else
                    echo "Info: Custom DocumentRoot wird für Chroot-User ignoriert"
                    custom_docroot=""
                fi

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
                list_vhosts
                echo
                read -p "Domain: " domain
                if [ ! -f "/etc/apache2/sites-available/${domain}.conf" ]; then
                    echo "Fehler: Domain existiert nicht!"
                    continue
                fi

                echo "Verfügbare PHP Versionen:"
                for version in /usr/bin/php[0-9]*; do
                    if [ -f "$version" ]; then
                        ver=$(basename "$version" | sed 's/php//')
                        if [ -S "/run/php/php${ver}-fpm.sock" ]; then
                            echo "- PHP $ver"
                        fi
                    fi
                done
                echo
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