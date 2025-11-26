#!/bin/bash
set -euo pipefail

# install_full_rpi5.sh
# Versión corregida y optimizada para Raspberry Pi 5 (64-bit, aarch64).
# Crea: entorno, instala dependencias, descarga VOSK, configura porcupine checks y systemd services.
#
# USO:
#   sudo bash install_full_rpi5.sh /ruta/credenciales_google.json
#
# Nota: requiere que coloques tu .ppn (wake-word) y porcupine_params.pv en /usr/local/asl_ai/porcupine
#       o que indiques las rutas cuando se te solicite.

ROOT_DIR=/usr/local/asl_ai
RUN_AS_USER="admin"   # Cambia si tu usuario en la Pi no es "pi"
VENV_PYTHON="python3"
VENV_DIR="$ROOT_DIR/venv"

if [ "$EUID" -ne 0 ]; then
  echo "Ejecuta este script como root (sudo)."
  exit 1
fi

if [ "$#" -lt 1 ]; then
  echo "Uso: sudo bash $0 /ruta/google_tts_credentials.json"
  exit 1
fi

GOOGLE_JSON_SRC="$1"

if [ ! -f "$GOOGLE_JSON_SRC" ]; then
  echo "ERROR: Archivo de credenciales Google no encontrado: $GOOGLE_JSON_SRC"
  exit 1
fi

mkdir -p "$ROOT_DIR"
chown -R "$RUN_AS_USER":"$RUN_AS_USER" "$ROOT_DIR"
cd "$ROOT_DIR"

echo "Instalador optimizado para Raspberry Pi 5 (64-bit - aarch64)"
echo

read -p "Número de nodo AllStar (por ejemplo 12345): " NODE_NUM
NODE_NUM=${NODE_NUM:-"12345"}

read -p "Usuario AMI [amiuser]: " AMI_USER
AMI_USER=${AMI_USER:-"amiuser"}
read -s -p "Clave AMI: " AMI_PASS
echo
read -p "Host AMI (IP o host): " AMI_HOST
AMI_HOST=${AMI_HOST:-"127.0.0.1"}

read -p "Usuario systemd para ejecutar servicios [$RUN_AS_USER]: " UA
UA=${UA:-$RUN_AS_USER}
RUN_AS_USER="$UA"

read -p "Porcupine Access Key (PICOVOICE) (obligatorio): " PORCUPINE_ACCESS_KEY
if [ -z "$PORCUPINE_ACCESS_KEY" ]; then
  echo "ERROR: Necesitas la access key de Picovoice para Porcupine."
  exit 1
fi

# Paquetes del sistema
apt update
DEBIAN_FRONTEND=noninteractive apt install -y --no-install-recommends \
  build-essential sox ffmpeg python3-pip python3-venv python3-dev \
  libatlas-base-dev libasound2-dev unzip wget curl git

# Crear y activar virtualenv como usuario objetivo
if [ ! -d "$VENV_DIR" ]; then
  sudo -u "$RUN_AS_USER" $VENV_PYTHON -m venv "$VENV_DIR"
fi

# Asegurarse de usar pip del virtualenv
PIP="$VENV_DIR/bin/pip"
PY="$VENV_DIR/bin/python"

# Upgrade pip & instalacion de paquetes Python
"$PIP" install --upgrade pip setuptools wheel
"$PIP" install vosk google-cloud-texttospeech pyaudio flask prometheus_client requests watchdog PyYAML

# pvporcupine: instalación opcional — en ARM64 puede requerir instalar desde wheel o fuente.
# Intentamos instalar pvporcupine si hay wheel disponible; si falla, avisamos al usuario.
if ! "$PIP" install pvporcupine; then
  echo "Aviso: instalación de pvporcupine falló. Es posible que necesites instalar el paquete manualmente para aarch64."
  echo "Consulta: https://picovoice.ai/docs/porcupine"
fi

# Copiar credenciales Google
mkdir -p "$ROOT_DIR/credentials"
cp "$GOOGLE_JSON_SRC" "$ROOT_DIR/credentials/google_tts.json"
chmod 600 "$ROOT_DIR/credentials/google_tts.json"
chown -R "$RUN_AS_USER":"$RUN_AS_USER" "$ROOT_DIR/credentials"

# Crear config.yaml con valores seguros
cat > "$ROOT_DIR/config.yaml" <<EOF
node_num: "$NODE_NUM"
ami:
  host: "$AMI_HOST"
  user: "$AMI_USER"
  pass: "$AMI_PASS"
porcupine:
  access_key: "$PORCUPINE_ACCESS_KEY"
  library_path: ""
  model_path: ""
  keyword_path: ""
  sensitivities: 0.6
vosk_model: $ROOT_DIR/vosk/vosk-model-small-es-0.42
sounds_dir: /var/lib/asterisk/sounds
google_credentials: $ROOT_DIR/credentials/google_tts.json
listen_rate: 16000
chunk: 1024
openweather_key: ""
chatgpt_key: ""
web_port: 8083
EOF

chown "$RUN_AS_USER":"$RUN_AS_USER" "$ROOT_DIR/config.yaml"
chmod 640 "$ROOT_DIR/config.yaml"

# Descargar y extraer VOSK modelo (si no existe)
mkdir -p "$ROOT_DIR/vosk"
if [ ! -d "$ROOT_DIR/vosk/vosk-model-small-es-0.42" ]; then
  cd "$ROOT_DIR/vosk"
  echo "Descargando modelo VOSK (small esp)..."
  wget -q https://alphacephei.com/vosk/models/vosk-model-small-es-0.42.zip -O vosk-model-small-es-0.42.zip
  echo "Extrayendo..."
  unzip -o vosk-model-small-es-0.42.zip -d .
  # Algunos zips vienen con carpeta adicional; normalizamos:
  # Buscar carpeta que contenga 'model-...'
  if [ -d "vosk-model-small-es-0.42" ]; then
    echo "VOSK model ubicado en $ROOT_DIR/vosk/vosk-model-small-es-0.42"
  else
    # Mover la primera carpeta que empiece con vosk-model-small-es-0.42*
    first_dir=$(find . -maxdepth 1 -type d -name "vosk-model-small-es-0.42*" | head -n1)
    if [ -n "$first_dir" ]; then
      mv "$first_dir" vosk-model-small-es-0.42
    fi
  fi
  rm -f vosk-model-small-es-0.42.zip
fi

# Crear carpeta porcupine y recordatorio para el usuario
mkdir -p "$ROOT_DIR/porcupine"
chown -R "$RUN_AS_USER":"$RUN_AS_USER" "$ROOT_DIR/porcupine"

echo
echo "== Porcupine =="
echo "Coloca tu wake-word .ppn y porcupine_params.pv en:"
echo "  $ROOT_DIR/porcupine/"
echo "Ejemplo de nombres esperados por el servicio:"
echo "  porcupine_params.pv"
echo "  <Miwake>.ppn"
echo

# Intentamos detectar la ruta de libpv_porcupine.so dentro del venv o en /usr/local/lib
LIB_PV_CANDIDATES=(
  "$VENV_DIR/lib/python*/site-packages/pvporcupine/lib/linux/aarch64/libpv_porcupine.so"
  "$VENV_DIR/lib/python*/site-packages/pvporcupine/lib/raspberry-pi/cortex-a76-aarch64/libpv_porcupine.so"
  "/usr/local/lib/libpv_porcupine.so"
  "/usr/lib/libpv_porcupine.so"
)

FOUND_LIB=""
for p in "${LIB_PV_CANDIDATES[@]}"; do
  f=$(ls $p 2>/dev/null | head -n1 || true)
  if [ -n "$f" ]; then
    FOUND_LIB="$f"
    break
  fi
done

if [ -n "$FOUND_LIB" ]; then
  echo "Se detectó libpv_porcupine: $FOUND_LIB"
  # Actualizar config.yaml con la ruta detectada
  sed -i "s|library_path: \"\"|library_path: \"$FOUND_LIB\"|" "$ROOT_DIR/config.yaml"
else
  echo "No se detectó libpv_porcupine.so automáticamente."
  echo "Si ya tienes el archivo .so, cópialo a /usr/local/lib/ y rerun este script o actualiza $ROOT_DIR/config.yaml manualmente."
fi

# Intentar detectar porcupine_params.pv y una .ppn en la carpeta porcupine
found_pv=$(find "$ROOT_DIR/porcupine" -maxdepth 1 -type f -name "porcupine_params.*" -print -quit || true)
found_ppn=$(find "$ROOT_DIR/porcupine" -maxdepth 1 -type f -name "*.ppn" -print -quit || true)
if [ -n "$found_pv" ]; then
  sed -i "s|model_path: \"\"|model_path: \"$found_pv\"|" "$ROOT_DIR/config.yaml"
fi
if [ -n "$found_ppn" ]; then
  sed -i "s|keyword_path: \"\"|keyword_path: \"$found_ppn\"|" "$ROOT_DIR/config.yaml"
fi

# Copiar scripts corregidos al ROOT_DIR
cat > "$ROOT_DIR/asl_ai_core.py" <<'PY'
#!/usr/bin/env python3
# -*- coding:utf-8 -*-

import os, time, json, subprocess, logging, yaml
import pyaudio
from vosk import Model, KaldiRecognizer
from pvporcupine import Porcupine
from google.cloud import texttospeech
from prometheus_client import Counter, Gauge, start_http_server
from logging.handlers import RotatingFileHandler

# -------------------------------------------------------------------
# LOGGING
# -------------------------------------------------------------------
logger = logging.getLogger("asl_ai")
logger.setLevel(logging.INFO)
fh = RotatingFileHandler("/var/log/asl_ai.log", maxBytes=5*1024*1024, backupCount=5)
fmt = logging.Formatter("%(asctime)s %(levelname)s %(message)s")
fh.setFormatter(fmt)
logger.addHandler(fh)

logger.info("ASL_AI CORE iniciar con autodetección de audio…")

# -------------------------------------------------------------------
# MÉTRICAS
# -------------------------------------------------------------------
REQ_COUNTER = Counter('asl_ai_requests_total', 'Total requests received via wakeword')
ERR_COUNTER = Counter('asl_ai_errors_total', 'Total errors')
LAST_REQ = Gauge('asl_ai_last_request_timestamp', 'Timestamp of last request')

# -------------------------------------------------------------------
# CONFIG
# -------------------------------------------------------------------
with open('/usr/local/asl_ai/config.yaml', 'r') as f:
    cfg = yaml.safe_load(f)

NODE_NUM = cfg.get('node_num')
VOSK_MODEL_PATH = cfg.get('vosk_model')
SOUNDS_DIR = cfg.get('sounds_dir')
RATE = cfg.get('listen_rate', 16000)
CHUNK = cfg.get('chunk', 1024)

os.environ['GOOGLE_APPLICATION_CREDENTIALS'] = cfg.get('google_credentials')

# Porcupine
porc_cfg = cfg.get('porcupine', {})
porcupine = Porcupine(
    access_key=porc_cfg['access_key'],
    library_path=porc_cfg['library_path'],
    model_path=porc_cfg['model_path'],
    keyword_paths=[porc_cfg['keyword_path']],
    sensitivities=[0.6]
)

# Vosk
model = Model(VOSK_MODEL_PATH)
recognizer = KaldiRecognizer(model, RATE)

tts_client = texttospeech.TextToSpeechClient()

# -------------------------------------------------------------------
# AUTODETECCIÓN DE MICRÓFONO USB
# -------------------------------------------------------------------
def detectar_microfono():
    """
    Busca una tarjeta de captura USB válida y devuelve:
    - index PyAudio
    - channels
    - rate usable
    - formato PyAudio
    """
    pa = pyaudio.PyAudio()
    logger.info("Buscando micrófono USB…")

    dispositivos = []
    for i in range(pa.get_device_count()):
        info = pa.get_device_info_by_index(i)
        name = info.get('name', '').lower()
        host = info.get('hostApi')
        max_in = info.get('maxInputChannels')

        dispositivos.append(info)

        if max_in > 0:
            logger.info(f"Dispositivo encontrado: {i} → {info}")

    # Filtrar por entradas válidas
    candidatos = [d for d in dispositivos if d['maxInputChannels'] > 0]

    if not candidatos:
        logger.error("❌ No se encontró ningún micrófono")
        raise RuntimeError("No hay micrófono disponible")

    # Prioridad: USB y con 1–2 canales
    for d in candidatos:
        name = d['name'].lower()
        if "usb" in name or "c-media" in name or "microphone" in name:
            logger.info(f"Micrófono elegido: {d}")
            idx = d['index']

            # canales
            canales = 1 if d['maxInputChannels'] >= 1 else d['maxInputChannels']
            logger.info(f"Canales seleccionados: {canales}")

            formato = pyaudio.paInt16  # USB Audio Class 1 siempre soporta S16_LE
            tasa = RATE

            return idx, canales, tasa, formato

    # Si no encontró USB, elegir el primero válido
    d = candidatos[0]
    idx = d['index']
    canales = 1
    formato = pyaudio.paInt16
    tasa = RATE

    logger.info(f"Micrófono elegido fallback: {d}")
    return idx, canales, tasa, formato


# -------------------------------------------------------------------
# CREAR STREAM DE AUDIO CON AUTODETECCIÓN ERROR-PROOF
# -------------------------------------------------------------------
def crear_stream_autodetect():
    """
    Intenta abrir un stream de captura robusto probando:
      - todos los dispositivos con maxInputChannels > 0
      - diferentes sample rates comunes
      - 1 o 2 canales
      - hw -> plughw -> default (None)
    Devuelve: (pa, stream, canales, rate)
    Lanza RuntimeError si no se puede abrir nada.
    """
    pa = pyaudio.PyAudio()
    logger.info("Iniciando creación robusta de stream (autodetect)...")

    # Detectar dispositivos con capacidad de entrada
    dispositivos = []
    for i in range(pa.get_device_count()):
        info = pa.get_device_info_by_index(i)
        if info.get('maxInputChannels', 0) > 0:
            di = {
                'index': i,
                'name': info.get('name'),
                'maxInputChannels': int(info.get('maxInputChannels', 0))
            }
            dispositivos.append(di)
            logger.info(f"  Candidate device {i}: {di['name']} (maxIn={di['maxInputChannels']})")

    # Si no hay dispositivos, intentar default
    if not dispositivos:
        logger.warning("No se detectaron dispositivos con maxInputChannels > 0. Intentando default.")
        dispositivos = [{'index': None, 'name': 'default', 'maxInputChannels': 1}]

    # Rates y channels a probar (ordenados por probabilidad de éxito para VOSK)
    candidate_rates = [16000, 8000, 44100, 48000]
    candidate_channels = [1, 2]

    # Métodos de apertura: primero device index real, luego None (default)
    modos_apertura = []
    for d in dispositivos:
        modos_apertura.append({'device': d['index'], 'descr': f"device_index={d['index']} ({d['name']})", 'maxch': d['maxInputChannels']})
    modos_apertura.append({'device': None, 'descr': 'default', 'maxch': 1})

    last_error = None
    for modo in modos_apertura:
        dev = modo['device']
        maxch = modo.get('maxch', 1)
        for ch in candidate_channels:
            if ch > maxch:
                # si dispositivo no soporta tantos canales, intentar de todos modos — ALSA puede convertir
                pass
            for rate in candidate_rates:
                try:
                    logger.info(f"Intentando abrir device={dev} channels={ch} rate={rate}")
                    stream = pa.open(
                        rate=rate,
                        channels=ch,
                        format=pyaudio.paInt16,
                        input=True,
                        input_device_index=dev,
                        frames_per_buffer=CHUNK
                    )
                    logger.info(f"✔ Audio abierto OK: device={dev} channels={ch} rate={rate}")
                    return pa, stream, ch, rate
                except Exception as e:
                    last_error = e
                    logger.debug(f"Fallo apertura device={dev} ch={ch} rate={rate}: {e}")

    # Si llegamos aquí, no se pudo abrir nada
    logger.critical("No se pudo abrir NINGÚN stream de audio. Último error: %s", last_error)
    raise RuntimeError("Fallo crítico en audio: no se pudo abrir ningún stream")


# -------------------------------------------------------------------
# TTS
# -------------

PY

cat > "$ROOT_DIR/ami_listener.py" <<'PY'
#!/usr/bin/env python3
import socket, threading, yaml, logging, time, subprocess
logger = logging.getLogger('ami')
logger.setLevel(logging.INFO)
fh = logging.FileHandler('/var/log/ami_listener.log')
fmt = logging.Formatter('%(asctime)s %(levelname)s %(message)s')
fh.setFormatter(fmt)
logger.addHandler(fh)
with open('config.yaml') as f:
    cfg = yaml.safe_load(f)
ami = cfg['ami']
HOST = ami.get('host')
USER = ami.get('user')
PASS = ami.get('pass')
class AMIClient:
    def __init__(self, host, user, passwd, port=5038):
        self.host = host
        self.user = user
        self.passwd = passwd
        self.port = port
        self.sock = None
        self.running = False
    def connect(self):
        self.sock = socket.create_connection((self.host,self.port))
        try:
            self.sock.recv(4096)
        except:
            pass
        self.send_action({'Action':'Login','Username':self.user,'Secret':self.passwd})
        self.running = True
        threading.Thread(target=self._reader,daemon=True).start()
        logger.info('Connected to AMI at %s:%s', self.host, self.port)
    def send_action(self, action):
        s = ''
        for k,v in action.items(): s += f"{k}: {v}\r\n"
        s += '\r\n'
        self.sock.sendall(s.encode())
    def _reader(self):
        buf = b''
        while self.running:
            try:
                data = self.sock.recv(4096)
                if not data:
                    time.sleep(1)
                    continue
                buf += data
                while b"\\r\\n\\r\\n" in buf:
                    part,buf = buf.split(b"\\r\\n\\r\\n",1)
                    text = part.decode(errors='ignore')
                    self._handle_event(text)
            except Exception:
                logger.exception('AMI read fail')
                time.sleep(1)
    def _handle_event(self, text):
        lines = [l for l in text.split('\\r\\n') if l]
        d = {}
        for line in lines:
            if ':' in line:
                k,v = line.split(':',1)
                d[k.strip()] = v.strip()
        if d.get('Event') in ('DTMF','ChannelDtmfReceived'):
            digit = d.get('Digit') or d.get('Dtmf')
            logger.info('DTMF received: %s', digit)
            self.on_dtmf(digit)
    def on_dtmf(self, digit):
        node = cfg.get('node_num')
        if digit=='1':
            subprocess.run(['asterisk','-rx',f'rpt playback {node} ai_resp'])
        elif digit=='2':
            subprocess.run(['asterisk','-rx',f'rpt playback {node} ai_status'])
        elif digit=='9':
            subprocess.run(['systemctl','restart','asl-ai'])
            logger.info('Restarting asl-ai service on DTMF 9')
if __name__=='__main__':
    client = AMIClient(HOST, USER, PASS, port=5038)
    client.connect()
    while True:
        time.sleep(1)
PY

cat > "$ROOT_DIR/asl_ai_web.py" <<'PY'
#!/usr/bin/env python3
from flask import Flask, render_template, jsonify, request
import yaml, os, subprocess, logging
app = Flask(__name__, template_folder='web/templates', static_folder='web/static')
with open('config.yaml') as f:
    cfg = yaml.safe_load(f)
LOG_FILE = '/var/log/asl_ai.log'
@app.route('/')
def index():
    return "<h3>ASL AI Web UI</h3><p>Usa /api/status y /api/logs</p>"
@app.route('/api/status')
def status():
    st = {
        'node': cfg.get('node_num'),
        'service': 'running' if os.system('systemctl is-active --quiet asl-ai')==0 else 'stopped'
    }
    return jsonify(st)
@app.route('/api/logs')
def logs():
    try:
        out = subprocess.check_output(['tail','-n','500',LOG_FILE]).decode(errors='ignore')
    except Exception as e:
        out = str(e)
    return jsonify({'logs': out})
@app.route('/api/play_last', methods=['POST'])
def play_last():
    subprocess.run(['asterisk','-rx',f'rpt playback {cfg.get("node_num")} ai_resp'])
    return jsonify({'ok': True})
if __name__=='__main__':
    app.run(host='0.0.0.0', port=8083)
PY

# Crear systemd services con el usuario seleccionado
cat > /etc/systemd/system/asl-ai.service <<EOF
[Unit]
Description=IA AllStarLink Core
After=network.target
[Service]
Type=simple
User=$RUN_AS_USER
WorkingDirectory=$ROOT_DIR
Environment=GOOGLE_APPLICATION_CREDENTIALS=$ROOT_DIR/credentials/google_tts.json
ExecStart=$VENV_DIR/bin/python $ROOT_DIR/asl_ai_core.py
Restart=on-failure
[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/asl-ai-web.service <<EOF
[Unit]
Description=ASL AI Web UI
After=network.target
[Service]
Type=simple
User=$RUN_AS_USER
WorkingDirectory=$ROOT_DIR
ExecStart=$VENV_DIR/bin/python $ROOT_DIR/asl_ai_web.py
Restart=on-failure
[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable asl-ai.service || true
systemctl enable asl-ai-web.service || true

echo
echo "Instalación base completada."
echo "Revisa /usr/local/asl_ai/config.yaml y coloca tu wake-word (.ppn) y porcupine_params.pv en $ROOT_DIR/porcupine/"
echo "Si libpv_porcupine.so no fue detectado, cópialo a /usr/local/lib/ y actualiza config.yaml -> porcupine.library_path"
echo "Servicios systemd creados: asl-ai.service y asl-ai-web.service (se ejecutarán como $RUN_AS_USER)"
echo
echo "Siguientes pasos sugeridos:"
echo "  - Añadir $RUN_AS_USER a grupos audio/www-data si es necesario:"
echo "      sudo usermod -aG audio,$RUN_AS_USER $RUN_AS_USER"
echo "  - Asegurarte que Asterisk tiene permisos sobre /var/lib/asterisk/sounds/"
echo "  - Revisar /var/log/asl_ai.log para problemas"
exit 0
