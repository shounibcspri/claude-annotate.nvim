-- The annotate buffer that editor.lua and tmux.lua open: the conversation, read from Claude
-- Code's transcript, and comments attached to excerpts of it. Select a block and the
-- comment key attaches a note. Saving (:w, :wq) turns every note into one message and hands
-- it to the opener's save, which puts it in Claude's prompt; the push key hands it to the
-- opener's push, which also sends it where it can. Both close nvim once they worked.
local M = {}

-- clear = true, so reloading the module replaces its autocmds rather than stacking copies
local group = vim.api.nvim_create_augroup('claude-annotate', { clear = true })

local CLAUDE_DIR = vim.fn.expand '~/.claude'

-- the config of the annotate on screen
local config

-- Excerpts cannot be re-derived from the buffer once comment lines are interleaved,
-- so keep them here, keyed by bufnr then comment number.
local excerpts = {}
-- the opener's save and push, keyed by bufnr
local handlers = {}

-- Only the full `>> [n] text` shape counts as one of ours. A bare prefix test also
-- claimed Claude's own output whenever it began with the prefix -- quoted text, a
-- diff -- and such a line then dropped out of the excerpt with nothing said.
local comment_pattern

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
-- Each Claude process registers in sessions/<pid>.json.
function M.registered(pid) return vim.uv.fs_stat(('%s/sessions/%d.json'):format(CLAUDE_DIR, pid)) ~= nil end

-- A pane showing a background session is a viewer: its own session is parked, and
-- parkedJobId names the job on screen, whose session id starts with that job id.
---@return string? path
function M.transcript_of(pid)
  local s = decode(table.concat(vim.fn.readfile(('%s/sessions/%d.json'):format(CLAUDE_DIR, pid)), '\n'))
  local id = s and (s.parkedJobId or s.sessionId)
  return id and vim.fn.glob(('%s/projects/*/%s*.jsonl'):format(CLAUDE_DIR, id), false, true)[1]
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

-- Every record names the one before it, its parentUuid. Editing or re-sending a prompt
-- starts a new branch from the same parent, and the old branch stays in the file:
--
--   A - B - C            C: your prompt before the edit
--        \- C' - D       C': the edited prompt, D: Claude's reply to it
--
-- Read top to bottom, the file holds both branches. Walking back from the newest record
-- (D) through the parents gives D C' B A, only the conversation you are in. A compaction
-- starts a new chain, whose first record points at the old chain's last one through
-- logicalParentUuid, so the walk carries on into it.
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

  -- The chain is newest first, so walk it backwards, grouping records into turns: a prompt
  -- of yours starts one, and Claude's text blocks after it are its reply. Everything else,
  -- tool calls and their results included, is skipped.
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
  for i = math.max(1, #turns - config.last_n_response + 1), #turns do
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

---@param transcript string the session's .jsonl
---@param cfg ClaudeAnnotateConfig
---@param opener { save: fun(lines: string[]): boolean, push: fun(lines: string[]): boolean }
---@return boolean opened false when the session has nothing to annotate yet
function M.open(transcript, cfg, opener)
  config = cfg
  -- escaped, because a configured prefix may hold characters Lua patterns treat as syntax
  comment_pattern = '^' .. config.prefix:gsub('%p', '%%%0') .. '%[(%d+)%]%s*(.*)$'

  local lines = render(read_turns(transcript))
  if #lines == 0 then return false end

  local buf = vim.api.nvim_create_buf(true, true)
  -- the session id, so which conversation you are looking at can be read at a glance
  vim.api.nvim_buf_set_name(buf, 'claude-annotate://' .. vim.fn.fnamemodify(transcript, ':t:r'))
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  -- written by the plugin, so :w saves the comments. Unmodified until you comment, so a
  -- plain :q leaves; once you have, :q asks for :q! like any editor before losing them
  vim.bo[buf].buftype = 'acwrite'
  vim.bo[buf].modified = false
  vim.api.nvim_create_autocmd('BufWriteCmd', { group = group, buffer = buf, callback = function() M.save() end })
  vim.bo[buf].filetype = 'markdown'
  -- a conversation, not a document: markdownlint's line length rule alone flags every paragraph
  vim.diagnostic.enable(false, { bufnr = buf })
  excerpts[buf] = {}
  handlers[buf] = opener

  -- a leader sequence timing out in visual mode runs `c` raw, deleting the selection;
  -- timeoutlen is global-only, but this nvim runs for annotating alone, so nothing leaks out
  vim.o.timeoutlen = 1000

  local opts = { buffer = buf, silent = true }
  local function map(mode, lhs, rhs, desc)
    if lhs and lhs ~= '' then vim.keymap.set(mode, lhs, rhs, vim.tbl_extend('force', opts, { desc = desc })) end
  end

  -- The buffer's keys, from config.keys, which exist only in this buffer: comment the
  -- current line (normal mode) or the selection (visual mode), and push.
  map(
    'n',
    config.keys.comment,
    function() M.comment(vim.fn.line '.', vim.fn.line '.') end,
    'Claude: co[m]ment this line'
  )
  map(
    'x',
    config.keys.comment,
    ':<C-u>lua require("claude-annotate.annotate").comment_visual()<CR>',
    'Claude: co[m]ment selection'
  )
  map('n', config.keys.submit, M.push, 'Claude: [p]ush comments')

  vim.api.nvim_win_set_buf(0, buf)
  -- a paragraph arrives as one line: wrap it at spaces, under its list marker if it has one
  vim.wo[0].linebreak = true
  vim.wo[0].breakindent = true
  vim.wo[0].breakindentopt = 'list:-1'
  vim.api.nvim_win_set_cursor(0, { #lines, 0 })
  return true
end

function M.comment_visual() M.comment(vim.fn.line "'<", vim.fn.line "'>") end

function M.comment(first, last)
  local buf = vim.api.nvim_get_current_buf()
  if not excerpts[buf] then return vim.notify('claude-annotate: not an annotate buffer', vim.log.levels.WARN) end

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

-- Every note as one message, or nil when there is none. The buffer is read in order, so
-- deleting a comment line drops it, and editing one picks up the new text.
---@return string[]? lines
local function message(buf)
  -- split, since writefile would turn a newline inside one line into a NUL
  local out = config.header ~= '' and vim.split(config.header, '\n', { plain = true }) or {}
  local seen = {}
  for _, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    local n, text = parse_comment(line)
    local excerpt = n and excerpts[buf][tonumber(n)]
    -- a yanked-and-put comment line carries its number along, and one note quoted
    -- twice reads to Claude as two separate objections
    if excerpt and not seen[n] then
      seen[n] = true
      -- the buffer's own number, not a fresh counter: deleting a comment leaves a
      -- gap, and a gap is better than Claude calling [3] something you can still
      -- see labelled [4] on your screen
      if #out > 0 then table.insert(out, '') end
      table.insert(out, ('[%s] on:'):format(n))
      for _, e in ipairs(excerpt) do
        table.insert(out, '> ' .. e)
      end
      table.insert(out, 'comment: ' .. text)
    end
  end
  if next(seen) then return out end
end

---@param how 'save'|'push'
local function deliver(how)
  local buf = vim.api.nvim_get_current_buf()
  if not excerpts[buf] then return vim.notify('claude-annotate: not an annotate buffer', vim.log.levels.WARN) end
  local lines = message(buf)
  if not lines then
    -- nothing to lose by leaving, so :wq goes on to quit
    vim.bo[buf].modified = false
    return vim.notify('claude-annotate: no comments to send', vim.log.levels.WARN)
  end
  -- a failed paste stays open, still modified, so the comments are there to retry
  if handlers[buf][how](lines) then
    vim.bo[buf].modified = false
    vim.cmd 'qa!'
  end
end

-- :w and :wq: put the comments in Claude's prompt
function M.save() deliver 'save' end

-- the push key: put them there and send them, where the opener can
function M.push() deliver 'push' end

vim.api.nvim_create_autocmd('BufDelete', {
  group = group,
  callback = function(ev)
    excerpts[ev.buf] = nil
    handlers[ev.buf] = nil
  end,
})

return M
