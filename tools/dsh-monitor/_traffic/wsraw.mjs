// wsraw.mjs — minimal raw RFC6455 client (no deps).
// Why not undici's global WebSocket? Because we need (a) the exact HTTP
// handshake response headers (to settle permessage-deflate) and (b) the exact
// on-the-wire frame byte count of every server->client frame.
import http from 'node:http';
import crypto from 'node:crypto';

export function wsConnect({ host, port, path, cookie, offerDeflate = false, timeoutMs = 20000 }) {
  return new Promise((resolve, reject) => {
    const key = crypto.randomBytes(16).toString('base64');
    const headers = {
      Connection: 'Upgrade',
      Upgrade: 'websocket',
      'Sec-WebSocket-Key': key,
      'Sec-WebSocket-Version': '13',
      Cookie: cookie
    };
    if (offerDeflate) headers['Sec-WebSocket-Extensions'] = 'permessage-deflate';

    const req = http.request({ host, port, path, headers, method: 'GET' });
    req.on('upgrade', (res, socket, head) => {
      socket.setNoDelay(true);
      resolve({ socket, responseHeaders: res.headers, statusCode: res.statusCode, head });
    });
    req.on('response', res => {
      let b = ''; res.on('data', d => (b += d)); res.on('end', () => reject(new Error(`HTTP ${res.statusCode} (no upgrade): ${b.slice(0, 300)}`)));
    });
    req.on('error', reject);
    req.setTimeout(timeoutMs, () => { req.destroy(new Error('ws handshake timeout')); });
    req.end();
  });
}

/** Frame parser: emits {opcode, fin, payload(Buffer), wireBytes, t} */
export function attachFrameReader(socket, onFrame, { onHandshakeLeftover } = {}) {
  let buf = Buffer.alloc(0);
  let fragments = [];
  let fragOpcode = 0;

  socket.on('data', chunk => {
    buf = Buffer.concat([buf, chunk]);
    for (;;) {
      if (buf.length < 2) return;
      const b0 = buf[0], b1 = buf[1];
      const fin = (b0 & 0x80) !== 0;
      const opcode = b0 & 0x0f;
      const masked = (b1 & 0x80) !== 0;
      let len = b1 & 0x7f;
      let off = 2;
      if (len === 126) { if (buf.length < off + 2) return; len = buf.readUInt16BE(off); off += 2; }
      else if (len === 127) {
        if (buf.length < off + 8) return;
        const hi = buf.readUInt32BE(off), lo = buf.readUInt32BE(off + 4);
        len = hi * 4294967296 + lo; off += 8;
      }
      let mask = null;
      if (masked) { if (buf.length < off + 4) return; mask = buf.subarray(off, off + 4); off += 4; }
      if (buf.length < off + len) return;
      let payload = Buffer.from(buf.subarray(off, off + len));
      if (masked) { for (let i = 0; i < payload.length; i++) payload[i] ^= mask[i & 3]; }
      const wireBytes = off + len;
      buf = buf.subarray(off + len);

      if (opcode === 0x8) { // close
        onFrame({ opcode, fin, payload, wireBytes, t: Date.now(), closed: true });
        return;
      }
      if (opcode === 0x9) { onFrame({ opcode, fin, payload, wireBytes, t: Date.now(), pong: true }); continue; }
      if (opcode === 0xa) { onFrame({ opcode, fin, payload, wireBytes, t: Date.now(), ping: true }); continue; }

      if (opcode === 0x0) {
        fragments.push(payload);
        if (fin) { const full = Buffer.concat(fragments); fragments = []; onFrame({ opcode: fragOpcode, fin, payload: full, wireBytes, t: Date.now(), fragmented: true }); }
      } else {
        if (!fin) { fragOpcode = opcode; fragments = [payload]; }
        else onFrame({ opcode, fin, payload, wireBytes, t: Date.now() });
      }
    }
  });
}

/** Send a masked text frame (client->server MUST be masked). */
export function sendText(socket, text) {
  const payload = Buffer.from(text, 'utf8');
  const len = payload.length;
  let header;
  if (len < 126) { header = Buffer.alloc(2); header[1] = 0x80 | len; }
  else if (len < 65536) { header = Buffer.alloc(4); header[1] = 0x80 | 126; header.writeUInt16BE(len, 2); }
  else { header = Buffer.alloc(10); header[1] = 0x80 | 127; header.writeBigUInt64BE(BigInt(len), 2); }
  header[0] = 0x81; // FIN + text
  const mask = crypto.randomBytes(4);
  const masked = Buffer.from(payload);
  for (let i = 0; i < masked.length; i++) masked[i] ^= mask[i & 3];
  socket.write(Buffer.concat([header, mask, masked]));
  return header.length + 4 + len; // bytes actually written on the wire
}

export function sendClose(socket) {
  try { socket.write(Buffer.from([0x88, 0x80, 0, 0, 0, 0])); } catch { /* ignore */ }
}
