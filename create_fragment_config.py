import json

path = r'C:\work\AiServerAutoSettings\test-user-happ-hostfix.json'
with open(path) as f:
    cfg = json.load(f)

# Configure dialerProxy in proxy outbound
for o in cfg.get('outbounds', []):
    if o.get('tag') == 'proxy':
        if 'sockopt' not in o['streamSettings']:
            o['streamSettings']['sockopt'] = {}
        o['streamSettings']['sockopt']['dialerProxy'] = 'fragment'

# Add fragment outbound if not present
has_fragment = any(o.get('tag') == 'fragment' for o in cfg.get('outbounds', []))
if not has_fragment:
    cfg['outbounds'].append({
        "tag": "fragment",
        "protocol": "freedom",
        "settings": {
            "fragment": {
                "packets": "tlshello",
                "length": "100-200",
                "interval": "10-20"
            }
        }
    })

with open(r'C:\work\AiServerAutoSettings\test-cf-fragment.json', 'w') as f:
    json.dump(cfg, f, indent=2)

print('test-cf-fragment.json written successfully')
