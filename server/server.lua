--[[
    pr_3dsound — server.lua v4.0

    v4.0 goals:
      * persistent positional emitters with late stream-in / stream-out
      * attached emitters follow networked entities server-side
      * playback timestamp is preserved when a player enters the radius later
      * client-triggered control is restricted to sounds owned by that client
      * global/broadcast control should be done through server-side exports

    Public server exports are intentionally kept compatible with v3.x.
]]

local Sounds = {}
local SERVER_INDEX_BASE = 100000

local CFG = {
    STREAM_INTERVAL_MS = 750,
    STREAM_IN_PADDING = 5.0,
    STREAM_OUT_PADDING = 15.0,
    MAX_RADIUS = 1000.0,
    MAX_CLIENT_RADIUS = 100.0,
    CLIENT_EVENT_COOLDOWN_MS = 200,
    CLIENT_MAX_SOURCE_DISTANCE = 25.0,
    CLIENT_BROADCAST_ACE = 'pr_3dsound.broadcast',
}

local clientCooldown = {}

local function nowMs()
    return GetGameTimer()
end

local function clamp(v, lo, hi)
    v = tonumber(v) or lo
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

local function toCoords(value)
    if type(value) == 'vector3' then
        return vector3(value.x + 0.0, value.y + 0.0, value.z + 0.0)
    end
    if type(value) == 'table' and tonumber(value.x) and tonumber(value.y) and tonumber(value.z) then
        return vector3(value.x + 0.0, value.y + 0.0, value.z + 0.0)
    end
end

local function packCoords(value)
    local c = toCoords(value)
    if not c then return nil end
    return { x = c.x, y = c.y, z = c.z }
end

local function normalizeOffset(offset)
    if type(offset) ~= 'table' then return { x = 0.0, y = 0.0, z = 0.0 } end
    return {
        x = tonumber(offset.x) or 0.0,
        y = tonumber(offset.y) or 0.0,
        z = tonumber(offset.z) or 0.0,
    }
end

local function validUrl(url)
    return type(url) == 'string' and #url <= 2048 and url:match('^https?://') ~= nil
end

local function validSoundName(name)
    if type(name) ~= 'string' or name == '' or #name > 240 then return false end
    if name:find('%.%.', 1, true) then return false end
    if name:sub(1, 1) == '/' or name:sub(1, 1) == '\\' then return false end
    return true
end

local function getNextIndex(uniqueId)
    if uniqueId then
        for index, sound in pairs(Sounds) do
            if sound.uniqueId == uniqueId then return index end
        end
    end

    local i = SERVER_INDEX_BASE + 1
    while Sounds[i] ~= nil do i = i + 1 end
    return i
end

local function getIndexByUniqueId(uniqueId)
    for index, sound in pairs(Sounds) do
        if sound.uniqueId == uniqueId then return index end
    end
end

local function playerCoords(src)
    src = tonumber(src)
    if not src then return nil end
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 or not DoesEntityExist(ped) then return nil end
    return GetEntityCoords(ped)
end

local function elapsedSeconds(sound)
    if sound.paused then
        return math.max(0.0, sound.pausedTimestamp or 0.0)
    end
    local startedAt = sound.startedAtMs or nowMs()
    return math.max(0.0, (nowMs() - startedAt) / 1000.0)
end

local function resetClock(sound, seconds)
    seconds = math.max(0.0, tonumber(seconds) or 0.0)
    sound.startedAtMs = nowMs() - math.floor(seconds * 1000.0)
    sound.pausedTimestamp = sound.paused and seconds or nil
end

local function canClientMutate(src, sound)
    return sound and sound.ownerSource and tonumber(sound.ownerSource) == tonumber(src)
end

local function clientRateAllowed(src)
    local now = nowMs()
    local last = clientCooldown[src] or 0
    if now - last < CFG.CLIENT_EVENT_COOLDOWN_MS then return false end
    clientCooldown[src] = now
    return true
end

local function hasBroadcastAce(src)
    return src == 0 or IsPlayerAceAllowed(src, CFG.CLIENT_BROADCAST_ACE)
end

local function clientIdAvailable(src, uniqueId)
    if not uniqueId then return true end
    local index = getIndexByUniqueId(uniqueId)
    if not index then return true end
    local sound = Sounds[index]
    return sound and sound.ownerSource and tonumber(sound.ownerSource) == tonumber(src)
end

local function coordsNearClient(src, coords)
    local pc = playerCoords(src)
    local c = toCoords(coords)
    if not pc or not c then return false end
    return #(pc - c) <= CFG.CLIENT_MAX_SOURCE_DISTANCE
end

local function entityCoords(sound)
    if not sound.attachNetId then return toCoords(sound.coords) end

    local entity = NetworkGetEntityFromNetworkId(sound.attachNetId)
    if entity and entity ~= 0 and DoesEntityExist(entity) then
        local c = GetEntityCoords(entity)
        -- Keep attached emitters inside the same OneSync routing bucket as the entity.
        if GetEntityRoutingBucket then sound.routingBucket = GetEntityRoutingBucket(entity) end
        -- Server proximity uses entity origin; clients apply the local attach offset.
        sound.coords = vector3(c.x, c.y, c.z)
        return sound.coords
    end

    return toCoords(sound.coords)
end

local function shouldHear(sound, src, currentlyListening)
    if sound.targetSource and sound.targetSource ~= -1 then
        return tonumber(src) == tonumber(sound.targetSource)
    end

    if sound.routingBucket ~= nil and GetPlayerRoutingBucket and GetPlayerRoutingBucket(src) ~= sound.routingBucket then
        return false
    end

    if sound.is2D then return true end

    local sc = toCoords(sound.coords)
    local pc = playerCoords(src)
    if not sc or not pc then return false end

    local radius = tonumber(sound.radius) or 50.0
    local padding = currentlyListening and CFG.STREAM_OUT_PADDING or CFG.STREAM_IN_PADDING
    return #(pc - sc) <= (radius + padding)
end

local function makeListenerToken(index, src)
    return ('%s:%s:%s:%s'):format(index, src, nowMs(), math.random(100000, 999999))
end

local function sendPlay(index, sound, src)
    local coords = entityCoords(sound) or vector3(0.0, 0.0, 0.0)
    local token = makeListenerToken(index, src)
    sound.listeners[src] = { token = token }

    local options = {
        startTime = elapsedSeconds(sound),
        serverManaged = true,
        endToken = token,
        paused = sound.paused == true,
    }

    if sound.kind == 'local' then
        TriggerClientEvent('pr_3dsound:client:play', src,
            index, packCoords(coords), sound.file, sound.volume, sound.radius,
            sound.uniqueId, sound.loop, nil, options)
    elseif sound.is2D then
        TriggerClientEvent('pr_3dsound:client:playUrl', src,
            index, sound.uniqueId, sound.url, sound.volume, sound.loop, options)
    else
        local attachData = nil
        if sound.attachNetId then
            attachData = {
                entityNetId = sound.attachNetId,
                offset = sound.attachOffset or { x = 0.0, y = 0.0, z = 0.0 },
            }
        end
        TriggerClientEvent('pr_3dsound:client:playUrlPos', src,
            index, sound.uniqueId, sound.url, sound.volume, packCoords(coords), sound.radius,
            sound.loop, options, attachData)
    end

    if sound.paused then
        TriggerClientEvent('pr_3dsound:client:pause', src, index)
    end
end

local function streamOut(index, sound, src)
    if sound.listeners[src] then
        TriggerClientEvent('pr_3dsound:client:stop', src, index)
        sound.listeners[src] = nil
    end
end

local function syncSound(index, sound)
    if not sound then return end

    -- Resolve attached entity once per sync pass (instead of once per player).
    if not sound.is2D then entityCoords(sound) end

    for _, player in ipairs(GetPlayers()) do
        local src = tonumber(player)
        if src then
            local listening = sound.listeners[src] ~= nil
            local hear = shouldHear(sound, src, listening)
            if hear and not listening then
                sendPlay(index, sound, src)
            elseif not hear and listening then
                streamOut(index, sound, src)
            end
        end
    end

    for src, _ in pairs(sound.listeners) do
        if not GetPlayerName(src) then
            sound.listeners[src] = nil
        end
    end
end

local function broadcastToListeners(sound, eventName, ...)
    for src, _ in pairs(sound.listeners) do
        TriggerClientEvent(eventName, src, ...)
    end
end

local function storeSound(index, data)
    local previous = Sounds[index]
    if previous then
        broadcastToListeners(previous, 'pr_3dsound:client:stop', index)
    end
    data.listeners = data.listeners or {}
    data.startedAtMs = data.startedAtMs or nowMs()
    data.paused = data.paused == true
    if data.kind == 'local' and not data.loop and not data.expiresAtMs then
        data.expiresAtMs = nowMs() + 120000 -- safety cleanup for one-shot local effects
    end
    Sounds[index] = data
    syncSound(index, data)
end

-- ============================================================
-- Server API
-- ============================================================

local function Play(coords, soundName, volume, radius, uniqueId, resourceName, loop)
    local c = toCoords(coords)
    if not c or not validSoundName(soundName) then return nil end

    local index = getNextIndex(uniqueId)
    uniqueId = uniqueId or tostring(index)
    radius = clamp(radius or 30.0, 1.0, CFG.MAX_RADIUS)
    volume = clamp(volume or 1.0, 0.0, 1.0)
    loop = loop == true

    local finalName = soundName
    if resourceName and resourceName ~= '' then
        if not validSoundName(resourceName) then return nil end
        finalName = resourceName .. '/' .. soundName
    end

    storeSound(index, {
        kind = 'local', uniqueId = uniqueId, file = finalName,
        coords = c, radius = radius, volume = volume,
        isUrl = false, is2D = false, loop = loop,
        -- One-shot local effects should not suddenly replay for players who arrive late.
        streamPersistent = loop,
    })

    -- For a non-loop local effect, freeze the initial audience after the first sync.
    if not loop then Sounds[index].targetSnapshot = true end
    return uniqueId
end

local function PlayUrl(targetSource, name, url, volume, loop)
    if not name or not validUrl(url) then return nil end
    local index = getNextIndex(name)
    storeSound(index, {
        kind = 'url', uniqueId = name, url = url,
        volume = clamp(volume or 1.0, 0.0, 1.0),
        isUrl = true, is2D = true, loop = loop == true,
        targetSource = (targetSource and targetSource ~= -1) and tonumber(targetSource) or nil,
    })
    return name
end

local function PlayUrlPos(targetSource, name, url, volume, coords, radius, loop)
    local c = toCoords(coords)
    if not name or not validUrl(url) or not c then return nil end
    local index = getNextIndex(name)
    storeSound(index, {
        kind = 'url', uniqueId = name, url = url, coords = c,
        volume = clamp(volume or 1.0, 0.0, 1.0),
        radius = clamp(radius or 50.0, 1.0, CFG.MAX_RADIUS),
        isUrl = true, is2D = false, loop = loop == true,
        targetSource = (targetSource and targetSource ~= -1) and tonumber(targetSource) or nil,
    })
    return name
end

local function PlayUrlAttached(targetSource, name, url, volume, entityNetId, radius, loop)
    if not name or not validUrl(url) or not tonumber(entityNetId) then return nil end
    local index = getNextIndex(name)
    local entity = NetworkGetEntityFromNetworkId(tonumber(entityNetId))
    local coords = (entity and entity ~= 0 and DoesEntityExist(entity)) and GetEntityCoords(entity) or vector3(0.0, 0.0, 0.0)

    storeSound(index, {
        kind = 'url', uniqueId = name, url = url, coords = coords,
        volume = clamp(volume or 1.0, 0.0, 1.0),
        radius = clamp(radius or 30.0, 1.0, CFG.MAX_RADIUS),
        isUrl = true, is2D = false,
        loop = (loop == nil) and true or loop == true,
        targetSource = (targetSource and targetSource ~= -1) and tonumber(targetSource) or nil,
        attachNetId = tonumber(entityNetId),
        attachOffset = { x = 0.0, y = 0.0, z = 0.0 },
    })
    return name
end

local function AttachToEntity(uniqueId, entityNetId, offset)
    local index = getIndexByUniqueId(uniqueId)
    local sound = index and Sounds[index]
    if not sound or not tonumber(entityNetId) then return false end
    sound.attachNetId = tonumber(entityNetId)
    sound.attachOffset = normalizeOffset(offset)
    entityCoords(sound)
    broadcastToListeners(sound, 'pr_3dsound:client:attachToEntity', index, sound.attachNetId, sound.attachOffset)
    syncSound(index, sound)
    return true
end

local function DetachEntity(uniqueId)
    local index = getIndexByUniqueId(uniqueId)
    local sound = index and Sounds[index]
    if not sound then return false end
    entityCoords(sound)
    sound.attachNetId = nil
    sound.attachOffset = nil
    broadcastToListeners(sound, 'pr_3dsound:client:detachEntity', index)
    return true
end

local function Pause(uniqueId)
    local index = getIndexByUniqueId(uniqueId)
    local sound = index and Sounds[index]
    if not sound or sound.paused then return sound ~= nil end
    sound.pausedTimestamp = elapsedSeconds(sound)
    sound.paused = true
    broadcastToListeners(sound, 'pr_3dsound:client:pause', index)
    return true
end

local function Resume(uniqueId)
    local index = getIndexByUniqueId(uniqueId)
    local sound = index and Sounds[index]
    if not sound then return false end
    if sound.paused then
        local t = sound.pausedTimestamp or 0.0
        sound.paused = false
        sound.pausedTimestamp = nil
        resetClock(sound, t)
    end
    broadcastToListeners(sound, 'pr_3dsound:client:resume', index)
    return true
end

local function Stop(uniqueId)
    local index = getIndexByUniqueId(uniqueId)
    local sound = index and Sounds[index]
    if not sound then return false end
    broadcastToListeners(sound, 'pr_3dsound:client:stop', index)
    Sounds[index] = nil
    return true
end

local function StopAll()
    for index, sound in pairs(Sounds) do
        broadcastToListeners(sound, 'pr_3dsound:client:stop', index)
    end
    Sounds = {}
end

local function UpdateCoords(uniqueId, coords)
    local index = getIndexByUniqueId(uniqueId)
    local sound = index and Sounds[index]
    local c = toCoords(coords)
    if not sound or not c then return false end
    sound.coords = c
    broadcastToListeners(sound, 'pr_3dsound:client:updateCoords', index, packCoords(c))
    syncSound(index, sound)
    return true
end

local function SetVolume(uniqueId, volume)
    local index = getIndexByUniqueId(uniqueId)
    local sound = index and Sounds[index]
    if not sound then return false end
    sound.volume = clamp(volume, 0.0, 1.0)
    broadcastToListeners(sound, 'pr_3dsound:client:setVolume', index, sound.volume)
    return true
end

local function SetVolumeMax(uniqueId, volume)
    return SetVolume(uniqueId, volume)
end

local function SetDistance(uniqueId, dist)
    local index = getIndexByUniqueId(uniqueId)
    local sound = index and Sounds[index]
    if not sound then return false end
    sound.radius = clamp(dist, 1.0, CFG.MAX_RADIUS)
    broadcastToListeners(sound, 'pr_3dsound:client:setDistance', index, sound.radius)
    syncSound(index, sound)
    return true
end

local function SetLoop(uniqueId, loopVal)
    local index = getIndexByUniqueId(uniqueId)
    local sound = index and Sounds[index]
    if not sound then return false end
    sound.loop = loopVal == true
    broadcastToListeners(sound, 'pr_3dsound:client:setLoop', index, sound.loop)
    return true
end

local function SetTimestamp(uniqueId, seconds)
    local index = getIndexByUniqueId(uniqueId)
    local sound = index and Sounds[index]
    if not sound then return false end
    seconds = math.max(0.0, tonumber(seconds) or 0.0)
    resetClock(sound, seconds)
    broadcastToListeners(sound, 'pr_3dsound:client:setTimestamp', index, seconds)
    return true
end

local function FadeIn(uniqueId, duration, targetVolume)
    local index = getIndexByUniqueId(uniqueId)
    local sound = index and Sounds[index]
    if not sound then return false end
    targetVolume = clamp(targetVolume or 1.0, 0.0, 1.0)
    sound.volume = targetVolume
    broadcastToListeners(sound, 'pr_3dsound:client:fadeIn', index, tonumber(duration) or 1000, targetVolume)
    return true
end

local function FadeOut(uniqueId, duration)
    local index = getIndexByUniqueId(uniqueId)
    local sound = index and Sounds[index]
    if not sound then return false end
    sound.volume = 0.0
    broadcastToListeners(sound, 'pr_3dsound:client:fadeOut', index, tonumber(duration) or 1000)
    return true
end

local function SoundExists(uniqueId)
    return getIndexByUniqueId(uniqueId) ~= nil
end

local function GetAllSounds()
    local result = {}
    for _, sound in pairs(Sounds) do
        result[sound.uniqueId] = {
            coords = packCoords(sound.coords), radius = sound.radius,
            volume = sound.volume, isUrl = sound.isUrl, is2D = sound.is2D,
            attachNetId = sound.attachNetId, loop = sound.loop,
            paused = sound.paused, timestamp = elapsedSeconds(sound),
        }
    end
    return result
end

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

-- ============================================================
-- Safe client bridge
-- ============================================================
-- Client-created URL sounds are self-only by default. A client can broadcast
-- only when granted ACE "pr_3dsound.broadcast". Trusted resources should use
-- the server exports above instead of TriggerServerEvent.

local function claimOwner(uniqueId, src)
    local index = getIndexByUniqueId(uniqueId)
    if index and Sounds[index] then Sounds[index].ownerSource = src end
end

RegisterNetEvent('pr_3dsound:server:play', function(coords, soundName, volume, radius, uniqueId, resourceName, loop)
    local src = source
    if not clientRateAllowed(src) or not clientIdAvailable(src, uniqueId) or not coordsNearClient(src, coords) or not validSoundName(soundName) then return end
    radius = clamp(radius or 30.0, 1.0, CFG.MAX_CLIENT_RADIUS)

    if hasBroadcastAce(src) then
        local id = Play(coords, soundName, volume, radius, uniqueId, resourceName, loop)
        if id then claimOwner(id, src) end
        return
    end

    -- Unprivileged requests are managed by the server but audible only to
    -- the requesting player, so pause/stop/volume controls remain functional.
    local index = getNextIndex(uniqueId)
    uniqueId = uniqueId or ('client_%s_%s'):format(src, index)
    local finalName = resourceName and resourceName ~= '' and (resourceName .. '/' .. soundName) or soundName
    storeSound(index, {
        kind = 'local', uniqueId = uniqueId, file = finalName,
        coords = toCoords(coords), radius = radius,
        volume = clamp(volume or 1.0, 0.0, 1.0),
        isUrl = false, is2D = false, loop = loop == true,
        targetSource = src, ownerSource = src,
    })
end)

RegisterNetEvent('pr_3dsound:server:playUrl', function(name, url, volume, loop)
    local src = source
    if not clientRateAllowed(src) or not clientIdAvailable(src, name) or not validUrl(url) then return end
    local target = hasBroadcastAce(src) and -1 or src
    local id = PlayUrl(target, name, url, volume, loop)
    if id then claimOwner(id, src) end
end)

RegisterNetEvent('pr_3dsound:server:playUrlPos', function(name, url, volume, coords, radius, loop)
    local src = source
    if not clientRateAllowed(src) or not clientIdAvailable(src, name) or not validUrl(url) or not coordsNearClient(src, coords) then return end
    local target = hasBroadcastAce(src) and -1 or src
    local id = PlayUrlPos(target, name, url, volume, coords, clamp(radius or 50.0, 1.0, CFG.MAX_CLIENT_RADIUS), loop)
    if id then claimOwner(id, src) end
end)

local function handleClientPlayUrlAttached(src, name, url, volume, entityNetId, radius, loop)
    if not clientRateAllowed(src) or not clientIdAvailable(src, name) or not validUrl(url) then return end
    local entity = NetworkGetEntityFromNetworkId(tonumber(entityNetId) or -1)
    if not entity or entity == 0 or not DoesEntityExist(entity) then return end
    if not coordsNearClient(src, GetEntityCoords(entity)) then return end
    local target = hasBroadcastAce(src) and -1 or src
    local id = PlayUrlAttached(target, name, url, volume, entityNetId, clamp(radius or 30.0, 1.0, CFG.MAX_CLIENT_RADIUS), loop)
    if id then claimOwner(id, src) end
end

RegisterNetEvent('pr_3dsound:server:playUrlAttached', function(name, url, volume, entityNetId, radius, loop)
    handleClientPlayUrlAttached(source, name, url, volume, entityNetId, radius, loop)
end)

RegisterNetEvent('pr_3dsound:server:attachSoundToEntity', function(name, url, volume, entityNetId, radius, loop)
    handleClientPlayUrlAttached(source, name, url, volume, entityNetId, radius, loop)
end)

local function guardedMutation(src, uniqueId, fn, ...)
    local index = getIndexByUniqueId(uniqueId)
    local sound = index and Sounds[index]
    if not canClientMutate(src, sound) then return false end
    return fn(uniqueId, ...)
end

RegisterNetEvent('pr_3dsound:server:attachToEntity', function(id, netId, offset) guardedMutation(source, id, AttachToEntity, netId, offset) end)
RegisterNetEvent('pr_3dsound:server:detachEntity', function(id) guardedMutation(source, id, DetachEntity) end)
RegisterNetEvent('pr_3dsound:server:pause', function(id) guardedMutation(source, id, Pause) end)
RegisterNetEvent('pr_3dsound:server:resume', function(id) guardedMutation(source, id, Resume) end)
RegisterNetEvent('pr_3dsound:server:stop', function(id) guardedMutation(source, id, Stop) end)
RegisterNetEvent('pr_3dsound:server:updateCoords', function(id, coords)
    if coordsNearClient(source, coords) then guardedMutation(source, id, UpdateCoords, coords) end
end)
RegisterNetEvent('pr_3dsound:server:setVolume', function(id, v) guardedMutation(source, id, SetVolume, v) end)
RegisterNetEvent('pr_3dsound:server:setVolumeMax', function(id, v) guardedMutation(source, id, SetVolumeMax, v) end)
RegisterNetEvent('pr_3dsound:server:setDistance', function(id, d) guardedMutation(source, id, SetDistance, clamp(d, 1.0, CFG.MAX_CLIENT_RADIUS)) end)
RegisterNetEvent('pr_3dsound:server:setLoop', function(id, v) guardedMutation(source, id, SetLoop, v) end)
RegisterNetEvent('pr_3dsound:server:setTimestamp', function(id, t) guardedMutation(source, id, SetTimestamp, t) end)
RegisterNetEvent('pr_3dsound:server:fadeIn', function(id, d, v) guardedMutation(source, id, FadeIn, d, v) end)
RegisterNetEvent('pr_3dsound:server:fadeOut', function(id, d) guardedMutation(source, id, FadeOut, d) end)
RegisterNetEvent('pr_3dsound:server:stopAll', function()
    if hasBroadcastAce(source) then StopAll() end
end)

RegisterNetEvent('pr_3dsound:server:soundEnded', function(uniqueId, token)
    local src = source
    local index = getIndexByUniqueId(uniqueId)
    local sound = index and Sounds[index]
    if not sound or sound.loop then return end
    local listener = sound.listeners[src]
    if not listener or listener.token ~= token then return end
    Stop(uniqueId)
end)

AddEventHandler('playerDropped', function()
    local src = source
    clientCooldown[src] = nil
    for _, sound in pairs(Sounds) do
        sound.listeners[src] = nil
        if sound.ownerSource == src and sound.targetSource == src then
            -- Self-only client sounds are garbage-collected when their owner leaves.
            sound._dropOwner = true
        end
    end
    for index, sound in pairs(Sounds) do
        if sound._dropOwner then Sounds[index] = nil end
    end
end)

CreateThread(function()
    while true do
        Wait(CFG.STREAM_INTERVAL_MS)
        local expired = {}
        local now = nowMs()

        for index, sound in pairs(Sounds) do
            if sound.expiresAtMs and now >= sound.expiresAtMs then
                expired[#expired + 1] = sound.uniqueId
            elseif sound.targetSnapshot and not sound.loop then
                -- Initial-only local effects: only remove disconnected listeners.
                for src, _ in pairs(sound.listeners) do
                    if not GetPlayerName(src) then sound.listeners[src] = nil end
                end
            else
                syncSound(index, sound)
            end
        end

        for i = 1, #expired do Stop(expired[i]) end
    end
end)
