#!/usr/bin/env node

import path from "node:path";
import { findRepositoryRoot } from "./config.js";
import { indexRepository } from "./indexer.js";
import { getRepositoryOutline } from "./outline.js";
import { searchRepository } from "./search.js";

function parseArgs(argv) {
  const [command = "index", ...rest] = argv;
  const options = {
    command,
    file: null,
    filesJson: null,
    root: null,
    json: false,
    limit: 6,
  };

  for (let index = 0; index < rest.length; index += 1) {
    const token = rest[index];
    if (token === "--root") {
      options.root = rest[index + 1];
      index += 1;
    } else if (token === "--json") {
      options.json = true;
    } else if (token === "--files-json") {
      options.filesJson = rest[index + 1];
      index += 1;
    } else if (token === "--limit") {
      options.limit = Number(rest[index + 1] || "6");
      index += 1;
    } else if (!options.file) {
      options.file = token;
    }
  }

  return options;
}

function print(payload, asJson) {
  if (asJson) {
    process.stdout.write(`${JSON.stringify(payload)}\n`);
    return;
  }

  process.stdout.write(`${JSON.stringify(payload, null, 2)}\n`);
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const root = findRepositoryRoot(args.root || process.cwd());

  if (args.command === "index" || args.command === "update") {
    print(await indexRepository(root), args.json);
    return;
  }

  if (args.command === "search") {
    if (!args.file) {
      throw new Error("search requires a file path");
    }

    const filePath = path.isAbsolute(args.file) ? args.file : path.join(root, args.file);
    print(await searchRepository(root, filePath, args.limit), args.json);
    return;
  }

  if (args.command === "outline") {
    const requestedFiles = args.filesJson ? JSON.parse(args.filesJson) : [];
    print(getRepositoryOutline(root, requestedFiles), args.json);
    return;
  }

  throw new Error(`Unknown command: ${args.command}`);
}

main().catch((error) => {
  process.stderr.write(`${error.message}\n`);
  process.exit(1);
});
