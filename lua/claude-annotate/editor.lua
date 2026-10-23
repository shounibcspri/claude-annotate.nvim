-- Claude Code's ctrl+g: it opens nvim on its prompt file, and this opens the annotate
-- buffer instead. Saving writes the message into that file, which Claude loads into its
-- input once nvim exits; Enter there sends it. Nothing in Claude's editor can send, so
-- <leader>pp saves too.

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
---@return boolean saved
local function save(prompt, draft, lines)
  if table.concat(draft):match '%S' then lines = vim.list_extend(vim.list_extend(vim.deepcopy(draft), { '' }), lines) end
  vim.fn.writefile(lines, prompt)
  return true
end

---@param file string the prompt file nvim was started on
function M.attach(file)
  -- read at VimEnter, so a setup that runs after plugin/ still counts; started on such a
  -- file by something other than Claude, nvim just edits it
  local function edit()
    local config = require('claude-annotate').config()
    local pid = claude_above()
    local transcript = pid and annotate.transcript_of(pid)
    if not transcript then return end
    -- read now, before anything writes the file
    local draft = vim.fn.readfile(file)
    local function to_prompt(lines) return save(file, draft, lines) end
    if not annotate.open(transcript, config, { save = to_prompt, push = to_prompt }) then
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
