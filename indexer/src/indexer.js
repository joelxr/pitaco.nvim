import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { Worker } from "node:worker_threads";
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
  const embeddingText = [
    `File: ${relativePath}`,
    `Language: ${language}`,
    `Kind: ${parsedChunk.kind}`,
    `Symbol: ${symbol}`,
    `Imports: ${imports.join(" | ")}`,
    `Exports: ${exportsList.join(" | ")}`,
    parsedChunk.code,
  ].join("\n");

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
    embeddingText,
    embeddingTextHash: sha1(embeddingText),
  };
}

function embeddingSourceKey(embeddingConfig, engine = embeddingConfig.provider || "mock") {
  const model = embeddingConfig.model || "";
  const baseUrl = engine === "ollama" ? (embeddingConfig.baseUrl || process.env.OLLAMA_URL || "http://localhost:11434") : "";
  return [engine, model, baseUrl].join(":");
}

function compactVector(vector) {
  return vector.map((value) => Number(value.toFixed(6)));
}

function canReuseChunkEmbedding(chunk, expectedSource, expectedEngine) {
  if (!Array.isArray(chunk?.embedding) || chunk.embedding.length === 0) {
    return false;
  }

  if (typeof chunk.embedding_source === "string" && chunk.embedding_source !== "") {
    return chunk.embedding_source === expectedSource;
  }

  return chunk.embedding_engine === expectedEngine;
}

function buildEmbeddingCache(store, expectedSource, expectedEngine) {
  const cache = new Map();

  for (const chunk of store.chunks) {
    if (!canReuseChunkEmbedding(chunk, expectedSource, expectedEngine)) {
      continue;
    }

    const embeddingTextHash = chunk.embeddingTextHash || sha1(chunk.embeddingText || "");
    if (embeddingTextHash && !cache.has(embeddingTextHash)) {
      cache.set(embeddingTextHash, chunk);
    }
  }

  return cache;
}

function persistedChunk(chunk, embedding, embeddingEngine, embeddingSource) {
  return {
    id: chunk.id,
    file: chunk.file,
    language: chunk.language,
    kind: chunk.kind,
    symbol: chunk.symbol,
    startLine: chunk.startLine,
    endLine: chunk.endLine,
    imports: chunk.imports,
    exports: chunk.exports,
    code: chunk.code,
    embeddingTextHash: chunk.embeddingTextHash,
    embedding: compactVector(embedding),
    embedding_engine: embeddingEngine,
    embedding_source: embeddingSource,
  };
}

function canReuseFileChunks(previous, existingById, expectedSource, expectedEngine) {
  if (!previous || !Array.isArray(previous.chunkIds) || previous.chunkIds.length === 0) {
    return false;
  }

  for (const chunkId of previous.chunkIds) {
    const chunk = existingById.get(chunkId);
    if (!canReuseChunkEmbedding(chunk, expectedSource, expectedEngine)) {
      return false;
    }
  }

  return true;
}

async function mapWithConcurrency(items, concurrency, iteratee) {
  const results = new Array(items.length);
  let nextIndex = 0;

  async function worker() {
    while (nextIndex < items.length) {
      const currentIndex = nextIndex;
      nextIndex += 1;
      results[currentIndex] = await iteratee(items[currentIndex], currentIndex);
    }
  }

  const workerCount = Math.min(Math.max(1, concurrency), items.length);
  await Promise.all(Array.from({ length: workerCount }, () => worker()));
  return results;
}

async function parseFileInWorker(language, source) {
  return new Promise((resolve, reject) => {
    const worker = new Worker(new URL("./parse_worker.js", import.meta.url), { type: "module" });
    let settled = false;

    function finish(fn, value) {
      if (settled) {
        return;
      }
      settled = true;
      worker.terminate().finally(() => {
        fn(value);
      });
    }

    worker.once("message", (message) => {
      if (message?.error) {
        finish(reject, new Error(message.error));
        return;
      }

      finish(resolve, message?.result ?? { imports: [], exports: [], chunks: [] });
    });

    worker.once("error", (error) => {
      finish(reject, error);
    });

    worker.once("exit", (code) => {
      if (!settled && code !== 0) {
        finish(reject, new Error(`Parse worker exited with code ${code}`));
      }
    });

    worker.postMessage({ language, source });
  });
}

async function parseSource(language, source, parseConcurrency) {
  if (parseConcurrency <= 1) {
    return parseFile(language, source);
  }

  return parseFileInWorker(language, source);
}

export async function indexRepository(root, options = {}) {
  const onProgress = typeof options.onProgress === "function" ? options.onProgress : null;
  const config = loadContextConfig(root);
  const store = loadStore(root);
  const files = scanFiles(root);
  if (onProgress) {
    onProgress({
      stage: "scan",
      message: `Scanning repository (${files.length} files)`,
      current: 0,
      total: files.length,
    });
  }
  const existingById = new Map(store.chunks.map((chunk) => [chunk.id, chunk]));
  const expectedEmbeddingEngine = config.embedding.provider || "mock";
  const expectedEmbeddingSource = embeddingSourceKey(config.embedding, expectedEmbeddingEngine);
  const existingByEmbeddingText = buildEmbeddingCache(store, expectedEmbeddingSource, expectedEmbeddingEngine);
  const nextManifest = { version: 1, files: {} };
  const nextChunks = [];
  let indexedFiles = 0;
  let changedFiles = 0;
  const pendingFiles = [];

  for (const file of files) {
    const stat = fs.statSync(file.absolutePath);
    const previous = store.manifest.files[file.relativePath];

    if (
      previous
      && previous.mtimeMs === stat.mtimeMs
      && previous.size === stat.size
      && canReuseFileChunks(previous, existingById, expectedEmbeddingSource, expectedEmbeddingEngine)
    ) {
      nextManifest.files[file.relativePath] = previous;
      for (const chunkId of previous.chunkIds) {
        const chunk = existingById.get(chunkId);
        if (chunk) {
          nextChunks.push(chunk);
        }
      }
      continue;
    }

    pendingFiles.push({
      file,
      stat,
      previous,
    });
  }

  const preparedFiles = await mapWithConcurrency(
    pendingFiles,
    config.indexing.parseConcurrency,
    async ({ file, stat, previous }) => {
      const source = await fs.promises.readFile(file.absolutePath, "utf8");
      const hash = sha1(source);

      if (
        previous
        && previous.hash === hash
        && canReuseFileChunks(previous, existingById, expectedEmbeddingSource, expectedEmbeddingEngine)
      ) {
        return {
          file,
          stat,
          hash,
          previous,
          reused: true,
        };
      }

      return {
        file,
        stat,
        hash,
        parsed: await parseSource(file.language, source, config.indexing.parseConcurrency),
        source,
        reused: false,
      };
    },
  );

  for (const prepared of preparedFiles) {
    indexedFiles += 1;
    if (onProgress) {
      onProgress({
        stage: "index",
        message: `Indexing ${indexedFiles}/${files.length}`,
        current: indexedFiles,
        total: files.length,
      });
    }

    const { file, stat, hash, previous } = prepared;

    if (prepared.reused) {
      nextManifest.files[file.relativePath] = {
        ...previous,
        hash,
        mtimeMs: stat.mtimeMs,
        size: stat.size,
      };
      for (const chunkId of previous.chunkIds) {
        const chunk = existingById.get(chunkId);
        if (chunk) {
          nextChunks.push(chunk);
        }
      }
      continue;
    }

    changedFiles += 1;
    const { parsed, source } = prepared;
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
    const indexedChunks = new Array(chunks.length);
    const pendingTexts = [];
    const pendingIndexes = [];

    chunks.forEach((chunk, index) => {
      const cachedChunk = existingByEmbeddingText.get(chunk.embeddingTextHash);
      if (cachedChunk) {
        indexedChunks[index] = persistedChunk(
          chunk,
          cachedChunk.embedding,
          cachedChunk.embedding_engine,
          cachedChunk.embedding_source || expectedEmbeddingSource,
        );
        return;
      }

      pendingTexts.push(chunk.embeddingText);
      pendingIndexes.push(index);
    });

    if (pendingTexts.length > 0) {
      const embeddings = await embedTexts(pendingTexts, config.embedding);
      const embeddingSource = embeddingSourceKey(config.embedding, embeddings.engine);

      pendingIndexes.forEach((chunkIndex, resultIndex) => {
        indexedChunks[chunkIndex] = persistedChunk(
          chunks[chunkIndex],
          embeddings.vectors[resultIndex],
          embeddings.engine,
          embeddingSource,
        );
      });
    }

    indexedChunks.forEach((chunk) => {
      nextChunks.push(chunk);
    });

    nextManifest.files[file.relativePath] = {
      hash,
      mtimeMs: stat.mtimeMs,
      size: stat.size,
      language: file.language,
      imports: parsed.imports,
      exports: parsed.exports,
      chunkIds: chunks.map((chunk) => chunk.id),
    };
  }

  store.manifest = nextManifest;
  store.chunks = nextChunks;
  store.summary = buildSummary(root, nextManifest, nextChunks);
  if (onProgress) {
    onProgress({
      stage: "save",
      message: "Writing index files",
      current: files.length,
      total: files.length,
    });
  }
  saveStore(root, store);

  return {
    root,
    indexed_files: indexedFiles,
    changed_files: changedFiles,
    total_chunks: nextChunks.length,
    summary: store.summary,
  };
}
