#!/usr/bin/env node

import fs from "node:fs";
import path from "node:path";
import { findRepositoryRoot, getIndexPaths } from "./config.js";
import { indexRepository } from "./indexer.js";
import { getRepositoryOutline } from "./outline.js";
import { searchRepository } from "./search.js";

const ACTIVE_LOCK_EXIT_CODE = 73;

function parseArgs(argv) {
  const [command = "index", ...rest] = argv;
  const options = {
    command,
    file: null,
    filesJson: null,
    root: null,
    json: false,
    progress: false,
    limit: 6,
  };

  for (let index = 0; index < rest.length; index += 1) {
    const token = rest[index];
    if (token === "--root") {
      options.root = rest[index + 1];
      index += 1;
    } else if (token === "--json") {
      options.json = true;
    } else if (token === "--progress") {
      options.progress = true;
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

function writeJsonAtomically(filePath, value) {
  const tempPath = `${filePath}.${process.pid}.tmp`;
  fs.writeFileSync(tempPath, JSON.stringify(value));
  fs.renameSync(tempPath, filePath);
}

function writeStatus(statusPath, payload) {
  writeJsonAtomically(statusPath, payload);
}

function removeFile(filePath) {
  try {
    fs.unlinkSync(filePath);
  } catch (error) {
    if (error?.code !== "ENOENT") {
      throw error;
    }
  }
}

function readLock(filePath) {
  try {
    return JSON.parse(fs.readFileSync(filePath, "utf8"));
  } catch {
    return null;
  }
}

function isProcessAlive(pid) {
  if (!Number.isInteger(pid) || pid <= 0) {
    return false;
  }

  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    return error?.code === "EPERM";
  }
}

function createIndexLock(root) {
  const { indexDir, lockPath, statusPath } = getIndexPaths(root);
  fs.mkdirSync(indexDir, { recursive: true });
  const payload = {
    pid: process.pid,
    startedAt: new Date().toISOString(),
  };

  while (true) {
    try {
      const fd = fs.openSync(lockPath, "wx");
      fs.writeFileSync(fd, JSON.stringify(payload));
      fs.closeSync(fd);
      return {
        path: lockPath,
        statusPath,
        startedAt: payload.startedAt,
        release() {
          try {
            const current = readLock(lockPath);
            if (current?.pid === process.pid) {
              fs.unlinkSync(lockPath);
            }
          } catch {}
        },
      };
    } catch (error) {
      if (error?.code !== "EEXIST") {
        throw error;
      }

      const current = readLock(lockPath);
      if (current?.pid === process.pid) {
        return {
          path: lockPath,
          statusPath,
          startedAt: payload.startedAt,
          release() {
            try {
              fs.unlinkSync(lockPath);
            } catch {}
          },
        };
      }

      if (current && isProcessAlive(current.pid)) {
        const error = new Error(`index already running for this repository (pid ${current.pid})`);
        error.code = "PITACO_INDEX_LOCK_ACTIVE";
        error.pid = current.pid;
        error.statusPath = statusPath;
        throw error;
      }

      try {
        fs.unlinkSync(lockPath);
      } catch (unlinkError) {
        if (unlinkError?.code !== "ENOENT") {
          throw unlinkError;
        }
      }
      removeFile(statusPath);
    }
  }
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const root = findRepositoryRoot(args.root || process.cwd());

  if (args.command === "index" || args.command === "update") {
    const lock = createIndexLock(root);
    const statusPath = lock.statusPath;
    const startedAt = lock.startedAt;
    const cleanup = () => lock.release();
    process.on("exit", cleanup);
    process.on("SIGINT", () => {
      cleanup();
      process.exit(130);
    });
    process.on("SIGTERM", () => {
      cleanup();
      process.exit(143);
    });

    const emitStatus = (payload) => {
      const status = {
        pid: process.pid,
        root,
        startedAt,
        ...payload,
      };
      writeStatus(statusPath, status);
      return status;
    };

    writeStatus(statusPath, {
      pid: process.pid,
      root,
      startedAt,
      stage: "scan",
      message: "Scanning repository",
      current: 0,
      total: 1,
      result: "running",
    });

    const onProgress = args.progress
      ? (payload) => {
        const status = emitStatus({
          stage: payload.stage || "index",
          message: payload.message || "Indexing repository",
          current: payload.current ?? 0,
          total: payload.total ?? 1,
          result: "running",
        });
        process.stderr.write(`${JSON.stringify({ kind: "progress", ...status })}\n`);
      }
      : (payload) => {
        emitStatus({
          stage: payload.stage || "index",
          message: payload.message || "Indexing repository",
          current: payload.current ?? 0,
          total: payload.total ?? 1,
          result: "running",
        });
      };
    try {
      const result = await indexRepository(root, { onProgress });
      writeStatus(statusPath, {
        pid: process.pid,
        root,
        startedAt,
        finishedAt: new Date().toISOString(),
        stage: "completed",
        message: "Indexing complete",
        current: result.indexed_files ?? 0,
        total: result.indexed_files ?? 0,
        indexed_files: result.indexed_files ?? 0,
        total_chunks: result.total_chunks ?? 0,
        result: "completed",
      });
      print(result, args.json);
    } catch (error) {
      error.statusPath = statusPath;
      error.root = root;
      error.startedAt = startedAt;
      throw error;
    } finally {
      cleanup();
    }
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
  if (error?.code === "PITACO_INDEX_LOCK_ACTIVE") {
    process.stderr.write(`${JSON.stringify({
      kind: "lock",
      status: "active",
      pid: error.pid,
      status_path: error.statusPath,
    })}\n`);
    process.exit(ACTIVE_LOCK_EXIT_CODE);
  }

  if (error?.statusPath) {
    writeStatus(error.statusPath, {
      pid: process.pid,
      root: error.root,
      startedAt: error.startedAt,
      finishedAt: new Date().toISOString(),
      stage: "failed",
      message: "Indexing failed",
      current: error.current ?? 0,
      total: error.total ?? 1,
      result: "failed",
      error: error.message,
    });
  }

  process.stderr.write(`${error.message}\n`);
  process.exit(1);
});
