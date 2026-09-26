--[[
    pr_3dsound — server.lua  v4.0.0-fixed

    Estado autoritativo + streaming dinâmico de emitters por proximidade.
    Mantém os exports server-side da v3.x.

    Segurança:
      * Use exports server-side para controlar sons.
      * TriggerServerEvent de controle é bloqueado por padrão.
      * Para liberar um player: ACE "pr_3dsound.control".
      * Compatibilidade legada (não recomendado):
          setr pr_3dsound_allow_client_events 1
]]

local Sounds = {}
local NextServerIndex = 100000 -- evita colisão com índices de sons locais do client

local CFG = {
    STREAM_INTERVAL_MS     = math.max(200, GetConvarInt('pr_3dsound_stream_interval', 1000)),
    STREAM_HYSTERESIS      = tonumber(GetConvar('pr_3dsound_stream_hysteresis', '8.0')) or 8.0,
    MAX_RADIUS             = tonumber(GetConvar('pr_3dsound_max_radius', '1000.0')) or 1000.0,
    ENTITY_MISSING_TIMEOUT = math.max(2000, GetConvarInt('pr_3dsound_entity_timeout', 10000)),
    ENTITY_MISSING_GRACE   = math.max(500, GetConvarInt('pr_3dsound_entity_grace', 2500)),
    ALLOW_CLIENT_EVENTS    = GetConvarInt('pr_3dsound_allow_client_events', 0) == 1,
    CLIENT_ACE             = GetConvar('pr_3dsound_client_ace', 'pr_3dsound.control'),
}

local deniedOnce = {}

-- =============================================
--  UTILIDADES
-- =============================================

local function clamp(v, lo, hi)
    v = tonumber(v) or lo
    return math.max(lo, math.min(hi, v))
end

local function toCoords(coords)
    if not coords then return nil end
    local x = tonumber(coords.x or coords[1])
    local y = tonumber(coords.y or coords[2])
    local z = tonumber(coords.z or coords[3])
    if not x or not y or not z then return nil end
    return vector3(x, y, z)
end

local function normalizeOffset(offset)
    if not offset then return { x = 0.0, y = 0.0, z = 0.0 } end
    return {
        x = tonumber(offset.x or offset[1]) or 0.0,
        y = tonumber(offset.y or offset[2]) or 0.0,
        z = tonumber(offset.z or offset[3]) or 0.0,
    }
end

local function validName(name)
    return type(name) == 'string' and #name > 0 and #name <= 128
end

local function validUrl(url)
    if type(url) ~= 'string' or #url == 0 or #url > 2048 then return false end
    local lower = url:lower()
    return lower:sub(1, 7) == 'http://' or lower:sub(1, 8) == 'https://'
end

local function validSoundPath(path)
    if type(path) ~= 'string' or #path == 0 or #path > 256 then return false end
    if path:find('..', 1, true) or path:sub(1, 1) == '/' or path:sub(1, 1) == '\\' then return false end
    return true
end

local function getIndexByUniqueId(uniqueId)
    if uniqueId == nil then return nil end
    for k, v in pairs(Sounds) do
        if v.uniqueId == uniqueId then return k end
    end
    return nil
end

local function eachListener(sound, fn)
    if not sound.listeners then return end
    for player, _ in pairs(sound.listeners) do fn(player) end
end

local function playbackOffset(sound)
    local base = tonumber(sound.seekBase) or 0.0
    if sound.paused then return tonumber(sound.pausedOffset) or base end

    local startedAt = tonumber(sound.startedAt) or GetGameTimer()
    local elapsedMs = GetGameTimer() - startedAt
    if elapsedMs < 0 then elapsedMs = 0 end
    return math.max(0.0, base + (elapsedMs / 1000.0))
end

local function getAttachedEntity(sound)
    if not sound.attachNetId then return nil end
    local entity = NetworkGetEntityFromNetworkId(sound.attachNetId)
    if entity and entity ~= 0 and DoesEntityExist(entity) then return entity end
    return nil
end

local function refreshSoundCoords(sound)
    local entity = getAttachedEntity(sound)
    if entity then
        local c = GetEntityCoords(entity)
        local o = sound.attachOffset or { x = 0.0, y = 0.0, z = 0.0 }
        sound.coords = vector3(c.x + o.x, c.y + o.y, c.z + o.z)
        sound.routingBucket = GetEntityRoutingBucket(entity)
        sound.entityMissingSince = nil
        return true
    end

    if sound.attachNetId then
        sound.entityMissingSince = sound.entityMissingSince or GetGameTimer()
        return false
    end

    return sound.coords ~= nil
end

local function eligibleTarget(sound, player)
    if sound.targetSource and sound.targetSource ~= player then return false end
    if sound.routingBucket ~= nil and GetPlayerRoutingBucket(player) ~= sound.routingBucket then return false end
    return true
end

local function distanceSq(a, b)
    local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
    return dx * dx + dy * dy + dz * dz
end

local function clientCanControl(src)
    if not src or src == 0 then return true end
    if CFG.ALLOW_CLIENT_EVENTS then return true end
    if IsPlayerAceAllowed(src, CFG.CLIENT_ACE) then return true end

    if not deniedOnce[src] then
        deniedOnce[src] = true
        print(('[pr_3dsound] Bloqueado TriggerServerEvent não autorizado do player %s. Use exports server-side ou ACE "%s".'):format(src, CFG.CLIENT_ACE))
    end
    return false
end

local function playerPosition(player)
    local ped = GetPlayerPed(player)
    if not ped or ped == 0 then return nil end
    local c = GetEntityCoords(ped)
    return vector3(c.x, c.y, c.z)
end

local function buildOptions(sound)
    return {
        serverManaged = true,
        startAt = playbackOffset(sound),
        paused = sound.paused == true,
    }
end

local function sendSoundToPlayer(index, sound, player)
    player = tonumber(player)
    if not player or GetPlayerName(player) == nil then return false end

    sound.listeners = sound.listeners or {}
    if sound.listeners[player] then return true end

    local options = buildOptions(sound)

    if sound.is2D then
        TriggerClientEvent('pr_3dsound:client:playUrl', player,
            index, sound.uniqueId, sound.url, sound.volume, sound.loop, options)
    elseif sound.isUrl then
        local attachData = nil
        if sound.attachNetId then
            attachData = {
                entityNetId = sound.attachNetId,
                offset = sound.attachOffset or { x = 0.0, y = 0.0, z = 0.0 },
            }
        end

        TriggerClientEvent('pr_3dsound:client:playUrlPos', player,
            index, sound.uniqueId, sound.url, sound.volume, sound.coords,
            sound.radius, sound.loop, options, attachData)
    else
        TriggerClientEvent('pr_3dsound:client:play', player,
            index, sound.coords, sound.soundName, sound.volume, sound.radius,
            sound.uniqueId, sound.loop, nil, options)
    end

    sound.listeners[player] = true
    return true
end

local function streamOutPlayer(index, sound, player)
    if not sound.listeners or not sound.listeners[player] then return end
    TriggerClientEvent('pr_3dsound:client:stop', player, index)
    sound.listeners[player] = nil
end

local function streamOutAll(index, sound)
    if not sound.listeners then return end
    eachListener(sound, function(player)
        TriggerClientEvent('pr_3dsound:client:stop', player, index)
    end)
    sound.listeners = {}
end

local function stopIndex(index)
    local sound = Sounds[index]
    if not sound then return false end

    eachListener(sound, function(player)
        TriggerClientEvent('pr_3dsound:client:stop', player, index)
    end)

    Sounds[index] = nil
    return true
end

local function replaceExisting(uniqueId)
    local existing = getIndexByUniqueId(uniqueId)
    if existing then stopIndex(existing) end
end

local function allocateIndex()
    NextServerIndex = NextServerIndex + 1
    return NextServerIndex
end

local function makeSound(uniqueId, data)
    replaceExisting(uniqueId)
    local index = allocateIndex()
    data.uniqueId = uniqueId
    data.listeners = {}
    data.startedAt = GetGameTimer()
    data.createdAt = data.startedAt
    data.seekBase = 0.0
    data.paused = false
    Sounds[index] = data
    return index, data
end

local function syncSpatialPlayer(index, sound, player, pCoords)
    if not eligibleTarget(sound, player) then
        streamOutPlayer(index, sound, player)
        return
    end

    if not sound.coords or not pCoords then return end

    local radius = sound.radius or 30.0
    local listening = sound.listeners and sound.listeners[player]
    local threshold = listening and (radius + CFG.STREAM_HYSTERESIS) or radius
    local inside = distanceSq(sound.coords, pCoords) <= (threshold * threshold)

    if inside and not listening then
        sendSoundToPlayer(index, sound, player)
    elseif not inside and listening then
        streamOutPlayer(index, sound, player)
    end
end

local function syncPlayer(player)
    player = tonumber(player)
    if not player then return end

    local pCoords = playerPosition(player)
    for index, sound in pairs(Sounds) do
        if sound.is2D then
            if eligibleTarget(sound, player) then sendSoundToPlayer(index, sound, player) end
        else
            local entityOk = refreshSoundCoords(sound)
            if sound.attachNetId and not entityOk then
                -- Durante troca de ownership/entrada em veículo o Network ID pode
                -- sumir por poucos ticks. Preserve listeners existentes nessa janela
                -- para não pausar/recriar a música. Novos listeners aguardam resolver.
                local missingFor = sound.entityMissingSince and (GetGameTimer() - sound.entityMissingSince) or 0
                if missingFor >= CFG.ENTITY_MISSING_GRACE then
                    streamOutPlayer(index, sound, player)
                end
            else
                syncSpatialPlayer(index, sound, player, pCoords)
            end
        end
    end
end

-- =============================================
--  PLAY — arquivo local em html/sounds/
-- =============================================

local function Play(coords, soundName, volume, radius, uniqueId, resourceName, loop)
    coords = toCoords(coords)
    if not coords or not validSoundPath(soundName) then return nil end

    uniqueId = uniqueId or ('snd_%d'):format(NextServerIndex + 1)
    radius = clamp(radius or 30.0, 1.0, CFG.MAX_RADIUS)
    volume = clamp(volume or 1.0, 0.0, 1.0)
    loop = loop == true

    local finalName = soundName
    if resourceName and resourceName ~= '' then
        if not validSoundPath(tostring(resourceName)) then return nil end
        finalName = tostring(resourceName) .. '/' .. soundName
    end

    local index, sound = makeSound(uniqueId, {
        coords = coords,
        radius = radius,
        volume = volume,
        isUrl = false,
        is2D = false,
        soundName = finalName,
        loop = loop,
    })

    for _, playerStr in ipairs(GetPlayers()) do
        local player = tonumber(playerStr)
        syncSpatialPlayer(index, sound, player, playerPosition(player))
    end

    return uniqueId
end

-- =============================================
--  PLAY URL — 2D
-- =============================================

local function PlayUrl(sourcePlayer, name, url, volume, loop)
    if not validName(name) or not validUrl(url) then return nil end

    volume = clamp(volume or 1.0, 0.0, 1.0)
    loop = loop == true
    local target = (sourcePlayer and tonumber(sourcePlayer) ~= -1) and tonumber(sourcePlayer) or nil

    local index, sound = makeSound(name, {
        isUrl = true,
        is2D = true,
        url = url,
        volume = volume,
        loop = loop,
        targetSource = target,
    })

    if target then
        sendSoundToPlayer(index, sound, target)
    else
        for _, playerStr in ipairs(GetPlayers()) do
            sendSoundToPlayer(index, sound, tonumber(playerStr))
        end
    end

    return name
end

-- =============================================
--  PLAY URL POS — emitter persistente
-- =============================================

local function PlayUrlPos(sourcePlayer, name, url, volume, coords, radius, loop, routingBucket)
    coords = toCoords(coords)
    if not coords or not validName(name) or not validUrl(url) then return nil end

    radius = clamp(radius or 50.0, 1.0, CFG.MAX_RADIUS)
    volume = clamp(volume or 1.0, 0.0, 1.0)
    loop = loop == true
    local target = (sourcePlayer and tonumber(sourcePlayer) ~= -1) and tonumber(sourcePlayer) or nil
    routingBucket = routingBucket ~= nil and tonumber(routingBucket) or nil

    local index, sound = makeSound(name, {
        coords = coords,
        radius = radius,
        volume = volume,
        isUrl = true,
        is2D = false,
        url = url,
        loop = loop,
        targetSource = target,
        routingBucket = routingBucket,
    })

    for _, playerStr in ipairs(GetPlayers()) do
        local player = tonumber(playerStr)
        syncSpatialPlayer(index, sound, player, playerPosition(player))
    end

    return name
end

-- =============================================
--  PLAY URL ATTACHED — emitter em entity
-- =============================================

local function PlayUrlAttached(sourcePlayer, name, url, volume, entityNetId, radius, loop)
    entityNetId = tonumber(entityNetId)
    if not entityNetId or entityNetId <= 0 or not validName(name) or not validUrl(url) then return nil end

    radius = clamp(radius or 30.0, 1.0, CFG.MAX_RADIUS)
    volume = clamp(volume or 1.0, 0.0, 1.0)
    loop = (loop == nil) and true or loop == true
    local target = (sourcePlayer and tonumber(sourcePlayer) ~= -1) and tonumber(sourcePlayer) or nil

    local entity = NetworkGetEntityFromNetworkId(entityNetId)
    local exists = entity and entity ~= 0 and DoesEntityExist(entity)
    local coords = exists and GetEntityCoords(entity) or vector3(0.0, 0.0, 0.0)
    local bucket = exists and GetEntityRoutingBucket(entity) or nil

    local index, sound = makeSound(name, {
        coords = coords,
        radius = radius,
        volume = volume,
        isUrl = true,
        is2D = false,
        url = url,
        loop = loop,
        targetSource = target,
        attachNetId = entityNetId,
        attachOffset = { x = 0.0, y = 0.0, z = 0.0 },
        routingBucket = bucket,
    })

    refreshSoundCoords(sound)

    for _, playerStr in ipairs(GetPlayers()) do
        local player = tonumber(playerStr)
        syncSpatialPlayer(index, sound, player, playerPosition(player))
    end

    return name
end

-- =============================================
--  CONTROLES
-- =============================================

local function AttachToEntity(uniqueId, entityNetId, offset)
    local index = getIndexByUniqueId(uniqueId)
    local sound = index and Sounds[index] or nil
    entityNetId = tonumber(entityNetId)
    if not sound or not entityNetId or entityNetId <= 0 or sound.is2D then return false end

    sound.attachNetId = entityNetId
    sound.attachOffset = normalizeOffset(offset)
    refreshSoundCoords(sound)

    eachListener(sound, function(player)
        TriggerClientEvent('pr_3dsound:client:attachToEntity', player, index, entityNetId, sound.attachOffset)
    end)

    return true
end

local function DetachEntity(uniqueId)
    local index = getIndexByUniqueId(uniqueId)
    local sound = index and Sounds[index] or nil
    if not sound then return false end

    refreshSoundCoords(sound)
    sound.attachNetId = nil
    sound.attachOffset = nil
    sound.routingBucket = nil
    sound.entityMissingSince = nil

    eachListener(sound, function(player)
        TriggerClientEvent('pr_3dsound:client:detachEntity', player, index)
    end)

    return true
end

local function Pause(uniqueId)
    local index = getIndexByUniqueId(uniqueId)
    local sound = index and Sounds[index] or nil
    if not sound then return false end

    if not sound.paused then
        sound.pausedOffset = playbackOffset(sound)
        sound.paused = true
    end

    local exactOffset = tonumber(sound.pausedOffset) or playbackOffset(sound)
    eachListener(sound, function(player)
        -- Uma única mensagem evita corrida NUI entre seek e pause.
        TriggerClientEvent('pr_3dsound:client:pauseAt', player, index, exactOffset)
    end)

    return true
end

local function Resume(uniqueId)
    local index = getIndexByUniqueId(uniqueId)
    local sound = index and Sounds[index] or nil
    if not sound then return false end

    local exactOffset = sound.paused and (tonumber(sound.pausedOffset) or 0.0) or playbackOffset(sound)
    if sound.paused then
        sound.seekBase = exactOffset
        sound.startedAt = GetGameTimer()
        sound.pausedOffset = nil
        sound.paused = false
    end

    eachListener(sound, function(player)
        -- Resume atômico: o NUI só executa play() depois que o seek foi aplicado.
        TriggerClientEvent('pr_3dsound:client:resumeAt', player, index, exactOffset)
    end)

    return true
end

local function Stop(uniqueId)
    local index = getIndexByUniqueId(uniqueId)
    if not index then return false end
    return stopIndex(index)
end

local function StopAll()
    local indexes = {}
    for index, _ in pairs(Sounds) do indexes[#indexes + 1] = index end
    for i = 1, #indexes do stopIndex(indexes[i]) end
    return true
end

local function UpdateCoords(uniqueId, coords)
    local index = getIndexByUniqueId(uniqueId)
    local sound = index and Sounds[index] or nil
    coords = toCoords(coords)
    if not sound or not coords or sound.is2D then return false end

    sound.coords = coords
    sound.attachNetId = nil
    sound.attachOffset = nil
    sound.routingBucket = nil
    sound.entityMissingSince = nil

    eachListener(sound, function(player)
        TriggerClientEvent('pr_3dsound:client:updateCoords', player, index, coords)
    end)

    return true
end

local function SetVolume(uniqueId, volume)
    local index = getIndexByUniqueId(uniqueId)
    local sound = index and Sounds[index] or nil
    if not sound then return false end

    sound.volume = clamp(volume, 0.0, 1.0)
    eachListener(sound, function(player)
        TriggerClientEvent('pr_3dsound:client:setVolume', player, index, sound.volume)
    end)
    return true
end

local function SetVolumeMax(uniqueId, volume)
    local index = getIndexByUniqueId(uniqueId)
    local sound = index and Sounds[index] or nil
    if not sound then return false end

    sound.volume = clamp(volume, 0.0, 1.0)
    eachListener(sound, function(player)
        TriggerClientEvent('pr_3dsound:client:setVolumeMax', player, index, sound.volume)
    end)
    return true
end

local function SetDistance(uniqueId, dist)
    local index = getIndexByUniqueId(uniqueId)
    local sound = index and Sounds[index] or nil
    if not sound or sound.is2D then return false end

    sound.radius = clamp(dist, 1.0, CFG.MAX_RADIUS)
    eachListener(sound, function(player)
        TriggerClientEvent('pr_3dsound:client:setDistance', player, index, sound.radius)
    end)
    return true
end

local function SetLoop(uniqueId, loopVal)
    local index = getIndexByUniqueId(uniqueId)
    local sound = index and Sounds[index] or nil
    if not sound then return false end

    sound.loop = loopVal == true
    eachListener(sound, function(player)
        TriggerClientEvent('pr_3dsound:client:setLoop', player, index, sound.loop)
    end)
    return true
end

local function SetTimestamp(uniqueId, time)
    local index = getIndexByUniqueId(uniqueId)
    local sound = index and Sounds[index] or nil
    if not sound then return false end

    time = math.max(0.0, tonumber(time) or 0.0)
    sound.seekBase = time
    sound.startedAt = GetGameTimer()
    if sound.paused then sound.pausedOffset = time end

    eachListener(sound, function(player)
        TriggerClientEvent('pr_3dsound:client:setTimestamp', player, index, time)
    end)
    return true
end

local function FadeIn(uniqueId, duration, targetVolume)
    local index = getIndexByUniqueId(uniqueId)
    local sound = index and Sounds[index] or nil
    if not sound then return false end

    duration = math.max(0, tonumber(duration) or 1000)
    targetVolume = clamp(targetVolume or 1.0, 0.0, 1.0)
    sound.volume = targetVolume

    eachListener(sound, function(player)
        TriggerClientEvent('pr_3dsound:client:fadeIn', player, index, duration, targetVolume)
    end)
    return true
end

local function FadeOut(uniqueId, duration)
    local index = getIndexByUniqueId(uniqueId)
    local sound = index and Sounds[index] or nil
    if not sound then return false end

    duration = math.max(0, tonumber(duration) or 1000)
    sound.volume = 0.0 -- novos listeners durante/depois do fade não entram em volume cheio

    eachListener(sound, function(player)
        TriggerClientEvent('pr_3dsound:client:fadeOut', player, index, duration)
    end)
    return true
end

local function SoundExists(uniqueId)
    return getIndexByUniqueId(uniqueId) ~= nil
end

local function GetAllSounds()
    local result = {}
    for _, v in pairs(Sounds) do
        local listenerCount = 0
        if v.listeners then for _ in pairs(v.listeners) do listenerCount = listenerCount + 1 end end

        result[v.uniqueId] = {
            coords = v.coords,
            radius = v.radius,
            volume = v.volume,
            isUrl = v.isUrl,
            is2D = v.is2D,
            attachNetId = v.attachNetId,
            paused = v.paused,
            loop = v.loop,
            listeners = listenerCount,
        }
    end
    return result
end

-- =============================================
--  EXPORTS
-- =============================================

exports('Play', Play)
exports('PlayUrl', PlayUrl)
exports('PlayUrlPos', PlayUrlPos)
exports('PlayUrlAttached', PlayUrlAttached)
exports('AttachToEntity', AttachToEntity)
exports('DetachEntity', DetachEntity)
exports('Pause', Pause)
exports('Resume', Resume)
exports('Stop', Stop)
exports('StopAll', StopAll)
exports('UpdateCoords', UpdateCoords)
exports('SetVolume', SetVolume)
exports('SetVolumeMax', SetVolumeMax)
exports('SetDistance', SetDistance)
exports('SetLoop', SetLoop)
exports('SetTimestamp', SetTimestamp)
exports('FadeIn', FadeIn)
exports('FadeOut', FadeOut)
exports('SoundExists', SoundExists)
exports('GetAllSounds', GetAllSounds)

-- =============================================
--  STREAMING DINÂMICO
-- =============================================

CreateThread(function()
    while true do
        Wait(CFG.STREAM_INTERVAL_MS)

        local players = GetPlayers()
        local positions = {}
        for i = 1, #players do
            local player = tonumber(players[i])
            positions[player] = playerPosition(player)
        end

        local toStop = {}

        for index, sound in pairs(Sounds) do
            if not sound.is2D then
                local entityOk = refreshSoundCoords(sound)

                if sound.attachNetId and not entityOk then
                    local missingFor = sound.entityMissingSince and (GetGameTimer() - sound.entityMissingSince) or 0

                    -- Grace period: mantém quem já está ouvindo sem destruir o player.
                    -- Se a entidade realmente não voltar, aí sim faz stream-out/stop.
                    if missingFor >= CFG.ENTITY_MISSING_GRACE then
                        streamOutAll(index, sound)
                    end

                    if missingFor >= CFG.ENTITY_MISSING_TIMEOUT then
                        toStop[#toStop + 1] = index
                    end
                else
                    for i = 1, #players do
                        local player = tonumber(players[i])
                        syncSpatialPlayer(index, sound, player, positions[player])
                    end

                    for player, _ in pairs(sound.listeners) do
                        if positions[player] == nil then sound.listeners[player] = nil end
                    end
                end
            else
                for player, _ in pairs(sound.listeners) do
                    if GetPlayerName(player) == nil then sound.listeners[player] = nil end
                end
            end
        end

        for i = 1, #toStop do stopIndex(toStop[i]) end
    end
end)

-- Sync após o client carregar/reiniciar a resource. O servidor pode ainda
-- considerar esse player listener de uma execução anterior do client; limpamos
-- apenas o estado desse player para forçar o reenvio correto.
local lastSyncRequest = {}
RegisterNetEvent('pr_3dsound:server:requestSync', function()
    local src = source
    local now = GetGameTimer()
    if lastSyncRequest[src] and (now - lastSyncRequest[src]) < 1000 then return end
    lastSyncRequest[src] = now

    for _, sound in pairs(Sounds) do
        if sound.listeners then sound.listeners[src] = nil end
    end
    syncPlayer(src)
end)

-- Cleanup de sons não-loop após o player realmente chegar ao fim.
-- Só aceitamos de um listener atual e após ao menos 500 ms de vida.
RegisterNetEvent('pr_3dsound:server:soundEnded', function(index)
    local src = source
    index = tonumber(index)
    local sound = index and Sounds[index] or nil
    if not sound or sound.loop or not sound.listeners or not sound.listeners[src] then return end
    if (GetGameTimer() - (sound.createdAt or 0)) < 500 then return end
    TriggerEvent('pr_3dsound:serverManagedEnded', sound.uniqueId, src)
    stopIndex(index)
end)

RegisterNetEvent('pr_3dsound:server:soundError', function(index, reason)
    local src = source
    index = tonumber(index)
    local sound = index and Sounds[index] or nil
    if not sound or not sound.listeners or not sound.listeners[src] then return end

    reason = type(reason) == 'string' and reason:sub(1, 240) or 'Falha ao reproduzir o stream.'
    TriggerEvent('pr_3dsound:serverManagedError', sound.uniqueId, reason, src)
    stopIndex(index)
end)

AddEventHandler('playerDropped', function()
    local src = source
    deniedOnce[src] = nil
    lastSyncRequest[src] = nil

    local toStop = {}
    for index, sound in pairs(Sounds) do
        if sound.listeners then sound.listeners[src] = nil end
        if sound.targetSource == src then toStop[#toStop + 1] = index end
    end

    for i = 1, #toStop do stopIndex(toStop[i]) end
end)

-- =============================================
--  NET EVENTS LEGADOS — protegidos por ACE
-- =============================================

local function guarded(fn)
    return function(...)
        local src = source
        if not clientCanControl(src) then return end
        return fn(src, ...)
    end
end

RegisterNetEvent('pr_3dsound:server:play', guarded(function(_, coords, soundName, volume, radius, uniqueId, resourceName, loop)
    Play(coords, soundName, volume, radius, uniqueId, resourceName, loop)
end))

RegisterNetEvent('pr_3dsound:server:playUrl', guarded(function(src, name, url, volume, loop)
    PlayUrl(src, name, url, volume, loop)
end))

RegisterNetEvent('pr_3dsound:server:playUrlPos', guarded(function(src, name, url, volume, coords, radius, loop)
    PlayUrlPos(src, name, url, volume, coords, radius, loop)
end))

RegisterNetEvent('pr_3dsound:server:playUrlAttached', guarded(function(src, name, url, volume, entityNetId, radius, loop)
    PlayUrlAttached(src, name, url, volume, entityNetId, radius, loop)
end))

RegisterNetEvent('pr_3dsound:server:attachSoundToEntity', guarded(function(src, name, url, volume, entityNetId, radius, loop)
    PlayUrlAttached(src, name, url, volume, entityNetId, radius, loop)
end))

RegisterNetEvent('pr_3dsound:server:attachToEntity', guarded(function(_, uniqueId, entityNetId, offset) AttachToEntity(uniqueId, entityNetId, offset) end))
RegisterNetEvent('pr_3dsound:server:detachEntity', guarded(function(_, uniqueId) DetachEntity(uniqueId) end))
RegisterNetEvent('pr_3dsound:server:pause', guarded(function(_, uniqueId) Pause(uniqueId) end))
RegisterNetEvent('pr_3dsound:server:resume', guarded(function(_, uniqueId) Resume(uniqueId) end))
RegisterNetEvent('pr_3dsound:server:stop', guarded(function(_, uniqueId) Stop(uniqueId) end))
RegisterNetEvent('pr_3dsound:server:stopAll', guarded(function(_) StopAll() end))
RegisterNetEvent('pr_3dsound:server:updateCoords', guarded(function(_, uniqueId, coords) UpdateCoords(uniqueId, coords) end))
RegisterNetEvent('pr_3dsound:server:setVolume', guarded(function(_, uniqueId, volume) SetVolume(uniqueId, volume) end))
RegisterNetEvent('pr_3dsound:server:setVolumeMax', guarded(function(_, uniqueId, volume) SetVolumeMax(uniqueId, volume) end))
RegisterNetEvent('pr_3dsound:server:setDistance', guarded(function(_, uniqueId, dist) SetDistance(uniqueId, dist) end))
RegisterNetEvent('pr_3dsound:server:setLoop', guarded(function(_, uniqueId, loopVal) SetLoop(uniqueId, loopVal) end))
RegisterNetEvent('pr_3dsound:server:setTimestamp', guarded(function(_, uniqueId, time) SetTimestamp(uniqueId, time) end))
RegisterNetEvent('pr_3dsound:server:fadeIn', guarded(function(_, uniqueId, dur, vol) FadeIn(uniqueId, dur, vol) end))
RegisterNetEvent('pr_3dsound:server:fadeOut', guarded(function(_, uniqueId, dur) FadeOut(uniqueId, dur) end))
