-- poser.lua
-- Aseprite 1.3.x compatible.
--
-- User-defined 2D hierarchy of "verts" drawn as circles with per-vert radius.
--
-- Edit modes (mutually exclusive):
--   - Move (bool): click+drag a vert to move it (children follow via parenting) in the ACTIVE state (rest/pose).
--   - Add  (bool): click+drag a vert to create a CHILD vert and drag the new child (in ACTIVE state).
--
-- Pose states (mutually exclusive):
--   - Rest (bool): edits base pose (base positions + base radii). MMB-drag changes BASE radius.
--   - Pose (bool): edits pose pose (pose positions + Z). MMB-drag changes Z.
--
-- Z variables:
--   - 2D mode uses pose_z2d (percent units, local). Radius in Pose (2D) = rest_r + rest_r*(effectiveZ2D/100).
--   - 3D mode uses pose_z3d (percent units, local) as DEPTH ONLY. In 3D, radius is NOT scaled by Z.
--   - Effective Z is hierarchical (parent Z affects children) separately per mode.
--
-- 3D view:
--   - "3d" enables orbit camera (yaw/pitch; no roll) with perspective projection.
--   - FOV slider (degrees) when 3d is enabled.
--   - Mouse wheel zooms (camera distance) (no radius/Z via wheel).
--   - MMB drag:
--       * Over a selected vert: adjusts radius (Rest) or Z (Pose) (kept).
--       * Else:
--           - Alt+MMB drag pans view (camera target) in camera-right/up directions.
--           - MMB drag rotates view (yaw/pitch).
--   - Moving verts in 3D respects camera angle (perspective-aware).
--   - In 3D, NO Z-based alpha fading.
--   - Optional 3D alpha effects:
--       * order alpha: compares each vert to its parent depth from camera POV.
--       * depth alpha: maps nearest vert to 100% and farthest vert to 10% alpha.
--
-- Right-drag (2D): rope-style IK solve with soft (max-length-only) constraints across the full connected component; verts may overlap and motion propagates through ancestors/descendants.

-- Multi-select:
--   - Shift+click adds verts to selection (last clicked becomes "last selected").
--   - Click empty space deselects all.
--
-- Buttons:
--   - Parent: last selected becomes parent of all other selected verts. (REST only)
--   - Mirror: duplicates last selected vert AND its subtree across pad center X. (REST only)
--   - Delete: deletes selected verts but keeps their children (children become roots). (REST only)
--   - Revert: (POSE only) resets selected verts pose position to rest position and sets pose Zs to 0.
--   - Revert All: (POSE only) resets ALL verts pose position to rest position and sets pose Zs to 0.
--
-- Mirror modifications:
--   - If enabled: moving a vert mirrors its motion and mirrored subtree follows.
--   - If enabled: radius edits in Rest mirror to mirror counterpart (ONLY that vert).
--   - If enabled: Z edits in Pose mirror to mirror counterpart (ONLY that vert) (2D or 3D Z depending on view).
--
-- Save / Load:
--   - Saves ALL verts (rest+pose positions, rest radius, pose_z2d, pose_z3d), parents, mirror pairs, and link overrides.
--   - Saves also UI flags and 3D camera (yaw/pitch/fov/dist/pan) and display_spheres.
--   - When loading older files without z2d/z3d, legacy pose_z is mapped to BOTH.

do
  local spr = app.activeSprite
  if not spr then return app.alert("No active sprite.") end

  local function clamp(v,a,b) if v<a then return a elseif v>b then return b else return v end end

  local function btnIs(ev, want)
    local b = ev.button
    if want == "LEFT" then
      return (b == MouseButton.LEFT) or (b == 1) or (b == "left")
    elseif want == "MIDDLE" then
      return (b == MouseButton.MIDDLE) or (b == 3) or (b == "middle")
    elseif want == "RIGHT" then
      return (b == MouseButton.RIGHT) or (b == 2) or (b == "right")
    end
    return false
  end

  local function dist2(ax,ay,bx,by)
    local dx = ax - bx
    local dy = ay - by
    return dx*dx + dy*dy
  end

  local function wheelDeltaY(ev)
    local dy = 0
    if ev.deltaY ~= nil then dy = ev.deltaY
    elseif ev.dy ~= nil then dy = ev.dy
    elseif ev.delta ~= nil then dy = ev.delta
    elseif ev.wheelDelta ~= nil then dy = -ev.wheelDelta
    end
    return tonumber(dy) or 0
  end

  local function evShift(ev)
    return (ev.shiftKey == true) or (ev.shift == true)
  end

  local function evAlt(ev)
    return (ev.altKey == true) or (ev.alt == true)
  end

  -- =========================
  -- script folder + txt preset helpers (key=value)
  -- =========================
  local function getScriptDir()
    local info = debug.getinfo(1, 'S')
    if not info or not info.source then return nil, "Could not determine script source path." end
    local src = info.source
    if src:sub(1,1) == '@' then src = src:sub(2) end
    local dir = app.fs.filePath(src)
    if dir == "" then return nil, "Script directory is empty or invalid." end
    return app.fs.normalizePath(dir), nil
  end

  local function parseValue(v)
    if v == "true" then return true end
    if v == "false" then return false end
    local n = tonumber(v)
    if n ~= nil then return n end
    return v
  end

  local function loadKeyValueFile(path)
    local t = {}
    local f = io.open(path, "r")
    if not f then return t, "Could not open: " .. tostring(path) end
    for line in f:lines() do
      local k, v = line:match("^%s*([^=]+)%s*=%s*(.-)%s*$")
      if k and v then t[k] = parseValue(v) end
    end
    f:close()
    return t, nil
  end

  local function saveKeyValueFile(path, data)
    local f = io.open(path, "w")
    if not f then return false, "Could not write: " .. tostring(path) end
    local function w(k, v) f:write(tostring(k), "=", tostring(v), "\n") end
    local ks = {}
    for k,_ in pairs(data) do ks[#ks+1] = k end
    table.sort(ks, function(a,b) return tostring(a) < tostring(b) end)
    for _,k in ipairs(ks) do w(k, data[k]) end
    f:close()
    return true, nil
  end

  local function fileSafe(s)
    s = tostring(s or "")
    s = s:gsub("[\\/]+", "")
    s = s:gsub("[^%w%._%-%s]", "")
    s = s:gsub("^%s+", ""):gsub("%s+$", "")
    if s == "" then s = "default.txt" end
    if not string.lower(s):match("%.txt$") then s = s .. ".txt" end
    return s
  end

  local SCRIPT_DIR, SD_ERR = getScriptDir()
  if not SCRIPT_DIR then return app.alert(SD_ERR or "Failed to locate script directory.") end

  local function listPresetTxtFiles(dir)
    local files, err = app.fs.listFiles(dir)
    if not files then return {}, "Failed to list files: " .. (err or "unknown") end
    local out = {}
    local seen = {}
    for _, file in ipairs(files) do
      local lower = string.lower(file)
      if lower:match("^.+%.txt$") then
        if not lower:match("%.shape%.txt$") and not lower:match("%.pose%.txt$") and not lower:match("%.sphere%.txt$") then
          if not seen[lower] then
            seen[lower] = true
            out[#out+1] = file
          end
        end
      end
    end
    table.sort(out, function(a,b) return string.lower(a) < string.lower(b) end)
    return out, nil
  end

  local function presetPathForSelected(filename)
    return app.fs.joinPath(SCRIPT_DIR, filename)
  end

  -- =========================
  -- view
  -- =========================
  local PAD_W, PAD_H = 380, 260
  local margin = 8
  local cx = math.floor(PAD_W/2 + 0.5)
  local cy = math.floor(PAD_H/2 + 0.5)

  local function isInsidePad(x,y)
    return x >= 0 and y >= 0 and x < PAD_W and y < PAD_H
  end

  local function clampToPad(x,y)
    x = clamp(x, margin, PAD_W - 1 - margin)
    y = clamp(y, margin, PAD_H - 1 - margin)
    return x, y
  end

  -- =========================
  -- 3D view toggles + camera
  -- =========================
  local view3d = false
  local display_spheres = true
  local order_alpha = false
  local depth_alpha = false
  local live_preview = false

  local PREVIEW_NAME = "_PoserPreview"
  local OUTPUT_NAME = "Poser Verts"

  local VIEW_SENS = 0.010
  local PAN_SENS = 1.0
  local PITCH_MAX = 1.52 -- ~87 deg

  local yaw = 0.0
  local pitch = 0.0

  local fov_deg = 60
  local fov_2d = 60
  local res_scale = 1.0
  local cam_dist = 420.0
  local CAM_DIST_MIN = 30.0
  local CAM_DIST_MAX = 4000.0

  local pan = { x=0.0, y=0.0, z=0.0 }

  local camR = {x=1,y=0,z=0}
  local camU = {x=0,y=1,z=0}
  local camF = {x=0,y=0,z=1} -- forward

  local function vdot(a,b) return a.x*b.x + a.y*b.y + a.z*b.z end

  local function findLayerByName(name)
    for _, lyr in ipairs(spr.layers) do
      if lyr.name == name then return lyr end
    end
    return nil
  end

  local function ensureLayer(name)
    local lyr = findLayerByName(name)
    if not lyr then
      lyr = spr:newLayer()
      lyr.name = name
    end
    return lyr
  end

  local function deletePreviewLayer()
    local lyr = findLayerByName(PREVIEW_NAME)
    if lyr then spr:deleteLayer(lyr) end
  end

  local function replaceCel(layer, frameObj, img, pos)
    local old = layer:cel(frameObj)
    if old then spr:deleteCel(old) end
    return spr:newCel(layer, frameObj, img, pos or Point(0, 0))
  end
  local function vcross(a,b)
    return {
      x = a.y*b.z - a.z*b.y,
      y = a.z*b.x - a.x*b.z,
      z = a.x*b.y - a.y*b.x
    }
  end
  local function vlen(a) return math.sqrt(a.x*a.x + a.y*a.y + a.z*a.z) end
  local function vnorm(a)
    local l = vlen(a)
    if l < 1e-12 then return {x=0,y=0,z=0} end
    return {x=a.x/l, y=a.y/l, z=a.z/l}
  end
  local function vrot(v, axis, ang)
    local ax = vnorm(axis)
    local c = math.cos(ang)
    local s = math.sin(ang)
    local d = vdot(ax, v)
    local cxv = vcross(ax, v)
    return {
      x = v.x*c + cxv.x*s + ax.x*d*(1-c),
      y = v.y*c + cxv.y*s + ax.y*d*(1-c),
      z = v.z*c + cxv.z*s + ax.z*d*(1-c),
    }
  end

  local function camRebuild()
    local R = {x=1,y=0,z=0}
    local U = {x=0,y=1,z=0}
    local F = {x=0,y=0,z=1}

    local worldY = {x=0,y=1,z=0}
    R = vrot(R, worldY, yaw)
    F = vrot(F, worldY, yaw)
    U = {x=0,y=1,z=0}

    R = vnorm(R)
    U = vrot(U, R, pitch)
    F = vrot(F, R, pitch)

    camR = vnorm(R)
    camU = vnorm(U)
    camF = vnorm(F)
  end

  camRebuild()

  local viewRot = { active=false, lastX=0, lastY=0 }
  local viewPanDrag = { active=false, lastX=0, lastY=0 }

  local function beginViewRotate(ev)
    viewRot.active = true
    viewRot.lastX = ev.x
    viewRot.lastY = ev.y
  end

  local function updateViewRotate(ev)
    if not viewRot.active then return end
    local dx = (ev.x - viewRot.lastX)
    local dy = (ev.y - viewRot.lastY)
    viewRot.lastX = ev.x
    viewRot.lastY = ev.y

    yaw = yaw + (dx * VIEW_SENS)
    pitch = clamp(pitch - (dy * VIEW_SENS), -PITCH_MAX, PITCH_MAX)
    camRebuild()
  end

  local function endViewRotate()
    viewRot.active = false
  end

  local function beginViewPan(ev)
    viewPanDrag.active = true
    viewPanDrag.lastX = ev.x
    viewPanDrag.lastY = ev.y
  end

  local function updateViewPan(ev)
    if not viewPanDrag.active then return end
    local dx = (ev.x - viewPanDrag.lastX)
    local dy = (ev.y - viewPanDrag.lastY)
    viewPanDrag.lastX = ev.x
    viewPanDrag.lastY = ev.y

    local scale = (PAN_SENS * (cam_dist / 420.0))
    pan.x = pan.x + (camR.x * dx + camU.x * dy) * scale
    pan.y = pan.y + (camR.y * dx + camU.y * dy) * scale
    pan.z = pan.z + (camR.z * dx + camU.z * dy) * scale
  end

  local function endViewPan()
    viewPanDrag.active = false
  end

  local function zoomByWheel(dy)
    if dy == 0 then return end
    local step = 1.12
    if dy > 0 then
      cam_dist = clamp(cam_dist * step, CAM_DIST_MIN, CAM_DIST_MAX)
    else
      cam_dist = clamp(cam_dist / step, CAM_DIST_MIN, CAM_DIST_MAX)
    end
  end

  local function focalFromFov()
    local fov = math.rad(clamp(tonumber(fov_deg) or 60, 15, 140))
    local halfW = (PAD_W * 0.5)
    return halfW / math.tan(fov * 0.5)
  end

  -- =========================
  -- 2D view pan/zoom
  -- =========================
  local view2d = { zoom = 1.0, panx = 0.0, pany = 0.0 }
  local view2dPanDrag = { active=false, lastX=0, lastY=0 }

  local function beginView2DPan(ev)
    view2dPanDrag.active = true
    view2dPanDrag.lastX = ev.x
    view2dPanDrag.lastY = ev.y
  end

  local function updateView2DPan(ev)
    if not view2dPanDrag.active then return end
    local dx = (ev.x - view2dPanDrag.lastX)
    local dy = (ev.y - view2dPanDrag.lastY)
    view2dPanDrag.lastX = ev.x
    view2dPanDrag.lastY = ev.y
    view2d.panx = view2d.panx + dx
    view2d.pany = view2d.pany + dy
  end

  local function endView2DPan()
    view2dPanDrag.active = false
  end

  local function zoom2DByWheel(dy)
    if dy == 0 then return end
    local step = 1.12
    -- Aseprite: dy > 0 is typically wheel DOWN
    if dy > 0 then
      view2d.zoom = clamp(view2d.zoom / step, 0.05, 40.0) -- down = zoom out
    else
      view2d.zoom = clamp(view2d.zoom * step, 0.05, 40.0) -- up = zoom in
    end
  end

  local function resetViewToFront()
    yaw = 0.0
    pitch = 0.0
    fov_deg = 60
    fov_2d = 60
    res_scale = 1.0
    cam_dist = 420.0
    pan.x, pan.y, pan.z = 0.0, 0.0, 0.0
    camRebuild()
    view2d.zoom = 1.0
    view2d.panx = 0.0
    view2d.pany = 0.0
  end

  -- =========================
  -- nodes + links + mirrors
  -- =========================
  local nodes = {}
  local order = {}
  local roots = {}
  local nextId = 1
  local links = {}

  local function newId()
    local id = tostring(nextId)
    nextId = nextId + 1
    return id
  end

  local function addNodeWithId(id, parentId, r)
    nodes[id] = {
      id = id,
      parent = parentId or nil,
      children = {},

      rest_localx = 0, rest_localy = 0,
      pose_localx = 0, pose_localy = 0,

      worldx = 0, worldy = 0,

      rest_r = r or 14,

      pose_z2d = 0,
      pose_z3d = 0,

      pose_pos_set = false,

      sphere = true,
      pinned = false,

      mirror = nil,

      prox_sign_2d = 1,
    }
    order[#order+1] = id
    return id
  end

  local function addNode(parentId, r)
    return addNodeWithId(newId(), parentId, r)
  end

  local function buildChildren()
    for _,id in ipairs(order) do
      if nodes[id] then nodes[id].children = {} end
    end
    roots = {}
    for _,id in ipairs(order) do
      local n = nodes[id]
      if n then
        if n.parent and nodes[n.parent] then
          nodes[n.parent].children[#nodes[n.parent].children+1] = id
        else
          roots[#roots+1] = id
        end
      end
    end
  end

  local function forEachDescendant(rootId, fn)
    buildChildren()
    local function rec(id)
      if not nodes[id] then return end
      fn(id)
      for _,cid in ipairs(nodes[id].children) do rec(cid) end
    end
    rec(rootId)
  end

  local function markPosePosSetSubtree(rootId)
    if not rootId or not nodes[rootId] then return end
    forEachDescendant(rootId, function(id)
      local n = nodes[id]
      if n then n.pose_pos_set = true end
    end)
  end

  local function ensurePoseDefaultsFromRest()
    for _,id in ipairs(order) do
      local n = nodes[id]
      if n and (n.pose_pos_set ~= true) then
        n.pose_localx = n.rest_localx
        n.pose_localy = n.rest_localy
      end
    end
  end

  local function pairKey(a,b)
    if not a or not b or a==b then return nil end
    if tostring(a) < tostring(b) then return a.."|"..b end
    return b.."|"..a
  end

  local function isParentChild(a,b)
    local na, nb = nodes[a], nodes[b]
    if not na or not nb then return false end
    return (na.parent == b) or (nb.parent == a)
  end

  local function getLinkState(a,b)
    local k = pairKey(a,b)
    if not k then return false end
    local v = links[k]
    if v ~= nil then return (v == true) end
    if isParentChild(a,b) then return true end
    return false
  end

  local function setLinkState(a,b,on)
    local k = pairKey(a,b)
    if not k then return end
    if isParentChild(a,b) then
      links[k] = (on == true) and true or false
    else
      if on == true then links[k] = true else links[k] = nil end
    end
  end

  local function clearMirrorFor(id)
    local n = nodes[id]
    if not n then return end
    local m = n.mirror
    n.mirror = nil
    if m and nodes[m] and nodes[m].mirror == id then
      nodes[m].mirror = nil
    end
  end

  local function setMirrorPair(a,b)
    if not a or not b or a==b then return end
    if not nodes[a] or not nodes[b] then return end
    clearMirrorFor(a)
    clearMirrorFor(b)
    nodes[a].mirror = b
    nodes[b].mirror = a
  end

  -- =========================
  -- state selection: rest vs pose
  -- =========================
  local stateRest = true
  local statePose = false

  local function setState(restOn, poseOn, dlg)
    local wasPose = (statePose == true)

    stateRest = (restOn == true)
    statePose = (poseOn == true)
    if stateRest and statePose then statePose = false end
    if not stateRest and not statePose then stateRest = true end

    if (not wasPose) and statePose then
      ensurePoseDefaultsFromRest()
    end

    if dlg then
      dlg:modify{ id="state_rest", selected=stateRest }
      dlg:modify{ id="state_pose", selected=statePose }
    end
  end

  local function getActiveLocal(n)
    if statePose then
      return n.pose_localx, n.pose_localy
    else
      return n.rest_localx, n.rest_localy
    end
  end

  local function setActiveLocal(n, lx, ly)
    if statePose then
      n.pose_localx, n.pose_localy = lx, ly
    else
      n.rest_localx, n.rest_localy = lx, ly
    end
  end

  local function computeWorldFromActiveLocals()
    buildChildren()
    local function rec(id, parentWx, parentWy)
      local n = nodes[id]
      if not n then return end

      local lx, ly = getActiveLocal(n)
      if n.parent and nodes[n.parent] then
        n.worldx = parentWx + lx
        n.worldy = parentWy + ly
      else
        n.worldx = lx
        n.worldy = ly
      end

      for _,cid in ipairs(n.children) do
        rec(cid, n.worldx, n.worldy)
      end
    end
    for _,rid in ipairs(roots) do
      rec(rid, 0, 0)
    end
  end

  local function computeActiveLocalsFromWorld()
    for _,id in ipairs(order) do
      local n = nodes[id]
      if n then
        if n.parent and nodes[n.parent] then
          local p = nodes[n.parent]
          setActiveLocal(n, n.worldx - p.worldx, n.worldy - p.worldy)
        else
          setActiveLocal(n, n.worldx, n.worldy)
        end
      end
    end
  end

  -- =========================
  -- effective Z (no alpha in 3D)
  -- =========================
  local function getLocalZ(n)
    if not n then return 0 end
    if view3d then return tonumber(n.pose_z3d) or 0 end
    return tonumber(n.pose_z2d) or 0
  end

  local function setLocalZ(n, v)
    if view3d then n.pose_z3d = v else n.pose_z2d = v end
  end

  local function buildEffectiveZMap()
    buildChildren()
    local eff = {}
    local function rec(id, parentZ)
      local n = nodes[id]
      if not n then return end
      local z = (parentZ or 0) + getLocalZ(n)
      eff[id] = z
      for _,cid in ipairs(n.children) do rec(cid, z) end
    end
    for _,rid in ipairs(roots) do rec(rid, 0) end
    return eff
  end

  local R_MIN = 3
  local R_MAX = 200

  -- forward declarations (range helpers)
  local computeRestWorldPositions
  local restRangeToParent
  local getFrontSignForRadiusBoost
  local apply2DProximityRadiusBoost
  local build2DProximityOverlapMap

  -- =========================
  -- projection
  -- =========================
  local function buildProjectedMap(effZ)
    local proj = {}

    if not view3d then
      local restWorld = nil
      local overlapMap = nil
      if statePose then
        restWorld = computeRestWorldPositions()
        overlapMap = build2DProximityOverlapMap(restWorld)
      end
      for _,id in ipairs(order) do
        local n = nodes[id]
        if n then
          local base = clamp(tonumber(n.rest_r) or 14, R_MIN, R_MAX)
          local ez = (statePose and effZ) and (tonumber(effZ[id]) or 0) or 0
          local r = base
          if statePose then
            r = clamp(base + (base * (ez / 100.0)), 1, 400)
            if n.parent and nodes[n.parent] and restWorld then
              local boosted = apply2DProximityRadiusBoost(id, n, base, r, restWorld, overlapMap)
              if boosted then r = boosted end
            end
          end
          local sx = cx + (n.worldx - cx) * view2d.zoom + view2d.panx
          local sy = cy + (n.worldy - cy) * view2d.zoom + view2d.pany
          proj[id] = { x = sx, y = sy, r = r * view2d.zoom, base = base, zpix = 0, camX = nil, camY = nil, camZ = nil }
        end
      end
      return proj
    end

    local f = focalFromFov()
    local epsZ = 0.001

    for _,id in ipairs(order) do
      local n = nodes[id]
      if n then
        local base = clamp(tonumber(n.rest_r) or 14, R_MIN, R_MAX)

        local ez = (statePose and effZ) and (tonumber(effZ[id]) or 0) or 0
        local zpix = base * (ez / 100.0)

        local wx = (n.worldx or 0) - cx + pan.x
        local wy = (n.worldy or 0) - cy + pan.y
        local wz = zpix + pan.z

        local vec = { x=wx, y=wy, z=wz }

        local camX = vdot(vec, camR)
        local camY = vdot(vec, camU)
        local camZ = vdot(vec, camF) + cam_dist
        if camZ < epsZ then camZ = epsZ end

        local sx = cx + (camX * f / camZ)
        local sy = cy + (camY * f / camZ)

        local r = base * (f / camZ)
        r = clamp(r, 1, 2000)

        proj[id] = { x = sx, y = sy, r = r, base = base, zpix = zpix, camX = camX, camY = camY, camZ = camZ }
      end
    end

    return proj
  end

  local function buildRasterProjectedMap(effZ, fallbackProj)
    if view3d then return fallbackProj end
    if (tonumber(res_scale) or 1.0) >= 0.999 then return fallbackProj end

    local proj = {}
    local restWorld = nil
    local overlapMap = nil
    if statePose then
      restWorld = computeRestWorldPositions()
      overlapMap = build2DProximityOverlapMap(restWorld)
    end

    for _,id in ipairs(order) do
      local n = nodes[id]
      if n then
        local base = clamp(tonumber(n.rest_r) or 14, R_MIN, R_MAX)
        local ez = (statePose and effZ) and (tonumber(effZ[id]) or 0) or 0
        local r = base
        if statePose then
          r = clamp(base + (base * (ez / 100.0)), 1, 400)
          if n.parent and nodes[n.parent] and restWorld then
            local boosted = apply2DProximityRadiusBoost(id, n, base, r, restWorld, overlapMap)
            if boosted then r = boosted end
          end
        end
        local sx = n.worldx + view2d.panx
        local sy = n.worldy + view2d.pany
        proj[id] = { x = sx, y = sy, r = r, base = base, zpix = 0, camX = nil, camY = nil, camZ = nil }
      end
    end
    return proj
  end

  local function screenDeltaToWorldDelta3(dsx, dsy, refCamZ)
    local f = focalFromFov()
    local z = refCamZ or cam_dist
    if z < 0.001 then z = 0.001 end

    local dCamX = dsx * z / f
    local dCamY = dsy * z / f

    return {
      x = camR.x * dCamX + camU.x * dCamY,
      y = camR.y * dCamX + camU.y * dCamY,
      z = camR.z * dCamX + camU.z * dCamY,
    }
  end

  local function screenToWorldAtCamZ(sx, sy, camZ)
    local f = focalFromFov()
    local z = camZ or cam_dist
    if z < 0.001 then z = 0.001 end

    local camX = (sx - cx) * z / f
    local camY = (sy - cy) * z / f
    local vec = {
      x = camR.x * camX + camU.x * camY + camF.x * (z - cam_dist),
      y = camR.y * camX + camU.y * camY + camF.y * (z - cam_dist),
      z = camR.z * camX + camU.z * camY + camF.z * (z - cam_dist),
    }

    return {
      x = vec.x + cx - pan.x,
      y = vec.y + cy - pan.y,
      zpix = vec.z - pan.z,
    }
  end

  -- =========================
  -- 3D alpha map
  -- =========================
  local function buildAlphaMap(proj)
    local alpha = {}
    for _,id in ipairs(order) do alpha[id] = 255 end
    if not view3d then return alpha end

    local minZ, maxZ = nil, nil
    if depth_alpha then
      for _,id in ipairs(order) do
        local p = proj[id]
        if p and p.camZ then
          if (not minZ) or (p.camZ < minZ) then minZ = p.camZ end
          if (not maxZ) or (p.camZ > maxZ) then maxZ = p.camZ end
        end
      end
    end

    local span = ((maxZ or 0) - (minZ or 0))

    for _,id in ipairs(order) do
      local p = proj[id]
      local a = 255

      if order_alpha then
        local n = nodes[id]
        if n and n.parent and nodes[n.parent] and p and proj[n.parent] then
          local pa = proj[n.parent]
          if (p.camZ or 0) > (pa.camZ or 0) then
            a = math.min(a, math.floor(255 * 0.30 + 0.5))
          end
        end
      end

      if depth_alpha and p and p.camZ then
        local t = 0
        if span > 1e-9 then t = (p.camZ - minZ) / span end
        t = clamp(t, 0.0, 1.0)
        local da = (1.0 - t) * 1.0 + t * 0.10
        a = math.min(a, math.floor(255 * da + 0.5))
      end

      alpha[id] = clamp(a, 0, 255)
    end

    return alpha
  end

  -- =========================
  -- selection
  -- =========================
  local selected = {}
  local selectedList = {}
  local lastSelected = nil

  local function selectionCount() return #selectedList end

  local function clearSelection()
    selected = {}
    selectedList = {}
    lastSelected = nil
  end

  local function setSingleSelection(id)
    clearSelection()
    if id and nodes[id] then
      selected[id] = true
      selectedList[1] = id
      lastSelected = id
    end
  end

  local function addToSelection(id)
    if not id or not nodes[id] then return end
    if selected[id] then
      for i=#selectedList,1,-1 do
        if selectedList[i] == id then table.remove(selectedList, i) break end
      end
      selectedList[#selectedList+1] = id
      lastSelected = id
      return
    end
    selected[id] = true
    selectedList[#selectedList+1] = id
    lastSelected = id
  end

  -- =========================
  -- picking helpers
  -- =========================
  local function pickNodeAt(x,y, proj)
    local best = nil
    local bestD = 1e18
    for _,id in ipairs(order) do
      local p = proj and proj[id]
      if p then
        local pr = math.max(6, p.r)
        local d = dist2(x,y, p.x,p.y)
        local pickR = pr + 6
        if d <= pickR*pickR and d < bestD then
          best = id
          bestD = d
        end
      end
    end
    return best
  end

  local function isCursorOverSelected(mx, my, proj)
    for _,id in ipairs(selectedList) do
      local p = proj[id]
      if p then
        local pr = math.max(6, p.r)
        local pickR = pr + 6
        if dist2(mx,my, p.x,p.y) <= pickR*pickR then
          return true
        end
      end
    end
    return false
  end

  -- =========================
  -- modes
  -- =========================
  local modeAdd = false
  local mirror_mods = false
  local limit_range = false

  local function setMode(addOn, dlg)
    modeAdd = (addOn == true)
    if dlg then
      dlg:modify{ id="mode_add", selected=modeAdd }
    end
  end

  -- =========================
  -- mirror move (mirrored subtree)
  -- =========================
  local function applyMirrorMoveFromWorld(id)
    local n = nodes[id]
    if not n or not mirror_mods then return end
    local mid = n.mirror
    if not mid or not nodes[mid] then return end
    local mn = nodes[mid]

    computeWorldFromActiveLocals()
    buildChildren()

    local prx, pry
    if n.parent and nodes[n.parent] then
      prx, pry = nodes[n.parent].worldx, nodes[n.parent].worldy
    else
      prx, pry = cx, cy
    end

    local vx = n.worldx - prx
    local vy = n.worldy - pry

    local mprx, mpry
    if mn.parent and nodes[mn.parent] then
      mprx, mpry = nodes[mn.parent].worldx, nodes[mn.parent].worldy
    else
      mprx, mpry = cx, cy
    end

    local target_wx = mprx + (-vx)
    local target_wy = mpry + ( vy)
    target_wx, target_wy = clampToPad(target_wx, target_wy)

    local dx = target_wx - (mn.worldx or 0)
    local dy = target_wy - (mn.worldy or 0)
    if dx == 0 and dy == 0 then return end

    local mids = {}
    forEachDescendant(mid, function(cid) mids[#mids+1] = cid end)

    for _,cid in ipairs(mids) do
      local nn = nodes[cid]
      if nn then
        local wx = (nn.worldx or 0) + dx
        local wy = (nn.worldy or 0) + dy
        wx, wy = clampToPad(wx, wy)
        nn.worldx, nn.worldy = wx, wy
      end
    end

    computeActiveLocalsFromWorld()
    computeWorldFromActiveLocals()

    if statePose then
      markPosePosSetSubtree(mid)
    end
  end

  -- =========================
  -- drag state
  -- =========================
  local depth_pref_sign = 1
  local depth_pref_set = false

  local drag = {
    active=false,
    id=nil,
    grabDx=0, grabDy=0,
    baseScreen=nil,
    subtreeIds=nil,
    baseWorld=nil,
    ropeComponentIds=nil,
    ropeBaseWorld=nil,

    baseLocalZ=0,
    baseRootCamZ=0,
    baseRootZpix=0,
    baseEffZ=nil,
    baseSubtreeZpix=nil,

    mmb=false,
    mmb_lastY=0,

    depthSign=0,
    right=false,
    startMx=0,
    startMy=0,
    moved=false,
  }

  local function beginDrag(id, mx, my, proj, isRightDrag)
    local n = nodes[id]
    if not n then return end

    computeWorldFromActiveLocals()
    buildChildren()

    local ids = {}
    forEachDescendant(id, function(cid) ids[#ids+1] = cid end)

    local base = {}
    for _,cid in ipairs(ids) do
      local nn = nodes[cid]
      if nn then base[cid] = { x = nn.worldx, y = nn.worldy } end
    end

    local p = proj and proj[id]
    local sx, sy = n.worldx, n.worldy
    local camZ = cam_dist
    if p then
      sx, sy = p.x, p.y
      camZ = p.camZ or cam_dist
    end

    drag.active = true
    drag.id = id
    drag.grabDx = sx - mx
    drag.grabDy = sy - my
    drag.baseScreen = { x = sx, y = sy }
    drag.subtreeIds = ids
    drag.baseWorld = base
    drag.baseLocalZ = getLocalZ(n)
    drag.baseRootCamZ = camZ
    drag.baseRootZpix = (p and p.zpix) or 0
    drag.baseEffZ = nil
    drag.baseSubtreeZpix = nil
    drag.ropeComponentIds = nil
    drag.ropeBaseWorld = nil

    if isRightDrag and (not view3d) then
      local comp, seen = {}, {}
      local q, qi = { id }, 1
      seen[id] = true
      while qi <= #q do
        local cur = q[qi]
        qi = qi + 1
        comp[#comp+1] = cur
        local cn = nodes[cur]
        if cn then
          local pid = cn.parent
          if pid and nodes[pid] and not seen[pid] then seen[pid] = true; q[#q+1] = pid end
          for _,cid in ipairs(cn.children or {}) do
            if nodes[cid] and not seen[cid] then seen[cid] = true; q[#q+1] = cid end
          end
        end
      end

      local compBase = {}
      for _,cid in ipairs(comp) do
        local nn = nodes[cid]
        if nn then compBase[cid] = { x = nn.worldx or 0, y = nn.worldy or 0 } end
      end
      drag.ropeComponentIds = comp
      drag.ropeBaseWorld = compBase
    end

    if statePose and view3d then
      local eff = buildEffectiveZMap()
      local subtreeZpix = {}
      for _,cid in ipairs(ids) do
        local pp = proj and proj[cid]
        subtreeZpix[cid] = (pp and pp.zpix) or 0
      end
      drag.baseEffZ = eff
      drag.baseSubtreeZpix = subtreeZpix
    end
    if view3d then
      drag.depthSign = (depth_pref_set and depth_pref_sign or 1)
    else
      local ns = (nodes[id] and tonumber(nodes[id].prox_sign_2d)) or 1
      drag.depthSign = (ns >= 0) and 1 or -1
    end
    drag.right = (isRightDrag == true)
    drag.startMx = mx
    drag.startMy = my
    drag.moved = false
  end

  local function endDrag()
    drag.active = false
    drag.id = nil
    drag.grabDx = 0
    drag.grabDy = 0
    drag.baseScreen = nil
    drag.subtreeIds = nil
    drag.baseWorld = nil
    drag.ropeComponentIds = nil
    drag.ropeBaseWorld = nil
    drag.baseLocalZ = 0
    drag.baseRootCamZ = 0
    drag.baseRootZpix = 0
    drag.baseEffZ = nil
    drag.baseSubtreeZpix = nil
    drag.mmb = false
    drag.depthSign = 0
    drag.right = false
    drag.startMx = 0
    drag.startMy = 0
    drag.moved = false
  end

  local function applySubtreePoseZ3DFromRootZpix(desiredRootZpix, liveEffZ)
    if not (statePose and view3d and drag.active and drag.id and desiredRootZpix ~= nil) then return end

    local ids = drag.subtreeIds
    if not ids or #ids == 0 then return end

    local baseEff = drag.baseEffZ
    local baseSubtreeZpix = drag.baseSubtreeZpix
    if not baseEff or not baseSubtreeZpix then return end

    local baseRootZpix = tonumber(drag.baseRootZpix) or 0
    local deltaRootZpix = desiredRootZpix - baseRootZpix
    local newEff = {}

    for _,cid in ipairs(ids) do
      local nn = nodes[cid]
      if nn then
        local base = clamp(tonumber(nn.rest_r) or 14, R_MIN, R_MAX)
        local baseNodeZpix = tonumber(baseSubtreeZpix[cid]) or 0
        local desiredNodeZpix = baseNodeZpix + deltaRootZpix

        local desiredEff = 0
        if math.abs(base) > 1e-9 then
          desiredEff = (desiredNodeZpix / base) * 100.0
        end

        local pid = nn.parent
        local parentEff = 0
        if pid then
          if newEff[pid] ~= nil then
            parentEff = newEff[pid]
          elseif liveEffZ and liveEffZ[pid] ~= nil then
            parentEff = tonumber(liveEffZ[pid]) or 0
          elseif baseEff[pid] ~= nil then
            parentEff = tonumber(baseEff[pid]) or 0
          end
        end

        local localZ = desiredEff - parentEff
        nn.pose_z3d = localZ
        newEff[cid] = parentEff + localZ
      end
    end
  end

  -- =========================
  -- Z / radius edits (MMB over selected)
  -- =========================
  -- CHANGE: radius edits NEVER affect children (rest or pose). Z edits also only affect that vert.
  local function applyRadiusRestSingle(id, delta)
    local n = nodes[id]
    if not n then return end
    n.rest_r = clamp((tonumber(n.rest_r) or 14) + delta, 3, 200)
  end

  local function applyPoseZSingle(id, deltaZ)
    local n = nodes[id]
    if not n then return end
    local cur = getLocalZ(n)
    if view3d then
      setLocalZ(n, cur + deltaZ)
    else
      setLocalZ(n, clamp(cur + deltaZ, -400, 400))
    end
  end

  local function applyRadiusOrZWithMirror(id, delta)
    if not id or not nodes[id] then return end
    if stateRest then
      applyRadiusRestSingle(id, delta)
      if mirror_mods then
        local m = nodes[id].mirror
        if m and nodes[m] then applyRadiusRestSingle(m, delta) end
      end
    else
      applyPoseZSingle(id, delta)
      if mirror_mods then
        local m = nodes[id].mirror
        if m and nodes[m] then applyPoseZSingle(m, delta) end
      end
    end
  end

  -- =========================
  -- init / reset
  -- =========================
  local function resetToSingleCenterNode()
    setState(true, false, nil)

    nodes = {}
    order = {}
    roots = {}
    links = {}
    clearSelection()
    nextId = 1

    local id = addNode(nil, 14)
    local n = nodes[id]

    n.rest_localx, n.rest_localy = cx, cy
    n.pose_localx, n.pose_localy = cx, cy
    n.pose_z2d = 0
    n.pose_z3d = 0
    n.worldx, n.worldy = cx, cy
    n.pose_pos_set = false
    n.prox_sign_2d = 1

    buildChildren()
    computeWorldFromActiveLocals()
    setSingleSelection(id)

    resetViewToFront()
  end

  -- =========================
  -- operations
  -- =========================
  local function isDescendant(childId, ancestorId)
    local cur = nodes[childId]
    while cur and cur.parent do
      if cur.parent == ancestorId then return true end
      cur = nodes[cur.parent]
    end
    return false
  end

  local function createChildAndDrag(parentId, mx, my)
    if not parentId or not nodes[parentId] then return nil end
    computeWorldFromActiveLocals()
    buildChildren()

    local p = nodes[parentId]
    local wx, wy = clampToPad(mx, my)

    local childId = addNode(parentId, p.rest_r)
    local c = nodes[childId]

    local prx, pry = p.worldx, p.worldy
    setActiveLocal(c, wx - prx, wy - pry)

    if stateRest then
      c.pose_localx, c.pose_localy = c.rest_localx, c.rest_localy
      c.pose_pos_set = false
    else
      c.rest_localx, c.rest_localy = c.pose_localx, c.pose_localy
      c.pose_pos_set = true
    end

    c.pose_z2d = 0
    c.pose_z3d = 0

    buildChildren()
    computeWorldFromActiveLocals()

    setSingleSelection(childId)
    return childId
  end

  local function doParent()
    if selectionCount() < 2 then return end
    local parentId = lastSelected
    if not parentId or not nodes[parentId] then return end

    for i=1,#selectedList do
      local id = selectedList[i]
      if id ~= parentId and nodes[id] then
        if not isDescendant(parentId, id) then
          nodes[id].parent = parentId

          if mirror_mods then
            local c = nodes[id]
            local p = nodes[parentId]
            if c and p and c.mirror and p.mirror and nodes[c.mirror] and nodes[p.mirror] then
              if not isDescendant(p.mirror, c.mirror) then
                nodes[c.mirror].parent = p.mirror
              end
            end
          end
        end
      end
    end

    buildChildren()
    computeWorldFromActiveLocals()
    computeActiveLocalsFromWorld()
    computeWorldFromActiveLocals()
  end

  local function collectSubtreeIds(rootId, out)
    buildChildren()
    forEachDescendant(rootId, function(id) out[#out+1] = id end)
  end

  local function mirrorSubtreeRest(rootId)
    if not rootId or not nodes[rootId] then return end

    computeWorldFromActiveLocals()
    buildChildren()

    local srcIds = {}
    collectSubtreeIds(rootId, srcIds)

    local map = {}
    for _,sid in ipairs(srcIds) do map[sid] = newId() end

    local function mirroredParentFor(origParentId)
      if not origParentId or not nodes[origParentId] then return nil end
      local pm = nodes[origParentId].mirror
      if pm and nodes[pm] then return pm end
      return origParentId
    end

    for _,sid in ipairs(srcIds) do
      local s = nodes[sid]
      local nid = map[sid]
      local parentNew = nil
      if s.parent and map[s.parent] then
        parentNew = map[s.parent]
      else
        parentNew = mirroredParentFor(s.parent)
      end
      addNodeWithId(nid, parentNew, s.rest_r)

      nodes[nid].pose_z2d = s.pose_z2d or 0
      nodes[nid].pose_z3d = s.pose_z3d or 0
      nodes[nid].pose_pos_set = (s.pose_pos_set == true)
      nodes[nid].prox_sign_2d = ((tonumber(s.prox_sign_2d) or 1) >= 0) and 1 or -1
    end

    local desiredW = {}
    for _,sid in ipairs(srcIds) do
      local s = nodes[sid]
      local nid = map[sid]
      local mwx = (2*cx) - s.worldx
      local mwy = s.worldy
      mwx, mwy = clampToPad(mwx, mwy)
      desiredW[nid] = {x=mwx, y=mwy}
    end

    local function parentDesiredWorld(newId0)
      local n = nodes[newId0]
      if not n or not n.parent then return nil end
      local p = nodes[n.parent]
      if not p then return nil end
      if desiredW[n.parent] then
        return desiredW[n.parent].x, desiredW[n.parent].y
      end
      return p.worldx, p.worldy
    end

    for _,sid in ipairs(srcIds) do
      local nid = map[sid]
      local nn = nodes[nid]
      local dw = desiredW[nid]
      if nn.parent and nodes[nn.parent] then
        local pwx, pwy = parentDesiredWorld(nid)
        if pwx then
          nn.rest_localx = dw.x - pwx
          nn.rest_localy = dw.y - pwy
        else
          nn.rest_localx = dw.x
          nn.rest_localy = dw.y
        end
      else
        nn.rest_localx = dw.x
        nn.rest_localy = dw.y
      end

      local s = nodes[sid]
      if s then
        local function poseWorldOf(id0)
          local n0 = nodes[id0]
          if not n0 then return 0,0 end
          local lx, ly = n0.pose_localx, n0.pose_localy
          if n0.parent and nodes[n0.parent] then
            local px, py = poseWorldOf(n0.parent)
            return px + lx, py + ly
          end
          return lx, ly
        end

        local swxP, swyP = poseWorldOf(sid)
        local mwxP = (2*cx) - swxP
        local mwyP = swyP
        mwxP, mwyP = clampToPad(mwxP, mwyP)

        if nn.parent and nodes[nn.parent] then
          local function poseWorldOfNew(id0)
            local n0 = nodes[id0]
            if not n0 then return 0,0 end
            local lx, ly = n0.pose_localx, n0.pose_localy
            if n0.parent and nodes[n0.parent] then
              local px, py = poseWorldOfNew(n0.parent)
              return px + lx, py + ly
            end
            return lx, ly
          end
          local ppx, ppy = poseWorldOfNew(nn.parent)
          nn.pose_localx = mwxP - ppx
          nn.pose_localy = mwyP - ppy
        else
          nn.pose_localx = mwxP
          nn.pose_localy = mwyP
        end

        nn.pose_pos_set = (s.pose_pos_set == true)
        if nn.pose_pos_set ~= true then
          nn.pose_localx, nn.pose_localy = nn.rest_localx, nn.rest_localy
        end
      end
    end

    for _,sid in ipairs(srcIds) do
      setMirrorPair(sid, map[sid])
    end

    for k,v in pairs(links) do
      if v == true or v == false then
        local a,b = k:match("^(.-)%|(.-)$")
        if a and b and map[a] and map[b] then
          local nk = pairKey(map[a], map[b])
          if nk then links[nk] = v end
        end
      end
    end

    buildChildren()
    computeWorldFromActiveLocals()
    setSingleSelection(map[rootId])
  end

  local function deleteSelectedButKeepChildren()
    if #order <= 1 then return end
    if selectionCount() < 1 then return end

    local toDelete = {}
    for _,id in ipairs(selectedList) do
      if nodes[id] then toDelete[id] = true end
    end

    local deleteCount = 0
    for _ in pairs(toDelete) do deleteCount = deleteCount + 1 end
    if deleteCount >= #order then
      return
    end

    computeWorldFromActiveLocals()
    buildChildren()

    for id,_ in pairs(toDelete) do
      local n = nodes[id]
      if n then
        clearMirrorFor(id)
        for _,cid in ipairs(n.children) do
          local c = nodes[cid]
          if c then c.parent = nil end
        end
      end
    end

    local newOrder = {}
    for _,id in ipairs(order) do
      if toDelete[id] then
        nodes[id] = nil
      else
        newOrder[#newOrder+1] = id
      end
    end
    order = newOrder

    local newLinks = {}
    for k,v in pairs(links) do
      local a,b = k:match("^(.-)%|(.-)$")
      if a and b and nodes[a] and nodes[b] then
        newLinks[k] = v
      end
    end
    links = newLinks

    buildChildren()
    computeWorldFromActiveLocals()

    clearSelection()
    if #order > 0 then setSingleSelection(order[1]) end
  end

  local function revertSelectedToRest()
    if selectionCount() < 1 then
      if not lastSelected or not nodes[lastSelected] then return end
      setSingleSelection(lastSelected)
    end
    for _,id in ipairs(selectedList) do
      local n = nodes[id]
      if n then
        n.pose_localx = n.rest_localx
        n.pose_localy = n.rest_localy
        n.pose_z2d = 0
        n.pose_z3d = 0
        n.pose_pos_set = false
      end
    end
    buildChildren()
    computeWorldFromActiveLocals()
  end

  local function revertAllToRest()
    for _,id in ipairs(order) do
      local n = nodes[id]
      if n then
        n.pose_localx = n.rest_localx
        n.pose_localy = n.rest_localy
        n.pose_z2d = 0
        n.pose_z3d = 0
        n.pose_pos_set = false
      end
    end
    buildChildren()
    computeWorldFromActiveLocals()
  end

  -- =========================
  -- drawing helpers
  -- =========================
  local function getResBlock()
    -- Keep block size in screen pixels independent from camera/2D zoom.
    local scale = clamp(tonumber(res_scale) or 1.0, 0.1, 1.0)
    return math.max(1, math.floor((1.0 / scale) + 0.5))
  end

  local function drawLineGC_1px(gc, x0, y0, x1, y1)
    local block = getResBlock()
    local function plotLow(lx, ly)
      if block <= 1 then
        gc:fillRect(Rectangle(lx, ly, 1, 1))
        return
      end
      gc:fillRect(Rectangle(lx * block, ly * block, block, block))
    end

    local lx0 = math.floor((x0 / block) + 0.5)
    local ly0 = math.floor((y0 / block) + 0.5)
    local lx1 = math.floor((x1 / block) + 0.5)
    local ly1 = math.floor((y1 / block) + 0.5)

    local dx = math.abs(lx1 - lx0)
    local sx = (lx0 < lx1) and 1 or -1
    local dy = -math.abs(ly1 - ly0)
    local sy = (ly0 < ly1) and 1 or -1
    local err = dx + dy
    while true do
      plotLow(lx0, ly0)
      if lx0 == lx1 and ly0 == ly1 then break end
      local e2 = 2 * err
      if e2 >= dy then err = err + dy; lx0 = lx0 + sx end
      if e2 <= dx then err = err + dx; ly0 = ly0 + sy end
    end
  end

  local function clipLineToRect(x0,y0,x1,y1, xmin,ymin,xmax,ymax)
    local INSIDE, LEFT, RIGHT, BOTTOM, TOP = 0, 1, 2, 4, 8
    local function outcode(x,y)
      local c = INSIDE
      if x < xmin then c = c + LEFT elseif x > xmax then c = c + RIGHT end
      if y < ymin then c = c + TOP  elseif y > ymax then c = c + BOTTOM end
      return c
    end

    local c0 = outcode(x0,y0)
    local c1 = outcode(x1,y1)

    while true do
      if (c0 + c1) == 0 then return true, x0,y0,x1,y1 end
      if (c0 & c1) ~= 0 then return false end

      local cx0 = (c0 ~= 0) and c0 or c1
      local x, y

      if (cx0 & TOP) ~= 0 then
        local t = (ymin - y0) / (y1 - y0)
        x = x0 + (x1 - x0) * t; y = ymin
      elseif (cx0 & BOTTOM) ~= 0 then
        local t = (ymax - y0) / (y1 - y0)
        x = x0 + (x1 - x0) * t; y = ymax
      elseif (cx0 & RIGHT) ~= 0 then
        local t = (xmax - x0) / (x1 - x0)
        x = xmax; y = y0 + (y1 - y0) * t
      else
        local t = (xmin - x0) / (x1 - x0)
        x = xmin; y = y0 + (y1 - y0) * t
      end

      if cx0 == c0 then x0, y0 = x, y; c0 = outcode(x0,y0)
      else x1, y1 = x, y; c1 = outcode(x1,y1) end
    end
  end

  local function drawLineClipped(gc, x0,y0,x1,y1)
    local ok, ax,ay,bx,by = clipLineToRect(x0,y0,x1,y1, 0,0, PAD_W-1, PAD_H-1)
    if not ok then return end
    drawLineGC_1px(gc, ax,ay,bx,by)
  end

  local function drawCirclePolyline(gc, cx0, cy0, r, segments)
    if r < 1 then return end
    local block = getResBlock()
    local lr = math.floor((r / block) + 0.5)
    if lr < 1 then lr = 1 end
    local lcx = math.floor((cx0 / block) + 0.5)
    local lcy = math.floor((cy0 / block) + 0.5)

    local function plotLow(px, py)
      if block <= 1 then
        gc:fillRect(Rectangle(px, py, 1, 1))
      else
        gc:fillRect(Rectangle(px * block, py * block, block, block))
      end
    end

    local x = lr
    local y = 0
    local d = 1 - lr
    while x >= y do
      plotLow(lcx + x, lcy + y)
      plotLow(lcx + y, lcy + x)
      plotLow(lcx - y, lcy + x)
      plotLow(lcx - x, lcy + y)
      plotLow(lcx - x, lcy - y)
      plotLow(lcx - y, lcy - x)
      plotLow(lcx + y, lcy - x)
      plotLow(lcx + x, lcy - y)
      y = y + 1
      if d <= 0 then
        d = d + 2 * y + 1
      else
        x = x - 1
        d = d + 2 * (y - x) + 1
      end
    end
  end

  local function drawPixelStrong(img, x, y, pix)
    if not pix then return end
    if x < 0 or y < 0 or x >= img.width or y >= img.height then return end
    local newA = app.pixelColor.rgbaA(pix)
    if newA <= 0 then return end
    local cur = img:getPixel(x, y)
    local curA = app.pixelColor.rgbaA(cur)
    if curA >= newA then return end
    img:drawPixel(x, y, pix)
  end

  local function drawLineSet(img, x0, y0, x1, y1, pix)
    if not pix then return end
    local block = getResBlock()
    local function plotLow(lx, ly)
      if block <= 1 then
        drawPixelStrong(img, lx, ly, pix)
        return
      end
      local gx = lx * block
      local gy = ly * block
      for oy=0,block-1 do
        for ox=0,block-1 do
          drawPixelStrong(img, gx + ox, gy + oy, pix)
        end
      end
    end

    local lx0 = math.floor((x0 / block) + 0.5)
    local ly0 = math.floor((y0 / block) + 0.5)
    local lx1 = math.floor((x1 / block) + 0.5)
    local ly1 = math.floor((y1 / block) + 0.5)

    local dx = math.abs(lx1 - lx0)
    local sx = (lx0 < lx1) and 1 or -1
    local dy = -math.abs(ly1 - ly0)
    local sy = (ly0 < ly1) and 1 or -1
    local err = dx + dy
    while true do
      plotLow(lx0, ly0)
      if lx0 == lx1 and ly0 == ly1 then break end
      local e2 = 2 * err
      if e2 >= dy then err = err + dy; lx0 = lx0 + sx end
      if e2 <= dx then err = err + dx; ly0 = ly0 + sy end
    end
  end

  local function drawCirclePolylineToImage(img, cx0, cy0, r, segments, pix)
    if r < 1 then return end
    local block = getResBlock()
    local lr = math.floor((r / block) + 0.5)
    if lr < 1 then lr = 1 end
    local lcx = math.floor((cx0 / block) + 0.5)
    local lcy = math.floor((cy0 / block) + 0.5)

    local function plotLow(px, py)
      if block <= 1 then
        drawPixelStrong(img, px, py, pix)
        return
      end
      local gx = px * block
      local gy = py * block
      for oy=0,block-1 do
        for ox=0,block-1 do
          drawPixelStrong(img, gx + ox, gy + oy, pix)
        end
      end
    end

    local x = lr
    local y = 0
    local d = 1 - lr
    while x >= y do
      plotLow(lcx + x, lcy + y)
      plotLow(lcx + y, lcy + x)
      plotLow(lcx - y, lcy + x)
      plotLow(lcx - x, lcy + y)
      plotLow(lcx - x, lcy - y)
      plotLow(lcx - y, lcy - x)
      plotLow(lcx + y, lcy - x)
      plotLow(lcx + x, lcy - y)
      y = y + 1
      if d <= 0 then
        d = d + 2 * y + 1
      else
        x = x - 1
        d = d + 2 * (y - x) + 1
      end
    end
  end

  local function renderVertsAndCirclesToImage()
    computeWorldFromActiveLocals()
    local effZ = statePose and buildEffectiveZMap() or nil
    local proj = buildProjectedMap(effZ)
    local projRaster = buildRasterProjectedMap(effZ, proj)
    local alphaMap = buildAlphaMap(proj)

    local img = Image(spr.width, spr.height, spr.colorMode)
    img:clear()

    for k,v in pairs(links) do
      if v == true then
        local a,b = k:match("^(.-)%|(.-)$")
        local pa, pb = projRaster[a], projRaster[b]
        if pa and pb then
          local aa = math.min(alphaMap[a] or 255, alphaMap[b] or 255)
          local pix = app.pixelColor.rgba(0, 0, 0, aa)
          drawLineSet(img, pa.x, pa.y, pb.x, pb.y, pix)
        end
      end
    end

    for _,id in ipairs(order) do
      local n = nodes[id]
      if n and n.parent and nodes[n.parent] then
        if getLinkState(id, n.parent) then
          local pa = projRaster[n.parent]
          local pb = projRaster[id]
          if pa and pb then
            local aa = math.min(alphaMap[n.parent] or 255, alphaMap[id] or 255)
            local pix = app.pixelColor.rgba(0, 0, 0, aa)
            drawLineSet(img, pa.x, pa.y, pb.x, pb.y, pix)
          end
        end
      end
    end

    for _,id in ipairs(order) do
      local p = projRaster[id]
      local pdot = proj[id]
      if p and pdot then
        local isSel = (selected[id] == true)
        local aa = alphaMap[id] or 255
        local r, g, b = 0, 0, 0
        if isSel then r, g, b, aa = 60, 220, 60, 255 end
        local pix = app.pixelColor.rgba(r, g, b, aa)

        local showSphere = (display_spheres == true) and (nodes[id] and nodes[id].sphere ~= false)
        if showSphere then
          drawCirclePolylineToImage(img, p.x, p.y, p.r, 52, pix)
        end

        local px = math.floor(pdot.x + 0.5)
        local py = math.floor(pdot.y + 0.5)
        drawPixelStrong(img, px, py, pix)
      end
    end

    return img
  end

  local function updateLivePreviewLayer()
    if not live_preview then
      app.transaction(function() deletePreviewLayer() end)
      return
    end
    local fr = app.activeFrame
    if not fr then return end
    local img = renderVertsAndCirclesToImage()
    app.transaction(function()
      local lyr = ensureLayer(PREVIEW_NAME)
      replaceCel(lyr, fr, img, Point(0, 0))
    end)
  end

  local function drawDoubleCircleLink(gc, ax, ay, bx, by, ra, rb)
    local r1 = math.max(0, ra)
    local r2 = math.max(0, rb)

    local dx = bx - ax
    local dy = by - ay
    local d2 = dx*dx + dy*dy
    if d2 < 1e-9 then return end
    local d = math.sqrt(d2)

    local dr = (r1 - r2)
    if d <= math.abs(dr) + 1e-6 then return end

    local base = math.atan(dy, dx)
    local c = clamp(dr / d, -1.0, 1.0)
    local off = math.acos(c)

    local function side(sign)
      local th = base + sign * off
      local ux = math.cos(th)
      local uy = math.sin(th)
      local x1 = ax + ux * r1
      local y1 = ay + uy * r1
      local x2 = bx + ux * r2
      local y2 = by + uy * r2
      drawLineClipped(gc, x1, y1, x2, y2)
    end

    side( 1)
    side(-1)
  end

  -- =========================
  -- 3D grid (FLOOR XZ at bottom)
  -- =========================
  local GRID_STEP = 20
  local GRID_HALF_STEPS = 6

  local function project3DPoint(wx, wy, wz)
    local f = focalFromFov()
    local epsZ = 0.001

    local vec = { x=wx - cx + pan.x, y=wy - cy + pan.y, z=wz + pan.z }

    local camX = vdot(vec, camR)
    local camY = vdot(vec, camU)
    local camZ = vdot(vec, camF) + cam_dist
    if camZ < epsZ then camZ = epsZ end

    local sx = cx + (camX * f / camZ)
    local sy = cy + (camY * f / camZ)
    return sx, sy
  end

  local function draw3DFloorGrid(gc)
    if not view3d then return end

    local floorY = PAD_H - margin
    local yoff = floorY

    gc.color = Color{r=120,g=120,b=120,a=80}

    local half = GRID_HALF_STEPS * GRID_STEP

    for xi=-GRID_HALF_STEPS, GRID_HALF_STEPS do
      local xw = cx + xi * GRID_STEP
      local x0,y0 = project3DPoint(xw, yoff, -half)
      local x1,y1 = project3DPoint(xw, yoff,  half)
      drawLineClipped(gc, x0,y0, x1,y1)
    end

    for zi=-GRID_HALF_STEPS, GRID_HALF_STEPS do
      local zw = zi * GRID_STEP
      local x0,y0 = project3DPoint(cx - half, yoff, zw)
      local x1,y1 = project3DPoint(cx + half, yoff, zw)
      drawLineClipped(gc, x0,y0, x1,y1)
    end
  end

  -- =========================
  -- UI: link checkbox sync
  -- =========================
  local function updateLinkUI(dlg)
    if not dlg then return end
    if #selectedList == 2 then
      local a = selectedList[1]
      local b = selectedList[2]
      dlg:modify{ id="link_pair", enabled=true, selected=getLinkState(a,b) }
    else
      dlg:modify{ id="link_pair", enabled=false, selected=false }
    end
  end

  local function updateSphereUI(dlg)
    if not dlg then return end
    if lastSelected and nodes[lastSelected] then
      dlg:modify{ id="sphere_vert", enabled=true, selected=(nodes[lastSelected].sphere ~= false) }
    else
      dlg:modify{ id="sphere_vert", enabled=false, selected=false }
    end
  end

  local function normalizeAlphaMode()
    if order_alpha and depth_alpha then
      depth_alpha = false
    end
  end

  -- =========================
  -- save/load
  -- =========================
  local CURRENT_FILE = "default.txt"

  local function selectedFileSafe()
    return fileSafe(CURRENT_FILE)
  end

  local function rebuildNextIdFromIds()
    local maxN = 0
    for _,id in ipairs(order) do
      local n = tonumber(id)
      if n and n > maxN then maxN = n end
    end
    nextId = maxN + 1
    if nextId < 1 then nextId = 1 end
  end

  local function saveGraph()
    local filename = selectedFileSafe()
    local path = presetPathForSelected(filename)

    buildChildren()

    local data = {}
    data["version"] = 9
    data["node_count"] = #order
    data["mirror_mods"] = (mirror_mods == true)
    data["limit_range"] = (limit_range == true)

    data["mode_add"] = (modeAdd == true)
    data["state_rest"] = (stateRest == true)
    data["state_pose"] = (statePose == true)

    data["view_3d"] = (view3d == true)
    data["display_spheres"] = (display_spheres == true)
    data["live"] = (live_preview == true)
    data["order_alpha"] = (order_alpha == true)
    data["depth_alpha"] = (depth_alpha == true)

    data["cam_yaw"] = yaw
    data["cam_pitch"] = pitch
    data["cam_fov"] = fov_deg
    data["fov_2d"] = fov_2d
    data["res_scale"] = res_scale
    data["cam_dist"] = cam_dist
    data["cam_pan_x"] = pan.x
    data["cam_pan_y"] = pan.y
    data["cam_pan_z"] = pan.z

    data["view2d_zoom"] = view2d.zoom
    data["view2d_panx"] = view2d.panx
    data["view2d_pany"] = view2d.pany

    data["depth_pref_sign"] = depth_pref_sign
    data["depth_pref_set"] = (depth_pref_set == true)

    for i,id in ipairs(order) do
      local n = nodes[id]
      data["node_"..i.."_id"] = id
      data["node_"..i.."_parent"] = n.parent or ""

      data["node_"..i.."_rest_lx"] = n.rest_localx or 0
      data["node_"..i.."_rest_ly"] = n.rest_localy or 0

      if n.pose_pos_set == true then
        data["node_"..i.."_pose_lx"] = n.pose_localx or n.rest_localx or 0
        data["node_"..i.."_pose_ly"] = n.pose_localy or n.rest_localy or 0
      else
        data["node_"..i.."_pose_lx"] = ""
        data["node_"..i.."_pose_ly"] = ""
      end

      data["node_"..i.."_rest_r"] = n.rest_r or 14
      data["node_"..i.."_pose_z2d"] = n.pose_z2d or 0
      data["node_"..i.."_pose_z3d"] = n.pose_z3d or 0
      data["node_"..i.."_mirror"] = n.mirror or ""
      data["node_"..i.."_sphere"] = (n.sphere ~= false)
      data["node_"..i.."_pinned"] = (n.pinned == true)
      data["node_"..i.."_prox_sign_2d"] = ((tonumber(n.prox_sign_2d) or 1) >= 0) and 1 or -1
    end

    local linkKeys = {}
    for k,_ in pairs(links) do linkKeys[#linkKeys+1] = k end
    table.sort(linkKeys, function(a,b) return tostring(a) < tostring(b) end)
    data["link_count"] = #linkKeys
    for i,k in ipairs(linkKeys) do
      data["link_"..i.."_key"] = k
      local v = links[k]
      if v == true then data["link_"..i.."_val"] = 1
      elseif v == false then data["link_"..i.."_val"] = 0
      else data["link_"..i.."_val"] = "" end
    end

    local ok, err = saveKeyValueFile(path, data)
    if not ok then app.alert(err or "Save failed.") end
  end

  local function loadGraph()
    local filename = selectedFileSafe()
    local path = presetPathForSelected(filename)
    if not app.fs.isFile(path) then return app.alert("File not found: " .. tostring(filename)) end

    local t, err = loadKeyValueFile(path)
    if err then return app.alert(err) end

    nodes = {}
    order = {}
    roots = {}
    links = {}
    clearSelection()
    nextId = 1

    mirror_mods = (t.mirror_mods == true)
    limit_range = (t.limit_range == true)

    local legacyModeMove = (t.mode_move ~= false)
    modeAdd = (t.mode_add == true)
    if not legacyModeMove then modeAdd = true end

    stateRest = (t.state_rest == true)
    statePose = (t.state_pose == true)
    if stateRest and statePose then statePose = false end
    if not stateRest and not statePose then stateRest = true end

    view3d = (t.view_3d == true)
    display_spheres = (t.display_spheres ~= false)
    live_preview = (t.live == true)
    order_alpha = (t.order_alpha == true)
    depth_alpha = (t.depth_alpha == true)
    normalizeAlphaMode()

    yaw = tonumber(t.cam_yaw) or 0.0
    pitch = clamp(tonumber(t.cam_pitch) or 0.0, -PITCH_MAX, PITCH_MAX)
    fov_deg = clamp(tonumber(t.cam_fov) or 60, 15, 140)
    fov_2d = clamp(tonumber(t.fov_2d) or 60, 15, 140)
    res_scale = clamp(tonumber(t.res_scale) or 1.0, 0.1, 1.0)
    cam_dist = clamp(tonumber(t.cam_dist) or 420.0, CAM_DIST_MIN, CAM_DIST_MAX)
    pan.x = tonumber(t.cam_pan_x) or 0.0
    pan.y = tonumber(t.cam_pan_y) or 0.0
    pan.z = tonumber(t.cam_pan_z) or 0.0
    camRebuild()

    view2d.zoom = clamp(tonumber(t.view2d_zoom) or 1.0, 0.05, 40.0)
    view2d.panx = tonumber(t.view2d_panx) or 0.0
    view2d.pany = tonumber(t.view2d_pany) or 0.0

    depth_pref_sign = tonumber(t.depth_pref_sign) or 1
    if depth_pref_sign >= 0 then depth_pref_sign = 1 else depth_pref_sign = -1 end
    depth_pref_set = (t.depth_pref_set == true)

    local ncount = tonumber(t.node_count) or 0
    for i=1,ncount do
      local id = tostring(t["node_"..i.."_id"] or "")
      if id ~= "" then
        local parent = tostring(t["node_"..i.."_parent"] or "")
        if parent == "" then parent = nil end

        addNodeWithId(id, parent, tonumber(t["node_"..i.."_rest_r"]) or 14)

        local n = nodes[id]
        n.rest_localx = tonumber(t["node_"..i.."_rest_lx"]) or 0
        n.rest_localy = tonumber(t["node_"..i.."_rest_ly"]) or 0

        local plx = t["node_"..i.."_pose_lx"]
        local ply = t["node_"..i.."_pose_ly"]
        local hasPosePos = true
        if plx == nil or ply == nil then
          hasPosePos = false
        else
          if tostring(plx) == "" or tostring(ply) == "" then
            hasPosePos = false
          end
        end

        if not hasPosePos then
          n.pose_localx, n.pose_localy = n.rest_localx, n.rest_localy
          n.pose_pos_set = false
        else
          n.pose_localx = tonumber(plx) or n.rest_localx
          n.pose_localy = tonumber(ply) or n.rest_localy
          n.pose_pos_set = true
        end

        n.rest_r = clamp(tonumber(t["node_"..i.."_rest_r"]) or 14, R_MIN, R_MAX)

        local legacy = t["node_"..i.."_pose_z"]
        local z2d = t["node_"..i.."_pose_z2d"]
        local z3d = t["node_"..i.."_pose_z3d"]

        if z2d == nil and z3d == nil and legacy ~= nil then
          local lz = tonumber(legacy) or 0
          n.pose_z2d = lz
          n.pose_z3d = lz
        else
          n.pose_z2d = tonumber(z2d) or 0
          n.pose_z3d = tonumber(z3d) or 0
        end

        n.sphere = (t["node_"..i.."_sphere"] ~= false)
        n.pinned = (t["node_"..i.."_pinned"] == true)
        local ps2d = tonumber(t["node_"..i.."_prox_sign_2d"])
        if ps2d == nil then ps2d = 1 end
        n.prox_sign_2d = (ps2d >= 0) and 1 or -1
      end
    end

    for i=1,ncount do
      local id = tostring(t["node_"..i.."_id"] or "")
      if id ~= "" and nodes[id] then
        local m = tostring(t["node_"..i.."_mirror"] or "")
        if m ~= "" and nodes[m] then
          setMirrorPair(id, m)
        end
      end
    end

    local lcount = tonumber(t.link_count) or 0
    for i=1,lcount do
      local k = tostring(t["link_"..i.."_key"] or "")
      local v = t["link_"..i.."_val"]
      if k ~= "" then
        if v == 1 or v == true or v == "1" then links[k] = true
        elseif v == 0 or v == false or v == "0" then links[k] = false end
      end
    end

    buildChildren()
    rebuildNextIdFromIds()
    if #order == 0 then
      resetToSingleCenterNode()
    else
      if statePose then ensurePoseDefaultsFromRest() end
      computeWorldFromActiveLocals()
      setSingleSelection(order[1])
    end
  end

  -- =========================
  -- range helpers (limit range)
  -- =========================
  computeRestWorldPositions = function()
    buildChildren()
    local w = {}
    local function rec(id, px, py)
      local n = nodes[id]
      if not n then return end
      local lx, ly = n.rest_localx, n.rest_localy
      local wx, wy
      if n.parent and nodes[n.parent] then
        wx = px + lx
        wy = py + ly
      else
        wx = lx
        wy = ly
      end
      w[id] = {x=wx, y=wy}
      for _,cid in ipairs(n.children) do
        rec(cid, wx, wy)
      end
    end
    for _,rid in ipairs(roots) do rec(rid, 0, 0) end
    return w
  end

  restRangeToParent = function(id, restWorld)
    local n = nodes[id]
    if not n or not n.parent or not nodes[n.parent] then return nil end
    local c = restWorld[id]
    local p = restWorld[n.parent]
    if not c or not p then return nil end
    local dx = c.x - p.x
    local dy = c.y - p.y
    return math.sqrt(dx*dx + dy*dy)
  end

  local function listComponentNodesFrom(startId)
    if not (startId and nodes[startId]) then return {} end
    buildChildren()

    local out, seen = {}, {}
    local q, qi = { startId }, 1
    seen[startId] = true

    while qi <= #q do
      local id = q[qi]
      qi = qi + 1
      out[#out+1] = id

      local n = nodes[id]
      if n then
        local pid = n.parent
        if pid and nodes[pid] and not seen[pid] then
          seen[pid] = true
          q[#q+1] = pid
        end
        for _,cid in ipairs(n.children or {}) do
          if nodes[cid] and not seen[cid] then
            seen[cid] = true
            q[#q+1] = cid
          end
        end
      end
    end

    return out
  end

  local function applyRightDragRopeIK(dragId, targetX, targetY)
    if not (dragId and nodes[dragId] and targetX and targetY) then return end

    local restWorld = computeRestWorldPositions()
    local componentIds = drag.ropeComponentIds or listComponentNodesFrom(dragId)
    if #componentIds == 0 then return end

    local edges = {}
    for _,id in ipairs(componentIds) do
      local n = nodes[id]
      if n and n.parent and nodes[n.parent] then
        local maxLen = restRangeToParent(id, restWorld)
        if maxLen and maxLen > 1e-6 then
          edges[#edges+1] = { a = n.parent, b = id, maxLen = maxLen }
        end
      end
    end


    local solverIterations = 30
    local tautness = 0.9
    local holdToStart = 0.045
    local baseHold = drag.ropeBaseWorld

    for _=1,solverIterations do
      local dragged = nodes[dragId]
      if dragged then
        dragged.worldx = targetX
        dragged.worldy = targetY
      end

      for _,e in ipairs(edges) do
        local a = nodes[e.a]
        local b = nodes[e.b]
        if a and b then
          local ax, ay = a.worldx or 0, a.worldy or 0
          local bx, by = b.worldx or 0, b.worldy or 0
          local dx = bx - ax
          local dy = by - ay
          local d2 = dx*dx + dy*dy
          local maxLen2 = e.maxLen * e.maxLen

          if d2 > maxLen2 then
            local d = math.sqrt(d2)
            if d > 1e-9 then
              local excess = (d - e.maxLen) * tautness
              local ux, uy = dx / d, dy / d

              local aLocked = (e.a == dragId) or (a.pinned == true)
              local bLocked = (e.b == dragId) or (b.pinned == true)

              if not aLocked and not bLocked then
                local half = excess * 0.5
                a.worldx = ax + ux * half
                a.worldy = ay + uy * half
                b.worldx = bx - ux * half
                b.worldy = by - uy * half
              elseif aLocked and not bLocked then
                b.worldx = bx - ux * excess
                b.worldy = by - uy * excess
              elseif (not aLocked) and bLocked then
                a.worldx = ax + ux * excess
                a.worldy = ay + uy * excess
              end
            end
          end
        end
      end
      if baseHold then
        for _,cid in ipairs(componentIds) do
          if cid ~= dragId then
            local nn = nodes[cid]
            local bb = baseHold[cid]
            if nn and bb and nn.pinned ~= true then
              nn.worldx = (nn.worldx or 0) + (bb.x - (nn.worldx or 0)) * holdToStart
              nn.worldy = (nn.worldy or 0) + (bb.y - (nn.worldy or 0)) * holdToStart
            end
          end
        end
      end

    end

    local dragged = nodes[dragId]
    if dragged then
      dragged.worldx = targetX
      dragged.worldy = targetY
    end
  end


  build2DProximityOverlapMap = function(restWorld)
    local out = {}
    if not restWorld then return out end

    buildChildren()

    local function rec(id, parentEffective)
      local n = nodes[id]
      if not n then return end

      local ownOverlap = 0.0
      if n.parent and nodes[n.parent] then
        local parentN = nodes[n.parent]
        local R = restRangeToParent(id, restWorld)
        if parentN and R and R > 1e-9 then
          local dxp = (n.worldx or 0) - (parentN.worldx or 0)
          local dyp = (n.worldy or 0) - (parentN.worldy or 0)
          local d = math.sqrt(dxp*dxp + dyp*dyp)
          ownOverlap = clamp(1.0 - (d / R), 0.0, 1.0)
        end
      end

      local pe = math.max(0.0, tonumber(parentEffective) or 0.0)
      -- Parent overlap should amplify child overlap without being hard-clamped
      -- to [0,1], otherwise hierarchy influence can disappear visually.
      local effective = ownOverlap * (1.0 + pe)

      out[id] = effective
      for _,cid in ipairs(n.children or {}) do
        rec(cid, effective)
      end
    end

    for _,rid in ipairs(roots) do
      rec(rid, 0.0)
    end

    return out
  end

  getFrontSignForRadiusBoost = function(id)
    if (not view3d) and id and nodes[id] then
      local ns = tonumber(nodes[id].prox_sign_2d) or 1
      return (ns >= 0) and 1 or -1
    end

    local sign = depth_pref_set and depth_pref_sign or 1
    if drag and drag.active and drag.depthSign and drag.depthSign ~= 0 then
      sign = drag.depthSign
    end
    return (sign >= 0) and 1 or -1
  end

  apply2DProximityRadiusBoost = function(id, n, base, currentR, restWorld, overlapMap)
    if not (id and n and base and currentR and restWorld) then return nil end
    local pid = n.parent
    if not (pid and nodes[pid]) then return nil end

    local overlap = nil
    if overlapMap and overlapMap[id] ~= nil then
      overlap = math.max(0.0, tonumber(overlapMap[id]) or 0.0)
    else
      local parentN = nodes[pid]
      local R = restRangeToParent(id, restWorld)
      if not parentN or not R or R <= 1e-9 then return nil end

      local dxp = (n.worldx or 0) - (parentN.worldx or 0)
      local dyp = (n.worldy or 0) - (parentN.worldy or 0)
      local d = math.sqrt(dxp*dxp + dyp*dyp)
      if d >= R then return currentR end

      overlap = clamp(1.0 - (d / R), 0.0, 1.0)
    end
    if overlap <= 0 then return currentR end
    if getFrontSignForRadiusBoost(id) <= 0 then return currentR end

    local fovMul = clamp(tonumber(fov_2d) or 60, 15, 140) / 100.0
    local proximityBoost = base * (overlap * fovMul)

    -- only increase final display radius, never decrease
    return currentR + proximityBoost
  end

  -- =========================
  -- paint
  -- =========================
  local function paintAll(gc)
    gc.color = Color{r=245,g=245,b=245,a=255}
    gc:fillRect(Rectangle(0,0,PAD_W,PAD_H))
    gc.color = Color{r=40,g=40,b=40,a=255}
    gc:rect(Rectangle(0,0,PAD_W-1,PAD_H-1))

    computeWorldFromActiveLocals()
    local effZ = statePose and buildEffectiveZMap() or nil
    local proj = buildProjectedMap(effZ)
    local projRaster = buildRasterProjectedMap(effZ, proj)
    local alphaMap = buildAlphaMap(proj)

    if view3d then draw3DFloorGrid(gc) end

    for k,v in pairs(links) do
      if v == true then
        local a,b = k:match("^(.-)%|(.-)$")
          local pa, pb = projRaster[a], projRaster[b]
          if pa and pb then
            local aa = math.min(alphaMap[a] or 255, alphaMap[b] or 255)
            gc.color = Color{r=0,g=0,b=0,a=aa}
            drawDoubleCircleLink(gc, pa.x, pa.y, pb.x, pb.y, pa.r, pb.r)
          end
        end
    end

    for _,id in ipairs(order) do
      local n = nodes[id]
      if n and n.parent and nodes[n.parent] then
        if getLinkState(id, n.parent) then
          local pa = projRaster[n.parent]
          local pb = projRaster[id]
          if pa and pb then
            local aa = math.min(alphaMap[n.parent] or 255, alphaMap[id] or 255)
            gc.color = Color{r=0,g=0,b=0,a=aa}
            drawDoubleCircleLink(gc, pa.x, pa.y, pb.x, pb.y, pa.r, pb.r)
          end
        end
      end
    end

    for _,id in ipairs(order) do
      local p = projRaster[id]
      local pdot = proj[id]
      if p and pdot then
        local isSel = (selected[id] == true)
        local isPinned = (nodes[id] and nodes[id].pinned == true)
        local aa = alphaMap[id] or 255
        if isSel then gc.color = Color{r=60,g=220,b=60,a=255}
        elseif isPinned then gc.color = Color{r=70,g=140,b=255,a=255}
        else gc.color = Color{r=0,g=0,b=0,a=aa} end

        local showSphere = (display_spheres == true) and (nodes[id] and nodes[id].sphere ~= false)
        if showSphere then
          drawCirclePolyline(gc, p.x, p.y, p.r, 52)
        end

        local px = math.floor(pdot.x + 0.5)
        local py = math.floor(pdot.y + 0.5)
        if isSel then
          gc.color = Color{r=60,g=220,b=60,a=255}
        elseif isPinned then
          gc.color = Color{r=70,g=140,b=255,a=255}
        else
          gc.color = Color{r=0,g=0,b=0,a=aa}
        end
        gc:fillRect(Rectangle(px-1, py-1, 3, 3))
      end
    end
  end

  -- =========================
  -- MMB adjust (over selected vert)
  -- =========================
  local function beginMMBAdjust(ev)
    drag.mmb = true
    drag.mmb_lastY = ev.y
  end

  local refreshUI

  local function updateMMBAdjust(ev, dlg)
    if not drag.mmb then return end
    if not lastSelected or not nodes[lastSelected] then return end
    local dy = (ev.y - drag.mmb_lastY)
    drag.mmb_lastY = ev.y
    if dy == 0 then return end
    local step = 1
    local delta = (dy < 0) and -step or step
    applyRadiusOrZWithMirror(lastSelected, delta)
    if dlg then refreshUI() end
  end

  local function endMMBAdjust()
    drag.mmb = false
  end

  -- =========================
  -- DIALOG + visibility
  -- =========================
  local options, optErr = listPresetTxtFiles(SCRIPT_DIR)
  if optErr then app.alert(optErr) end
  if #options == 0 then options = {"default.txt"} end
  do
    local hasDefault = false
    for _,f in ipairs(options) do if string.lower(f) == "default.txt" then hasDefault = true break end end
    if not hasDefault then table.insert(options, 1, "default.txt") end
  end

  local dlg = Dialog("Poser (Rest/Pose)")

  refreshUI = function()
    if dlg then dlg:repaint() end
    updateLivePreviewLayer()
  end

  local function updateControlsForState()
    local isRest = stateRest
    pcall(function()
      dlg:modify{ id="mode_add", visible=isRest }
      dlg:modify{ id="btn_parent", visible=isRest }
      dlg:modify{ id="btn_mirror", visible=isRest }
      dlg:modify{ id="btn_delete", visible=isRest }
      dlg:modify{ id="btn_reset_view_rest", visible=isRest }
      dlg:modify{ id="btn_revert", visible=(not isRest) }
      dlg:modify{ id="btn_revert_all", visible=(not isRest) }
      dlg:modify{ id="btn_reset_view_pose", visible=(not isRest) }
    end)
  end

  local function updateControlsFor3D()
    pcall(function()
      dlg:modify{ id="fov", visible=(view3d==true) }
      dlg:modify{ id="fov_2d", visible=(view3d~=true) }
      dlg:modify{ id="order_alpha", visible=(view3d==true) }
      dlg:modify{ id="depth_alpha", visible=(view3d==true) }
    end)
  end

  dlg:combobox{
    id="file",
    label="File",
    options=options,
    option="default.txt",
    onchange=function(ev)
      local v = nil
      if ev and ev.option then v = ev.option end
      if not v and dlg.data and dlg.data.file then v = dlg.data.file end
      CURRENT_FILE = fileSafe(v or "default.txt")
    end
  }

  dlg:newrow()
  dlg:button{
    id="btn_save",
    text="Save",
    onclick=function()
      if dlg.data and dlg.data.file then CURRENT_FILE = fileSafe(dlg.data.file) end
      saveGraph()
    end
  }
  dlg:button{
    id="btn_load",
    text="Load",
    onclick=function()
      if dlg.data and dlg.data.file then CURRENT_FILE = fileSafe(dlg.data.file) end
      loadGraph()

      setMode(modeAdd, dlg)
      setState(stateRest, statePose, dlg)

      dlg:modify{ id="mirror_mods", selected=(mirror_mods==true) }
      dlg:modify{ id="limit_range", selected=(limit_range==true) }
      dlg:modify{ id="view_3d", selected=(view3d==true) }
      updateSphereUI(dlg)
      dlg:modify{ id="live", selected=(live_preview==true) }
      dlg:modify{ id="order_alpha", selected=(order_alpha==true) }
      dlg:modify{ id="depth_alpha", selected=(depth_alpha==true) }
      dlg:modify{ id="fov", value=clamp(tonumber(fov_deg) or 60, 15, 140) }
      dlg:modify{ id="fov_2d", value=clamp(tonumber(fov_2d) or 60, 15, 140) }
      dlg:modify{ id="res_scale", value=math.floor(clamp((tonumber(res_scale) or 1.0) * 100, 10, 100) + 0.5) }

      updateControlsForState()
      updateControlsFor3D()
      updateLinkUI(dlg)
      updateSphereUI(dlg)
      refreshUI()
    end
  }

  dlg:newrow()
  dlg:slider{
    id="fov",
    label="FOV",
    min=15,
    max=140,
    value=fov_deg,
    visible=false,
    onchange=function()
      fov_deg = clamp(tonumber(dlg.data.fov) or 60, 15, 140)
      refreshUI()
    end
  }
  dlg:slider{
    id="fov_2d",
    label="2D FOV",
    min=15,
    max=140,
    value=fov_2d,
    visible=true,
    onchange=function()
      fov_2d = clamp(tonumber(dlg.data.fov_2d) or 60, 15, 140)
      refreshUI()
    end
  }
  dlg:slider{
    id="res_scale",
    label="res scale",
    min=10,
    max=100,
    value=100,
    visible=true,
    onchange=function()
      res_scale = clamp((tonumber(dlg.data.res_scale) or 100) / 100.0, 0.1, 1.0)
      refreshUI()
    end
  }

  dlg:newrow()
  dlg:check{
    id="state_rest",
    text="rest",
    selected=true,
    onclick=function()
      setState(true, false, dlg)
      updateControlsForState()
      refreshUI()
    end
  }
  dlg:check{
    id="state_pose",
    text="pose",
    selected=false,
    onclick=function()
      setState(false, true, dlg)
      updateControlsForState()
      refreshUI()
    end
  }
  dlg:check{
    id="live",
    text="live",
    selected=false,
    onclick=function()
      live_preview = (dlg.data.live == true)
      refreshUI()
    end
  }
  dlg:check{
    id="mode_add",
    text="add",
    selected=false,
    onclick=function()
      setMode(dlg.data.mode_add == true, dlg)
      refreshUI()
    end
  }

  dlg:newrow()

  dlg:check{
    id="view_3d",
    label="",
    text="3d",
    selected=false,
    onclick=function()
      view3d = (dlg.data.view_3d == true)

      if view3d and modeAdd then
        setMode(false, dlg)
      end

      updateControlsFor3D()
      refreshUI()
    end
  }

  dlg:check{
    id="order_alpha",
    label="",
    text="order alpha",
    selected=false,
    visible=false,
    onclick=function()
      order_alpha = (dlg.data.order_alpha == true)
      if order_alpha then
        depth_alpha = false
        dlg:modify{ id="depth_alpha", selected=false }
      end
      refreshUI()
    end
  }

  dlg:check{
    id="depth_alpha",
    label="",
    text="depth alpha",
    selected=false,
    visible=false,
    onclick=function()
      depth_alpha = (dlg.data.depth_alpha == true)
      if depth_alpha then
        order_alpha = false
        dlg:modify{ id="order_alpha", selected=false }
      end
      refreshUI()
    end
  }

  dlg:newrow()
  dlg:canvas{
    id="pad",
    width=PAD_W, height=PAD_H,

    onpaint=function(ev)
      paintAll(ev.context)
    end,

    onwheel=function(ev)
      local dy = wheelDeltaY(ev)
      if dy == 0 then return end

      if drag.active and drag.id then
        if statePose then
          local sign = (dy > 0) and -1 or 1
          drag.depthSign = sign
          if view3d then
            depth_pref_sign = sign
            depth_pref_set = true
          else
            local dn = nodes[drag.id]
            if dn then dn.prox_sign_2d = sign end
          end
          refreshUI()
        end
        return
      end

      if drag.mmb then return end

      if view3d then
        zoomByWheel(dy)
      else
        zoom2DByWheel(dy)
      end
      refreshUI()
    end,

    onmousedown=function(ev)
      if not isInsidePad(ev.x, ev.y) then return end
      local mx,my = clampToPad(ev.x, ev.y)

      computeWorldFromActiveLocals()
      local effZ = statePose and buildEffectiveZMap() or nil
      local proj = buildProjectedMap(effZ)

      if btnIs(ev, "MIDDLE") then
        if view3d then
          if #selectedList > 0 and isCursorOverSelected(mx, my, proj) then
            beginMMBAdjust(ev)
          else
            if evAlt(ev) then
              beginViewPan(ev)
            else
              beginViewRotate(ev)
            end
          end
        else
          if #selectedList > 0 and isCursorOverSelected(mx, my, proj) then
            beginMMBAdjust(ev)
          else
            if evAlt(ev) then
              beginView2DPan(ev)
            end
          end
        end
        return
      end

      if btnIs(ev, "LEFT") then
        local hit = pickNodeAt(mx,my, proj)
        local sh = evShift(ev)

        if not hit then
          if not sh then
            clearSelection()
            updateLinkUI(dlg)
            updateSphereUI(dlg)
            refreshUI()
          end
          return
        end

        if sh then addToSelection(hit) else setSingleSelection(hit) end
        updateLinkUI(dlg)
        updateSphereUI(dlg)

        if modeAdd and stateRest then
          local newId = createChildAndDrag(hit, mx, my)
          if newId then
            computeWorldFromActiveLocals()
            local effZ2 = statePose and buildEffectiveZMap() or nil
            local proj2 = buildProjectedMap(effZ2)
            beginDrag(newId, mx, my, proj2)
            updateSphereUI(dlg)
          end
        else
          beginDrag(hit, mx, my, proj, false)
        end

        refreshUI()
        return
      end

      if btnIs(ev, "RIGHT") then
        local hit = pickNodeAt(mx,my, proj)
        if not hit then return end
        setSingleSelection(hit)
        updateLinkUI(dlg)
        updateSphereUI(dlg)
        beginDrag(hit, mx, my, proj, true)
        refreshUI()
        return
      end
    end,

    onmousemove=function(ev)
      if viewPanDrag.active then
        updateViewPan(ev)
        refreshUI()
        return
      end
      if viewRot.active then
        updateViewRotate(ev)
        refreshUI()
        return
      end
      if view2dPanDrag.active then
        updateView2DPan(ev)
        refreshUI()
        return
      end
      if drag.mmb then
        updateMMBAdjust(ev, dlg)
        return
      end
      if not drag.active or not drag.id then return end

      local mx,my = clampToPad(ev.x, ev.y)
      if (not drag.moved) then
        local ddx = mx - (drag.startMx or mx)
        local ddy = my - (drag.startMy or my)
        if (ddx*ddx + ddy*ddy) > 9 then drag.moved = true end
      end

      local n = nodes[drag.id]
      if not n then return end

      computeWorldFromActiveLocals()
      local effZ = statePose and buildEffectiveZMap() or nil
      local proj = buildProjectedMap(effZ)

      local base = drag.baseWorld or {}
      local baseRoot = base[drag.id]
      local baseScreen = drag.baseScreen
      if not baseRoot or not baseScreen then return end

      local target_sx = mx + drag.grabDx
      local target_sy = my + drag.grabDy

      local dsx = target_sx - baseScreen.x
      local dsy = target_sy - baseScreen.y

      local dW = {x=dsx, y=dsy, z=0}
      if view3d then
        local ww = screenDeltaToWorldDelta3(dsx, dsy, drag.baseRootCamZ)
        dW.x, dW.y, dW.z = ww.x, ww.y, ww.z
      else
        local z2 = math.max(0.0001, view2d.zoom)
        dW.x = dsx / z2
        dW.y = dsy / z2
        dW.z = 0
      end

      local ids = drag.subtreeIds or { drag.id }
      local unrestricted3dPose = (view3d and statePose and not (limit_range and n.parent and nodes[n.parent]))
      local targetRoot = nil
      if unrestricted3dPose then
        targetRoot = screenToWorldAtCamZ(target_sx, target_sy, drag.baseRootCamZ)
      end

      local function translateSubtree(dx, dy)
        for _,cid in ipairs(ids) do
          local b = base[cid]
          local nn = nodes[cid]
          if b and nn then
            if nn.pinned ~= true then
              nn.worldx = b.x + dx
              nn.worldy = b.y + dy
            end
          end
        end
      end

      if limit_range and statePose and n.parent and nodes[n.parent] then
        buildChildren()
        local restWorld = computeRestWorldPositions()
        local R = restRangeToParent(drag.id, restWorld)

        if R and R > 1e-9 then
          if view3d then
            local pid = n.parent
            local pp = proj[pid]
            if pp then
              local f = focalFromFov()
              local parentCamX = pp.camX or 0
              local parentCamY = pp.camY or 0
              local parentCamZ = pp.camZ or cam_dist
              if parentCamZ < 0.001 then parentCamZ = 0.001 end

              local rel_sx = target_sx - pp.x
              local rel_sy = target_sy - pp.y

              local dCamX = rel_sx * parentCamZ / f
              local dCamY = rel_sy * parentCamZ / f
              local dPlane = math.sqrt(dCamX*dCamX + dCamY*dCamY)

              if dPlane > R and dPlane > 1e-9 then
                local s = R / dPlane
                dCamX = dCamX * s
                dCamY = dCamY * s
                dPlane = R
              end

              local depthCam = 0
              local hitFound = false
              do
                local px = (target_sx - cx) / f
                local py = (target_sy - cy) / f
                local D = vnorm({x=px, y=py, z=1})
                local C = {x=parentCamX, y=parentCamY, z=parentCamZ}
                local a = vdot(D, D)
                local b = -2.0 * vdot(D, C)
                local c = vdot(C, C) - (R*R)
                local disc = (b*b) - (4*a*c)
                if disc >= 0 then
                  local sd = math.sqrt(disc)
                  local inv = 1.0 / (2*a)
                  local t0 = (-b - sd) * inv
                  local t1 = (-b + sd) * inv
                  if t0 > t1 then t0, t1 = t1, t0 end
                  if t1 > 0 then
                    local sign = drag.depthSign
                    if sign == 0 then
                      local childCamZ = proj[drag.id] and (proj[drag.id].camZ or parentCamZ) or parentCamZ
                      sign = (childCamZ > parentCamZ) and 1 or -1
                    end
                    if sign >= 0 then sign = 1 else sign = -1 end
                    local t = (sign < 0) and t0 or t1
                    if t <= 0 then t = t1 end
                    local hit = {x=D.x*t, y=D.y*t, z=D.z*t}
                    dCamX = hit.x - C.x
                    dCamY = hit.y - C.y
                    depthCam = hit.z - C.z
                    hitFound = true
                  end
                end
              end

              if not hitFound then
                local rem2 = (R*R) - (dPlane*dPlane)
                if rem2 < 0 then rem2 = 0 end
                local depthMax = math.sqrt(rem2)
                local overlap = 1.0 - (dPlane / R)
                overlap = clamp(overlap, 0.0, 1.0)
                local sign = (drag.depthSign ~= 0) and drag.depthSign or depth_pref_sign
                if sign >= 0 then sign = 1 else sign = -1 end
                depthCam = sign * depthMax * overlap
              end

              local offW = {
                x = camR.x*dCamX + camU.x*dCamY + camF.x*depthCam,
                y = camR.y*dCamX + camU.y*dCamY + camF.y*depthCam,
                z = camR.z*dCamX + camU.z*dCamY + camF.z*depthCam,
              }

              local parentN = nodes[pid]
              local newRootX = (parentN.worldx or 0) + offW.x
              local newRootY = (parentN.worldy or 0) + offW.y

              local dx = newRootX - baseRoot.x
              local dy = newRootY - baseRoot.y
              translateSubtree(dx, dy)

              local parentZpix = (pp.zpix or 0)
              local desiredChildZpix = parentZpix + offW.z
              applySubtreePoseZ3DFromRootZpix(desiredChildZpix, effZ)
            else
              translateSubtree(dW.x, dW.y)
            end
          else
            local pid = n.parent
            local parentN = nodes[pid]
            if parentN then
              local newRootX = baseRoot.x + dW.x
              local newRootY = baseRoot.y + dW.y
              if not drag.right then
                local dxp = newRootX - (parentN.worldx or 0)
                local dyp = newRootY - (parentN.worldy or 0)
                local dd = math.sqrt(dxp*dxp + dyp*dyp)
                if dd > R and dd > 1e-9 then
                  local s = R / dd
                  newRootX = (parentN.worldx or 0) + dxp*s
                  newRootY = (parentN.worldy or 0) + dyp*s
                end
              end
              local dx = newRootX - baseRoot.x
              local dy = newRootY - baseRoot.y
              if (not view3d) and drag.right then
                applyRightDragRopeIK(drag.id, newRootX, newRootY)
              else
                translateSubtree(dx, dy)
              end
            else
              local dx, dy = dW.x, dW.y
              if (not view3d) and drag.right then
                applyRightDragRopeIK(drag.id, baseRoot.x + dx, baseRoot.y + dy)
              else
                translateSubtree(dx, dy)
              end
            end
          end
        else
          if (not view3d) and drag.right then
            applyRightDragRopeIK(drag.id, baseRoot.x + dW.x, baseRoot.y + dW.y)
          else
            translateSubtree(dW.x, dW.y)
          end
        end
      else
        if targetRoot and baseRoot then
          local dx = targetRoot.x - baseRoot.x
          local dy = targetRoot.y - baseRoot.y
          if (not view3d) and drag.right then
            applyRightDragRopeIK(drag.id, targetRoot.x, targetRoot.y)
          else
            translateSubtree(dx, dy)
          end
        else
          local dx, dy = dW.x, dW.y
          if (not view3d) and drag.right then
            applyRightDragRopeIK(drag.id, baseRoot.x + dx, baseRoot.y + dy)
          else
            translateSubtree(dx, dy)
          end
        end
      end

      if unrestricted3dPose then
        local desiredZpix = (targetRoot and targetRoot.zpix) or ((drag.baseRootZpix or 0) + dW.z)
        applySubtreePoseZ3DFromRootZpix(desiredZpix, effZ)
      end

      computeActiveLocalsFromWorld()
      computeWorldFromActiveLocals()

      if statePose then
        markPosePosSetSubtree(drag.id)
      end

      applyMirrorMoveFromWorld(drag.id)

      refreshUI()
    end,

    onmouseup=function(ev)
      if btnIs(ev, "MIDDLE") then
        if viewPanDrag.active then endViewPan() end
        if viewRot.active then endViewRotate() end
        if view2dPanDrag.active then endView2DPan() end
        if drag.mmb then endMMBAdjust() end
        return
      end
      if btnIs(ev, "LEFT") then
        if drag.active and not drag.right then endDrag(); refreshUI() end
        return
      end
      if btnIs(ev, "RIGHT") then
        if drag.active and drag.right and drag.id then
          local n = nodes[drag.id]
          if n and not drag.moved then
            n.pinned = not (n.pinned == true)
          end
          endDrag()
          refreshUI()
        end
        return
      end
    end
  }

  dlg:newrow()
  dlg:button{
    id="btn_parent",
    text="parent",
    onclick=function()
      doParent()
      updateLinkUI(dlg)
      refreshUI()
    end
  }

  dlg:button{
    id="btn_mirror",
    text="mirror",
    onclick=function()
      if lastSelected and nodes[lastSelected] then
        mirrorSubtreeRest(lastSelected)
        updateLinkUI(dlg)
        refreshUI()
      end
    end
  }

  dlg:button{
    id="btn_delete",
    text="delete",
    onclick=function()
      deleteSelectedButKeepChildren()
      updateLinkUI(dlg)
      updateSphereUI(dlg)
      refreshUI()
    end
  }
  dlg:button{
    id="btn_reset_view_rest",
    text="reset view",
    onclick=function()
      resetViewToFront()
      refreshUI()
    end
  }

  dlg:newrow()
  dlg:button{
    id="btn_revert",
    text="revert",
    onclick=function()
      revertSelectedToRest()
      updateSphereUI(dlg)
      refreshUI()
    end
  }

  dlg:button{
    id="btn_revert_all",
    text="revert all",
    onclick=function()
      revertAllToRest()
      updateSphereUI(dlg)
      refreshUI()
    end
  }
  dlg:button{
    id="btn_reset_view_pose",
    text="reset view",
    onclick=function()
      resetViewToFront()
      refreshUI()
    end
  }

  dlg:newrow()
  dlg:check{
    id="link_pair",
    text="link",
    selected=false,
    enabled=false,
    onclick=function()
      if #selectedList ~= 2 then
        updateLinkUI(dlg)
        return
      end
      local a = selectedList[1]
      local b = selectedList[2]
      local on = (dlg.data.link_pair == true)
      setLinkState(a,b,on)
      refreshUI()
    end
  }
  dlg:check{
    id="sphere_vert",
    text="sphere",
    selected=true,
    enabled=false,
    onclick=function()
      if lastSelected and nodes[lastSelected] then
        nodes[lastSelected].sphere = (dlg.data.sphere_vert == true)
        refreshUI()
      else
        updateSphereUI(dlg)
      end
    end
  }
  dlg:check{
    id="limit_range",
    text="limit range",
    selected=false,
    onclick=function()
      limit_range = (dlg.data.limit_range == true)
      refreshUI()
    end
  }
  dlg:check{
    id="mirror_mods",
    text="mirror modifications",
    selected=false,
    onclick=function()
      mirror_mods = (dlg.data.mirror_mods == true)
      refreshUI()
    end
  }

  dlg:newrow()

  resetToSingleCenterNode()

  CURRENT_FILE = fileSafe("default.txt")
  setMode(false, dlg)
  setState(true, false, dlg)

  dlg:modify{ id="mirror_mods", selected=false }
  mirror_mods = false

  dlg:modify{ id="limit_range", selected=false }
  limit_range = false

  dlg:modify{ id="view_3d", selected=false }
  view3d = false

  dlg:modify{ id="live", selected=false }
  live_preview = false

  dlg:modify{ id="order_alpha", selected=false }
  order_alpha = false

  dlg:modify{ id="depth_alpha", selected=false }
  depth_alpha = false

  depth_pref_sign = 1
  depth_pref_set = false

  dlg:modify{ id="fov", value=fov_deg, visible=false }
  dlg:modify{ id="fov_2d", value=fov_2d, visible=true }
  dlg:modify{ id="res_scale", value=100, visible=true }

  updateControlsForState()
  updateControlsFor3D()
  updateLinkUI(dlg)
  updateSphereUI(dlg)

  dlg:show{ wait=false }
  refreshUI()
end
