fx_version 'cerulean'
game 'gta5'

author 'PierreMoraes'
name 'pr_3dsound'
description '3D sound system — local files, URL streams, YouTube, SoundCloud'
version '2.0.0'

client_scripts {
    'client/client.lua',
    'client/test_commands.lua',  -- REMOVA EM PRODUÇÃO
}

server_scripts {
    'server/server.lua'
}

ui_page 'html/index.html'

files {
    'html/index.html',
    'html/scripts/*.js',
    'html/**/*.js',
    'html/**/*.css',
    -- sons proprios do pr_3dsound
    'html/sounds/*.ogg',
    'html/sounds/*.mp3',
    'html/sounds/*.weba',
    -- sons de outros scripts em subpastas (ex: html/sounds/meu_script/pistola.ogg)
    'html/sounds/**/*.ogg',
    'html/sounds/**/*.mp3',
    'html/sounds/**/*.weba',
}
