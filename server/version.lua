-- bridge/version.lua  (carregado no shared_scripts)
local CURRENT_VERSION = "4.0.0"
local REPO_OWNER      = "Pierremoraes-ofc"
local REPO_NAME       = "pr_3dsound"




-- Só roda no server para não abrir requisição no client
if IsDuplicityVersion() and Config.Version then
	CreateThread(function()
		-- Aguarda o server subir completamente
		Wait(5000)

		if pr_lib and pr_lib.versionCheck then
			pr_lib.versionCheck(("%s/%s"):format(REPO_OWNER, REPO_NAME))
		end
	end)
end


