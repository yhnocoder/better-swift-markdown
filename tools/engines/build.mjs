// Builds the formula and diagram engines the Markdown component runs in JavaScriptCore (engines.ts: MathJax and pele)
// into Sources/MarkdownUI/Assets/engines.js, and THIRD-PARTY-NOTICES.txt beside it: every package the bundle takes code
// from, its version, its licence's name and text. `npm install && npm run build` here.
// ENGINES_MODULES: a node_modules folder to take esbuild and the engines' packages from instead of this folder's own
import { createRequire } from "node:module";
import { existsSync, readdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const modules = process.env.ENGINES_MODULES ?? join(here, "node_modules");
const require = createRequire(join(modules, "noop.js"));
const { build } = require("esbuild");
const out = join(here, "../../Sources/MarkdownUI/Assets");
const result = await build({
  entryPoints: [join(here, "engines.ts")],
  bundle: true,
  format: "iife",
  target: "safari18",
  outfile: join(out, "engines.js"),
  minify: true,
  legalComments: "none",
  metafile: true,
  nodePaths: [modules],
  logLevel: "warning",
});
// the packages the bundle took code from, each once, by the package.json above each input
const packages = new Map();
for (const input of Object.keys(result.metafile.inputs)) {
  const at = input.lastIndexOf("node_modules/");
  if (at < 0) continue;
  const rest = input.slice(at + "node_modules/".length).split("/");
  const name = rest[0].startsWith("@") ? `${rest[0]}/${rest[1]}` : rest[0];
  const dir = join(modules, name);
  if (packages.has(name) || !existsSync(join(dir, "package.json"))) continue;
  const pkg = JSON.parse(readFileSync(join(dir, "package.json"), "utf8"));
  const file = readdirSync(dir).find((f) => /^(licen[cs]e|copying)(\.(md|txt))?$/i.test(f));
  if (!file) throw new Error(`${name} has no licence file`);
  packages.set(name, { version: pkg.version, license: pkg.license, text: readFileSync(join(dir, file), "utf8").trim() });
}
const rule = "=".repeat(80);
const notices = [...packages.keys()].sort().map((name) => {
  const p = packages.get(name);
  return `${rule}\n${name} ${p.version} (${p.license})\n${rule}\n\n${p.text}\n`;
});
writeFileSync(
  join(out, "THIRD-PARTY-NOTICES.txt"),
  `engines.js bundles code from these packages, under their own licences.\n\n${notices.join("\n")}`,
);
console.log(`built ${join(out, "engines.js")} from ${[...packages.keys()].sort().join(", ")}`);
