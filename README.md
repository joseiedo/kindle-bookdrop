# Bookdrop

A KOReader plugin to manage your Kindle's books from a browser over Wi-Fi: browse with covers, read highlights, upload, download, move, rename and delete books, and create, rename or delete folders. No USB cable.

![Bookdrop web UI](docs/screenshot.png)

## Install

Connect the Kindle over USB, run `./deploy.sh`, eject, and restart KOReader.

To update over Wi-Fi instead (no need to quit KOReader): put your public key in `koreader/settings/SSH/authorized_keys` once, start **Network → SSH server** in KOReader, then run `./deploy.sh <kindle-ip>` and restart KOReader. The key defaults to `~/.ssh/kindle_ed25519` (override with `SSH_KEY`).

## Use

1. In KOReader: **Network → Bookdrop → Bookdrop server**.
2. Open the address it shows (e.g. `http://192.168.1.23:8080`) on your computer.
3. Drag books onto the page to upload. Click a book to read its highlights and notes. Hover a book to rename, download or delete it. Drag books onto a folder to move them, or use **Select** to move or delete several at once (**Move to…** can create the folder). Highlights and reading progress move with the book; on a name clash you choose to replace, keep both, or skip. Open a folder to rename or delete it (deleting removes everything inside).

The server runs until you toggle it off, the Kindle sleeps, or KOReader exits. It keeps the Kindle awake, so turn it off when done. There's no password: anyone on your Wi-Fi can use it while it runs.

Covers come from KOReader's cover browser cache; unindexed books show a placeholder until the Kindle extracts the cover.

## Develop

```
bookdrop.koplugin/
  main.lua              KOReader integration: menu, firewall, covers, cleanup
  bookdrop_server.lua   non-blocking HTTP server polled by KOReader's UI loop
  bookdrop_api.lua      routes (no KOReader dependencies)
  bookdrop_json.lua     tiny JSON encoder
  web/index.html        browser UI
dev/serve.sh            run the server locally
```

Needs `luajit` and `luarocks --lua-version=5.1 --local install luasocket luafilesystem`:

```
./dev/serve.sh dev/sample-books 8099
```

Local runs show placeholder covers (covers need KOReader).

## License

[AGPL-3.0](LICENSE), same as KOReader. Not affiliated with or endorsed by Amazon; Kindle is a trademark of Amazon.com, Inc.
