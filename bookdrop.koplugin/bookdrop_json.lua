--[[--
Minimal JSON encoder. Lua can't tell an empty array from an empty object,
so arrays are marked explicitly with json.array().
]]

local json = {}

local ARRAY = {}
json.null = setmetatable({}, { __tojson = "null" })

function json.array(t)
    return setmetatable(t or {}, ARRAY)
end

local ESCAPES = {
    ['"'] = '\\"', ["\\"] = "\\\\", ["\b"] = "\\b", ["\f"] = "\\f",
    ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t",
}

local function encodeString(s)
    return '"' .. s:gsub('[%c"\\]', function(c)
        return ESCAPES[c] or string.format("\\u%04x", c:byte())
    end) .. '"'
end

local encode

local function encodeTable(t, out)
    if t == json.null then
        table.insert(out, "null")
    elseif getmetatable(t) == ARRAY then
        table.insert(out, "[")
        for i, v in ipairs(t) do
            if i > 1 then table.insert(out, ",") end
            encode(v, out)
        end
        table.insert(out, "]")
    else
        table.insert(out, "{")
        local first = true
        for k, v in pairs(t) do
            if not first then table.insert(out, ",") end
            first = false
            table.insert(out, encodeString(tostring(k)))
            table.insert(out, ":")
            encode(v, out)
        end
        table.insert(out, "}")
    end
end

encode = function(v, out)
    local kind = type(v)
    if kind == "string" then
        table.insert(out, encodeString(v))
    elseif kind == "number" then
        if v ~= v or v == math.huge or v == -math.huge then
            table.insert(out, "null")
        elseif v == math.floor(v) and math.abs(v) < 2^53 then
            table.insert(out, string.format("%d", v))
        else
            table.insert(out, string.format("%.14g", v))
        end
    elseif kind == "boolean" then
        table.insert(out, tostring(v))
    elseif kind == "table" then
        encodeTable(v, out)
    else
        table.insert(out, "null")
    end
end

function json.encode(v)
    local out = {}
    encode(v, out)
    return table.concat(out)
end

return json
