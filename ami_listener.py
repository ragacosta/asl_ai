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
