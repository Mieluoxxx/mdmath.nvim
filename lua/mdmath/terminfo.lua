local api = vim.api

local M = {}

local winsize = nil

function M.size()
    if winsize == nil then
        winsize, err = require'mdmath.terminfo._system'.request_size()
        if not winsize then
            error('Failed to get terminal size: code ' .. err)
        end
    end

    return winsize
end

-- Fallback used when the terminal reports no pixel size via TIOCGWINSZ.
-- Some terminals (notably Ghostty/macOS) fill row/col but leave xpixel/ypixel as 0.
-- Returning 0 here makes rsvg-convert fail with InvalidMatrix / Invalid zoom factor.
local FALLBACK_CELL_WIDTH = 10
local FALLBACK_CELL_HEIGHT = 20

function M.cell_size()
    local size = M.size()

    local col = size.col
    local row = size.row
    local xpixel = size.xpixel
    local ypixel = size.ypixel

    local width, height
    if col and col > 0 and xpixel and xpixel > 0 then
        width = xpixel / col
    end
    if row and row > 0 and ypixel and ypixel > 0 then
        height = ypixel / row
    end

    if not width or width <= 0 or width ~= width then
        width = FALLBACK_CELL_WIDTH
    end
    if not height or height <= 0 or height ~= height then
        height = FALLBACK_CELL_HEIGHT
    end

    return width, height
end

function M.refresh()
    winsize = nil
end

local function create_autocmd()
    api.nvim_create_autocmd('VimResized', {
        callback = function()
            M.refresh()
        end
    })
end

if vim.in_fast_event() then
    vim.schedule(create_autocmd)
else
    create_autocmd()
end

return M
