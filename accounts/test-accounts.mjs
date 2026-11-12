import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import http from 'node:http';
import crypto from 'node:crypto';
import {spawnSync,spawn} from 'node:child_process';
import {pathToFileURL} from 'node:url';
import {connectAccount as connectRaw,normalizeKey,listAccounts,accountLabel,inspectAccount} from './server-account.mjs';
const connectAccount=(input,...args)=>connectRaw({serverUrl:'https://api.example.invalid',webappUrl:'https://web.example.invalid',...input},...args);
const root=fs.mkdtempSync(path.join(os.tmpdir(),'happier-accounts-test-'));
const packageRoot=process.env.HAPPIER_TEST_PACKAGE_ROOT || path.dirname(fs.realpathSync(path.join(os.homedir(),'.local/bin/happier')));
const protocol=await import(pathToFileURL(path.join(packageRoot,'node_modules/@happier-dev/protocol/dist/index.js')));
let checks=0;const check=(value)=>{assert.ok(value);checks++;};
const accounts=new Map(), stores=new Map(), services=new Map();
const server=http.createServer(async(req,res)=>{
    res.setHeader('Content-Type','application/json');
    if(req.url==='/v1/features'){res.end(JSON.stringify({features:{sharing:{contentKeys:{enabled:true}}}}));return;}
    if(req.url==='/v1/machines'){res.end('[]');return;}
    let raw='';for await(const c of req)raw+=c;const body=JSON.parse(raw);
    const publicKey=crypto.createPublicKey({key:Buffer.concat([Buffer.from('302a300506032b6570032100','hex'),Buffer.from(body.publicKey,'base64')]),format:'der',type:'spki'});
    assert(crypto.verify(null,Buffer.from(body.challenge,'base64'),publicKey,Buffer.from(body.signature,'base64')));
    assert(crypto.verify(null,protocol.createAccountContentPublicKeyBindingMessage(Buffer.from(body.contentPublicKey,'base64')),publicKey,Buffer.from(body.contentPublicKeySig,'base64')));
    let restorable=false;
    for(const v of [7,8]) {
        try {
            protocol.assertAccountKeyProvisioningAllowed({mode:'e2ee',account:{publicKey:Buffer.from(body.publicKey,'base64').toString('hex'),contentPublicKey:body.contentPublicKey,contentPublicKeySig:body.contentPublicKeySig},material:{type:'legacy',secret:Buffer.alloc(32,v)}});
            restorable=true;
        }catch{}
    }
    assert.ok(restorable,'published account key must match native app recovery derivation');
    if(!accounts.has(body.publicKey))accounts.set(body.publicKey,{token:'fake-'+accounts.size,chats:['preserve-history']});
    res.end(JSON.stringify({token:accounts.get(body.publicKey).token}));
});
await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
const api=async(route,body,token)=>{const r=await fetch('http://127.0.0.1:'+server.address().port+route,{method:body?'POST':'GET',body:body?JSON.stringify(body):undefined,headers:token?{Authorization:'Bearer '+token}:{}});return r.json();};
const vendor=async dir=>({protocol,persistence:{writeCredentialsTokenOnly:async({token})=>{stores.get(dir).token=token;},readCredentials:async()=>{const c=stores.get(dir);return c?{token:c.token,encryption:{type:'dataKey',publicKey:c.publicKey,machineKey:c.machineKey}}:null;},writeCredentialsDataKey:async creds=>{stores.set(dir,creds);fs.writeFileSync(path.join(dir,'fixture-credentials.json'),JSON.stringify(creds));}}});
const service=async(id,dir)=>{if(!services.has(id))services.set(id,{dir,machine:'stable-'+services.size});};
try {
    const seed=Buffer.alloc(32,7), key=seed.toString('base64url');
    check(normalizeKey(key+'\r\n').equals(seed));
    check(normalizeKey('AAAAA-AAAAA-AAAAA-AAAAA-AAAAA-AAAAA-AAAAA-AAAAA-AAAAA-AAAAA-AA').equals(Buffer.alloc(32)));
    // Same vector as the launcher's HappierKey.Format test (shown once to the owner for the phone).
    check(normalizeKey('AEBAG-BAFAY-DQQCI-KBMGA-2DQPC-AIREE-YUCUL-BOGAZ-DINRY-HI6D4-QA').equals(Buffer.from(Array.from({length:32},(_,i)=>i+1))));
    assert.throws(()=>normalizeKey('bad'));checks++;
    fs.writeFileSync(path.join(root,'shared-provider-marker'),'shared-native-auth');
    const one=await connectAccount({key},vendor,api,service,root);
    const bytes=fs.readFileSync(path.join(services.get(one.account).dir,'fixture-credentials.json'));
    check(!bytes.includes(key));check(stores.size===1 && one.ok);
    check(listAccounts(root).accounts[0].label.startsWith('Без имени '));
    await connectAccount({key,label:'Мой аккаунт'},vendor,api,service,root);
    check(listAccounts(root).accounts[0].label==='Мой аккаунт');
    assert.throws(()=>accountLabel('bad\r\nlabel'));checks++;
    fs.chmodSync(services.get(one.account).dir,0o755);
    const again=await connectAccount({key:key+'\r\n'},vendor,api,service,root);
    check((fs.statSync(services.get(one.account).dir).mode & 0o777)===0o700);
    check(again.account===one.account && accounts.size===1 && stores.size===1);
    check(fs.readFileSync(path.join(services.get(one.account).dir,'fixture-credentials.json')).equals(bytes));
    await assert.rejects(connectAccount({key,expectedAccount:'b'.repeat(64),label:'someone else'},vendor,api,service,root));checks++;
    check(listAccounts(root).accounts[0].label==='Мой аккаунт');
    const machine=services.get(one.account).machine;
    const two=await connectAccount({key:Buffer.alloc(32,8).toString('base64url')},vendor,api,service,root);
    check(two.account!==one.account && accounts.size===2 && stores.size===2 && services.size===2);
    check(services.get(one.account).machine===machine);
    check([...accounts.values()].every(a=>a.chats[0]==='preserve-history'));
    check(fs.readFileSync(path.join(root,'shared-provider-marker'),'utf8')==='shared-native-auth');
    check([...services.values()].every(s=>s.dir.startsWith(path.join(root,'secrets'))));
    let failed=false;try{await connectAccount({key},vendor,async()=>{throw Error('offline');},service,root);}catch{failed=true;}
    check(failed && stores.size===2 && services.get(one.account).machine===machine);
    const badHome=path.join(root,'symlink-home');fs.mkdirSync(badHome);fs.symlinkSync(root,path.join(badHome,'secrets'));
    await assert.rejects(connectAccount({key},vendor,api,service,badHome));checks++;
    let denied=false;
    try{await connectAccount({key},vendor,async()=>({features:{auth:{login:{keyChallenge:{enabled:false}}}}}),service,root);}catch{denied=true;}
    check(denied && services.size===2 && stores.size===2);
    await assert.rejects(connectAccount({key:Buffer.alloc(32,9).toString('base64url')},vendor,async()=>({features:{auth:{login:{keyChallenge:{enabled:false}}}}}),service,root));
    check(listAccounts(root).accounts.length===2);
    let renewal=false;
    await connectAccount({key},vendor,async(route,body,token)=>{
        if(route==='/v1/machines' && token){renewal=true;throw Error('expired');}
        return api(route,body,token);
    },service,root);
    check(renewal && services.get(one.account).machine===machine);
    await assert.rejects(connectAccount({key},vendor,api,async()=>{throw Error('daemon offline');},root));checks++;
    // Exercise the real shipped persistence adapter in a fresh process with an isolated HOME.
    const child=spawnSync(process.execPath,['--input-type=module','-e',`
        import {connectAccount,loadVendor} from ${JSON.stringify(pathToFileURL(path.resolve('accounts/server-account.mjs')).href)};
        import assert from 'node:assert/strict';
        const home=process.env.HOME;
        const value=await connectAccount({key:Buffer.alloc(32,3).toString('base64url'),serverUrl:'https://api.example.invalid',webappUrl:'https://web.example.invalid'},()=>loadVendor(${JSON.stringify(packageRoot)}),async r=>r==='/v1/features'?{}:{token:'fixture-token'},async(id,dir)=>{
            const {persistence}=await loadVendor(${JSON.stringify(packageRoot)});
            const stored=await persistence.readCredentials();assert.equal(stored.encryption.type,'dataKey');assert.equal(stored.token,'fixture-token');
            assert.ok(dir.startsWith(home+'/secrets/'));
        },home);
        assert.ok(value.ok);
    `],{env:{...process.env,HOME:path.join(root,'isolated-package')},encoding:'utf8',timeout:30000});
    check(child.status===0); // Never print vendor diagnostics, even on test failure.
    // Happier's own install (~/.happier, its own daemon): listed and inspected like a program account, read only.
    const nativeHome=(base,sub,token='fake-token')=>{
        const dir=path.join(base,'.happier','servers','cloud');fs.mkdirSync(dir,{recursive:true});
        fs.writeFileSync(path.join(base,'.happier','settings.json'),JSON.stringify({schemaVersion:6,activeServerId:'cloud',servers:{cloud:{id:'cloud',serverUrl:'https://api.example.invalid/',webappUrl:'https://web.example.invalid'}},lastTokenSubByServerId:{cloud:sub}}));
        const jwt=['e30',Buffer.from(JSON.stringify({sub})).toString('base64url'),token].join('.');
        fs.writeFileSync(path.join(dir,'access.key'),JSON.stringify({token:jwt,encryption:{publicKey:'PUBLIC',machineKey:'NATIVE-MACHINE-KEY'}}),{mode:0o600});
        return jwt;
    };
    const only=path.join(root,'native-only');
    check(listAccounts(only).accounts.length===0); // no ~/.happier and no program accounts: nothing
    nativeHome(only,'acc-1');
    const listed=listAccounts(only).accounts;
    check(listed.length===1 && /^[a-f0-9]{64}$/.test(listed[0].account) && listed[0].serverUrl==='https://api.example.invalid' && listed[0].webappUrl==='https://web.example.invalid');
    const shown=JSON.stringify(listed);check(!shown.includes('fake-token') && !shown.includes('NATIVE-MACHINE-KEY') && !shown.includes('acc-1'));
    nativeHome(only,'acc-1','renewed-token');check(listAccounts(only).accounts[0].account===listed[0].account); // stable across token renewal
    nativeHome(only,'acc-2');check(listAccounts(only).accounts[0].account!==listed[0].account); // another login, another id
    const jwt=nativeHome(only,'acc-1');
    fs.rmSync(path.join(only,'.happier','servers','cloud','access.key'));check(listAccounts(only).accounts.length===0); // no credentials: not an account
    fs.writeFileSync(path.join(only,'.happier','access.key'),JSON.stringify({token:jwt,secret:'LEGACY'}));check(listAccounts(only).accounts[0]?.account===listed[0].account); // legacy key file
    nativeHome(only,'acc-1');
    // Native + program accounts side by side; ids never collide.
    nativeHome(root,'acc-1');
    const mixed=listAccounts(root).accounts;
    check(mixed.length===3 && mixed[0].account===listed[0].account && new Set(mixed.map(a=>a.account)).size===3 && mixed.some(a=>a.account===one.account));
    // inspect: a live daemon process from its state file + the server lists its machine as active for this token.
    const daemon=spawn(process.execPath,['-e','setTimeout(()=>{},60000)','daemon'],{stdio:'ignore'});
    try {
        const state=path.join(only,'.happier','servers','cloud','daemon.state.json');
        fs.writeFileSync(state,JSON.stringify({pid:daemon.pid,machineId:'machine-1',controlToken:'CONTROL'}));
        const before=fs.readdirSync(path.join(only,'.happier'),{recursive:true}).sort().map(f=>{const s=fs.statSync(path.join(only,'.happier',f));return f+':'+s.mtimeMs+':'+s.mode;}).join('|');
        let seen='';const answer=active=>async(url,options)=>{seen=url+' '+options.headers.Authorization;return {ok:true,json:async()=>[{id:'machine-1',active}]};};
        check((await inspectAccount(listed[0].account,only,answer(true))).ok===true && seen==='https://api.example.invalid/v1/machines Bearer '+jwt);
        check((await inspectAccount(listed[0].account,only,answer(false))).ok===false); // daemon present but the server sees it offline
        check((await inspectAccount(listed[0].account,only,async()=>({ok:false}))).ok===false); // expired/revoked token
        fs.writeFileSync(state,JSON.stringify({pid:process.pid,machineId:'machine-1'}));
        check((await inspectAccount(listed[0].account,only,answer(true))).ok===false); // pid alive but not a daemon
        fs.writeFileSync(state,JSON.stringify({pid:daemon.pid,machineId:'machine-1'}));
        const after=fs.readdirSync(path.join(only,'.happier'),{recursive:true}).sort().map(f=>{const s=fs.statSync(path.join(only,'.happier',f));return f+':'+s.mtimeMs+':'+s.mode;}).join('|');
        check(before.replace(/daemon\.state\.json:[^|]*/,'')===after.replace(/daemon\.state\.json:[^|]*/,'')); // inspect wrote/chmodded nothing
        daemon.kill();await new Promise(resolve=>daemon.once('exit',resolve));
        check((await inspectAccount(listed[0].account,only,answer(true))).ok===false); // daemon stopped
    } finally { daemon.kill(); }
    console.log('OK: '+checks+' account checks (fake HTTP server; installed Happier protocol crypto; fake ~/.happier; no live accounts)');
} finally {server.closeAllConnections();await new Promise(resolve=>server.close(resolve));fs.rmSync(root,{recursive:true,force:true});}
