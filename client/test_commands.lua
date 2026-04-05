--[[
    pr_3dsound — test_commands.lua  v2.1
    Comandos de teste via chat. Apenas para desenvolvimento — remova em produção!

    ARQUITETURA:
    • /play, /play2d, /playfile  →  TriggerServerEvent (Play acontece no server)
    • /spause, /sresume, /sstop, /svol, etc. → TriggerServerEvent também
    • /sinfo → export client-side (estado local)

    ╔══════════════════════════════════════════════════════════════╗
    ║  COMANDOS                                                    ║
    ║                                                              ║
    ║  /play     <url> [volume] [raio]                             ║
    ║  /play2d   <url> [volume]                                    ║
    ║  /playfile <arquivo> [volume] [raio]                         ║
    ║  /spause   <id>                                              ║
    ║  /sresume  <id>                                              ║
    ║  /sstop    <id>                                              ║
    ║  /svol     <id> <0.0-1.0>                                    ║
    ║  /sdist    <id> <raio>                                       ║
    ║  /sloop    <id> <on|off>                                     ║
    ║  /sfade    <id> <in|out> [ms]                                ║
    ║  /smove    <id>                                              ║
    ║  /sinfo    <id>                                              ║
    ║  /sstopall                                                   ║
    ║  /sound    (lista todos os comandos)                         ║
    ╚══════════════════════════════════════════════════════════════╝
]]

-- ─── helpers ──────────────────────────────────────────────────────────────────

-- Exports CLIENT-SIDE (SoundExists, GetInfo, IsPlaying, IsPaused — de client.lua)
local pr = exports['pr_3dsound']

-- Gera ID unico legivel: snd_<timer>_<rand>
local function genId()
    return ('snd_%d_%d'):format(GetGameTimer() % 99999, math.random(100, 999))
end

-- Mensagens coloridas no chat
local function msg(text, r, g, b)
    TriggerEvent('chat:addMessage', {
        color     = { r or 0, g or 200, b or 255 },
        multiline = true,
        args      = { '[3DSnd]', text },
    })
end

local function ok(t)  msg(t,  60, 220, 100) end
local function err(t) msg(t, 255,  80,  80) end
local function inf(t) msg(t,  80, 180, 255) end

-- Checa se o ID existe (client-side) antes de controles
local function checkId(id)
    if not id then
        err('Informe o ID do som.')
        return false
    end
    if not pr:SoundExists(id) then
        err(('ID nao encontrado: ^3%s^7  (terminou ou nunca existiu)'):format(id))
        return false
    end
    return true
end

-- ─── /play <url> [volume] [raio] ─────────────────────────────────────────────
-- URL 3D na posicao atual do jogador

RegisterCommand('play', function(source, args)
    local url    = args[1]
    local volume = tonumber(args[2]) or 0.8
    local radius = tonumber(args[3]) or 50.0

    if not url then
        err('Uso: /play ^3<url>^7 [volume 0-1] [raio metros]')
        inf('Ex: /play https://www.youtube.com/watch?v=... 0.8 40')
        return
    end

    local id     = genId()
    local coords = GetEntityCoords(PlayerPedId())

    -- Envia ao SERVER que distribui para os jogadores no raio
    TriggerServerEvent('pr_3dsound:server:playUrlPos', id, url, volume, coords, false)

    -- Ajusta distancia apos o server processar
    Citizen.SetTimeout(300, function()
        TriggerServerEvent('pr_3dsound:server:setDistance', id, radius)
    end)

    ok(('|>> Som 3D iniciado!'))
    ok(('    ID  : ^3%s'):format(id))
    inf(('    URL : %s'):format(url))
    inf(('    Vol : %.2f  |  Raio: %.0f m'):format(volume, radius))
    inf('    Use o ID acima para pausar, parar, etc.')
end, false)

-- ─── /play2d <url> [volume] ───────────────────────────────────────────────────
-- URL 2D global (sem posicao, ouvido em todo lugar)

RegisterCommand('play2d', function(source, args)
    local url    = args[1]
    local volume = tonumber(args[2]) or 0.8

    if not url then
        err('Uso: /play2d ^3<url>^7 [volume 0-1]')
        inf('Ex: /play2d https://www.youtube.com/watch?v=... 0.5')
        return
    end

    local id = genId()
    TriggerServerEvent('pr_3dsound:server:playUrl', id, url, volume, false)

    ok(('|>> Som 2D global iniciado!'))
    ok(('    ID  : ^3%s'):format(id))
    inf(('    URL : %s'):format(url))
    inf(('    Vol : %.2f  (ouvido em todo lugar)'):format(volume))
end, false)

-- ─── /playfile <arquivo> [volume] [raio] ─────────────────────────────────────
-- Arquivo local de html/sounds/

RegisterCommand('playfile', function(source, args)
    local file   = args[1]
    local volume = tonumber(args[2]) or 1.0
    local radius = tonumber(args[3]) or 30.0

    if not file then
        err('Uso: /playfile ^3<arquivo>^7 [volume] [raio]')
        inf('Ex: /playfile pr-wep/pistola.ogg 1.0 40')
        return
    end

    local id     = genId()
    local coords = GetEntityCoords(PlayerPedId())

    TriggerServerEvent('pr_3dsound:server:play', coords, file, volume, radius, id, nil, false)

    ok(('|>> Arquivo local iniciado!'))
    ok(('    ID      : ^3%s'):format(id))
    inf(('    Arquivo : %s'):format(file))
    inf(('    Vol: %.2f  |  Raio: %.0f m'):format(volume, radius))
end, false)

-- ─── /spause <id> ────────────────────────────────────────────────────────────

RegisterCommand('spause', function(source, args)
    local id = args[1]
    if not checkId(id) then return end
    TriggerServerEvent('pr_3dsound:server:pause', id)
    ok(('Pausado: ^3%s'):format(id))
end, false)

-- ─── /sresume <id> ───────────────────────────────────────────────────────────

RegisterCommand('sresume', function(source, args)
    local id = args[1]
    if not checkId(id) then return end
    TriggerServerEvent('pr_3dsound:server:resume', id)
    ok(('Retomado: ^3%s'):format(id))
end, false)

-- ─── /sstop <id> ─────────────────────────────────────────────────────────────

RegisterCommand('sstop', function(source, args)
    local id = args[1]
    if not checkId(id) then return end
    TriggerServerEvent('pr_3dsound:server:stop', id)
    ok(('Parado: ^3%s'):format(id))
end, false)

-- ─── /svol <id> <volume> ─────────────────────────────────────────────────────

RegisterCommand('svol', function(source, args)
    local id  = args[1]
    local vol = tonumber(args[2])
    if not checkId(id) then return end
    if not vol then err('Uso: /svol <id> <0.0 - 1.0>'); return end
    vol = math.max(0.0, math.min(1.0, vol))
    TriggerServerEvent('pr_3dsound:server:setVolume', id, vol)
    ok(('Volume de ^3%s^7 -> %.2f'):format(id, vol))
end, false)

-- ─── /sdist <id> <raio> ──────────────────────────────────────────────────────

RegisterCommand('sdist', function(source, args)
    local id   = args[1]
    local dist = tonumber(args[2])
    if not checkId(id) then return end
    if not dist then err('Uso: /sdist <id> <raio em metros>'); return end
    TriggerServerEvent('pr_3dsound:server:setDistance', id, dist)
    ok(('Raio de ^3%s^7 -> %.0f m'):format(id, dist))
end, false)

-- ─── /sloop <id> <on|off> ────────────────────────────────────────────────────

RegisterCommand('sloop', function(source, args)
    local id  = args[1]
    local val = args[2]
    if not checkId(id) then return end
    if not val then err('Uso: /sloop <id> <on|off>'); return end
    local loopVal = (val == 'on' or val == '1' or val == 'true')
    TriggerServerEvent('pr_3dsound:server:setLoop', id, loopVal)
    ok(('Loop de ^3%s^7 -> %s'):format(id, loopVal and 'ON' or 'OFF'))
end, false)

-- ─── /sfade <id> <in|out> [ms] ───────────────────────────────────────────────

RegisterCommand('sfade', function(source, args)
    local id       = args[1]
    local dir      = args[2]
    local duration = tonumber(args[3]) or 2000
    if not checkId(id) then return end
    if not dir then err('Uso: /sfade <id> <in|out> [ms]'); return end

    if dir == 'in' then
        TriggerServerEvent('pr_3dsound:server:fadeIn', id, duration, 1.0)
        ok(('FadeIn ^3%s^7 em %d ms'):format(id, duration))
    elseif dir == 'out' then
        TriggerServerEvent('pr_3dsound:server:fadeOut', id, duration)
        ok(('FadeOut ^3%s^7 em %d ms'):format(id, duration))
    else
        err('Direcao invalida — use: in  ou  out')
    end
end, false)

-- ─── /smove <id> ─────────────────────────────────────────────────────────────
-- Move o som para a posicao atual do jogador

RegisterCommand('smove', function(source, args)
    local id = args[1]
    if not checkId(id) then return end
    local coords = GetEntityCoords(PlayerPedId())
    TriggerServerEvent('pr_3dsound:server:updateCoords', id, coords)
    ok(('Som ^3%s^7 movido para (%.1f, %.1f, %.1f)'):format(id, coords.x, coords.y, coords.z))
end, false)

-- ─── /sinfo <id> ─────────────────────────────────────────────────────────────

RegisterCommand('sinfo', function(source, args)
    local id = args[1]
    if not checkId(id) then return end

    local info = pr:GetInfo(id)
    if not info then
        inf(('ID ^3%s^7 existe mas sem estado local ainda (pode estar carregando).'):format(id))
        return
    end

    inf(('=== Info: ^3%s^7 ==='):format(id))
    inf(('  Playing : %s  |  Paused: %s  |  Loop: %s'):format(
        tostring(info.playing), tostring(info.paused), tostring(info.loop)))
    inf(('  Vol     : %.2f  |  VolMax: %.2f  |  Raio: %.0f m'):format(
        info.vol or 0, info.maxVol or 0, info.dist or 0))
    if info.pos then
        inf(('  Posicao : %.1f, %.1f, %.1f'):format(info.pos.x, info.pos.y, info.pos.z))
    end
    if info.url then
        inf(('  URL     : %s'):format(info.url))
    end
    inf(('  Tipo    : %s  |  isUrl: %s'):format(
        info.is2D and '2D global' or '3D posicional', tostring(info.isUrl)))
end, false)

-- ─── /sstopall ───────────────────────────────────────────────────────────────

RegisterCommand('sstopall', function()
    SendNUIMessage({ type = 'stopAll' })
    ok('Reset NUI — todos os sons parados localmente.')
end, false)

-- ─── /sound — ajuda ──────────────────────────────────────────────────────────

RegisterCommand('sound', function()
    inf('======= pr_3dsound — Comandos de Teste =======')
    inf('^3/play     ^7<url> [vol] [raio]       -> URL 3D na sua posicao')
    inf('^3/play2d   ^7<url> [vol]              -> URL 2D global')
    inf('^3/playfile ^7<arquivo> [vol] [raio]   -> arquivo local 3D')
    inf('^3/spause   ^7<id>                     -> pausar')
    inf('^3/sresume  ^7<id>                     -> retomar')
    inf('^3/sstop    ^7<id>                     -> parar')
    inf('^3/svol     ^7<id> <0-1>               -> volume')
    inf('^3/sdist    ^7<id> <metros>            -> raio de audicao')
    inf('^3/sloop    ^7<id> <on|off>            -> loop')
    inf('^3/sfade    ^7<id> <in|out> [ms]       -> fade')
    inf('^3/smove    ^7<id>                     -> mover p/ sua posicao')
    inf('^3/sinfo    ^7<id>                     -> ver estado')
    inf('^3/sstopall ^7                         -> parar tudo')
end, false)

-- ─── hint ao spawnar ─────────────────────────────────────────────────────────

AddEventHandler('playerSpawned', function()
    Citizen.Wait(3000)
    inf('pr_3dsound ativo. ^3/sound^7 para ver os comandos de teste.')
end)
