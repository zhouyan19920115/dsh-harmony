// Simulate what the app does with the relay's desktop package:
//   HEAD  → version + size + sha256
//   GET   → the bytes, check the size and the SHA-256
//   a second time: the same version → reuse (no download)
const crypto = require('node:crypto');
const fs = require('node:fs');

const base = process.argv[2] ?? 'http://127.0.0.1:8794';
const url = `${base}/_dsh/desktop-package`;
const cacheFile = 'tools/_app-sim-package.bin';
const stateFile = 'tools/_app-sim-version.txt';

function headerOf(response, name) {
  return response.headers.get(name) ?? '';
}

(async () => {
  // 1. the head request: what version is it now?
  const head = await fetch(url, { method: 'HEAD' });
  const version = headerOf(head, 'x-dsh-package-version');
  const sha256 = (headerOf(head, 'x-dsh-package-sha256') ?? '').toLowerCase();
  const size = Number.parseInt(headerOf(head, 'content-length') ?? '0', 10);
  console.log(`  HEAD  HTTP ${head.status} | version=${version} | size=${size} | sha256=${sha256}`);

  // 2. the cached copy: same version → reuse it, no download.
  const stored = fs.existsSync(stateFile) ? fs.readFileSync(stateFile, 'utf8').trim() : '';
  const cached = fs.existsSync(cacheFile) ? fs.statSync(cacheFile).size : 0;
  if (stored === version && cached === size && stored.length > 0) {
    console.log(`  the cached copy is version ${stored} (${cached} bytes) -> reused, no download ✓`);
    return;
  }
  console.log('  the cached copy is missing or stale -> download');

  // 3. the download.
  const res = await fetch(url);
  if (res.status !== 200) throw new Error(`HTTP ${res.status}`);
  const bytes = Buffer.from(await res.arrayBuffer());
  if (bytes.length !== size) throw new Error(`size: ${bytes.length} != ${size}`);
  const mine = crypto.createHash('sha256').update(bytes).digest('hex');
  if (sha256.length === 64 && mine !== sha256) throw new Error(`sha256: ${mine} != ${sha256}`);
  console.log(`  GET   ${bytes.length} bytes | the SHA-256 matches: ${mine === sha256} ✓`);
  fs.writeFileSync(cacheFile, bytes);
  fs.writeFileSync(stateFile, version);
  console.log('  written to the cache');
})().catch((error) => {
  console.log(`  ERR ${error.message}`);
  process.exitCode = 1;
});
