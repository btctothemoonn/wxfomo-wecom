#!/usr/bin/env node

import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const configPath = path.join(
  os.homedir(),
  "Library",
  "Application Support",
  "wxFomo",
  "configuration-center.json"
);
const outputPath = path.resolve(process.argv[2] || "dist/sophie-stream-probe.mp3");
const text = process.argv[3] || "发现 CA";

const document = JSON.parse(fs.readFileSync(configPath, "utf8"));
const configuration = document?.speech?.configuration || {};
const apiKey = String(document?.speech?.volcengineSeedAPIKey || "").trim();
if (!apiKey) throw new Error("配置中心没有火山语音 API Key");

const endpoint = configuration.seedStreamEndpoint
  || "https://openspeech.bytedance.com/api/v3/tts/unidirectional";
const model = configuration.seedStreamModel || "seed-tts-2.0-expressive";
const resourceId = configuration.seedResourceID || "seed-tts-2.0";
const speaker = configuration.voiceID || "zh_female_sophie_uranus_bigtts";
const format = configuration.audioFormat || "mp3";
const sampleRate = Number(configuration.sampleRate || 24000);

const response = await fetch(endpoint, {
  method: "POST",
  headers: {
    "Content-Type": "application/json",
    Accept: "text/plain",
    "X-Api-Key": apiKey,
    "X-Api-Resource-Id": resourceId,
    "X-Api-Request-Id": crypto.randomUUID()
  },
  body: JSON.stringify({
    user: { uid: "wxFomo-probe" },
    req_params: {
      text,
      speaker,
      model,
      audio_params: {
        format,
        sample_rate: sampleRate,
        speech_rate: 0
      },
      additions: JSON.stringify({
        disable_markdown_filter: true,
        cache_config: { text_type: 1, use_cache: false }
      })
    }
  })
});

if (!response.ok) {
  const message = (await response.text()).slice(0, 400);
  throw new Error(`火山流式语音 HTTP ${response.status}: ${message}`);
}
if (!response.body) throw new Error("火山流式语音没有响应体");

let pending = "";
let complete = false;
const audioChunks = [];

function processLine(rawLine) {
  const line = rawLine.trim();
  if (!line) return;
  const frame = JSON.parse(line);
  const code = Number(frame?.code ?? 0);
  if (code === 0 && frame?.data) {
    audioChunks.push(Buffer.from(frame.data, "base64"));
    return;
  }
  if (code === 0) return;
  if (code === 20000000) {
    complete = true;
    return;
  }
  throw new Error(`火山流式语音失败（${code}）：${frame?.message || "未知错误"}`);
}

const decoder = new TextDecoder();
for await (const chunk of response.body) {
  pending += decoder.decode(chunk, { stream: true });
  let newlineIndex;
  while ((newlineIndex = pending.indexOf("\n")) >= 0) {
    processLine(pending.slice(0, newlineIndex));
    pending = pending.slice(newlineIndex + 1);
  }
}
pending += decoder.decode();
processLine(pending);

if (!audioChunks.length) throw new Error("火山流式语音没有返回音频");
if (!complete) throw new Error("火山流式语音没有返回完成帧");

const audio = Buffer.concat(audioChunks);
fs.mkdirSync(path.dirname(outputPath), { recursive: true });
fs.writeFileSync(outputPath, audio, { mode: 0o600 });
console.log(JSON.stringify({
  ok: true,
  model,
  resourceId,
  speaker,
  audioChunks: audioChunks.length,
  audioBytes: audio.length,
  outputPath
}));
