# Bookdrop

A KOReader plugin to manage your Kindle's books from a browser over Wi-Fi: browse with covers, upload, download, delete, and create, rename or delete folders. No USB cable.

![Bookdrop web UI](docs/screenshot.png)

## Install

Connect the Kindle over USB, run `./deploy.sh`, eject, and restart KOReader.

## Use

1. In KOReader: **Network → Bookdrop → Bookdrop server**.
2. Open the address it shows (e.g. `http://192.168.1.23:8080`) on your computer.
3. Drag books onto the page to upload. Hover a book to download or delete it; **Select** deletes several. Open a folder to rename or delete it (deleting removes everything inside).

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
