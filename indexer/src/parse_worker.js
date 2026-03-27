import { parentPort } from "node:worker_threads";
import { parseFile } from "./parser.js";

parentPort.on("message", ({ language, source }) => {
  try {
    parentPort.postMessage({ result: parseFile(language, source) });
  } catch (error) {
    parentPort.postMessage({
      error: error instanceof Error ? error.message : String(error),
    });
  }
});
