# Reply drafter

Drafts replies on X for you to review and post yourself. It's a separate tool for growing @AST_Labs, not part of the StreamSpike app or its build.

It never posts, likes, follows or sends DMs, and it never scripts the X website. Those are the things [X's automation rules](https://help.x.com/en/rules-and-policies/x-automation) can suspend an account for. The relevance filter and lead scoring follow the approach in `mguozhen/social-bot`; the browser posting part was left out.

## How it works

1. **Posts in:** paste posts into a text file, or use the official X API recent search (read-only, with your own bearer token).
2. **Filter:** a free keyword check, then Claude decides whether a reply would help the author, and scores how likely they are to need ClipSpike or StreamSpike (1 to 10).
3. **Draft:** Claude writes a reply under 270 characters. Most replies don't mention the products. When one does, it says plainly that you built it.
4. **Out:** `drafts/<date>.md`, best leads first. Each draft has a "Reply on X" link that opens the composer with the text filled in. You edit the text and press Post.

Posts it has drafted for are logged in `drafts/seen.sqlite`, so it never drafts twice for the same post.

## Setup

```sh
cd tools/reply-drafter
pip3 install -r requirements.txt
cp config.example.json config.json     # optional: edit keywords, products, daily_max
export ANTHROPIC_API_KEY=...           # or sign in with `ant auth login`
```

## Use

```sh
# Posts you copied from X (format: see posts.example.txt)
python3 reply_drafter.py --posts posts.txt

# Official X API search (needs a paid X API plan with recent search)
export X_BEARER_TOKEN=...
python3 reply_drafter.py --x-search "twitch clips" --x-search "vod highlights"

# Check what would be sent to Claude, without calling it
python3 reply_drafter.py --posts posts.txt --dry-run
```

`posts.txt` holds blocks separated by `---`. Each block is the post URL, an optional `by @handle` line, and the post text.

## Cost

One Claude call per new, on-topic post, on `claude-opus-5-5` at low effort. That's roughly a cent or two per post. Change `model` in `config.json` to trade quality for cost. Requests use server-side refusal fallbacks (`fallbacks: "default"`), so a declined request is retried on another model in the same call. A post that's still declined is listed under Skipped.

## Tests

```sh
python3 -m unittest test_reply_drafter.py
```

The tests run offline with a fake client, with no network and no API key. One test also checks that the source contains no posting, liking, following, DM or browser-automation code.
