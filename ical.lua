--[[

lua-ical, utility for parsing iCalendar file format written in Lua
Copyright (C) 2016  MParolari

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program.  If not, see <http://www.gnu.org/licenses/>.

]]

local ical = {}

local parser = {}

local wd = {SU = 0, MO = 1, TU = 2, WE = 3, TH = 4, FR = 5, SA = 6}

-- support function for deep-copy a table
local function clone (tb)
    if type(tb) ~= "table" then return tb end
    local ctb, mt = {}, getmetatable(tb)
    for k,v in pairs(tb) do
        if type(v) == "table" then ctb[k] = clone(v)
        else ctb[k] = v
        end
    end
    setmetatable(ctb, mt)
    return ctb
end

--TODO parsing period (list of dates?)
local function parse_date(v)
  if not v then return nil end
	local t, utc = {}, nil
	t.year, t.month, t.day = v:match("^(%d%d%d%d)(%d%d)(%d%d)")
	t.hour, t.min, t.sec, utc = v:match("T(%d%d)(%d%d)(%d%d)(Z?)")
  if (t.hour == nil) or (t.min == nil) or (t.sec == nil) then
    t.hour, t.min, t.sec, utc = 0,0,0,nil
  end
	for k,v in pairs(t) do t[k] = tonumber(v) end
	return os.time(t), utc
end

function parser.VEVENT(entry, k, v)
	if k == "BEGIN" then
		function entry:duration(f) return ical.duration(self, f) end
		function entry:is_in(s) return ical.is_in(self, s) end
    function entry:is_over(s) return ical.is_over(self, s) end
    
	elseif k:find("DTSTART") or k:find("DTEND") then
		-- get timezone id
		local tzid = k:match("TZID=([a-zA-Z-\\/]+)")
		local value = k:match("VALUE=([a-zA-Z-\\/]+)")
		
		if string.find(k, ";") then
			k = k:match("^(.-);")
		end
		
    -- parsing value
    local time, utc = parse_date(v)
    if utc == 'Z' then tzid = 'UTC' end
		
		-- write entry
		entry[k] = time
		entry[k..'_TZID'] = tzid
    
	elseif k:find("RRULE") or k:find("EXRULE") then
		entry[k] = {}
		entry[k].FREQ = v:match("FREQ=([a-zA-Z]+)")
		entry[k].WKST = v:match("WKST=([A-Z]+)")
		entry[k].UNTIL = parse_date(v:match("UNTIL=([TZ0-9]+)"))
    entry[k].COUNT = v:match("COUNT=([0-9]+)")
    entry[k].INTERVAL = v:match("INTERVAL=([0-9]+)")
		-- byday, bymonth, ecc ecc
    local byk, by = v:match("(BY%a+)=([A-Z,]+)")
    if byk and by then
      entry[k][byk] = {}
      for b in by:gmatch("([A-Z]+),?") do
        table.insert(entry[k][byk], b)
      end
    end
    if entry[k].UNTIL == nil and entry[k].COUNT == nil then
      return "RRULE.UNTIL or RRULE.COUNT not found"
    end
    
	elseif k:find("EXDATE") then
		local tzid = k:match("TZID=([a-zA-Z-\\/]+)")
		if k:find(";") then
			k = k:match("^(.-);")
		end
		if entry[k] == nil then entry[k] = {} end
		if entry[k..'_TZID'] == nil then entry[k..'_TZID'] = {} end
		-- parsing value
    local time, utc = parse_date(v)
    if utc == 'Z' then tzid = 'UTC' end
    
		table.insert(entry[k], time)
		table.insert(entry[k..'_TZID'], tzid)
    
	else
		entry[k] = v
	end
  
  return nil -- no problems
end

function parser.VCALENDAR(entry, k, v)
	if k == "BEGIN" then
		function entry:events() return ical.events(self) end
	else
		entry[k] = v
	end
end

function ical.new(data)
	local entry = { subs = {}, type = nil }
	local stack = {}
	local line_num = 0; -- only for check errors
	
	--TODO check if there's a standard or it's a workaround for google calendars only
	data = data:gsub("[\r\n]+ ", "")
	
	-- Parse
	for line in data:gmatch("(.-)[\r\n]+") do
		line_num = line_num + 1;
    --print(line_num)
    
		-- retrieve key and value
		local k,v = line:match("^(.-):(.*)$")
		if not(k and v) then
			return nil, "Parsing error, key:value format not valid at line "..line_num
		end
		
		-- open a new entry
		if k == "BEGIN" then
			local new_entry = { subs = {}, type = v } -- new entry
			table.insert(entry.subs, new_entry) -- insert new entry in sub-entries
			table.insert(stack, entry) -- push current entry in stack
			entry = new_entry -- current entry is now the new entry just created
		end
		
		-- call the parser
		if parser[entry.type] then
			local err = parser[entry.type](entry, k, v)
      if err then return nil, err end
		else
			entry[k] = v
		end
		
		-- close current entry
		if k == "END" then
			if entry.type ~= v then -- check end
				return nil, "Parsing error, expected END:"..entry.type.." before line "..line_num
			end
			entry = table.remove(stack) -- pop the previous entry
		end
	end
	
	-- Return calendar
	return entry.subs[1]
end

function ical.duration(a, f)
	if a and a.type == "VEVENT" then
		local d = os.difftime(a.DTEND, a.DTSTART)
		if f == "hour" then d = d/3600
		elseif f == "min" then d = d/60
		end
		return d
	else
		return nil
	end
end

function ical.time_compare(a, b) --TODO define better (b-a)?
	if not(a and b) then return nil end
	local d = os.difftime(a, b)
	if d < 0 then
		return -1
	elseif d > 0 then
		return 1
	elseif d == 0 then
		return 0
	end
end

-- Given an entry, it returns the VEVENT sub-entries
function ical.events(cal)
	if type(cal) ~= "table" or cal.type ~= "VCALENDAR" then return nil end
	local evs = {}
	for _,e in ipairs(cal.subs) do
		if e.type == "VEVENT" then
      -- insert event
			table.insert(evs, e)
      -- check RRULE
			if e.RRULE then
        -- check RRULE WEEKLY
				if e.RRULE.FREQ == "WEEKLY" then
          -- new (current) event
					local ne = clone(e)
          local count = 0
					repeat
            -- if true, ne will be inserted
            local inserting = false
            
            -- add 24 hours
						ne.DTSTART = ne.DTSTART + 24*3600
						ne.DTEND = ne.DTEND + 24*3600
            
            -- check weekday --TODO iterate over day
						local w = tonumber(os.date("%w", ne.DTSTART))
						for _, weekday in ipairs(e.RRULE.BYDAY) do
							if wd[weekday] == w then inserting = true end
						end
            
            -- check EXDATE
            if e.EXDATE ~= nil then
              for _, exdate in ipairs(e.EXDATE) do
                if ical.time_compare(exdate, ne.DTSTART) == 0 then inserting = false end
              end
            end
            
            -- insert
            if inserting then table.insert(evs, clone(ne)) end
            
            local quit = true -- avoid infinite loop by default
            if e.RRULE.UNTIL then
              quit = ical.time_compare(ne.DTSTART, e.RRULE.UNTIL) >= 0
            elseif e.RRULE.COUNT then
              count = count +1
              quit = count < e.RRULE.COUNT
            else
              return nil, "RRULE.UNTIL or RRULE.COUNT not found"
            end
            
					until quit
				end
        --TODO check other sequences
			end -- endif RRULE
		end -- endif EVENT
	end
	return evs
end

function ical.sort_events(evs)
	table.sort(evs,
		function(a,b)
			return ical.time_compare(a.DTSTART, b.DTSTART) < 0
		end
	)
end

function ical.is_in(e, s)
	if type(e) ~= "table" or type(s) ~= "table" then return nil end
	return (ical.time_compare(e.DTSTART, s.DTSTART) >= 0) and
				 (e.DTEND == nil or (ical.time_compare(e.DTEND, s.DTEND) <= 0))
end

function ical.is_over(e, s)
	if type(e) ~= "table" or type(s) ~= "table" then return nil end
  local es_ss = ical.time_compare(e.DTSTART, s.DTSTART)
  local es_se = ical.time_compare(e.DTSTART, s.DTEND)
  local ee_ss = ical.time_compare(e.DTEND, s.DTSTART)
  local ee_se = ical.time_compare(e.DTEND, s.DTEND)
  -- if event hasn't an end
  if e.DTEND == nil then
    return (es_ss >= 0) and (es_se <= 0) -- s_start, e_start, s_end
  end
  -- else
	return ((es_ss >= 0) and (es_se <= 0)) -- s_start, e_start, s_end
      or ((ee_ss >= 0) and (ee_se <= 0)) -- s_start, e_end, s_end
      or ((es_ss <= 0) and (ee_se >= 0)) -- e_start, s_start, s_end, e_end
end

function ical.span(start, end_)
  return {DTSTART = start, DTEND = end_}
end

function ical.span_duration(start, duration)
  return ical.span(start, start + duration)
end

return ical;
