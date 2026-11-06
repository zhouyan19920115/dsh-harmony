// 临时的假桥接/中继, 只为验证手机端的证书指纹弹窗。用完就删。
const http = require('http');

let sha = '8FADBB6C4E7A1B2C3D4E5F60718293A4B5C6D7E8F90A1B2C3D4E5F60718293A4';

const server = http.createServer((req, res) => {
  console.log(`[mock] ${req.method} ${req.url}`);
  if (req.url.startsWith('/api/v1/remote-config')) {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({
      available: true,
      relayUrl: 'https://relay.example.com:8443/dev-test',
      token: 'test-token',
      reason: ''
    }));
    return;
  }
  if (req.url.startsWith('/api/v1/relay/certificate')) {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({
      sha256: sha,
      host: '192.168.1.112',
      port: 9911,
      selfSigned: true
    }));
    return;
  }
  res.writeHead(404, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify({ error: 'not found' }));
});

server.listen(9911, '0.0.0.0', () => console.log('[mock] listening on 9911, sha=' + sha));

process.on('SIGTERM', () => { console.log('[mock] sha=' + sha); process.exit(0); });
