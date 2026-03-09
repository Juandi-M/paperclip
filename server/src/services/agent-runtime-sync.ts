/**
 * Agent Runtime Sync Service
 *
 * Periodically syncs the local agent-runtime directory to S3 so that agent
 * memory, notes, and logs survive container restarts and re-deployments.
 *
 * Directory layout (local):
 *   <agentRuntimeDir>/<agentName>/<...files>
 *
 * S3 object key layout (per Paperclip instance):
 *   agent-runtime/<instanceId>/<agentName>/<...files>
 *
 * Only runs when the storage provider is "s3". Silently skips on "local_disk".
 * Skips individual files whose S3 etag matches the local content hash —
 * unchanged files are never re-uploaded.
 */

import fs from "node:fs/promises";
import path from "node:path";
import { createHash } from "node:crypto";
import { loadConfig } from "../config.js";
import { createStorageProviderFromConfig } from "../storage/provider-registry.js";
import { resolvePaperclipInstanceId } from "../home-paths.js";
import type { StorageProvider } from "../storage/types.js";

function md5(buf: Buffer): string {
  return createHash("md5").update(buf).digest("hex");
}

function normalizeEtag(raw: string | undefined): string {
  // S3 ETags are quoted strings: "abc123" → abc123
  return raw ? raw.replace(/^"|"$/g, "") : "";
}

async function walkDir(dir: string): Promise<string[]> {
  const entries = await fs.readdir(dir, { withFileTypes: true });
  const results: string[] = [];
  for (const entry of entries) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      results.push(...(await walkDir(full)));
    } else if (entry.isFile()) {
      results.push(full);
    }
  }
  return results;
}

async function syncFile(
  provider: StorageProvider,
  localPath: string,
  objectKey: string,
): Promise<"uploaded" | "skipped" | "error"> {
  try {
    const body = await fs.readFile(localPath);
    const localEtag = md5(body);

    const head = await provider.headObject({ objectKey });
    if (head.exists && normalizeEtag(head.etag) === localEtag) {
      return "skipped";
    }

    await provider.putObject({
      objectKey,
      body,
      contentType: "application/octet-stream",
      contentLength: body.length,
    });
    return "uploaded";
  } catch {
    return "error";
  }
}

export async function syncAgentRuntimeToS3(): Promise<{
  provider: string;
  uploaded: number;
  skipped: number;
  errors: number;
}> {
  const config = loadConfig();

  if (config.storageProvider !== "s3") {
    return { provider: config.storageProvider, uploaded: 0, skipped: 0, errors: 0 };
  }

  const runtimeDir = config.agentRuntimeDir;

  // Ensure the directory exists before trying to walk it
  const exists = await fs.stat(runtimeDir).then((s) => s.isDirectory()).catch(() => false);
  if (!exists) {
    return { provider: "s3", uploaded: 0, skipped: 0, errors: 0 };
  }

  const provider = createStorageProviderFromConfig(config);
  const instanceId = resolvePaperclipInstanceId();
  const files = await walkDir(runtimeDir);

  let uploaded = 0;
  let skipped = 0;
  let errors = 0;

  for (const filePath of files) {
    const relative = path.relative(runtimeDir, filePath);
    const objectKey = `agent-runtime/${instanceId}/${relative.split(path.sep).join("/")}`;
    const result = await syncFile(provider, filePath, objectKey);
    if (result === "uploaded") uploaded++;
    else if (result === "skipped") skipped++;
    else errors++;
  }

  return { provider: "s3", uploaded, skipped, errors };
}
