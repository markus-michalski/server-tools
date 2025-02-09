#!/bin/bash

# Gemeinsame Funktionen laden
source /root/server-tools/common-functions.sh

# DocRoot Funktionen
add_docroot() {
    local username=$1
    local docroot=$2
    local is_developer=$3

    if [ -z "$username" ] || [ -z "$docroot" ]; then
        echo "Fehler: Username und DocRoot müssen angegeben werden!"
        return 1
    fi

    # Prüfe und installiere ACL wenn nötig
    if ! check_acl; then
        echo "FEHLER: ACL-Setup fehlgeschlagen."
        return 1
    fi

    # Normalisiere den Pfad
    docroot=$(echo "$docroot" | sed 's#/\+#/#g' | sed 's#/$##')

    echo "Erstelle/Aktualisiere DocRoot: $docroot"

    # Erstelle DocRoot falls nicht vorhanden
    if [ ! -d "$docroot" ]; then
        mkdir -p "$docroot"
    fi

    echo "Setze ACL-Berechtigungen..."

    # Setze Basis-Besitzer
    chown "${username}:www-data" "$docroot"
    chmod 775 "$docroot"

    # Setze ACL für bestehende Dateien
    setfacl -R -m u:${username}:rwx,g:www-data:rwx "$docroot"
    # Setze Default-ACL für neue Dateien
    setfacl -R -d -m u:${username}:rwx,g:www-data:rwx "$docroot"

    # Erstelle symbolischen Link
    local link_name=$(basename "$docroot")
    local count=0
    local final_link_name="${link_name}"

    while [ -L "/home/$username/www-${final_link_name}" ]; do
        count=$((count + 1))
        final_link_name="${link_name}-${count}"
    done

    ln -s "$docroot" "/home/$username/www-${final_link_name}"

    echo "DocRoot Setup abgeschlossen"
    return 0
}

repair_acl_permissions() {
    local docroot=$1
    local username=$2

    if [ -z "$docroot" ] || [ -z "$username" ]; then
        echo "Fehler: DocRoot und Username müssen angegeben werden!"
        return 1
    fi

    if [ ! -d "$docroot" ]; then
        echo "Fehler: DocRoot existiert nicht!"
        return 1
    fi

    if ! check_acl; then
        echo "FEHLER: ACL-Setup fehlgeschlagen."
        return 1
    fi

    echo "Repariere ACL-Berechtigungen für $docroot..."

    # Setze ACL für bestehende Dateien
    setfacl -R -m u:${username}:rwx,g:www-data:rwx "$docroot"
    # Setze Default-ACL für neue Dateien
    setfacl -R -d -m u:${username}:rwx,g:www-data:rwx "$docroot"

    echo "ACL-Berechtigungen repariert!"
    getfacl "$docroot"
}

repair_docroot_permissions() {
    local username=$1
    local is_developer=$2

    if [ -z "$username" ]; then
        echo "Fehler: Kein Username angegeben!"
        return 1
    fi

    echo "Repariere DocRoot-Berechtigungen für User ${username}..."

    # Prüfe ob es ein Chroot-User ist
    if [ -d "/var/www/jails/${username}" ]; then
        local docroot="/var/www/${username}"
        chown -R "${username}:www-data" "$docroot"
        chmod 750 "$docroot"
        return 0
    fi

    # Für Standard/Entwickler-User
    for link in /home/${username}/www-*; do
        if [ -L "$link" ]; then
            local docroot=$(readlink -f "$link")
            if [ -d "$docroot" ]; then
                echo "Verarbeite: $docroot"

                echo "1/3 Setze Basis-Berechtigungen..."
                chown www-data:www-data "$docroot"
                chmod 775 "$docroot"
                chmod g+s "$docroot"

                echo "2/3 Verarbeite Verzeichnisse..."
                find "$docroot" -type d -print0 | while IFS= read -r -d $'\0' dir; do
                    echo -ne "   Verarbeite: $dir\r"
                    chown www-data:www-data "$dir"
                    chmod 775 "$dir"
                done
                echo

                echo "3/3 Verarbeite Dateien..."
                find "$docroot" -type f -print0 | while IFS= read -r -d $'\0' file; do
                    echo -ne "   Verarbeite: $file\r"
                    chown www-data:www-data "$file"
                    chmod 664 "$file"
                done
                echo

                echo "DocRoot $docroot wurde verarbeitet"
                echo "----------------------------------------"
            fi
        fi
    done

    echo "DocRoot-Berechtigungen wurden aktualisiert!"
}

# Chroot User Funktionen
create_secure_chroot_user() {
    local username=$1
    local password=$2
    local web_root=${3:-"/var/www/${username}"}

    echo "Erstelle Chroot-User: $username"

    # Basis-Verzeichnisstruktur
    local jail_root="/var/www/jails/${username}"

    # 1. Erstelle Web-Verzeichnisstruktur
    echo "1/5 Erstelle Web-Verzeichnisstruktur..."
    mkdir -p "${web_root}"
    mkdir -p "${web_root}/html"
    mkdir -p "${web_root}/logs"
    mkdir -p "${web_root}/tmp"

    # 2. Erstelle Jail-Verzeichnis
    echo "2/5 Erstelle Jail-Verzeichnis..."
    mkdir -p "${jail_root}"

    # 3. Erstelle User mit Bash als Shell
    echo "3/5 Erstelle User..."
    useradd -d "${jail_root}" \
            -g www-data \
            -s /bin/bash \
            "${username}"

    # Setze Passwort
    echo "${username}:${password}" | chpasswd

    # 4. Erstelle notwendige Verzeichnisse für Shell-Zugriff
    echo "4/5 Erstelle Shell-Umgebung..."

    # Erstelle grundlegende Verzeichnisstruktur
    mkdir -p "${jail_root}"/{dev,etc,bin,lib,lib64,usr/bin,usr/lib}
    mkdir -p "${jail_root}/dev/pts"
    mkdir -p "${jail_root}/dev/shm"
    mkdir -p "${jail_root}/var/www/${username}"

    # Füge Mount-Einträge zu fstab hinzu wenn nicht vorhanden
    local fstab_modified=0

    if ! grep -q "${jail_root}/dev/pts" /etc/fstab; then
        echo "devpts ${jail_root}/dev/pts devpts gid=5,mode=620 0 0" >> /etc/fstab
        fstab_modified=1
    fi

    if ! grep -q "${jail_root}/dev/shm" /etc/fstab; then
        echo "tmpfs ${jail_root}/dev/shm tmpfs defaults 0 0" >> /etc/fstab
        fstab_modified=1
    fi

    if ! grep -q "${web_root} ${jail_root}/var/www/${username}" /etc/fstab; then
        echo "${web_root} ${jail_root}/var/www/${username} none bind 0 0" >> /etc/fstab
        fstab_modified=1
    fi

    # Lade systemd neu, wenn fstab geändert wurde
    if [ $fstab_modified -eq 1 ]; then
        systemctl daemon-reload
    fi

    # Mounte die Verzeichnisse
    mount -t devpts devpts "${jail_root}/dev/pts" -o gid=5,mode=620
    mount -t tmpfs tmpfs "${jail_root}/dev/shm"
    mount --bind "${web_root}" "${jail_root}/var/www/${username}"

    # Erstelle /dev/null und /dev/urandom wenn nicht vorhanden
    if [ ! -e "${jail_root}/dev/null" ]; then
        mknod "${jail_root}/dev/null" c 1 3
        chmod 666 "${jail_root}/dev/null"
    fi
    if [ ! -e "${jail_root}/dev/urandom" ]; then
        mknod "${jail_root}/dev/urandom" c 1 9
        chmod 666 "${jail_root}/dev/urandom"
    fi

    # Kopiere grundlegende Befehle
    BASIC_COMMANDS=(
        "/bin/bash"
        "/bin/ls"
        "/bin/cp"
        "/bin/mv"
        "/bin/rm"
        "/bin/mkdir"
        "/bin/rmdir"
        "/bin/chmod"
        "/bin/chown"
        "/bin/cat"
        "/bin/grep"
        "/bin/pwd"
        "/usr/bin/id"
        "/usr/bin/whoami"
        "/usr/bin/groups"
        "/usr/bin/touch"
    )

    for cmd in "${BASIC_COMMANDS[@]}"; do
        if [ -f "$cmd" ]; then
            cp "$cmd" "${jail_root}${cmd}"
            # Kopiere abhängige Bibliotheken
            ldd "$cmd" | grep -o '/lib.*\.so[^ ]*' | while read lib; do
                mkdir -p "${jail_root}/$(dirname "$lib")"
                cp "$lib" "${jail_root}$lib"
            done
        fi
    done

    # 5. Erstelle Verzeichnisstruktur und setze Berechtigungen
    echo "5/5 Setze finale Struktur und Berechtigungen..."

    # Berechtigungen für Web-Verzeichnis
    chown -R "${username}:www-data" "${web_root}"
    find "${web_root}" -type d -exec chmod 750 {} \;
    find "${web_root}" -type f -exec chmod 640 {} \;

    # Erstelle relativen Symlink
    ln -sfn "var/www/${username}" "${jail_root}/web"
    chown -h "${username}:www-data" "${jail_root}/web"

    # SSH Setup
    mkdir -p "${jail_root}/.ssh"
    chmod 700 "${jail_root}/.ssh"
    touch "${jail_root}/.ssh/authorized_keys"
    chmod 600 "${jail_root}/.ssh/authorized_keys"
    chown -R "${username}:www-data" "${jail_root}/.ssh"

    # SSH Konfiguration
    local ssh_config="/etc/ssh/sshd_config"

    # Prüfe und setze globale Subsystem-Konfiguration
    if ! grep -q "^Subsystem.*sftp.*internal-sftp" "$ssh_config"; then
        # Entferne alte sftp Subsystem-Konfiguration falls vorhanden
        sed -i '/^Subsystem.*sftp/d' "$ssh_config"
        # Füge neue Konfiguration hinzu
        sed -i '1iSubsystem sftp internal-sftp' "$ssh_config"
    fi

    # Entferne existierende Match-Block-Konfiguration für diesen User falls vorhanden
    sed -i "/Match User ${username}/,+10d" "$ssh_config"

    # Füge neue User-spezifische Konfiguration hinzu
    cat >> "$ssh_config" << EOF

# Secure Chroot Config für ${username}
Match User ${username}
    ChrootDirectory ${jail_root}
    X11Forwarding no
    AllowTcpForwarding no
    PermitTunnel no
    AllowAgentForwarding no
EOF

    # Teste SSH-Konfiguration
    if ! sshd -t; then
        echo "Fehler: SSH-Konfiguration ist ungültig!"
        # Stelle Backup wieder her falls vorhanden
        if [ -f "${ssh_config}.bak" ]; then
            mv "${ssh_config}.bak" "$ssh_config"
            systemctl restart sshd
        fi
        return 1
    fi

    # Starte SSH neu
    systemctl restart sshd

    # .bashrc im Jail
    cat > "${jail_root}/.bashrc" << EOF
export PS1='\u@\h:\w\$ '
export PATH=/usr/local/bin:/usr/bin:/bin
alias ll='ls -la'
cd /web
EOF

    # Finale Berechtigungen für Jail
    chown root:root "${jail_root}"
    chmod 755 "${jail_root}"

    echo "=== Chroot-User Setup abgeschlossen ==="
    echo "Web-Verzeichnis: ${web_root}"
    echo "Jail-Verzeichnis: ${jail_root}"
    echo "SSH-Zugriff: ssh -p 62954 ${username}@domain"
    echo "SFTP-Zugriff: sftp -P 62954 ${username}@domain"

    # Zeige Verzeichnisstruktur
    echo -e "\nVerzeichnisstruktur:"
    echo "Real:"
    tree -L 2 "${web_root}"
    echo -e "\nJail:"
    ls -la "${jail_root}/web"
}

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

delete_chroot_user() {
    local username=$1

    echo "Lösche Chroot-User: $username"

    # Pfade
    local web_root="/var/www/${username}"
    local jail_root="/var/www/jails/${username}"

    # Prüfe ob der User existiert
    if ! id "$username" &>/dev/null; then
        echo "Fehler: User ${username} existiert nicht!"
        return 1
    fi

    # Prüfe ob es ein Chroot-User ist
    if [ ! -d "$jail_root" ]; then
        echo "Fehler: ${username} ist kein Chroot-User!"
        return 1
    fi

    # Backup erstellen
    local backup_dir="/root/user_backups"
    mkdir -p "${backup_dir}"
    local timestamp=$(date +%Y%m%d_%H%M%S)

    echo "Erstelle Backup..."
    tar czf "${backup_dir}/${username}_backup_${timestamp}.tar.gz" "${web_root}" 2>/dev/null

    # Beende alle Prozesse des Users
    echo "Beende aktive Prozesse..."
    pkill -u "${username}" || true
    sleep 2

    # Unmounte alle Verzeichnisse
    echo "Unmounte Verzeichnisse..."

    # Unmount in spezifischer Reihenfolge
    local mount_points=(
        "${jail_root}/var/www/${username}"  # Web-Verzeichnis zuerst
        "${jail_root}/dev/pts"              # dann pts
        "${jail_root}/dev/shm"              # dann shm
    )

    for mount_point in "${mount_points[@]}"; do
        if mount | grep -q " $mount_point "; then
            echo "Unmounte $mount_point"
            umount -f "$mount_point" 2>/dev/null || umount -l "$mount_point" 2>/dev/null
            sleep 1
        fi
    done

    # Zusätzliche Sicherheit: Prüfe auf verbliebene Mounts
    local remaining_mounts=$(mount | grep "${jail_root}" | awk '{print $3}')
    if [ ! -z "$remaining_mounts" ]; then
        echo "Unmounte verbliebene Mountpoints..."
        echo "$remaining_mounts" | while read mount_point; do
            umount -f "$mount_point" 2>/dev/null || umount -l "$mount_point" 2>/dev/null
            sleep 1
        done
    fi

    # Entferne fstab Einträge
    echo "Entferne fstab Einträge..."
    sed -i "\#${jail_root}#d" /etc/fstab

    # Lade systemd neu nach fstab Änderungen
    systemctl daemon-reload

    # User entfernen
    echo "Lösche User..."
    userdel -f "${username}" 2>/dev/null
    sleep 1

    # Versuche mehrmals die Verzeichnisse zu löschen
    echo "Lösche Verzeichnisse..."
    local max_attempts=3
    local attempt=1

    while [ $attempt -le $max_attempts ]; do
        echo "Versuch $attempt von $max_attempts..."

        # Prüfe erst, ob noch Mounts existieren
        if mount | grep -q "${jail_root}"; then
            echo "Es existieren noch Mounts, versuche erneut zu unmounten..."
            mount | grep "${jail_root}" | awk '{print $3}' | while read mount_point; do
                umount -f "$mount_point" 2>/dev/null || umount -l "$mount_point" 2>/dev/null
            done
            sleep 2
        fi

        # Versuche zu löschen
        if rm -rf "${web_root}" "${jail_root}" 2>/dev/null; then
            echo "Verzeichnisse erfolgreich gelöscht!"
            break
        else
            echo "Löschen fehlgeschlagen, warte kurz..."
            sleep 3
            attempt=$((attempt + 1))
        fi
    done

    if [ $attempt -gt $max_attempts ]; then
        echo "WARNUNG: Konnte nicht alle Verzeichnisse löschen!"
        echo "Bitte prüfen Sie manuell:"
        echo "- ${web_root}"
        echo "- ${jail_root}"
    fi

    # SSH-Config entfernen
    echo "Entferne SSH-Konfiguration..."
    sed -i "/# Secure Chroot Config für ${username}/,+6d" /etc/ssh/sshd_config

    # SSH neu starten wenn Konfiguration valide ist
    if sshd -t; then
        systemctl restart sshd
    else
        echo "WARNUNG: SSH-Konfiguration scheint beschädigt zu sein!"
        echo "Bitte überprüfen Sie die Konfiguration manuell."
    fi

    if [ -d "${jail_root}" ]; then
        echo "WARNUNG: Jail-Verzeichnis existiert noch: ${jail_root}"
        echo "Sie können versuchen, den Server neu zu starten und dann manuell zu löschen:"
        echo "rm -rf ${jail_root}"
    fi

    echo "Chroot-User wurde gelöscht!"
    echo "Backup erstellt: ${backup_dir}/${username}_backup_${timestamp}.tar.gz"
}

install_chroot_dev_tools() {
    local username=$1
    local jail_root="/var/www/jails/${username}"

    if [ ! -d "$jail_root" ]; then
        echo "Fehler: Chroot-Verzeichnis für ${username} existiert nicht!"
        return 1
    fi

    echo "Installiere Entwickler-Tools für Chroot-User ${username}..."

    # Erstelle notwendige Verzeichnisse
    mkdir -p "${jail_root}/usr/local/bin"
    mkdir -p "${jail_root}/usr/lib/node_modules"
    mkdir -p "${jail_root}/.composer"
    mkdir -p "${jail_root}/tmp"
    mkdir -p "${jail_root}/dev"

    # Composer installieren
    echo "1/6 Installiere Composer..."
    if [ ! -f "/usr/local/bin/composer" ]; then
        EXPECTED_CHECKSUM="$(php -r 'copy("https://composer.github.io/installer.sig", "php://stdout");')"
        php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');"
        ACTUAL_CHECKSUM="$(php -r "echo hash_file('sha384', 'composer-setup.php');")"

        if [ "$EXPECTED_CHECKSUM" != "$ACTUAL_CHECKSUM" ]; then
            rm composer-setup.php
            echo 'Composer Installer korrupt'
            return 1
        fi

        php composer-setup.php --install-dir=/usr/local/bin --filename=composer
        rm composer-setup.php
    fi
    cp /usr/local/bin/composer "${jail_root}/usr/local/bin/"
    chmod +x "${jail_root}/usr/local/bin/composer"

    # PHP und Extensions
    echo "2/6 Kopiere PHP und Extensions..."
    mkdir -p "${jail_root}/usr/bin"
    cp /usr/bin/php* "${jail_root}/usr/bin/" 2>/dev/null || true
    mkdir -p "${jail_root}/usr/lib/php"
    cp -r /usr/lib/php/* "${jail_root}/usr/lib/php/" 2>/dev/null || true

    # Node.js und NPM (Optional)
    echo "3/6 Installiere Node.js Basis..."
    if command -v node >/dev/null; then
        cp $(which node) "${jail_root}/usr/bin/"
        cp $(which npm) "${jail_root}/usr/bin/"
    fi

    # Symfony CLI (Optional)
    echo "4/6 Installiere Symfony CLI..."
    if command -v symfony >/dev/null; then
        cp $(which symfony) "${jail_root}/usr/local/bin/"
        chmod +x "${jail_root}/usr/local/bin/symfony"
    fi

    # Zusätzliche Entwickler-Tools
    echo "5/6 Kopiere zusätzliche Entwickler-Tools..."
    local dev_tools=(
        "git" "curl" "wget" "unzip" "tar" "gzip"
        "nano" "vim" "grep" "awk" "sed"
    )

    for tool in "${dev_tools[@]}"; do
        if [ -f "/usr/bin/$tool" ]; then
            cp "/usr/bin/$tool" "${jail_root}/usr/bin/"
        fi
    done

    # Symfony und allgemeine Entwicklungs-Bibliotheken
    echo "6/6 Kopiere Bibliotheken..."
    local dev_libs=(
        "libicu*"
        "libxml2*"
        "libxslt*"
        "libzip*"
        "libsqlite3*"
        "libonig*"
        "libcurl*"
        "libssl*"
        "libcrypto*"
        "libbz2*"
        "libreadline*"
        "libncurses*"
        "libtinfo*"
        "libstdc++*"
        "libgcc_s*"
        "libc.*"
        "libintl*"
        "libyaml*"
        "libpcre*"
        "libmagic*"
        "libsasl*"
        "libgssapi*"
        "libkrb5*"
        "libk5crypto*"
        "libcom_err*"
        "liblzma*"
        "libffi*"
        "libpng*"
        "libjpeg*"
        "libfreetype*"
        "libmemcached*"
        "libldap*"
        "libpq*"
    )

    for lib in "${dev_libs[@]}"; do
        mkdir -p "${jail_root}/lib/x86_64-linux-gnu/"
        cp /lib/x86_64-linux-gnu/${lib} "${jail_root}/lib/x86_64-linux-gnu/" 2>/dev/null || true
        mkdir -p "${jail_root}/usr/lib/x86_64-linux-gnu/"
        cp /usr/lib/x86_64-linux-gnu/${lib} "${jail_root}/usr/lib/x86_64-linux-gnu/" 2>/dev/null || true
    done

    # Erstelle /dev/null und /dev/urandom wenn nicht vorhanden
    if [ ! -e "${jail_root}/dev/null" ]; then
        mknod "${jail_root}/dev/null" c 1 3
        chmod 666 "${jail_root}/dev/null"
    fi
    if [ ! -e "${jail_root}/dev/urandom" ]; then
        mknod "${jail_root}/dev/urandom" c 1 9
        chmod 666 "${jail_root}/dev/urandom"
    fi

    # Composer Konfiguration für Symfony
    cat > "${jail_root}/.composer/composer.json" <<EOF
{
    "config": {
        "bin-dir": "vendor/bin",
        "allow-plugins": {
            "symfony/flex": true,
            "symfony/runtime": true,
            "php-http/discovery": true
        },
        "optimize-autoloader": true,
        "preferred-install": {
            "*": "dist"
        },
        "sort-packages": true
    }
}
EOF

    # Entwickler .bashrc mit Symfony-Support
    cat > "${jail_root}/.bashrc" <<EOF
# Basis PATH
export PATH=/usr/local/bin:/usr/bin:/bin:/home/${username}/bin

# Entwickler Aliase
alias ll='ls -la'
alias la='ls -la'
alias l='ls -CF'
alias composer='COMPOSER_ALLOW_SUPERUSER=1 composer'
alias sf='php bin/console'
alias sfcc='php bin/console cache:clear'
alias sfserve='php -S 0.0.0.0:8000 -t public'
alias sfperms='find . -type f -exec chmod 664 {} \; && find . -type d -exec chmod 775 {} \;'

# Git Aliase
alias gs='git status'
alias ga='git add'
alias gc='git commit'
alias gp='git push'
alias gl='git pull'

# Composer Environment
export COMPOSER_HOME="/home/${username}/.composer"
export PATH="\$PATH:/web/vendor/bin"

# PHP Settings für Entwicklung
export APP_ENV=dev
alias php='php -d memory_limit=-1'

# Node.js Environment (wenn installiert)
if [ -f /usr/bin/node ]; then
    export NODE_PATH="/usr/lib/node_modules"
fi

# Symfony Environment
export SYMFONY_ENV=dev
export SYMFONY_DEBUG=1

# Standard Verzeichnis
cd /web
EOF

    # Cache- und Log-Verzeichnisse
    mkdir -p "${jail_root}/tmp/symfony-cache"
    mkdir -p "${jail_root}/tmp/symfony-logs"
    chown -R "${username}:www-data" "${jail_root}/tmp"
    chmod -R 775 "${jail_root}/tmp"

    # Setze finale Berechtigungen
    chown -R "${username}:www-data" "${jail_root}/.composer"
    chown "${username}:www-data" "${jail_root}/.bashrc"
    chmod 755 "${jail_root}/usr/local/bin/composer"

    echo "============================================"
    echo "Entwickler-Tools wurden erfolgreich installiert!"
    echo "============================================"
    echo "Verfügbare Tools:"
    echo "- Composer (global installiert)"
    echo "- PHP und Extensions"
    echo "- Git, Curl, Wget, etc."
    if command -v node >/dev/null; then
        echo "- Node.js und NPM"
    fi
    if command -v symfony >/dev/null; then
        echo "- Symfony CLI"
    fi
    echo
    echo "Symfony Features:"
    echo "- Composer mit Symfony Flex Support"
    echo "- Symfony Console Aliase (sf, sfcc, sfserve)"
    echo "- Cache & Log Verzeichnisse"
    echo "- Optimierte PHP-Einstellungen"
    echo
    echo "Nützliche Aliase:"
    echo "- sf       (symfony console)"
    echo "- sfcc     (cache clear)"
    echo "- sfserve  (development server)"
    echo "- sfperms  (fix permissions)"
    echo
    echo "Um ein neues Symfony-Projekt zu erstellen:"
    echo "1. ssh -p 62954 ${username}@domain"
    echo "2. cd /web/html/deine-domain"
    echo "3. composer create-project symfony/skeleton ."
    echo "   oder"
    echo "   composer create-project symfony/website-skeleton ."
    echo
    echo "HINWEIS: Bei Berechtigungsproblemen:"
    echo "cd /web/html/deine-domain && sfperms"
}

# Standard SSH User erstellen
create_ssh_user() {
    local username=$1
    local password=$2
    local is_developer=$3

    if [ -z "$username" ]; then
        echo "Fehler: Kein Username angegeben!"
        return 1
    fi

    if [ -z "$password" ]; then
        echo "Fehler: Kein Passwort angegeben!"
        return 1
    fi

    # Prüfe ob User bereits existiert
    if id "$username" &>/dev/null; then
        echo "WARNUNG: User ${username} existiert bereits!"
        read -p "Möchten Sie den bestehenden User überschreiben? (j/N): " overwrite
        if [[ "$overwrite" == "j" || "$overwrite" == "J" ]]; then
            echo "Lösche bestehenden User..."
            delete_ssh_user "$username"
            sleep 2
        else
            echo "Abbruch durch Benutzer."
            return 1
        fi
    fi

    # Erstelle User mit www-data als Gruppe
    useradd -m -g www-data -s /bin/bash "$username"
    echo "${username}:${password}" | chpasswd

    # Basis-Verzeichnisstruktur
    if [ "$is_developer" = "true" ]; then
        mkdir -p "/home/${username}/"{bin,dev,logs}

        # Entwickler-Tools verlinken
        DEV_COMMANDS=(
            "git" "composer" "php" "mysql" "npm" "node"
            "curl" "wget" "tar" "gzip" "unzip" "ssh"
            "rsync" "scp" "sftp" "ls" "cp" "mv" "rm"
            "mkdir" "rmdir" "grep" "nano" "vi" "chmod"
            "chown" "cat" "less"
        )

        for cmd in "${DEV_COMMANDS[@]}"; do
            if [ -f "/usr/bin/${cmd}" ]; then
                ln -sf "/usr/bin/${cmd}" "/home/${username}/bin/${cmd}"
            elif [ -f "/bin/${cmd}" ]; then
                ln -sf "/bin/${cmd}" "/home/${username}/bin/${cmd}"
            fi
        done

        # Entwickler .bashrc
        cat > "/home/${username}/.bashrc" << EOF
# Entwickler PATH-Setup
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/home/${username}/bin"

# Entwickler-Aliase
alias ll='ls -la'

# Logging von Befehlen
export PROMPT_COMMAND='if [ "$(id -u)" -ne 0 ]; then echo "\$(date "+%Y-%m-%d.%H:%M:%S") \$(pwd) \$(history 1)" >> "/home/${username}/logs/bash_history.log"; fi'

# Entwicklungsumgebung
export COMPOSER_HOME="/home/${username}/.composer"
export NODE_ENV="development"
export PHP_ENV="development"
EOF

    else
        mkdir -p "/home/${username}/bin"

        # Standard-Befehle
        ALLOWED_COMMANDS=("ls" "cp" "mv" "rm" "mkdir" "rmdir" "grep" "nano" "vi" "chmod" "chown" "cat" "less" "sftp" "scp")
        for cmd in "${ALLOWED_COMMANDS[@]}"; do
            if [ -f "/bin/${cmd}" ]; then
                ln -sf "/bin/${cmd}" "/home/${username}/bin/${cmd}"
            elif [ -f "/usr/bin/${cmd}" ]; then
                ln -sf "/usr/bin/${cmd}" "/home/${username}/bin/${cmd}"
            fi
        done

        # Standard .bashrc
        cat > "/home/${username}/.bashrc" << EOF
# Standard PATH-Setup
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/home/${username}/bin"
EOF
    fi

    # Setze finale Berechtigungen
    chown -R "${username}:www-data" "/home/${username}"
    chmod 750 "/home/${username}"
    chmod 755 "/home/${username}/bin"

    echo "SSH-User ${username} wurde erstellt!"
}

# User löschen
delete_ssh_user() {
    local username=$1

    if [ -z "$username" ]; then
        echo "Fehler: Kein Username angegeben!"
        return 1
    fi

    if ! id "$username" &>/dev/null; then
        echo "Fehler: User ${username} existiert nicht!"
        return 1
    fi

    echo "ACHTUNG: User ${username} wird gelöscht!"
    read -p "Fortfahren? (j/N): " confirm
    if [[ "$confirm" != "j" && "$confirm" != "J" ]]; then
        echo "Abbruch durch Benutzer."
        return 1
    fi

    # Beende alle Prozesse des Users
    pkill -u "$username"

    # Backup des Home-Verzeichnisses
    if [ -d "/home/${username}" ]; then
        read -p "Backup des Home-Verzeichnisses erstellen? (j/N): " backup
        if [[ "$backup" == "j" || "$backup" == "J" ]]; then
            backup_dir="/root/user_backups"
            mkdir -p "$backup_dir"
            timestamp=$(date +%Y%m%d_%H%M%S)
            tar czf "${backup_dir}/${username}_backup_${timestamp}.tar.gz" "/home/${username}" 2>/dev/null
            echo "Backup erstellt unter: ${backup_dir}/${username}_backup_${timestamp}.tar.gz"
        fi
    fi

    # Lösche User und Home-Verzeichnis
    userdel -r "$username" 2>/dev/null || {
        echo "Standard-Löschung fehlgeschlagen, versuche forcierte Löschung..."
        userdel "$username" 2>/dev/null
        rm -rf "/home/${username}" 2>/dev/null
    }

    echo "User ${username} wurde gelöscht!"
}

# Chroot User löschen
delete_chroot_user() {
    local username=$1

    echo "Lösche Chroot-User: $username"

    # Pfade
    local web_root="/var/www/${username}"
    local jail_root="/var/www/jails/${username}"

    # Backup erstellen
    local backup_dir="/root/user_backups"
    mkdir -p "${backup_dir}"
    local timestamp=$(date +%Y%m%d_%H%M%S)

    echo "Erstelle Backup..."
    tar czf "${backup_dir}/${username}_backup_${timestamp}.tar.gz" "${web_root}" "${jail_root}" 2>/dev/null

    # User und Verzeichnisse entfernen
    userdel -f "${username}" 2>/dev/null
    rm -rf "${web_root}" "${jail_root}"

    # SSH-Config entfernen
    sed -i "/# Secure Chroot Config für ${username}/,+5d" /etc/ssh/sshd_config

    # SSH neu starten
    systemctl restart sshd

    echo "Chroot-User wurde gelöscht!"
    echo "Backup erstellt: ${backup_dir}/${username}_backup_${timestamp}.tar.gz"
}

# Hilfsfunktionen für SSH User Management
list_ssh_users() {
    echo "=== SSH User ==="
    echo "Standard und Entwickler User:"
    # Zeige nur nicht-Chroot User
    awk -F: '$7 ~ /\/bin\/bash/ && $6 !~ /\/var\/www\/jails/ {print "- " $1}' /etc/passwd

    # Prüfe auf Chroot-User nur wenn das Verzeichnis existiert
    if [ -d "/var/www/jails" ]; then
        # Zähle die Anzahl der Unterverzeichnisse
        local chroot_count=$(find "/var/www/jails" -maxdepth 1 -mindepth 1 -type d | wc -l)

        if [ "$chroot_count" -gt 0 ]; then
            echo
            echo "Chroot User:"
            find "/var/www/jails" -maxdepth 1 -mindepth 1 -type d -exec basename {} \; | while read user; do
                if id "$user" &>/dev/null; then
                    echo "- $user (chroot)"
                else
                    # Aufräumen: Entferne verwaiste Chroot-Verzeichnisse
                    echo "- $user (verwaist, wird aufgeräumt)"
                    local jail_root="/var/www/jails/$user"

                    # Unmounte in definierter Reihenfolge
                    for mount_point in "${jail_root}/var/www/$user" "${jail_root}/dev/pts" "${jail_root}/dev/shm"; do
                        if mount | grep -q " $mount_point "; then
                            echo "  Unmounte $mount_point"
                            umount -f "$mount_point" 2>/dev/null || umount -l "$mount_point" 2>/dev/null
                            sleep 1
                        fi
                    done

                    # Entferne fstab Einträge
                    sed -i "\#${jail_root}#d" /etc/fstab
                    systemctl daemon-reload

                    # Warte kurz
                    sleep 2

                    # Versuche das Verzeichnis zu löschen
                    rm -rf "/var/www/jails/$user" "/var/www/$user" 2>/dev/null
                fi
            done
        fi
    fi
}

# Hilfsfunktion zum Unmounten aller Verzeichnisse eines Users
unmount_user_directories() {
    local username=$1
    local jail_root="/var/www/jails/${username}"

    # Finde und unmounte alle Mounts in umgekehrter Reihenfolge
    mount | grep "${jail_root}" | awk '{print $3}' | sort -r | while read mount_point; do
        echo "Unmounte $mount_point"
        umount -f "$mount_point" 2>/dev/null || umount -l "$mount_point" 2>/dev/null
    done

    # Warte kurz
    sleep 2

    # Entferne fstab Einträge
    sed -i "\#${jail_root}#d" /etc/fstab

    return 0
}

# Hilfsfunktionen für SSH Key Management
add_ssh_key() {
    local username=$1
    local ssh_key=$2

    if [ -z "$username" ] || [ -z "$ssh_key" ]; then
        echo "Fehler: Username und SSH-Key müssen angegeben werden!"
        return 1
    fi

    # Prüfe ob es ein Chroot-User ist
    if [ -d "/var/www/jails/$username" ]; then
        local ssh_dir="/var/www/jails/${username}/.ssh"
    else
        local ssh_dir="/home/${username}/.ssh"
    fi

    mkdir -p "$ssh_dir"
    echo "$ssh_key" >> "${ssh_dir}/authorized_keys"
    chmod 700 "$ssh_dir"
    chmod 600 "${ssh_dir}/authorized_keys"
    chown -R "${username}:www-data" "$ssh_dir"

    echo "SSH-Key wurde hinzugefügt!"
}

generate_ssh_key() {
    local username=$1
    local key_type=${2:-"ed25519"}

    if [ -z "$username" ]; then
        echo "Fehler: Kein Username angegeben!"
        return 1
    fi

    # Prüfe ob es ein Chroot-User ist
    if [ -d "/var/www/jails/$username" ]; then
        local ssh_dir="/var/www/jails/${username}/.ssh"
    else
        local ssh_dir="/home/${username}/.ssh"
    fi

    mkdir -p "$ssh_dir"

    if [ "$key_type" = "ed25519" ]; then
        ssh-keygen -t ed25519 -f "${ssh_dir}/id_ed25519" -N "" -C "${username}@$(hostname)"
    else
        ssh-keygen -t rsa -b 4096 -f "${ssh_dir}/id_rsa" -N "" -C "${username}@$(hostname)"
    fi

    chmod 700 "$ssh_dir"
    chown -R "${username}:www-data" "$ssh_dir"

    echo "SSH-Key wurde generiert!"
}

list_ssh_keys() {
    local username=$1

    if [ -z "$username" ]; then
        echo "Fehler: Kein Username angegeben!"
        return 1
    fi

    # Prüfe ob es ein Chroot-User ist
    if [ -d "/var/www/jails/$username" ]; then
        local auth_keys="/var/www/jails/${username}/.ssh/authorized_keys"
    else
        local auth_keys="/home/${username}/.ssh/authorized_keys"
    fi

    if [ -f "$auth_keys" ]; then
        echo "SSH-Keys für User ${username}:"
        cat "$auth_keys"
    else
        echo "Keine SSH-Keys für User ${username} gefunden."
    fi
}

upgrade_to_dev() {
    local username=$1

    if [ -z "$username" ]; then
        echo "Fehler: Kein Username angegeben!"
        return 1
    fi

    if [ -d "/var/www/jails/$username" ]; then
        echo "Chroot-User können nicht zu Entwickler-Accounts upgegradet werden!"
        return 1
    fi

    echo "ACHTUNG: User ${username} wird zu einem Entwickler-Account geändert!"
    read -p "Fortfahren? (j/N): " confirm
    if [[ "$confirm" != "j" && "$confirm" != "J" ]]; then
        echo "Abbruch durch Benutzer."
        return 1
    fi

    # Backup der SSH-Keys
    local temp_keys=""
    if [ -f "/home/${username}/.ssh/authorized_keys" ]; then
        temp_keys=$(cat "/home/${username}/.ssh/authorized_keys")
    fi

    # User neu erstellen als Entwickler
    delete_ssh_user "$username"
    sleep 2
    create_ssh_user "$username" "" "true"

    # SSH-Keys wiederherstellen
    if [ ! -z "$temp_keys" ]; then
        echo "$temp_keys" > "/home/${username}/.ssh/authorized_keys"
        chmod 600 "/home/${username}/.ssh/authorized_keys"
        chown "${username}:www-data" "/home/${username}/.ssh/authorized_keys"
    fi

    echo "User wurde zu einem Entwickler-Account upgegradet!"
}

# DocRoot Management Menü
manage_docroots() {
    local username=$1
    local submenu=true

    while $submenu; do
        clear
        echo "=== DocRoot Management für $username ==="
        echo "1. DocRoot hinzufügen"
        echo "2. DocRoots anzeigen"
        echo "3. DocRoot entfernen"
        echo "4. DocRoot-Berechtigungen reparieren"
        echo "5. Zurück"
        echo
        read -p "Wähle eine Option (1-5): " choice

        case $choice in
            1)
                read -p "Pfad zum neuen DocRoot (oder 'q' für abbrechen): " new_docroot
                if [ "$new_docroot" != "q" ] && [ ! -z "$new_docroot" ]; then
                    if grep -q "/bin/bash" <(getent passwd "$username"); then
                        add_docroot "$username" "$new_docroot" "true"
                    else
                        add_docroot "$username" "$new_docroot" "false"
                    fi
                fi
                ;;
            2)
                list_docroots "$username"
                ;;
            3)
                echo "Verfügbare DocRoots:"
                list_docroots "$username"
                echo
                read -p "Pfad zum zu entfernenden DocRoot: " remove_path
                if [ ! -z "$remove_path" ]; then
                    remove_docroot "$username" "$remove_path"
                fi
                ;;
            4)
                if grep -q "/bin/bash" <(getent passwd "$username"); then
                    repair_docroot_permissions "$username" "true"
                else
                    repair_docroot_permissions "$username" "false"
                fi
                echo "Berechtigungen wurden repariert!"
                ;;
            5)
                submenu=false
                continue
                ;;
            *)
                echo "Ungültige Option!"
                ;;
        esac

        if [ "$choice" != "5" ]; then
            echo
            read -p "Enter drücken zum Fortfahren..."
        fi
    done
}

# Hauptmenü-Funktion
ssh_menu() {
    local submenu=true

    while $submenu; do
            clear
            echo "=== SSH User Management ==="
            echo "1. Standard SSH-User erstellen"
            echo "2. Entwickler SSH-User erstellen"
            echo "3. Secure Chroot-User erstellen (ISPConfig-Style)"
            echo "4. SSH-User löschen"
            echo "5. SSH-User anzeigen"
            echo "6. SSH-Key zu bestehendem User hinzufügen"
            echo "7. Neuen SSH-Key für User generieren"
            echo "8. SSH-Keys eines Users anzeigen"
            echo "9. User zu Entwickler-Account upgraden"
            echo "10. DocRoots verwalten"
            echo "11. DocRoot-Berechtigungen reparieren"
            echo "12. ACL-Berechtigungen reparieren"
            echo "13. Entwickler-Tools für Chroot-User installieren"
            echo "14. Chroot-Struktur prüfen/reparieren"
            echo "15. Zurück zum Hauptmenü"
            echo
            read -r -p "Wähle eine Option (1-15): " choice

        case $choice in
            1)
                echo
                read -p "Username (oder 'q' für abbrechen): " username
                [ "$username" = "q" ] && continue
                read -s -p "Passwort: " password
                echo
                create_ssh_user "$username" "$password" "false"
                ;;
            2)
                echo
                read -p "Username (oder 'q' für abbrechen): " username
                [ "$username" = "q" ] && continue
                read -s -p "Passwort: " password
                echo
                create_ssh_user "$username" "$password" "true"
                ;;
            3)
                echo
                read -p "Username (oder 'q' für abbrechen): " username
                [ "$username" = "q" ] && continue
                read -s -p "Passwort: " password
                echo
                read -p "Web-Verzeichnis [/var/www/$username]: " web_root
                web_root=${web_root:-"/var/www/$username"}
                create_secure_chroot_user "$username" "$password" "$web_root"
                ;;
            4)
                echo
                echo "=== SSH User löschen ==="
                list_ssh_users
                echo
                read -p "Username zum Löschen (oder 'q' für abbrechen): " username
                [ "$username" = "q" ] && continue

                if ! id "$username" &>/dev/null; then
                    echo "Fehler: User ${username} existiert nicht!"
                    read -p "Enter drücken zum Fortfahren..."
                    continue
                fi

                # Prüfe ob es ein Chroot-User ist
                if [ -d "/var/www/jails/$username" ]; then
                    read -p "ACHTUNG: Chroot-User ${username} wird gelöscht! Fortfahren? (j/N): " confirm
                    if [[ "$confirm" == "j" || "$confirm" == "J" ]]; then
                        # Unmounte erst alle Verzeichnisse
                        local jail_root="/var/www/jails/${username}"

                        echo "Unmounte Verzeichnisse..."

                        # Definierte Reihenfolge für Unmounts
                        local mount_points=(
                            "${jail_root}/var/www/${username}"
                            "${jail_root}/dev/pts"
                            "${jail_root}/dev/shm"
                        )

                        for mount_point in "${mount_points[@]}"; do
                            if mount | grep -q " $mount_point "; then
                                echo "Unmounte $mount_point"
                                umount -f "$mount_point" 2>/dev/null || umount -l "$mount_point" 2>/dev/null
                                sleep 1
                            fi
                        done

                        # Warte kurz
                        sleep 2

                        # Entferne fstab Einträge
                        sed -i "\#${jail_root}#d" /etc/fstab
                        systemctl daemon-reload

                        # Jetzt erst den User löschen
                        delete_chroot_user "$username"
                    else
                        echo "Abbruch durch Benutzer."
                    fi
                else
                    delete_ssh_user "$username"
                fi
                ;;
            5)
                echo
                list_ssh_users
                ;;
            6)
                echo
                list_ssh_users
                echo
                read -p "Username (oder 'q' für abbrechen): " username
                [ "$username" = "q" ] && continue
                echo "Bitte SSH Public Key eingeben (Format: ssh-rsa/ssh-ed25519 AAAA... user@host):"
                read ssh_key
                add_ssh_key "$username" "$ssh_key"
                ;;
            7)
                echo
                list_ssh_users
                echo
                read -p "Username (oder 'q' für abbrechen): " username
                [ "$username" = "q" ] && continue
                read -p "Key-Typ (ed25519/rsa) [Standard: ed25519]: " key_type
                [ -z "$key_type" ] && key_type="ed25519"
                generate_ssh_key "$username" "$key_type"
                ;;
            8)
                echo
                list_ssh_users
                echo
                read -p "Username (oder 'q' für abbrechen): " username
                [ "$username" = "q" ] && continue
                list_ssh_keys "$username"
                ;;
            9)
                echo
                list_ssh_users
                echo
                read -p "Username zum Upgrade (oder 'q' für abbrechen): " username
                [ "$username" = "q" ] && continue
                upgrade_to_dev "$username"
                ;;
            10)
                echo
                list_ssh_users
                echo
                read -p "Username für DocRoot-Management (oder 'q' für abbrechen): " username
                [ "$username" = "q" ] && continue
                if id "$username" &>/dev/null; then
                    manage_docroots "$username"
                else
                    echo "User existiert nicht!"
                    read -p "Enter drücken zum Fortfahren..."
                fi
                ;;
            11)
                echo
                list_ssh_users
                echo
                read -p "Username für Berechtigungsreparatur (oder 'q' für abbrechen): " username
                [ "$username" = "q" ] && continue
                if id "$username" &>/dev/null; then
                    if grep -q "/bin/bash" <(getent passwd "$username"); then
                        repair_docroot_permissions "$username" "true"
                    else
                        repair_docroot_permissions "$username" "false"
                    fi
                    echo "Berechtigungen wurden repariert!"
                else
                    echo "User existiert nicht!"
                fi
                read -p "Enter drücken zum Fortfahren..."
                ;;
            12)
                echo
                list_ssh_users
                echo
                read -p "Username für ACL-Reparatur (oder 'q' für abbrechen): " username
                [ "$username" = "q" ] && continue
                if id "$username" &>/dev/null; then
                    read -p "DocRoot-Pfad: " docroot
                    repair_acl_permissions "$docroot" "$username"
                else
                    echo "User existiert nicht!"
                fi
                read -p "Enter drücken zum Fortfahren..."
                ;;
            13)
                echo "=== Chroot Entwickler-Tools Installation ==="
                echo "Verfügbare Chroot-User:"
                found_users=false
                for user in /var/www/jails/*; do
                    if [ -d "$user" ]; then
                        echo "- $(basename "$user")"
                        found_users=true
                    fi
                done

                if [ "$found_users" = false ]; then
                    echo "Keine Chroot-User gefunden!"
                    read -p "Enter drücken zum Fortfahren..."
                    continue
                fi

                echo
                read -p "Username (oder 'q' für abbrechen): " username
                [ "$username" = "q" ] && continue

                if [ ! -d "/var/www/jails/$username" ]; then
                    echo "Fehler: Kein Chroot-User mit diesem Namen gefunden!"
                else
                    install_chroot_dev_tools "$username"
                fi
                ;;

            14)
                echo "=== Chroot-Verwaltung ==="
                echo "Verfügbare Chroot-User:"
                for user in /var/www/jails/*; do
                    if [ -d "$user" ]; then
                        echo "- $(basename "$user")"
                    fi
                done
                echo
                read -p "Username (oder 'q' für abbrechen): " username
                [ "$username" = "q" ] && continue

                if [ ! -d "/var/www/jails/$username" ]; then
                    echo "Fehler: Kein Chroot-User mit diesem Namen gefunden!"
                    read -p "Enter drücken zum Fortfahren..."
                    continue
                fi

                verify_chroot_structure "$username"
                echo
                read -p "Soll die Chroot-Struktur repariert werden? (j/N): " repair
                if [[ "$repair" == "j" || "$repair" == "J" ]]; then
                    repair_chroot_setup "$username"
                fi
                ;;

            15)
                submenu=false
                continue
                ;;

            *)
                echo "Ungültige Option!"
                ;;
        esac

        if [ "$choice" != "14" ]; then
            echo
            read -p "Enter drücken zum Fortfahren..."
            clear
        fi
    done
}

# Hauptprogramm
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [ "$EUID" -ne 0 ]; then
        echo "Dieses Script muss als root ausgeführt werden!"
        exit 1
    fi
    ssh_menu
fi