import fs from "node:fs";
import path from "node:path";
import { loadContextConfig } from "./config.js";
import { cosineSimilarity, embedTexts, lexicalOverlap } from "./embeddings.js";
import { loadStore } from "./store.js";

function candidateText(chunk) {
  return [
    `File: ${chunk.file}`,
    `Language: ${chunk.language}`,
    `Kind: ${chunk.kind}`,
    `Symbol: ${chunk.symbol}`,
    `Imports: ${(chunk.imports || []).join(" | ")}`,
    `Exports: ${(chunk.exports || []).join(" | ")}`,
    chunk.code || "",
  ].join("\n");
}

function scoreChunk(queryText, queryEmbedding, chunk, currentFile) {
  const embeddingScore = cosineSimilarity(queryEmbedding, chunk.embedding);
  const lexicalScore = lexicalOverlap(queryText, candidateText(chunk));
  const filePenalty = chunk.file === currentFile ? -0.2 : 0;
  const symbolBoost = queryText.includes(chunk.symbol) ? 0.1 : 0;
  return embeddingScore + lexicalScore * 0.35 + filePenalty + symbolBoost;
}

export async function searchRepository(root, fileArg, limit) {
  const absoluteFile = path.isAbsolute(fileArg) ? fileArg : path.join(root, fileArg);
  const relativeFile = path.relative(root, absoluteFile);
  const source = fs.existsSync(absoluteFile) ? fs.readFileSync(absoluteFile, "utf8") : "";
  const queryText = [`File: ${relativeFile}`, source].join("\n");
  const config = loadContextConfig(root);
  const store = loadStore(root);
  const embeddings = await embedTexts([queryText], config.embedding);
  const queryEmbedding = embeddings.vectors[0];
  const results = store.chunks
    .map((chunk) => ({
      ...chunk,
      score: scoreChunk(queryText, queryEmbedding, chunk, relativeFile),
    }))
    .sort((left, right) => right.score - left.score)
    .slice(0, limit);

  return {
    root,
    engine: embeddings.warning ? `${embeddings.engine} (fallback)` : embeddings.engine,
    warning: embeddings.warning,
    summary: store.summary,
    results: results.map((chunk) => ({
      id: chunk.id,
      file: chunk.file,
      language: chunk.language,
      kind: chunk.kind,
      symbol: chunk.symbol,
      startLine: chunk.startLine,
      endLine: chunk.endLine,
      score: chunk.score,
      code: chunk.code,
      imports: chunk.imports,
      exports: chunk.exports,
    })),
  };
}
