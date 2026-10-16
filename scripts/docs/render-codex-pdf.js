#!/usr/bin/env node
// Renders a canonical Markdown document to a print-ready PDF codex.
//
// Usage: node scripts/docs/render-codex-pdf.js <source.md> <out.pdf>
//
// Needs: Node 18+, Chrome or Edge (headless print), and network for the first
// `npx` fetch of the pinned `marked` package (cached afterwards).
// The Markdown is the source of truth. The PDF is a rendered snapshot, so
// regenerate it from the Markdown; never edit the PDF or the intermediate HTML.
// Relative image links resolve against the source document's folder.
"use strict";
const fs = require("fs");
const os = require("os");
const path = require("path");
const { execFileSync } = require("child_process");
const { pathToFileURL } = require("url");

const MARKED = "marked@18.1.1";
const BROWSERS = [
  "C:/Program Files/Google/Chrome/Application/chrome.exe",
  "C:/Program Files (x86)/Google/Chrome/Application/chrome.exe",
  "C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe",
  "C:/Program Files/Microsoft/Edge/Application/msedge.exe",
];

const CSS = `
@page { size: Letter; margin: 0.8in 0.75in; @bottom-center { content: counter(page); font: 9pt Georgia, serif; color: #666; } }
body { font: 11pt/1.45 Georgia, "Times New Roman", serif; color: #1a1a1a; }
h1 { font-size: 24pt; margin: 0 0 0.4em; border-bottom: 2px solid #444; padding-bottom: 0.2em; }
h2 { font-size: 16pt; margin: 1.4em 0 0.4em; border-bottom: 1px solid #aaa; break-after: avoid; }
h3 { font-size: 13pt; margin: 1.1em 0 0.3em; break-after: avoid; }
h4, h5, h6 { font-size: 11pt; margin: 1em 0 0.3em; break-after: avoid; }
p, li { orphans: 3; widows: 3; }
code { font: 9.5pt Consolas, monospace; background: #f1f1f1; padding: 0 2px; }
pre { background: #f1f1f1; padding: 8px; white-space: pre-wrap; break-inside: avoid; }
table { border-collapse: collapse; width: 100%; margin: 0.8em 0; font-size: 9pt; }
th, td { border: 1px solid #777; padding: 4px 6px; vertical-align: top; }
td code { overflow-wrap: anywhere; }
th { background: #e8e8e8; }
tr { break-inside: avoid; }
img { max-width: 100%; }
blockquote { margin: 0.8em 0; padding-left: 1em; border-left: 3px solid #aaa; color: #444; }
`;

const [src, out] = process.argv.slice(2);
if (!src || !out) {
  console.error("Usage: node scripts/docs/render-codex-pdf.js <source.md> <out.pdf>");
  process.exit(2);
}
const srcPath = path.resolve(src);
const outPath = path.resolve(out);
const browser = BROWSERS.find((p) => fs.existsSync(p));
if (!browser) {
  console.error("Chrome or Edge not found.");
  process.exit(1);
}

const run = (cmd, args) => execFileSync(cmd, args, { encoding: "utf8", maxBuffer: 256 * 1024 * 1024 });

// npm's npx ships beside node; running its script avoids shell quoting of paths.
const npx = path.join(path.dirname(process.execPath), "node_modules", "npm", "bin", "npx-cli.js");
const body = run(process.execPath, [npx, "--yes", MARKED, "--gfm", "-i", srcPath]);
const title = (body.match(/<h1[^>]*>(.*?)<\/h1>/s) || [, path.basename(srcPath)])[1].replace(/<[^>]+>/g, "");
const base = pathToFileURL(path.dirname(srcPath) + path.sep).href;
const html = `<!doctype html><html lang="en"><head><meta charset="utf-8"><base href="${base}"><title>${title}</title><style>${CSS}</style></head><body>${body}</body></html>`;

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "codex-pdf-"));
const htmlPath = path.join(tmp, "codex.html");
fs.writeFileSync(htmlPath, html);
fs.mkdirSync(path.dirname(outPath), { recursive: true });
try {
  run(browser, [
    "--headless=new", "--disable-gpu", "--no-pdf-header-footer",
    `--user-data-dir=${path.join(tmp, "profile")}`,
    `--print-to-pdf=${outPath}`, pathToFileURL(htmlPath).href,
  ]);
  console.log(`rendered ${outPath} (${fs.statSync(outPath).size} bytes)`);
} finally {
  fs.rmSync(tmp, { recursive: true, force: true });
}
