# Bookdrop

A KOReader plugin that lets you manage the Kindle's `books/` folder from a browser on any computer on the same Wi-Fi: see your books with covers, upload, download and delete them, and create folders. No USB cable needed.

## Install

1. Connect the Kindle over USB and run `./deploy.sh`.
2. Eject the Kindle and restart KOReader.

## Use

1. In KOReader, open the top menu, then **Network (Wi-Fi icon) → Bookdrop → Bookdrop server**.
2. A popup shows an address like `http://192.168.1.23:8080`. Open it in your computer's browser.
3. Drag books onto the page to upload them. Hover over a book to download or delete it, or use **Select** to delete several at once.

The server is a manual toggle: it only starts and stops when you tap it. It also goes down if the Kindle sleeps or KOReader exits. While it runs, the Kindle won't fall asleep on its own, so remember to turn it off to save battery. **Show address** in the same menu shows the address again.

Covers and titles come from KOReader's cover browser cache. Books it hasn't indexed yet get a plain placeholder cover; the Kindle extracts the real cover in the background and the page updates on its own.

There is no password. Anyone on your Wi-Fi can open the page while the server is running.

## Develop

```
bookdrop.koplugin/
  main.lua              KOReader integration: menu, firewall, covers, cleanup on delete
  bookdrop_server.lua   non-blocking HTTP server polled by KOReader's UI loop
  bookdrop_api.lua      routes (no KOReader dependencies)
  bookdrop_json.lua     tiny JSON encoder
  web/index.html        the browser UI
dev/
  serve.sh              run the server on this computer against dev/sample-books
```

Run it locally (needs `luajit`, plus `luarocks --lua-version=5.1 --local install luasocket luafilesystem`):

```
./dev/serve.sh dev/sample-books 8099
```

Covers and metadata are KOReader-only, so local runs show placeholder covers.
