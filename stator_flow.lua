-- stator_flow
--
-- by chris randall
--
-- crow clock
-- keyboard
-- sample playback
-- note looper

engine.name = nil                           -- no synth engine

local musicutil = require "musicutil"
local util      = require "util"
local keyboard  = include("stator_flow/keyboard")

--------------------------------------------------------------------
-- CONFIG
--------------------------------------------------------------------
local NUM_VOICES       = 6
local root_note        = 72                     -- C4 = 60 → sample pitched at C5
local SAMPLE_DIR       = _path.audio .. "stator_flow/"
local DEFAULT_SAMPLE   = SAMPLE_DIR .. "Califone_One_Shots_01.wav"

--------------------------------------------------------------------
-- SAMPLE BANK (16 one‑shots)
--------------------------------------------------------------------
local sample_files = {}
for i=1,16 do
  sample_files[i] = SAMPLE_DIR .. "Califone_One_Shots_" .. string.format("%02d", i) .. ".wav"
end
local current_sample_idx = 1
local function load_sample(idx)
  current_sample_idx = idx
  softcut.buffer_read_mono(sample_files[idx], 0, 0, -1, 1, 1)   -- into buf‑1
  for v=1,NUM_VOICES do softcut.position(v, 0) end               -- reset play heads
  print("Loaded sample: " .. sample_files[idx])
end

--------------------------------------------------------------------
-- STATE
--------------------------------------------------------------------
local g; local grid_cols, grid_rows = 16, 8

-- transport
local running, waiting_to_start = false, false
local clk_id, current_step      = nil, 0

-- looper
local pattern = {}
local recording, playing        = false, false
local record_start_time         = 0
local play_clock                = nil
local pending_record_start,
      pending_record_stop,
      pending_play_start        = false, false, false

-- UI pages
local current_page, total_pages = 1, 2

local slider_rows = { [2]=1.0, [3]=0.75, [4]=0.5, [5]=0.25, [6]=0 }

-- grid column for each parameter (gap after column 3)
local param_cols = {1,2,3,5,6}   -- cut, pan, lvl, atk, rel

-- per‑voice “last used” timestamp
local voice_age, last_voice = {}, 1
for v=1,NUM_VOICES do voice_age[v] = 0 end

--------------------------------------------------------------------
-- SOFTCUT PARAM SET
--------------------------------------------------------------------
local params_def = {
  {name="level", min=0   , max=1   , step=0.05, value=0.7,
   apply=function(val)
     for i=1,NUM_VOICES do
       softcut.level(i,val)
       softcut.post_filter_dry(i, 0) -- ensure dry path is silent
     end
   end},
  {name="pan rand", min=0   , max=1   , step=0.05, value=0.6 , apply=nil},      -- spread
  {name="cutoff", min=50 , max=2000, step=  50, value=1200,
   apply=function(val) for i=1,NUM_VOICES do softcut.post_filter_fc(i,val) end end},
  {name="attack", min=0.1   , max=5   , step=0.05, value=0.01, apply=nil},      -- envelope A
  {name="release", min=0.1   , max=5   , step=0.05, value=0.30, apply=nil},      -- envelope R
}
local sel_param = 1

--------------------------------------------------------------------
-- INITIALISE
--------------------------------------------------------------------
function init()
  -- crow outs
  crow.output[1].action = "{to(5,0.001),to(0,0.001)}"
  crow.output[2].volts  = 0

  -- grid + keyboard (rows 1‑7)
  g = grid.connect(); g.key = grid_key
  grid_cols, grid_rows = g.cols, g.rows
  keyboard.init{ x=1, y=1, width=grid_cols, height=7 }

  -- Softcut
  softcut.buffer_clear()
  for v=1,NUM_VOICES do
    softcut.enable(v,1); softcut.buffer(v,1)
    softcut.rate(v,1);   softcut.loop(v,0)
    softcut.fade_time(v, 2)

    -- ‑‑‑ activate filter path
    softcut.post_filter_lp (v, 1.0)    -- send 100 % into low‑pass
    softcut.post_filter_rq(v, 2.0)     -- resonance (Q); 1.0 = gentle

  end
  load_sample(1)                                   -- default sample

  -- redraw timers
  clock.run(function() while true do clock.sleep(0.10) redraw()      end end)
  clock.run(function() while true do clock.sleep(1/15) grid_redraw() end end)
end

--------------------------------------------------------------------
-- ENCODERS
--------------------------------------------------------------------
function enc(n,d)
  if n==1 and d~=0 then
    current_page = ((current_page-1 + (d>0 and 1 or -1)) % total_pages) + 1
  elseif current_page==2 then
    if n==2 and d~=0 then
      sel_param = util.clamp(sel_param + (d>0 and 1 or -1), 1, #params_def)
    elseif n==3 and d~=0 then
      local p = params_def[sel_param]
      p.value = util.clamp(p.value + p.step*d, p.min, p.max)
      if p.apply then p.apply(p.value) end
      if sel_param==2 then                                -- update pan spread
        for v=1,NUM_VOICES do
          local spread = util.linlin(1,NUM_VOICES,-p.value,p.value,v)
          softcut.pan(v, spread)
        end
      end
    end
  end
end

--------------------------------------------------------------------
-- KEY 2  (transport)
--------------------------------------------------------------------
function key(n,z) if n==2 and z==1 then toggle_transport() end end

--------------------------------------------------------------------
-- TRANSPORT + CLOCK
--------------------------------------------------------------------
local function stop_clock()
  running, waiting_to_start = false,false
  if clk_id then clock.cancel(clk_id) end
  crow.output[2].volts = 0
  current_step = 0
  keyboard.clear_pressed_keys()
end

local function start_clock()
  running = true
  clk_id  = clock.run(function()
    while running do
      crow.output[1]()
      current_step = (current_step % grid_cols)+1
      clock.sync(1/4)
    end
  end)
end

function toggle_transport()
  if running or waiting_to_start then stop_clock(); stop_looper(); return end

  crow.output[2].volts = 5
  local src = params:string("clock_source"):lower()
  if src:find("link") then
    waiting_to_start = true
    if #pattern>0 and not playing then pending_play_start=true end
    clock.run(function()
      clock.sync(4)
      if waiting_to_start then start_clock(); waiting_to_start=false end
      if pending_play_start then playing=true; start_playback(); pending_play_start=false end
    end)
  else start_clock() end
end

--------------------------------------------------------------------
-- VOICE PICK + ENVELOPE
--------------------------------------------------------------------
local function trigger_sample(note)
  -- steal oldest
  local v, oldest = 1, math.huge
  for i=1,NUM_VOICES do if voice_age[i] < oldest then oldest, v = voice_age[i], i end end

  softcut.play(v,0)
  softcut.rate(v, 2^((note-root_note)/12))
  softcut.position(v,0)
  softcut.play(v,1)
  voice_age[v] = util.time()
  last_voice   = v

  -- attack envelope
  local atk = params_def[4].value
  local lvl = params_def[1].value
  softcut.level(v,0)
  softcut.level_slew_time(v, atk)
  softcut.level(v,lvl)
end

local function release_voice(v)
  local rel = params_def[5].value
  softcut.level_slew_time(v, rel)
  softcut.level(v, 0)
end

--------------------------------------------------------------------
-- KEYBOARD EVENT
--------------------------------------------------------------------
local function process_keyboard_event(ev,z)
  if not ev then return end
  if z==1 then                                     -- NOTE ON
    crow.output[3].volts = (ev.note-60)/12
    crow.output[4].volts = 5
    trigger_sample(ev.note)
    if recording then
      table.insert(pattern,{time=util.time()-record_start_time,type="on",note=ev.note})
    end
  else                                             -- NOTE OFF
    crow.output[4].volts = 0
    release_voice(last_voice)
    if recording then
      table.insert(pattern,{time=util.time()-record_start_time,type="off",note=ev.note})
    end
  end
end

--------------------------------------------------------------------
-- GRID KEY
--------------------------------------------------------------------
function grid_key(x,y,z)
  -- bottom row (8)
  if y==8 and z==1 then
    if   x==1  then toggle_transport()
    elseif keyboard.root_buttons[x] then keyboard.root_note = keyboard.root_buttons[x]
    elseif x==16 then                       -- loop gate
      if recording then pending_record_stop=true; clock.run(wait_stop_and_play)
      elseif not playing and #pattern>0 then pending_play_start=true; clock.run(wait_start_play)
      elseif not playing then pending_record_start=true; clock.run(wait_start_record) end
    elseif x==15 then                       -- stop / clear
      if playing or recording then stop_looper() elseif #pattern>0 then pattern={} end
    elseif x==8  then current_page=1
    elseif x==9  then current_page=2 end
    return
  end

  -- sample selector on row‑1 of synth page
  local selector_y = keyboard.y_start
  local play_row_y = keyboard.y_start + keyboard.height - 1
  if current_page==2 and y==selector_y and z==1 then load_sample(x); return end

  -- page‑2 parameter sliders (rows 2‑6)
  if current_page==2 and y>=2 and y<=6 then
    -- find if this x matches one of our param columns
    local param_idx = nil
    for i,col in ipairs(param_cols) do
      if x == col then param_idx = i; break end
    end
    if param_idx then
      local p   = params_def[param_idx]
      local pct = slider_rows[y]
      p.value   = util.clamp(p.min + (p.max-p.min)*pct, p.min, p.max)
      if p.apply then p.apply(p.value) end
      sel_param = param_idx
      return
    end
  end

  -- keyboard rows
  if current_page==1 or (current_page==2 and y==play_row_y) then
    local ev = keyboard.handle_key(x,y,z)
    process_keyboard_event(ev,z)
  end
end

--------------------------------------------------------------------
-- LOOPER TIMERS / HELPERS
--------------------------------------------------------------------
function wait_start_record() clock.sync(4); if pending_record_start then pattern={}; recording=true; record_start_time=util.time(); pending_record_start=false end end
function wait_stop_and_play() clock.sync(4); if pending_record_stop then recording=false; playing=true; pad_pattern(); start_playback(); pending_record_stop=false end end
function wait_start_play()   clock.sync(4); if pending_play_start then playing=true; start_playback(); pending_play_start=false end end

function stop_looper() playing=false; recording=false; if play_clock then clock.cancel(play_clock) end end

function pad_pattern() local l=get_pattern_length(); local bar=60/clock.get_tempo()*4; local full=math.ceil(l/bar)*bar; if l<full then table.insert(pattern,{time=full,type="pad"}) end end
function get_pattern_length() local m=0; for _,e in ipairs(pattern) do if e.time>m then m=e.time end end; return math.max(m,0.1) end

function start_playback()
  if #pattern==0 then playing=false; return end
  if play_clock then clock.cancel(play_clock) end
  play_clock = clock.run(function()
    while playing do
      local t0=util.time()
      for _,e in ipairs(pattern) do
        clock.sleep(e.time-(util.time()-t0))
        if not playing then break end
        if e.type=="on" then crow.output[3].volts=(e.note-60)/12; crow.output[4].volts=5; trigger_sample(e.note)
        elseif e.type=="off" then crow.output[4].volts=0; release_voice(last_voice) end
      end
    end
  end)
end

--------------------------------------------------------------------
-- GRID REDRAW
--------------------------------------------------------------------
function grid_redraw()
  if not g then return end
  g:all(0)

  if current_page==1 then
    keyboard.grid_redraw(g)             -- rows 1‑7
  else
    local sel_y = keyboard.y_start         -- row‑1  sample buttons
    for x=1,16 do
      g:led(x, sel_y, (x==current_sample_idx) and 11 or 3)
    end

    -- rows 2‑6 : single bright LED (nearest row) for each parameter
    for param_idx = 1, 5 do
      local p   = params_def[param_idx]
      local pct = (p.value - p.min) / (p.max - p.min)      -- 0‑1
      -- rows map to pct values: row2=1.0, row3=0.75, row4=0.5, row5=0.25, row6=0
      local nearest_row, best_delta = 2, math.huge
      for r,val in pairs(slider_rows) do
        local d = math.abs(pct - val)
        if d < best_delta then best_delta, nearest_row = d, r end
      end

      local col = param_cols[param_idx]
      for r = 2, 6 do
        local lev = (r == nearest_row) and 11 or 2
        g:led(col, r, lev)
      end
    end

    -- small keyboard row‑7
    keyboard.grid_redraw_row(g, keyboard.y_start+keyboard.height-1)
  end

  -- bottom row LEDs
  g:led(1,8,(running or waiting_to_start) and 11 or 2)
  for x=3,6 do g:led(x,8,(keyboard.root_note==keyboard.root_buttons[x]) and 11 or 2) end
  g:led(16,8,recording and 11 or (playing and 7 or 2))
  g:led(15,8,(#pattern>0) and 4 or 1)
  g:led(8,8,(current_page==1) and 11 or 2)
  g:led(9,8,(current_page==2) and 11 or 2)

  g:refresh()
end

--------------------------------------------------------------------
-- SCREEN REDRAW (10 Hz)
--------------------------------------------------------------------
function redraw()
  screen.clear()

  if current_page==1 then
    screen.level(1);  screen.move(1,10); screen.text("bpm")
    screen.level(15); screen.move(1,20); screen.text(string.format("%d", math.floor(clock.get_tempo()+0.5)))
    screen.level(1);  screen.move(1,33); screen.text("clock")
    screen.level(15); screen.move(1,40); screen.text(waiting_to_start and "wait" or (running and "run" or "stop"))
    screen.level(1);  screen.move(50,33); screen.text("loop")
    screen.level(15); screen.move(50,40); screen.text(recording and "rec" or playing and "play" or (#pattern>0 and "stop" or "none"))
  else
    screen.level(1); screen.move(1,10); screen.text(params_def[sel_param].name)
    local vals={
      util.linlin(  0,   1,0,9, params_def[1].value),
      util.linlin(  0,   1,0,9, params_def[2].value),
      util.linlin( 50,2000,0,9, params_def[3].value),
      util.linlin(  0.1,   5,0,9, params_def[4].value),
      util.linlin(  0.1,   5,0,9, params_def[5].value),
    }
    local xstart={1,11,21,33,43}
    for i,v in ipairs(vals) do
      screen.level(i == sel_param and 11 or 1)
      screen.move(xstart[i], 20)
      screen.text(params_def[i].name:sub(1,1))
      local h=math.floor(v+0.5)

      screen.level(1)
      screen.rect(xstart[i],22,5,10); screen.fill()

      if h>0 then
        screen.level(i==sel_param and 11 or 5)
        screen.rect(xstart[i],31-h,5,h); screen.fill()
      end
    end
  end

  -- 16‑step bar
  local size,ybar=7,55
  for i=1,16 do
    local x=(i-1)*8
    screen.level(i==current_step and 15 or 1)
    screen.rect(x,ybar,size,size); screen.fill()
  end

  screen.update()
end

--------------------------------------------------------------------
-- CLEANUP
--------------------------------------------------------------------
function cleanup() crow.output[2].volts=0 end