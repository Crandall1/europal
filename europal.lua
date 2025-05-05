-- europal
--
-- by chris randall
--
-- a grid control hub for 
-- eurorack clocking and
-- playing
--
-- crow out 1: seq clock 
-- crow out 2: seq run
-- crow out 3: keyboard cv
-- crow out 4: keyboard gate
--
--         k2: play/stop
--         k3: note looper
--         e2: bpm

engine.name = "None"

----------------------------------------------------------------
-- STATE
----------------------------------------------------------------
local running, waiting_to_start = false, false
local clk_id
local g
local grid_cols, grid_rows = 16, 8
local current_step = 0
local grid_brightness, pressed_keys = {}, {}
local octave_offset = 0
local root_note = 72
local root_buttons = { [3]=48, [4]=60, [5]=72, [6]=84 }

local pattern = {}
local recording = false
local playing = false
local paused = false
local record_start_time = 0
local play_clock = nil
local pending_record_start = false
local pending_record_stop = false
local pending_play_start = false

-- K3 state
local k3_press_count = 0

----------------------------------------------------------------
-- HELPERS
----------------------------------------------------------------
function get_note_at(x, y)
  local row_offset = (7 - y) * 5
  return root_note + row_offset + (x - 1)
end

function is_c_major(n)
  return ({[0]=1, [2]=1, [4]=1, [5]=1, [7]=1, [9]=1, [11]=1})[n % 12]
end

function update_grid_toggle_button()
  g:led(1,8,(running or waiting_to_start) and 11 or 4)
  g:refresh()
end

function pad_pattern_to_full_bar()
  local pattern_length = get_pattern_length()
  local bar_length = 60 / clock.get_tempo() * 4
  local bars = math.ceil(pattern_length / bar_length)
  local full_bar_length = bars * bar_length
  if pattern_length < full_bar_length then
    table.insert(pattern, { time = full_bar_length, type = "pad" })
    print(string.format("Padded pattern to %.2f sec (%.0f bars)", full_bar_length, bars))
  end
end

function get_pattern_length()
  local max_time = 0
  for _, event in ipairs(pattern) do
    if event.time > max_time then max_time = event.time end
  end
  return math.max(max_time, 0.1)
end

function wait_for_next_bar_to_start_recording()
  clock.sync(4)
  if pending_record_start then
    start_recording()
    pending_record_start = false
  end
end

function wait_for_next_bar_to_stop_and_play()
  clock.sync(4)
  if pending_record_stop then
    stop_recording_and_start_playback()
    pending_record_stop = false
  end
end

function wait_for_next_bar_to_start_playing()
  clock.sync(4)
  if pending_play_start then
    playing = true  -- make sure we are in 'playing' mode
    start_playback()
    pending_play_start = false
    grid_redraw()
  end
end

----------------------------------------------------------------
-- INIT
----------------------------------------------------------------
function init()
  crow.output[1].action = "{to(5,0.001),to(0,0.001)}"
  crow.output[2].volts  = 0

  g = grid.connect()
  grid_cols, grid_rows = g.cols, g.rows
  g.key = grid_key

  for x = 1, grid_cols do grid_brightness[x] = 1 end

  clock.run(function() while true do clock.sleep(0.1) redraw() end end)

  update_grid_toggle_button()
  grid_redraw()
end

----------------------------------------------------------------
-- TRANSPORT + K3 HANDLER
----------------------------------------------------------------
function key(n, z)
  if n == 2 and z == 1 then
    toggle_transport()
  end
  if n == 3 and z == 1 then
    handle_k3_press()
  end
end

function toggle_transport()
  if running or waiting_to_start then
    stop_clock()
    if playing or recording then
      stop_playback_or_recording()
    end
    return
  end
  crow.output[2].volts = 5
  if params:string("clock_source"):lower():find("link") then
    waiting_to_start = true
    if #pattern > 0 and not playing then
      pending_play_start = true
      print("Waiting for next bar to start both transport and loop...")
    end
    clock.run(function()
      clock.sync(4)
      if waiting_to_start then start_clock() end
      if pending_play_start then
        playing = true
        start_playback()
        pending_play_start = false
        grid_redraw()
      end
    end)
  else
    start_clock()
  end
end

function enc(n, d)
  if n == 2 then
    local bpm = params:get("clock_tempo")
    bpm = util.clamp(bpm + d, 40, 200)
    bpm = math.floor(bpm + 0.5)
    params:set("clock_tempo", bpm)
    redraw()
  end
end

function handle_k3_press()
  if k3_press_count >= 3 then k3_press_count = 0 end
  k3_press_count = k3_press_count + 1
  print("K3 press, count: "..k3_press_count)

  if k3_press_count == 1 then
    if not recording and not playing then
      pending_record_start = true
      print("K3: waiting to start recording...")
      clock.run(wait_for_next_bar_to_start_recording)
    end
  elseif k3_press_count == 2 then
    if recording then
      pending_record_stop = true
      print("K3: will stop recording and start playback...")
      clock.run(wait_for_next_bar_to_stop_and_play)
    elseif not recording and #pattern > 0 then
      pending_play_start = true
      print("K3: waiting to start playback...")
      clock.run(wait_for_next_bar_to_start_playing)
    end
  elseif k3_press_count == 3 then
    if playing or recording then
      stop_playback_or_recording()
      clear_pattern()
      print("K3: stopped + cleared loop")
    end
  end
  grid_redraw()
end

----------------------------------------------------------------
-- CLOCK
----------------------------------------------------------------
function start_clock()
  running, waiting_to_start = true, false
  clk_id = clock.run(clock_pulse)
  update_grid_toggle_button()
end

function stop_clock()
  running, waiting_to_start = false, false
  if clk_id then clock.cancel(clk_id) end
  crow.output[2].volts = 0
  current_step = 0
  pressed_keys = {}
  for x = 1, grid_cols do grid_brightness[x] = 1 end
  grid_redraw()
  update_grid_toggle_button()
end

function clock_pulse()
  while running do
    crow.output[1]()
    for x=1,grid_cols do
      if grid_brightness[x]>1 then
        grid_brightness[x] = math.max(1, grid_brightness[x]*0.75)
      end
    end
    current_step = (current_step % grid_cols) + 1
    grid_redraw()
    clock.sync(1/4)
  end
end

----------------------------------------------------------------
-- GRID
----------------------------------------------------------------
function grid_key(x, y, z)
  local id = x.."_"..y

  if y==8 then
    if x==1 and z==1 then
      toggle_transport()
    elseif root_buttons[x] and z==1 then
      root_note = root_buttons[x]
      grid_redraw()
    elseif x==16 and z==1 then
      if recording then
        pending_record_stop = true
        print("Will stop recording and start playback at next bar...")
        clock.run(wait_for_next_bar_to_stop_and_play)
      elseif (not playing and not recording) and #pattern > 0 then
        pending_play_start = true
        print("Waiting for next bar to start playback...")
        clock.run(wait_for_next_bar_to_start_playing)
      elseif not playing and not recording then
        pending_record_start = true
        print("Waiting for next bar to start recording...")
        clock.run(wait_for_next_bar_to_start_recording)
      end
    elseif x==15 then
      if z==1 then
        if playing or recording then
          stop_playback_or_recording()
        elseif not playing and #pattern > 0 then
          clear_pattern()
        end
      end
      grid_redraw()
    end
    return
  end

  if y>=2 and y<=7 then
    if z==1 then
      local note = get_note_at(x, y) + octave_offset
      crow.output[3].volts = (note - 60) / 12
      crow.output[4].volts = 5
      pressed_keys[id]=true
      if recording then
        table.insert(pattern, { time = util.time() - record_start_time, type = "on", note = note })
      end
    else
      crow.output[4].volts = 0
      pressed_keys[id]=false
      if recording then
        table.insert(pattern, { time = util.time() - record_start_time, type = "off", note = get_note_at(x, y) + octave_offset })
      end
    end
    grid_redraw()
  end
end

----------------------------------------------------------------
-- PATTERN
----------------------------------------------------------------
function start_recording()
  pattern = {}
  recording = true
  playing = false
  paused = false
  record_start_time = util.time()
  grid_redraw()
end

function stop_recording_and_start_playback()
  if #pattern == 0 then
    recording = false
    playing = false
    paused = false
    grid_redraw()
    return
  end
  recording = false
  playing = true
  paused = false
  pad_pattern_to_full_bar()
  start_playback()
  grid_redraw()
end

function stop_playback_or_recording()
  if recording then
    recording = false
    pending_record_start = false
    pending_record_stop = false
  end
  if playing then
    playing = false
    if play_clock then clock.cancel(play_clock) end
  end
  paused = false
  grid_redraw()
end

function clear_pattern()
  pattern = {}
  grid_redraw()
end

function start_playback()
  if #pattern == 0 then
    playing = false
    return
  end
  if play_clock then clock.cancel(play_clock) end
  play_clock = clock.run(function()
    while playing do
      local start_time = util.time()
      local length = get_pattern_length()
      for _, event in ipairs(pattern) do
        clock.sleep(event.time - (util.time() - start_time))
        if not playing then break end
        if event.type == "on" then
          crow.output[3].volts = (event.note - 60) / 12
          crow.output[4].volts = 5
        elseif event.type == "off" then
          crow.output[4].volts = 0
        end
      end
    end
  end)
end

----------------------------------------------------------------
-- GRID DRAW
----------------------------------------------------------------
function grid_redraw()
  for y=2,7 do
    for x=1,grid_cols do
      local id = x.."_"..y
      local bright
      if pressed_keys[id] then bright = 11
      else
        local note = get_note_at(x,y)+octave_offset
        if note%12==0 then bright = 5
        elseif is_c_major(note) then bright = 2
        else bright = 0 end
      end
      g:led(x,y,bright)
    end
  end
  g:led(1,8,(running or waiting_to_start) and 11 or 2)
  for x=3,6 do
    local bright = (root_note==root_buttons[x]) and 11 or 2
    g:led(x,8,bright)
  end
  local rec_bright = recording and 11 or (playing and 7 or 2)
  g:led(16,8,rec_bright)
  local bright_15 = (#pattern > 0) and 4 or 1
  g:led(15,8,bright_15)
  g:refresh()
end

----------------------------------------------------------------
-- SCREEN
----------------------------------------------------------------
function redraw()
  screen.clear()
  
  -- BPM DISPLAY
  screen.level(1)
  screen.move(1,13)
  screen.text("bpm")
  screen.move(1, 20)
  screen.level(15)
  screen.text(string.format("%d", math.floor(clock.get_tempo() + 0.5)))
  
  -- CLOCK DISPLAY
  screen.level(1)
  screen.move(1,33)
  screen.text("clock")
  screen.move(1,40)
  screen.level(15)
  local transport_state = waiting_to_start and "waiting" or (running and "running" or "stopped")
  screen.text(transport_state)
  
  -- LOOP DISPLAY
  screen.level(1)
  screen.move(50,33)
  screen.text("loop")
  screen.move(50,40)
  screen.level(15)
  local loop_state
  if pending_record_start then
    loop_state = "wait (rec)"
  elseif pending_play_start then
    loop_state = "wait (play)"
  elseif recording then
    loop_state = "recording"
  elseif playing then
    loop_state = "playing"
  elseif paused then
    loop_state = "paused"
  elseif #pattern > 0 then
    loop_state = "stopped"
  else
    loop_state = "none"
  end
  screen.text(loop_state)
  local size = 7
  local y = 50
  for i=1,16 do
    local x = (i-1)*(size + 1)
    if i==current_step then
      screen.level(15)
      screen.rect(x,y,size,size)
      screen.fill()
    else
      screen.level(1)
      screen.rect(x,y,size,size)
      screen.fill()
    end
  end
  screen.update()
end

----------------------------------------------------------------
-- CLEANUP
----------------------------------------------------------------
function cleanup()
  crow.output[2].volts = 0
end