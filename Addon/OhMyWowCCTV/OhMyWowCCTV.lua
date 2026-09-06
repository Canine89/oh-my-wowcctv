-- Oh My WoW CCTV
-- 역할: 쐐기(또는 공격대) 인스턴스에 들어가면 전투 기록(/combatlog)을 자동으로 켠다.
-- macOS CCTV 앱은 Logs/WoWCombatLog-*.txt 에 기록되는 CHALLENGE_MODE_START / CHALLENGE_MODE_END
-- 줄을 보고 OBS 녹화를 시작/종료한다. 애드온은 파일에 직접 쓸 수 없으므로 "기록을 켜두는 것"이 전부다.

local ADDON_NAME = ...
local PREFIX = "|cff2ecc71CCTV|r "

local frame = CreateFrame("Frame")
local enabledByUs = false

-- 인스턴스를 나가도 쐐기 인스턴스는 유지되므로, 기록도 바로 끄지 않고 이 시간 동안 유지한다.
-- 그 사이 다시 들어오면 계속 기록한다. (나가는 순간의 ZONE_CHANGE 줄도 이 덕분에 파일에 남는다)
local LEAVE_GRACE_SECONDS = 180
local leaveToken = 0

local defaults = {
    enabled = true,   -- 자동 전투 기록 on/off
    raids = true,     -- 공격대 인스턴스에서도 기록
    quiet = false,    -- 채팅 안내 숨김
}

local function say(msg)
    if OhMyWowCCTVDB and OhMyWowCCTVDB.quiet then return end
    print(PREFIX .. msg)
end

local function initDB()
    OhMyWowCCTVDB = OhMyWowCCTVDB or {}
    for k, v in pairs(defaults) do
        if OhMyWowCCTVDB[k] == nil then OhMyWowCCTVDB[k] = v end
    end
end

-- 현재 위치가 기록 대상 인스턴스인지
local function wantsLogging()
    local inInstance, instanceType = IsInInstance()
    if not inInstance then return false, nil end
    if instanceType == "party" then return true, "던전" end
    if instanceType == "raid" and OhMyWowCCTVDB.raids then return true, "공격대" end
    return false, nil
end

local function ensureAdvancedLogging()
    -- CHALLENGE_MODE_*/ENCOUNTER_* 줄은 기본 기록에도 남지만,
    -- 고급 전투 기록을 켜야 파싱에 쓸 부가 정보가 안정적으로 남는다.
    if C_CVar.GetCVar("advancedCombatLogging") ~= "1" then
        C_CVar.SetCVar("advancedCombatLogging", "1")
    end
end

local function update(reason)
    if not OhMyWowCCTVDB or not OhMyWowCCTVDB.enabled then return end

    local want, kind = wantsLogging()
    local logging = LoggingCombat()

    if want then
        -- 다시 들어왔으면 예약된 기록 종료를 취소한다
        if leaveToken > 0 then
            leaveToken = 0
            if logging then say(kind .. " 재입장 → 전투 기록 계속") end
        end
        if not logging then
            ensureAdvancedLogging()
            LoggingCombat(true)
            enabledByUs = true
            say(kind .. " 입장 감지 → 전투 기록 시작 (" .. reason .. ")")
        end
    elseif logging and enabledByUs and leaveToken == 0 then
        -- 우리가 켠 것만, 그것도 유예 시간이 지난 뒤에 끈다. 유저가 직접 켠 기록은 건드리지 않는다.
        leaveToken = leaveToken + 1
        local token = leaveToken
        say(string.format("인스턴스 이탈 → %d분 안에 돌아오지 않으면 전투 기록 종료", LEAVE_GRACE_SECONDS / 60))
        C_Timer.After(LEAVE_GRACE_SECONDS, function()
            if token ~= leaveToken then return end -- 그 사이 재입장함
            leaveToken = 0
            if not wantsLogging() and LoggingCombat() and enabledByUs then
                LoggingCombat(false)
                enabledByUs = false
                say("전투 기록 종료")
            end
        end)
    end
end

frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
frame:RegisterEvent("CHALLENGE_MODE_START")
frame:RegisterEvent("CHALLENGE_MODE_COMPLETED")
frame:RegisterEvent("CHALLENGE_MODE_RESET")

frame:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 == ADDON_NAME then
            initDB()
            say("로드됨. 쐐기 던전 입장 시 전투 기록을 자동으로 켭니다. (/cctv 로 설정)")
        end
        return
    end

    if event == "CHALLENGE_MODE_START" then
        -- 이미 던전 입장 시점에 켜져 있어야 CHALLENGE_MODE_START 줄이 빠짐없이 남는다.
        update("쐐기 시작")
        if LoggingCombat() then
            say("쐐기 시작 → CCTV 앱이 녹화를 시작합니다.")
        end
        return
    end

    if event == "CHALLENGE_MODE_COMPLETED" then
        say("쐐기 종료 → CCTV 앱이 잠시 후 녹화를 마칩니다.")
        return
    end

    -- PLAYER_ENTERING_WORLD 직후에는 IsInInstance 가 늦게 갱신되는 경우가 있어 한 번 더 확인
    update(event)
    C_Timer.After(2, function() update(event .. " (지연 확인)") end)
end)

-- 슬래시 명령
SLASH_OHMYWOWCCTV1 = "/cctv"
SlashCmdList["OHMYWOWCCTV"] = function(msg)
    msg = (msg or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
    initDB()

    if msg == "on" then
        OhMyWowCCTVDB.enabled = true
        say("자동 전투 기록: 켜짐")
        update("수동")
    elseif msg == "off" then
        OhMyWowCCTVDB.enabled = false
        say("자동 전투 기록: 꺼짐")
    elseif msg == "raid" then
        OhMyWowCCTVDB.raids = not OhMyWowCCTVDB.raids
        say("공격대에서도 기록: " .. (OhMyWowCCTVDB.raids and "켜짐" or "꺼짐"))
        update("수동")
    elseif msg == "quiet" then
        OhMyWowCCTVDB.quiet = not OhMyWowCCTVDB.quiet
        print(PREFIX .. "채팅 안내: " .. (OhMyWowCCTVDB.quiet and "숨김" or "표시"))
    else
        local want = wantsLogging()
        print(PREFIX .. "상태")
        print("  자동 기록: " .. (OhMyWowCCTVDB.enabled and "켜짐" or "꺼짐"))
        print("  공격대 포함: " .. (OhMyWowCCTVDB.raids and "켜짐" or "꺼짐"))
        print("  현재 전투 기록: " .. (LoggingCombat() and "기록 중" or "꺼짐") .. (want and " (기록 대상 인스턴스)" or ""))
        print("  고급 전투 기록: " .. (C_CVar.GetCVar("advancedCombatLogging") == "1" and "켜짐" or "꺼짐"))
        print("  명령: /cctv on|off|raid|quiet")
    end
end
