// Mochi Sketchbook level editor server (local only).
//   node editor/serve.mjs            -> http://localhost:5175
// Serves the editor page, saves levels as godot/levels/<name>.json and can launch Godot straight into one.
// Set GODOT=<path to the Godot console exe> if it isn't at the default spot below.
import { createServer } from "node:http";
import { readFile, writeFile, readdir, mkdir } from "node:fs/promises";
import { spawn } from "node:child_process";
import { extname, join, normalize, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = fileURLToPath(new URL(".", import.meta.url));
const REPO = resolve(HERE, "..");
const LEVELS = join(REPO, "godot", "levels");
const GODOT = process.env.GODOT || "C:/Users/mainm/Godot/Godot_v4.7.2-stable_win64_console.exe";
const PORT = Number(process.argv[2]) || 5175;
const TYPES = { ".html": "text/html; charset=utf-8", ".js": "text/javascript", ".json": "application/json", ".png": "image/png" };
const NAME = /^[a-z0-9_-]{1,40}$/;

async function body(req) {
  const chunks = [];
  for await (const c of req) chunks.push(c);
  return Buffer.concat(chunks).toString("utf8");
}

createServer(async (req, res) => {
  const url = new URL(req.url, "http://x");
  const path = decodeURIComponent(url.pathname);
  const json = (code, data) => res.writeHead(code, { "content-type": "application/json" }).end(JSON.stringify(data));
  try {
    if (path === "/api/levels" && req.method === "GET") {
      await mkdir(LEVELS, { recursive: true });
      const names = (await readdir(LEVELS)).filter((f) => f.endsWith(".json")).map((f) => f.slice(0, -5));
      return json(200, names.sort());
    }
    const m = path.match(/^\/api\/(levels|play)\/([^/]+)$/);
    if (m) {
      const name = m[2];
      if (!NAME.test(name)) return json(400, { error: "Level names use a-z, 0-9, - and _ only." });
      const file = join(LEVELS, name + ".json");
      if (m[1] === "levels" && req.method === "GET") return json(200, JSON.parse(await readFile(file, "utf8")));
      if (m[1] === "levels" && req.method === "PUT") {
        const data = JSON.parse(await body(req));  // validate it parses before writing
        await mkdir(LEVELS, { recursive: true });
        // one line per number list (the height grid), so the file stays readable and diffs stay small
        await writeFile(file, JSON.stringify(data, null, 1).replace(/\[\s*(-?\d+(?:,\s*-?\d+)*)\s*\]/g, (m, nums) => "[" + nums.replace(/\s+/g, "") + "]"));
        return json(200, { saved: name });
      }
      if (m[1] === "play" && req.method === "POST") {
        const child = spawn(GODOT, ["--path", join(REPO, "godot"), "--", `--level=${name}`], { detached: true, stdio: "ignore" });
        child.on("error", (e) => console.error("Could not start Godot:", e.message));
        child.unref();
        return json(200, { playing: name });
      }
    }
    const file = normalize(join(HERE, path === "/" ? "index.html" : path));
    if (!file.startsWith(HERE)) return res.writeHead(403).end();
    const data = await readFile(file);  // read first: a missing file must still get a clean 404
    res.writeHead(200, { "content-type": TYPES[extname(file)] || "application/octet-stream" }).end(data);
  } catch (e) {
    if (!res.headersSent) json(e.code === "ENOENT" ? 404 : 500, { error: e.message });
  }
}).listen(PORT, "127.0.0.1", () => console.log(`Level editor at http://localhost:${PORT}`));
