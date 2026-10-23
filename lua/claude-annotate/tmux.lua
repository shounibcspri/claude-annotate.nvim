-- The tmux popup, optional: its binding (see tmux/claude-annotate.conf) opens nvim in a
-- popup over the Claude pane and passes that pane's id in. Submit pastes the message into
-- the pane and presses Enter.

local annotate = require 'claude-annotate.annotate'

local M = {}

-- tmux clipboard slot; internal, and nothing is gained by letting it be renamed
local TMUX_BUFFER = 'claude-annotate'

local function tmux(args)
  local res = vim.system(vim.list_extend({ 'tmux' }, args), { text = true }):wait()
  if res.code ~= 0 then error('tmux failed: ' .. (res.stderr or '')) end
  return res.stdout or ''
end

-- Searching only the pane's own process tree, nearest first, rules out a crashed Claude's
-- leftover file, a reused pid and a pane with the same id on another tmux server.
---@return integer? pid
local function claude_in_pane(pane)
  local queue = { tonumber(tmux { 'display', '-p', '-t', pane, '#{pane_pid}' }) }
  local i = 1
  while queue[i] do
    if annotate.registered(queue[i]) then return queue[i] end
    vim.list_extend(queue, vim.api.nvim_get_proc_children(queue[i]))
    i = i + 1
  end
end

-- Pastes the message into Claude's prompt in the pane; with `enter`, also sends it.
---@return boolean pasted
local function paste(pane, pid, lines, enter)
  local tmpfile = vim.fn.tempname()
  -- binary, so no newline follows the last line and the prompt does not end on a blank one
  vim.fn.writefile(lines, tmpfile, 'b')
  local ok, err = pcall(function()
    -- a suspended or exited Claude leaves a shell in front, which would run the excerpts as
    -- commands: a line like `>   notes.md is …` empties notes.md
    local front = vim.trim(tmux { 'display', '-p', '-t', pane, '#{pane_current_command}' })
    local claude = vim.api.nvim_get_proc(pid)
    if not claude or claude.name ~= front then error((front ~= '' and front or 'nothing') .. ' is in front, not Claude', 0) end
    tmux { 'load-buffer', '-b', TMUX_BUFFER, tmpfile }
    -- -p wraps in bracketed paste so the newlines do not submit line by line
    tmux { 'paste-buffer', '-b', TMUX_BUFFER, '-d', '-p', '-t', pane }
    if enter then
      -- block rather than defer: nvim exits right after, and a deferred timer would die
      -- with it, leaving the text pasted but never sent
      vim.wait(200)
      tmux { 'send-keys', '-t', pane, 'Enter' }
    end
  end)
  -- the pane can be killed or given to another program while the popup is open; staying
  -- open on failure keeps the comments there to copy out
  if not ok then
    vim.notify('claude-annotate: could not reach pane ' .. pane .. ': ' .. tostring(err), vim.log.levels.ERROR)
  end
  return ok
end

-- Nothing to annotate: close the popup rather than leave a bare nvim behind, whose
-- unmapped <leader>pp would paste the last yank twice. The popup takes nvim's messages
-- with it, so the reason goes to tmux's status line.
local function leave(pane, why)
  pcall(tmux, { 'display-message', '-d', '3000', '-t', pane, 'claude-annotate: ' .. why })
  vim.cmd 'qa!'
end

---@param pane string tmux pane id to annotate, e.g. '%35'
---@param config ClaudeAnnotateConfig
function M.open(pane, config)
  local pid = claude_in_pane(pane)
  local transcript = pid and annotate.transcript_of(pid)
  if not transcript then return leave(pane, 'no Claude session in this pane') end
  local opened = annotate.open(transcript, config, {
    -- :w puts the comments in Claude's prompt for you to send; <leader>pp sends them too
    save = function(lines) return paste(pane, pid, lines, false) end,
    push = function(lines) return paste(pane, pid, lines, true) end,
  })
  if not opened then leave(pane, 'nothing to annotate yet') end
end

return M
