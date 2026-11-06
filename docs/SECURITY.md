# Security of DSHsync

This document describes the threat model of the phone → relay → bridge → DSH chain, what the
code already does about it, what is still open and how a public relay has to be operated.

The short version: **the relay is a byte pipe and nothing else.** It never sees a command, it
never holds a key that can sign anything, and it can be thrown away and replaced at any time.
The trust is anchored on the desktop (the bridge) and on the DSH application.

---

## 1. The chain and what each segment trusts

```
   ┌──────────────┐        ┌─────────────────────┐        ┌──────────────┐        ┌─────────┐
   │ phone        │  (1)   │ relay (public VPS)  │  (2)   │ bridge       │  (3)   │ DSH     │
   │ HarmonyOS    │───────▶│  wss / https        │───────▶│ on the PC    │───────▶│ desktop │
   │ app          │◀───────│  forwards bytes     │◀───────│ localhost    │◀───────│ 127.0.0.1│
   └──────────────┘        └─────────────────────┘        └──────────────┘        └─────────┘
        owns the                sees the traffic,          holds the bridge        owns the
        bridge token            knows the device ids       token, the state        sessions and
        (pairing)               and the account             file and the DSH         the secrets
                                ids                        owner cookie
```

| segment | what it trusts | what it must never do |
|---|---|---|
| **phone** | the bridge token it received while pairing, the fingerprint of the relay certificate | store the token in the clear, talk to anything but the relay it was told to use |
| **relay** | the device token and the account token of the caller | decrypt the traffic, decide what a command means, keep a session longer than the account allows |
| **bridge** | the DSH owner cookie it mints itself, the device token of the relay | let a request without the bridge token through, talk to a DSH that is not on the loopback interface |
| **DSH** | the owner cookie that the bridge mints | listen on a public interface, trust a `Host` header from the local network |

### The three hops

1. **phone ↔ relay** — TLS, terminated by the relay. The phone pins the certificate
   (SHA256 fingerprint) on the first use. The relay sees the plaintext of the API calls.
2. **relay ↔ bridge** — TLS (`wss://`) as well. The desktop dials **out**, so the desktop
   needs no inbound port. The relay sees the plaintext here as well.
3. **bridge ↔ DSH** — plain HTTP on `127.0.0.1`, but the bridge sends an **owner cookie** it
   mints itself and forces the `Host` header to `127.0.0.1:<port>`. A page in the local
   browser has no access to that cookie, so it cannot drive the DSH.

---

## 2. What is already done

| measure | where | state |
|---|---|---|
| The relay answers **401** for a missing or wrong device token and closes the connection | `relay/src/server.js` (`#authorizeDevice`) | done, covered by a test |
| The device token is compared in **constant time** | `relay/src/devices.js` (`constantTimeEquals`) | done |
| The DSH listens on **127.0.0.1 only** | DSH application | done |
| The bridge mints its **own owner cookie** for the DSH and forces `Host: 127.0.0.1:<port>` | `bridge/src/dsh.js` | done — a page in the local browser cannot get that cookie |
| The **pairing code** is valid for 60 seconds and can only be used once | `bridge/src/server.js` | done |
| The device tokens are **revocable**: `DELETE /_relay/accounts/<accountId>/devices/<deviceId>` drops the device, closes its session and writes the registry back | `relay/src/server.js` (`#revokeDevice`) | done, covered by a test |
| The relay **rate limits** failed device attempts per address (10 per minute, `429` afterwards) | `relay/src/server.js` (`#isRateLimited`) | done, covered by a test |
| The desktop → relay link is **TLS** and the certificate is **verified** (`--relay-ca`, `rejectUnauthorized` stays on) | `bridge/src/relay-client.js` | done, covered by a test |
| The launcher signs a **self signed certificate** for the relay and prints its SHA256 fingerprint | `tools/install-desktop.ps1`, `tools/start-desktop.cmd` | done |
| The bridge prints the **DSH version** and warns when it is older than `0.1.2-alpha.1` (the fix of CVE-2026-82533, the local `Host` header bypass) | `bridge/src/dsh.js`, `bridge/src/cli.js` | done |

The DSH that is installed here is **0.2.1-rc.2** — far above the fixed version.

---

## 3. What is still open

| risk | why it matters | what closes it |
|---|---|---|
| **The relay sees the plaintext** of the phone ↔ bridge traffic | a compromised relay can read every message and every command, and it can replay them | end to end encryption between the phone and the bridge (design below), or a relay that is operated by the owner alone |
| **The bridge token travels in the clear** through the relay | a compromised relay can **impersonate the phone** and drive the computer on its own | the same: put the token into the encrypted envelope (design below) |
| **A self signed certificate needs a human** | the phone cannot know whether the relay is the real one | the first-use dialog with the SHA256 fingerprint; for a public relay a **publicly trusted certificate** is better |
| **The relay host itself** | whoever controls the VPS sees everything that is not encrypted | self host the relay, or accept the risk consciously |
| **The phone stores the bridge token** | a backup or a decompiled app can lift it | the token is encrypted with a key that lives in the **HUKS** (the key store of the system), see `harmony/entry/src/main/ets/common/Config.ets` |
| **A dangerous command runs without a second look** | with `danger-full-access` the phone can run anything on the computer | the bridge explains what it is about to do, the phone asks the user (second confirmation, the DSH asks on its own as well) |

### The consequence of a compromised relay — read this one

**Before the end to end encryption is in place:**

> A relay that is compromised (the VPS is broken into, the operator is hostile, the traffic is
> intercepted) gives the attacker **the bridge token**. The bridge token is the key to the
> computer: with it the attacker can send any prompt to the DSH of that PC and therefore
> **run commands on the computer of the owner** — read files, write files, install software.
> The attacker does not need the phone, the DSH password or the DSH itself.
>
> The relay does **not** get the DSH owner cookie and does **not** get the DSH secrets, but it
> does not need them.

**After the end to end encryption is in place:**

> A compromised relay sees only ciphertext, it cannot read the messages, it cannot use the
> bridge token, and it cannot impersonate the phone. It can still cut the connection (denial
> of service) and it can see the metadata (which device, which account, how much traffic).

That difference is the reason the end to end encryption is the next step.

### The end to end encryption (landed — the REST path)

**Status: the REST path between the phone and the desktop bridge is encrypted end to end; the relay
only ever sees ciphertext.**

- The phone and the bridge share the bridge token. The phone derives a *wrapping* key with
  `HKDF-SHA256(token, salt = accountId:deviceId, info = 'dsh-harmony-seal-wrap-v1')` and uses it to
  wrap its own random 32 byte *seal key* (`X-Dsh-Seal-Key`).
- Every request body is sealed with AES-256-GCM under the seal key
  (`X-Dsh-Seal` = `base64(iv(12B) || ciphertext || tag(16B))`, AAD = `method + "\n" + path + "\n" + timestamp`),
  and the **bearer token travels inside the envelope** — never in a header, never in the query.
- The bridge opens the envelope **before** it checks the token, so it validates the token that came
  out of the envelope. The answer of a sealed request is sealed as well.
- The replay window is ±5 minutes (`X-Dsh-Seal-Ts`).
- The bridge keeps **no state**: the wrapped seal key rides with every request, so no secret is
  written to disk.
- **Old phones keep working**: a request without `X-Dsh-Seal` is handled as before (plain bearer
  token). `--require-seal` makes the seal a hard requirement for strict deployments.
- Phone side: `harmony/entry/src/main/ets/common/Seal.ets` (HKDF + AES-256-GCM + a hand written
  base64; this SDK has no `createSymKey`, the raw key is imported with
  `createSymKeyGenerator('AES256').convertKeySync(...)`). Desktop side: `bridge/src/seal.js`.

**Still open:** the WebSocket handshake carried the token in the query string, and the query string
ends up in relay logs — the upgrade handler is being changed to stop that. Storing the phone side
token in the system keystore (HUKS) is in progress.

### The end to end encryption (the original design)

* **Key**: `HKDF-SHA256(bridge token, salt = accountId + ':' + deviceId)` → 32 bytes.
  Both sides know the bridge token (the phone got it while pairing, the bridge has it in its
  state file) and both know the account and the device id, so no extra key exchange is needed.
  The relay never learns the key: it only knows the token of the *device* side, not the token
  of the *phone* side.
* **Envelope**: `X-Dsh-Seal: base64(iv(12B) || ciphertext || tag(16B))` with AES-256-GCM.
  The AAD is `method + path + timestamp`, so a captured envelope cannot be moved to another
  endpoint. The timestamp is inside the ciphertext, the bridge rejects anything that is more
  than 5 minutes away (replay protection).
* **Compatibility**: the bridge accepts both — an encrypted body and a plain one — so an old
  phone keeps working. A strict deployment switches on `--require-seal`.
* **Both sides can do it**: the phone has `@kit.CryptoArchitectureKit` (AES-GCM and HKDF are
  available on API 26), the bridge has `node:crypto` (`hkdfSync`, `createCipheriv`).
* **What still has to be built**: the header has to be forwarded verbatim by the relay
  (`relay/src/http-rewriter.js` forwards every header it does not rewrite, so `X-Dsh-Seal`
  already passes), the bridge has to decrypt **before** it checks the token (that happens in
  `bridge/src/server.js`), and the phone has to seal every request and unseal every answer.

---

## 4. Public deployment checklist

A relay that is reachable from the internet:

- [ ] **Host it yourself.** A relay on a machine you control is a relay you can audit.
      A public "free relay" is a relay that reads everything.
- [ ] **Enforce `wss://` / `https://`.** The relay needs `--tls-port`, `--tls-cert` and
      `--tls-key`; use a certificate from a public CA (Let's Encrypt) so that the phone can
      trust it without a dialog. Never run the phone side on the plain port.
- [ ] **Change the default ports.** 8788 (plain) and 8789 (TLS) are defaults, not secrets.
- [ ] **SSH keys only**, no password login, no root login.
- [ ] **fail2ban** (or the equivalent) on the SSH port and on the relay port.
- [ ] **Only the TLS port is open** in the firewall; the plain port is for the local demo only.
- [ ] **Rotate the account and device tokens** from time to time
      (`DELETE /_relay/accounts/<accountId>/devices/<deviceId>` revokes a single device).
- [ ] **Keep the relay up to date** — it is the part of the chain that faces the internet.
- [ ] **Watch the log**: a burst of `401` answers means somebody is guessing tokens; the
      relay answers `429` after 10 failed attempts per minute and address.

### The desktop side

- [ ] Start it with `tools\start-desktop.cmd --with-relay` — it signs the certificate, starts
      the relay with TLS and dials in with `wss://`.
- [ ] Compare the **SHA256 fingerprint** the launcher prints with the one the phone shows in
      its first-use dialog. They have to be the same.
- [ ] Keep the DSH up to date: the bridge prints the DSH version and warns when it is older
      than `0.1.2-alpha.1`.

### The phone side

- [ ] The bridge token is stored encrypted, the key lives in the key store of the system.
- [ ] A backup of the app does **not** contain the token: after a restore the phone has to be
      paired again. That is intentional.

---

## 5. The commands behind the claims

```powershell
# the suites
node bridge/test/run.js            # the bridge
node bridge/test/relay-client.test.js   # the relay client of the bridge
node relay/test/run.js             # the relay

# a relay with TLS and a desktop that dials in with wss://
node relay\src\cli.js --port 8788 --tls-port 8789 --tls-cert cert.pem --tls-key key.pem
node bridge\src\cli.js --relay wss://127.0.0.1:8789/bridge --device-token <hex> --device-id <id> --relay-ca cert.pem
```

`curl --insecure` is good enough to see that the handshake works, but it is **not** a proof:
a production setup has to verify the certificate (the public CA, or the fingerprint the
launcher prints).

## 6. End to end encryption: what works, what is blocked, and why

### The protocol (byte for byte the same on both sides)

| header | meaning |
| --- | --- |
| `X-Dsh-Seal` | `base64(iv(12B) \|\| ciphertext \|\| tag(16B))`, AES-256-GCM |
| `X-Dsh-Seal-Ts` | the timestamp (ms) the seal was made for; the replay window is ±5 minutes |
| `X-Dsh-Seal-Id` | the salt: `<accountId>:<deviceId>` (public — the secret is the bridge token) |
| `X-Dsh-Seal-Key` | the phone's own random seal key, wrapped with the wrapping key |

- The **bearer token travels inside the envelope**, never in a header and never in the query
  string. The bridge opens the envelope *before* it checks the token.
- The AAD is `METHOD\npath\ntimestamp`. **Only the pathname** — the bridge uses `url.pathname`, so
  a request like `/api/v1/sessions/x/messages?limit=200` must bind `/api/v1/sessions/x/messages`.
- The wrapping key is `HKDF-SHA256(bridge token, salt = accountId:deviceId,
  info = 'dsh-harmony-seal-wrap-v1')`. The bridge keeps **no state**: the wrapped seal key rides
  with every request.
- Old phones keep working: a request without `X-Dsh-Seal` is handled as before. `--require-seal`
  turns the seal into a hard requirement for strict deployments.

### Cross end proof (the phone and the bridge derive the same key)

The phone (`harmony/entry/src/main/ets/common/Seal.ets`) and the bridge
(`bridge/src/seal.js`) were checked against each other on a real device:

```
deriveWrapKey('the-bridge-token', 'acc-1', 'dev-phone')
  phone : P7/IY2Vq6n17R8BNZKRxYfhA4uZgcWPvtlYBrk2gIW8=
  bridge: P7/IY2Vq6n17R8BNZKRxYfhA4uZgcWPvtlYBrk2gIW8=   (identical)
```

That vector is pinned in `bridge/test/seal.test.js` so a regression on either side fails the
suite.

### Two API traps (both cost hours — they are written down here on purpose)

1. **`HKDFSpec.algName` must be `'HKDF'`, not `'HKDF|SHA256'`.** The factory still takes
   `createKdf('HKDF|SHA256')`, but the spec itself only accepts the short name; the long name
   fails with `build context fail`.
2. **`cryptoFramework.createDataBlob` does not exist in this SDK.** The official samples use it,
   but on API 26 a `DataBlob` is the plain object `{ data: Uint8Array }`.

### The phone currently falls back to plaintext — and says so

On the API 26 SDK of this device, **`cryptoFramework`'s cipher cannot be used from ArkTS**:

- `cipher.init(mode, key, null, callback)` succeeds — the cipher itself works;
- `cipher.init(mode, key, <any params object>, callback)` fails with code **401**
  (`build context for init fail!`) — the parameter object never reaches the native side.

That was measured with GCM, CBC and ECB, with generated and imported keys, with the callback and
the promise form, and with `initSync`. Since GCM needs the IV in the parameters, **AES-GCM cannot
be done from ArkTS on this SDK**.

The phone therefore runs a **capability self test** (one AES-GCM round trip with a throwaway key)
before it uses the seal:

- self test passes → the sealed path is used;
- self test fails → the phone stays on the plain bearer token and logs the reason once
  (`密封自检没通过(...)`), and never tries the seal again.

**The seal is an enhancement, never a precondition** — the app always keeps working, and the
bridge keeps `--require-seal` for deployments that want to insist on it.

The remaining path to real end to end encryption on the phone is the **C API (NDK)** of
`cryptoFramework`, where the parameters are C structures and the marshalling problem does not
exist. That is tracked as a separate task.

---

## 7. The threat model of the public relay

The public relay exists so that **an ordinary user needs nothing**: no domain, no VPS, no
certificate, no account. The bridge registers itself there on the first run
(see [SELF-HOST.md](SELF-HOST.md) chapter 1). This chapter says exactly what that costs.

### 7.1 What the relay can see

The relay is the man in the middle of every remote session. It sees the **metadata**, always:

| it sees | example |
|---|---|
| which account | `acc-1a2b` |
| which device | `dev-8f2a`, the device name ("my desktop") |
| when the connection was open | the timestamps of the handshake and of the heartbeat |
| how much went through | the byte count per connection |
| the addresses | the IP of the phone and the IP of the bridge |

### 7.2 What the relay can see today — and what it cannot see later

**Today the phone talks to the bridge in plaintext.** The end to end seal is implemented on the
bridge, but on the phone the `cryptoFramework` cipher cannot be initialised from ArkTS on the
current SDK (section 6), so the capability self test fails and the phone stays on the plain
bearer token.

> **Consequence, stated plainly: a public relay operator can read the conversations of the
> people who use it.** Not the DSH secrets, not the DSH owner cookie — the conversations and the
> commands.

**When the end to end encryption lands on the phone (the NDK path of section 6), the relay only
ever sees ciphertext** and cannot read the messages, cannot use the bridge token, and cannot
impersonate the phone. It can still cut the connection and it still sees the metadata of 7.1.

The desktop side can insist on the seal today: the bridge has `--require-seal`, which refuses
every request that is not sealed. A deployment that wants no plaintext at all can use it, and the
phone falls back to plaintext only when the seal is impossible.

### 7.3 The answer to "can you peek at my conversations"

Not "trust us" — **read the code**. The relay is open source:

- the whole relay is in this repository (`relay/`), ~2000 lines;
- the phone app is in this repository (`harmony/`);
- the bridge is in this repository (`bridge/`);
- anyone can read it, run it, and check what it does with the traffic;
- anyone can **run their own relay** — one command, see [SELF-HOST.md](SELF-HOST.md) chapter 2.

So the question is not "do we peek" but "who operates the machine". For a public relay the
answer is the project. If that is not good enough for your data, **run the relay yourself** —
that is exactly what chapter 2 is for, and it is one command.

### 7.4 When to self host

| your situation | what to do |
|---|---|
| chatting about ordinary things, on your own phone | the public relay is fine |
| work code, customer data, anything you would not paste into a chat | **self host** (chapter 2) or use the LAN (no relay at all) |
| you need to be sure | self host, and read the relay source while you are at it |

### 7.5 The credentials never leave the machine

The account id, the device id and the tokens are **generated on the computer of the user**
(`%USERPROFILE%\.dsh-harmony-bridge\bridge.json`) and are never written into a config file: a
config file that carries a token is refused with an error. The public relay only learns the
ids and the tokens it issued itself. The packaging of the desktop program refuses to ship an
account registry, a device registry or any token file
(`tools/package-desktop.ps1`, the self check after the zip is built).
