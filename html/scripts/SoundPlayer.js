/**
 * pr_3dsound — SoundPlayer.js  v2.0
 *
 * Gerencia três tipos de fonte de áudio:
 *   1. LOCAL  — arquivos .ogg/.mp3/.weba em html/sounds/
 *   2. STREAM — URLs diretas (rádio, CDN) via Howler com html5:true
 *   3. YOUTUBE — YouTube IFrame API (via ytPlayer)
 *
 * SoundCloud: a API pública do SoundCloud exige client_id e foi descontinuada
 * para novos apps. A forma suportada é usar a URL de stream direto do SoundCloud
 * (ex: https://soundcloud.com/artista/musica) — alguns faixas permitem embed;
 * para reprodução confiável em FiveM use a URL do stream .mp3 quando disponível.
 * O player trata qualquer http/https não-YouTube como stream direto via Howler.
 *
 * Spotify não oferece API de stream de áudio puro sem autenticação OAuth,
 * portanto não é possível reproduzir via iframe/src em contexto FiveM.
 */

'use strict';

// ─── Detecção de tipo de URL ──────────────────────────────────────────────────

function detectUrlType(url) {
    if (!url) return 'local';
    if (/^https?:\/\//i.test(url)) {
        if (/youtube\.com\/watch|youtu\.be\//i.test(url)) return 'youtube';
        return 'stream';
    }
    return 'local';
}

function extractYouTubeId(url) {
    var m = url.match(/(?:v=|youtu\.be\/)([A-Za-z0-9_-]{11})/);
    return m ? m[1] : null;
}

// ─── Registro de players ──────────────────────────────────────────────────────

var players   = {};  // índice → { type, howl|ytPlayer, vol, maxVol, dist, pos, playing, paused, loop }
var ytReady   = false;
var ytQueue   = [];  // comandos pendentes enquanto a API do YouTube não carregou

// ─── YouTube IFrame API ───────────────────────────────────────────────────────

window.onYouTubeIframeAPIReady = function () {
    ytReady = true;
    ytQueue.forEach(function (fn) { fn(); });
    ytQueue = [];
};

function createYTPlayer(index, videoId, volume, loop, onReady) {
    var containerId = 'yt-' + index;
    var div = document.getElementById(containerId);
    if (!div) {
        div = document.createElement('div');
        div.id = containerId;
        div.style.display = 'none';
        document.getElementById('trash').appendChild(div);
    }

    var p = new YT.Player(containerId, {
        height: '0', width: '0',
        videoId: videoId,
        playerVars: {
            autoplay:    1,
            controls:    0,
            disablekb:   1,
            iv_load_policy: 3,
            modestbranding: 1,
            playsinline: 1,
        },
        events: {
            onReady: function (e) {
                e.target.setVolume(Math.round(volume * 100));
                if (loop) {
                    e.target.setLoop(true);
                    // loop via playlist do próprio vídeo
                    e.target.loadVideoById({ videoId: videoId, suggestedQuality: 'small' });
                }
                if (onReady) onReady(e.target);
            },
            onStateChange: function (e) {
                if (e.data === YT.PlayerState.ENDED) {
                    if (players[index] && players[index].loop) {
                        e.target.seekTo(0);
                        e.target.playVideo();
                    } else {
                        notifyEnded(index);
                    }
                }
            },
            onError: function (e) {
                console.warn('[pr_3dsound] YouTube error', e.data, 'index', index);
            }
        }
    });
    return p;
}

// ─── Notificação ao client Lua ────────────────────────────────────────────────

function notifyEnded(index) {
    if (!players[index]) return;
    players[index].playing = false;
    $.post('https://pr_3dsound/soundEnded', JSON.stringify({ index: index }));
    cleanupPlayer(index);
}

function cleanupPlayer(index) {
    var p = players[index];
    if (!p) return;
    if (p.type === 'local' || p.type === 'stream') {
        if (p.howl) { p.howl.stop(); p.howl.unload(); }
    } else if (p.type === 'youtube') {
        if (p.ytPlayer) {
            try { p.ytPlayer.stopVideo(); p.ytPlayer.destroy(); } catch (e) {}
        }
        var div = document.getElementById('yt-' + index);
        if (div) div.remove();
    }
    delete players[index];
}

// ─── Howler helpers ───────────────────────────────────────────────────────────

function createHowl(src, volume, loop, is3D, pos, onEnd) {
    var h = new Howl({
        src:    [src],
        volume: volume,
        loop:   loop || false,
        html5:  /^https?:\/\//i.test(src),   // streams precisam de html5
        onend:  function () { if (!loop && onEnd) onEnd(); },
        // ✅ ADICIONAR ISSO:
        onloaderror: function (id, err) {
            console.error('[pr_3dsound] Falha ao carregar áudio:', src, err);
        },
        onplayerror: function (id, err) {
            console.error('[pr_3dsound] Falha ao tocar áudio:', src, err);
            // Tenta desbloquear o AudioContext e repetir
            Howler.ctx && Howler.ctx.resume && Howler.ctx.resume().then(function () {
                h.play();
            });
        },
    });
    if (is3D) {
        h.pannerAttr({
            panningModel:  'HRTF',
            rolloffFactor: 1,
            distanceModel: 'linear',
            maxDistance:   10000,
        });
        if (pos) h.pos(pos.x, pos.y, pos.z);
    }
    return h;
}

// ─── API pública ──────────────────────────────────────────────────────────────

var SoundPlayer = {

    // ── play (arquivo local) ─────────────────────────────────────────────────
    play: function (index, file, volume, pos, loop) {
        cleanupPlayer(index);
        var src  = './sounds/' + DOMPurify.sanitize(file);
        var howl = createHowl(src, volume, loop, !!pos, pos, function () { notifyEnded(index); });
        if (pos) Howler.pos(pos.x, pos.y, pos.z);
        howl.play();
        players[index] = { type: 'local', howl: howl, vol: volume, maxVol: volume, pos: pos, playing: true, paused: false, loop: loop || false };
    },

    // ── playUrl (stream 2D) ──────────────────────────────────────────────────
    playUrl: function (index, url, volume, loop, options) {
        cleanupPlayer(index);
        options = options || {};
        var urlType = detectUrlType(url);

        if (urlType === 'youtube') {
            var vid = extractYouTubeId(url);
            if (!vid) { console.warn('[pr_3dsound] YouTube ID inválido:', url); return; }
            players[index] = { type: 'youtube', ytPlayer: null, vol: volume, maxVol: volume, playing: false, paused: false, loop: loop || false };
            var doCreate = function () {
                players[index].ytPlayer = createYTPlayer(index, vid, volume, loop, function (p) {
                    players[index].playing = true;
                    if (options.onPlayStart) options.onPlayStart({ index: index });
                });
            };
            ytReady ? doCreate() : ytQueue.push(doCreate);
        } else {
            // stream direto (rádio, SoundCloud stream URL, CDN, etc.)
            var howl = createHowl(DOMPurify.sanitize(url), volume, loop, false, null, function () {
                if (options.onPlayEnd) options.onPlayEnd({ index: index, url: url });
                notifyEnded(index);
            });
            if (options.onLoading) howl.on('load', function () { options.onLoading({ index: index }); });
            howl.play();
            players[index] = { type: 'stream', howl: howl, vol: volume, maxVol: volume, playing: true, paused: false, loop: loop || false };
            if (options.onPlayStart) howl.once('play', function () { options.onPlayStart({ index: index }); });
        }
    },

    // ── playUrlPos (stream 3D posicional) ────────────────────────────────────
    playUrlPos: function (index, url, volume, pos, loop, options) {
        cleanupPlayer(index);
        options = options || {};
        var urlType = detectUrlType(url);

        if (urlType === 'youtube') {
            // YouTube não tem áudio Web Audio posicional; tocamos em 2D e
            // controlamos volume por distância manualmente no loop Lua
            var vid = extractYouTubeId(url);
            if (!vid) { console.warn('[pr_3dsound] YouTube ID inválido:', url); return; }
            players[index] = { type: 'youtube', ytPlayer: null, vol: volume, maxVol: volume, pos: pos, playing: false, paused: false, loop: loop || false };
            var doCreate = function () {
                players[index].ytPlayer = createYTPlayer(index, vid, volume, loop, function (p) {
                    players[index].playing = true;
                    if (options.onPlayStart) options.onPlayStart({ index: index });
                });
            };
            ytReady ? doCreate() : ytQueue.push(doCreate);
        } else {
            var howl = createHowl(DOMPurify.sanitize(url), volume, loop, true, pos, function () {
                if (options.onPlayEnd) options.onPlayEnd({ index: index, url: url });
                notifyEnded(index);
            });
            if (options.onLoading) howl.on('load', function () { options.onLoading({ index: index }); });
            Howler.pos(pos.x, pos.y, pos.z);
            howl.play();
            players[index] = { type: 'stream', howl: howl, vol: volume, maxVol: volume, pos: pos, playing: true, paused: false, loop: loop || false };
            if (options.onPlayStart) howl.once('play', function () { options.onPlayStart({ index: index }); });
        }
    },

    // ── updateVolume (chamado pelo loop 3D do Lua) ───────────────────────────
    updateVolume: function (index, volume, playerPos, camDir) {
        var p = players[index];
        if (!p) return;
        var v = Math.max(0, Math.min(p.maxVol || 1, volume));

        if (p.type === 'youtube') {
            if (p.ytPlayer && p.ytPlayer.setVolume) p.ytPlayer.setVolume(Math.round(v * 100));
        } else if (p.howl) {
            p.howl.volume(v);
        }

        // Atualiza listener (câmera) — para Howler
        if (playerPos) Howler.pos(playerPos.x, playerPos.y, playerPos.z);
        if (camDir)    Howler.orientation(camDir.x, camDir.y, camDir.z, 0, 0, 1);
    },

    // ── pause ─────────────────────────────────────────────────────────────────
    pause: function (index) {
        var p = players[index];
        if (!p) return;
        p.paused  = true;
        p.playing = false;
        if (p.type === 'youtube') { if (p.ytPlayer) p.ytPlayer.pauseVideo(); }
        else if (p.howl)          { p.howl.pause(); }
    },

    // ── resume ────────────────────────────────────────────────────────────────
    resume: function (index) {
        var p = players[index];
        if (!p) return;
        p.paused  = false;
        p.playing = true;
        if (p.type === 'youtube') { if (p.ytPlayer) p.ytPlayer.playVideo(); }
        else if (p.howl)          { p.howl.play(); }
    },

    // ── stop ──────────────────────────────────────────────────────────────────
    stop: function (index) {
        cleanupPlayer(index);
    },

    // ── updateCoords ─────────────────────────────────────────────────────────
    updateCoords: function (index, pos) {
        var p = players[index];
        if (!p) return;
        p.pos = pos;
        if ((p.type === 'local' || p.type === 'stream') && p.howl) p.howl.pos(pos.x, pos.y, pos.z);
    },

    // ── setVolume (2D flat) ───────────────────────────────────────────────────
    setVolume: function (index, volume) {
        var p = players[index];
        if (!p) return;
        p.vol = Math.max(0, Math.min(1, volume));
        if (p.type === 'youtube') { if (p.ytPlayer) p.ytPlayer.setVolume(Math.round(p.vol * 100)); }
        else if (p.howl)          { p.howl.volume(p.vol); }
    },

    // ── setVolumeMax (para sons 3D — volume máximo quando distância = 0) ─────
    setVolumeMax: function (index, volume) {
        var p = players[index];
        if (!p) return;
        p.maxVol = Math.max(0, Math.min(1, volume));
    },

    // ── setDistance ───────────────────────────────────────────────────────────
    setDistance: function (index, distance) {
        var p = players[index];
        if (!p) return;
        p.dist = distance;
        if ((p.type === 'local' || p.type === 'stream') && p.howl) {
            p.howl.pannerAttr({ maxDistance: distance * 2 });
        }
    },

    // ── setLoop ───────────────────────────────────────────────────────────────
    setLoop: function (index, loopVal) {
        var p = players[index];
        if (!p) return;
        p.loop = loopVal;
        if (p.type === 'youtube') { if (p.ytPlayer) p.ytPlayer.setLoop(loopVal); }
        else if (p.howl)          { p.howl.loop(loopVal); }
    },

    // ── setTimestamp ──────────────────────────────────────────────────────────
    setTimestamp: function (index, time) {
        var p = players[index];
        if (!p) return;
        if (p.type === 'youtube') { if (p.ytPlayer) p.ytPlayer.seekTo(time, true); }
        else if (p.howl)          { p.howl.seek(time); }
    },

    // ── fadeIn ────────────────────────────────────────────────────────────────
    fadeIn: function (index, duration, targetVolume) {
        var p = players[index];
        if (!p) return;
        if ((p.type === 'local' || p.type === 'stream') && p.howl) {
            p.howl.fade(0, targetVolume, duration);
        }
        // YouTube: sem API nativa de fade, simula via intervalo
        if (p.type === 'youtube' && p.ytPlayer) {
            var cur = 0, target = Math.round(targetVolume * 100), steps = 20;
            var inc = target / steps, delay = duration / steps;
            var iv = setInterval(function () {
                cur = Math.min(cur + inc, target);
                if (p.ytPlayer) p.ytPlayer.setVolume(Math.round(cur));
                if (cur >= target) clearInterval(iv);
            }, delay);
        }
    },

    // ── fadeOut ───────────────────────────────────────────────────────────────
    fadeOut: function (index, duration) {
        var p = players[index];
        if (!p) return;
        var currentVol = p.vol || 1;
        if ((p.type === 'local' || p.type === 'stream') && p.howl) {
            p.howl.fade(p.howl.volume(), 0, duration);
        }
        if (p.type === 'youtube' && p.ytPlayer) {
            var cur = Math.round(currentVol * 100), steps = 20;
            var dec = cur / steps, delay = duration / steps;
            var iv = setInterval(function () {
                cur = Math.max(cur - dec, 0);
                if (p.ytPlayer) p.ytPlayer.setVolume(Math.round(cur));
                if (cur <= 0) clearInterval(iv);
            }, delay);
        }
    },

    // ── stopAll ───────────────────────────────────────────────────────────────
    stopAll: function () {
        Object.keys(players).forEach(function (k) { cleanupPlayer(parseInt(k)); });
    },
};

window.SoundPlayer = SoundPlayer;
