import fs from "node:fs";
import path from "node:path";
import { getIndexPaths } from "./config.js";

function ensureDir(dirPath) {
  fs.mkdirSync(dirPath, { recursive: true });
}

function readJson(filePath, fallback) {
  if (!fs.existsSync(filePath)) {
    return fallback;
  }

  return JSON.parse(fs.readFileSync(filePath, "utf8"));
}

function writeJson(filePath, value) {
  fs.writeFileSync(filePath, JSON.stringify(value, null, 2));
}

export function loadStore(root) {
  const paths = getIndexPaths(root);
  ensureDir(paths.indexDir);
  return {
    paths,
    manifest: readJson(paths.manifestPath, { version: 1, files: {} }),
    chunks: readJson(paths.chunksPath, []),
    summary: readJson(paths.summaryPath, {}),
  };
}

export function saveStore(root, store) {
  const paths = getIndexPaths(root);
  ensureDir(paths.baseDir);
  ensureDir(paths.indexDir);
  writeJson(paths.manifestPath, store.manifest);
  writeJson(paths.chunksPath, store.chunks);
  writeJson(paths.summaryPath, store.summary);
}

export function buildSummary(root, manifest, chunks) {
  const languages = {};
  const symbols = {};

  for (const file of Object.values(manifest.files)) {
    languages[file.language] = (languages[file.language] || 0) + 1;
  }

  for (const chunk of chunks) {
    if (chunk.symbol) {
      symbols[chunk.symbol] = (symbols[chunk.symbol] || 0) + 1;
    }
  }

  return {
    repository_name: path.basename(root),
    file_count: Object.keys(manifest.files).length,
    chunk_count: chunks.length,
    languages: Object.keys(languages).sort((left, right) => languages[right] - languages[left]),
    top_symbols: Object.keys(symbols).sort((left, right) => symbols[right] - symbols[left]).slice(0, 10),
    updated_at: new Date().toISOString(),
  };
}
