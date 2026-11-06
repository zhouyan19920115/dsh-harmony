// The secrets of a device handshake.
//
// A token in the url of a WebSocket handshake ends up in the access log of every proxy on the
// way — and the relay is the one place that must not see the secrets in the clear. The device
// therefore offers them with the `Sec-WebSocket-Protocol` header of the handshake:
//
//   * `dsh-device.<deviceToken>`  — the token of the device;
//   * `dsh-account.<accountToken>` — the token of the account (only with an account);
//   * `dsh-account-id.<accountId>` — the account (not a secret, but it belongs with the rest).
//
// The header is not written into any log, and the relay echoes the protocol it picked, so the
// handshake stays a normal WebSocket handshake.

/** The prefix of the device token. */
export const DEVICE_PROTOCOL_PREFIX = 'dsh-device.';
/** The prefix of the account token. */
export const ACCOUNT_PROTOCOL_PREFIX = 'dsh-account.';
/** The prefix of the account id. */
export const ACCOUNT_ID_PROTOCOL_PREFIX = 'dsh-account-id.';

/**
 * The prefix of the **bridge token** — the token the phone holds.
 *
 * The desktop bridge announces it in its `HELLO` frame (the relay keeps only its hash), so the
 * relay can tell whether a client that connects to the phone side of the relay really is the
 * phone of that bridge. A client that prefers to authenticate during the handshake may offer it
 * with `dsh-bridge.<token>`; the phone itself authenticates with its first frame instead.
 */
export const BRIDGE_PROTOCOL_PREFIX = 'dsh-bridge.';

/**
 * The path the phone side of the relay uses for its WebSocket.
 *
 * The phone connects to `/<deviceId>/ws` (or `/<accountId>/<deviceId>/ws`); the relay strips
 * the device prefix and forwards `…/ws` to the device, whose own WebSocket lives at the same
 * path. The bridge knows the path as `WS_PATH` (`bridge/src/protocol.js`) — both sides have to
 * agree on it, `relay/test/run.js` checks that.
 */
export const PHONE_WS_PATH = '/ws';

/**
 * Read the secrets a device offered with its handshake.
 *
 * @param {import('node:http').IncomingMessage} request
 * @returns {{deviceToken: string, accountToken: string, accountId: string, bridgeToken: string, raw: string}}
 */
export function offeredRelayProtocols(request) {
  const header = request?.headers?.['sec-websocket-protocol'];
  const raw = typeof header === 'string' ? header : '';
  const parts = raw.split(',').map((part) => part.trim()).filter((part) => part.length > 0);
  let deviceToken = '';
  let accountToken = '';
  let accountId = '';
  let bridgeToken = '';
  for (const part of parts) {
    if (part.startsWith(DEVICE_PROTOCOL_PREFIX) && deviceToken.length === 0) {
      deviceToken = part.slice(DEVICE_PROTOCOL_PREFIX.length);
    } else if (part.startsWith(ACCOUNT_PROTOCOL_PREFIX) && accountToken.length === 0) {
      accountToken = part.slice(ACCOUNT_PROTOCOL_PREFIX.length);
    } else if (part.startsWith(ACCOUNT_ID_PROTOCOL_PREFIX) && accountId.length === 0) {
      accountId = part.slice(ACCOUNT_ID_PROTOCOL_PREFIX.length);
    } else if (part.startsWith(BRIDGE_PROTOCOL_PREFIX) && bridgeToken.length === 0) {
      bridgeToken = part.slice(BRIDGE_PROTOCOL_PREFIX.length);
    }
  }
  return { deviceToken, accountToken, accountId, bridgeToken, raw };
}

/**
 * Build the header a device offers with its handshake.
 *
 * @param {{deviceToken: string, accountToken?: string|null, accountId?: string|null}} options
 * @returns {string} the value of the `Sec-WebSocket-Protocol` header
 */
export function buildRelayProtocolHeader({ deviceToken, accountToken = null, accountId = null }) {
  const parts = [];
  if (typeof deviceToken === 'string' && deviceToken.length > 0) {
    parts.push(`${DEVICE_PROTOCOL_PREFIX}${deviceToken}`);
  }
  if (typeof accountToken === 'string' && accountToken.length > 0) {
    parts.push(`${ACCOUNT_PROTOCOL_PREFIX}${accountToken}`);
  }
  if (typeof accountId === 'string' && accountId.length > 0) {
    parts.push(`${ACCOUNT_ID_PROTOCOL_PREFIX}${accountId}`);
  }
  return parts.join(', ');
}
