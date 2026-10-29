# GroupedApplication Container

GroupedApplication ist ein Mitarbeiterportal: gruppierte Anwendungskacheln, News mit
angehefteten Meldungen, SAML-Single-Sign-on sowie Anbindungen an Citrix StoreFront und Nextcloud
in einer gemeinsamen, frei brandbaren Weboberfläche.

## Container-Image

Das offizielle Linux-x86-64-Image wird über GitHub Container Registry bereitgestellt und kann ohne
`docker login` heruntergeladen werden:

```text
ghcr.io/team-netz-consulting/groupedapplication
```

Für produktive Installationen immer einen freigegebenen Versionstag verwenden:

```bash
docker pull ghcr.io/team-netz-consulting/groupedapplication:2026.10.29.2
```

`latest` verweist auf die zuletzt freigegebene Version, sollte aber nicht für dauerhaft
reproduzierbare Kundeninstallationen verwendet werden.

## Voraussetzungen

- Linux-x86-64-Host mit Docker Engine und Docker-Compose-Plug-in
- mindestens 2 vCPU und 4 GB Arbeitsspeicher
- ein TLS-Reverse-Proxy vor dem Container (nginx, Traefik, IIS/ARR, ...). Die Anwendung selbst
  spricht nur HTTP auf Port 8080 und darf nicht direkt ins Internet veröffentlicht werden.

## Installation

```bash
git clone https://github.com/team-netz-Consulting/GroupedApplication-Container.git
cd GroupedApplication-Container
sudo ./install.sh
```

Das Skript richtet alles unter `/opt/groupedapplication` ein: Es fragt die E-Mail des ersten
SystemOwners, den Lizenz-Kundennamen, den Host-Port und die Image-Version ab, erzeugt ein sicheres SQL-Kennwort, einen
JWT-Signaturschlüssel und ein Erstkennwort, legt die persistenten Verzeichnisse mit den
erforderlichen Container-UIDs an und startet den Stack. Die Erstanmeldedaten liegen
ausschließlich root-lesbar unter `/opt/groupedapplication/ERSTANMELDUNG.txt`; die Anmeldung
erfolgt unter `/admin`. Eine vorhandene `.env` und bestehende Daten werden nie überschrieben.

Datenbankschema-Migrationen laufen beim Start der Anwendung automatisch.

## Lizenz aktivieren

GroupedApplication benötigt eine Lizenz von team-netz. Ohne gültige Lizenz sehen Mitarbeiter nach
der Anmeldung nur den Hinweis „Lizenz erforderlich“; erreichbar bleiben die Anmeldung und die
Administration unter `/admin`, damit die Lizenz aktiviert werden kann:

1. Unter `/admin` mit den Erstanmeldedaten anmelden.
2. Den Reiter **Lizenz** öffnen. Kundenname und License-Manager-URL sind aus der Installation
   vorbelegt (`LICENSE_CUSTOMER_NAME`, `LICENSE_MANAGER_BASE_URL` in der `.env`).
3. Den erhaltenen Aktivierungscode eingeben und **Aktivieren** wählen. Der Server benötigt dafür
   einmalig ausgehenden HTTPS-Zugriff auf den License Manager.

Ohne Internetzugang erzeugt die Aktivierung eine Offline-Anfrage. Diese an team-netz senden und die
zurückgegebene `.license`-Datei im selben Reiter unter **Signierte Lizenz importieren** einspielen.

Danach wird die Lizenz lokal geprüft; eine dauerhafte Verbindung zum License Manager ist nicht nötig.
Sie ist an den Kundennamen und den Container-Hostnamen `groupedapplication` gebunden und liegt unter
`/opt/groupedapplication/data/license` – dieses Verzeichnis daher mitsichern. Läuft die Lizenz ab,
gilt eine Kulanzzeit, in der die Anwendung weiter nutzbar ist; die Administration zeigt dann einen
Hinweis. Enthält die Lizenz ein Benutzerlimit, können darüber hinaus keine weiteren Konten angelegt
werden, auch nicht automatisch per SAML.

## Update

```bash
cd GroupedApplication-Container
git pull
sudo ./install.sh
```

Das Skript bietet an, `GROUPED_APP_IMAGE_TAG` in `/opt/groupedapplication/.env` auf die neue
Version zu setzen, lädt das Image und startet den Stack neu. Alternativ den Tag manuell ändern und
`docker compose pull && docker compose up -d` in `/opt/groupedapplication` ausführen.

## Persistente Daten

Unter `/opt/groupedapplication/data`:

| Verzeichnis | Inhalt |
|---|---|
| `mssql` | SQL-Server-Datenbankdateien |
| `uploads` | hochgeladene Bilder (Kachel-Icons, News, Logo, Hintergrund, Avatare) |
| `logs` | tägliche Anwendungslogs, 14 Tage Aufbewahrung |
| `license` | aktivierte Lizenz und License-Manager-Einstellungen |
| `certs` | eigene CA-Zertifikate (siehe unten) |

Sicherung, z. B.: `sudo tar czf groupedapplication-$(date +%F).tar.gz -C /opt/groupedapplication .env data`

## Eigene CA-Zertifikate

Spricht die Anwendung mit internen HTTPS-Endpunkten einer eigenen PKI (Citrix StoreFront,
SAML-IdP, Nextcloud), müssen deren Root-/Intermediate-Zertifikate im PEM-Format (`.crt` oder
`.pem`) nach `/opt/groupedapplication/data/certs` kopiert werden. Danach:

```bash
cd /opt/groupedapplication && docker compose restart app
```

Ein auf dem Host installiertes Zertifikat genügt nicht, da der Container einen eigenen
Zertifikatsspeicher verwendet. Typisches Symptom: `AuthenticationException ... PartialChain` im Log.

## Umstieg von einer Quellcode-Installation

Bestehende Installationen, die per Deploy-Key aus dem Quellcode gebaut wurden, lassen sich
ohne Datenverlust übernehmen:

```bash
cd <altes Installationsverzeichnis>
docker compose down
sudo install -d /opt/groupedapplication
sudo cp -a data /opt/groupedapplication/data
sudo cp .env /opt/groupedapplication/.env
sudo cp certs/*.crt /opt/groupedapplication/data/certs/ 2>/dev/null || true
cd <GroupedApplication-Container> && sudo ./install.sh
```

`install.sh` ergänzt die fehlenden Image- und Lizenzeinträge in der übernommenen `.env` (den
Lizenz-Kundennamen fragt es ab) und korrigiert die Verzeichnisrechte. `DB_SA_PASSWORD` und
`JWT_SIGNING_KEY` bleiben dabei erhalten. Anschließend die Lizenz wie oben beschrieben aktivieren.
Danach kann der Deploy-Key auf dem Server entfernt werden.
