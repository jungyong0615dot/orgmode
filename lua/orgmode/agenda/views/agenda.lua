local Date = require('orgmode.objects.date')
local Files = require('orgmode.parser.files')
local Range = require('orgmode.parser.range')
local config = require('orgmode.config')
local ClockReport = require('orgmode.clock.report')
local AgendaItem = require('orgmode.agenda.agenda_item')
local AgendaFilter = require('orgmode.agenda.filter')
local utils = require('orgmode.utils')

local function sort_by_date_or_priority_or_category(a, b)
  if a.headline:get_priority_sort_value() ~= b.headline:get_priority_sort_value() then
    return a.headline:get_priority_sort_value() > b.headline:get_priority_sort_value()
  end


  if not a.real_date:is_same(b.real_date, 'day') then
    return a.real_date:is_before(b.real_date)
  end
  return a.index < b.index
end

---@param agenda_items AgendaItem[]
---@return AgendaItem[]
local function sort_agenda_items(agenda_items)
  table.sort(agenda_items, function(a, b)

    if a.real_date:is_deadline() and not b.real_date:is_deadline() then
      return true
    elseif not a.real_date:is_deadline() and b.real_date:is_deadline() then
      return false
    end

    if a.headline:is_done() and not b.headline:is_done() then
      return true
    elseif not a.headline:is_done() and b.headline:is_done() then
      return false
    end



    -- self:diff(from)
    if a.real_date:is_deadline() and b.real_date:is_deadline() then
      if a.real_date:diff(b.real_date) >= 0 then
        return false
      else
        return true
      end
    end


    if a.is_same_day and b.is_same_day then
      if a.real_date:has_time() and not b.real_date:has_time() then
        return true
      end
      if b.real_date:has_time() and not a.real_date:has_time() then
        return false
      end
      if a.real_date:has_time() and b.real_date:has_time() then
        return a.real_date:is_before(b.real_date)
      end
      return sort_by_date_or_priority_or_category(a, b)
    end

    if a.is_same_day and not b.is_same_day then
      if a.real_date:has_time() or (b.real_date:is_none() and not a.real_date:is_none()) then
        return true
      end
    end

    if not a.is_same_day and b.is_same_day then
      if b.real_date:has_time() or (a.real_date:is_none() and not b.real_date:is_none()) then
        return false
      end
    end

    return sort_by_date_or_priority_or_category(a, b)
  end)
  return agenda_items
end

---@class AgendaView
---@field span string|number
---@field from Date
---@field to Date
---@field items table[]
---@field content table[]
---@field highlights table[]
---@field clock_report ClockReport
---@field show_clock_report boolean
---@field start_on_weekday number
---@field start_day string
---@field header string
---@field filters AgendaFilter
---@field win_width number
local AgendaView = {}

function AgendaView:new(opts)
  opts = opts or {}
  local data = {
    content = {},
    highlights = {},
    items = {},
    span = opts.span or config:get_agenda_span(),
    from = opts.from or Date.now():start_of('day'),
    to = nil,
    filters = opts.filters or AgendaFilter:new(),
    clock_report = nil,
    show_clock_report = opts.show_clock_report or false,
    start_on_weekday = opts.org_agenda_start_on_weekday or config.org_agenda_start_on_weekday,
    start_day = opts.org_agenda_start_day or config.org_agenda_start_day,
    header = opts.org_agenda_overriding_header,
    win_width = opts.win_width or utils.winwidth(),
  }

  setmetatable(data, self)
  self.__index = self
  data:_set_date_range()
  return data
end

function AgendaView:_get_title()
  if self.header then
    return self.header
  end
  local span = self.span
  if type(span) == 'number' then
    span = string.format('%d days', span)
  end
  local span_number = ''
  if span == 'week' then
    span_number = string.format(' (W%d)', self.from:get_week_number())
  end
  return utils.capitalize(span) .. '-agenda' .. span_number .. ':'
end

function AgendaView:_set_date_range(from)
  local span = self.span
  from = from or self.from
  local is_week = span == 'week' or span == '7'
  if is_week and self.start_on_weekday then
    from = from:set_isoweekday(self.start_on_weekday)
  end

  local to = nil
  local modifier = { [span] = 1 }
  if type(span) == 'number' then
    modifier = { day = span }
  end

  to = from:add(modifier)

  if self.start_day and type(self.start_day) == 'string' then
    from = from:adjust(self.start_day)
    to = to:adjust(self.start_day)
  end

  self.span = span
  self.from = from
  self.to = to
end

function AgendaView:_build_items()
  local dates = self.from:get_range_until(self.to)
  local agenda_days = {}

  local headline_dates = {}
  for _, orgfile in ipairs(Files.all()) do
    for _, headline in ipairs(orgfile:get_opened_headlines()) do
      for _, headline_date in ipairs(headline:get_valid_dates_for_agenda()) do
        table.insert(headline_dates, {
          headline_date = headline_date,
          headline = headline,
        })
      end
    end
  end

  for _, day in ipairs(dates) do
    local date = { day = day, agenda_items = {} }

    for index, item in ipairs(headline_dates) do
      local agenda_item = AgendaItem:new(item.headline_date, item.headline, day, index)
      if agenda_item.is_valid and self.filters:matches(item.headline) then
        table.insert(date.agenda_items, agenda_item)
      end
    end

    date.agenda_items = sort_agenda_items(date.agenda_items)

    table.insert(agenda_days, date)
  end

  self.items = agenda_days
end

function AgendaView:build()
  self:_build_items()
  local content = { { line_content = self:_get_title() } }
  local highlights = {}
  for _, item in ipairs(self.items) do
    local day = item.day
    local agenda_items = item.agenda_items

    local is_today = day:is_today()
    local is_weekend = day:is_weekend()

    if is_today or is_weekend then
      table.insert(highlights, {
        hlgroup = 'OrgBold',
        range = Range:new({
          start_line = #content + 1,
          end_line = #content + 1,
          start_col = 1,
          end_col = 0,
        }),
      })
    end

    local total_effort_minute = 0

    local todo_effort_minute = 0
    local current_effort_minute = 0
    local total_clocked_minute = 0

-- .logbook:get_total_with_active()
    for _, agenda_item in ipairs(agenda_items) do
      local effort_str = agenda_item.headline:get_property("effort") or "00:00"

      local logbook = agenda_item.headline.logbook


      if logbook then
        if agenda_item.headline:is_clocked_in() then
          total_clocked_minute = total_clocked_minute + logbook:get_total_with_active().minutes
        else
          total_clocked_minute = total_clocked_minute + logbook:get_total().minutes
        end
      end

      if not agenda_item.headline_date:is_deadline() then
        string.gsub(effort_str, "(%d+):(%d+)", function(h, m)
          total_effort_minute = total_effort_minute + (tonumber(h) * 60) + tonumber(m)
        end)
      end

      if not (agenda_item.headline:is_done() or agenda_item.headline_date:is_deadline()) then
        string.gsub(effort_str, "(%d+):(%d+)", function(h, m)
          todo_effort_minute = todo_effort_minute + (tonumber(h) * 60) + tonumber(m)
        end)
      end

      if agenda_item.headline:is_clocked_in() and not agenda_item.headline_date:is_deadline() then
        string.gsub(effort_str, "(%d+):(%d+)", function(h, m)
           current_effort_minute = current_effort_minute + (tonumber(h) * 60) + tonumber(m)
        end)
      end

    end

    -- table.insert(content, { line_content = self:_format_day(day) .. " [Tot " .. tostring(total_effort_minute) .. " min, R " .. todo_effort_minute .. " min (w/o c.c - " .. tostring(todo_effort_minute - current_effort_minute) .. " min)]" })
    table.insert(content, { line_content = self:_format_day(day) .. string.format(" [Tot %s min, R %s min (w/o c.c - %s), El %s min", tostring(total_effort_minute), todo_effort_minute, tostring(todo_effort_minute - current_effort_minute), tostring(total_clocked_minute) )})

    local longest_items = utils.reduce(agenda_items, function(acc, agenda_item)
      acc.category = math.max(acc.category, vim.api.nvim_strwidth(agenda_item.headline:get_category()))
      acc.label = math.max(acc.label, vim.api.nvim_strwidth(agenda_item.label))
      return acc
    end, {
      category = 0,
      label = 0,
    })
    local category_len = math.max(5, (longest_items.category + 1))
    local date_len = math.min(11, longest_items.label)

    -- print(win_width)

    for _, agenda_item in ipairs(agenda_items) do
      table.insert(
        content,
        AgendaView.build_agenda_item_content(agenda_item, category_len, date_len, #content, self.win_width)
      )
    end
  end

  self.content = content
  self.highlights = highlights
  self.active_view = 'agenda'
  if self.show_clock_report then
    self.clock_report = ClockReport.from_date_range(self.from, self.to)
    utils.concat(self.content, self.clock_report:draw_for_agenda(#self.content + 1))
  end
  
  return self
end

function AgendaView:advance_span(direction, count)
  count = count or 1
  direction = direction * count
  local action = { [self.span] = direction }
  if type(self.span) == 'number' then
    action = { day = self.span * direction }
  end
  self.from = self.from:add(action)
  self.to = self.to:add(action)
  return self:build()
end

function AgendaView:change_span(span)
  if span == self.span then
    return
  end
  if span == 'year' then
    local c = vim.fn.confirm('Are you sure you want to print agenda for the whole year?', '&Yes\n&No')
    if c ~= 1 then
      return
    end
  end
  self.span = span
  self:_set_date_range()
  return self:build()
end

function AgendaView:goto_date(date)
  self.to = nil
  self:_set_date_range(date)
  self:build()
  vim.schedule(function()
    vim.fn.search(self:_format_day(date))
  end)
end

function AgendaView:reset()
  return self:goto_date(Date.now():start_of('day'))
end

function AgendaView:toggle_clock_report()
  self.show_clock_report = not self.show_clock_report
  local text = self.show_clock_report and 'on' or 'off'
  utils.echo_info(string.format('Clocktable mode is %s', text))
  return self:build()
end

function AgendaView:after_print(_)
  return vim.fn.search(self:_format_day(Date.now()))
end

---@param agenda_item AgendaItem
---@return table
function AgendaView.build_agenda_item_content(agenda_item, longest_category, longest_date, line_nr, win_width)
  local headline = agenda_item.headline
  local category = '  ' .. utils.pad_right(string.format('%s:', headline:get_category()), longest_category)
  local date = agenda_item.label
  if date ~= '' then
    date = ' ' .. utils.pad_right(agenda_item.label, longest_date)
  end
  local todo_keyword = agenda_item.headline.todo_keyword.value
  local todo_padding = ''
  if todo_keyword ~= '' and vim.trim(agenda_item.label):find(':$') then
    todo_padding = ' '
  end
  todo_keyword = todo_padding .. todo_keyword
  local line = string.format('%s%s%s %s', category, date, todo_keyword, headline.title)
  local todo_keyword_pos = string.format('%s%s%s', category, date, todo_padding):len()
  if #headline.tags > 0 then
    local tags_string = headline:tags_to_string()
    local padding_length = math.max(1, win_width - vim.api.nvim_strwidth(line) - vim.api.nvim_strwidth(tags_string))
    local indent = string.rep(' ', padding_length)
    line = string.format('%s%s%s', line, indent, tags_string)
  end

  local item_highlights = {}
  if #agenda_item.highlights then
    item_highlights = vim.tbl_map(function(hl)
      hl.range = Range:new({
        start_line = line_nr + 1,
        end_line = line_nr + 1,
        start_col = 1,
        end_col = 0,
      })
      if hl.todo_keyword then
        hl.range.start_col = todo_keyword_pos + 1
        hl.range.end_col = todo_keyword_pos + hl.todo_keyword:len() + 1
      end
      return hl
    end, agenda_item.highlights)
  end

  if headline:is_clocked_in() then
    table.insert(item_highlights, {
      range = Range:new({
        start_line = line_nr + 1,
        end_line = line_nr + 1,
        start_col = 1,
        end_col = 0,
      }),
      hl_group = 'Cursor',
      whole_line = true,
    })
  end

  return {
    line_content = line,
    line = line_nr,
    jumpable = true,
    file = headline.file,
    file_position = headline.range.start_line,
    highlights = item_highlights,
    longest_date = longest_date,
    longest_category = longest_category,
    agenda_item = agenda_item,
    headline = headline,
  }
end

function AgendaView:_format_day(day)
  return string.format('%-10s %s', day:format('%A'), day:format('%d %B %Y'))
end

return AgendaView
