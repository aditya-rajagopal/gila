const log = std.log.scoped(.gila);

const secret_seed: [std.Random.ChaCha.secret_seed_length]u8 = "gila_m0nster_v3n0m_s3cr3t_k3y_9z".*;

var gen: std.Random.ChaCha = undefined;
var initialized: bool = false;

pub fn new(gpa: std.mem.Allocator) ![]u8 {
    if (!initialized) {
        gen = std.Random.ChaCha.init(secret_seed);
        initialized = true;
    }
    const now = std.time.Instant.now() catch unreachable;
    const entropy: []const u8 = std.mem.asBytes(&now);
    gen.addEntropy(entropy);
    var rng = gen.random();
    const random_number = rng.int(u32);
    return std.fmt.allocPrint(gpa, "{s}_{s}_{s}", .{
        adjectives[random_number & 0x3FF],
        species_names[(random_number >> 10) & 0x7F],
        encodeBase32(@truncate(random_number >> 17))[0..],
    });
}

pub fn isValid(id: []const u8) bool {
    const num_underscores = std.mem.count(u8, id, "_");
    if (num_underscores != 2) {
        log.err("Expected task_id of the form word_word_ccc. Found '{s}' with only {d} underscores", .{ id, num_underscores });
        return false;
    }
    const last_underscore = std.mem.lastIndexOfScalar(u8, id, '_') orelse unreachable;
    if (last_underscore != id.len - 4) {
        log.err("Expected task_id of the form word_word_ccc. The last part only has '{d}' characters", .{id.len - last_underscore});
        return false;
    }
    for (id[id.len - 3 ..]) |c| {
        if (std.mem.findScalar(u8, base32_alphabet, c) == null) {
            log.err("Characters in the last part of the task_id must be in base32 alphabet: found '{c}'", .{c});
            return false;
        }
    }
    for (id[0 .. id.len - 3]) |c| {
        if (!std.ascii.isAlphabetic(c) and c != '_') {
            log.err("Characters in the middle part of the task_id must be alphabetic: found '{c}'", .{c});
            return false;
        }
    }
    return true;
}

test "id" {
    var ids = std.StringHashMap(void).init(std.testing.allocator);
    defer ids.deinit();
    for (0..1000) |_| {
        const id = try new(std.testing.allocator);
        const result = try ids.getOrPut(id);
        try std.testing.expect(!result.found_existing);
        try std.testing.expect(isValid(id));
    }
}

const adjectives = [_][]const u8{
    "abandoned",   "able",        "absolute",    "adorable",     "academic",    "acceptable",  "acclaimed",   "accurate",
    "aching",      "acidic",      "acrobatic",   "active",       "actual",      "adept",       "admirable",   "admired",
    "adolescent",  "adorable",    "adored",      "advanced",     "afraid",      "aged",        "aggravating", "aggressive",
    "agile",       "agitated",    "agonizing",   "agreeable",    "ajar",        "alarmed",     "alarming",    "alert",
    "alienated",   "alive",       "all",         "altruistic",   "amazing",     "ambitious",   "ample",       "amused",
    "amusing",     "anchored",    "ancient",     "angelic",      "angry",       "anguished",   "animated",    "annual",
    "another",     "antique",     "anxious",     "any",          "apt",         "arctic",      "arid",        "aromatic",
    "artistic",    "ashamed",     "assured",     "astonishing",  "athletic",    "attached",    "attentive",   "attractive",
    "austere",     "authentic",   "authorized",  "automatic",    "avaricious",  "average",     "aware",       "awesome",
    "awful",       "awkward",     "babyish",     "bad",          "back",        "baggy",       "bare",        "barren",
    "basic",       "beautiful",   "belated",     "beloved",      "beneficial",  "better",      "best",        "bewitched",
    "big",         "bitter",      "black",       "bland",        "blank",       "blaring",     "bleak",       "blind",
    "blissful",    "blond",       "blue",        "blushing",     "bogus",       "boiling",     "bold",        "bony",
    "boring",      "bossy",       "both",        "bouncy",       "bountiful",   "bowed",       "brave",       "breakable",
    "brief",       "bright",      "brilliant",   "brisk",        "broken",      "bronze",      "brown",       "bruised",
    "bubbly",      "bulky",       "bumpy",       "buoyant",      "burdensome",  "burly",       "bustling",    "busy",
    "buttery",     "buzzing",     "calculating", "calm",         "candid",      "canine",      "capital",     "carefree",
    "careful",     "careless",    "caring",      "cautious",     "cavernous",   "celebrated",  "charming",    "cheap",
    "cheerful",    "cheery",      "chief",       "chilly",       "chubby",      "circular",    "classic",     "clean",
    "clear",       "clever",      "close",       "closed",       "cloudy",      "clueless",    "clumsy",      "cluttered",
    "coarse",      "cold",        "colorful",    "colorless",    "colossal",    "comfortable", "common",      "competent",
    "complete",    "complex",     "complicated", "composed",     "concerned",   "concrete",    "confused",    "conscious",
    "considerate", "constant",    "content",     "conventional", "cooked",      "cool",        "cooperative", "corny",
    "corrupt",     "costly",      "courageous",  "courteous",    "crafty",      "crazy",       "creamy",      "creative",
    "creepy",      "criminal",    "crisp",       "critical",     "crooked",     "crowded",     "cruel",       "crushing",
    "cuddly",      "cultivated",  "cultured",    "cumbersome",   "curly",       "curvy",       "cute",        "cylindrical",
    "damaged",     "damp",        "dangerous",   "dapper",       "daring",      "darling",     "dark",        "dazzling",
    "dead",        "deadly",      "deafening",   "dear",         "dearest",     "decent",      "decimal",     "decisive",
    "deep",        "defenseless", "defensive",   "defiant",      "deficient",   "definite",    "definitive",  "delayed",
    "delectable",  "delicious",   "delightful",  "delirious",    "demanding",   "dense",       "dental",      "dependable",
    "dependent",   "descriptive", "deserted",    "detailed",     "determined",  "devoted",     "different",   "difficult",
    "digital",     "diligent",    "dim",         "dimpled",      "dimwitted",   "direct",      "disastrous",  "discrete",
    "disfigured",  "disgusting",  "disloyal",    "dismal",       "distant",     "downright",   "dreary",      "dirty",
    "disguised",   "dishonest",   "dismal",      "distant",      "distinct",    "distorted",   "dizzy",       "dopey",
    "doting",      "double",      "downright",   "drab",         "drafty",      "dramatic",    "dreary",      "droopy",
    "dry",         "dual",        "dull",        "dutiful",      "each",        "eager",       "earnest",     "early",
    "easy",        "ecstatic",    "edible",      "educated",     "elaborate",   "elastic",     "elated",      "elderly",
    "electric",    "elegant",     "elementary",  "elliptical",   "embarrassed", "eminent",     "emotional",   "empty",
    "enchanted",   "enchanting",  "energetic",   "enlightened",  "enormous",    "enraged",     "entire",      "envious",
    "equal",       "equatorial",  "essential",   "esteemed",     "ethical",     "euphoric",    "even",        "evergreen",
    "everlasting", "every",       "evil",        "exalted",      "excellent",   "exemplary",   "exhausted",   "excitable",
    "excited",     "exciting",    "exotic",      "expensive",    "expert",      "extroverted", "fabulous",    "failing",
    "faint",       "fair",        "faithful",    "fake",         "false",       "familiar",    "famous",      "fancy",
    "fantastic",   "far",         "faraway",     "fast",         "fat",         "fatal",       "fatherly",    "favorable",
    "favorite",    "fearful",     "fearless",    "feisty",       "feline",      "female",      "feminine",    "few",
    "fickle",      "filthy",      "fine",        "finished",     "firm",        "first",       "firsthand",   "fitting",
    "fixed",       "flaky",       "flamboyant",  "flashy",       "flat",        "flawed",      "flawless",    "flickering",
    "flimsy",      "flippant",    "flowery",     "fluffy",       "fluid",       "flustered",   "focused",     "fond",
    "foolhardy",   "foolish",     "forceful",    "forked",       "formal",      "forsaken",    "forthright",  "fortunate",
    "fragrant",    "frail",       "frank",       "frayed",       "free",        "French",      "fresh",       "frequent",
    "friendly",    "frightened",  "frightening", "frigid",       "frilly",      "frizzy",      "frivolous",   "front",
    "frosty",      "frozen",      "frugal",      "fruitful",     "full",        "fumbling",    "functional",  "funny",
    "fussy",       "fuzzy",       "gargantuan",  "gaseous",      "general",     "generous",    "gentle",      "genuine",
    "giant",       "giddy",       "gigantic",    "gifted",       "giving",      "glamorous",   "glaring",     "glass",
    "gleaming",    "gleeful",     "glistening",  "glittering",   "gloomy",      "glorious",    "glossy",      "glum",
    "golden",      "good",        "gorgeous",    "graceful",     "gracious",    "grand",       "grandiose",   "granular",
    "grateful",    "grave",       "gray",        "great",        "greedy",      "green",       "gregarious",  "grim",
    "grimy",       "gripping",    "grizzled",    "gross",        "grotesque",   "grouchy",     "grounded",    "growing",
    "growling",    "grown",       "grubby",      "gruesome",     "grumpy",      "guilty",      "gullible",    "gummy",
    "hairy",       "half",        "handmade",    "handsome",     "handy",       "happy",       "hard",        "harmful",
    "harmless",    "harmonious",  "harsh",       "hasty",        "hateful",     "haunting",    "healthy",     "heartfelt",
    "hearty",      "heavenly",    "heavy",       "hefty",        "helpful",     "helpless",    "hidden",      "hideous",
    "high",        "hilarious",   "hoarse",      "hollow",       "homely",      "honest",      "honorable",   "honored",
    "hopeful",     "horrible",    "hospitable",  "hot",          "huge",        "humble",      "humiliating", "humming",
    "humongous",   "hungry",      "hurtful",     "husky",        "icky",        "icy",         "ideal",       "idealistic",
    "identical",   "idle",        "idiotic",     "idolized",     "ignorant",    "ill",         "illegal",     "illiterate",
    "illustrious", "imaginary",   "imaginative", "immaculate",   "immaterial",  "immediate",   "immense",     "impeccable",
    "impartial",   "imperfect",   "impish",      "impolite",     "important",   "impossible",  "impressive",  "improbable",
    "impure",      "inborn",      "incomplete",  "incredible",   "indelible",   "indolent",    "infamous",    "infantile",
    "infatuated",  "inferior",    "infinite",    "informal",     "innocent",    "insecure",    "insidious",   "insistent",
    "intelligent", "intent",      "internal",    "intrepid",     "ironclad",    "itchy",       "jaded",       "jagged",
    "jaunty",      "jealous",     "joint",       "jolly",        "joyful",      "juicy",       "jumbo",       "junior",
    "jumpy",       "keen",        "key",         "kind",         "knobby",      "knotty",      "knowing",     "known",
    "kooky",       "kosher",      "lame",        "lanky",        "large",       "last",        "late",        "lavish",
    "lawful",      "lazy",        "leading",     "lean",         "leafy",       "left",        "legal",       "light",
    "likable",     "likely",      "limited",     "limp",         "lined",       "liquid",      "little",      "live",
    "lively",      "livid",       "lone",        "lonely",       "long",        "loose",       "lost",        "loud",
    "lovable",     "lovely",      "loving",      "low",          "loyal",       "lucky",       "luminous",    "lumpy",
    "mad",         "majestic",    "major",       "massive",      "mature",      "meager",      "mean",        "meaty",
    "medical",     "mediocre",    "medium",      "meek",         "mellow",      "merry",       "messy",       "mild",
    "milky",       "mindless",    "minor",       "minty",        "miserly",     "misty",       "mixed",       "modern",
    "modest",      "moist",       "monthly",     "moral",        "muddy",       "muffled",     "mundane",     "murky",
    "musty",       "muted",       "naive",       "narrow",       "nasty",       "natural",     "naughty",     "nautical",
    "near",        "neat",        "needy",       "nervous",      "new",         "next",        "nice",        "nifty",
    "nimble",      "nippy",       "noisy",       "nonstop",      "normal",      "notable",     "noted",       "novel",
    "numb",        "nutty",       "obedient",    "obese",        "oblong",      "oily",        "odd",         "oddball",
    "offbeat",     "offensive",   "official",    "old",          "only",        "open",        "optimal",     "opulent",
    "orange",      "orderly",     "organic",     "ornate",       "ordinary",    "original",    "other",       "our",
    "outlying",    "oval",        "overdue",     "pale",         "paltry",      "parallel",    "parched",     "partial",
    "past",        "pastel",      "peppery",     "perfect",      "perky",       "personal",    "pesky",       "petty",
    "phony",       "physical",    "piercing",    "pink",         "pitiful",     "plain",       "plastic",     "playful",
    "pleasant",    "pleased",     "pleasing",    "plump",        "plush",       "polished",    "polite",      "pointed",
    "poised",      "poor",        "popular",     "portly",       "posh",        "powerful",    "precious",    "present",
    "pretty",      "precious",    "pricey",      "prickly",      "primary",     "prime",       "private",     "prize",
    "profuse",     "proper",      "proud",       "prudent",      "punctual",    "pungent",     "puny",        "pure",
    "purple",      "pushy",       "puzzled",     "quaint",       "queasy",      "quick",       "quiet",       "quirky",
    "radiant",     "ragged",      "rapid",       "rare",         "rash",        "raw",         "ready",       "real",
    "red",         "regular",     "remote",      "ripe",         "roasted",     "robust",      "rosy",        "rotten",
    "rough",       "round",       "rowdy",       "royal",        "rubbery",     "rundown",     "ruddy",       "rude",
    "runny",       "rural",       "rusty",       "sad",          "safe",        "salty",       "sandy",       "sane",
    "sarcastic",   "satisfied",   "scaly",       "scared",       "scary",       "scrawny",     "second",      "secret",
    "selfish",     "separate",    "serene",      "serious",      "severe",      "shabby",      "shadowy",     "shady",
    "shallow",     "shameful",    "sharp",       "shiny",        "shocked",     "shocking",    "shoddy",      "short",
    "showy",       "shrill",      "shy",         "sick",         "silent",      "silky",       "silly",       "silver",
    "similar",     "simple",      "sinful",      "single",       "skinny",      "sleepy",      "slim",        "slimy",
    "slow",        "slushy",      "small",       "smart",        "smoggy",      "smooth",      "smug",        "snappy",
    "snarling",    "sneaky",      "snoopy",      "soft",         "soggy",       "solid",       "sore",        "soulful",
    "sour",        "sparse",      "speedy",      "spicy",        "spiffy",      "square",      "squeaky",     "squiggly",
    "stable",      "stale",       "starchy",     "stark",        "starry",      "steep",       "sticky",      "stiff",
    "stingy",      "stormy",      "straight",    "strange",      "steel",       "strict",      "strong",      "stunning",
    "stupid",      "sturdy",      "subtle",      "sudden",       "sugary",      "sunny",       "super",       "superior",
    "surprised",   "sweaty",      "sweet",       "swift",        "tall",        "tame",        "tan",         "tart",
    "tasty",       "taut",        "tedious",     "teeming",      "tender",      "tense",       "tepid",       "terrible",
    "testy",       "thick",       "thin",        "third",        "thirsty",     "thorny",      "tidy",        "tight",
    "timely",      "tinted",      "tiny",        "tired",        "torn",        "total",       "tough",       "traumatic",
    "tragic",      "trained",     "tricky",      "trifling",     "trim",        "trivial",     "troubled",    "true",
    "trusting",    "trusty",      "tubby",       "twin",         "ugly",        "ultimate",    "unaware",     "uncommon",
    "uneven",      "unfinished",  "unfit",       "unfolded",     "unhappy",     "unhealthy",   "uniform",     "unique",
    "united",      "unkempt",     "unknown",     "unlawful",     "unlined",     "unlucky",     "unnatural",   "unripe",
    "unruly",      "untidy",      "untrue",      "unusual",      "upbeat",      "upright",     "upset",       "urban",
    "usable",      "useless",     "utilized",    "utter",        "vain",        "valid",       "valuable",    "variable",
    "vast",        "vengeful",    "vibrant",     "vicious",      "violet",      "virtual",     "visible",     "vital",
    "vivid",       "wan",         "warm",        "warped",       "wary",        "wasteful",    "watchful",    "watery",
    "wavy",        "weak",        "webbed",      "wee",          "weepy",       "weighty",     "weird",       "wet",
    "whimsical",   "white",       "wild",        "wilted",       "windy",       "wise",        "witty",       "wobbly",
    "wonderful",   "wooden",      "woozy",       "wordy",        "worldly",     "worn",        "worried",     "worrisome",
    "worse",       "worst",       "worthless",   "worthy",       "wretched",    "writhing",    "wrong",       "wry",
    "yawning",     "yearly",      "yellow",      "young",        "youthful",    "yummy",       "zealous",     "zesty",
};

const std = @import("std");
comptime {
    @setEvalBranchQuota(10000);
    // Check if all adjectives are unique
    const kv_list = blk: {
        var list: []const struct { []const u8, void } = &.{};
        for (adjectives) |adj| {
            list = list ++ &[_]struct { []const u8, void }{.{ adj, {} }};
        }
        break :blk list;
    };
    var seen = std.StaticStringMap(void).initComptime(kv_list);
    if (seen.keys().len != adjectives.len) {
        @compileError("Adjectives must be unique");
    }

    if (adjectives.len != 1024) {
        const string = std.fmt.comptimePrint("{d}", .{adjectives.len});
        @compileError("Adjectives must be 1024 in length is" ++ string);
    }
}

const base32_alphabet = "0123456789abcdefghjkmnpqrstvwxyz";
fn encodeBase32(input: u15) [3]u8 {
    var out: [3]u8 = undefined;
    var i: usize = 0;
    var data = input;
    while (i < out.len) : (i += 1) {
        const pos = data & 31;
        out[i] = base32_alphabet[pos];
        data >>= 5;
    }
    return out;
}

const species_names = [_][]const u8{
    "acid",   "alien",  "alpha",  "armor", "arrow", "atom",  "axe",   "azure",
    "base",   "basil",  "beam",   "beast", "beta",  "blade", "blast", "nimbus",
    "bolt",   "bone",   "byte",   "chaos", "chip",  "claw",  "cobra", "code",
    "core",   "croc",   "crypt",  "dash",  "demon", "dino",  "doom",  "draco",
    "drake",  "dust",   "dwarf",  "echo",  "edge",  "ember", "fang",  "fire",
    "flash",  "flux",   "gale",   "gator", "gear",  "gecko", "ghost", "giant",
    "gila",   "glitch", "glow",   "grid",  "grim",  "goose", "haku",  "halo",
    "hash",   "heat",   "horn",   "hydra", "iron",  "jade",  "jolt",  "junk",
    "kaiju",  "kamodo", "knight", "koi",   "laser", "lava",  "link",  "load",
    "loop",   "magma",  "mamba",  "mars",  "mech",  "metal", "mist",  "mode",
    "moon",   "moss",   "mushu",  "naga",  "neon",  "newt",  "node",  "nova",
    "ogre",   "omega",  "onyx",   "orbit", "orc",   "path",  "pixel", "pyro",
    "quest",  "radar",  "rage",   "raid",  "ray",   "rex",   "scale", "shade",
    "skink",  "smaug",  "snap",   "spark", "spike", "storm", "tail",  "tegu",
    "thorn",  "titan",  "toad",   "toxic", "troll", "viper", "void",  "volt",
    "vortex", "warp",   "wave",   "wind",  "wyrm",  "zap",   "zero",  "zone",
};

comptime {
    if (species_names.len != 128) {
        const string = std.fmt.comptimePrint("{d}", .{species_names.len});
        @compileError("species_names.len must be 128 is " ++ string);
    }
}
