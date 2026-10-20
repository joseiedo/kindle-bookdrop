-- Run Bookdrop's server on a desktop, outside KOReader, for testing.
-- usage: ./dev/serve.sh [books_dir] [port]
local root = arg[1] or "dev/sample-books"
local port = tonumber(arg[2]) or 8080

local lfs = require("lfs")
local socket = require("socket")
local Api = require("bookdrop_api")
local Server = require("bookdrop_server")

local plugin_dir = (arg[0]:match("^(.*)/dev/[^/]*$") or ".") .. "/bookdrop.koplugin"
lfs.mkdir(root)

local screensaver_dir
local reading = {
    fonts = { "EB Garamond", "Literata", "Noto Serif" }, font = "Noto Serif",
    margins = { left = 10, right = 10, top = 15, bottom = 15 }, book = "Sample.epub",
}
local api = Api.new{
    root = root, lfs = lfs, web_dir = plugin_dir .. "/web",
    dirs = { fonts = root .. "/../sample-fonts", photos = root .. "/../sample-photos" },
    hooks = {
        screensaver = function(dir) return { supported = true, active = screensaver_dir == dir } end,
        useScreensaver = function(dir) screensaver_dir = dir end,
        reading = function() return reading end,
        setReading = function(s)
            reading.font = s.font or reading.font
            reading.margins = s.margins
            return reading
        end,
        changed = function() print("changed") end,
        diskUsage = function(dir)
            local p = io.popen("df -k '" .. dir .. "' | tail -1")
            local total, used, free = p:read("*a"):match("%S+%s+(%d+)%s+(%d+)%s+(%d+)")
            p:close()
            -- df -k reports KiB; the API reports bytes, like KOReader's util.diskUsage()
            return total and { total = total * 1024, used = used * 1024, free = free * 1024 }
        end,
        -- Move "Book.sdr" along with "Book.epub", like KOReader's default sidecar location
        moveBook = function(old_abs, new_abs)
            local ok, err = os.rename(old_abs, new_abs)
            if not ok then return nil, err end
            local sdr = function(abs) return abs:gsub("%.[^./]+$", "") .. ".sdr" end
            if lfs.attributes(sdr(old_abs), "mode") == "directory" then
                os.rename(sdr(old_abs), sdr(new_abs))
            end
            return true
        end,
        -- KOReader's default sidecar location: "Book.epub" -> "Book.sdr/metadata.epub.lua"
        sidecar = function(abs)
            local stem, ext = abs:match("^(.*)%.([^./]+)$")
            local chunk = stem and loadfile(stem .. ".sdr/metadata." .. ext .. ".lua")
            if not chunk then return nil end
            local ok, data = pcall(setfenv(chunk, {}))
            return ok and data or nil
        end,
    },
}
local server = Server.new{
    port = port,
    handler = function(req)
        print(req.method, req.path)
        return api:handle(req)
    end,
    openBody = function(req) return api:openBody(req) end,
    logger = print,
}
assert(server:start())
print(string.format("Serving %s on http://localhost:%d", root, port))
-- Mimic UIManager's ZMQ polling: waitEvent() about every 50ms
while true do
    server:waitEvent()
    socket.sleep(0.05)
end
