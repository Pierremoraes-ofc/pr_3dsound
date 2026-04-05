--[[
    pr_3dsound — client.lua  v2.0
    Suporte: arquivos locais, URL streams, YouTube (iframe API), SoundCloud
    Recursos: Play, PlayUrl, PlayUrlPos, Pause, Resume, Stop,
              UpdateCoords, SetVolume, SetVolumeMax, SetDistance,
              SetLoop, SetTimestamp, FadeIn, FadeOut,
              SoundExists, IsPlaying, IsPaused, GetInfo
]]

local Sounds         = {}  -- { playing, paused, pos, vol, maxVol, dist, isUrl, is2D }
local emittersActive = 0

-- =============================================
--  UTILITÁRIOS
-- =============================================

local function rot_to_direction(rot)
    local rZ  = rot.z * 0.0174532924
    local rX  = rot.x * 0.0174532924
    local num = math.abs(math.cos(rX))
    return {
        x = (-math.sin(rZ)) * num,
        y = (math.cos(rZ))  * num,
        z = math.sin(rX)
    }
end

local function clamp(v, lo, hi)
    return math.max(lo, math.min(hi, v))
end

local function calcDistanceVolume(s, coords)
    local dist = #(coords - vector3(s.pos.x, s.pos.y, s.pos.z))
    local mult  = (s.maxVol or s.vol) / (s.dist or 30.0)
    return clamp((s.maxVol or s.vol) - (dist * mult), 0.0, 1.0)
end

-- =============================================
--  LOOP DE ATUALIZAÇÃO 3D
-- =============================================

local function startLoop()
    if emittersActive > 0 then return end
    emittersActive = 1
    Citizen.CreateThread(function()
        local ped = PlayerPedId()
        while emittersActive > 0 do
            emittersActive = 0
            local coords  = GetEntityCoords(ped)
            local camDir  = rot_to_direction(GetGameplayCamRot(0))

            for k, v in pairs(Sounds) do
                if v.playing and not v.is2D then
                    emittersActive = emittersActive + 1
                    local distVol = calcDistanceVolume(v, coords)
                    SendNUIMessage({
                        type       = 'updateVolume',
                        soundIndex = k,
                        volume     = distVol,
                        playerPos  = { x = coords.x, y = coords.y, z = coords.z },
                        camDir     = camDir,
                    })
                end
            end

            local wait = emittersActive > 8 and 100 or 250
            Citizen.Wait(wait)
        end
    end)
end

-- =============================================
--  PLAY — arquivo local
-- =============================================

RegisterNetEvent('pr_3dsound:client:play')
AddEventHandler('pr_3dsound:client:play', function(index, coords, soundName, volume, radius, uniqueId, loop)
    Sounds[index] = {
        uniqueId = uniqueId,
        pos      = coords,
        vol      = volume,
        maxVol   = volume,
        dist     = radius,
        playing  = true,
        paused   = false,
        is2D     = false,
        isUrl    = false,
        loop     = loop or false,
    }

    local distVol = calcDistanceVolume(Sounds[index], GetEntityCoords(PlayerPedId()))
    SendNUIMessage({
        type        = 'play',
        soundIndex  = index,
        file        = soundName,
        volume      = distVol,
        pos         = coords,
        loop        = loop or false,
    })
    startLoop()
end)

-- =============================================
--  PLAY URL — 2D (sem posição, ouve em todo lugar)
-- =============================================

RegisterNetEvent('pr_3dsound:client:playUrl')
AddEventHandler('pr_3dsound:client:playUrl', function(index, name, url, volume, loop, options)
    Sounds[index] = {
        uniqueId = name,
        vol      = volume,
        maxVol   = volume,
        playing  = true,
        paused   = false,
        is2D     = true,
        isUrl    = true,
        loop     = loop or false,
        url      = url,
    }
    SendNUIMessage({
        type       = 'playUrl',
        soundIndex = index,
        url        = url,
        volume     = volume,
        loop       = loop or false,
        options    = options or {},
    })
end)

-- =============================================
--  PLAY URL POS — 3D posicional
-- =============================================

RegisterNetEvent('pr_3dsound:client:playUrlPos')
AddEventHandler('pr_3dsound:client:playUrlPos', function(index, name, url, volume, coords, radius, loop, options)
    Sounds[index] = {
        uniqueId = name,
        pos      = coords,
        vol      = volume,
        maxVol   = volume,
        dist     = radius,
        playing  = true,
        paused   = false,
        is2D     = false,
        isUrl    = true,
        loop     = loop or false,
        url      = url,
    }
    local distVol = calcDistanceVolume(Sounds[index], GetEntityCoords(PlayerPedId()))
    SendNUIMessage({
        type       = 'playUrlPos',
        soundIndex = index,
        url        = url,
        volume     = distVol,
        pos        = coords,
        loop       = loop or false,
        options    = options or {},
    })
    startLoop()
end)

-- =============================================
--  PAUSE / RESUME
-- =============================================

RegisterNetEvent('pr_3dsound:client:pause')
AddEventHandler('pr_3dsound:client:pause', function(index)
    if not Sounds[index] then return end
    Sounds[index].playing = false
    Sounds[index].paused  = true
    SendNUIMessage({ type = 'pause', soundIndex = index })
end)

RegisterNetEvent('pr_3dsound:client:resume')
AddEventHandler('pr_3dsound:client:resume', function(index)
    if not Sounds[index] then return end
    Sounds[index].playing = true
    Sounds[index].paused  = false
    SendNUIMessage({ type = 'resume', soundIndex = index })
    startLoop()
end)

-- =============================================
--  STOP
-- =============================================

RegisterNetEvent('pr_3dsound:client:stop')
AddEventHandler('pr_3dsound:client:stop', function(index)
    if not Sounds[index] then return end
    Sounds[index].playing = false
    SendNUIMessage({ type = 'stop', soundIndex = index })
    Sounds[index] = nil
end)

-- =============================================
--  UPDATE COORDS
-- =============================================

RegisterNetEvent('pr_3dsound:client:updateCoords')
AddEventHandler('pr_3dsound:client:updateCoords', function(index, coords)
    if not Sounds[index] then return end
    Sounds[index].pos = coords
    SendNUIMessage({ type = 'updateCoords', soundIndex = index, pos = coords })
end)

-- =============================================
--  SET VOLUME / SET VOLUME MAX
-- =============================================

RegisterNetEvent('pr_3dsound:client:setVolume')
AddEventHandler('pr_3dsound:client:setVolume', function(index, volume)
    if not Sounds[index] then return end
    Sounds[index].vol = clamp(volume, 0.0, 1.0)
    SendNUIMessage({ type = 'setVolume', soundIndex = index, volume = Sounds[index].vol })
end)

RegisterNetEvent('pr_3dsound:client:setVolumeMax')
AddEventHandler('pr_3dsound:client:setVolumeMax', function(index, volume)
    if not Sounds[index] then return end
    Sounds[index].maxVol = clamp(volume, 0.0, 1.0)
    SendNUIMessage({ type = 'setVolumeMax', soundIndex = index, volume = Sounds[index].maxVol })
end)

-- =============================================
--  SET DISTANCE
-- =============================================

RegisterNetEvent('pr_3dsound:client:setDistance')
AddEventHandler('pr_3dsound:client:setDistance', function(index, dist)
    if not Sounds[index] then return end
    Sounds[index].dist = dist
    SendNUIMessage({ type = 'setDistance', soundIndex = index, distance = dist })
end)

-- =============================================
--  SET LOOP
-- =============================================

RegisterNetEvent('pr_3dsound:client:setLoop')
AddEventHandler('pr_3dsound:client:setLoop', function(index, loopVal)
    if not Sounds[index] then return end
    Sounds[index].loop = loopVal
    SendNUIMessage({ type = 'setLoop', soundIndex = index, loop = loopVal })
end)

-- =============================================
--  SET TIMESTAMP
-- =============================================

RegisterNetEvent('pr_3dsound:client:setTimestamp')
AddEventHandler('pr_3dsound:client:setTimestamp', function(index, time)
    if not Sounds[index] then return end
    SendNUIMessage({ type = 'setTimestamp', soundIndex = index, time = time })
end)

-- =============================================
--  FADE IN / FADE OUT
-- =============================================

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
--  CALLBACKS DO NUI → CLIENT
-- =============================================

-- Som terminou naturalmente (sem loop)
RegisterNUICallback('soundEnded', function(data, cb)
    local index = data.index
    if Sounds[index] then
        Sounds[index].playing = false
        Sounds[index] = nil
    end
    cb('ok')
end)

-- Solicitação de informações de estado
RegisterNUICallback('getInfo', function(data, cb)
    local index = data.index
    if not Sounds[index] then cb(nil); return end
    cb(Sounds[index])
end)

-- =============================================
--  EXPORTS CLIENT-SIDE
-- =============================================

exports('SoundExists', function(uniqueId)
    for _, v in pairs(Sounds) do
        if v.uniqueId == uniqueId then return true end
    end
    return false
end)

exports('IsPlaying', function(uniqueId)
    for _, v in pairs(Sounds) do
        if v.uniqueId == uniqueId then return v.playing end
    end
    return false
end)

exports('IsPaused', function(uniqueId)
    for _, v in pairs(Sounds) do
        if v.uniqueId == uniqueId then return v.paused end
    end
    return false
end)

exports('GetInfo', function(uniqueId)
    for _, v in pairs(Sounds) do
        if v.uniqueId == uniqueId then return v end
    end
    return nil
end)
