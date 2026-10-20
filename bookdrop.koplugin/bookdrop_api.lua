--[[--
HTTP routes for Bookdrop: list, upload, download, move, rename, delete books and manage
folders under a root folder. Also manages flat file collections (fonts, screensaver
photos), the screensaver setting and the default reading font and margins.

Kept free of KOReader UI dependencies so it can run on a desktop for testing;
KOReader-specific behaviour (covers, metadata, sidecar cleanup, file browser
refresh) is injected through the `hooks` table.
]]

local json = require("bookdrop_json")

local BOOK_EXTS = {
    epub = true, pdf = true, mobi = true, azw3 = true, azw = true, kfx = true,
    txt = true, fb2 = true, cbz = true, cbr = true, djvu = true, rtf = true,
    doc = true, docx = true, html = true, htm = true, chm = true,
}

local COLLECTION_EXTS = {
    fonts = { ttf = true, otf = true, ttc = true },
    photos = { jpg = true, jpeg = true, png = true, gif = true, webp = true },
}

local MIME = {
    html = "text/html; charset=utf-8", js = "application/javascript",
    css = "text/css", svg = "image/svg+xml", png = "image/png",
    json = "application/json; charset=utf-8",
    jpg = "image/jpeg", jpeg = "image/jpeg", gif = "image/gif", webp = "image/webp",
    ttf = "font/ttf", otf = "font/otf", ttc = "font/collection",
}

local PAGES = {
    ["/"] = "home.html", ["/index.html"] = "home.html", ["/books"] = "index.html",
    ["/fonts"] = "files.html", ["/photos"] = "files.html", ["/base.css"] = "base.css",
}

local function extOf(name)
    local ext = name:match("%.([^./]+)$")
    return ext and ext:lower()
end

local function text(status, body)
    return { status = status, type = "text/plain; charset=utf-8", body = body }
end

local function jsonResponse(status, value)
    return { status = status, type = MIME.json, body = json.encode(value) }
end

--- Normalise a client supplied relative path. Returns nil when it tries to escape.
local function cleanRel(rel)
    rel = rel or ""
    if rel:find("%z") or rel:find("\\", 1, true) then return nil end
    local parts = {}
    for part in rel:gmatch("[^/]+") do
        if part == ".." or part == "." then return nil end
        table.insert(parts, part)
    end
    return table.concat(parts, "/")
end

local function validName(name)
    return name and name ~= "" and #name <= 240
        and not name:find("[/\\%z]") and name:sub(1, 1) ~= "."
end

--- hooks.reading() result, with its font list encoded as a JSON array
local function readingResponse(r)
    local out = {}
    for k, v in pairs(r) do out[k] = v end
    out.fonts = json.array(r.fonts)
    return jsonResponse(200, out)
end

local Api = {}
Api.__index = Api

--- opts: root, lfs, web_dir, dirs = { fonts = abs, photos = abs },
---       hooks = { bookInfo(abs), coverFile(abs, mtime), queueCovers(list),
---       deleteBook(abs), moveBook(old_abs, new_abs), folderRenamed(old_abs, new_abs), changed(),
---       diskUsage(root) -> { total, used, free } in bytes, sidecar(abs) -> settings table,
---       screensaver() -> { active, supported }, useScreensaver(dir),
---       reading() -> { fonts, font, margins = { left, right, top, bottom }, book },
---       setReading({ font, margins, apply_open }) -> same as reading() }
function Api.new(opts)
    local self = setmetatable(opts, Api)
    self.hooks = self.hooks or {}
    self.root = self.root:gsub("/+$", "")
    self.dirs = self.dirs or {}
    return self
end

function Api:abs(rel)
    rel = cleanRel(rel)
    if not rel then return nil end
    if rel == "" then return self.root, rel end
    return self.root .. "/" .. rel, rel
end

function Api:mode(abs)
    return self.lfs.attributes(abs, "mode")
end

function Api:scan()
    local books, folders, pending = {}, {}, {}
    local lfs, hooks = self.lfs, self.hooks
    local function walk(abs, rel)
        local ok, iter, dir_obj = pcall(lfs.dir, abs)
        if not ok then return end
        for name in iter, dir_obj do
            if name:sub(1, 1) ~= "." and not name:match("%.sdr$") then
                local child = abs .. "/" .. name
                local child_rel = rel == "" and name or rel .. "/" .. name
                local attr = lfs.attributes(child)
                if attr and attr.mode == "directory" then
                    table.insert(folders, child_rel)
                    walk(child, child_rel)
                elseif attr and attr.mode == "file" and BOOK_EXTS[extOf(name) or ""] then
                    local book = {
                        path = child_rel,
                        name = name,
                        folder = rel,
                        ext = extOf(name),
                        size = attr.size,
                        mtime = attr.modification,
                        cover = "none",
                    }
                    local info = hooks.bookInfo and hooks.bookInfo(child)
                    if info then
                        book.title = info.title
                        book.authors = info.authors
                        book.series = info.series
                        book.pages = info.pages
                        book.cover = info.cover or "none"
                        if book.cover == "pending" then
                            table.insert(pending, child)
                        end
                    end
                    table.insert(books, book)
                end
            end
        end
    end
    walk(self.root, "")
    table.sort(folders)
    if #pending > 0 and hooks.queueCovers then
        hooks.queueCovers(pending)
    end
    return books, folders
end

--- Delete a directory and everything in it. Books go through hooks.deleteBook
--- so their reading progress, history and cached info go with them.
function Api:purge(abs)
    local lfs = self.lfs
    local names = {}
    local ok, iter, dir_obj = pcall(lfs.dir, abs)
    if not ok then return nil, iter end
    for name in iter, dir_obj do
        if name ~= "." and name ~= ".." then table.insert(names, name) end
    end
    for _, name in ipairs(names) do
        local child = abs .. "/" .. name
        -- Don't follow symlinks out of the folder
        local mode = lfs.symlinkattributes(child, "mode")
        if mode == "directory" then
            local purged, err = self:purge(child)
            if not purged then return nil, err end
        elseif mode then -- may already be gone, e.g. a sidecar removed with its book
            local removed, err
            if mode == "file" and BOOK_EXTS[extOf(name) or ""] and self.hooks.deleteBook then
                removed = self.hooks.deleteBook(child)
            else
                removed, err = os.remove(child)
            end
            if not removed and lfs.symlinkattributes(child, "mode") then
                return nil, err or ("cannot delete " .. name)
            end
        end
    end
    return lfs.rmdir(abs)
end

--- Highlights from a book's sidecar settings, in reading order.
--- Handles the current `annotations` list and the older `highlight` table.
function Api:highlights(abs)
    local data = self.hooks.sidecar and self.hooks.sidecar(abs)
    local list = {}
    if type(data) ~= "table" then return list end
    local function add(item, page)
        if type(item) ~= "table" or type(item.text) ~= "string" or item.text == "" then return end
        table.insert(list, {
            text = item.text,
            note = type(item.note) == "string" and item.note ~= "" and item.note or nil,
            chapter = item.chapter,
            page = item.pageref or item.pageno or page,
            color = item.color,
            datetime = item.datetime,
        })
    end
    if type(data.annotations) == "table" then
        for _, a in ipairs(data.annotations) do
            -- Bookmarks have no drawer; only highlights do
            if a.drawer then add(a) end
        end
    elseif type(data.highlight) == "table" then
        local pages = {}
        for page in pairs(data.highlight) do table.insert(pages, page) end
        table.sort(pages, function(a, b) return (tonumber(a) or 0) < (tonumber(b) or 0) end)
        for _, page in ipairs(pages) do
            for _, hl in ipairs(data.highlight[page]) do add(hl, page) end
        end
    end
    return list
end

--- "Book.epub" -> "Book (2).epub", "Book (3).epub"... until the name is free in folder_abs
function Api:freeName(folder_abs, name)
    local stem, ext = name:match("^(.*)%.([^.]+)$")
    local final_name, n = name, 1
    while self:mode(folder_abs .. "/" .. final_name) do
        n = n + 1
        final_name = string.format("%s (%d).%s", stem, n, ext)
    end
    return final_name
end

function Api:storage()
    local usage = self.hooks.diskUsage and self.hooks.diskUsage(self.root)
    return usage or json.null
end

--- Directory and accepted extensions of a collection ("fonts", "photos"), or nil.
--- Creates the directory on first use.
function Api:collection(kind)
    local dir, exts = self.dirs[kind], COLLECTION_EXTS[kind]
    if not (dir and exts) then return nil end
    if not self:mode(dir) then
        local path = dir:sub(1, 1) == "/" and "" or nil
        for part in dir:gmatch("[^/]+") do
            path = path and path .. "/" .. part or part
            if not self:mode(path) then self.lfs.mkdir(path) end
        end
    end
    return dir, exts
end

--- Absolute path of an existing file in a collection, or nil.
function Api:collectionFile(kind, name)
    local dir, exts = self:collection(kind)
    if not dir or not validName(name) or not exts[extOf(name) or ""] then return nil end
    local abs = dir .. "/" .. name
    return self:mode(abs) == "file" and abs or nil
end

function Api:listCollection(kind)
    local dir, exts = self:collection(kind)
    local files = {}
    local ok, iter, dir_obj = pcall(self.lfs.dir, dir)
    if not ok then return files end
    for name in iter, dir_obj do
        local attr = name:sub(1, 1) ~= "." and exts[extOf(name) or ""] and self.lfs.attributes(dir .. "/" .. name)
        if attr and attr.mode == "file" then
            table.insert(files, { name = name, size = attr.size, mtime = attr.modification })
        end
    end
    table.sort(files, function(a, b) return a.name:lower() < b.name:lower() end)
    return files
end

--- Called by the server once headers are in, for requests carrying a body.
function Api:openBody(req)
    if req.method ~= "PUT" then return nil end
    local folder_abs, name, final_path = nil, req.query.name, nil
    if req.path == "/api/upload" then
        folder_abs = self:abs(req.query.folder)
        if not folder_abs or self:mode(folder_abs) ~= "directory" then
            return nil, text(404, "Folder not found")
        end
        if not validName(name) then
            return nil, text(400, "Invalid file name")
        end
        if not BOOK_EXTS[extOf(name) or ""] then
            return nil, text(415, "Not an ebook file: " .. name)
        end
        final_path = function(abs) return abs:sub(#self.root + 2) end
    elseif req.path == "/api/files/upload" then
        local exts
        folder_abs, exts = self:collection(req.query.kind)
        if not folder_abs then
            return nil, text(404, "Unknown collection")
        end
        if not validName(name) then
            return nil, text(400, "Invalid file name")
        end
        if not exts[extOf(name) or ""] then
            return nil, text(415, "Unsupported file type: " .. name)
        end
        final_path = function(abs) return abs:match("[^/]+$") end
    else
        return nil
    end

    local final_name = self:freeName(folder_abs, name)
    local final_abs = folder_abs .. "/" .. final_name
    local tmp_abs = folder_abs .. "/." .. final_name .. ".bookdrop-part"
    local fh, err = io.open(tmp_abs, "wb")
    if not fh then
        return nil, text(500, "Cannot create file: " .. tostring(err))
    end

    local api = self
    return {
        write = function(_, data)
            return fh:write(data) ~= nil
        end,
        finish = function()
            fh:close()
            fh = nil
            local ok, rename_err = os.rename(tmp_abs, final_abs)
            if not ok then
                os.remove(tmp_abs)
                return text(500, "Cannot save file: " .. tostring(rename_err))
            end
            if api.hooks.changed then api.hooks.changed() end
            return jsonResponse(201, { path = final_path(final_abs), name = final_name })
        end,
        abort = function()
            if fh then fh:close() fh = nil end
            os.remove(tmp_abs)
        end,
    }
end

function Api:serveStatic(file)
    local fh = io.open(self.web_dir .. "/" .. file, "rb")
    if not fh then return text(404, "Not found") end
    return { status = 200, type = MIME[extOf(file)] or "application/octet-stream", file = fh }
end

function Api:handle(req)
    local m, p, q = req.method, req.path, req.query

    if m == "GET" and PAGES[p] then
        return self:serveStatic(PAGES[p])
    end

    if m == "GET" and p == "/api/files" then
        local dir = self:collection(q.kind)
        if not dir then return text(404, "Unknown collection") end
        local result = { dir = dir, files = json.array(self:listCollection(q.kind)) }
        if q.kind == "photos" then
            result.screensaver = self.hooks.screensaver and self.hooks.screensaver(dir) or json.null
        end
        return jsonResponse(200, result)
    end

    if m == "GET" and p == "/api/files/raw" then
        local abs = self:collectionFile(q.kind, q.name)
        local fh = abs and io.open(abs, "rb")
        if not fh then return text(404, "Not found") end
        return { status = 200, type = MIME[extOf(abs)] or "application/octet-stream", file = fh,
                 headers = { ["Cache-Control"] = "max-age=86400" } }
    end

    if m == "DELETE" and p == "/api/files" then
        local abs = self:collectionFile(q.kind, q.name)
        if not abs then return text(404, "Not found") end
        if not os.remove(abs) then return text(500, "Could not delete") end
        return jsonResponse(200, { deleted = q.name })
    end

    if m == "POST" and p == "/api/screensaver" then
        local dir = self:collection("photos")
        if not (dir and self.hooks.useScreensaver) then return text(501, "Not available") end
        self.hooks.useScreensaver(dir)
        return jsonResponse(200, self.hooks.screensaver(dir))
    end

    if m == "GET" and p == "/api/books" then
        local books, folders = self:scan()
        return jsonResponse(200, {
            root = self.root:match("[^/]+$") or self.root,
            books = json.array(books),
            folders = json.array(folders),
            storage = self:storage(),
        })
    end

    if m == "GET" and p == "/api/cover" then
        local abs = self:abs(q.path)
        local cover = abs and self.hooks.coverFile and self:mode(abs) == "file"
            and self.hooks.coverFile(abs, self.lfs.attributes(abs, "modification"))
        local fh = cover and io.open(cover, "rb")
        if not fh then return text(404, "No cover") end
        return { status = 200, type = MIME.png, file = fh,
                 headers = { ["Cache-Control"] = "max-age=86400" } }
    end

    if m == "GET" and p == "/api/download" then
        local abs, rel = self:abs(q.path)
        if not abs or rel == "" or self:mode(abs) ~= "file" then return text(404, "Not found") end
        local fh = io.open(abs, "rb")
        if not fh then return text(404, "Not found") end
        local name = rel:match("[^/]+$")
        return { status = 200, type = "application/octet-stream", file = fh, headers = {
            ["Content-Disposition"] = "attachment; filename*=UTF-8''" .. name:gsub("[^%w%.%-_]", function(c)
                return string.format("%%%02X", c:byte())
            end),
        } }
    end

    if m == "GET" and p == "/api/highlights" then
        local abs, rel = self:abs(q.path)
        if not abs or rel == "" or self:mode(abs) ~= "file" then return text(404, "Not found") end
        return jsonResponse(200, { path = rel, highlights = json.array(self:highlights(abs)) })
    end

    if m == "DELETE" and p == "/api/books" then
        local abs, rel = self:abs(q.path)
        if not abs or rel == "" or self:mode(abs) ~= "file" then return text(404, "Not found") end
        local ok
        if self.hooks.deleteBook then
            ok = self.hooks.deleteBook(abs)
        else
            ok = os.remove(abs)
        end
        if not ok then return text(500, "Could not delete") end
        if self.hooks.changed then self.hooks.changed() end
        return jsonResponse(200, { deleted = rel })
    end

    -- Move and/or rename a book. conflict: "ask" (409 if taken), "overwrite" or "rename" (keep both)
    if m == "POST" and p == "/api/books/move" then
        local abs, rel = self:abs(q.path)
        if not abs or rel == "" or self:mode(abs) ~= "file" then return text(404, "Not found") end
        local new_abs, new_rel = self:abs(q.to)
        local name = new_rel and new_rel:match("[^/]+$")
        if not new_abs or new_rel == "" or not validName(name) then return text(400, "Invalid file name") end
        if not BOOK_EXTS[extOf(name) or ""] then return text(415, "Not an ebook file: " .. name) end
        local folder_abs = new_abs:match("^(.*)/[^/]+$")
        if self:mode(folder_abs) ~= "directory" then return text(404, "Folder not found") end
        if new_rel == rel then return jsonResponse(200, { path = rel, name = name }) end
        -- Case-only renames are fine on case-insensitive disks: target "exists" but is the same file
        if self:mode(new_abs) and new_rel:lower() ~= rel:lower() then
            if q.conflict == "rename" then
                name = self:freeName(folder_abs, name)
                new_abs = folder_abs .. "/" .. name
                new_rel = new_abs:sub(#self.root + 2)
            elseif q.conflict == "overwrite" and self:mode(new_abs) == "file" then
                local removed
                if self.hooks.deleteBook then
                    removed = self.hooks.deleteBook(new_abs)
                else
                    removed = os.remove(new_abs)
                end
                if not removed then return text(500, "Could not replace " .. name) end
            else
                return text(409, "Already exists")
            end
        end
        local ok, err
        if self.hooks.moveBook then
            ok, err = self.hooks.moveBook(abs, new_abs)
        else
            ok, err = os.rename(abs, new_abs)
        end
        if self.hooks.changed then self.hooks.changed() end
        if not ok then return text(500, "Could not move book: " .. tostring(err)) end
        return jsonResponse(200, { path = new_rel, name = name })
    end

    if m == "POST" and p == "/api/folder" then
        local abs, rel = self:abs(q.path)
        local name = rel and rel:match("[^/]+$")
        if not abs or rel == "" or not validName(name) then return text(400, "Invalid folder name") end
        if self:mode(abs) then return text(409, "Already exists") end
        local parent = abs:match("^(.*)/[^/]+$")
        if self:mode(parent) ~= "directory" then return text(404, "Parent folder not found") end
        local ok, err = self.lfs.mkdir(abs)
        if not ok then return text(500, "Could not create folder: " .. tostring(err)) end
        if self.hooks.changed then self.hooks.changed() end
        return jsonResponse(201, { path = rel })
    end

    if m == "DELETE" and p == "/api/folder" then
        local abs, rel = self:abs(q.path)
        if not abs or rel == "" or self:mode(abs) ~= "directory" then return text(404, "Not found") end
        local ok, err = self:purge(abs)
        if self.hooks.changed then self.hooks.changed() end
        if not ok then return text(500, "Could not delete folder: " .. tostring(err)) end
        return jsonResponse(200, { deleted = rel })
    end

    if m == "POST" and p == "/api/folder/rename" then
        local abs, rel = self:abs(q.path)
        if not abs or rel == "" or self:mode(abs) ~= "directory" then return text(404, "Not found") end
        local name = q.name
        if not validName(name) then return text(400, "Invalid folder name") end
        local parent_rel = rel:match("^(.*)/[^/]+$")
        local new_rel = parent_rel and parent_rel .. "/" .. name or name
        local new_abs = self.root .. "/" .. new_rel
        if new_rel == rel then return jsonResponse(200, { path = rel }) end
        -- Case-only renames are fine on case-insensitive disks: target "exists" but is the same dir
        if self:mode(new_abs) and new_rel:lower() ~= rel:lower() then
            return text(409, "Already exists")
        end
        local ok, err = os.rename(abs, new_abs)
        if not ok then return text(500, "Could not rename folder: " .. tostring(err)) end
        if self.hooks.folderRenamed then self.hooks.folderRenamed(abs, new_abs) end
        if self.hooks.changed then self.hooks.changed() end
        return jsonResponse(200, { path = new_rel })
    end

    if m == "GET" and p == "/api/reading" then
        if not self.hooks.reading then return text(501, "Not available") end
        return readingResponse(self.hooks.reading())
    end

    -- Default font and margins for new books; apply=1 also restyles the book open now
    if m == "POST" and p == "/api/reading" then
        if not self.hooks.setReading then return text(501, "Not available") end
        local current = self.hooks.reading()
        local font = q.font
        if font then
            local known = false
            for _, f in ipairs(current.fonts) do
                if f == font then known = true break end
            end
            if not known then return text(400, "Unknown font: " .. font) end
        end
        local margins = {}
        for _, side in ipairs{ "left", "right", "top", "bottom" } do
            local n = tonumber(q[side])
            if not n or n < 0 or n > 200 or n % 1 ~= 0 then
                return text(400, "Margins must be whole numbers from 0 to 200")
            end
            margins[side] = n
        end
        return readingResponse(self.hooks.setReading{ font = font, margins = margins, apply_open = q.apply == "1" })
    end

    if p:sub(1, 5) == "/api/" then
        return text(404, "Unknown endpoint")
    end
    return text(404, "Not found")
end

Api.cleanRel = cleanRel
Api.validName = validName

return Api
