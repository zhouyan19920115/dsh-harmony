// Minimal asar reader: list / extract files from an Electron app.asar without npm install.
// asar layout: 4-byte headerSize, 4-byte jsonSize, 4-byte jsonPickleSize, 4-byte dataSize,
// then the JSON header, then the file data at baseOffset.
import { readFileSync, writeFileSync, mkdirSync, existsSync, readdirSync, statSync } from 'node:fs';
import { dirname, join, relative } from 'node:path';

const asarPath = process.argv[2];
const mode = process.argv[3] || 'list';
const filter = process.argv[4] || '';
const outDir = process.argv[5] || '';

const fd = readFileSync(asarPath);
const headerSize = fd.readUInt32LE(4);
const headerJsonSize = fd.readUInt32LE(12);
const headerJson = JSON.parse(fd.subarray(16, 16 + headerJsonSize).toString('utf8'));
const baseOffset = 8 + headerSize;

function walk(node, prefix = '') {
  const out = [];
  for (const [name, entry] of Object.entries(node.files || {})) {
    const p = prefix ? `${prefix}/${name}` : name;
    if (entry.files) out.push(...walk(entry, p));
    else out.push({ path: p, size: entry.size, offset: entry.offset });
  }
  return out;
}
const all = walk(headerJson);

if (mode === 'list') {
  const re = filter ? new RegExp(filter, 'i') : null;
  for (const f of all) {
    if (!re || re.test(f.path)) console.log(`${String(f.size).padStart(10)}  ${f.path}`);
  }
} else if (mode === 'extract') {
  const re = new RegExp(filter, 'i');
  let n = 0;
  for (const f of all) {
    if (!re.test(f.path)) continue;
    const data = fd.subarray(baseOffset + Number(f.offset), baseOffset + Number(f.offset) + f.size);
    const dest = join(outDir, f.path);
    mkdirSync(dirname(dest), { recursive: true });
    writeFileSync(dest, data);
    n++;
  }
  console.log(`extracted ${n} files -> ${outDir}`);
}
