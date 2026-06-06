#!/usr/bin/env bash
set -euo pipefail

# ---- Configuration ----
# MODE: hugo (reads Markdown from CONTENT_DIR) or html (reads HTML from HTML_DIR)
MODE="${MODE:-hugo}"

# Hugo mode
CONTENT_DIR="${CONTENT_DIR:-content}"

# HTML mode
HTML_DIR="${HTML_DIR:-public}"

# Shared
OUTPUT_DIR="${OUTPUT_DIR:-gopher}"
GOPHER_HOST="${GOPHER_HOST:-localhost}"
GOPHER_PORT="${GOPHER_PORT:-70}"
BANNER_FILE="${BANNER_FILE:-banner.txt}"
SITE_URL="${SITE_URL:-}"

if [[ "$MODE" == "hugo" && ! -d "$CONTENT_DIR" ]]; then
  echo "Error: content directory not found: $CONTENT_DIR"
  exit 1
fi

if [[ "$MODE" == "html" && ! -d "$HTML_DIR" ]]; then
  echo "Error: HTML directory not found: $HTML_DIR"
  exit 1
fi

export MODE CONTENT_DIR HTML_DIR OUTPUT_DIR GOPHER_HOST GOPHER_PORT BANNER_FILE SITE_URL

python3 <<'PY'
import os
import re
import shutil
import datetime
from pathlib import Path
from html.parser import HTMLParser

MODE        = os.environ.get("MODE", "hugo")
CONTENT_DIR = Path(os.environ.get("CONTENT_DIR", "content"))
HTML_DIR    = Path(os.environ.get("HTML_DIR", "public"))
OUTPUT_DIR  = Path(os.environ.get("OUTPUT_DIR", "gopher"))
GOPHER_HOST = os.environ.get("GOPHER_HOST", "localhost")
GOPHER_PORT = os.environ.get("GOPHER_PORT", "70")
BANNER_FILE = Path(os.environ.get("BANNER_FILE", "banner.txt"))
SITE_URL    = os.environ.get("SITE_URL", "")

TODAY = datetime.date.today()


# ---- Banner ----

def read_banner():
    if BANNER_FILE.exists():
        banner = BANNER_FILE.read_text(encoding="utf-8").rstrip()
        if banner:
            return banner
    return ""


# ---- Gophermap line ----

def gophermap_line(kind, label, selector):
    return f"{kind}{label}\t{selector}\t{GOPHER_HOST}\t{GOPHER_PORT}"


# ---- Shared output ----

def write_text_file(out_path, title, date, summary, body, source_url=""):
    lines = []
    lines.append(title)
    lines.append("=" * len(title))
    lines.append("")

    if date:
        lines.append(f"Date: {date}")
        lines.append("")

    if summary:
        lines.append(summary)
        lines.append("")

    if body:
        lines.append(body)
        lines.append("")

    if source_url:
        lines.append(f"Website: {source_url}")
        lines.append("")

    if SITE_URL:
        lines.append(f"Main website: {SITE_URL}")
        lines.append("")

    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text("\n".join(lines), encoding="utf-8")


def write_section_gophermap(section_dir, label, items):
    section_dir.mkdir(parents=True, exist_ok=True)

    lines = []
    lines.append(gophermap_line("i", label, "fake\tfake\t0"))
    lines.append(gophermap_line("i", "", "fake\tfake\t0"))
    lines.append(gophermap_line("1", "Back to Home", "/"))
    lines.append(gophermap_line("i", "", "fake\tfake\t0"))

    for item in sorted(items, key=lambda x: x["title"].lower()):
        lines.append(gophermap_line("0", item["title"], item["selector"]))

    lines.append("")
    (section_dir / "gophermap").write_text("\n".join(lines), encoding="utf-8")


def gopher_selector(file_path):
    rel = file_path.relative_to(OUTPUT_DIR)
    return "/" + str(rel).replace(os.sep, "/")


def write_home_gophermap(items_by_section):
    lines = []

    banner = read_banner()
    if banner:
        lines.append(banner)
        lines.append("")

    if SITE_URL:
        lines.append(gophermap_line("i", f"Main website: {SITE_URL}", "fake\tfake\t0"))
        lines.append(gophermap_line("i", "", "fake\tfake\t0"))

    for section in sorted(items_by_section):
        label = section.replace("-", " ").replace("_", " ").title()
        lines.append(gophermap_line("1", label, f"/{section}"))

    lines.append("")
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    (OUTPUT_DIR / "gophermap").write_text("\n".join(lines), encoding="utf-8")


# ============================================================
# Hugo mode  (reads Markdown + front matter from CONTENT_DIR)
# ============================================================

def clean_value(value):
    value = value.strip()
    if value in ("", "null", "None", "~"):
        return ""
    if value.lower() in ("true", "false"):
        return value.lower() == "true"
    if (value.startswith('"') and value.endswith('"')) or \
       (value.startswith("'") and value.endswith("'")):
        return value[1:-1]
    return value


def parse_key_values(raw, mode="yaml"):
    data = {}
    for line in raw.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if mode == "toml" and "=" in line:
            key, value = line.split("=", 1)
        elif ":" in line:
            key, value = line.split(":", 1)
        else:
            continue
        key = key.strip().strip('"').strip("'")
        value = value.strip()
        if " #" in value:
            value = value.split(" #", 1)[0].strip()
        data[key] = clean_value(value)
    return data


def parse_front_matter(text):
    text = text.lstrip("﻿")
    if text.startswith("---"):
        end = text.find("\n---", 3)
        if end == -1:
            return {}, text
        raw = text[3:end].strip()
        body = text[end + len("\n---"):].lstrip()
        return parse_key_values(raw, mode="yaml"), body
    if text.startswith("+++"):
        end = text.find("\n+++", 3)
        if end == -1:
            return {}, text
        raw = text[3:end].strip()
        body = text[end + len("\n+++"):].lstrip()
        return parse_key_values(raw, mode="toml"), body
    return {}, text


def parse_date(value):
    if not value:
        return None
    s = str(value).strip().strip('"').strip("'")
    m = re.match(r"^(\d{4})-(\d{2})-(\d{2})", s)
    if not m:
        return None
    try:
        return datetime.date(int(m.group(1)), int(m.group(2)), int(m.group(3)))
    except ValueError:
        return None


def should_publish(front):
    if front.get("draft") is True:
        return False
    if str(front.get("status", "")).strip().lower() in ("draft", "archived"):
        return False
    d = parse_date(front.get("date", ""))
    if d and d > TODAY:
        return False
    return True


def slugify(value):
    value = str(value).strip().lower()
    value = re.sub(r"[^\w\s/-]", "", value)
    value = value.replace("_", "-")
    value = re.sub(r"\s+", "-", value)
    value = re.sub(r"-+", "-", value)
    return value.strip("-/") or "untitled"


def markdown_to_text(markdown):
    text = markdown
    text = re.sub(r"\{\{<.*?>\}\}", "", text, flags=re.DOTALL)
    text = re.sub(r"\{\{%.*?%\}\}", "", text, flags=re.DOTALL)
    text = re.sub(r"<[^>]+>", "", text)
    text = re.sub(r"!\[([^\]]*)\]\(([^)]+)\)", r"\1", text)
    text = re.sub(r"\[([^\]]+)\]\(([^)]+)\)", r"\1 (\2)", text)
    text = re.sub(r"^#{1,6}\s*", "", text, flags=re.MULTILINE)
    for ch in ("**", "__", "*", "_", "`"):
        text = text.replace(ch, "")
    text = re.sub(r"^\s*>\s?", "", text, flags=re.MULTILINE)
    text = re.sub(r"^\s*[-+]\s+", "- ", text, flags=re.MULTILINE)
    text = re.sub(r"^\s*\d+\.\s+", "- ", text, flags=re.MULTILINE)
    text = re.sub(r"\n{3,}", "\n\n", text)
    return text.strip()


def section_from_md_path(path):
    rel = path.relative_to(CONTENT_DIR)
    return rel.parts[0] if len(rel.parts) > 1 else "pages"


def output_path_for_md(path, front):
    section = section_from_md_path(path)
    url = str(front.get("url", "")).strip().strip("/")
    if url:
        return OUTPUT_DIR / f"{slugify(url)}.txt"
    slug = str(front.get("slug", "")).strip().strip("/")
    filename = slugify(slug or path.stem)
    return OUTPUT_DIR / section / f"{filename}.txt"


def run_hugo_mode():
    published = []
    skipped = []

    for path in sorted(CONTENT_DIR.rglob("*.md")):
        if path.name == "_index.md":
            continue
        try:
            text = path.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            text = path.read_text(encoding="latin-1")

        front, body = parse_front_matter(text)

        if not should_publish(front):
            skipped.append(str(path))
            continue

        title = str(front.get("title") or path.stem).strip()
        out_path = output_path_for_md(path, front)
        section = section_from_md_path(path)

        write_text_file(
            out_path,
            title=title,
            date=str(front.get("date") or "").strip(),
            summary=str(front.get("summary") or front.get("description") or "").strip(),
            body=markdown_to_text(body),
            source_url=str(
                front.get("external_url") or front.get("website") or
                front.get("source_url") or ""
            ).strip(),
        )

        published.append({
            "title": title,
            "section": section,
            "selector": gopher_selector(out_path),
        })

    items_by_section = {}
    for item in published:
        items_by_section.setdefault(item["section"], []).append(item)

    for section, items in items_by_section.items():
        label = section.replace("-", " ").replace("_", " ").title()
        write_section_gophermap(OUTPUT_DIR / section, label, items)

    write_home_gophermap(items_by_section)

    print(f"Generated Gopher output in: {OUTPUT_DIR}")
    print(f"Published: {len(published)}  Skipped: {len(skipped)}")
    if skipped:
        print("\nSkipped:")
        for s in skipped:
            print(f"  {s}")


# ============================================================
# HTML mode  (reads rendered HTML files from HTML_DIR)
# ============================================================

SKIP_TAGS = {"script", "style", "nav", "header", "footer", "aside", "noscript"}


class HTMLTextExtractor(HTMLParser):
    def __init__(self):
        super().__init__()
        self._parts = []
        self._title_parts = []
        self._depth = {t: 0 for t in SKIP_TAGS}
        self._in_title = False
        self._block_tags = {"p", "div", "li", "h1", "h2", "h3", "h4", "h5", "h6", "br", "tr"}

    def handle_starttag(self, tag, attrs):
        tag = tag.lower()
        if tag in self._depth:
            self._depth[tag] += 1
        if tag == "title":
            self._in_title = True
        if tag in self._block_tags:
            self._parts.append("\n")

    def handle_endtag(self, tag):
        tag = tag.lower()
        if tag in self._depth:
            self._depth[tag] = max(0, self._depth[tag] - 1)
        if tag == "title":
            self._in_title = False

    def _in_skip(self):
        return any(v > 0 for v in self._depth.values())

    def handle_data(self, data):
        if self._in_title:
            self._title_parts.append(data)
            return
        if self._in_skip():
            return
        self._parts.append(data)

    def title(self):
        return "".join(self._title_parts).strip()

    def text(self):
        raw = "".join(self._parts)
        raw = re.sub(r"[^\S\n]+", " ", raw)
        raw = re.sub(r"\n[^\S\n]+", "\n", raw)
        raw = re.sub(r"\n{3,}", "\n\n", raw)
        return raw.strip()


def section_from_html_path(path):
    rel = path.relative_to(HTML_DIR)
    parts = rel.parts
    if len(parts) <= 1:
        return None
    return parts[0]


def output_path_for_html(path):
    rel = path.relative_to(HTML_DIR)
    parts = list(rel.parts)

    if parts[-1] == "index.html":
        if len(parts) == 1:
            return None
        parts[-1] = parts[-2] + ".txt"
        parts = parts[:-2] + [parts[-1]]
    else:
        parts[-1] = path.stem + ".txt"

    return OUTPUT_DIR / Path(*parts)


def run_html_mode():
    published = []

    for path in sorted(HTML_DIR.rglob("*.html")):
        rel = path.relative_to(HTML_DIR)

        # Skip root index — it becomes the gophermap home
        if str(rel) == "index.html":
            continue

        try:
            html = path.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            html = path.read_text(encoding="latin-1")

        extractor = HTMLTextExtractor()
        extractor.feed(html)

        title = extractor.title() or path.stem.replace("-", " ").replace("_", " ").title()
        body = extractor.text()

        out_path = output_path_for_html(path)
        if out_path is None:
            continue

        section = section_from_html_path(path) or "pages"

        write_text_file(out_path, title=title, date="", summary="", body=body)

        published.append({
            "title": title,
            "section": section,
            "selector": gopher_selector(out_path),
        })

    items_by_section = {}
    for item in published:
        items_by_section.setdefault(item["section"], []).append(item)

    for section, items in items_by_section.items():
        label = section.replace("-", " ").replace("_", " ").title()
        write_section_gophermap(OUTPUT_DIR / section, label, items)

    write_home_gophermap(items_by_section)

    print(f"Generated Gopher output in: {OUTPUT_DIR}")
    print(f"Published: {len(published)}")


# ============================================================

def main():
    if OUTPUT_DIR.exists():
        shutil.rmtree(OUTPUT_DIR)
    OUTPUT_DIR.mkdir(parents=True)

    if MODE == "html":
        run_html_mode()
    else:
        run_hugo_mode()


if __name__ == "__main__":
    main()
PY
