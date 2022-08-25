-- !::exe [luafile %]
--
-- render.lua
--

local char = string.char
local max = math.max
local min = math.min
local string_rep = string.rep
local table_insert = table.insert
local table_remove = table.remove
local table_sort = table.sort

local buf_delete = vim.api.nvim_buf_delete
local buf_get_lines = vim.api.nvim_buf_get_lines
local buf_get_name = vim.api.nvim_buf_get_name
local buf_get_option = vim.api.nvim_buf_get_option
local buf_line_count = vim.api.nvim_buf_line_count
local bufadd = vim.fn.bufadd
local bufwinnr = vim.fn.bufwinnr
local command = vim.api.nvim_command
local defer_fn = vim.defer_fn
local get_current_buf = vim.api.nvim_get_current_buf
local getchar = vim.fn.getchar
local has = vim.fn.has
local list_bufs = vim.api.nvim_list_bufs
local list_extend = vim.list_extend
local notify = vim.notify
local set_current_buf = vim.api.nvim_set_current_buf
local strcharpart = vim.fn.strcharpart
local strwidth = vim.api.nvim_strwidth
local tabpagenr = vim.fn.tabpagenr

-- TODO: remove `vim.fs and` after 0.8 release
local normalize = vim.fs and vim.fs.normalize

local animate = require'bufferline.animate'
local bbye = require'bufferline.bbye'
local Buffer = require'bufferline.buffer'
local bufferline = require'bufferline'
local icons = require'bufferline.icons'
local JumpMode = require'bufferline.jump_mode'
local Layout = require'bufferline.layout'
local state = require'bufferline.state'
local utils = require'bufferline.utils'

local ANIMATION_OPEN_DURATION   = 150
local ANIMATION_OPEN_DELAY      = 50
local ANIMATION_CLOSE_DURATION  = 150
local ANIMATION_SCROLL_DURATION = 200
local ANIMATION_MOVE_DURATION   = 150

--- The highlight to use based on the state of a buffer.
local HL_BY_ACTIVITY = {
  [0] = 'Inactive',
  [1] = 'Visible',
  [2] = 'Current',
}

--- The width of a left offset before the bufferline renders.
local offset = 0

--- The highlight group used for the offset.
--- @type nil|string
local offset_hl

--- The text which fills the offset.
--- @type nil|string
local offset_text

local function hl_tabline(name)
  return '%#' .. name .. '#'
end

-- A "group" is an array with the format { HL_GROUP, TEXT_CONTENT }

--- @class bufferline.Render.Group
--- @field hl string the highlight group to use
--- @field text string the content being rendered

--- Concatenates some `groups` into a valid string.
--- @param groups table<bufferline.Render.Group>
--- @return string
local function groups_to_string(groups)
  local result = ''

  for _, group in ipairs(groups) do
    local hl   = group[1]
    local text = group[2]
    -- WARN: We have to escape the text in case it contains '%', which is a special character to the
    --       tabline.
    --       To escape '%', we make it '%%'. It just so happens that '%' is also a special character
    --       in Lua, so we have write '%%' to mean '%'.
    result = result .. hl .. text:gsub('%%', '%%%%')
  end

  return result
end

--- Insert `others` into `groups` at the `position`.
--- @param groups table<bufferline.Render.Group>
--- @param position integer
--- @param others table<bufferline.Render.Group>
--- @return table<bufferline.Render.Group> with_insertions
local function groups_insert(groups, position, others)
  local current_position = 0

  local new_groups = {}

  local i = 1
  while i <= #groups do
    local group = groups[i]
    local group_width = strwidth(group[2])

    -- While we haven't found the position...
    if current_position + group_width <= position then
      table_insert(new_groups, group)
      i = i + 1
      current_position = current_position + group_width

    -- When we found the position...
    else
      local available_width = position - current_position

      -- Slice current group if it `position` is inside it
      if available_width > 0 then
        local new_group = { group[1], strcharpart(group[2], 0, available_width) }
        table_insert(new_groups, new_group)
      end

      -- Add new other groups
      local others_width = 0
      for _, other in ipairs(others) do
        local other_width = strwidth(other[2])
        others_width = others_width + other_width
        table_insert(new_groups, other)
      end

      local end_position = position + others_width

      -- Then, resume adding previous groups
      -- table.insert(new_groups, 'then')
      while i <= #groups do
        local previous_group = groups[i]
        local previous_group_width = strwidth(previous_group[2])
        local previous_group_start_position = current_position
        local previous_group_end_position   = current_position + previous_group_width

        if previous_group_end_position <= end_position and previous_group_width ~= 0 then
          -- continue
        elseif previous_group_start_position >= end_position then
          -- table.insert(new_groups, 'direct')
          table_insert(new_groups, previous_group)
        else
          local remaining_width = previous_group_end_position - end_position
          local start = previous_group_width - remaining_width
          local end_  = previous_group_width
          local new_group = { previous_group[1], strcharpart(previous_group[2], start, end_) }
          -- table.insert(new_groups, { group_start_position, group_end_position, end_position })
          table_insert(new_groups, new_group)
        end

        i = i + 1
        current_position = current_position + previous_group_width
      end

      break
    end
  end

  return new_groups
end

--- Select from `groups` while fitting within the provided `width`, discarding all indices larger than the last index that fits.
--- @param groups table<bufferline.Render.Group>
--- @param width integer
local function slice_groups_right(groups, width)
  local accumulated_width = 0

  local new_groups = {}

  for _, group in ipairs(groups) do
    local hl   = group[1]
    local text = group[2]
    local text_width = strwidth(text)

    accumulated_width = accumulated_width + text_width

    if accumulated_width >= width then
      local diff = text_width - (accumulated_width - width)
      local new_group = {hl, strcharpart(text, 0, diff)}
      table_insert(new_groups, new_group)
      break
    end

    table_insert(new_groups, group)
  end

  return new_groups
end

--- Select from `groups` in reverse while fitting within the provided `width`, discarding all indices less than the last index that fits.
--- @param groups table<bufferline.Render.Group>
--- @param width integer
local function slice_groups_left(groups, width)
  local accumulated_width = 0

  local new_groups = {}

  for _, group in ipairs(utils.reverse(groups)) do
    local hl   = group[1]
    local text = group[2]
    local text_width = strwidth(text)

    accumulated_width = accumulated_width + text_width

    if accumulated_width >= width then
      local length = text_width - (accumulated_width - width)
      local start = text_width - length
      local new_group = {hl, strcharpart(text, start, length)}
      table_insert(new_groups, 1, new_group)
      break
    end

    table_insert(new_groups, 1, group)
  end

  return new_groups
end

local function sort_pins_to_left()
  local unpinned = {}

  local i = 1
  while i <= #state.buffers do
    local bufnr = state.buffers[i]
    if state.is_pinned(bufnr) then
      i = i + 1
    else
      table_insert(unpinned, bufnr)
    end
  end

  state.buffers = list_extend(state.buffers, unpinned)
end

local function with_pin_order(order_func)
  return function(a, b)
    local a_pinned = state.is_pinned(a)
    local b_pinned = state.is_pinned(b)

    if a_pinned and not b_pinned then
      return true
    elseif b_pinned and not a_pinned then
      return false
    else
      return order_func(a, b)
    end
  end
end

--- @class bufferline.Render
--- @field private scroll integer the place where the bufferline is scrolled/wants to scroll to.
--- @field private scroll_current integer
local Render = {
  scroll = 0,
  scroll_current = 0,
}

--- Render the buffer jump mode.
function Render.activate_jump_mode()
  if JumpMode.reinitialize then
    JumpMode.initialize_indexes()
  end

  state.is_picking_buffer = true

  bufferline.update()
  command('redrawtabline')

  state.is_picking_buffer = false

  local ok, byte = pcall(getchar)
  if ok then
    local letter = char(byte)

    if letter ~= '' then
      if JumpMode.buffer_by_letter[letter] ~= nil then
        set_current_buf(JumpMode.buffer_by_letter[letter])
      else
        notify("Couldn't find buffer", vim.log.levels.WARN, {title = 'barbar.nvim'})
      end
    end
  else
    notify("Invalid input", vim.log.levels.WARN, {title = 'barbar.nvim'})
  end

  bufferline.update()
  command('redrawtabline')
end

--- Close all open buffers, except the current one.
function Render.close_all_but_current()
  local current_bufnr = get_current_buf()

  for _, bufnr in ipairs(state.buffers) do
    if bufnr ~= current_bufnr then
      bbye.bdelete(false, bufnr)
    end
  end

  bufferline.update()
end

--- Close all open buffers, except pinned ones.
function Render.close_all_but_pinned()
  for _, bufnr in ipairs(state.buffers) do
    if not state.is_pinned(bufnr) then
      bbye.bdelete(false, bufnr)
    end
  end

  bufferline.update()
end

--- Close all open buffers, except pinned ones or the current one.
function Render.close_all_but_current_or_pinned()
  local current_bufnr = get_current_buf()

  for _, bufnr in ipairs(state.buffers) do
    if not state.is_pinned(bufnr) and bufnr ~= current_bufnr then
      bbye.bdelete(false, bufnr)
    end
  end

  bufferline.update()
end

--- Close all buffers which are visually left of the current buffer.
function Render.close_buffers_left()
  local idx = utils.index_of(state.buffers, get_current_buf())
  if idx == nil or idx == 1 then
    return
  end

  for i = idx - 1, 1, -1 do
    bbye.bdelete(false, state.buffers[i])
  end

  bufferline.update()
end

--- Close all buffers which are visually right of the current buffer.
function Render.close_buffers_right()
  local idx = utils.index_of(state.buffers, get_current_buf())
  if idx == nil then
    return
  end

  for i = #state.buffers, idx + 1, -1 do
    bbye.bdelete(false, state.buffers[i])
  end

  bufferline.update()
end

--- Order the buffers by their buffer number.
function Render.order_by_buffer_number()
  table_sort(state.buffers, function(a, b) return a < b end)
  bufferline.update()
end

--- Order the buffers by their parent directory.
function Render.order_by_directory()
  table_sort(state.buffers, with_pin_order(function(a, b)
    local name_of_a = buf_get_name(a)
    local name_of_b = buf_get_name(b)
    local a_less_than_b = name_of_b < name_of_a

    -- TODO: remove this block after 0.8 releases
    if not normalize then
      local a_is_relative = utils.is_relative_path(name_of_a)
      if a_is_relative and utils.is_relative_path(name_of_b) then
        return a_less_than_b
      end

      return a_is_relative
    end

    local level_of_a = #vim.split(normalize(name_of_a), '/')
    local level_of_b = #vim.split(normalize(name_of_b), '/')

    if level_of_a ~= level_of_b then
      return level_of_a < level_of_b
    end

    return a_less_than_b
  end))

  bufferline.update()
end

--- Order the buffers by filetype.
function Render.order_by_language()
  table_sort(state.buffers, with_pin_order(function(a, b)
    return buf_get_option(a, 'filetype') < buf_get_option(b, 'filetype')
  end))

  bufferline.update()
end

--- Order the buffers by their respective window number.
function Render.order_by_window_number()
  table_sort(state.buffers, with_pin_order(function(a, b)
    return bufwinnr(buf_get_name(a)) < bufwinnr(buf_get_name(b))
  end))

  bufferline.update()
end

--- Generate a valid `&tabline` given the current state of Neovim.
--- @param refocus nil|boolean if `true`, the bufferline will be refocused on the current buffer (default: `true`)
--- @param update_names nil|boolean whether to refresh the names of the buffers (default: `false`)
--- @return nil|string syntax
function Render.render(update_names, refocus)
  local opts = vim.g.bufferline
  local buffer_numbers = state.get_updated_buffers(update_names)

  if opts.auto_hide then
    if #buffer_numbers <= 1 then
      if vim.o.showtabline == 2 then
        vim.o.showtabline = 0
      end
      return
    end
    if vim.o.showtabline == 0 then
      vim.o.showtabline = 2
    end
  end

  local current = get_current_buf()

  -- Store current buffer to open new ones next to this one
  if buf_get_option(current, 'buflisted') then
    if vim.b.empty_buffer then
      state.last_current_buffer = nil
    else
      state.last_current_buffer = current
    end
  end

  local click_enabled = has('tablineat') and opts.clickable
  local has_close = opts.closable
  local has_icons = (opts.icons == true) or (opts.icons == 'both') or (opts.icons == 'buffer_number_with_icon')
  local has_icon_custom_colors = opts.icon_custom_colors
  local has_buffer_number = (opts.icons == 'buffer_numbers') or (opts.icons == 'buffer_number_with_icon')
  local has_numbers = (opts.icons == 'numbers') or (opts.icons == 'both')

  local layout = Layout.calculate(state)

  local items = {}

  local current_buffer_index = nil
  local current_buffer_position = 0
  for i, buffer_number in ipairs(buffer_numbers) do

    local buffer_data = state.get_buffer_data(buffer_number)
    local buffer_name = buffer_data.name or '[no name]'

    buffer_data.real_width    = Layout.calculate_width(buffer_name, layout.base_width, layout.padding_width)
    buffer_data.real_position = current_buffer_position

    local activity = Buffer.get_activity(buffer_number)
    local is_inactive = activity == 0
    -- local is_visible = activity == 1
    local is_current = activity == 2
    local is_modified = buf_get_option(buffer_number, 'modified')
    -- local is_closing = buffer_data.closing
    local is_pinned = state.is_pinned(buffer_number)

    local status = HL_BY_ACTIVITY[activity]
    local mod = is_modified and 'Mod' or ''

    local separatorPrefix = hl_tabline('Buffer' .. status .. 'Sign')
    local separator = is_inactive and
      opts.icon_separator_inactive or
      opts.icon_separator_active

    local namePrefix = hl_tabline('Buffer' .. status .. mod)
    local name = buffer_name

    -- The buffer name
    local bufferIndexPrefix = ''
    local bufferIndex = ''

    -- The jump letter
    local jumpLetterPrefix = ''
    local jumpLetter = ''

    -- The devicon
    local iconPrefix = ''
    local icon = ''

    if has_buffer_number or has_numbers then
      local number_text =
        has_buffer_number and
          tostring(buffer_number) or
          tostring(i)

      bufferIndexPrefix = hl_tabline('Buffer' .. status .. 'Index')
      bufferIndex = number_text .. ' '
    end

    if state.is_picking_buffer then
      local letter = JumpMode.get_letter(buffer_number)

      -- Replace first character of buf name with jump letter
      if letter and not has_icons then
        name = strcharpart(name, 1)
      end

      jumpLetterPrefix = hl_tabline('Buffer' .. status .. 'Target')
      jumpLetter = (letter or '') ..
        (has_icons and (' ' .. (letter and '' or ' ')) or '')
    else

      if has_icons then
        local iconChar, iconHl = icons.get_icon(buffer_name, buf_get_option(buffer_number, 'filetype'), status)
        local hlName = is_inactive and 'BufferInactive' or iconHl
        iconPrefix = has_icon_custom_colors and hl_tabline('Buffer' .. status .. 'Icon') or hlName and hl_tabline(hlName) or namePrefix
        icon = iconChar .. ' '
      end
    end

    local closePrefix = ''
    local close = ''
    if has_close or is_pinned then
      local closeIcon =
        is_pinned and
          opts.icon_pinned or
        (not is_modified and
          opts.icon_close_tab or
          opts.icon_close_tab_modified)

      closePrefix = namePrefix
      close = closeIcon .. ' '

      if click_enabled then
        closePrefix =
            '%' .. buffer_number .. '@BufferlineCloseClickHandler@' .. closePrefix
      end
    end

    local clickable = ''
    if click_enabled then
      clickable = '%' .. buffer_number .. '@BufferlineMainClickHandler@'
    end

    local padding = string_rep(' ', layout.padding_width)

    local item = {
      is_current = is_current,
      width = buffer_data.width
        -- <padding> <base_widths[i]> <padding>
        or layout.base_widths[i] + (2 * layout.padding_width),
      position = buffer_data.position or buffer_data.real_position,
      groups = {
        {clickable .. separatorPrefix,    separator},
        {'',                 padding},
        {bufferIndexPrefix,  bufferIndex},
        {clickable .. iconPrefix,         icon},
        {jumpLetterPrefix,   jumpLetter},
        {clickable .. namePrefix,         name},
        {'',                 padding},
        {'',                 ' '},
        {closePrefix,        close},
      }
    }

    if is_current and refocus ~= false then
      current_buffer_index = i
      current_buffer_position = buffer_data.real_position

      local start = current_buffer_position
      local end_  = current_buffer_position + item.width

      if Render.scroll > start then
        state.set_scroll(start)
      elseif Render.scroll + layout.buffers_width < end_ then
        state.set_scroll(Render.scroll + (end_ - (Render.scroll + layout.buffers_width)))
      end
    end

    table_insert(items, item)
    current_buffer_position = current_buffer_position + item.width
  end

  -- Create actual tabline string
  local result = ''

  -- Add offset filler & text (for filetree/sidebar plugins)
  if offset > 0 then
    local offset_available_width = offset - 2
    local groups = {{
      hl_tabline(offset_hl or 'BufferOffset'),
      ' ' .. (offset_text or ''),
    }}
    result = result .. groups_to_string(slice_groups_right(groups, offset_available_width))
    result = result .. string_rep(' ', offset_available_width - #offset_text)
    result = result .. ' '
  end

  -- Add bufferline
  local bufferline_groups = {
    { hl_tabline('BufferTabpageFill'), string_rep(' ', layout.actual_width) }
  }

  for i, item in ipairs(items) do
    if i ~= current_buffer_index then
      bufferline_groups = groups_insert(bufferline_groups, item.position, item.groups)
    end
  end
  if current_buffer_index ~= nil then
    local item = items[current_buffer_index]
    bufferline_groups = groups_insert(bufferline_groups, item.position, item.groups)
  end

  -- Crop to scroll region
  local max_scroll = max(layout.actual_width - layout.buffers_width, 0)
  local scroll = min(Render.scroll_current, max_scroll)
  local buffers_end = layout.actual_width - scroll

  if buffers_end > layout.buffers_width then
    bufferline_groups = slice_groups_right(bufferline_groups, scroll + layout.buffers_width)
  end
  if scroll > 0 then
    bufferline_groups = slice_groups_left(bufferline_groups, layout.buffers_width)
  end

  -- Render bufferline string
  result = result .. groups_to_string(bufferline_groups)

  -- To prevent the expansion of the last click group
  result = result .. '%0@BufferlineMainClickHandler@' .. hl_tabline('BufferTabpageFill')

  if layout.actual_width + strwidth(opts.icon_separator_inactive) <= layout.buffers_width and #items > 0 then
    result = result .. opts.icon_separator_inactive
  end

  local current_tabpage = tabpagenr()
  local total_tabpages  = tabpagenr('$')
  if layout.tabpages_width > 0 then
    result = result .. '%=%#BufferTabpages# ' .. tostring(current_tabpage) .. '/' .. tostring(total_tabpages) .. ' '
  end

  result = result .. hl_tabline('BufferTabpageFill')

  return result
end

--- Restore the buffers
--- @param bufnames table<string>
function Render.restore_buffers(bufnames)
  -- Close all empty buffers. Loading a session may call :tabnew several times
  -- and create useless empty buffers.
  for _,bufnr in ipairs(list_bufs()) do
    if buf_get_name(bufnr) == ''
      and buf_get_option(bufnr, 'buftype') == ''
      and buf_line_count(bufnr) == 1
      and buf_get_lines(bufnr, 0, 1, true)[1] == ''
    then
        buf_delete(bufnr, {})
    end
  end

  state.buffers = {}
  for _,name in ipairs(bufnames) do
    table_insert(state.buffers, bufadd(name))
  end

  bufferline.update()
end

--- Offset the rendering of the bufferline
--- @param width integer the amount to offset
--- @param text nil|string text to put in the offset
--- @param hl nil|string
function Render.set_offset(width, text, hl)
  offset = width

  if width > 0 then
    offset_text = text
    offset_hl = hl
  else
    offset_text = nil
    offset_hl = nil
  end

  bufferline.update()
end

-- WARN: MOVERS AND SHAKERS

--- Toggle the `bufnr`'s "pin" state, visually.
--- @param bufnr nil|integer
function Render.toggle_pin(bufnr)
  state.toggle_pin(bufnr or 0)
  sort_pins_to_left()
  bufferline.update()
end

-- # ANIMATION

-- ## CLOSING

--- Close the `bufnr`, visually.
--- @param bufnr integer
--- @param do_name_update nil|boolean refreshes all buffer names iff `true`
function Render.close_buffer(bufnr, do_name_update)
  state.close_buffer(bufnr, do_name_update)
  bufferline.update()
end

--- An incremental animation for `close_buffer_animated`.
--- @param bufnr integer
--- @param new_width integer
local function close_buffer_animated_tick(bufnr, new_width, animation)
  if new_width > 0 and state.buffers_by_id[bufnr] ~= nil then
    local buffer_data = state.get_buffer_data(bufnr)
    buffer_data.width = new_width
    bufferline.update()
    return
  end
  animate.stop(animation)
  Render.close_buffer(bufnr, true)
end

--- Same as `close_buffer`, but animated.
--- @param bufnr integer
function Render.close_buffer_animated(bufnr)
  if vim.g.bufferline.animation == false then
    return Render.close_buffer(bufnr)
  end

  local buffer_data = state.get_buffer_data(bufnr)
  local current_width = buffer_data.real_width

  buffer_data.closing = true
  buffer_data.width = current_width

  animate.start(
    ANIMATION_CLOSE_DURATION, current_width, 0, vim.v.t_number,
    function(new_width, m)
      close_buffer_animated_tick(bufnr, new_width, m)
    end)
end

-- ## MOVING

local move_animation = nil
local move_animation_data = nil

--- An incremental animation for `move_buffer_animated`.
local function move_buffer_animated_tick(ratio, current_animation)
  local data = move_animation_data

  for _, current_number in ipairs(state.buffers) do
    local current_data = state.get_buffer_data(current_number)

    if current_animation.running == true then
      current_data.position = animate.lerp(
        ratio,
        data.previous_positions[current_number],
        data.next_positions[current_number]
      )
    else
      current_data.position = nil
      current_data.moving = false
    end
  end

  bufferline.update()

  if current_animation.running == false then
    move_animation = nil
    move_animation_data = nil
  end
end

--- Move a buffer (with animation, if configured).
--- @param from_idx integer the buffer's original index.
--- @param to_idx integer the buffer's new index.
local function move_buffer(from_idx, to_idx)
  to_idx = max(1, min(#state.buffers, to_idx))
  if to_idx == from_idx then
    return
  end

  local bufnr = state.buffers[from_idx]

  local previous_positions
  if vim.g.bufferline.animation == true then
    previous_positions = Layout.calculate_buffers_position_by_buffer_number(state)
  end

  table_remove(state.buffers, from_idx)
  table_insert(state.buffers, to_idx, bufnr)
  sort_pins_to_left()

  if vim.g.bufferline.animation == true then
    local current_index = utils.index_of(state.buffers, bufnr)
    local start_index = min(from_idx, current_index)
    local end_index   = max(from_idx, current_index)

    if start_index == end_index then
      return
    elseif move_animation ~= nil then
      animate.stop(move_animation)
    end

    local next_positions = Layout.calculate_buffers_position_by_buffer_number(state)

    for i, _ in ipairs(state.buffers) do
      local current_number = state.buffers[i]
      local current_data = state.get_buffer_data(current_number)

      local previous_position = previous_positions[current_number]
      local next_position     = next_positions[current_number]

      if next_position ~= previous_position then
        current_data.position = previous_positions[current_number]
        current_data.moving = true
      end
    end

    move_animation_data = {
      previous_positions = previous_positions,
      next_positions = next_positions,
    }

    move_animation =
      animate.start(ANIMATION_MOVE_DURATION, 0, 1, vim.v.t_float,
        function(ratio, current_animation) move_buffer_animated_tick(ratio, current_animation) end)
  end

  bufferline.update()
end

--- Move the current buffer to the index specified.
--- @param idx integer
function Render.move_current_buffer_to(idx)
  state.get_updated_buffers()

  if idx == -1 then
    idx = #state.buffers
  end

  local current_bufnr = get_current_buf()
  local from_idx = utils.index_of(state.buffers, current_bufnr)

  move_buffer(from_idx, idx)
end

--- Move the current buffer a certain number of times over.
--- @param steps integer
function Render.move_current_buffer(steps)
  state.get_updated_buffers()

  local currentnr = get_current_buf()
  local idx = utils.index_of(state.buffers, currentnr)

  move_buffer(idx, idx + steps)
end

-- ## OPENING

--- The incremental animation for `open_buffer_start_animation`.
--- @param bufnr integer
--- @param new_width integer
--- @param animation unknown
local function open_buffer_animated_tick(bufnr, new_width, animation)
  local buffer_data = state.get_buffer_data(bufnr)
  buffer_data.width = animation.running and new_width or nil

  bufferline.update()
end

--- Opens a buffer with animation.
--- @param bufnr integer
local function open_buffer_start_animation(layout, bufnr)
  local buffer_data = state.get_buffer_data(bufnr)
  buffer_data.real_width = Layout.calculate_width(buffer_data.name, layout.base_width, layout.padding_width)

  local target_width = buffer_data.real_width

  buffer_data.width = 1

  defer_fn(function()
    animate.start(
      ANIMATION_OPEN_DURATION, 1, target_width, vim.v.t_number,
      function(new_width, animation)
        open_buffer_animated_tick(bufnr, new_width, animation)
      end)
  end, ANIMATION_OPEN_DELAY)
end

local function open_buffers(new_buffers)
  local opts = vim.g.bufferline
  local initial_buffers = #state.buffers

  -- Open next to the currently opened tab
  -- Find the new index where the tab will be inserted
  local new_index = utils.index_of(state.buffers, state.last_current_buffer)
  if new_index ~= nil then
    new_index = new_index + 1
  else
    new_index = #state.buffers + 1
  end

  -- Insert the buffers where they go
  for _, new_buffer in ipairs(new_buffers) do
    if utils.index_of(state.buffers, new_buffer) == nil then
      local actual_index = new_index

      local should_insert_at_start = opts.insert_at_start
      local should_insert_at_end = opts.insert_at_end or
        -- We add special buffers at the end
        buf_get_option(new_buffer, 'buftype') ~= ''

      if should_insert_at_start then
        actual_index = 1
        new_index = new_index + 1
      elseif should_insert_at_end then
        actual_index = #state.buffers + 1
      else
        new_index = new_index + 1
      end

      table_insert(state.buffers, actual_index, new_buffer)
    end
  end

  sort_pins_to_left()

  -- We're done if there is no animations
  if opts.animation == false then
    return
  end

  -- Case: opening a lot of buffers from a session
  -- We avoid animating here as well as it's a bit
  -- too much work otherwise.
  if initial_buffers <= 1 and #new_buffers > 1 or
     initial_buffers == 0 and #new_buffers == 1
  then
    return
  end

  -- Update names because they affect the layout
  state.update_names()

  local layout = Layout.calculate(state)

  for _, buffer_number in ipairs(new_buffers) do
    open_buffer_start_animation(layout, buffer_number)
  end
end

-- ## SCROLLING

local scroll_animation = nil

--- An incremental animation for `set_scroll`.
local function set_scroll_tick(new_scroll, animation)
  Render.scroll_current = new_scroll
  if animation.running == false then
    scroll_animation = nil
  end
  bufferline.update(nil, false)
end

--- Scrolls the bufferline to the `target`.
--- @param target unknown where to scroll to
function Render.set_scroll(target)
  Render.scroll = target

  if scroll_animation ~= nil then
    animate.stop(scroll_animation)
  end

  scroll_animation = animate.start(
    ANIMATION_SCROLL_DURATION, Render.scroll_current, target, vim.v.t_number,
    set_scroll_tick)
end

-- print(render(state.buffers))

return Render
