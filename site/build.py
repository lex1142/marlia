#!/usr/bin/env python3
"""Generates the static site in docs/ from site/template.html.

    python3 site/build.py           write docs/index.html, docs/<lang>/index.html, sitemap, robots, 404
    python3 site/build.py --check   exit 1 if anything in docs/ is out of date (used by CI)

Why a generator: search engines and link previews read the HTML as served. The page used to be
filled in by JavaScript, with one URL for every language, so only an English skeleton was
indexable. Each language now gets its own URL with all text already in the HTML, its own
<title>/description, hreflang links to the others and JSON-LD. The page script still runs on top
(interactive demo, live release info), so the text it renders must match what is prerendered
here: keep glue()/size formatting below in step with the template's script.

Only the Python standard library is used.
"""
import html
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TEMPLATE = os.path.join(ROOT, "site", "template.html")
DOCS = os.path.join(ROOT, "docs")
SITE = "https://marlia.app/"
REPO = "https://github.com/lex1142/marlia"
LANGS = ["en", "ru", "zh", "es", "ja"]                     # first one lives at the site root
NAMES = {"en": "English", "ru": "Русский", "zh": "简体中文", "es": "Español", "ja": "日本語"}
TAGS = {"en": "en", "ru": "ru", "zh": "zh-Hans", "es": "es", "ja": "ja"}      # html lang / hreflang
LOCALES = {"en": "en_US", "ru": "ru_RU", "zh": "zh_CN", "es": "es_ES", "ja": "ja_JP"}
NB = "\u00a0"


def url_for(lang):
    return SITE if lang == "en" else f"{SITE}{lang}/"


# ---------- text helpers: mirror glue(), sizeText() and fill() in the template script ----------

GLUE = [
    (r"(\d) (MB|МБ|KB|КБ|GB|ГБ)", r"\1" + NB + r"\2"),
    (r"macOS (\d)", "macOS" + NB + r"\1"),
    (r"Apple (Silicon|シリコン|芯片)", "Apple" + NB + r"\1"),
    (r"(\d) (steps|шагов|pasos|Schritte|ステップ|步)", r"\1" + NB + r"\2"),
    (r"Total Commander", "Total" + NB + "Commander"),
    (r" (·|—)", NB + r"\1"),
    (r" (→)", NB + r"\1"),
]


def glue(s):
    for pattern, repl in GLUE:
        s = re.sub(pattern, repl, s)
    return s


def size_text(lang, nbytes):
    v = round(nbytes / 1e6, 1)
    num = str(int(v)) if v == int(v) else f"{v:.1f}"
    if lang in ("ru", "es"):
        num = num.replace(".", ",")
    return num + " " + ("МБ" if lang == "ru" else "MB")


def release(template):
    """The RELEASE fallback constant from the template script."""
    m = re.search(r'const RELEASE = \{\s*version: "([^"]+)",\s*bytes: (\d+),\s*url: "([^"]+)"', template)
    assert m, "RELEASE constant not found in template"
    return {"version": m.group(1), "bytes": int(m.group(2)), "url": m.group(3)}


# ---------- page generation ----------

ELEMENT = re.compile(
    r'<(?P<tag>[a-zA-Z][a-zA-Z0-9]*)(?P<attrs>[^>]*?\sdata-(?P<kind>[th])="(?P<key>[^"]+)"[^>]*)>'
    r"(?P<inner>.*?)</(?P=tag)>",
    re.S,
)


def render_page(template, strings, lang, rel):
    tr = lambda key: strings.get(key, "")

    def fill(s):
        return s.replace("{ver}", rel["version"]).replace("{size}", size_text(lang, rel["bytes"]))

    # text and markup of every translatable element
    expected = len(re.findall(r'\sdata-[th]="', template.split('<script type="application/json"')[0]))
    count = 0

    def element(m):
        nonlocal count
        count += 1
        text = glue(fill(tr(m.group("key"))))
        if m.group("kind") == "t":
            inner = html.escape(text, quote=False)
        else:
            inner = (text
                     .replace("{DMG}", f'<a href="{rel["url"]}" target="_blank" rel="noopener">Marlia-{rel["version"]}.dmg</a>')
                     .replace("{REL}", f'<a href="{REPO}/releases" target="_blank" rel="noopener">Releases</a>'))
        return f'<{m.group("tag")}{m.group("attrs")}>{inner}</{m.group("tag")}>'

    body_end = template.index('<script type="application/json"')
    page = ELEMENT.sub(element, template[:body_end]) + template[body_end:]
    assert count == expected, f"{lang}: prerendered {count} of {expected} translatable elements"

    # attribute translations
    page = re.sub(r'(\sdata-alt="([^"]+)"[^>]*?\salt=")[^"]*(")',
                  lambda m: m.group(1) + html.escape(tr(m.group(2))) + m.group(3), page)
    page = re.sub(r'(\sdata-aria="([^"]+)"[^>]*?\saria-label=")[^"]*(")',
                  lambda m: m.group(1) + html.escape(tr(m.group(2))) + m.group(3), page)
    page = re.sub(r'(<a class="btn btn-primary" data-dl href=")[^"]*(")', lambda m: m.group(1) + rel["url"] + m.group(2), page)

    # <html>, language menu, footer language links
    page = page.replace('<html lang="en" data-lang="en">', f'<html lang="{TAGS[lang]}" data-lang="{lang}">', 1)
    page = page.replace(f'<option value="{lang}">', f'<option value="{lang}" selected>', 1)
    up = "" if lang == "en" else "../"
    links = []
    for code in LANGS:
        href = (up + ("" if code == "en" else code + "/")) or "./"
        current = ' aria-current="page"' if code == lang else ""
        links.append(f'<a href="{href}" hreflang="{TAGS[code]}" lang="{TAGS[code]}" data-lang-link="{code}"{current}>{NAMES[code]}</a>')
    page = re.sub(r"<!-- langs:start -->.*?<!-- langs:end -->", lambda _: "".join(links), page, flags=re.S)

    # head: title, description, canonical, hreflang, Open Graph, JSON-LD
    title, desc = tr("meta.title"), tr("meta.desc")
    esc = lambda s: html.escape(s, quote=True)
    alternates = "".join(f'<link rel="alternate" hreflang="{TAGS[c]}" href="{url_for(c)}">\n' for c in LANGS)
    ld = {
        "@context": "https://schema.org",
        "@type": "SoftwareApplication",
        "name": "Marlia",
        "url": url_for(lang),
        "description": desc,
        "inLanguage": TAGS[lang],
        "applicationCategory": "UtilitiesApplication",
        "applicationSubCategory": "File manager",
        "operatingSystem": "macOS 13.5 or later",
        "processorRequirements": "Apple Silicon (arm64)",
        "softwareVersion": rel["version"],
        "downloadUrl": rel["url"],
        "fileSize": size_text("en", rel["bytes"]),
        "isAccessibleForFree": True,
        "offers": {"@type": "Offer", "price": "0", "priceCurrency": "USD"},
        "license": "https://www.gnu.org/licenses/gpl-3.0.html",
        "image": SITE + "media/og.jpg",
        "screenshot": SITE + "media/hero-light.webp",
        "sameAs": [REPO],
    }
    head = (
        "<!-- seo:start (generated per language by site/build.py) -->\n"
        f"<title>{esc(title)}</title>\n"
        f'<meta name="description" content="{esc(desc)}">\n'
        f'<link rel="canonical" href="{url_for(lang)}">\n'
        f"{alternates}"
        f'<link rel="alternate" hreflang="x-default" href="{SITE}">\n'
        '<meta property="og:type" content="website">\n'
        '<meta property="og:site_name" content="Marlia">\n'
        f'<meta property="og:locale" content="{LOCALES[lang]}">\n'
        f'<meta property="og:title" content="{esc(title)}">\n'
        f'<meta property="og:description" content="{esc(desc)}">\n'
        f'<meta property="og:url" content="{url_for(lang)}">\n'
        f'<meta property="og:image" content="{SITE}media/og.jpg">\n'
        '<meta property="og:image:width" content="1200">\n'
        '<meta property="og:image:height" content="717">\n'
        '<meta name="twitter:card" content="summary_large_image">\n'
        f'<meta name="twitter:title" content="{esc(title)}">\n'
        f'<meta name="twitter:description" content="{esc(desc)}">\n'
        '<script type="application/ld+json">' + json.dumps(ld, ensure_ascii=False).replace("</", "<\\/") + "</script>\n"
    )
    if lang == "en":
        # A first-time visitor whose browser prefers one of the other languages goes there once;
        # an explicit pick in the menu is remembered and always wins. Crawlers (no stored choice,
        # English browser) stay on the English page.
        others = json.dumps([c for c in LANGS if c != "en"])
        head += (
            "<script>(function(){try{if(localStorage.getItem(\"marlia.lang\"))return;}catch(e){return;}"
            f"var L={others},p=navigator.languages&&navigator.languages.length?navigator.languages:[navigator.language||\"\"];"
            "for(var i=0;i<p.length;i++){var c=String(p[i]).toLowerCase().split(\"-\")[0];"
            "if(c===\"en\")return;if(L.indexOf(c)>=0){location.replace(c+\"/\"+location.hash);return;}}})();</script>\n"
        )
    head += "<!-- seo:end -->"
    page = re.sub(r"<!-- seo:start.*?<!-- seo:end -->", lambda _: head, page, flags=re.S)

    # only this page's strings travel with it
    block = json.dumps({lang: strings}, ensure_ascii=False, separators=(",", ":")).replace("</", "<\\/")
    page = re.sub(r'(<script type="application/json" id="i18n">\n).*?(\n</script>)',
                  lambda m: m.group(1) + block + m.group(2), page, count=1, flags=re.S)

    # asset paths from a language subfolder
    if lang != "en":
        page = re.sub(r'(\s(?:src|href|poster)=")(media/|fonts/|marlia-icon\.png)', r"\1../\2", page)
    return page


def sitemap():
    alts = "".join(f'    <xhtml:link rel="alternate" hreflang="{TAGS[c]}" href="{url_for(c)}"/>\n' for c in LANGS)
    alts += f'    <xhtml:link rel="alternate" hreflang="x-default" href="{SITE}"/>\n'
    urls = "".join(f"  <url>\n    <loc>{url_for(c)}</loc>\n{alts}  </url>\n" for c in LANGS)
    return ('<?xml version="1.0" encoding="UTF-8"?>\n'
            '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9" xmlns:xhtml="http://www.w3.org/1999/xhtml">\n'
            f"{urls}</urlset>\n")


def robots():
    return f"User-agent: *\nAllow: /\n\nSitemap: {SITE}sitemap.xml\n"


def not_found():
    # Served by GitHub Pages for any missing path at any depth, so it uses absolute URLs.
    return """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Page not found · Marlia</title>
<meta name="robots" content="noindex">
<link rel="icon" type="image/png" href="/marlia-icon.png">
<link rel="stylesheet" href="/fonts/fonts.css">
<style>
:root { --paper: #f3f5fa; --ink: #0f1630; --muted: #56607a; --accent: #2342c8; }
@media (prefers-color-scheme: dark) { :root { color-scheme: dark; --paper: #0b1020; --ink: #e8ecf7; --muted: #9aa4bf; --accent: #8197ff; } }
body { margin: 0; min-height: 100vh; display: grid; place-items: center; background: var(--paper); color: var(--ink);
       font: 16px/1.6 "Onest", -apple-system, BlinkMacSystemFont, "Helvetica Neue", Arial, sans-serif;
       padding: 24px max(16px, env(safe-area-inset-left, 0px)); box-sizing: border-box; }
main { max-width: 34rem; display: grid; gap: 14px; }
h1 { margin: 0; font: 800 2rem/1.15 "Manrope", "Avenir Next", "Helvetica Neue", Arial, sans-serif; }
p { margin: 0; color: var(--muted); }
a { color: var(--accent); font-weight: 600; }
img { width: 56px; height: 56px; }
</style>
</head>
<body>
<main>
  <img src="/marlia-icon.png" alt="" width="56" height="56">
  <h1>This page doesn't exist</h1>
  <p>The link may be old or mistyped.</p>
  <p><a href="/">Go to the Marlia home page</a></p>
</main>
</body>
</html>
"""


def outputs():
    template = open(TEMPLATE, encoding="utf-8").read()
    m = re.search(r'<script type="application/json" id="i18n">\n(.*?)\n</script>', template, re.S)
    assert m, "i18n block not found in template"
    table = json.loads(m.group(1).replace("<\\/", "</"))
    missing = {l: sorted(set(table["en"]) - set(table.get(l, {}))) for l in LANGS}
    missing = {l: keys for l, keys in missing.items() if keys}
    assert not missing, f"untranslated keys: {missing}"
    rel = release(template)
    files = {}
    for lang in LANGS:
        strings = {**table["en"], **table[lang]}
        path = "index.html" if lang == "en" else f"{lang}/index.html"
        files[path] = render_page(template, strings, lang, rel)
    files["sitemap.xml"] = sitemap()
    files["robots.txt"] = robots()
    files["404.html"] = not_found()
    return files


def main():
    check = "--check" in sys.argv[1:]
    stale = []
    for path, content in outputs().items():
        full = os.path.join(DOCS, path)
        current = open(full, encoding="utf-8").read() if os.path.exists(full) else None
        if current == content:
            continue
        stale.append(path)
        if not check:
            os.makedirs(os.path.dirname(full), exist_ok=True)
            with open(full, "w", encoding="utf-8") as f:
                f.write(content)
    if check:
        if stale:
            print("docs/ is out of date, run: python3 site/build.py\n  " + "\n  ".join(stale))
            sys.exit(1)
        print("docs/ is up to date")
    else:
        print("wrote: " + (", ".join(stale) if stale else "nothing, already up to date"))


if __name__ == "__main__":
    main()
