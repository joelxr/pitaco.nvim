import Parser from "tree-sitter";
import Go from "tree-sitter-go";
import JavaScript from "tree-sitter-javascript";
import Lua from "@tree-sitter-grammars/tree-sitter-lua";
import Python from "tree-sitter-python";
import TypeScript from "tree-sitter-typescript";

const parserByLanguage = {
  go: Go,
  javascript: JavaScript,
  lua: Lua,
  python: Python,
  typescript: TypeScript.typescript,
};

const chunkNodeTypes = {
  go: new Set(["function_declaration", "method_declaration", "type_declaration"]),
  javascript: new Set([
    "class_declaration",
    "function_declaration",
    "generator_function_declaration",
    "lexical_declaration",
    "method_definition",
  ]),
  lua: new Set(["function_declaration", "function_definition", "local_function"]),
  python: new Set(["class_definition", "function_definition"]),
  typescript: new Set([
    "class_declaration",
    "function_declaration",
    "generator_function_declaration",
    "lexical_declaration",
    "method_definition",
  ]),
};

const importNodeTypes = new Set(["import_statement", "import_declaration"]);
const exportNodeTypes = new Set(["export_statement", "export_clause", "export_specifier"]);

function traverse(node, visit) {
  visit(node);
  for (const child of node.namedChildren ?? []) {
    traverse(child, visit);
  }
}

function findNamedDescendant(node, types) {
  for (const child of node.namedChildren ?? []) {
    if (types.has(child.type)) {
      return child;
    }
    const nested = findNamedDescendant(child, types);
    if (nested) {
      return nested;
    }
  }
  return null;
}

function textFor(node, source) {
  return source.slice(node.startIndex, node.endIndex);
}

function extractName(node, source) {
  const byField = node.childForFieldName?.("name");
  if (byField) {
    return textFor(byField, source);
  }

  const identifier = findNamedDescendant(node, new Set(["identifier", "property_identifier", "type_identifier"]));
  if (identifier) {
    return textFor(identifier, source);
  }

  return `${node.type}@${node.startPosition.row + 1}`;
}

function classifyKind(node) {
  if (node.type.includes("class")) {
    return "class";
  }
  if (node.type.includes("method")) {
    return "method";
  }
  if (node.type.includes("type_declaration")) {
    return "type";
  }
  return "function";
}

function lexicalChunks(node, source) {
  const code = textFor(node, source);
  if (!/(const|let|var)\s+[A-Za-z0-9_$]+\s*=/.test(code)) {
    return [];
  }

  return [{
    kind: "function",
    symbol: extractName(node, source),
    code,
    startLine: node.startPosition.row + 1,
    endLine: node.endPosition.row + 1,
  }];
}

export function parseFile(language, source) {
  const parserLanguage = parserByLanguage[language];
  if (!parserLanguage) {
    return { imports: [], exports: [], chunks: [] };
  }

  const parser = new Parser();
  parser.setLanguage(parserLanguage);
  const tree = parser.parse(source);
  const root = tree.rootNode;
  const imports = [];
  const exports = [];
  const chunks = [];

  traverse(root, (node) => {
    if (importNodeTypes.has(node.type)) {
      imports.push(textFor(node, source));
      return;
    }

    if (exportNodeTypes.has(node.type) || node.type.startsWith("export_")) {
      exports.push(textFor(node, source));
      return;
    }

    const supportedTypes = chunkNodeTypes[language];
    if (!supportedTypes?.has(node.type)) {
      return;
    }

    if (node.type === "lexical_declaration") {
      for (const chunk of lexicalChunks(node, source)) {
        chunks.push(chunk);
      }
      return;
    }

    chunks.push({
      kind: classifyKind(node),
      symbol: extractName(node, source),
      code: textFor(node, source),
      startLine: node.startPosition.row + 1,
      endLine: node.endPosition.row + 1,
    });
  });

  return { imports, exports, chunks };
}
