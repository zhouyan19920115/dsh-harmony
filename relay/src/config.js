// Configuration of the relay: the JSON file and the command line.
//
// The file is the comfortable way to run a relay that other people use: the operator writes
// `relay.config.json` once and starts the relay without remembering any flag. The command line
// always wins over the file, so a file can be edited without breaking a script that passes
// flags.
//
// The file describes **where** the relay listens and **how** it is reached. It never holds a
// credential: the accounts, the devices and their tokens live in the account registry, which is
// a separate file with its own permissions.

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

/** The name of the config file. */
export const DEFAULT_CONFIG_FILE = 'relay.config.json';

/** Where the config file is looked for, in this order. */
export function configCandidates(cwd = process.cwd()) {
  const here = path.dirname(fileURLToPath(import.meta.url));
  return [
    path.join(cwd, DEFAULT_CONFIG_FILE),
    path.join(cwd, 'relay', DEFAULT_CONFIG_FILE),
    path.join(here, '..', '..', DEFAULT_CONFIG_FILE),
    path.join(here, '..', DEFAULT_CONFIG_FILE),
  ];
}

/**
 * Find the `--config <path>` argument without parsing everything else.
 *
 * @param {string[]} argv the command line
 * @returns {string|null} the path the command line names, or null
 */
export function findConfigPath(argv = []) {
  for (let i = 0; i < argv.length; i += 1) {
    const raw = argv[i];
    if (!raw.startsWith('--')) continue;
    const eq = raw.indexOf('=');
    const name = eq === -1 ? raw.slice(2) : raw.slice(2, eq);
    if (name !== 'config') continue;
    if (eq !== -1) return raw.slice(eq + 1);
    const next = argv[i + 1];
    return next === undefined || next.startsWith('--') ? null : next;
  }
  return null;
}

/**
 * The first config file that exists, or null.
 *
 * @param {string[]} [candidates] the paths to look at
 * @returns {string|null}
 */
export function findExistingConfigFile(candidates = configCandidates()) {
  for (const candidate of candidates) {
    try {
      if (fs.existsSync(candidate)) return path.resolve(candidate);
    } catch {
      // an unreadable candidate is simply not the file
    }
  }
  return null;
}

/**
 * Read a JSON config file.
 *
 * @param {string} file the path of the file
 * @returns {object} the parsed object (an empty object when the file does not exist)
 */
export function loadConfigFile(file) {
  if (!file) return {};
  const resolved = path.resolve(file);
  if (!fs.existsSync(resolved)) return {};
  let parsed;
  try {
    // A file written by an editor on Windows often starts with a byte order mark; JSON.parse
    // does not accept it.
    const text = fs.readFileSync(resolved, 'utf8').replace(/^\uFEFF/u, '');
    parsed = JSON.parse(text);
  } catch (error) {
    throw new Error(`the config file ${resolved} is not valid JSON: ${error.message}`);
  }
  if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) {
    throw new Error(`the config file ${resolved} must hold a JSON object`);
  }
  return parsed;
}

/**
 * The keys the config file may carry, and the option each one fills.
 *
 * `accountsFile` is the name in the file, `accountFile` the name of the option; both work.
 */
export const CONFIG_KEYS = Object.freeze({
  port: 'port',
  host: 'host',
  tlsPort: 'tlsPort',
  tlsCert: 'tlsCert',
  tlsKey: 'tlsKey',
  publicUrl: 'publicUrl',
  accountsFile: 'accountFile',
  accountFile: 'accountFile',
  deviceFile: 'device',
  bridgePort: 'bridgePort',
  deviceRateLimit: 'deviceRateLimit',
  allowJoin: 'allowJoin',
  desktopPackageUrl: 'desktopPackageUrl',
  desktopPackageFile: 'desktopPackageFile',
  desktopPackageVersion: 'desktopPackageVersion',
});

/**
 * Turn the keys of a config file into the options of the relay.
 *
 * @param {object} raw the parsed config file
 * @param {string} [file] the file the options came from, for the error messages
 * @returns {object} the options the command line does not override
 */
export function relayConfigToOptions(raw, file = 'the config file') {
  const options = {};
  for (const [key, value] of Object.entries(raw ?? {})) {
    const option = CONFIG_KEYS[key];
    if (option === undefined) {
      throw new Error(`${file}: unknown key "${key}" (known: ${Object.keys(CONFIG_KEYS).join(', ')})`);
    }
    if (value === null || value === undefined) continue;
    if (typeof value === 'object') {
      throw new Error(`${file}: the key "${key}" must be a simple value`);
    }
    options[option] = value;
  }
  return options;
}
