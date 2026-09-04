#!/usr/bin/env node

import { lstat } from "node:fs/promises";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import { TextDecoder } from "node:util";

const SUPPORTED_SCHEMA_VERSION = 1;
const MAX_LINE_BYTES = 1_048_576;
const MAX_SEQUENCE = 9_223_372_036_854_775_807n;
const STABLE_SESSION_MS = 30_000;
const utf8 = new TextDecoder("utf-8", { fatal: true });
let stdoutFailed = false;

process.stdout.on("error", (error) => {
  stdoutFailed = true;
});

const SAFE_LOG_FIELDS = new Set([
  "schemaVersion",
  "type",
  "sequence",
  "messageType",
  "attachmentCount",
  "hasSender",
  "hasSourceSequence",
  "byteCount",
  "expectedSequence",
  "receivedSequence",
  "reconnectMs",
  "code",
]);

async function safeLog(event, fields = {}) {
  const record = {
    timestamp: new Date().toISOString(),
    component: "wxfomo-readonly-worker",
    event,
  };
  for (const [key, value] of Object.entries(fields)) {
    if (SAFE_LOG_FIELDS.has(key)) record[key] = value;
  }
  if (stdoutFailed) return;
  let writable;
  try {
    writable = process.stdout.write(`${JSON.stringify(record)}\n`);
  } catch (error) {
    if (error?.code === "EPIPE" || error?.code === "ERR_STREAM_DESTROYED") {
      stdoutFailed = true;
      return;
    }
    throw error;
  }
  if (writable) return;
  await new Promise((resolve) => {
    const settle = () => {
      process.stdout.off("drain", settle);
      process.stdout.off("error", settle);
      process.stdout.off("close", settle);
      resolve();
    };
    process.stdout.once("drain", settle);
    process.stdout.once("error", settle);
    process.stdout.once("close", settle);
  });
}

class WorkerError extends Error {
  constructor(code, permanent = false) {
    super(code);
    this.code = code;
    this.permanent = permanent;
  }
}

function isPlainObject(value) {
  if (value === null || typeof value !== "object" || Array.isArray(value)) return false;
  const prototype = Object.getPrototypeOf(value);
  return prototype === Object.prototype || prototype === null;
}

function validateEnvelope(value) {
  if (!isPlainObject(value)) throw new WorkerError("invalid_envelope");
  if (!Number.isInteger(value.schemaVersion)) throw new WorkerError("invalid_schema_version");
  if (value.schemaVersion !== SUPPORTED_SCHEMA_VERSION) {
    throw new WorkerError("unsupported_schema_version", true);
  }
  if (value.type !== "message") throw new WorkerError("unsupported_event_type");
  if (
    typeof value.streamID !== "string"
    || !/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i
      .test(value.streamID)
  ) {
    throw new WorkerError("invalid_stream_id");
  }
  if (typeof value.sequence !== "string" || !/^[1-9][0-9]{0,18}$/.test(value.sequence)) {
    throw new WorkerError("invalid_sequence");
  }
  const sequence = BigInt(value.sequence);
  if (sequence > MAX_SEQUENCE) throw new WorkerError("invalid_sequence");
  if (typeof value.emittedAt !== "string" || Number.isNaN(Date.parse(value.emittedAt))) {
    throw new WorkerError("invalid_emitted_at");
  }

  const payload = value.payload;
  if (!isPlainObject(payload)) throw new WorkerError("invalid_payload");
  if (typeof payload.eventID !== "string" || payload.eventID.length === 0) {
    throw new WorkerError("invalid_event_id");
  }
  if (typeof payload.group !== "string" || typeof payload.content !== "string") {
    throw new WorkerError("invalid_message_text");
  }
  if (
    (payload.senderDisplayName !== null
      && payload.senderDisplayName !== undefined
      && typeof payload.senderDisplayName !== "string")
    || (payload.senderStableID !== null
      && payload.senderStableID !== undefined
      && typeof payload.senderStableID !== "string")
  ) {
    throw new WorkerError("invalid_sender");
  }
  if (!["text", "media", "system", "unknown"].includes(payload.messageType)) {
    throw new WorkerError("invalid_message_type");
  }
  if (typeof payload.observedAt !== "string" || Number.isNaN(Date.parse(payload.observedAt))) {
    throw new WorkerError("invalid_observed_at");
  }
  if (!Array.isArray(payload.attachments)) throw new WorkerError("invalid_attachments");
  if (!payload.attachments.every((attachment) => (
    isPlainObject(attachment)
    && typeof attachment.fileURL === "string"
    && ["image", "video", "audio", "file", "unknown"].includes(attachment.kind)
    && (attachment.identifier === null
      || attachment.identifier === undefined
      || typeof attachment.identifier === "string")
    && (attachment.typeHint === null
      || attachment.typeHint === undefined
      || typeof attachment.typeHint === "string")
  ))) {
    throw new WorkerError("invalid_attachment");
  }
  if (
    !["localized_label", "structured_fragments", "notification_payload", "unavailable"]
      .includes(payload.senderConfidence)
    || typeof payload.isFromSelf !== "boolean"
  ) {
    throw new WorkerError("invalid_message_metadata");
  }
  if (
    payload.sourceSequence !== null
    && payload.sourceSequence !== undefined
    && (typeof payload.sourceSequence !== "string"
      || !/^[0-9]{1,19}$/.test(payload.sourceSequence))
  ) {
    throw new WorkerError("invalid_source_sequence");
  }
  if (
    typeof payload.sourceSequence === "string"
    && BigInt(payload.sourceSequence) > MAX_SEQUENCE
  ) {
    throw new WorkerError("invalid_source_sequence");
  }

  return { envelope: value, payload, sequence };
}

class NDJSONSplitter {
  constructor(onLine) {
    this.onLine = onLine;
    this.fragments = [];
    this.byteCount = 0;
  }

  append(fragment) {
    if (this.byteCount + fragment.length > MAX_LINE_BYTES) {
      throw new WorkerError("line_too_large");
    }
    if (fragment.length > 0) this.fragments.push(fragment);
    this.byteCount += fragment.length;
  }

  async push(chunk) {
    let start = 0;
    for (let index = 0; index < chunk.length; index += 1) {
      if (chunk[index] !== 0x0a) continue;
      this.append(chunk.subarray(start, index));
      await this.flushLine();
      start = index + 1;
    }
    this.append(chunk.subarray(start));
  }

  async flushLine() {
    let line = Buffer.concat(this.fragments, this.byteCount);
    this.fragments = [];
    this.byteCount = 0;
    if (line.length > 0 && line[line.length - 1] === 0x0d) line = line.subarray(0, -1);
    if (line.length === 0) return;

    let text;
    try {
      text = utf8.decode(line);
    } catch {
      throw new WorkerError("invalid_utf8");
    }

    let value;
    try {
      value = JSON.parse(text);
    } catch {
      throw new WorkerError("invalid_json");
    }
    await this.onLine(value);
  }

  discardPartialLine() {
    const byteCount = this.byteCount;
    this.fragments = [];
    this.byteCount = 0;
    return byteCount;
  }
}

async function verifySocket(socketPath) {
  if (!path.isAbsolute(socketPath) || socketPath.includes("\0")) {
    throw new WorkerError("invalid_socket_path", true);
  }
  if (Buffer.byteLength(socketPath, "utf8") > 103) {
    throw new WorkerError("socket_path_too_long", true);
  }

  let info;
  try {
    info = await lstat(socketPath);
  } catch (error) {
    throw new WorkerError(error?.code === "ENOENT" ? "socket_missing" : "socket_stat_failed");
  }
  if (info.isSymbolicLink() || !info.isSocket()) {
    throw new WorkerError("socket_type_rejected", true);
  }
  if (typeof process.getuid === "function" && info.uid !== process.getuid()) {
    throw new WorkerError("socket_owner_rejected", true);
  }
  if ((info.mode & 0o777) !== 0o600) {
    throw new WorkerError("socket_permissions_rejected", true);
  }
}

function defaultSocketPath() {
  return path.join(
    os.homedir(),
    "Library",
    "Application Support",
    "wxFomo",
    "automation",
    "events.sock",
  );
}

function parseSocketPath(argv) {
  if (argv.length === 0) return defaultSocketPath();
  if (argv.length === 2 && argv[0] === "--socket") return argv[1];
  throw new WorkerError("invalid_arguments", true);
}

class ReadonlyWorker {
  constructor(socketPath) {
    this.socketPath = socketPath;
    this.stopped = false;
    this.socket = null;
    this.retryAttempt = 0;
    this.retryTimer = null;
    this.retryResolve = null;
    this.activeStreamID = null;
    this.lastSequence = null;
  }

  async run() {
    while (!this.stopped) {
      let connectedAt = null;
      try {
        await verifySocket(this.socketPath);
        if (this.stopped) return;
        connectedAt = await this.consumeConnection();
      } catch (error) {
        if (this.stopped) return;
        const code = error instanceof WorkerError ? error.code : "connection_failed";
        await safeLog("connection_error", { code });
        if (error instanceof WorkerError && error.permanent) {
          process.exitCode = 2;
          return;
        }
      }
      if (this.stopped) return;

      if (connectedAt !== null && Date.now() - connectedAt >= STABLE_SESSION_MS) {
        this.retryAttempt = 0;
      } else {
        this.retryAttempt += 1;
      }
      await this.waitBeforeRetry();
    }
  }

  async consumeConnection() {
    const socket = net.createConnection({ path: this.socketPath });
    this.socket = socket;
    let connectedAt;
    try {
      await new Promise((resolve, reject) => {
        let settled = false;
        const finish = (callback, value) => {
          if (settled) return;
          settled = true;
          clearTimeout(timeout);
          socket.off("connect", onConnect);
          socket.off("error", onError);
          socket.off("close", onClose);
          callback(value);
        };
        const onConnect = () => finish(resolve);
        const onError = () => finish(reject, new WorkerError("connect_failed"));
        const onClose = () => finish(reject, new WorkerError("connect_closed"));
        const timeout = setTimeout(
          () => finish(reject, new WorkerError("connect_timeout")),
          10_000,
        );
        socket.once("connect", onConnect);
        socket.once("error", onError);
        socket.once("close", onClose);
        if (this.stopped) {
          socket.destroy();
          finish(reject, new WorkerError("stopped"));
        }
      });

      if (this.stopped) return null;
      connectedAt = Date.now();
      await safeLog("connected");
    } catch (error) {
      socket.destroy();
      if (this.socket === socket) this.socket = null;
      throw error;
    }

    const splitter = new NDJSONSplitter(async (rawEnvelope) => {
      let decoded;
      try {
        decoded = validateEnvelope(rawEnvelope);
      } catch (error) {
        if (error instanceof WorkerError && error.code === "unsupported_schema_version") {
          await safeLog("schema_rejected", {
            schemaVersion: Number.isInteger(rawEnvelope?.schemaVersion)
              ? rawEnvelope.schemaVersion
              : undefined,
            code: error.code,
          });
        }
        throw error;
      }

      if (this.activeStreamID !== decoded.envelope.streamID) {
        this.activeStreamID = decoded.envelope.streamID;
        this.lastSequence = null;
      }
      if (this.lastSequence !== null && decoded.sequence <= this.lastSequence) {
        await safeLog("sequence_non_monotonic", {
          expectedSequence: String(this.lastSequence + 1n),
          receivedSequence: decoded.envelope.sequence,
        });
        return;
      }
      const expectedSequence = this.lastSequence === null ? 1n : this.lastSequence + 1n;
      if (decoded.sequence !== expectedSequence) {
        await safeLog("sequence_gap", {
          expectedSequence: String(expectedSequence),
          receivedSequence: decoded.envelope.sequence,
        });
      }
      this.lastSequence = decoded.sequence;

      await safeLog("message", {
        schemaVersion: decoded.envelope.schemaVersion,
        type: decoded.envelope.type,
        sequence: decoded.envelope.sequence,
        messageType: decoded.payload.messageType,
        attachmentCount: decoded.payload.attachments.length,
        hasSender: typeof decoded.payload.senderDisplayName === "string",
        hasSourceSequence: typeof decoded.payload.sourceSequence === "string",
      });
    });

    try {
      for await (const chunk of socket) {
        await splitter.push(chunk);
      }
      const truncatedBytes = splitter.discardPartialLine();
      if (truncatedBytes > 0) await safeLog("truncated_line", { byteCount: truncatedBytes });
      await safeLog("disconnected");
      return connectedAt;
    } finally {
      socket.destroy();
      if (this.socket === socket) this.socket = null;
    }
  }

  async waitBeforeRetry() {
    if (this.stopped) return;
    const ceiling = Math.min(30_000, 250 * (2 ** Math.min(this.retryAttempt, 16)));
    const reconnectMs = Math.floor((ceiling / 2) + (Math.random() * ceiling / 2));
    await safeLog("reconnect_scheduled", { reconnectMs });
    await new Promise((resolve) => {
      this.retryResolve = resolve;
      this.retryTimer = setTimeout(() => {
        this.retryResolve = null;
        resolve();
      }, reconnectMs);
    });
    this.retryTimer = null;
  }

  stop() {
    this.stopped = true;
    if (this.retryTimer !== null) clearTimeout(this.retryTimer);
    this.retryTimer = null;
    this.retryResolve?.();
    this.retryResolve = null;
    this.socket?.destroy();
  }
}

let socketPath;
try {
  socketPath = parseSocketPath(process.argv.slice(2));
} catch (error) {
  await safeLog("startup_error", {
    code: error instanceof WorkerError ? error.code : "invalid_arguments",
  });
  process.exitCode = 2;
}

if (socketPath !== undefined) {
  const worker = new ReadonlyWorker(socketPath);
  process.once("SIGINT", () => worker.stop());
  process.once("SIGTERM", () => worker.stop());
  await worker.run();
}
