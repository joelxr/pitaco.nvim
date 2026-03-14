# pitaco-indexer

Local repository indexing and semantic retrieval CLI for `pitaco.nvim`.

## Commands

```bash
pitaco-indexer index --root /path/to/repo --json
pitaco-indexer update --root /path/to/repo --json
pitaco-indexer search path/to/file.lua --root /path/to/repo --limit 6 --json
```

## Directory layout

```text
indexer/
  src/
    cli.js
    config.js
    embeddings.js
    indexer.js
    parser.js
    search.js
    store.js
```

## Index contents

The index is written to:

```text
.repo-pitaco/
  config.json
  index/
    manifest.json
    chunks.json
    summary.json
```

`manifest.json` tracks file hashes and mtimes for incremental updates.
`chunks.json` stores semantic chunks plus embeddings.
`summary.json` stores repository metadata used in prompt assembly.

## Embeddings

Recommended providers:

- `ollama` with `nomic-embed-text`
- `openai` with `text-embedding-3-small`
- `openrouter` with `text-embedding-3-small`

If no embedding provider is configured, the CLI falls back to a local hashed embedding so search still works offline.
