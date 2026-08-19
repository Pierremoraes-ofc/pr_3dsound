fx_version("cerulean")
game("gta5")

author("PierreMoraes")
name("pr_3dsound")
description("3D sound system — local files, URL streams, YouTube, SoundCloud embed")
version("3.1.1")

client_scripts({
	"client/client.lua",
	"client/native_sound.lua",
	-- 'client/test_commands.lua', -- habilite apenas para testes; broadcast exige ACE pr_3dsound.broadcast
})

server_scripts({
	"server/server.lua",
	"server/native_sound.lua",
})

ui_page("html/index.html")

files({
	"html/index.html",
	"html/scripts/*.js",
	"html/**/*.js",
	"html/**/*.css",
	-- sons proprios do pr_3dsound
	"html/sounds/*.ogg",
	"html/sounds/*.mp3",
	"html/sounds/*.weba",
	-- sons de outros scripts em subpastas (ex: html/sounds/meu_script/pistola.ogg)
	"html/sounds/**/*.ogg",
	"html/sounds/**/*.mp3",
	"html/sounds/**/*.weba",
})
