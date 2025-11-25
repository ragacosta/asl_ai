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
from vosk import Model, KaldiRecognizer
try:
    from pvporcupine import Porcupine
except Exception:
    Porcupine = None
import pyaudio
from google.cloud import texttospeech
from prometheus_client import Counter, Gauge, start_http_server
import requests
from logging.handlers import RotatingFileHandler

logger = logging.getLogger('asl_ai')
logger.setLevel(logging.INFO)
fh = RotatingFileHandler('/var/log/asl_ai.log', maxBytes=5*1024*1024, backupCount=5)
fmt = logging.Formatter('%(asctime)s %(levelname)s %(message)s')
fh.setFormatter(fmt)
logger.addHandler(fh)

REQ_COUNTER = Counter('asl_ai_requests_total', 'Total requests received via wakeword')
ERR_COUNTER = Counter('asl_ai_errors_total', 'Total errors')
LAST_REQ = Gauge('asl_ai_last_request_timestamp', 'Timestamp of last request')

with open('config.yaml','r') as f:
    cfg = yaml.safe_load(f)

NODE_NUM = cfg.get('node_num')
porc_cfg = cfg.get('porcupine', {})
WAKE_MODEL = porc_cfg.get('keyword_path')
PORCUPINE_LIB_PATH = porc_cfg.get('library_path')
PORCUPINE_MODEL_PATH = porc_cfg.get('model_path')
PORCUPINE_ACCESS_KEY = porc_cfg.get('access_key')

VOSK_MODEL_PATH = cfg.get('vosk_model')
SOUNDS_DIR = cfg.get('sounds_dir')
RATE = cfg.get('listen_rate',16000)
CHUNK = cfg.get('chunk',1024)

os.environ['GOOGLE_APPLICATION_CREDENTIALS'] = cfg.get('google_credentials')

if Porcupine is None:
    logger.error('pvporcupine no está disponible. Revisa la instalación.')
else:
    if not all([PORCUPINE_ACCESS_KEY, PORCUPINE_LIB_PATH, PORCUPINE_MODEL_PATH, WAKE_MODEL]):
        logger.error('Porcupine configuración incompleta en config.yaml; Porcupine no será inicializado.')
    else:
        if not os.path.isfile(PORCUPINE_LIB_PATH):
            logger.error('Porcupine library not found at %s', PORCUPINE_LIB_PATH)
        elif not os.path.isfile(PORCUPINE_MODEL_PATH):
            logger.error('Porcupine model not found at %s', PORCUPINE_MODEL_PATH)
        elif not os.path.isfile(WAKE_MODEL):
            logger.error('Porcupine keyword file not found at %s', WAKE_MODEL)
        else:
            logger.info('Inicializando Porcupine...')
            porcupine = Porcupine(
                access_key=PORCUPINE_ACCESS_KEY,
                library_path=PORCUPINE_LIB_PATH,
                model_path=PORCUPINE_MODEL_PATH,
                keyword_paths=[WAKE_MODEL],
                sensitivities=[float(porc_cfg.get('sensitivities', porc_cfg.get('sensitivity', 0.6)))]
            )

logger.info('Inicializando VOSK...')
model = Model(VOSK_MODEL_PATH)
recognizer = KaldiRecognizer(model, RATE)

pa = pyaudio.PyAudio()
stream = pa.open(rate=RATE, channels=1, format=pyaudio.paInt16, input=True, frames_per_buffer=CHUNK)

tts_client = texttospeech.TextToSpeechClient()

start_http_server(8001)
logger.info('Prometheus metrics on :8001')

def generar_audio_tts(texto, out_path='/tmp/tts_8k.wav'):
    try:
        synthesis_input = texttospeech.SynthesisInput(text=texto)
        voice = texttospeech.VoiceSelectionParams(language_code='es-MX', name='es-MX-Standard-B')
        audio_config = texttospeech.AudioConfig(audio_encoding=texttospeech.AudioEncoding.LINEAR16)
        response = tts_client.synthesize_speech(input=synthesis_input, voice=voice, audio_config=audio_config)
        tmp = '/tmp/tts.wav'
        with open(tmp,'wb') as f:
            f.write(response.audio_content)
        subprocess.run(['sox', tmp, '-r', '8000', '-c', '1', out_path], check=True)
        return out_path
    except Exception:
        logger.exception('TTS failure')
        ERR_COUNTER.inc()
        return None

def reproducir_allstar(wav_path, name='ai_resp'):
    try:
        dest = os.path.join(SOUNDS_DIR, f"{name}.wav")
        subprocess.run(['sudo','cp', wav_path, dest], check=True)
        subprocess.run(['asterisk','-rx', f'rpt playback {NODE_NUM} {name}'], check=True)
        logger.info('Reproduced on node %s', NODE_NUM)
    except Exception:
        logger.exception('Playback error')
        ERR_COUNTER.inc()

OPENWEATHER_KEY = os.environ.get('OPENWEATHER_KEY') or cfg.get('openweather_key')

def handle_intent(texto):
    texto = texto.lower()
    if 'temperatura' in texto or 'clima' in texto:
        ciudad = 'Ciudad de México'
        if 'en' in texto:
            try:
                ciudad = texto.split('en')[-1].strip()
            except:
                pass
        if OPENWEATHER_KEY:
            try:
                r = requests.get('https://api.openweathermap.org/data/2.5/weather',
                                 params={'q': ciudad, 'appid': OPENWEATHER_KEY, 'units':'metric','lang':'es'}, timeout=5)
                j = r.json()
                temp = j['main']['temp']
                desc = j['weather'][0]['description']
                return f'La temperatura en {ciudad} es de {int(temp)} grados Celsius y {desc}.'
            except Exception:
                logger.exception('OpenWeather error')
                return 'No pude consultar el clima ahora.'
        else:
            return 'No tengo configurada la API de clima. Configura OPENWEATHER_KEY.'
    return 'Comando recibido: ' + texto

def main_loop():
    logger.info('Starting main loop')
    while True:
        try:
            if 'porcupine' in globals():
                pcm = stream.read(CHUNK, exception_on_overflow=False)
                res = porcupine.process(pcm)
                if res >= 0:
                    logger.info('Wake word detected')
                    REQ_COUNTER.inc()
                    LAST_REQ.set_to_current_time()
                    frames = [pcm]
                    for _ in range(int(RATE/CHUNK*4)):
                        frames.append(stream.read(CHUNK, exception_on_overflow=False))
                    raw = '/tmp/cmd.raw'
                    with open(raw,'wb') as f:
                        for fr in frames:
                            f.write(fr)
                    wavfile = '/tmp/cmd.wav'
                    subprocess.run(['sox','-t','raw','-r',str(RATE),'-e','signed','-b','16','-c','1',raw,wavfile], check=True)
                    with open(wavfile,'rb') as f:
                        data = f.read()
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
                # Si Porcupine no está disponible, hacemos un simple reconocimiento continuo con VOSK
                pcm = stream.read(CHUNK, exception_on_overflow=False)
                if recognizer.AcceptWaveform(pcm):
                    r = json.loads(recognizer.Result())
                else:
                    r = json.loads(recognizer.FinalResult())
                texto = r.get('text','')
                if texto:
                    logger.info('Recognized (VOSK continuous): %s', texto)
        except Exception:
            logger.exception('Main loop error')
            ERR_COUNTER.inc()
            time.sleep(1)

if __name__ == '__main__':
    main_loop()
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
    app.run(host='0.0.0.0', port=8080)
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
