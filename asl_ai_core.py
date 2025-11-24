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
WAKE_MODEL = cfg.get('porcupine_ppn')
VOSK_MODEL_PATH = cfg.get('vosk_model')
SOUNDS_DIR = cfg.get('sounds_dir')
RATE = cfg.get('listen_rate',16000)
CHUNK = cfg.get('chunk',1024)

os.environ['GOOGLE_APPLICATION_CREDENTIALS'] = cfg.get('google_credentials')

# Init
logger.info('Inicializando Porcupine...')
porcupine = Porcupine(key_phrase_paths=[WAKE_MODEL])

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
    # Fallback: echo
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
