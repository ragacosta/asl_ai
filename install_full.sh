#!/bin/bash
set -e

ROOT_DIR=/usr/local/asl_ai
mkdir -p "$ROOT_DIR"
cd "$ROOT_DIR"

echo "Instalador completo: IA + AllStarLink + Web UI + Monitoreo"

DEFAULT_NODE="<NODE_NUM>"
DEFAULT_GOOGLE_JSON="<GOOGLE_JSON>"
DEFAULT_AMI_USER="<AMI_USER>"
DEFAULT_AMI_PASS="<AMI_PASS>"
DEFAULT_AMI_HOST="<AMI_HOST>"

read -p "Número de nodo AllStar [${DEFAULT_NODE}]: " NODE_NUM
NODE_NUM=${NODE_NUM:-$DEFAULT_NODE}

read -p "Ruta JSON credenciales Google TTS [${DEFAULT_GOOGLE_JSON}]: " GOOGLE_JSON
GOOGLE_JSON=${GOOGLE_JSON:-$DEFAULT_GOOGLE_JSON}

read -p "Usuario AMI [${DEFAULT_AMI_USER}]: " AMI_USER
AMI_USER=${AMI_USER:-$DEFAULT_AMI_USER}
read -s -p "Clave AMI [${DEFAULT_AMI_PASS}]: " AMI_PASS
AMI_PASS=${AMI_PASS:-$DEFAULT_AMI_PASS}
echo
read -p "Host AMI [${DEFAULT_AMI_HOST}]: " AMI_HOST
AMI_HOST=${AMI_HOST:-$DEFAULT_AMI_HOST}

# Verifica JSON
if [ ! -f "$GOOGLE_JSON" ]; then
  echo "ERROR: Credencial Google no encontrada: $GOOGLE_JSON"
  exit 1
fi

# Instala dependencias
sudo apt update
sudo apt install -y sox ffmpeg python3-pip python3-venv python3-pyaudio libatlas-base-dev unzip wget

# Crea virtualenv
python3 -m venv venv
source venv/bin/activate
pip install --upgrade pip
pip install vosk pvporcupine google-cloud-texttospeech pyaudio flask prometheus_client requests watchdog PyYAML

# Copia credencial
mkdir -p $ROOT_DIR/credentials
cp "$GOOGLE_JSON" $ROOT_DIR/credentials/google_tts.json
chmod 600 $ROOT_DIR/credentials/google_tts.json

# Crear archivo config
cat > $ROOT_DIR/config.yaml <<EOF
node_num: "$NODE_NUM"
ami:
  host: "$AMI_HOST"
  user: "$AMI_USER"
  pass: "$AMI_PASS"
porcupine:
  access_key: ""
  library_path: "/usr/local/lib/libpv_porcupine.so"
  model_path: "/usr/local/asl_ai/porcupine/porcupine_params.pv"
  keyword_path: "/usr/local/asl_ai/porcupine/alexa_es.ppn"
vosk_model: /usr/local/asl_Aivosk/vosk-model-small-es-0.42
sounds_dir: /var/lib/asterisk/sounds
google_credentials: $ROOT_DIR/credentials/google_tts.json
listen_rate: 16000
chunk: 1024
openweather_key: ""
chatgpt_key: ""
web_port: 8080
EOF

# Descargar modelo VOSK si no existe
mkdir -p /usr/local/asl_ai/vosk
if [ ! -d "/usr/local/asl_ai/vosk/vosk-model-small-es-0.42" ]; then
  cd /usr/local/asl_ai/vosk
  wget -q https://alphacephei.com/vosk/models/vosk-model-small-es-0.42.zip
  unzip -o vosk-model-small-es-0.42.zip
  rm vosk-model-small-es-0.42.zip
fi

# Directorio Porcupine
mkdir -p /usr/local/asl_ai/porcupine

# Copiar scripts (se sobreescriben si existen)
cat > $ROOT_DIR/asl_ai_core.py <<'PY'
#!/usr/bin/env python3
# -*- coding:utf-8 -*-
import os
import time
import json
import subprocess
import logging
import yaml
from vosk import Model, KaldiRecognizer
from pvporcupine import Porcupine
import pyaudio
from google.cloud import texttospeech
from prometheus_client import Counter, Gauge, start_http_server
import requests
from logging.handlers import RotatingFileHandler

# Logging avanzado
logger = logging.getLogger('asl_ai')
logger.setLevel(logging.INFO)
fh = RotatingFileHandler('/var/log/asl_ai.log', maxBytes=5*1024*1024, backupCount=5)
fmt = logging.Formatter('%(asctime)s %(levelname)s %(message)s')
fh.setFormatter(fmt)
logger.addHandler(fh)

# Metrics
REQ_COUNTER = Counter('asl_ai_requests_total', 'Total requests received via wakeword')
ERR_COUNTER = Counter('asl_ai_errors_total', 'Total errors')
LAST_REQ = Gauge('asl_ai_last_request_timestamp', 'Timestamp of last request')

# Load config
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

# Init Porcupine (modern SDK requires access_key, library_path, model_path, keyword_paths, sensitivities)
if not all([PORCUPINE_ACCESS_KEY, PORCUPINE_LIB_PATH, PORCUPINE_MODEL_PATH, WAKE_MODEL]):
    logger.error('Porcupine configuration incomplete. Check config.yaml')
    raise SystemExit('Porcupine configuration incomplete. Check config.yaml')

if not os.path.isfile(PORCUPINE_LIB_PATH):
    logger.error('Porcupine library not found at %s', PORCUPINE_LIB_PATH)
    raise FileNotFoundError(f'Porcupine library not found: {PORCUPINE_LIB_PATH}')

if not os.path.isfile(PORCUPINE_MODEL_PATH):
    logger.error('Porcupine model not found at %s', PORCUPINE_MODEL_PATH)
    raise FileNotFoundError(f'Porcupine model not found: {PORCUPINE_MODEL_PATH}')

if not os.path.isfile(WAKE_MODEL):
    logger.error('Porcupine keyword file not found at %s', WAKE_MODEL)
    raise FileNotFoundError(f'Porcupine keyword file not found: {WAKE_MODEL}')

logger.info('Inicializando Porcupine...')

porcupine = Porcupine(
    access_key=PORCUPINE_ACCESS_KEY,
    library_path=PORCUPINE_LIB_PATH,
    model_path=PORCUPINE_MODEL_PATH,
    keyword_paths=[WAKE_MODEL],
    sensitivities=[0.6]
)

logger.info('Inicializando VOSK...')
model = Model(VOSK_MODEL_PATH)
recognizer = KaldiRecognizer(model, RATE)

pa = pyaudio.PyAudio()
stream = pa.open(rate=RATE, channels=1, format=pyaudio.paInt16, input=True, frames_per_buffer=CHUNK)

tts_client = texttospeech.TextToSpeechClient()

# Start prometheus metrics server
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
        except Exception:
            logger.exception('Main loop error')
            ERR_COUNTER.inc()
            time.sleep(1)

if __name__ == '__main__':
    main_loop()

PY

cat > $ROOT_DIR/ami_listener.py <<'PY'
#!/usr/bin/env python3
import socket
import threading
import yaml
import logging
import time
import subprocess

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
                while b"\r\n\r\n" in buf:
                    part,buf = buf.split(b"\r\n\r\n",1)
                    text = part.decode(errors='ignore')
                    self._handle_event(text)
            except Exception:
                logger.exception('AMI read fail')
                time.sleep(1)

    def _handle_event(self, text):
        lines = [l for l in text.split('\r\n') if l]
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

cat > $ROOT_DIR/asl_ai_web.py <<'PY'
#!/usr/bin/env python3
from flask import Flask, render_template, jsonify, request
import yaml, os, subprocess, logging

app = Flask(__name__, template_folder='web/templates', static_folder='web/static')

with open('config.yaml') as f:
    cfg = yaml.safe_load(f)

LOG_FILE = '/var/log/asl_ai.log'

@app.route('/')
def index():
    return render_template('index.html')

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

# systemd services
sudo tee /etc/systemd/system/asl-ai.service > /dev/null <<EOF
[Unit]
Description=IA AllStarLink Core
After=network.target

[Service]
Type=simple
User=admin
WorkingDirectory=$ROOT_DIR
Environment=GOOGLE_APPLICATION_CREDENTIALS=$ROOT_DIR/credentials/google_tts.json
ExecStart=$ROOT_DIR/venv/bin/python $ROOT_DIR/asl_ai_core.py
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

sudo tee /etc/systemd/system/asl-ai-web.service > /dev/null <<EOF
[Unit]
Description=ASL AI Web UI
After=network.target

[Service]
Type=simple
User=admin
WorkingDirectory=$ROOT_DIR
ExecStart=$ROOT_DIR/venv/bin/python $ROOT_DIR/asl_ai_web.py
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable asl-ai.service
sudo systemctl enable asl-ai-web.service
echo "-- Recuerda copiar libpv_porcupine.so a /usr/local/lib/ (o la ruta que uses) --"
echo "-- Recuerda poner porcupine_params.pv y tu .ppn en /usr/local/asl_ai/porcupine/ --"
echo "Instalación base completada. Edita /usr/local/asl_ai/config.yaml si es necesario y coloca tu wake-word .ppn en /usr/local/asl_ai/porcupine/"
