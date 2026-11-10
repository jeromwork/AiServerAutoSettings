// Happier 0.2.17 adapter. Crypto and credential storage use the installed vendor package.
// stdin is private; stdout is deliberately limited to public account identity/health.
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import crypto from 'node:crypto';
import { pathToFileURL } from 'node:url';
import { spawnSync } from 'node:child_process';
export function normalizeKey(value) {
    const text = value.trim();
    if (/^[A-Za-z0-9_+\/-]{43}=?$/.test(text)) {
        const bytes = Buffer.from(text, 'base64url');
        if (bytes.length === 32) return bytes;
    }
    const clean = text.toUpperCase().replace(/0/g,'O').replace(/1/g,'I').replace(/8/g,'B').replace(/9/g,'G').replace(/[\s-]/g,'');
    if (!/^[A-Z2-7]{52}$/.test(clean)) throw Error('key');
    let bits=0, value32=0; const out=[];
    for (const c of clean) { value32=(value32<<5)|'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567'.indexOf(c); bits+=5; if(bits>=8){bits-=8;out.push((value32>>>bits)&255);} }
    return Buffer.from(out);
}
function safeDirectory(dir) {
    for(let p=dir;;p=path.dirname(p)) { if(fs.existsSync(p) && fs.lstatSync(p).isSymbolicLink()) throw Error('symlink'); if(path.dirname(p)===p) break; }
    fs.mkdirSync(dir,{recursive:true,mode:0o700});
}
export async function connectAccount(input, vendor, api, service, home=os.homedir()) {
    const seed=normalizeKey(input.key);
    const signing=crypto.createPrivateKey({key:Buffer.concat([Buffer.from('302e020100300506032b657004220420','hex'),seed]),format:'der',type:'pkcs8'});
    const pub=crypto.createPublicKey(signing).export({format:'der',type:'spki'}).subarray(-32);
    const endpoint=new URL(input.serverUrl || 'https://api.happier.dev');
    const web=new URL(input.webappUrl || 'https://cloud.happier.dev');
    if(endpoint.protocol!=='https:' || web.protocol!=='https:' || endpoint.username || endpoint.password || web.username || web.password || endpoint.pathname!=='/' || web.pathname!=='/' || endpoint.search || web.search || endpoint.hash || web.hash) throw Error('url');
    const id=crypto.createHash('sha256').update(pub).update(endpoint.origin).digest('hex');
    const dir=path.join(home,'secrets','happier','accounts',id);
    safeDirectory(dir);
    // Persist no recovery secret on the server; only vendor-derived terminal credentials.
    process.env.HAPPIER_HOME_DIR=dir;
    process.env.HAPPIER_SERVER_URL=endpoint.origin;
    process.env.HAPPIER_WEBAPP_URL=web.origin;
    const {protocol,persistence}=await vendor(dir);
    const challenge=crypto.randomBytes(32), b64=x=>Buffer.from(x).toString('base64');
    const body={publicKey:b64(pub),challenge:b64(challenge),signature:b64(crypto.sign(null,challenge,signing))};
    const features=await api('/v1/features');
    if(features?.features?.auth?.login?.keyChallenge?.enabled===false) throw Error('policy');
    const machineKey=protocol.deriveAccountMachineKeyFromRecoverySecret(seed);
    // machineKey already IS the X25519 scalar (the vendor helper hashed the content seed).
    // Deriving a seed keypair again would produce a different account key and break app restore.
    const contentPrivate=crypto.createPrivateKey({key:Buffer.concat([Buffer.from('302e020100300506032b656e04220420','hex'),Buffer.from(machineKey)]),format:'der',type:'pkcs8'});
    const contentKey=crypto.createPublicKey(contentPrivate).export({format:'der',type:'spki'}).subarray(-32);
    if(features?.features?.sharing?.contentKeys?.enabled===true) {
        body.contentPublicKey=b64(contentKey);
        body.contentPublicKeySig=b64(crypto.sign(null,protocol.createAccountContentPublicKeyBindingMessage(contentKey),signing));
        protocol.assertAccountKeyProvisioningAllowed({mode:'e2ee',account:{publicKey:pub.toString('hex'),contentPublicKey:body.contentPublicKey,contentPublicKeySig:body.contentPublicKeySig},material:{type:'legacy',secret:seed}});
    }
    const {token}=await api('/v1/auth',body);
    if(typeof token!=='string' || !token) throw Error('auth');
    const existing=await persistence.readCredentials();
    // Preserve machine identity and encryption. Only an expired/revoked token is renewed.
    if(!existing) await persistence.writeCredentialsDataKey({token,publicKey:contentKey,machineKey});
    else {
        if(existing.encryption?.type!=='dataKey' || !Buffer.from(existing.encryption.machineKey).equals(Buffer.from(machineKey)) || !Buffer.from(existing.encryption.publicKey).equals(Buffer.from(contentKey))) throw Error('credential-mismatch');
        try { await api('/v1/machines',undefined,existing.token); }
        catch { await persistence.writeCredentialsTokenOnly({token}); }
    }
    await service(id,dir);
    return {schema:1,ok:true,account:id,web:web.origin};
}
export async function loadVendor(root) {
    const files=fs.readdirSync(path.join(root,'package-dist'));
    const persistenceFile=files.find(x=>/^persistence-.*\.mjs$/.test(x));
    if(!persistenceFile) throw Error('vendor-layout');
    const protocol=await import(pathToFileURL(path.join(root,'node_modules/@happier-dev/protocol/dist/index.js')));
    const module=await import(pathToFileURL(path.join(root,'package-dist',persistenceFile)));
    const persistence=Object.values(module).find(x=>x && typeof x.readCredentials==='function' && typeof x.writeCredentialsDataKey==='function');
    if(!persistence) throw Error('vendor');
    return {protocol,persistence};
}
async function main() {
    let raw=''; for await(const chunk of process.stdin) {raw+=chunk;if(raw.length>8192) throw Error('input');}
    const input=JSON.parse(raw.replace(/\r/g,''));
    const binary=fs.realpathSync(path.join(os.homedir(),'.local/bin/happier'));
    const root=path.dirname(binary);
    // Fail closed on unsupported package layouts; never invent a credential format.
    const vendor=async()=>loadVendor(root);
    const api=async(route,body,token)=>{
        const r=await fetch(process.env.HAPPIER_SERVER_URL+route,{method:body?'POST':'GET',headers:{'Content-Type':'application/json',...(token?{Authorization:'Bearer '+token}:{})},body:body?JSON.stringify(body):undefined,signal:AbortSignal.timeout(15000)});
        if(!r.ok) throw Error('http');return r.json();
    };
    const service=async(id,dir)=>{
        const name='remoteagents-happier-'+id+'.service';
        const units=path.join(os.homedir(),'.config/systemd/user');safeDirectory(units);
        const unit=path.join(units,name);
        if(fs.existsSync(unit) && fs.lstatSync(unit).isSymbolicLink()) throw Error('symlink');
        // Never change/restart an existing unit. HOME stays shared for native provider subscriptions.
        if(!fs.existsSync(unit)) {
            const quote=x=>'"'+x.replace(/[%\\"]/g,c=>c==='%'?'%%':'\\'+c)+'"';
            fs.writeFileSync(unit,'[Unit]\nDescription=RemoteAgents Happier account\nAfter=network-online.target\n[Service]\nType=simple\nEnvironment='+quote('HAPPIER_HOME_DIR='+dir)+'\nEnvironment='+quote('HAPPIER_SERVER_URL='+process.env.HAPPIER_SERVER_URL)+'\nEnvironment='+quote('HAPPIER_WEBAPP_URL='+process.env.HAPPIER_WEBAPP_URL)+'\nEnvironment='+quote('PATH='+path.join(os.homedir(),'.local/share/remoteagents-accounts/node')+':'+path.join(os.homedir(),'.local/bin')+':/usr/local/bin:/usr/bin:/bin')+'\nExecStart='+quote(path.join(os.homedir(),'.local/bin/happier'))+' daemon start-sync\nRestart=on-failure\nRestartSec=5\nKillMode=process\nStandardOutput=null\nStandardError=null\n[Install]\nWantedBy=default.target\n',{mode:0o600,flag:'wx'});
        }
        const run=args=>{const r=spawnSync('systemctl',['--user',...args],{stdio:'ignore',timeout:30000});if(r.status!==0) throw Error('service');};
        run(['daemon-reload']);run(['enable',name]);run(['start',name]);run(['is-active','--quiet',name]);
        // Health is checked through an authenticated API request instead of a state marker.
        const {persistence}=await vendor();const credentials=await persistence.readCredentials();
        let healthy=false;
        for(let attempt=0;attempt<20;attempt++) {
            const settings=await persistence.readSettings();
            const r=await fetch(process.env.HAPPIER_SERVER_URL+'/v1/machines',{headers:{Authorization:'Bearer '+credentials.token},signal:AbortSignal.timeout(10000)});
            if(!r.ok) throw Error('health');
            const machines=await r.json();
            if(settings.machineId && Array.isArray(machines) && machines.some(m=>m.id===settings.machineId && m.active===true)){healthy=true;break;}
            await new Promise(resolve=>setTimeout(resolve,1000));
        }
        if(!healthy) throw Error('machine-offline');
    };
    process.stdout.write(JSON.stringify(await connectAccount(input,vendor,api,service))+'\n');
}
if(process.argv[1] && import.meta.url===pathToFileURL(process.argv[1]).href) main().catch(()=>{process.stderr.write('Happier: подключение аккаунта не подтверждено\n');process.exitCode=1;});
