// Real ui-web in Chrome; Node built-ins only. Every external HTTP request is intercepted.
const {spawn} = require('node:child_process');
const {verify, createPublicKey, createPrivateKey} = require('node:crypto');
const assert = require('node:assert/strict');
const [origin, profile] = process.argv.slice(2);
const jsDelayMs = Number(process.env.HAPPIER_TEST_JS_DELAY_MS || 0);
assert(Number.isFinite(jsDelayMs) && jsDelayMs >= 0, 'invalid UI script delay');
const chrome = spawn('/usr/bin/google-chrome', ['--headless', '--no-sandbox', '--disable-gpu',
    '--disable-dev-shm-usage', '--disable-background-networking', '--disable-sync', '--disable-extensions',
    '--no-first-run', '--no-default-browser-check', '--no-proxy-server',
    '--host-resolver-rules=MAP * ~NOTFOUND, EXCLUDE 127.0.0.1',
    '--user-data-dir=' + profile, '--remote-debugging-pipe'],
    {stdio: ['ignore', 'ignore', 'pipe', 'pipe', 'pipe']});
let seq = 0, buffer = '', session, calls = [], fatal;
let closingChrome = false, delayNativeLogin = true, delayedScripts = 0;
const waiting = new Map();
function pipeError(error) {
    if (closingChrome && ['ECONNRESET', 'EPIPE'].includes(error.code)) return;
    fatal = error;
    process.exitCode = 1;
    console.error('Chrome CDP pipe error:', error);
    for (const callback of waiting.values()) callback.reject(error);
    waiting.clear();
}
chrome.stdio[3].on('error', pipeError);
chrome.stdio[4].on('error', pipeError);
function closeChrome() {
    closingChrome = true;
    chrome.kill('SIGKILL');
}
function send(method, params = {}, sid = session) {
    const id = ++seq;
    return new Promise((resolve, reject) => {
        waiting.set(id, {resolve, reject});
        chrome.stdio[3].write(JSON.stringify({id, method, params, ...(sid ? {sessionId: sid} : {})}) + '\0');
    });
}
chrome.stdio[4].on('data', data => {
    buffer += data;
    for (let end; (end = buffer.indexOf('\0')) !== -1;) {
        const msg = JSON.parse(buffer.slice(0, end)); buffer = buffer.slice(end + 1);
        if (msg.id) {
            const callback = waiting.get(msg.id); waiting.delete(msg.id);
            if (msg.error) callback?.reject(Error(msg.error.message)); else callback?.resolve(msg.result);
        } else if (msg.method === 'Fetch.requestPaused') intercept(msg.params, msg.sessionId).catch(e => {
            // Navigation cancels in-flight requests from the previous document.
            if (!e.message.includes('Invalid InterceptionId')) fatal = e;
        });
    }
});
chrome.stderr.resume();
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
const key = Array(10).fill('AAAAA').concat('AA').join('-'); // public test seed: 32 zero bytes
const token = Buffer.from('{}').toString('base64url') + '.' +
    Buffer.from(JSON.stringify({sub:'ra-browser-fixture', exp:4102444800})).toString('base64url') + '.fixture';
async function intercept({requestId, request, resourceType}, sid) {
    assert(!request.url.includes(key), 'secret in request URL');
    if (request.url.startsWith(origin + '/')) {
        // Delay only vendor scripts for the first login; the handoff add-on runs immediately.
        if (delayNativeLogin && jsDelayMs && resourceType === 'Script' &&
            new URL(request.url).pathname !== '/_remoteagents/addon.js') {
            delayedScripts++;
            await sleep(jsDelayMs);
        }
        return send('Fetch.continueRequest', {requestId}, sid);
    }
    const url = new URL(request.url);
    calls.push({path: url.pathname, method: request.method});
    let body = {}, responseCode = 200;
    if (url.origin !== 'https://api.happier.dev') responseCode = 404;
    else if (request.method === 'OPTIONS') body = {};
    else if (url.pathname === '/v1/auth') {
        assert.equal(request.method, 'POST');
        const payload = JSON.parse(request.postData);
        assert.deepEqual(Object.keys(payload).sort(), ['challenge', 'publicKey', 'signature']);
        const pk = Buffer.from(payload.publicKey, 'base64');
        assert.equal(pk.length, 32);
        const expected = createPublicKey(createPrivateKey({key:Buffer.concat([Buffer.from('302e020100300506032b657004220420','hex'), Buffer.alloc(32)]), format:'der', type:'pkcs8'})).export({format:'der',type:'spki'}).subarray(-32);
        assert.deepEqual(pk, expected, 'restore must authenticate the supplied account');
        const pub = createPublicKey({key: Buffer.concat([Buffer.from('302a300506032b6570032100', 'hex'), pk]), format:'der', type:'spki'});
        assert(verify(null, Buffer.from(payload.challenge, 'base64'), pub, Buffer.from(payload.signature, 'base64')));
        body = {token};
        if (rejectAuth) {responseCode = 401; body = {error:'invalid_signature'};}
    } else if (url.pathname === '/health' || url.pathname === '/v1/auth/ping') {
        body = {status:'ok'};
    } else if (url.pathname === '/v1/features') {
        body = {features:{auth:{login:{keyChallenge:{enabled:true}}}}, capabilities:{}};
    } else if (url.pathname === '/v1/account/profile') {
        body = {id:'ra-browser-fixture', timestamp:0, firstName:null, lastName:null, username:null, avatar:null, linkedProviders:[]};
    } else if (/sessions|machines|artifacts/.test(url.pathname)) body = {sessions:[], machines:[], artifacts:[], hasNext:false};
    else responseCode = 404;
    await send('Fetch.fulfillRequest', {requestId, responseCode,
        responseHeaders:[{name:'Content-Type',value:'application/json'}, {name:'Access-Control-Allow-Origin',value:'*'}, {name:'Access-Control-Allow-Methods',value:'GET, POST, OPTIONS'}, {name:'Access-Control-Allow-Headers',value:'*'}],
        body:Buffer.from(JSON.stringify(body)).toString('base64')}, sid);
}
async function evaluate(expression) {
    const result = await send('Runtime.evaluate', {expression, returnByValue:true, awaitPromise:true});
    if (result.exceptionDetails) throw Error(result.exceptionDetails.text);
    return result.result.value;
}
async function until(expression, label, timeoutMs = 20000) {
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
        if (fatal) throw fatal;
        try {if (await evaluate(`Boolean(${expression})`)) return;} catch (e) {if (!e.message.includes('context')) throw e;}
        await sleep(100);
    }
    throw Error('Timeout: ' + label + '; calls: ' + JSON.stringify(calls) + '; state: ' + await evaluate(`JSON.stringify({path:location.pathname, text:document.body?.innerText.slice(0,500),keys:Object.keys(localStorage), pending:sessionStorage.length})`));
}
const credentials = `Object.fromEntries(Object.keys(localStorage).filter(k=>k==='auth_credentials'||k.startsWith('auth_credentials__srv_')).map(k=>[k,localStorage.getItem(k)]))`;
const authCalls = () => calls.filter(x=>x.path === '/v1/auth' && x.method === 'POST').length;
let rejectAuth = false;
(async () => {
    const {targetId} = await send('Target.createTarget', {url:'about:blank'}, null);
    session = (await send('Target.attachToTarget', {targetId, flatten:true}, null)).sessionId;
    await send('Page.enable');
    await send('Runtime.enable');
    await send('Network.enable');
    await send('Network.setBlockedURLs', {urls:['ws://*', 'wss://*']});
    await send('Fetch.enable', {patterns:[{urlPattern:'*'}]});
    await send('Page.navigate', {url:origin + '/?handoff=kept#ra-login=' + key});
    await until(`Object.keys(${credentials}).length === 1`, 'native login saves credentials', 20000 + jsDelayMs);
    delayNativeLogin = false;
    if (jsDelayMs) assert(delayedScripts > 0, 'UI scripts must actually be delayed');
    assert.equal(authCalls(), 1);
    assert.equal(await evaluate('location.hash'), '');
    assert.equal(await evaluate('location.search'), '?handoff=kept');
    assert.equal(await evaluate(`sessionStorage.getItem('remoteagents.happier-login')`), null);
    const saved = await evaluate(credentials);
    const value = JSON.parse(Object.values(saved)[0]);
    assert.equal(value.token, token);
    assert.equal(value.secret, Buffer.alloc(32).toString('base64url'));
    assert(Object.keys(saved)[0].startsWith('auth_credentials__srv_'));
    // Same origin reopen: preserve a different existing account, no auth attempt.
    const different = JSON.stringify({token, secret:Buffer.alloc(32, 1).toString('base64url')});
    await evaluate(`localStorage.setItem(${JSON.stringify(Object.keys(saved)[0])},${JSON.stringify(different)})`);
    await send('Page.navigate', {url:origin + '/?existing=1#ra-login=' + key});
    await until(`document.getElementById('remoteagents-quotas') && !location.hash`, 'existing account page');
    await sleep(1200);
    assert.equal(authCalls(), 1);
    assert.equal(Object.values(await evaluate(credentials))[0], different);
    assert.equal(await evaluate('location.pathname'), '/');
    // A token-only credential for another server also prevents replacement.
    await evaluate(`localStorage.clear(); localStorage.setItem('auth_credentials__srv_other',JSON.stringify({token:'other-token'}))`);
    await send('Page.navigate', {url:origin + '/#ra-login=' + key});
    await until(`document.getElementById('remoteagents-quotas') && !location.hash`, 'other server account page');
    await sleep(600);
    assert.equal(authCalls(), 1);
    assert.equal(await evaluate(`localStorage.getItem('auth_credentials__srv_other')`), '{"token":"other-token"}');
    await evaluate('localStorage.clear(); sessionStorage.clear()');
    await send('Page.navigate', {url:origin + '/?invalid=1#ra-login=bad-key'});
    await until(`document.querySelector('[data-testid="welcome-decision-panel"]') && !location.hash`, 'invalid key ordinary welcome');
    assert.equal(await evaluate('location.pathname + location.search'), '/?invalid=1');
    assert.equal(authCalls(), 1);
    assert.deepEqual(await evaluate(credentials), {});
    // No handoff on repeat opening: no auth and no implicit account creation.
    await send('Page.navigate', {url:origin + '/'});
    await until(`document.querySelector('[data-testid="welcome-decision-panel"]')`, 'repeat ordinary welcome');
    await sleep(600);
    assert.equal(authCalls(), 1);
    // Rejection consumes the handoff too; reload must not retry.
    rejectAuth = true;
    await send('Page.navigate', {url:origin + '/#ra-login=' + key});
    await until(`document.querySelector('[data-testid="restore-manual-secret-input"]')?.value === '' && sessionStorage.getItem('remoteagents.happier-login') === null`, 'failed restore form');
    for (let i=0; i<100 && authCalls() !== 2; i++) await sleep(100);
    assert.equal(authCalls(), 2);
    assert.deepEqual(await evaluate(credentials), {});
    await send('Page.reload');
    await until(`document.querySelector('[data-testid="restore-manual-submit"]')`, 'reload after failed login');
    await sleep(1200);
    assert.equal(authCalls(), 2);
    assert.equal(await evaluate('location.hash'), '');
    assert(!calls.some(x=>x.method === 'POST' && !['/v1/auth', '/v1/kv/bulk'].includes(x.path)), 'unexpected signup or mutation');
    if (fatal) throw fatal;
    if (jsDelayMs) console.log(`PASS: UI script delay ${jsDelayMs} ms, ${delayedScripts} intercepted scripts`);
    console.log('PASS: official ui-web native login, signed challenge, fragment/query, existing accounts, invalid/missing key, single failed attempt');
})().catch(e => {console.error(e); process.exitCode=1;}).finally(closeChrome);
process.on('exit', closeChrome);
setTimeout(() => {console.error('Chrome login deadline'); process.exit(1);}, 90000 + jsDelayMs).unref();
