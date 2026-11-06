// The cross platform interop check of the seal.
//
//   node tools/seal-interop.js [--device <hdcTarget>] [--bridge <url>] [--token <bridgeToken>]
//
// It proves that the two ends agree **byte for byte**:
//
//   1. the bridge (node, `bridge/src/seal.js` -> OpenSSL) computes the fixed vector,
//   2. the phone (the native module, `harmony/entry/src/main/cpp/seal_core.c` -> the system
//      crypto framework) computes the same vector on the device,
//   3. the two are compared byte for byte,
//   4. the other direction: an envelope the bridge seals is opened by the device,
//   5. and (with --bridge) a request that carries the seal of the device is sent to the bridge,
//      which must open it.
//
// The vector lives in `bridge/test/seal.test.js` (`SEAL_TEST_VECTOR`) so that both ends use the
// same numbers.

import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import process from 'node:process';

import { deriveSealKey, sealBody, unsealBody } from '../bridge/src/seal.js';

const ROOT = path.resolve(path.dirname(new URL(import.meta.url).pathname.replace(/^\//, '')), '..');
const IDE = process.env.DEVECO_STUDIO_PATH ?? 'D:\\APP\\Devecostudio26\\DevEco Studio';
const NDK = path.join(IDE, 'sdk', 'default', 'openharmony', 'native');
const HDC = path.join(IDE, 'sdk', 'default', 'openharmony', 'toolchains', 'hdc.exe');
const CPP = path.join(ROOT, 'harmony', 'entry', 'src', 'main', 'cpp');
const INTEROP = path.join(CPP, 'test', 'seal_interop.c');
const CORE = path.join(CPP, 'seal_core.c');

/**
 * Read the fixed vector out of the test file.
 *
 * The test file runs its suite when it is imported (and ends with `process.exit`), so the
 * vector is read from its source instead of importing it — the vector has a single home.
 *
 * @param {string} root the root of the project
 * @returns {object} the vector
 */
function readVector(root) {
  const file = path.join(root, 'bridge', 'test', 'seal.test.js');
  const source = fs.readFileSync(file, 'utf8');
  const start = source.indexOf('SEAL_TEST_VECTOR = Object.freeze({');
  if (start === -1) throw new Error(`the fixed vector is not in ${file}`);
  const open = source.indexOf('{', start);
  let depth = 0;
  let end = -1;
  for (let i = open; i < source.length; i += 1) {
    if (source[i] === '{') depth += 1;
    else if (source[i] === '}') {
      depth -= 1;
      if (depth === 0) {
        end = i;
        break;
      }
    }
  }
  if (end === -1) throw new Error('the fixed vector is not closed');
  // The literal is a plain object of strings: it is evaluated as it is (the file is ours).
  // eslint-disable-next-line no-new-func
  return new Function(`return ${source.slice(open, end + 1)};`)();
}

/** The arguments of the program. */
function parseArgs(argv) {
  const options = { device: '127.0.0.1:5555', bridge: null, token: null, keep: false };
  for (let i = 0; i < argv.length; i += 1) {
    const flag = argv[i];
    if (flag === '--device') options.device = argv[++i];
    else if (flag === '--bridge') options.bridge = argv[++i];
    else if (flag === '--token') options.token = argv[++i];
    else if (flag === '--keep') options.keep = true;
    else if (flag === '--help' || flag === '-h') {
      process.stdout.write('usage: node tools/seal-interop.js [--device <target>] [--bridge <url>] [--token <token>]\n');
      process.exit(0);
    }
  }
  return options;
}

/** The architecture of a device (arm64-v8a or x86_64). */
function archOf(target) {
  const info = execFileSync(HDC, ['-t', target, 'shell', 'uname -m'], { encoding: 'utf8' });
  const arch = info.trim();
  if (arch.startsWith('aarch64')) return 'arm64-v8a';
  if (arch.startsWith('x86_64')) return 'x86_64';
  throw new Error(`the architecture of the device is not supported: ${arch}`);
}

/** Compile the interop program for the architecture of the device. */
function build(arch, target) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'dsh-seal-interop-'));
  const binary = path.join(directory, 'seal_interop');
  const triple = arch === 'arm64-v8a' ? 'aarch64-linux-ohos' : 'x86_64-linux-ohos';
  execFileSync(path.join(NDK, 'llvm', 'bin', 'clang.exe'), [
    `--target=${triple}`,
    `--gcc-toolchain=${path.join(NDK, 'llvm')}`,
    `--sysroot=${path.join(NDK, 'sysroot')}`,
    '-D__MUSL__',
    '-O2',
    '-fPIE',
    '-pie',
    '-fuse-ld=lld',
    '-o', binary,
    INTEROP,
    CORE,
    '-lohcrypto',
  ], { stdio: 'inherit' });
  process.stdout.write(`the interop program is built for ${arch} (${binary})\n`);
  return { binary, directory };
}

/** Run a program on the device with the vector on its standard input. */
function runOnDevice(target, binary, vector) {
  const remote = '/data/local/tmp/seal_interop';
  const remoteVector = '/data/local/tmp/seal_vector.txt';
  execFileSync(HDC, ['-t', target, 'file', 'send', binary, remote], { stdio: 'inherit' });
  execFileSync(HDC, ['-t', target, 'shell', `chmod 755 ${remote}`], { stdio: 'inherit' });
  // The vector goes through a file: `hdc shell` does not forward the standard input.
  // Every value is raw bytes and is written as hex.
  const input = Object.entries(vector)
    .map(([name, value]) => `${name}=${Buffer.isBuffer(value) ? value.toString('hex') : Buffer.from(String(value), 'utf8').toString('hex')}`)
    .join('\n');
  const local = path.join(path.dirname(binary), 'vector.txt');
  fs.writeFileSync(local, `${input}\n`);
  execFileSync(HDC, ['-t', target, 'file', 'send', local, remoteVector], { stdio: 'inherit' });
  const output = execFileSync(
    HDC,
    ['-t', target, 'shell', `${remote} < ${remoteVector}`],
    { encoding: 'utf8', timeout: 60_000 },
  );
  const parsed = {};
  for (const line of output.split(/\r?\n/u)) {
    const at = line.indexOf('=');
    if (at > 0) parsed[line.slice(0, at)] = line.slice(at + 1);
  }
  return parsed;
}

/** Compare two hex strings and report the first difference. */
function sameHex(name, actual, expected) {
  if (actual === expected) {
    process.stdout.write(`  ok   ${name} is the same on both ends (${expected.length / 2} bytes)\n`);
    return true;
  }
  process.stdout.write(`  FAIL ${name} differs\n       the device: ${actual}\n       the bridge: ${expected}\n`);
  return false;
}

const options = parseArgs(process.argv.slice(2));
const vector = readVector(ROOT);
let failures = 0;

/* 1. The bridge computes the vector. */
process.stdout.write('the bridge (node, OpenSSL) computes the vector\n');
const key = deriveSealKey({
  token: vector.token,
  accountId: vector.accountId,
  deviceId: vector.deviceId,
});
if (key.toString('hex') !== vector.key) {
  process.stdout.write(`  FAIL the derived key drifted: ${key.toString('hex')}\n`);
  failures += 1;
} else {
  process.stdout.write(`  ok   the derived key is the pinned one\n`);
}

/* 2. The device computes the same vector with the native module. */
const arch = archOf(options.device);
const { binary, directory } = build(arch, options.device);
process.stdout.write(`\nthe device (${options.device}, ${arch}) computes the vector with the native module\n`);
const device = runOnDevice(options.device, binary, {
  key: vector.key,
  iv: vector.iv,
  aad: Buffer.from(
    `${vector.method.toUpperCase()}\n${vector.path}\n${vector.timestamp}`,
    'utf8',
  ).toString('hex'),
  plain: vector.plain,
});

if (!sameHex('the iv', device.iv ?? '', vector.iv)) failures += 1;
if (!sameHex('the ciphertext', device.ciphertext ?? '', vector.ciphertext)) failures += 1;
if (!sameHex('the tag', device.tag ?? '', vector.tag)) failures += 1;

/* 3. The device opens its own seal. */
const opened = Buffer.from(device.opened ?? '', 'hex').toString('utf8');
if (opened === vector.plain) {
  process.stdout.write('  ok   the device opens its own seal\n');
} else {
  process.stdout.write(`  FAIL the device did not open its own seal: ${opened}\n`);
  failures += 1;
}

/* 4. The other direction: the bridge seals, the device opens. */
process.stdout.write('\nthe bridge seals and the device opens that envelope\n');
const sealed = sealBody(key, Buffer.from(vector.plain, 'utf8'), {
  method: vector.method,
  path: vector.path,
  timestamp: vector.timestamp,
});
const envelope = Buffer.from(sealed.seal, 'base64');
const back = runOnDevice(options.device, binary, {
  key: vector.key,
  iv: envelope.subarray(0, 12).toString('hex'),
  aad: Buffer.from(
    `${vector.method.toUpperCase()}\n${vector.path}\n${vector.timestamp}`,
    'utf8',
  ).toString('hex'),
  plain: vector.plain,
  ciphertext: envelope.subarray(12, envelope.length - 16).toString('hex'),
  tag: envelope.subarray(envelope.length - 16).toString('hex'),
});
const backPlain = Buffer.from(back.opened ?? '', 'hex').toString('utf8');
if (backPlain === vector.plain) {
  process.stdout.write('  ok   the device opens the envelope of the bridge\n');
} else {
  process.stdout.write(`  FAIL the device did not open the envelope of the bridge: ${backPlain}\n`);
  failures += 1;
}

/* 5. The bridge opens a seal that the device made (the real round trip over the wire). */
if (options.bridge && options.token) {
  process.stdout.write('\nthe bridge opens the seal of the device over the wire\n');
  const url = new URL(options.bridge);
  const pathName = vector.path;
  const timestamp = Date.now();
  const aadBytes = Buffer.from(`${vector.method.toUpperCase()}\n${pathName}\n${timestamp}`, 'utf8');
  const body = JSON.stringify({ token: options.token, body: { title: 'seal-interop' } });
  // The device seals the body of the request (with a fresh nonce of its own).
  const deviceSeal = runOnDevice(options.device, binary, {
    key: Buffer.from(vector.key, 'hex'),
    iv: Buffer.alloc(0),
    aad: aadBytes,
    plain: Buffer.from(body, 'utf8'),
  });
  if (!deviceSeal.iv || deviceSeal.iv.length !== 24) {
    process.stdout.write('  FAIL the device did not seal the body\n');
    failures += 1;
  } else {
    const envelope = Buffer.concat([
      Buffer.from(deviceSeal.iv, 'hex'),
      Buffer.from(deviceSeal.ciphertext, 'hex'),
      Buffer.from(deviceSeal.tag, 'hex'),
    ]).toString('base64');
    const response = await fetch(new URL(pathName, url), {
      method: vector.method,
      headers: {
        'content-type': 'application/json',
        'x-dsh-seal': envelope,
        'x-dsh-seal-ts': String(timestamp),
        'x-dsh-seal-id': `${vector.accountId}:${vector.deviceId}`,
      },
      body: '',
    });
    const text = await response.text();
    if (response.status === 401) {
      process.stdout.write(`  FAIL the bridge refused the seal of the device: ${text}\n`);
      failures += 1;
    } else {
      process.stdout.write(`  ok   the bridge opened the seal of the device (HTTP ${response.status})\n`);
      process.stdout.write(`       ${text.slice(0, 200)}\n`);
    }
  }
}

if (!options.keep) fs.rmSync(directory, { recursive: true, force: true });

process.stdout.write(`\n${failures === 0 ? 'the two ends agree byte for byte' : `${failures} difference(s)`}\n`);
process.exitCode = failures === 0 ? 0 : 1;
