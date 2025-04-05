obs = obslua

function script_description()
  return "Switch between select media sources when they finish playing"
end

modes = {RANDOM = 1, RANDOM_REPEATS = 2, ORDERED = 3}

mode = modes.RANDOM
logging = false
marker = nil
check_interval = 1

prev_time = 0

my_settings = nil
match_count_prop = nil
scene_data = {}

math.randomseed(os.time())

function script_update(settings)
  my_settings = settings 
  marker = obs.obs_data_get_string(settings, "marker")
  mode = obs.obs_data_get_int(settings, "mode")
  check_interval = obs.obs_data_get_int(settings, "check_interval")
  logging = obs.obs_data_get_bool(settings, "enable_logging")
  enabled = obs.obs_data_get_bool(settings, "enabled")
  randomize()
end

function script_defaults(settings)
  obs.obs_data_set_default_string(settings, "marker", "%%")
  obs.obs_data_set_default_int(settings, "mode", 1)
  obs.obs_data_set_default_int(settings, "check_interval", 500)
  obs.obs_data_set_default_bool(settings, "enabled", true)
  obs.obs_data_set_default_bool(settings, "enable_logging", false)
end

function script_properties()
  props = obs.obs_properties_create()

  local p = obs.obs_properties_add_list(props, "mode", "Mode", obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_INT)
  OPTIONS = {"Random", "Random w/ repeats", "Ordered"}
  for i,v in ipairs(OPTIONS) do
    obs.obs_property_list_add_int(p, v, i)
  end

  obs.obs_properties_add_text(props, "marker", "Marker", obs.OBS_TEXT_DEFAULT)
  obs.obs_properties_add_int(props, "check_interval", "Check Interval (ms)", 250, 1000000, 1)
  obs.obs_properties_add_bool(props, "enabled", "Enabled")
  obs.obs_properties_add_bool(props, "enable_logging", "Enable Logging")

  match_count_prop = obs.obs_properties_add_text(props, "match_count", "Matching Sources in Preview Scene", obs.OBS_TEXT_INFO)
  obs.obs_properties_add_button(props, "check_match_count_button", "Check Matches", update_match_count_display)
  obs.obs_properties_add_button(props, "randomize_button", "Randomize", randomize)

  update_match_count_display(props) -- set initial count 

  obs.obs_properties_apply_settings(props, my_settings)

  my_props = props
 
  return props
end

function randomize()
  scene_data = {}
end

function log(s)
  if logging then
    print(s)
  end
end

function update_match_count_display(props)
  local matches = get_matching_sources(obs.obs_frontend_get_current_preview_scene())
  if matches ~= nil then
    local label = string.format("%d matching source(s) in previewed scene", #matches)
    obs.obs_property_set_description(match_count_prop, label)
    obslua.obs_properties_apply_settings(props, my_settings);
  end
  return true
end

function get_matching_sources(scene, out_list)
  if out_list == nil then
    out_list = {}
  end

  if scene == nil then
    scene = obs.obs_frontend_get_current_scene()
    if scene == nil then
        return nil
    end
  end

  local scene = obs.obs_scene_from_source(scene)
  local scene_items = obs.obs_scene_enum_items(scene)

  local sources = obs.obs_enum_sources()
  log("Matching Sources:")
  for i = #scene_items, 1, -1 do
    local item = scene_items[i]
    local source = obs.obs_sceneitem_get_source(item)
    local source_name = obs.obs_source_get_name(source)
    local source_id = obs.obs_source_get_id(source)
    local visible = obs.obs_sceneitem_visible(item)

    if visible and source_id == "scene" then
      get_matching_sources(source, out_list)
    end

    if string.find(source_name, marker) then
      if source_id == "ffmpeg_source" or source_id == "vlc_source" then
        log("! " .. source_name)
        table.insert(out_list, { name = source_name, source = source, item = item })
      end
    end
  end

  obs.source_list_release(sources)

  return out_list
end

function shuffle_table(t)
    local n = #t
    for i = n, 2, -1 do
        local j = math.random(i)
        t[i], t[j] = t[j], t[i]
    end
end

function refresh_sources(scene)
  local sources = get_matching_sources()
  if mode ~= modes.ORDERED then
    shuffle_table(sources)
  end
  local scene_name = obs.obs_source_get_name(scene)
  scene_data[scene_name] = { sources = sources, played = {}}
  return sources
end

function script_tick(seconds)
  if not enabled then
    return
  end

  local current_time = obs.os_gettime_ns() / 1e6  -- Convert nanoseconds to milliseconds
  local scene = obs.obs_frontend_get_current_scene()
  local scene_name = obs.obs_source_get_name(scene)

  if scene_name == nil then
    return
  end

  if current_time - prev_time >= check_interval then
    log("Checking")
    prev_time = current_time

    if scene_data[scene_name] == nil then
      log("Cached sources not found for scene, loading: " .. scene_name)
      refresh_sources(scene)
    end
    sources = scene_data[scene_name].sources

    local n = 0
    local done = false
    for _, source in ipairs(sources) do
      if done then
        break
      end
      n = n + 1

      local visible = obs.obs_sceneitem_visible(source.item)
      if visible then
        local state = obs.obs_source_media_get_state(source.source)
        if state == obs.OBS_MEDIA_STATE_ENDED then
          log("Source stopped : " .. source.name)

          if mode == modes.RANDOM_REPEATS then
            refresh_sources(scene)
          end

          obs.obs_sceneitem_set_visible(source.item, false)

          local j = n
          while not done do
            j = j + 1
            if j > #sources then
              j = 1
            end
            if j == n and #scene_data[scene_name].sources > 1 then
              scene_data[scene_name].played[source.name] = {}
            else
              next_source = sources[j]
              if mode == modes.RANDOM_REPEATS or scene_data[scene_name].played[next_source.name] == nil then
                log("Starting source: " .. next_source.name)
                obs.obs_sceneitem_set_visible(next_source.item, true)
                obs.obs_source_media_restart(next_source.source)
                done = true
              end
            end
          end
        end
      end
    end
  end
end
