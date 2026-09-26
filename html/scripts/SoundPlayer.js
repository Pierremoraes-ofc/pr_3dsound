/**
 * pr_3dsound — SoundPlayer.js  v4.1.0-hls
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

function isHlsUrl(url) {
    return /\.m3u8(?:$|[?#])/i.test(String(url || ''));
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

function writePlayerVolume(p, v) {
    v = Math.max(0, Math.min(1, Number(v) || 0));

    if (p.type === 'spatialstream' && p.gainNode && Howler.ctx) {
        p.gainNode.gain.cancelScheduledValues(Howler.ctx.currentTime);
        p.gainNode.gain.setValueAtTime(v, Howler.ctx.currentTime);
    } else if (p.type === 'mediastream' && p.audio) {
        p.audio.volume = v;
    } else if (p.type === 'youtube') {
        if (p.ytPlayer && p.ytPlayer.setVolume) p.ytPlayer.setVolume(Math.round(v * 100));
    } else if (p.type === 'soundcloud') {
        if (p.scWidget) p.scWidget.setVolume(Math.round(v * 100));
    } else if (p.howl) {
        p.howl.volume(v);
    }
}

function setPlayerVolume(p, v) {
    v = Math.max(0, Math.min(1, Number(v) || 0));
    p._baseOutputVolume = v;
    var fade = (p._fadeMult !== undefined) ? p._fadeMult : 1.0;
    writePlayerVolume(p, v * fade);
}

function animateFadeMultiplier(p, from, to, duration) {
    if (!p) return;
    if (p._fadeTimer) { clearInterval(p._fadeTimer); p._fadeTimer = null; }

    duration = Math.max(0, Number(duration) || 0);
    from = Math.max(0, Math.min(1, Number(from) || 0));
    to = Math.max(0, Math.min(1, Number(to) || 0));

    p._fadeMult = from;
    writePlayerVolume(p, (p._baseOutputVolume !== undefined ? p._baseOutputVolume : (p.vol || 1)) * p._fadeMult);

    if (duration <= 0) {
        p._fadeMult = to;
        writePlayerVolume(p, (p._baseOutputVolume !== undefined ? p._baseOutputVolume : (p.vol || 1)) * p._fadeMult);
        return;
    }

    var started = performance.now();
    p._fadeTimer = setInterval(function () {
        var t = Math.min(1, (performance.now() - started) / duration);
        p._fadeMult = from + ((to - from) * t);
        writePlayerVolume(p, (p._baseOutputVolume !== undefined ? p._baseOutputVolume : (p.vol || 1)) * p._fadeMult);
        if (t >= 1) {
            clearInterval(p._fadeTimer);
            p._fadeTimer = null;
        }
    }, 40);
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
    $.post('http://pr_3dsound/soundEnded', JSON.stringify({ index: index }));
    cleanupPlayer(index);
}

function notifyError(index, reason) {
    $.post('http://pr_3dsound/soundError', JSON.stringify({
        index: index,
        reason: String(reason || 'Falha ao reproduzir o stream.')
    }));
    cleanupPlayer(index);
}

function cleanupPlayer(index) {
    var p = players[index];
    if (!p) return;

    if (p._fadeTimer) { clearInterval(p._fadeTimer); p._fadeTimer = null; }

    if (p.type === 'local' || p.type === 'stream') {
        if (p.howl) { p.howl.stop(); p.howl.unload(); }
    } else if (p.type === 'spatialstream') {
        destroySpatialStream(p);
    } else if (p.type === 'mediastream') {
        destroyMediaStream(p);
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

// ─── Howler / WebAudio helpers ────────────────────────────────────────────────

function createHowl(src, volume, loop, is3D, pos, onEnd) {
    var isStream = /^https?:\/\//i.test(src);
    // HTML5 Audio não fornece o pipeline espacial do Howler. Para arquivos
    // locais 3D usamos WebAudio mesmo em .ogg. URL 2D pode continuar em html5.
    var useHtml5 = isStream && !is3D;

    var h = new Howl({
        src: [src],
        volume: volume,
        loop: !!loop,
        html5: useHtml5,
        preload: true,
        onend: function () { if (!loop && onEnd) onEnd(); },
        onloaderror: function (id, err) { console.error('[pr_3dsound] Falha ao carregar:', src, err); },
        onplayerror: function (id, err) {
            console.error('[pr_3dsound] Falha ao tocar:', src, err);
            if (Howler.ctx && Howler.ctx.resume) {
                Howler.ctx.resume().then(function () { h.play(); }).catch(function () {});
            }
        },
        onload: function () {
            if (Howler.ctx && Howler.ctx.state === 'suspended') Howler.ctx.resume().catch(function () {});
        },
    });

    if (is3D) {
        // Distância é calculada no Lua. O panner fica responsável apenas pela
        // direção/HRTF, evitando atenuação duplicada.
        h.pannerAttr({
            panningModel: 'HRTF',
            distanceModel: 'linear',
            refDistance: 1,
            maxDistance: 100000,
            rolloffFactor: 0,
        });
        if (pos) h.pos(pos.x, pos.y, pos.z);
    }

    return h;
}

function seekHowlWhenReady(howl, seconds, loop) {
    seconds = Number(seconds) || 0;
    if (!howl || seconds <= 0) return;

    var apply = function () {
        try {
            var duration = howl.duration();
            var target = seconds;
            if (loop && isFinite(duration) && duration > 0) target = seconds % duration;
            else if (isFinite(duration) && duration > 0) target = Math.min(seconds, Math.max(0, duration - 0.05));
            howl.seek(target);
        } catch (e) {
            console.warn('[pr_3dsound] Não foi possível aplicar timestamp Howl:', e);
        }
    };

    if (howl.state && howl.state() === 'loaded') apply();
    else howl.once('load', apply);
}

function setPannerPosition(node, pos) {
    if (!node || !pos) return;
    var ctx = Howler.ctx;
    var x = Number(pos.x) || 0;
    var y = Number(pos.y) || 0;
    var z = Number(pos.z) || 0;

    if (node.positionX && ctx) {
        node.positionX.setValueAtTime(x, ctx.currentTime);
        node.positionY.setValueAtTime(y, ctx.currentTime);
        node.positionZ.setValueAtTime(z, ctx.currentTime);
    } else if (node.setPosition) {
        node.setPosition(x, y, z);
    }
}

function seekMediaWhenReady(audio, seconds, loop) {
    seconds = Math.max(0, Number(seconds) || 0);
    if (!audio) return;

    var apply = function () {
        try {
            var target = seconds;
            var duration = Number(audio.duration);

            if (isFinite(duration) && duration > 0) {
                target = loop ? (seconds % duration) : Math.min(seconds, Math.max(0, duration - 0.05));
            } else if (audio.seekable && audio.seekable.length) {
                // HLS/MSE pode reportar duration=Infinity por alguns instantes.
                // Nesse caso use a janela seekable em vez de desistir do seek.
                var start = audio.seekable.start(0);
                var end = audio.seekable.end(audio.seekable.length - 1);
                target = Math.max(start, Math.min(seconds, Math.max(start, end - 0.05)));
            }

            audio.currentTime = target;
        } catch (e) {
            console.warn('[pr_3dsound] Stream não aceita seek de sincronização:', e);
        }
    };

    if (audio.readyState >= 1) apply();
    else {
        audio.addEventListener('loadedmetadata', apply, { once: true });
        audio.addEventListener('durationchange', apply, { once: true });
    }
}


function seekMediaAndThen(audio, seconds, loop, done) {
    seconds = Math.max(0, Number(seconds) || 0);
    if (!audio) { if (done) done(); return; }

    var finished = false;
    var timer = null;
    var finish = function () {
        if (finished) return;
        finished = true;
        if (timer) clearTimeout(timer);
        if (done) done();
    };

    var apply = function () {
        if (finished) return true;
        try {
            var hasMetadata = audio.readyState >= 1 || (audio.seekable && audio.seekable.length);
            if (!hasMetadata) return false;

            var target = seconds;
            var duration = Number(audio.duration);
            if (isFinite(duration) && duration > 0) {
                target = loop ? (seconds % duration) : Math.min(seconds, Math.max(0, duration - 0.05));
            } else if (audio.seekable && audio.seekable.length) {
                var start = audio.seekable.start(0);
                var end = audio.seekable.end(audio.seekable.length - 1);
                target = Math.max(start, Math.min(seconds, Math.max(start, end - 0.05)));
            }

            var onSeeked = function () { finish(); };
            audio.addEventListener('seeked', onSeeked, { once: true });
            audio.currentTime = target;

            // Alguns CEF não disparam seeked quando a diferença é muito pequena.
            if (Math.abs((Number(audio.currentTime) || 0) - target) < 0.08) {
                setTimeout(finish, 0);
            } else {
                timer = setTimeout(finish, 900);
            }
            return true;
        } catch (e) {
            console.warn('[pr_3dsound] Stream não aceitou seek atômico:', e);
            finish();
            return true;
        }
    };

    if (apply()) return;
    var retry = function () { apply(); };
    audio.addEventListener('loadedmetadata', retry, { once: true });
    audio.addEventListener('durationchange', retry, { once: true });
    audio.addEventListener('canplay', retry, { once: true });
    timer = setTimeout(function () {
        if (!apply()) finish();
    }, 1400);
}

function setupHlsOnAudio(audio, src, onReady, onError) {
    var hls = null;
    var readyCalled = false;

    function ready() {
        if (readyCalled) return;
        readyCalled = true;
        if (onReady) onReady();
    }

    if (!isHlsUrl(src)) {
        audio.src = src;
        audio.addEventListener('loadedmetadata', ready, { once: true });
        return null;
    }

    // Safari/native HLS (caso o CEF passe a suportar nativamente).
    if (audio.canPlayType && audio.canPlayType('application/vnd.apple.mpegurl')) {
        audio.src = src;
        audio.addEventListener('loadedmetadata', ready, { once: true });
        return null;
    }

    if (typeof Hls === 'undefined' || !Hls.isSupported()) {
        throw new Error('HLS.js/MSE indisponivel no CEF');
    }

    hls = new Hls({
        enableWorker: true,
        lowLatencyMode: false,
        backBufferLength: 30,
    });

    hls.attachMedia(audio);
    hls.on(Hls.Events.MEDIA_ATTACHED, function () {
        hls.loadSource(src);
    });
    hls.on(Hls.Events.MANIFEST_PARSED, ready);
    var networkRetryCount = 0;
    var maxNetworkRetries = 3;

    hls.on(Hls.Events.ERROR, function (event, data) {
        if (!data || !data.fatal) return;
        var status = data.response && (data.response.code || data.response.status);
        if (!status && data.networkDetails) status = data.networkDetails.status;
        var failedUrl = (data.response && data.response.url) || (data.context && data.context.url) || src;
        console.error('[pr_3dsound] HLS fatal:', data.type, data.details,
            'status=', status || 0, 'url=', failedUrl, 'headers=', hasHttpHeadersForUrl(failedUrl),
            'retry=', networkRetryCount + '/' + maxNetworkRetries);

        // Evita loop infinito de manifestLoadError. Se CORS/rede estiver quebrado,
        // repetir para sempre apenas polui o console e mantém um player inválido vivo.
        if (data.type === Hls.ErrorTypes.NETWORK_ERROR) {
            if (networkRetryCount >= maxNetworkRetries) {
                console.error('[pr_3dsound] HLS abortado apos', maxNetworkRetries, 'retries:', src);
                try { hls.stopLoad(); } catch (e) {}
                if (onError) onError(data);
                return;
            }
            networkRetryCount++;
            setTimeout(function () {
                try {
                    hls.stopLoad();
                    hls.loadSource(src);
                    hls.startLoad();
                } catch (e) {}
            }, 750 * networkRetryCount);
            return;
        }
        if (data.type === Hls.ErrorTypes.MEDIA_ERROR) {
            try { hls.recoverMediaError(); } catch (e) {}
            return;
        }

        if (onError) onError(data);
    });

    return hls;
}

function startMediaElement(audio, options, loop) {
    options = options || {};

    var playNow = function () {
        if (options.paused) return;
        var promise = audio.play();
        if (promise && promise.catch) {
            promise.catch(function (err) {
                console.warn('[pr_3dsound] Autoplay bloqueado; tentando novamente.', err);
                tryUnlockCtx();
                setTimeout(function () {
                    var retry = audio.play();
                    if (retry && retry.catch) retry.catch(function () {});
                }, 50);
            });
        }
    };

    // Em stream-in/recriação HLS, nunca comece do zero para só depois fazer seek.
    // O play acontece somente quando o timestamp autoritativo já foi aplicado.
    if (Number(options.startAt) > 0.05) {
        seekMediaAndThen(audio, options.startAt, loop, playNow);
    } else {
        playNow();
    }
}

function createMediaStream(src, volume, loop, options, onEnd, onError) {
    options = options || {};
    var audio = document.createElement('audio');
    audio.crossOrigin = 'anonymous';
    audio.preload = 'auto';
    audio.loop = !!loop;
    audio.autoplay = false;
    audio.volume = Math.max(0, Math.min(1, Number(volume) || 0));
    audio.style.display = 'none';
    document.body.appendChild(audio);

    if (!loop && onEnd) audio.addEventListener('ended', onEnd, { once: true });
    audio.addEventListener('error', function () {
        console.error('[pr_3dsound] Falha no media stream:', src, 'mediaError=', audio.error && audio.error.code);
        if (onError) onError(audio.error);
    });

    var hls = setupHlsOnAudio(audio, src, function () {
        startMediaElement(audio, options, loop);
    }, onError);

    // Para URL nao-HLS, loadedmetadata dispara startMediaElement via setup.
    return { audio: audio, hls: hls };
}

function destroyMediaStream(p) {
    if (!p) return;
    try { if (p.hls) p.hls.destroy(); } catch (e) {}
    try {
        if (p.audio) {
            p.audio.pause();
            p.audio.removeAttribute('src');
            p.audio.load();
            p.audio.remove();
        }
    } catch (e) {}
}

function createSpatialStream(src, volume, loop, pos, options, onEnd, onError) {
    options = options || {};
    tryUnlockCtx();

    var ctx = Howler.ctx;
    if (!ctx || !ctx.createMediaElementSource || !ctx.createPanner) {
        throw new Error('WebAudio MediaElementSource/PannerNode indisponivel no CEF');
    }

    var audio = document.createElement('audio');
    audio.crossOrigin = 'anonymous';
    audio.preload = 'auto';
    audio.loop = !!loop;
    audio.autoplay = false;
    audio.volume = 1.0; // volume espacial e controlado no GainNode
    audio.style.display = 'none';
    document.body.appendChild(audio);

    var sourceNode = ctx.createMediaElementSource(audio);
    var pannerNode = ctx.createPanner();
    var filterNode = ctx.createBiquadFilter();
    var gainNode = ctx.createGain();

    pannerNode.panningModel = 'HRTF';
    pannerNode.distanceModel = 'linear';
    pannerNode.refDistance = 1;
    pannerNode.maxDistance = 100000;
    pannerNode.rolloffFactor = 0;
    setPannerPosition(pannerNode, pos);

    filterNode.type = 'lowpass';
    filterNode.frequency.setValueAtTime(22050, ctx.currentTime);
    filterNode.Q.setValueAtTime(0.2, ctx.currentTime);
    gainNode.gain.setValueAtTime(Math.max(0, Math.min(1, Number(volume) || 0)), ctx.currentTime);

    sourceNode.connect(pannerNode);
    pannerNode.connect(filterNode);
    filterNode.connect(gainNode);
    gainNode.connect(ctx.destination);

    if (!loop && onEnd) audio.addEventListener('ended', onEnd, { once: true });
    audio.addEventListener('error', function () {
        console.error('[pr_3dsound] Falha no stream 3D:', src, 'mediaError=', audio.error && audio.error.code);
        if (onError) onError(audio.error);
    });

    var hls = setupHlsOnAudio(audio, src, function () {
        startMediaElement(audio, options, loop);
    }, onError);

    return {
        audio: audio,
        hls: hls,
        sourceNode: sourceNode,
        pannerNode: pannerNode,
        filterNode: filterNode,
        gainNode: gainNode,
    };
}

function destroySpatialStream(p) {
    if (!p) return;

    try { if (p.hls) p.hls.destroy(); } catch (e) {}
    try {
        if (p.audio) {
            p.audio.pause();
            p.audio.removeAttribute('src');
            p.audio.load();
            p.audio.remove();
        }
    } catch (e) {}

    [p.sourceNode, p.pannerNode, p.filterNode, p.gainNode].forEach(function (node) {
        try { if (node) node.disconnect(); } catch (e) {}
    });
}

function newPlayer(extra) {
    return Object.assign({
        vol: 1,
        maxVol: 1,
        playing: false,
        paused: false,
        loop: false,
        audio: null,
        hls: null,
        sourceNode: null,
        pannerNode: null,
        gainNode: null,
        filterNode: null,
        _occlusionMult: 1.0,
        _lastDistVol: 1.0,
        _fadeMult: 1.0,
        _fadeTimer: null,
        _baseOutputVolume: 1.0,
    }, extra);
}

// ─── API pública ──────────────────────────────────────────────────────────────

var SoundPlayer = {

    play: function (index, file, volume, pos, loop, is2D, options) {
        cleanupPlayer(index);
        options = options || {};

        var src = './sounds/' + DOMPurify.sanitize(file);
        var is3D = !is2D && !!pos;
        var howl = createHowl(src, volume, loop, is3D, is3D ? pos : null, function () { notifyEnded(index); });

        seekHowlWhenReady(howl, options.startAt, loop);
        if (!options.paused) howl.play();

        players[index] = newPlayer({
            type: 'local',
            howl: howl,
            vol: volume,
            maxVol: volume,
            pos: is3D ? pos : null,
            is2D: !!is2D,
            playing: !options.paused,
            paused: !!options.paused,
            loop: !!loop,
            _lastDistVol: volume,
            _baseOutputVolume: volume,
        });
    },

    playUrl: function (index, url, volume, loop, options) {
        cleanupPlayer(index);
        options = options || {};
        var urlType = detectUrlType(url);

        if (urlType === 'youtube') {
            var vid = extractYouTubeId(url);
            if (!vid) { console.warn('[pr_3dsound] YT ID inválido:', url); return; }

            players[index] = newPlayer({
                type: 'youtube', ytPlayer: null, vol: volume, maxVol: volume,
                loop: !!loop, paused: !!options.paused, playing: false,
                _lastDistVol: volume, _baseOutputVolume: volume,
            });

            var doCreate = function () {
                if (!players[index]) return;
                players[index].ytPlayer = createYTPlayer(index, vid, volume, loop, function (player) {
                    if (!players[index]) return;
                    if (Number(options.startAt) > 0) { try { player.seekTo(Number(options.startAt), true); } catch (e) {} }
                    if (options.paused) { try { player.pauseVideo(); } catch (e) {} }
                    players[index].playing = !options.paused;
                    if (options.onPlayStart) options.onPlayStart({ index: index });
                });
            };
            ytReady ? doCreate() : ytQueue.push(doCreate);

        } else if (urlType === 'soundcloud') {
            players[index] = newPlayer({
                type: 'soundcloud', scWidget: null, vol: volume, maxVol: volume,
                loop: !!loop, paused: !!options.paused, playing: false,
                _lastDistVol: volume, _baseOutputVolume: volume,
            });

            createSCWidget(index, url, volume, loop, function (widget) {
                if (!players[index]) return;
                if (Number(options.startAt) > 0) { try { widget.seekTo(Number(options.startAt) * 1000); } catch (e) {} }
                if (options.paused) { try { widget.pause(); } catch (e) {} }
                players[index].playing = !options.paused;
                if (options.onPlayStart) options.onPlayStart({ index: index });
            });

        } else {
            var cleanUrl2D = DOMPurify.sanitize(url);

            if (isHlsUrl(cleanUrl2D)) {
                try {
                    var media = createMediaStream(cleanUrl2D, volume, loop, options, function () {
                        if (options.onPlayEnd) options.onPlayEnd({ index: index, url: url });
                        notifyEnded(index);
                    }, function (hlsErr) {
                        console.error('[pr_3dsound] HLS 2D falhou:', cleanUrl2D);
                        notifyError(index, hlsErr && (hlsErr.details || hlsErr.message) || 'Falha HLS 2D');
                    });

                    players[index] = newPlayer({
                        type: 'mediastream', audio: media.audio, hls: media.hls, url: cleanUrl2D,
                        vol: volume, maxVol: volume,
                        playing: !options.paused, paused: !!options.paused, loop: !!loop,
                        _lastDistVol: volume, _baseOutputVolume: volume,
                    });
                    if (options.onPlayStart && !options.paused) options.onPlayStart({ index: index });
                } catch (err) {
                    console.error('[pr_3dsound] Nao foi possivel iniciar HLS 2D:', err);
                    notifyError(index, err && err.message || 'Falha ao iniciar HLS 2D');
                }
            } else {
                var howl = createHowl(cleanUrl2D, volume, loop, false, null, function () {
                    if (options.onPlayEnd) options.onPlayEnd({ index: index, url: url });
                    notifyEnded(index);
                });

                seekHowlWhenReady(howl, options.startAt, loop);
                if (!options.paused) howl.play();

                players[index] = newPlayer({
                    type: 'stream', howl: howl, vol: volume, maxVol: volume,
                    playing: !options.paused, paused: !!options.paused, loop: !!loop,
                    _lastDistVol: volume, _baseOutputVolume: volume,
                });

                if (options.onPlayStart && !options.paused) {
                    howl.once('play', function () { options.onPlayStart({ index: index }); });
                }
            }
        }
    },

    playUrlPos: function (index, url, volume, pos, loop, options) {
        cleanupPlayer(index);
        options = options || {};
        var urlType = detectUrlType(url);
        var maxVolume = (options.maxVolume !== undefined) ? Number(options.maxVolume) : Number(volume);
        if (!isFinite(maxVolume)) maxVolume = Number(volume) || 0;
        maxVolume = Math.max(0, Math.min(1, maxVolume));
        var initialDistVolume = (options.initialDistVolume !== undefined) ? Number(options.initialDistVolume) : Number(volume);
        if (!isFinite(initialDistVolume)) initialDistVolume = Number(volume) || 0;
        var initialOcclusionMult = (options.initialOcclusionMult !== undefined) ? Number(options.initialOcclusionMult) : 1.0;
        if (!isFinite(initialOcclusionMult)) initialOcclusionMult = 1.0;
        initialOcclusionMult = Math.max(0, Math.min(1, initialOcclusionMult));

        // Iframes de YouTube/SoundCloud são cross-origin: o browser não permite
        // conectar o áudio interno deles ao nosso PannerNode. Eles continuam com
        // volume/distância/oclusão. URL DIRETA usa WebAudio HRTF de verdade.
        if (urlType === 'youtube') {
            var vid = extractYouTubeId(url);
            if (!vid) { console.warn('[pr_3dsound] YT ID inválido:', url); return; }

            players[index] = newPlayer({
                type: 'youtube', ytPlayer: null, vol: maxVolume, maxVol: maxVolume, pos: pos,
                loop: !!loop, paused: !!options.paused, playing: false,
                _occlusionMult: initialOcclusionMult, _lastDistVol: initialDistVolume, _baseOutputVolume: volume,
            });

            var doCreate = function () {
                if (!players[index]) return;
                players[index].ytPlayer = createYTPlayer(index, vid, volume, loop, function (player) {
                    if (!players[index]) return;
                    if (Number(options.startAt) > 0) { try { player.seekTo(Number(options.startAt), true); } catch (e) {} }
                    if (options.paused) { try { player.pauseVideo(); } catch (e) {} }
                    players[index].playing = !options.paused;
                    if (options.onPlayStart) options.onPlayStart({ index: index });
                });
            };
            ytReady ? doCreate() : ytQueue.push(doCreate);

        } else if (urlType === 'soundcloud') {
            players[index] = newPlayer({
                type: 'soundcloud', scWidget: null, vol: maxVolume, maxVol: maxVolume, pos: pos,
                loop: !!loop, paused: !!options.paused, playing: false,
                _occlusionMult: initialOcclusionMult, _lastDistVol: initialDistVolume, _baseOutputVolume: volume,
            });

            createSCWidget(index, url, volume, loop, function (widget) {
                if (!players[index]) return;
                if (Number(options.startAt) > 0) { try { widget.seekTo(Number(options.startAt) * 1000); } catch (e) {} }
                if (options.paused) { try { widget.pause(); } catch (e) {} }
                players[index].playing = !options.paused;
                if (options.onPlayStart) options.onPlayStart({ index: index });
            });

        } else {
            var cleanUrl = DOMPurify.sanitize(url);

            try {
                var nodes = createSpatialStream(cleanUrl, volume, loop, pos, options, function () {
                    if (options.onPlayEnd) options.onPlayEnd({ index: index, url: url });
                    notifyEnded(index);
                }, function () {
                    var current = players[index];
                    if (!current || current.type !== 'spatialstream') return;

                    destroySpatialStream(current);

                    if (isHlsUrl(cleanUrl)) {
                        try {
                            var fallbackMedia = createMediaStream(cleanUrl, volume, loop, options, function () {
                                if (options.onPlayEnd) options.onPlayEnd({ index: index, url: url });
                                notifyEnded(index);
                            }, function (hlsErr) {
                                console.error('[pr_3dsound] HLS 2D fallback falhou:', cleanUrl, hlsErr || 'erro desconhecido');
                                notifyError(index, hlsErr && (hlsErr.details || hlsErr.message) || 'Falha no fallback HLS');
                            });

                            players[index] = newPlayer({
                                type: 'mediastream', audio: fallbackMedia.audio, hls: fallbackMedia.hls,
                                url: cleanUrl, vol: maxVolume, maxVol: maxVolume, pos: pos,
                                playing: !options.paused, paused: !!options.paused, loop: !!loop,
                                _occlusionMult: initialOcclusionMult, _lastDistVol: initialDistVolume, _baseOutputVolume: volume,
                            });
                        } catch (fallbackErr) {
                            console.error('[pr_3dsound] Não foi possível iniciar HLS.js no fallback 2D:', fallbackErr);
                            notifyError(index, fallbackErr && fallbackErr.message || 'Falha ao iniciar fallback HLS');
                        }
                    } else {
                        var fallback = createHowl(cleanUrl, volume, loop, false, null, function () { notifyEnded(index); });
                        seekHowlWhenReady(fallback, options.startAt, loop);
                        if (!options.paused) fallback.play();

                        players[index] = newPlayer({
                            type: 'stream', howl: fallback, vol: maxVolume, maxVol: maxVolume, pos: pos,
                            playing: !options.paused, paused: !!options.paused, loop: !!loop,
                            _occlusionMult: initialOcclusionMult, _lastDistVol: initialDistVolume, _baseOutputVolume: volume,
                        });
                    }
                });

                players[index] = newPlayer({
                    type: 'spatialstream',
                    audio: nodes.audio,
                    hls: nodes.hls,
                    url: cleanUrl,
                    sourceNode: nodes.sourceNode,
                    pannerNode: nodes.pannerNode,
                    filterNode: nodes.filterNode,
                    gainNode: nodes.gainNode,
                    vol: maxVolume,
                    maxVol: maxVolume,
                    pos: pos,
                    playing: !options.paused,
                    paused: !!options.paused,
                    loop: !!loop,
                    _occlusionMult: initialOcclusionMult,
                    _lastDistVol: initialDistVolume,
                    _baseOutputVolume: volume,
                });

                if (options.onPlayStart && !options.paused) options.onPlayStart({ index: index });

            } catch (err) {

                if (isHlsUrl(cleanUrl)) {
                    try {
                        var fallbackMedia = createMediaStream(cleanUrl, volume, loop, options, function () {
                            if (options.onPlayEnd) options.onPlayEnd({ index: index, url: url });
                            notifyEnded(index);
                        }, function (hlsErr) {
                            console.error('[pr_3dsound] HLS 2D fallback falhou:', cleanUrl, hlsErr || 'erro desconhecido');
                            notifyError(index, hlsErr && (hlsErr.details || hlsErr.message) || 'Falha no fallback HLS');
                        });

                        players[index] = newPlayer({
                            type: 'mediastream', audio: fallbackMedia.audio, hls: fallbackMedia.hls,
                            url: cleanUrl, vol: maxVolume, maxVol: maxVolume, pos: pos,
                            playing: !options.paused, paused: !!options.paused, loop: !!loop,
                            _occlusionMult: initialOcclusionMult, _lastDistVol: initialDistVolume, _baseOutputVolume: volume,
                        });
                    } catch (fallbackErr) {
                        console.error('[pr_3dsound] Não foi possível iniciar HLS.js no fallback 2D:', fallbackErr);
                        notifyError(index, fallbackErr && fallbackErr.message || 'Falha ao iniciar fallback HLS');
                    }
                } else {
                    var fallback = createHowl(cleanUrl, volume, loop, false, null, function () { notifyEnded(index); });
                    seekHowlWhenReady(fallback, options.startAt, loop);
                    if (!options.paused) fallback.play();

                    players[index] = newPlayer({
                        type: 'stream', howl: fallback, vol: maxVolume, maxVol: maxVolume, pos: pos,
                        playing: !options.paused, paused: !!options.paused, loop: !!loop,
                        _occlusionMult: initialOcclusionMult, _lastDistVol: initialDistVolume, _baseOutputVolume: volume,
                    });
                }
            }
        }
    },

    updateVolume: function (index, distVolume, playerPos, camDir) {
        var p = players[index];
        if (!p) return;

        p._lastDistVol = Number(distVolume) || 0;
        var max = (p.maxVol !== undefined) ? p.maxVol : 1;
        var mult = (p._occlusionMult !== undefined) ? p._occlusionMult : 1.0;
        var v = Math.max(0, Math.min(max, p._lastDistVol * mult));
        setPlayerVolume(p, v);

        // Howler e os nossos MediaElementSource compartilham o mesmo AudioContext,
        // então o listener global também posiciona os PannerNodes customizados.
        if (playerPos) Howler.pos(playerPos.x, playerPos.y, playerPos.z);
        if (camDir) Howler.orientation(camDir.x, camDir.y, camDir.z, 0, 0, 1);
    },

    setFilter: function (index, freq, occlusionMult) {
        var p = players[index];
        if (!p) return;

        var mult = (occlusionMult !== undefined) ? Number(occlusionMult) : 1.0;
        p._occlusionMult = Math.max(0, Math.min(1, mult));
        p._occlusionFreq = freq;

        if (p.filterNode && Howler.ctx) {
            var hz = Math.max(250, Math.min(22050, Number(freq) || 22050));
            p.filterNode.frequency.cancelScheduledValues(Howler.ctx.currentTime);
            p.filterNode.frequency.setTargetAtTime(hz, Howler.ctx.currentTime, 0.03);
        }

        var distVol = (p._lastDistVol !== undefined) ? p._lastDistVol : (p.vol || 1);
        var max = (p.maxVol !== undefined) ? p.maxVol : 1;
        setPlayerVolume(p, Math.max(0, Math.min(max, distVol * p._occlusionMult)));
    },

    pause: function (index) {
        var p = players[index];
        if (!p) return;
        p.paused = true;
        p.playing = false;

        if (p.type === 'youtube') {
            if (p.ytPlayer) p.ytPlayer.pauseVideo();
        } else if (p.type === 'soundcloud') {
            if (p.scWidget) p.scWidget.pause();
        } else if (p.type === 'spatialstream' || p.type === 'mediastream') {
            if (p.audio) p.audio.pause();
        } else if (p.howl) {
            p.howl.pause();
        }
    },

    resume: function (index) {
        var p = players[index];
        if (!p) return;
        p.paused = false;
        p.playing = true;

        if (p.type === 'youtube') {
            if (p.ytPlayer) p.ytPlayer.playVideo();
        } else if (p.type === 'soundcloud') {
            if (p.scWidget) p.scWidget.play();
        } else if (p.type === 'spatialstream' || p.type === 'mediastream') {
            if (p.audio) {
                var promise = p.audio.play();
                if (promise && promise.catch) promise.catch(function () {});
            }
        } else if (p.howl) {
            p.howl.play();
        }

        tryUnlockCtx();
    },

    pauseAt: function (index, time) {
        var p = players[index];
        if (!p) return;
        time = Math.max(0, Number(time) || 0);
        p.paused = true;
        p.playing = false;

        if (p.type === 'youtube') {
            try { if (p.ytPlayer) { p.ytPlayer.pauseVideo(); p.ytPlayer.seekTo(time, true); } } catch (e) {}
        } else if (p.type === 'soundcloud') {
            try { if (p.scWidget) { p.scWidget.pause(); p.scWidget.seekTo(time * 1000); } } catch (e) {}
        } else if (p.type === 'spatialstream' || p.type === 'mediastream') {
            if (p.audio) {
                var keepVolume = p.audio.volume;
                p.audio.pause();
                seekMediaAndThen(p.audio, time, p.loop, function () {
                    if (p.audio) p.audio.volume = keepVolume;
                });
            }
        } else if (p.howl) {
            try { p.howl.pause(); p.howl.seek(time); } catch (e) {}
        }
    },

    resumeAt: function (index, time) {
        var p = players[index];
        if (!p) return;
        time = Math.max(0, Number(time) || 0);
        p.paused = false;
        p.playing = true;

        if (p.type === 'youtube') {
            try { if (p.ytPlayer) { p.ytPlayer.seekTo(time, true); p.ytPlayer.playVideo(); } } catch (e) {}
        } else if (p.type === 'soundcloud') {
            try { if (p.scWidget) { p.scWidget.seekTo(time * 1000); p.scWidget.play(); } } catch (e) {}
        } else if (p.type === 'spatialstream' || p.type === 'mediastream') {
            if (p.audio) {
                var keepVolume = p.audio.volume;
                p.audio.pause();
                seekMediaAndThen(p.audio, time, p.loop, function () {
                    if (!p.audio || p.paused) return;
                    p.audio.volume = keepVolume;
                    var promise = p.audio.play();
                    if (promise && promise.catch) promise.catch(function () {});
                });
            }
        } else if (p.howl) {
            try { p.howl.seek(time); p.howl.play(); } catch (e) {}
        }
        tryUnlockCtx();
    },


    stop: function (index) {
        cleanupPlayer(index);
    },

    updateCoords: function (index, pos) {
        var p = players[index];
        if (!p || !pos) return;
        p.pos = pos;

        if (p.type === 'spatialstream') {
            setPannerPosition(p.pannerNode, pos);
        } else if (p.howl && p.howl.pos) {
            p.howl.pos(pos.x, pos.y, pos.z);
        }
    },

    setVolume: function (index, volume) {
        var p = players[index];
        if (!p) return;
        var oldMax = (p.maxVol !== undefined) ? Number(p.maxVol) : Number(p.vol || 0);
        var next = Math.max(0, Math.min(1, Number(volume) || 0));
        p.vol = p.maxVol = next;
        p._fadeMult = 1.0;

        // Para emitters 3D preserve a atenuação já calculada. Aplicar `next`
        // diretamente causava um pico até chegar o próximo updateVolume do Lua.
        if (p.pos && p._lastDistVol !== undefined) {
            if (oldMax > 0.0001) p._lastDistVol = Math.max(0, p._lastDistVol * (next / oldMax));
            else p._lastDistVol = 0;
            var mult = (p._occlusionMult !== undefined) ? p._occlusionMult : 1.0;
            setPlayerVolume(p, Math.max(0, Math.min(next, p._lastDistVol * mult)));
        } else {
            setPlayerVolume(p, next);
        }
    },

    setVolumeMax: function (index, volume) {
        var p = players[index];
        if (!p) return;
        p.maxVol = Math.max(0, Math.min(1, Number(volume) || 0));
    },

    setDistance: function (index, distance) {
        var p = players[index];
        if (!p) return;
        p.dist = Number(distance) || 0;
        if (p.howl && p.howl.pannerAttr) p.howl.pannerAttr({ maxDistance: 100000, rolloffFactor: 0 });
        if (p.pannerNode) p.pannerNode.maxDistance = 100000;
    },

    setLoop: function (index, loopVal) {
        var p = players[index];
        if (!p) return;
        p.loop = !!loopVal;

        if (p.type === 'youtube') {
            if (p.ytPlayer) p.ytPlayer.setLoop(!!loopVal);
        } else if (p.type === 'spatialstream' || p.type === 'mediastream') {
            if (p.audio) p.audio.loop = !!loopVal;
        } else if (p.howl) {
            p.howl.loop(!!loopVal);
        }
    },

    setTimestamp: function (index, time) {
        var p = players[index];
        if (!p) return;
        time = Math.max(0, Number(time) || 0);

        if (p.type === 'youtube') {
            if (p.ytPlayer) p.ytPlayer.seekTo(time, true);
        } else if (p.type === 'soundcloud') {
            if (p.scWidget) p.scWidget.seekTo(time * 1000);
        } else if (p.type === 'spatialstream' || p.type === 'mediastream') {
            if (p.audio) {
                var shouldResume = p.playing && !p.paused;
                var keepVolume = p.audio.volume;
                p.audio.pause();
                seekMediaAndThen(p.audio, time, p.loop, function () {
                    if (!p.audio) return;
                    p.audio.volume = keepVolume;
                    if (shouldResume && !p.paused) {
                        var promise = p.audio.play();
                        if (promise && promise.catch) promise.catch(function () {});
                    }
                });
            }
        } else if (p.howl) {
            seekHowlWhenReady(p.howl, time, p.loop);
        }
    },

    fadeIn: function (index, duration, targetVolume) {
        var p = players[index];
        if (!p) return;
        p.vol = p.maxVol = Math.max(0, Math.min(1, Number(targetVolume) || 0));
        animateFadeMultiplier(p, 0.0, 1.0, duration);
    },

    fadeOut: function (index, duration) {
        var p = players[index];
        if (!p) return;
        animateFadeMultiplier(p, (p._fadeMult !== undefined ? p._fadeMult : 1.0), 0.0, duration);
    },

    stopAll: function () {
        Object.keys(players).forEach(function (k) { cleanupPlayer(k); });
    },
};

window.SoundPlayer = SoundPlayer;
