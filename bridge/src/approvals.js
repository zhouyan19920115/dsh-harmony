// Owner-side subscriber of the DSH forwarded-event stream (`/api/remote.mux` + `$events`).
//
// Why this exists: the desktop's two interaction waterfalls are Cordis events, not RPC methods:
//   - `approval/request`        内核审批(允许 / 拒绝)
//   - `user-questions/request`  ask_user_question 的 ABCD 选项卡片
// Both are forwarded to an owner Peer holding an `$events` stream, and the answer travels back
// over the unary endpoint `$events/result`. That is why the phone can answer the native popups.
//
// Frames we care about look like:
//   { type: 'ready', clientId, host: { home } }
//   { type: 'emit', event: 'api-session/added', args: [...] }
//   { type: 'waterfall', event: 'approval/request', eventId, agentId, request: {...} }
//   { type: 'waterfall', event: 'user-questions/request', eventId, agentId, request: {...} }
//
// The reply is a plain HTTP RPC:
//   POST /api/$events/result  args = { clientId, eventId, outcome: { kind: 'result', value } }
// where value is an approval outcome string ('allowed-once' | 'rejected' | 'cancelled' |
// 'unavailable') for approvals, and `{ answers: [{ id, selected, custom? }] }` for questions.

import crypto from 'node:crypto';

import { DshError } from './dsh.js';
import { WebSocketClient } from './ws.js';

const MUX_PATH = '/api/remote.mux';
const EVENTS_ENDPOINT = '$events';
const RESULT_ENDPOINT = '$events/result';

/** Outcomes the approval waterfall accepts. */
export const APPROVAL_OUTCOMES = Object.freeze(['allowed-once', 'rejected', 'cancelled', 'unavailable']);

export class ApprovalWatcher {
  /**
   * @param {object} options
   * @param {import('./dsh.js').DshClient} options.dsh the client whose owner cookie is reused
   * @param {(level: string, message: string) => void} [options.log]
   * @param {number} [options.ttlMs] how long a request stays answerable in our list
   */
  constructor({ dsh, log = null, ttlMs = 10 * 60 * 1000 } = {}) {
    this.dsh = dsh;
    this.log = log ?? (() => {});
    this.ttlMs = ttlMs;
    this.socket = null;
    this.streamId = null;
    this.clientId = null;
    /** eventId -> 待答条目(审批 / 提问) */
    this.pending = new Map();
    this.stopped = true;
    this.retryTimer = null;
    this.connecting = null;
  }

  /** Open the stream once and keep it open. Errors are logged, never thrown. */
  start() {
    if (!this.stopped) return;
    this.stopped = false;
    void this.#connect();
  }

  stop() {
    this.stopped = true;
    if (this.retryTimer !== null) {
      clearTimeout(this.retryTimer);
      this.retryTimer = null;
    }
    for (const entry of this.pending.values()) if (entry.timer !== null) clearTimeout(entry.timer);
    this.pending.clear();
    try { this.socket?.close(); } catch { /* already closed */ }
    this.socket = null;
    this.clientId = null;
  }

  async #connect() {
    if (this.stopped || this.connecting !== null) return;
    this.connecting = (async () => {
      try {
        const url = new URL(this.dsh.baseUrl.replace(/^http/u, 'ws') + MUX_PATH);
        // The owner cookie is bound to the authority, so the handshake must carry both.
        const socket = new WebSocketClient(url, { headers: { host: this.dsh.authority, cookie: this.dsh.cookieHeader() } });
        socket.on('message', (text) => this.#onFrame(text));
        socket.on('error', (error) => this.log('warn', `interaction stream error: ${error?.message ?? error}`));
        socket.on('close', () => {
          this.socket = null;
          this.clientId = null;
          if (!this.stopped) this.#scheduleReconnect();
        });
        await socket.connect();
        this.socket = socket;
        this.streamId = crypto.randomUUID();
        socket.send(JSON.stringify({ type: 'open', streamId: this.streamId, endpoint: EVENTS_ENDPOINT, payload: { args: {} } }));
        this.log('info', 'interaction stream opened (owner $events)');
      } catch (error) {
        this.log('warn', `interaction stream could not open: ${error?.message ?? error}`);
        this.#scheduleReconnect();
      } finally {
        this.connecting = null;
      }
    })();
  }

  #scheduleReconnect() {
    if (this.stopped || this.retryTimer !== null) return;
    this.retryTimer = setTimeout(() => {
      this.retryTimer = null;
      void this.#connect();
    }, 5000);
    this.retryTimer.unref?.();
  }

  #onFrame(text) {
    let frame;
    try { frame = JSON.parse(String(text)); } catch { return; }
    if (frame?.type === 'error') {
      this.log('warn', `interaction stream rejected: ${frame.error?.code ?? 'unknown'} ${frame.error?.message ?? ''}`);
      return;
    }
    const value = frame?.type === 'item' ? frame.value : null;
    if (value?.type === 'ready') {
      this.clientId = String(value.clientId ?? '');
      this.log('info', `interaction stream ready (clientId ${this.clientId.slice(0, 8)})`);
      return;
    }
    if (value?.type === 'waterfall'
      && (value.event === 'approval/request' || value.event === 'user-questions/request')) {
      this.#remember(value);
    }
  }

  #remember(frame) {
    const eventId = String(frame.eventId ?? '');
    if (eventId.length === 0) return;
    const request = frame.request ?? {};
    if (this.pending.has(eventId)) return;
    const timer = setTimeout(() => this.pending.delete(eventId), this.ttlMs);
    timer.unref?.();
    const entry = {
      eventId,
      kind: frame.event === 'user-questions/request' ? 'question' : 'approval',
      agentId: String(frame.agentId ?? ''),
      toolName: String(request.toolName ?? ''),
      callId: request.callId === undefined ? '' : String(request.callId),
      reason: String(request.reason ?? ''),
      displayReason: request.displayReason ?? null,
      questions: null,
      at: Date.now(),
      timer,
    };
    if (entry.kind === 'question') {
      const raw = Array.isArray(request.questions) ? request.questions : [];
      const questions = [];
      for (const item of raw) {
        if (item === null || typeof item !== 'object') continue;
        if (typeof item.id !== 'string' || item.id.length === 0) continue;
        const options = Array.isArray(item.options)
          ? item.options.filter((o) => o !== null && typeof o === 'object' && typeof o.label === 'string')
            .map((o) => ({ label: o.label, ...(typeof o.description === 'string' ? { description: o.description } : {}) }))
          : undefined;
        questions.push({
          id: item.id,
          question: typeof item.question === 'string' ? item.question : '',
          ...(typeof item.header === 'string' && item.header.length > 0 ? { header: item.header } : {}),
          ...(typeof item.detail === 'string' && item.detail.length > 0 ? { detail: item.detail } : {}),
          ...(options !== undefined && options.length > 0 ? { options } : {}),
          ...(item.multiSelect === true ? { multiSelect: true } : {}),
        });
      }
      entry.questions = questions;
      this.log('info', `question requested: ${questions.length} question(s) for ${entry.agentId}`);
    } else {
      this.log('info', `approval requested: ${request.toolName ?? '?'} for ${entry.agentId}`);
    }
    this.pending.set(eventId, entry);
  }

  /** The requests still waiting for an answer, newest last. */
  list() {
    const now = Date.now();
    const out = [];
    for (const entry of this.pending.values()) {
      out.push({
        eventId: entry.eventId,
        kind: entry.kind,
        agentId: entry.agentId,
        toolName: entry.toolName,
        callId: entry.callId,
        reason: entry.reason,
        displayReason: entry.displayReason,
        questions: entry.questions,
        expiresAt: entry.at + this.ttlMs,
        remainingMs: Math.max(0, entry.at + this.ttlMs - now),
      });
    }
    return out;
  }

  /** Whether the stream is currently open. */
  get live() {
    return this.socket !== null && this.clientId !== null;
  }

  /**
   * Answer one pending interaction.
   *
   * @param {string} eventId
   * @param {string} outcome approval outcome (ignored for questions)
   * @param {object[]|null} answers `[{ id, selected, custom? }]` for questions
   * @returns {Promise<boolean>} whether the gateway accepted the reply
   */
  async answer(eventId, outcome, answers = null) {
    const entry = this.pending.get(String(eventId));
    if (entry === undefined) throw new DshError('bridge/interaction-gone', 'this is no longer waiting (answered elsewhere or expired)');
    if (this.clientId === null) throw new DshError('bridge/interaction-stream-down', 'the interaction stream is not connected right now');
    let value;
    if (entry.kind === 'question') {
      const list = Array.isArray(answers) ? answers : [];
      if (list.length === 0) throw new DshError('bridge/bad-answer', 'an answer batch is required for a question');
      value = { answers: list };
    } else {
      if (!APPROVAL_OUTCOMES.includes(outcome)) {
        throw new DshError('bridge/bad-outcome', `unknown approval outcome ${JSON.stringify(outcome)}`);
      }
      value = outcome;
    }
    const args = { clientId: this.clientId, eventId: entry.eventId, outcome: { kind: 'result', value } };
    const envelope = {
      type: 'client-request',
      rpcId: crypto.randomUUID(),
      method: RESULT_ENDPOINT,
      payload: { args },
    };
    const response = await fetch(this.dsh.baseUrl + '/api/' + RESULT_ENDPOINT, {
      method: 'POST',
      headers: this.dsh.authHeaders(),
      body: JSON.stringify(envelope),
    });
    const text = await response.text();
    let parsed = null;
    try { parsed = JSON.parse(text); } catch { parsed = null; }
    if (response.status !== 200 || parsed?.result?.ok !== true) {
      const error = parsed?.result?.error ?? { code: `http-${response.status}` };
      throw new DshError(error.code ?? 'bridge/interaction-failed', error.message ?? 'the reply was refused');
    }
    this.pending.delete(entry.eventId);
    if (entry.timer !== null) clearTimeout(entry.timer);
    this.log('info', `${entry.kind} answered`);
    return true;
  }
}