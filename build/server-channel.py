#!/usr/bin/env python3
# Transport channel export moved from the retired Disk installer.
import os,sys,json,subprocess,base64
from pathlib import Path
def channel(data):
    source=json.loads(Path(os.environ.get('REMOTEAGENTS_CHANNEL_SOURCE') or os.environ.get('REMOTE_DISK_CHANNEL_SOURCE','/etc/sing-box/config.json')).read_text())
    inbound=next(x for x in source['inbounds'] if x['type']=='vless' and x.get('listen_port')==443 and any(u.get('name')=='client' for u in x['users']))
    user=next(x for x in inbound['users'] if x.get('name')=='client');tls=inbound['tls'];reality=tls['reality']
    raw=base64.urlsafe_b64decode(reality['private_key']+'===')
    if len(raw)!=32:raise ValueError('Некорректный Reality key')
    der=subprocess.run(['openssl','pkey','-inform','DER','-pubout','-outform','DER'],input=bytes.fromhex('302e020100300506032b656e04220420')+raw,capture_output=True,timeout=5)
    if der.returncode:raise ValueError('Не удалось получить Reality public key')
    public=base64.urlsafe_b64encode(der.stdout[-32:]).decode().rstrip('=')
    v=dict(type='vless',tag='vless-direct',server=data['server'],server_port=443,uuid=user['uuid'],flow=user.get('flow',''),tls=dict(enabled=True,server_name=tls.get('server_name') or reality['handshake']['server'],utls=dict(enabled=True,fingerprint='chrome'),reality=dict(enabled=True,public_key=public,short_id=reality['short_id'][0])))
    out=[v];tags=['vless-direct']
    if data.get('hop'):out += [dict(v,tag='vless-hop',detour='hop-ssh'),dict(data['hop'],type='ssh',tag='hop-ssh')];tags.append('vless-hop')
    out.append(dict(type='urltest',tag='server',outbounds=tags,url='https://www.gstatic.com/generate_204',interval='1m',tolerance=300))
    targets=[('ssh',2222,int(data.get('sshPort',22)))]
    return dict(log=dict(disabled=True),inbounds=[dict(type='direct',tag=tag,listen='127.0.0.1',listen_port=port,network='tcp',override_address='127.0.0.1',override_port=target) for tag,port,target in targets],outbounds=out,route=dict(final='server',auto_detect_interface=True))
print(json.dumps(channel(json.loads(base64.b64decode(sys.argv[1])))))
