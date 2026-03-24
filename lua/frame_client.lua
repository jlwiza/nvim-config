-- frame_client.lua
-- Three separate responsibilities:
--   1. POLL  — always running, reads state, updates local truth, never writes
--   2. CMD   — fire and forget, write only, no callback, no readback
--   3. FOCUS — determines whose commands are authoritative

local uv = vim.uv or vim.loop
local M = {}

local HOST = '127.0.0.1'
local PORT = 4242

-- ── shared state (poll is the only thing that writes to this) ─────────────────
local state = {
  current_time = 0,
  current_dim = 0,
  frame_count = 0,
  dim_count = 0,
  frames = {}, -- [n] = { uid=hex_str, dims={...} }
}

local ble_buf = nil
local ble_ns = vim.api.nvim_create_namespace 'ble'
local ble_focused = false
local moving = false -- true while poll is repositioning cursor
local playing = false
local play_timer = nil

-- ── debug ─────────────────────────────────────────────────────────────────────
local log_path = '/tmp/ble_debug.log'
local function dbg(msg)
  local f = io.open(log_path, 'a')
  if f then
    f:write(os.date '%H:%M:%S' .. ' ' .. msg .. '\n')
    f:close()
  end
  vim.schedule(function()
    print('[ble] ' .. msg)
  end)
end

-- ── CMD: fire and forget, no callback ─────────────────────────────────────────
local function cmd(msg)
  local c = uv.new_tcp()
  c:connect(HOST, PORT, function(err)
    if err then
      dbg('cmd error: ' .. tostring(err))
      c:close()
      return
    end
    c:read_start(function(_, _) end) -- drain so server doesn't block
    c:write(msg)
    c:shutdown(function()
      c:close()
    end)
  end)
end

-- ── helpers ──────────────────────────────────────────────────────────────────

-- word N in a line starts at col N * (TOKEN_WIDTH+1)
-- we use fixed-width tokens so col math is simple
-- col_to_dim: cursor col → dim index
-- line layout: frame_idx  main  dim0  dim1 ...
--              word 0      1     2     3
-- dim index = word_index - 2  (word 0 and 1 are not dims)
local function col_to_dim(col, line)
  if not line then
    return 0
  end
  local pos = 0
  local word_idx = 0
  for w in line:gmatch '%S+' do
    local wend = pos + #w
    if col <= wend then
      return math.max(0, word_idx - 2)
    end
    pos = wend + 1
    word_idx = word_idx + 1
  end
  return math.max(0, word_idx - 2)
end

-- dim_to_col: dim index → start col of that word
-- dim 0 → word 2, dim 1 → word 3, etc.
local function dim_to_col(d, line)
  if not line then
    return 0
  end
  local target = d + 2 -- skip frame_idx and main
  local i = 0
  local pos = 0
  for w in line:gmatch '%S+' do
    if i == target then
      return pos
    end
    pos = pos + #w + 1
    i = i + 1
  end
  return pos
end

-- rewrite .ble buffer: one line per frame, hex uids space-separated
-- frame_uid dim0_uid dim1_uid ...
local function update_ble_buf()
  if not ble_buf or not vim.api.nvim_buf_is_valid(ble_buf) then
    return
  end
  local fc = state.frame_count
  local dc = state.dim_count
  local function tok(v)
    return (v and v ~= 'null') and ('0x' .. v) or 'null'
  end
  local lines = {}
  for i = 1, fc do
    local fr = state.frames[i]
    local main = tok(fr and fr.uid)
    local dims = {}
    for j = 1, dc do
      table.insert(dims, tok(fr and fr.dims[j]))
    end
    table.insert(lines, tostring(i - 1) .. ' ' .. main .. ' : ' .. table.concat(dims, ' '))
  end
  -- 500 line buffer past end for new frame entry
  for i = fc, fc + 499 do
    local dims = {}
    for _ = 1, dc do
      table.insert(dims, 'null')
    end
    table.insert(lines, tostring(i) .. ' null : ' .. table.concat(dims, ' '))
  end
  moving = true
  vim.api.nvim_buf_set_lines(ble_buf, 0, -1, false, lines)

  -- highlights: main uid and selected dim column
  vim.api.nvim_buf_clear_namespace(ble_buf, ble_ns, 0, -1)
  for i, line in ipairs(lines) do
    local row = i - 1
    -- highlight main token (word 1, after frame index)
    local main_s, main_e = line:find('%S+', line:find ' ' + 1)
    if main_s then
      vim.api.nvim_buf_add_highlight(ble_buf, ble_ns, 'DiagnosticInfo', row, main_s - 1, main_e)
    end
    -- highlight selected dim column (word 3 + current_dim, skipping ' : ')
    local colon = line:find ': '
    if colon then
      local after = colon + 2
      local wi = 0
      local s, e = after, after
      while true do
        local ws, we = line:find('%S+', s)
        if not ws then
          break
        end
        if wi == state.current_dim then
          vim.api.nvim_buf_add_highlight(ble_buf, ble_ns, 'DiagnosticWarn', row, ws - 1, we)
          break
        end
        wi = wi + 1
        s = we + 1
      end
    end
  end

  vim.schedule(function()
    vim.schedule(function()
      moving = false
    end)
  end)
end

-- ── POLL: one in flight at a time, updates state{}, moves cursor if needed ────
local function poll_loop()
  local c = uv.new_tcp()
  local buf = ''
  c:connect(HOST, PORT, function(err)
    if err then
      dbg('poll connect error: ' .. tostring(err))
      c:close()
      -- retry after delay
      local t = uv.new_timer()
      t:start(500, 0, function()
        t:close()
        poll_loop()
      end)
      return
    end

    c:read_start(function(rerr, data)
      if rerr then
        c:close()
        return
      end
      if data then
        buf = buf .. data
        if not buf:find '%-%-%-\n' then
          return
        end
        c:close()

        -- parse state
        local t = tonumber(buf:match 'current_time=(%d+)')
        local d = tonumber(buf:match 'current_dim=(%d+)')
        local fc = tonumber(buf:match 'frame_count=(%d+)')
        local dc = tonumber(buf:match 'current_dim_count=(%d+)')
        if t ~= nil then
          local time_changed = (t ~= state.current_time)
          local dim_changed = (d ~= state.current_dim)
          state.current_time = t
          state.current_dim = d or state.current_dim
          if fc then
            state.frame_count = fc
          end
          if dc then
            state.dim_count = dc
          end

          -- parse frames table: frame_begin + dim_option lines
          local frames = {}
          local fi = 0
          for line in buf:gmatch '[^\n]+' do
            local uid = line:match '^frame_begin=(%x+)'
            if uid then
              fi = fi + 1
              frames[fi] = { uid = uid, dims = {} }
            end
            local dim_val = line:match '^dim_option=(.+)'
            if dim_val and fi > 0 then
              table.insert(frames[fi].dims, dim_val)
            end
          end
          state.frames = frames

          vim.schedule(function()
            dbg(string.format('poll: time=%d focused=%s changed=%s', t, tostring(ble_focused), tostring(time_changed)))

            -- only rewrite buf when editor drives (safe, no feedback loop)
            if not ble_focused and (time_changed or dim_changed) then
              update_ble_buf()
            end

            -- only move cursor if .ble is NOT focused and state changed
            if not ble_focused and (time_changed or dim_changed) then
              if ble_buf and vim.api.nvim_buf_is_valid(ble_buf) then
                local win = vim.fn.bufwinid(ble_buf)
                if win ~= -1 then
                  local lc = vim.api.nvim_buf_line_count(ble_buf)
                  local row = math.min(t + 1, lc)
                  local line = vim.api.nvim_buf_get_lines(ble_buf, row - 1, row, false)[1] or ''
                  local col = dim_to_col(d or 0, line)
                  moving = true
                  vim.api.nvim_win_set_cursor(win, { row, col })
                  dbg('poll moved cursor to line ' .. row .. ' col ' .. col)
                  vim.schedule(function()
                    moving = false
                  end)
                end
              end
            end

            -- next poll only after this one fully processed
            local timer = uv.new_timer()
            timer:start(150, 0, function()
              timer:close()
              poll_loop()
            end)
          end)
        else
          local timer = uv.new_timer()
          timer:start(150, 0, function()
            timer:close()
            poll_loop()
          end)
        end
      else
        -- EOF without terminator
        c:close()
        local timer = uv.new_timer()
        timer:start(150, 0, function()
          timer:close()
          poll_loop()
        end)
      end
    end)

    c:write 'state\n'
    c:shutdown()
  end)
end

-- ── play ──────────────────────────────────────────────────────────────────────

local function stop_play()
  if play_timer then
    play_timer:stop()
    play_timer:close()
    play_timer = nil
  end
  playing = false
  dbg 'play stopped'
end

local function start_play(fps)
  if playing then
    stop_play()
    return
  end
  playing = true
  fps = fps or 12
  dbg('play start ' .. fps .. 'fps')
  play_timer = uv.new_timer()
  play_timer:start(0, math.floor(1000 / fps), function()
    vim.schedule(function()
      local next_t = state.current_time + 1
      if next_t >= state.frame_count then
        next_t = 0
      end
      state.current_time = next_t
      cmd(string.format('frame:%d\n', next_t))
    end)
  end)
end

-- ── cursor moved in .ble: user is driving, fire cmd, don't readback ───────────
local function on_cursor_moved()
  if moving then
    return
  end
  if not ble_focused then
    return
  end
  local win = vim.fn.bufwinid(ble_buf)
  if win == -1 then
    return
  end
  local cursor = vim.api.nvim_win_get_cursor(win)
  local row = cursor[1]
  local col = cursor[2]
  local t = row - 1
  local line = vim.api.nvim_buf_get_lines(ble_buf, row - 1, row, false)[1] or ''
  local d = col_to_dim(col, line)
  local time_changed = (t ~= state.current_time)
  local dim_changed = (d ~= state.current_dim)
  if time_changed then
    state.current_time = t
    dbg(string.format('cursor cmd: frame:%d', t))
    cmd(string.format('frame:%d\n', t))
  end
  if dim_changed then
    state.current_dim = d
    dbg(string.format('cursor cmd: dim:%d', d))
    cmd(string.format('dim:%d\n', d))
  end
end

-- ── attach ────────────────────────────────────────────────────────────────────
local function attach(bufnr)
  if ble_buf == bufnr then
    return
  end
  ble_buf = bufnr
  dbg('attached buf ' .. bufnr)

  vim.api.nvim_create_autocmd('CursorMoved', {
    buffer = bufnr,
    callback = on_cursor_moved,
  })
  vim.api.nvim_create_autocmd('FocusGained', {
    callback = function()
      local win = vim.fn.bufwinid(ble_buf)
      if win ~= -1 and win == vim.api.nvim_get_current_win() then
        ble_focused = true
        cmd 'focus:lua\n'
        dbg 'focus:lua'
      end
    end,
  })
  vim.api.nvim_create_autocmd('FocusLost', {
    callback = function()
      ble_focused = false
      cmd 'focus:editor\n'
      dbg 'focus:editor'
    end,
  })
  vim.api.nvim_create_autocmd('WinEnter', {
    buffer = bufnr,
    callback = function()
      ble_focused = true
      cmd 'focus:lua\n'
      dbg 'focus:lua (WinEnter)'
    end,
  })
  vim.api.nvim_create_autocmd('WinLeave', {
    buffer = bufnr,
    callback = function()
      ble_focused = false
      cmd 'focus:editor\n'
      dbg 'focus:editor (WinLeave)'
    end,
  })

  -- keymaps (buffer-local)
  local opts = { buffer = bufnr, noremap = true, silent = true }
  vim.keymap.set('n', '<localleader>p', function()
    start_play(12)
  end, opts)
  vim.keymap.set('n', '<localleader>P', function()
    stop_play()
  end, opts)
  vim.keymap.set('n', 'q', function()
    stop_play()
  end, opts)

  poll_loop()
end

-- ── setup ─────────────────────────────────────────────────────────────────────
function M.setup()
  vim.api.nvim_create_autocmd('BufEnter', {
    pattern = '*.ble',
    callback = function(ev)
      attach(ev.buf)
    end,
  })
end

function M.debug()
  print(
    string.format(
      '[ble] time=%d dim=%d frames=%d dims=%d focused=%s buf=%s',
      state.current_time,
      state.current_dim,
      state.frame_count,
      state.dim_count,
      tostring(ble_focused),
      tostring(ble_buf)
    )
  )
end

function M.play(fps)
  start_play(fps)
end
function M.stop()
  stop_play()
end

return M
