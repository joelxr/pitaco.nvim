import fs from "node:fs";
import path from "node:path";
import { SUPPORTED_LANGUAGES } from "./config.js";
import { parseFile } from "./parser.js";
import { loadStore, buildFileOutline } from "./store.js";

function normalizeRange(range) {
  const startLine = Number(range?.startLine) || 0;
  const endLine = Number(range?.endLine) || startLine;

  return {
    startLine,
    endLine: Math.max(startLine, endLine),
  };
}

export function getRepositoryOutline(root, requestedFiles = []) {
  const store = loadStore(root);
  const files = [];

  for (const entry of requestedFiles) {
    if (!entry?.file) {
      continue;
    }

    const relativePath = path.isAbsolute(entry.file) ? path.relative(root, entry.file) : entry.file;
    const changedLines = Array.isArray(entry.changedLines) ? entry.changedLines.map(normalizeRange) : [];
    let outline = buildFileOutline(store, relativePath, changedLines);
    if (!outline) {
      const absolutePath = path.join(root, relativePath);
      const language = SUPPORTED_LANGUAGES[path.extname(relativePath)];
      if (language && fs.existsSync(absolutePath)) {
        const source = fs.readFileSync(absolutePath, "utf8");
        const parsed = parseFile(language, source);
        const symbols = parsed.chunks
          .filter((chunk) => {
            if (changedLines.length === 0) {
              return true;
            }

            return changedLines.some((range) =>
              chunk.startLine <= range.endLine && chunk.endLine >= range.startLine
            );
          })
          .map((chunk) => ({
            kind: chunk.kind,
            symbol: chunk.symbol,
            startLine: chunk.startLine,
            endLine: chunk.endLine,
          }));

        outline = {
          file: relativePath,
          language,
          imports: parsed.imports || [],
          exports: parsed.exports || [],
          symbols,
        };
      }
    }
    if (!outline) {
      continue;
    }

    files.push({
      ...outline,
      changedLines,
    });
  }

  return {
    root,
    files,
  };
}
