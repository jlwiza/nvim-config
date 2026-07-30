-- frame_client.lua
--
-- ── transport architecture ───────────────────────────────────────────────────
--   1. ORDERED PIPE — all outbound commands go through a queue with exactly
--      one in-flight connection at a time. The next message is sent only
--      after the server has fully processed the previous one (connection
--      closed = serveClient returned). One connection per message, strictly
--      serialized ⇒ total ordering, no server changes needed.
--   2. GOTO DEBOUNCE — cursor sweeps coalesce: only the SETTLED destination
--      goto goes over the wire (80ms after the cursor stops). Any real
--      command (commit, duplicate, pin...) FLUSHES a pending goto first.
--   3. LATCH EXPIRY — the poll latch absorbs ONE stale in-flight poll after
--      nvim sends a goto; if the server disagrees twice in a row the EDITOR
--      navigated on its own — server is truth, adopt it.
--   4. RESILIENCE — connection-level failures (server closed, restarting)
--      log to /tmp/ble_debug.log only, never the cmdline (no "Press ENTER"
--      storms on editor shutdown). The poll chain retries on EVERY failure
--      path — including mid-read resets — so it survives server death and
--      latches onto the next editor instance without touching the buffer.
--
-- ── display ──────────────────────────────────────────────────────────────────
--   • The warn-highlight follows the PATH: each recorded row highlights its
--     OWNER dim's cell; rows past the recorded end highlight the current
--     dim's cell — the lane the path will extend along.
--   • KEY vs HOLD. The server tags a row with held=<key time> when the row is
--     an inbetween rather than a key (straight off FrameNode.key_time, which
--     reprojectPath stamps). Keys draw BleKey, holds draw BleHold, so the
--     structure of the timing reads at a glance instead of having to be
--     counted. A path built by frontier extension carries no key structure,
--     so every row reads as a key — same as before holds existed.
--   • CELL STATE dims a row, and OUTRANKS key/hold coloring. The server tags
--     each frame with cell=<state> when it isn't plain `own`:
--       pass_through — this element owns nothing here; you're seeing the
--                      element it contributes to, showing through
--       overridden   — this element's frame exists but a contributor above
--                      it has imaging rights, so the art isn't this one's
--     Both render through BleDim (links to Comment by default). Nothing is
--     hidden — the grid still reads the same, it just stops claiming credit
--     for frames it isn't drawing.
--   • Cursor snap is polite: if your cursor already resolves to the current
--     row+dim (anywhere in the cell, or the main column), it stays put. It
--     snaps only when the position changed under you (editor-side D/A/S/W),
--     when you're parked in gutter whitespace (→ nearest cell start), or
--     off-grid. The label region is never touched.
-- ─────────────────────────────────────────────────────────────────────────────

local uv = vim.uv or vim.loop
local M = {}

local HOST = '127.0.0.1'
local PORT = 4242
local PAD_ROWS = 500
local GOTO_SETTLE_MS = 80 -- sweep settle time; below click-perception
local PIPE_TIMEOUT_MS = 1500 -- give up on a hung connection, keep the pipe moving

-- dim group for pass-through / overridden rows. `default = true` so a
-- colorscheme or your own :hi wins over this.
vim.api.nvim_set_hl(0, 'BleDim', { link = 'Comment', default = true })
-- key vs inbetween on the path cell. Same `default = true` contract: drop
--   :hi BleKey guifg=...    :hi BleHold guifg=...
-- anywhere and yours wins.
vim.api.nvim_set_hl(0, 'BleKey', { link = 'DiagnosticWarn', default = true })
vim.api.nvim_set_hl(0, 'BleHold', { link = 'NonText', default = true })

local state = {
  current_time = 0,
  current_dim = 0,
  frame_count = 0,
  dim_count = 0,
  frames = {},
  elements = {},
}

local painted = false
local last_sig = nil
local ble_buf = nil
local ble_ns = vim.api.nvim_create_namespace 'ble'
local ble_focused = false
local expect_cursor = nil
local last_sent_time = nil
local last_sent_dim = nil
local latch_misses = 0

-- ── debug ─────────────────────────────────────────────────────────────────────
local log_path = '/tmp/ble_debug.log'

-- file-only: for connection-level noise (server down, restarts). NEVER prints
-- to the cmdline — a dying server must not trigger "Press ENTER" prompts.
local function dbg_log(msg)
  local f = io.open(log_path, 'a')
  if f then
    f:write(os.date '%H:%M:%S' .. ' ' .. msg .. '\n')
    f:close()
  end
end

-- loud: for things the user should see in the cmdline.
local function dbg(msg)
  dbg_log(msg)
  vim.schedule(function()
    print('[ble] ' .. msg)
  end)
end

-- ── ordered command pipe ──────────────────────────────────────────────────────
-- One in-flight connection at a time. An item is {msg, cb?}; cb receives the
-- reply text (first line) for request-style messages. EOF from the server
-- means serveClient returned, i.e. the command was fully processed — only
-- then does the next item go out.
local out_q = {}
local out_busy = false

local function pump()
  if out_busy then
    return
  end
  local item = table.remove(out_q, 1)
  if not item then
    return
  end
  out_busy = true

  local c = uv.new_tcp()
  local buf = ''
  local done = false
  local guard = uv.new_timer()

  local function finish()
    if done then
      return
    end
    done = true
    guard:stop()
    guard:close()
    if not c:is_closing() then
      c:close()
    end
    out_busy = false
    if item.cb then
      vim.schedule(function()
        item.cb(buf)
      end)
    end
    pump()
  end

  -- a hung/dead server must not stall the pipe forever
  guard:start(PIPE_TIMEOUT_MS, 0, function()
    dbg_log('pipe timeout (dropped: ' .. item.msg:gsub('\n', '') .. ')')
    finish()
  end)

  c:connect(HOST, PORT, function(err)
    if err then
      dbg_log('pipe connect error: ' .. tostring(err) .. ' (dropped: ' .. item.msg:gsub('\n', '') .. ')')
      finish()
      return
    end
    c:read_start(function(rerr, data)
      if rerr or not data then
        finish() -- EOF: server done processing this command
        return
      end
      buf = buf .. data
      if item.cb and buf:find '\n' then
        finish() -- got the reply line; don't wait for EOF
      end
    end)
    c:write(item.msg)
    c:shutdown() -- half-close: done writing, wait for server reply/EOF
  end)
end

local function enqueue(msg, cb)
  out_q[#out_q + 1] = { msg = msg, cb = cb }
  pump()
end

-- ── goto debounce ─────────────────────────────────────────────────────────────
-- Cursor sweeps emit one goto per crossed cell; only the destination matters.
-- pending_goto holds the latest; the timer sends it once the cursor settles.
local goto_timer = nil
local pending_goto = nil

local function flush_goto()
  if not pending_goto then
    return
  end
  local g = pending_goto
  pending_goto = nil
  if goto_timer then
    goto_timer:stop()
  end
  enqueue('goto:' .. g.t .. ':' .. g.d .. '\n')
end

local function send_goto(t, d)
  pending_goto = { t = t, d = d }
  if not goto_timer then
    goto_timer = uv.new_timer()
  end
  goto_timer:stop()
  goto_timer:start(GOTO_SETTLE_MS, 0, function()
    flush_goto()
  end)
end

-- public send functions: any real command flushes a pending goto FIRST, so
-- ordering between navigation and actions is preserved even mid-debounce.
local function cmd(msg)
  dbg_log('send ' .. msg:gsub('\n', ''))
  flush_goto()
  enqueue(msg)
end

local function request(msg, on_reply)
  dbg_log('send ' .. msg:gsub('\n', ''))
  flush_goto()
  enqueue(msg, on_reply)
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

-- ── labels ────────────────────────────────────────────────────────────────────
-- '|' and TAB are structural: '|' is the join/split delimiter of the label
-- region, TAB is the grid/label separator. A label containing either desyncs
-- the positional gid mapping in apply_edits, so renames land on the wrong
-- element. Sanitize everything outbound. (Mirror this in setLabel on the Zig
-- side too — this only covers labels typed through vim.)
local function sanitize_label(s)
  return (s:gsub('[|\t]', '-'))
end

-- ── render ─────────────────────────────────────────────────────────────────────
local function tok(v)
  return (v and v ~= 'null') and ('[' .. v .. ']') or '[x]'
end

local function frames_sig()
  local parts = {
    tostring(state.frame_count),
    tostring(state.dim_count),
    tostring(state.current_dim),
    tostring(state.current_time),
  }
  for i = 1, state.frame_count do
    local fr = state.frames[i]
    parts[#parts + 1] = (fr and fr.uid) or 'n'
    if fr then
      parts[#parts + 1] = table.concat(fr.dims, ',')
      parts[#parts + 1] = tostring(fr.owner)
      -- cell state changes nothing about the TEXT, only the highlight — but a
      -- repaint is how highlights get reapplied, so it has to be in the sig or
      -- toggling a contributor leaves the old dimming on screen.
      parts[#parts + 1] = fr.cell or 'own'
      -- same reasoning for key/hold: a retime changes only colors, so without
      -- this the grid keeps yesterday's key structure painted on it.
      parts[#parts + 1] = tostring(fr.held or 'k')
    end
  end
  if state.elements then
    for _, e in ipairs(state.elements) do
      parts[#parts + 1] = 'e' .. e.gid .. ',' .. e.label
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
  for ri, row in ipairs(rows) do
    local parts = { pad(row[1], widths[1]), pad(row[2], widths[2]), ':' }
    for c = 3, #row do
      parts[#parts + 1] = pad(row[c], widths[c])
    end
    local line = table.concat(parts, ' ')

    -- current frame's row: append element names after a TAB. The grid is all
    -- spaces/brackets/digits, so a tab is a delimiter that can never collide
    -- with grid padding (triple-spaces occur *inside* the padded grid).
    if (ri - 1) == state.current_time and state.elements and #state.elements > 0 then
      local names = {}
      for _, e in ipairs(state.elements) do
        names[#names + 1] = e.label
      end
      line = line .. '\t' .. table.concat(names, ' | ')
    end

    lines[#lines + 1] = line
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

    local fr = state.frames[li]
    -- not `own` ⇒ this element isn't the one drawing here. Same text, dimmer.
    local dimmed = (fr ~= nil) and (fr.cell ~= nil) and (fr.cell ~= 'own')

    if words[2] and words[2].w ~= '[x]' then
      vim.api.nvim_buf_add_highlight(ble_buf, ble_ns, dimmed and 'BleDim' or 'DiagnosticInfo', row, words[2].col, words[2].e)
    end

    local colon_i = nil
    for wi, wd in ipairs(words) do
      if wd.w == ':' then
        colon_i = wi
        break
      end
    end
    if colon_i then
      -- highlight FOLLOWS THE PATH: a recorded row lights its owner dim's
      -- cell (the traversal reads [1] [2] [3] across lanes); past the
      -- recorded end, light the current dim's cell — the lane the path
      -- will extend along.
      local hl_dim = (fr and fr.owner) or state.current_dim
      local target = words[colon_i + 1 + hl_dim]
      if target and target.w ~= '[x]' then
        -- KEY or HOLD. `held` absent ⇒ this row is a key (a row with no key
        -- structure at all, e.g. the padding rows past frame_count, also
        -- reads as a key — same as before holds existed). Dimming wins over
        -- both: what's on screen isn't this element's to claim either way.
        local is_key = (fr == nil) or (fr.held == nil)
        local hl = dimmed and 'BleDim' or (is_key and 'BleKey' or 'BleHold')
        vim.api.nvim_buf_add_highlight(ble_buf, ble_ns, hl, row, target.col, target.e)
      end
    end
  end

  if win ~= -1 then
    local target_row = state.current_time + 1
    local linecount = vim.api.nvim_buf_line_count(ble_buf)
    if target_row >= 1 and target_row <= linecount then
      local full_line = lines[target_row] or ''
      local sep = full_line:find('\t', 1, true)
      local grid_line = sep and full_line:sub(1, sep - 1) or full_line

      -- polite snap: leave the cursor alone if it already resolves to the
      -- current row+dim (anywhere inside the cell, or the main column), or
      -- if it's in the label region. Snap only when the position changed
      -- under it (editor-side navigation), when it's parked on gutter
      -- whitespace (→ nearest cell start), or when it's off this row.
      local stay = false
      if before and before[1] == target_row then
        local bc = before[2]
        if sep and bc >= sep - 1 then
          stay = true -- label region: never fight label editing
        else
          local bd = col_to_dim(bc, grid_line)
          local ch = grid_line:sub(bc + 1, bc + 1) -- bc is 0-based
          local on_word = ch ~= '' and ch ~= ' '
          if on_word and (bd == 'main' or bd == state.current_dim) then
            stay = true
          end
        end
      end

      if not stay then
        local target_col = dim_to_col(state.current_dim, grid_line)
        if not before or before[1] ~= target_row or before[2] ~= target_col then
          vim.api.nvim_win_set_cursor(win, { target_row, target_col })
          expect_cursor = { target_row, target_col }
        end
      end
    end
  end

  -- a server-driven repaint is never a user edit: keep the buffer clean so the
  -- modified-guard only trips on genuine unsaved typing (nvim_buf_set_lines
  -- above re-marks it modified, so we must clear here).
  vim.bo[ble_buf].modified = false
end

-- ── poll ────────────────────────────────────────────────────────────────────
-- Polls use their own throwaway connections, NOT the ordered pipe: "state" is
-- read-only, so interleaving with commands is harmless, and keeping it off the
-- pipe means a slow blob can never delay a user action.
--
-- EVERY failure path retries — connect refused, mid-read reset, EOF — so the
-- chain survives server death and latches onto the next editor instance.
local function poll_loop()
  local c = uv.new_tcp()
  local buf = ''

  local function retry(ms)
    local timer = uv.new_timer()
    timer:start(ms or 150, 0, function()
      timer:close()
      poll_loop()
    end)
  end

  c:connect(HOST, PORT, function(err)
    if err then
      -- server down/restarting: quiet, patient retry
      c:close()
      retry(500)
      return
    end

    c:read_start(function(rerr, data)
      if rerr then
        -- mid-read reset (server died with our connection open): the chain
        -- must survive this too, or the grid goes dead until file reopen
        dbg_log('poll read error: ' .. tostring(rerr))
        c:close()
        retry(500)
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

      -- latch: absorb ONE stale in-flight poll after we send a goto; but if
      -- the server disagrees twice in a row, the EDITOR navigated on its own
      -- (D/A/S/W keys, playback...) — server is truth, drop the latch and
      -- adopt. Without this the latch sticks forever on editor-side moves,
      -- local state goes stale, and the next cursor event in nvim "corrects"
      -- the server with a goto built from stale state (the dim snap-back).
      local t_ok = (last_sent_time == nil) or (t == last_sent_time)
      local d_ok = (last_sent_dim == nil) or (d ~= nil and d == last_sent_dim)

      if t_ok and d_ok then
        state.current_time = t
        state.current_dim = d or state.current_dim
        last_sent_time, last_sent_dim, latch_misses = nil, nil, 0
      else
        latch_misses = latch_misses + 1
        if latch_misses >= 2 then
          state.current_time = t
          state.current_dim = d or state.current_dim
          last_sent_time, last_sent_dim, latch_misses = nil, nil, 0
        end
      end

      if fc then
        state.frame_count = fc
      end
      if dc then
        state.dim_count = dc
      end

      -- frames: lines like  frame=<t>:<main>:<dim0>:...:owner=<n>[:cell=<s>][:held=<kt>]
      --
      -- TRAILING ATTRS ARE ORDER-FREE. Everything after the dim columns is
      -- key=value; strip them all off the end before the positional parse.
      -- The old code stripped ':owner=%w+$' anchored, so appending ANY new
      -- fact after owner silently turned owner into a dim column and shifted
      -- the whole grid. This loop can't be broken that way — add facts on the
      -- Zig side in any order and they land in `attrs`.
      local frames = {}
      for line in buf:gmatch '[^\n]+' do
        local body = line:match '^frame=(.+)$'
        if body then
          local attrs = {}
          while true do
            local k, v = body:match ':(%w+)=([%w_]+)$'
            if not k then
              break
            end
            attrs[k] = v
            body = body:gsub(':%w+=[%w_]+$', '')
          end

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
              owner = (attrs.owner and attrs.owner ~= 'null') and tonumber(attrs.owner) or nil,
              -- absent ⇒ this element owns and draws this frame
              cell = attrs.cell or 'own',
              -- absent ⇒ this row IS a key; otherwise the TIME of the key
              -- that governs it (this row is one of its inbetweens)
              held = attrs.held and tonumber(attrs.held) or nil,
            }
          end
        end
      end
      state.frames = frames

      -- current frame's game elements (in-buffer label region)
      -- [%w_]+ not %w+: Zig @tagName gives snake_case for snake_case enum
      -- tags, and %w drops the underscore — the element silently vanished,
      -- and the POSITIONAL gid mapping in apply_edits then shifted every
      -- rename after it onto the wrong element. (Same reason cell= values
      -- like pass_through are matched with [%w_]+ above.)
      local elements = {}
      for gid, typ, lbl in buf:gmatch 'element=(%d+):([%w_]+):([^\n]*)' do
        elements[#elements + 1] = { gid = tonumber(gid), type = typ, label = lbl }
      end
      state.elements = elements

      vim.schedule(function()
        -- don't repaint over in-progress edits; wait until :w clears modified
        if ble_buf and vim.api.nvim_buf_is_valid(ble_buf) and vim.bo[ble_buf].modified then
          retry()
          return
        end
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

-- ── apply edits on :w ─────────────────────────────────────────────────────────
-- parse the current frame's label region and push renames for anything changed.
-- only the current-time row carries labels, so that's the only row we diff.
local function looks_like_grid_token(s)
  -- reject anything that could be a mis-captured grid cell rather than a label
  return s == '' or s == 'null' or s == ':' or s:match '^%[.-%]$' ~= nil
end

local function apply_edits()
  if not ble_buf or not vim.api.nvim_buf_is_valid(ble_buf) then
    return
  end
  local row = state.current_time + 1
  local line = vim.api.nvim_buf_get_lines(ble_buf, row - 1, row, false)[1] or ''
  local sep = line:find('\t', 1, true) -- TAB before the names (grid has no tabs)
  if not sep then
    return
  end
  local region = line:sub(sep + 1)

  local i = 1
  for name in (region .. ' | '):gmatch '(.-) | ' do
    name = sanitize_label(vim.trim(name))
    local e = state.elements[i]
    -- only rename as many as we actually have, and never send a grid token
    if e and not looks_like_grid_token(name) and name ~= e.label then
      cmd('gameui:renamegid:' .. e.gid .. ':' .. name .. '\n')
      dbg('rename gid=' .. e.gid .. ' -> ' .. name)
      e.label = name -- keep local state in sync so the next repaint matches
    end
    i = i + 1
    if i > #state.elements then
      break
    end
  end
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
    dbg_log('cursor: ignored own move at row ' .. cursor[1])
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

  -- cursor over the label region on the current row → select that element
  if t == state.current_time and state.elements and #state.elements > 0 then
    local sep = line:find('\t', 1, true) -- TAB before the names
    if sep and col >= sep then
      local region = line:sub(sep + 1)
      local base = sep -- 0-based col where names start (tab is 1 char)
      local idx, cur = 1, base
      for name in (region .. ' | '):gmatch '(.-) | ' do
        local nend = cur + #name
        if col <= nend then
          if state.elements[idx] then
            cmd('gameui:select:' .. state.elements[idx].gid .. '\n')
          end
          break
        end
        cur = nend + 3 -- skip ' | '
        idx = idx + 1
      end
      return
    end
  end

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
    -- local state + latch update IMMEDIATELY (highlight follows the cursor,
    -- in-flight polls can't snap us back) — but the wire only sees the
    -- SETTLED destination, via the debounce.
    state.current_time = t
    state.current_dim = target_dim
    last_sent_time = t
    last_sent_dim = target_dim
    send_goto(t, target_dim)
  end
end

local function active_uid_at(t)
  local fr = state.frames[t + 1]
  return fr and fr.uid and tonumber(fr.uid) or nil
end

local function paste_uid()
  if not M.clip then
    dbg 'nothing yanked'
    return
  end
  local win = vim.fn.bufwinid(ble_buf)
  local t = vim.api.nvim_win_get_cursor(win)[1] - 1
  local parent = active_uid_at(t - 1) -- parent is the frame before the paste point
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
        -- nudge so the new connection shows up; goes through cmd so it's
        -- ordered AFTER the connect on the pipe
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

  -- label-region guard: on the current row, label words after the TAB would
  -- count as dim columns in col_to_dim, and the dim_idx-1 fallback could hand
  -- you the LAST dim's uid while yanking from a label. In the label region →
  -- nil; otherwise trim the line so the grid math only sees the grid.
  local sep = line:find('\t', 1, true)
  if sep then
    if col >= sep then
      return nil
    end
    line = line:sub(1, sep - 1)
  end

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
  dbg('attached buf ' .. bufnr .. ' [version resilient-1]')

  -- make :w flush edits to the editor instead of writing a file
  vim.bo[bufnr].buftype = 'acwrite'

  -- timeline is a grid; never soft-wrap it, or wide rows (with labels) spill
  -- onto a second visual line
  do
    local win = vim.fn.bufwinid(bufnr)
    if win ~= -1 then
      vim.wo[win].wrap = false
    end
  end
  vim.api.nvim_create_autocmd('BufWriteCmd', {
    buffer = bufnr,
    callback = function()
      apply_edits() -- sends renames and patches e.label locally
      -- redraw from (patched) state, THEN clear modified — set_lines inside
      -- update_ble_buf re-marks the buffer modified, so clearing must come after.
      last_sig = nil
      update_ble_buf()
      vim.bo[bufnr].modified = false
    end,
  })

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
        dbg_log 'focus:lua (FocusGained)'
      end
    end,
  })
  vim.api.nvim_create_autocmd('FocusLost', {
    callback = function()
      ble_focused = false
      cmd 'focus:editor\n'
      dbg_log 'focus:editor (FocusLost)'
    end,
  })
  vim.api.nvim_create_autocmd('WinEnter', {
    buffer = bufnr,
    callback = function()
      ble_focused = true
      cmd 'focus:lua\n'
      dbg_log 'focus:lua (WinEnter)'
    end,
  })
  vim.api.nvim_create_autocmd('WinLeave', {
    buffer = bufnr,
    callback = function()
      ble_focused = false
      cmd 'focus:editor\n'
      dbg_log 'focus:editor (WinLeave)'
    end,
  })

  local opts = { buffer = bufnr, noremap = true, silent = true }
  vim.keymap.set('n', 'w', function()
    request('toggle_pin\n', function(reply)
      local pin = reply:match 'pin:(%w+)' or '?'
      dbg('pin ' .. pin) -- shows "[ble] pin on" / "[ble] pin off" in cmdline
    end)
  end, opts)
  vim.keymap.set('n', '<localleader>n', function()
    cmd 'newframe\n'
    dbg_log 'newframe'
  end, opts)
  vim.keymap.set('n', 'y', function()
    M.clip = uid_under_cursor()
    dbg('yank ' .. tostring(M.clip))
  end, opts)
  vim.keymap.set('n', '<M-d>', function() -- Alt-d
    cmd 'duplicate\n'
    dbg_log 'duplicate'
  end, opts)
  vim.keymap.set('n', 'p', function()
    paste_uid()
  end, opts)

  vim.keymap.set('n', '<localleader>ge', function()
    -- select whatever name the cursor is on, then prompt
    local win = vim.fn.bufwinid(ble_buf)
    local cur = vim.api.nvim_win_get_cursor(win)
    local t = cur[1] - 1
    if t ~= state.current_time then
      return
    end
    request('gameui:getlabel\n', function(reply)
      local curname = reply:match 'label:([^\n]*)' or ''
      vim.ui.input({ prompt = 'element label: ', default = curname }, function(input)
        if input and #input > 0 then
          cmd('gameui:rename:' .. sanitize_label(input) .. '\n')
        end
      end)
    end)
  end, opts)

  local function char_key(i)
    return function()
      cmd('char:' .. i .. '\n')
      dbg_log('char ' .. i)
    end
  end
  for i = 1, 9 do
    vim.keymap.set('n', '<M-' .. i .. '>', char_key(i - 1), opts)
  end
  vim.keymap.set('n', '<M-0>', char_key(9), opts)
  vim.keymap.set('n', '<M-=>', function()
    cmd 'char:new\n'
    dbg_log 'char new'
  end, opts)
  vim.keymap.set('n', '<localleader>gs', function()
    cmd 'gameui:addscript\n'
    dbg 'gameui addscript'
  end, opts)
  vim.keymap.set('n', '<localleader>gp', function()
    cmd 'gameui:addpoint\n'
    dbg_log 'gameui addpoint'
  end, opts)
  vim.keymap.set('n', '<localleader>gb', function()
    cmd 'gameui:addbbox\n'
    dbg_log 'gameui addbbox'
  end, opts)
  vim.keymap.set('n', '<localleader>gd', function()
    cmd 'gameui:delete\n' -- this frame only; stops carry-forward
    dbg 'gameui delete (frame)'
  end, opts)
  vim.keymap.set('n', '<localleader>gD', function()
    cmd 'gameui:deleteall\n' -- every frame, the full nuke
    dbg 'gameui delete (ALL frames)'
  end, opts)

  -- rename the selected element: fetch current label, prompt, send new
  vim.keymap.set('n', '<localleader>gr', function()
    request('gameui:getlabel\n', function(reply)
      local cur = reply:match 'label:([^\n]*)' or ''
      vim.ui.input({ prompt = 'element label: ', default = cur }, function(input)
        if input and #input > 0 then
          cmd('gameui:rename:' .. sanitize_label(input) .. '\n')
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
      '[ble] time=%d dim=%d frames=%d dims=%d focused=%s buf=%s queue=%d busy=%s',
      state.current_time,
      state.current_dim,
      state.frame_count,
      state.dim_count,
      tostring(ble_focused),
      tostring(ble_buf),
      #out_q,
      tostring(out_busy)
    )
  )
end

return M
