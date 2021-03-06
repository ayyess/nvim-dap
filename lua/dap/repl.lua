local api = vim.api
local M = {}

local win = nil
local buf = nil
local session = nil


local history = {
  last = nil,
  entries = {},
  idx = 1
}


local frames_ns = api.nvim_create_namespace('dap.repl.frames')
local frames_marks = {}

M.commands = {
  continue = {'.continue', '.c'},
  next_ = {'.next', '.n'},
  into = {'.into'},
  out = {'.out'},
  scopes = {'.scopes'},
  threads = {'.threads'},
  frames = {'.frames'},
  exit = {'exit', '.exit'},
  up = {'.up'},
  down = {'.down'},
  goto_ = {'.goto'}
}

function M.print_stackframes()
  local frames = (session.threads[session.stopped_thread_id] or {}).frames or {}
  frames_marks = {}
  if buf then
    api.nvim_buf_clear_namespace(buf, frames_ns, 0, -1)
  end
  for _, frame in pairs(frames) do
    local line
    if frame.id == session.current_frame.id then
      line = '→ ' .. frame.name
    else
      line = '  ' .. frame.name
    end
    local lnum = M.append(line)
    if lnum and buf then
      local mark = api.nvim_buf_set_extmark(buf, frames_ns, 0, lnum, 0, {})
      frames_marks[mark] = frame
    end
  end
end

function M.open()
  if win and api.nvim_win_is_valid(win) and api.nvim_win_get_buf(win) == buf then
    return
  end
  if not buf then
    buf = api.nvim_create_buf(true, true)
    api.nvim_buf_set_name(buf, '[dap-repl]')
    api.nvim_buf_set_option(buf, 'buftype', 'prompt')
    api.nvim_buf_set_option(buf, 'omnifunc', 'v:lua.dap.omnifunc')
    api.nvim_buf_set_keymap(buf, 'n', '<CR>', "<Cmd>lua require('dap').repl.on_enter()<CR>", {})
    api.nvim_buf_set_keymap(buf, 'i', '<up>', "<Cmd>lua require('dap').repl.on_up()<CR>", {})
    api.nvim_buf_set_keymap(buf, 'i', '<down>', "<Cmd>lua require('dap').repl.on_down()<CR>", {})
    vim.fn.prompt_setprompt(buf, 'dap> ')
    vim.fn.prompt_setcallback(buf, 'dap#repl_execute')
    api.nvim_buf_attach(buf, false, {
      on_lines = function(b)
        api.nvim_buf_set_option(b, 'modified', false)
      end;
      on_changedtick = function(b)
        api.nvim_buf_set_option(b, 'modified', false)
      end;
      on_detach = function()
        buf = nil
        return true
      end;
    })
  end
  local current_win = api.nvim_get_current_win()
  api.nvim_command('belowright new')
  win = api.nvim_get_current_win()
  api.nvim_win_set_buf(win, buf)
  api.nvim_set_current_win(current_win)
end


function M.on_enter()
  if not buf or not session then
    return
  end
  local lnum = api.nvim_win_get_cursor(0)[1]
  local start = {lnum - 1, 0}
  local frame_marks = api.nvim_buf_get_extmarks(buf, frames_ns, start, start, {})
  if #frame_marks > 0 then
    local mark_id = frame_marks[1][1]
    local frame = frames_marks[mark_id]
    if frame then
      session:_frame_set(frame)
      local new_marks = {}
      for m, f in pairs(frames_marks) do
        local mark = api.nvim_buf_get_extmark_by_id(buf, frames_ns, m)
        local line =  mark[1]
        if f.id == frame.id then
          api.nvim_buf_set_lines(buf, line, line + 1, true, {'→ '..f.name})
        else
          api.nvim_buf_set_lines(buf, line, line + 1, true, {'  '..f.name})
        end
        local new_mark = api.nvim_buf_set_extmark(buf, frames_ns, 0, line, 0, {})
        new_marks[new_mark] = f
      end
      frames_marks = new_marks
    end
  end
end


local function select_history(delta)
  if not buf then
    return
  end
  history.idx = history.idx + delta
  if history.idx < 1 then
    history.idx = #history.entries
  elseif history.idx > #history.entries then
    history.idx = 1
  end
  local text = history.entries[history.idx]
  local lnum = vim.fn.line('$') - 1
  api.nvim_buf_set_lines(buf, lnum, lnum + 1, true, {'dap> ' .. text })
end


function M.on_up()
  select_history(-1)
end

function M.on_down()
  select_history(1)
end


function M.append(line, lnum)
  if buf then
    if api.nvim_get_current_win() == win and lnum == '$' then
      lnum = nil
    end
    local lines = vim.split(line, '\n')
    lnum = lnum or (vim.fn.line('$') - 1)
    vim.fn.appendbufline(buf, lnum, lines)
    return lnum
  end
  return nil
end


function M.execute(text)
  if text == '' then
    if history.last then
      text = history.last
    else
      return
    end
  else
    history.last = text
    table.insert(history.entries, text)
    history.idx = #history.entries + 1
  end
  if vim.tbl_contains(M.commands.exit, text) then
    if session then
      session:disconnect()
    end
    api.nvim_command('close')
    return
  end
  if not session then
    M.append('No active debug session')
    return
  end
  if vim.tbl_contains(M.commands.continue, text) then
    session:_step('continue')
  elseif vim.tbl_contains(M.commands.next_, text) then
    session:_step('next')
  elseif vim.tbl_contains(M.commands.into, text) then
    session:_step('stepIn')
  elseif vim.tbl_contains(M.commands.out, text) then
    session:_step('stepOut')
  elseif vim.tbl_contains(M.commands.up, text) then
    session:_frame_delta(1)
    M.print_stackframes()
  elseif vim.tbl_contains(M.commands.down, text) then
    session:_frame_delta(-1)
    M.print_stackframes()
  elseif vim.tbl_contains(M.commands.goto_, vim.split(text, ' ')[1]) then
    local split = vim.split(text, ' ')
    if split[2] then
      session:_goto(tonumber(split[2]))
    end
  elseif vim.tbl_contains(M.commands.scopes, text) then
    local frame = session.current_frame
    if frame then
      for _, scope in pairs(frame.scopes) do
        M.append(string.format("%s  (frame: %s)", scope.name, frame.name))
        for _, variable in pairs(scope.variables) do
          M.append(string.rep(' ', 2) .. variable.name .. ': ' .. variable.value)
        end
      end
    end
  elseif vim.tbl_contains(M.commands.threads, text) then
    for _, thread in pairs(session.threads) do
      if session.stopped_thread_id == thread.id then
        M.append('→ ' .. thread.name)
      else
        M.append('  ' .. thread.name)
      end
    end
  elseif vim.tbl_contains(M.commands.frames, text) then
    M.print_stackframes()
  else
    local lnum = vim.fn.line('$') - 1
    session:evaluate(text, function(err, resp)
      if err then
        M.append(err.message, lnum)
      else
        M.append(resp.result, lnum)
      end
    end)
  end
end


function M.set_session(s)
  session = s
  history.last = nil
  history.entries = {}
  history.idx = 1
  if s and buf and api.nvim_buf_is_loaded(buf) then
    api.nvim_buf_set_lines(buf, 0, -1, true, {})
  end
end


return M
