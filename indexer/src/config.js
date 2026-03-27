import fs from "node:fs";
import os from "node:os";
import path from "node:path";

export const IGNORED_DIRECTORIES = new Set([
  ".git",
  ".repo-pitaco",
  "build",
  "dist",
  "node_modules",
  "target",
  "vendor",
]);

export const SUPPORTED_LANGUAGES = {
  ".go": "go",
  ".js": "javascript",
  ".jsx": "javascript",
  ".lua": "lua",
  ".py": "python",
  ".ts": "typescript",
  ".tsx": "typescript",
};

export function findRepositoryRoot(startDir = process.cwd()) {
  let current = path.resolve(startDir);

  while (true) {
    if (fs.existsSync(path.join(current, ".git"))) {
      return current;
    }

    const parent = path.dirname(current);
    if (parent === current) {
      return path.resolve(startDir);
    }
    current = parent;
  }
}

export function getIndexPaths(root) {
  const baseDir = path.join(root, ".repo-pitaco");
  const indexDir = path.join(baseDir, "index");
  return {
    baseDir,
    indexDir,
    configPath: path.join(baseDir, "config.json"),
    lockPath: path.join(indexDir, "index.lock"),
    statusPath: path.join(indexDir, "index.status.json"),
    manifestPath: path.join(indexDir, "manifest.json"),
    chunksPath: path.join(indexDir, "chunks.json"),
    embeddingsPath: path.join(indexDir, "embeddings.json"),
    summaryPath: path.join(indexDir, "summary.json"),
  };
}

function readJson(filePath) {
  if (!fs.existsSync(filePath)) {
    return null;
  }

  return JSON.parse(fs.readFileSync(filePath, "utf8"));
}

function defaultEmbeddingConfig() {
  const explicitProvider = process.env.PITACO_EMBEDDING_PROVIDER;
  if (explicitProvider) {
    return { provider: explicitProvider };
  }

  if (process.env.OPENAI_API_KEY) {
    return { provider: "openai", model: "text-embedding-3-small" };
  }

  if (process.env.OPENROUTER_API_KEY) {
    return { provider: "openrouter", model: "text-embedding-3-small" };
  }

  return { provider: "mock", model: "hash-256" };
}

function defaultParseConcurrency() {
  const parallelism = typeof os.availableParallelism === "function"
    ? os.availableParallelism()
    : ((os.cpus() || []).length || 1);
  return Math.max(1, Math.min(4, parallelism));
}

function positiveInteger(value, fallback) {
  const numeric = Number(value);
  if (!Number.isFinite(numeric) || numeric < 1) {
    return fallback;
  }

  return Math.floor(numeric);
}

export function loadContextConfig(root) {
  const { configPath } = getIndexPaths(root);
  const fileConfig = readJson(configPath) ?? {};
  const embedding = {
    ...defaultEmbeddingConfig(),
    ...(fileConfig.embedding ?? {}),
  };

  if (process.env.PITACO_EMBEDDING_MODEL) {
    embedding.model = process.env.PITACO_EMBEDDING_MODEL;
  }

  return {
    search: {
      limit: 6,
      ...(fileConfig.search ?? {}),
    },
    embedding,
    indexing: {
      parseConcurrency: positiveInteger(
        process.env.PITACO_INDEX_PARSE_CONCURRENCY ?? fileConfig.indexing?.parseConcurrency,
        defaultParseConcurrency(),
      ),
    },
  };
}
