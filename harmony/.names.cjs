const fs = require('fs');
const t = fs.readFileSync(process.argv[2], 'utf8');
const m = [...t.matchAll(/"name": "([A-Za-z0-9_.]+)"/g)].map(x => x[1]);
console.log([...new Set(m)].join('\n'));
