// The account registry of the relay.
//
// WHAT AN "ACCOUNT" IS HERE
// --------------------------
// An account is **a shared secret (the account token) plus the list of devices that belong to
// it**. That is all. There is:
//
//   * no user account system — no password, no email address, no signup flow;
//   * no hosted backend — the registry is a JSON file that the relay operator keeps;
//   * no end-to-end encryption — the relay is a byte pipe, the bridge authenticates the phone
//     with its own bearer token.
//
// The registry lives in `relay/accounts.json`:
//
//   {
//     "accounts": [
//       {
//         "id": "acc-1a2b",
//         "name": "我的账号",
//         "token": "<32 bytes hex — the account secret>",
//         "createdAt": 1790000000000,
//         "devices": [
//           { "id": "dev-8f2a", "name": "我的台式机", "role": "desktop",
//             "token": "<32 bytes hex>", "port": 8787, "lastSeen": 0 }
//         ]
//       }
//     ]
//   }
//
// The old flat registry (`relay/devices.json`, `{ "devices": [...] }`) is still understood: it is
// migrated into exactly one account when it is loaded, so an existing deployment keeps working.
//
// The device id is **namespaced by the account** (the same `dev-…` id may exist under two
// accounts, exactly like the `@@unique([accountId, id])` of a real multi device backend). The
// account token and the device token are compared in constant time, so a wrong guess leaks
// neither the value nor the length of the stored secret.

import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';

import { constantTimeEquals } from './devices.js';

/** The prefix of an account id (`acc-1a2b`). */
export const ACCOUNT_ID_PREFIX = 'acc-';

/** The prefix of a device id (`dev-8f2a`). */
export const DEVICE_ID_PREFIX = 'dev-';

/** A device that runs the desktop bridge. */
export const ROLE_DESKTOP = 'desktop';

/** A device that is the phone of the account (it has no bridge port). */
export const ROLE_PHONE = 'phone';

/** The roles a device may have. */
export const ROLES = Object.freeze([ROLE_DESKTOP, ROLE_PHONE]);

/** Generate a fresh account id: `acc-` plus 4 hex characters. */
export function generateAccountId() {
  return `${ACCOUNT_ID_PREFIX}${crypto.randomBytes(2).toString('hex')}`;
}

/** Generate a fresh account token: 32 random bytes as hex. */
export function generateAccountToken() {
  return crypto.randomBytes(32).toString('hex');
}

/** Generate a fresh device id: `dev-` plus 4 hex characters. */
export function generateDeviceId() {
  return `${DEVICE_ID_PREFIX}${crypto.randomBytes(2).toString('hex')}`;
}

/** Generate a fresh device token: 32 random bytes as hex. */
export function generateDeviceToken() {
  return crypto.randomBytes(32).toString('hex');
}

/**
 * The hash of the secret of a machine.
 *
 * The secret of a machine is only ever stored hashed: the relay compares the hash of the secret
 * of a registration with the hash it kept, so the secret itself never reaches the disk.
 *
 * @param {string} secret the secret of the machine
 * @returns {string} the hash as hex
 */
export function hashSecret(secret) {
  return crypto.createHash('sha256').update(String(secret ?? ''), 'utf8').digest('hex');
}

/**
 * Normalize one device entry of the registry.
 *
 * @param {object} entry the raw entry
 * @param {{accountId: string, defaultPort: number}} options
 * @returns {{id: string, name: string, token: string, role: string, port: number|null, lastSeen: number, accountId: string, secretHash: string, registeredAt: number}}
 */
function normalizeDevice(entry, { accountId, defaultPort }) {
  if (!entry || typeof entry.id !== 'string' || entry.id.length === 0) {
    throw new Error('every device needs a non empty "id"');
  }
  if (typeof entry.token !== 'string' || entry.token.length === 0) {
    throw new Error(`the device ${entry.id} needs a non empty "token"`);
  }
  const role = ROLES.includes(entry.role) ? entry.role : ROLE_DESKTOP;
  const hasPort = Number.isInteger(entry.port) && entry.port > 0;
  return {
    id: entry.id,
    name: typeof entry.name === 'string' && entry.name.length > 0 ? entry.name : entry.id,
    token: entry.token,
    role,
    // A phone has no bridge port; a desktop without an explicit port uses the default.
    port: role === ROLE_PHONE ? null : (hasPort ? entry.port : defaultPort),
    lastSeen: Number.isFinite(entry.lastSeen) ? entry.lastSeen : 0,
    accountId,
    // The hash of the secret of the machine — the secret itself is never stored.
    secretHash: typeof entry.secretHash === 'string' ? entry.secretHash : '',
    registeredAt: Number.isFinite(entry.registeredAt) ? entry.registeredAt : 0,
  };
}

/**
 * Read the account registry.
 *
 * Two formats are understood:
 *
 *   * the **new** format `{ "accounts": [ … ] }`;
 *   * the **legacy** flat format `{ "devices": [ … ] }` (or a bare array), which is migrated
 *     into exactly one account.
 *
 * @param {string} file path of the JSON file
 * @param {{defaultPort?: number, migrateAccountId?: string, migrateAccountName?: string}} [options]
 * @returns {{file: string, accounts: Map<string, object>, format: string, migrated: boolean}}
 */
export function loadAccountRegistry(file, {
  defaultPort = 8787,
  migrateAccountId = null,
  migrateAccountName = null,
} = {}) {
  let raw;
  try {
    raw = fs.readFileSync(file, 'utf8');
  } catch (error) {
    throw new Error(`the account registry ${file} cannot be read: ${error.message}`);
  }

  let parsed;
  try {
    parsed = JSON.parse(raw);
  } catch (error) {
    throw new Error(`the account registry ${file} is not valid JSON: ${error.message}`);
  }

  const accounts = new Map();

  const list = parsed && typeof parsed === 'object' && Array.isArray(parsed.accounts) ? parsed.accounts : null;
  if (list) {
    for (const entry of list) {
      if (!entry || typeof entry.id !== 'string' || entry.id.length === 0) {
        throw new Error(`every account of ${file} needs a non empty "id"`);
      }
      if (typeof entry.token !== 'string' || entry.token.length === 0) {
        throw new Error(`the account ${entry.id} of ${file} needs a non empty "token"`);
      }
      if (accounts.has(entry.id)) {
        throw new Error(`the account id ${entry.id} of ${file} is used twice`);
      }
      const devices = new Map();
      const deviceList = Array.isArray(entry.devices) ? entry.devices : [];
      for (const rawDevice of deviceList) {
        const device = normalizeDevice(rawDevice, { accountId: entry.id, defaultPort });
        if (devices.has(device.id)) {
          throw new Error(`the device id ${device.id} of the account ${entry.id} is used twice`);
        }
        devices.set(device.id, device);
      }
      accounts.set(entry.id, {
        id: entry.id,
        name: typeof entry.name === 'string' && entry.name.length > 0 ? entry.name : entry.id,
        token: entry.token,
        createdAt: Number.isFinite(entry.createdAt) ? entry.createdAt : Date.now(),
        devices,
      });
    }
    return { file, accounts, format: 'accounts', migrated: false };
  }

  // The legacy flat registry: every device becomes a member of one single account.
  const legacyDevices = Array.isArray(parsed) ? parsed : parsed?.devices;
  if (!Array.isArray(legacyDevices)) {
    throw new Error(`the account registry ${file} must contain an "accounts" array (or the legacy "devices" array)`);
  }

  // The legacy file may carry hints about the account it belongs to, so that the migration is
  // deterministic and lands on the same account every time.
  const hint = parsed && typeof parsed === 'object' && !Array.isArray(parsed) ? parsed.account : null;
  const hintedId = hint?.id
    ?? legacyDevices.find((entry) => typeof entry?.accountId === 'string' && entry.accountId.length > 0)?.accountId
    ?? null;
  const accountId = migrateAccountId ?? hintedId ?? generateAccountId();
  const devices = new Map();
  for (const rawDevice of legacyDevices) {
    const device = normalizeDevice(rawDevice, { accountId, defaultPort });
    if (devices.has(device.id)) {
      throw new Error(`the device id ${device.id} of ${file} is used twice`);
    }
    devices.set(device.id, device);
  }
  accounts.set(accountId, {
    id: accountId,
    name: migrateAccountName ?? hint?.name ?? '默认账号',
    token: hint?.token ?? generateAccountToken(),
    createdAt: Number.isFinite(hint?.createdAt) ? hint.createdAt : Date.now(),
    devices,
  });
  return { file, accounts, format: 'devices', migrated: true };
}

/**
 * Write the account registry back to disk.
 *
 * @param {string} file path of the JSON file
 * @param {{accounts: Map<string, object>}} registry
 */
export function saveAccountRegistry(file, registry) {
  const payload = {
    accounts: [...registry.accounts.values()].map((account) => ({
      id: account.id,
      name: account.name,
      token: account.token,
      createdAt: account.createdAt,
      devices: [...account.devices.values()].map((device) => ({
        id: device.id,
        name: device.name,
        role: device.role,
        token: device.token,
        ...(device.port ? { port: device.port } : {}),
        lastSeen: device.lastSeen ?? 0,
        // The hash of the secret of the machine: the secret itself is never written to the disk.
        ...(device.secretHash ? { secretHash: device.secretHash } : {}),
        ...(device.registeredAt ? { registeredAt: device.registeredAt } : {}),
      })),
    })),
  };
  const target = path.resolve(file);
  fs.mkdirSync(path.dirname(target), { recursive: true });
  fs.writeFileSync(target, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
}

/** The account with that id, or `null`. */
export function findAccount(registry, accountId) {
  return registry.accounts.get(String(accountId ?? '')) ?? null;
}

/**
 * The account whose token matches, or `null`.
 *
 * The comparison is constant time, so a wrong token leaks neither the value nor the length of
 * the stored one.
 */
export function findAccountByToken(registry, token) {
  const candidate = String(token ?? '');
  if (candidate.length === 0) return null;
  for (const account of registry.accounts.values()) {
    if (typeof account.token === 'string' && account.token.length > 0 && constantTimeEquals(candidate, account.token)) {
      return account;
    }
  }
  return null;
}

/** The device of that account, or `null`. */
export function findDevice(registry, accountId, deviceId) {
  const account = findAccount(registry, accountId);
  if (!account) return null;
  return account.devices.get(String(deviceId ?? '')) ?? null;
}

/** Every device of that account (an empty list when the account does not exist). */
export function listDevices(registry, accountId) {
  const account = findAccount(registry, accountId);
  if (!account) return [];
  return [...account.devices.values()];
}

/**
 * The accounts that own a device id.
 *
 * More than one owner means the id is ambiguous: the legacy url `/<deviceId>/…` cannot be
 * resolved and the relay refuses it instead of guessing.
 */
export function deviceOwners(registry, deviceId) {
  const owners = [];
  for (const account of registry.accounts.values()) {
    if (account.devices.has(deviceId)) owners.push(account);
  }
  return owners;
}

/**
 * Refresh the `lastSeen` of a device.
 *
 * @returns {object|null} the device, or `null` when it does not exist
 */
export function touchDevice(registry, accountId, deviceId, at = Date.now()) {
  const device = findDevice(registry, accountId, deviceId);
  if (!device) return null;
  device.lastSeen = at;
  return device;
}

/**
 * Add a device to an account (or replace it when the id is already taken).
 *
 * @returns {object} the new device
 */
export function addDevice(registry, accountId, {
  id,
  name,
  token,
  role = ROLE_DESKTOP,
  port = null,
  lastSeen = 0,
  secretHash = '',
  registeredAt = 0,
} = {}) {
  const account = findAccount(registry, accountId);
  if (!account) throw new Error(`the account ${accountId} does not exist`);
  const deviceId = id ?? generateDeviceId();
  if (account.devices.has(deviceId)) {
    throw new Error(`the device ${deviceId} already belongs to the account ${accountId}`);
  }
  const device = normalizeDevice({
    id: deviceId,
    name: name ?? deviceId,
    token: token ?? generateDeviceToken(),
    role,
    port,
    lastSeen,
    secretHash,
    registeredAt,
  }, { accountId, defaultPort: 8787 });
  account.devices.set(deviceId, device);
  return device;
}

/**
 * Create an account in the registry.
 *
 * @returns {object} the new account
 */
export function createAccount(registry, {
  id,
  name,
  token,
  createdAt = Date.now(),
} = {}) {
  const accountId = id ?? generateAccountId();
  if (registry.accounts.has(accountId)) {
    throw new Error(`the account ${accountId} already exists`);
  }
  const account = {
    id: accountId,
    name: name ?? accountId,
    token: token ?? generateAccountToken(),
    createdAt,
    devices: new Map(),
  };
  registry.accounts.set(accountId, account);
  return account;
}
