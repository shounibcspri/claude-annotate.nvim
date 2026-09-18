-- Annotate Claude Code's output like a code review.
--
-- Launched by a tmux binding (see tmux/claude-review.conf), which opens this in a
-- popup over the Claude pane and passes that pane's id in. Select a block and
-- <leader>cm attaches a comment to it; <leader>pp pastes every comment back into
-- the pane and submits.

local M = {}

local PREFIX = '>> '
local HISTORY_LINES = 2000
local TMUX_BUFFER = 'claude-review'

-- Excerpts cannot be re-derived from the buffer once comment lines are interleaved,
-- so keep them here, keyed by bufnr then comment number.
local excerpts = {}

local function tmux(args)
  local res = vim.system(vim.list_extend({ 'tmux' }, args), { text = true }):wait()
  if res.code ~= 0 then error('tmux failed: ' .. (res.stderr or '')) end
  return res.stdout or ''
end

-- Only the full `>> [n] text` shape counts as one of ours. A bare prefix test also
-- claimed Claude's own output whenever it began with the prefix -- quoted text, a
-- diff -- and such a line then dropped out of the excerpt with nothing said.
local COMMENT_PATTERN = '^' .. PREFIX:gsub('%p', '%%%0') .. '%[(%d+)%]%s*(.*)$'

---@return string? n, string? text
local function parse_comment(line) return line:match(COMMENT_PATTERN) end

local function is_comment(line) return parse_comment(line) ~= nil end

-- Reshape the capture into the subset of ANSI baleia can render.
local function normalize_ansi(text)
  -- OSC 8 hyperlink wrappers carry no colour and would show up as literal junk
  text = text:gsub('\27%]8;.-[\27\7]\\?', '')
  -- Neovim has no dim attribute, so faint text (Claude's "+N lines" hints) would come
  -- out at full strength. Standing in the grey Claude itself uses for secondary text
  -- keeps the contrast; dim is only ever emitted bare, so nothing else is clobbered.
  return (text:gsub('\27%[2m', '\27[38;5;246m'))
end

local function strip_sgr(line) return (line:gsub('\27%[[%d;]*m', '')) end

---@param pane string tmux pane id to review, e.g. '%35'
function M.open(pane)
  -- -J rejoins the terminal's own hard wrapping, so one paragraph is one line and a
  -- bare `V` grabs a whole thought instead of a fragment
  -- -e keeps the SGR escape codes so baleia can restore Claude's bold and colours
  local captured = tmux { 'capture-pane', '-p', '-e', '-J', '-t', pane, '-S', '-' .. HISTORY_LINES }

  local lines = vim.split(normalize_ansi(captured), '\n', { plain = true })
  -- a trailing blank line is not literally empty under -e: it still carries a reset
  while #lines > 0 and strip_sgr(lines[#lines]):match '^%s*$' do
    table.remove(lines)
  end
  if #lines == 0 then return vim.notify('claude-review: pane ' .. pane .. ' is empty', vim.log.levels.WARN) end

  local baleia_ok, baleia = pcall(require, 'baleia')
  if not baleia_ok then
    -- colour is a nicety, the excerpts are the point: a missing optional dependency
    -- should cost highlighting, not fill the buffer with literal escape codes
    lines = vim.tbl_map(strip_sgr, lines)
    vim.notify('claude-review: baleia.nvim not found, output will not be coloured', vim.log.levels.WARN)
  end

  local buf = vim.api.nvim_create_buf(true, true)
  vim.api.nvim_buf_set_name(buf, 'claude-review://' .. pane)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  -- rewrites the lines without the escape codes and highlights them instead, so every
  -- later read of this buffer -- excerpts included -- sees plain text
  if baleia_ok then baleia.setup({}).once(buf) end
  vim.b[buf].claude_pane = pane
  excerpts[buf] = {}

  -- a leader sequence timing out in visual mode runs `c` raw, deleting the selection;
  -- timeoutlen is global-only, but this popup is its own process, so nothing leaks out
  vim.o.timeoutlen = 1000

  local opts = { buffer = buf, silent = true }
  vim.keymap.set(
    'n',
    '<leader>cm',
    function() M.comment(vim.fn.line '.', vim.fn.line '.') end,
    vim.tbl_extend('force', opts, { desc = 'Claude: co[m]ment this line' })
  )
  vim.keymap.set(
    'x',
    '<leader>cm',
    ':<C-u>lua require("claude-review").comment_visual()<CR>',
    vim.tbl_extend('force', opts, { desc = 'Claude: co[m]ment selection' })
  )
  vim.keymap.set('n', '<leader>pp', M.submit, vim.tbl_extend('force', opts, { desc = 'Claude: [p]ush comments' }))

  vim.api.nvim_win_set_buf(0, buf)
  vim.wo[0].linebreak = true -- -J lines are long; break them at spaces, not mid-word
  vim.api.nvim_win_set_cursor(0, { #lines, 0 })
end

function M.comment_visual() M.comment(vim.fn.line "'<", vim.fn.line "'>") end

function M.comment(first, last)
  local buf = vim.api.nvim_get_current_buf()
  if not excerpts[buf] then return vim.notify('claude-review: not a review buffer', vim.log.levels.WARN) end

  local selected = vim.api.nvim_buf_get_lines(buf, first - 1, last, false)
  -- a selection may span comment lines added earlier; they are not part of the excerpt
  local excerpt = vim.tbl_filter(function(l) return not is_comment(l) end, selected)
  -- blank lines inside a block are meaningful, but an all-blank excerpt anchors nothing
  if not vim.iter(excerpt):any(function(l) return l:match '%S' ~= nil end) then
    return vim.notify('claude-review: nothing to anchor a comment to', vim.log.levels.WARN)
  end

  vim.ui.input({ prompt = 'comment: ' }, function(input)
    if not input or input == '' then return end
    local n = vim.tbl_count(excerpts[buf]) + 1
    excerpts[buf][n] = excerpt
    vim.api.nvim_buf_set_lines(buf, last, last, false, { ('%s[%d] %s'):format(PREFIX, n, input) })
  end)
end

function M.submit()
  local buf = vim.api.nvim_get_current_buf()
  local pane = vim.b[buf].claude_pane
  if not pane or not excerpts[buf] then return vim.notify('claude-review: not a review buffer', vim.log.levels.WARN) end

  local out = { 'Comments on your last response:', '' }
  local count = 0
  local seen = {}
  -- walk in buffer order, so deleting a comment line drops it from the submission
  -- and editing one picks up the new text
  for _, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    local n, text = parse_comment(line)
    local excerpt = n and excerpts[buf][tonumber(n)]
    -- a yanked-and-put comment line carries its number along, and one note quoted
    -- twice reads to Claude as two separate objections
    if excerpt and not seen[n] then
      seen[n] = true
      count = count + 1
      -- the buffer's own number, not a fresh counter: deleting a comment leaves a
      -- gap, and a gap is better than Claude calling [3] something you can still
      -- see labelled [4] on your screen
      table.insert(out, ('[%s] on:'):format(n))
      for _, e in ipairs(excerpt) do
        table.insert(out, '> ' .. e)
      end
      table.insert(out, 'comment: ' .. text)
      table.insert(out, '')
    end
  end

  if count == 0 then return vim.notify('claude-review: no comments to submit', vim.log.levels.WARN) end

  local tmpfile = vim.fn.tempname()
  vim.fn.writefile(out, tmpfile)
  tmux { 'load-buffer', '-b', TMUX_BUFFER, tmpfile }
  -- -p wraps in bracketed paste so the newlines do not submit line by line
  tmux { 'paste-buffer', '-b', TMUX_BUFFER, '-d', '-p', '-t', pane }
  -- block rather than defer: we exit immediately after, and a deferred timer would
  -- die with nvim, leaving the text pasted but never submitted
  vim.wait(200)
  tmux { 'send-keys', '-t', pane, 'Enter' }

  -- closes the popup, revealing the reply
  vim.cmd 'qa!'
end

vim.api.nvim_create_autocmd('BufDelete', {
  callback = function(ev) excerpts[ev.buf] = nil end,
})

return M
