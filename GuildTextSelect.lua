local ADDON_NAME = ...
local DEFAULT_SIZE = 12

-- Saved settings. Replaced by GuildTextFontDB once the addon's saved variables load.
local db = {}
local category

local function defaultFont()
    return (ChatFontNormal and ChatFontNormal:GetFont()) or "Fonts\\ARIALN.TTF"
end

local copyFont = CreateFont("GuildTextFontFont")
copyFont:CopyFontObject(GameFontHighlightSmall)

-- Every section registers a function here that re-lays out its text after a font change.
local sections = {}

local function applyFont()
    local _, _, flags = GameFontHighlightSmall:GetFont()
    local size = math.floor((tonumber(db.size) or DEFAULT_SIZE) + 0.5)
    if copyFont:SetFont(db.font or defaultFont(), size, flags or "") == false then
        -- The chosen font file is gone (for example its addon was removed); fall back to the chat font.
        copyFont:SetFont(defaultFont(), size, flags or "")
    end
    for _, relayout in ipairs(sections) do relayout() end
end
applyFont()

-- Fonts offered in the options menu: the game's own fonts plus anything registered with LibSharedMedia.
local function fontOptions()
    local list, seen = {}, {}
    local function add(name, path)
        if type(path) ~= "string" or path == "" then return end
        local key = path:lower():gsub("/", "\\")
        if seen[key] then return end
        seen[key] = true
        list[#list + 1] = { name = name, path = path }
    end
    add("Chat font", defaultFont())
    add("Arial Narrow", "Fonts\\ARIALN.TTF")
    add("Friz Quadrata", "Fonts\\FRIZQT__.TTF")
    add("Morpheus", "Fonts\\MORPHEUS.ttf")
    add("Skurri", "Fonts\\skurri.ttf")
    local LSM = LibStub and LibStub("LibSharedMedia-3.0", true)
    if LSM then
        for _, name in ipairs(LSM:List("font")) do
            add(name, LSM:Fetch("font", name, true))
        end
    end
    -- Keep the saved choice visible even if its source is no longer registered.
    if db.font then add(db.font:match("[^\\/]+$") or db.font, db.font) end
    return list
end

local function registerSettings()
    if not (Settings and Settings.RegisterVerticalLayoutCategory and Settings.RegisterAddOnSetting) then return end
    local cat = Settings.RegisterVerticalLayoutCategory("Guild Text Font")

    local fontSetting = Settings.RegisterAddOnSetting(cat, "GuildTextFont_Font", "font", db,
        "string", "Font", defaultFont())
    Settings.SetOnValueChangedCallback("GuildTextFont_Font", applyFont)
    local createDropdown = Settings.CreateDropdown or Settings.CreateDropDown
    createDropdown(cat, fontSetting, function()
        local container = Settings.CreateControlTextContainer()
        for _, font in ipairs(fontOptions()) do container:Add(font.path, font.name) end
        return container:GetData()
    end, "Font used for the Message of the Day, Guild Information and Guild News text.")

    local sizeSetting = Settings.RegisterAddOnSetting(cat, "GuildTextFont_Size", "size", db,
        "number", "Font size", DEFAULT_SIZE)
    Settings.SetOnValueChangedCallback("GuildTextFont_Size", applyFont)
    local sliderOptions = Settings.CreateSliderOptions(8, 20, 1)
    if MinimalSliderWithSteppersMixin then
        sliderOptions:SetLabelFormatter(MinimalSliderWithSteppersMixin.Label.Right)
    end
    Settings.CreateSlider(cat, sizeSetting, sliderOptions, "Size of the guild text.")

    Settings.RegisterAddOnCategory(cat)
    return cat
end

SLASH_GUILDTEXTFONT1 = "/gtf"
SlashCmdList.GUILDTEXTFONT = function()
    if category then Settings.OpenToCategory(category:GetID()) end
end

local function readable(value)
    return not issecretvalue or not issecretvalue(value)
end

local function plainText(value)
    if not readable(value) or type(value) ~= "string" then return end
    return (value:gsub("||", "\001")
        :gsub("|H.-|h(.-)|h", "%1")
        :gsub("|c%x%x%x%x%x%x%x%x", "")
        :gsub("|r", "")
        :gsub("|T.-|t", "")
        :gsub("|A.-|a", "")
        :gsub("|n", "\n")
        :gsub("\001", "|"))
end

local function urlRange(chunk)
    local lower = chunk:lower()
    local first = lower:find("https?://") or lower:find("www%.")
        or lower:find("%f[%w][%w][%w.%-]*%.%a%a+[/:?#]")
    if not first then return end

    local url = chunk:sub(first):match("^[^<>\"']+")
    if not url then return end
    url = url:gsub("[.,;:!?]+$", "")
    local openFor = { [")"] = "(", ["]"] = "[", ["}"] = "{" }
    while openFor[url:sub(-1)] do
        local closing = url:sub(-1)
        local _, opens = url:gsub("%" .. openFor[closing], "")
        local _, closes = url:gsub("%" .. closing, "")
        if closes <= opens then break end
        url = url:sub(1, -2):gsub("[.,;:!?]+$", "")
    end
    if #url > 0 then return first, first + #url - 1 end
end

local function selectionAtCursor(text, cursor)
    for first, chunk, after in text:gmatch("()(%S+)()") do
        if cursor < first - 1 then return end
        if cursor < after then
            local startURL, endURL = urlRange(chunk)
            local position = cursor - first + 1
            if startURL and position >= startURL - 1 and position <= endURL then
                return first + startURL - 2, first + endURL - 1
            end

            -- Keep byte offsets intact when turning Unicode dashes into word breaks.
            local words = chunk:gsub("\226\128[\144-\149]", "   ")
            for startWord, word in words:gmatch("()([%w_\128-\255][%w_\128-\255']*)") do
                word = word:gsub("'+$", "")
                local endWord = startWord + #word - 1
                if position >= startWord - 1 and position <= endWord then
                    return first + startWord - 2, first + endWord - 1
                end
            end
            return
        end
    end
end

local function closeToClick(x, y, click)
    local dx, dy = x - click.x, y - click.y
    return dx * dx + dy * dy <= 36
end

local function createEditor(parent, font, multiline)
    local edit = CreateFrame("EditBox", nil, parent)
    edit:SetAutoFocus(false)
    edit:SetMultiLine(multiline)
    edit:SetFontObject(font)
    edit:SetJustifyH("LEFT")
    if edit.SetPassThroughButtons then edit:SetPassThroughButtons("RightButton") end
    edit:SetScript("OnEscapePressed", edit.ClearFocus)
    edit:SetScript("OnEnterPressed", edit.ClearFocus)
    edit:SetScript("OnHide", edit.ClearFocus)
    local mouseDown, previousClick
    edit:SetScript("OnEditFocusLost", function(self)
        mouseDown, previousClick = nil, nil
        self:HighlightText(0, 0)
    end)
    edit:SetScript("OnMouseDown", function(_, button)
        if button ~= "LeftButton" then return end
        local x, y = GetCursorPosition()
        mouseDown = { x = x, y = y, time = GetTime() }
    end)
    edit:SetScript("OnMouseUp", function(self, button, upInside)
        if button ~= "LeftButton" then return end
        local down, firstClick = mouseDown, previousClick
        mouseDown, previousClick = nil, nil
        local x, y = GetCursorPosition()
        local now = GetTime()
        if not down or upInside == false or not self:HasFocus()
            or now - down.time > 0.35 or not closeToClick(x, y, down) then return end

        local text = self.copyText
        if not text or text == "" then return end
        if firstClick and firstClick.text == text and now - firstClick.time <= 0.35
            and closeToClick(x, y, firstClick) then
            local first, last = selectionAtCursor(text, firstClick.cursor)
            if first then
                -- Apply the full range after the native double-click finishes.
                C_Timer.After(0, function()
                    if self:HasFocus() and self.copyText == text and not mouseDown and not previousClick then
                        self:HighlightText(first, last)
                    end
                end)
            end
        else
            previousClick = { x = x, y = y, time = now, text = text, cursor = self:GetCursorPosition() }
        end
    end)
    -- The edit box supplies selection only. Keep its contents read-only.
    edit:SetScript("OnTextChanged", function(self)
        if not self.settingText and self:GetText() ~= self.copyText then
            local cursor = self:GetCursorPosition()
            self.settingText = true
            self:SetText(self.copyText or "")
            self:SetCursorPosition(math.min(cursor, #(self.copyText or "")))
            self.settingText = nil
        end
    end)
    return edit
end

local function setText(edit, text)
    if edit.copyText == text then return end
    edit:ClearFocus()
    edit.settingText = true
    edit.copyText = text
    edit:SetText(text)
    edit:SetCursorPosition(0)
    edit.settingText = nil
end

local function createSection(info, original, getter, leftOffset, bottomAnchor, originalBar)
    local scroll = CreateFrame("ScrollFrame", nil, info, "ScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", original, "TOPLEFT", leftOffset, 0)
    scroll:SetPoint("TOPRIGHT", original, "TOPRIGHT")
    if originalBar then
        scroll:SetPoint("BOTTOM", original, "BOTTOM")
    elseif bottomAnchor then
        scroll:SetPoint("BOTTOM", bottomAnchor, "TOP", 0, 4)
    else
        scroll:SetPoint("BOTTOM", info, "BOTTOM", 0, 5)
    end
    scroll:SetFrameLevel(original:GetFrameLevel() + 1)
    scroll:Hide()
    local edit = createEditor(scroll, copyFont, true)
    local rightInset, topInset, bottomInset = 6, 4, 4
    edit:SetHeight(1)
    edit:SetTextInsets(0, rightInset, topInset, bottomInset)
    edit:SetSpacing(2)
    scroll:SetScrollChild(edit)
    -- The measuring string must use the same font so the scroll height stays correct.
    local measure = scroll:CreateFontString(nil, "ARTWORK")
    measure:SetFontObject(copyFont)
    measure:SetSpacing(2)
    measure:SetWordWrap(true)
    measure:SetNonSpaceWrap(true)
    measure:Hide()

    local function resize()
        local width = math.max(1, scroll:GetWidth())
        edit:SetWidth(width)
        measure:SetWidth(math.max(1, width - rightInset))
        edit:SetHeight(math.max(1, scroll:GetHeight(), measure:GetStringHeight() + topInset + bottomInset))
    end
    scroll:SetScript("OnSizeChanged", resize)

    -- Re-apply the font and re-measure when the font or size changes in the options.
    sections[#sections + 1] = function()
        edit:SetFontObject(copyFont)
        measure:SetFontObject(copyFont)
        local text = edit.copyText
        if text and text ~= "" then
            edit.settingText = true
            edit:SetText(text)
            edit.settingText = nil
            measure:SetText(text)
        end
        resize()
        scroll:SetVerticalScroll(math.min(scroll:GetVerticalScroll(), scroll:GetVerticalScrollRange()))
    end

    edit:SetScript("OnCursorChanged", function(self, _, y, _, height)
        if not self:HasFocus() then return end
        local offset = scroll:GetVerticalScroll()
        local top = -y
        local bottom = top + height
        if top < offset then
            scroll:SetVerticalScroll(math.max(0, top))
        elseif bottom > offset + scroll:GetHeight() then
            scroll:SetVerticalScroll(math.min(scroll:GetVerticalScrollRange(), bottom - scroll:GetHeight()))
        end
    end)

    local pendingRefresh
    local function refresh()
        if edit:HasFocus() then
            pendingRefresh = true
            if originalBar then originalBar:Hide() end
            return
        end
        pendingRefresh = nil
        local ok, result = pcall(getter)
        local text = ok and plainText(result)
        if not text then
            scroll:Hide()
            setText(edit, "")
            original:Show()
            if originalBar then originalBar:Show() end
            return
        end
        local changed = edit.copyText ~= text
        local offset = originalBar and scroll:GetVerticalScroll() or 0
        setText(edit, text)
        if changed then
            measure:SetText(text)
            resize()
        end
        original:Hide()
        if originalBar then originalBar:Hide() end
        scroll:Show()
        if changed then scroll:SetVerticalScroll(math.min(offset, scroll:GetVerticalScrollRange())) end
    end
    edit:HookScript("OnEditFocusLost", function()
        if pendingRefresh and info:IsVisible() then refresh() end
    end)
    return refresh
end

local function attachNews(news)
    local box = news.ScrollBox
    local view = box:GetView()
    if not (view and view.GetDataProvider and news.ScrollBar
        and type(CommunitiesGuildNews_Update) == "function") then return end

    -- Read the full filtered list with the same formatter the stock rows use.
    -- The editor belongs to the panel, so recycled rows cannot interrupt a drag.
    local sample = CreateFrame("Button", nil, news, "CommunitiesGuildNewsButtonTemplate")
    sample:Hide()
    if not (sample.Init and sample.text) then return end
    local function getNewsText()
        local provider = view:GetDataProvider()
        if not (provider and provider.EnumerateEntireRange) then return end
        local entries = {}
        for _, data in provider:EnumerateEntireRange() do
            sample.text:SetText("")
            if pcall(sample.Init, sample, data) then
                local text = sample.text:GetText()
                if readable(text) and type(text) == "string" and text ~= "" then
                    entries[#entries + 1] = text
                end
            end
        end
        if #entries > 0 then return table.concat(entries, "\n\n") end
    end

    local refresh = createSection(news, box, getNewsText, 10, nil, news.ScrollBar)
    news:HookScript("OnShow", refresh)
    hooksecurefunc("CommunitiesGuildNews_Update", function(frame)
        if frame == news and news:IsVisible() then refresh() end
    end)
    if news:IsVisible() then refresh() end
end

local attached, settingsLoaded
local events = CreateFrame("Frame")
local function attach()
    if attached then return end
    local details = CommunitiesFrame and CommunitiesFrame.GuildDetailsFrame
    local info = details and details.Info
    local news = details and details.News
    if not (info and news and info.MOTDScrollFrame and info.DetailsFrame
        and C_GuildInfo and C_GuildInfo.GetMOTD and C_GuildInfo.GetInfoText
        and type(CommunitiesGuildInfoFrame_UpdateText) == "function"
        and news.ScrollBox) then return end

    local detailsHeader = info.Header3 or _G[info:GetName() .. "Header3"]
    if not detailsHeader then return end
    local updateMOTD = createSection(info, info.MOTDScrollFrame, C_GuildInfo.GetMOTD, -4, detailsHeader)
    local updateInfo = createSection(info, info.DetailsFrame, C_GuildInfo.GetInfoText, -4)
    local function refresh()
        if not info:IsVisible() then return end
        updateMOTD()
        updateInfo()
    end

    info:HookScript("OnShow", refresh)
    hooksecurefunc("CommunitiesGuildInfoFrame_UpdateText", function(frame)
        if frame == info then refresh() end
    end)
    info:HookScript("OnEvent", function(_, event)
        if event == "GUILD_MOTD" or event == "PLAYER_GUILD_UPDATE" then refresh() end
    end)
    attachNews(news)
    refresh()
    attached = true
end

events:RegisterEvent("ADDON_LOADED")
events:SetScript("OnEvent", function(_, _, name)
    if name == ADDON_NAME and not settingsLoaded then
        GuildTextFontDB = GuildTextFontDB or {}
        db = GuildTextFontDB
        db.font = db.font or defaultFont()
        db.size = db.size or DEFAULT_SIZE
        settingsLoaded = true
        applyFont()
        category = registerSettings()
    end
    if name == "Blizzard_Communities" or name == ADDON_NAME then attach() end
    if attached and settingsLoaded then events:UnregisterEvent("ADDON_LOADED") end
end)