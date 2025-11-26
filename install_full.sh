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
# -*- coding: utf-8 -*-
"""
ASL_AI CORE - Final
- Abre el mic USB por índice PyAudio detectado (ej. index 1)
- Usa la sampleRate nativa del dispositivo (ej. 44100)
- Resamplea en tiempo real a 16000 Hz para VOSK usando audioop.ratecv
- Silencia ALSA/JACK/Pulse durante operaciones ruidosas
- Mantiene Porcupine / VOSK / TTS / playback AllStar
"""

import os
import sys
import time
import json
import subprocess
import logging
import yaml
import contextlib
from logging.handlers import RotatingFileHandler
from array import array
import audioop

# Optional imports
try:
    import pyaudio
except Exception:
    pyaudio = None

try:
    from vosk import Model, KaldiRecognizer
except Exception:
    Model = None
    KaldiRecognizer = None

try:
    from pvporcupine import Porcupine
except Exception:
    Porcupine = None

try:
    from google.cloud import texttospeech
except Exception:
    texttospeech = None

try:
    from prometheus_client import Counter, Gauge, start_http_server
except Exception:
    Counter = Gauge = start_http_server = None

# ---------------- logging ----------------
LOG_FILE = '/var/log/asl_ai.log'
os.makedirs(os.path.dirname(LOG_FILE), exist_ok=True)
logger = logging.getLogger('asl_ai')
logger.setLevel(logging.INFO)
fh = RotatingFileHandler(LOG_FILE, maxBytes=5*1024*1024, backupCount=5)
fh.setFormatter(logging.Formatter('%(asctime)s %(levelname)s %(message)s'))
logger.addHandler(fh)
logger.info("=== ASL_AI CORE (final) starting ===")

# metrics fallback
if Counter and Gauge:
    REQ_COUNTER = Counter('asl_ai_requests_total', 'Total requests via wakeword')
    ERR_COUNTER = Counter('asl_ai_errors_total', 'Total errors')
    LAST_REQ = Gauge('asl_ai_last_request_timestamp', 'Last request time')
else:
    class _D:
        def inc(self, *a, **k): pass
        def set_to_current_time(self, *a, **k): pass
    REQ_COUNTER = ERR_COUNTER = LAST_REQ = _D()

# ---------------- suppress helper ----------------
@contextlib.contextmanager
def suppress_alsa_errors():
    """Temporarily redirect stderr to /dev/null to silence ALSA/JACK/Pulse messages."""
    fd = sys.stderr.fileno()
    saved = os.dup(fd)
    devnull = os.open(os.devnull, os.O_RDWR)
    os.dup2(devnull, fd)
    try:
        yield
    finally:
        os.dup2(saved, fd)
        os.close(devnull)
        os.close(saved)

# ---------------- config ----------------
CFG_PATH = '/usr/local/asl_ai/config.yaml'
if not os.path.isfile(CFG_PATH):
    logger.critical('Missing config: %s', CFG_PATH)
    raise SystemExit('config.yaml missing')

with open(CFG_PATH, 'r') as f:
    cfg = yaml.safe_load(f)

NODE_NUM = cfg.get('node_num')
SOUNDS_DIR = cfg.get('sounds_dir', '/var/lib/asterisk/sounds')
VOSK_MODEL_PATH = cfg.get('vosk_model')
os.environ['GOOGLE_APPLICATION_CREDENTIALS'] = cfg.get('google_credentials', '')

# Vosk target rate
VOSK_RATE = 16000

# preferred chunk (frames at device rate) - keep moderate size
CHUNK = int(cfg.get('chunk', 2048))

# ---------------- Porcupine (optional) ----------------
porcupine = None
if Porcupine:
    porc_cfg = cfg.get('porcupine', {}) or {}
    try:
        if all([porc_cfg.get('access_key'), porc_cfg.get('library_path'),
                porc_cfg.get('model_path'), porc_cfg.get('keyword_path')]):
            porcupine = Porcupine(
                access_key=porc_cfg.get('access_key'),
                library_path=porc_cfg.get('library_path'),
                model_path=porc_cfg.get('model_path'),
                keyword_paths=[porc_cfg.get('keyword_path')],
                sensitivities=[float(porc_cfg.get('sensitivities', 0.6))]
            )
            logger.info('Porcupine initialized.')
        else:
            logger.info('Porcupine not fully configured.')
    except Exception:
        logger.exception('Porcupine init failed')
        porcupine = None
else:
    logger.info('pvporcupine not installed')

# ---------------- VOSK ----------------
if Model is None:
    logger.critical('vosk not installed')
    raise SystemExit('vosk missing')
logger.info('Loading VOSK model: %s', VOSK_MODEL_PATH)
with suppress_alsa_errors():
    try:
        model = Model(VOSK_MODEL_PATH)
        # will create recognizer later with proper sample rate (VOSK_RATE)
        recognizer = KaldiRecognizer(model, VOSK_RATE)
        logger.info('VOSK loaded.')
    except Exception:
        logger.exception('VOSK load failed')
        raise

# ---------------- TTS ----------------
if texttospeech:
    try:
        tts_client = texttospeech.TextToSpeechClient()
    except Exception:
        logger.exception('TTS init failed')
        tts_client = None
else:
    tts_client = None

def generar_audio_tts(texto, out='/tmp/tts_8k.wav'):
    if not tts_client:
        return None
    try:
        synthesis = texttospeech.SynthesisInput(text=texto)
        voice = texttospeech.VoiceSelectionParams(language_code='es-MX', name='es-MX-Standard-B')
        acfg = texttospeech.AudioConfig(audio_encoding=texttospeech.AudioEncoding.LINEAR16)
        r = tts_client.synthesize_speech(input=synthesis, voice=voice, audio_config=acfg)
        tmp = '/tmp/tts_tmp.wav'
        with open(tmp, 'wb') as f:
            f.write(r.audio_content)
        subprocess.run(['sox', tmp, '-r', '8000', '-c', '1', out], check=True)
        return out
    except Exception:
        logger.exception('TTS error')
        ERR_COUNTER.inc()
        return None

def reproducir_allstar(path, name='ai_resp'):
    try:
        os.makedirs(SOUNDS_DIR, exist_ok=True)
        dest = os.path.join(SOUNDS_DIR, f'{name}.wav')
        subprocess.run(['sudo','cp', path, dest], check=True)
        if NODE_NUM:
            subprocess.run(['asterisk','-rx', f'rpt playback {NODE_NUM} {name}'], check=True)
        logger.info('Playback requested.')
    except Exception:
        logger.exception('Playback error')
        ERR_COUNTER.inc()

# ---------------- PyAudio helper ----------------
def pyaudio_device_list():
    """Return list of device info dicts from pyaudio; returns empty list if pyaudio missing."""
    if not pyaudio:
        return []
    pa = pyaudio.PyAudio()
    devices = []
    for i in range(pa.get_device_count()):
        try:
            devices.append(pa.get_device_info_by_index(i))
        except Exception:
            devices.append({'index': i, 'error': True})
    pa.terminate()
    return devices

def resolve_usb_index(preferred_names=('usb','pnp','device','c-media')):
    """Choose best PyAudio index for USB mic (heuristic)."""
    devices = pyaudio_device_list()
    picked = None
    for d in devices:
        name = (d.get('name') or '').lower()
        if any(w in name for w in preferred_names) and int(d.get('maxInputChannels',0))>0:
            picked = int(d['index'])
            break
    if picked is None:
        for d in devices:
            if int(d.get('maxInputChannels',0))>0:
                picked = int(d['index'])
                break
    return picked, devices

# audio state
pa = None
stream = None
device_index = None
device_rate = None
device_channels = 1
resample_state = None  # for audioop.ratecv

# init audio open using device index and device native rate
def init_audio(retries=6, delay=1.0):
    global pa, stream, device_index, device_rate, device_channels, resample_state
    if not pyaudio:
        logger.critical('pyaudio missing')
        raise RuntimeError('pyaudio missing')

    attempt = 0
    while attempt < retries:
        attempt += 1
        try:
            pa = pyaudio.PyAudio()
            idx, devices = resolve_usb_index()
            if idx is None:
                idx = 0
            device_index = int(idx)
            info = pa.get_device_info_by_index(device_index)
            device_rate = int(info.get('defaultSampleRate', 44100))
            device_channels = int(info.get('maxInputChannels', 1))
            logger.info('Using PyAudio index %s -> %s (inChannels=%s rate=%s)', device_index, info.get('name'), device_channels, device_rate)

            # open stream at device's native rate (to avoid paInvalidSampleRate)
            with suppress_alsa_errors():
                stream = pa.open(
                    rate=device_rate,
                    channels=device_channels,
                    format=pyaudio.paInt16,
                    input=True,
                    input_device_index=device_index,
                    frames_per_buffer=CHUNK
                )
            # init audioop state for ratecv (mono only expected)
            resample_state = None
            logger.info('Stream opened at device rate %d Hz', device_rate)
            return True
        except Exception as e:
            logger.warning('Audio init attempt %d failed: %s', attempt, e)
            ERR_COUNTER.inc()
            try:
                if stream:
                    stream.close()
                if pa:
                    pa.terminate()
            except Exception:
                pass
            pa = None
            stream = None
            device_index = None
            device_rate = None
            device_channels = 1
            time.sleep(delay)
    return False

def read_and_resample():
    """
    Read one chunk from stream (device_rate, int16, device_channels).
    Convert to mono if needed and resample to VOSK_RATE using audioop.ratecv.
    Return bytes (int16) at VOSK_RATE.
    """
    global resample_state
    raw = stream.read(CHUNK, exception_on_overflow=False)
    # ensure mono: if device_channels > 1, mix to mono
    if device_channels > 1:
        # audioop.tomono(src, width, lfactor, rfactor)
        raw = audioop.tomono(raw, 2, 0.5, 0.5)
    # resample from device_rate -> VOSK_RATE
    if device_rate == VOSK_RATE:
        return raw
    try:
        converted, resample_state = audioop.ratecv(raw, 2, 1, device_rate, VOSK_RATE, resample_state)
        return converted
    except Exception:
        logger.exception('audioop.ratecv failed')
        ERR_COUNTER.inc()
        # fallback: try naive decimation if possible
        try:
            arr = array('h')
            arr.frombytes(raw)
            if device_rate % VOSK_RATE == 0:
                factor = device_rate // VOSK_RATE
                dec = arr[::factor]
                return dec.tobytes()
        except Exception:
            pass
        return b''

# ---------------- intents ----------------
def handle_intent(texto):
    texto = (texto or '').strip().lower()
    if not texto:
        return "No entendí."

    if 'temperatura' in texto or 'clima' in texto:
        ciudad = 'Ciudad de México'
        if ' en ' in texto:
            ciudad = texto.split(' en ')[-1].strip()
        KEY = cfg.get('openweather_key') or os.environ.get('OPENWEATHER_KEY')
        if not KEY:
            return 'No tengo configurada la API del clima.'
        try:
            out = subprocess.check_output([
                'curl','-s','-G','https://api.openweathermap.org/data/2.5/weather',
                '--data-urlencode', f"q={ciudad}",
                '--data-urlencode', f"appid={KEY}",
                '--data-urlencode', 'units=metric',
                '--data-urlencode', 'lang=es'
            ])
            j = json.loads(out.decode())
            temp = j['main']['temp']; desc = j['weather'][0]['description']
            return f'La temperatura en {ciudad} es de {int(temp)} grados Celsius y {desc}.'
        except Exception:
            logger.exception('OpenWeather error')
            return 'No pude consultar el clima ahora.'
    return 'Comando recibido: ' + texto

# ---------------- main loop ----------------
def main_loop():
    if not init_audio():
        logger.critical('Audio init failed, exiting.')
        return
    logger.info('Entering main loop (device_rate=%s -> %s Hz)', device_rate, VOSK_RATE)

    while True:
        try:
            pcm = read_and_resample()
            if not pcm:
                continue

            # If porcupine exists, it typically expects PCM at its configured rate.
            if porcupine:
                try:
                    idx = porcupine.process(pcm)
                except Exception:
                    idx = -1
                    logger.exception('Porcupine process error')
                if idx >= 0:
                    logger.info('Wakeword detected')
                    REQ_COUNTER.inc(); LAST_REQ.set_to_current_time()
                    # gather ~3 seconds of speech (VOSK_RATE)
                    frames = [pcm]
                    frames_needed = int((VOSK_RATE * 3) / (len(pcm) // 2))  # rough
                    for _ in range(max(1, frames_needed)):
                        frames.append(read_and_resample())
                    data = b''.join(frames)
                    if recognizer.AcceptWaveform(data):
                        r = json.loads(recognizer.Result())
                    else:
                        r = json.loads(recognizer.FinalResult())
                    texto = r.get('text','')
                    logger.info('Recognized: %s', texto)
                    respuesta = handle_intent(texto)
                    wav = generar_audio_tts(respuesta)
                    if wav:
                        reproducir_allstar(wav)
            else:
                # continuous
                if recognizer.AcceptWaveform(pcm):
                    r = json.loads(recognizer.Result())
                else:
                    r = json.loads(recognizer.FinalResult())
                texto = r.get('text','')
                if texto:
                    logger.info('Recognized (continuous): %s', texto)
                    respuesta = handle_intent(texto)
                    wav = generar_audio_tts(respuesta)
                    if wav:
                        reproducir_allstar(wav)

        except Exception:
            logger.exception('Main loop error; attempting to reinit audio')
            ERR_COUNTER.inc()
            try:
                if stream:
                    stream.close()
                if pa:
                    pa.terminate()
            except Exception:
                pass
            time.sleep(2)
            if not init_audio(retries=3, delay=2.0):
                logger.critical('Audio reinit failed, sleeping 10s')
                time.sleep(10)

# ---------------- run ----------------
if __name__ == '__main__':
    try:
        if start_http_server:
            start_http_server(8001)
            logger.info('Prometheus on :8001')
        main_loop()
    except KeyboardInterrupt:
        logger.info('KeyboardInterrupt')
    finally:
        try:
            if stream:
                stream.stop_stream(); stream.close()
        except Exception:
            pass
        if pa:
            pa.terminate()
        logger.info('ASL_AI stopped cleanly.')


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
After=network.tarjet sound.target

[Service]
Type=simple
User=$RUN_AS_USER
WorkingDirectory=/usr/local/asl_ai
Environment=GOOGLE_APPLICATION_CREDENTIALS=/usr/local/asl_ai/credentials/google_tts.json

ExecStart=/usr/bin/bash -c 'exec 2>/dev/null;exec /usr/local/asl_ai/venv/bin/python /usr/local/asl_ai/asl_ai_core.py'

Restart=on-failure
RestartSec=2

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
