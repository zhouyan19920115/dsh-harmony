// Byte faithful HTTP/1.1 request handling for the phone side of the relay.
//
// The relay is a dumb pipe: the bytes the phone sends must reach the desktop device *unchanged*
// (the `Authorization` header included) and the bytes the device answers must reach the phone
// unchanged (the `101 Switching Protocols` of a WebSocket upgrade included).
//
// The only thing the relay has to change is the request target: the phone addresses the relay
// with `/<deviceId>/api/v1/...` while the device expects `/api/v1/...`. This module therefore
// scans the outgoing byte stream, finds the request heads and rewrites the request line. Every
// other byte - header order, header casing, body framing (Content-Length *and* chunked) - is
// forwarded verbatim.
//
// The scanner is deliberately independent of Node's HTTP parser: it runs on the raw socket so
// that a keep alive connection can carry several requests, each with its own device prefix
// removed, while the bytes of the request bodies stay untouched.

/** Maximum size of a request head we are willing to buffer (16 KB). */
const MAX_HEAD_SIZE = 16 * 1024;

const CRLF = Buffer.from('\r\n');
const CRLFCRLF = Buffer.from('\r\n\r\n');
const EMPTY = Buffer.alloc(0);

/**
 * Split a request target into the device id and the path that is forwarded to the device.
 *
 * `/dev-8f2a/api/v1/health?x=1` -> `{ deviceId: 'dev-8f2a', rest: '/api/v1/health?x=1' }`
 *
 * @param {string} target the raw request target
 * @returns {{deviceId: string, rest: string}}
 */
export function splitDeviceTarget(target) {
  const raw = String(target ?? '');
  const queryIndex = raw.indexOf('?');
  const path = queryIndex === -1 ? raw : raw.slice(0, queryIndex);
  const query = queryIndex === -1 ? '' : raw.slice(queryIndex);
  const slash = path.indexOf('/', 1);
  if (slash === -1) return { deviceId: path.replace(/^\//u, ''), rest: `/${query}` };
  return { deviceId: path.slice(1, slash), rest: `${path.slice(slash)}${query}` };
}

/**
 * Remove the device prefix from a request target.
 *
 * @param {string} target the request target as sent by the phone
 * @param {string} prefix the device prefix, e.g. `/dev-8f2a`
 * @returns {string|null} the forwarded target, or `null` when the target does not carry the prefix
 */
export function stripDevicePrefix(target, prefix) {
  if (!target.startsWith(prefix)) return null;
  const rest = target.slice(prefix.length);
  if (rest === '') return '/';
  if (rest[0] === '/' || rest[0] === '?') return rest;
  return null;
}

/** Parse the request line and the headers of a request head. */
function parseHead(head) {
  const text = head.toString('latin1');
  const lines = text.split('\r\n');
  const requestLine = lines[0] ?? '';
  const firstSpace = requestLine.indexOf(' ');
  const secondSpace = firstSpace === -1 ? -1 : requestLine.indexOf(' ', firstSpace + 1);
  const method = firstSpace === -1 ? requestLine : requestLine.slice(0, firstSpace);
  const target = firstSpace === -1 || secondSpace === -1 ? '' : requestLine.slice(firstSpace + 1, secondSpace);
  const version = secondSpace === -1 ? '' : requestLine.slice(secondSpace + 1);

  const headers = new Map();
  for (const line of lines.slice(1)) {
    if (line === '') break;
    const colon = line.indexOf(':');
    if (colon === -1) continue;
    headers.set(line.slice(0, colon).trim().toLowerCase(), line.slice(colon + 1).trim());
  }

  const transferEncoding = headers.get('transfer-encoding') ?? '';
  const contentLength = headers.has('content-length') ? Number.parseInt(headers.get('content-length'), 10) : NaN;
  let bodyMode = 'none';
  if (transferEncoding.toLowerCase().includes('chunked')) bodyMode = 'chunked';
  else if (Number.isFinite(contentLength) && contentLength > 0) bodyMode = 'length';

  return { method, target, version, headers, bodyMode, contentLength: Number.isFinite(contentLength) ? contentLength : 0 };
}

/**
 * Rewrite one request head: the device prefix is removed from the request target, every other
 * byte of the head stays exactly where it was.
 */
export function rewriteHead(head, prefix) {
  const request = parseHead(head);
  const stripped = prefix ? stripDevicePrefix(request.target, prefix) : null;
  if (stripped === null) return { head, request };

  // Locate the request target inside the raw head and splice the new target in.
  const headText = head.toString('latin1');
  const lineEnd = headText.indexOf('\r\n');
  const requestLine = lineEnd === -1 ? headText : headText.slice(0, lineEnd);
  const firstSpace = requestLine.indexOf(' ');
  const secondSpace = firstSpace === -1 ? -1 : requestLine.indexOf(' ', firstSpace + 1);
  if (firstSpace === -1 || secondSpace === -1) return { head, request };

  const targetStart = firstSpace + 1;
  const targetEnd = secondSpace;
  const newHead = Buffer.concat([
    head.subarray(0, targetStart),
    Buffer.from(stripped, 'latin1'),
    head.subarray(targetEnd),
  ]);
  return { head: newHead, request: { ...request, target: stripped } };
}

/**
 * Streams the bytes of the phone towards the device and rewrites the request targets.
 *
 * `push()` returns the bytes that have to be forwarded to the device. The bytes are returned
 * as soon as they are known, so a large body is never buffered as a whole.
 */
export class RequestRewriter {
  /**
   * @param {{prefix?: string, singleRequest?: boolean, dropTarget?: (target: string) => boolean}} options
   *   `prefix` the device prefix that is removed from the request targets
   *   `singleRequest` stop after the first request head (used for WebSocket upgrades, where the
   *   rest of the connection carries WebSocket frames instead of HTTP requests)
   *   `dropTarget` requests whose target matches are **not** forwarded to the device. The relay
   *   uses it for the endpoints it answers itself: the device would answer them with its own
   *   token check, and the extra answer on the connection would be read by the phone as the
   *   answer to its next request.
   */
  constructor({ prefix = '', singleRequest = false, dropTarget = null } = {}) {
    this.prefix = prefix;
    this.singleRequest = singleRequest;
    this.dropTarget = dropTarget;
    this.pending = EMPTY;
    this.state = 'head';
    this.bodyRemaining = 0;
    this.chunkRemaining = 0;
    this.heads = 0;
    this.requests = [];
    /** The request that is being read is not forwarded to the device. */
    this.dropping = false;
  }

  /** The requests that were seen so far (parsed, for logging and tests). */
  get parsedRequests() {
    return this.requests;
  }

  /**
   * Feed bytes into the rewriter.
   *
   * @param {Buffer} chunk
   * @returns {Buffer} the bytes that must be forwarded to the device
   */
  push(chunk) {
    if (chunk && chunk.length > 0) {
      this.pending = this.pending.length === 0 ? Buffer.from(chunk) : Buffer.concat([this.pending, chunk]);
    }
    const out = [];
    for (;;) {
      if (this.state === 'head') {
        if (this.singleRequest && this.heads > 0) {
          if (this.pending.length > 0) {
            out.push(this.pending);
            this.pending = EMPTY;
          }
          break;
        }
        const index = this.pending.indexOf(CRLFCRLF);
        if (index === -1) {
          if (this.pending.length > MAX_HEAD_SIZE) {
            throw new Error('the request head is too large');
          }
          break;
        }
        const head = this.pending.subarray(0, index + CRLFCRLF.length);
        this.pending = this.pending.subarray(index + CRLFCRLF.length);
        const rewritten = rewriteHead(head, this.prefix);
        this.heads += 1;
        this.requests.push(rewritten.request);
        // 中继自己回答的请求不转发给设备(但它的请求体还是要被读完, 否则下一条请求就乱了)。
        this.dropping = typeof this.dropTarget === 'function' && this.dropTarget(rewritten.request.target);
        if (!this.dropping) {
          out.push(rewritten.head);
        }
        if (rewritten.request.bodyMode === 'length') {
          this.bodyRemaining = rewritten.request.contentLength;
          this.state = 'body';
        } else if (rewritten.request.bodyMode === 'chunked') {
          this.state = 'chunk-size';
        } else {
          this.state = 'head';
        }
        continue;
      }

      if (this.state === 'body') {
        const take = Math.min(this.bodyRemaining, this.pending.length);
        if (take > 0) {
          if (!this.dropping) {
            out.push(this.pending.subarray(0, take));
          }
          this.pending = this.pending.subarray(take);
          this.bodyRemaining -= take;
        }
        if (this.bodyRemaining > 0) break;
        this.state = 'head';
        continue;
      }

      if (this.state === 'chunk-size') {
        const index = this.pending.indexOf(CRLF);
        if (index === -1) {
          if (this.pending.length > MAX_HEAD_SIZE) throw new Error('the chunk header is too large');
          break;
        }
        const line = this.pending.subarray(0, index).toString('latin1');
        const size = Number.parseInt(line.split(';')[0].trim(), 16);
        if (!Number.isFinite(size) || size < 0) throw new Error(`invalid chunk size "${line}"`);
        // The chunk header is forwarded verbatim.
        if (!this.dropping) {
          out.push(this.pending.subarray(0, index + CRLF.length));
        }
        this.pending = this.pending.subarray(index + CRLF.length);
        if (size === 0) {
          this.state = 'chunk-trailer';
        } else {
          this.chunkRemaining = size;
          this.state = 'chunk-data';
        }
        continue;
      }

      if (this.state === 'chunk-data') {
        const take = Math.min(this.chunkRemaining, this.pending.length);
        if (take > 0) {
          if (!this.dropping) {
            out.push(this.pending.subarray(0, take));
          }
          this.pending = this.pending.subarray(take);
          this.chunkRemaining -= take;
        }
        if (this.chunkRemaining > 0) break;
        this.state = 'chunk-crlf';
        continue;
      }

      if (this.state === 'chunk-crlf') {
        if (this.pending.length < 2) break;
        if (this.pending[0] !== 0x0d || this.pending[1] !== 0x0a) {
          throw new Error('a chunk is not terminated by CRLF');
        }
        if (!this.dropping) {
          out.push(this.pending.subarray(0, 2));
        }
        this.pending = this.pending.subarray(2);
        this.state = 'chunk-size';
        continue;
      }

      if (this.state === 'chunk-trailer') {
        const index = this.pending.indexOf(CRLF);
        if (index === -1) {
          if (this.pending.length > MAX_HEAD_SIZE) throw new Error('the chunk trailer is too large');
          break;
        }
        const line = this.pending.subarray(0, index);
        // The trailer (and its empty line) is forwarded verbatim.
        if (!this.dropping) {
          out.push(this.pending.subarray(0, index + CRLF.length));
        }
        this.pending = this.pending.subarray(index + CRLF.length);
        if (line.length === 0) {
          this.state = 'head';
        }
        continue;
      }

      break;
    }
    if (out.length === 0) return EMPTY;
    if (out.length === 1) return out[0];
    return Buffer.concat(out);
  }
}
