"""Пути к серверу 109 и конфиг sing-box (перенос из tools/lan_poc.py, прошёл три ревью).

Отличия от lan_poc (названы в отчёте): (1) tcp_keep_alive/tcp_keep_alive_interval на TCP-outbound'ах; (2) для SSH-перехода нет
внешних утилит: логин, ключ и порт - из hops[].ssh и keyFile, ключи хоста - из своего разбора known_hosts; (3) вход direct
на каждый путь вместо одного mixed; (4) Clash API.
Путь = {name (тег последнего outbound'а), kind, outs, final, node}; node - сервер первого звена (для лимита «3 пробы на узел»).
"""
import copy, os, re, socket

from . import journal
from .settings import Fail, known_host_keys, read_json

KINDS = ['hy2', 'hy2obfs', 'tuic', 'trojan', 'reality', 'shadowtls', 'ws-direct', 'ws-cdn']
NAME_RE = re.compile(r'^[a-zA-Z0-9][a-zA-Z0-9_-]{0,47}$')
PATHS_MAX = 64
TCP_TYPES = ('vless', 'trojan', 'shadowtls', 'ssh', 'vmess', 'shadowsocks')
# детектор заморозки, раздел 2.7: ядро закроет TCP-соединение через ~15 с + 9 x 5 с без ответа вместо 16 минут по умолчанию
KEEPALIVE = {'tcp_keep_alive': '15s', 'tcp_keep_alive_interval': '5s'}
HOP_RE = re.compile(r'^(?:([a-z_][a-z0-9_-]{0,31})@)?([a-zA-Z0-9][a-zA-Z0-9.-]{0,252})(?::(\d{1,5}))?$')


def free_ports(n):
    """n разных свободных портов 127.0.0.1 (bind на порт 0; сокеты закрываются вместе)."""
    socks = [socket.socket() for _ in range(n)]
    try:
        for s in socks:
            s.bind(('127.0.0.1', 0))
        return [s.getsockname()[1] for s in socks]
    finally:
        for s in socks:
            s.close()


def set_algs(ssh):
    """sing-box 1.14 берёт host_key_algorithms до проверки host_key (Set-TransportHostKeyAlgorithms)."""
    algs = [a for k in ssh.get('host_key') or [] for a in (['rsa-sha2-512', 'rsa-sha2-256'] if k.split()[0] == 'ssh-rsa' else [k.split()[0]])]
    return dict(ssh, host_key_algorithms=algs) if algs else ssh


def entry_outbounds(e, name):
    """Узел входа на sparfum: {вид: (outbounds, final)} - как в Get-TransportCandidates (Transport.Common.ps1 ~760)."""
    x, s, p = e['secrets'], e['server'], e['ports']
    tls = {'enabled': True, 'server_name': e['sni'], 'insecure': bool(e.get('insecure'))}
    h3, u = dict(tls, alpn=['h3']), {'enabled': True, 'fingerprint': 'chrome'}
    cover = {'enabled': True, 'server_name': e['cover'], 'utls': u}
    r = {'hy2': {'type': 'hysteria2', 'server_port': p['hy2'], 'password': x['hy2'], 'tls': h3},
         'hy2obfs': {'type': 'hysteria2', 'server_port': p['hy2_obfs'], 'password': x['hy2'], 'tls': h3,
                     'obfs': {'type': 'salamander', 'password': x['hy2_obfs']}},
         'tuic': {'type': 'tuic', 'server_port': p['tuic'], 'uuid': x['tuic_uuid'], 'password': x['tuic'], 'congestion_control': 'bbr', 'tls': h3},
         'trojan': {'type': 'trojan', 'server_port': p['trojan'], 'password': x['trojan'], 'tls': tls},
         'reality': {'type': 'vless', 'server_port': p['reality'], 'uuid': x['vless_uuid'], 'flow': 'xtls-rprx-vision',
                     'tls': dict(cover, reality={'enabled': True, 'public_key': x['reality_public'], 'short_id': x['short_id']})}}
    if x.get('ws_path'):
        def wsv(srv, d, insecure):
            tl = dict({'enabled': True, 'server_name': d, 'alpn': ['http/1.1'], 'utls': u}, **({'insecure': True} if insecure else {}))
            return {'type': 'vless', 'server': srv, 'server_port': 443, 'uuid': x['ws_uuid'], 'tls': tl, 'transport': {
                'type': 'ws', 'path': x['ws_path'], 'max_early_data': 2048, 'early_data_header_name': 'Sec-WebSocket-Protocol', 'headers': {'Host': d}}}
        r['ws-direct'] = wsv(s, e.get('domain') or e['sni'], True)
        if e.get('domain'):
            r['ws-cdn'] = wsv(e['domain'], e['domain'], False)
    out = {k: ([dict(o, tag=k + '-' + name, server=o.get('server', s), server_port=int(o['server_port']))], k + '-' + name) for k, o in r.items()}
    st = {'type': 'shadowtls', 'tag': 'stls-' + name, 'server': s, 'server_port': int(p['shadowtls']), 'version': 3, 'password': x['shadowtls'], 'tls': cover}
    ss = {'type': 'shadowsocks', 'tag': 'shadowtls-' + name, 'method': '2022-blake3-aes-128-gcm', 'password': x['ss'], 'detour': st['tag']}
    out['shadowtls'] = ([st, ss], ss['tag'])
    return out


def hop_outbound(hop, prof):
    """SSH-переход (sparfum) без внешних утилит: логин@хост[:порт] из hops[].ssh, ключ из keyFile, ключи хоста из known_hosts / hostKey."""
    m = HOP_RE.match(str(hop.get('ssh') or hop.get('alias') or ''))
    if not m or not m.group(1):
        raise Fail('hop: нужен адрес вида логин@хост[:порт] (псевдонимы ssh без разбора конфига не поддерживаются)')
    user, host, port = m.group(1), m.group(2), int(m.group(3) or 22)
    key = hop.get('keyFile')
    if not 0 < port < 65536 or not key or not os.path.isfile(key):
        raise Fail('hop: неверный порт или нет keyFile')
    kh, pin = hop.get('knownHostsPath'), hop.get('hostKey')
    keys = known_host_keys(kh, host, port) if kh else []
    if not keys and pin:
        keys = [pin] if isinstance(pin, str) else [k for k in pin if isinstance(k, str)]
    if not keys and not kh:
        keys = known_host_keys(os.path.join(os.path.expanduser('~'), '.ssh', 'known_hosts'), host, port)
    if not keys:
        raise Fail('нет закреплённого ключа хоста SSH-перехода')
    return set_algs({'type': 'ssh', 'tag': 'hop-' + hop['name'], 'server': host, 'server_port': port, 'user': user, 'private_key_path': key, 'host_key': keys})


def build_paths(s):
    """settings -> ([путь], {что пропущено: причина}). Порядок: узлы входа, relay, hop, cdn, прямой VLESS."""
    cfg, prof, outs, t = s.cfg, s.prof, s.outs, s.cfg.get('transport') or {}
    vl, paths, miss = next((o for o in outs if o.get('type') == 'vless'), None), [], {}
    hops = list(t.get('hops') or [])
    route = t.get('serverRoute') or (cfg.get('wizard') or {}).get('serverRoute') or {}  # маршрут мастера (Transport.Common.ps1 ~712)
    if route.get('used') == 'hop' and route.get('hop'):
        h = dict(route['hop'], name='wizard-server-route', enabled=True)
        if not h.get('knownHostsPath') and prof.get('knownHostsPath'):
            h['knownHostsPath'] = os.path.join(os.path.dirname(prof['knownHostsPath']), 'known_hosts-hop')
        hops = [x for x in hops if x.get('name') != h['name']] + [h]
    cache = t.get('cacheRoot') or s.installed

    def vless(tag, **kw):  # копия VLESS канала (как $v в Get-TransportCandidates), без detour
        return dict({k: v for k, v in copy.deepcopy(vl).items() if k != 'detour'}, tag=tag, **kw)

    def add(kind, outs_, final):
        for o in outs_:
            journal.collect(o)
        paths.append({'name': final, 'kind': kind, 'outs': outs_, 'final': final, 'node': str(outs_[0].get('server') or s.server)})

    def entry_file(n):
        return read_json(os.path.join(cache, 'secrets', 'entries', n + '.json'))
    for kind, items in (('entry', t.get('entries')), ('relay', t.get('relays')), ('hop', hops), ('cdn', t.get('cdn'))):
        for it in items or []:
            if not isinstance(it, dict) or it.get('enabled') is False:
                continue
            try:
                n = it.get('name') or it.get('entry')
                if not n or not NAME_RE.match(str(n)):
                    raise Fail('имя пути: только буквы, цифры, _ и -')
                if kind == 'entry':
                    e = entry_file(n)
                    journal.register(*[v for v in (e.get('secrets') or {}).values() if isinstance(v, str)])
                    for k, v in entry_outbounds(e, n).items():
                        if k in (it.get('kinds') or KINDS):
                            add(kind, v[0], v[1])
                elif kind == 'cdn':
                    e = entry_file(it['entry'])
                    x = e['secrets']
                    journal.register(*[v for v in x.values() if isinstance(v, str)])
                    if not x.get('ws_uuid') or not x.get('ws_path'):
                        raise Fail('узел не содержит WebSocket')
                    d = it['domain']
                    add(kind, [{'type': 'vless', 'tag': 'cdn-' + n, 'server': d, 'server_port': 443, 'uuid': x['ws_uuid'],
                                'tls': {'enabled': True, 'server_name': d, 'alpn': ['http/1.1'], 'utls': {'enabled': True, 'fingerprint': 'chrome'}},
                                'transport': {'type': 'ws', 'path': it.get('path') or x['ws_path'], 'headers': {'Host': d},
                                              'max_early_data': 2048, 'early_data_header_name': 'Sec-WebSocket-Protocol'}}], 'cdn-' + n)
                else:
                    if not vl:
                        raise Fail('в channel нет VLESS')
                    if kind == 'relay':
                        tag = 'vless-relay-' + n
                        add(kind, [vless(tag, server=it.get('host') or it['server'], server_port=int(it['port']))], tag)
                    else:
                        h = hop_outbound(dict(it, name=n), prof)
                        tag = 'vless-sshhop-' + n
                        add(kind, [h, vless(tag, detour=h['tag'], server=s.server)], tag)
            except (KeyError, TypeError, ValueError, Fail) as e:
                miss['%s:%s' % (kind, it.get('name') or it.get('entry'))] = 'пропущен: ' + (str(e.args[0]) if e.args else e.__class__.__name__)
    if vl:
        add('vless', [vless('vless-direct', server=s.server)], 'vless-direct')
    seen = set()
    paths = [p for p in paths if not (p['name'] in seen or seen.add(p['name']))][:PATHS_MAX]
    return paths, miss


def make_config(s, ports, clash_port, secret):
    """Конфиг sing-box: вход direct 127.0.0.1:<порт> -> сервер:порт SSH для каждого пути, Clash API на 127.0.0.1 с secret.
    Нет tun, прокси, DNS и маршрутов системы. ports: {имя пути: порт}."""
    ins, rules, outs, tags = [], [], [], set()
    for p in s.paths:
        ins.append({'type': 'direct', 'tag': 'in-' + p['name'], 'listen': '127.0.0.1', 'listen_port': ports[p['name']],
                    'override_address': s.server, 'override_port': s.port})
        rules.append({'inbound': 'in-' + p['name'], 'outbound': p['final']})
        for o in copy.deepcopy(p['outs']):
            if o['tag'] in tags:
                continue
            tags.add(o['tag'])
            if o.get('type') in TCP_TYPES and not o.get('detour'):  # первое звено цепочки и одиночные TCP-пути
                o.update(KEEPALIVE)
            outs.append(o)
    return {'log': {'level': 'info', 'disable_color': True},  # level=info: строка "sing-box started" - событие готовности
            'inbounds': ins, 'outbounds': outs, 'route': {'rules': rules},
            'experimental': {'clash_api': {'external_controller': '127.0.0.1:%d' % clash_port, 'secret': secret}}}
