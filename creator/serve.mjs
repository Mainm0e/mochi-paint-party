// Local preview server for the web pages:
//   node creator/serve.mjs              -> creator/ at http://localhost:5173
//   node creator/serve.mjs game 5174    -> game/    at http://localhost:5174
// index.html is written as an Artifact page body, so it is wrapped in a minimal HTML skeleton here.
import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { extname, join, normalize, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = fileURLToPath(new URL(".", import.meta.url));
const ROOT = process.argv[2] ? resolve(HERE, "..", process.argv[2]) + sep : HERE;
const PORT = Number(process.argv[3]) || 5173;
const TYPES = { ".html": "text/html", ".js": "text/javascript", ".json": "application/json", ".png": "image/png",
  ".glb": "model/gltf-binary" };

createServer(async (req, res) => {
  const path = decodeURIComponent(new URL(req.url, "http://x").pathname);
  const file = normalize(join(ROOT, path === "/" ? "index.html" : path));
  if (!file.startsWith(ROOT)) return res.writeHead(403).end();
  try {
    let body = await readFile(file);
    if (file.endsWith("index.html")) {
      body = '<!doctype html><html lang="en"><head><meta charset="utf-8">' +
        '<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">' +
        "<style>body{margin:0}[hidden]{display:none!important}</style></head><body>" + body + "</body></html>";
    }
    res.writeHead(200, { "content-type": TYPES[extname(file)] || "application/octet-stream" }).end(body);
  } catch {
    res.writeHead(404).end("Not found");
  }
}).listen(PORT, () => console.log(`Mochi Maker at http://localhost:${PORT}`));
