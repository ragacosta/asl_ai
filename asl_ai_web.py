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
