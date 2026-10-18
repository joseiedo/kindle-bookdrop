--[[--
Tiny non-blocking HTTP server driven by KOReader's UI loop.

UIManager polls every registered "ZMQ" through waitEvent() roughly every
50ms. Each call here does a bounded slice of socket work and returns nil
(we never produce input events), so large uploads never freeze the UI.

Every response is sent with "Connection: close".
]]

local socket = require("socket")

local CHUNK = 64 * 1024          -- bytes per receive/read
local SLICE = 0.04               -- seconds of work per UI tick
local MAX_HEADER = 16 * 1024
local MAX_MEMORY_BODY = 64 * 1024 -- bodies without a sink are buffered in RAM
local IDLE_TIMEOUT = 30          -- seconds without traffic before dropping

local STATUS_TEXT = {
    [200] = "OK", [201] = "Created", [204] = "No Content",
    [400] = "Bad Request", [403] = "Forbidden", [404] = "Not Found",
    [405] = "Method Not Allowed", [409] = "Conflict", [411] = "Length Required",
    [413] = "Payload Too Large", [415] = "Unsupported Media Type",
    [431] = "Request Header Fields Too Large", [500] = "Internal Server Error",
    [507] = "Insufficient Storage",
}

local function urlDecode(s)
    s = s:gsub("+", " ")
    return (s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end

local function parseQuery(qs)
    local query = {}
    for pair in qs:gmatch("[^&]+") do
        local k, v = pair:match("^([^=]*)=?(.*)$")
        query[urlDecode(k)] = urlDecode(v)
    end
    return query
end

local function parseHead(head)
    local method, target = head:match("^(%u+) (%S+) HTTP/%d%.%d\r\n")
    if not method then return nil end
    local headers = {}
    for k, v in head:gmatch("\r\n([^:\r\n]+):[ \t]*([^\r\n]*)") do
        headers[k:lower()] = v
    end
    local path, qs = target:match("^([^?]*)%??(.*)$")
    return {
        method = method,
        path = urlDecode(path),
        query = parseQuery(qs),
        headers = headers,
    }
end

-- Swallows a body we already decided to reject, so the client gets to read
-- our response instead of a connection reset.
local function discardSink(response)
    return {
        write = function() return true end,
        finish = function() return response end,
        abort = function() end,
    }
end

local function memorySink()
    local parts = {}
    return {
        write = function(_, data) table.insert(parts, data) return true end,
        finish = function(_, req) req.body = table.concat(parts) end,
        abort = function() end,
    }
end

local Server = {}
Server.__index = Server

--- opts.port, opts.handler(req) -> response, opts.openBody(req) -> sink | nil, response
-- A response is { status, type, body (string) | file (open handle), headers }.
-- A sink is { write(self, data) -> ok, finish(self, req) -> response|nil, abort(self) }.
function Server.new(opts)
    return setmetatable({
        host = opts.host or "*",
        port = tonumber(opts.port),
        handler = opts.handler,
        openBody = opts.openBody,
        logger = opts.logger,
        clients = {},
        last_activity = socket.gettime(),
    }, Server)
end

function Server:start()
    local sock, err = socket.bind(self.host, self.port)
    if not sock then return nil, err end
    sock:settimeout(0)
    self.sock = sock
    return true
end

function Server:stop()
    for _, cl in pairs(self.clients) do
        self:_drop(cl)
    end
    if self.sock then
        self.sock:close()
        self.sock = nil
    end
end

function Server:isBusy()
    return next(self.clients) ~= nil
end

function Server:_log(...)
    if self.logger then self.logger(...) end
end

function Server:_drop(cl)
    if cl.sink then
        pcall(cl.sink.abort, cl.sink)
        cl.sink = nil
    end
    if cl.file then
        cl.file:close()
        cl.file = nil
    end
    cl.sock:close()
    self.clients[cl.sock] = nil
end

function Server:_respond(cl, res)
    res = res or { status = 500, body = "No response" }
    local status = res.status or 200
    local lines = {
        string.format("HTTP/1.1 %d %s", status, STATUS_TEXT[status] or "Unknown"),
        "Connection: close",
        "Cache-Control: no-store",
    }
    if res.type then
        table.insert(lines, "Content-Type: " .. res.type)
    end
    if res.file then
        local size = res.file:seek("end")
        res.file:seek("set", 0)
        table.insert(lines, "Content-Length: " .. size)
    else
        table.insert(lines, "Content-Length: " .. #(res.body or ""))
    end
    for k, v in pairs(res.headers or {}) do
        table.insert(lines, k .. ": " .. v)
    end
    table.insert(lines, "")
    table.insert(lines, "")
    cl.out = table.concat(lines, "\r\n") .. (res.body or "")
    cl.pos = 1
    cl.file = res.file
    cl.state = "send"
end

function Server:_dispatch(cl)
    local ok, res = pcall(self.handler, cl.req)
    if not ok then
        self:_log("handler error", res)
        res = { status = 500, type = "text/plain", body = tostring(res) }
    end
    self:_respond(cl, res)
end

function Server:_finishBody(cl)
    local sink = cl.sink
    cl.sink = nil
    local ok, res = pcall(sink.finish, sink, cl.req)
    if not ok then
        self:_log("sink error", res)
        pcall(sink.abort, sink)
        return self:_respond(cl, { status = 500, type = "text/plain", body = tostring(res) })
    end
    if res then
        return self:_respond(cl, res)
    end
    self:_dispatch(cl)
end

function Server:_feed(cl, data)
    if #data > cl.remaining then
        data = data:sub(1, cl.remaining)
    end
    cl.remaining = cl.remaining - #data
    if #data > 0 and not cl.sink:write(data) then
        pcall(cl.sink.abort, cl.sink)
        cl.sink = discardSink({ status = 507, type = "text/plain", body = "Could not write file (disk full?)" })
    end
    if cl.remaining == 0 then
        self:_finishBody(cl)
    end
end

function Server:_begin(cl, head, rest)
    local req = parseHead(head)
    if not req then
        return self:_respond(cl, { status = 400, type = "text/plain", body = "Bad request" })
    end
    cl.req = req
    local length = tonumber(req.headers["content-length"] or 0) or 0
    if req.headers["transfer-encoding"] then
        return self:_respond(cl, { status = 411, type = "text/plain", body = "Content-Length required" })
    end
    if length == 0 then
        return self:_dispatch(cl)
    end

    local sink, res
    if self.openBody then
        sink, res = self.openBody(req)
    end
    if not sink then
        if res then
            sink = discardSink(res)
        elseif length <= MAX_MEMORY_BODY then
            sink = memorySink()
        else
            sink = discardSink({ status = 413, type = "text/plain", body = "Body too large" })
        end
    end
    cl.sink = sink
    cl.remaining = length
    cl.state = "body"
    if (req.headers["expect"] or ""):lower() == "100-continue" then
        cl.sock:send("HTTP/1.1 100 Continue\r\n\r\n")
    end
    if #rest > 0 then
        self:_feed(cl, rest)
    end
end

-- Returns true when progress was made.
function Server:_step(cl, now)
    if cl.state == "send" then
        local last, err, partial = cl.sock:send(cl.out, cl.pos)
        last = last or partial
        local progressed = last and last >= cl.pos
        if progressed then
            cl.pos = last + 1
            cl.t = now
        end
        if cl.pos > #cl.out then
            local chunk = cl.file and cl.file:read(CHUNK)
            if chunk then
                cl.out, cl.pos = chunk, 1
                return true
            end
            self:_drop(cl)
            return true
        end
        if err == "closed" or now - cl.t > IDLE_TIMEOUT then
            self:_drop(cl)
        end
        return progressed
    end

    local data, err, partial = cl.sock:receive(CHUNK)
    data = data or partial
    if data and #data > 0 then
        cl.t = now
        if cl.state == "head" then
            cl.buf = cl.buf .. data
            local e = cl.buf:find("\r\n\r\n", 1, true)
            if e then
                local head, rest = cl.buf:sub(1, e + 1), cl.buf:sub(e + 4)
                cl.buf = nil
                self:_begin(cl, head, rest)
            elseif #cl.buf > MAX_HEADER then
                self:_respond(cl, { status = 431, type = "text/plain", body = "Headers too large" })
            end
        else
            self:_feed(cl, data)
        end
        return true
    end
    if err == "closed" or now - cl.t > IDLE_TIMEOUT then
        self:_drop(cl)
    end
    return false
end

function Server:waitEvent()
    if not self.sock then return nil end
    local now = socket.gettime()
    local deadline = now + SLICE
    for _ = 1, 8 do
        local c = self.sock:accept()
        if not c then break end
        c:settimeout(0)
        self.clients[c] = { sock = c, state = "head", buf = "", t = now }
        self.last_activity = now
    end
    if next(self.clients) then
        self.last_activity = now -- a long upload counts as activity
    end
    repeat
        local progressed = false
        for _, cl in pairs(self.clients) do
            if self:_step(cl, now) then progressed = true end
        end
        now = socket.gettime()
    until not progressed or now >= deadline
    return nil
end

return Server
