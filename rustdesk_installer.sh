#!/bin/bash

# ##################################################################
#  RustDesk Server Manager (RDSM)
#  Ein Skript zur einfachen Installation, Verwaltung und
#  Client-Erstellung für einen selbstgehosteten RustDesk Server.
# ##################################################################

# --- Globale Variablen und Konfiguration ---
CONFIG_DIR="/etc/rustdesk-manager"
CONFIG_FILE="${CONFIG_DIR}/rdsm.conf"
INSTALL_PATH="/opt/rustdesk-server"
CLIENT_DIR="${INSTALL_PATH}/clients"
LOG_FILE="/var/log/rdsm_installer.log"

# --- Farbdefinitionen für die Ausgabe ---
C_RESET='\033[0m'
C_RED='\033[0;31m'
C_GREEN='\033[0;32m'
C_YELLOW='\033[0;33m'
C_BLUE='\033[38;5;81m'

# --- Hilfsfunktionen für formatierte Ausgaben ---
echo_info() { echo -e "${C_BLUE}INFO: $1${C_RESET}"; }
echo_success() { echo -e "${C_GREEN}ERFOLG: $1${C_RESET}"; }
echo_warning() { echo -e "${C_YELLOW}WARNUNG: $1${C_RESET}"; }
echo_error() { echo -e "${C_RED}FEHLER: $1${C_RESET}"; }

# --- Hauptfunktionen ---

# Funktion zur Überprüfung, ob das Skript als root ausgeführt wird
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo_error "Dieses Skript muss mit Root-Rechten ausgeführt werden. Bitte verwenden Sie 'sudo'."
        exit 1
    fi
}

# Funktion zur Überprüfung des Installationsstatus
check_installation_state() {
    if [ -f "$CONFIG_FILE" ]; then
        echo "VOLLSTÄNDIG"
    elif [ -d "$INSTALL_PATH" ] || [ -f "/etc/systemd/system/hbbs.service" ]; then
        echo "FEHLGESCHLAGEN"
    else
        echo "SAUBER"
    fi
}

# Funktion zur Deinstallation
uninstall_server() {
    echo_info "Stoppe und deaktiviere RustDesk-Dienste..."
    systemctl stop hbbs hbbr &>/dev/null
    systemctl disable hbbs hbbr &>/dev/null

    echo_info "Entferne Systemd-Service-Dateien..."
    rm -f /etc/systemd/system/hbbs.service
    rm -f /etc/systemd/system/hbbr.service
    systemctl daemon-reload

    echo_info "Entferne Installations- und Konfigurationsdateien..."
    rm -rf "$INSTALL_PATH"
    rm -rf "$CONFIG_DIR"

    echo_success "RustDesk Server wurde vollständig deinstalliert."
}

# Installationsroutine
install_server() {
    echo_info "Starte die Installation des RustDesk Servers..."
    
    # 1. Abhängigkeiten installieren
    echo_info "Installiere notwendige Abhängigkeiten (wget, unzip, curl, jq, qrencode)..."
    apt-get update &>/dev/null
    apt-get install -y wget sudo unzip curl jq qrencode &>> "$LOG_FILE"
    if [ $? -ne 0 ]; then
        echo_error "Installation der Abhängigkeiten fehlgeschlagen. Details siehe in $LOG_FILE"
        exit 1
    fi

    # 2. Domain abfragen
    read -rp "Bitte geben Sie Ihre öffentliche Domain für den Server ein (z.B. rustdesk.ihredomain.de): " SERVER_DOMAIN
    if [ -z "$SERVER_DOMAIN" ]; then
        echo_error "Die Domain darf nicht leer sein. Abbruch."
        exit 1
    fi

    # 3. Firewall-Konfiguration (optional)
    if command -v ufw &> /dev/null; then
        read -rp "INFO: Firewall (UFW) erkannt. Sollen die RustDesk-Ports (21115-21119) freigegeben werden? (j/N): " UFW_CHOICE
        if [[ "$UFW_CHOICE" =~ ^[jJ]$ ]]; then
            echo_info "Konfiguriere UFW..."
            ufw allow 21115/tcp
            ufw allow 21116/tcp
            ufw allow 21116/udp
            ufw allow 21117/tcp
            ufw allow 21118/tcp
            ufw allow 21119/tcp
            ufw reload
            echo_success "Firewall-Regeln wurden hinzugefügt."
        fi
    fi

    # 4. Server-Binaries herunterladen
    echo_info "Lade die neueste Version des RustDesk Servers herunter..."
    LATEST_VERSION=$(curl -s "https://api.github.com/repos/rustdesk/rustdesk-server/releases/latest" | jq -r .tag_name)
    wget "https://github.com/rustdesk/rustdesk-server/releases/download/${LATEST_VERSION}/rustdesk-server-linux-amd64.zip" -O /tmp/rustdesk-server.zip &>> "$LOG_FILE"
    if [ $? -ne 0 ]; then
        echo_error "Download fehlgeschlagen. Details siehe in $LOG_FILE"
        uninstall_server # Aufräumen
        exit 1
    fi

    mkdir -p "$INSTALL_PATH"
    # --- KORRIGIERTER BLOCK ---
    # Entpackt direkt in den Installationspfad
    unzip -o /tmp/rustdesk-server.zip -d "$INSTALL_PATH" &>> "$LOG_FILE"
    
    # Verschiebt die Dateien aus der verschachtelten Struktur nach oben
    # Die Pfad-Prüfung macht es robuster für zukünftige Änderungen
    NESTED_PATH=$(find "$INSTALL_PATH" -name hbbs -exec dirname {} \;)
    if [ -n "$NESTED_PATH" ] && [ "$NESTED_PATH" != "$INSTALL_PATH" ]; then
        mv "${NESTED_PATH}/"* "$INSTALL_PATH/"
        # Entfernt die leeren übergeordneten Ordner
        find "$INSTALL_PATH" -type d -empty -delete
    fi
    
    rm -f /tmp/rustdesk-server.zip
    # --- ENDE KORRIGIERTER BLOCK ---

    # 5. Systemd-Services erstellen
    echo_info "Erstelle Systemd-Dienste..."
    
    HBBS_PARAMS="-r ${SERVER_DOMAIN}:21117"
    HBBR_PARAMS=""

    cat > /etc/systemd/system/hbbs.service <<EOL
[Unit]
Description=RustDesk ID/Rendezvous Server
Requires=network-online.target
After=network-online.target

[Service]
Type=simple
LimitNOFILE=1048576
ExecStart=${INSTALL_PATH}/hbbs ${HBBS_PARAMS}
WorkingDirectory=${INSTALL_PATH}
User=root
Group=root
Restart=always
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOL

    cat > /etc/systemd/system/hbbr.service <<EOL
[Unit]
Description=RustDesk Relay Server
Requires=network-online.target
After=network-online.target

[Service]
Type=simple
LimitNOFILE=1048576
ExecStart=${INSTALL_PATH}/hbbr ${HBBR_PARAMS}
WorkingDirectory=${INSTALL_PATH}
User=root
Group=root
Restart=always
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOL

    systemctl daemon-reload
    systemctl enable hbbs hbbr &>/dev/null
    
    # 6. Konfigurationsdatei erstellen, um die Installation abzuschließen
    mkdir -p "$CONFIG_DIR"
    cat > "$CONFIG_FILE" <<EOL
# RDSM Konfigurationsdatei
SERVER_DOMAIN="${SERVER_DOMAIN}"
HBBS_PARAMS="${HBBS_PARAMS}"
HBBR_PARAMS="${HBBR_PARAMS}"
EOL

    # 7. Server starten
    start_services

    echo_success "RustDesk Server wurde erfolgreich installiert und gestartet."
    echo_info "Ihr öffentlicher Schlüssel wird nun angezeigt. Bewahren Sie ihn gut auf."
    sleep 2
    echo # Diese Zeile fügt den Zeilenumbruch hinzu
    cat "${INSTALL_PATH}/id_ed25519.pub"
    echo # Diese Zeile fügt den Zeilenumbruch hinzu
    read -rp "Drücken Sie [Enter], um zum Hauptmenü zurückzukehren."
}

# --- Verwaltungsfunktionen ---
load_config() { source "$CONFIG_FILE"; }
start_services() { echo_info "Starte Dienste..."; systemctl start hbbs hbbr; }
stop_services() { echo_info "Stoppe Dienste..."; systemctl stop hbbs hbbr; }
restart_services() { echo_info "Starte Dienste neu..."; systemctl restart hbbs hbbr; }
show_logs() { journalctl -u hbbs -u hbbr -f --no-pager; }

update_server() {
    echo_info "Suche nach Updates für den RustDesk Server..."
    LATEST_VERSION=$(curl -s "https://api.github.com/repos/rustdesk/rustdesk-server/releases/latest" | jq -r .tag_name)
    CURRENT_VERSION=$(${INSTALL_PATH}/hbbs --version | awk '{print $2}')

    if [ "$LATEST_VERSION" == "$CURRENT_VERSION" ]; then
        echo_info "Sie verwenden bereits die neueste Version ($CURRENT_VERSION)."
    else
        read -rp "Eine neue Version ($LATEST_VERSION) ist verfügbar. Jetzt aktualisieren? (j/N): " UPDATE_CHOICE
        if [[ "$UPDATE_CHOICE" =~ ^[jJ]$ ]]; then
            stop_services
            echo_info "Lade Version $LATEST_VERSION herunter..."
            wget "https://github.com/rustdesk/rustdesk-server/releases/download/${LATEST_VERSION}/rustdesk-server-linux-amd64.zip" -O /tmp/rustdesk-server.zip &>> "$LOG_FILE"
            unzip -o /tmp/rustdesk-server.zip -d "$INSTALL_PATH/amd64" &>> "$LOG_FILE"
            mv "$INSTALL_PATH/amd64/"* "$INSTALL_PATH/"
            rm -rf /tmp/rustdesk-server.zip "$INSTALL_PATH/amd64"
            start_services
            echo_success "Server wurde auf Version $LATEST_VERSION aktualisiert."
        fi
    fi
}


edit_parameters() {
    echo_info "Öffne Konfigurationsdatei im Nano-Editor..."
    echo_warning "Änderungen erfordern einen Neustart der Dienste, um wirksam zu werden."
    nano "$CONFIG_FILE"
    read -rp "Sollen die Dienste jetzt neugestartet werden, um die Änderungen zu übernehmen? (j/N): " RESTART_CHOICE
    if [[ "$RESTART_CHOICE" =~ ^[jJ]$ ]]; then
        # Parameter in Service-Dateien aktualisieren
        load_config
        sed -i "s|ExecStart=.*|ExecStart=${INSTALL_PATH}/hbbs ${HBBS_PARAMS}|" /etc/systemd/system/hbbs.service
        sed -i "s|ExecStart=.*|ExecStart=${INSTALL_PATH}/hbbr ${HBBR_PARAMS}|" /etc/systemd/system/hbbr.service
        systemctl daemon-reload
        restart_services
        echo_success "Parameter aktualisiert und Dienste neugestartet."
    fi
}

reset_parameters() {
    load_config
    HBBS_PARAMS_DEFAULT="-r ${SERVER_DOMAIN}:21117"
    HBBR_PARAMS_DEFAULT=""
    sed -i "s|HBBS_PARAMS=.*|HBBS_PARAMS=\"${HBBS_PARAMS_DEFAULT}\"|" "$CONFIG_FILE"
    sed -i "s|HBBR_PARAMS=.*|HBBR_PARAMS=\"${HBBR_PARAMS_DEFAULT}\"|" "$CONFIG_FILE"
    echo_success "Parameter wurden auf Standardwerte zurückgesetzt."
    edit_parameters # Direkt zur Bearbeitung/Neustart springen
}


generate_new_key() {
    echo_warning "Sie sind dabei, einen neuen Sicherheitsschlüssel zu generieren."
    echo_warning "ALLE bestehenden Clients verlieren die Verbindung und müssen neu konfiguriert werden!"
    read -rp "Sind Sie absolut sicher? Geben Sie 'JA' ein, um fortzufahren: " CONFIRM_KEY
    if [ "$CONFIRM_KEY" == "JA" ]; then
        stop_services
        echo_info "Sichere alte Schlüssel..."
        mv "${INSTALL_PATH}/id_ed25519" "${INSTALL_PATH}/id_ed25519.bak"
        mv "${INSTALL_PATH}/id_ed25519.pub" "${INSTALL_PATH}/id_ed25519.pub.bak"
        start_services
        echo_success "Neue Schlüssel wurden generiert. Server wird gestartet..."
        sleep 2
        echo_info "Der neue öffentliche Schlüssel lautet:"
        cat "${INSTALL_PATH}/id_ed25519.pub"
    else
        echo_info "Aktion abgebrochen."
    fi
}

# --- Client-Erstellungsfunktionen ---

create_client_package() {
    OS_TYPE=$1
    echo_info "Erstelle Client-Paket für ${OS_TYPE}..."
    load_config
    RUSTDESK_KEY=$(cat "${INSTALL_PATH}/id_ed25519.pub")
    
    mkdir -p "$CLIENT_DIR"
    LATEST_VERSION=$(curl -s "https://api.github.com/repos/rustdesk/rustdesk/releases/latest" | jq -r .tag_name)

    case $OS_TYPE in
        Windows)
            FILE_EXT="exe"
            PLATFORM="x86_64"
            CLIENT_URL="https://github.com/rustdesk/rustdesk/releases/download/${LATEST_VERSION}/rustdesk-${LATEST_VERSION}-${PLATFORM}.${FILE_EXT}"
            SCITER_URL="https://github.com/rustdesk/rustdesk/releases/download/${LATEST_VERSION}/rustdesk-sciter.zip"
            
            echo_info "Lade Windows Client und Bundle-Tool..."
            wget -q --show-progress "$CLIENT_URL" -O "${CLIENT_DIR}/rustdesk_win.exe"
            wget -q "$SCITER_URL" -O "${CLIENT_DIR}/sciter.zip"
            unzip -o "${CLIENT_DIR}/sciter.zip" -d "$CLIENT_DIR"
            
            echo_info "Bette Konfiguration ein..."
            "${CLIENT_DIR}/wo-bundle.exe" "${CLIENT_DIR}/rustdesk_win.exe" --host "$SERVER_DOMAIN" --key "$RUSTDESK_KEY"
            mv "${CLIENT_DIR}/rustdesk_win_bundled.exe" "${CLIENT_DIR}/RustDesk_Client_Windows.exe"
            rm "${CLIENT_DIR}/rustdesk_win.exe" "${CLIENT_DIR}/sciter.zip" "${CLIENT_DIR}/wo-bundle.exe"
            ;;
        macOS)
            FILE_EXT="dmg"
            PLATFORMS=("aarch64" "x86_64") # Apple Silicon & Intel
            wget -q -N https://raw.githubusercontent.com/rustdesk/rustdesk/master/src/hbb-util.py -P "$CLIENT_DIR"
            chmod +x "${CLIENT_DIR}/hbb-util.py"
            
            for PLATFORM in "${PLATFORMS[@]}"; do
                echo_info "Bearbeite macOS Client für ${PLATFORM}..."
                CLIENT_URL="https://github.com/rustdesk/rustdesk/releases/download/${LATEST_VERSION}/rustdesk-${LATEST_VERSION}-${PLATFORM}.${FILE_EXT}"
                wget -q --show-progress "$CLIENT_URL" -O "${CLIENT_DIR}/rustdesk_${PLATFORM}.dmg"
                python3 "${CLIENT_DIR}/hbb-util.py" --cm-config-set "${CLIENT_DIR}/rustdesk_${PLATFORM}.dmg" --host "$SERVER_DOMAIN" --key "$RUSTDESK_KEY"
            done
            rm "${CLIENT_DIR}/hbb-util.py"
            ;;
        Linux)
            FILE_EXT="AppImage"
            PLATFORM="x86_64"
            CLIENT_URL="https://github.com/rustdesk/rustdesk/releases/download/${LATEST_VERSION}/rustdesk-${LATEST_VERSION}-${PLATFORM}.${FILE_EXT}"
            wget -q -N https://raw.githubusercontent.com/rustdesk/rustdesk/master/src/hbb-util.py -P "$CLIENT_DIR"
            chmod +x "${CLIENT_DIR}/hbb-util.py"

            echo_info "Lade und konfiguriere Linux AppImage..."
            wget -q --show-progress "$CLIENT_URL" -O "${CLIENT_DIR}/RustDesk_Client_Linux.AppImage"
            python3 "${CLIENT_DIR}/hbb-util.py" --cm-config-set "${CLIENT_DIR}/RustDesk_Client_Linux.AppImage" --host "$SERVER_DOMAIN" --key "$RUSTDESK_KEY"
            rm "${CLIENT_DIR}/hbb-util.py"
            ;;
    esac
    echo_success "Client-Paket(e) für ${OS_TYPE} wurde(n) in ${CLIENT_DIR} erstellt."
}

show_qr_code() {
    load_config
    RUSTDESK_KEY=$(cat "${INSTALL_PATH}/id_ed25519.pub")
    CONFIG_STRING="{\"host\":\"${SERVER_DOMAIN}\",\"key\":\"${RUSTDESK_KEY}\"}"
    echo_info "Scannen Sie diesen QR-Code mit Ihrer mobilen RustDesk App:"
    qrencode -t ansiutf8 "$CONFIG_STRING"
}

start_download_server() {
    if ! command -v python3 &> /dev/null; then
        echo_error "Python 3 ist nicht installiert, der Webserver kann nicht gestartet werden."
        return
    fi
    IP_ADDR=$(hostname -I | awk '{print $1}')
    PORT=8000
    echo_info "Starte temporären Webserver zum Download der Clients."
    echo_info "Öffnen Sie in Ihrem Browser: http://${IP_ADDR}:${PORT}"
    echo_warning "Drücken Sie STRG+C, um den Server zu beenden und zum Menü zurückzukehren."
    pushd "$CLIENT_DIR" > /dev/null
    python3 -m http.server $PORT
    popd > /dev/null
}


# --- Menüs ---

client_menu() {
    while true; do
        clear
        echo "--------------------------------------------------"
        echo "  Client-Pakete erstellen"
        echo "--------------------------------------------------"
        echo "  1) Alle Clients (Windows, macOS, Linux)"
        echo "  2) Nur Windows Client (.exe)"
        echo "  3) Nur macOS Clients (.dmg)"
        echo "  4) Nur Linux Client (.AppImage)"
        echo "  5) QR-Code für mobile Clients anzeigen"
        echo "  6) Download-Server starten"
        echo "  0) Zurück zum Hauptmenü"
        echo "--------------------------------------------------"
        read -rp "Ihre Auswahl: " choice
        
        case $choice in
            1) create_client_package Windows; create_client_package macOS; create_client_package Linux ;;
            2) create_client_package Windows ;;
            3) create_client_package macOS ;;
            4) create_client_package Linux ;;
            5) show_qr_code ;;
            6) start_download_server ;;
            0) break ;;
            *) echo_error "Ungültige Auswahl." ;;
        esac
        read -rp "Drücken Sie [Enter], um fortzufahren."
    done
}

main_menu() {
    while true; do
        load_config
        HBBS_STATUS=$(systemctl is-active hbbs)
        HBBR_STATUS=$(systemctl is-active hbbr)
        
        clear
        echo "--------------------------------------------------"
        echo "  RustDesk Server Manager (RDSM)"
        echo "--------------------------------------------------"
        echo -e "  Domain: ${C_YELLOW}${SERVER_DOMAIN}${C_RESET}"
        echo -e "  Status: hbbs [${HBBS_STATUS}] | hbbr [${HBBR_STATUS}]"
        echo "--------------------------------------------------"
        echo ""
        echo "  Hauptmenü:"
        echo "  1) Server-Dienste starten"
        echo "  2) Server-Dienste stoppen"
        echo "  3) Server-Dienste neustarten"
        echo "  4) Live-Logs anzeigen"
        echo ""
        echo "  Client-Verwaltung:"
        echo "  5) 🛠️  Client-Pakete erstellen (Untermenü)"
        echo ""
        echo "  Konfiguration & Wartung:"
        echo "  6) Startparameter bearbeiten"
        echo "  7) Standard-Parameter wiederherstellen"
        echo "  8) 🔑  Neuen Sicherheitsschlüssel generieren"
        echo "  9) Server-Software aktualisieren"
        echo ""
        echo "  System:"
        echo "  10) ALLES deinstallieren"
        echo "  0) Beenden"
        echo "--------------------------------------------------"
        read -rp "Ihre Auswahl: " choice

        case $choice in
            1) start_services ;;
            2) stop_services ;;
            3) restart_services ;;
            4) show_logs ;;
            5) client_menu ;;
            6) edit_parameters ;;
            7) reset_parameters ;;
            8) generate_new_key ;;
            9) update_server ;;
            10) 
                read -rp "WARNUNG: Dies wird den Server vollständig entfernen. Geben Sie 'DEINSTALLIEREN' ein zur Bestätigung: " CONFIRM_UNINSTALL
                if [ "$CONFIRM_UNINSTALL" == "DEINSTALLIEREN" ]; then
                    uninstall_server
                    exit 0
                else
                    echo_info "Deinstallation abgebrochen."
                fi
                ;;
            0) exit 0 ;;
            *) echo_error "Ungültige Auswahl." ;;
        esac
        
        if [[ "$choice" != "4" ]]; then
             read -rp "Drücken Sie [Enter], um fortzufahren."
        fi
    done
}

recovery_menu() {
    clear
    echo "--------------------------------------------------"
    echo -e "  ${C_YELLOW}WARNUNG: Unvollständige Installation erkannt!${C_RESET}"
    echo "--------------------------------------------------"
    echo "  Es scheint, als wäre der letzte Installationsversuch"
    echo "  fehlgeschlagen. Ein Neustart der Installation wird"
    echo "  ohne vorherige Bereinigung nicht empfohlen."
    echo ""
    echo "  Was möchten Sie tun?"
    echo ""
    echo "  1) Installationsreste sauber entfernen (Empfohlen)"
    echo "  2) Trotzdem versuchen, neu zu installieren"
    echo "  0) Beenden"
    echo "--------------------------------------------------"
    read -rp "Ihre Auswahl: " choice

    case $choice in
        1) uninstall_server; install_server ;;
        2) uninstall_server; install_server ;; # Sicherheitshalber immer erst aufräumen
        0) exit 0 ;;
        *) echo_error "Ungültige Auswahl." ;;
    esac
}

# --- Skriptausführung ---
check_root

STATE=$(check_installation_state)

case $STATE in
    "SAUBER")
        read -rp "Willkommen beim RustDesk Server Manager. Keine Installation gefunden. Jetzt installieren? (J/n): " INSTALL_CHOICE
        if [[ -z "$INSTALL_CHOICE" || "$INSTALL_CHOICE" =~ ^[jJ]$ ]]; then
            install_server
            main_menu
        else
            echo_info "Installation abgebrochen."
            exit 0
        fi
        ;;
    "VOLLSTÄNDIG")
        main_menu
        ;;
    "FEHLGESCHLAGEN")
        recovery_menu
        ;;
esac

exit 0
