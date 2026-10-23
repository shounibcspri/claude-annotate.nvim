-- Annotate Claude Code's output like a code review. Two ways open the review:
--   editor.lua  Claude Code's own ctrl+g; submit fills Claude's input
--   tmux.lua    a tmux popup on prefix + i, once its binding is installed; submit sends
-- Both open the same review buffer, annotate.lua.

local M = {}

---@class ClaudeAnnotateConfig
---@field last_n_response integer how many of Claude's latest responses to show, each with your prompt
---@field prefix string marks a comment line in the buffer
---@field keys { comment: string, submit: string, quit: string }
local config = {
  last_n_response = 10,
  prefix = '>> ',
  keys = {
    comment = '<leader>cm',
    submit = '<leader>pp',
    quit = 'q',
  },
}

---@return ClaudeAnnotateConfig
function M.config() return config end

local hooked = false

-- ctrl+g runs $VISUAL, else $EDITOR, on a temp file named claude-prompt-<uuid>.md. Run by
-- plugin/ at startup, and by setup for a config that links the Lua module alone.
function M.hook()
  if hooked then return end
  hooked = true
  local file = vim.fn.argc() == 1 and vim.fn.fnamemodify(vim.fn.argv(0), ':p')
  if file and vim.fs.basename(file):match '^claude%-prompt%-.+%.md$' then require('claude-annotate.editor').attach(file) end
end

---@param opts ClaudeAnnotateConfig?
function M.setup(opts)
  config = vim.tbl_deep_extend('force', config, opts or {})
  M.hook()
end

-- what the tmux binding calls
---@param pane string tmux pane id to review, e.g. '%35'
function M.open(pane) require('claude-annotate.tmux').open(pane, config) end

return M
