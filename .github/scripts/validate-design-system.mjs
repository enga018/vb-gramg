import fs from "node:fs";
import path from "node:path";
import postcss from "postcss";
import valueParser from "postcss-value-parser";
import { parse } from "parse5";

const cssFiles = ["design-tokens.css", "theme.css", "responsive.css"];
const htmlFiles = [
  "mis.html",
  "mis-import.html",
  "fto.html",
  "fto-import.html",
  "contribution.html",
  "demand.html",
  "periods.html",
];

const failures = [];
const declaredVariables = new Set();
const referencedVariables = [];

for (const file of cssFiles) {
  if (!fs.existsSync(file)) {
    failures.push(`Missing shared stylesheet: ${file}`);
    continue;
  }

  const source = fs.readFileSync(file, "utf8");
  let root;
  try {
    root = postcss.parse(source, { from: file });
  } catch (error) {
    failures.push(`CSS parse error in ${file}: ${error.message}`);
    continue;
  }

  root.walkDecls((decl) => {
    if (decl.prop.startsWith("--")) declaredVariables.add(decl.prop);
    valueParser(decl.value).walk((node) => {
      if (node.type === "function" && node.value.toLowerCase() === "var") {
        const first = node.nodes?.find((child) => child.type === "word");
        if (first?.value.startsWith("--")) {
          referencedVariables.push({ name: first.value, file, line: decl.source?.start?.line ?? "?" });
        }
      }
    });
  });
}

for (const reference of referencedVariables) {
  if (!declaredVariables.has(reference.name)) {
    failures.push(`Undefined CSS variable ${reference.name} in ${reference.file}:${reference.line}`);
  }
}

for (const file of htmlFiles) {
  if (!fs.existsSync(file)) {
    failures.push(`Missing application page: ${file}`);
    continue;
  }

  const source = fs.readFileSync(file, "utf8");
  const parseErrors = [];
  parse(source, { onParseError: (error) => parseErrors.push(error) });

  for (const error of parseErrors) {
    failures.push(`HTML parse error in ${file} at line ${error.startLine ?? "?"}: ${error.code}`);
  }

  for (const stylesheet of ["responsive.css", "theme.css"]) {
    const escaped = stylesheet.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
    const linkPattern = new RegExp(`<link\\b[^>]*href=["'][^"']*(?:^|/)${escaped}(?:\\?[^"']*)?["'][^>]*>`, "i");
    if (!linkPattern.test(source)) {
      failures.push(`Missing ${stylesheet} reference in ${file}`);
    }
    if (!fs.existsSync(path.join(path.dirname(file), stylesheet))) {
      failures.push(`Broken local stylesheet path: ${file} -> ${stylesheet}`);
    }
  }
}

if (failures.length) {
  console.error("Design-system validation failed:");
  for (const failure of failures) console.error(`- ${failure}`);
  process.exit(1);
}

console.log(`Design-system validation passed: ${cssFiles.length} CSS files, ${htmlFiles.length} HTML pages, ${declaredVariables.size} declared CSS variables, ${referencedVariables.length} variable references.`);
