import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { IGNORED_DIRECTORIES, SUPPORTED_LANGUAGES, loadContextConfig } from "./config.js";
import { embedTexts } from "./embeddings.js";
import { parseFile } from "./parser.js";
import { buildSummary, loadStore, saveStore } from "./store.js";

function sha1(value) {
  return crypto.createHash("sha1").update(value).digest("hex");
}

function scanFiles(root) {
  const result = [];

  function visit(currentDir) {
    const entries = fs.readdirSync(currentDir, { withFileTypes: true });
    for (const entry of entries) {
      if (entry.isDirectory()) {
        if (!IGNORED_DIRECTORIES.has(entry.name)) {
          visit(path.join(currentDir, entry.name));
        }
        continue;
      }

      const filePath = path.join(currentDir, entry.name);
      const language = SUPPORTED_LANGUAGES[path.extname(entry.name)];
      if (!language) {
        continue;
      }

      result.push({
        absolutePath: filePath,
        relativePath: path.relative(root, filePath),
        language,
      });
    }
  }

  visit(root);
  result.sort((left, right) => left.relativePath.localeCompare(right.relativePath));
  return result;
}

function createChunk(relativePath, language, imports, exportsList, parsedChunk) {
  const symbol = parsedChunk.symbol || `${relativePath}:${parsedChunk.startLine}`;
  const id = sha1(`${relativePath}:${parsedChunk.kind}:${symbol}:${parsedChunk.startLine}:${parsedChunk.endLine}`);

  return {
    id,
    file: relativePath,
    language,
    kind: parsedChunk.kind,
    symbol,
    startLine: parsedChunk.startLine,
    endLine: parsedChunk.endLine,
    imports,
    exports: exportsList,
    code: parsedChunk.code.trim(),
    embeddingText: [
      `File: ${relativePath}`,
      `Language: ${language}`,
      `Kind: ${parsedChunk.kind}`,
      `Symbol: ${symbol}`,
      `Imports: ${imports.join(" | ")}`,
      `Exports: ${exportsList.join(" | ")}`,
      parsedChunk.code,
    ].join("\n"),
  };
}

export async function indexRepository(root) {
  const config = loadContextConfig(root);
  const store = loadStore(root);
  const files = scanFiles(root);
  const existingById = new Map(store.chunks.map((chunk) => [chunk.id, chunk]));
  const nextManifest = { version: 1, files: {} };
  const nextChunks = [];
  let indexedFiles = 0;
  let changedFiles = 0;

  for (const file of files) {
    indexedFiles += 1;
    const source = fs.readFileSync(file.absolutePath, "utf8");
    const stat = fs.statSync(file.absolutePath);
    const hash = sha1(source);
    const previous = store.manifest.files[file.relativePath];

    if (previous && previous.hash === hash && previous.mtimeMs === stat.mtimeMs) {
      nextManifest.files[file.relativePath] = previous;
      for (const chunkId of previous.chunkIds) {
        const chunk = existingById.get(chunkId);
        if (chunk) {
          nextChunks.push(chunk);
        }
      }
      continue;
    }

    changedFiles += 1;
    const parsed = parseFile(file.language, source);
    const semanticChunks = parsed.chunks.length > 0
      ? parsed.chunks
      : [{
        kind: "file",
        symbol: path.basename(file.relativePath),
        code: source,
        startLine: 1,
        endLine: source.split("\n").length,
      }];

    const chunks = semanticChunks.map((chunk) =>
      createChunk(file.relativePath, file.language, parsed.imports, parsed.exports, chunk),
    );
    const embeddings = await embedTexts(chunks.map((chunk) => chunk.embeddingText), config.embedding);

    chunks.forEach((chunk, index) => {
      nextChunks.push({
        ...chunk,
        embedding: embeddings.vectors[index],
        embedding_engine: embeddings.engine,
      });
    });

    nextManifest.files[file.relativePath] = {
      hash,
      mtimeMs: stat.mtimeMs,
      language: file.language,
      imports: parsed.imports,
      exports: parsed.exports,
      chunkIds: chunks.map((chunk) => chunk.id),
    };
  }

  store.manifest = nextManifest;
  store.chunks = nextChunks;
  store.summary = buildSummary(root, nextManifest, nextChunks);
  saveStore(root, store);

  return {
    root,
    indexed_files: indexedFiles,
    changed_files: changedFiles,
    total_chunks: nextChunks.length,
    summary: store.summary,
  };
}
