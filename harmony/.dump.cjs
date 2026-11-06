const fs = require('fs');
const path = process.argv[2];
const mode = process.argv[3] || 'all';
const j = JSON.parse(fs.readFileSync(path, 'utf8'));
const out = [];
const walk = (n) => {
  if (!n) return;
  const a = n.attributes || {};
  if (mode === 'inputs') {
    if (a.type === 'TextInput') out.push('INPUT value=' + JSON.stringify(a.value || '') + ' | ' + a.bounds);
  } else if (mode === 'buttons') {
    if (a.type === 'Button') out.push('BTN ' + JSON.stringify(a.text || '') + ' | ' + a.bounds);
  } else {
    if (a.text && String(a.text).trim().length > 0) out.push(String(a.text).replace(/\n/g, ' / ').slice(0, 60) + ' | ' + a.bounds);
  }
  (n.children || []).forEach(walk);
};
walk(j);
console.log(out.join('\n'));
