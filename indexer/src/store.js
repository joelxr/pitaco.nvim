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
    embeddings: readJson(paths.embeddingsPath, { version: 1, items: {} }),
    summary: readJson(paths.summaryPath, {}),
  };
}

export function saveStore(root, store) {
  const paths = getIndexPaths(root);
  ensureDir(paths.baseDir);
  ensureDir(paths.indexDir);
  writeJson(paths.manifestPath, store.manifest);
  writeJson(paths.chunksPath, store.chunks);
  writeJson(paths.embeddingsPath, store.embeddings);
  writeJson(paths.summaryPath, store.summary);
}

export function buildFileOutline(store, relativePath, changedLines = []) {
  const file = store.manifest.files[relativePath];
  if (!file) {
    return null;
  }

  const rangeList = Array.isArray(changedLines) ? changedLines : [];
  const hasChangedLines = rangeList.length > 0;
  const chunkIds = new Set(file.chunkIds || []);
  const symbols = [];

  for (const chunk of store.chunks) {
    if (!chunkIds.has(chunk.id)) {
      continue;
    }

    const intersectsChangedLines = !hasChangedLines || rangeList.some((range) => {
      const startLine = Number(range.startLine) || 0;
      const endLine = Number(range.endLine) || startLine;
      return chunk.startLine <= endLine && chunk.endLine >= startLine;
    });
    if (!intersectsChangedLines) {
      continue;
    }

    symbols.push({
      kind: chunk.kind,
      symbol: chunk.symbol,
      startLine: chunk.startLine,
      endLine: chunk.endLine,
    });
  }

  symbols.sort((left, right) => {
    if (left.startLine !== right.startLine) {
      return left.startLine - right.startLine;
    }
    return left.endLine - right.endLine;
  });

  return {
    file: relativePath,
    language: file.language,
    imports: file.imports || [],
    exports: file.exports || [],
    symbols,
  };
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
