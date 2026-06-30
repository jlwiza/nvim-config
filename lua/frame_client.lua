-- frame_client.lua
local uv = vim.uv or vim.loop
local M = {}

local HOST = '127.0.0.1'
local PORT = 4242
local PAD_ROWS = 500

local state = {
  current_time = 0,
  current_dim = 0,
  frame_count = 0,
  dim_count = 0,
  frames = {},
}

local painted = false
local last_sig = nil
local ble_buf = nil
local ble_ns = vim.api.nvim_create_namespace 'ble'
local ble_focused = false
local expect_cursor = nil
local playing = false
local play_timer = nil
local last_sent_time = nil
local last_sent_dim = nil

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

-- ── CMD: fire and forget ──────────────────────────────────────────────────────
local function cmd(msg)
  dbg('SEND ' .. msg:gsub('\n', '')) -- ← first line inside cmd, in the file
  local c = uv.new_tcp()
  c:connect(HOST, PORT, function(err)
    if err then
      dbg('cmd error: ' .. tostring(err))
      c:close()
      return
    end
    c:read_start(function(_, _) end)
    c:write(msg)
    c:shutdown(function()
      c:close()
    end)
  end)
end

-- ── column math ───────────────────────────────────────────────────────────────
local function each_word(line, fn)
  for s, w in line:gmatch '()(%S+)' do
    fn(s - 1, w)
  end
end

-- returns a dim index (0-based), 'main' for the main column, or nil
local function col_to_dim(col, line)
  if not line then
    return nil
  end
  local seen_colon = false
  local colon_col = nil
  local dim_idx = 0
  local result = nil
  each_word(line, function(c0, w)
    if result ~= nil then
      return
    end
    if w == ':' then
      seen_colon = true
      colon_col = c0
      return
    end
    if seen_colon then
      local wend = c0 + #w
      if col < wend then
        result = dim_idx
        return
      end
      dim_idx = dim_idx + 1
    end
  end)
  if not seen_colon then
    return nil
  end
  -- cursor left of the ':' → main column, scrub time + snap to owner
  if colon_col and col < colon_col then
    return 'main'
  end
  if result ~= nil then
    return result
  end
  return math.max(0, dim_idx - 1)
end

local function dim_to_col(d, line)
  if not line then
    return 0
  end
  local seen_colon = false
  local dim_idx = 0
  local result = nil
  each_word(line, function(c0, w)
    if result ~= nil then
      return
    end
    if seen_colon then
      if dim_idx == d then
        result = c0
        return
      end
      dim_idx = dim_idx + 1
    end
    if w == ':' then
      seen_colon = true
    end
  end)
  return result or 0
end

-- ── render ─────────────────────────────────────────────────────────────────────
local function tok(v)
  return (v and v ~= 'null') and ('[' .. v .. ']') or '[x]'
end

local function frames_sig()
  local parts = { tostring(state.frame_count), tostring(state.dim_count), tostring(state.current_dim) }
  for i = 1, state.frame_count do
    local fr = state.frames[i]
    parts[#parts + 1] = (fr and fr.uid) or 'n'
    if fr then
      parts[#parts + 1] = table.concat(fr.dims, ',')
    end
  end
  return table.concat(parts, '|')
end

local function update_ble_buf()
  if not ble_buf or not vim.api.nvim_buf_is_valid(ble_buf) then
    return
  end
  local fc = state.frame_count
  local dc = state.dim_count

  local rows = {}
  for i = 1, fc do
    local fr = state.frames[i]
    local row = { tostring(i - 1), tok(fr and fr.uid) }
    for j = 1, dc do
      row[#row + 1] = tok(fr and fr.dims[j])
    end
    rows[#rows + 1] = row
  end
  for i = fc, fc + PAD_ROWS - 1 do
    local row = { tostring(i), 'null' }
    for _ = 1, dc do
      row[#row + 1] = 'null'
    end
    rows[#rows + 1] = row
  end

  local widths = {}
  for _, row in ipairs(rows) do
    for c, cell in ipairs(row) do
      widths[c] = math.max(widths[c] or 0, #cell)
    end
  end
  local function pad(s, w)
    return s .. string.rep(' ', w - #s)
  end

  local lines = {}
  for _, row in ipairs(rows) do
    local parts = { pad(row[1], widths[1]), pad(row[2], widths[2]), ':' }
    for c = 3, #row do
      parts[#parts + 1] = pad(row[c], widths[c])
    end
    lines[#lines + 1] = table.concat(parts, ' ')
  end

  local win = vim.fn.bufwinid(ble_buf)
  local before = (win ~= -1) and vim.api.nvim_win_get_cursor(win) or nil

  vim.api.nvim_buf_set_lines(ble_buf, 0, -1, false, lines)

  vim.api.nvim_buf_clear_namespace(ble_buf, ble_ns, 0, -1)
  for li, line in ipairs(lines) do
    local row = li - 1
    local words = {}
    each_word(line, function(c0, w)
      words[#words + 1] = { col = c0, e = c0 + #w, w = w }
    end)

    if words[2] and words[2].w ~= '[x]' then
      vim.api.nvim_buf_add_highlight(ble_buf, ble_ns, 'DiagnosticInfo', row, words[2].col, words[2].e)
    end

    local colon_i = nil
    for wi, wd in ipairs(words) do
      if wd.w == ':' then
        colon_i = wi
        break
      end
    end
    if colon_i then
      local target = words[colon_i + 1 + state.current_dim]
      if target and target.w ~= '[x]' then
        vim.api.nvim_buf_add_highlight(ble_buf, ble_ns, 'DiagnosticWarn', row, target.col, target.e)
      end
    end
  end

  if win ~= -1 then
    local target_row = state.current_time + 1
    local col = before and before[2] or 0
    local linecount = vim.api.nvim_buf_line_count(ble_buf)
    if target_row >= 1 and target_row <= linecount then
      vim.api.nvim_win_set_cursor(win, { target_row, col })
      expect_cursor = { target_row, col }
    end
  end
end

-- ── POLL ────────────────────────────────────────────────────────────────────
local function poll_loop()
  local c = uv.new_tcp()
  local buf = ''

  local function retry()
    local timer = uv.new_timer()
    timer:start(150, 0, function()
      timer:close()
      poll_loop()
    end)
  end

  c:connect(HOST, PORT, function(err)
    if err then
      dbg('poll connect error: ' .. tostring(err))
      c:close()
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
      if not data then
        c:close()
        retry()
        return
      end

      buf = buf .. data
      if not buf:find '%-%-%-\n' then
        return
      end
      c:close()

      local t = tonumber(buf:match 'current_time=(%d+)')
      local d = tonumber(buf:match 'current_dim=(%d+)')
      local fc = tonumber(buf:match 'frame_count=(%d+)')
      local dc = tonumber(buf:match 'current_dim_count=(%d+)')
      if t == nil then
        retry()
        return
      end

      -- latch: don't let a stale in-flight poll clobber a just-sent value
      local time_changed, dim_changed

      if last_sent_time == nil or t == last_sent_time then
        time_changed = (t ~= state.current_time)
        state.current_time = t
        last_sent_time = nil
      else
        time_changed = false
      end

      if last_sent_dim == nil or (d ~= nil and d == last_sent_dim) then
        dim_changed = (d ~= state.current_dim)
        state.current_dim = d or state.current_dim
        last_sent_dim = nil
      else
        dim_changed = false
      end

      if fc then
        state.frame_count = fc
      end
      if dc then
        state.dim_count = dc
      end

      -- frames: lines like  frame=<t>:<main>:<dim0>:<dim1>:...:owner=<n>
      local frames = {}
      for line in buf:gmatch '[^\n]+' do
        local body = line:match '^frame=(.+)$'
        if body then
          -- strip owner off the end before the positional parse
          local owner = body:match ':owner=(%w+)'
          body = body:gsub(':owner=%w+$', '')

          local fields = {}
          for p in (body .. ':'):gmatch '([^:]*):' do
            fields[#fields + 1] = p
          end
          local idx = tonumber(fields[1])
          if idx ~= nil then
            local main = fields[2]
            local dims = {}
            for i = 3, #fields do
              dims[#dims + 1] = fields[i]
            end
            frames[idx + 1] = {
              uid = (main and main ~= 'null') and main or nil,
              dims = dims,
              owner = (owner and owner ~= 'null') and tonumber(owner) or nil,
            }
          end
        end
      end
      state.frames = frames

      vim.schedule(function()
        local sig = frames_sig()
        if (not painted) or sig ~= last_sig then
          update_ble_buf()
          painted = true
          last_sig = sig
        end

        retry()
      end)
    end)

    c:write 'state\n'
    c:shutdown()
  end)
end

-- ── cursor moved: real user input only ────────────────────────────────────────
local function on_cursor_moved()
  if not ble_buf or not vim.api.nvim_buf_is_valid(ble_buf) then
    return
  end
  local win = vim.fn.bufwinid(ble_buf)
  if win == -1 then
    return
  end
  if vim.api.nvim_get_current_win() ~= win then
    return
  end

  local cursor = vim.api.nvim_win_get_cursor(win)
  if expect_cursor and cursor[1] == expect_cursor[1] and cursor[2] == expect_cursor[2] then
    expect_cursor = nil
    dbg('cursor: ignored own move at row ' .. cursor[1])
    return
  end
  expect_cursor = nil

  if not ble_focused then
    ble_focused = true
    cmd 'focus:lua\n'
  end

  local row = cursor[1]
  local col = cursor[2]
  local t = row - 1
  local line = vim.api.nvim_buf_get_lines(ble_buf, row - 1, row, false)[1] or ''
  local dd = col_to_dim(col, line)

  -- resolve target dim: main-column click snaps to that row's owner lane,
  -- a dim-column click uses that dim directly
  local target_dim
  if dd == 'main' then
    local fr = state.frames[t + 1]
    target_dim = (fr and fr.owner) or state.current_dim
  else
    target_dim = dd
  end
  if target_dim == nil then
    target_dim = state.current_dim
  end

  if t ~= state.current_time or target_dim ~= state.current_dim then
    state.current_time = t
    state.current_dim = target_dim
    last_sent_time = t
    last_sent_dim = target_dim
    cmd('goto:' .. t .. ':' .. target_dim .. '\n') -- ONE atomic message
  end
end

local function active_uid_at(t)
  local fr = state.frames[t + 1]
  return fr and fr.uid and tonumber(fr.uid) or nil
end

local function request(msg, on_reply)
  local c = uv.new_tcp()
  local buf = ''
  c:connect(HOST, PORT, function(err)
    if err then
      c:close()
      return
    end
    c:read_start(function(rerr, data)
      if rerr or not data then
        c:close()
        vim.schedule(function()
          on_reply(buf)
        end)
        return
      end
      buf = buf .. data
      if buf:find '\n' then
        c:close()
        vim.schedule(function()
          on_reply(buf)
        end)
      end
    end)
    c:write(msg)
  end)
end

local function paste_uid()
  if not M.clip then
    dbg 'nothing yanked'
    return
  end
  local win = vim.fn.bufwinid(ble_buf)
  local t = vim.api.nvim_win_get_cursor(win)[1] - 1
  local parent = active_uid_at(t - 1) -- parent is the frame BEFORE the paste point
  if not parent then
    dbg('no parent at t=' .. (t - 1))
    return
  end
  local dim = state.current_dim

  local function go(force)
    local suffix = force and ':force' or ''
    request(string.format('connect:%d:%d:%d:%d%s\n', parent, dim, t, M.clip, suffix), function(reply)
      local victim = reply:match 'conflict:(%d+)'
      if victim and not force then
        if vim.fn.confirm('overwrite uid ' .. victim .. '?', '&Yes\n&No', 2) == 1 then
          go(true)
        end
      else
        -- nudging it so it refreshes and shows it up, prob not necesary
        state.current_time = t
        state.current_dim = dim
        last_sent_time = t
        last_sent_dim = dim
        cmd(string.format('goto:%d:%d\n', t, dim))
      end
    end)
  end
  go(false)
end

local function uid_under_cursor()
  local win = vim.fn.bufwinid(ble_buf)
  local cur = vim.api.nvim_win_get_cursor(win)
  local row, col = cur[1], cur[2]
  local line = vim.api.nvim_buf_get_lines(ble_buf, row - 1, row, false)[1] or ''
  local fr = state.frames[row] -- row == t + 1
  if not fr then
    return nil
  end
  local dd = col_to_dim(col, line)
  if dd == 'main' or dd == nil then
    return fr.uid and tonumber(fr.uid) or nil
  end
  local v = fr.dims[dd + 1] -- dd is 0-based, dims is 1-based
  return (v and v ~= 'null') and tonumber(v) or nil
end

-- ── attach ────────────────────────────────────────────────────────────────────
local function attach(bufnr)
  if ble_buf == bufnr then
    return
  end
  ble_buf = bufnr
  painted = false
  last_sig = nil
  dbg('attached buf ' .. bufnr .. ' [VERSION col-fix-2]')

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
        dbg 'focus:lua (FocusGained)'
      end
    end,
  })
  vim.api.nvim_create_autocmd('FocusLost', {
    callback = function()
      ble_focused = false
      cmd 'focus:editor\n'
      dbg 'focus:editor (FocusLost)'
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

  local opts = { buffer = bufnr, noremap = true, silent = true }
  vim.keymap.set('n', 'w', function()
    cmd 'toggle_pin\n'
    dbg 'toggle_pin'
  end, opts)
  vim.keymap.set('n', '<localleader>n', function()
    cmd 'newframe\n'
    dbg 'newframe'
  end, opts)
  vim.keymap.set('n', 'y', function()
    M.clip = uid_under_cursor()
    dbg('yank ' .. tostring(M.clip))
  end, opts)
  vim.keymap.set('n', '<M-d>', function() -- Alt-D; use '<M-d>' if your term sends Alt
    cmd 'duplicate\n'
    dbg 'duplicate'
  end, opts)
  vim.keymap.set('n', 'p', function()
    paste_uid()
  end, opts)

  local function char_key(i)
    return function()
      cmd('char:' .. i .. '\n')
      dbg('char ' .. i)
    end
  end
  for i = 1, 9 do
    vim.keymap.set('n', '<M-' .. i .. '>', char_key(i - 1), opts)
  end
  vim.keymap.set('n', '<M-0>', char_key(9), opts)
  vim.keymap.set('n', '<M-=>', function()
    cmd 'char:new\n'
    dbg 'char new'
  end, opts)
  vim.keymap.set('n', '<localleader>gp', function()
    cmd 'gameui:addpoint\n'
    dbg 'gameui addpoint'
  end, opts)
  vim.keymap.set('n', '<localleader>gb', function()
    cmd 'gameui:addbbox\n'
    dbg 'gameui addbbox'
  end, opts)
  vim.keymap.set('n', '<localleader>gd', function()
    cmd 'gameui:delete\n'
    dbg 'gameui delete'
  end, opts)

  -- rename the selected element: fetch current label, prompt, send new
  vim.keymap.set('n', '<localleader>gr', function()
    request('gameui:getlabel\n', function(reply)
      local cur = reply:match 'label:([^\n]*)' or ''
      vim.ui.input({ prompt = 'Element label: ', default = cur }, function(input)
        if input and #input > 0 then
          cmd('gameui:rename:' .. input .. '\n')
          dbg('gameui rename -> ' .. input)
        end
      end)
    end)
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
