# pr_3dsound  v2.0

Sistema de áudio 3D para FiveM com suporte a:

- **Arquivos locais** — `.ogg`, `.mp3`, `.weba` em `html/sounds/`
- **Streams diretos** — URLs http(s): rádios, CDN, SoundCloud (stream URL)
- **YouTube** — via IFrame API (vídeos com embedding habilitado pelo autor)
- **Efeito 3D posicional** — HRTF via Web Audio API (Howler Spatial)
- **FadeIn / FadeOut**, **Loop**, **Timestamp**, **SetVolume / SetVolumeMax**

> **Spotify** não é suportável: não disponibiliza stream de áudio puro sem OAuth.  
> **SoundCloud** funciona quando você usa a URL direta do arquivo de stream `.mp3`.  
> **YouTube**: vídeos bloqueados pelo autor (erro 101/150) não poderão ser reproduzidos.

---

## Exports — Server Side

```lua
-- Arquivo local (html/sounds/)
exports['pr_3dsound']:Play(coords, soundName, volume, radius, uniqueId, resourceName, loop)

-- Stream / YouTube (2D — ouvido em todo lugar)
exports['pr_3dsound']:PlayUrl(source, name, url, volume, loop)

-- Stream / YouTube (3D posicional)
exports['pr_3dsound']:PlayUrlPos(source, name, url, volume, coords, loop)

-- Controles (todos usam o uniqueId / name definido no Play*)
exports['pr_3dsound']:Pause(uniqueId)
exports['pr_3dsound']:Resume(uniqueId)
exports['pr_3dsound']:Stop(uniqueId)
exports['pr_3dsound']:UpdateCoords(uniqueId, coords)
exports['pr_3dsound']:SetVolume(uniqueId, volume)      -- 0.0 a 1.0 — plano (2D)
exports['pr_3dsound']:SetVolumeMax(uniqueId, volume)   -- 0.0 a 1.0 — máximo 3D
exports['pr_3dsound']:SetDistance(uniqueId, radius)
exports['pr_3dsound']:SetLoop(uniqueId, true/false)
exports['pr_3dsound']:SetTimestamp(uniqueId, seconds)
exports['pr_3dsound']:FadeIn(uniqueId, durationMs, targetVolume)
exports['pr_3dsound']:FadeOut(uniqueId, durationMs)
exports['pr_3dsound']:SoundExists(uniqueId)            -- retorna true/false
```

---

## Exports — Client Side

```lua
exports['pr_3dsound']:SoundExists(uniqueId)   -- true/false
exports['pr_3dsound']:IsPlaying(uniqueId)     -- true/false
exports['pr_3dsound']:IsPaused(uniqueId)      -- true/false
exports['pr_3dsound']:GetInfo(uniqueId)       -- tabela com vol, pos, dist, etc.
```

---

## Exemplos de uso

### Arquivo local 3D (ex: tiro de pistola em coords fixas)
```lua
local coords = vector3(100.0, 200.0, 30.0)
exports['pr_3dsound']:Play(coords, 'pistola.ogg', 1.0, 50, 'som_pistola_1', 'pr-wep')
```

### Rádio em posição 3D (stream direto)
```lua
local coords = vector3(100.0, 200.0, 30.0)
exports['pr_3dsound']:PlayUrlPos(-1, 'radio_praia', 'https://stream.exemplo.com/radio.mp3', 0.8, coords, true)
exports['pr_3dsound']:SetDistance('radio_praia', 80)
```

### YouTube 3D em uma posição (boombox, palco, etc.)
```lua
local coords = vector3(100.0, 200.0, 30.0)
exports['pr_3dsound']:PlayUrlPos(-1, 'boombox_1', 'https://www.youtube.com/watch?v=6Dh-RL__uN4', 0.8, coords, false)
exports['pr_3dsound']:SetDistance('boombox_1', 30)

-- Parar depois de 60 segundos
Citizen.SetTimeout(60000, function()
    exports['pr_3dsound']:Stop('boombox_1')
end)
```

### YouTube 2D (ambiente, menu, cutscene)
```lua
exports['pr_3dsound']:PlayUrl(-1, 'menu_music', 'https://www.youtube.com/watch?v=6Dh-RL__uN4', 0.5, false)
```

### FadeIn / FadeOut
```lua
exports['pr_3dsound']:PlayUrl(-1, 'ambient', 'https://stream.exemplo.com/ambient.mp3', 1.0, true)
exports['pr_3dsound']:FadeIn('ambient', 3000, 0.8)  -- 3 segundos até 80%

-- Para fadeout antes de parar:
exports['pr_3dsound']:FadeOut('ambient', 2000)
Citizen.SetTimeout(2100, function()
    exports['pr_3dsound']:Stop('ambient')
end)
```

### Verificar estado
```lua
if exports['pr_3dsound']:IsPlaying('boombox_1') then
    print('tocando!')
end
local info = exports['pr_3dsound']:GetInfo('boombox_1')
if info then
    print('volume:', info.vol, 'dist:', info.dist)
end
```

---

## Estrutura de arquivos

```
pr_3dsound/
├── client/
│   ├── client.lua
│   └── test_commands.lua
│
├── server/
│   ├── server.lua
│   └── version.lua
│
├── fxmanifest.lua
├── README.md
└── html/
    ├── index.html
    ├── scripts/
    │   ├── SoundPlayer.js
    │   └── listener.js
    │
    └── sounds/
        ├── standard-sound.ogg
        └── custom-folder/
            ├── my-sound.ogg
            └── my-sound.mp3
```

---

## Notas técnicas

- O loop 3D roda a cada **250 ms** (ou 100 ms com mais de 8 emissores ativos).
- O volume de distância é calculado em Lua e enviado ao NUI; o volume nunca vai abaixo de 0.
- Ao parar um som, `.unload()` é chamado no Howl para liberar nós do Web Audio context.
- URLs são sanitizadas com DOMPurify antes de qualquer uso no NUI.
- Sons YouTube que não permitem embedding retornam erro 101/150 no console NUI — isso é uma restrição do YouTube, não do script.





Melhorias a serem feitas:
1. por favor pode gerar  o embed do SoundCloud.
2. Ter opcao de ao dar play poder fazer o attach do som em algo.
3. auto update de coords quando um som e tocado em um veiculo.
4. raycast para detectar paredes assim o som perde alcande.
5. som abafar ao abrir e fechar portas e janelas.