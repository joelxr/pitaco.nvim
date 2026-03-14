import crypto from "node:crypto";

const MOCK_DIMENSIONS = 256;

function chunkArray(items, size) {
  const result = [];
  for (let index = 0; index < items.length; index += size) {
    result.push(items.slice(index, index + size));
  }
  return result;
}

function normalize(vector) {
  const magnitude = Math.sqrt(vector.reduce((sum, value) => sum + value * value, 0)) || 1;
  return vector.map((value) => value / magnitude);
}

function buildMockVector(text) {
  const vector = new Array(MOCK_DIMENSIONS).fill(0);
  const tokens = String(text).toLowerCase().match(/[a-z0-9_]+/g) ?? [];

  for (const token of tokens) {
    const digest = crypto.createHash("sha256").update(token).digest();
    const index = digest[0] % MOCK_DIMENSIONS;
    vector[index] += 1;
  }

  return normalize(vector);
}

async function fetchJson(url, options) {
  const response = await fetch(url, options);
  if (!response.ok) {
    const body = await response.text();
    throw new Error(`Embedding request failed (${response.status}): ${body}`);
  }

  return response.json();
}

async function embedWithOpenAI(config, texts) {
  const body = {
    input: texts,
    model: config.model || "text-embedding-3-small",
  };

  const json = await fetchJson("https://api.openai.com/v1/embeddings", {
    method: "POST",
    headers: {
      "content-type": "application/json",
      authorization: `Bearer ${process.env.OPENAI_API_KEY}`,
    },
    body: JSON.stringify(body),
  });

  return json.data.map((item) => item.embedding);
}

async function embedWithOpenRouter(config, texts) {
  const body = {
    input: texts,
    model: config.model || "text-embedding-3-small",
  };

  const json = await fetchJson("https://openrouter.ai/api/v1/embeddings", {
    method: "POST",
    headers: {
      "content-type": "application/json",
      authorization: `Bearer ${process.env.OPENROUTER_API_KEY}`,
    },
    body: JSON.stringify(body),
  });

  return json.data.map((item) => item.embedding);
}

async function embedWithOllama(config, texts) {
  const url = `${config.baseUrl || process.env.OLLAMA_URL || "http://localhost:11434"}/api/embed`;
  const json = await fetchJson(url, {
    method: "POST",
    headers: {
      "content-type": "application/json",
    },
    body: JSON.stringify({
      model: config.model || "nomic-embed-text",
      input: texts,
    }),
  });

  return json.embeddings;
}

export async function embedTexts(texts, embeddingConfig) {
  if (!texts.length) {
    return { vectors: [], engine: "none" };
  }

  const provider = embeddingConfig.provider || "mock";
  if (provider === "mock") {
    return {
      vectors: texts.map(buildMockVector),
      engine: "mock",
    };
  }

  try {
    const batches = chunkArray(texts, 64);
    const vectors = [];

    for (const batch of batches) {
      let embeddings;
      if (provider === "openai") {
        embeddings = await embedWithOpenAI(embeddingConfig, batch);
      } else if (provider === "openrouter") {
        embeddings = await embedWithOpenRouter(embeddingConfig, batch);
      } else if (provider === "ollama") {
        embeddings = await embedWithOllama(embeddingConfig, batch);
      } else {
        throw new Error(`Unsupported embedding provider: ${provider}`);
      }

      for (const vector of embeddings) {
        vectors.push(normalize(vector));
      }
    }

    return { vectors, engine: provider };
  } catch (error) {
    return {
      vectors: texts.map(buildMockVector),
      engine: "mock",
      warning: error.message,
    };
  }
}

export function cosineSimilarity(left, right) {
  if (!Array.isArray(left) || !Array.isArray(right) || left.length !== right.length) {
    return 0;
  }

  let score = 0;
  for (let index = 0; index < left.length; index += 1) {
    score += left[index] * right[index];
  }
  return score;
}

export function lexicalOverlap(queryText, candidateText) {
  const queryTokens = new Set(String(queryText).toLowerCase().match(/[a-z0-9_]+/g) ?? []);
  const candidateTokens = new Set(String(candidateText).toLowerCase().match(/[a-z0-9_]+/g) ?? []);
  if (queryTokens.size === 0 || candidateTokens.size === 0) {
    return 0;
  }

  let matches = 0;
  for (const token of queryTokens) {
    if (candidateTokens.has(token)) {
      matches += 1;
    }
  }

  return matches / Math.max(queryTokens.size, candidateTokens.size);
}
