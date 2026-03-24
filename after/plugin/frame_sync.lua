-- Simple, stupid, works: sends cursor row/col to 127.0.0.1:4242 on CursorMoved.
-- Loads automatically because it's in after/plugin/.

-- Guard so we don't double-register if you reload config
if vim.g.frame_sync_loaded then
  return
end
vim.g.frame_sync_loaded = true

-- Toggle enable/disable (default: enabled)
vim.g.frame_sync_enabled = true

local uv = vim.loop -- libuv handle

local function send_data(msg)
  if not vim.g.frame_sync_enabled then
    return
  end
  local sock = uv.new_tcp()
  sock:connect('127.0.0.1', 4242, function(err)
    if err then
      -- No server? Ignore quietly. This is meant to be fire-and-forget.
      sock:close()
      return
    end
    sock:write(msg, function()
      sock:shutdown()
      sock:close()
    end)
  end)
end

-- Send both frame (col) and dim (row) on every cursor move
local function on_cursor_moved()
  local pos = vim.api.nvim_win_get_cursor(0) -- {row, col}
  local row, col = pos[1], pos[2]
  -- Zero-based, like your app expects? If you want 0-based, subtract 1:
  -- row, col = row - 1, col
  send_data('frame:' .. tostring(col) .. '\n')
  send_data('dim:' .. tostring(row) .. '\n')
end

-- Create the autocmd once
vim.api.nvim_create_autocmd('CursorMoved', {
  group = vim.api.nvim_create_augroup('FrameSyncGroup', { clear = true }),
  callback = on_cursor_moved,
})

-- Handy toggles:
vim.api.nvim_create_user_command('FrameSyncEnable', function()
  vim.g.frame_sync_enabled = true
end, {})
vim.api.nvim_create_user_command('FrameSyncDisable', function()
  vim.g.frame_sync_enabled = false
end, {})
