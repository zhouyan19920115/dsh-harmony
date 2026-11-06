const fs = require('fs');
const path = process.argv[2];
const t = fs.readFileSync(path, 'utf8');
function list(label, re) {
  const out = new Set();
  let m;
  while ((m = re.exec(t)) !== null) {
    m[1].split(',').forEach(x => {
      const v = x.replace(/[\s"]/g, '');
      if (v.length) out.add(v);
    });
  }
  console.log(label + ':');
  Array.from(out).sort().forEach(v => console.log('  ' + v));
}
list('ACTIONS', /"actions": \[([^\]]*)\]/g);
list('ENTITIES', /"entities": \[([^\]]*)\]/g);
list('URIS', /"uris": \[([^\]]*)\]/g);
list('MIMES', /"supportMimeTypes": \[([^\]]*)\]/g);
list('SCHEME', /"scheme": "([^"]*)"/g);
list('HOST', /"host": "([^"]*)"/g);
list('PATH', /"path": "([^"]*)"/g);
list('EXTENSIONS', /"extension": "([^"]*)"/g);
