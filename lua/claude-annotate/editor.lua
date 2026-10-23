-- Claude Code's ctrl+g: it opens nvim on its prompt file, and this opens the annotate
-- buffer instead. Submit writes the message into that file, which Claude loads into its
-- input once nvim exits; Enter sends it.

local annotate = require 'claude-annotate.annotate'

local M = {}

-- The Claude whose ctrl+g started this nvim. An ancestor rather than the parent: the code
-- runs in `nvim --embed`, a child of the nvim process drawing the screen.
---@return integer? pid
local function claude_above()
  local proc = vim.api.nvim_get_proc(vim.fn.getpid())
  while proc and proc.ppid > 1 do
    if annotate.registered(proc.ppid) then return proc.ppid end
    proc = vim.api.nvim_get_proc(proc.ppid)
  end
end

-- A draft typed before ctrl+g stays in front of the notes.
local function save(prompt, lines)
  while lines[#lines] == '' do
    table.remove(lines)
  end
  local draft = vim.fn.readfile(prompt)
  if table.concat(draft):match '%S' then lines = vim.list_extend(vim.list_extend(draft, { '' }), lines) end
  vim.fn.writefile(lines, prompt)
  vim.cmd 'qa!'
end

---@param file string the prompt file nvim was started on
function M.attach(file)
  -- read at VimEnter, so a setup that runs after plugin/ still counts; started on such a
  -- file by something other than Claude, nvim just edits it
  local function edit()
    local config = require('claude-annotate').config()
    local pid = claude_above()
    local transcript = pid and annotate.transcript_of(pid)
    if transcript and not annotate.open(transcript, config, function(lines) save(file, lines) end) then
      vim.notify 'claude-annotate: nothing to annotate yet, so this is the prompt as usual'
    end
  end
  if vim.v.vim_did_enter == 1 then
    edit()
  else
    vim.api.nvim_create_autocmd('VimEnter', { once = true, callback = edit })
  end
end

return M
