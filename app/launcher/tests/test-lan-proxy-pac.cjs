const fs = require('fs'), vm = require('vm'), assert = require('assert');
let dnsCalls = 0;
const ip = x => x.split('.').reduce((n, s) => (n << 8) | Number(s), 0);
const ctx = vm.createContext({
  isInNet: (h, n, m) => (ip(h) & ip(m)) === ip(n),
  shExpMatch: (h, p) => new RegExp('^' + p.replace(/[.+^${}()|[\]\\]/g, '\\$&').replace(/\*/g, '.*') + '$').test(h),
  dnsResolve: () => { dnsCalls++; throw new Error('local DNS forbidden'); }
});
vm.runInContext(fs.readFileSync(process.argv[2], 'utf8'), ctx, {timeout: 100});
for (const [url, host, proxied] of [
  ['https://10.123.0.1/', '10.123.0.1', true],
  ['http://10.124.0.1/', '10.124.0.1', false],
  ['https://A.EXAMPLE.ORG/', 'A.EXAMPLE.ORG', true],
  ['https://example.org/', 'example.org', false],
  ['https://notexample.org/', 'notexample.org', false],
  ['https://exact.example.net/', 'exact.example.net', true],
  ['http://db.example.net:5432/', 'db.example.net', true],
  ['http://db.example.net/', 'db.example.net', false],
  ['http://db.example.net:5433/', 'db.example.net', false],
  ['https://public.example.com/', 'public.example.com', false]
]) assert.equal(ctx.FindProxyForURL(url, host), proxied ? 'PROXY 127.0.0.1:17880' : 'DIRECT', url);
assert.equal(dnsCalls, 0);
console.log('PASS: PAC destinations, ports, case, wildcard boundary, no local DNS');
