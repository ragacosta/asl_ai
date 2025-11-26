#!/usr/bin/env bash
set -euo pipefail
# install_full_rpi5_v2.sh
# Instalador mejorado para ASL_AI en Raspberry Pi 5 (64-bit)
# - Autodetección de tarjeta USB (arecord -l)
# - /etc/asound.conf apuntando a la tarjeta correcta (evita dmix/plug)
# - Crea venv, instala dependencias
# - Crea servicios systemd (core + web) con opción de silenciar stderr
# - Crea config.yaml mínimo si falta
#
# Ejecútalo como root (sudo)

ROOT_DIR="/usr/local/asl_ai"
VENV_DIR="${ROOT_DIR}/venv"
SRC_DIR="${ROOT_DIR}"
USER_NAME="admin"
SILENCE_JOURNAL=true   # si quieres ver stderr en journal, cambia a false

# Paquetes del sistema mínimos (adaptar si ya los tienes instalados)
SYSTEM_PACKAGES=(
  python3 python3-venv python3-pip build-essential git wget curl sox \
  libasound2-dev portaudio19-dev libportaudio2 libportaudiocpp0 \
  libpulse-dev ffmpeg
)

echo
echo ">> Instalador ASL_AI - versión corregida (rpi5)"
echo ">> ROOT_DIR = ${ROOT_DIR}"
echo

# 1) Actualizar e instalar paquetes
echo "-> instalando paquetes del sistema (si faltan)..."
apt-get update -y
apt-get install -y "${SYSTEM_PACKAGES[@]}"

# 2) Crear usuario/dirs
echo "-> creando directorios..."
mkdir -p "${ROOT_DIR}"
chown -R "${USER_NAME}:${USER_NAME}" "${ROOT_DIR}"
chmod 755 "${ROOT_DIR}"

# 3) Añadir user al grupo audio
echo "-> añadiendo ${USER_NAME} al grupo audio..."
usermod -aG audio "${USER_NAME}" || true

# 4) Detectar tarjeta USB para captura (arecord -l)
echo "-> detectando tarjeta de captura USB (arecord -l)..."
USB_CARD=""
USB_DEVICE=""
if command -v arecord >/dev/null 2>&1; then
    # buscamos primera tarjeta que contenga "USB" o tenga subdevice(s)
    while IFS= read -r line; do
        if [[ "$line" =~ card[[:space:]]([0-9]+):[[:space:]](.+)\ \[USB ]]; then
            USB_CARD="${BASH_REMATCH[1]}"
        fi
    done < <(arecord -l 2>/dev/null || true)

    # Fallback: si no encuentra "USB" buscar card con subdevice capture
    if [ -z "${USB_CARD}" ]; then
        # parse simple: card N: ... device M: ... with "CAPTURE" or "subdevices: 1/1"
        # We'll pick first card that has "CAPTURE Hardware Devices" entry
        # Simpler: pick first card that is not "vc4" (hdmi) if possible
        CARDS_OUT="$(cat /proc/asound/cards 2>/dev/null || true)"
        # Try to choose first non-hdmi card number
        if echo "${CARDS_OUT}" | grep -qi usb; then
            USB_CARD="$(echo "${CARDS_OUT}" | grep -i usb -n | head -n1 | awk '{print $1}')"
        fi
    fi

    # Final fallback default 0
    if [ -z "${USB_CARD}" ]; then
        # find first card that is not vc4-hdmi
        USB_CARD="$(awk '/\[/ {print NR-1}' <(cat /proc/asound/cards) | head -n1 || true)"
        # If still empty, set 0
        if [ -z "${USB_CARD}" ]; then
            USB_CARD=0
        fi
    fi
else
    echo "WARNING: arecord no está disponible; configurando card 0 por defecto."
    USB_CARD=0
fi

echo "-> tarjeta detectada: card ${USB_CARD}"

# 5) Escribir /etc/asound.conf para usar hw:USB_CARD,0 como default (evita dmix/dsnoop)
ASOUND_CONF="/etc/asound.conf"
echo "-> generando ${ASOUND_CONF} apuntando a card ${USB_CARD}..."
cat > "${ASOUND_CONF}.tmp" <<EOF
pcm.!default {
  type hw
  card ${USB_CARD}
  device 0
}
ctl.!default {
  type hw
  card ${USB_CARD}
}
EOF
# Solo sobrescribimos si cambia
if ! cmp -s "${ASOUND_CONF}.tmp" "${ASOUND_CONF}" 2>/dev/null; then
    mv "${ASOUND_CONF}.tmp" "${ASOUND_CONF}"
    echo "  /etc/asound.conf actualizado."
else
    rm -f "${ASOUND_CONF}.tmp"
    echo "  /etc/asound.conf ya está correcto."
fi

# 6) Clonar repo si no existe (opcional)
if [ ! -d "${ROOT_DIR}/.git" ]; then
    echo "-> clonando repo (si procede)..."
    if [ -z "${GIT_REPO:-}" ]; then
        GIT_REPO="https://github.com/ragacosta/asl_ai.git"
    fi
    if ! id "${USER_NAME}" >/dev/null 2>&1; then
        echo "User ${USER_NAME} no existe; crea el usuario antes e intenta de nuevo."
    else
        # clone only if dir appears vacío
        if [ -z "$(ls -A "${ROOT_DIR}")" ]; then
            sudo -u "${USER_NAME}" git clone "${GIT_REPO}" "${ROOT_DIR}"
        else
            echo "-> ${ROOT_DIR} no vacío; no clono."
        fi
    fi
fi

# 7) Crear venv e instalar requirements
echo "-> creando virtualenv en ${VENV_DIR}..."
python3 -m venv "${VENV_DIR}" || true
# Ensure pip up to date
"${VENV_DIR}/bin/pip" install --upgrade pip setuptools wheel >/dev/null 2>&1 || true

# Requirements: incluye pyaudio, vosk, pvporcupine opcional, prometheus_client, soundfile si hace falta
REQS=(
  wheel
  pip
  soundfile
  vosk
  pyaudio
  numpy
  PyYAML
  prometheus_client
)

echo "-> instalando paquetes pip (puede tardar)..."
"${VENV_DIR}/bin/pip" install "${REQS[@]}"

# 8) Descargar modelo VOSK si no existe (ajusta la URL si quieres otro modelo)
VOSK_DIR="${ROOT_DIR}/vosk"
MODEL_NAME="${VOSK_MODEL:-vosk-model-small-es-0.42}"
MODEL_PATH="${VOSK_DIR}/${MODEL_NAME}"
if [ ! -d "${MODEL_PATH}" ]; then
    echo "-> Descargando modelo VOSK (${MODEL_NAME})... (esto puede tardar mucho)"
    mkdir -p "${VOSK_DIR}"
    cd "${VOSK_DIR}"
    # URL known for small es model (user can replace if different)
    MODEL_URL="https://alphacephei.com/vosk/models/${MODEL_NAME}.zip"
    # Try download if accessible
    if command -v wget >/dev/null 2>&1; then
        wget -q --show-progress "${MODEL_URL}" -O "${MODEL_NAME}.zip" || true
    else
        curl -L "${MODEL_URL}" -o "${MODEL_NAME}.zip" || true
    fi
    if [ -f "${MODEL_NAME}.zip" ]; then
        unzip -q "${MODEL_NAME}.zip"
        rm -f "${MODEL_NAME}.zip"
        echo "  Modelo VOSK descargado."
    else
        echo "  No se pudo descargar el modelo VOSK automáticamente. Puedes hacerlo manualmente y colocarlo en ${MODEL_PATH}"
    fi
fi

# 9) Escribir config.yaml mínimo si no existe
CFG_FILE="${ROOT_DIR}/config.yaml"
if [ ! -f "${CFG_FILE}" ]; then
    echo "-> generando config.yaml mínimo en ${CFG_FILE}"
    cat > "${CFG_FILE}" <<EOF
node_num: null
sounds_dir: /var/lib/asterisk/sounds
vosk_model: ${MODEL_PATH}
listen_rate: 16000
chunk: 3072
google_credentials: /usr/local/asl_ai/credentials/google_tts.json
porcupine: {}
openweather_key: null
EOF
    chown "${USER_NAME}:${USER_NAME}" "${CFG_FILE}"
fi

# 10) Crear servicio systemd (core)
SERVICE_FILE="/etc/systemd/system/asl-ai.service"
echo "-> creando servicio systemd: ${SERVICE_FILE}"
if [ "${SILENCE_JOURNAL}" = true ] ; then
    # ExecStart silencia stderr antes de ejecutar Python
    EXEC_CMD="/usr/bin/bash -c 'exec 2>/dev/null; exec ${VENV_DIR}/bin/python ${ROOT_DIR}/asl_ai_core.py'"
else
    EXEC_CMD="${VENV_DIR}/bin/python ${ROOT_DIR}/asl_ai_core.py"
fi

cat > "${SERVICE_FILE}" <<EOF
[Unit]
Description=IA AllStarLink Core
After=network.target sound.target

[Service]
Type=simple
User=${USER_NAME}
WorkingDirectory=${ROOT_DIR}
Environment=GOOGLE_APPLICATION_CREDENTIALS=${ROOT_DIR}/credentials/google_tts.json
ExecStart=${EXEC_CMD}
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

# 11) Crear servicio systemd (web) - si existe web app
SERVICE_WEB="/etc/systemd/system/asl-ai-web.service"
echo "-> creando servicio systemd web: ${SERVICE_WEB}"
if [ "${SILENCE_JOURNAL}" = true ] ; then
    EXEC_WEB="/usr/bin/bash -c 'exec 2>/dev/null; exec ${VENV_DIR}/bin/python ${ROOT_DIR}/asl_ai_web.py'"
else
    EXEC_WEB="${VENV_DIR}/bin/python ${ROOT_DIR}/asl_ai_web.py"
fi

cat > "${SERVICE_WEB}" <<EOF
[Unit]
Description=IA AllStarLink Web
After=network.target

[Service]
Type=simple
User=${USER_NAME}
WorkingDirectory=${ROOT_DIR}
ExecStart=${EXEC_WEB}
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

# 12) Permisos y owner
echo "-> ajustando permisos..."
chown -R "${USER_NAME}:${USER_NAME}" "${ROOT_DIR}"
chmod -R 755 "${ROOT_DIR}"

# 13) systemd daemon-reload & enable services
echo "-> recargando systemd y habilitando servicios..."
systemctl daemon-reload
systemctl enable asl-ai.service || true
systemctl enable asl-ai-web.service || true

# 14) Mensajes finales y sugerencias
echo
echo "=== INSTALACIÓN COMPLETA (acciones recomendadas) ==="
echo "1) Revisa /etc/asound.conf (apunta a card ${USB_CARD})"
echo "2) Asegúrate de que ${USER_NAME} cerró sesión para aplicar grupo audio"
echo "3) Revisa ${CFG_FILE} y ajusta rutas/credenciales"
echo "4) Inicia los servicios:"
echo "     sudo systemctl start asl-ai.service"
echo "     sudo systemctl start asl-ai-web.service"
echo "5) Para debug (foreground):"
echo "     sudo -u ${USER_NAME} ${VENV_DIR}/bin/python ${ROOT_DIR}/asl_ai_core.py"
echo
echo "Si quieres que también coloque las versiones corregidas de asl_ai_core.py y asl_ai_web.py,"
echo "responde y las escribo automáticamente dentro de ${ROOT_DIR} (att: correciones audio/resample/porcupine)."
echo

exit 0
