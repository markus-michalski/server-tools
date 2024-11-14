## ssl-lets-encrypt-exists.sh

#### Benutzung

1. Speichere den Code in einer Datei, z.B. `configure-apache-ssl.sh`
2. Mache das Skript ausführbar:

`chmod +x configure-apache-ssl.sh`

3. Führe es aus (als root oder mit sudo):

`sudo ./configure-apache-ssl.sh markus-michalski.net`

Das Skript wird:

1. Das existierende Let's Encrypt Zertifikat verwenden
2. Apache für SSL konfigurieren
3. Eine automatische Weiterleitung von HTTP auf HTTPS einrichten
4. Die Apache-Konfiguration testen und neu laden

## ssl-lets-encrypt-new.sh

#### Benutzung

1. Für eine normale Domain:



`sudo ./ssl-setup-subdomain.sh example.com admin@example.com`

2. Für eine Subdomain:

`sudo ./ssl-setup-subdomain.sh stage.markus-michalski.net webmaster@markus-michalski.net subdomain`

Die wichtigsten Änderungen im Skript sind:

1. Unterscheidung zwischen Subdomain und Hauptdomain
2. Bei Subdomains wird kein [www.-Präfix](http://www.-Pr%C3%A4fix) hinzugefügt
3. Automatische Erstellung der Verzeichnisstruktur
4. Vermeidung von doppelten Cronjobs
5. Überprüfung ob Verzeichnisse bereits existieren

Das Skript erstellt automatisch:

- Das Verzeichnis `/var/www/stage.markus-michalski.net/html`
- Die Apache-Konfiguration mit SSL
- Ein eigenes Zertifikat für die Subdomain
- Die HTTP zu HTTPS Weiterleitung
