-- keyboard.lua
-- standalone adaptable grid keyboard module (no crow/synth)

local musicutil = require "musicutil"
local kb = {}

-- runtime‑configurable bounds
kb.x_start = 1
kb.y_start = 1
kb.width  = 16
kb.height = 6  -- rows of keys

kb.root_note     = 72   -- C5 default
kb.root_buttons  = { [3]=48, [4]=60, [5]=72, [6]=84 }
kb.pressed_keys  = {}

----------------------------------------------------------------
-- PUBLIC: init{ x,y,width,height }
----------------------------------------------------------------
function kb.init(bounds)
  kb.x_start = bounds.x or kb.x_start
  kb.y_start = bounds.y or kb.y_start
  kb.width   = bounds.width  or kb.width
  kb.height  = bounds.height or kb.height
  kb.pressed_keys = {}
end

----------------------------------------------------------------
-- NOTE + SCALE HELPERS
----------------------------------------------------------------
function kb.get_note_at(x,y)
  local col_offset = x - kb.x_start
  local row_offset = (kb.y_start + kb.height - 1) - y -- rows count upward
  return kb.root_note + col_offset + (row_offset * 5)
end

function kb.is_c_major(n)
  return ({[0]=1,[2]=1,[4]=1,[5]=1,[7]=1,[9]=1,[11]=1})[n%12]
end

----------------------------------------------------------------
-- GRID INPUT HANDLER
-- returns {note=<midi>, state=1|0} or nil
----------------------------------------------------------------
function kb.handle_key(x,y,z)
  if x < kb.x_start or x >= kb.x_start+kb.width then return nil end
  if y < kb.y_start or y >= kb.y_start+kb.height then return nil end

  local id   = x .. "_" .. y
  local note = kb.get_note_at(x,y)
  kb.pressed_keys[id] = (z==1) and true or false
  return {note = note, state = z}
end

----------------------------------------------------------------
-- GRID DRAW
----------------------------------------------------------------
function kb.grid_redraw(g)
  for y = kb.y_start, kb.y_start+kb.height-1 do
    for x = kb.x_start, kb.x_start+kb.width-1 do
      local id   = x .. "_" .. y
      local note = kb.get_note_at(x,y)
      local br   = 0
      if kb.pressed_keys[id] then
        br = 11
      elseif note%12==0 then
        br = 5
      elseif kb.is_c_major(note) then
        br = 2
      end
      g:led(x,y,br)
    end
  end
end

----------------------------------------------------------------
-- GRID DRAW ‑ PARTIAL (first N rows)
----------------------------------------------------------------
function kb.grid_redraw_rows(g, rows)
  rows = math.min(rows or kb.height, kb.height)
  for y = kb.y_start, kb.y_start + rows - 1 do
    for x = kb.x_start, kb.x_start + kb.width - 1 do
      local id   = x .. "_" .. y
      local note = kb.get_note_at(x, y)
      local br   = 0
      if kb.pressed_keys[id]       then br = 11
      elseif note % 12 == 0        then br = 5
      elseif kb.is_c_major(note)   then br = 2 end
      g:led(x, y, br)
    end
  end
end

----------------------------------------------------------------
-- GRID DRAW  – single absolute row
----------------------------------------------------------------
function kb.grid_redraw_row(g, y)
  for x = kb.x_start, kb.x_start + kb.width - 1 do
    local id   = x .. "_" .. y
    local note = kb.get_note_at(x, y)
    local br   = 0
    if kb.pressed_keys[id]       then br = 11
    elseif note % 12 == 0        then br = 5
    elseif kb.is_c_major(note)   then br = 2 end
    g:led(x, y, br)
  end
end

----------------------------------------------------------------
-- UTIL
----------------------------------------------------------------
function kb.clear_pressed_keys()
  kb.pressed_keys = {}
end

return kb