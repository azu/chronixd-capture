import { createServer } from "node:http";
import { readdir, readFile } from "node:fs/promises";
import { join, extname } from "node:path";

const PORT = Number(process.env.PORT ?? 6419);
const RESEARCH_DIR = process.argv[2] ?? "./tmp/docs/research";

const html = (title: string, body: string) => `<!DOCTYPE html>
<html lang="ja">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${title}</title>
<style>
  body { max-width: 720px; margin: 2rem auto; padding: 0 1rem; font-family: -apple-system, sans-serif; line-height: 1.6; color: #333; }
  a { color: #0969da; }
  h1 { border-bottom: 1px solid #ddd; padding-bottom: 0.3em; }
  h3 { margin-top: 1.5em; }
  pre { background: #f6f8fa; padding: 1em; overflow-x: auto; border-radius: 6px; }
  code { background: #f0f0f0; padding: 0.2em 0.4em; border-radius: 3px; font-size: 0.9em; }
  pre code { background: none; padding: 0; }
  .file-list { list-style: none; padding: 0; }
  .file-list li { padding: 0.5em 0; border-bottom: 1px solid #eee; }
  .file-list .time { color: #888; font-size: 0.85em; margin-right: 0.5em; }
  nav { margin-bottom: 1em; }
</style>
</head>
<body>${body}</body>
</html>`;

// minimal markdown to HTML (headings, links, bold, code blocks, paragraphs)
function md2html(md: string): string {
  const lines = md.split("\n");
  const out: string[] = [];
  let inCode = false;

  for (const line of lines) {
    if (line.startsWith("```")) {
      out.push(inCode ? "</code></pre>" : "<pre><code>");
      inCode = !inCode;
      continue;
    }
    if (inCode) { out.push(escHtml(line) + "\n"); continue; }

    let l = line;
    // headings
    const hm = l.match(/^(#{1,6})\s+(.+)/);
    if (hm) { const n = hm[1].length; out.push(`<h${n}>${inline(hm[2])}</h${n}>`); continue; }
    // hr
    if (/^---+$/.test(l)) { out.push("<hr>"); continue; }
    // list
    if (/^[-*]\s/.test(l)) { out.push(`<li>${inline(l.slice(2))}</li>`); continue; }
    // empty line
    if (l.trim() === "") { out.push("<br>"); continue; }
    // paragraph
    out.push(`<p>${inline(l)}</p>`);
  }
  return out.join("\n");
}

function escHtml(s: string): string {
  return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}

function inline(s: string): string {
  return escHtml(s)
    .replace(/\[([^\]]+)\]\(([^)]+)\)/g, '<a href="$2" target="_blank">$1</a>')
    .replace(/\*\*(.+?)\*\*/g, "<strong>$1</strong>")
    .replace(/`(.+?)`/g, "<code>$1</code>");
}

const server = createServer(async (req, res) => {
  const url = new URL(req.url ?? "/", `http://localhost:${PORT}`);
  const path = decodeURIComponent(url.pathname);

  try {
    if (path === "/" || path === "") {
      // index: list files sorted by mtime desc
      const files = await readdir(RESEARCH_DIR);
      const mdFiles = files.filter(f => extname(f) === ".md").sort().reverse();
      const items = mdFiles.map(f => {
        const m = f.match(/^(\d{8})-(\d{6})_/);
        const time = m ? `${m[1].slice(4, 6)}/${m[1].slice(6)} ${m[2].slice(0, 2)}:${m[2].slice(2, 4)}` : "";
        return `<li><span class="time">${time}</span><a href="/${encodeURIComponent(f)}">${f}</a></li>`;
      });
      res.writeHead(200, { "Content-Type": "text/html; charset=utf-8" });
      res.end(html("Research", `<h1>Research</h1><ul class="file-list">${items.join("")}</ul>`));
    } else {
      // serve file
      const filename = path.slice(1);
      const filepath = join(RESEARCH_DIR, filename);
      const content = await readFile(filepath, "utf-8");
      const rendered = md2html(content);
      res.writeHead(200, { "Content-Type": "text/html; charset=utf-8" });
      res.end(html(filename, `<nav><a href="/">← 一覧</a></nav>${rendered}`));
    }
  } catch {
    res.writeHead(404, { "Content-Type": "text/plain" });
    res.end("Not Found");
  }
});

server.listen(PORT, () => {
  console.log(`Research server: http://localhost:${PORT}`);
});
