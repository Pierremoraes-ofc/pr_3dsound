-- bridge/version.lua  (carregado no shared_scripts)
local CURRENT_VERSION = "3.1.1"
local REPO_OWNER = "Pierremoraes-ofc"
local REPO_NAME = "pr_3dsound"

if Config.Version then
	-- Só roda no server para não abrir requisição no client
	if IsDuplicityVersion() then
		CreateThread(function()
			-- Aguarda o server subir completamente
			Wait(5000)

			local url = ("https://api.github.com/repos/%s/%s/releases/latest"):format(REPO_OWNER, REPO_NAME)

			PerformHttpRequest(url, function(statusCode, response, headers)
				if statusCode ~= 200 or not response then
					if Config.debug then
						Debug("ERROR", Lang:t("message.UpdateCheckFailed"))
					end
					return
				end

				local data = json.decode(response)
				if not data or not data.tag_name then
					return
				end

				local latestVersion = data.tag_name:gsub("^v", "")

				local isUpToDate = latestVersion == CURRENT_VERSION

				-- Se estiver atualizado mas o debug for false, não exibimos nada para manter o console limpo
				if isUpToDate and not Config.Debug then
					return
				end

				local status = isUpToDate and "^2UP TO DATE^0" or "^1OUTDATED^0"
				local versionText = isUpToDate and ("VERSION %s"):format(CURRENT_VERSION)
					or ("VERSION %s -> %s"):format(CURRENT_VERSION, latestVersion)

				local function center(text, width)
					local cleanText = text:gsub("%^%d", "")
					local spaces = width - string.len(cleanText)
					local left = math.floor(spaces / 2)
					local right = spaces - left
					return string.rep(" ", left) .. text .. string.rep(" ", right)
				end

				local box = {
					"^8--------------------------------------------------^0",
					"^8|^0                                                ^8|^0",
					"^8|^0" .. center("^53 3333  ddddddd         sssss   ooooo  u   u n   n ddddd^0", 48) .. "^8|^0",
					"^8|^0" .. center("^53    3  dd   dd        ss      oo   oo u   u nn  n dd  dd^0", 48) .. "^8|^0",
					"^8|^0" .. center("^53 3333  dd   dd         ssss   oo   oo u   u n n n dd   dd^0", 48) .. "^8|^0",
					"^8|^0" .. center("^53    3  dd   dd            ss  oo   oo u   u n  nn dd   dd^0", 48) .. "^8|^0",
					"^8|^0" .. center("^53 3333  ddddddd        sssss    ooooo   uuu  n   n ddddd^0", 48) .. "^8|^0",
					"^8|^0                                                ^8|^0",
					"^8|^0" .. center("^5   333   DDDDD           SSSSS   OOOOO  U   U N   N DDDDD^0", 48) .. "^8|^0",
					"^8|^0" .. center("^5  3   3  D   DD         SS      O   OO U   U NN  N D   DD^0", 48) .. "^8|^0",
					"^8|^0" .. center("^5     33  D   DD          SSSS   O   OO U   U N N N D   DD^0", 48) .. "^8|^0",
					"^8|^0" .. center("^5  3   3  D   DD             SS O   OO U   U N  NN D   DD^0", 48) .. "^8|^0",
					"^8|^0" .. center("^5   333   DDDDD          SSSSS   OOOOO   UUU  N   N DDDDD^0", 48) .. "^8|^0",
					"^8|^0                                                ^8|^0",
					"^8|^0" .. center(status, 48) .. "^8|^0",
					"^8|^0" .. center(versionText, 48) .. "^8|^0",
				}

				if not isUpToDate then
					table.insert(box, "^8|^0                                                ^8|^0")
					table.insert(box, "^8|^0" .. center("^3Please update your script!^0", 48) .. "^8|^0")
					table.insert(box, "^8|^0                                                ^8|^0")
					table.insert(box, "^8--------------------------------------------------^0")
					table.insert(
						box,
						""
							.. center(
								("^3https://github.com/%s/%s/releases/latest^0"):format(REPO_OWNER, REPO_NAME),
								48
							)
							.. ""
					)
				else
					table.insert(box, "^8|^0                                                ^8|^0")
					table.insert(box, "^8--------------------------------------------------^0")
				end

				print("\n")
				for _, line in ipairs(box) do
					print(line)
				end
				print("\n")
			end, "GET", "", { ["User-Agent"] = "fivem_bridge" })
		end)
	end
end
