import json

with open(r'C:\work\AiServerAutoSettings\test-cf-fragment.json') as f:
    cfg = json.load(f)

# Put direct IP in address so Xray does not need DNS to connect to proxy!
for o in cfg.get('outbounds', []):
    if o.get('tag') == 'proxy':
        o['settings']['vnext'][0]['address'] = '172.67.146.165'
        o['streamSettings']['tlsSettings']['serverName'] = 'vpn.corenetai.ru'
        o['streamSettings']['wsSettings']['headers']['Host'] = 'vpn.corenetai.ru'

# Simplify DNS to system / 8.8.8.8 direct
cfg['dns'] = {
    "servers": ["8.8.8.8", "1.1.1.1"]
}
cfg['routing']['rules'] = []  # Default everything to proxy

with open(r'C:\work\AiServerAutoSettings\test-cf-directip.json', 'w') as f:
    json.dump(cfg, f, indent=2)

print('test-cf-directip.json created')
