import json

path = r'C:\work\AiServerAutoSettings\test-cf-directip.json'
with open(path) as f:
    cfg = json.load(f)

for o in cfg.get('outbounds', []):
    if o.get('tag') == 'proxy':
        o['settings']['vnext'][0]['address'] = '162.159.192.1'
        o['streamSettings']['tlsSettings']['serverName'] = 'vpn.corenetai.ru'
        o['streamSettings']['wsSettings']['headers']['Host'] = 'vpn.corenetai.ru'

with open(path, 'w') as f:
    json.dump(cfg, f, indent=2)

print('Updated to clean IP 162.159.192.1')
