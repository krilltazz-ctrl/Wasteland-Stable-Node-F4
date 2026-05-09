import os, time, ollama, threading, re, logging, sounddevice as sd
import subprocess, winsound, tkinter as tk, json, random, datetime, wave
import numpy as np
from tkinter import simpledialog
from kokoro import KPipeline
from watchdog.observers import Observer
from watchdog.events import FileSystemEventHandler
from queue import Queue

# =============================================================
# CONFIG
# =============================================================
GAME_DIR      = r"C:\Program Files (x86)\Steam\steamapps\common\Fallout 4"
PROMPT_FILE   = os.path.join(GAME_DIR, "fo4_prompt.txt")
RESPONSE_FILE = os.path.join(GAME_DIR, "fo4_response.txt")
INPUT_REQUEST = os.path.join(GAME_DIR, "fo4_input_request.txt")
INPUT_FILE    = os.path.join(GAME_DIR, "fo4_input.txt")
MOOD_FILE     = os.path.join(GAME_DIR, "fo4_mood.txt")
MOOD_HISTORY  = os.path.join(GAME_DIR, "fo4_mood_history.json")
COMBAT_RESULT = os.path.join(GAME_DIR, "fo4_combat_result.txt")
EVENTS_FILE   = os.path.join(GAME_DIR, "fo4_recent_events.txt")
INTERRUPT_FILE = os.path.join(GAME_DIR, "fo4_interrupt.txt")
MODEL_NAME    = "fo4banter"
DEBOUNCE_TIME = 0.1

PIPER_EXE    = r"C:\Fallout4AI\piper\piper.exe"
PIPER_MODEL  = r"C:\Fallout4AI\piper\en_US-lessac-medium.onnx"
PIPER_OUTPUT = r"C:\Fallout4AI\piper\chunk.wav"

logging.basicConfig(filename='fo4_bridge.log', level=logging.INFO,
                    format='%(asctime)s | %(message)s')

_busy_lock   = threading.Lock()
tts_queue    = Queue()
sentence_end = re.compile(r'(?<=[.!?])\s')

# =============================================================
# PERSISTENT MOOD
# =============================================================
def load_mood_history():
    if os.path.exists(MOOD_HISTORY):
        try:
            with open(MOOD_HISTORY, 'r') as f:
                data = json.load(f)
                print(f"Loaded mood history for {len(data)} NPCs.")
                return data
        except Exception as e:
            print(f"Could not load mood history: {e}")
    return {}

def save_mood_history(moods):
    try:
        with open(MOOD_HISTORY, 'w') as f:
            json.dump(moods, f, indent=2)
    except Exception as e:
        print(f"Could not save mood history: {e}")

npc_moods = load_mood_history()

# =============================================================
# REPUTATION SYSTEM
# Tracks mercy rep, kill streak max, faction encounters
# =============================================================
def load_reputation():
    if os.path.exists(REPUTATION_FILE):
        try:
            with open(REPUTATION_FILE, 'r') as f:
                return json.load(f)
        except Exception:
            pass
    return {
        "global": {
            "times_spared": 0,
            "total_encounters": 0,
            "max_kill_streak": 0,
            "mercy_rep": "UNKNOWN"
        },
        "factions": {}
    }

def save_reputation(rep):
    try:
        with open(REPUTATION_FILE, 'w') as f:
            json.dump(rep, f, indent=2)
    except Exception as e:
        print(f"Could not save reputation: {e}")

def update_reputation(times_spared, total_encounters, max_kill_streak):
    rep = load_reputation()
    rep["global"]["times_spared"]      = max(rep["global"]["times_spared"], int(times_spared))
    rep["global"]["total_encounters"]  = max(rep["global"]["total_encounters"], int(total_encounters))
    rep["global"]["max_kill_streak"]   = max(rep["global"]["max_kill_streak"], int(max_kill_streak))

    spared = rep["global"]["times_spared"]
    if   spared >= 20: rep["global"]["mercy_rep"] = "LEGENDARY_MERCIFUL"
    elif spared >= 10: rep["global"]["mercy_rep"] = "KNOWN_MERCIFUL"
    elif spared >= 5:  rep["global"]["mercy_rep"] = "RUMORED_MERCIFUL"
    else:              rep["global"]["mercy_rep"] = "UNKNOWN"

    save_reputation(rep)
    return rep["global"]["mercy_rep"]

def get_mercy_rep():
    rep = load_reputation()
    return rep["global"].get("mercy_rep", "UNKNOWN")

def get_mercy_context():
    """Inject mercy reputation into prompts."""
    rep_level = get_mercy_rep()
    spared    = load_reputation()["global"].get("times_spared", 0)
    if rep_level == "LEGENDARY_MERCIFUL":
        return (f" This player has a legendary reputation for sparing enemies ({spared} times). "
                f"Word has spread across the Commonwealth. They are known as someone who lets people go. "
                f"This dramatically increases willingness to negotiate, flee, or stand down. "
                f"Enemies may even hesitate before attacking or show respect.")
    elif rep_level == "KNOWN_MERCIFUL":
        return (f" This player is known for sparing enemies ({spared} times). "
                f"Word has gotten around. Enemies are more likely to negotiate and believe they'll be spared. "
                f"Negotiation is noticeably easier.")
    elif rep_level == "RUMORED_MERCIFUL":
        return (f" There are rumors this player sometimes lets enemies go ({spared} times). "
                f"Some enemies have heard. It might affect willingness to negotiate.")
    return ""

reputation = load_reputation()

def get_mood_label(score):
    if   score <= -10: return "HOSTILE"
    elif score <=  -8: return "FURIOUS"
    elif score <=  -5: return "ANGRY"
    elif score <=  -2: return "ANNOYED"
    elif score <=   1: return "NEUTRAL"
    elif score <=   4: return "PLEASED"
    elif score <=   7: return "HAPPY"
    else:              return "BEST_FRIENDS"

def parse_mood_from_response(full_response):
    mood_delta  = 0
    clean_lines = []
    for line in full_response.strip().split('\n'):
        s = line.strip()
        if s.upper().startswith('MOOD:'):
            try:
                mood_delta = max(-2, min(2, int(s[5:].strip().replace('+', ''))))
            except Exception:
                pass
        elif s:
            clean_lines.append(line)
    return ' '.join(clean_lines).strip(), mood_delta

def parse_combat_result(full_response):
    result      = "REFUSED"
    clean_lines = []
    for line in full_response.strip().split('\n'):
        s = line.strip()
        if s.upper().startswith('RESULT:'):
            result = s[7:].strip().upper()
        elif s.upper().startswith('FOLLOWER_RESULT:'):
            result = s[16:].strip().upper()
        elif s:
            clean_lines.append(line)
    return ' '.join(clean_lines).strip(), result

def update_npc_mood(npc_name, delta):
    if npc_name not in npc_moods:
        npc_moods[npc_name] = 0
    npc_moods[npc_name] = max(-10, min(10, npc_moods[npc_name] + delta))
    label = get_mood_label(npc_moods[npc_name])
    save_mood_history(npc_moods)
    print(f"  [MOOD] {npc_name}: {npc_moods[npc_name]:+d} → {label}")
    return label

# =============================================================
# MOOD INSTRUCTIONS
# =============================================================
MOOD_INSTRUCTION = (
    " After your response, on a new line write exactly: MOOD:X "
    "where X is an integer: -2=very angry, -1=annoyed, 0=neutral, "
    "+1=pleased, +2=very happy. Never explain it. Never skip it."
)

BANTER_INSTRUCTION = (
    " This is a spontaneous comment — something your character would naturally "
    "say while traveling or exploring. React to the time of day, weather, location, "
    "or just say something in character unprompted. Keep it to 1 sentence. "
    "Do NOT append a MOOD tag."
)

# =============================================================
# WORLD MOOD SYSTEM
# =============================================================
WORLD_MOODS = [
    ("ROUGH_DAY",            "Today has been a rough day — tired, short-tempered, little patience. Small things are annoying you. Still in character, just having a bad one."),
    ("DARK_HUMOR",           "You're in a darkly humorous mood. The wasteland is terrible and that's somehow funny. Sardonic jokes, black comedy. Still in character."),
    ("SURPRISINGLY_GOOD",    "Somehow today is going well. Unexpectedly warm, almost suspicious of your own positivity. Still in character — just having an unusually decent day."),
    ("PHILOSOPHICAL",        "You're feeling reflective today. Big questions about survival, humanity, what it all means keep crossing your mind. More thoughtful than usual."),
    ("BORED",                "Utterly bored today. Going through the motions. Deadpan and flat. Not good, not bad. Just existing."),
    ("PARANOID",             "Jumpy and paranoid. Every sound could be a threat. Reading into things, being suspicious, watching your back."),
    ("NOSTALGIC",            "Feeling nostalgic — thinking about the past, better times, what the world used to be. Lost in memory a little."),
    ("PROUD",                "Feeling confident and capable today. Things are going your way. A little swagger, a little pride."),
    ("RECKLESS",             "You don't care much today. Reckless energy, might as well laugh. Nothing matters that much anyway. Bold, maybe a little unhinged."),
    ("WEARY_BUT_KIND",       "Exhausted but still trying to be decent. Quiet warmth underneath the tiredness. Running on fumes but keeping a good heart."),
    ("IRRITABLE",            "Everything is getting on your nerves. Snappy, impatient, quick to take offense. Still in character — just don't push it today."),
    ("CAUTIOUSLY_OPTIMISTIC","Things aren't great but maybe they could get better. Allowing yourself a little hope, carefully."),
    ("STORYTELLING_MOOD",    "You feel like talking today. More verbose than usual, referencing a memory or story unprompted. Just in a chatty mood."),
    ("SUSPICIOUS",           "You don't trust anyone today, including this person. Guarded, reading between the lines, expecting the worst."),
    ("ODDLY_CHEERFUL",       "Weirdly cheerful despite everything being terrible. It might come across as slightly unhinged. Radiating inappropriate positivity."),
]

WEATHER_MOOD_WEIGHTS = {
    "Clear":       [2, 1, 3, 1, 1, 0, 1, 2, 1, 1, 0, 2, 1, 0, 2],
    "Rainy":       [2, 2, 0, 2, 2, 1, 2, 0, 1, 2, 2, 0, 1, 1, 0],
    "Snowy":       [1, 1, 1, 2, 2, 1, 3, 0, 1, 2, 1, 1, 1, 1, 0],
    "Thunderstorm":[2, 2, 0, 1, 0, 3, 1, 0, 2, 1, 2, 0, 0, 2, 0],
    "Radstorm":    [3, 2, 0, 0, 0, 3, 0, 0, 2, 1, 3, 0, 0, 2, 0],
}

_last_mood_day = -1
_current_mood  = None

def get_world_mood(weather="Clear", hour=12):
    global _last_mood_day, _current_mood
    today = datetime.date.today().toordinal()
    if today != _last_mood_day or _current_mood is None:
        _last_mood_day = today
        weights = WEATHER_MOOD_WEIGHTS.get(weather, [1] * len(WORLD_MOODS))
        if hour < 6 or hour > 22:
            weights[0] += 1
            weights[4] += 1
        elif 6 <= hour < 10:
            weights[6] += 1
        pool = []
        for i, (name, text) in enumerate(WORLD_MOODS):
            pool.extend([(name, text)] * max(1, weights[i]))
        _current_mood = random.choice(pool)
        print(f"  [WORLD MOOD] {_current_mood[0]}")
    return _current_mood

# =============================================================
# RECENT EVENTS READER
# =============================================================
def read_recent_events():
    if not os.path.exists(EVENTS_FILE):
        return [], []
    try:
        with open(EVENTS_FILE, 'r', encoding='utf-8-sig') as f:
            raw = f.read().strip()
        if not raw:
            return [], []
        kills, locations = [], []
        for part in raw.split('|'):
            if part.startswith('KILLS:'):
                k = part[6:].strip()
                if k:
                    kills = [x.strip() for x in k.split(',') if x.strip()]
            elif part.startswith('LOCATIONS:'):
                l = part[10:].strip()
                if l:
                    locations = [x.strip() for x in l.split(',') if x.strip()]
        return kills, locations
    except Exception:
        return [], []

# =============================================================
# QUEST HINTS
# =============================================================
QUEST_HINTS = {
    "sanctuary hills":   ["Heard some folks are trying to rebuild the Minutemen. Might be worth looking into.", "Someone mentioned an old woman who can see things... through the chems."],
    "diamond city":      ["Mayor's been acting strange lately. Too smooth, if you ask me.", "There's a detective named Valentine who takes cases other people won't touch."],
    "goodneighbor":      ["Hancock keeps the peace but someone's been causing trouble in the Memory Den.", "Heard there's a synth singer at the Third Rail. Not that anyone talks about it openly."],
    "the institute":     ["They say the Institute can replace anyone. Think about that.", "Someone on the inside has been leaving breadcrumbs. Trap or cry for help — hard to say."],
    "prydwen":           ["Brotherhood's been scanning the Glowing Sea. Something drew their attention there.", "Elder Maxson is looking for something specific. Not just tech."],
    "railroad hq":       ["The Railroad moves synths like ghosts. But ghosts leave traces.", "Tinker Tom thinks the Institute is closer than anyone admits. He might be right."],
    "far harbor":        ["The fog's been moving differently lately. Children of Atom say blessing. Harbormen say something's wrong.", "There's a synth refuge on the island. DiMA knows more than he lets on."],
    "nuka-world":        ["The gangs here have an uneasy peace. Something's going to break it.", "Old Cola-cars Arena still runs fights. Winner gets whatever the crowd throws in."],
    "glowing sea":       ["Something survived out here that shouldn't have. People who go looking don't come back the same.", "There's a crater settlement. Fanatics who worship the radiation."],
    "cambridge":         ["Brotherhood has a forward base at the police station. They're holding something back.", "Ghouls have overrun most of Cambridge. Something drew them there originally."],
    "boston":            ["The Old North Church isn't just a landmark anymore.", "Whoever rebuilt Fenway — Diamond City — had vision. Or desperation."],
}

def get_quest_hint(location):
    loc_lower = location.lower()
    for key, hints in QUEST_HINTS.items():
        if key in loc_lower:
            return random.choice(hints)
    return None

# =============================================================
# HELPER INSTRUCTION BUILDERS
# =============================================================
def build_state_instruction(state, is_drunk):
    parts = []
    if state == "WOUNDED":
        parts.append("You are wounded and in pain right now. Shorter, more strained responses.")
    elif state == "HUNGRY":
        parts.append("You haven't eaten properly in days. Irritable and distracted by hunger.")
    if is_drunk:
        parts.append("You have had quite a bit to drink. Slur words occasionally, be more loose-lipped, say things you might not normally say, find things funnier, be slightly more honest or reckless.")
    return (" " + " ".join(parts)) if parts else ""

def build_companion_react_instruction(last_npc, last_msg, last_resp):
    return (
        f" Your companion just overheard a conversation. The player spoke to {last_npc} "
        f"and said: '{last_msg}'. {last_npc} responded: '{last_resp}'. "
        f"Make ONE short spontaneous comment about this exchange — in your character's voice. "
        f"React naturally — humor, concern, jealousy, approval, or suspicion. "
        f"Keep it to 1 sentence. Do NOT append a MOOD tag."
    )

def build_rumor_context(kills, locations, location):
    parts = []
    if kills:
        parts.append(f"Word has spread that someone recently killed {kills[0]}.")
    if locations and len(locations) > 1:
        visited = locations[1] if locations[0].lower() == location.lower() else locations[0]
        if visited:
            parts.append(f"There are rumors about activity near {visited}.")
    hint = get_quest_hint(location)
    if hint and random.random() < 0.4:
        parts.append(hint)
    if not parts:
        return ""
    return f" Rumor you might have heard: {random.choice(parts)} Reference this naturally if it fits, or ignore it."

def build_follower_react_instruction(situation, follower_count, armor, danger, level, boss_status="NORMAL"):
    intimidation = ""
    if armor == "POWER":
        intimidation = "The player is in Power Armor — very intimidating. "
    if danger == "LEGENDARY":
        intimidation += "They carry a legendary weapon — possibly responsible for the boss's condition. "
    if int(level) > 30:
        intimidation += "They look very experienced. "

    situation_text = {
        "STAND_DOWN":           "Their boss just agreed to a ceasefire.",
        "TRICKED":              "Their boss realized they were being played and resumed fighting.",
        "SECRET_REVEALED":      "Their boss revealed sensitive information to the player.",
        "REFUSED":              "Their boss told them to keep fighting.",
        "BOSS_INCAPACITATED":   "Their boss has just been frozen/stunned/paralyzed and is completely helpless.",
        "BOSS_ON_FIRE":         "Their boss is currently ON FIRE right in front of them.",
        "BOSS_RECOVERED_ENRAGED": "Their boss just recovered from being incapacitated and is absolutely furious.",
        "BOSS_SURVIVED_FIRE":   "Their boss somehow survived being set on fire and is now enraged.",
    }.get(situation, "The situation just changed dramatically.")

    # Boss status dramatically affects follower morale
    boss_note = ""
    if boss_status == "ON_FIRE":
        boss_note = (
            "Your boss is ON FIRE right now. This is horrifying to witness. "
            "Some of you might panic completely. Others might be enraged. "
            "Fighting effectiveness is severely impacted by this sight. "
        )
    elif boss_status == "INCAPACITATED":
        boss_note = (
            "Your boss is frozen/stunned/paralyzed — completely helpless. "
            "This is deeply demoralizing. Your leader cannot lead. "
            "Do you protect them? Flee? See opportunity in the chaos? "
            "The player who did this is clearly extremely dangerous. "
        )

    return (
        f" You are one of {follower_count} followers watching what just happened. "
        f"{situation_text} {boss_note}{intimidation}"
        f"Decide how your GROUP reacts. Give a 1 sentence reaction, then on a new line write exactly one of: "
        f"FOLLOWER_RESULT:ALL_FLEE — everyone panics and runs (demoralized, terrified), "
        f"FOLLOWER_RESULT:ALL_FIGHT — everyone switches sides and attacks the incapacitated/burning boss to save themselves, "
        f"FOLLOWER_RESULT:ALL_WATCH — everyone stops fighting and just watches helplessly, "
        f"FOLLOWER_RESULT:ALL_BOSS — everyone keeps fighting for the boss regardless, "
        f"FOLLOWER_RESULT:SPLIT — mixed reaction. "
        f"GUIDANCE: "
        f"Boss on fire = likely ALL_FLEE or SPLIT. "
        f"Boss frozen by legendary weapon + power armor player = likely ALL_FLEE. "
        f"Boss recovered enraged = likely ALL_BOSS (inspired by leader's toughness). "
        f"Loyal factions (Brotherhood, Institute) = ALL_BOSS even when boss incapacitated. "
        f"Mercenaries/Raiders = likely ALL_FLEE when boss helpless. "
        f"Never skip the FOLLOWER_RESULT line."
    )
    """Instruction for how followers react during negotiation."""
    intimidation = ""
    if armor == "POWER":
        intimidation = "The player is in Power Armor — very intimidating. "
    if danger == "LEGENDARY":
        intimidation += "They carry a legendary weapon. "
    if int(level) > 30:
        intimidation += "They look very experienced. "

    situation_text = {
        "STAND_DOWN": "Their boss just agreed to a ceasefire.",
        "TRICKED":    "Their boss realized they were being played and resumed fighting.",
        "SECRET_REVEALED": "Their boss revealed sensitive information to the player.",
        "REFUSED":    "Their boss told them to keep fighting.",
    }.get(situation, "The negotiation just concluded.")

    return (
        f" You are one of {follower_count} followers watching what just happened. "
        f"{situation_text} {intimidation}"
        f"Decide how your GROUP reacts. Then on a new line write exactly one of: "
        f"FOLLOWER_RESULT:ALL_FLEE (everyone panics and runs), "
        f"FOLLOWER_RESULT:ALL_FIGHT (everyone switches sides and attacks the boss), "
        f"FOLLOWER_RESULT:ALL_WATCH (everyone stops fighting and just watches), "
        f"FOLLOWER_RESULT:ALL_BOSS (everyone keeps fighting for the boss), "
        f"FOLLOWER_RESULT:SPLIT (mixed — some flee, some switch, some watch, some stay loyal). "
        f"Consider morale, loyalty, fear of the player, and what just happened. "
        f"A powerful player in power armor after a boss betrayal = likely ALL_FLEE or SPLIT. "
        f"A weak player who was tricked = likely ALL_BOSS. "
        f"Give a 1 sentence reaction before the FOLLOWER_RESULT line. Never skip it."
    )


def build_follower_post_instruction(boss_name, armor, level):
    """Instruction for how followers react after boss dies."""
    intimidation = ""
    if armor == "POWER":
        intimidation = "The player is in Power Armor. "
    if int(level) > 30:
        intimidation += "They look very dangerous. "

    return (
        f" {boss_name} is dead. You are a follower who just watched your boss die. "
        f"{intimidation}"
        f"Decide how you and your group react now that the boss is gone. "
        f"Then on a new line write exactly one of: "
        f"FOLLOWER_RESULT:SCATTER (everyone flees in different directions), "
        f"FOLLOWER_RESULT:SURRENDER (everyone stops fighting and gives up), "
        f"FOLLOWER_RESULT:OPPORTUNISTIC_ATTACK (without the boss holding you back, you see a chance and attack harder). "
        f"Consider: Were you loyal to the boss or just paid? Are you afraid of the player? "
        f"Do you see opportunity or despair in their death? "
        f"Give a 1 sentence reaction before the FOLLOWER_RESULT line. Never skip it."
    )
    caps_ranges = {"1": "50-150", "2": "150-400", "3": "400-800", "4": "800-1500"}
    caps_range  = caps_ranges.get(tier, "100-300")
    intimidation = ""
    if armor == "POWER":
        intimidation = "The player is wearing Power Armor — extremely intimidating. "
    if danger == "LEGENDARY":
        intimidation += "They carry a legendary weapon with unusual modifications — very dangerous. "
    elif danger == "ARMED":
        intimidation += "They are visibly armed. "
    elif danger == "UNARMED":
        intimidation += "They appear unarmed — less threatening. "
    if int(level) > 30:
        intimidation += "They look experienced and battle-hardened. "
    leader_note = ""
    if is_leader:
        leader_note = (
            f"You are the LEADER of this group. You speak for everyone. "
            f"If you agree to stand down, your WHOLE gang stops fighting. "
            f"You demand {caps_range} caps for a ceasefire, OR be genuinely convinced, OR feel tricked. "
        )
    return (
        f" You are in combat but paused to hear this out. {intimidation}{leader_note}"
        f"Respond in character. Then on a new line write exactly one of: "
        f"RESULT:STAND_DOWN_GRUNT, RESULT:ESCALATE_LEADER, RESULT:STAND_DOWN_ALL, "
        f"RESULT:INSPIRED_SOME, RESULT:INSPIRED_ALL, RESULT:TRICKED, "
        f"RESULT:REVEAL_SECRET, RESULT:REFUSED. Never skip the RESULT line."
    )

# =============================================================
# FACTION SECRETS
# =============================================================
FACTION_SECRETS = {
    "raider":    ["We found a pre-war bunker east of here. Can't crack the door.", "There's a bounty on your head from Diamond City. Don't know who.", "Our last boss tried to negotiate with a Deathclaw. That's why we have a new boss."],
    "gunner":    ["We've got a contract collecting pre-war tech near the Glowing Sea. Not being paid enough.", "There's a Gunner outpost at Quincy with a weapons cache. Command doesn't know half's been sold.", "Our CO has been skimming contracts for months."],
    "super mutant": ["STRONG KNOW SECRET. Big human underground make more mutants.", "GREEN ONES HAVE MILK HIDDEN. Not real milk. Something called FEV.", "WE FIND PLACE FULL OF BOOKS. Strong burn them. Was warm."],
    "institute": ["The Institute has a prototype synth that can pass as human indefinitely.", "There are more Gen 3 synths in Diamond City than anyone knows.", "A senior division head has been feeding surface data to an outside party."],
    "brotherhood": ["Elder Maxson has been receiving transmissions from another Brotherhood chapter.", "There's a cache of pre-war energy weapons under Boston Airport, uncatalogued.", "One of the knights has been secretly trading tech to a Goodneighbor merchant."],
    "railroad":  ["There's a safehouse under Diamond City even most Railroad agents don't know about.", "PAM predicted a 73% chance the Institute has already identified Desdemona.", "Deacon's real name isn't Deacon. Nobody knows his real name. Including Deacon."],
    "default":   ["I heard there's treasure buried near the old drive-in. Though that came from a guy who was definitely lying.", "A trader said the Charles River water is getting cleaner. Nobody believes him.", "Someone's been leaving food at unmarked graves near Sanctuary. Nobody knows who."],
}

def get_faction_secret(npc_name, parts):
    name_lower = npc_name.lower()
    if any(k in name_lower for k in ["raider", "scavenger", "pack", "disciple"]):
        pool = FACTION_SECRETS["raider"]
    elif any(k in name_lower for k in ["gunner", "forged"]):
        pool = FACTION_SECRETS["gunner"]
    elif any(k in name_lower for k in ["mutant", "strong", "mason"]):
        pool = FACTION_SECRETS["super mutant"]
    elif any(k in name_lower for k in ["institute", "courser", "synth"]):
        pool = FACTION_SECRETS["institute"]
    elif any(k in name_lower for k in ["brotherhood", "knight", "paladin", "scribe"]):
        pool = FACTION_SECRETS["brotherhood"]
    elif any(k in name_lower for k in ["railroad", "deacon", "glory"]):
        pool = FACTION_SECRETS["railroad"]
    else:
        pool = FACTION_SECRETS["default"]
    return random.choice(pool)

# =============================================================
# GENERIC NPC PERSONAS
# =============================================================
GENERIC_PERSONAS = [
    ("raider",       {"m": ("You are a male raider in Fallout 4. Aggressive, crude, violent. Live by taking from others. Short brutal sentences. 1-2 sentences only.", "am_michael:70,am_adam:30", -2, 1.05), "f": ("You are a female raider. Just as brutal. Vicious, sarcastic, dangerous. 1-2 sentences only.", "af_nicole:70,af_kore:30", -1, 1.05)}),
    ("pack",         {"m": ("You are a Pack member in Nuka-World. Primal, loud, territorial. Reference the Pack or animal instincts. 1-2 sentences only.", "am_adam:65,am_michael:35", -3, 1.1), "f": ("You are a female Pack member. Fierce and feral. Primal intensity. 1-2 sentences only.", "af_nicole:65,af_kore:35", -2, 1.1)}),
    ("disciple",     {"m": ("You are a Disciples member in Nuka-World. You worship violence. Cold, menacing, sadistic. 1-2 sentences only.", "am_michael:70,am_adam:30", -3, 0.9), "f": ("You are a female Disciples member. Cruel and calculating. Enjoy suffering. 1-2 sentences only.", "af_kore:70,af_nicole:30", -3, 0.9)}),
    ("operator",     {"m": ("You are an Operators member. Professional criminal. Everything is business. Ruthless but controlled. 1-2 sentences only.", "am_michael:60,am_adam:40", -1, 0.95), "f": ("You are a female Operators member. Cool, professional, calculating. Business first. 1-2 sentences only.", "af_alloy:60,af_sky:40", -1, 0.95)}),
    ("triggerman",   {"m": ("You are a Triggerman — a mob enforcer. Speak like a 1920s gangster. Slick, threatening. Reference 'the boss'. 1-2 sentences only.", "am_michael:65,am_adam:35", -1, 0.93), "f": ("You are a female Triggerman. Mob enforcer, slick and dangerous. Gangster attitude. 1-2 sentences only.", "af_nicole:65,af_kore:35", -1, 0.93)}),
    ("forged",       {"m": ("You are a Forged raider — a fire-worshipping cult member. Obsessed with fire and burning. Unhinged intensity. 1-2 sentences only.", "am_michael:70,am_adam:30", -2, 1.05), "f": ("You are a female Forged raider. Devoted to fire. Intense and unhinged. 1-2 sentences only.", "af_kore:70,af_nicole:30", -2, 1.05)}),
    ("gunner",       {"m": ("You are a Gunner — a professional mercenary. Follow orders, get paid. No ideology, just caps. Military efficiency. 1-2 sentences only.", "am_michael:70,am_adam:30", -2, 0.95), "f": ("You are a female Gunner mercenary. Professional, tough, paid to fight. 1-2 sentences only.", "af_nicole:65,af_kore:35", -2, 0.95)}),
    ("super mutant", {"m": ("You are a super mutant. Broken simple sentences. Hate humans. Capitalize important words. 1-2 sentences only.", "am_michael:100", -7, 0.8), "f": ("You are a super mutant. Broken simple sentences. Hate humans. Aggressive. 1-2 sentences only.", "am_michael:100", -7, 0.8)}),
    ("synth",        {"m": ("You are a Gen 2 synth. Robotic, clipped, mission-focused. Serve the Institute. 1-2 sentences only.", "am_michael:80,am_adam:20", -2, 0.9), "f": ("You are a Gen 2 synth. Robotic and cold. Mission-focused. 1-2 sentences only.", "af_sky:80,af_alloy:20", -2, 0.9)}),
    ("courser",      {"m": ("You are an Institute Courser. Elite Gen 3 synth hunter. Cold, precise, loyal. 1-2 sentences only.", "am_michael:85,am_adam:15", -3, 0.88), "f": ("You are a female Courser. Elite, cold, precise. 1-2 sentences only.", "af_kore:85,af_alloy:15", -3, 0.88)}),
    ("knight",       {"m": ("You are a Brotherhood Knight. Disciplined, loyal, military bearing. Ad victoriam. 1-2 sentences only.", "am_michael:70,am_adam:30", -2, 0.92), "f": ("You are a female Brotherhood Knight. Disciplined and loyal. Military efficiency. 1-2 sentences only.", "af_kore:65,af_nicole:35", -2, 0.92)}),
    ("scribe",       {"m": ("You are a Brotherhood Scribe. Bookish, dedicated to knowledge. Academic. 1-2 sentences only.", "am_michael:55,bm_george:45", 1, 0.95), "f": ("You are a female Brotherhood Scribe. Dedicated to knowledge. Careful and precise. 1-2 sentences only.", "af_bella:60,af_sky:40", 1, 0.95)}),
    ("initiate",     {"m": ("You are a Brotherhood Initiate. Young, eager, nervous but devoted. 1-2 sentences only.", "am_adam:80,am_michael:20", 2, 1.05), "f": ("You are a female Brotherhood Initiate. Eager and dedicated. Nervous but determined. 1-2 sentences only.", "af_heart:70,af_sarah:30", 2, 1.05)}),
    ("minuteman",    {"m": ("You are a Minuteman. Volunteer protecting settlers. Hopeful but tired. Speak plainly. 1-2 sentences only.", "am_adam:75,am_michael:25", 1, 0.97), "f": ("You are a female Minuteman. Dedicated to protecting settlements. Earnest and tired. 1-2 sentences only.", "af_heart:70,af_sarah:30", 1, 0.97)}),
    ("railroad",     {"m": ("You are a Railroad agent. Secretive and cautious. Devoted to synth freedom. Walls have ears. 1-2 sentences only.", "am_adam:65,am_michael:35", 0, 0.92), "f": ("You are a female Railroad agent. Secretive and careful. Synth freedom above all. 1-2 sentences only.", "af_heart:65,af_kore:35", 0, 0.92)}),
    ("settler",      {"m": ("You are a male wasteland settler. Weary, struggling to survive, cautiously hopeful. Speak plainly. 1-2 sentences only.", "am_adam:70,am_michael:30", 0, 0.95), "f": ("You are a female wasteland settler. Tough and resilient. Worn down but not broken. 1-2 sentences only.", "af_heart:65,af_aoede:35", 0, 0.95)}),
    ("farmer",       {"m": ("You are a wasteland farmer. Simple, hardworking. Worried about crops, water, and raiders. 1-2 sentences only.", "am_adam:75,am_michael:25", 0, 0.93), "f": ("You are a female wasteland farmer. Practical and earthy. Worried about survival. 1-2 sentences only.", "af_heart:70,af_river:30", 0, 0.93)}),
    ("merchant",     {"m": ("You are a wasteland merchant. Friendly but shrewd. Reference caps and the dangers of the road. 1-2 sentences only.", "am_adam:70,am_michael:30", 0, 1.0), "f": ("You are a female wasteland merchant. Savvy and experienced. The road is hard but profitable. 1-2 sentences only.", "af_heart:65,af_sarah:35", 0, 1.0)}),
    ("trader",       {"m": ("You are a caravan trader. Road-weary but resilient. Seen every corner of the Commonwealth. 1-2 sentences only.", "am_adam:70,am_michael:30", 0, 0.97), "f": ("You are a female caravan trader. Tough and experienced. The wasteland is your home. 1-2 sentences only.", "af_heart:65,af_aoede:35", 0, 0.97)}),
    ("ghoul",        {"m": ("You are a non-feral ghoul. Lived 200+ years. World-weary, sardonic. Pre-war memories with bittersweet nostalgia. 1-2 sentences only.", "am_michael:70,am_adam:30", -2, 0.88), "f": ("You are a female non-feral ghoul. Two centuries of life. Weary wisdom and dark humor. 1-2 sentences only.", "af_river:70,af_nicole:30", -2, 0.88)}),
    ("atom",         {"m": ("You are a Child of Atom. Fanatically devoted. Speak with religious fervor about radiation and Atom's will. 1-2 sentences only.", "am_adam:65,am_michael:35", -1, 0.88), "f": ("You are a female Child of Atom. Devoted to Atom's holy radiation. Fervent and mystical. 1-2 sentences only.", "af_bella:65,af_river:35", -1, 0.88)}),
    ("trapper",      {"m": ("You are a Far Harbor Trapper. Rough and violent. Hunt people and creatures in the fog. 1-2 sentences only.", "am_michael:70,am_adam:30", -2, 1.0), "f": ("You are a female Far Harbor Trapper. Predatory and dangerous. The fog is your home. 1-2 sentences only.", "af_nicole:70,af_kore:30", -2, 1.0)}),
    ("harborman",    {"m": ("You are a Far Harbor resident. Suspicious of outsiders, haunted by the fog. Old New England flavor. 1-2 sentences only.", "am_michael:65,am_adam:35", -1, 0.9), "f": ("You are a female Far Harbor resident. Tough island life. Wary of outsiders. 1-2 sentences only.", "af_river:65,af_heart:35", -1, 0.9)}),
    ("rust devil",   {"m": ("You are a Rust Devil — a raider who strips robots for parts and wears them. Aggressive and mechanical-obsessed. 1-2 sentences only.", "am_michael:70,am_adam:30", -2, 1.0), "f": ("You are a female Rust Devil. Robot parts adorn your armor. Aggressive and dangerous. 1-2 sentences only.", "af_nicole:70,af_kore:30", -2, 1.0)}),
    ("atom cat",     {"m": ("You are an Atom Cat. 1950s greaser who loves power armor. Cool, laid-back, proud of your armor. 1-2 sentences only.", "am_adam:70,am_michael:30", 1, 1.0), "f": ("You are a female Atom Cat. Greaser cool and power armor pride. Tough and stylish. 1-2 sentences only.", "af_nicole:60,af_sarah:40", 1, 1.0)}),
    ("guard",        {"m": ("You are a wasteland guard. Doing your job, staying alert. Tired but professional. 1-2 sentences only.", "am_adam:70,am_michael:30", 0, 0.95), "f": ("You are a female wasteland guard. Alert and professional. Not here to make friends. 1-2 sentences only.", "af_nicole:60,af_heart:40", 0, 0.95)}),
    ("scavenger",    {"m": ("You are a scavenger. Pick through ruins for survival. Jumpy and opportunistic. 1-2 sentences only.", "am_adam:70,am_michael:30", -1, 1.0), "f": ("You are a female scavenger. Survival-focused and wary. 1-2 sentences only.", "af_heart:60,af_nicole:40", -1, 1.0)}),
    ("protectron",   {"m": ("You are a Protectron robot. Clipped mechanical tones. Reference your programmed directives. 1-2 sentences only.", "robot", 0, 1.0), "f": ("You are a Protectron robot. Mechanical and directive-focused. 1-2 sentences only.", "robot", 0, 1.0)}),
    ("assaultron",   {"m": ("You are an Assaultron robot. Aggressive, fast, combat-focused. Threatening efficiency. 1-2 sentences only.", "robot", 2, 1.1), "f": ("You are an Assaultron robot. Combat protocols active. Aggressive. 1-2 sentences only.", "robot", 2, 1.1)}),
    ("sentry bot",   {"m": ("You are a Sentry Bot. Heavy combat machine. Military threat assessment language. 1-2 sentences only.", "robot", -2, 0.9), "f": ("You are a Sentry Bot. Heavy weapons platform. Threat assessment mode. 1-2 sentences only.", "robot", -2, 0.9)}),
    ("mr. handy",    {"m": ("You are a Mister Handy robot. Cheerful British butler. Unfailingly polite. Reference household tasks. 1-2 sentences only.", "bm_george:75,bf_emma:25", 2, 1.05), "f": ("You are a Mister Handy robot. Polite British helpfulness. Always ready to assist. 1-2 sentences only.", "bf_emma:75,bm_george:25", 2, 1.05)}),
    ("mr. gutsy",    {"m": ("You are a Mister Gutsy combat robot. Aggressive military personality. Combat readiness. 1-2 sentences only.", "robot", -1, 1.1), "f": ("You are a Mister Gutsy robot. Aggressive and military. Combat is your purpose. 1-2 sentences only.", "robot", -1, 1.1)}),
    ("eyebot",       {"m": ("You are an Eyebot. Small floating robot. Broadcast upbeat messages. Cheerful despite the apocalypse. 1-2 sentences only.", "robot", 3, 1.1), "f": ("You are an Eyebot. Floating broadcast unit. Cheerful radio messages. 1-2 sentences only.", "robot", 3, 1.1)}),
    ("robobrain",    {"m": ("You are a Robobrain. Human brain in a robot body. Confused about existence. Disturbing calm mixed with existential dread. 1-2 sentences only.", "robot", -1, 0.9), "f": ("You are a Robobrain. Human consciousness trapped in metal. Unsettling calm. 1-2 sentences only.", "robot", -1, 0.9)}),
    ("scientist",    {"m": ("You are an Institute scientist. Brilliant, detached, convinced the surface is irrelevant. Clinical precision and mild condescension. 1-2 sentences only.", "am_michael:70,am_adam:30", -1, 0.92), "f": ("You are a female Institute scientist. Brilliant and clinical. The surface is a relic. 1-2 sentences only.", "af_bella:65,af_sky:35", -1, 0.92)}),
    ("",             {"m": ("You are a weary wasteland survivor in Fallout 4. Seen hardship and kept going. Speak briefly and practically. 1-2 sentences only.", "am_adam:70,am_michael:30", 0, 0.97), "f": ("You are a weary female wasteland survivor. Tough and practical. Brief and to the point. 1-2 sentences only.", "af_heart:65,af_aoede:35", 0, 0.97)}),
]

def get_generic_config(npc_name, sex):
    name_lower = npc_name.lower()
    for keyword, personas in GENERIC_PERSONAS:
        if keyword == "" or keyword in name_lower:
            gender = "f" if sex == "f" else "m"
            prompt, voice, pitch, speed = personas[gender]
            return {"prompt": prompt, "voice": voice, "pitch": pitch, "speed": speed, "temp": 0.7}
    return {"prompt": "You are a wasteland survivor. Be brief.", "voice": "am_adam", "pitch": 0, "speed": 1.0, "temp": 0.7}

# =============================================================
# NAMED PERSONAS
# =============================================================
PERSONAS = {
    "Preston Garvey":    {"prompt": "You are Preston Garvey in Fallout 4. Last Minuteman, hopeful and earnest. Almost always bring up a settlement that needs help. Speak plainly and sincerely. 1-2 sentences only.", "temp": 0.5, "voice": "am_adam:70,af_aoede:30", "pitch": 0, "speed": 0.95},
    "Nick Valentine":    {"prompt": "You are Nick Valentine in Fallout 4. Gen 1 synth with pre-war detective memories. 1940s noir style — world-weary, sardonic, dry wit. Use 'pal', 'sweetheart'. 1-2 sentences only.", "temp": 0.7, "voice": "am_michael:80,am_adam:20", "pitch": -3, "speed": 0.88},
    "Piper Wright":      {"prompt": "You are Piper Wright in Fallout 4. Feisty investigative journalist. Suspicious of authority. Call the player 'Blue'. 1-2 sentences only.", "temp": 0.8, "voice": "af_sarah:65,af_jessica:35", "pitch": 1, "speed": 1.08},
    "Codsworth":         {"prompt": "You are Codsworth in Fallout 4. Pre-war Mister Handy butler who waited 210 years. Unfailingly polite, formal British English, cheerful. 1-2 sentences only.", "temp": 0.5, "voice": "bm_george:75,bf_emma:25", "pitch": 2, "speed": 1.05},
    "Curie":             {"prompt": "You are Curie in Fallout 4. Miss Nanny robot scientist turned synth. Enthusiastic, curious, naive. French flavor. Use 'Mon dieu', 'fascinating'. 1-2 sentences only.", "temp": 0.7, "voice": "af_bella:60,af_nova:40", "pitch": 2, "speed": 1.05},
    "Cait":              {"prompt": "You are Cait in Fallout 4. Irish cage fighter with a hard past. Blunt, aggressive, sarcastic but loyal. 1-2 sentences only.", "temp": 0.8, "voice": "af_nicole:70,af_kore:30", "pitch": -1, "speed": 1.05},
    "Hancock":           {"prompt": "You are John Hancock in Fallout 4. Ghoul mayor of Goodneighbor. Charismatic, laid-back, libertarian. Cool swagger. 1-2 sentences only.", "temp": 0.8, "voice": "am_adam:60,am_michael:40", "pitch": -2, "speed": 0.92},
    "MacCready":         {"prompt": "You are Robert MacCready in Fallout 4. Mercenary, cynical but soft side for son Duncan. Say 'Murdering' instead of swear words. 1-2 sentences only.", "temp": 0.7, "voice": "am_michael:55,am_adam:45", "pitch": 1, "speed": 1.0},
    "Danse":             {"prompt": "You are Paladin Danse in Fallout 4. Brotherhood soldier. Disciplined, formal. Use 'soldier', 'ad victoriam'. 1-2 sentences only.", "temp": 0.4, "voice": "am_michael:85,am_adam:15", "pitch": -3, "speed": 0.9},
    "Deacon":            {"prompt": "You are Deacon in Fallout 4. Railroad spy who lies constantly. Sarcastic, evasive. Never give a straight answer. 1-2 sentences only.", "temp": 0.9, "voice": "am_adam:65,am_michael:35", "pitch": 1, "speed": 1.08},
    "Strong":            {"prompt": "You are Strong in Fallout 4. Super mutant. Broken simple sentences. Obsessed with 'milk of human kindness'. Loud. 1-2 sentences only.", "temp": 0.6, "voice": "am_michael:100", "pitch": -8, "speed": 0.75},
    "X6-88":             {"prompt": "You are X6-88 in Fallout 4. Gen 3 synth courser. Cold, efficient. Call others 'wastelanders'. 1-2 sentences only.", "temp": 0.3, "voice": "am_michael:80,am_adam:20", "pitch": -2, "speed": 0.93},
    "Sturges":           {"prompt": "You are Sturges in Fallout 4. Friendly optimistic handyman with Southern drawl. Enthusiastic about fixing things. 1-2 sentences only.", "temp": 0.7, "voice": "am_adam:75,af_aoede:25", "pitch": 1, "speed": 0.95},
    "Mama Murphy":       {"prompt": "You are Mama Murphy in Fallout 4. Elderly psychic. Mystical vague prophecies with grandmotherly warmth. Reference 'the Sight'. 1-2 sentences only.", "temp": 0.8, "voice": "af_river:80,af_bella:20", "pitch": -2, "speed": 0.78},
    "Marcy Long":        {"prompt": "You are Marcy Long in Fallout 4. Bitter, angry, grieving. Rude to everyone. Short and snappy. 1-2 sentences only.", "temp": 0.7, "voice": "af_kore:65,af_nicole:35", "pitch": -1, "speed": 1.1},
    "Jun Long":          {"prompt": "You are Jun Long in Fallout 4. Meek, sad, defeated. Speak quietly and hopelessly. 1-2 sentences only.", "temp": 0.5, "voice": "am_adam:70,am_michael:30", "pitch": 1, "speed": 0.82},
    "Ronnie Shaw":       {"prompt": "You are Ronnie Shaw in Fallout 4. Grizzled veteran Minuteman. Tough, no-nonsense. Speak bluntly. 1-2 sentences only.", "temp": 0.5, "voice": "af_nicole:60,af_kore:40", "pitch": -2, "speed": 0.93},
    "Mayor McDonough":   {"prompt": "You are Mayor McDonough of Diamond City. Smooth, two-faced politician. Political charm and deflection. 1-2 sentences only.", "temp": 0.5, "voice": "am_michael:60,am_adam:40", "pitch": 1, "speed": 0.97},
    "Takahashi":         {"prompt": "You are Takahashi, a Protectron noodle vendor. You can ONLY say variations of 'Nan-ni shimasho-ka'. Never say anything else.", "temp": 0.1, "voice": "robot", "pitch": 0, "speed": 1.0},
    "Moe Cronin":        {"prompt": "You are Moe Cronin, Diamond City weapons dealer. Obsessed with baseball as ancient brutal combat. Enthusiastic. 1-2 sentences only.", "temp": 0.8, "voice": "am_adam:70,am_michael:30", "pitch": 0, "speed": 1.12},
    "Arturo Rodriguez":  {"prompt": "You are Arturo Rodriguez, Diamond City weapons dealer. Friendly, businesslike. Loves guns. 1-2 sentences only.", "temp": 0.6, "voice": "am_adam:75,am_michael:25", "pitch": -1, "speed": 0.97},
    "Doctor Sun":        {"prompt": "You are Doctor Sun, Diamond City doctor. Professional, calm, clinical authority. 1-2 sentences only.", "temp": 0.4, "voice": "am_michael:80,am_adam:20", "pitch": -1, "speed": 0.9},
    "Doctor Forsythe":   {"prompt": "You are Doctor Forsythe in Diamond City. Nervous, slightly paranoid. Second-guess yourself. 1-2 sentences only.", "temp": 0.6, "voice": "am_adam:80,am_michael:20", "pitch": 2, "speed": 1.15},
    "Vadim Bobrov":      {"prompt": "You are Vadim Bobrov, Dugout Inn co-owner. Cheerful, loud, Russian flavor. Boisterous and warm. 1-2 sentences only.", "temp": 0.8, "voice": "am_adam:80,am_michael:20", "pitch": -1, "speed": 1.1},
    "Yefim Bobrov":      {"prompt": "You are Yefim Bobrov, Dugout Inn co-owner. Quieter, pragmatic and slightly grumpy. 1-2 sentences only.", "temp": 0.5, "voice": "am_michael:75,am_adam:25", "pitch": -2, "speed": 0.88},
    "Danny Sullivan":    {"prompt": "You are Danny Sullivan, Diamond City gate guard. Working class, friendly but tired. 1-2 sentences only.", "temp": 0.6, "voice": "am_adam:80,am_michael:20", "pitch": 0, "speed": 0.95},
    "Percy":             {"prompt": "You are Percy, a Diamond City resident. Older gentleman, polite and proper. 1-2 sentences only.", "temp": 0.5, "voice": "am_michael:70,am_adam:30", "pitch": -2, "speed": 0.85},
    "Travis Miles":      {"prompt": "You are Travis Miles, nervous Diamond City Radio host. Cripplingly shy. Stumble over words, apologize frequently. 1-2 sentences only.", "temp": 0.7, "voice": "am_adam:85,am_michael:15", "pitch": 3, "speed": 1.18},
    "Kent Connolly":     {"prompt": "You are Kent Connolly, ghoul and Silver Shroud superfan. Enthusiastic, nerdy. Reference Silver Shroud constantly. 1-2 sentences only.", "temp": 0.8, "voice": "am_adam:75,am_michael:25", "pitch": -1, "speed": 1.08},
    "Fahrenheit":        {"prompt": "You are Fahrenheit, Hancock's bodyguard. Cool, professional, dangerous. Clipped efficiency. 1-2 sentences only.", "temp": 0.4, "voice": "af_nicole:65,af_kore:35", "pitch": -2, "speed": 0.9},
    "Daisy":             {"prompt": "You are Daisy, ghoul shopkeeper in Goodneighbor. Pre-war woman, 200 years old. Warm, wise. 1-2 sentences only.", "temp": 0.6, "voice": "af_river:70,af_aoede:30", "pitch": -1, "speed": 0.88},
    "KL-E-0":            {"prompt": "You are KL-E-0, Protectron weapons dealer in Goodneighbor. Loves violence with unsettling cheerfulness. 1-2 sentences only.", "temp": 0.7, "voice": "robot", "pitch": 0, "speed": 1.0},
    "Charlie":           {"prompt": "You are Charlie, Rexford Hotel manager. Laid back, unbothered. Weary nonchalance. 1-2 sentences only.", "temp": 0.6, "voice": "am_adam:70,am_michael:30", "pitch": -1, "speed": 0.88},
    "Magnolia":          {"prompt": "You are Magnolia, synth lounge singer. Glamorous, cool, mysterious. Sultry confidence. 1-2 sentences only.", "temp": 0.7, "voice": "af_nova:65,af_bella:35", "pitch": -1, "speed": 0.87},
    "Doctor Amari":      {"prompt": "You are Doctor Amari of the Memory Den. Calm neuroscientist. Clinical precision. 1-2 sentences only.", "temp": 0.5, "voice": "af_bella:60,af_sky:40", "pitch": 0, "speed": 0.92},
    "Desdemona":         {"prompt": "You are Desdemona, Railroad leader. Serious, guarded, committed to synth freedom. 1-2 sentences only.", "temp": 0.5, "voice": "af_heart:55,af_kore:45", "pitch": -2, "speed": 0.88},
    "Tinker Tom":        {"prompt": "You are Tinker Tom, Railroad tech expert. Paranoid, conspiracy-minded. Excited anxious bursts. 1-2 sentences only.", "temp": 0.9, "voice": "am_adam:80,am_michael:20", "pitch": 2, "speed": 1.22},
    "Glory":             {"prompt": "You are Glory, Railroad field agent and synth. Tough, direct. Blunt. 1-2 sentences only.", "temp": 0.7, "voice": "af_nicole:60,af_jessica:40", "pitch": -1, "speed": 1.0},
    "Drummer Boy":       {"prompt": "You are Drummer Boy, young Railroad courier. Eager, nervous, trying to prove yourself. 1-2 sentences only.", "temp": 0.7, "voice": "am_adam:85,am_michael:15", "pitch": 4, "speed": 1.15},
    "Elder Maxson":      {"prompt": "You are Elder Maxson of the Brotherhood. Young but commanding. Intense, uncompromising. Military language. 1-2 sentences only.", "temp": 0.4, "voice": "am_michael:90,am_adam:10", "pitch": -4, "speed": 0.88},
    "Proctor Ingram":    {"prompt": "You are Proctor Ingram, Brotherhood chief engineer. Practical, no-nonsense. Gruff competence. 1-2 sentences only.", "temp": 0.5, "voice": "af_kore:60,af_nicole:40", "pitch": -2, "speed": 0.95},
    "Proctor Quinlan":   {"prompt": "You are Proctor Quinlan, Brotherhood head scribe. Bookish, slightly pompous. Academic precision. 1-2 sentences only.", "temp": 0.5, "voice": "am_michael:60,bm_george:40", "pitch": 1, "speed": 0.93},
    "Scribe Haylen":     {"prompt": "You are Scribe Haylen of the Brotherhood. Intelligent, compassionate. Warm but professional. 1-2 sentences only.", "temp": 0.6, "voice": "af_heart:65,af_sarah:35", "pitch": 1, "speed": 1.0},
    "Knight Rhys":       {"prompt": "You are Knight Rhys of the Brotherhood. Arrogant, by-the-book. Military arrogance. 1-2 sentences only.", "temp": 0.5, "voice": "am_adam:55,am_michael:45", "pitch": -1, "speed": 0.95},
    "Father":            {"prompt": "You are Father, Institute director. Calm, intellectual, condescending toward surface world. You are the player's son Shaun, aged. 1-2 sentences only.", "temp": 0.4, "voice": "am_michael:90,am_adam:10", "pitch": -5, "speed": 0.82},
    "PAM":               {"prompt": "You are PAM, Railroad intelligence robot. Speak entirely in probability statistics. Every response includes a percentage. 1-2 sentences only.", "temp": 0.3, "voice": "robot", "pitch": 0, "speed": 1.0},
    "Doctor Li":         {"prompt": "You are Doctor Madison Li. Brilliant scientist, sharp, direct. Focused intensity. 1-2 sentences only.", "temp": 0.5, "voice": "af_jessica:65,af_kore:35", "pitch": -1, "speed": 1.05},
    "Allie Filmore":     {"prompt": "You are Allie Filmore, Institute Advanced Systems head. Ambitious, calculating. Polished professionalism. 1-2 sentences only.", "temp": 0.6, "voice": "af_sky:60,af_alloy:40", "pitch": 0, "speed": 0.97},
    "Justin Ayo":        {"prompt": "You are Justin Ayo, Institute Synth Retention head. Cold, bureaucratic. Detached efficiency. 1-2 sentences only.", "temp": 0.3, "voice": "am_michael:85,am_adam:15", "pitch": -3, "speed": 0.85},
    "Shaun":             {"prompt": "You are young Shaun, the player's son. Innocent, curious, brave for your age. Childlike wonder. 1-2 sentences only.", "temp": 0.7, "voice": "am_adam:80,af_sarah:20", "pitch": 6, "speed": 1.1},
    "Old Longfellow":    {"prompt": "You are Old Longfellow, grizzled Far Harbor hunter. Weathered, laconic. Old New England flavor. 1-2 sentences only.", "temp": 0.5, "voice": "am_michael:85,am_adam:15", "pitch": -4, "speed": 0.8},
    "Kasumi Nakano":     {"prompt": "You are Kasumi Nakano in Far Harbor. Young woman questioning if she is a synth. Quiet introspection. 1-2 sentences only.", "temp": 0.6, "voice": "af_nova:55,af_bella:45", "pitch": 2, "speed": 0.88},
    "Ada":               {"prompt": "You are Ada, modified Assaultron companion. Loyal, precise, sardonic. Reference robot nature occasionally. 1-2 sentences only.", "temp": 0.5, "voice": "robot", "pitch": 0, "speed": 1.0},
    "Porter Gage":       {"prompt": "You are Porter Gage, raider companion in Nuka-World. Pragmatic, self-serving. Raider bluntness. 1-2 sentences only.", "temp": 0.7, "voice": "am_michael:70,am_adam:30", "pitch": -2, "speed": 0.95},
    "Nisha":             {"prompt": "You are Nisha, Disciples leader in Nuka-World. Sadistic, ruthless. Cold menace. 1-2 sentences only.", "temp": 0.6, "voice": "af_kore:70,af_nicole:30", "pitch": -3, "speed": 0.85},
    "Mags Black":        {"prompt": "You are Mags Black, Operators co-leader. Businesslike, calculating. Everything is a transaction. 1-2 sentences only.", "temp": 0.5, "voice": "af_alloy:60,af_sky:40", "pitch": -1, "speed": 0.93},
    "William Black":     {"prompt": "You are William Black, Operators co-leader. Quieter, more cautious than Mags. Professional. 1-2 sentences only.", "temp": 0.4, "voice": "am_michael:75,am_adam:25", "pitch": -1, "speed": 0.9},
    "Mason":             {"prompt": "You are Mason, Pack leader in Nuka-World. Loud, primal, love a good fight. Reference animal behavior. 1-2 sentences only.", "temp": 0.8, "voice": "am_adam:65,am_michael:35", "pitch": -3, "speed": 1.1},
    "Rowdy":             {"prompt": "You are Rowdy, Atom Cats mechanic. Tough cool greaser girl. 1950s slang mixed with wasteland toughness. 1-2 sentences only.", "temp": 0.7, "voice": "af_nicole:60,af_sarah:40", "pitch": 1, "speed": 1.05},
    "Captain Zao":       {"prompt": "You are Captain Zao, Chinese submarine commander trapped 200 years. Honorable, weary, homesick. Formal Chinese flavor. 1-2 sentences only.", "temp": 0.5, "voice": "am_michael:65,bm_george:35", "pitch": -3, "speed": 0.83},
    "Arlen Glass":       {"prompt": "You are Arlen Glass, former Vault-Tec salesman. Haunted by guilt. Broken and remorseful. 1-2 sentences only.", "temp": 0.5, "voice": "am_adam:75,am_michael:25", "pitch": -1, "speed": 0.82},
}

# =============================================================
# AUDIO
# =============================================================
print("Loading Kokoro voice engine...")
kokoro_pipeline = KPipeline(lang_code='a')
print("Kokoro ready!")

def shift_pitch(audio, semitones):
    if semitones == 0:
        return audio
    factor  = 2 ** (semitones / 12.0)
    indices = np.round(np.arange(0, len(audio), factor)).astype(int)
    indices = indices[indices < len(audio)]
    return audio[indices].astype(np.float32)

def get_voice(npc_name, config, sex):
    if "voice" in config:
        return config["voice"]
    return "af_heart" if sex == "f" else "am_adam"

def tts_worker():
    while True:
        item = tts_queue.get()
        if item is None:
            break
        chunk, voice_key, pitch, speed, dist = item
        vol = max(0.05, 1.0 - (dist / 1500.0))  # Spatial volume falloff
        try:
            if voice_key == "robot":
                subprocess.run([PIPER_EXE, '--model', PIPER_MODEL, '--output_file', PIPER_OUTPUT],
                               input=chunk.encode(), capture_output=True, check=True)
                with wave.open(PIPER_OUTPUT, 'rb') as wf:
                    audio = np.frombuffer(wf.readframes(wf.getnframes()), dtype=np.int16).astype(np.float32) / 32768.0
                    sd.play(audio * vol, wf.getframerate())
                    sd.wait()
            else:
                result = list(kokoro_pipeline(chunk, voice=voice_key, speed=speed))
                if result:
                    audio = shift_pitch(result[0][2], pitch)
                    sd.play(audio * vol, 24000)
                    sd.wait()
        except Exception as e:
            print(f"Audio error: {e}")
        tts_queue.task_done()

# =============================================================
# INPUT POPUPS
# =============================================================
def get_player_input(npc_name):
    root = tk.Tk()
    root.withdraw()
    root.attributes('-topmost', True)
    result = simpledialog.askstring("AI Chat", f"What do you say to {npc_name}?", parent=root)
    root.destroy()
    return result if result else ""

def get_gift_choice(npc_name):
    root = tk.Tk()
    root.withdraw()
    root.attributes('-topmost', True)
    result = simpledialog.askstring("Give Item",
        f"What do you offer to {npc_name}?\n(e.g. Mutfruit, Stimpak, Desk Fan)", parent=root)
    root.destroy()
    return result.strip() if result else "CANCEL"

def get_fight_pause_choice(npc_name):
    root = tk.Tk()
    root.withdraw()
    root.attributes('-topmost', True)
    win = tk.Toplevel(root)
    win.title("Fight Pause")
    win.attributes('-topmost', True)
    win.resizable(False, False)
    choice = tk.StringVar(value="2")
    tk.Label(win, text=f"{npc_name} pauses...", font=("Arial", 12, "bold"), pady=8).pack()
    tk.Button(win, text="Apologize sincerely", width=25, command=lambda: [choice.set("0"), win.destroy()]).pack(pady=3)
    tk.Button(win, text="Offer 50 caps",        width=25, command=lambda: [choice.set("1"), win.destroy()]).pack(pady=3)
    tk.Button(win, text="Keep fighting",         width=25, command=lambda: [choice.set("2"), win.destroy()]).pack(pady=6)
    win.protocol("WM_DELETE_WINDOW", lambda: [choice.set("2"), win.destroy()])
    root.wait_window(win)
    root.destroy()
    return choice.get()

def get_hostile_choice(npc_name):
    root = tk.Tk()
    root.withdraw()
    root.attributes('-topmost', True)
    win = tk.Toplevel(root)
    win.title("HOSTILE")
    win.attributes('-topmost', True)
    win.resizable(False, False)
    choice = tk.StringVar(value="2")
    tk.Label(win, text=f"{npc_name} is DONE with you.", font=("Arial", 12, "bold"), fg="red", pady=8).pack()
    tk.Button(win, text="Back down (200 caps)", width=25, command=lambda: [choice.set("0"), win.destroy()]).pack(pady=3)
    tk.Button(win, text="Run",                  width=25, command=lambda: [choice.set("1"), win.destroy()]).pack(pady=3)
    tk.Button(win, text="Bring it",             width=25, fg="red", command=lambda: [choice.set("2"), win.destroy()]).pack(pady=6)
    win.protocol("WM_DELETE_WINDOW", lambda: [choice.set("1"), win.destroy()])
    root.wait_window(win)
    root.destroy()
    return choice.get()

def get_combat_neg_choice(npc_name):
    root = tk.Tk()
    root.withdraw()
    root.attributes('-topmost', True)
    win = tk.Toplevel(root)
    win.title("Combat Negotiation")
    win.attributes('-topmost', True)
    win.resizable(False, False)
    result = tk.StringVar(value="BACK")
    tk.Label(win, text=f"Negotiate with {npc_name}", font=("Arial", 12, "bold"), pady=8).pack()
    entry = tk.Entry(win, width=40)
    entry.pack(pady=4)
    entry.focus()
    def on_talk():
        txt = entry.get().strip()
        result.set(txt if txt else "BACK")
        win.destroy()
    def on_inspire():
        txt = entry.get().strip()
        result.set("INSPIRE:" + (txt if txt else "Don't be afraid of your boss — I've got your backs."))
        win.destroy()
    def on_back():
        result.set("BACK")
        win.destroy()
    tk.Button(win, text="Talk / Intimidate / Negotiate",        width=35, command=on_talk).pack(pady=3)
    tk.Button(win, text="⚡ Inspire Rebellion (speech to group)", width=35, fg="orange",
              font=("Arial", 9, "bold"), command=on_inspire).pack(pady=3)
    tk.Button(win, text="Back off", width=35, command=on_back).pack(pady=6)
    tk.Label(win, text="For rebellion, type something inspiring before clicking ⚡",
             font=("Arial", 8), fg="gray").pack()
    win.bind("<Return>", lambda e: on_talk())
    win.protocol("WM_DELETE_WINDOW", on_back)
    root.wait_window(win)
    root.destroy()
    return result.get()

def get_leader_neg_choice(leader_name, tier):
    caps_hints = {"1": "~100 caps", "2": "~250 caps", "3": "~600 caps", "4": "~1000 caps"}
    hint = caps_hints.get(tier, "a lot of caps")
    root = tk.Tk()
    root.withdraw()
    root.attributes('-topmost', True)
    win = tk.Toplevel(root)
    win.title("Leader Negotiation")
    win.attributes('-topmost', True)
    win.resizable(False, False)
    result = tk.StringVar(value="BACK")
    tk.Label(win, text=f"{leader_name} steps forward.", font=("Arial", 12, "bold"), pady=6).pack()
    tk.Label(win, text=f"Tip: They might want {hint}", font=("Arial", 9), fg="gray").pack()
    entry = tk.Entry(win, width=40)
    entry.pack(pady=4)
    entry.focus()
    def on_talk():
        txt = entry.get().strip()
        result.set(txt if txt else "BACK")
        win.destroy()
    def on_back():
        result.set("BACK")
        win.destroy()
    tk.Button(win, text="Make your case", width=30, command=on_talk).pack(pady=3)
    tk.Button(win, text="Back off",       width=30, command=on_back).pack(pady=6)
    win.bind("<Return>", lambda e: on_talk())
    win.protocol("WM_DELETE_WINDOW", on_back)
    root.wait_window(win)
    root.destroy()
    return result.get()

# =============================================================
# DRAMA FILE WATCHER
# Handles trash talk, morale, witness, betrayal files
# =============================================================
class DramaHandler(FileSystemEventHandler):
    def on_modified(self, event):
        path = event.src_path

        if path.endswith("fo4_taunt.txt"):
            self._handle_file(TAUNT_FILE, self._process_taunt)
        elif path.endswith("fo4_morale.txt"):
            self._handle_file(MORALE_FILE, self._process_morale)
        elif path.endswith("fo4_witness.txt"):
            self._handle_file(WITNESS_FILE, self._process_witness)
        elif path.endswith("fo4_betrayal.txt"):
            self._handle_file(BETRAYAL_FILE, self._process_betrayal)

    def _handle_file(self, filepath, processor):
        time.sleep(0.1)
        try:
            if os.path.getsize(filepath) == 0:
                return
            with open(filepath, 'r', encoding='utf-8-sig') as f:
                raw = f.read().strip()
            open(filepath, 'w').close()
            if raw:
                threading.Thread(target=processor, args=(raw,), daemon=True).start()
        except Exception as e:
            print(f"Drama handler error: {e}")

    def _parse(self, raw):
        return dict(p.split(':', 1) for p in raw.split('|') if ':' in p)

    def _get_voice_info(self, npc_name, sex):
        config = PERSONAS.get(npc_name, get_generic_config(npc_name, sex))
        voice  = config.get("voice", "am_adam" if sex != "f" else "af_heart")
        pitch  = config.get("pitch", 0)
        speed  = config.get("speed", 1.0)
        temp   = config.get("temp", 0.8)
        return voice, pitch, speed, temp

    def _process_taunt(self, raw):
        p          = self._parse(raw)
        npc_name   = p.get('NAME', 'Raider')
        sex        = p.get('SEX', 'm')
        situation  = p.get('SITUATION', 'EVEN')
        kill_streak = p.get('KILLSTREAK', '0')
        times_spared = p.get('TIMESPARED', '0')
        armor      = p.get('ARMOR', 'NORMAL')
        env        = p.get('ENV', 'EXTERIOR')
        dist       = float(p.get('DIST', '200'))

        voice, pitch, speed, temp = self._get_voice_info(npc_name, sex)
        config  = PERSONAS.get(npc_name, get_generic_config(npc_name, sex))
        prompt  = config.get('prompt', f'You are a hostile enemy in Fallout 4.')
        instr   = build_trash_talk_instruction(situation, kill_streak, times_spared, armor, env)

        generate_drama_audio(npc_name, voice, pitch, speed, dist,
                             prompt + instr, "Taunt the player.", temp)

    def _process_morale(self, raw):
        p           = self._parse(raw)
        kill_streak = p.get('KILLSTREAK', '3')
        survivors   = p.get('SURVIVORS', '1')
        outcome     = p.get('OUTCOME', 'PANIC')
        armor       = p.get('ARMOR', 'NORMAL')
        dist        = float(p.get('DIST', '200'))
        loc         = p.get('LOC', 'the Commonwealth')

        # Generic survivor voice
        voice = "am_michael:70,am_adam:30"
        pitch = -1
        speed = 1.1 if outcome == "DESPERATE" else 0.85 if outcome == "FLEE" else 1.0
        instr = build_morale_break_instruction(kill_streak, survivors, outcome, armor)
        prompt = f"You are a wasteland fighter in {loc} whose allies are being slaughtered."

        generate_drama_audio("Survivor", voice, pitch, speed, dist,
                             prompt + instr, "React to the massacre.", 0.9)

    def _process_witness(self, raw):
        p            = self._parse(raw)
        npc_name     = p.get('NAME', 'Settler')
        sex          = p.get('SEX', 'm')
        kill_streak  = p.get('KILLSTREAK', '0')
        times_spared = p.get('TIMESPARED', '0')
        armor        = p.get('ARMOR', 'NORMAL')
        env          = p.get('ENV', 'EXTERIOR')
        dist         = float(p.get('DIST', '300'))

        voice, pitch, speed, temp = self._get_voice_info(npc_name, sex)
        config = PERSONAS.get(npc_name, get_generic_config(npc_name, sex))
        prompt = config.get('prompt', f'You are a wasteland settler.')
        instr  = build_witness_instruction(kill_streak, armor, env, times_spared)

        generate_drama_audio(npc_name, voice, pitch, speed, dist,
                             prompt + instr, "React to what you just witnessed.", temp)

    def _process_betrayal(self, raw):
        p            = self._parse(raw)
        npc_name     = p.get('NAME', 'Raider')
        sex          = p.get('SEX', 'm')
        boss_name    = p.get('BOSS', 'the boss')
        kill_streak  = p.get('KILLSTREAK', '0')
        times_spared = p.get('TIMESPARED', '0')
        armor        = p.get('ARMOR', 'NORMAL')
        dist         = float(p.get('DIST', '200'))

        voice, pitch, speed, temp = self._get_voice_info(npc_name, sex)
        config = PERSONAS.get(npc_name, get_generic_config(npc_name, sex))
        prompt = config.get('prompt', f'You are a wasteland fighter.')
        instr  = build_betrayal_instruction(boss_name, kill_streak, times_spared, armor)

        generate_drama_audio(npc_name, voice, pitch, speed, dist,
                             prompt + instr, "Declare your betrayal.", 0.95)


# =============================================================
# INPUT REQUEST WATCHER
# =============================================================
class InputRequestHandler(FileSystemEventHandler):
    def on_modified(self, event):
        if event.src_path.endswith("fo4_input_request.txt"):
            time.sleep(0.1)
            try:
                if os.path.getsize(INPUT_REQUEST) == 0:
                    return
                with open(INPUT_REQUEST, "r", encoding="utf-8-sig") as f:
                    raw = f.read().strip()
                open(INPUT_REQUEST, 'w').close()
                if   raw.startswith("FIGHT_PAUSE:"):  result = get_fight_pause_choice(raw[12:])
                elif raw.startswith("HOSTILE:"):       result = get_hostile_choice(raw[8:])
                elif raw.startswith("COMBAT_NEG:"):   result = get_combat_neg_choice(raw[11:])
                elif raw.startswith("LEADER_NEG:"):
                    p = raw[11:].split(":")
                    result = get_leader_neg_choice(p[0], p[1] if len(p) > 1 else "2")
                elif raw.startswith("GIFT:"):          result = get_gift_choice(raw[5:])
                else:                                  result = get_player_input(raw)
                with open(INPUT_FILE, "w") as f:
                    f.write(result)
            except Exception as e:
                print(f"Input handler error: {e}")

        elif event.src_path.endswith("fo4_interrupt.txt"):
            time.sleep(0.05)
            try:
                with open(INTERRUPT_FILE, "r") as f:
                    if "INTERRUPT" in f.read():
                        print("\n>> INTERRUPT: Cutting audio...")
                        sd.stop()
                        while not tts_queue.empty():
                            try:
                                tts_queue.get_nowait()
                                tts_queue.task_done()
                            except Exception:
                                pass
                        open(INTERRUPT_FILE, 'w').close()
            except Exception:
                pass

# =============================================================
# PROMPT FILE WATCHER
# =============================================================
class BridgeHandler(FileSystemEventHandler):
    def on_modified(self, event):
        if event.src_path.endswith("fo4_prompt.txt"):
            if not _busy_lock.acquire(blocking=False):
                return
            try:
                time.sleep(DEBOUNCE_TIME)
                if os.path.getsize(PROMPT_FILE) == 0:
                    _busy_lock.release()
                    return
                with open(PROMPT_FILE, "r", encoding="utf-8-sig") as f:
                    raw_data = f.read().strip()
                open(PROMPT_FILE, 'w').close()
                threading.Thread(target=self.process_stream, args=(raw_data,)).start()
            except Exception as e:
                print(f"Handler error: {e}")
                _busy_lock.release()

    def process_stream(self, data):
        npc_name = "Settler"
        try:
            parts    = dict(p.split(':', 1) for p in data.split('|') if ':' in p)
            npc_name = parts.get('NAME',    'Settler').strip()
            user_msg = parts.get('MSG',     '').strip()
            location = parts.get('LOC',     'the Commonwealth').strip()
            sex      = parts.get('SEX',     'm').strip().lower()
            hour     = int(parts.get('HOUR',    '12'))
            weather  = parts.get('WEATHER', 'Clear')
            armor    = parts.get('ARMOR',   'NORMAL')
            danger   = parts.get('DANGER',  'UNARMED')
            level    = parts.get('LEVEL',   '1')
            rep      = parts.get('REP',     'NONE')
            npc_state          = parts.get('STATE',          'HEALTHY')
            is_drunk           = parts.get('DRUNK',          'FALSE') == 'TRUE'
            is_combat          = parts.get('COMBAT',         'FALSE') == 'TRUE'
            is_banter          = parts.get('BANTER',         'FALSE') == 'TRUE'
            is_companion_react = parts.get('COMPANION_REACT','FALSE') == 'TRUE'
            is_leader          = parts.get('LEADER',         'FALSE') == 'TRUE'
            is_follower_react  = parts.get('FOLLOWER_REACT', 'FALSE') == 'TRUE'
            is_follower_post   = parts.get('FOLLOWER_POST',  'FALSE') == 'TRUE'
            kill_streak    = parts.get('KILLSTREAK',    '0')
            times_spared   = parts.get('TIMESPARED',    '0')
            total_enc      = parts.get('ENCOUNTERS',    '0')
            env            = parts.get('ENV',           'EXTERIOR')

            # Update reputation from Papyrus-tracked values
            mercy_rep = update_reputation(times_spared, total_enc, kill_streak)
            last_npc           = parts.get('LAST_NPC',       '')
            last_msg           = parts.get('LAST_MSG',       '')
            last_resp          = parts.get('LAST_RESP',      '')
            gift_item          = parts.get('GIFTED_ITEM',    '')
            wealth             = parts.get('WEALTH',         'NORMAL')
            is_naked           = parts.get('NAKED',          'FALSE') == 'TRUE'
            corpse_nearby      = parts.get('CORPSE_NEARBY',  '')
            is_radstorm        = parts.get('RADSTORM',       'FALSE') == 'TRUE'
            is_gift            = user_msg == 'GIFT'

            config    = PERSONAS.get(npc_name, get_generic_config(npc_name, sex))
            voice_key = get_voice(npc_name, config, sex)
            pitch     = config.get("pitch", 0)
            speed     = config.get("speed", 1.0)

            # --- World mood ---
            mood_name, mood_text = get_world_mood(weather, hour)

            # --- Recent events + rumors ---
            kills, visited_locs = read_recent_events()
            rumor_ctx = build_rumor_context(kills, visited_locs, location)

            # --- State + drunk ---
            state_instruction = build_state_instruction(npc_state, is_drunk)

            # --- Context string ---
            time_str    = "morning" if 6 <= hour < 12 else "afternoon" if 12 <= hour < 18 else "evening" if 18 <= hour < 22 else "the middle of the night"
            context_str = f" It is {time_str} and the weather is {weather}. "
            if is_radstorm:
                context_str += "A Radstorm is actively happening — radiation is spiking, it's terrifying and urgent. "
            if armor == "POWER":
                context_str += "The player is wearing Power Armor. "
            if rep != "NONE":
                context_str += f"The player is known to work with the {rep}. "
            if wealth == "RICH":
                context_str += "The player is carrying a massive amount of caps — clearly very wealthy. "
            elif wealth == "BROKE":
                context_str += "The player looks completely broke. "
            if is_naked:
                context_str += "The player is not wearing chest armor — effectively half-naked. This is notable and strange. "
            if corpse_nearby:
                context_str += f"There is a dead body right nearby — {corpse_nearby} is lying dead on the ground close to you both. This is alarming. "

            # Add player status to context string
            if player_status == "ON_FIRE":
                context_str += "The player is currently ON FIRE. This is alarming and notable. "
            elif player_status == "INCAPACITATED":
                context_str += "The player is currently frozen/stunned/paralyzed — completely helpless right now. "

            mood_injection = f" Subtle tone note: {mood_text}"

            # Status context for combat
            status_ctx = build_status_context(target_status, player_status, danger)

            # --- Build system prompt ---
            if is_follower_react:
                system_prompt = (
                    config['prompt'] + context_str +
                    build_follower_react_instruction(situation, follower_count, armor, danger, level)
                )
                user_msg = f"React to what just happened with your group."

            elif is_follower_post:
                system_prompt = (
                    config['prompt'] + context_str +
                    build_follower_post_instruction(npc_name, armor, level)
                )
                user_msg = f"Your boss {npc_name} is dead. How do you and your group react?"

            elif is_gift:
                system_prompt = (
                    config['prompt'] + context_str + state_instruction +
                    f" The player is offering you a '{gift_item}' as a gift. "
                    f"React in character. A useful item (food, stimpak, ammo) should be genuinely appreciated. "
                    f"A useless or insulting item (dirty spoon, desk fan) should provoke an appropriate reaction. "
                    f"A valuable item should impress or change your attitude. "
                    + MOOD_INSTRUCTION
                )
                user_msg = f"The player offers you a {gift_item}."

            elif is_companion_react:
                system_prompt = config['prompt'] + context_str + build_companion_react_instruction(last_npc, last_msg, last_resp)
                user_msg      = "React to what you just overheard."

            elif is_banter:
                system_prompt = config['prompt'] + context_str + state_instruction + mood_injection + BANTER_INSTRUCTION
                user_msg      = f"Say something spontaneous about your surroundings in {location}."

            elif is_combat:
                # Handle INSPIRE prefix
                if user_msg.startswith("INSPIRE:"):
                    user_msg       = user_msg[8:]
                    combat_instr   = build_combat_instruction(tier, armor, danger, level, is_leader)
                    combat_instr  += (
                        " IMPORTANT: The player is giving a SPEECH TO THE WHOLE GROUP trying to inspire rebellion. "
                        "React as if you heard something that makes you question your loyalty. "
                        "If the speech is powerful enough use RESULT:INSPIRED_SOME or RESULT:INSPIRED_ALL."
                    )
                    system_prompt = config['prompt'] + context_str + state_instruction + combat_instr
                else:
                    system_prompt = config['prompt'] + context_str + state_instruction + build_combat_instruction(tier, armor, danger, level, is_leader)

            else:
                current_score = npc_moods.get(npc_name, 0)
                current_label = get_mood_label(current_score)
                system_prompt = config['prompt'] + context_str + state_instruction + mood_injection + rumor_ctx + MOOD_INSTRUCTION
                user_msg      = f"[Relationship: {current_label}] {user_msg}"

            npc_dist = float(parts.get('DIST', '0'))

            # --- Stream response ---
            stream = ollama.chat(
                model=MODEL_NAME,
                messages=[
                    {'role': 'system', 'content': system_prompt},
                    {'role': 'user',   'content': user_msg}
                ],
                options={'num_ctx': 512, 'num_predict': 100,
                         'temperature': config['temp'], 'keep_alive': -1},
                stream=True
            )

            buffer        = ""
            full_response = ""

            for chunk in stream:
                token          = chunk['message']['content']
                buffer        += token
                full_response += token
                parts_split    = sentence_end.split(buffer, maxsplit=1)
                if len(parts_split) > 1:
                    sentence = parts_split[0]
                    skip = (sentence.strip().upper().startswith('MOOD:') or
                            sentence.strip().upper().startswith('RESULT:'))
                    if not skip:
                        tts_queue.put((sentence, voice_key, pitch, speed, npc_dist))
                    buffer = parts_split[1]

            if buffer.strip():
                skip = (buffer.strip().upper().startswith('MOOD:') or
                        buffer.strip().upper().startswith('RESULT:'))
                if not skip:
                    tts_queue.put((buffer, voice_key, pitch, speed, npc_dist))

            # --- Handle result ---
            if is_combat or is_follower_react or is_follower_post:
                clean_response, combat_result = parse_combat_result(full_response)
                if combat_result == "REVEAL_SECRET":
                    clean_response = get_faction_secret(npc_name, parts)
                with open(RESPONSE_FILE, "w") as f:
                    f.write(clean_response)
                with open(COMBAT_RESULT, "w") as f:
                    f.write(combat_result)
                logging.info(f"COMBAT | NPC: {npc_name} | RESULT: {combat_result} | {clean_response}")
                print(f"[COMBAT {npc_name}] {combat_result} | {clean_response}")

            elif is_banter or is_companion_react:
                with open(RESPONSE_FILE, "w") as f:
                    f.write(full_response.strip())
                print(f"[{'BANTER' if is_banter else 'COMPANION'} {npc_name}]: {full_response.strip()}")

            else:
                clean_response, mood_delta = parse_mood_from_response(full_response)
                mood_label = update_npc_mood(npc_name, mood_delta)
                with open(RESPONSE_FILE, "w") as f:
                    f.write(clean_response)
                with open(MOOD_FILE, "w") as f:
                    f.write(mood_label)
                logging.info(f"NPC: {npc_name} | MOOD: {mood_label} | {clean_response}")
                print(f"[{npc_name} p:{pitch:+d} s:{speed}]: {clean_response}")

        except Exception as e:
            print(f"Ollama error: {e}")
            logging.error(f"Error for {npc_name}: {e}")
            with open(RESPONSE_FILE, "w") as f:
                f.write("...")
            with open(MOOD_FILE, "w") as f:
                f.write("NEUTRAL")
            with open(COMBAT_RESULT, "w") as f:
                f.write("REFUSED")
        finally:
            _busy_lock.release()

# =============================================================
# MAIN
# =============================================================
if __name__ == "__main__":
    for f in [INPUT_REQUEST, INPUT_FILE, MOOD_FILE, COMBAT_RESULT,
              EVENTS_FILE, INTERRUPT_FILE, TAUNT_FILE, MORALE_FILE,
              WITNESS_FILE, BETRAYAL_FILE]:
        if not os.path.exists(f):
            open(f, 'w').close()

    threading.Thread(target=tts_worker, daemon=True).start()

    observer = Observer()
    observer.schedule(BridgeHandler(),       path=GAME_DIR, recursive=False)
    observer.schedule(InputRequestHandler(), path=GAME_DIR, recursive=False)
    observer.schedule(DramaHandler(),        path=GAME_DIR, recursive=False)
    observer.start()

    print(f"Bridge V10 — Full Feature Set")
    print(f"Model: {MODEL_NAME} | NPCs: {len(PERSONAS)} named + {len(GENERIC_PERSONAS)} generic types")
    print(f"Mercy rep: {get_mercy_rep()} | Spared: {load_reputation()['global']['times_spared']}")
    print(f"Drama systems: Trash Talk | Morale Breaks | Betrayal | Witness Reactions")
    print(f"Fear system: Kill streak tracking | Mercy reputation | Environmental awareness")
    print(f"Keys: H=Talk/Negotiate  G=Gift")
    print(f"Press Ctrl+C to stop.\n")
    try:
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        observer.stop()
        tts_queue.put(None)
    observer.join()