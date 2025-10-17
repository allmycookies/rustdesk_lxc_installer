#!/bin/bash

# ##################################################################
#  RustDesk Server Manager (RDSM)
#  Ein Skript zur einfachen Installation, Verwaltung und
#  Client-Erstellung für einen selbstgehosteten RustDesk Server.
#  Version: v0.6 (one-file client builder, no ps1/cmd)
# ##################################################################

# --- Globale Variablen und Konfiguration ---
CONFIG_DIR="/etc/rustdesk-manager"
CONFIG_FILE="${CONFIG_DIR}/rdsm.conf"
INSTALL_PATH="/opt/rustdesk-server"
CLIENT_DIR="${INSTALL_PATH}/clients"
LOG_FILE="/var/log/rdsm_installer.log"

# --- Farben ---
C_RESET='\033[0m'; C_RED='\033[0;31m'; C_GREEN='\033[0;32m'; C_YELLOW='\033[0;33m'; C_BLUE='\033[38;5;81m'
echo_info()    { echo -e "${C_BLUE}INFO: $1${C_RESET}"; }
echo_success() { echo -e "${C_GREEN}ERFOLG: $1${C_RESET}"; }
echo_warning() { echo -e "${C_YELLOW}WARNUNG: $1${C_RESET}"; }
echo_error()   { echo -e "${C_RED}FEHLER: $1${C_RESET}"; }

# --- Root prüfen ---
check_root() { if [ "$(id -u)" -ne 0 ]; then echo_error "Als root ausführen (sudo)."; exit 1; fi; }

# --- Installationsstatus ---
check_installation_state() {
  if [ -f "$CONFIG_FILE" ]; then echo "VOLLSTÄNDIG"
  elif [ -d "$INSTALL_PATH" ] || [ -f "/etc/systemd/system/hbbs.service" ]; then echo "FEHLGESCHLAGEN"
  else echo "SAUBER"; fi
}

# --- Dienste/Deinstall ---
uninstall_server() {
  echo_info "Stoppe RustDesk-Dienste..."; systemctl stop hbbs hbbr &>/dev/null; systemctl disable hbbs hbbr &>/dev/null
  echo_info "Entferne systemd Units..."; rm -f /etc/systemd/system/hbbs.service /etc/systemd/system/hbbr.service; systemctl daemon-reload
  echo_info "Entferne Dateien..."; rm -rf "$INSTALL_PATH" "$CONFIG_DIR"
  echo_success "RustDesk Server deinstalliert."
}

# --- Installation ---
install_server() {
  echo_info "Installiere RustDesk Server..."
  echo_info "Installiere Pakete (wget unzip curl jq qrencode file xz-utils p7zip-full makeself)..."
  apt-get update &>/dev/null
  apt-get install -y wget unzip curl jq qrencode file xz-utils p7zip-full makeself &>> "$LOG_FILE" || { echo_error "Pakete fehlgeschlagen (siehe $LOG_FILE)"; exit 1; }

  read -rp "Öffentliche Domain (z.B. rustdesk.deine-domain.de): " SERVER_DOMAIN
  [ -z "$SERVER_DOMAIN" ] && { echo_error "Domain leer."; exit 1; }

  if command -v ufw &>/dev/null; then
    read -rp "UFW-Regeln für Ports 21115-21119 setzen? (j/N): " UFW_CHOICE
    [[ "$UFW_CHOICE" =~ ^[jJ]$ ]] && { ufw allow 21115/tcp; ufw allow 21116/tcp; ufw allow 21116/udp; ufw allow 21117/tcp; ufw allow 21118/tcp; ufw allow 21119/tcp; ufw reload; echo_success "UFW angepasst."; }
  fi

  echo_info "Lade neueste rustdesk-server Release..."
  LATEST_VERSION=$(curl -s "https://api.github.com/repos/rustdesk/rustdesk-server/releases/latest" | jq -r .tag_name)
  wget "https://github.com/rustdesk/rustdesk-server/releases/download/${LATEST_VERSION}/rustdesk-server-linux-amd64.zip" -O /tmp/rustdesk-server.zip &>> "$LOG_FILE" || { echo_error "Download fehlgeschlagen."; uninstall_server; exit 1; }
  mkdir -p "$INSTALL_PATH"; unzip -o /tmp/rustdesk-server.zip -d "$INSTALL_PATH" &>> "$LOG_FILE"
  NESTED_PATH=$(find "$INSTALL_PATH" -name hbbs -exec dirname {} \;)
  if [ -n "$NESTED_PATH" ] && [ "$NESTED_PATH" != "$INSTALL_PATH" ]; then mv "${NESTED_PATH}/"* "$INSTALL_PATH/"; find "$INSTALL_PATH" -type d -empty -delete; fi
  rm -f /tmp/rustdesk-server.zip

  echo_info "Erzeuge systemd Units..."
  HBBS_PARAMS="-r ${SERVER_DOMAIN}:21117"; HBBR_PARAMS=""
  cat > /etc/systemd/system/hbbs.service <<EOL
[Unit]
Description=RustDesk ID/Rendezvous Server
After=network-online.target
Requires=network-online.target
[Service]
Type=simple
LimitNOFILE=1048576
ExecStart=${INSTALL_PATH}/hbbs ${HBBS_PARAMS}
WorkingDirectory=${INSTALL_PATH}
Restart=always
[Install]
WantedBy=multi-user.target
EOL
  cat > /etc/systemd/system/hbbr.service <<EOL
[Unit]
Description=RustDesk Relay Server
After=network-online.target
Requires=network-online.target
[Service]
Type=simple
LimitNOFILE=1048576
ExecStart=${INSTALL_PATH}/hbbr ${HBBR_PARAMS}
WorkingDirectory=${INSTALL_PATH}
Restart=always
[Install]
WantedBy=multi-user.target
EOL

  systemctl daemon-reload; systemctl enable hbbs hbbr &>/dev/null
  mkdir -p "$CONFIG_DIR"
  cat > "$CONFIG_FILE" <<EOL
SERVER_DOMAIN="${SERVER_DOMAIN}"
HBBS_PARAMS="${HBBS_PARAMS}"
HBBR_PARAMS="${HBBR_PARAMS}"
EOL

  start_services
  echo_success "Server installiert."
  echo_info "Öffentlicher Schlüssel:"
  echo; sleep 1; cat "${INSTALL_PATH}/id_ed25519.pub"; echo
  read -rp "Weiter mit [Enter]..."
}

# --- Verwaltung ---
load_config() { source "$CONFIG_FILE"; }
start_services() { echo_info "Starte Dienste..."; systemctl start hbbs hbbr; }
stop_services() { echo_info "Stoppe Dienste..."; systemctl stop hbbs hbbr; }
restart_services() { echo_info "Neustart Dienste..."; systemctl restart hbbs hbbr; }
show_logs() { journalctl -u hbbs -u hbbr -f --no-pager; }

update_server() {
  echo_info "Prüfe Updates..."
  LATEST_VERSION=$(curl -s "https://api.github.com/repos/rustdesk/rustdesk-server/releases/latest" | jq -r .tag_name)
  CURRENT_VERSION=$(${INSTALL_PATH}/hbbs --version | awk '{print $2}')
  if [ "$LATEST_VERSION" == "$CURRENT_VERSION" ]; then echo_info "Schon aktuell ($CURRENT_VERSION)."
  else
    read -rp "Update auf $LATEST_VERSION durchführen? (j/N): " OK
    if [[ "$OK" =~ ^[jJ]$ ]]; then
      stop_services
      wget "https://github.com/rustdesk/rustdesk-server/releases/download/${LATEST_VERSION}/rustdesk-server-linux-amd64.zip" -O /tmp/rustdesk-server.zip &>> "$LOG_FILE"
      unzip -o /tmp/rustdesk-server.zip -d "$INSTALL_PATH/amd64" &>> "$LOG_FILE"
      mv "$INSTALL_PATH/amd64/"* "$INSTALL_PATH/"; rm -rf /tmp/rustdesk-server.zip "$INSTALL_PATH/amd64"
      start_services; echo_success "Aktualisiert auf $LATEST_VERSION."
    fi
  fi
}

edit_parameters() {
  echo_info "Öffne $CONFIG_FILE (nano)..."
  nano "$CONFIG_FILE"
  read -rp "Dienste neu starten? (j/N): " R
  if [[ "$R" =~ ^[jJ]$ ]]; then
    load_config
    sed -i "s|ExecStart=.*|ExecStart=${INSTALL_PATH}/hbbs ${HBBS_PARAMS}|" /etc/systemd/system/hbbs.service
    sed -i "s|ExecStart=.*|ExecStart=${INSTALL_PATH}/hbbr ${HBBR_PARAMS}|" /etc/systemd/system/hbbr.service
    systemctl daemon-reload; restart_services; echo_success "Übernommen."
  fi
}

reset_parameters() {
  load_config; HBBS_PARAMS_DEFAULT="-r ${SERVER_DOMAIN}:21117"; HBBR_PARAMS_DEFAULT=""
  sed -i "s|HBBS_PARAMS=.*|HBBS_PARAMS=\"${HBBS_PARAMS_DEFAULT}\"|" "$CONFIG_FILE"
  sed -i "s|HBBR_PARAMS=.*|HBBR_PARAMS=\"${HBBR_PARAMS_DEFAULT}\"|" "$CONFIG_FILE"
  echo_success "Standardwerte gesetzt."; edit_parameters
}

generate_new_key() {
  echo_warning "Neuer Schlüssel trennt ALLE Clients!"
  read -rp "Sicher? 'JA' eingeben: " OK; [ "$OK" != "JA" ] && { echo_info "Abgebrochen."; return; }
  stop_services
  mv "${INSTALL_PATH}/id_ed25519" "${INSTALL_PATH}/id_ed25519.bak" 2>/dev/null
  mv "${INSTALL_PATH}/id_ed25519.pub" "${INSTALL_PATH}/id_ed25519.pub.bak" 2>/dev/null
  start_services
  echo_success "Neuer Schlüssel generiert:"; cat "${INSTALL_PATH}/id_ed25519.pub"
}

# ------------------------------------------------------------
# Helpers für Client-Build
# ------------------------------------------------------------

# GitHub-Asset laden
download_latest_client_asset() {
  local PATTERN="$1" OUTFILE="$2"
  local API_URL="https://api.github.com/repos/rustdesk/rustdesk/releases/latest"

  # Pattern als Variable an jq übergeben -> keine Escape-Probleme
  local URL
  URL=$(curl -sL "$API_URL" | jq -r --arg re "$PATTERN" '
    .assets[] | select(.name | test($re)) | .browser_download_url
  ' | head -n1)

  if [ -z "$URL" ] || [ "$URL" = "null" ]; then
    echo_error "Asset nicht gefunden: $PATTERN"
    return 1
  fi

  echo_info "Lade $(basename "$URL")"
  wget --show-progress -O "$OUTFILE" "$URL" || return 1
}


# TOML für Server erzeugen (immer frisch -> Schlüssel/Domain-Änderungen greifen)
write_server_toml() {
  local OUT="$1" HOST="$2" KEY="$3"
  cat > "$OUT" <<EOF
[server]
host = "${HOST}"
key  = "${KEY}"
EOF
}

# 7-Zip SFX bauen (führt NUR Programm aus; SFX löscht Temp danach)
# RunProgram/ExecuteParameters lt. 7-Zip Doku. %T = Temp-Ordner.  (SFX entfernt Temp nach Programmende)
# Quelle: 7-Zip SFX-Doku. :contentReference[oaicite:2]{index=2}
build_windows_sfx() {
  local PAYLOAD_DIR="$1" OUT_EXE="$2" RUNLINE="$3"

  # Bevorzuge das GUI-Modul (7zS.sfx)
  local SFX_MODULE=""
  for cand in /usr/lib/p7zip/7zS.sfx /usr/lib/p7zip/7z.sfx /usr/lib/p7zip/7zCon.sfx; do
    if [ -f "$cand" ]; then SFX_MODULE="$cand"; break; fi
  done
  if [ -z "$SFX_MODULE" ]; then
    echo_error "SFX-Modul nicht gefunden (installiere: p7zip-full)."
    return 1
  fi

  # Archiv bauen
  ( cd "$PAYLOAD_DIR" && 7z a -mx9 -bd -t7z payload.7z . >/dev/null ) || return 1

  # Nur RunProgram verwenden – Parameter gehören mit in die gleiche Zeile
  cat > "$PAYLOAD_DIR/sfx_config.txt" <<EOF
;!@Install@!UTF-8!
GUIMode="2"
Title="RustDesk One-File"
RunProgram=${RUNLINE}
;!@InstallEnd@!
EOF

  # Zusammenfügen
  cat "$SFX_MODULE" "$PAYLOAD_DIR/sfx_config.txt" "$PAYLOAD_DIR/payload.7z" > "$OUT_EXE" || return 1
  chmod +x "$OUT_EXE"
  return 0
}



# makeself-Wrapper (extrahiert -> führt Befehl -> räumt auf)
build_linux_makeself() {
  local PAYLOAD_DIR="$1" OUT_FILE="$2" START_CMD="$3"
  makeself --quiet --nox11 "$PAYLOAD_DIR" "$OUT_FILE" "RustDesk One-File" bash -lc "$START_CMD"
}

# Android QR generieren (offizielles Format) :contentReference[oaicite:3]{index=3}
build_android_qr() {
  local HOST="$1" KEY="$2" OUTPNG="$3" OUTJSON="$4"
  echo "{\"host\":\"${HOST}\",\"key\":\"${KEY}\"}" > "$OUTJSON"
  qrencode -o "$OUTPNG" "config=$(cat "$OUTJSON")"
}

# ------------------------------------------------------------
# Client-Erstellung (ohne Batch/PS1, nur temporär, auto-clean)
# ------------------------------------------------------------

create_client_package() {
  local OS_TYPE="$1"
  echo_info "Erstelle Client für ${OS_TYPE}…"
  load_config
  local PUBKEY; PUBKEY=$(cat "${INSTALL_PATH}/id_ed25519.pub")
  mkdir -p "$CLIENT_DIR"

  case "$OS_TYPE" in
    Windows)
      local TMP; TMP="$(mktemp -d)"
      local OUT="${CLIENT_DIR}/RustDesk_${SERVER_DOMAIN}_Windows.exe"
      local PUBKEY; PUBKEY=$(cat "${INSTALL_PATH}/id_ed25519.pub")
    
      echo_info "Baue Windows One-File-Client…"
      download_latest_client_asset "x86_64\\.exe$" "${TMP}/rustdesk.exe" || { rm -rf "$TMP"; return 1; }
      mkdir -p "${TMP}/config"
      write_server_toml "${TMP}/config/RustDesk2.toml" "$SERVER_DOMAIN" "$PUBKEY"
    
      # Wichtig: ALLES in derselben RunProgram-Zeile, korrekt gequotet.
      # SFX startet im Entpack-Ordner -> relative Pfade funktionieren.
      # Keine Batch, kein PowerShell – nur Prozessstart mit Parametern.
      local RUNLINE="\"\\\"rustdesk.exe\\\" --import-config config\\\\RustDesk2.toml\""
    
      build_windows_sfx "$TMP" "$OUT" "$RUNLINE" || { rm -rf "$TMP"; return 1; }
      rm -rf "$TMP"
      echo_success "Windows One-File erstellt: $OUT"
      ;;

    Linux)
      local TMP; TMP="$(mktemp -d)"
      local OUT="${CLIENT_DIR}/RustDesk_${SERVER_DOMAIN}_Linux.run"
      download_latest_client_asset "x86_64\\.AppImage$" "${TMP}/rustdesk.AppImage" || { rm -rf "$TMP"; return 1; }
      chmod +x "${TMP}/rustdesk.AppImage"
      mkdir -p "${TMP}/config"; write_server_toml "${TMP}/config/RustDesk2.toml" "$SERVER_DOMAIN" "$PUBKEY"
      # makeself startet AppImage mit Import, danach Ende -> makeself säubert Temp
      build_linux_makeself "$TMP" "$OUT" "./rustdesk.AppImage --import-config ./config/RustDesk2.toml" || { rm -rf "$TMP"; return 1; }
      rm -rf "$TMP"; echo_success "Linux One-File erstellt: $OUT"
      ;;

    macOS)
      # One-File .sh: lädt DMG, mountet, startet RustDesk direkt vom DMG mit --import-config, unmountet. Keine dauerhafte Installation.
      local OUT="${CLIENT_DIR}/RustDesk_${SERVER_DOMAIN}_macOS_OneFile.sh"
      cat > "$OUT" <<'EOSH'
#!/bin/bash
set -euo pipefail
if ! command -v curl >/dev/null; then echo "curl fehlt"; exit 1; fi
if ! command -v hdiutil >/dev/null; then echo "hdiutil fehlt"; exit 1; fi
TMPDIR="$(mktemp -d)"; trap 'hdiutil detach "$MP" >/dev/null 2>&1 || true; rm -rf "$TMPDIR"' EXIT
echo "Lade RustDesk DMG…"
DMG_URL=$(curl -s https://api.github.com/repos/rustdesk/rustdesk/releases/latest | /usr/bin/python3 - <<'PY'
import sys, json, re
data=json.load(sys.stdin)
for a in data.get("assets",[]):
    n=a.get("name","")
    if re.search(r"mac.*(x86_64|aarch64).*\.dmg$", n, re.I):
        print(a["browser_download_url"]); break
PY
)
[ -z "$DMG_URL" ] && { echo "Kein DMG gefunden"; exit 1; }
curl -L "$DMG_URL" -o "$TMPDIR/rustdesk.dmg"
echo "Mounten…"
MP=$(hdiutil attach "$TMPDIR/rustdesk.dmg" -nobrowse | awk '/Volumes/ {print $3; exit}')
echo "Starte RustDesk mit Import…"
/usr/bin/python3 - <<'PY'
import os, subprocess, time, shlex, sys
cfg = """__RDTOML__"""
cfg_path = os.path.join(os.environ["TMPDIR"] if "TMPDIR" in os.environ else "/tmp","RustDesk2.toml")
open(cfg_path,"w").write(cfg)
# Pfad zur Binärdatei im .app
app_bin = os.path.join(os.environ["MP"], "RustDesk.app/Contents/MacOS/RustDesk")
cmd = [app_bin, "--import-config", cfg_path]
p = subprocess.Popen(cmd)
p.wait()
PY
echo "Unmounten…"
EOSH
      # TOML einbetten
      local TOML; TOML=$(printf '[server]\nhost = "%s"\nkey  = "%s"\n' "$SERVER_DOMAIN" "$PUBKEY")
      # sichere Ersetzung (keine Slashes kaputt machen)
      awk -v toml="$TOML" '{gsub(/__RDTOML__/,toml); print}' "$OUT" > "${OUT}.tmp" && mv "${OUT}.tmp" "$OUT"
      chmod +x "$OUT"
      echo_success "macOS One-File erstellt: $OUT"
      ;;

    Android)
      mkdir -p "$CLIENT_DIR/android"
      build_android_qr "$SERVER_DOMAIN" "$PUBKEY" "${CLIENT_DIR}/android/android_config_qr.png" "${CLIENT_DIR}/android/android_config.json"
      echo_success "Android: QR & JSON erzeugt unter ${CLIENT_DIR}/android/"
      echo_info "Android: App öffnen → Menü → Server → QR scannen. (Offizielle Methode.)"
      ;;

  esac
}

show_qr_code() {
  load_config
  local PUBKEY; PUBKEY=$(cat "${INSTALL_PATH}/id_ed25519.pub")
  local CONFIG_STRING="config={\"host\":\"${SERVER_DOMAIN}\",\"key\":\"${PUBKEY}\"}"
  echo_info "QR (Android/iOS) – mit Handy in RustDesk scannen:"
  qrencode -t ansiutf8 "$CONFIG_STRING"
}

start_download_server() {
  command -v python3 >/dev/null || { echo_error "Python3 fehlt."; return; }
  [ -d "$CLIENT_DIR" ] || mkdir -p "$CLIENT_DIR"
  IP_ADDR=$(hostname -I | awk '{print $1}'); PORT=8000
  echo_info "HTTP-Download unter: http://${IP_ADDR}:${PORT}"
  echo_warning "STRG+C beendet."
  ( cd "$CLIENT_DIR" && python3 -m http.server $PORT )
}

# --- Menüs ---

client_menu() {
  while true; do
    clear
    echo "--------------------------------------------------"
    echo "  Client-Pakete erstellen"
    echo "--------------------------------------------------"
    echo "  1) Alle: Windows (SFX), Linux (.run), macOS (.sh), Android (QR)"
    echo "  2) Nur Windows (SFX .exe)"
    echo "  3) Nur macOS (OneFile .sh)"
    echo "  4) Nur Linux (OneFile .run)"
    echo "  5) Nur Android (QR/JSON)"
    echo "  6) QR-Code in Konsole anzeigen"
    echo "  7) Download-Server starten"
    echo "  0) Zurück"
    echo "--------------------------------------------------"
    read -rp "Auswahl: " choice
    case $choice in
      1) create_client_package Windows; create_client_package Linux; create_client_package macOS; create_client_package Android ;;
      2) create_client_package Windows ;;
      3) create_client_package macOS ;;
      4) create_client_package Linux ;;
      5) create_client_package Android ;;
      6) show_qr_code ;;
      7) start_download_server ;;
      0) break ;;
      *) echo_error "Ungültig." ;;
    esac
    read -rp "Weiter mit [Enter]..."
  done
}

main_menu() {
  while true; do
    load_config 2>/dev/null || true
    HBBS_STATUS=$(systemctl is-active hbbs 2>/dev/null); HBBR_STATUS=$(systemctl is-active hbbr 2>/dev/null)
    clear
    echo "--------------------------------------------------"
    echo "  RustDesk Server Manager (RDSM)"
    echo "--------------------------------------------------"
    echo -e "  Domain: ${C_YELLOW}${SERVER_DOMAIN:-<nicht gesetzt>}${C_RESET}"
    echo -e "  Status: hbbs [${HBBS_STATUS:-n/a}] | hbbr [${HBBR_STATUS:-n/a}]"
    echo "--------------------------------------------------"
    echo "  1) Server starten"
    echo "  2) Server stoppen"
    echo "  3) Server neustarten"
    echo "  4) Live-Logs"
    echo "  5) 🛠️  Client-Pakete erstellen"
    echo "  6) Startparameter bearbeiten"
    echo "  7) Standard-Parameter wiederherstellen"
    echo "  8) 🔑  Neuen Sicherheitsschlüssel generieren"
    echo "  9) Server-Software aktualisieren"
    echo " 10) ALLES deinstallieren"
    echo "  0) Beenden"
    echo "--------------------------------------------------"
    read -rp "Auswahl: " choice
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
      10) read -rp "Gib 'JA' ein: " C; [ "$C" = "JA" ] && { uninstall_server; exit 0; } || echo_info "Abgebrochen." ;;
      0) exit 0 ;;
      *) echo_error "Ungültig." ;;
    esac
    [[ "$choice" != "4" ]] && read -rp "Weiter mit [Enter]..."
  done
}

recovery_menu() {
  clear
  echo "--------------------------------------------------"
  echo -e "  ${C_YELLOW}WARNUNG: Unvollständige Installation erkannt!${C_RESET}"
  echo "--------------------------------------------------"
  echo "  1) Sauber entfernen (empfohlen) & neu installieren"
  echo "  2) Trotzdem neu installieren"
  echo "  0) Beenden"
  echo "--------------------------------------------------"
  read -rp "Auswahl: " choice
  case $choice in
    1) uninstall_server; install_server ;;
    2) uninstall_server; install_server ;;
    0) exit 0 ;;
    *) echo_error "Ungültig." ;;
  esac
}

# --- Start ---
check_root
STATE=$(check_installation_state)
case $STATE in
  "SAUBER") read -rp "Willkommen bei RDSM v0.6. Jetzt installieren? (J/n): " A; if [[ -z "$A" || "$A" =~ ^[jJ]$ ]]; then install_server; main_menu; else echo_info "Abbruch."; fi ;;
  "VOLLSTÄNDIG") main_menu ;;
  "FEHLGESCHLAGEN") recovery_menu ;;
esac
exit 0
