local uv = vim.loop
local util = require'mdmath.util'
local diacritics = require'mdmath.Image.diacritics'

local stdout = uv.new_tty(1, false)
if not stdout then
    error('failed to open stdout')
end

-- Stay in the 256-color ID range. Unicode placeholders encode the image id
-- in the cell foreground color; 24-bit IDs via guifg are less reliable in
-- some terminals (including Ghostty).
local _id = 1
local function next_id()
    local id = _id
    _id = _id + 1
    if _id > 254 then
        _id = 1
    end
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

    -- Prefer the real terminal device. Neovim can swallow APC sequences
    -- written only to stdout in some UI setups.
    local tty = io.open('/dev/tty', 'w')
    if tty then
        tty:write(message)
        tty:flush()
        tty:close()
        return
    end

    if stdout then
        stdout:write(message)
    end
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

    -- Direct transmission. File transmission (t=f) is silently ignored by
    -- some terminals when the process cannot share the path (sandbox, macOS).
    local encoded = vim.base64.encode(data):gsub('%-', '/')
    local chunks = {}
    for i = 1, #encoded, CHUNK do
        chunks[#chunks + 1] = encoded:sub(i, i + CHUNK - 1)
    end

    for i, chunk in ipairs(chunks) do
        local more = i < #chunks and 1 or 0
        if i == 1 then
            kitty_send({a = 't', i = id, f = 100, t = 'd', m = more, q = 2}, chunk)
        else
            kitty_send({m = more, q = 2}, chunk)
        end
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
