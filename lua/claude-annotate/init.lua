-- Annotate Claude Code's output like a code review.
--
-- Launched by a tmux binding (see tmux/claude-annotate.conf), which opens this in a
-- popup over the Claude pane and passes that pane's id in. Select a block and the
-- comment key attaches a note to it; the submit key pastes every note back into the
-- pane as one message and submits.

local M = {}

---@class ClaudeAnnotateConfig
---@field turns integer how many of your latest prompts to show, each with its reply
---@field prefix string marks a comment line in the buffer
---@field keys { comment: string, submit: string, quit: string }
local config = {
  turns = 10,
  prefix = '>> ',
  keys = {
    comment = '<leader>cm',
    submit = '<leader>pp',
    quit = 'q',
  },
}

-- tmux clipboard slot; internal, and nothing is gained by letting it be renamed
local TMUX_BUFFER = 'claude-annotate'

local CLAUDE_DIR = vim.fn.expand '~/.claude'

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
local comment_pattern

-- rebuilt when the prefix changes rather than per line, and escaped because a
-- configured prefix may hold characters Lua patterns treat as syntax
local function compile_pattern()
  comment_pattern = '^' .. config.prefix:gsub('%p', '%%%0') .. '%[(%d+)%]%s*(.*)$'
end
compile_pattern()

---@param opts ClaudeAnnotateConfig?
function M.setup(opts)
  config = vim.tbl_deep_extend('force', config, opts or {})
  compile_pattern()
end

---@return string? n, string? text
local function parse_comment(line) return line:match(comment_pattern) end

local function is_comment(line) return parse_comment(line) ~= nil end

-- as vim.NIL, JSON null is truthy: a compaction's null parentUuid would then hide the
-- logicalParentUuid beside it
local function decode(json)
  local ok, value = pcall(vim.json.decode, json, { luanil = { object = true, array = true } })
  if ok and type(value) == 'table' then return value end
end

-- Not the pane: Claude wraps its text at the pane's width as it writes it, so a capture
-- breaks lines at whatever width the pane had then, and a pane on the alternate screen
-- keeps no scrollback at all. The transcript holds the markdown as Claude wrote it.
--
-- Each Claude process registers in sessions/<pid>.json. Searching only the pane's own
-- process tree, nearest first, rules out a crashed Claude's leftover file, a reused pid
-- and a pane with the same id on another tmux server. A pane showing a background session
-- is a viewer: its own session is parked, and parkedJobId names the job on screen, whose
-- session id starts with that job id.
---@return string? path, integer? pid
local function transcript_for(pane)
  local queue = { tonumber(tmux { 'display', '-p', '-t', pane, '#{pane_pid}' }) }
  local i = 1
  while queue[i] do
    local path = ('%s/sessions/%d.json'):format(CLAUDE_DIR, queue[i])
    if vim.uv.fs_stat(path) then
      local s = decode(table.concat(vim.fn.readfile(path), '\n'))
      local id = s and (s.parkedJobId or s.sessionId)
      return id and vim.fn.glob(('%s/projects/*/%s*.jsonl'):format(CLAUDE_DIR, id), false, true)[1], queue[i]
    end
    vim.list_extend(queue, vim.api.nvim_get_proc_children(queue[i]))
    i = i + 1
  end
end

-- Only what you typed starts a turn, and much else is filed as a user record: tool
-- results, slash commands, task notifications, messages from other sessions. A prompt
-- typed while Claude is busy is queued, and recorded only as an attachment.
---@return string? text
local function prompt_text(rec)
  if rec.type == 'attachment' then
    local a = rec.attachment
    local queued = a and a.type == 'queued_command' and a.origin and a.origin.kind == 'human'
    return queued and type(a.prompt) == 'string' and a.prompt or nil
  end
  if rec.type ~= 'user' or not (rec.origin and rec.origin.kind == 'human') then return nil end
  local content = rec.message and rec.message.content
  if type(content) == 'string' then return content end
  local texts = {}
  for _, block in ipairs(content or {}) do
    if block.type == 'tool_result' then return nil end
    if block.type == 'text' then table.insert(texts, block.text) end
  end
  return table.concat(texts, '\n')
end

-- The file is a tree: an edited or re-sent prompt leaves its old branch behind, so the
-- conversation is the chain of parents back from the newest record. A compaction starts
-- a new chain, whose root links the old one as its logicalParentUuid.
---@return { prompt: string, reply: string[] }[] turns oldest first
local function read_turns(path)
  local by_uuid, newest = {}, nil
  for line in io.lines(path) do
    local rec = decode(line)
    if rec and rec.uuid then
      by_uuid[rec.uuid] = rec
      -- subagents write to the same file, and an agent's report is not the reply you saw
      if (rec.type == 'user' or rec.type == 'assistant') and not rec.isSidechain then newest = rec end
    end
  end

  local chain = {}
  local rec = newest
  while rec do
    table.insert(chain, rec)
    rec = by_uuid[rec.parentUuid or rec.logicalParentUuid]
  end

  local turns = {}
  for i = #chain, 1, -1 do
    local prompt = prompt_text(chain[i])
    local turn = turns[#turns]
    -- prompts sent before Claude says anything share the one reply that follows
    if prompt and turn and #turn.reply == 0 then
      turn.prompt = turn.prompt .. '\n\n' .. prompt
    elseif prompt then
      table.insert(turns, { prompt = prompt, reply = {} })
    elseif turn and chain[i].type == 'assistant' then
      for _, block in ipairs(chain[i].message.content) do
        if block.type == 'text' then table.insert(turn.reply, block.text) end
      end
    end
  end
  return turns
end

-- Your prompts as markdown quotes, which the syntax sets apart. Claude's text is indented
-- the way Claude Code indents it, which also keeps any line of it from reading as a comment.
---@return string[] lines
local function render(turns)
  local lines = {}
  local function add(text, lead)
    text = text:match '^\n*(.-)\n*$'
    if not text:match '%S' then return end
    if #lines > 0 then table.insert(lines, '') end
    for _, l in ipairs(vim.split(text, '\n', { plain = true })) do
      local line = (lead .. l):gsub('%s+$', '')
      -- a configured prefix can still make a line pass for a comment, such as `> ` with an
      -- earlier submission's `> [1] on:`; a zero-width space in front stops it matching
      table.insert(lines, is_comment(line) and '\226\128\139' .. line or line)
    end
  end
  for i = math.max(1, #turns - config.turns + 1), #turns do
    -- counted from the end, the way you refer to them; markdown's [[ and ]] jump between them
    local back = #turns - i + 1
    add(back == 1 and 'Last response' or ('Response -%d'):format(back), '## ')
    add(turns[i].prompt, '> ')
    for _, text in ipairs(turns[i].reply) do
      add(text, '  ')
    end
  end
  return lines
end

---@param pane string tmux pane id to review, e.g. '%35'
function M.open(pane)
  local transcript, pid = transcript_for(pane)
  if not transcript then
    return vim.notify('claude-annotate: no Claude session found in pane ' .. pane, vim.log.levels.WARN)
  end
  local lines = render(read_turns(transcript))
  if #lines == 0 then
    return vim.notify('claude-annotate: nothing to review yet in ' .. transcript, vim.log.levels.WARN)
  end

  local buf = vim.api.nvim_create_buf(true, true)
  -- the session id, so which conversation you are looking at can be read at a glance
  vim.api.nvim_buf_set_name(buf, 'claude-annotate://' .. vim.fn.fnamemodify(transcript, ':t:r'))
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = 'markdown'
  -- a conversation, not a document: markdownlint's line length rule alone flags every paragraph
  vim.diagnostic.enable(false, { bufnr = buf })
  vim.b[buf].claude_pane = pane
  vim.b[buf].claude_pid = pid
  excerpts[buf] = {}

  -- a leader sequence timing out in visual mode runs `c` raw, deleting the selection;
  -- timeoutlen is global-only, but this popup is its own process, so nothing leaks out
  vim.o.timeoutlen = 1000

  local opts = { buffer = buf, silent = true }
  local function map(mode, lhs, rhs, desc)
    if lhs and lhs ~= '' then vim.keymap.set(mode, lhs, rhs, vim.tbl_extend('force', opts, { desc = desc })) end
  end

  map(
    'n',
    config.keys.comment,
    function() M.comment(vim.fn.line '.', vim.fn.line '.') end,
    'Claude: co[m]ment this line'
  )
  map(
    'x',
    config.keys.comment,
    ':<C-u>lua require("claude-annotate").comment_visual()<CR>',
    'Claude: co[m]ment selection'
  )
  map('n', config.keys.submit, M.submit, 'Claude: [p]ush comments')
  -- setting the lines marks the buffer modified, so plain `:q` refuses and leaving
  -- without commenting meant typing `:qa!`. Recording a macro in a snapshot you are
  -- about to throw away is not a thing anyone wants to do.
  map('n', config.keys.quit, '<Cmd>qa!<CR>', 'Claude: [q]uit, discard comments')

  vim.api.nvim_win_set_buf(0, buf)
  -- a paragraph arrives as one line: wrap it at spaces, under its list marker if it has one
  vim.wo[0].linebreak = true
  vim.wo[0].breakindent = true
  vim.wo[0].breakindentopt = 'list:-1'
  vim.api.nvim_win_set_cursor(0, { #lines, 0 })
end

function M.comment_visual() M.comment(vim.fn.line "'<", vim.fn.line "'>") end

function M.comment(first, last)
  local buf = vim.api.nvim_get_current_buf()
  if not excerpts[buf] then return vim.notify('claude-annotate: not a review buffer', vim.log.levels.WARN) end

  local selected = vim.api.nvim_buf_get_lines(buf, first - 1, last, false)
  -- a selection may span comment lines added earlier; they are not part of the excerpt
  local excerpt = vim.tbl_filter(function(l) return not is_comment(l) end, selected)
  -- blank lines inside a block are meaningful, but an all-blank excerpt anchors nothing
  if not vim.iter(excerpt):any(function(l) return l:match '%S' ~= nil end) then
    return vim.notify('claude-annotate: nothing to anchor a comment to', vim.log.levels.WARN)
  end

  vim.ui.input({ prompt = 'comment: ' }, function(input)
    if not input or input == '' then return end
    local n = vim.tbl_count(excerpts[buf]) + 1
    excerpts[buf][n] = excerpt
    vim.api.nvim_buf_set_lines(buf, last, last, false, { ('%s[%d] %s'):format(config.prefix, n, input) })
  end)
end

function M.submit()
  local buf = vim.api.nvim_get_current_buf()
  local pane = vim.b[buf].claude_pane
  if not pane or not excerpts[buf] then return vim.notify('claude-annotate: not a review buffer', vim.log.levels.WARN) end

  local out = { 'Comments on this conversation:', '' }
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

  if count == 0 then return vim.notify('claude-annotate: no comments to submit', vim.log.levels.WARN) end

  local tmpfile = vim.fn.tempname()
  vim.fn.writefile(out, tmpfile)
  local sent, err = pcall(function()
    -- a suspended or exited Claude leaves a shell in front, which would run the excerpts as
    -- commands: a line like `>   notes.md is …` empties notes.md
    local front = vim.trim(tmux { 'display', '-p', '-t', pane, '#{pane_current_command}' })
    local claude = vim.api.nvim_get_proc(vim.b[buf].claude_pid)
    if not claude or claude.name ~= front then error(front .. ' is in front, not Claude', 0) end
    tmux { 'load-buffer', '-b', TMUX_BUFFER, tmpfile }
    -- -p wraps in bracketed paste so the newlines do not submit line by line
    tmux { 'paste-buffer', '-b', TMUX_BUFFER, '-d', '-p', '-t', pane }
    -- block rather than defer: we exit immediately after, and a deferred timer would
    -- die with nvim, leaving the text pasted but never submitted
    vim.wait(200)
    tmux { 'send-keys', '-t', pane, 'Enter' }
  end)
  -- the pane can be killed or given to another program while the popup is open; stay
  -- open on failure so the comments are still there to copy out
  if not sent then
    return vim.notify('claude-annotate: could not reach pane ' .. pane .. ': ' .. tostring(err), vim.log.levels.ERROR)
  end

  -- closes the popup, revealing the reply
  vim.cmd 'qa!'
end

-- clear = true, so reloading the module replaces this rather than stacking another copy
vim.api.nvim_create_autocmd('BufDelete', {
  group = vim.api.nvim_create_augroup('claude-annotate', { clear = true }),
  callback = function(ev) excerpts[ev.buf] = nil end,
})

return M
