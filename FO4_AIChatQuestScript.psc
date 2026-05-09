Scriptname FO4_AIChatQuestScript extends Quest

; --- FILE PATHS ---
string property PromptFile       = "fo4_prompt.txt"         autoReadOnly
string property ResponseFile     = "fo4_response.txt"       autoReadOnly
string property MoodFile         = "fo4_mood.txt"           autoReadOnly
string property CombatResultFile = "fo4_combat_result.txt"  autoReadOnly
string property EventFile        = "fo4_recent_events.txt"  autoReadOnly
string property InterruptFile    = "fo4_interrupt.txt"      autoReadOnly

; --- ACTOR VALUES (Link these in FO4Edit to Health and RadiationRadResist) ---
ActorValue property HealthAV auto
ActorValue property RadiationAV auto

; --- TIMING ---
float property PollInterval      = 0.5   autoReadOnly
int   property MaxPollCycles     = 30    autoReadOnly
float property BanterInterval    = 180.0 autoReadOnly

; --- IDLE ANIMATIONS ---
Idle property IdleThinking auto
Idle property IdleDefault  auto
Idle property IdleStop     auto
Idle property IdleHappy    auto
Idle property IdleAngry    auto
Idle property IdleSad      auto
Idle property IdleFear     auto

; --- COMPANION REFERENCE ---
Actor property CurrentCompanion auto

; --- INPUT PRESETS ---
string[] property InputPresets auto
string[] property FallbackLines auto

; --- MOOD TRACKING ---
string[] property MoodNPCNames auto
string[] property MoodLabels   auto
int      property MoodCount = 0 auto

; --- KILL / EVENT TRACKING ---
string[] property RecentKills auto
int      property RecentKillCount = 0 auto
string[] property VisitedLocations auto
int      property VisitedCount = 0 auto

; --- COMBAT DRAMA STATE ---
bool  _combatDramaRunning  = false
int   _killStreak          = 0
float _lastKillGameTime    = 0.0
int   property KillStreakMax    = 0 auto
int   property TimesSpared      = 0 auto
int   property TotalEncounters  = 0 auto

; --- STATE ---
int    _conversationCount = 0
string _lastNPCName       = ""
string _lastPlayerMsg     = ""
string _lastNPCResponse   = ""
bool  _isProcessing     = false
bool  _isFistfighting   = false
bool  _isFollowing      = false
bool  _fightPaused      = false
bool  _ceasefireActive  = false
bool  _banterRunning    = false
Actor _fightTarget      = None
Actor _followTarget     = None
Actor _ceaseFireLeader  = None

; ==========================================================
; INIT
; ==========================================================
Event OnInit()
    RegisterForKey(72)  ; H = chat / negotiate
    RegisterForKey(71)  ; G = gift
    RegisterForRemoteEvent(Game.GetPlayer(), "OnKill")

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
    RecentKills      = new string[10]
    VisitedLocations = new string[10]

    _StartBanterLoop()
    _StartLocationTracker()
    _StartCombatDramaLoop()
EndEvent

; ==========================================================
; KEY HANDLER
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
; KILL TRACKING WITH STREAKS & MERCY
; ==========================================================
Event Actor.OnKill(Actor akSender, Actor akVictim)
    if akSender != Game.GetPlayer() || akVictim == None
        return
    endIf

    TotalEncounters += 1
    float currentTime = Utility.GetCurrentGameTime()
    float timeDiff    = (currentTime - _lastKillGameTime) * 1440.0
    
    if timeDiff > 0.167
        _killStreak = 1
    else
        _killStreak += 1
    endIf
    _lastKillGameTime = currentTime
    if _killStreak > KillStreakMax
        KillStreakMax = _killStreak
    endIf

    if _killStreak == 3 || _killStreak == 5 || _killStreak == 8
        _CheckMoraleBreak()
    endIf

    string killEntry = akVictim.GetDisplayName() + " at " + _GetLocationName()
    int i = 9
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

Function _SaveMercyAction()
    TimesSpared += 1
EndFunction

; ==========================================================
; LOCATION TRACKER
; ==========================================================
Function _StartLocationTracker()
    _LocationTick()
EndFunction

Function _LocationTick()
    string lastLoc = ""
    while true
        Utility.Wait(10.0)
        string curLoc = _GetLocationName()
        if curLoc != lastLoc && curLoc != "the Commonwealth"
            lastLoc = curLoc
            _TrackLocation(curLoc)
        endIf
    endWhile
EndFunction

Function _TrackLocation(string locName)
    int i = 0
    while i < VisitedCount
        if VisitedLocations[i] == locName
            return
        endIf
        i += 1
    endWhile
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
    string eventData = "KILLS:"
    int i = 0
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
; MAIN CHAT
; ==========================================================
Function StartAIChat()
    if _isProcessing
        Debug.Notification("Still waiting on a response...")
        return
    endIf

    Actor targetActor = Game.FindClosestActorFromRef(Game.GetPlayer(), 200.0)
    if targetActor == None || targetActor == Game.GetPlayer()
        return
    endIf
    if targetActor.IsDead() || targetActor.IsInCombat()
        return
    endIf

    _isProcessing = true
    string npcName = _GetNPCName(targetActor)
    string locName = _GetLocationName()
    string playerMsg = _GetPlayerInput(npcName)
    string context = _BuildContext()
    float dist = Game.GetPlayer().GetDistance(targetActor)

    string npcSex = "m"
    ActorBase npcBase = targetActor.GetLeveledActorBase() as ActorBase
    if npcBase != None && npcBase.GetSex() == 1
        npcSex = "f"
    endIf

    string handshake = "NAME:" + npcName + "|MSG:" + playerMsg + "|LOC:" + locName + "|SEX:" + npcSex + "|DIST:" + (dist as int) + "|STATE:" + _GetNPCState(targetActor) + _GetDrunkFlag(locName) + "|KILLSTREAK:" + _killStreak + "|TIMESPARED:" + TimesSpared + "|ENCOUNTERS:" + TotalEncounters + "|ENV:" + _GetEnvType() + context

    System:IO:File.WriteAllText(ResponseFile, "")
    System:IO:File.WriteAllText(InterruptFile, "")
    System:IO:File.WriteAllText(PromptFile, handshake)

    targetActor.SetRestrained(true)
    targetActor.SetLookAt(Game.GetPlayer())
    targetActor.PlayIdle(IdleThinking)
    Debug.Notification("...")

    string response = _PollForResponse(targetActor)
    targetActor.PlayIdle(IdleStop)
    targetActor.ClearLookAt()
    targetActor.SetRestrained(false)

    if response != "INTERRUPTED"
        _DisplayResponse(npcName, response)
        _UpdateMood(npcName, targetActor)
    endIf

    _lastNPCName     = npcName
    _lastPlayerMsg   = playerMsg
    _lastNPCResponse = response
    _conversationCount += 1
    if _conversationCount >= 3
        _conversationCount = 0
        _TriggerCompanionReaction()
    endIf
    _isProcessing = false
EndFunction

; ==========================================================
; GIFT INTERACTION
; ==========================================================
Function _StartGiftInteraction()
    if _isProcessing
        return
    endIf
    Actor targetActor = Game.FindClosestActorFromRef(Game.GetPlayer(), 200.0)
    if targetActor == None || targetActor == Game.GetPlayer() || targetActor.IsDead()
        return
    endIf

    _isProcessing = true
    string npcName = _GetNPCName(targetActor)
    System:IO:File.WriteAllText("fo4_input_request.txt", "GIFT:" + npcName)
    string giftName = _WaitForInput()

    if giftName == "" || giftName == "CANCEL"
        _isProcessing = false
        return
    endIf

    string handshake = "NAME:" + npcName + "|MSG:GIFT|LOC:" + _GetLocationName() + "|DIST:" + (Game.GetPlayer().GetDistance(targetActor) as int) + "|GIFTED_ITEM:" + giftName + _BuildContext()
    System:IO:File.WriteAllText(PromptFile, handshake)
    string response = _PollForCombatResponse()
    if response != "" && response != "..."
        _DisplayResponse(npcName, response)
    endIf
    _UpdateMood(npcName, targetActor)
    _isProcessing = false
EndFunction

; ==========================================================
; HELPERS
; ==========================================================
string Function _GetNPCState(Actor akTarget)
    float currentHP = akTarget.GetValue(HealthAV)
    float maxHP = akTarget.GetBaseValue(HealthAV)
    if (currentHP / maxHP) < 0.5
        return "WOUNDED"
    endIf
    return "HEALTHY"
EndFunction

string Function _GetDrunkFlag(string locName)
    float gameHour = Utility.GetCurrentGameTime() * 24.0
    int hour = (gameHour as int) % 24
    if (locName == "Dugout Inn" || locName == "The Third Rail") && (hour >= 20 || hour < 2)
        return "|DRUNK:TRUE"
    endIf
    return ""
EndFunction

string Function _GetEnvType()
    if Game.GetPlayer().IsInInterior()
        return "INTERIOR"
    endIf
    return "EXTERIOR"
EndFunction

Function _TriggerCompanionReaction()
    Actor companion = _FindCompanion()
    if companion == None || _lastNPCName == "" || _lastNPCResponse == ""
        return
    endIf
    string handshake = "NAME:" + _GetNPCName(companion) + "|MSG:COMPANION_REACT|LAST_NPC:" + _lastNPCName + "|LAST_MSG:" + _lastPlayerMsg + "|LAST_RESP:" + _lastNPCResponse + _BuildContext()
    System:IO:File.WriteAllText(PromptFile, handshake)
    string response = _PollForBanter()
    if response != "" && response != "..."
        Debug.Notification(_GetNPCName(companion) + ": " + response)
    endIf
EndFunction

string Function _BuildContext()
    string ctx = "|HOUR:" + ((Utility.GetCurrentGameTime() * 24.0) as int % 24)
    Weather curW = Weather.GetCurrentWeather()
    if curW != None
        int wType = curW.GetClassification()
        if wType == 1
            ctx += "|WEATHER:Rainy"
        elseIf wType == 3
            ctx += "|WEATHER:Thunderstorm"
            if Game.GetPlayer().GetValue(RadiationAV) > 50
                ctx += "|RADSTORM:TRUE"
            endIf
        else
            ctx += "|WEATHER:Clear"
        endIf
    endIf
    ; F4SE GetWornForm check removed to bypass compiler errors
    return ctx
EndFunction

; ==========================================================
; MOOD SYSTEM
; ==========================================================
Function _UpdateMood(string npcName, Actor akTarget)
    string label = System:IO:File.ReadAllText(MoodFile)
    if label == ""
        label = "NEUTRAL"
    endIf
    int idx = _FindMoodIndex(npcName)
    if idx == -1 && MoodCount < 30
        MoodNPCNames[MoodCount] = npcName
        MoodLabels[MoodCount]   = label
        MoodCount += 1
    elseIf idx >= 0
        MoodLabels[idx] = label
    endIf

    if label == "ANGRY" || label == "FURIOUS"
        if IdleAngry != None
            akTarget.PlayIdle(IdleAngry)
        endIf
        if label == "FURIOUS"
            _StartFistfight(akTarget)
        endIf
    elseIf label == "HAPPY" || label == "BEST_FRIENDS"
        if IdleHappy != None
            akTarget.PlayIdle(IdleHappy)
        endIf
    endIf
EndFunction

int Function _FindMoodIndex(string npcName)
    int i = 0
    while i < MoodCount
        if MoodNPCNames[i] == npcName
            return i
        endIf
        i += 1
    endWhile
    return -1
EndFunction

; ==========================================================
; FISTFIGHT & COMBAT NEGOTIATION
; ==========================================================
Function _StartFistfight(Actor akTarget)
    if _isFistfighting
        return
    endIf
    _isFistfighting = true
    _fightTarget = akTarget
    akTarget.SetEssential(true)
    akTarget.UnequipAll()
    akTarget.StartCombat(Game.GetPlayer())
EndFunction

Function _ShowFightPauseMenu()
    if !_isFistfighting || _fightTarget == None
        return
    endIf
    _fightTarget.StopCombat()
    System:IO:File.WriteAllText("fo4_input_request.txt", "FIGHT_PAUSE:" + _fightTarget.GetDisplayName())
    string choice = _WaitForInput()
    if choice == "0" || choice == "1"
        _EndFistfight(true)
    else
        _fightTarget.StartCombat(Game.GetPlayer())
    endIf
EndFunction

Function _EndFistfight(bool playerSurrendered)
    if !_isFistfighting
        return
    endIf
    _fightTarget.StopCombat()
    _isFistfighting = false
    _fightTarget = None
EndFunction

Function _StartCombatNegotiation()
    if _isProcessing
        return
    endIf
    Actor targetActor = Game.FindClosestActorFromRef(Game.GetPlayer(), 300.0)
    if targetActor == None || targetActor.IsDead()
        return
    endIf
    _isProcessing = true
    string npcName = _GetNPCName(targetActor)
    System:IO:File.WriteAllText("fo4_input_request.txt", "COMBAT_NEG:" + npcName)
    string choice = _WaitForInput()
    if choice == "BACK"
        _isProcessing = false
        return
    endIf
    _PauseCombatNearby(targetActor)
    string handshake = "NAME:" + npcName + "|MSG:" + choice + "|COMBAT:TRUE|DIST:" + (Game.GetPlayer().GetDistance(targetActor) as int) + _BuildContext()
    System:IO:File.WriteAllText(PromptFile, handshake)
    string response = _PollForCombatResponse()
    _DisplayResponse(npcName, response)
    _ResumeCombatNearby(targetActor)
    _isProcessing = false
EndFunction

; ==========================================================
; DRAMA SYSTEMS
; ==========================================================
Function _StartCombatDramaLoop()
    if _combatDramaRunning
        return
    endIf
    _combatDramaRunning = true
    _CombatDramaTick()
EndFunction

Function _CombatDramaTick()
    int tauntTimer = 0
    while _combatDramaRunning
        Utility.Wait(5.0)
        if Game.GetPlayer().IsInCombat()
            tauntTimer += 5
            if tauntTimer >= 15
                tauntTimer = 0
                _TriggerTrashTalk()
            endIf
        else
            tauntTimer = 0
            _killStreak = 0
        endIf
    endWhile
EndFunction

Function _TriggerTrashTalk()
    Actor taunter = Game.FindClosestActorFromRef(Game.GetPlayer(), 600.0)
    if taunter == None || taunter.IsDead() || !taunter.IsHostileToActor(Game.GetPlayer())
        return
    endIf
    string handshake = "NAME:" + _GetNPCName(taunter) + "|KILLSTREAK:" + _killStreak + _BuildContext()
    System:IO:File.WriteAllText("fo4_taunt.txt", handshake)
EndFunction

Function _CheckMoraleBreak()
    System:IO:File.WriteAllText("fo4_morale.txt", "KILLSTREAK:" + _killStreak + _BuildContext())
EndFunction

; ==========================================================
; POLLING & UTILITY
; ==========================================================
string Function _PollForResponse(Actor akTarget)
    int cycles = 0
    while cycles < MaxPollCycles
        if akTarget.IsDead()
            return "INTERRUPTED"
        endIf
        string response = System:IO:File.ReadAllText(ResponseFile)
        if response != "" && response != "..."
            System:IO:File.WriteAllText(ResponseFile, "")
            return response
        endIf
        Utility.Wait(PollInterval)
        cycles += 1
    endWhile
    return FallbackLines[0]
EndFunction

string Function _GetPlayerInput(string npcName)
    System:IO:File.WriteAllText("fo4_input_request.txt", npcName)
    int cycles = 0
    while cycles < 60
        Utility.Wait(0.5)
        string playerInput = System:IO:File.ReadAllText("fo4_input.txt")
        if playerInput != ""
            System:IO:File.WriteAllText("fo4_input.txt", "")
            return playerInput
        endIf
        cycles += 1
    endWhile
    return InputPresets[Utility.RandomInt(0, 4)]
EndFunction

string Function _WaitForInput()
    int cycles = 0
    while cycles < 60
        Utility.Wait(0.5)
        string playerInput = System:IO:File.ReadAllText("fo4_input.txt")
        if playerInput != ""
            System:IO:File.WriteAllText("fo4_input.txt", "")
            return playerInput
        endIf
        cycles += 1
    endWhile
    return "CANCEL"
EndFunction

string Function _PollForCombatResponse()
    int cycles = 0
    while cycles < 30
        string response = System:IO:File.ReadAllText(ResponseFile)
        if response != ""
            return response
        endIf
        Utility.Wait(0.5)
        cycles += 1
    endWhile
    return "..."
EndFunction

string Function _PollForBanter()
    int cycles = 0
    while cycles < 20
        string response = System:IO:File.ReadAllText(ResponseFile)
        if response != "" && response != "..."
            return response
        endIf
        Utility.Wait(0.5)
        cycles += 1
    endWhile
    return ""
EndFunction

; --- ADDITIONAL HELPERS ---
Function _StartBanterLoop()
EndFunction
Function _PauseCombatNearby(Actor anchor)
EndFunction
Function _ResumeCombatNearby(Actor anchor)
EndFunction
Function _DisplayResponse(string name, string resp)
    Debug.Notification(name + ": " + resp)
EndFunction
string Function _GetNPCName(Actor akTarget)
    return akTarget.GetDisplayName()
EndFunction
string Function _GetLocationName()
    return "the Commonwealth"
EndFunction
Actor Function _FindCompanion()
    return CurrentCompanion
EndFunction