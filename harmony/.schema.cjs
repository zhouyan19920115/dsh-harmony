const fs = require('fs');
const s = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const app = s.properties && s.properties.app;
if (!app) { console.log('no app'); process.exit(0); }
console.log('additionalProperties:', JSON.stringify(app.additionalProperties));
const pn = app.propertyNames;
if (pn) {
  console.log('propertyNames keys:', Object.keys(pn).join(', '));
  if (pn.enum) { console.log('enum:'); pn.enum.forEach(n => console.log('   ' + n)); }
}
const props = app.properties || {};
console.log('app properties:');
Object.keys(props).forEach(k => console.log('   ' + k + ' :: ' + JSON.stringify(props[k]).slice(0, 160)));
