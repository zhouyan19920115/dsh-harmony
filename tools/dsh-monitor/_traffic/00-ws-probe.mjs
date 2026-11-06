// 00-ws-probe.mjs — settle permessage-deflate, in three parts:
//  A) local echo server records the EXACT handshake headers Node's global
//     WebSocket (undici) sends.
//  B) raw handshake to DSH /api/remote.mux OFFERING permessage-deflate
//     -> does the DSH server accept it?
//  C) raw handshake to DSH /api/remote.mux WITHOUT offering it (what a plain
//     Node client actually gets) -> negotiated extension?
import http from 'node:http';
import { DshClient } from '../dsh-client.mjs';
import { wsConnect } from './wsraw.mjs';

const results = { undiciClientHandshake: null, dshWithDeflateOffer: null, dshWithoutDeflateOffer: null };

// ---------- A) what does undici's global WebSocket send? ----------
await new Promise(resolve => {
  const srv = http.createServer();
  srv.on('upgrade', (req, socket) => {
    results.undiciClientHandshake = { headers: req.headers };
    socket.write('HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: 1\r\n\r\n');
    setTimeout(() => { try { socket.destroy(); } catch {} srv.close(() => resolve()); }, 300);
  });
  srv.listen(0, '127.0.0.1', () => {
    const port = srv.address().port;
    const ws = new WebSocket(`ws://127.0.0.1:${port}/x`);
    ws.onerror = () => {};
    setTimeout(() => { try { ws.close(); } catch {} }, 500);
  });
});

const c = new DshClient();
const [host, portStr] = c.authority.split(':');
const port = Number(portStr);

// ---------- B) DSH handshake, offering permessage-deflate ----------
for (const [key, offer] of [['dshWithDeflateOffer', true], ['dshWithoutDeflateOffer', false]]) {
  try {
    const { socket, responseHeaders, statusCode } = await wsConnect({
      host, port, path: '/api/remote.mux', cookie: c.cookie, offerDeflate: offer
    });
    results[key] = { statusCode, responseHeaders, offered: offer ? 'permessage-deflate' : null };
    socket.destroy();
  } catch (e) {
    results[key] = { error: String(e.message), offered: offer ? 'permessage-deflate' : null };
  }
}

console.log(JSON.stringify(results, null, 2));
