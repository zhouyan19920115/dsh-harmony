// Device registry of the relay: the list of desktops that are allowed to dial in.
//
// The registry is a JSON file (see `relay/devices.json`):
//
//   { "devices": [ { "id": "dev-8f2a", "name": "我的台式机", "token": "<64 hex chars>" } ] }
//
// The token is issued by the relay operator and shared with the desktop bridge. It is compared
// in constant time, so a wrong token leaks neither the value nor the length of the stored one.

import crypto from 'node:crypto';
import fs from 'node:fs';

/**
 * Constant time string comparison.
 *
 * Both sides are hashed first, so the comparison time depends on neither the length nor the
 * content of the arguments.
 *
 * @param {string} a
 * @param {string} b
 * @returns {boolean}
 */
export function constantTimeEquals(a, b) {
  const left = crypto.createHash('sha256').update(String(a ?? ''), 'utf8').digest();
  const right = crypto.createHash('sha256').update(String(b ?? ''), 'utf8').digest();
  return crypto.timingSafeEqual(left, right);
}

/**
 * Read the device registry.
 *
 * @param {string} file path of the JSON file
 * @param {{defaultPort?: number}} [options] fallback bridge port for devices without one
 * @returns {Map<string, {id: string, name: string, token: string, port: number}>}
 */
export function loadDeviceRegistry(file, { defaultPort = 8787 } = {}) {
  let raw;
  try {
    raw = fs.readFileSync(file, 'utf8');
  } catch (error) {
    throw new Error(`the device registry ${file} cannot be read: ${error.message}`);
  }

  let parsed;
  try {
    parsed = JSON.parse(raw);
  } catch (error) {
    throw new Error(`the device registry ${file} is not valid JSON: ${error.message}`);
  }

  const list = Array.isArray(parsed) ? parsed : parsed?.devices;
  if (!Array.isArray(list)) {
    throw new Error(`the device registry ${file} must contain a "devices" array`);
  }

  const registry = new Map();
  for (const entry of list) {
    if (!entry || typeof entry.id !== 'string' || entry.id.length === 0) {
      throw new Error(`every device of ${file} needs a non empty "id"`);
    }
    if (typeof entry.token !== 'string' || entry.token.length === 0) {
      throw new Error(`the device ${entry.id} of ${file} needs a non empty "token"`);
    }
    if (registry.has(entry.id)) {
      throw new Error(`the device id ${entry.id} of ${file} is used twice`);
    }
    registry.set(entry.id, {
      id: entry.id,
      name: typeof entry.name === 'string' && entry.name.length > 0 ? entry.name : entry.id,
      token: entry.token,
      port: Number.isInteger(entry.port) && entry.port > 0 ? entry.port : defaultPort,
    });
  }
  if (registry.size === 0) {
    throw new Error(`the device registry ${file} does not list any device`);
  }
  return registry;
}

/** Generate a fresh device token: 32 random bytes as hex. */
export function generateDeviceToken() {
  return crypto.randomBytes(32).toString('hex');
}
