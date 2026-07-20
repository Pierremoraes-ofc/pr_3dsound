/**
 * pr_3dsound — SoundPlayer.js  v3.2
 *
 * Correções v3.2:
 *   - AudioContext desbloqueado na inicialização → elimina delay/pausa no início
 *   - Oclusão via multiplicador de volume (funciona para local, stream, YT e SC)
 *     O filtro lowpass é salvo mas o volume é o efeito principal e mais confiável
 *   - _lastDistVol salva o volume de distância limpo; setFilter multiplica por cima
 *   - SoundCloud via Widget API (embed, sem client_id)
 */

'use strict';

// ─── Unlock do AudioContext ───────────────────────────────────────────────────
// GTA V / CEF suspende o AudioContext por política de autoplay.
// Fazemos resume() o mais cedo possível e repetimos se necessário.

function tryUnlockCtx() {
    var ctx = Howler.ctx;
    if (!ctx) { setTimeout(tryUnlockCtx, 200); return; }
    if (ctx.state !== 'running') {
        ctx.resume().catch(function () {});
    }
}

document.addEventListener('DOMContentLoaded', tryUnlockCtx);
// Também tenta em qualquer interação (backup)
['click', 'keydown', 'touchstart', 'mousedown'].forEach(function (ev) {
    document.addEventListener(ev, tryUnlockCtx, { once: true });
});
// Tenta periodicamente até conseguir
var _unlockInterval = setInterval(function () {
    var ctx = Howler.ctx;
    if (!ctx) return;
    if (ctx.state === 'running') { clearInterval(_unlockInterval); return; }
    ctx.resume().catch(function () {});
}, 500);

// ─── Detecção de tipo de URL ──────────────────────────────────────────────────

function detectUrlType(url) {
    if (!url) return 'local';
    if (/^https?:\/\//i.test(url)) {
        if (/youtube\.com\/watch|youtu\.be\//i.test(url)) return 'youtube';
        if (/soundcloud\.com\//i.test(url))               return 'soundcloud';
        return 'stream';
    }
    return 'local';
}

function extractYouTubeId(url) {
    var m = url.match(/(?:v=|youtu\.be\/)([A-Za-z0-9_-]{11})/);
    return m ? m[1] : null;
}

// ─── Registro de players ──────────────────────────────────────────────────────
var players = {};
var ytReady = false;
var ytQueue = [];

// ─── Oclusão por volume ───────────────────────────────────────────────────────
//
// A abordagem de filtro Web Audio (BiquadFilter por nó) é frágil no Howler
// porque a API interna (_sounds, _node, _panner) não é estável entre versões
// e varia entre html5:true (streams) e html5:false (local).
//
// Estratégia robusta e universal:
//   - O Lua calcula distVolume e occlusionMult separadamente
//   - updateVolume recebe distVolume e aplica: vol = distVol × occlusionMult
//   - setFilter recebe freq (para visualização/debug) e occlusionMult
//   - Para sons locais sem html5 também aplica o BiquadFilter quando possível
//
// Isso funciona para TODOS os tipos (local, stream, YT, SC).

function setPlayerVolume(p, v) {
    v = Math.max(0, Math.min(1, v));
    if      (p.type === 'youtube')    { if (p.ytPlayer && p.ytPlayer.setVolume) p.ytPlayer.setVolume(Math.round(v * 100)); }
    else if (p.type === 'soundcloud') { if (p.scWidget)  p.scWidget.setVolume(Math.round(v * 100)); }
    else if (p.howl)                  { p.howl.volume(v); }
}

// ─── SoundCloud Widget API ────────────────────────────────────────────────────

function createSCWidget(index, url, volume, loop, onReady) {
    var containerId = 'sc-' + index;
    var iframe = document.getElementById(containerId);
    if (!iframe) {
        iframe = document.createElement('iframe');
        iframe.id     = containerId;
        iframe.width  = '1';
        iframe.height = '1';
        iframe.style.cssText = 'position:absolute;left:-9999px;top:-9999px;border:0;';
        iframe.allow  = 'autoplay';
        var embedSrc = 'https://w.soundcloud.com/player/?url='
            + encodeURIComponent(DOMPurify.sanitize(url))
            + '&auto_play=true&hide_related=true&show_comments=false'
            + '&show_user=false&show_reposts=false&show_teaser=false'
            + '&visual=false&buying=false&liking=false&download=false&sharing=false';
        iframe.src = embedSrc;
        document.body.appendChild(iframe);
    }

    function tryBind(attempts) {
        if (typeof SC === 'undefined' || !SC.Widget) {
            if (attempts > 0) setTimeout(function () { tryBind(attempts - 1); }, 200);
            else console.error('[pr_3dsound] SoundCloud Widget API não carregou.');
            return;
        }
        var widget = SC.Widget(iframe);
        widget.bind(SC.Widget.Events.READY, function () {
            widget.setVolume(Math.round(volume * 100));
            if (loop) {
                widget.bind(SC.Widget.Events.FINISH, function () {
                    widget.seekTo(0);
                    widget.play();
                });
            } else {
                widget.bind(SC.Widget.Events.FINISH, function () {
                    notifyEnded(index);
                });
            }
            if (onReady) onReady(widget);
        });
        widget.bind(SC.Widget.Events.ERROR, function (e) {
            console.warn('[pr_3dsound] SoundCloud error index=' + index, e);
        });
        if (players[index]) players[index].scWidget = widget;
    }
    tryBind(25);
}

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

    //
    // SOLUÇÃO PARA O BUG DE PLAY→PAUSE→PLAY DO CEF/CHROME:
    //
    // O Chromium Embedded Framework bloqueia autoplay de mídia COM SOM.
    // Quando o YT Player tenta tocar com volume > 0, o CEF pausa imediatamente
    // após iniciar — causando o ciclo play→pause→play visível.
    //
    // A solução definitiva: iniciar MUTADO (mute:1) para bypassar a política,
    // aguardar o primeiro evento PLAYING confirmar que o vídeo está rodando,
    // então desmutar e setar o volume correto.
    // Após o primeiro PLAYING, o CEF já não bloqueia mais a reprodução.
    //
    var _unmuteOnPlay = true;   // flag: ainda precisa desmutar na primeira vez?

    return new YT.Player(containerId, {
        height: '0', width: '0', videoId: videoId,
        playerVars: {
            autoplay:       1,
            controls:       0,
            disablekb:      1,
            iv_load_policy: 3,
            modestbranding: 1,
            playsinline:    1,
            mute:           1,   // ← começa mutado para bypassar política de autoplay
        },
        events: {
            onReady: function (e) {
                // Já está mutado por playerVars; garante e dá play
                e.target.mute();
                e.target.setVolume(0);
                if (loop) {
                    e.target.setLoop(true);
                    e.target.loadVideoById({ videoId: videoId, suggestedQuality: 'small' });
                } else {
                    e.target.playVideo();
                }
                if (onReady) onReady(e.target);
            },
            onStateChange: function (e) {
                if (e.data === YT.PlayerState.PLAYING) {
                    if (_unmuteOnPlay) {
                        // Primeiro PLAYING confirmado → agora é seguro desmutar
                        _unmuteOnPlay = false;
                        e.target.unMute();
                        e.target.setVolume(Math.round(volume * 100));
                    }
                    if (players[index]) players[index].playing = true;
                }
                if (e.data === YT.PlayerState.ENDED) {
                    if (players[index] && players[index].loop) {
                        e.target.seekTo(0); e.target.playVideo();
                    } else {
                        notifyEnded(index);
                    }
                }
            },
            onError: function (e) { console.warn('[pr_3dsound] YouTube error', e.data, 'index', index); }
        }
    });
}

// ─── Notificação e cleanup ────────────────────────────────────────────────────

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
        if (p.ytPlayer) { try { p.ytPlayer.stopVideo(); p.ytPlayer.destroy(); } catch (e) {} }
        var yd = document.getElementById('yt-' + index);
        if (yd) yd.remove();
    } else if (p.type === 'soundcloud') {
        if (p.scWidget) { try { p.scWidget.pause(); } catch (e) {} }
        var sd = document.getElementById('sc-' + index);
        if (sd) sd.remove();
    }
    delete players[index];
}

// ─── Howler helper ────────────────────────────────────────────────────────────

function createHowl(src, volume, loop, is3D, pos, onEnd) {
    var isStream = /^https?:\/\//i.test(src);
    var useHtml5 = isStream || /\.ogg(?:$|\?)/i.test(src);
    var h = new Howl({
        src:    [src],
        volume: volume,
        loop:   loop || false,
        html5:  useHtml5,
        onend:  function () { if (!loop && onEnd) onEnd(); },
        onloaderror: function (id, err) { console.error('[pr_3dsound] Falha ao carregar:', src, err); },
        onplayerror: function (id, err) {
            console.error('[pr_3dsound] Falha ao tocar:', src, err);
            if (Howler.ctx && Howler.ctx.resume) Howler.ctx.resume().then(function () { h.play(); });
        },
        onload: function () {
            // Garante AudioContext desbloqueado quando o som carrega
            if (Howler.ctx && Howler.ctx.state === 'suspended') Howler.ctx.resume().catch(function(){});
        },
    });
    if (is3D && !isStream) {
        h.pannerAttr({ panningModel: 'HRTF', rolloffFactor: 1, distanceModel: 'linear', maxDistance: 10000 });
        if (pos) h.pos(pos.x, pos.y, pos.z);
    }
    return h;
}

function newPlayer(extra) {
    return Object.assign({
        vol: 1, maxVol: 1, playing: false, paused: false, loop: false,
        gainNode: null, filterNode: null,
        _occlusionMult: 1.0,   // multiplicador atual de oclusão (0.0-1.0)
        _lastDistVol:   1.0,   // último volume de distância recebido do Lua
    }, extra);
}

// ─── API pública ──────────────────────────────────────────────────────────────

var SoundPlayer = {

    play: function (index, file, volume, pos, loop) {
        cleanupPlayer(index);
        var src  = './sounds/' + DOMPurify.sanitize(file);
        var howl = createHowl(src, volume, loop, !!pos, pos, function () { notifyEnded(index); });
        if (pos) Howler.pos(pos.x, pos.y, pos.z);
        howl.play();
        players[index] = newPlayer({ type: 'local', howl: howl, vol: volume, maxVol: volume, pos: pos, playing: true, loop: loop || false, _lastDistVol: volume });
    },

    playUrl: function (index, url, volume, loop, options) {
        cleanupPlayer(index);
        options = options || {};
        var urlType = detectUrlType(url);

        if (urlType === 'youtube') {
            var vid = extractYouTubeId(url);
            if (!vid) { console.warn('[pr_3dsound] YT ID inválido:', url); return; }
            players[index] = newPlayer({ type: 'youtube', ytPlayer: null, vol: volume, maxVol: volume, loop: loop || false, _lastDistVol: volume });
            var doCreate = function () {
                players[index].ytPlayer = createYTPlayer(index, vid, volume, loop, function () {
                    if (players[index]) { players[index].playing = true; }
                    if (options.onPlayStart) options.onPlayStart({ index: index });
                });
            };
            ytReady ? doCreate() : ytQueue.push(doCreate);

        } else if (urlType === 'soundcloud') {
            players[index] = newPlayer({ type: 'soundcloud', scWidget: null, vol: volume, maxVol: volume, loop: loop || false, _lastDistVol: volume });
            createSCWidget(index, url, volume, loop, function () {
                if (players[index]) players[index].playing = true;
                if (options.onPlayStart) options.onPlayStart({ index: index });
            });

        } else {
            var howl = createHowl(DOMPurify.sanitize(url), volume, loop, false, null, function () {
                if (options.onPlayEnd) options.onPlayEnd({ index: index, url: url });
                notifyEnded(index);
            });
            howl.play();
            players[index] = newPlayer({ type: 'stream', howl: howl, vol: volume, maxVol: volume, playing: true, loop: loop || false, _lastDistVol: volume });
            if (options.onPlayStart) howl.once('play', function () { options.onPlayStart({ index: index }); });
        }
    },

    playUrlPos: function (index, url, volume, pos, loop, options) {
        cleanupPlayer(index);
        options = options || {};
        var urlType = detectUrlType(url);

        if (urlType === 'youtube') {
            var vid = extractYouTubeId(url);
            if (!vid) { console.warn('[pr_3dsound] YT ID inválido:', url); return; }
            players[index] = newPlayer({ type: 'youtube', ytPlayer: null, vol: volume, maxVol: volume, pos: pos, loop: loop || false, _lastDistVol: volume });
            var doCreate = function () {
                players[index].ytPlayer = createYTPlayer(index, vid, volume, loop, function () {
                    if (players[index]) players[index].playing = true;
                    if (options.onPlayStart) options.onPlayStart({ index: index });
                });
            };
            ytReady ? doCreate() : ytQueue.push(doCreate);

        } else if (urlType === 'soundcloud') {
            players[index] = newPlayer({ type: 'soundcloud', scWidget: null, vol: volume, maxVol: volume, pos: pos, loop: loop || false, _lastDistVol: volume });
            createSCWidget(index, url, volume, loop, function () {
                if (players[index]) players[index].playing = true;
                if (options.onPlayStart) options.onPlayStart({ index: index });
            });

        } else {
            var howl = createHowl(DOMPurify.sanitize(url), volume, loop, true, pos, function () {
                if (options.onPlayEnd) options.onPlayEnd({ index: index, url: url });
                notifyEnded(index);
            });
            Howler.pos(pos.x, pos.y, pos.z);
            howl.play();
            players[index] = newPlayer({ type: 'stream', howl: howl, vol: volume, maxVol: volume, pos: pos, playing: true, loop: loop || false, _lastDistVol: volume });
            if (options.onPlayStart) howl.once('play', function () { options.onPlayStart({ index: index }); });
        }
    },

    // Chamado pelo loop 3D do Lua com o volume de distância puro (sem oclusão)
    updateVolume: function (index, distVolume, playerPos, camDir) {
        var p = players[index];
        if (!p) return;
        p._lastDistVol = distVolume;
        // Volume final = distância × oclusão atual
        var v = Math.max(0, Math.min(p.maxVol || 1, distVolume * (p._occlusionMult !== undefined ? p._occlusionMult : 1.0)));
        setPlayerVolume(p, v);
        if (playerPos) Howler.pos(playerPos.x, playerPos.y, playerPos.z);
        if (camDir)    Howler.orientation(camDir.x, camDir.y, camDir.z, 0, 0, 1);
    },

    // Chamado pelo loop 3D com multiplicador de oclusão calculado no Lua
    // occlusionMult: 1.0 = sem oclusão, 0.35 = muito abafado
    setFilter: function (index, freq, occlusionMult) {
        var p = players[index];
        if (!p) return;
        var mult = (occlusionMult !== undefined) ? occlusionMult : 1.0;
        p._occlusionMult = mult;
        p._occlusionFreq = freq;
        // Aplica imediatamente com o último distVol conhecido
        var distVol = p._lastDistVol !== undefined ? p._lastDistVol : (p.vol || 1);
        var v = Math.max(0, Math.min(p.maxVol || 1, distVol * mult));
        setPlayerVolume(p, v);
    },

    pause: function (index) {
        var p = players[index];
        if (!p) return;
        p.paused = true; p.playing = false;
        if      (p.type === 'youtube')    { if (p.ytPlayer) p.ytPlayer.pauseVideo(); }
        else if (p.type === 'soundcloud') { if (p.scWidget) p.scWidget.pause(); }
        else if (p.howl)                  { p.howl.pause(); }
    },

    resume: function (index) {
        var p = players[index];
        if (!p) return;
        p.paused = false; p.playing = true;
        if      (p.type === 'youtube')    { if (p.ytPlayer) p.ytPlayer.playVideo(); }
        else if (p.type === 'soundcloud') { if (p.scWidget) p.scWidget.play(); }
        else if (p.howl)                  { p.howl.play(); }
        tryUnlockCtx();
    },

    stop: function (index) { cleanupPlayer(index); },

    updateCoords: function (index, pos) {
        var p = players[index];
        if (!p) return;
        p.pos = pos;
        if (p.howl && !(/^https?:\/\//i.test(p.howl._src || ''))) p.howl.pos(pos.x, pos.y, pos.z);
    },

    setVolume: function (index, volume) {
        var p = players[index];
        if (!p) return;
        p.vol = p.maxVol = Math.max(0, Math.min(1, volume));
        setPlayerVolume(p, p.vol);
    },

    setVolumeMax: function (index, volume) {
        var p = players[index];
        if (!p) return;
        p.maxVol = Math.max(0, Math.min(1, volume));
    },

    setDistance: function (index, distance) {
        var p = players[index];
        if (!p) return;
        p.dist = distance;
        if (p.howl) p.howl.pannerAttr({ maxDistance: distance * 2 });
    },

    setLoop: function (index, loopVal) {
        var p = players[index];
        if (!p) return;
        p.loop = loopVal;
        if      (p.type === 'youtube') { if (p.ytPlayer) p.ytPlayer.setLoop(loopVal); }
        else if (p.howl)               { p.howl.loop(loopVal); }
    },

    setTimestamp: function (index, time) {
        var p = players[index];
        if (!p) return;
        if      (p.type === 'youtube')    { if (p.ytPlayer) p.ytPlayer.seekTo(time, true); }
        else if (p.type === 'soundcloud') { if (p.scWidget) p.scWidget.seekTo(time * 1000); }
        else if (p.howl)                  { p.howl.seek(time); }
    },

    fadeIn: function (index, duration, targetVolume) {
        var p = players[index];
        if (!p) return;
        if (p.howl) { p.howl.fade(0, targetVolume, duration); return; }
        var setter = p.type === 'youtube'
            ? function (v) { if (p.ytPlayer) p.ytPlayer.setVolume(v); }
            : function (v) { if (p.scWidget)  p.scWidget.setVolume(v); };
        var cur = 0, target = Math.round(targetVolume * 100), steps = 20;
        var inc = target / steps, delay = duration / steps;
        var iv = setInterval(function () {
            cur = Math.min(cur + inc, target);
            setter(Math.round(cur));
            if (cur >= target) clearInterval(iv);
        }, delay);
    },

    fadeOut: function (index, duration) {
        var p = players[index];
        if (!p) return;
        if (p.howl) { p.howl.fade(p.howl.volume(), 0, duration); return; }
        var currentVol = p.vol || 1;
        var setter = p.type === 'youtube'
            ? function (v) { if (p.ytPlayer) p.ytPlayer.setVolume(v); }
            : function (v) { if (p.scWidget)  p.scWidget.setVolume(v); };
        var cur = Math.round(currentVol * 100), steps = 20;
        var dec = cur / steps, delay = duration / steps;
        var iv = setInterval(function () {
            cur = Math.max(cur - dec, 0);
            setter(Math.round(cur));
            if (cur <= 0) clearInterval(iv);
        }, delay);
    },

    stopAll: function () {
        Object.keys(players).forEach(function (k) { cleanupPlayer(parseInt(k)); });
    },
};

window.SoundPlayer = SoundPlayer;
