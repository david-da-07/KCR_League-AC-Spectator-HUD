--[[
  KCR Spectator HUD  (CSP online script)
  ---------------------------------------------------------------------------
  Torre de tiempos estilo F1 para streams. Se configura por slots (CONFIG.hudSlots,
  hiddenSlots, safetyCarSlots), sin filtros de nombre ni de modelo.

  * Torre a la izquierda: posicion, escudo, nombre, gap (INTERVAL / LEADER) y neumatico.
  * Cabecera: VUELTA x/total en carrera, tiempo restante en practica/qualy.
  * Piloto spectateado:
      - Practica / Qualy -> sectores y tiempo total (morado / verde / amarillo).
      - Carrera          -> acelerador, freno, marcha, velocidad y mapa del circuito.
  * F7 cambia INTERVAL <-> LEADER, F8 oculta/muestra el HUD.

  Solo usa la API estandar de CSP (ac.getCar, ui.*), no necesita el plugin.
  Compatible con LuaJIT (sintaxis Lua 5.1).
]]

-- ============================================================================
-- CONFIGURACION
-- ============================================================================
local CONFIG = {
  -- SLOTS: numeros de CAR_n del entry_list.ini (empezando en 0), da igual quien los ocupe.
  hudSlots = { 22 },            -- slots en los que se dibuja el HUD.         Ej: { 21 }
  hiddenSlots = { 22 },         -- slots que NO salen en la torre de tiempos.  Ej: { 21 }
  safetyCarSlots = { 20, 21 },  -- slot(s) del Safety Car: no salen en la torre y activan el estado SC
  debugSlots = false,       -- true: dibuja un panel con tu slot y el de cada coche (para comprobar)

  -- Estado de pista
  stoppedSeconds = 1,              -- un coche parado en pista tanto tiempo => amarilla en su sector
  stoppedSpeedKmh = 10,            -- por debajo de esta velocidad se considera parado

  defaultMode = 'interval',      -- 'interval' | 'leader'
  nameFormat = 'surname',        -- 'surname' | 'tla' (3 letras) | 'full'
  keyToggleMode = 'F9',
  keyToggleHud = 'F10',
  clickToFocus = true,          -- clic en una fila de la torre => seguir a ese piloto
  keyPrevCar = 'PageUp',        -- coche anterior de la torre (alternativa si no hay cursor)
  keyNextCar = 'PageDown',      -- coche siguiente de la torre

  maxRows = 24,
  checkpoints = 300,             -- resolucion del calculo de gaps (por vuelta)
  statusTop = 30,

  -- Escudo por equipo (ruta local o URL). Si no hay, se usa ui/badge.png del coche.
  -- Ejemplo: ['Vasser Sullivan'] = 'https://tu-servidor/badges/vasser.png'
  teamBadges = {},
  -- Color del equipo (r,g,b 0..1). Si no hay, se genera uno a partir del nombre.
  teamColors = {},

  -- Neumaticos: clave = nombre corto del compuesto (SHORT_NAME de tyres.ini, en mayusculas)
  tyres = {
    SS = { label = 'S', color = { 0.78, 0.30, 1.00 } },  -- ultra blando (morado)
    US = { label = 'U', color = { 0.78, 0.30, 1.00 } },
    S  = { label = 'S', color = { 0.93, 0.13, 0.15 } },  -- blando (rojo)
    M  = { label = 'M', color = { 1.00, 0.84, 0.00 } },  -- medio (amarillo)
    H  = { label = 'H', color = { 0.95, 0.95, 0.95 } },  -- duro (blanco)
    I  = { label = 'I', color = { 0.10, 0.75, 0.30 } },  -- intermedio (verde)
    W  = { label = 'W', color = { 0.15, 0.45, 1.00 } },  -- lluvia (azul)
    -- V = { label = 'V', color = { ... } },              -- anade aqui compuestos propios
  },
}

-- ============================================================================
-- UTILIDADES
-- ============================================================================
local N = CONFIG.checkpoints

local S = {
  now = 0,
  cars = {},
  mode = CONFIG.defaultMode,
  hud = true,
  sessionIdx = nil,
  secStart = nil,      -- posiciones de spline donde empieza cada sector
  bestSec = {},        -- mejores sectores globales (ms)
  bestLap = nil,       -- mejor vuelta global (ms)
  map = nil,           -- false = no disponible
  tyreCache = {},
  errors = {},
}

local function try(f, ...)
  local ok, r = pcall(f, ...)
  if ok then return r end
  return nil
end

local function logOnce(msg)
  if S.errors[msg] then return end
  S.errors[msg] = true
  if ac and ac.log then pcall(ac.log, 'KCR Spectator: ' .. tostring(msg)) end
end

local function readFile(path)
  if io and io.load then
    local ok, r = pcall(io.load, path)
    if ok and type(r) == 'string' and r ~= '' then return r end
  end
  if io and io.open then
    local ok, f = pcall(io.open, path, 'rb')
    if ok and f then
      local d = f:read('*a')
      f:close()
      return d
    end
  end
  return nil
end

-- Slot del servidor (CAR_n) de un coche. Se usa car.sessionID (indice de la entry list);
-- si no existiera en tu version de CSP se usa el indice del cliente y se avisa en el log.
local function slotOf(car, i)
  local s = car and car.sessionID
  if s == nil then
    logOnce('car.sessionID no disponible: se usa el indice del cliente como slot')
    return i
  end
  return s
end

local function inList(list, v)
  for _, x in ipairs(list) do
    if x == v then return true end
  end
  return false
end

local function validTime(ms)
  return ms ~= nil and ms > 0 and ms < 3600000
end

local function fmtLap(ms)
  if not validTime(ms) then return '-:--.---' end
  local m = math.floor(ms / 60000)
  return string.format('%d:%06.3f', m, (ms - m * 60000) / 1000)
end

local function fmtSector(ms)
  if not ms or ms <= 0 then return '--.---' end
  if ms >= 60000 then return fmtLap(ms) end
  return string.format('%.3f', ms / 1000)
end

local function fmtGap(sec)
  if sec < 0 then sec = 0 end
  if sec < 60 then return string.format('+%.3f', sec) end
  local m = math.floor(sec / 60)
  return string.format('+%d:%04.1f', m, sec - m * 60)
end

local function fmtClock(ms)
  if not ms or ms < 0 then return '--:--' end
  local s = math.floor(ms / 1000)
  local h = math.floor(s / 3600)
  local m = math.floor((s - h * 3600) / 60)
  s = s - h * 3600 - m * 60
  if h > 0 then return string.format('%d:%02d:%02d', h, m, s) end
  return string.format('%02d:%02d', m, s)
end

-- ============================================================================
-- INFO ESTATICA: pistas, sectores, mapa
-- ============================================================================
local function trackBase()
  local root = try(ac.getFolder, ac.FolderID.ContentTracks)
  local id = try(ac.getTrackFullID, '/')
  if not root or not id then return nil end
  return root .. '/' .. id
end

local function loadSectors()
  local starts = {}
  local base = trackBase()
  local txt = base and readFile(base .. '/data/sections.ini')
  if txt then
    for v in txt:gmatch('[\r\n]%s*IN%s*=%s*([%d%.%-]+)') do
      local n = tonumber(v)
      if n and n >= 0 and n < 1 then starts[#starts + 1] = n end
    end
    table.sort(starts)
    if #starts >= 2 and #starts <= 5 then
      if starts[1] > 0.05 then table.insert(starts, 1, 0) end
      return starts
    end
  end
  return { 0, 1 / 3, 2 / 3 }
end

local function sectorIndex(sp)
  for i = #S.secStart, 1, -1 do
    if sp >= S.secStart[i] then return i end
  end
  return 1
end

local function loadMap()
  local base = trackBase()
  if not base then return false end
  local ini = readFile(base .. '/data/map.ini')
  if not ini then return false end
  local function val(k, d)
    local v = ini:match('[\r\n]%s*' .. k .. '%s*=%s*([%d%.%-eE]+)')
    return tonumber(v) or d
  end
  local m = {
    img = base .. '/map.png',
    w = val('WIDTH', 1000), h = val('HEIGHT', 1000),
    scale = val('SCALE_FACTOR', 1), xo = val('X_OFFSET', 0), zo = val('Z_OFFSET', 0),
  }
  if m.scale == 0 then m.scale = 1 end
  local sz = try(ui.imageSize, m.img)
  if sz and sz.x and sz.x > 1 and sz.y > 1 then m.w, m.h = sz.x, sz.y end
  return m
end

-- ============================================================================
-- ESTADO POR COCHE
-- ============================================================================
local function newLap() return { s = {}, col = {}, pit = false } end

local function getCS(i)
  local cs = S.cars[i]
  if not cs then
    cs = {
      times = {}, pb = {}, pbLap = nil,
      prof = {},          -- perfil de la vuelta en curso: checkpoint -> ms desde meta (para el delta)
      cur = newLap(), last = nil,
      lapCount = nil, info = nil, infoT = -100,
    }
    S.cars[i] = cs
  end
  return cs
end

local function resetAll()
  S.cars = {}
  S.bestSec = {}
  S.bestLap = nil
end

local function hashColor(str)
  local h = 0
  for i = 1, #str do h = (h * 31 + str:byte(i)) % 360 end
  -- HSV (h, 0.65, 0.95) -> RGB
  local s, v = 0.65, 0.95
  local c = v * s
  local x = c * (1 - math.abs((h / 60) % 2 - 1))
  local m = v - c
  local r, g, b = 0, 0, 0
  if h < 60 then r, g, b = c, x, 0
  elseif h < 120 then r, g, b = x, c, 0
  elseif h < 180 then r, g, b = 0, c, x
  elseif h < 240 then r, g, b = 0, x, c
  elseif h < 300 then r, g, b = x, 0, c
  else r, g, b = c, 0, x end
  return { r + m, g + m, b + m }
end

local function driverLabel(full)
  full = full or ''
  full = full:gsub('^%s+', ''):gsub('%s+$', '')
  if full == '' then return '---' end
  local surname = full:match('([^%s]+)$') or full
  if CONFIG.nameFormat == 'full' then return full:upper() end
  if CONFIG.nameFormat == 'tla' then return surname:sub(1, 3):upper() end
  return surname:upper()
end

local function utf8char(c)
  if c < 0x80 then return string.char(c) end
  if c < 0x800 then return string.char(0xC0 + math.floor(c / 64), 0x80 + c % 64) end
  return string.char(0xE0 + math.floor(c / 4096), 0x80 + math.floor(c / 64) % 64, 0x80 + c % 64)
end

-- Decodifica los escapes de una cadena JSON (\uXXXX, \", \\, \/)
local function jsonString(s)
  s = s:gsub('\\u(%x%x%x%x)', function(h) return utf8char(tonumber(h, 16)) end)
  s = s:gsub('\\(["\\/])', '%1')
  return s
end

-- Valor de texto de un campo JSON simple ("clave": "valor"), respetando comillas escapadas
local function jsonField(txt, key)
  if not txt then return nil end
  local _, e = txt:find('"' .. key .. '"%s*:%s*"')
  if not e then return nil end
  local i, n = e + 1, #txt
  while i <= n do
    local c = txt:sub(i, i)
    if c == '\\' then i = i + 2
    elseif c == '"' then return jsonString(txt:sub(e + 1, i - 1))
    else i = i + 1 end
  end
  return nil
end

-- Ultimo recurso si no se puede leer ui_car.json: 'emka_lexus_rc_f_gt3' -> 'Emka Lexus RC F GT3'
local function prettyId(id)
  local out = {}
  for tok in (id or ''):gmatch('[^_%-%s]+') do
    if tok:match('^%a+%d+$') or #tok <= 3 then out[#out + 1] = tok:upper()
    else out[#out + 1] = tok:sub(1, 1):upper() .. tok:sub(2):lower() end
  end
  return table.concat(out, ' ')
end

local function refreshInfo(i, cs)
  local carId = try(ac.getCarID, i) or ''
  local skin = try(ac.getCarSkinID, i) or ''
  local name = try(ac.getDriverName, i) or ''
  local skinTeam, carName
  local root = try(ac.getFolder, ac.FolderID.ContentCars)
  if root and carId ~= '' then
    if skin ~= '' then
      local txt = readFile(root .. '/' .. carId .. '/skins/' .. skin .. '/ui_skin.json')
      skinTeam = jsonField(txt, 'team')
    end
    carName = jsonField(readFile(root .. '/' .. carId .. '/ui/ui_car.json'), 'name')
  end
  -- nombre visual del coche (ui_car.json); nunca el id crudo
  if not carName or carName == '' then carName = prettyId(carId) end
  if skinTeam == '' then skinTeam = nil end
  -- clave interna para colores y escudos (CONFIG.teamBadges / teamColors): equipo del skin o id del coche
  local team = skinTeam or carId
  local badge = CONFIG.teamBadges[team]
  if not badge and root and carId ~= '' then badge = root .. '/' .. carId .. '/ui/badge.png' end
  cs.info = {
    carId = carId, name = name, label = driverLabel(name), team = team,
    carName = carName, skinTeam = skinTeam,
    color = CONFIG.teamColors[team] or hashColor(team), badge = badge,
  }
  cs.infoT = S.now
end

local function getInfo(i, cs)
  local name = try(ac.getDriverName, i) or ''
  if not cs.info or cs.info.name ~= name or S.now - cs.infoT > 5 then refreshInfo(i, cs) end
  return cs.info
end

-- Neumatico: devuelve {label, color{r,g,b}}
local function tyreOf(i, car)
  local ci = car.compoundIndex or 0
  local carId = try(ac.getCarID, i) or ''
  local key = carId .. ':' .. tostring(ci)
  local hit = S.tyreCache[key]
  if hit then return hit end
  local short = try(ac.getTyresName, i, ci)
  local long = try(ac.getTyresLongName, i, ci)
  if not short and not long then return { label = '?', color = { 0.6, 0.6, 0.6 } } end
  local s = (short or ''):upper()
  local l = (long or ''):lower()
  local res = CONFIG.tyres[s]
  if not res then
    if l:find('wet') or l:find('rain') or l:find('full') then res = CONFIG.tyres.W
    elseif l:find('inter') then res = CONFIG.tyres.I
    elseif l:find('ultra') or l:find('super') then res = CONFIG.tyres.SS
    elseif l:find('soft') then res = CONFIG.tyres.S
    elseif l:find('medium') then res = CONFIG.tyres.M
    elseif l:find('hard') then res = CONFIG.tyres.H
    end
  end
  if not res then
    local lab = (s ~= '' and s:sub(1, 1)) or (l ~= '' and l:sub(1, 1):upper()) or '?'
    res = { label = lab, color = { 0.80, 0.80, 0.80 } }
  end
  S.tyreCache[key] = res
  return res
end

-- ============================================================================
-- ACTUALIZACION (progreso, gaps, sectores)
-- ============================================================================
local function recordSector(cs, idx, ms, valid)
  local cur = cs.cur
  if not valid or ms <= 0 then
    cur.s[idx] = false
    return
  end
  local col = 'yellow'
  local gb = S.bestSec[idx]
  local pb = cs.pb[idx]
  if not gb or ms < gb then
    col = 'purple'
    S.bestSec[idx] = ms
  end
  if not pb or ms < pb then
    if col ~= 'purple' then col = 'green' end
    cs.pb[idx] = ms
  end
  cur.s[idx] = ms
  cur.col[idx] = col
end

-- Tiempo de la vuelta en curso (ms). Usa el cronometro del juego y, si no existe, uno propio
-- que arranca al pasar por meta.
local function lapMs(cs, car)
  local v = try(function() return car.lapTimeMs end)
  if type(v) == 'number' and v >= 0 then return v end
  return (S.now - (cs.lapT0 or S.now)) * 1000
end

-- Perfil de la vuelta: para cada checkpoint (0..N-1) los ms desde meta, interpolando entre frames.
-- Al cruzar meta el perfil terminado pasa a profDone y empieza uno nuevo.
local function recordProfile(cs, car, sp)
  local ms = lapMs(cs, car)
  local pos = sp * N
  local prev = cs.profPos
  if prev == nil then
    cs.prof = {}
  elseif pos < prev - N / 2 then
    cs.profDone = cs.prof            -- el spline dio la vuelta: este perfil esta terminado
    cs.wrapT = S.now
    cs.prof = { [0] = 0 }
  elseif pos > prev then
    for c = math.floor(prev) + 1, math.floor(pos) do
      local f = (c - prev) / (pos - prev)
      cs.prof[c] = cs.profMs + (ms - cs.profMs) * f
    end
  end
  cs.profPos, cs.profMs = pos, ms
end

-- Si la vuelta es la mejor personal y su perfil esta completo, pasa a ser la referencia del delta.
local function promoteProfile(cs, p, total)
  if not p then return end
  local cnt = 0
  for _ in pairs(p) do cnt = cnt + 1 end
  if cnt >= N * 0.97 then
    p[N] = total
    cs.bestProf = p
  end
end

-- Delta (ms) de la vuelta en curso contra la mejor personal en el mismo punto de la pista.
local function deltaMs(cs, car)
  local bp = cs.bestProf
  if not bp or cs.cur.pit then return nil end
  local pos = (car.splinePosition or 0) * N
  local c = math.floor(pos)
  local r0, r1 = bp[c], bp[c + 1]
  if not r0 or not r1 then return nil end
  return lapMs(cs, car) - (r0 + (r1 - r0) * (pos - c))
end

local function finishLap(cs, car)
  local cur = cs.cur
  local n = #S.secStart
  local total = car.previousLapTimeMs
  -- perfil de la vuelta que acaba de terminar: si el spline ya dio la vuelta (hace menos de 5 s) es
  -- profDone; si lapCount cambio antes que el spline, todavia es el perfil en curso
  local profile
  if cs.wrapT and S.now - cs.wrapT < 5 then
    profile = cs.profDone
  else
    profile = cs.prof
    cs.prof = {}
  end
  cs.wrapT = nil
  local lap = { s = cur.s, col = cur.col, pit = cur.pit, lapMs = nil, lapCol = nil }
  local ok = validTime(total) and not cur.pit
  if ok then
    local sum = 0
    for k = 1, n - 1 do
      if not cur.s[k] then ok = false break end
      sum = sum + cur.s[k]
    end
    if ok then
      local lastMs = total - sum
      if lastMs > 0 then
        -- el ultimo sector se calcula con el tiempo oficial de vuelta
        local saveCur = cs.cur
        cs.cur = lap
        recordSector(cs, n, lastMs, true)
        cs.cur = saveCur
        lap.lapMs = total
        local col = 'yellow'
        if not S.bestLap or total < S.bestLap then col = 'purple' S.bestLap = total end
        if not cs.pbLap or total < cs.pbLap then
          if col ~= 'purple' then col = 'green' end
          cs.pbLap = total
          promoteProfile(cs, profile, total)
        end
        lap.lapCol = col
      else
        lap.s[n] = false
      end
    end
  end
  if not lap.lapMs then
    if validTime(total) then lap.lapMsInvalid = total end
    lap.s[n] = lap.s[n] or false
  end
  cs.last = lap
  cs.cur = newLap()
end

local function updateSectors(cs, car, sp)
  local t = S.now
  local idx = sectorIndex(sp)
  local n = #S.secStart
  if car.isInPitlane then cs.cur.pit = true cs.secPit = true end
  if cs.secIdx == nil then
    cs.secIdx = idx
    cs.secStartT = t
    cs.lapT0 = t
    cs.secPit = true      -- sector empezado a medias: no vale
    cs.cur.pit = true     -- vuelta incompleta: no vale
    return
  end
  if idx == cs.secIdx then return end
  if idx == cs.secIdx + 1 then
    recordSector(cs, cs.secIdx, (t - cs.secStartT) * 1000, not cs.secPit)
    cs.secIdx = idx
    cs.secStartT = t
    cs.secPit = car.isInPitlane and true or false
  elseif idx == 1 and cs.secIdx == n then
    -- cruce de meta en el spline: el ultimo sector se cierra con previousLapTimeMs
    cs.secIdx = 1
    cs.secStartT = t
    cs.lapT0 = t
    cs.secPit = car.isInPitlane and true or false
  else
    -- salto (reset/teleport): la vuelta deja de ser valida
    cs.secIdx = idx
    cs.secStartT = t
    cs.secPit = true
    cs.cur.pit = true
  end
end

local function updateProgress(cs, car, dt)
  local sp = car.splinePosition or 0
  local t = S.now
  if cs.lastSp == nil then
    local total = (car.lapCount or 0) + sp
    if (car.lapCount or 0) == 0 and sp > 0.5 then total = sp - 1 end   -- parrilla antes de meta
    cs.total = total
    cs.lastSp = sp
    cs.lastT = t
    cs.cp = math.floor(total * N)
    cs.times[cs.cp] = t
    return sp
  end
  local d = sp - cs.lastSp
  if d < -0.5 then d = d + 1 elseif d > 0.5 then d = d - 1 end
  cs.total = cs.total + d
  cs.lastSp = sp
  local newcp = math.floor(cs.total * N)
  if newcp > cs.cp then
    local span = newcp - cs.cp
    for c = cs.cp + 1, newcp do
      cs.times[c] = cs.lastT + (t - cs.lastT) * (c - cs.cp) / span
      cs.times[c - 2 * N - 2] = nil
    end
    cs.cp = newcp
  elseif newcp < cs.cp - 3 then
    cs.cp = newcp   -- marcha atras / reset: no tocamos tiempos
  end
  cs.lastT = t
  return sp
end

local function updateCar(i, car, dt)
  local cs = getCS(i)
  local lc = car.lapCount or 0
  if cs.lapCount ~= nil and lc < cs.lapCount then
    -- sesion reiniciada
    S.cars[i] = nil
    cs = getCS(i)
  end
  local sp = updateProgress(cs, car, dt)
  updateSectors(cs, car, sp)
  recordProfile(cs, car, sp)
  if cs.lapCount ~= nil and lc > cs.lapCount then finishLap(cs, car) end
  cs.lapCount = lc
  return cs
end

local function sessionInfo(sim)
  local kind = 'practice'
  local sess = try(ac.getSession, sim.currentSessionIndex)
  local t = sim.raceSessionType
  if t == nil and sess then t = sess.type end
  if ac.SessionType then
    if t == ac.SessionType.Race then kind = 'race'
    elseif t == ac.SessionType.Qualify then kind = 'qualy' end
  end
  local laps = sess and tonumber(sess.laps) or 0
  local timed = sess and sess.isTimedRace or false
  return kind, laps, timed, sess
end

local function timeLeftMs(sim, sess)
  if sim.sessionTimeLeft then return sim.sessionTimeLeft end
  if sess and sess.durationMinutes and sim.currentSessionTime then
    return sess.durationMinutes * 60000 - sim.currentSessionTime
  end
  return nil
end

-- El HUD solo se dibuja si el coche local (indice 0 del cliente) esta en uno de hudSlots.
local function isHudClient()
  if #CONFIG.hudSlots == 0 then
    logOnce('CONFIG.hudSlots esta vacio: el HUD no se dibuja en ningun slot')
    return false
  end
  local car = ac.getCar(0)
  if not car then return false end
  return inList(CONFIG.hudSlots, slotOf(car, 0))
end

-- ============================================================================
-- ESTADO DE PISTA (banderas, Safety Car)
-- ============================================================================
-- Banderas que CSP puede presentar al cliente (sim.raceFlagType). Se resuelven por nombre
-- y si una no existe en tu version de CSP simplemente se ignora.
-- 4.o campo: true si la bandera afecta a TODA la pista y por tanto marca todos los sectores.
local FLAG_TABLE = {
  { 'SessionSuspended', 'RED FLAG',        'red',       true  },
  { 'PitLaneClosed',    'PIT LANE CLOSED', 'red',       false },
  { 'Code60',           'CODE 60',         'yellow',    true  },
  { 'Caution',          'YELLOW FLAG',     'yellow',    true  },
  { 'SlowVehicle',      'SLOW VEHICLE',    'yellow',    false },
  { 'Ambulance',        'AMBULANCE',       'yellow',    false },
  { 'Finished',         'CHEQUERED FLAG',  'chequered', false },
  { 'OneLapLeft',       'FINAL LAP',       'white',     false },
}

local function simFlag(sim)
  local ft, v = ac.FlagType, sim.raceFlagType
  if not ft or v == nil then return nil end
  for _, f in ipairs(FLAG_TABLE) do
    local e = ft[f[1]]
    if e ~= nil and v == e then return f end
  end
  return nil
end

local function updateTrack(sim, kind, laps, timed)
  local sc = { present = false, active = false }
  local hz, hzList = {}, {}
  local movers, leader = 0, 0
  for i = 0, (sim.carsCount or 0) - 1 do
    local car = ac.getCar(i)
    if car and car.isConnected then
      local slot = slotOf(car, i)
      if inList(CONFIG.safetyCarSlots, slot) then
        sc.present = true
        if not car.isInPitlane then sc.active = true end
      elseif not inList(CONFIG.hiddenSlots, slot) then
        local cs = getCS(i)
        local v = car.speedKmh or 0
        if cs.total and cs.total > leader then leader = cs.total end
        if car.isInPitlane then
          cs.wasMoving = false
          cs.stopT = nil
        elseif v > 40 then
          movers = movers + 1
          cs.wasMoving = true
          cs.stopT = nil
        elseif v < CONFIG.stoppedSpeedKmh and cs.wasMoving then
          cs.stopT = cs.stopT or S.now
          if S.now - cs.stopT >= CONFIG.stoppedSeconds then
            local k = sectorIndex(car.splinePosition or 0)
            if not hz[k] then hz[k] = true hzList[#hzList + 1] = k end
          end
        else
          cs.stopT = nil
        end
      end
    end
  end
  table.sort(hzList)
  -- sin coches rodando (bandera roja, final de sesion, parrilla) no hay peligro local que avisar
  if movers == 0 then hz, hzList = {}, {} end

  local f = simFlag(sim)
  local derivedFinish = kind == 'race' and laps and laps > 0 and not timed and leader >= laps
  local derivedLast = kind == 'race' and laps and laps > 1 and not timed
                      and leader >= laps - 1 and leader < laps

  -- T.all: color con el que se marcan TODOS los sectores (bandera de pista completa).
  -- Si es nil, solo se marcan los sectores con un coche parado (T.hz).
  local T = { key = 'clear', text = 'TRACK CLEAR', color = 'green', hz = hz, sc = sc, all = nil }
  if f and f[3] == 'red' then
    T.key, T.text, T.color = 'red', f[2], 'red'
    if f[4] then T.all = 'red' end
  elseif sc.active then
    T.key, T.text, T.color, T.all = 'sc', 'SAFETY CAR', 'orange', 'orange'
  elseif (f and f[3] == 'chequered') or derivedFinish then
    T.key, T.text, T.color = 'chequered', 'CHEQUERED FLAG', 'chequered'
  elseif #hzList > 0 or (f and f[3] == 'yellow') then
    local global = f and f[3] == 'yellow' and f[4]
    local txt = f and f[3] == 'yellow' and f[2] or 'YELLOW FLAG'
    if global then
      T.all = 'yellow'   -- amarilla en toda la pista: todos los sectores, sin lista de sectores
    elseif #hzList > 0 then
      local parts = {}
      for _, k in ipairs(hzList) do parts[#parts + 1] = 'S' .. k end
      txt = txt .. '  ' .. table.concat(parts, ' ')
    end
    T.key, T.text, T.color = 'yellow', txt, 'yellow'
  elseif (f and f[3] == 'white') or derivedLast then
    T.key, T.text, T.color = 'white', f and f[3] == 'white' and f[2] or 'FINAL LAP', 'white'
  end
  S.track = T
end

function script.update(dt)
  local ok, err = pcall(function()
    S.now = S.now + (dt or 0)
    local sim = ac.getSim()
    if not sim then return end
    if not S.secStart then S.secStart = loadSectors() end
    if S.sessionIdx ~= sim.currentSessionIndex then
      S.sessionIdx = sim.currentSessionIndex
      resetAll()
    end
    for i = 0, (sim.carsCount or 0) - 1 do
      local car = ac.getCar(i)
      if car and car.isConnected then updateCar(i, car, dt) end
    end
    local kind, laps, timed = sessionInfo(sim)
    updateTrack(sim, kind, laps, timed)
  end)
  if not ok then logOnce('update: ' .. tostring(err)) end
end

-- ============================================================================
-- ORDEN Y GAPS
-- ============================================================================
local function buildRows(sim, kind)
  local rows = {}
  for i = 0, (sim.carsCount or 0) - 1 do
    local car = ac.getCar(i)
    if car and car.isConnected then
      local cs = getCS(i)
      local info = getInfo(i, cs)
      local slot = slotOf(car, i)
      if not inList(CONFIG.hiddenSlots, slot) and not inList(CONFIG.safetyCarSlots, slot) then
        rows[#rows + 1] = {
          i = i, car = car, cs = cs, info = info,
          best = validTime(car.bestLapTimeMs) and car.bestLapTimeMs or nil,
          pos = car.racePosition or 0,
        }
      end
    end
  end
  if kind == 'race' then
    table.sort(rows, function(a, b)
      local pa = a.pos > 0 and a.pos or 1000
      local pb = b.pos > 0 and b.pos or 1000
      if pa ~= pb then return pa < pb end
      local ta, tb = a.cs.total or 0, b.cs.total or 0
      if ta ~= tb then return ta > tb end
      return a.i < b.i
    end)
  else
    table.sort(rows, function(a, b)
      if a.best and b.best then
        if a.best ~= b.best then return a.best < b.best end
        return a.i < b.i
      end
      if a.best then return true end
      if b.best then return false end
      return a.i < b.i
    end)
  end
  return rows
end

-- gap en segundos (a delante de b) o numero de vueltas de diferencia
local function raceGap(a, b, trackLen)
  local diff = (a.cs.total or 0) - (b.cs.total or 0)
  local laps = math.floor(diff + 1e-6)
  if laps >= 1 then return nil, laps end
  local c = b.cs.cp
  local ta = c and a.cs.times[c]
  local tb = c and b.cs.times[c]
  if ta and tb then return math.max(0, tb - ta), 0 end
  local speed = math.max((b.car.speedKmh or 0) / 3.6, 15)
  return math.max(0, diff * trackLen / speed), 0
end

local function gapText(rows, k, kind, trackLen)
  local r = rows[k]
  if r.car.isInPitlane then return 'PIT', 'pit' end
  if kind == 'race' then
    if k == 1 then return 'LEADER', 'leader' end
    local ref = (S.mode == 'leader') and rows[1] or rows[k - 1]
    local sec, laps = raceGap(ref, r, trackLen)
    if laps and laps >= 1 then return string.format('+%d LAP%s', laps, laps > 1 and 'S' or ''), 'lapped' end
    return fmtGap(sec), 'gap'
  end
  -- practica / qualy
  if not r.best then return 'NO TIME', 'none' end
  if k == 1 then return fmtLap(r.best), 'leader' end
  local ref = (S.mode == 'leader') and rows[1] or rows[k - 1]
  return fmtGap((r.best - ref.best) / 1000), 'gap'
end

-- ============================================================================
-- DIBUJO
-- ============================================================================
local function rgb(c, a) return rgbm(c[1], c[2], c[3], a or 1) end

local COL = {
  bg       = function() return rgbm(0.04, 0.04, 0.06, 0.88) end,
  bgHead   = function() return rgbm(0.10, 0.10, 0.15, 0.95) end,
  bgFocus  = function() return rgbm(0.22, 0.22, 0.32, 0.95) end,
  white    = function() return rgbm(1, 1, 1, 1) end,
  dim      = function() return rgbm(0.65, 0.65, 0.70, 1) end,
  pit      = function() return rgbm(0.25, 0.85, 1.00, 1) end,
  purple   = function() return rgbm(0.75, 0.35, 1.00, 1) end,
  green    = function() return rgbm(0.10, 0.90, 0.35, 1) end,
  yellow   = function() return rgbm(1.00, 0.85, 0.05, 1) end,
  throttle = function() return rgbm(0.10, 0.90, 0.30, 1) end,
  brake    = function() return rgbm(0.95, 0.12, 0.12, 1) end,
}

local function sectorColor(name)
  if name == 'purple' then return COL.purple() end
  if name == 'green' then return COL.green() end
  if name == 'yellow' then return COL.yellow() end
  return COL.dim()
end

local function drawText(str, size, x, y, col)
  ui.dwriteDrawText(str, size, vec2(x, y), col)
end

local function drawTextRight(str, size, xr, y, col)
  local w = 0
  local m = try(ui.measureDWriteText, str, size)
  if m and m.x then w = m.x else w = #str * size * 0.55 end
  ui.dwriteDrawText(str, size, vec2(xr - w, y), col)
end

local function drawTextCenter(str, size, xc, y, col)
  local w = 0
  local m = try(ui.measureDWriteText, str, size)
  if m and m.x then w = m.x else w = #str * size * 0.55 end
  ui.dwriteDrawText(str, size, vec2(xc - w / 2, y), col)
end

local function drawTyre(cx, cy, r, tyre)
  ui.drawCircleFilled(vec2(cx, cy), r, rgbm(0.02, 0.02, 0.03, 1), 24)
  ui.drawCircle(vec2(cx, cy), r - 1.5, rgb(tyre.color), 24, math.max(2, r * 0.28))
  drawTextCenter(tyre.label, r * 1.15, cx, cy - r * 0.72, COL.white())
end

local function drawTower(rows, kind, sim, laps, timed, sess, u, focusIdx, trackLen)
  local x0, y0 = 24 * u, 60 * u
  local W, headH, rowH = 410 * u, 38 * u, 30 * u
  local count = math.min(#rows, CONFIG.maxRows)
  S.hit = {}   -- rectangulos clicables de esta frame (lo usa handleFocusInput)

  -- cabecera
  ui.drawRectFilled(vec2(x0, y0), vec2(x0 + W, y0 + headH), COL.bgHead(), 4 * u, 3)
  local title
  if kind == 'race' then
    if laps and laps > 0 and not timed then
      local lead = rows[1] and rows[1].cs.total or 0
      local lap = math.max(1, math.floor(lead) + 1)
      if lap > laps then title = 'FINISH' else title = string.format('LAP %d/%d', lap, laps) end
    else
      title = 'RACE  ' .. fmtClock(timeLeftMs(sim, sess))
    end
  elseif kind == 'qualy' then
    title = 'QUALY  ' .. fmtClock(timeLeftMs(sim, sess))
  else
    title = 'PRACTICE  ' .. fmtClock(timeLeftMs(sim, sess))
  end
  drawText(title, 21 * u, x0 + 12 * u, y0 + 6 * u, COL.white())
  drawTextRight(S.mode == 'leader' and 'LEADER' or 'INTERVAL', 13 * u, x0 + W - 12 * u, y0 + 12 * u, COL.dim())

  -- cuerpo
  local by = y0 + headH
  ui.drawRectFilled(vec2(x0, by), vec2(x0 + W, by + rowH * count), COL.bg(), 4 * u, 12)
  for k = 1, count do
    local r = rows[k]
    local y = by + (k - 1) * rowH
    S.hit[#S.hit + 1] = { x1 = x0, y1 = y, x2 = x0 + W, y2 = y + rowH, idx = r.i }
    if r.i == focusIdx then
      ui.drawRectFilled(vec2(x0, y), vec2(x0 + W, y + rowH), COL.bgFocus())
    elseif S.hover == r.i then
      ui.drawRectFilled(vec2(x0, y), vec2(x0 + W, y + rowH), rgbm(1, 1, 1, 0.10))
    end
    -- posicion
    ui.drawRectFilled(vec2(x0 + 4 * u, y + 3 * u), vec2(x0 + 34 * u, y + rowH - 3 * u), rgbm(0.95, 0.95, 0.95, 1), 3 * u)
    drawTextCenter(tostring(k), 17 * u, x0 + 19 * u, y + 5 * u, rgbm(0.05, 0.05, 0.08, 1))
    -- color de equipo
    ui.drawRectFilled(vec2(x0 + 38 * u, y + 3 * u), vec2(x0 + 42 * u, y + rowH - 3 * u), rgb(r.info.color))
    -- escudo
    if r.info.badge then
      pcall(ui.drawImage, r.info.badge, vec2(x0 + 47 * u, y + 3 * u), vec2(x0 + 47 * u + (rowH - 6 * u), y + rowH - 3 * u),
        rgbm(1, 1, 1, 1), vec2(0, 0), vec2(1, 1), true)
    end
    -- nombre
    drawText(r.info.label, 17 * u, x0 + 82 * u, y + 5 * u, COL.white())
    -- gap
    local txt, st = gapText(rows, k, kind, trackLen)
    local gcol = COL.white()
    if st == 'pit' then gcol = COL.pit()
    elseif st == 'none' or st == 'lapped' then gcol = COL.dim() end
    drawTextRight(txt, 16 * u, x0 + W - 46 * u, y + 6 * u, gcol)
    -- neumatico
    drawTyre(x0 + W - 22 * u, y + rowH / 2, 10 * u, tyreOf(r.i, r.car))
    if k < count then
      ui.drawLine(vec2(x0 + 4 * u, y + rowH), vec2(x0 + W - 4 * u, y + rowH), rgbm(1, 1, 1, 0.06), 1)
    end
  end
end

local function textWidth(str, size)
  local m = try(ui.measureDWriteText, str, size)
  if m and m.x then return m.x end
  return #str * size * 0.55
end

-- Quita el ultimo caracter UTF-8 solo si ha quedado cortado a medias
local function trimBrokenUtf8(s)
  local i, cont = #s, 0
  while i > 0 and s:byte(i) >= 0x80 and s:byte(i) < 0xC0 do i = i - 1 cont = cont + 1 end
  if i == 0 then return '' end
  local b = s:byte(i)
  if b < 0x80 then return s end
  local need = (b >= 0xF0 and 3) or (b >= 0xE0 and 2) or 1
  if cont >= need then return s end
  return s:sub(1, i - 1)
end

-- Cabecera del panel: piloto, a su derecha (separado) el nombre visual del coche y el equipo,
-- y el neumatico a la derecha del todo. `reserve` = espacio a la derecha que no se puede pisar.
local function panelHeader(x, y, w, u, row, reserve)
  local tyre = tyreOf(row.i, row.car)
  local labelSize = 20 * u
  local lw = textWidth(row.info.label, labelSize)
  drawText(row.info.label, labelSize, x + 14 * u, y + 6 * u, COL.white())

  local sub = row.info.carName or ''
  if row.info.skinTeam and row.info.skinTeam ~= '' and row.info.skinTeam ~= sub then
    sub = sub .. '  ·  ' .. row.info.skinTeam
  end
  local sx = x + 14 * u + lw + 18 * u
  local maxW = (x + w - (reserve or 60 * u)) - sx
  if textWidth(sub, 13 * u) > maxW then
    -- recortar reservando sitio para los puntos suspensivos
    while #sub > 1 and textWidth(sub .. '...', 13 * u) > maxW do
      sub = trimBrokenUtf8(sub:sub(1, #sub - 1))
    end
    sub = sub .. '...'
  end
  if sub ~= '' and maxW > 20 * u then drawText(sub, 13 * u, sx, y + 12 * u, COL.dim()) end
  drawTyre(x + w - 24 * u, y + 20 * u, 11 * u, tyre)
end

local function fmtDelta(ms)
  return string.format('%+.3f', ms / 1000)
end

local drawMap   -- definida mas abajo

-- Panel de Practica / Qualy: mapa, S1..Sn, TOTAL y DELTA. Todo cuenta en vivo desde el paso por meta.
local function drawTimingPanel(row, rows, u, W, H)
  local cs, car = row.cs, row.car
  local n = #S.secStart
  local boxes = n + 2                                   -- sectores + TOTAL + DELTA
  local mapW = 190 * u
  local boxW, gap = 118 * u, 10 * u
  local w = mapW + boxes * boxW + (boxes + 1) * gap
  local h = 170 * u
  local x, y = (W - w) / 2, H - h - 28 * u
  ui.drawRectFilled(vec2(x, y), vec2(x + w, y + h), COL.bg(), 6 * u)

  -- cabecera derecha: LAST (color de la ultima vuelta) y BEST
  local right = x + w - 56 * u
  local leftEdge = right
  if cs.pbLap then
    local t = 'BEST ' .. fmtLap(cs.pbLap)
    drawTextRight(t, 13 * u, right, y + 11 * u, COL.dim())
    leftEdge = right - textWidth(t, 13 * u) - 18 * u
  end
  local last = cs.last
  if last and (last.lapMs or last.lapMsInvalid) then
    local t = 'LAST ' .. fmtLap(last.lapMs or last.lapMsInvalid)
    drawTextRight(t, 13 * u, leftEdge, y + 11 * u, last.lapMs and sectorColor(last.lapCol) or COL.dim())
    leftEdge = leftEdge - textWidth(t, 13 * u) - 18 * u
  end
  panelHeader(x, y, w, u, row, (x + w) - leftEdge + 10 * u)

  drawMap(x + 8 * u, y + 44 * u, mapW - 16 * u, h - 52 * u, rows, row.i, u)

  local by, bh = y + 46 * u, 100 * u
  for k = 1, boxes do
    local bx = x + mapW + gap + (k - 1) * (boxW + gap)
    ui.drawRectFilled(vec2(bx, by), vec2(bx + boxW, by + bh), rgbm(0.10, 0.10, 0.14, 1), 4 * u)
    local label, txt, col, bar
    if k <= n then
      label = 'S' .. k
      local v = cs.cur.s[k]
      if v then
        txt, col = fmtSector(v), sectorColor(cs.cur.col[k])
        bar = true
      elseif v == nil and cs.secIdx == k and cs.secStartT then
        -- sector en curso: cronometro en vivo (el S1 arranca al pasar por meta)
        txt = fmtSector((S.now - cs.secStartT) * 1000)
        col = cs.secPit and COL.dim() or COL.white()
      else
        txt, col = '--.---', COL.dim()
      end
    elseif k == n + 1 then
      label = 'TOTAL'
      txt = fmtLap(lapMs(cs, car))
      col = cs.cur.pit and COL.dim() or COL.white()
    else
      label = 'DELTA'
      local d = deltaMs(cs, car)
      if d then
        txt = fmtDelta(d)
        col = d <= 0 and COL.green() or COL.brake()
        bar = true
      else
        txt, col = '--', COL.dim()
      end
    end
    drawText(label, 12 * u, bx + 8 * u, by + 6 * u, COL.dim())
    drawTextCenter(txt, 27 * u, bx + boxW / 2, by + 38 * u, col)
    if bar then
      ui.drawRectFilled(vec2(bx, by + bh - 4 * u), vec2(bx + boxW, by + bh), col, 2 * u)
    end
  end
end

drawMap = function(x, y, w, h, rows, focusIdx, u)
  if S.map == nil then S.map = loadMap() end
  local m = S.map
  if not m then return end
  local k = math.min(w / m.w, h / m.h)
  local ox = x + (w - m.w * k) / 2
  local oy = y + (h - m.h * k) / 2
  pcall(ui.drawImage, m.img, vec2(ox, oy), vec2(ox + m.w * k, oy + m.h * k), rgbm(1, 1, 1, 0.85))
  for _, r in ipairs(rows) do
    local p = r.car.position
    if p then
      local px = ox + ((p.x + m.xo) / m.scale) * k
      local py = oy + ((p.z + m.zo) / m.scale) * k
      local focus = r.i == focusIdx
      local rad = (focus and 6 or 3.5) * u
      if focus then ui.drawCircleFilled(vec2(px, py), rad + 2 * u, rgbm(1, 1, 1, 1), 16) end
      ui.drawCircleFilled(vec2(px, py), rad, rgb(r.info.color), 16)
    end
  end
end

local function bar(x, y, w, h, v, col)
  ui.drawRectFilled(vec2(x, y), vec2(x + w, y + h), rgbm(0.12, 0.12, 0.16, 1), 3)
  v = math.max(0, math.min(1, v or 0))
  if v > 0 then
    ui.drawRectFilled(vec2(x, y + h * (1 - v)), vec2(x + w, y + h), col, 3)
  end
end

local function gearText(g)
  if g == nil then return 'N' end
  if g < 0 then return 'R' end
  if g == 0 then return 'N' end
  return tostring(math.floor(g))
end

local function drawTelemetryPanel(row, rows, u, W, H, withMap)
  local mapW = withMap and 190 * u or 0
  local w = mapW + 440 * u
  local h = 170 * u
  local x, y = (W - w) / 2, H - h - 28 * u
  ui.drawRectFilled(vec2(x, y), vec2(x + w, y + h), COL.bg(), 6 * u)
  panelHeader(x, y, w, u, row)
  local car = row.car
  local cx = x
  if withMap then
    drawMap(x + 8 * u, y + 44 * u, mapW - 16 * u, h - 52 * u, rows, row.i, u)
    cx = x + mapW
  end
  -- barras
  local bh = h - 62 * u
  local bw = 26 * u
  local by = y + 46 * u
  bar(cx + 26 * u, by, bw, bh, car.gas, COL.throttle())
  bar(cx + 26 * u + bw + 12 * u, by, bw, bh, car.brake, COL.brake())
  drawTextCenter('THR', 11 * u, cx + 26 * u + bw / 2, by + bh + 2 * u, COL.dim())
  drawTextCenter('BRK', 11 * u, cx + 26 * u + bw * 1.5 + 12 * u, by + bh + 2 * u, COL.dim())
  -- marcha
  local gx = cx + 170 * u
  drawTextCenter(gearText(car.gear), 78 * u, gx, y + 46 * u, COL.white())
  drawTextCenter('GEAR', 12 * u, gx, y + h - 22 * u, COL.dim())
  -- velocidad
  local sx = cx + 330 * u
  drawTextCenter(tostring(math.floor((car.speedKmh or 0) + 0.5)), 58 * u, sx, y + 52 * u, COL.white())
  drawTextCenter('KM/H', 13 * u, sx, y + h - 36 * u, COL.dim())
end

local FLAG_FILL = {
  green     = { { 0.05, 0.50, 0.22, 0.95 }, { 1, 1, 1 } },
  yellow    = { { 1.00, 0.82, 0.00, 0.98 }, { 0.05, 0.05, 0.05 } },
  red       = { { 0.85, 0.07, 0.07, 0.98 }, { 1, 1, 1 } },
  orange    = { { 1.00, 0.50, 0.00, 0.98 }, { 0.05, 0.05, 0.05 } },
  white     = { { 0.94, 0.94, 0.94, 0.98 }, { 0.05, 0.05, 0.05 } },
  chequered = { { 0.05, 0.05, 0.05, 0.98 }, { 1, 1, 1 } },
}

local function drawTrackStatus(u, W)
  local T = S.track
  if not T then return end
  local bw, bh = 320 * u, 38 * u
  local x, y = (W - bw) / 2, CONFIG.statusTop * u
  local fill = FLAG_FILL[T.color] or FLAG_FILL.green
  ui.drawRectFilled(vec2(x, y), vec2(x + bw, y + bh), rgbm(fill[1][1], fill[1][2], fill[1][3], fill[1][4]), 5 * u)
  if T.color == 'chequered' then
    -- cuadros a los lados y placa negra al centro para el texto
    local sq = bh / 3
    local cols = math.floor(bw / sq)
    for r = 0, 2 do
      for c = 0, cols - 1 do
        if (r + c) % 2 == 0 then
          ui.drawRectFilled(vec2(x + c * sq, y + r * sq), vec2(x + (c + 1) * sq, y + (r + 1) * sq), rgbm(1, 1, 1, 1))
        end
      end
    end
    ui.drawRectFilled(vec2(x + bw * 0.18, y + 3 * u), vec2(x + bw * 0.82, y + bh - 3 * u), rgbm(0.05, 0.05, 0.05, 1), 4 * u)
  end
  drawTextCenter(T.text, 19 * u, x + bw / 2, y + 7 * u, rgbm(fill[2][1], fill[2][2], fill[2][3], 1))

  -- tira de sectores: todos del color de la bandera si afecta a toda la pista (T.all),
  -- si no, amarillo solo en los sectores con un coche parado
  local ALL = {
    yellow = rgbm(1.00, 0.82, 0.00, 1),
    red    = rgbm(0.85, 0.07, 0.07, 1),
    orange = rgbm(1.00, 0.50, 0.00, 1),
  }
  local n = #S.secStart
  local gap = 4 * u
  local sw = (bw - gap * (n - 1)) / n
  for k = 1, n do
    local sx = x + (k - 1) * (sw + gap)
    local hot = T.hz and T.hz[k]
    local c = hot and rgbm(1.00, 0.82, 0.00, 1) or rgbm(0.10, 0.55, 0.25, 0.9)
    if T.all and ALL[T.all] then c = ALL[T.all] end
    ui.drawRectFilled(vec2(sx, y + bh + 4 * u), vec2(sx + sw, y + bh + 9 * u), c, 2 * u)
  end

  -- Safety Car: activo / en boxes (solo si hay un coche de seguridad conectado)
  if T.sc and T.sc.present then
    local cw, ch = 150 * u, 22 * u
    local cx, cy = (W - cw) / 2, y + bh + 14 * u
    local on = T.sc.active
    ui.drawRectFilled(vec2(cx, cy), vec2(cx + cw, cy + ch),
      on and rgbm(1.00, 0.50, 0.00, 0.98) or rgbm(0.10, 0.10, 0.15, 0.9), 4 * u)
    drawTextCenter(on and 'SC  ON TRACK' or 'SC  IN PIT', 13 * u, W / 2, cy + 3 * u,
      on and rgbm(0.05, 0.05, 0.05, 1) or COL.dim())
  end
end

-- Cambiar el coche seguido (camara/HUD). Usa ac.focusCar con el indice de coche del cliente.
local function focusCarIndex(idx)
  if not ac.focusCar then
    logOnce('ac.focusCar no esta disponible en esta version de CSP')
    return
  end
  local ok, err = pcall(ac.focusCar, idx)
  if not ok then logOnce('ac.focusCar fallo: ' .. tostring(err)) end
end

local function keyIndex(name)
  local ki = ui.KeyIndex
  local k = ki and name and ki[name]
  if k == nil and name then logOnce('ui.KeyIndex no tiene la tecla ' .. tostring(name)) end
  return k
end

-- Clic en una fila de la torre y teclas anterior/siguiente.
local function handleFocusInput(rows, focusIdx)
  S.hover = nil
  if CONFIG.clickToFocus then
    local mp = try(ui.mousePos)
    if mp and mp.x and mp.x >= 0 and mp.y >= 0 then
      for _, h in ipairs(S.hit or {}) do
        if mp.x >= h.x1 and mp.x <= h.x2 and mp.y >= h.y1 and mp.y <= h.y2 then
          S.hover = h.idx
          if ui.mouseClicked(0) and h.idx ~= focusIdx then focusCarIndex(h.idx) end
          break
        end
      end
    end
  end

  local dir = 0
  local kp, kn = keyIndex(CONFIG.keyPrevCar), keyIndex(CONFIG.keyNextCar)
  if kp and ui.keyboardButtonPressed(kp, false) then dir = -1 end
  if kn and ui.keyboardButtonPressed(kn, false) then dir = 1 end
  if dir ~= 0 and #rows > 0 then
    local cur = 0
    for k, r in ipairs(rows) do if r.i == focusIdx then cur = k end end
    local nxt = cur + dir
    if cur == 0 then nxt = (dir > 0) and 1 or #rows end
    if nxt < 1 then nxt = #rows elseif nxt > #rows then nxt = 1 end
    focusCarIndex(rows[nxt].i)
  end
end

local function drawHud()
  local sim = ac.getSim()
  if not sim or not S.secStart then return end
  local screen = ui.windowSize()
  local W, H = screen.x, screen.y
  local u = math.max(0.5, H / 1080)
  local kind, laps, timed, sess = sessionInfo(sim)
  local rows = buildRows(sim, kind)
  if #rows == 0 then return end
  local trackLen = (sim.trackLengthM and sim.trackLengthM > 0) and sim.trackLengthM or 5000
  local focusIdx = sim.focusedCar
  drawTrackStatus(u, W)
  drawTower(rows, kind, sim, laps, timed, sess, u, focusIdx, trackLen)
  handleFocusInput(rows, focusIdx)

  local focusRow
  for _, r in ipairs(rows) do if r.i == focusIdx then focusRow = r end end
  if not focusRow then return end
  if kind == 'race' then
    drawTelemetryPanel(focusRow, rows, u, W, H, true)
  else
    drawTimingPanel(focusRow, rows, u, W, H)
  end
end

-- Panel de comprobacion (CONFIG.debugSlots): tu slot y el slot de cada coche conectado.
local function drawSlotDebug()
  local sim = ac.getSim()
  if not sim then return end
  local me = ac.getCar(0)
  local lines = { 'SLOT DEBUG  -  tu slot: ' .. tostring(me and slotOf(me, 0)) }
  for i = 0, (sim.carsCount or 0) - 1 do
    local car = ac.getCar(i)
    if car and car.isConnected then
      lines[#lines + 1] = string.format('CAR_%s   %s', tostring(slotOf(car, i)), tostring(try(ac.getDriverName, i) or '?'))
    end
  end
  local x, y = ui.windowSize().x - 340, 20
  ui.drawRectFilled(vec2(x - 8, y - 6), vec2(x + 332, y + #lines * 20 + 6), rgbm(0, 0, 0, 0.8))
  for k, t in ipairs(lines) do
    ui.dwriteDrawText(t, 15, vec2(x, y + (k - 1) * 20), rgbm(1, 1, 1, 1))
  end
end

function script.drawUI(dt)
  local ok, err = pcall(function()
    local k1 = ui.KeyIndex and ui.KeyIndex[CONFIG.keyToggleMode]
    local k2 = ui.KeyIndex and ui.KeyIndex[CONFIG.keyToggleHud]
    if k1 and ui.keyboardButtonPressed(k1, false) then
      S.mode = (S.mode == 'interval') and 'leader' or 'interval'
    end
    if k2 and ui.keyboardButtonPressed(k2, false) then S.hud = not S.hud end
    if CONFIG.debugSlots then pcall(drawSlotDebug) end
    if not S.hud or not isHudClient() then return end
    local fontPushed = pcall(ui.pushDWriteFont, 'Segoe UI;Weight=Bold')
    local ok2, err2 = pcall(drawHud)
    if fontPushed then pcall(ui.popDWriteFont) end
    if not ok2 then error(err2, 0) end
  end)
  if not ok then logOnce('drawUI: ' .. tostring(err)) end
end
