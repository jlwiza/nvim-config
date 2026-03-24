-- zdb.lua — Neovim plugin for zdb live debugger
--
-- Keybindings:
--   <leader>db     toggle breakpoint on current line
--   <leader>dd     open/close debug panel
--   <leader>dc     continue
--   <leader>ds     step in
--   <leader>dn     step over
--   <leader>do     step out
--   <leader>dq     quit debuggee
--
-- In the debug panel:
--   c       continue       s       step in
--   n       step over      o       step out
--   q       quit program   p/Enter inspect variable
--   v       list all vars  x       clear output
--   Esc     close panel

local M = {}

-- ============================================================================
-- Config
-- ============================================================================

M.config = {
  breakpoint_file = 'zdb_breakpoints.zon',
  state_file = 'zdb_state.txt',
  command_file = 'zdb_command.txt',
  output_file = 'zdb_output.txt',
  sign_text = '●',
  sign_hl = 'DiagnosticError',
  poll_ms = 100,
  panel_width = 55,
}

-- ============================================================================
-- State
-- ============================================================================

local breakpoints = {}
local panel_buf = nil
local panel_win = nil
local poll_timer = nil
local last_state_content = nil
local last_output_content = nil
local cached_root = nil
local current_state = nil
local output_lines = {}
local ns = vim.api.nvim_create_namespace 'zdb'
local hl_ns = vim.api.nvim_create_namespace 'zdb_hl'

-- ============================================================================
-- Highlight groups
-- ============================================================================

local function setup_highlights()
  local hi = vim.api.nvim_set_hl

  -- Status
  hi(0, 'ZdbStopped', { fg = '#ff6b6b', bold = true })
  hi(0, 'ZdbRunning', { fg = '#69db7c', bold = true })
  hi(0, 'ZdbWaiting', { fg = '#868e96', bold = true })

  -- Panel structure
  hi(0, 'ZdbSeparator', { fg = '#495057' })
  hi(0, 'ZdbHeader', { fg = '#ffd43b', bold = true })
  hi(0, 'ZdbLabel', { fg = '#868e96' }) -- "File:", "Line:", etc.
  hi(0, 'ZdbValue', { fg = '#e9ecef' }) -- file path, line number

  -- Variable display
  hi(0, 'ZdbVarName', { fg = '#74c0fc' }) -- variable names
  hi(0, 'ZdbTypeName', { fg = '#da77f2' }) -- final type name (AnimationTimeline)
  hi(0, 'ZdbTypeModule', { fg = '#ffa94d' }) -- module path prefix (timeline.)
  hi(0, 'ZdbTypeSigil', { fg = '#868e96' }) -- *, [], ? etc.
  hi(0, 'ZdbFieldName', { fg = '#91a7ff' }) -- .field names
  hi(0, 'ZdbString', { fg = '#69db7c' }) -- string values
  hi(0, 'ZdbNumber', { fg = '#ffa94d' }) -- numeric values
  hi(0, 'ZdbKeyword', { fg = '#ff922b' }) -- null, true, false
  hi(0, 'ZdbEnum', { fg = '#e599f7' }) -- .enum_tag
  hi(0, 'ZdbFn', { fg = '#868e96', italic = true }) -- <fn>
  hi(0, 'ZdbPtr', { fg = '#868e96', italic = true }) -- ptr
  hi(0, 'ZdbBrace', { fg = '#868e96' }) -- { }

  -- Output
  hi(0, 'ZdbPrompt', { fg = '#ffd43b', bold = true }) -- >>> query
  hi(0, 'ZdbHelpKey', { fg = '#74c0fc', bold = true }) -- [c], [s], etc.
  hi(0, 'ZdbHelpText', { fg = '#868e96' })
end

-- ============================================================================
-- Breakpoint toggling
-- ============================================================================

local function get_project_root()
  local markers = { '.git', 'build.zig', 'build.zig.zon' }
  local path = vim.fn.expand '%:p:h'
  while path and path ~= '/' do
    for _, marker in ipairs(markers) do
      if vim.fn.isdirectory(path .. '/' .. marker) == 1 or vim.fn.filereadable(path .. '/' .. marker) == 1 then
        return path
      end
    end
    path = vim.fn.fnamemodify(path, ':h')
  end
  return vim.fn.getcwd()
end

local function relative_path(filepath, root)
  if filepath:sub(1, #root) == root then
    return filepath:sub(#root + 2)
  end
  return filepath
end

local function write_breakpoints_zon(root)
  local lines = { '.{', '    .breakpoints = .{' }
  for filepath, file_bps in pairs(breakpoints) do
    local rel = relative_path(filepath, root)
    for line, enabled in pairs(file_bps) do
      if enabled then
        table.insert(lines, string.format('        .{ .file = "%s", .line = %d },', rel, line))
      end
    end
  end
  table.insert(lines, '    },')
  table.insert(lines, '}')
  table.insert(lines, '')

  local zon_path = root .. '/' .. M.config.breakpoint_file
  local f = io.open(zon_path, 'w')
  if f then
    f:write(table.concat(lines, '\n'))
    f:close()
  end
end

local function update_signs(bufnr)
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  local filepath = vim.api.nvim_buf_get_name(bufnr)
  local file_bps = breakpoints[filepath]
  if not file_bps then
    return
  end

  for line, enabled in pairs(file_bps) do
    if enabled then
      vim.api.nvim_buf_set_extmark(bufnr, ns, line - 1, 0, {
        sign_text = M.config.sign_text,
        sign_hl_group = M.config.sign_hl,
      })
    end
  end
end

local function toggle_breakpoint()
  local bufnr = vim.api.nvim_get_current_buf()
  local filepath = vim.api.nvim_buf_get_name(bufnr)
  local line = vim.api.nvim_win_get_cursor(0)[1]

  if not breakpoints[filepath] then
    breakpoints[filepath] = {}
  end

  if breakpoints[filepath][line] then
    breakpoints[filepath][line] = nil
  else
    breakpoints[filepath][line] = true
  end

  update_signs(bufnr)
  cached_root = cached_root or get_project_root()
  write_breakpoints_zon(cached_root)
end

-- ============================================================================
-- Command sending
-- ============================================================================

local function send_command(cmd)
  local root = cached_root or get_project_root()
  local cmd_path = root .. '/' .. M.config.command_file
  local f = io.open(cmd_path, 'w')
  if f then
    f:write(cmd .. '\n')
    f:flush()
    f:close()
  end
end

-- ============================================================================
-- Tab completion for variable inspection
-- ============================================================================

-- Cache of known field names: { ["timeline"] = {"dimensions", "mainFrames", ...}, ... }
local known_fields = {}

-- Extract field names from output lines (patterns like "  .field_name = ...")
local function learn_fields_from_output(query, lines_to_scan)
  local fields = {}
  for _, line in ipairs(lines_to_scan) do
    local field = line:match '^%s*%.(%w+)%s*='
    if field then
      table.insert(fields, field)
    end
  end
  if #fields > 0 then
    known_fields[query] = fields
  end
end

-- Try to learn fields from already-displayed output_lines for a given query
local function try_learn_from_existing_output(query)
  if known_fields[query] then
    return
  end
  -- Look for a ">>> query" line in output_lines, then scan lines after it
  local found_query = false
  local lines_after = {}
  for _, line in ipairs(output_lines) do
    if found_query then
      -- Stop at next >>> or separator
      if line:match '^%s*>>>' or line:match '^─' then
        break
      end
      table.insert(lines_after, line)
    end
    if line:match('^%s*>>> ' .. vim.pesc(query) .. '$') then
      found_query = true
    end
  end
  if #lines_after > 0 then
    learn_fields_from_output(query, lines_after)
  end
end

-- Get variable names from current state
local function get_var_names()
  local names = {}
  if current_state and current_state.variables then
    for _, var_line in ipairs(current_state.variables) do
      local name = var_line:match '^%s+(%S+):'
      if name then
        table.insert(names, name)
      end
    end
  end
  return names
end

-- Completion function: called by vim.fn.input
function M.complete(arg_lead)
  local completions = {}

  -- Find the last dot to determine prefix vs field
  local last_dot = arg_lead:match '.*()%.'

  if last_dot then
    -- Completing after a dot: "timeline.dim" → look up fields for "timeline"
    local prefix = arg_lead:sub(1, last_dot - 1)
    local partial = arg_lead:sub(last_dot + 1)

    -- Try to learn from existing output first
    try_learn_from_existing_output(prefix)

    -- If still no fields, synchronously query the program and wait
    if not known_fields[prefix] then
      local root = cached_root or get_project_root()
      if root then
        -- Delete old output so we can detect fresh response
        local out_path = root .. '/' .. M.config.output_file
        os.remove(out_path)
        last_output_content = nil

        -- Send query
        send_command(prefix)
        M._last_query = prefix

        -- Wait for fresh output (vim.wait keeps UI responsive)
        vim.wait(400, function()
          local f = io.open(out_path, 'r')
          if not f then
            return false
          end
          local content = f:read '*all'
          f:close()
          if not content or content == '' then
            return false
          end

          -- Got response — parse fields
          local new_lines = {}
          for line in content:gmatch '[^\n]+' do
            table.insert(new_lines, line)
          end
          learn_fields_from_output(prefix, new_lines)

          -- Add to output display
          last_output_content = content
          table.insert(output_lines, '>>> ' .. prefix)
          for _, line in ipairs(new_lines) do
            table.insert(output_lines, ' ' .. line)
          end
          return true
        end, 20)
      end
    end

    local fields = known_fields[prefix]
    if fields then
      for _, field in ipairs(fields) do
        if partial == '' or field:sub(1, #partial) == partial then
          table.insert(completions, prefix .. '.' .. field)
        end
      end
    end
  else
    -- Completing variable names
    local vars = get_var_names()
    for _, name in ipairs(vars) do
      if arg_lead == '' or name:sub(1, #arg_lead) == arg_lead then
        table.insert(completions, name)
      end
    end
    -- Also add commands
    for _, cmd in ipairs { 'continue', 'step', 'next', 'out', 'quit', 'vars', 'clear' } do
      if arg_lead == '' or cmd:sub(1, #arg_lead) == arg_lead then
        table.insert(completions, cmd)
      end
    end
  end

  return completions
end

-- Helper to clear output and delete the file on disk
local function clear_output()
  output_lines = {}
  last_output_content = nil
  -- Delete the output file so polling doesn't re-add it
  local root = cached_root or get_project_root()
  if root then
    os.remove(root .. '/' .. M.config.output_file)
  end
  if M._render then
    M._render()
  end
end

local function prompt_and_send()
  -- Register the completion function in vimscript (once)
  vim.cmd [[
        if !exists('*ZdbComplete')
            function! ZdbComplete(ArgLead, CmdLine, CursorPos)
                return luaeval('require("zdb").complete(_A)', a:ArgLead)
            endfunction
        endif
    ]]

  -- Use vim.fn.input with tab completion
  local ok, input = pcall(vim.fn.input, {
    prompt = 'zdb> ',
    completion = 'customlist,ZdbComplete',
  })

  if ok and input and input ~= '' then
    -- Handle clear locally (don't send to program)
    if input == 'clear' or input == 'cls' then
      clear_output()
      return
    end

    send_command(input)
    table.insert(output_lines, '>>> ' .. input)

    -- Learn the base query for future field completion
    local base = input:match '^([^%[]+)'
    if base then
      M._last_query = base
    end

    if M._render then
      M._render()
    end
  end
end

-- ============================================================================
-- State/output parsing
-- ============================================================================

local function parse_state(content)
  local state = { variables = {} }
  local in_vars = false

  for line in content:gmatch '[^\n]+' do
    if line == '---' then
      in_vars = true
    elseif in_vars then
      table.insert(state.variables, line)
    else
      local key, val = line:match '^(%w+)=(.+)$'
      if key then
        state[key] = val
      end
    end
  end
  return state
end

-- ============================================================================
-- Syntax highlighting
-- ============================================================================

local function highlight_panel(lines)
  if not panel_buf or not vim.api.nvim_buf_is_valid(panel_buf) then
    return
  end

  vim.api.nvim_buf_clear_namespace(panel_buf, hl_ns, 0, -1)

  for i, line in ipairs(lines) do
    local row = i - 1

    -- Status lines
    if line:match '⏸  STOPPED' then
      vim.api.nvim_buf_set_extmark(panel_buf, hl_ns, row, 0, {
        end_col = #line,
        hl_group = 'ZdbStopped',
      })
    elseif line:match '▶  RUNNING' then
      vim.api.nvim_buf_set_extmark(panel_buf, hl_ns, row, 0, {
        end_col = #line,
        hl_group = 'ZdbRunning',
      })
    elseif line:match '○  WAITING' then
      vim.api.nvim_buf_set_extmark(panel_buf, hl_ns, row, 0, {
        end_col = #line,
        hl_group = 'ZdbWaiting',
      })

      -- Separator lines
    elseif line:match '^─+$' then
      vim.api.nvim_buf_set_extmark(panel_buf, hl_ns, row, 0, {
        end_col = #line,
        hl_group = 'ZdbSeparator',
      })

      -- Section headers
    elseif line:match '^ Variables:' or line:match '^ Output:' then
      vim.api.nvim_buf_set_extmark(panel_buf, hl_ns, row, 0, {
        end_col = #line,
        hl_group = 'ZdbHeader',
      })

      -- Info labels: "  File: ...", "  Line: ...", "  Func: ..."
    elseif line:match '^  File:' or line:match '^  Line:' or line:match '^  Func:' then
      local colon_pos = line:find ':'
      if colon_pos then
        vim.api.nvim_buf_set_extmark(panel_buf, hl_ns, row, 0, {
          end_col = colon_pos,
          hl_group = 'ZdbLabel',
        })
        vim.api.nvim_buf_set_extmark(panel_buf, hl_ns, row, colon_pos, {
          end_col = #line,
          hl_group = 'ZdbValue',
        })
      end

      -- Help lines with [key] markers
    elseif line:match '%[%a%]' then
      -- Highlight each [x] in the line
      local pos = 1
      while true do
        local s, e = line:find('%[%a%]', pos)
        if not s then
          break
        end
        vim.api.nvim_buf_set_extmark(panel_buf, hl_ns, row, s - 1, {
          end_col = e,
          hl_group = 'ZdbHelpKey',
        })
        pos = e + 1
      end

      -- >>> prompt lines
    elseif line:match '^%s*>>>' then
      vim.api.nvim_buf_set_extmark(panel_buf, hl_ns, row, 0, {
        end_col = #line,
        hl_group = 'ZdbPrompt',
      })

      -- Variable lines: "  name: Type = value"
    elseif line:match '^%s+%S+:%s' then
      local indent_end = #(line:match '^(%s+)' or '')
      local colon_pos = line:find(':', indent_end + 1)
      local eq_pos = line:find(' = ', indent_end + 1)

      if colon_pos then
        -- Variable name (blue)
        vim.api.nvim_buf_set_extmark(panel_buf, hl_ns, row, indent_end, {
          end_col = colon_pos - 1,
          hl_group = 'ZdbVarName',
        })

        if eq_pos then
          -- Type string between : and =
          local type_str = line:sub(colon_pos + 2, eq_pos - 1)
          local type_start = colon_pos + 1 -- +1 for the space after :
          highlight_type(row, type_start, type_str)

          -- Value part
          local val_start = eq_pos + 3
          local val_text = line:sub(val_start)
          highlight_value(row, val_start - 1, val_text)
        else
          -- Just type, no =
          local type_str = line:sub(colon_pos + 2)
          highlight_type(row, colon_pos + 1, type_str)
        end
      end

      -- Output lines with .field = value patterns
    elseif line:match '^%s+%.%w+' then
      local dot_start = line:find '%.'
      if dot_start then
        local eq_pos = line:find(' = ', dot_start)
        if eq_pos then
          vim.api.nvim_buf_set_extmark(panel_buf, hl_ns, row, dot_start - 1, {
            end_col = eq_pos,
            hl_group = 'ZdbFieldName',
          })
          local val_start = eq_pos + 3
          local val_text = line:sub(val_start)
          highlight_value(row, val_start - 1, val_text)
        else
          vim.api.nvim_buf_set_extmark(panel_buf, hl_ns, row, dot_start - 1, {
            end_col = #line,
            hl_group = 'ZdbFieldName',
          })
        end
      end

      -- Output lines with [N] array index
    elseif line:match '^%s+%[%d+%]' then
      local bracket_end = line:find '%]'
      if bracket_end then
        vim.api.nvim_buf_set_extmark(panel_buf, hl_ns, row, 0, {
          end_col = bracket_end,
          hl_group = 'ZdbLabel',
        })
        local val_text = line:sub(bracket_end + 2)
        if #val_text > 0 then
          highlight_value(row, bracket_end + 1, val_text)
        end
      end
    end
  end
end

-- Highlight a type string like "*timeline.AnimationTimeline" or "usize"
-- Sigils (*, []) → gray, module path → gray, final type name → purple
function highlight_type(row, col, type_str)
  if not panel_buf or #type_str == 0 then
    return
  end

  local pos = col
  local i = 1

  -- Skip and highlight leading sigils: *, ?, [], *const, etc.
  while i <= #type_str do
    local ch = type_str:sub(i, i)
    if ch == '*' or ch == '?' or ch == '[' or ch == ']' then
      pcall(vim.api.nvim_buf_set_extmark, panel_buf, hl_ns, row, pos, {
        end_col = pos + 1,
        hl_group = 'ZdbTypeSigil',
      })
      pos = pos + 1
      i = i + 1
    elseif type_str:sub(i, i + 5) == 'const ' then
      pcall(vim.api.nvim_buf_set_extmark, panel_buf, hl_ns, row, pos, {
        end_col = pos + 5,
        hl_group = 'ZdbTypeSigil',
      })
      pos = pos + 6
      i = i + 6
    else
      break
    end
  end

  -- Remaining is the type path like "timeline.AnimationTimeline" or "usize"
  local rest = type_str:sub(i)
  local last_dot = rest:match '.*()%.'

  if last_dot then
    -- Module path before last dot → gray
    pcall(vim.api.nvim_buf_set_extmark, panel_buf, hl_ns, row, pos, {
      end_col = pos + last_dot,
      hl_group = 'ZdbTypeModule',
    })
    -- Final type name after last dot → purple
    pcall(vim.api.nvim_buf_set_extmark, panel_buf, hl_ns, row, pos + last_dot, {
      end_col = pos + #rest,
      hl_group = 'ZdbTypeName',
    })
  else
    -- Simple type like "usize", "bool" → purple
    pcall(vim.api.nvim_buf_set_extmark, panel_buf, hl_ns, row, pos, {
      end_col = pos + #rest,
      hl_group = 'ZdbTypeName',
    })
  end
end

-- Highlight a value string at a given position
function highlight_value(row, col, text)
  if not panel_buf then
    return
  end

  -- String values
  if text:match '^"' then
    pcall(vim.api.nvim_buf_set_extmark, panel_buf, hl_ns, row, col, {
      end_col = col + #text,
      hl_group = 'ZdbString',
    })
    -- null, true, false
  elseif text == 'null' or text == 'true' or text == 'false' then
    pcall(vim.api.nvim_buf_set_extmark, panel_buf, hl_ns, row, col, {
      end_col = col + #text,
      hl_group = 'ZdbKeyword',
    })
    -- Enum .tag
  elseif text:match '^%.%w' then
    pcall(vim.api.nvim_buf_set_extmark, panel_buf, hl_ns, row, col, {
      end_col = col + #text,
      hl_group = 'ZdbEnum',
    })
    -- <fn>
  elseif text == '<fn>' then
    pcall(vim.api.nvim_buf_set_extmark, panel_buf, hl_ns, row, col, {
      end_col = col + #text,
      hl_group = 'ZdbFn',
    })
    -- ptr
  elseif text == 'ptr' then
    pcall(vim.api.nvim_buf_set_extmark, panel_buf, hl_ns, row, col, {
      end_col = col + #text,
      hl_group = 'ZdbPtr',
    })
    -- Numbers
  elseif text:match '^%-?%d' then
    pcall(vim.api.nvim_buf_set_extmark, panel_buf, hl_ns, row, col, {
      end_col = col + #text,
      hl_group = 'ZdbNumber',
    })
  end
end

-- ============================================================================
-- Panel rendering
-- ============================================================================

function M._render()
  if not panel_buf or not vim.api.nvim_buf_is_valid(panel_buf) then
    return
  end

  local lines = {}
  local state = current_state or {}

  if state.status == 'stopped' then
    table.insert(lines, ' ⏸  STOPPED')
    table.insert(lines, string.rep('─', M.config.panel_width - 2))
    table.insert(lines, string.format('  File: %s', state.file or '?'))
    table.insert(lines, string.format('  Line: %s', state.line or '?'))
    table.insert(lines, string.format('  Func: %s()', state['function'] or '?'))
    table.insert(lines, string.rep('─', M.config.panel_width - 2))

    table.insert(lines, ' Variables:')
    if #state.variables > 0 then
      for _, var_line in ipairs(state.variables) do
        table.insert(lines, var_line)
      end
    else
      table.insert(lines, '   (none)')
    end

    table.insert(lines, string.rep('─', M.config.panel_width - 2))

    if #output_lines > 0 then
      table.insert(lines, ' Output:')
      for _, out_line in ipairs(output_lines) do
        table.insert(lines, out_line)
      end
      table.insert(lines, string.rep('─', M.config.panel_width - 2))
    end

    table.insert(lines, ' [c]ontinue [s]tep [n]ext [o]ut [q]uit [p]rint [v]ars [x]cle')
    table.insert(lines, '  r')
    table.insert(lines, ' Press p or Enter to inspect a variable')

    -- Jump to the file:line in the source window
    if state.file and state.line then
      local root = cached_root or get_project_root()
      local target = state.file
      if state.file:sub(1, 1) ~= '/' then
        target = root .. '/' .. state.file
      end
      local lnum = tonumber(state.line)

      for _, win in ipairs(vim.api.nvim_list_wins()) do
        local buf = vim.api.nvim_win_get_buf(win)
        if buf ~= panel_buf then
          local win_name = vim.api.nvim_buf_get_name(buf)
          if win_name ~= target then
            local found_buf = vim.fn.bufnr(target)
            if found_buf == -1 then
              vim.api.nvim_win_call(win, function()
                vim.cmd('edit ' .. vim.fn.fnameescape(target))
              end)
            else
              vim.api.nvim_win_set_buf(win, found_buf)
            end
          end
          if lnum then
            pcall(vim.api.nvim_win_set_cursor, win, { lnum, 0 })
          end
          break
        end
      end
    end
  elseif state.status == 'running' then
    table.insert(lines, ' ▶  RUNNING')
    table.insert(lines, string.rep('─', M.config.panel_width - 2))
    table.insert(lines, '  Program is running...')
    table.insert(lines, '  Set breakpoints with <leader>db')
    output_lines = {}
  else
    table.insert(lines, ' ○  WAITING')
    table.insert(lines, string.rep('─', M.config.panel_width - 2))
    table.insert(lines, '  No state file found.')
    table.insert(lines, '  Start your program with debug mode.')
  end

  vim.api.nvim_buf_set_option(panel_buf, 'modifiable', true)
  vim.api.nvim_buf_set_lines(panel_buf, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(panel_buf, 'modifiable', false)

  -- Apply syntax highlighting
  highlight_panel(lines)

  -- Scroll panel to bottom so latest output is visible
  if panel_win and vim.api.nvim_win_is_valid(panel_win) then
    local line_count = vim.api.nvim_buf_line_count(panel_buf)
    pcall(vim.api.nvim_win_set_cursor, panel_win, { line_count, 0 })
  end
end

-- ============================================================================
-- Polling
-- ============================================================================

local function poll_state()
  if not cached_root then
    return
  end

  local state_path = cached_root .. '/' .. M.config.state_file
  local sf = io.open(state_path, 'r')
  if sf then
    local content = sf:read '*all'
    sf:close()

    if content ~= last_state_content then
      last_state_content = content
      local state = parse_state(content)

      vim.schedule(function()
        if
          state.status == 'stopped'
          and (not current_state or current_state.status ~= 'stopped' or current_state.line ~= state.line or current_state.file ~= state.file)
        then
          output_lines = {}
          last_output_content = nil
          known_fields = {}
          M._last_query = nil
        end

        current_state = state

        if state.status == 'stopped' and not M.is_panel_open() then
          M.open_panel()
        end
        M._render()
      end)
    end
  else
    if last_state_content ~= nil then
      last_state_content = nil
      vim.schedule(function()
        current_state = { status = 'waiting' }
        M._render()
      end)
    end
  end

  local out_path = cached_root .. '/' .. M.config.output_file
  local of = io.open(out_path, 'r')
  if of then
    local content = of:read '*all'
    of:close()

    if content and content ~= '' and content ~= last_output_content then
      last_output_content = content
      vim.schedule(function()
        local new_lines = {}
        for line in content:gmatch '[^\n]+' do
          table.insert(output_lines, ' ' .. line)
          table.insert(new_lines, line)
        end

        -- Learn field names from this output for tab completion
        if M._last_query then
          learn_fields_from_output(M._last_query, new_lines)
        end

        M._render()
      end)
    end
  end
end

-- ============================================================================
-- Panel management
-- ============================================================================

local function setup_panel_keymaps()
  if not panel_buf then
    return
  end

  local opts = { buffer = panel_buf, nowait = true, silent = true }

  vim.keymap.set('n', 'c', function()
    send_command 'continue'
  end, opts)
  vim.keymap.set('n', 's', function()
    send_command 'step'
  end, opts)
  vim.keymap.set('n', 'n', function()
    send_command 'next'
  end, opts)
  vim.keymap.set('n', 'o', function()
    send_command 'out'
  end, opts)
  vim.keymap.set('n', 'q', function()
    send_command 'quit'
  end, opts)

  vim.keymap.set('n', 'p', prompt_and_send, opts)
  vim.keymap.set('n', 'v', function()
    send_command 'v'
  end, opts)
  vim.keymap.set('n', '<CR>', prompt_and_send, opts)

  -- Clear output
  vim.keymap.set('n', 'x', function()
    clear_output()
  end, opts)

  vim.keymap.set('n', '<Esc>', function()
    M.close_panel()
  end, opts)
end

function M.is_panel_open()
  return panel_win and vim.api.nvim_win_is_valid(panel_win)
end

function M.open_panel()
  if M.is_panel_open() then
    return
  end

  panel_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_option(panel_buf, 'buftype', 'nofile')
  vim.api.nvim_buf_set_option(panel_buf, 'bufhidden', 'wipe')
  vim.api.nvim_buf_set_option(panel_buf, 'swapfile', false)
  vim.api.nvim_buf_set_name(panel_buf, '[zdb]')
  vim.api.nvim_buf_set_option(panel_buf, 'filetype', 'zdb')

  vim.cmd 'botright vsplit'
  panel_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(panel_win, panel_buf)
  vim.api.nvim_win_set_width(panel_win, M.config.panel_width)

  vim.wo[panel_win].number = false
  vim.wo[panel_win].relativenumber = false
  vim.wo[panel_win].signcolumn = 'no'
  vim.wo[panel_win].wrap = true
  vim.wo[panel_win].cursorline = false

  setup_panel_keymaps()
  M._render()

  M.start_polling()
  vim.cmd 'wincmd p'
end

function M.close_panel()
  if M.is_panel_open() then
    vim.api.nvim_win_close(panel_win, true)
  end
  panel_win = nil
  panel_buf = nil
  M.stop_polling()
end

function M.toggle_panel()
  if M.is_panel_open() then
    M.close_panel()
  else
    M.open_panel()
  end
end

function M.start_polling()
  if poll_timer then
    return
  end

  poll_timer = vim.loop.new_timer()
  poll_timer:start(0, M.config.poll_ms, function()
    poll_state()
  end)
end

function M.stop_polling()
  if poll_timer then
    poll_timer:stop()
    poll_timer:close()
    poll_timer = nil
  end
  last_state_content = nil
  last_output_content = nil
end

-- ============================================================================
-- Setup
-- ============================================================================

function M.setup(opts)
  M.config = vim.tbl_deep_extend('force', M.config, opts or {})
  cached_root = get_project_root()

  setup_highlights()

  vim.keymap.set('n', '<leader>db', toggle_breakpoint, { desc = 'zdb: toggle breakpoint' })
  vim.keymap.set('n', '<leader>dd', M.toggle_panel, { desc = 'zdb: toggle debug panel' })
  vim.keymap.set('n', '<leader>dc', function()
    send_command 'continue'
  end, { desc = 'zdb: continue' })
  vim.keymap.set('n', '<leader>ds', function()
    send_command 'step'
  end, { desc = 'zdb: step in' })
  vim.keymap.set('n', '<leader>dn', function()
    send_command 'next'
  end, { desc = 'zdb: step over' })
  vim.keymap.set('n', '<leader>do', function()
    send_command 'out'
  end, { desc = 'zdb: step out' })
  vim.keymap.set('n', '<leader>dq', function()
    send_command 'quit'
  end, { desc = 'zdb: quit debuggee' })
  vim.keymap.set('n', '<leader>dx', function()
    clear_output()
  end, { desc = 'zdb: clear output' })

  vim.api.nvim_create_user_command('ZdbToggle', toggle_breakpoint, {})
  vim.api.nvim_create_user_command('ZdbPanel', M.toggle_panel, {})
  vim.api.nvim_create_user_command('ZdbContinue', function()
    send_command 'continue'
  end, {})
  vim.api.nvim_create_user_command('ZdbStep', function()
    send_command 'step'
  end, {})
  vim.api.nvim_create_user_command('ZdbNext', function()
    send_command 'next'
  end, {})
  vim.api.nvim_create_user_command('ZdbOut', function()
    send_command 'out'
  end, {})
  vim.api.nvim_create_user_command('ZdbQuit', function()
    send_command 'quit'
  end, {})
  vim.api.nvim_create_user_command('ZdbClear', function()
    clear_output()
  end, {})
  vim.api.nvim_create_user_command('ZdbPrint', function(a)
    if a.args and a.args ~= '' then
      send_command(a.args)
    else
      prompt_and_send()
    end
  end, { nargs = '?' })

  vim.api.nvim_create_autocmd('BufEnter', {
    pattern = '*.zig',
    callback = function(ev)
      update_signs(ev.buf)
    end,
  })
end

return M
