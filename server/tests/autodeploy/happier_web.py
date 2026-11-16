#!/usr/bin/env python3
"""Offline signed-mirror acceptance. Only Docker namespaces; no host services.

Usage: python3 server/tests/autodeploy/happier_web.py --release-dir /path/to/signed-ui
The directory must have the official archive/checksums/minisig (all verified).
No code from the archive is executed. Ubuntu packages are needed to build the image.
"""
import argparse
import os
from pathlib import Path
import subprocess
import sys
import time
import tempfile
import uuid

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
sys.path.insert(0,str(HERE.parent))
from resource_guard import wait_for_memory


def docker(*args, check=True, timeout=600):
    if args and args[0] in ('build','run') and not wait_for_memory():
        raise SystemExit(77)
    result = subprocess.run(['nice','-n','10','sudo','-n','docker',*map(str,args)],capture_output=True,text=True,timeout=timeout)
    if check and result.returncode:
        raise RuntimeError('Docker acceptance failed: ' + result.stderr[-4000:])
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--release-dir',default=os.environ.get('REMOTEAGENTS_HAPPIER_WEB_RELEASE_DIR'), required=not os.environ.get('REMOTEAGENTS_HAPPIER_WEB_RELEASE_DIR'))
    args = parser.parse_args()
    directory = Path(args.release_dir).resolve()
    checks = sorted(directory.glob('checksums-happier-ui-web-v*.txt'))
    if not checks:
        raise SystemExit('No signed mirror checksums')
    files = []
    for checksum in checks:
        version = checksum.name[len('checksums-happier-ui-web-v'):-4]
        files += [checksum,Path(str(checksum)+'.minisig'),directory/('happier-ui-web-v'+version+'-web-any.tar.gz')]
    if not all(p.is_file() for p in files):
        raise SystemExit('Incomplete signed mirror')
    image = 'ra-happier-web-' + uuid.uuid4().hex[:10]
    names = []
    try:
        docker('build','--target','happier-web','-t',image,HERE,timeout=900)
        with tempfile.TemporaryDirectory(prefix='ra-happier-export-') as tmp:
            for mode in ('source','target'):
                name = image + '-' + mode
                names.append(name)
                docker('run','-d','--memory','1500m','--memory-swap','1500m','--name',name,
                       '--privileged','--cgroupns=private','--tmpfs','/run','--tmpfs','/run/lock',
                       '--network','none','--mount','type=bind,src='+str(REPO)+',dst=/src,readonly',image)
                for _ in range(100):
                    if docker('exec',name,'systemctl','is-system-running',check=False).stdout.strip() in ('running','degraded'):
                        break
                    time.sleep(.2)
                else:
                    raise RuntimeError('Container systemd did not become ready')
                docker('exec',name,'systemctl','start','systemd-user-sessions.service')
                # /run is tmpfs: ssh.service creates its privilege-separation directory.
                docker('exec',name,'systemctl','start','ssh.service')
                docker('exec',name,'useradd','-m','-s','/bin/bash','worker')
                docker('exec',name,'mkdir','-p','/opt/ui-mirror')
                for path in files:
                    docker('cp',path,name+':/opt/ui-mirror/'+path.name)
                docker('exec',name,'chmod','-R','a+rX','/opt/ui-mirror')
                if mode == 'target':
                    docker('cp',Path(tmp)/'export.json',name+':/root/import.json')
                result = docker('exec','-e','REMOTEAGENTS_HAPPIER_WEB_RELEASE_DIR=/opt/ui-mirror',name,
                                'nice','-n','10','python3','-I','/src/server/tests/autodeploy/happier_web_fixture.py',mode,timeout=600)
                print(result.stdout,end='',flush=True)
                if mode == 'source':
                    docker('cp',name+':/root/export.json',Path(tmp)/'export.json')
                    # sudo docker cp preserves the root-owned export's 0600.
                    assert (Path(tmp)/'export.json').stat().st_mode & 0o777 == 0o600
                # Never keep two systemd containers alive concurrently.
                docker('rm','-f',name)
    finally:
        for name in names:
            docker('rm','-f',name,check=False)
        docker('image','rm',image,check=False)


if __name__ == '__main__':
    main()
