#!/usr/bin/env python3
import json,sys
from pathlib import Path
state=Path('/var/lib/tailscale-fixture')
if sys.argv[1]=='status':print(json.dumps({'BackendState':'Running' if state.exists() else 'NeedsLogin','Self':{'HostName':'fixture'}}))
elif sys.argv[1]=='debug':print('{}')
elif sys.argv[1]=='up':
 arg=next(a for a in sys.argv if a.startswith('--auth-key=file:'))
 assert Path(arg.split('file:',1)[1]).read_text()=='TS_SENTINEL'
 assert '--accept-dns=false' in sys.argv and '--accept-routes=false' in sys.argv
 assert '--tun=userspace-networking' in Path('/etc/default/tailscaled').read_text()
 state.write_text('Running')
