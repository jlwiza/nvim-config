-- bltool.lua — the .bltool file surface for BL_Editor
--
-- Opening any *.bltool file (the .ble pattern) turns that buffer into the
-- live tool surface: click-drag sliders, < n > spinners, [x] toggles, the
-- element list with connection arrows, HSV with a true-color swatch, rel
-- sets. Contents are rendered from the server's "tool" blob and never
-- written to disk — the file is just the anchor you open.
--
-- Protocol contract (matches frameServer.zig): ONE command per connection,
-- newline-terminated. Sends are SERIALIZED — exactly one command connection
-- in flight; the next is sent only after the previous connection closes.
-- Merge the send queue with frame_client.lua's if you want a single pipe.
--
-- Usage:
--   require("bltool").setup()   -- registers the *.bltool autocmds
--   :e tools.bltool             -- open the surface
--
-- Keys inside the buffer:
--   <LeftMouse>/<LeftDrag>  grab a slider / hit a spinner arrow / toggle / [Set]
--   h / l                   nudge control under cursor (slider step, spinner ±1)
--   H / L                   big nudge
--   <CR> / <Space>          toggle a checkbox, press [Set]
--   c                       on an element row: CONNECT it to a target element
--                           (it becomes a contributor: motion sums, newest
--                           gets imaging rights)
--   x                       on an element row: DISCONNECT it from a target
--   t                       on an element row: mute/unmute its contribution
--   r                       refresh from server
--
-- If `c` lands you in E21 ("Cannot make changes, 'modifiable' is off") then the
-- buffer-local keymaps are absent and vim ran its own change operator. That
-- used to be attach()'s early return — see the note there. `:verbose nmap c`
-- tells you whether the mapping exists.
--
-- NOTE: elem:connect / tool:set / gameui:* are all gated server-side behind
-- focus:lua. frame_client.lua sets that when you're in a .ble buffer, so if
-- these silently no-op, focus is the first thing to check.

local M = {}

local HOST = '127.0.0.1'
local PORT = 4242

-- ONE augroup, cleared on every setup(). Without this, autocmds were
-- registered ungrouped: reloading your config left the OLD callbacks alive
-- (still running the old attach, still early-returning) alongside the new ones,
-- and calling setup() twice simply stacked duplicates. Nothing you changed in
-- this file could take effect while a stale copy was still firing.
local AUGROUP = 'bltool'
local grp = nil

local BAR_W = 16 -- slider bar width in cells
local LABEL_W = 12 -- label column width
local NS = vim.api.nvim_create_namespace 'bltool'

-- How long to wait for a reply before giving up on a job and moving on. Without
-- this a single unanswered connection leaves in_flight pinned true and the whole
-- panel goes dead until nvim restarts — frame_client.lua has always had a guard,
-- this didn't.
local REPLY_TIMEOUT_MS = 2000

-- ── serialized one-shot sender (the ordering contract) ─────────────────────
local queue = {}
local in_flight = false

local function pump()
  if in_flight then
    return
  end
  local job = table.remove(queue, 1)
  if not job then
    return
  end
  in_flight = true

  local uv = vim.uv or vim.loop
  local client = uv.new_tcp()
  local chunks = {}
  local done = false
  local timer = nil

  local function finish()
    if done then
      return
    end
    done = true
    if timer and not timer:is_closing() then
      timer:stop()
      timer:close()
    end
    if client and not client:is_closing() then
      client:close()
    end
    in_flight = false
    local reply = table.concat(chunks)
    if job.cb then
      vim.schedule(function()
        job.cb(reply)
      end)
    end
    vim.schedule(pump)
  end

  -- the guard. Fires only if finish() hasn't already run, so a normal reply
  -- costs nothing.
  timer = uv.new_timer()
  timer:start(REPLY_TIMEOUT_MS, 0, function()
    if not done then
      vim.schedule(function()
        vim.notify('bltool: no reply for "' .. job.cmd .. '" — is the editor running?', vim.log.levels.WARN)
      end)
      finish()
    end
  end)

  client:connect(HOST, PORT, function(err)
    if err then
      return finish()
    end
    client:write(job.cmd .. '\n')
    client:read_start(function(rerr, data)
      if rerr or not data then
        return finish()
      end
      chunks[#chunks + 1] = data
      -- blobs end with "---\n"; one-line replies close from the server side,
      -- but cut early when we can tell we're done
      local all = table.concat(chunks)
      if all:match '%-%-%-\n$' or all:match '^ok\n$' or all:match '^rel:' or all:match '^pin:' or all:match '^label:' then
        return finish()
      end
    end)
  end)
end

local function send(cmd, cb)
  queue[#queue + 1] = { cmd = cmd, cb = cb }
  pump()
end

-- ── model: parse the tool blob ─────────────────────────────────────────────
-- model = { elems={ {uid,label,targets={},prog} }, elem_more=n,
--           controls={ key -> {kind,min,max,val} }, order={key,...},
--           relsets={ {gid,label,ndots} } }
local function parse_tool_blob(blob)
  local model = { elems = {}, elem_more = 0, controls = {}, order = {}, relsets = {} }
  for line in blob:gmatch '[^\n]+' do
    local uid, label, targets, flags = line:match '^elem=(%d+):([^:]*):([^:]*):(.*)$'
    if uid then
      local t = {}
      for bang, n in targets:gmatch '(!?)(%d+)' do
        t[#t + 1] = { uid = tonumber(n), off = bang == '!' }
      end
      model.elems[#model.elems + 1] = {
        uid = tonumber(uid),
        label = label,
        targets = t,
        prog = flags == 'prog',
      }
      goto continue
    end
    local more = line:match '^elem_more=(%d+)$'
    if more then
      model.elem_more = tonumber(more)
      goto continue
    end

    local skey, smin, smax, sval = line:match '^slider=([%w_.]+):([%-%d.]+):([%-%d.]+):([%-%d.]+)$'
    if skey then
      model.controls[skey] = { kind = 'slider', min = tonumber(smin), max = tonumber(smax), val = tonumber(sval) }
      model.order[#model.order + 1] = skey
      goto continue
    end
    local tkey, tval = line:match '^toggle=([%w_.]+):(%d)$'
    if tkey then
      model.controls[tkey] = { kind = 'toggle', val = tval == '1' }
      model.order[#model.order + 1] = tkey
      goto continue
    end
    local pkey, pval = line:match '^spin=([%w_.]+):(%d+)$'
    if pkey then
      model.controls[pkey] = { kind = 'spin', val = tonumber(pval) }
      model.order[#model.order + 1] = pkey
      goto continue
    end
    local gid, rlabel, ndots = line:match '^relset=(%d+):([^:]*):(%d+)$'
    if gid then
      model.relsets[#model.relsets + 1] = { gid = tonumber(gid), label = rlabel, ndots = tonumber(ndots) }
    end
    ::continue::
  end
  return model
end

-- ── hsv → hex (for the swatch) ─────────────────────────────────────────────
local function hsv_to_hex(h, s, v)
  h, s, v = (h % 360) / 60, s / 100, v / 100
  local c = v * s
  local x = c * (1 - math.abs(h % 2 - 1))
  local r, g, b
  if h < 1 then
    r, g, b = c, x, 0
  elseif h < 2 then
    r, g, b = x, c, 0
  elseif h < 3 then
    r, g, b = 0, c, x
  elseif h < 4 then
    r, g, b = 0, x, c
  elseif h < 5 then
    r, g, b = x, 0, c
  else
    r, g, b = c, 0, x
  end
  local m2 = v - c
  return string.format('#%02X%02X%02X', math.floor((r + m2) * 255 + 0.5), math.floor((g + m2) * 255 + 0.5), math.floor((b + m2) * 255 + 0.5))
end

-- ── rendering ──────────────────────────────────────────────────────────────
local state = {
  buf = nil,
  win = nil,
  model = nil,
  -- per rendered line: control metadata for hit-testing / keys
  -- lines[lnum] = { kind, key, min, max, val, bar_col, bar_w, gid, uid }
  lines = {},
  drag = nil, -- { lnum } while a slider drag is live
}

-- timeline.live_stack — DISPLAY sampling for connected elements. Off (the
-- default) means a held frame shows what its governing key showed: gravity
-- lands on keys, inbetweens don't creep. On means every frame samples live,
-- for watching the gravity actually fall while the target holds. Changes
-- nothing about the wiring or the recording — see timeline.StackSampling.
local SECTIONS = {
  { title = 'brush', keys = { 'brush.size', 'brush.opacity', 'brush.gap_close' } },
  { title = 'lasso', keys = { 'lasso.edge_soft' } },
  { title = 'procrustes', keys = { 'procrustes.flip', 'procrustes.tolerance' } },
  { title = 'color', keys = { 'color.h', 'color.s', 'color.v' }, swatch = true },
  { title = 'timeline', keys = { 'timeline.pinned', 'timeline.live_stack', 'timeline.hold' } },
  {
    title = 'onion',
    keys = {
      'onion.enabled',
      'onion.dimension_ghosts',
      'onion.before',
      'onion.after',
      'onion.opacity_before',
      'onion.opacity_after',
    },
  },
}

local HOLD_NAMES = { [1] = '(on ones)', [2] = '(on twos)', [3] = '(on threes)', [4] = '(on fours)' }

local function short_key(key)
  return key:match '%.([%w_]+)$' or key
end

local function bar_string(min, max, val)
  local ratio = 0
  if max > min then
    ratio = (val - min) / (max - min)
  end
  ratio = math.max(0, math.min(1, ratio))
  local fill = math.floor(ratio * BAR_W + 0.5)
  return string.rep('█', fill) .. string.rep('─', BAR_W - fill)
end

local function render()
  if not (state.buf and vim.api.nvim_buf_is_valid(state.buf)) then
    return
  end
  local m = state.model
  if not m then
    return
  end

  local out, meta = {}, {}
  local function push(line, info)
    out[#out + 1] = line
    meta[#out] = info
  end

  -- ── elements
  push('── elements ─────────────────────────────', nil)
  for _, e in ipairs(m.elems) do
    local label = e.label ~= '' and (' ' .. e.label) or ''
    local arrow = ''
    if #e.targets > 0 then
      local parts = {}
      for _, t in ipairs(e.targets) do
        parts[#parts + 1] = string.format('[%d]%s', t.uid, t.off and ' (off)' or '')
      end
      arrow = '  -> ' .. table.concat(parts, ' ')
    end
    local prog = e.prog and '  (auto)' or ''
    -- element rows carry their uid so c/x/t can act on the row under the cursor
    push(string.format('[%d]%s%s%s', e.uid, label, arrow, prog), { kind = 'elem', uid = e.uid, targets = e.targets })
  end
  if m.elem_more > 0 then
    push(string.format('(%d more…)', m.elem_more), nil)
  end
  push('', nil)

  -- ── control sections
  for _, sec in ipairs(SECTIONS) do
    local any = false
    for _, k in ipairs(sec.keys) do
      if m.controls[k] then
        any = true
        break
      end
    end
    if any then
      push(string.format('── %s %s', sec.title, string.rep('─', math.max(0, 38 - #sec.title))), nil)
      for _, key in ipairs(sec.keys) do
        local c = m.controls[key]
        if c then
          local name = short_key(key)
          local pad = string.rep(' ', math.max(1, LABEL_W - #name))
          if c.kind == 'slider' then
            local bar = bar_string(c.min, c.max, c.val)
            local line = string.format('%s%s%s  %.2f', name, pad, bar, c.val)
            push(line, {
              kind = 'slider',
              key = key,
              min = c.min,
              max = c.max,
              val = c.val,
              bar_col = #name + #pad,
              bar_w = BAR_W,
            })
          elseif c.kind == 'toggle' then
            local box = c.val and '[x]' or '[ ]'
            push(string.format('%s %s', box, name), { kind = 'toggle', key = key, val = c.val })
          elseif c.kind == 'spin' then
            local extra = ''
            if key == 'timeline.hold' then
              extra = '   ' .. (HOLD_NAMES[c.val] or string.format('(on %ds)', c.val))
            end
            push(string.format('%s%s< %d >%s', name, pad, c.val, extra), { kind = 'spin', key = key, val = c.val, bar_col = #name + #pad })
          end
        end
      end
      if sec.swatch then
        local h = (m.controls['color.h'] or {}).val or 0
        local s = (m.controls['color.s'] or {}).val or 0
        local v = (m.controls['color.v'] or {}).val or 0
        local hex = hsv_to_hex(h, s, v)
        push(hex .. '  ██████████', { kind = 'swatch', hex = hex })
      end
      push('', nil)
    end
  end

  -- ── rel sets
  if #m.relsets > 0 then
    push('── rel sets ─────────────────────────────', nil)
    for _, rs in ipairs(m.relsets) do
      local label = rs.label ~= '' and rs.label or ('rel_' .. rs.gid)
      push(string.format('%s   %d dots   [Set]', label, rs.ndots), { kind = 'relset', gid = rs.gid })
    end
    push('', nil)
  end

  vim.bo[state.buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, out)
  vim.bo[state.buf].modifiable = false
  -- rendered text is not an unsaved edit — without this the buffer shows [+]
  -- forever and 'confirm' nags on close
  vim.bo[state.buf].modified = false
  state.lines = meta

  -- swatch highlight: true-color block in the buffer
  vim.api.nvim_buf_clear_namespace(state.buf, NS, 0, -1)
  for lnum, info in pairs(meta) do
    if info and info.kind == 'swatch' then
      vim.api.nvim_set_hl(0, 'BltoolSwatch', { fg = info.hex })
      vim.api.nvim_buf_set_extmark(state.buf, NS, lnum - 1, #info.hex + 2, {
        end_col = #info.hex + 2 + #'██████████',
        hl_group = 'BltoolSwatch',
      })
    end
  end
end

-- ── refresh ────────────────────────────────────────────────────────────────
function M.refresh()
  send('tool', function(blob)
    state.model = parse_tool_blob(blob)
    render()
  end)
end

-- ── value edits ────────────────────────────────────────────────────────────
local function fmt_val(info, v)
  if info.kind == 'spin' then
    return tostring(math.floor(v + 0.5))
  end
  return string.format('%.2f', v)
end

local function set_value(info, v)
  if info.kind == 'slider' then
    v = math.max(info.min, math.min(info.max, v))
  elseif info.kind == 'spin' then
    v = math.max(info.key == 'timeline.hold' and 1 or 0, math.floor(v + 0.5))
  end
  info.val = v
  -- optimistic local update, then confirm with a refresh on reply
  send('tool:set:' .. info.key .. ':' .. fmt_val(info, v), function()
    M.refresh()
  end)
  -- re-render immediately from the tweaked model so drags feel live
  if state.model and state.model.controls[info.key] then
    state.model.controls[info.key].val = v
    render()
  end
end

local function toggle(info)
  send('tool:set:' .. info.key .. ':' .. (info.val and '0' or '1'), function()
    M.refresh()
  end)
end

local function nudge(lnum, dir, big)
  local info = state.lines[lnum]
  if not info then
    return
  end
  if info.kind == 'slider' then
    local step = (info.max - info.min) / BAR_W * (big and 4 or 1)
    set_value(info, info.val + dir * step)
  elseif info.kind == 'spin' then
    set_value(info, info.val + dir * (big and 10 or 1))
  elseif info.kind == 'toggle' then
    toggle(info)
  end
end

-- ── connections ────────────────────────────────────────────────────────────
-- The element under the cursor becomes a CONTRIBUTOR to whichever element you
-- name. Its motion sums onto the target's, and since connect appends to the
-- stack, the newest contributor takes imaging rights (last-wins). The arrow
-- column ("[1]  -> [0]") shows the result after the refresh.
--
-- CHAINS are fine: connect A to B and B to C and A's displacement reaches C
-- (resolveStack recurses). A CYCLE is not — A to B plus B to A has no meaning
-- when a contribution flows one way, and the server drops the branch that
-- closes it and prints "[stack] CYCLE". Nothing here stops you building one, so
-- that print is the signal if a chain silently stops contributing.
-- Exposed on M as well as bound to keys. A buffer-local keymap can be
-- intercepted (which-key, operator-pending resolution, a stale module in
-- package.loaded), and when that happens `c` falls through to vim's change
-- operator and you get E21 on a nomodifiable buffer. A user command can't be
-- intercepted by any of that, so :BltoolConnect always works.
local function connect_elem(disconnect)
  local info = state.lines[vim.fn.line '.']
  if not info or info.kind ~= 'elem' then
    vim.notify('bltool: put the cursor on an element row first', vim.log.levels.WARN)
    return
  end
  local verb = disconnect and 'disconnect' or 'connect'
  local prompt = string.format('%s [%d] %s element: ', verb, info.uid, disconnect and 'from' or '->')
  vim.ui.input({ prompt = prompt }, function(inp)
    if not inp or inp == '' then
      return
    end
    local target = tonumber(inp:match '%d+')
    if not target then
      vim.notify('bltool: expected an element number', vim.log.levels.WARN)
      return
    end
    if target == info.uid then
      vim.notify('bltool: an element cannot contribute to itself', vim.log.levels.WARN)
      return
    end
    send(string.format('elem:%s:%d:%d', verb, target, info.uid), function()
      M.refresh()
    end)
  end)
end

-- t on an element row: mute/unmute its contribution. One target → toggle it
-- directly; several → prompt for which. Muted = no motion, no image; the
-- root shows pristine (edits were CoW copies, the original was never touched).
local function toggle_contrib()
  local info = state.lines[vim.fn.line '.']
  if not info or info.kind ~= 'elem' then
    vim.notify('bltool: put the cursor on an element row first', vim.log.levels.WARN)
    return
  end
  if not info.targets or #info.targets == 0 then
    vim.notify('bltool: this element contributes to nothing', vim.log.levels.WARN)
    return
  end
  local function fire(target)
    send(string.format('elem:toggle:%d:%d', target, info.uid), function()
      M.refresh()
    end)
  end
  if #info.targets == 1 then
    fire(info.targets[1].uid)
  else
    vim.ui.input({ prompt = string.format('toggle [%d] on which target: ', info.uid) }, function(inp)
      local target = inp and tonumber(inp:match '%d+')
      if target then
        fire(target)
      end
    end)
  end
end

-- ── module-level handles for the user commands ─────────────────────────────
function M.connect()
  connect_elem(false)
end
function M.disconnect()
  connect_elem(true)
end
function M.toggle()
  toggle_contrib()
end

-- ── mouse ──────────────────────────────────────────────────────────────────
local function slider_from_col(info, col)
  -- col is 0-based byte col; bar chars are multibyte, so work in cells
  local cell = vim.fn.virtcol { vim.fn.line '.', col + 1 } - 1
  local rel = cell - info.bar_col
  local ratio = math.max(0, math.min(1, rel / info.bar_w))
  return info.min + ratio * (info.max - info.min)
end

local function on_mouse(is_drag)
  local mp = vim.fn.getmousepos()
  if mp.winid ~= state.win then
    return
  end
  local lnum = mp.line
  local info = state.lines[lnum]
  if not info then
    state.drag = nil
    return
  end

  if info.kind == 'slider' then
    if is_drag and state.drag ~= lnum then
      if state.drag == nil then
        state.drag = lnum
      else
        return
      end
    end
    state.drag = lnum
    -- virtcol relative to the buffer line
    local cell = mp.column - 1
    local rel = cell - info.bar_col
    if not is_drag and (rel < 0 or rel > info.bar_w + 6) then
      return
    end
    local ratio = math.max(0, math.min(1, rel / info.bar_w))
    set_value(info, info.min + ratio * (info.max - info.min))
  elseif not is_drag then
    state.drag = nil
    if info.kind == 'toggle' then
      toggle(info)
    elseif info.kind == 'spin' then
      local cell = mp.column - 1
      -- "< n >": left arrow region decrements, right increments
      if cell <= info.bar_col + 1 then
        set_value(info, info.val - 1)
      else
        set_value(info, info.val + 1)
      end
    elseif info.kind == 'relset' then
      send('gameui:select:' .. info.gid, function()
        send('reldot:set', function()
          M.refresh()
        end)
      end)
    end
  end
end

-- ── rel flow ───────────────────────────────────────────────────────────────
function M.rel_add()
  send('reldot:add', function(reply)
    local gid = reply:match '^rel:(%d+)'
    if gid then
      -- second anchor landed: in-betweens generated, prompt for the name
      vim.ui.input({ prompt = 'rel set name: ' }, function(name)
        if name and #name > 0 then
          send('gameui:renamegid:' .. gid .. ':' .. name, function()
            M.refresh()
          end)
        else
          M.refresh()
        end
      end)
    elseif reply:match '^rel:pending' then
      vim.notify('rel: first anchor placed — move to the other key and rel-add again', vim.log.levels.INFO)
    end
  end)
end

function M.rel_set()
  send('reldot:set', function()
    M.refresh()
  end)
end

function M.rel_cancel()
  send 'reldot:cancel'
end

-- ── attach to a .bltool FILE (the .ble pattern) ────────────────────────────
-- Opening any *.bltool file turns that buffer into the live tool surface.
-- The file on disk is just an anchor — contents are rendered from the server,
-- never written back.
--
-- NO `if state.buf == buf then return end` GUARD HERE, deliberately.
-- Buffer-local keymaps die with the buffer but state.buf does not, so wiping a
-- .bltool and reopening it — nvim happily hands back the same buffer number —
-- hit that early return, skipped every keymap.set, and left a buffer that
-- RENDERED fine (render() only needs state.buf) with no keys at all. The
-- symptom is `c` falling through to vim's change operator: "E21: Cannot make
-- changes, 'modifiable' is off". keymap.set is idempotent, so re-running the
-- whole block on every attach costs nothing and can't drift.
local function attach(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  state.buf = buf

  vim.bo[buf].filetype = 'bltool'
  vim.bo[buf].modifiable = false
  vim.bo[buf].swapfile = false
  vim.bo[buf].undofile = false

  -- render text must never be written to disk as the file's contents. ONCE per
  -- buffer: attach now runs on every enter, and autocmds don't dedupe, so
  -- without this flag :w would accumulate a no-op handler per visit.
  if not vim.b[buf].bltool_wcmd then
    vim.b[buf].bltool_wcmd = true
    vim.api.nvim_create_autocmd('BufWriteCmd', {
      buffer = buf,
      group = grp,
      callback = function() end, -- :w is a no-op on the tool surface
    })
  end

  local opts = { buffer = buf, nowait = true, silent = true }
  vim.keymap.set('n', '<LeftMouse>', function()
    on_mouse(false)
  end, opts)
  vim.keymap.set('n', '<LeftDrag>', function()
    on_mouse(true)
  end, opts)
  vim.keymap.set('n', '<LeftRelease>', function()
    state.drag = nil
  end, opts)
  vim.keymap.set('n', 'h', function()
    nudge(vim.fn.line '.', -1, false)
  end, opts)
  vim.keymap.set('n', 'l', function()
    nudge(vim.fn.line '.', 1, false)
  end, opts)
  vim.keymap.set('n', 'H', function()
    nudge(vim.fn.line '.', -1, true)
  end, opts)
  vim.keymap.set('n', 'L', function()
    nudge(vim.fn.line '.', 1, true)
  end, opts)
  vim.keymap.set('n', '<CR>', function()
    nudge(vim.fn.line '.', 1, false)
  end, opts)
  vim.keymap.set('n', '<Space>', function()
    nudge(vim.fn.line '.', 1, false)
  end, opts)
  -- ── NOT silent, and that's the point ──────────────────────────────────
  -- These three ASK A QUESTION. vim.ui.input's default implementation echoes
  -- its prompt on the command line, and `silent = true` suppresses precisely
  -- that: the mapping fires, an INVISIBLE prompt opens, your next keystroke
  -- gets eaten answering it, and the whole thing reads as "the key does
  -- nothing" — often followed by a stray E21 from whatever you pressed next.
  -- silent stays on the mouse/nudge maps below, which never prompt and would
  -- otherwise spam the cmdline on every drag frame.
  --
  -- <cmd>...<CR> rather than Lua callbacks because c/x/t are vim OPERATORS and
  -- MOTIONS; <cmd> resolves outside operator-pending handling, so which-key
  -- (delay = 0 here) and mini.ai's textobjects can't get in front of them.
  --
  -- The commands work regardless of any of this: :BltoolConnect,
  -- :BltoolDisconnect, :BltoolToggle, :BltoolRefresh.
  local ask = { buffer = buf, nowait = true }
  vim.keymap.set('n', 'c', '<cmd>BltoolConnect<CR>', ask)
  vim.keymap.set('n', 'x', '<cmd>BltoolDisconnect<CR>', ask)
  vim.keymap.set('n', 't', '<cmd>BltoolToggle<CR>', ask)
  vim.keymap.set('n', 'r', '<cmd>BltoolRefresh<CR>', opts)

  M.refresh()
end

function M.setup(opts)
  opts = opts or {}
  if opts.host then
    HOST = opts.host
  end
  if opts.port then
    PORT = opts.port
  end

  -- clear = true makes setup() idempotent and evicts any autocmds from a
  -- previous load of this module. See the AUGROUP note at the top.
  grp = vim.api.nvim_create_augroup(AUGROUP, { clear = true })

  -- FOUR events, on purpose, because each covers a hole the others leave:
  --   BufReadPost  first read of the file from disk
  --   BufNewFile   the file doesn't exist yet
  --   BufWinEnter  the buffer is displayed in a window again — this is the `:q`
  --                then reopen case, where the buffer stayed LOADED so no read
  --                event fires at all
  --   BufEnter     backstop for reaching the buffer any other way (:b#, window
  --                switch, session restore)
  -- attach is idempotent and re-arms the keymaps every time, which is the whole
  -- point: buffer-local maps die with the buffer, and a buffer that's been
  -- wiped and restored renders fine while having no keys.
  vim.api.nvim_create_autocmd({ 'BufReadPost', 'BufNewFile', 'BufWinEnter', 'BufEnter' }, {
    group = grp,
    pattern = '*.bltool',
    callback = function(ev)
      -- window the buffer is showing in — mouse hit-testing needs it
      state.win = vim.api.nvim_get_current_win()
      attach(ev.buf)
    end,
  })

  -- Element ops as COMMANDS, not just keys. Same functions the c/x/t maps call,
  -- but reachable when the maps aren't — which is the difference between
  -- "the panel is broken" and "press : instead".
  vim.api.nvim_create_user_command('BltoolConnect', M.connect, {})
  vim.api.nvim_create_user_command('BltoolDisconnect', M.disconnect, {})
  vim.api.nvim_create_user_command('BltoolToggle', M.toggle, {})
  vim.api.nvim_create_user_command('BltoolRefresh', M.refresh, {})

  vim.api.nvim_create_user_command('BltoolRelAdd', M.rel_add, {})
  vim.api.nvim_create_user_command('BltoolRelSet', M.rel_set, {})
  vim.api.nvim_create_user_command('BltoolRelCancel', M.rel_cancel, {})
  -- manual escape hatch: re-arm keymaps and re-read the blob on the current
  -- buffer, for when the autocmds have been outmaneuvered
  vim.api.nvim_create_user_command('BltoolAttach', function()
    state.win = vim.api.nvim_get_current_win()
    attach(vim.api.nvim_get_current_buf())
  end, {})
end

return M
