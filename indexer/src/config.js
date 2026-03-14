import fs from "node:fs";
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
    manifestPath: path.join(indexDir, "manifest.json"),
    chunksPath: path.join(indexDir, "chunks.json"),
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
  };
}
