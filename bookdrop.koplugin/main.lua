--[[--
Bookdrop: manage the books folder from a browser on another computer.

Start it from the Network menu, open the shown address on your PC, and
list, upload, download or delete books. Started and stopped by hand only;
it also goes down when the device suspends or KOReader exits.
]]

local DataStorage = require("datastorage")
local Device = require("device")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local socket = require("socket")
local util = require("util")
local bit = require("bit")
local _ = require("gettext")
local T = require("ffi/util").template

local Api = require("bookdrop_api")
local Server = require("bookdrop_server")

local DEFAULT_ROOT = Device:isKindle() and "/mnt/us/books" or DataStorage:getDataDir() .. "/books"
local COVER_CACHE = "/tmp/bookdrop-covers"
local COVER_SPECS = { max_cover_w = 360, max_cover_h = 540 }

local plugin_dir = debug.getinfo(1, "S").source:match("^@(.*)/[^/]*$") or "."

-- The plugin is re-instantiated on every reader/file manager switch, but the
-- server must survive that, so it lives at module level.
local running = nil -- { server = Server, port = n }

local Bookdrop = WidgetContainer:extend{
    name = "bookdrop",
    is_doc_only = false,
}

local function getIP()
    -- Connecting a UDP socket sends nothing, but makes the kernel pick the
    -- interface (and so the address) it would route through.
    local udp = socket.udp()
    if udp then
        udp:setpeername("192.0.2.1", 9)
        local ip = udp:getsockname()
        udp:close()
        if ip and ip ~= "0.0.0.0" and not ip:match("^127%.") then
            return ip
        end
    end
    local p = io.popen("ip -4 -o addr show 2>/dev/null")
    if p then
        local out = p:read("*a") or ""
        p:close()
        for ip in out:gmatch("inet (%d+%.%d+%.%d+%.%d+)") do
            if not ip:match("^127%.") then return ip end
        end
    end
end

local function hash(s)
    local h = 2166136261
    for i = 1, #s do
        h = bit.bxor(h, s:byte(i))
        h = bit.tobit(h * 16777619)
    end
    return bit.tohex(h)
end

local BookInfoManager -- lazy: only needed while the server runs
local function getBIM()
    if BookInfoManager == nil then
        local ok, bim = pcall(require, "bookinfomanager")
        BookInfoManager = ok and bim or false
        if not ok then logger.warn("Bookdrop: coverbrowser unavailable, no covers", bim) end
    end
    return BookInfoManager or nil
end

local hooks = {}

function hooks.bookInfo(abs)
    local bim = getBIM()
    if not bim then return nil end
    local ok, info = pcall(bim.getBookInfo, bim, abs, false)
    if not ok then return nil end
    if not info then
        return { cover = "pending" }
    end
    local authors = info.authors and info.authors:gsub("\n", ", ")
    local cover
    if info.unsupported or info.ignore_cover then
        cover = "none"
    elseif info.has_cover then
        cover = "ready"
    elseif info.cover_fetched or (tonumber(info.in_progress) or 0) >= 2 then
        -- fetched without finding one, or extraction keeps crashing: give up
        cover = "none"
    else
        cover = "pending"
    end
    return {
        title = info.title,
        authors = authors,
        series = info.series,
        pages = info.pages,
        cover = cover,
    }
end

function hooks.queueCovers(files)
    local bim = getBIM()
    if not bim or bim:isExtractingInBackground() then return end
    local jobs = {}
    for _, abs in ipairs(files) do
        table.insert(jobs, { filepath = abs, cover_specs = COVER_SPECS })
    end
    logger.dbg("Bookdrop: extracting covers for", #jobs, "books")
    bim:extractInBackground(jobs)
end

function hooks.coverFile(abs, mtime)
    local cached = string.format("%s/%s-%d.png", COVER_CACHE, hash(abs), mtime or 0)
    if lfs.attributes(cached, "mode") == "file" then return cached end
    local bim = getBIM()
    if not bim then return nil end
    local ok, info = pcall(bim.getBookInfo, bim, abs, true)
    if not ok or not info or not info.cover_bb then return nil end
    util.makePath(COVER_CACHE)
    local written = pcall(info.cover_bb.writePNG, info.cover_bb, cached)
    info.cover_bb:free()
    return written and cached or nil
end

function hooks.deleteBook(abs)
    if not os.remove(abs) then return false end
    -- Same cleanup as FileManager:deleteFile()
    local function try(mod, fn)
        local ok, m = pcall(require, mod)
        if ok and m then pcall(fn, m) end
    end
    try("ui/widget/booklist", function(m) m.resetBookInfoCache(abs) end)
    try("docsettings", function(m) m.updateLocation(abs) end)
    try("readhistory", function(m) m:fileDeleted(abs) end)
    try("readcollection", function(m) m:removeItem(abs) end)
    local bim = getBIM()
    if bim then pcall(bim.deleteBookInfo, bim, abs) end
    return true
end

function hooks.folderRenamed(old_abs, new_abs)
    -- Same bookkeeping as FileManager:renameFile() for folders; sidecars move with the folder
    for _, mod in ipairs{ "readhistory", "readcollection" } do
        local ok, m = pcall(require, mod)
        if ok and m and m.updateItemsByPath then pcall(m.updateItemsByPath, m, old_abs, new_abs) end
    end
end

local function refreshFileManager()
    local ok, FileManager = pcall(require, "apps/filemanager/filemanager")
    if ok and FileManager.instance then
        FileManager.instance:onRefresh()
    end
end

function hooks.changed()
    UIManager:unschedule(refreshFileManager)
    UIManager:scheduleIn(1, refreshFileManager)
end

function hooks.diskUsage(root)
    local usage = util.diskUsage(root)
    if usage and usage.total then
        return { total = usage.total, used = usage.used, free = usage.available }
    end
end

function Bookdrop:init()
    self.port = tonumber(G_reader_settings:readSetting("bookdrop_port")) or 8080
    self.root = G_reader_settings:readSetting("bookdrop_root") or DEFAULT_ROOT
    self.ui.menu:registerToMainMenu(self)
end

function Bookdrop:isRunning()
    return running ~= nil
end

function Bookdrop:url()
    local ip = getIP()
    local port = running and running.port or self.port
    return ip and string.format("http://%s:%d", ip, port)
end

-- Kindle's own power daemon puts the device to sleep (and drops Wi-Fi)
-- after a few idle minutes; hold it off while serving.
local function keepAwake(on)
    UIManager[on and "preventStandby" or "allowStandby"](UIManager)
    if Device:isKindle() then
        os.execute("lipc-set-prop com.lab126.powerd preventScreenSaver " .. (on and 1 or 0))
    end
end

local function firewall(action, port)
    if not Device:isKindle() then return end
    os.execute(string.format("iptables -%s INPUT -p tcp --dport %d -m conntrack --ctstate NEW,ESTABLISHED -j ACCEPT", action, port))
    os.execute(string.format("iptables -%s OUTPUT -p tcp --sport %d -m conntrack --ctstate ESTABLISHED -j ACCEPT", action, port))
end

function Bookdrop:start()
    if running then return self:showAddress() end
    if lfs.attributes(self.root, "mode") ~= "directory" then
        util.makePath(self.root)
    end
    local api = Api.new{ root = self.root, lfs = lfs, web_dir = plugin_dir .. "/web", hooks = hooks }
    local server = Server.new{
        port = self.port,
        handler = function(req) return api:handle(req) end,
        openBody = function(req) return api:openBody(req) end,
        logger = function(...) logger.warn("Bookdrop:", ...) end,
    }
    local ok, err = server:start()
    if not ok then
        UIManager:show(InfoMessage:new{
            icon = "notice-warning",
            text = T(_("Could not start Bookdrop on port %1:\n%2"), self.port, tostring(err)),
        })
        return
    end
    firewall("A", self.port)
    UIManager:insertZMQ(server)
    keepAwake(true)
    running = { server = server, port = self.port }
    logger.info("Bookdrop: serving", self.root, "on port", self.port)
    self:showAddress()
end

function Bookdrop:stop()
    if not running then return end
    UIManager:removeZMQ(running.server)
    running.server:stop()
    firewall("D", running.port)
    keepAwake(false)
    running = nil
    logger.info("Bookdrop: stopped")
end

function Bookdrop:showAddress()
    local url = self:url()
    local text
    if not url then
        text = _("Bookdrop is running, but no Wi-Fi address was found.\nConnect to Wi-Fi and check again.")
    else
        text = T(_("Bookdrop is running.\n\nOn your computer, open:\n\n%1\n\nBoth devices must be on the same Wi-Fi."), url)
    end
    UIManager:show(InfoMessage:new{ text = text })
end

-- The server can't outlive a suspend (Wi-Fi goes down) or KOReader itself.
function Bookdrop:onSuspend() self:stop() end
function Bookdrop:onExit() self:stop() end

function Bookdrop:addToMainMenu(menu_items)
    menu_items.bookdrop = {
        text = _("Bookdrop (manage books from PC)"),
        sorting_hint = "network",
        sub_item_table = {
            {
                text = _("Bookdrop server"),
                keep_menu_open = true,
                checked_func = function() return self:isRunning() end,
                callback = function(touchmenu_instance)
                    if self:isRunning() then
                        self:stop()
                    else
                        local NetworkMgr = require("ui/network/manager")
                        NetworkMgr:runWhenConnected(function()
                            self:start()
                            if touchmenu_instance then touchmenu_instance:updateItems() end
                        end)
                    end
                    if touchmenu_instance then touchmenu_instance:updateItems() end
                end,
            },
            {
                text = _("Show address"),
                enabled_func = function() return self:isRunning() end,
                keep_menu_open = true,
                callback = function() self:showAddress() end,
            },
            {
                text_func = function() return T(_("Port: %1"), self.port) end,
                enabled_func = function() return not self:isRunning() end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    self:showPortDialog(touchmenu_instance)
                end,
            },
            {
                text_func = function() return T(_("Folder: %1"), self.root) end,
                enabled_func = function() return not self:isRunning() end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    local PathChooser = require("ui/widget/pathchooser")
                    UIManager:show(PathChooser:new{
                        select_file = false,
                        path = self.root,
                        onConfirm = function(path)
                            self.root = path
                            G_reader_settings:saveSetting("bookdrop_root", path)
                            if touchmenu_instance then touchmenu_instance:updateItems() end
                        end,
                    })
                end,
            },
        },
    }
end

function Bookdrop:showPortDialog(touchmenu_instance)
    local InputDialog = require("ui/widget/inputdialog")
    local dialog
    dialog = InputDialog:new{
        title = _("Bookdrop port"),
        input = tostring(self.port),
        input_type = "number",
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            { text = _("Save"), is_enter_default = true, callback = function()
                local port = tonumber(dialog:getInputText())
                if port and port >= 1024 and port <= 65535 then
                    self.port = port
                    G_reader_settings:saveSetting("bookdrop_port", port)
                    UIManager:close(dialog)
                    if touchmenu_instance then touchmenu_instance:updateItems() end
                end
            end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

return Bookdrop
