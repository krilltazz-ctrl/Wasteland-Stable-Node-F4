Scriptname FO4_AIChatQuestScript extends Quest

; --- FILE PATHS ---
string property PromptFile       = "fo4_prompt.txt"         autoReadOnly
string property ResponseFile     = "fo4_response.txt"       autoReadOnly
string property MoodFile         = "fo4_mood.txt"           autoReadOnly
string property CombatResultFile = "fo4_combat_result.txt"  autoReadOnly
string property EventFile        = "fo4_recent_events.txt"  autoReadOnly

; --- TIMING ---
float property PollInterval      = 0.5   autoReadOnly
int   property MaxPollCycles     = 30    autoReadOnly
float property BanterInterval    = 180.0 autoReadOnly

; --- IDLE ANIMATIONS ---
Idle[] property IdleThinking auto
Idle property IdleDefault  auto
Idle property IdleStop     auto

; --- MOOD ANIMATIONS ---
Idle property IdleHappy auto
Idle property IdleAngry auto
Idle property IdleSad   auto
Idle property IdleFear  auto

; --- COMPANION REFERENCE ---
Actor property CurrentCompanion auto

; --- INPUT PRESETS ---
string[] property InputPresets auto

; --- FALLBACK LINES ---
string[] property FallbackLines auto

; --- MOOD TRACKING ---
string[] property MoodNPCNames auto
string[] property MoodLabels   auto
int      property MoodCount = 0 auto

; --- CONVERSATION COUNTER ---
int  _conversationCount = 0
string _lastNPCName     = ""
string _lastPlayerMsg   = ""
string _lastNPCResponse = ""

; --- STATE ---
bool  _isProcessing     = false
bool  _isFistfighting   = false
bool  _isFollowing      = false
bool  _fightPaused      = false
bool  _ceasefireActive  = false
bool  _banterRunning    = false
Actor _fightTarget      = None
Actor _followTarget     = None
Actor _ceaseFireLeader  = None

; --- GIFT KEY ---
; G key = 71
string[] property RecentKills auto
int      property RecentKillCount = 0 auto
string[] property VisitedLocations auto
int      property VisitedCount = 0 auto


; ==========================================================
; INIT
; ==========================================================
Event OnInit()
    RegisterForKey(72)  ; H = chat
    RegisterForKey(71)  ; G = gift
    RegisterForActorKill()

    InputPresets    = new string[5]
    InputPresets[0] = "Tell me something interesting."
    InputPresets[1] = "How are things going around here?"
    InputPresets[2] = "Seen anything strange lately?"
    InputPresets[3] = "What do you think about this place?"
    InputPresets[4] = "Got any advice for me?"

    FallbackLines    = new string[5]
    FallbackLines[0] = "..."
    FallbackLines[1] = "Got nothing for you right now."
    FallbackLines[2] = "My head's not right today."
    FallbackLines[3] = "Ask me later."
    FallbackLines[4] = "Not now."

    MoodNPCNames     = new string[30]
    MoodLabels       = new string[30]
    MoodCount        = 0
    RecentKills      = new string[10]
    RecentKillCount  = 0
    VisitedLocations = new string[10]
    VisitedCount     = 0
    FollowerStates   = new string[10]
    FollowerCount    = 0

    _StartBanterLoop()
    _StartCombatDramaLoop()
    _StartLocationTracker()
EndEvent


; ==========================================================
; KILL TRACKING
; ==========================================================
Event OnActorKill(Actor akVictim, Actor akKiller)
    string killName
    string killLoc
    string killEntry
    float currentTime
    float timeDiff

    if akKiller != Game.GetPlayer()
        return
    endIf
    if akVictim == None || akVictim.IsDead() == false
        return
    endIf

    ; --- Kill streak tracking ---
    currentTime = Utility.GetCurrentGameTime()
    timeDiff    = (currentTime - _lastKillGameTime) * 1440.0
    if timeDiff > 0.167
        _killStreak = 1
    else
        _killStreak += 1
    endIf
    _lastKillGameTime = currentTime
    if _killStreak > KillStreakMax
        KillStreakMax = _killStreak
    endIf

    ; --- Morale check at streak thresholds ---
    if _killStreak == 3 || _killStreak == 5 || _killStreak == 8
        _CheckMoraleBreak()
    endIf

    ; --- Kill log ---
    killName  = akVictim.GetDisplayName()
    killLoc   = _GetLocationName()
    killEntry = killName + " at " + killLoc

    int i
    i = 9
    while i > 0
        RecentKills[i] = RecentKills[i - 1]
        i -= 1
    endWhile
    RecentKills[0] = killEntry
    if RecentKillCount < 10
        RecentKillCount += 1
    endIf

    _WriteRecentEvents()
EndEvent


; ==========================================================
; LOCATION TRACKER
; ==========================================================
Function _StartLocationTracker()
    _LocationTick()
EndFunction


Function _LocationTick()
    string lastLoc
    string curLoc
    lastLoc = ""

    while true
        Utility.Wait(10.0)
        curLoc = _GetLocationName()
        if curLoc != lastLoc && curLoc != "the Commonwealth"
            lastLoc = curLoc
            _TrackLocation(curLoc)
        endIf
    endWhile
EndFunction


Function _TrackLocation(string locName)
    ; Check if already tracked
    int i
    i = 0
    while i < VisitedCount
        if VisitedLocations[i] == locName
            return
        endIf
        i += 1
    endWhile

    ; Shift and add
    i = 9
    while i > 0
        VisitedLocations[i] = VisitedLocations[i - 1]
        i -= 1
    endWhile
    VisitedLocations[0] = locName
    if VisitedCount < 10
        VisitedCount += 1
    endIf

    _WriteRecentEvents()
EndFunction


Function _WriteRecentEvents()
    string eventData
    int i

    eventData = "KILLS:"
    i = 0
    while i < RecentKillCount
        if i > 0
            eventData += ","
        endIf
        eventData += RecentKills[i]
        i += 1
    endWhile

    eventData += "|LOCATIONS:"
    i = 0
    while i < VisitedCount
        if i > 0
            eventData += ","
        endIf
        eventData += VisitedLocations[i]
        i += 1
    endWhile

    System:IO:File.WriteAllText(EventFile, eventData)
EndFunction


; ==========================================================
; H KEY
; ==========================================================
Event OnKeyDown(Int KeyCode)
    If KeyCode == 72
        if _isFistfighting
            _ShowFightPauseMenu()
        elseIf Game.GetPlayer().IsInCombat()
            _StartCombatNegotiation()
        else
            StartAIChat()
        endIf
    elseIf KeyCode == 71
        _StartGiftInteraction()
    EndIf
EndEvent


; ==========================================================
; MAIN CHAT
; ==========================================================
Function StartAIChat()
    Actor targetActor
    float pX
    float pY
    float pZ
    string npcName
    string locName
    string playerMsg
    string context
    string npcSex
    string handshake
    string response
    string npcState
    string drunkFlag
    ActorBase npcBase

    if _isProcessing
        Debug.Notification("Still waiting on a response...")
        return
    endIf

    targetActor = Game.FindClosestActorFromRef(Game.GetPlayer(), 200.0)
    if targetActor == None
        Debug.Notification("No one nearby to talk to.")
        return
    endIf
    if targetActor == Game.GetPlayer()
        pX = Game.GetPlayer().X
        pY = Game.GetPlayer().Y
        pZ = Game.GetPlayer().Z
        targetActor = Game.FindClosestActor(pX, pY, pZ, 400.0)
    endIf
    if targetActor == None || targetActor == Game.GetPlayer()
        Debug.Notification("No one nearby to talk to.")
        return
    endIf
    if targetActor.IsDead()
        Debug.Notification("They're not going to answer.")
        return
    endIf
    if targetActor.IsInCombat()
        Debug.Notification("They're a little busy right now.")
        return
    endIf

    _isProcessing   = true
    npcName         = _GetNPCName(targetActor)
    locName         = _GetLocationName()
    playerMsg       = _GetPlayerInput(npcName)
    context         = _BuildContext()
    npcSex          = "m"

    npcBase = targetActor.GetLeveledActorBase() as ActorBase
    if npcBase != None
        if npcBase.GetSex() == 1
            npcSex = "f"
        endIf
    endIf

    ; --- NPC State ---
    npcState = _GetNPCState(targetActor)

    ; --- Combat interrupt check ---
    ; If player enters combat mid-conversation kill the audio
    if Game.GetPlayer().IsInCombat()
        System:IO:File.WriteAllText("fo4_interrupt.txt", "INTERRUPT")
        targetActor.SetRestrained(false)
        targetActor.ClearLookAt()
        Debug.Notification("Not a great time for a chat...")
        _isProcessing = false
        return
    endIf

    ; --- Drunk check ---
    drunkFlag = _GetDrunkFlag(locName)

    handshake = "NAME:" + npcName + "|MSG:" + playerMsg + "|LOC:" + locName + "|SEX:" + npcSex + "|STATE:" + npcState + drunkFlag + context

    System:IO:File.WriteAllText(ResponseFile, "")
    System:IO:File.WriteAllText(PromptFile, handshake)

    targetActor.SetRestrained(true)
    targetActor.SetLookAt(Game.GetPlayer())
    ; Play random thinking idle if array has entries
    if IdleThinking != None && IdleThinking.Length > 0
        targetActor.PlayIdle(IdleThinking[Utility.RandomInt(0, IdleThinking.Length - 1)])
    endIf
    Debug.Notification("...")

    response = _PollForResponse(targetActor)

    targetActor.PlayIdle(IdleStop)
    targetActor.ClearLookAt()
    targetActor.SetRestrained(false)

    _DisplayResponse(npcName, response)
    _UpdateMood(npcName, targetActor)

    ; --- Store last exchange for companion reaction ---
    _lastNPCName     = npcName
    _lastPlayerMsg   = playerMsg
    _lastNPCResponse = response
    _conversationCount += 1

    ; --- Companion reacts every 3rd conversation ---
    if _conversationCount >= 3
        _conversationCount = 0
        _TriggerCompanionReaction()
    endIf

    System:IO:File.WriteAllText(ResponseFile, "")
    _isProcessing = false
EndFunction


; ==========================================================
; GIFT INTERACTION (G key)
; ==========================================================
Function _StartGiftInteraction()
    Actor targetActor
    float pX
    float pY
    float pZ
    string npcName
    string giftName
    string handshake
    string response
    string npcSex
    ActorBase npcBase

    if _isProcessing
        Debug.Notification("Still busy...")
        return
    endIf

    targetActor = Game.FindClosestActorFromRef(Game.GetPlayer(), 200.0)
    if targetActor == None || targetActor == Game.GetPlayer()
        Debug.Notification("No one nearby to give to.")
        return
    endIf
    if targetActor.IsDead()
        Debug.Notification("That won't help them now.")
        return
    endIf

    _isProcessing = true
    npcName       = _GetNPCName(targetActor)
    npcSex        = "m"

    npcBase = targetActor.GetLeveledActorBase() as ActorBase
    if npcBase != None
        if npcBase.GetSex() == 1
            npcSex = "f"
        endIf
    endIf

    ; Ask Python what item the player wants to give
    System:IO:File.WriteAllText("fo4_input_request.txt", "GIFT:" + npcName)
    giftName = _WaitForInput()

    if giftName == "" || giftName == "CANCEL"
        Debug.Notification("Never mind.")
        _isProcessing = false
        return
    endIf

    Debug.Notification("You offer " + giftName + " to " + npcName + "...")

    ; Send to bridge for reaction
    handshake = "NAME:" + npcName + "|MSG:GIFT|LOC:" + _GetLocationName() + "|SEX:" + npcSex + "|GIFTED_ITEM:" + giftName + _BuildContext()
    System:IO:File.WriteAllText(ResponseFile, "")
    System:IO:File.WriteAllText(PromptFile, handshake)

    ; Freeze NPC briefly
    targetActor.SetRestrained(true)
    targetActor.SetLookAt(Game.GetPlayer())

    response = _PollForBanter()

    targetActor.ClearLookAt()
    targetActor.SetRestrained(false)

    if response != ""
        _DisplayResponse(npcName, response)
        _UpdateMood(npcName, targetActor)
    endIf

    System:IO:File.WriteAllText(ResponseFile, "")
    _isProcessing = false
EndFunction



string Function _GetNPCState(Actor akTarget)
    ; Check if NPC appears wounded or hungry
    ; Use essential/protected flags as proxy
    if akTarget.IsEssential()
        return "HEALTHY"
    endIf

    ; Check if NPC is a settler (may be hungry)
    string npcName
    npcName = _GetNPCName(akTarget)

    int lvl
    lvl = akTarget.GetLevel()

    ; Lower level NPCs in dangerous areas likely hurt
    if lvl < 5 && Game.GetPlayer().IsInCombat()
        return "WOUNDED"
    endIf

    ; Random chance of hungry for settlers
    int roll
    roll = Utility.RandomInt(0, 10)
    if roll < 2
        return "HUNGRY"
    endIf

    return "HEALTHY"
EndFunction


; ==========================================================
; DRUNK DETECTION
; ==========================================================
string Function _GetDrunkFlag(string locName)
    string locLower
    float gameHour
    int hour
    int roll

    locLower  = locName
    gameHour  = Utility.GetCurrentGameTime() * 24.0
    hour      = gameHour as int
    hour      = hour - ((hour / 24) * 24)

    ; Bar locations and late hours increase drunk chance
    bool isBar
    isBar = false
    if locLower == "Dugout Inn" || locLower == "The Third Rail" || locLower == "Goodneighbor" || locLower == "Rexford Hotel"
        isBar = true
    endIf

    if isBar && (hour >= 20 || hour < 2)
        roll = Utility.RandomInt(0, 10)
        if roll < 4
            return "|DRUNK:TRUE"
        endIf
    elseIf isBar
        roll = Utility.RandomInt(0, 10)
        if roll < 2
            return "|DRUNK:TRUE"
        endIf
    endIf

    return ""
EndFunction


; ==========================================================
; COMPANION REACTION
; ==========================================================
Function _TriggerCompanionReaction()
    Actor companion
    string compName
    string handshake
    string response
    string context

    companion = _FindCompanion()
    if companion == None
        return
    endIf
    if _lastNPCName == "" || _lastNPCResponse == ""
        return
    endIf

    compName = _GetNPCName(companion)
    context  = _BuildContext()

    handshake = "NAME:" + compName + "|MSG:COMPANION_REACT|LOC:" + _GetLocationName() + "|SEX:m|COMPANION_REACT:TRUE|LAST_NPC:" + _lastNPCName + "|LAST_MSG:" + _lastPlayerMsg + "|LAST_RESP:" + _lastNPCResponse + context

    System:IO:File.WriteAllText(ResponseFile, "")
    System:IO:File.WriteAllText(PromptFile, handshake)

    Utility.Wait(3.0)
    response = _PollForBanter()
    if response != "" && response != "..."
        Debug.Notification(compName + ": " + response)
    endIf
    System:IO:File.WriteAllText(ResponseFile, "")
EndFunction


; ==========================================================
; CONTEXT BUILDER
; ==========================================================
string Function _BuildContext()
    string ctx
    float gameHour
    int hour
    Weather currentWeather
    int wType
    string weatherStr
    string armorStr
    string dangerStr
    string repStr
    string wealthStr
    string nakedStr
    string corpseStr
    string radstormStr
    string envStr
    Keyword legendaryKW
    Keyword powerArmorKW
    Weapon equippedWeapon
    Faction minutemenFaction
    Faction bosFaction
    Actor nearbyCorpse
    Actor nearestActor
    Cell currentCell
    Form chestArmor
    int playerCaps
    float distToNPC

    ctx = ""

    gameHour = Utility.GetCurrentGameTime() * 24.0
    hour     = gameHour as int
    hour     = hour - ((hour / 24) * 24)
    ctx     += "|HOUR:" + hour

    ; --- Weather + Radstorm ---
    weatherStr  = "Clear"
    radstormStr = ""
    currentWeather = Weather.GetCurrentWeather()
    if currentWeather != None
        wType = currentWeather.GetClassification()
        if wType == 1
            weatherStr = "Rainy"
        elseIf wType == 2
            weatherStr = "Snowy"
        elseIf wType == 3
            weatherStr = "Thunderstorm"
        elseIf wType == 4
            weatherStr  = "Radstorm"
            radstormStr = "|RADSTORM:TRUE"
        endIf
    endIf
    ctx += "|WEATHER:" + weatherStr + radstormStr

    ; --- Power armor ---
    armorStr     = "NORMAL"
    powerArmorKW = Game.GetFormFromFile(0x00044CB4, "Fallout4.esm") as Keyword
    if powerArmorKW != None && Game.GetPlayer().WornHasKeyword(powerArmorKW)
        armorStr = "POWER"
    endIf
    ctx += "|ARMOR:" + armorStr

    ; --- Legendary weapon ---
    dangerStr      = "UNARMED"
    legendaryKW    = Game.GetFormFromFile(0x000FECF4, "Fallout4.esm") as Keyword
    equippedWeapon = Game.GetPlayer().GetEquippedWeapon() as Weapon
    if equippedWeapon != None
        if legendaryKW != None && equippedWeapon.HasKeyword(legendaryKW)
            dangerStr = "LEGENDARY"
        else
            dangerStr = "ARMED"
        endIf
    endIf
    ctx += "|DANGER:" + dangerStr
    ctx += "|LEVEL:" + Game.GetPlayer().GetLevel()

    ; --- Faction rep ---
    repStr           = "NONE"
    minutemenFaction = Game.GetFormFromFile(0x0002ACDD, "Fallout4.esm") as Faction
    bosFaction       = Game.GetFormFromFile(0x0001CFFE, "Fallout4.esm") as Faction
    if minutemenFaction != None && Game.GetPlayer().GetFactionRank(minutemenFaction) >= 0
        repStr = "Minutemen"
    elseIf bosFaction != None && Game.GetPlayer().GetFactionRank(bosFaction) >= 0
        repStr = "Brotherhood"
    endIf
    ctx += "|REP:" + repStr
    ctx += "|KILLSTREAK:" + _killStreak
    ctx += "|TIMESPARED:" + TimesSpared
    ctx += "|ENCOUNTERS:" + TotalEncounters

    ; --- Environment ---
    string envStr
    Cell currentCell
    envStr      = "EXTERIOR"
    currentCell = Game.GetPlayer().GetParentCell()
    if currentCell != None
        if currentCell.IsInterior()
            envStr = "INTERIOR"
        endIf
    endIf
    ctx += "|ENV:" + envStr
    wealthStr  = "NORMAL"
    playerCaps = Game.GetPlayer().GetItemCount(Game.GetFormFromFile(0x0000000F, "Fallout4.esm"))
    if playerCaps >= 10000
        wealthStr = "RICH"
    elseIf playerCaps <= 50
        wealthStr = "BROKE"
    endIf
    ctx += "|WEALTH:" + wealthStr

    ; --- Naked check (chest slot empty) ---
    nakedStr  = ""
    chestArmor = Game.GetPlayer().GetWornForm(0x00000003)
    if chestArmor == None
        nakedStr = "|NAKED:TRUE"
    endIf
    ctx += nakedStr

    ; --- Corpse nearby check ---
    corpseStr    = ""
    nearbyCorpse = Game.FindClosestActorFromRef(Game.GetPlayer(), 300.0)
    if nearbyCorpse != None && nearbyCorpse != Game.GetPlayer()
        if nearbyCorpse.IsDead()
            corpseStr = "|CORPSE_NEARBY:" + nearbyCorpse.GetDisplayName()
        endIf
    endIf
    ctx += corpseStr

    ; --- Distance for spatial audio ---
    distToNPC    = 0.0
    nearestActor = Game.FindClosestActorFromRef(Game.GetPlayer(), 2000.0)
    if nearestActor != None && nearestActor != Game.GetPlayer()
        distToNPC = Game.GetPlayer().GetDistance(nearestActor)
    endIf
    ctx += "|DIST:" + distToNPC

    ; --- Player status ---
    string playerStatus
    playerStatus = "NORMAL"
    if Game.GetPlayer().IsOnFire()
        playerStatus = "ON_FIRE"
    elseIf Game.GetPlayer().IsUnconscious()
        playerStatus = "INCAPACITATED"
    endIf
    ctx += "|PLAYER_STATUS:" + playerStatus

    return ctx
EndFunction


; ==========================================================
; MOOD SYSTEM
; ==========================================================
Function _UpdateMood(string npcName, Actor akTarget)
    string label
    int idx

    label = System:IO:File.ReadAllText(MoodFile)
    if label == ""
        label = "NEUTRAL"
    endIf

    idx = _FindMoodIndex(npcName)
    if idx == -1 && MoodCount < 30
        MoodNPCNames[MoodCount] = npcName
        MoodLabels[MoodCount]   = label
        MoodCount += 1
    elseIf idx >= 0
        MoodLabels[idx] = label
    endIf

    ; --- Mood animations ---
    if label == "PLEASED" || label == "HAPPY" || label == "BEST_FRIENDS"
        if IdleHappy != None
            akTarget.PlayIdle(IdleHappy)
        endIf
    elseIf label == "ANGRY" || label == "FURIOUS"
        if IdleAngry != None
            akTarget.PlayIdle(IdleAngry)
        endIf
    elseIf label == "ANNOYED"
        if IdleSad != None
            akTarget.PlayIdle(IdleSad)
        endIf
    elseIf label == "HOSTILE"
        if IdleFear != None
            akTarget.PlayIdle(IdleFear)
        endIf
    endIf

    ; --- Mood notifications and behaviors ---
    if label == "ANNOYED"
        Debug.Notification(npcName + " seems annoyed...")
    elseIf label == "ANGRY"
        Debug.Notification(npcName + " is getting angry! Watch it.")
    elseIf label == "FURIOUS"
        Debug.Notification(npcName + " has had ENOUGH!")
        Utility.Wait(1.5)
        _StartFistfight(akTarget)
    elseIf label == "HOSTILE"
        Debug.Notification(npcName + " reaches for their weapon...")
        Utility.Wait(2.0)
        _StartHostileCombat(akTarget)
    elseIf label == "PLEASED"
        Debug.Notification(npcName + " seems pleased.")
    elseIf label == "HAPPY"
        Debug.Notification(npcName + " really likes you!")
    elseIf label == "BEST_FRIENDS"
        Debug.Notification(npcName + " considers you a true friend!")
        Utility.Wait(1.5)
        _TriggerFriendlyOutcome(akTarget)
    endIf
EndFunction


int Function _FindMoodIndex(string npcName)
    int i
    i = 0
    while i < MoodCount
        if MoodNPCNames[i] == npcName
            return i
        endIf
        i += 1
    endWhile
    return -1
EndFunction


; ==========================================================
; FISTFIGHT SYSTEM
; ==========================================================
Function _StartFistfight(Actor akTarget)
    if _isFistfighting
        return
    endIf

    _isFistfighting = true
    _fightPaused    = false
    _fightTarget    = akTarget

    akTarget.SetEssential(true)
    akTarget.UnequipAll()

    Debug.Notification("FISTFIGHT! Press H to offer peace. No weapons!")
    Utility.Wait(2.0)
    akTarget.StartCombat(Game.GetPlayer())
    Utility.Wait(20.0)

    if _isFistfighting
        _EndFistfight(false)
    endIf
EndFunction


Function _EndFistfight(bool playerSurrendered)
    Actor target
    int roll
    int idx

    if !_isFistfighting
        return
    endIf

    target = _fightTarget
    target.StopCombat()
    target.StopCombatAlarm()
    Game.GetPlayer().StopCombat()
    target.SetEssential(false)

    if playerSurrendered
        Debug.MessageBox(target.GetDisplayName() + ":\n\nFine. But don't push me again.")
    else
        roll = Utility.RandomInt(0, 1)
        if roll == 0
            Debug.MessageBox(target.GetDisplayName() + ":\n\nHeh. Not bad. Watch your mouth next time.")
        else
            Debug.MessageBox(target.GetDisplayName() + ":\n\n...Alright, you win. I'll remember that.")
        endIf
    endIf

    idx = _FindMoodIndex(target.GetDisplayName())
    if idx >= 0
        MoodLabels[idx] = "NEUTRAL"
    endIf

    _isFistfighting = false
    _fightPaused    = false
    _fightTarget    = None
EndFunction


; ==========================================================
; FIGHT PAUSE MENU
; ==========================================================
Function _ShowFightPauseMenu()
    string npcName
    string choice
    int playerCaps

    if !_isFistfighting || _fightTarget == None
        return
    endIf

    _fightTarget.StopCombat()
    _fightPaused = true
    npcName      = _fightTarget.GetDisplayName()

    System:IO:File.WriteAllText("fo4_input_request.txt", "FIGHT_PAUSE:" + npcName)
    choice = _WaitForInput()

    if choice == "0"
        Debug.Notification("You apologize sincerely...")
        _EndFistfight(true)
    elseIf choice == "1"
        playerCaps = Game.GetPlayer().GetItemCount(Game.GetFormFromFile(0x0000000F, "Fallout4.esm"))
        if playerCaps >= 50
            Game.GetPlayer().RemoveItem(Game.GetFormFromFile(0x0000000F, "Fallout4.esm"), 50)
            Debug.Notification("You hand over 50 caps...")
            _EndFistfight(true)
        else
            Debug.Notification("You don't have enough caps!")
            _fightPaused = false
            _fightTarget.StartCombat(Game.GetPlayer())
        endIf
    else
        Debug.Notification("Back to it!")
        _fightPaused = false
        _fightTarget.StartCombat(Game.GetPlayer())
    endIf
EndFunction


; ==========================================================
; HOSTILE COMBAT
; ==========================================================
Function _StartHostileCombat(Actor akTarget)
    string npcName
    string choice
    int playerCaps
    int idx

    npcName = akTarget.GetDisplayName()
    System:IO:File.WriteAllText("fo4_input_request.txt", "HOSTILE:" + npcName)
    choice = _WaitForInput()

    if choice == "0"
        playerCaps = Game.GetPlayer().GetItemCount(Game.GetFormFromFile(0x0000000F, "Fallout4.esm"))
        if playerCaps >= 200
            Game.GetPlayer().RemoveItem(Game.GetFormFromFile(0x0000000F, "Fallout4.esm"), 200)
            Debug.Notification("You back down and pay up. The tension breaks.")
            idx = _FindMoodIndex(npcName)
            if idx >= 0
                MoodLabels[idx] = "ANGRY"
            endIf
        else
            Debug.Notification("You don't have 200 caps!")
            akTarget.StartCombat(Game.GetPlayer())
        endIf
    elseIf choice == "1"
        Debug.Notification("You back away slowly...")
        idx = _FindMoodIndex(npcName)
        if idx >= 0
            MoodLabels[idx] = "FURIOUS"
        endIf
    else
        Debug.Notification("It's on. Don't die.")
        akTarget.StartCombat(Game.GetPlayer())
    endIf
EndFunction


; ==========================================================
; COMBAT NEGOTIATION
; ==========================================================
Function _StartCombatNegotiation()
    Actor targetActor
    string gruntName
    string context
    string tierStr
    string choice
    string handshake
    string response
    string result
    string secret

    if _isProcessing
        return
    endIf

    targetActor = Game.FindClosestActorFromRef(Game.GetPlayer(), 300.0)
    if targetActor == None || targetActor == Game.GetPlayer()
        Debug.Notification("No one close enough to negotiate with.")
        return
    endIf
    if targetActor.IsDead()
        return
    endIf
    if !targetActor.IsHostileToActor(Game.GetPlayer())
        Debug.Notification("They're not hostile.")
        return
    endIf

    _isProcessing = true
    gruntName     = _GetNPCName(targetActor)
    context       = _BuildContext()
    tierStr       = _GetEnemyTier(targetActor)

    ; --- Check target status ---
    string targetStatus
    targetStatus = _GetActorStatus(targetActor)

    if targetStatus == "INCAPACITATED"
        ; Can't talk to a frozen/tranq'd/stunned enemy — but followers notice
        Debug.Notification(gruntName + " is incapacitated. Their followers are watching...")
        _HandleFollowerReactions(targetActor, "BOSS_INCAPACITATED")
        ; Start monitoring in case they wake up angry
        if !_monitoringBoss
            _monitoringBoss = true
            _monitoredBoss  = targetActor
            _MonitorBossStatus(targetActor)
        endIf
        _isProcessing = false
        return
    endIf

    if targetStatus == "ON_FIRE"
        Debug.Notification(gruntName + " is on fire — they're desperate. Negotiate now!")
    endIf

    System:IO:File.WriteAllText("fo4_input_request.txt", "COMBAT_NEG:" + gruntName)
    choice = _WaitForInput()

    if choice == "BACK"
        Debug.Notification("You stay focused on the fight.")
        _isProcessing = false
        return
    endIf

    _PauseCombatNearby(targetActor)
    Debug.Notification(gruntName + " holds up a hand... listening.")

    handshake = "NAME:" + gruntName + "|MSG:" + choice + "|LOC:" + _GetLocationName() + "|SEX:m|COMBAT:TRUE|TIER:" + tierStr + "|TARGET_STATUS:" + targetStatus + context
    System:IO:File.WriteAllText(ResponseFile, "")
    System:IO:File.WriteAllText(CombatResultFile, "")
    System:IO:File.WriteAllText(PromptFile, handshake)

    response = _PollForCombatResponse()
    result   = System:IO:File.ReadAllText(CombatResultFile)

    _DisplayResponse(gruntName, response)

    if result == "STAND_DOWN_GRUNT"
        _HandleStandDownGrunt(targetActor, gruntName)
        _SaveMercyAction()
    elseIf result == "ESCALATE_LEADER"
        _HandleLeaderEscalation(targetActor, gruntName, context, tierStr)
    elseIf result == "INSPIRED_SOME"
        Debug.Notification("Your words hit home... a few of them turn on their own!")
        _HandleRebellion(targetActor, false)
    elseIf result == "INSPIRED_ALL"
        Debug.Notification("The whole group rises up against their boss!")
        _HandleRebellion(targetActor, true)
    elseIf result == "TRICKED"
        Debug.Notification(gruntName + " realizes they've been played! They fight harder!")
        _ResumeCombatNearby(targetActor)
    elseIf result == "REVEAL_SECRET"
        secret = System:IO:File.ReadAllText(ResponseFile)
        Debug.MessageBox("INTEL:\n\n" + secret)
        _ResumeCombatNearby(targetActor)
    else
        Debug.Notification(gruntName + " shakes their head. Back to fighting.")
        _ResumeCombatNearby(targetActor)
    endIf

    System:IO:File.WriteAllText(ResponseFile, "")
    System:IO:File.WriteAllText(CombatResultFile, "")
    _isProcessing = false
EndFunction


Function _HandleStandDownGrunt(Actor grunt, string gruntName)
    grunt.StopCombat()
    grunt.StopCombatAlarm()
    Debug.Notification(gruntName + " stands down. Just them though.")
    _ResumeCombatNearby(grunt)
    Utility.Wait(60.0)
    Debug.Notification(gruntName + " decides the deal is done.")
EndFunction


Function _HandleLeaderEscalation(Actor grunt, string gruntName, string context, string tierStr)
    Actor leader
    string leaderName
    string leaderHandshake
    string leaderChoice
    string leaderResponse
    string leaderResult
    string secret

    leader = _FindFactionLeader(grunt)

    if leader == None || leader == grunt
        Debug.Notification(gruntName + ": I don't answer to nobody. Deal's off.")
        _ResumeCombatNearby(grunt)
        return
    endIf

    leaderName = _GetNPCName(leader)
    Debug.Notification(gruntName + ": Hold on... let me get the boss.")
    Utility.Wait(2.0)
    Debug.Notification(leaderName + " steps forward...")

    System:IO:File.WriteAllText("fo4_input_request.txt", "LEADER_NEG:" + leaderName + ":" + tierStr)
    leaderChoice = _WaitForInput()

    if leaderChoice == "BACK"
        Debug.Notification("Negotiations break down.")
        _ResumeCombatNearby(grunt)
        return
    endIf

    leaderHandshake = "NAME:" + leaderName + "|MSG:" + leaderChoice + "|LOC:" + _GetLocationName() + "|SEX:m|COMBAT:TRUE|TIER:" + tierStr + "|LEADER:TRUE" + context
    System:IO:File.WriteAllText(ResponseFile, "")
    System:IO:File.WriteAllText(CombatResultFile, "")
    System:IO:File.WriteAllText(PromptFile, leaderHandshake)

    leaderResponse = _PollForCombatResponse()
    leaderResult   = System:IO:File.ReadAllText(CombatResultFile)

    _DisplayResponse(leaderName, leaderResponse)

    if leaderResult == "STAND_DOWN_ALL"
        _HandleGangStandDown(leader, leaderName)
        _HandleFollowerReactions(leader, "STAND_DOWN")
    elseIf leaderResult == "TRICKED"
        Debug.Notification(leaderName + " laughs. 'Did you really think that would work?'")
        _ResumeCombatNearby(grunt)
        _HandleFollowerReactions(leader, "TRICKED")
    elseIf leaderResult == "REVEAL_SECRET"
        secret = System:IO:File.ReadAllText(ResponseFile)
        Debug.MessageBox("INTEL from " + leaderName + ":\n\n" + secret)
        _ResumeCombatNearby(grunt)
        _HandleFollowerReactions(leader, "SECRET_REVEALED")
    else
        Debug.Notification(leaderName + " waves dismissively. 'Kill them.'")
        _ResumeCombatNearby(grunt)
        _HandleFollowerReactions(leader, "REFUSED")
    endIf

    System:IO:File.WriteAllText(ResponseFile, "")
    System:IO:File.WriteAllText(CombatResultFile, "")
EndFunction


Function _HandleGangStandDown(Actor leader, string leaderName)
    Actor nearby
    float sx
    int i

    _ceasefireActive = true
    _ceaseFireLeader = leader
    nearby           = None
    sx               = 0.0
    i                = 0

    while i < 10
        sx     = leader.X + (i * 50.0)
        nearby = Game.FindClosestActor(sx, leader.Y, leader.Z, 500.0)
        if nearby != None && nearby != Game.GetPlayer() && !nearby.IsDead()
            if nearby.IsHostileToActor(Game.GetPlayer())
                nearby.StopCombat()
                nearby.StopCombatAlarm()
            endIf
        endIf
        i += 1
    endWhile

    Debug.Notification("CEASEFIRE! The whole gang stands down for 60 seconds.")
    Utility.Wait(60.0)

    if _ceasefireActive
        Debug.Notification(leaderName + ": Time's up. Get out or we finish this.")
        _ceasefireActive = false
        _ceaseFireLeader = None
    endIf
EndFunction


; ==========================================================
; COMBAT DRAMA LOOP
; Master timer for trash talk, betrayal, witness checks
; ==========================================================
Function _StartCombatDramaLoop()
    if _combatDramaRunning
        return
    endIf
    _combatDramaRunning = true
    _CombatDramaTick()
EndFunction


Function _CombatDramaTick()
    int tauntTimer
    int betrayalTimer
    int witnessTimer
    int tauntThreshold
    int betrayalThreshold

    tauntTimer        = 0
    betrayalTimer     = 0
    witnessTimer      = 0
    tauntThreshold    = Utility.RandomInt(25, 40)
    betrayalThreshold = Utility.RandomInt(50, 75)

    while _combatDramaRunning
        Utility.Wait(5.0)

        if Game.GetPlayer().IsInCombat()
            tauntTimer    += 5
            betrayalTimer += 5
            witnessTimer  += 5

            if tauntTimer >= tauntThreshold
                tauntTimer     = 0
                tauntThreshold = Utility.RandomInt(25, 45)
                _TriggerTrashTalk()
            endIf

            if betrayalTimer >= betrayalThreshold
                betrayalTimer     = 0
                betrayalThreshold = Utility.RandomInt(50, 80)
                _CheckBetrayal()
            endIf

            if witnessTimer >= 20
                witnessTimer = 0
                _CheckWitnesses()
            endIf
        else
            ; Reset timers when out of combat
            tauntTimer    = 0
            betrayalTimer = 0
            witnessTimer  = 0
            _killStreak   = 0
        endIf
    endWhile
EndFunction


; ==========================================================
; TRASH TALK
; Enemy taunts player during combat — audio only
; ==========================================================
Function _TriggerTrashTalk()
    Actor taunter
    string taunterName
    string npcSex
    string situation
    string existing
    float dist
    ActorBase npcBase

    taunter = None
    npcSex  = "m"
    dist    = 0.0

    if _isProcessing
        return
    endIf

    taunter = Game.FindClosestActorFromRef(Game.GetPlayer(), 600.0)
    if taunter == None || taunter == Game.GetPlayer()
        return
    endIf
    if !taunter.IsHostileToActor(Game.GetPlayer()) || taunter.IsDead()
        return
    endIf
    if taunter.IsUnconscious() || taunter.IsOnFire()
        return
    endIf

    taunterName = _GetNPCName(taunter)
    dist        = Game.GetPlayer().GetDistance(taunter)
    npcBase     = taunter.GetLeveledActorBase() as ActorBase
    if npcBase != None
        if npcBase.GetSex() == 1
            npcSex = "f"
        endIf
    endIf

    situation = "EVEN"
    if _killStreak >= 5
        situation = "PLAYER_DOMINATING"
    elseIf _killStreak >= 3
        situation = "PLAYER_WINNING"
    elseIf _killStreak == 0
        situation = "PLAYER_STRUGGLING"
    endIf

    ; Don't queue up if file not yet processed
    existing = System:IO:File.ReadAllText("fo4_taunt.txt")
    if existing != ""
        return
    endIf

    System:IO:File.WriteAllText("fo4_taunt.txt", "NAME:" + taunterName + "|SEX:" + npcSex + "|SITUATION:" + situation + "|KILLSTREAK:" + _killStreak + "|DIST:" + dist + "|TIMESPARED:" + TimesSpared + _BuildContext())
EndFunction


; ==========================================================
; MORALE BREAK
; Triggered at kill streak thresholds
; ==========================================================
Function _CheckMoraleBreak()
    Actor nearby
    float sx
    float px
    float py
    float pz
    int survivorCount
    int i
    int roll
    string outcome
    string existing

    nearby        = None
    survivorCount = 0
    i             = 0
    px            = Game.GetPlayer().X
    py            = Game.GetPlayer().Y
    pz            = Game.GetPlayer().Z

    ; Count nearby surviving enemies
    while i < 8
        sx     = px + (i * 80.0)
        nearby = Game.FindClosestActor(sx, py, pz, 400.0)
        if nearby != None && nearby != Game.GetPlayer() && !nearby.IsDead()
            if nearby.IsHostileToActor(Game.GetPlayer())
                survivorCount += 1
            endIf
        endIf
        i += 1
    endWhile

    if survivorCount == 0
        return
    endIf

    ; Determine morale outcome — weighted by kill streak
    roll    = Utility.RandomInt(0, 10)
    outcome = "PANIC"

    if _killStreak >= 6
        if roll <= 7
            outcome = "FLEE"
        else
            outcome = "DESPERATE"
        endIf
    elseIf _killStreak >= 4
        if roll <= 4
            outcome = "FLEE"
        elseIf roll <= 7
            outcome = "PANIC"
        else
            outcome = "DESPERATE"
        endIf
    else
        if roll <= 2
            outcome = "FLEE"
        elseIf roll <= 6
            outcome = "PANIC"
        else
            outcome = "DESPERATE"
        endIf
    endIf

    ; Apply gameplay effect for FLEE
    if outcome == "FLEE"
        i = 0
        while i < 8
            sx     = px + (i * 80.0)
            nearby = Game.FindClosestActor(sx, py, pz, 400.0)
            if nearby != None && nearby != Game.GetPlayer() && !nearby.IsDead()
                if nearby.IsHostileToActor(Game.GetPlayer())
                    nearby.StopCombat()
                    nearby.StopCombatAlarm()
                    nearby.EvaluatePackage()
                endIf
            endIf
            i += 1
        endWhile
        _SaveMercyAction()
    endIf

    ; Queue speech
    existing = System:IO:File.ReadAllText("fo4_morale.txt")
    if existing != ""
        return
    endIf

    System:IO:File.WriteAllText("fo4_morale.txt", "KILLSTREAK:" + _killStreak + "|SURVIVORS:" + survivorCount + "|OUTCOME:" + outcome + "|DIST:200" + _BuildContext())
EndFunction


; ==========================================================
; BETRAYAL CHECK
; Random enemy might turn on their own boss
; ==========================================================
Function _CheckBetrayal()
    Actor target
    Actor boss
    string targetName
    string bossName
    string npcSex
    string existing
    int roll
    int threshold
    float dist
    ActorBase npcBase

    target  = None
    boss    = None
    npcSex  = "m"
    dist    = 200.0

    ; Betrayal chance: harder at low kill streak, easier with mercy rep
    threshold = 80 - (_killStreak * 8) - (TimesSpared / 2)
    if threshold < 20
        threshold = 20
    endIf
    roll = Utility.RandomInt(0, 100)

    if roll < threshold
        return
    endIf

    target = Game.FindClosestActorFromRef(Game.GetPlayer(), 400.0)
    if target == None || target == Game.GetPlayer() || target.IsDead()
        return
    endIf
    if !target.IsHostileToActor(Game.GetPlayer())
        return
    endIf
    if target.IsUnconscious() || target.IsOnFire()
        return
    endIf

    targetName = _GetNPCName(target)
    dist       = Game.GetPlayer().GetDistance(target)
    npcBase    = target.GetLeveledActorBase() as ActorBase
    if npcBase != None
        if npcBase.GetSex() == 1
            npcSex = "f"
        endIf
    endIf

    boss     = _FindFactionLeader(target)
    bossName = "the boss"
    if boss != None && boss != target && !boss.IsDead()
        bossName = _GetNPCName(boss)
    endIf

    ; Make them actually betray
    target.StopCombat()
    Utility.Wait(0.3)
    if boss != None && boss != target && !boss.IsDead()
        target.StartCombat(boss)
    else
        target.StopCombatAlarm()
    endIf

    ; Queue speech
    existing = System:IO:File.ReadAllText("fo4_betrayal.txt")
    if existing != ""
        return
    endIf

    System:IO:File.WriteAllText("fo4_betrayal.txt", "NAME:" + targetName + "|SEX:" + npcSex + "|BOSS:" + bossName + "|KILLSTREAK:" + _killStreak + "|TIMESPARED:" + TimesSpared + "|DIST:" + dist + _BuildContext())
EndFunction


; ==========================================================
; WITNESS REACTIONS
; Neutral NPCs nearby react to what they see
; ==========================================================
Function _CheckWitnesses()
    Actor witness
    string witnessName
    string npcSex
    string existing
    float dist
    ActorBase npcBase

    witness = None
    npcSex  = "m"
    dist    = 0.0

    witness = Game.FindClosestActorFromRef(Game.GetPlayer(), 500.0)
    if witness == None || witness == Game.GetPlayer() || witness.IsDead()
        return
    endIf
    if witness.IsHostileToActor(Game.GetPlayer())
        return
    endIf
    if witness.IsInCombat()
        return
    endIf

    witnessName = _GetNPCName(witness)
    dist        = Game.GetPlayer().GetDistance(witness)
    npcBase     = witness.GetLeveledActorBase() as ActorBase
    if npcBase != None
        if npcBase.GetSex() == 1
            npcSex = "f"
        endIf
    endIf

    existing = System:IO:File.ReadAllText("fo4_witness.txt")
    if existing != ""
        return
    endIf

    System:IO:File.WriteAllText("fo4_witness.txt", "NAME:" + witnessName + "|SEX:" + npcSex + "|KILLSTREAK:" + _killStreak + "|DIST:" + dist + "|TIMESPARED:" + TimesSpared + _BuildContext())
EndFunction


; ==========================================================
; MERCY TRACKING
; Called whenever player lets someone go
; ==========================================================
Function _SaveMercyAction()
    TimesSpared     += 1
    TotalEncounters += 1
EndFunction



; Returns ON_FIRE / INCAPACITATED / NORMAL / DEAD
; ==========================================================
string Function _GetActorStatus(Actor akActor)
    if akActor == None
        return "NONE"
    endIf
    if akActor.IsDead()
        return "DEAD"
    endIf
    if akActor.IsOnFire()
        return "ON_FIRE"
    endIf
    if akActor.IsUnconscious()
        return "INCAPACITATED"
    endIf
    return "NORMAL"
EndFunction



; Called after any leader negotiation outcome
; ==========================================================
Function _HandleFollowerReactions(Actor boss, string situation)
    string bossName
    string bossStatus
    string handshake
    string response
    string result
    int followerCount
    Actor nearby
    float sx
    int i

    bossName      = _GetNPCName(boss)
    bossStatus    = _GetActorStatus(boss)
    followerCount = 0
    nearby        = None
    sx            = 0.0
    i             = 0

    ; Count nearby followers first
    while i < 8
        sx     = boss.X + (i * 80.0)
        nearby = Game.FindClosestActor(sx, boss.Y, boss.Z, 500.0)
        if nearby != None && nearby != Game.GetPlayer() && nearby != boss && !nearby.IsDead()
            if nearby.IsHostileToActor(Game.GetPlayer())
                followerCount += 1
            endIf
        endIf
        i += 1
    endWhile

    if followerCount == 0
        return
    endIf

    ; Ask bridge how followers react
    handshake = "NAME:" + bossName + "|MSG:FOLLOWER_REACT|LOC:" + _GetLocationName() + "|SEX:m|FOLLOWER_REACT:TRUE|SITUATION:" + situation + "|BOSS_STATUS:" + bossStatus + "|FOLLOWER_COUNT:" + followerCount + _BuildContext()
    System:IO:File.WriteAllText(ResponseFile, "")
    System:IO:File.WriteAllText(PromptFile, handshake)

    response = _PollForCombatResponse()
    result   = System:IO:File.ReadAllText(CombatResultFile)

    Debug.Notification("The followers react: " + result)
    _ApplyFollowerResult(result, boss)

    System:IO:File.WriteAllText(ResponseFile, "")
    System:IO:File.WriteAllText(CombatResultFile, "")
EndFunction


Function _ApplyFollowerResult(string result, Actor boss)
    Actor nearby
    float sx
    int i
    int roll

    nearby = None
    sx     = 0.0
    i      = 0
    FollowerCount = 0

    while i < 8
        sx     = boss.X + (i * 80.0)
        nearby = Game.FindClosestActor(sx, boss.Y, boss.Z, 500.0)
        if nearby != None && nearby != Game.GetPlayer() && nearby != boss && !nearby.IsDead()
            if nearby.IsHostileToActor(Game.GetPlayer())

                string behavior
                behavior = "BOSS"  ; default

                if result == "ALL_FLEE"
                    behavior = "FLEE"
                elseIf result == "ALL_FIGHT"
                    behavior = "FIGHT"
                elseIf result == "ALL_WATCH"
                    behavior = "WATCH"
                elseIf result == "ALL_BOSS"
                    behavior = "BOSS"
                elseIf result == "SPLIT"
                    ; Random mix for each follower
                    roll = Utility.RandomInt(0, 3)
                    if roll == 0
                        behavior = "FLEE"
                    elseIf roll == 1
                        behavior = "FIGHT"
                    elseIf roll == 2
                        behavior = "WATCH"
                    else
                        behavior = "BOSS"
                    endIf
                endIf

                ; Store state for post-boss tracking
                if FollowerCount < 10
                    FollowerStates[FollowerCount] = behavior
                    FollowerCount += 1
                endIf

                ; Apply behavior
                if behavior == "FLEE"
                    nearby.StopCombat()
                    nearby.StopCombatAlarm()
                    nearby.SetRestrained(false)
                    Debug.Notification(nearby.GetDisplayName() + " turns and flees!")
                    ; Force them to run away from player
                    nearby.EvaluatePackage()

                elseIf behavior == "FIGHT"
                    nearby.StopCombat()
                    Utility.Wait(0.2)
                    nearby.StartCombat(boss)
                    Debug.Notification(nearby.GetDisplayName() + " switches sides!")

                elseIf behavior == "WATCH"
                    nearby.StopCombat()
                    nearby.StopCombatAlarm()
                    Debug.Notification(nearby.GetDisplayName() + " steps back and watches...")

                ; BOSS = do nothing, keep fighting
                endIf
            endIf
        endIf
        i += 1
    endWhile

    ; Start monitoring boss death if there are watchers or fighters
    if !_monitoringBoss && boss != None && !boss.IsDead()
        _monitoringBoss = true
        _monitoredBoss  = boss
        _MonitorBossDeath(boss)
    endIf
EndFunction


; ==========================================================
; BOSS STATUS MONITOR
; Watches for boss waking from incapacitation or dying
; ==========================================================
Function _MonitorBossStatus(Actor boss)
    int cycles
    string lastStatus
    string currentStatus
    cycles     = 0
    lastStatus = "INCAPACITATED"

    while _monitoringBoss && boss != None && cycles < 600
        Utility.Wait(0.5)
        currentStatus = _GetActorStatus(boss)

        if currentStatus == "DEAD"
            _monitoringBoss = false
            _monitoredBoss  = None
            Debug.Notification("The boss is dead. The followers reassess...")
            Utility.Wait(1.5)
            _HandlePostBossReactions(boss)
            return

        elseIf lastStatus == "INCAPACITATED" && currentStatus == "NORMAL"
            ; Boss woke up — they're ANGRY
            Debug.Notification(_GetNPCName(boss) + " recovers — and they're furious!")
            boss.StartCombat(Game.GetPlayer())
            ; Tell followers their boss is back and enraged
            _HandleFollowerReactions(boss, "BOSS_RECOVERED_ENRAGED")
            ; Keep monitoring in case they die
            lastStatus = "NORMAL"

        elseIf lastStatus == "NORMAL" && currentStatus == "INCAPACITATED"
            ; Boss got incapacitated again
            lastStatus = "INCAPACITATED"
            _HandleFollowerReactions(boss, "BOSS_INCAPACITATED")

        elseIf lastStatus == "NORMAL" && currentStatus == "ON_FIRE"
            lastStatus = "ON_FIRE"
            _HandleFollowerReactions(boss, "BOSS_ON_FIRE")

        elseIf lastStatus == "ON_FIRE" && currentStatus == "NORMAL"
            lastStatus = "NORMAL"
            Debug.Notification(_GetNPCName(boss) + " survived the flames — and they want revenge!")
            _HandleFollowerReactions(boss, "BOSS_SURVIVED_FIRE")
        endIf

        cycles += 1
    endWhile

    _monitoringBoss = false
    _monitoredBoss  = None
EndFunction



; Polls until boss dies then triggers post-death follower logic
; ==========================================================
Function _MonitorBossDeath(Actor boss)
    int cycles
    cycles = 0

    while _monitoringBoss && boss != None && cycles < 600
        Utility.Wait(0.5)
        if boss.IsDead()
            _monitoringBoss = false
            _monitoredBoss  = None
            Debug.Notification("The boss is dead. The followers reassess...")
            Utility.Wait(1.5)
            _HandlePostBossReactions(boss)
            return
        endIf
        cycles += 1
    endWhile

    _monitoringBoss = false
    _monitoredBoss  = None
EndFunction


; ==========================================================
; POST-BOSS-DEATH FOLLOWER REACTIONS
; ==========================================================
Function _HandlePostBossReactions(Actor bossCorpse)
    string bossName
    string handshake
    string response
    string result
    Actor nearby
    float sx
    int i

    bossName = _GetNPCName(bossCorpse)
    nearby   = None
    sx       = 0.0
    i        = 0

    ; Ask bridge what followers do now that boss is dead
    handshake = "NAME:" + bossName + "|MSG:FOLLOWER_POST|LOC:" + _GetLocationName() + "|SEX:m|FOLLOWER_POST:TRUE" + _BuildContext()
    System:IO:File.WriteAllText(ResponseFile, "")
    System:IO:File.WriteAllText(PromptFile, handshake)

    response = _PollForCombatResponse()
    result   = System:IO:File.ReadAllText(CombatResultFile)

    System:IO:File.WriteAllText(ResponseFile, "")
    System:IO:File.WriteAllText(CombatResultFile, "")

    ; Apply post-death behavior to remaining nearby hostiles
    while i < 8
        sx     = bossCorpse.X + (i * 80.0)
        nearby = Game.FindClosestActor(sx, bossCorpse.Y, bossCorpse.Z, 500.0)
        if nearby != None && nearby != Game.GetPlayer() && !nearby.IsDead()
            if nearby.IsHostileToActor(Game.GetPlayer()) || nearby.IsInCombat()

                if result == "SCATTER"
                    nearby.StopCombat()
                    nearby.StopCombatAlarm()
                    nearby.EvaluatePackage()
                    Debug.Notification(nearby.GetDisplayName() + " scatters!")

                elseIf result == "SURRENDER"
                    nearby.StopCombat()
                    nearby.StopCombatAlarm()
                    nearby.SetRestrained(true)
                    Debug.Notification(nearby.GetDisplayName() + " surrenders.")
                    Utility.Wait(30.0)
                    nearby.SetRestrained(false)

                elseIf result == "OPPORTUNISTIC_ATTACK"
                    ; They see a chance — attack player harder
                    nearby.StartCombat(Game.GetPlayer())
                    Debug.Notification(nearby.GetDisplayName() + ": Without the boss, nothing's stopping us now!")

                else
                    ; Default — scatter
                    nearby.StopCombat()
                    nearby.StopCombatAlarm()
                endIf
            endIf
        endIf
        i += 1
    endWhile

    Debug.Notification("The situation resolves: " + result)
EndFunction



string Function _GetEnemyTier(Actor akTarget)
    int lvl
    lvl = akTarget.GetLevel()
    if lvl <= 10
        return "1"
    elseIf lvl <= 25
        return "2"
    elseIf lvl <= 50
        return "3"
    else
        return "4"
    endIf
EndFunction


; ==========================================================
; FACTION LEADER FINDER
; ==========================================================
Actor Function _FindFactionLeader(Actor grunt)
    Actor highestActor
    Actor nearby
    float searchX
    int highestLevel
    int i

    highestActor = grunt
    highestLevel = grunt.GetLevel()
    nearby       = None
    searchX      = 0.0
    i            = 0

    while i < 8
        searchX = grunt.X + (i * 100.0)
        nearby  = Game.FindClosestActor(searchX, grunt.Y, grunt.Z, 600.0)
        if nearby != None && nearby != Game.GetPlayer() && !nearby.IsDead()
            if nearby.IsHostileToActor(Game.GetPlayer())
                if nearby.GetLevel() > highestLevel
                    highestLevel = nearby.GetLevel()
                    highestActor = nearby
                endIf
            endIf
        endIf
        i += 1
    endWhile

    return highestActor
EndFunction


; ==========================================================
; COMBAT PAUSE/RESUME
; ==========================================================
Function _PauseCombatNearby(Actor anchor)
    Actor nearby
    float sx
    int i

    nearby = None
    sx     = 0.0
    i      = 0

    while i < 8
        sx     = anchor.X + (i * 80.0)
        nearby = Game.FindClosestActor(sx, anchor.Y, anchor.Z, 400.0)
        if nearby != None && nearby != Game.GetPlayer() && !nearby.IsDead()
            if nearby.IsHostileToActor(Game.GetPlayer())
                nearby.StopCombat()
            endIf
        endIf
        i += 1
    endWhile
EndFunction


Function _ResumeCombatNearby(Actor anchor)
    Actor nearby
    float sx
    int i

    nearby = None
    sx     = 0.0
    i      = 0

    while i < 8
        sx     = anchor.X + (i * 80.0)
        nearby = Game.FindClosestActor(sx, anchor.Y, anchor.Z, 400.0)
        if nearby != None && nearby != Game.GetPlayer() && !nearby.IsDead()
            if nearby.IsHostileToActor(Game.GetPlayer())
                nearby.StartCombat(Game.GetPlayer())
            endIf
        endIf
        i += 1
    endWhile
EndFunction


; ==========================================================
; REBELLION
; ==========================================================
Function _HandleRebellion(Actor spark, bool allTurn)
    Actor leader
    Actor nearby
    float sx
    int turnCount
    int maxTurns
    int i
    string leaderName

    leader     = _FindFactionLeader(spark)
    nearby     = None
    sx         = 0.0
    turnCount  = 0
    maxTurns   = 0
    i          = 0
    leaderName = ""

    if leader == None || leader == spark
        spark.StopCombat()
        Debug.Notification("They're confused... but they stop shooting at you.")
        return
    endIf

    leaderName = _GetNPCName(leader)

    if allTurn
        maxTurns = 8
    else
        maxTurns = 2
    endIf

    while i < 8 && turnCount < maxTurns
        sx     = spark.X + (i * 80.0)
        nearby = Game.FindClosestActor(sx, spark.Y, spark.Z, 500.0)
        if nearby != None && nearby != Game.GetPlayer() && nearby != leader && !nearby.IsDead()
            if nearby.IsHostileToActor(Game.GetPlayer())
                nearby.StopCombat()
                Utility.Wait(0.3)
                nearby.StartCombat(leader)
                turnCount += 1
                Debug.Notification(nearby.GetDisplayName() + " turns on " + leaderName + "!")
            endIf
        endIf
        i += 1
    endWhile

    if turnCount == 0
        Debug.Notification("Nobody moved. Your words fell flat.")
    else
        Debug.Notification(turnCount + " turned against " + leaderName + ". Use the chaos!")
        Utility.Wait(45.0)
        Debug.Notification("The rebellion fizzles out...")
    endIf
EndFunction


; ==========================================================
; COMPANION BANTER LOOP
; ==========================================================
Function _StartBanterLoop()
    if _banterRunning
        return
    endIf
    _banterRunning = true
    _BanterTick()
EndFunction


Function _BanterTick()
    Actor companion
    string compName
    string context
    string handshake
    string response

    while _banterRunning
        Utility.Wait(BanterInterval)
        companion = _FindCompanion()
        if companion == None
            ; no companion
        elseIf _isProcessing || _isFistfighting || Game.GetPlayer().IsInCombat()
            ; bad time
        else
            compName  = _GetNPCName(companion)
            context   = _BuildContext()
            handshake = "NAME:" + compName + "|MSG:BANTER|LOC:" + _GetLocationName() + "|SEX:m|BANTER:TRUE" + context

            System:IO:File.WriteAllText(ResponseFile, "")
            System:IO:File.WriteAllText(PromptFile, handshake)

            response = _PollForBanter()
            if response != "" && response != "..."
                Debug.Notification(compName + ": " + response)
            endIf
            System:IO:File.WriteAllText(ResponseFile, "")
        endIf
    endWhile
EndFunction


Actor Function _FindCompanion()
    Actor nearby
    float dist

    if CurrentCompanion != None
        dist = Game.GetPlayer().GetDistance(CurrentCompanion)
        if dist < 400.0 && !CurrentCompanion.IsDead()
            return CurrentCompanion
        endIf
    endIf

    nearby = Game.FindClosestActorFromRef(Game.GetPlayer(), 300.0)
    if nearby != None && nearby != Game.GetPlayer() && !nearby.IsDead()
        if nearby.IsPlayerTeammate()
            return nearby
        endIf
    endIf

    return None
EndFunction


string Function _PollForBanter()
    int cycles
    string response

    cycles = 0
    while cycles < 20
        response = System:IO:File.ReadAllText(ResponseFile)
        if response != "" && response != "..."
            return response
        endIf
        Utility.Wait(0.5)
        cycles += 1
    endWhile
    return ""
EndFunction


; ==========================================================
; FRIENDLY OUTCOME
; ==========================================================
Function _TriggerFriendlyOutcome(Actor akTarget)
    string npcName
    int roll
    int caps
    int idx
    Form capsForm
    Form stimpakForm

    npcName     = akTarget.GetDisplayName()
    roll        = Utility.RandomInt(0, 2)
    capsForm    = Game.GetFormFromFile(0x0000000F, "Fallout4.esm")
    stimpakForm = Game.GetFormFromFile(0x00023736, "Fallout4.esm")

    if roll == 0
        akTarget.SetPlayerTeammate(true)
        _isFollowing  = true
        _followTarget = akTarget
        Debug.Notification(npcName + " wants to tag along for a while!")
        _FollowTimer(akTarget, npcName)
    elseIf roll == 1
        caps = Utility.RandomInt(50, 300)
        if capsForm != None
            Game.GetPlayer().AddItem(capsForm, caps)
            Debug.Notification(npcName + " slips you " + caps + " caps.")
        endIf
    else
        if stimpakForm != None
            Game.GetPlayer().AddItem(stimpakForm, 2)
            Debug.Notification(npcName + " hands you a couple Stimpaks.")
        endIf
    endIf

    idx = _FindMoodIndex(npcName)
    if idx >= 0
        MoodLabels[idx] = "NEUTRAL"
    endIf
EndFunction


Function _FollowTimer(Actor akTarget, string npcName)
    Utility.Wait(180.0)
    if _isFollowing && _followTarget != None
        akTarget.SetPlayerTeammate(false)
        Debug.Notification(npcName + " waves and heads back.")
        _isFollowing  = false
        _followTarget = None
    endIf
EndFunction


; ==========================================================
; POLL HELPERS
; ==========================================================
string Function _PollForResponse(Actor akTarget)
    int cycles
    int halfPoint
    string response

    cycles    = 0
    halfPoint = MaxPollCycles / 2

    while cycles < MaxPollCycles
        response = System:IO:File.ReadAllText(ResponseFile)
        if response != "" && response != "..."
            return response
        elseif response == "..."
            return _GetFallbackLine()
        endIf
        if cycles == halfPoint
            akTarget.PlayIdle(IdleDefault)
        endIf
        Utility.Wait(PollInterval)
        cycles += 1
    endWhile
    Debug.Notification("They seem distracted.")
    return _GetFallbackLine()
EndFunction


string Function _PollForCombatResponse()
    int cycles
    string response

    cycles = 0
    while cycles < 30
        response = System:IO:File.ReadAllText(ResponseFile)
        if response != ""
            return response
        endIf
        Utility.Wait(0.5)
        cycles += 1
    endWhile
    return "..."
EndFunction


string Function _WaitForInput()
    int cycles
    string playerInput

    cycles = 0
    while cycles < 60
        Utility.Wait(0.5)
        playerInput = System:IO:File.ReadAllText("fo4_input.txt")
        if playerInput != ""
            System:IO:File.WriteAllText("fo4_input.txt", "")
            return playerInput
        endIf
        cycles += 1
    endWhile
    return "2"
EndFunction


; ==========================================================
; GENERAL HELPERS
; ==========================================================
Function _DisplayResponse(string npcName, string response)
    Debug.MessageBox(npcName + ":\n\n" + response)
EndFunction


string Function _GetNPCName(Actor akTarget)
    string name
    name = akTarget.GetDisplayName()
    if name != ""
        return name
    endIf
    return "Settler"
EndFunction


string Function _GetLocationName()
    Location loc
    Form locForm

    loc = Game.GetPlayer().GetCurrentLocation()
    if loc != None
        locForm = loc as Form
        if locForm != None
            return locForm.GetName()
        endIf
    endIf
    return "the Commonwealth"
EndFunction


string Function _GetPlayerInput(string npcName)
    int cycles
    string playerInput
    int idx

    System:IO:File.WriteAllText("fo4_input_request.txt", npcName)
    cycles = 0
    while cycles < 60
        Utility.Wait(0.5)
        playerInput = System:IO:File.ReadAllText("fo4_input.txt")
        if playerInput != ""
            System:IO:File.WriteAllText("fo4_input.txt", "")
            return playerInput
        endIf
        cycles += 1
    endWhile
    idx = Utility.RandomInt(0, InputPresets.Length - 1)
    return InputPresets[idx]
EndFunction


string Function _GetFallbackLine()
    int idx
    idx = Utility.RandomInt(0, FallbackLines.Length - 1)
    return FallbackLines[idx]
EndFunction