--[[
    pr_3dsound — client.lua  v4.0
    ─────────────────────────────────────────────────────────────────────────────
    EXPORTS client-side (use em outros scripts client-side):
      exports['pr_3dsound']:SoundExists(uniqueId)   → bool
      exports['pr_3dsound']:IsPlaying(uniqueId)     → bool
      exports['pr_3dsound']:IsPaused(uniqueId)      → bool
      exports['pr_3dsound']:GetInfo(uniqueId)       → table | nil
      exports['pr_3dsound']:GetAllSounds()          → table
      exports['pr_3dsound']:PlayLocal(file, volume, radius, loop)  → uniqueId
      exports['pr_3dsound']:PlayUrl2D(url, volume, loop)           → uniqueId
      exports['pr_3dsound']:PlayUrl3D(url, volume, radius, loop)   → uniqueId
      exports['pr_3dsound']:PlayAttached(url, volume, entityNetId, radius, loop) → uniqueId
      exports['pr_3dsound']:Stop(uniqueId)
      exports['pr_3dsound']:Pause(uniqueId)
      exports['pr_3dsound']:Resume(uniqueId)
      exports['pr_3dsound']:SetVolume(uniqueId, volume)
      exports['pr_3dsound']:SetDistance(uniqueId, dist)
      exports['pr_3dsound']:FadeIn(uniqueId, duration, targetVolume)
      exports['pr_3dsound']:FadeOut(uniqueId, duration)
]]

local Sounds         = {}
local emittersActive = 0

-- =============================================
--  CONFIG
-- =============================================

local CFG = {
    -- ── Raycast ──────────────────────────────────────────────────────────
    RAYCAST_ENABLED     = true,
    RAYCAST_INTERVAL_MS = 400,
    RAYCAST_SMOOTH      = 0.72,
    RAYCAST_FLAGS       = 1 + 2 + 8,   -- mundo + veículos + objetos
    WALL_MULT           = 0.20,         -- parede grossa
    WALL_THIN_MULT      = 0.50,         -- parede fina / veículo alheio

    -- ── Veículo da fonte (som dentro do carro, player ouvindo de fora) ───
    VEHCLOSED_MULT      = 0.15,         -- todas portas/janelas fechadas
    VEHWINDOW_MULT      = 0.35,         -- janela quebrada/aberta (sem porta aberta)
    VEHOPEN1_MULT       = 0.60,         -- 1 porta aberta
    VEHOPEN2_MULT       = 0.70,         -- 2 portas abertas
    -- 3+ portas → 1.0 (definido no código)

    -- ── Veículo do player (player dentro ouvindo sons externos) ──────────
    VEHCLOSED_PLAYER_MULT  = 0.15,
    VEHWINDOW_PLAYER_MULT  = 0.50,
    VEHOPEN_PLAYER_MULT    = 0.85,

    -- ── Portal MLO ────────────────────────────────────────────────────────
    MLO_ENABLED         = true,
    MLO_PORTAL_MULT     = 0.55,
}

-- =============================================
--  UTILITÁRIOS
-- =============================================

local function rot_to_direction(rot)
    local rZ = rot.z * 0.0174532924
    local rX = rot.x * 0.0174532924
    local num = math.abs(math.cos(rX))
    return { x = (-math.sin(rZ)) * num, y = (math.cos(rZ)) * num, z = math.sin(rX) }
end

local function clamp(v, lo, hi)
    return math.max(lo, math.min(hi, v))
end

local function calcDistanceVolume(s, coords)
    local dist = #(coords - vector3(s.pos.x, s.pos.y, s.pos.z))
    local mult = (s.maxVol or s.vol) / (s.dist or 30.0)
    return clamp((s.maxVol or s.vol) - (dist * mult), 0.0, 1.0)
end

local function snapshotSoundKeys()
    local keys = {}
    local lastKey = nil
    while true do
        local ok, key = pcall(next, Sounds, lastKey)
        if not ok or key == nil then break end
        keys[#keys + 1] = key
        lastKey = key
    end
    return keys
end

local function findSoundByUniqueId(uniqueId)
    local keys = snapshotSoundKeys()
    for i = 1, #keys do
        local k = keys[i]
        local v = Sounds[k]
        if v and v.uniqueId == uniqueId then
            return k, v
        end
    end
    return nil, nil
end

local function getHeadCoords(ped)
    local c = GetEntityCoords(ped)
    return vector3(c.x, c.y, c.z + 0.7)
end

local function genId()
    return ('snd_%d_%d'):format(GetGameTimer() % 99999, math.random(100, 999))
end

-- =============================================
--  RAYCAST EM DOIS FRAMES
-- =============================================

local rayHandles = {}

local function launchRay(k, headPos, soundPos, ignoreEnt)
    local handle = StartShapeTestLosProbe(
        headPos.x,  headPos.y,  headPos.z,
        soundPos.x, soundPos.y, soundPos.z,
        CFG.RAYCAST_FLAGS,
        ignoreEnt,
        4
    )
    rayHandles[k] = handle
end

local function resolveRay(k)
    local handle = rayHandles[k]
    if not handle then return 1.0 end
    rayHandles[k] = nil

    local retval, hit, _, _, entityHit = GetShapeTestResult(handle)
    if retval == 0 then return nil end
    if hit ~= 1   then return 1.0 end

    if entityHit and entityHit ~= 0 and GetEntityType(entityHit) == 2 then
        return CFG.WALL_THIN_MULT  -- veículo alheio
    end
    return CFG.WALL_MULT  -- parede/objeto sólido
end

-- =============================================
--  OCLUSÃO: VEÍCULO DA FONTE DE SOM
-- =============================================
--[[
    Som dentro do veículo, player fora ouvindo.
    Player DENTRO do mesmo veículo → 1.0 (sem oclusão).
    Player fora: depende de quantas portas estão abertas e estado das janelas.
]]

local function getSourceVehicleMult(soundEntry, ped)
    local vehicle = soundEntry.attachEntity
    if not vehicle or not DoesEntityExist(vehicle) then return 1.0 end
    if GetEntityType(vehicle) ~= 2 then return 1.0 end

    -- Player dentro do veículo da fonte → sem oclusão
    if GetVehiclePedIsIn(ped, false) == vehicle then return 1.0 end

    -- Conta portas abertas (índices 0-3; ignora capo=4 e traseira=5+)
    local openDoors = 0
    for i = 0, 3 do
        if GetVehicleDoorAngleRatio(vehicle, i) > 0.05 then
            openDoors = openDoors + 1
        end
    end

    if openDoors >= 3 then return 1.0          end
    if openDoors == 2  then return CFG.VEHOPEN2_MULT end
    if openDoors == 1  then return CFG.VEHOPEN1_MULT end

    -- Nenhuma porta aberta — verifica janelas
    for i = 0, 3 do
        if not IsVehicleWindowIntact(vehicle, i) then
            return CFG.VEHWINDOW_MULT  -- pelo menos 1 janela quebrada/aberta
        end
    end

    return CFG.VEHCLOSED_MULT  -- tudo fechado
end

-- =============================================
--  OCLUSÃO: VEÍCULO DO PLAYER (sons externos)
-- =============================================
--[[
    Player dentro do próprio veículo ouvindo sons externos.
    Verifica porta/janela do assento do player.
]]

local function getPlayerVehicleMult(ped)
    local vehicle = GetVehiclePedIsIn(ped, false)
    if vehicle == 0 then return 1.0 end

    local seatIndex = -1
    for s = -1, 3 do
        if GetPedInVehicleSeat(vehicle, s) == ped then
            seatIndex = s; break
        end
    end

    local doorIdx = seatIndex + 1
    if doorIdx < 0 or doorIdx >= 4 then return 1.0 end

    if GetVehicleDoorAngleRatio(vehicle, doorIdx) > 0.05 then
        return CFG.VEHOPEN_PLAYER_MULT
    end
    if IsVehicleWindowIntact(vehicle, doorIdx) then
        return CFG.VEHCLOSED_PLAYER_MULT
    end
    return CFG.VEHWINDOW_PLAYER_MULT
end

-- =============================================
--  OCLUSÃO MLO
-- =============================================

local function getMloMult(playerCoords, soundPos)
    if not CFG.MLO_ENABLED then return 1.0 end

    local ped            = PlayerPedId()
    local playerInterior = GetInteriorFromEntity(ped)
    local soundInterior  = GetInteriorAtCoords(soundPos.x, soundPos.y, soundPos.z)

    -- Player fora, som dentro → abafa
    if playerInterior == 0 and soundInterior ~= 0 then return CFG.MLO_PORTAL_MULT end
    -- Player dentro, som fora → abafa
    if playerInterior ~= 0 and soundInterior == 0 then return CFG.MLO_PORTAL_MULT end
    -- Ambos fora → raycast cuida
    if playerInterior == 0 and soundInterior == 0 then return 1.0 end
    -- Interiores diferentes → 2 paredes
    if playerInterior ~= soundInterior then return CFG.MLO_PORTAL_MULT * CFG.MLO_PORTAL_MULT end

    -- Mesmo interior: usa distância e portais como heurística
    local portalCount = GetInteriorPortalCount(playerInterior)
    if portalCount == 0 then return 1.0 end
    local dist = #(playerCoords - vector3(soundPos.x, soundPos.y, soundPos.z))
    if dist > 8.0 then return CFG.MLO_PORTAL_MULT end
    return 1.0
end

-- =============================================
--  MAIN LOOP 3D
-- =============================================

local function startLoop()
    if emittersActive > 0 then return end
    emittersActive = 1
    Citizen.CreateThread(function()
        local raycastTimer = {}
        local smoothedMult = {}

        while emittersActive > 0 do
            emittersActive = 0
            local ped           = PlayerPedId()
            local groundCoords  = GetEntityCoords(ped)
            local headCoords    = getHeadCoords(ped)
            local camDir        = rot_to_direction(GetGameplayCamRot(0))
            local now           = GetGameTimer()
            local playerVehicle = GetVehiclePedIsIn(ped, false)
            local playerVehMult = getPlayerVehicleMult(ped)

            -- ① Resolve rays do tick anterior
            local soundKeys = snapshotSoundKeys()
            for i = 1, #soundKeys do
                local k = soundKeys[i]
                local v = Sounds[k]
                if v and v.playing and not v.is2D then
                    local resolved = resolveRay(k)
                    if resolved ~= nil then
                        local prev = smoothedMult[k] or resolved
                        smoothedMult[k] = CFG.RAYCAST_SMOOTH * prev + (1 - CFG.RAYCAST_SMOOTH) * resolved
                    end
                end
            end

            -- ② Processa emitters
            soundKeys = snapshotSoundKeys()
            for i = 1, #soundKeys do
                local k = soundKeys[i]
                local v = Sounds[k]
                if v and v.playing and not v.is2D then
                    emittersActive = emittersActive + 1

                    -- Auto-update coords para attachs. Se o entity ainda nao estava
                    -- streamado quando o som chegou, tenta resolver o netId novamente.
                    if (not v.attachEntity or not DoesEntityExist(v.attachEntity)) and v.attachNetId then
                        local candidate = NetToEnt(v.attachNetId)
                        if candidate and candidate ~= 0 and DoesEntityExist(candidate) then
                            v.attachEntity = candidate
                        end
                    end

                    if v.attachEntity and DoesEntityExist(v.attachEntity) then
                        local ec
                        if v.attachOffset then
                            local off = v.attachOffset
                            ec = GetOffsetFromEntityInWorldCoords(v.attachEntity, off.x or 0.0, off.y or 0.0, off.z or 0.0)
                        else
                            ec = GetEntityCoords(v.attachEntity)
                        end
                        v.pos = { x = ec.x, y = ec.y, z = ec.z }
                        SendNUIMessage({ type = 'updateCoords', soundIndex = k, pos = v.pos })
                    end

                    -- ③ Ray: cabeça do player → fonte; ignora veículo do player
                    raycastTimer[k] = raycastTimer[k] or 0
                    if CFG.RAYCAST_ENABLED and (now - raycastTimer[k]) >= CFG.RAYCAST_INTERVAL_MS then
                        raycastTimer[k] = now
                        local ignoreEnt = playerVehicle ~= 0 and playerVehicle or ped
                        launchRay(k, headCoords, v.pos, ignoreEnt)
                    end

                    -- ④ Oclusão do veículo da fonte
                    local sourceVehicle      = v.attachEntity
                        and DoesEntityExist(v.attachEntity)
                        and GetEntityType(v.attachEntity) == 2
                        and v.attachEntity or nil
                    local playerInsideSource = sourceVehicle and (playerVehicle == sourceVehicle)

                    local sourceVehMult       = playerInsideSource and 1.0 or getSourceVehicleMult(v, ped)
                    local effectivePlayerMult = playerInsideSource and 1.0 or playerVehMult

                    -- ⑤ MLO
                    local mloMult = getMloMult(groundCoords, v.pos)

                    -- ⑥ Multiplicador final
                    local rayMult   = smoothedMult[k] or 1.0
                    local finalMult = clamp(rayMult * mloMult * sourceVehMult * effectivePlayerMult, 0.0, 1.0)

                    -- ⑦ Envia ao NUI
                    local distVol = calcDistanceVolume(v, groundCoords)

                    SendNUIMessage({
                        type       = 'updateVolume',
                        soundIndex = k,
                        volume     = distVol,
                        playerPos  = { x = groundCoords.x, y = groundCoords.y, z = groundCoords.z },
                        camDir     = camDir,
                    })
                    SendNUIMessage({
                        type          = 'setFilter',
                        soundIndex    = k,
                        freq          = math.floor(900 + (21150 * finalMult)),
                        occlusionMult = finalMult,
                    })
                end
            end

            Citizen.Wait(emittersActive > 8 and 100 or 250)
        end
    end)
end

-- =============================================
--  HELPERS INTERNOS DE PLAY (usados pelos exports client-side e net events)
-- =============================================

local function _registerSound(index, data)
    Sounds[index] = data
end

local function _doPlay(index, coords, soundName, volume, radius, uniqueId, loop, options)
    options = options or {}
    _registerSound(index, {
        uniqueId = uniqueId, pos = coords, vol = volume, maxVol = volume, dist = radius,
        playing = true, paused = false, is2D = false, isUrl = false, loop = loop or false,
        serverManaged = options.serverManaged == true, endToken = options.endToken,
    })
    local distVol = calcDistanceVolume(Sounds[index], GetEntityCoords(PlayerPedId()))
    SendNUIMessage({ type = 'play', soundIndex = index, file = soundName, volume = distVol, pos = coords, loop = loop or false, options = options })
    if options.startTime and options.startTime > 0 then
        SendNUIMessage({ type = 'setTimestamp', soundIndex = index, time = options.startTime })
    end
    startLoop()
    return uniqueId
end

local function _doPlayUrl(index, name, url, volume, loop, options)
    options = options or {}
    _registerSound(index, {
        uniqueId = name, vol = volume, maxVol = volume,
        playing = true, paused = false, is2D = true, isUrl = true, loop = loop or false, url = url,
        serverManaged = options.serverManaged == true, endToken = options.endToken,
    })
    SendNUIMessage({ type = 'playUrl', soundIndex = index, url = url, volume = volume, loop = loop or false, options = options })
    return name
end

local function _doPlayUrlPos(index, name, url, volume, coords, radius, loop, attachData, options)
    options = options or {}
    local entity, offset, attachNetId = nil, nil, nil
    if attachData then
        attachNetId = attachData.entityNetId
        entity = NetToEnt(attachNetId)
        offset = attachData.offset or { x = 0, y = 0, z = 0 }
        if not entity or entity == 0 or not DoesEntityExist(entity) then
            entity = nil -- o loop tenta resolver novamente quando o entity streamar
        end
    end
    _registerSound(index, {
        uniqueId = name, pos = coords, vol = volume, maxVol = volume, dist = radius,
        playing = true, paused = false, is2D = false, isUrl = true, loop = loop or false, url = url,
        attachEntity = entity, attachNetId = attachNetId, attachOffset = offset,
        serverManaged = options.serverManaged == true, endToken = options.endToken,
    })
    local distVol = calcDistanceVolume(Sounds[index], GetEntityCoords(PlayerPedId()))
    SendNUIMessage({ type = 'playUrlPos', soundIndex = index, url = url, volume = distVol, pos = coords, loop = loop or false, options = options })
    startLoop()
    return name
end

-- =============================================
--  NET EVENTS — recebe do server
-- =============================================

RegisterNetEvent('pr_3dsound:client:play')
AddEventHandler('pr_3dsound:client:play', function(index, coords, soundName, volume, radius, uniqueId, loop, attachData, options)
    _doPlay(index, coords, soundName, volume, radius, uniqueId, loop, options)
end)

RegisterNetEvent('pr_3dsound:client:playUrl')
AddEventHandler('pr_3dsound:client:playUrl', function(index, name, url, volume, loop, options)
    _doPlayUrl(index, name, url, volume, loop, options)
end)

RegisterNetEvent('pr_3dsound:client:playUrlPos')
AddEventHandler('pr_3dsound:client:playUrlPos', function(index, name, url, volume, coords, radius, loop, options, attachData)
    _doPlayUrlPos(index, name, url, volume, coords, radius, loop, attachData, options)
end)

RegisterNetEvent('pr_3dsound:client:attachToEntity')
AddEventHandler('pr_3dsound:client:attachToEntity', function(index, entityNetId, offset)
    if not Sounds[index] then return end

    local function tryAttach(attempts)
        if not Sounds[index] then return end
        local entity = NetToEnt(entityNetId)
        if DoesEntityExist(entity) then
            Sounds[index].attachEntity = entity
            Sounds[index].attachNetId = entityNetId
            Sounds[index].attachOffset = offset or { x = 0, y = 0, z = 0 }
        elseif attempts > 0 then
            Citizen.SetTimeout(500, function() tryAttach(attempts - 1) end)
        else
            print('[pr_3dsound] WARN: entity netId=' .. tostring(entityNetId) .. ' nao encontrada apos retries')
        end
    end

    tryAttach(10) -- tenta por 5s (10x a cada 500ms)
end)

RegisterNetEvent('pr_3dsound:client:detachEntity')
AddEventHandler('pr_3dsound:client:detachEntity', function(index)
    if not Sounds[index] then return end
    Sounds[index].attachEntity = nil
    Sounds[index].attachNetId = nil
    Sounds[index].attachOffset = nil
end)

RegisterNetEvent('pr_3dsound:client:pause')
AddEventHandler('pr_3dsound:client:pause', function(index)
    if not Sounds[index] then return end
    Sounds[index].playing = false; Sounds[index].paused = true
    SendNUIMessage({ type = 'pause', soundIndex = index })
end)

RegisterNetEvent('pr_3dsound:client:resume')
AddEventHandler('pr_3dsound:client:resume', function(index)
    if not Sounds[index] then return end
    Sounds[index].playing = true; Sounds[index].paused = false
    SendNUIMessage({ type = 'resume', soundIndex = index })
    startLoop()
end)

RegisterNetEvent('pr_3dsound:client:stop')
AddEventHandler('pr_3dsound:client:stop', function(index)
    if not Sounds[index] then return end
    Sounds[index].playing = false
    SendNUIMessage({ type = 'stop', soundIndex = index })
    Sounds[index] = nil
end)

RegisterNetEvent('pr_3dsound:client:updateCoords')
AddEventHandler('pr_3dsound:client:updateCoords', function(index, coords)
    if not Sounds[index] then return end
    Sounds[index].pos = coords
    SendNUIMessage({ type = 'updateCoords', soundIndex = index, pos = coords })
end)

RegisterNetEvent('pr_3dsound:client:setVolume')
AddEventHandler('pr_3dsound:client:setVolume', function(index, volume)
    if not Sounds[index] then return end
    Sounds[index].vol = clamp(volume, 0.0, 1.0)
    Sounds[index].maxVol = Sounds[index].vol
    SendNUIMessage({ type = 'setVolume', soundIndex = index, volume = Sounds[index].vol })
end)

RegisterNetEvent('pr_3dsound:client:setVolumeMax')
AddEventHandler('pr_3dsound:client:setVolumeMax', function(index, volume)
    if not Sounds[index] then return end
    Sounds[index].maxVol = clamp(volume, 0.0, 1.0)
    SendNUIMessage({ type = 'setVolumeMax', soundIndex = index, volume = Sounds[index].maxVol })
end)

RegisterNetEvent('pr_3dsound:client:setDistance')
AddEventHandler('pr_3dsound:client:setDistance', function(index, dist)
    if not Sounds[index] then return end
    Sounds[index].dist = dist
    SendNUIMessage({ type = 'setDistance', soundIndex = index, distance = dist })
end)

RegisterNetEvent('pr_3dsound:client:setLoop')
AddEventHandler('pr_3dsound:client:setLoop', function(index, loopVal)
    if not Sounds[index] then return end
    Sounds[index].loop = loopVal
    SendNUIMessage({ type = 'setLoop', soundIndex = index, loop = loopVal })
end)

RegisterNetEvent('pr_3dsound:client:setTimestamp')
AddEventHandler('pr_3dsound:client:setTimestamp', function(index, time)
    if not Sounds[index] then return end
    SendNUIMessage({ type = 'setTimestamp', soundIndex = index, time = time })
end)

RegisterNetEvent('pr_3dsound:client:fadeIn')
AddEventHandler('pr_3dsound:client:fadeIn', function(index, duration, targetVolume)
    if not Sounds[index] then return end
    SendNUIMessage({ type = 'fadeIn', soundIndex = index, duration = duration, volume = targetVolume })
end)

RegisterNetEvent('pr_3dsound:client:fadeOut')
AddEventHandler('pr_3dsound:client:fadeOut', function(index, duration)
    if not Sounds[index] then return end
    SendNUIMessage({ type = 'fadeOut', soundIndex = index, duration = duration })
end)

-- =============================================
--  CALLBACKS NUI → CLIENT
-- =============================================

RegisterNUICallback('soundEnded', function(data, cb)
    local index = data.index
    local sound = Sounds[index]
    if sound then
        if sound.serverManaged and sound.endToken and sound.uniqueId then
            TriggerServerEvent('pr_3dsound:server:soundEnded', sound.uniqueId, sound.endToken)
        end
        sound.playing = false
        Sounds[index] = nil
    end
    cb('ok')
end)

RegisterNUICallback('getInfo', function(data, cb)
    if not Sounds[data.index] then cb(nil); return end
    cb(Sounds[data.index])
end)

-- =============================================
--  EXPORTS CLIENT-SIDE
-- =============================================

-- Estado
exports('SoundExists', function(uniqueId)
    return findSoundByUniqueId(uniqueId) ~= nil
end)

exports('IsPlaying', function(uniqueId)
    local _, v = findSoundByUniqueId(uniqueId)
    if v then return v.playing end
    return false
end)

exports('IsPaused', function(uniqueId)
    local _, v = findSoundByUniqueId(uniqueId)
    if v then return v.paused end
    return false
end)

exports('GetInfo', function(uniqueId)
    local _, v = findSoundByUniqueId(uniqueId)
    return v
end)

exports('GetAllSounds', function()
    local result = {}
    local keys = snapshotSoundKeys()
    for i = 1, #keys do
        local v = Sounds[keys[i]]
        if v then result[v.uniqueId] = v end
    end
    return result
end)

-- Play client-side (não passa pelo server — só afeta o player local)
exports('PlayLocal', function(file, volume, radius, loop)
    local ped    = PlayerPedId()
    local coords = GetEntityCoords(ped)
    local id     = genId()
    local index  = 1
    while Sounds[index] do index = index + 1 end
    _doPlay(index, coords, file, volume or 1.0, radius or 30.0, id, loop or false)
    return id
end)

exports('PlayLocal2D', function(file, volume, loop)
    local id    = genId()
    local index = 1
    while Sounds[index] do index = index + 1 end
    _registerSound(index, {
        uniqueId = id, vol = volume or 1.0, maxVol = volume or 1.0,
        playing = true, paused = false, is2D = true, isUrl = false, loop = loop or false,
    })
    SendNUIMessage({ type = 'play', soundIndex = index, file = file, volume = volume or 1.0, is2D = true, loop = loop or false })
    return id
end)

exports('PlayUrl2D', function(url, volume, loop)
    local id    = genId()
    local index = 1
    while Sounds[index] do index = index + 1 end
    _doPlayUrl(index, id, url, volume or 1.0, loop or false, nil)
    return id
end)

exports('PlayUrl3D', function(url, volume, radius, loop)
    local ped    = PlayerPedId()
    local coords = GetEntityCoords(ped)
    local id     = genId()
    local index  = 1
    while Sounds[index] do index = index + 1 end
    _doPlayUrlPos(index, id, url, volume or 1.0, coords, radius or 50.0, loop or false, nil, nil)
    return id
end)

exports('PlayAttached', function(url, volume, entityNetId, radius, loop)
    local entity = NetToEnt(entityNetId)
    local coords = DoesEntityExist(entity) and GetEntityCoords(entity) or GetEntityCoords(PlayerPedId())
    local id     = genId()
    local index  = 1
    while Sounds[index] do index = index + 1 end
    local attachData = { entityNetId = entityNetId, offset = { x = 0, y = 0, z = 0 } }
    _doPlayUrlPos(index, id, url, volume or 1.0, coords, radius or 30.0, (loop == nil) and true or loop, attachData, nil)
    return id
end)

-- Controles client-side
exports('Stop', function(uniqueId)
    local k, v = findSoundByUniqueId(uniqueId)
    if not k or not v then return false end
    v.playing = false
    SendNUIMessage({ type = 'stop', soundIndex = k })
    Sounds[k] = nil
    return true
end)

exports('Pause', function(uniqueId)
    local k, v = findSoundByUniqueId(uniqueId)
    if not k or not v then return false end
    v.playing = false; v.paused = true
    SendNUIMessage({ type = 'pause', soundIndex = k })
    return true
end)

exports('Resume', function(uniqueId)
    local k, v = findSoundByUniqueId(uniqueId)
    if not k or not v then return false end
    v.playing = true; v.paused = false
    SendNUIMessage({ type = 'resume', soundIndex = k })
    startLoop()
    return true
end)

exports('SetVolume', function(uniqueId, volume)
    local k, v = findSoundByUniqueId(uniqueId)
    if not k or not v then return false end
    v.vol = clamp(volume, 0.0, 1.0)
    v.maxVol = v.vol
    SendNUIMessage({ type = 'setVolume', soundIndex = k, volume = v.vol })
    return true
end)

exports('SetDistance', function(uniqueId, dist)
    local k, v = findSoundByUniqueId(uniqueId)
    if not k or not v then return false end
    v.dist = dist
    SendNUIMessage({ type = 'setDistance', soundIndex = k, distance = dist })
    return true
end)

exports('FadeIn', function(uniqueId, duration, targetVolume)
    local k = findSoundByUniqueId(uniqueId)
    if not k then return false end
    SendNUIMessage({ type = 'fadeIn', soundIndex = k, duration = duration or 1000, volume = targetVolume or 1.0 })
    return true
end)

exports('FadeOut', function(uniqueId, duration)
    local k = findSoundByUniqueId(uniqueId)
    if not k then return false end
    SendNUIMessage({ type = 'fadeOut', soundIndex = k, duration = duration or 1000 })
    return true
end)


AddEventHandler('onResourceStop', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end
    SendNUIMessage({ type = 'stopAll' })
end)
