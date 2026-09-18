#!/usr/bin/env python3
"""
Builds the docs site from the Markdown that already lives in this repository.

One source of truth: README.md and docs/*.md are the documentation, and this
script only skins them. Nothing here is hand-authored HTML that could drift
away from the docs people read on GitHub.

Design tokens are the ones from cnsunzone.com, verbatim.
"""
import os, re, shutil, html

try:
    import markdown
except ImportError:
    raise SystemExit("pip install markdown")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT  = os.path.join(ROOT, "_site")

CSS = """
:root{
  --bg:#07090f; --bg-2:#0b0e17; --card:#10141f; --card-2:#141927; --line:#1d2436;
  --cyan:#00d9d9; --cyan-dim:#0e8f8f; --cyan-glow:rgba(0,217,217,.35);
  --amber:#ffb833; --green:#00c850; --red:#ff5470;
  --text:#e8edf4; --muted:#8b96a8; --faint:#5a6478;
  --mono:"SF Mono",ui-monospace,SFMono-Regular,Menlo,Monaco,"Cascadia Mono","Roboto Mono",Consolas,monospace;
}
*{box-sizing:border-box}
html{scroll-behavior:smooth}
body{
  margin:0; background:var(--bg); color:var(--text);
  font-family:var(--mono); font-size:15px; line-height:1.7;
  -webkit-font-smoothing:antialiased;
}
body::before{
  content:""; position:fixed; inset:0; pointer-events:none; z-index:0;
  background:
    radial-gradient(60% 50% at 78% 0%, rgba(0,217,217,.10), transparent 70%),
    linear-gradient(transparent 39px,rgba(29,36,54,.35) 39px),
    linear-gradient(90deg,transparent 39px,rgba(29,36,54,.35) 39px);
  background-size:auto, 40px 40px, 40px 40px;
}
.wrap{position:relative; z-index:1; max-width:1180px; margin:0 auto; padding:0 24px}

header.top{
  position:sticky; top:0; z-index:10; backdrop-filter:blur(10px);
  background:rgba(7,9,15,.82); border-bottom:1px solid var(--line);
}
header.top .wrap{display:flex; align-items:center; gap:18px; height:60px; flex-wrap:wrap}
.brand{display:flex; align-items:center; gap:10px; font-weight:800; letter-spacing:-.5px; text-decoration:none; color:var(--text)}
.mark{width:26px;height:26px;border-radius:8px;border:1px solid var(--cyan-dim);
  display:grid;place-items:center;color:var(--cyan);font-size:13px;background:var(--card)}
.brand b{color:var(--cyan); font-weight:800}
nav.top-nav{margin-left:auto; display:flex; gap:6px; flex-wrap:wrap}
nav.top-nav a{
  color:var(--muted); text-decoration:none; font-size:13px; letter-spacing:.6px;
  padding:7px 14px; border-radius:100px; border:1px solid transparent;
}
nav.top-nav a:hover{color:var(--cyan); border-color:var(--line); background:var(--card)}
nav.top-nav a.on{color:var(--cyan); border-color:var(--cyan-dim)}

.layout{display:grid; grid-template-columns:250px 1fr; gap:38px; padding:38px 0 90px}
@media (max-width:900px){ .layout{grid-template-columns:1fr; gap:22px} aside{position:static !important} }

aside{position:sticky; top:84px; align-self:start}
aside .label{font-size:11px; letter-spacing:1.6px; color:var(--faint); margin:0 0 12px 14px}
aside a{
  display:block; color:var(--muted); text-decoration:none; font-size:13.5px;
  padding:9px 14px; border-radius:10px; border:1px solid transparent;
}
aside a:hover{color:var(--text); background:var(--card); border-color:var(--line)}
aside a.on{color:var(--cyan); background:var(--card); border-color:var(--cyan-dim)}

article{min-width:0}
article h1{font-size:40px; font-weight:800; letter-spacing:-1px; line-height:1.15; margin:.2em 0 .5em}
article h2{font-size:24px; font-weight:800; letter-spacing:-.5px; margin:2.2em 0 .7em;
  padding-top:1.1em; border-top:1px solid var(--line)}
article h3{font-size:17px; font-weight:700; color:var(--cyan); margin:1.8em 0 .5em}
article p,article li{color:#cdd6e2}
article strong{color:var(--text)}
article a{color:var(--cyan); text-decoration:none; border-bottom:1px solid var(--cyan-dim)}
article a:hover{background:rgba(0,217,217,.08)}
article img{max-width:100%; border-radius:14px; border:1px solid var(--line)}
/* Badges sit on one row. A blanket display:block on images stacks them into a
   vertical column, which looks broken -- they are inline content, not figures. */
article p img[src*="shields.io"]{border:0; border-radius:4px; margin:0 5px 6px 0; vertical-align:middle}
article p img{vertical-align:middle}
article hr{border:0; border-top:1px solid var(--line); margin:2.4em 0}
article blockquote{margin:1.4em 0; padding:.2em 1.2em; border-left:2px solid var(--cyan-dim);
  color:var(--muted); background:var(--card); border-radius:0 12px 12px 0}

code{font-family:var(--mono); font-size:.9em; background:var(--card-2);
  border:1px solid var(--line); border-radius:6px; padding:.12em .4em; color:var(--cyan)}
pre{background:var(--card); border:1px solid var(--line); border-radius:14px;
  padding:18px 20px; overflow:auto; line-height:1.55}
pre code{background:none; border:0; padding:0; color:#cdd6e2; font-size:13px}

table{border-collapse:collapse; width:100%; margin:1.4em 0; font-size:13.5px; display:block; overflow-x:auto}
th,td{border:1px solid var(--line); padding:10px 13px; text-align:left; vertical-align:top}
th{background:var(--card-2); color:var(--muted); font-weight:700;
  letter-spacing:.8px; font-size:11.5px; text-transform:uppercase; white-space:nowrap}
tr:nth-child(even) td{background:rgba(16,20,31,.5)}

footer{border-top:1px solid var(--line); padding:26px 0 60px; color:var(--faint); font-size:12.5px}
footer a{color:var(--muted); text-decoration:none}
footer a:hover{color:var(--cyan)}
"""

NAV = [("index.html", "Overview"),
       ("00-INSTALL.html", "Install"),
       ("01-ARCHITECTURE.html", "Architecture"),
       ("02-GPU-KERNEL.html", "GPU kernel"),
       ("03-ADDRESS-MATH.html", "Address maths"),
       ("04-VERIFICATION.html", "Verification"),
       ("05-SECURITY.html", "Security"),
       ("06-BUILD-AND-RUN.html", "Running"),
       ("CONTRIBUTING.html", "Contributing")]

SHELL = """<!DOCTYPE html>
<html lang="en"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>{title}</title>
<meta name="description" content="{desc}">
<meta name="color-scheme" content="dark">
<style>{css}</style>
</head><body>
<header class="top"><div class="wrap">
  <a class="brand" href="index.html"><span class="mark">◈</span>VANITY<b>METAL</b></a>
  <nav class="top-nav">{topnav}</nav>
</div></header>
<div class="wrap"><div class="layout">
  <aside>
    <p class="label">DOCUMENTATION</p>
    {sidenav}
  </aside>
  <article>{body}</article>
</div></div>
<footer><div class="wrap">
  MIT licensed · <a href="https://github.com/Solitechworld/VanityMetal">GitHub</a>
  · <a href="https://cnsunzone.com">cnsunzone.com</a>
  <br>Built from the Markdown in the repository — these pages and the docs on
  GitHub are the same source.
</div></footer>
</body></html>
"""

def convert(md_text):
    return markdown.markdown(md_text, extensions=["tables", "fenced_code", "toc", "sane_lists"])

def rewrite_links(h):
    # docs/xx-NAME.md and xx-NAME.md -> xx-NAME.html; README.md -> index.html
    h = re.sub(r'href="(?:docs/)?([0-9]{2}-[A-Z-]+)\.md"', r'href="\1.html"', h)
    h = re.sub(r'href="CONTRIBUTING\.md"', 'href="CONTRIBUTING.html"', h)
    h = re.sub(r'href="README\.md"', 'href="index.html"', h)
    return h

def first_heading(md_text, fallback):
    m = re.search(r'^#\s+(.+)$', md_text, re.M)
    return m.group(1).strip() if m else fallback

def build():
    if os.path.isdir(OUT): shutil.rmtree(OUT)
    os.makedirs(OUT)

    pages = [("README.md", "index.html")]
    for f in sorted(os.listdir(os.path.join(ROOT, "docs"))):
        if f.endswith(".md"):
            pages.append((os.path.join("docs", f), f[:-3] + ".html"))
    if os.path.exists(os.path.join(ROOT, "CONTRIBUTING.md")):
        pages.append(("CONTRIBUTING.md", "CONTRIBUTING.html"))

    for src, dst in pages:
        md_text = open(os.path.join(ROOT, src), encoding="utf-8").read()
        title = first_heading(md_text, "VanityMetal")
        body = rewrite_links(convert(md_text))
        topnav = "".join(
            f'<a class="{"on" if h==dst else ""}" href="{h}">{html.escape(l)}</a>'
            for h, l in NAV[:5])
        sidenav = "".join(
            f'<a class="{"on" if h==dst else ""}" href="{h}">{html.escape(l)}</a>'
            for h, l in NAV)
        page = SHELL.format(
            title=html.escape(title if dst == "index.html" else title + " — VanityMetal"),
            desc="GPU vanity address engine for macOS — secp256k1 in Swift and Metal.",
            css=CSS, topnav=topnav, sidenav=sidenav, body=body)
        open(os.path.join(OUT, dst), "w", encoding="utf-8").write(page)
        print("  ", dst)

    # images referenced by the docs
    res = os.path.join(ROOT, "Resources")
    if os.path.isdir(res):
        os.makedirs(os.path.join(OUT, "Resources"), exist_ok=True)
        for f in os.listdir(res):
            if f.lower().endswith((".png", ".svg", ".jpg")):
                shutil.copy2(os.path.join(res, f), os.path.join(OUT, "Resources", f))
    open(os.path.join(OUT, ".nojekyll"), "w").close()
    print("built ->", OUT)

if __name__ == "__main__":
    build()
