--[[--
HTTP routes for Bookdrop: list, upload, download, delete books and manage
folders under a root folder.

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

local MIME = {
    html = "text/html; charset=utf-8", js = "application/javascript",
    css = "text/css", svg = "image/svg+xml", png = "image/png",
    json = "application/json; charset=utf-8",
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

local Api = {}
Api.__index = Api

--- opts: root, lfs, web_dir, hooks = { bookInfo(abs), coverFile(abs, mtime), queueCovers(list),
---       deleteBook(abs), folderRenamed(old_abs, new_abs), changed(), diskUsage(root) }
function Api.new(opts)
    local self = setmetatable(opts, Api)
    self.hooks = self.hooks or {}
    self.root = self.root:gsub("/+$", "")
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

function Api:storage()
    local usage = self.hooks.diskUsage and self.hooks.diskUsage(self.root)
    return usage or json.null
end

--- Called by the server once headers are in, for requests carrying a body.
function Api:openBody(req)
    if not (req.method == "PUT" and req.path == "/api/upload") then
        return nil
    end
    local folder_abs = self:abs(req.query.folder)
    local name = req.query.name
    if not folder_abs or self:mode(folder_abs) ~= "directory" then
        return nil, text(404, "Folder not found")
    end
    if not validName(name) then
        return nil, text(400, "Invalid file name")
    end
    if not BOOK_EXTS[extOf(name) or ""] then
        return nil, text(415, "Not an ebook file: " .. name)
    end

    -- Never overwrite: "Book.epub" -> "Book (2).epub"
    local stem, ext = name:match("^(.*)%.([^.]+)$")
    local final_name, n = name, 1
    while self:mode(folder_abs .. "/" .. final_name) do
        n = n + 1
        final_name = string.format("%s (%d).%s", stem, n, ext)
    end
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
            local rel = final_abs:sub(#api.root + 2)
            return jsonResponse(201, { path = rel, name = final_name })
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

    if m == "GET" and (p == "/" or p == "/index.html") then
        return self:serveStatic("index.html")
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

    if p:sub(1, 5) == "/api/" then
        return text(404, "Unknown endpoint")
    end
    return text(404, "Not found")
end

Api.cleanRel = cleanRel
Api.validName = validName

return Api
