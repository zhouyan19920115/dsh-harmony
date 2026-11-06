#!/usr/bin/env node
// Command line entry point of the DSH Harmony cloud relay.
//
//   node relay/src/cli.js --port 8788 --account-file relay/accounts.json \
//        [--tls-port 8443 --tls-cert cert.pem --tls-key key.pem] \
//        [--public-url https://relay.example.com:8443]
//
// `--port` is the plain port the desktop bridge dials out to (`ws://host:8788/bridge`).
// `--tls-port` is the optional TLS port for the phone (`https://host:8443/<accountId>/<deviceId>/...`).
//
// The registry holds **accounts** (a shared secret plus a list of devices), see docs/ACCOUNT.md.
// The old flat device registry (`--device relay/devices.json`) is still understood: it is
// migrated into exactly one account when it is loaded.

import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

import {
  addDevice,
  createAccount,
  findAccount,
  loadAccountRegistry,
  saveAccountRegistry,
} from './accounts.js';
import {
  findConfigPath,
  findExistingConfigFile,
  loadConfigFile,
  relayConfigToOptions,
} from './config.js';
import { DEFAULT_DEVICE_RATE_LIMIT, RelayServer, createTimers } from './server.js';
import { DESKTOP_PACKAGE_PATH, LEGAL_PATH_PREFIX } from './server.js';
import { maskEndpoint, maskSecret } from './mask.js';

const VERSION = '1.0.0';

/** The default file of the account registry. */
export const DEFAULT_ACCOUNT_FILE = 'relay/accounts.json';

/** The default file of the legacy flat device registry. */
export const DEFAULT_DEVICE_FILE = 'relay/devices.json';

const USAGE = `dsh-harmony-relay ${VERSION}

Usage: dsh-harmony-relay [options]

Options:
  --config <file>            JSON file with the options below; the command line wins over it
                             (default: relay.config.json in the working directory, if it exists)
  --port <number>          plain port the desktop bridge dials in to (default 8788)
  --host <address>         address to bind (default 0.0.0.0)
  --account-file <file>    account registry (default ${DEFAULT_ACCOUNT_FILE})
  --device <file>          legacy flat device registry, migrated into one account
                           (default ${DEFAULT_DEVICE_FILE})
  --bridge-port <number>   port of the bridge on the device (default 8787)
  --tls-port <number>      TLS port for the phone (0 or missing disables TLS)
  --tls-cert <file>        TLS certificate (PEM)
  --tls-key <file>         TLS private key (PEM)
  --public-url <url>       public base url of the relay, e.g. https://relay.example.com:8443
  --no-join                refuse a device that presents an account token but is not
                           registered yet (default: a new device joins the account)
  --account-create         create an account in the registry and exit
  --account-id <id>        the id of the created account (default: generated)
  --account-name <name>    the name of the created account
  --device-id <id>         the id of the device of the created account
  --device-name <name>     the name of the device of the created account
  --device-rate-limit <n>  failed device attempts per address and minute before the relay
                           answers with 429 (default ${DEFAULT_DEVICE_RATE_LIMIT}, 0 disables)
  --desktop-package-url <url>
                           public base url the phone downloads the desktop package from, e.g.
                           https://relay.example.com — the package is then served under
                           ${DESKTOP_PACKAGE_PATH} (not set: the phone uses the copy inside
                           the app, the relay serves nothing)
  --desktop-package-file <file>
                           the package to serve (default: the desktop zip next to the relay, if
                           it is there)
  --desktop-package-version <text>
                           version of the served package (for the phone's cache)
  --legal-dir <dir>       directory with the privacy policy and the user agreement
                           (index.html + user-agreement.html); they are then served under
                           ${LEGAL_PATH_PREFIX}/ (not set: the relay serves nothing there)
  --help                   show this text
`;

/**
 * The desktop package the relay serves, if there is one.
 *
 * The operator points at it with `--desktop-package-file`; without that the relay looks for the
 * desktop zip next to itself (the app resource of the repository is enough).
 *
 * @param {object} options the parsed options
 * @param {string} [cwd] the working directory
 * @returns {string|null} the absolute path, or null when there is no package
 */
export function resolveDesktopPackageFile(options, cwd = process.cwd()) {
  if (options.desktopPackageFile) return path.resolve(options.desktopPackageFile);
  const candidates = [
    path.join(cwd, 'dsh-harmony-desktop-exe.zip'),
    path.join(cwd, 'deploy', 'dsh-harmony-desktop-exe.zip'),
    path.join(cwd, 'harmony', 'deploy', 'dsh-harmony-desktop-exe.zip'),
  ];
  for (const candidate of candidates) {
    try {
      if (fs.existsSync(candidate)) return candidate;
    } catch {
      // an unreadable candidate is simply not the file
    }
  }
  return null;
}

/** Log with the `[relay]` prefix and a timestamp. */
export function makeLogger(prefix = '[relay]') {
  return (level, message) => {
    const stamp = new Date().toISOString().replace('T', ' ').slice(0, 23);
    process.stdout.write(`${stamp} ${prefix} ${level.toUpperCase().padEnd(5)} ${message}\n`);
  };
}

/**
 * Parse the command line.
 *
 * @param {string[]} [argv] the command line
 * @param {object} [base] the options a config file provided; the command line wins over them
 */
export function parseArgs(argv = [], base = {}) {
  const options = {
    port: 8788,
    host: '0.0.0.0',
    accountFile: DEFAULT_ACCOUNT_FILE,
    device: DEFAULT_DEVICE_FILE,
    bridgePort: 8787,
    tlsPort: 0,
    tlsCert: null,
    tlsKey: null,
    publicUrl: null,
    allowJoin: true,
    accountCreate: false,
    accountId: null,
    accountName: null,
    deviceId: null,
    deviceName: null,
    deviceRateLimit: DEFAULT_DEVICE_RATE_LIMIT,
    desktopPackageUrl: null,
    desktopPackageFile: null,
    desktopPackageVersion: null,
    legalDir: null,
    config: null,
    help: false,
    ...base,
  };

  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    const next = () => {
      const value = argv[i + 1];
      if (value === undefined) throw new Error(`${arg} needs a value`);
      i += 1;
      return value;
    };
    switch (arg) {
      case '--port': options.port = Number.parseInt(next(), 10); break;
      case '--host': options.host = next(); break;
      case '--account-file': options.accountFile = next(); break;
      case '--device': options.device = next(); break;
      case '--bridge-port': options.bridgePort = Number.parseInt(next(), 10); break;
      case '--tls-port': options.tlsPort = Number.parseInt(next(), 10); break;
      case '--tls-cert': options.tlsCert = next(); break;
      case '--tls-key': options.tlsKey = next(); break;
      case '--public-url': options.publicUrl = next(); break;
      case '--no-join': options.allowJoin = false; break;
      case '--account-create': options.accountCreate = true; break;
      case '--account-id': options.accountId = next(); break;
      case '--account-name': options.accountName = next(); break;
      case '--device-id': options.deviceId = next(); break;
      case '--device-name': options.deviceName = next(); break;
      case '--device-rate-limit': options.deviceRateLimit = Number.parseInt(next(), 10); break;
      case '--desktop-package-url': options.desktopPackageUrl = next(); break;
      case '--desktop-package-file': options.desktopPackageFile = next(); break;
      case '--desktop-package-version': options.desktopPackageVersion = next(); break;
      case '--legal-dir': options.legalDir = next(); break;
      case '--config': options.config = next(); break;
      case '--help':
      case '-h': options.help = true; break;
      default:
        throw new Error(`unknown option ${arg}`);
    }
  }

  if (!Number.isInteger(options.port) || options.port < 0 || options.port > 65535) {
    throw new Error(`invalid --port ${options.port}`);
  }
  if (!Number.isInteger(options.tlsPort) || options.tlsPort < 0 || options.tlsPort > 65535) {
    throw new Error(`invalid --tls-port ${options.tlsPort}`);
  }
  if (!Number.isInteger(options.bridgePort) || options.bridgePort < 1 || options.bridgePort > 65535) {
    throw new Error(`invalid --bridge-port ${options.bridgePort}`);
  }
  if (options.tlsPort > 0 && (!options.tlsCert || !options.tlsKey)) {
    throw new Error('--tls-port needs --tls-cert and --tls-key');
  }
  if (!Number.isInteger(options.deviceRateLimit) || options.deviceRateLimit < 0 || options.deviceRateLimit > 10000) {
    throw new Error(`invalid --device-rate-limit ${options.deviceRateLimit}`);
  }
  return options;
}

/**
 * Build the url the phone has to use for a device.
 *
 * With an account the url carries it: `https://relay/<accountId>/<deviceId>`. Without an account
 * the legacy shape `https://relay/<deviceId>` is used.
 *
 * @param {string} publicUrl the public base url of the relay
 * @param {string} deviceId the device id
 * @param {string} [accountId] the account id
 */
export function phoneUrl(publicUrl, deviceId, accountId = null) {
  const base = String(publicUrl).replace(/\/+$/u, '');
  if (accountId) return `${base}/${accountId}/${deviceId}`;
  return `${base}/${deviceId}`;
}

/**
 * Build the url the desktop bridge has to dial in to.
 *
 * @param {string} publicUrl the public base url of the relay
 * @param {number} port the plain port of the relay
 * @param {string} deviceId the device id
 * @param {string} token the device token
 * @param {{accountId?: string, accountToken?: string}} [account] the account of the device
 */
export function deviceUrl(publicUrl, port, deviceId, token, { accountId = null, accountToken = null } = {}) {
  const base = new URL(String(publicUrl));
  base.protocol = 'ws:';
  base.port = String(port);
  base.pathname = '/bridge';
  const params = new URLSearchParams({ token: String(token), deviceId: String(deviceId) });
  if (accountId) params.set('accountId', String(accountId));
  if (accountToken) params.set('accountToken', String(accountToken));
  base.search = params.toString();
  return base.toString();
}

/**
 * The registry files the relay reads, in the order it looks at them.
 *
 * An explicitly named file always wins; otherwise the new account registry is preferred and the
 * legacy device registry is the fallback (and the migration source).
 */
export function resolveRegistryFiles(options) {
  const accountFile = path.resolve(options.accountFile);
  const deviceFile = path.resolve(options.device);
  if (options.accountFile !== DEFAULT_ACCOUNT_FILE) return { files: [accountFile], accountFile };
  if (options.device !== DEFAULT_DEVICE_FILE) return { files: [deviceFile], accountFile: deviceFile };
  return { files: [accountFile, deviceFile], accountFile };
}

/** Print the startup banner. */
export function printBanner({ log, options, registry, phoneBase, dialInBase, registryFile }) {
  const line = '─'.repeat(68);
  const accounts = [...registry.accounts.values()];
  log('info', line);
  log('info', `dsh-harmony-relay ${VERSION} — cloud relay for the HarmonyOS client`);
  log('info', `account registry: ${registryFile} (${accounts.length} account${accounts.length === 1 ? '' : 's'})`);
  log('info', `device dial-in  : ${dialInBase}   (the desktop bridge connects here)`);
  log('info', `phone base url  : ${phoneBase}`);
  if (options.desktopPackageUrl) {
    log('info', `desktop package : ${options.desktopPackageUrl.replace(/\/+$/u, '')}${DESKTOP_PACKAGE_PATH}  (the phone downloads it from here)`);
  }
  if (options.legalDir) {
    log('info', `legal pages     : ${options.legalDir.replace(/\/+$/u, '')}${LEGAL_PATH_PREFIX}/  (privacy policy + user agreement)`);
  }
  log('info', `bridge port     : ${options.bridgePort} (the port the device opens)`);
  log('info', line);
  for (const account of accounts) {
    const devices = [...account.devices.values()];
    log('info', `account ${account.id}  "${account.name}"  (${devices.length} device${devices.length === 1 ? '' : 's'})`);
    // The tokens are secrets: the banner only shows their shape. The full ones go to stderr,
    // because the operator has to copy the dial-in command into the bridge configuration.
    log('info', `  account token : ${maskSecret(account.token)}`);
    log('info', '  phone urls (enter one of these in the phone app):');
    for (const device of devices) {
      log('info', `    ${phoneUrl(phoneBase, device.id, account.id)}   (${device.name}, ${device.role})`);
    }
    log('info', '  device dial-in (the desktop bridge needs this):');
    for (const device of devices) {
      // The url carries the token in the query — that is the legacy compatibility path
      // (the current protocol puts the token in the Sec-WebSocket-Protocol header), so it is
      // masked here as well.
      log('info', `    ${maskEndpoint(deviceUrl(dialInBase, options.port, device.id, device.token, {
        accountId: account.id,
        accountToken: account.token,
      }))}`);
      log('info', `    bridge --relay ws://127.0.0.1:${options.port}/bridge --device-token ${maskSecret(device.token)}`);
      log('info', `           --device-id ${device.id} --account ${account.id} --account-token ${maskSecret(account.token)}`);
      // The copy-paste commands with the real tokens — on stderr, not in the banner.
      process.stderr.write(`[relay] bridge --relay ws://127.0.0.1:${options.port}/bridge --device-token ${device.token}\n`);
      process.stderr.write(`[relay]            --device-id ${device.id} --account ${account.id} --account-token ${account.token}\n`);
    }
  }
  log('info', line);
  if (accounts.length > 0) {
    const first = accounts[0];
    const firstDevice = [...first.devices.values()][0];
    if (firstDevice) {
      log('info', 'try it:');
      log('info', `  curl -s -H "Authorization: Bearer <bridgeToken>" ${phoneUrl(phoneBase, firstDevice.id, first.id)}/api/v1/health`);
      log('info', `  curl -s "${phoneBase}/_relay/accounts/${first.id}/devices?accountToken=${maskSecret(first.token)}"`);
    }
  }
  log('info', line);
}

/** Create an account (and optionally a device) in the registry. */
function createAccountCommand(options, log) {
  const { files, accountFile } = resolveRegistryFiles(options);
  let registry = { accounts: new Map() };
  const existing = files.find((file) => fs.existsSync(file));
  if (existing) {
    registry = loadAccountRegistry(existing, { defaultPort: options.bridgePort });
    if (registry.migrated) log('info', `the legacy registry ${existing} was migrated into one account`);
  }
  const account = createAccount(registry, {
    id: options.accountId ?? undefined,
    name: options.accountName ?? options.accountId ?? '我的账号',
  });
  let device = null;
  if (options.deviceId) {
    device = addDevice(registry, account.id, {
      id: options.deviceId,
      name: options.deviceName ?? options.deviceId,
    });
  }
  saveAccountRegistry(accountFile, registry);
  log('info', `the account was written to ${accountFile}`);
  log('info', `account id     : ${account.id}`);
  log('info', `account name   : ${account.name}`);
  // The new token is a secret: masked in the log, in the clear on stderr (the operator has to
  // copy it into the bridge configuration).
  log('info', `account token  : ${maskSecret(account.token)}`);
  process.stderr.write(`[relay] account token  : ${account.token}\n`);
  if (device) {
    log('info', `device id      : ${device.id}`);
    log('info', `device name    : ${device.name}`);
    log('info', `device token   : ${maskSecret(device.token)}`);
    process.stderr.write(`[relay] device token   : ${device.token}\n`);
  }
}

/** Run the relay. */
export async function main(argv = process.argv.slice(2)) {
  // The config file comes first, the command line wins over it.
  const configArg = findConfigPath(argv);
  const configPath = configArg ?? findExistingConfigFile();
  let fileOptions = {};
  let configFile = null;
  if (configPath) {
    try {
      const raw = loadConfigFile(configPath);
      fileOptions = relayConfigToOptions(raw, configPath);
      configFile = configPath;
    } catch (error) {
      process.stderr.write(`[relay] ERROR ${error.message}\n`);
      process.exitCode = 2;
      return null;
    }
  } else if (configArg !== null) {
    process.stderr.write(`[relay] ERROR the config file ${configArg} does not exist\n`);
    process.exitCode = 2;
    return null;
  }

  let options;
  try {
    options = parseArgs(argv, fileOptions);
  } catch (error) {
    process.stderr.write(`[relay] ERROR ${error.message}\n\n${USAGE}`);
    process.exitCode = 2;
    return null;
  }
  if (options.help) {
    process.stdout.write(USAGE);
    return null;
  }

  const log = makeLogger();
  if (configFile) log('info', `config file  : ${configFile}`);

  if (options.accountCreate) {
    try {
      createAccountCommand(options, log);
    } catch (error) {
      process.stderr.write(`[relay] ERROR ${error.message}\n`);
      process.exitCode = 2;
      return null;
    }
    return null;
  }

  const { files, accountFile } = resolveRegistryFiles(options);
  let registry = null;
  let usedFile = null;
  for (const file of files) {
    if (!fs.existsSync(file)) continue;
    try {
      registry = loadAccountRegistry(file, { defaultPort: options.bridgePort });
      usedFile = file;
    } catch (error) {
      process.stderr.write(`[relay] ERROR ${error.message}\n`);
      process.exitCode = 2;
      return null;
    }
    break;
  }
  if (!registry) {
    process.stderr.write(`[relay] ERROR no account registry found (${files.join(' or ')}) — create one with --account-create\n`);
    process.exitCode = 2;
    return null;
  }
  if (registry.migrated) {
    const migrated = findAccount(registry, [...registry.accounts.keys()][0]);
    log('info', `the legacy device registry ${usedFile} was migrated into the account ${migrated?.id}`);
    try {
      saveAccountRegistry(accountFile, registry);
      log('info', `the migrated registry was written to ${accountFile}`);
    } catch (error) {
      log('warn', `the migrated registry could not be written: ${error.message}`);
    }
  }

  const relay = new RelayServer({
    registry,
    bridgePort: options.bridgePort,
    log: (level, message) => log(level, message),
    timers: createTimers(),
    allowJoin: options.allowJoin,
    registryFile: accountFile,
    deviceRateLimit: options.deviceRateLimit,
    // The desktop package: the relay only serves it when the operator published an address for
    // it — otherwise the phone uses the copy inside the app.
    desktopPackageFile: options.desktopPackageUrl ? resolveDesktopPackageFile(options) : null,
    desktopPackageUrl: options.desktopPackageUrl,
    desktopPackageVersion: options.desktopPackageVersion,
    // The privacy policy / the user agreement (public pages, no token needed).
    legalDir: options.legalDir ? path.resolve(options.legalDir) : null,
  });

  try {
    await relay.listen({
      port: options.port,
      host: options.host,
      tlsPort: options.tlsPort,
      tlsCert: options.tlsCert,
      tlsKey: options.tlsKey,
    });
  } catch (error) {
    process.stderr.write(`[relay] ERROR the relay could not start: ${error.message}\n`);
    process.exitCode = 1;
    return null;
  }

  const displayHost = options.host === '0.0.0.0' ? '127.0.0.1' : options.host;
  const publicHost = options.publicUrl ? new URL(options.publicUrl).hostname : displayHost;
  const phoneBase = options.publicUrl
    ? options.publicUrl.replace(/\/+$/u, '')
    : (relay.tlsServer ? `https://${displayHost}:${relay.tlsPort}` : `http://${displayHost}:${relay.port}`);
  const dialInBase = `ws://${publicHost}:${relay.port}`;

  printBanner({ log, options, registry, phoneBase, dialInBase, registryFile: accountFile });
  if (!options.publicUrl) {
    // Without a public url the relay can only be reached on the address it binds to. That is
    // fine for a relay behind a reverse proxy in the same network, but a phone on the internet
    // needs the public url of the relay.
    log('warn', `no public url was given: the phone has to use ${phoneBase} (the address of this machine)`);
    log('warn', 'set "publicUrl" in relay.config.json (or --public-url) when phones reach this relay over the internet');
  }
  log('info', 'ready — the desktop bridge can dial in and the phone can connect');

  const shutdown = async (signal) => {
    log('info', `received ${signal}, shutting down`);
    await relay.close();
    process.exit(0);
  };
  process.on('SIGINT', () => { void shutdown('SIGINT'); });
  process.on('SIGTERM', () => { void shutdown('SIGTERM'); });

  return { relay, options, registry };
}

const invokedDirectly = process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url);
if (invokedDirectly) {
  main().catch((error) => {
    process.stderr.write(`[relay] ERROR ${error instanceof Error ? error.stack ?? error.message : String(error)}\n`);
    process.exit(1);
  });
}
