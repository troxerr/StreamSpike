#!/usr/bin/env python3
"""Draft X replies for a person to review and post by hand.

This tool never posts, likes, follows or sends DMs, and it never scripts the
X website. Posts come from a file you paste them into, or from the official
X API v2 recent-search endpoint (read-only, with your own bearer token).
The output is a Markdown file of suggestions, each with an x.com reply link
that opens the composer prefilled; you edit the text and press Post yourself.

Usage:
  python3 reply_drafter.py --posts posts.txt
  python3 reply_drafter.py --x-search "twitch clips" --x-search "clip channel"
  python3 reply_drafter.py --posts posts.txt --dry-run   # no Claude calls
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import re
import sqlite3
import sys
import urllib.parse
import urllib.request
from dataclasses import dataclass
from pathlib import Path

HERE = Path(__file__).resolve().parent
DEFAULT_CONFIG = HERE / "config.json"
EXAMPLE_CONFIG = HERE / "config.example.json"
MAX_REPLY_CHARS = 270
X_SEARCH_URL = "https://api.x.com/2/tweets/search/recent"

RESULT_SCHEMA = {
    "type": "object",
    "properties": {
        "relevant": {"type": "boolean"},
        "lead_score": {"type": "integer"},
        "reason": {"type": "string"},
        "mentions_product": {"type": "boolean"},
        "reply": {"type": "string"},
    },
    "required": ["relevant", "lead_score", "reason", "mentions_product", "reply"],
    "additionalProperties": False,
}


@dataclass
class Post:
    url: str
    text: str
    author: str = ""

    @property
    def post_id(self) -> str | None:
        match = re.search(r"/status(?:es)?/(\d+)", self.url)
        return match.group(1) if match else None


@dataclass
class Draft:
    post: Post
    relevant: bool
    lead_score: int
    reason: str
    mentions_product: bool
    reply: str

    def reply_link(self) -> str | None:
        if not self.post.post_id:
            return None
        query = urllib.parse.urlencode({"in_reply_to": self.post.post_id, "text": self.reply})
        return f"https://x.com/intent/post?{query}"


# ---------- input ----------

def parse_posts_file(text: str) -> list[Post]:
    """Blocks separated by a line of '---'. First line is the post URL,
    an optional 'by @handle' line, then the post text."""
    posts = []
    for block in re.split(r"^\s*---\s*$", text, flags=re.MULTILINE):
        lines = [line.rstrip() for line in block.strip().splitlines()]
        if not lines or not lines[0].startswith("http"):
            continue
        url, rest = lines[0].strip(), lines[1:]
        author = ""
        if rest and rest[0].lower().startswith("by @"):
            author = rest[0][3:].strip()
            rest = rest[1:]
        body = "\n".join(rest).strip()
        if body:
            posts.append(Post(url=url, text=body, author=author))
    return posts


def search_x(query: str, bearer: str, max_results: int = 10) -> list[Post]:
    """Official X API v2 recent search. Read-only; needs X_BEARER_TOKEN."""
    params = urllib.parse.urlencode({
        "query": f"{query} -is:retweet -is:reply lang:en",
        "max_results": max(10, min(max_results, 100)),
        "expansions": "author_id",
        "user.fields": "username",
    })
    request = urllib.request.Request(f"{X_SEARCH_URL}?{params}",
                                     headers={"Authorization": f"Bearer {bearer}"})
    with urllib.request.urlopen(request, timeout=30) as response:
        data = json.load(response)
    users = {u["id"]: u["username"] for u in data.get("includes", {}).get("users", [])}
    posts = []
    for tweet in data.get("data", []):
        handle = users.get(tweet.get("author_id"), "i")
        posts.append(Post(url=f"https://x.com/{handle}/status/{tweet['id']}",
                          text=tweet["text"], author=f"@{handle}"))
    return posts


# ---------- dedup ----------

class SeenStore:
    def __init__(self, path: Path):
        self.db = sqlite3.connect(path)
        self.db.execute("CREATE TABLE IF NOT EXISTS seen (url TEXT PRIMARY KEY, drafted_at TEXT)")

    def has(self, url: str) -> bool:
        return self.db.execute("SELECT 1 FROM seen WHERE url = ?", (url,)).fetchone() is not None

    def add(self, url: str) -> None:
        self.db.execute("INSERT OR IGNORE INTO seen VALUES (?, ?)",
                        (url, dt.datetime.now().isoformat(timespec="seconds")))
        self.db.commit()


# ---------- filtering and drafting ----------

def keyword_match(post: Post, keywords: list[str]) -> bool:
    text = post.text.lower()
    return not keywords or any(k.lower() in text for k in keywords)


def system_prompt(config: dict) -> str:
    me = config["me"]
    products = "\n".join(f"- {name}: {desc}" for name, desc in config["products"].items())
    return f"""You draft replies on X for {me['name']} ({me['handle']}), {me['bio']}.
They read every draft and post it by hand, or throw it away.

Their products:
{products}

Decide whether this post is worth a reply from them, then draft one.

Rules for the reply:
- Add something specific the author can use: a fix, a number, a short how-to, or a real question.
- Most replies should not mention the products. Mention one only when it directly solves what the
  post is about, and then say plainly that they built it ("I built ClipSpike for this").
  Never pose as a neutral user or customer.
- Under {MAX_REPLY_CHARS} characters. First person, plain words. No hashtags, no emoji, no links,
  no em dashes, no flattery openers, no asking for likes, follows or reposts.
- If the post is off-topic, hostile, sensitive, or a reply would feel like an ad, set relevant to
  false and leave reply empty.

lead_score: 1-10, how likely this author is to need the products (streamer or clipper with a
clipping problem scores high; a general tech post scores low)."""


def draft_reply(client, config: dict, post: Post) -> Draft:
    user = f"Post by {post.author or 'unknown'} ({post.url}):\n\n{post.text}"
    response = client.beta.messages.create(
        model=config.get("model", "claude-opus-5-5"),
        max_tokens=8000,
        system=system_prompt(config),
        messages=[{"role": "user", "content": user}],
        output_config={"effort": "low", "format": {"type": "json_schema", "schema": RESULT_SCHEMA}},
        betas=["server-side-fallback-2026-07-01"],
        fallbacks="default",
    )
    if response.stop_reason == "refusal":
        return Draft(post, False, 0, "model declined", False, "")
    text = next(block.text for block in response.content if block.type == "text")
    data = json.loads(text)
    reply = data["reply"].strip()
    if len(reply) > MAX_REPLY_CHARS:
        reply = reply[:MAX_REPLY_CHARS].rsplit(" ", 1)[0]
    return Draft(post, bool(data["relevant"]) and bool(reply), int(data["lead_score"]),
                 data["reason"], bool(data["mentions_product"]), reply)


# ---------- output ----------

def render_markdown(drafts: list[Draft], skipped: list[Draft], when: dt.datetime) -> str:
    drafts = sorted(drafts, key=lambda d: d.lead_score, reverse=True)
    out = [f"# Reply drafts, {when:%A %B %d, %Y}", "",
           "Nothing here has been posted. Open a link, edit the text, and press Post yourself.", ""]
    if not drafts:
        out.append("No posts were worth a reply this time.")
    for i, d in enumerate(drafts, 1):
        quoted = "\n".join(f"> {line}" for line in d.post.text.splitlines())
        out += [f"## {i}. {d.post.author or 'Post'} (lead {d.lead_score}/10)", "",
                f"[Original post]({d.post.url})", "", quoted, "",
                f"**Draft reply** ({len(d.reply)} chars{', mentions a product' if d.mentions_product else ''}):", "",
                d.reply, ""]
        link = d.reply_link()
        out += [f"[Reply on X with this text]({link})" if link else "_No post ID in the URL; copy the text._",
                "", f"_Why: {d.reason}_", ""]
    if skipped:
        out += ["## Skipped", ""]
        out += [f"- {d.post.url}: {d.reason}" for d in skipped]
        out.append("")
    return "\n".join(out)


def load_config(path: Path) -> dict:
    if not path.exists():
        path = EXAMPLE_CONFIG
    return json.loads(path.read_text())


def main(argv: list[str] | None = None, client=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--posts", type=Path, help="text file of pasted posts")
    parser.add_argument("--x-search", action="append", default=[], help="X API recent-search query (repeatable)")
    parser.add_argument("--config", type=Path, default=DEFAULT_CONFIG)
    parser.add_argument("--out", type=Path, default=HERE / "drafts")
    parser.add_argument("--max", type=int, default=None, help="max drafts to write")
    parser.add_argument("--dry-run", action="store_true", help="filter and list posts without calling Claude")
    args = parser.parse_args(argv)

    config = load_config(args.config)
    limit = args.max or config.get("daily_max", 10)

    posts: list[Post] = []
    if args.posts:
        posts += parse_posts_file(args.posts.read_text())
    if args.x_search:
        bearer = os.environ.get("X_BEARER_TOKEN")
        if not bearer:
            print("Set X_BEARER_TOKEN to use --x-search, or paste posts with --posts.", file=sys.stderr)
            return 2
        for query in args.x_search:
            posts += search_x(query, bearer)
    if not posts:
        print("No posts to read. Use --posts FILE or --x-search QUERY.", file=sys.stderr)
        return 2

    args.out.mkdir(parents=True, exist_ok=True)
    seen = SeenStore(args.out / "seen.sqlite")
    fresh = [p for p in dict((p.url, p) for p in posts).values()
             if not seen.has(p.url) and keyword_match(p, config.get("keywords", []))]
    print(f"{len(posts)} posts read, {len(fresh)} new and on-topic.")

    if args.dry_run:
        for p in fresh:
            print(f"- {p.url}")
        return 0

    if client is None:
        import anthropic
        client = anthropic.Anthropic()

    drafts, skipped = [], []
    for post in fresh:
        if len(drafts) >= limit:
            break
        draft = draft_reply(client, config, post)
        (drafts if draft.relevant else skipped).append(draft)
        seen.add(post.url)

    now = dt.datetime.now()
    path = args.out / f"{now:%Y-%m-%d-%H%M}.md"
    path.write_text(render_markdown(drafts, skipped, now))
    print(f"{len(drafts)} drafts, {len(skipped)} skipped. Wrote {path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
