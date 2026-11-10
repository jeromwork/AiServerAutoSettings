import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import http from 'node:http';
import crypto from 'node:crypto';
import {spawnSync} from 'node:child_process';
import {pathToFileURL} from 'node:url';
import {connectAccount,normalizeKey} from './server-account.mjs';
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
    assert.throws(()=>normalizeKey('bad'));checks++;
    fs.writeFileSync(path.join(root,'shared-provider-marker'),'shared-native-auth');
    const one=await connectAccount({key},vendor,api,service,root);
    const bytes=fs.readFileSync(path.join(services.get(one.account).dir,'fixture-credentials.json'));
    check(!bytes.includes(key));check(stores.size===1 && one.ok);
    const again=await connectAccount({key:key+'\r\n'},vendor,api,service,root);
    check(again.account===one.account && accounts.size===1 && stores.size===1);
    check(fs.readFileSync(path.join(services.get(one.account).dir,'fixture-credentials.json')).equals(bytes));
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
        const value=await connectAccount({key:Buffer.alloc(32,3).toString('base64url')},()=>loadVendor(${JSON.stringify(packageRoot)}),async r=>r==='/v1/features'?{}:{token:'fixture-token'},async(id,dir)=>{
            const {persistence}=await loadVendor(${JSON.stringify(packageRoot)});
            const stored=await persistence.readCredentials();assert.equal(stored.encryption.type,'dataKey');assert.equal(stored.token,'fixture-token');
            assert.ok(dir.startsWith(home+'/secrets/'));
        },home);
        assert.ok(value.ok);
    `],{env:{...process.env,HOME:path.join(root,'isolated-package')},encoding:'utf8',timeout:30000});
    check(child.status===0); // Never print vendor diagnostics, even on test failure.
    console.log('OK: '+checks+' account checks (fake HTTP server; installed Happier protocol crypto; no live accounts)');
} finally {server.closeAllConnections();await new Promise(resolve=>server.close(resolve));fs.rmSync(root,{recursive:true,force:true});}
