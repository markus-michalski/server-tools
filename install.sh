#!/bin/bash

# Installationspfad
INSTALL_DIR="/root/server-tools"

# Prüfe Root-Rechte
if [ "$EUID" -ne 0 ]; then 
    echo "Dieses Skript muss als root ausgeführt werden!"
    exit 1
fi

# Erstelle Installationsverzeichnis
echo "Erstelle Installationsverzeichnis ${INSTALL_DIR}..."
mkdir -p "${INSTALL_DIR}"

# Bearbeite Zeilenenden
echo "Bearbeite Zeilenenden der Dateien (LF)"
dos2unix common-functions.sh
dos2unix vhost-functions.sh
dos2unix ssl-functions.sh
dos2unix db-functions.sh
dos2unix ssh-functions.sh
dos2unix server-tools.sh

# Kopiere Skripte
echo "Kopiere Skript-Dateien..."
cp common-functions.sh "${INSTALL_DIR}/"
cp vhost-functions.sh "${INSTALL_DIR}/"
cp ssl-functions.sh "${INSTALL_DIR}/"
cp db-functions.sh "${INSTALL_DIR}/"
cp ssh-functions.sh "${INSTALL_DIR}/"
cp server-tools.sh "${INSTALL_DIR}/"

# Setze Ausführungsrechte
echo "Setze Berechtigungen..."
chmod 700 "${INSTALL_DIR}"/*.sh
chown root:root "${INSTALL_DIR}"/*.sh

# Erstelle Symlink im PATH
echo "Erstelle Symlink..."
ln -sf "${INSTALL_DIR}/server-tools.sh" /usr/local/bin/servertools

echo "Installation abgeschlossen!"
echo "Starte das Tool mit: servertools"
