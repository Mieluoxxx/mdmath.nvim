local uv = vim.loop
local util = require'mdmath.util'
local diacritics = require'mdmath.Image.diacritics'

local stdout = uv.new_tty(1, false)
if not stdout then
    error('failed to open stdout')
end

-- Keep a separate range from other Kitty graphics users such as image.nvim.
local _id = 333
local function next_id()
    local id = _id
    _id = _id + 1
    return id
end

local function tmux_escape(sequence)
    return "\x1bPtmux;" .. sequence:gsub("\x1b", "\x1b\x1b") .. "\x1b\\"
end

local function write_raw(message)
    local tmux = os.getenv("TMUX")
    if tmux and tmux ~= "" then
        message = tmux_escape(message)
    end
    -- Never write to /dev/tty while Neovim owns the UI: APC payloads leak as text.
    stdout:write(message)
end

local function kitty_send(params, payload)
    if not params.q then
        params.q = 2
    end

    local tbl = {}
    for k, v in pairs(params) do
        tbl[#tbl + 1] = tostring(k) .. "=" .. tostring(v)
    end

    local control = table.concat(tbl, ",")
    if payload ~= nil then
        write_raw(string.format("\x1b_G%s;%s\x1b\\", control, payload))
    else
        write_raw(string.format("\x1b_G%s\x1b\\", control))
    end
end

-- `payload` is already base64 encoded when sending direct data chunks.
-- Keep this separate from kitty_send(), which encodes raw file/control data.
local function kitty_send_encoded(params, payload)
    if not params.q then
        params.q = 2
    end

    local tbl = {}
    for k, v in pairs(params) do
        tbl[#tbl + 1] = tostring(k) .. "=" .. tostring(v)
    end

    write_raw(string.format("\x1b_G%s;%s\x1b\\", table.concat(tbl, ","), payload))
end

local CHUNK = 4096

local function transmit_png(id, path)
    local file = io.open(path, 'rb')
    if not file then
        error('mdmath: cannot read image file: ' .. tostring(path))
    end
    local data = file:read('*a')
    file:close()
    if not data or data == '' then
        error('mdmath: empty image file: ' .. tostring(path))
    end

    -- Direct transmission. File transmission (t=f) is often ignored when the
    -- terminal cannot read Neovim's temp path.
    local encoded = vim.base64.encode(data):gsub('%-', '/')
    local chunks = {}
    for i = 1, #encoded, CHUNK do
        chunks[#chunks + 1] = encoded:sub(i, i + CHUNK - 1)
    end

    local more = #chunks > 1 and 1 or 0
    local control = {a = 't', i = id, f = 100, t = 'd', m = more, q = 2}
    for i, chunk in ipairs(chunks) do
        kitty_send_encoded(control, chunk)

        -- Continuation frames must contain only m=1/m=0. Do not repeat
        -- a=T/U/r/c on the final chunk; placement is sent separately.
        if i == #chunks - 1 then
            control = {m = 0, q = 2}
        else
            control = {m = 1, q = 2}
        end
        uv.sleep(1)
    end
end

local Image = util.class 'Image'

function Image:__tostring()
    return string.format('<Image id=%d>', self.id)
end

function Image:_init(rows, cols, payload)
    local id = next_id()
    if self.id then
        self:close()
    end

    self.id = id
    self.rows = rows
    self.cols = cols

    local path = payload
    if type(path) == 'string' and path ~= '' and path:sub(1, 1) ~= '/' then
        path = vim.fn.fnamemodify(path, ':p')
    end

    transmit_png(id, path)
    kitty_send({a = 'p', U = 1, i = id, r = rows, c = cols, q = 2})
end

function Image.unicode_at(row, col)
    return '\u{10EEEE}' .. diacritics[row] .. diacritics[col]
end

function Image:text()
    local text = {}
    for row = 1, self.rows do
        local T = {}
        for col = 1, self.cols do
            T[#T + 1] = Image.unicode_at(row, col)
        end
        text[#text + 1] = table.concat(T)
    end
    return text
end

function Image:color()
    return self.id -- Color is represented by the id
end

function Image:close()
    if not self.id then
        return
    end

    kitty_send({i = self.id, a = 'd', d = 'I'})
    self.id = nil
end

return Image
