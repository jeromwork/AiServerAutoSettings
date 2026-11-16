// Minisign's two Ed25519 signatures, including the authenticated trusted comment.
// Matches Happier packages/release-runtime/src/minisign.ts; no npm dependencies.
'use strict';
const {createHash, createPublicKey, verify} = require('node:crypto');
const fs = require('node:fs');
const PUBLIC_KEY = 'RWQ85PZ7FyiukYbL3qv/bKnwgbT68wLVzotapeMFIb8n+c7pBQ7U8W2t';
function decode(line, size) {
    if (!/^[A-Za-z0-9+/]+={0,2}$/.test(line)) throw Error('base64');
    const b = Buffer.from(line, 'base64');
    if (b.length !== size) throw Error('size');
    return b;
}
function verifyMinisign(message, sigFile, publicKey = PUBLIC_KEY) {
    try {
        const pub = decode(publicKey, 42);
        const lines = sigFile.replace(/\r/g, '').trimEnd().split('\n');
        if (lines.length !== 4 || !lines[2].startsWith('trusted comment: ')) return false;
        const sig = decode(lines[1], 74), global = decode(lines[3], 64);
        if (pub.subarray(0, 2).toString() !== 'Ed' || !pub.subarray(2, 10).equals(sig.subarray(2, 10))) return false;
        const algorithm = sig.subarray(0, 2).toString();
        if (!['ED', 'Ed'].includes(algorithm)) return false;
        const key = createPublicKey({key: Buffer.concat([Buffer.from('302a300506032b6570032100', 'hex'), pub.subarray(10)]), format: 'der', type: 'spki'});
        const payload = algorithm === 'ED' ? createHash('blake2b512').update(message).digest() : message;
        return verify(null, payload, key, sig.subarray(10)) &&
            verify(null, Buffer.concat([sig.subarray(10), Buffer.from(lines[2].slice(17))]), key, global);
    } catch { return false; }
}
module.exports = {verifyMinisign, PUBLIC_KEY};
if (require.main === module) {
    try {
        if (!verifyMinisign(fs.readFileSync(process.argv[2]), fs.readFileSync(process.argv[3], 'utf8'))) process.exitCode = 1;
    } catch { process.exitCode = 1; }
    if (process.exitCode) process.stderr.write('Release signature rejected\n');
}
