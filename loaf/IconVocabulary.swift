import Foundation

enum IconVocabulary {
    static func searchTerms(glyph: String, unicodeName: String) -> String {
        let key = canonicalGlyph(glyph)
        let name = normalize(unicodeName)
        var terms = [name, aliases[key] ?? ""]
        for family in families where family.names.contains(where: { matchesFamily($0, name: name) }) {
            terms.append(family.terms)
        }
        if name.contains("white") { terms.append("outline outlined hollow light") }
        if name.contains("black") { terms.append("filled solid dark") }
        if name.contains("half") { terms.append("split divided half") }
        if name.contains("circled digit") || name.contains("circled number") {
            terms.append("number numbered badge counter circle round")
            if let number = key.unicodeScalars.first?.properties.numericValue, number.rounded() == number {
                terms.append(String(Int(number)))
            }
        }
        return tokens(terms.joined(separator: " ")).reduce(into: [String]()) { result, term in
            if !result.contains(term) { result.append(term) }
        }.joined(separator: " ")
    }

    static func score(query: String, glyph: String, unicodeName: String) -> Int? {
        Entry(glyph: glyph, unicodeName: unicodeName).score(query: query)
    }

    struct Entry {
        let searchTerms: String
        private let glyph: String
        private let name: String
        private let vocabulary: [String]
        private let exactTokens: Set<String>

        init(glyph: String, unicodeName: String) {
            self.glyph = canonicalGlyph(glyph)
            name = normalize(unicodeName)
            searchTerms = IconVocabulary.searchTerms(glyph: glyph, unicodeName: unicodeName)
            vocabulary = tokens(searchTerms)
            exactTokens = Set(vocabulary)
        }

        func score(query: String) -> Int? {
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return 0 }
            if canonicalGlyph(trimmed) == glyph { return 1_000 }
            let words = tokens(trimmed).filter { !queryNoise.contains($0) }
            guard !words.isEmpty else { return nil }
            var score = 0
            for word in words {
                if exactTokens.contains(word) {
                    score += 100
                } else if singularForms(word).contains(where: { exactTokens.contains($0) }) {
                    score += 90
                } else if vocabulary.contains(where: { $0.hasPrefix(word) }) {
                    score += 60
                } else if word.count >= 3 && vocabulary.contains(where: { $0.contains(word) }) {
                    score += 20
                } else {
                    return nil
                }
            }
            let phrase = words.joined(separator: " ")
            if name == phrase {
                score += 300
            } else if name.hasPrefix(phrase) {
                score += 150
            } else if name.contains(phrase) {
                score += 80
            }
            return score
        }
    }

    private static func canonicalGlyph(_ value: String) -> String {
        value.replacingOccurrences(of: "\u{FE0F}", with: "").replacingOccurrences(of: "\u{FE0E}", with: "")
    }
    private static func normalize(_ value: String) -> String { tokens(value).joined(separator: " ") }
    private static func matchesFamily(_ family: String, name: String) -> Bool {
        if family == "smil" || family == "grin" {
            return name.split(separator: " ").contains(where: { $0.hasPrefix(family) })
        }
        return (" " + name + " ").contains(" " + family + " ")
    }
    private static func tokens(_ value: String) -> [String] {
        value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    private static func singularForms(_ word: String) -> [String] {
        guard word.count > 3, word.hasSuffix("s"), !word.hasSuffix("ss") else { return [] }
        var forms = [String(word.dropLast())]
        if word.hasSuffix("ies") { forms.append(String(word.dropLast(3)) + "y") }
        if word.hasSuffix("es") { forms.append(String(word.dropLast(2))) }
        return forms
    }
    private static let queryNoise: Set<String> = [
        "a", "an", "the", "for", "my", "me", "of", "with", "and", "icon", "icons", "emoji", "emojis", "profile",
        "profiles",
    ]

    private struct Family {
        let names: [String]
        let terms: String
    }
    private static let families: [Family] = [
        Family(names: ["face"], terms: "mood emotion expression people person smiley emoticon"),
        Family(names: ["smil", "grin"], terms: "happy cheerful joy friendly positive"),
        Family(names: ["cry", "frown", "weary", "tired"], terms: "sad upset unhappy exhausted mood"),
        Family(names: ["angry", "anger", "pout"], terms: "mad annoyed frustrated rage grumpy"),
        Family(names: ["laugh", "tears of joy"], terms: "funny humor humour lol happy silly"),
        Family(names: ["kiss", "heart"], terms: "love affection romance favorite favourite relationship"),
        Family(names: ["moon", "planet", "comet"], terms: "space astronomy cosmos celestial night sky"),
        Family(names: ["star", "sparkle"], terms: "favorite favourite bright shine sparkle special"),
        Family(
            names: ["sun", "cloud", "rain", "snow", "fog", "tornado", "cyclone"],
            terms: "weather forecast climate outdoors sky"),
        Family(
            names: ["tree", "herb", "leaf", "seedling", "blossom", "clover", "shamrock"],
            terms: "plant nature garden gardening green grow growth botanical"),
        Family(names: ["monkey", "paw", "bear"], terms: "animal animals pet wildlife cute"),
        Family(
            names: ["book", "memo", "pencil", "scroll"],
            terms: "school study student learning education writing reading notes"),
        Family(names: ["computer", "phone", "robot"], terms: "technology tech digital device electronics"),
        Family(names: ["music", "speaker", "microphone"], terms: "music audio sound listening song podcast"),
        Family(names: ["camera", "television"], terms: "media video film movies entertainment creative"),
        Family(names: ["game", "alien monster"], terms: "gaming gamer games play arcade fun"),
        Family(
            names: ["airplane", "train", "bus", "automobile", "bicycle", "ship", "boat"],
            terms: "travel transport transportation journey trip vehicle commute"),
        Family(
            names: ["lock", "key", "shield", "fingerprint"],
            terms: "security privacy private safe protection password authentication"),
        Family(
            names: ["circle", "square", "triangle", "rectangle", "lozenge"],
            terms: "shape geometric geometry minimal abstract design"),
        Family(
            names: [
                "aries", "taurus", "gemini", "cancer", "leo", "virgo", "libra", "scorpius", "sagittarius", "capricorn",
                "aquarius", "pisces", "ophiuchus",
            ], terms: "zodiac astrology horoscope constellation birth sign"),
        Family(names: ["hand", "thumb", "finger"], terms: "gesture people person hands"),
        Family(names: ["battery"], terms: "power energy charging charge electric"),
        Family(
            names: ["beverage", "teapot", "milk", "wine", "cocktail"], terms: "drink drinks beverage break cafe kitchen"
        ),
        Family(names: ["flag"], terms: "flag banner marker milestone signal"),
        Family(
            names: ["clock", "hourglass", "calendar"],
            terms: "time timer schedule planning appointment reminder productivity"),
        Family(
            names: ["quotation", "comma"],
            terms: "quote quotes quotation punctuation writing literature author excerpt dialogue"),
        Family(names: ["yang"], terms: "line lines bar bars stripe stripes minimal symbol abstract"),
    ]

    private static let aliases: [String: String] = {

        let groups: [(String, String)] = [
            ("☀🌞", "sun sunny sunshine summer daylight warm morning"),
            ("☁🌥⛅", "cloud cloudy overcast partly sunny"),
            ("☂☔🌧🌦", "rain rainy umbrella wet drizzle showers"),
            ("☃❄🌨", "snow snowy snowflake winter cold frozen frost"),
            ("⛈🌩⚡", "thunder lightning storm electric electricity bolt power energy fast"),
            ("🌪🌀", "tornado cyclone hurricane storm swirl windy wind"),
            ("🌫", "fog foggy mist misty haze hazy"),
            ("🌈", "rainbow colorful colourful color colour spectrum prism pride inclusive queer lgbt lgbtq lgbtqia"),
            ("🌊💧💦", "water ocean sea wave surf swimming beach blue fluid"),
            ("🌐", "internet web website browser online network world global globe earth"),
            ("🌑🌒🌓🌔🌕🌖🌗🌘🌙🌛🌜", "moon lunar phases evening night bedtime quiet calm sleepy"),
            ("☄🚀🪐", "space spaceship rocket launch explore exploration universe science scifi"),
            ("★☆⭐🌟✨⯨⯩⯪⯫", "star stars sparkle magic shiny favorite favourite bookmark featured highlight"),
            ("🌱", "sprout seed seedling plant growing growth fresh beginner new garden eco sustainable sustainability"),
            ("🌲🌳", "tree forest woods woodland outdoors hiking camping nature environment evergreen pine oak"),
            ("🌸", "flower flowers blossom bloom cherry spring floral pink garden"),
            ("🌿", "leaf leaves herb herbs plant green botanical garden cooking"),
            ("☘🍀", "clover shamrock lucky luck irish ireland nature green"),
            ("🐵🙈🙉🙊", "monkey playful cheeky animal banana"),
            ("🙈", "shy embarrassed peek hiding privacy see no evil"),
            ("🙉", "cookies cookie hear no evil listening mute deaf"),
            ("🙊", "secret quiet hush silence speak no evil"),
            ("🐾", "pets pet dog cat paw paws puppy kitten animal footprint"),
            ("🧸", "teddy bear plush cuddly cozy cosy childhood toy soft cute comfort"),
            ("🦴", "bone bones dog pet skeleton fossil archaeology"),
            ("🦠", "microbe germ bacteria virus biology science lab health"),
            ("☕🫖", "coffee tea teapot cafe café caffeine espresso latte cozy cosy relaxed relaxing warm morning break"),
            ("🍷🍸", "wine cocktail bar drinks party evening celebration social happy hour"),
            ("🍼🥛", "milk baby nursery kids family childhood bottle drink"),
            ("🎁", "gift present surprise birthday giving shopping celebration"),
            ("🎃👻🕸", "halloween spooky scary autumn fall october horror"),
            ("👻", "ghost private incognito invisible anonymous privacy"),
            ("☠💀", "skull skeleton danger pirate spooky dead death gothic"),
            ("🎆🎈🎉🥳🙌", "party celebration birthday festive congratulations hooray confetti fun"),
            ("🎙", "microphone mic podcast recording voice singing karaoke streamer streaming"),
            (
                "🎮👾",
                "controller joystick gamer gaming game videogame video games arcade play console xbox playstation nintendo"
            ),
            ("🎯", "target goal goals focus focused aim bullseye productivity achievement"),
            ("🎲", "dice die boardgame tabletop board games random luck gambling"),
            ("🎵🎶🎧", "music musical song songs melody playlist headphones listening tunes"),
            ("🏆", "trophy prize winner winning award achievement champion success sport sports"),
            (
                "🏝🏞⛰🗻",
                "outdoors outdoor nature hiking camping scenery landscape adventure getaway vacation holiday travel"
            ),
            ("🏝", "island tropical beach paradise summer palm sunny vacation"),
            ("🏠", "home house personal family domestic cozy cosy living"),
            ("⚓⛵🚢", "boat boating ship sailing sailor nautical sea ocean harbor harbour marina"),
            ("✈🛫🛬", "plane flying flight airport aviation travel holiday vacation departure arrival"),
            ("🚅🚆", "train railway railroad metro subway commute transit rail"),
            ("🚌", "bus coach public transport transit school commute"),
            ("🚗", "car automobile driving driver roadtrip road trip motor auto"),
            ("🚲", "bike bicycle cycling cyclist ride fitness commute"),
            ("🛸👽", "alien extraterrestrial ufo spaceship science scifi unknown space"),
            ("🏹🗡🔫", "weapon adventure combat fantasy battle game gaming"),
            ("👀👁", "eye eyes see look watch watching view visible visibility observe attention"),
            ("👌👍", "okay ok yes good approve approval like positive success"),
            ("👎", "no dislike disapprove negative bad"),
            ("✌☮", "peace peaceful chill calm relaxed victory"),
            ("👑", "crown royal royalty king queen premium special fancy"),
            ("👤", "person personal user account individual solo silhouette"),
            ("👥🤝", "people team teamwork group friends community social collaboration together partnership"),
            ("🤖", "robot bot ai artificial intelligence automation coding tech machine"),
            ("👿😈", "devil imp horns mischievous naughty evil trouble"),
            ("💉💊", "health medical medicine doctor healthcare pharmacy vaccine nurse wellness"),
            ("💋💍💎❤❣💔🥰😍", "love romance romantic relationship affection heart hearts dating"),
            ("💍", "ring wedding marriage engaged engagement jewelry jewellery"),
            ("💎", "diamond gem gemstone jewelry jewellery precious luxury crystal"),
            ("💔", "heartbreak broken sad breakup lonely"),
            ("💡", "idea ideas lightbulb inspiration creative creativity innovation thinking bright"),
            ("💢😠😡🤬🗯", "angry anger mad annoyed frustration frustrated rage rant grumpy"),
            ("💣💥", "bomb boom explode explosion explosive impact surprise"),
            ("💤😴🕯", "sleep sleepy sleeping bedtime rest relaxing calm quiet cozy cosy night"),
            ("💨", "fast speed quick wind air gust breeze running"),
            ("💩", "poop poo silly funny bathroom toilet joke"),
            ("💫😵", "dizzy confused dazed spinning stars overwhelmed"),
            ("💬🗣📣", "chat talk talking speech conversation communicate communication messages social"),
            ("💭🤔", "think thinking thought thoughts pondering ideas brainstorm wondering reflection"),
            ("💯", "hundred perfect perfection excellent score points success"),
            (
                "💵🪙🤑",
                "money finance financial budget budgeting banking bank cash savings investing investment wealth rich"
            ),
            ("💻🖥", "computer laptop desktop mac pc work office programming code coding development developer tech"),
            ("📁", "folder files documents organize organisation organization archive storage project work"),
            ("📌📍", "pin pinned location place map maps destination reminder bookmark"),
            ("📎", "paperclip attach attachment attached paperwork file documents office"),
            ("🏫", "school campus education classroom learning study university college student"),
            (
                "📓📖📜📝✏",
                "book books notebook notes note writing write read reading study school studying student education learning homework journal diary author"
            ),
            ("📞📱", "phone telephone call calling mobile iphone smartphone contact communication"),
            ("📶🛜", "wifi wi fi wireless internet network signal connection online connectivity"),
            ("📷", "camera photo photography photographer photos picture pictures capture creative art"),
            ("📹📺", "video videos movies film cinema television tv watch watching entertainment streaming youtube"),
            ("🔅🔆", "brightness bright dim light display screen"),
            ("🔇🔈🔉🔊", "speaker audio sound volume music listening podcast headphones"),
            ("🔇", "mute muted silent silence quiet"),
            ("🔋🪫", "battery charge charging energy power electric electronics"),
            ("🔍🔎", "search find discover discovery magnify magnifying glass research explore curiosity"),
            (
                "🔑🗝🔒🔓🛡🫆",
                "security secure safety safe protect protection privacy password passwords authentication login access identity"
            ),
            ("🔓", "unlock unlocked open access permission"),
            ("🔔🔕", "bell notification notifications alert alerts reminder reminders"),
            ("🔕", "mute muted silent silence do not disturb focus"),
            ("🔞", "adult adults mature age restricted eighteen"),
            ("🔥", "fire flame hot heat warm burning trending lit campfire"),
            ("🔦", "torch flashlight light camping explore search"),
            (
                "🔧🔨🪚⚙",
                "tools tool repair fix fixing building build making maker diy workshop maintenance engineering tinkering"
            ),
            ("⚙", "settings preferences configure configuration gear cog controls system"),
            ("🔮🪄", "magic magical mystery fantasy wizard witch spell fortune future imagination creative"),
            ("🔰", "beginner new starter learning novice green"),
            ("🕐🗓", "time date schedule scheduling calendar planning plan appointment productivity work"),
            ("🖌", "paint painting brush art artist creative design drawing illustration color colour"),
            ("🖐", "hand hands hello wave waving stop high five"),
            ("🖕", "middle finger rude annoyed rebellious punk"),
            ("🖱", "mouse cursor click computer input pointer gaming"),
            ("🗑", "trash bin wastebasket rubbish garbage delete remove discard cleanup cleaning"),
            ("🧩", "puzzle jigsaw puzzles piece extension extensions addon add on problem solving thinking"),
            ("🧭", "compass direction navigation explore adventure discovery travel north map"),
            ("🪧", "sign placard protest announcement message statement"),
            ("☐☑☒✓✔✗❌", "check checkbox checklist tasks todo to do done complete completion select selection"),
            ("☑✓✔", "yes correct success confirmed approved checkmark tick"),
            ("☒✗❌", "no wrong error failure cross cancel close remove"),
            ("⚠⛔🚫", "warning danger caution stop blocked block prohibited restricted unsafe"),
            ("☰", "menu list navigation hamburger sidebar"),
            ("◧◨", "sidebar layout panel split side view window"),
            ("♻", "recycle recycling sustainable sustainability eco environment green reuse"),
            ("♿", "accessibility accessible wheelchair mobility inclusion inclusive"),
            ("♀♂⚧", "gender identity feminine masculine female male woman man transgender trans queer"),
            ("🚹🚺🚻🚼🚽", "bathroom restroom toilet facilities people family baby"),
            ("♨", "hot springs spa bath warm relaxation wellness steam sauna"),
            ("🛒", "shopping shop cart trolley groceries grocery buy buying store retail errands"),
            ("😀😁😃😄😇🙂", "happy smile smiling cheerful friendly positive joy wholesome kind"),
            ("😂😆🤣", "laugh laughing funny hilarious lol humor humour comedy silly"),
            ("😅😓", "sweat nervous awkward relief stressed embarrassed"),
            ("😉😏", "wink winking smirk cheeky playful flirt flirting knowing"),
            ("😋", "yummy delicious tasty hungry food foodie cooking eating"),
            ("😎", "cool sunglasses shades chill relaxed confident summer"),
            ("😐😑😶", "neutral blank expressionless quiet silent indifferent unbothered"),
            ("😖😩😫", "tired weary exhausted frustrated stressed overwhelmed struggling"),
            ("😗😘😚", "kiss kissing love affectionate romance flirt"),
            ("😛😜😝🤪", "tongue playful silly goofy fun cheeky joking wacky crazy"),
            ("😢😭", "cry crying tears sad sadness upset unhappy emotional"),
            ("😤", "proud triumph determined frustrated huff angry"),
            ("😬", "grimace awkward cringe nervous uncomfortable embarrassed"),
            ("😮😱😳🤯", "surprise surprised shocked shock amazed wow disbelief"),
            ("😱", "scared fear afraid scream screaming panic horror"),
            ("😳", "blush blushing embarrassed shy flustered"),
            ("🙃🫠", "silly awkward irony ironic sarcasm sarcastic overwhelmed melting"),
            ("🙄", "eyeroll eye roll annoyed sarcastic skeptical bored unimpressed"),
            ("🙏", "pray prayer thanks thank you gratitude grateful please hope hopeful"),
            ("🤓🧐", "nerd geek smart intelligent research academic study scholar curious learning"),
            ("🤘", "rock music metal concert punk rockstar"),
            ("🤡", "clown circus funny joke silly foolish"),
            ("🤢🤮", "sick illness nauseous nausea disgust disgusting unwell vomit"),
            ("🤨", "skeptical suspicious doubt doubtful questioning raised eyebrow"),
            ("🤩", "starstruck excited amazed wow delighted impressed"),
            ("🥴", "woozy dizzy tipsy drunk confused exhausted awkward"),
            ("🫥", "invisible hiding hidden shy private quiet anonymous"),

            (
                "⌛",
                "hourglass sand timer countdown waiting wait patience pending deadline history past vintage retro antique"
            ),
            ("⏰", "alarm wake up wakeup waking morning clock time timer reminder punctual routine"),
            ("🕐", "clock watch hour hours time timezone time zone punctual schedule meeting appointment"),
            (
                "🗓",
                "calendar planner agenda dates events meeting meetings appointment appointments organize organised organized"
            ),
            ("⏹", "stop stopped halt finish end square block media playback player transport"),
            ("⏺", "record recording recorder studio capture broadcast live circle dot media"),
            (
                "①②③④⑤⑥⑦⑧⑨⓪",
                "number numeral numeric numbered label badge counter count index order sequence round circle circled"
            ),
            ("◩◪", "square diagonal divided split geometric shape minimal abstract half tile"),
            ("⚊", "line horizontal dash bar stripe stroke simple minimal abstract"),
            ("⚌", "lines horizontal double pair bars stripes equal simple minimal abstract"),
            ("☹", "frown frowning sad unhappy disappointed down gloomy melancholy miserable emotional mood"),
            ("♈", "ram sheep aries fire zodiac astrology horoscope constellation birth sign"),
            ("♉", "bull ox taurus earth zodiac astrology horoscope constellation birth sign"),
            ("♊", "twins twin gemini air zodiac astrology horoscope constellation birth sign"),
            ("♋", "crab cancer water zodiac astrology horoscope constellation birth sign"),
            ("♌", "lion leo fire zodiac astrology horoscope constellation birth sign"),
            ("♍", "maiden virgin virgo earth zodiac astrology horoscope constellation birth sign"),
            ("♎", "scales balance libra air zodiac astrology horoscope constellation birth sign"),
            ("♏", "scorpion scorpio scorpius water zodiac astrology horoscope constellation birth sign"),
            ("♐", "archer bow arrow sagittarius fire zodiac astrology horoscope constellation birth sign"),
            ("♑", "goat sea goat capricorn earth zodiac astrology horoscope constellation birth sign"),
            ("♒", "water bearer aquarius air zodiac astrology horoscope constellation birth sign"),
            ("♓", "fish fishes pisces water zodiac astrology horoscope constellation birth sign"),
            ("⛎", "snake serpent bearer ophiuchus zodiac astrology horoscope constellation birth sign"),
            (
                "✉",
                "mail email e mail inbox letter letters envelope postal post correspondence message messages communication penpal"
            ),
            (
                "❓",
                "question questions help support faq ask asking answers curiosity curious wondering inquiry mystery unknown puzzled"
            ),
            (
                "❢",
                "exclamation attention notice important urgent alert emphasis emphatic announcement surprise excited"
            ),
            (
                "❛❜❟",
                "single quote apostrophe punctuation writing writer author literature text speech quotation excerpt"
            ),
            ("❝❞❠", "double quote quotation quotes writing writer author literature text speech excerpt dialogue"),
            ("🏳", "flag white surrender truce peaceful peace blank banner"),
            ("🏴", "flag black pirate pirates rebellion rebel banner"),
            ("🚩", "flag red marker marked waypoint finish milestone checkpoint goal destination warning"),
            ("👈👉", "point pointing pointer finger index gesture hand direction side this here there indicate"),
            ("👈", "left previous back backwards west"),
            ("👉", "right next forward forwards east"),
            (
                "☀🌞",
                "sunrise sunbeam solar dawn sunshine beach sunbathe daylight daylight outdoors bright optimistic optimism"
            ),
            ("☁🌥⛅", "clouds sky fluffy soft airy daydream daydreaming"),
            ("☂☔", "umbrella brolly raincoat shelter sheltered protection rainy waterproof"),
            ("☃", "snowman snow person winter holiday holidays festive snowball frosty"),
            ("❄", "snowflake ice icy chill chilly crystal crystals wintry wintertime"),
            ("⛈🌩⚡", "thunderstorm lightning energetic charging electrified zap zapping"),
            ("🌊", "wave waves surfing surfer seaside coastal coast waterfront nautical tide tides oceanic"),
            ("💧💦", "droplet droplets splash splashing hydration hydrate wet liquid rain shower showers"),
            ("🌐", "www worldwide international globe globes connected connections networking browsing"),
            ("🌙🌑🌒🌓🌔🌕🌖🌗🌘🌛🌜", "nocturnal nighttime stargazing lunar moonlight moonlit moonbeam dreaming dream dark mode"),
            ("☄", "comet meteor shooting star asteroid cosmic outer space stargazer stargazing"),
            (
                "🚀",
                "astronaut spacecraft spaceflight startup startups launch launching liftoff takeoff ambitious ambition"
            ),
            ("🪐", "saturn planet planets planetary rings orbit orbital solar system cosmic"),
            (
                "★☆⭐🌟✨",
                "stars sparkles twinkle twinkling glitter glittering celestial aesthetic favorites favourites wishlist wish"
            ),
            ("🌱🌿🌲🌳", "plants greenery earthy environmental conservation ecology organic outdoorsy vegetarian vegan"),
            ("🌱", "sprouting sapling seedlings gardening gardener growth growing renewal renew fresh start"),
            ("🌲", "conifer spruce fir christmas lumber wilderness evergreen tree trees"),
            ("🌳", "deciduous oak maple trunk branches tree trees shady shade park parks"),
            ("🌸", "sakura cherry blossom flowers petals blooming delicate springtime florist floral botanical"),
            ("🌿", "foliage sprig herbs herbal herbalist greenery mint basil rosemary leaves leaf"),
            ("☘🍀", "fortune fortunate good luck lucky charm charms shamrocks clovers"),
            ("🐵🙈🙉🙊", "monkeys primate chimp chimpanzee ape jungle mischievous mischief cheeky playful"),
            (
                "🐾",
                "cat cats dog dogs kitten kittens puppy puppies pawprint pawprints pets animals veterinarian veterinary"
            ),
            (
                "🧸",
                "bear bears teddy stuffed animal plushie cuddle cuddles cuddling comfort comforting soft toy childhood"
            ),
            (
                "🦠",
                "microscope microbiology microbial biology biological infection infectious germs bacteria scientific laboratory research"
            ),
            (
                "🦴",
                "bones skeleton skeletal fossil fossils anatomy archaeologist paleontology dinosaur dinos archaeology"
            ),
            (
                "☕",
                "cup mug cuppa brew brewing barista cappuccino mocha americano decaf coffeehouse coffeeshop coffee shop tea teatime hot chocolate"
            ),
            (
                "🫖",
                "tea pot kettle teacup teatime brew brewing steep steeping afternoon tea herbal chamomile matcha chai"
            ),
            ("🍷", "wineglass vino winery vineyard sommelier merlot red white tasting drink drinking nightlife"),
            ("🍸", "martini margarita mojito bartender mixology mixologist aperitif nightlife drink drinking"),
            (
                "🍼",
                "parent parenting parenthood newborn infant infancy baby babies bottle feeding daycare caretaker nursery"
            ),
            ("🥛", "dairy drink drinking glass oat almond soy breakfast calcium"),
            (
                "🎁",
                "present presents gifts wrapped wrapping ribbon giving generous generosity birthday birthdays shopping holiday holidays"
            ),
            ("🎃", "pumpkin jack o lantern jackolantern harvest trick treat trickortreat spooky seasonal"),
            ("🕸", "cobweb cobwebs spider spiders web webs arachnid creepy spooky haunted halloween"),
            ("👻", "ghost ghosts phantom spirit spirits haunting haunted boo spectral secret stealth private browsing"),
            (
                "☠💀",
                "skulls skeletons crossbones pirate pirates goth gothic metal mortality poison poisonous toxic warning"
            ),
            ("🎆", "firework fireworks pyrotechnics spark burst festival new year newyear celebration celebrating"),
            ("🎈", "balloon balloons inflate inflated floating float birthday birthdays celebration celebrating"),
            (
                "🎉🥳🙌",
                "celebrate celebrating celebratory congratulations congrats hooray cheers yay event events festivities"
            ),
            (
                "🎙",
                "mic microphone broadcast broadcasting broadcaster audio voiceover vocal vocals journalist journalism interview interviews"
            ),
            ("🎮👾", "videogames gamepad gamepads player players multiplayer esports steam retro gaming"),
            (
                "🎯",
                "archery dart darts dartboard bull s eye bullseye target targets goals objectives focused precision accurate accuracy"
            ),
            (
                "🎲",
                "dnd dungeons dragons tabletop rpg roleplaying boardgame boardgames chance chances probability roll rolling dice"
            ),
            ("🎵🎶", "musician musicians songwriting composer composing musical notes notation rhythm harmonies harmony"),
            (
                "🏆",
                "awards champion championship victory victorious best first place competition competitive accomplishment accomplishments reward"
            ),
            (
                "🏝🏞⛰🗻",
                "hike hiker backpacking trail trails trekking outdoorsy getaway scenic scenery exploring excursion"
            ),
            (
                "⛰🗻",
                "mountain mountains alpine summit peak peaks climbing climber mountaineer mountaineering hiking altitude"
            ),
            (
                "🏠",
                "household residence residential hometown homely domestic personal workspace nest nesting family families"
            ),
            (
                "⚓⛵🚢",
                "maritime mariner cruise cruising yacht yachting vessel captain sailor sailors sailing boating watersport"
            ),
            (
                "✈🛫🛬",
                "aeroplane airplane aircraft aviation airline airlines pilot pilots jet jetsetter jetsetting flying flight flights"
            ),
            (
                "🚅🚆",
                "trains locomotive commuter commuting transit metro public transportation transport railways railroads"
            ),
            ("🚌", "buses bussing coach coaches passenger passengers commuter commuting public transportation transit"),
            (
                "🚗",
                "cars motorcar automotive motorist motoring road trip roadtrip roadtripping commute commuting vehicle vehicles"
            ),
            (
                "🚲",
                "biking biker bicycle bicycles bike bikes cycling cyclist cyclists cycle ride riding pedal pedals exercise workout"
            ),
            (
                "🛸👽👾",
                "aliens extraterrestrial martian space invader invaders scifi sci fi science fiction cosmic outer space"
            ),
            ("🏹🗡🔫", "fantasy combat warrior fighter battle battles fighting weapon weapons adventure adventurer"),
            (
                "👀👁",
                "eyeball eyeballs lookout observation observer observing vision visual sight sighted view viewing watchful mindful mindfulness"
            ),
            (
                "👌👍",
                "approve approved approval okay ok agree agreed agreement thumbs up thumbsup nice excellent positive upvote"
            ),
            ("👎", "disagree disagreed disapproval thumbs down thumbsdown downvote reject rejected rejection"),
            (
                "✌☮",
                "peaceful pacifist pacifism zen meditation meditate meditating harmony calm calming serenity serene"
            ),
            ("👑", "regal monarch monarchy coronation ruler sovereign queen king princess prince kingdom royal royals"),
            (
                "👤",
                "human humanbeing individual individuality identity account accounts avatar avatars user users anonymous persona"
            ),
            (
                "👥🤝",
                "friend friends friendship crew club clubs colleagues coworkers coworker co worker shared sharing team teams community communities"
            ),
            (
                "🤝",
                "handshake hand shake deal deals agreement partner partners partnership partnering cooperation collaborate collaboration trust trusted"
            ),
            (
                "🤖💻🖥",
                "programmer programmers software engineer engineering coding coder coders developer developers dev development code computer computers"
            ),
            (
                "🤖",
                "artificial intelligence ai bot bots robotics robotic chatbot assistant assistants automate automated automation machine learning"
            ),
            (
                "💉💊",
                "medicine medication medications medicinal hospital treatment treatments clinic clinical wellness healthcare health care doctor doctors nurse nurses"
            ),
            (
                "💋💍💎❤❣💔🥰😍",
                "loving loved beloved romantic romance sweet sweetheart darling affection affectionate valentines valentine"
            ),
            (
                "💍",
                "engagement engagementring wedding weddings bride bridal married marriage anniversary anniversaries jewel jewels jewelry jewellery"
            ),
            (
                "💎",
                "gem gems gemstone gemstones crystal crystals jewel jewels diamond diamonds sparkle sparkling luxury luxurious precious treasure"
            ),
            (
                "💡",
                "light bulb lightbulb eureka invent inventor invention innovation creative creativity inspiration inspired illuminate illumination"
            ),
            (
                "💤😴🕯",
                "rest rested restful resting unwind unwinding relax relaxation relaxed doze dozing nap napping sleep sleeping slumber dream dreams"
            ),
            (
                "💬🗣📣",
                "message messaging messenger chat chatting chatter conversation conversations communication communicating speak speaking speech voices"
            ),
            (
                "💭🤔",
                "thought thoughtful thinking contemplate contemplating contemplation ponder pondering curious curiosity brainstorm brainstorming reflective reflection"
            ),
            (
                "💵🪙🤑",
                "business economy economic economics cryptocurrency crypto bitcoin savings saving spend spending payment payments investing investor investments"
            ),
            (
                "💻🖥📁📎",
                "office business working workplace workspace productivity professional profession job jobs career careers"
            ),
            (
                "📁",
                "file files folder folders document documents filing organised organized organise organize organisation organization collection collections archive archives"
            ),
            (
                "📌📍",
                "pinned pinning pushpin push pin marker markers mark place places location locations bookmark bookmarks save saved reminder"
            ),
            (
                "📎",
                "paper clip paperclip clip attachment attachments attached attaching documents files stationery stationary paperwork"
            ),
            (
                "📓📖📜📝✏",
                "reader readers writer writers author authors novelist novel novels journal journaling literature literary library libraries homework studying coursework academic academia student students"
            ),
            (
                "📓",
                "notebook notebooks notepad diary diaries bullet journal bulletjournal journaling personal notes stationery"
            ),
            (
                "📖",
                "books bookworm read reader reading literature literary library libraries ebook ebooks novel novels story stories storytelling"
            ),
            (
                "📜",
                "scroll parchment manuscript manuscripts certificate diploma history historical historian ancient antique old document documents"
            ),
            (
                "📝✏",
                "write writing written writer writers pen pencil pencils note notes notetaking note taking jot jotting drafting edit editing editor editors"
            ),
            (
                "📞📱",
                "telephone telephony call calls calling caller contact contacts communication communicate mobile cell cellphone cell phone smartphone smartphones"
            ),
            (
                "📶🛜",
                "wifi wi fi wlan hotspot wireless broadband router routing networking network networks connect connected connection connections internet online"
            ),
            (
                "📷📹",
                "photographer photography filming videographer videography camera cameras capture capturing creator creators creative content"
            ),
            (
                "📺",
                "tv television telly shows show series channel channels streaming streamer broadcast broadcasting entertainment netflix"
            ),
            (
                "🔇🔈🔉🔊",
                "sound sounds audio acoustics acoustic volume speaker speakers listen listening music musical soundscape soundscapes soundtrack"
            ),
            (
                "🔋🪫",
                "charged rechargeable recharging charger charge charging electric electricity electrical power powered energy energetic"
            ),
            ("🪫", "low depleted drained empty exhausted recharge recharging power saving conserve conservation"),
            (
                "🔍🔎",
                "magnifier magnification magnify magnifying lookup look up find finding search searching seeker seek seeking research researcher discover discovering curiosity curious"
            ),
            (
                "🔑🗝🔒🔓🛡🫆",
                "secure secured security private privacy protection protected protective protect protecting confidential confidentiality confidentially secrets secret login log in signin sign in vault identity"
            ),
            (
                "🫆",
                "biometric biometrics fingerprint fingerprints thumbprint touch id touchid authentication authenticate unique uniqueness identity identify identification"
            ),
            (
                "🛡",
                "shield shields defend defending defense defence defensive guardian guarding guard armour armor protected protector protection"
            ),
            (
                "🔔🔕",
                "reminder reminders remind notification notifications notify alert alerts alerting bell bells alarm alarms"
            ),
            (
                "🔕🔇",
                "silence silent silenced mute muted quiet quietness do not disturb dnd peaceful focus focused concentration"
            ),
            (
                "🔥",
                "flame flames fire fiery ignite ignition bonfire fireplace campfire passion passionate intensity intense heat heated"
            ),
            (
                "🔦",
                "flash light flashlight torch torchlight illuminate illumination explorer exploring adventure camping light lights"
            ),
            (
                "🔧🔨🪚⚙",
                "handyman handy craft crafts craftsman craftsmanship construct construction builder builders carpenter carpentry hardware mechanical mechanic mechanics maintenance maintain troubleshoot troubleshooting"
            ),
            (
                "⚙",
                "gear gears cog cogs cogwheel settings setting preference preferences customize customization customise customisation adjustment adjustments setup tuning tune"
            ),
            (
                "🔮🪄",
                "wizard wizardry witch witchcraft sorcery sorcerer enchant enchanted enchanting enchantment fantasy fantastical magical magician mystical mystic divination spellcasting"
            ),
            ("🔰", "rookie newcomer newbie learner learning novice beginner beginners starter starting fresh start new"),
            (
                "🖌",
                "paintbrush painter painting artist artists artistic art arts artwork palette pigment color colors colour colours drawing draw designer design designers illustration illustrator creative creativity"
            ),
            (
                "🖐",
                "wave waving greeting greetings hello hi hey highfive high five palm raised hand hands welcoming welcome"
            ),
            (
                "🖱",
                "mouse mice cursor cursors pointer pointing click clicks clicking scroll scrolling input computer computers desktop peripheral peripherals"
            ),
            (
                "🗑",
                "bin bins trash trashcan trash can garbage waste wastepaper wastebasket recycle remove removal discard discarded clean cleaning tidy tidying declutter decluttering"
            ),
            (
                "🧩",
                "puzzle puzzles puzzling jigsaw pieces problem problems solver solving solution solutions addon addons extension extensions plugin plugins logic logical brainteaser brainteasers"
            ),
            (
                "🧭",
                "compass compasses explorer explorers exploration discover discovery discoverer direction directions directional navigation navigating wayfinding orient orientation wander wandering wanderlust adventure adventurer"
            ),
            (
                "🪧",
                "placard placards signage signs signpost billboard announcement announcements protest protesting activist activism message messages motto"
            ),
            (
                "☐☑☒✓✔✗❌",
                "task tasks checklist checklists checkbox checkboxes todo todos to do productivity complete completed completing completion finished finish done checked unchecked"
            ),
            (
                "⚠⛔🚫",
                "warning warnings warned caution cautious dangerous danger hazardous hazard hazards restricted restriction restrictions forbidden prohibited prohibition stop blocked block"
            ),
            (
                "☰",
                "hamburger menu menus navigation nav list lists listing sidebar sections categories index table contents"
            ),
            (
                "♻",
                "recycling recycled recyclable renew renewable sustainability sustainable environmental environment eco ecological ecology circular reuse reusable"
            ),
            (
                "♿",
                "accessible access accessibility inclusive inclusivity inclusion disabled disability wheelchair wheelchairs mobility assistive assistance"
            ),
            ("♀", "female feminine woman women girl girls femininity venus"),
            ("♂", "male masculine man men boy boys masculinity mars"),
            ("⚧", "trans transgender nonbinary non binary gender genderqueer identity inclusive pride"),
            ("🚹", "mens men man male restroom bathroom lavatory washroom"),
            ("🚺", "womens women woman female restroom bathroom lavatory washroom"),
            ("🚻🚽", "restroom restrooms toilet toilets washroom lavatory bathroom bathrooms loo wc facilities"),
            (
                "🚼",
                "baby babies infant infants newborn children kids family parenting nursery changing childcare daycare"
            ),
            (
                "♨",
                "hotspring hot springs thermal geothermal bath bathing spa spas sauna steam steamy wellness relax relaxing relaxation"
            ),
            (
                "🛒",
                "shop shopper shopping store stores grocery groceries supermarket supermarkets purchase purchases purchasing buy buying retail cart carts trolley trolleys basket baskets errands ecommerce e commerce"
            ),
            (
                "😀😁😃😄😇🙂",
                "cheer cheery cheerfulness happiness happy joyful joy delighted delightful pleased pleasure upbeat optimistic optimism"
            ),
            ("😇", "angel angelic halo innocent innocence wholesome well behaved kind kindness good goodness"),
            (
                "😂😆🤣",
                "laugh laughs laughter laughable cracking up rofl lmao hahaha giggle giggling comedian comedy comedic humour humorous humor hilarious"
            ),
            (
                "😅😓",
                "sweaty sweating nervous nerves nerves awkward awkwardness stress stressful stressed worry worried relieved relief phew"
            ),
            (
                "😉😏",
                "wink winking smirk smirking mischievous mischief knowing cheeky flirty flirtation flirting sarcastic sarcasm"
            ),
            (
                "😋",
                "yum nom tasty taste delicious deliciousness savour savor savouring savoring foodie food foodies hungry hunger appetite snacking"
            ),
            (
                "😎",
                "sunglasses sunglasses shades coolness confident confidence relaxed relaxing chill chilling stylish style swag summer"
            ),
            (
                "😐😑😶",
                "meh deadpan flat expression expressionless indifferent indifference unimpressed emotionless blank pokerface poker face quiet silent"
            ),
            (
                "😖😩😫",
                "exhaustion exhausted fatigue fatigued tired tiredness overwhelmed overwhelm fed up frustrated frustration stressed stress suffering struggle struggling"
            ),
            (
                "😛😜😝🤪",
                "goof goofy goofball silliness silly joke jokes joking jokey playful playfulness tongue tongueout wacky crazy zany fun"
            ),
            (
                "😢😭☹",
                "sad sadness sorrow sorrowful tear tears tearful crying cry cried unhappy unhappiness emotional emotion melancholy blue blues"
            ),
            (
                "😤",
                "huff huffing proud pride determined determination resolve stubborn defiant defiance triumph triumphant steam steaming"
            ),
            (
                "😬",
                "eek yikes awkward awkwardness uncomfortable discomfort nervous nervousness embarrassing embarrassment cringe cringing grimace grimacing"
            ),
            (
                "😮😱😳🤯",
                "surprised surprising surprise shock shocked shocking astonished astonishment amazed amazement stunned startling startled disbelief wow"
            ),
            ("😮", "gasp gasping open mouth astonished astonishment amazed amazement disbelief awe awestruck"),
            (
                "😱",
                "scream screaming scared scary frightened fright fear fearful afraid terrified terror panic panicking horror horrified"
            ),
            ("😳", "blush blushing flushed flustered shy shyness embarrassment embarrassed bashful awkward"),
            (
                "🙃🫠",
                "ironic irony sarcasm sarcastic upside down upside down face awkward awkwardness silly silliness uncomfortable melting melt melted"
            ),
            (
                "🙄",
                "eyeroll eye roll rolling eyes boredom bored boring unimpressed annoyed annoyance exasperated exasperation disbelief skeptical sceptical skepticism scepticism"
            ),
            (
                "🙏",
                "praying prayer prayers thank thanks thankful thanking grateful gratitude hope hopeful hoping faith faithful religion religious spirituality spiritual namaste gratitude please wish wishing"
            ),
            (
                "🤓🧐",
                "nerdy geeky intellectual intellect intellects academic academics bookish scholarly smart intelligence intelligent researcher researchers knowledge knowledgeable learning curiosity curious"
            ),
            ("🤓", "nerd nerds geek geeks glasses spectacles study studying student students school homework"),
            (
                "🧐",
                "monocle detective detectives inspect inspecting inspection investigate investigating investigation inquisitive analytical analysis observing observer"
            ),
            (
                "🤘",
                "rock rocknroll rock n roll metal heavy metal metalhead rocker rockers concert concerts music musician musicians horns rebellious punk"
            ),
            (
                "🤡",
                "clown clowns clowning circus joker jest jester foolish fool fools fooling silly silliness comedy comedian prank prankster"
            ),
            (
                "🤢🤮",
                "nauseated nauseous nausea queasy sick sickly sickness ill illness unwell disgust disgusted disgusting gross yuck puke puking vomit vomiting"
            ),
            (
                "🤨",
                "skeptical sceptical skepticism scepticism suspicious suspicion doubt doubting doubtful dubious unsure uncertain question questioning eyebrow raised eyebrow"
            ),
            (
                "🤩",
                "starstruck star struck excited excitement enthusiastic enthusiasm amazed amazement dazzled delighted impressed admiration admire fan fans fandom"
            ),
            (
                "🤬",
                "swear swearing curse cursing profanity furious fury outrage outraged anger angry frustration frustrated annoyed annoyance rage raging"
            ),
            (
                "🤯",
                "mindblown mind blown mindblowing mind blowing explode exploding head overwhelmed overwhelm shocked shock astonished unbelievable disbelief"
            ),
            (
                "🥰😍",
                "adoring adore adored loving love loved crush crushing infatuated infatuation enamored enamoured affectionate affection sweet sweetheart hearts"
            ),
            (
                "🥴",
                "woozy wooziness intoxicated intoxication dizzy dizziness dazed tipsy drunk drunken confused confusion delirious hungover hangover"
            ),
            (
                "🫥",
                "shy shyness introvert introverted introversion invisible invisibility hide hiding disappeared disappearing hidden anonymity anonymous private quiet understated"
            ),
            (
                "◐◑◒◓◖◗",
                "semicircle semi circle hemisphere split divided half halves minimal geometric circle circles rounded"
            ),
            ("◌", "dotted dots dot dashed dashed circle ring loading spinner progress incomplete unfinished"),
            (
                "■□▮▯◧◨◩◪",
                "quadrilateral box boxes block blocks tile tiles rectangle rectangles rectangular square squares grid geometry geometric abstract minimal minimalist"
            ),
            ("◊", "diamond diamonds rhombus lozenge jewel jewels gem gems geometric abstract minimal minimalist"),
            (
                "○◌●◐◑◒◓◖◗◯⭕",
                "circles circular rounded roundness dot dots ring rings orb orbs disk disc ball balls geometric abstract minimal minimalist"
            ),
            (
                "▲△▶▷▼▽◀◁◢◣◤◥◭◮",
                "triangles triangular triad trinity pyramid pyramids geometric abstract minimal minimalist"
            ),
            ("■□▮▯", "square rectangle block box tile minimal grid"),
            ("◊", "diamond rhombus lozenge geometric shape minimal"),
            ("○◌●◐◑◒◓◖◗◯⭕", "circle round circular dot dots orb ring minimal geometric"),
            ("▲△▶▷▼▽◀◁◢◣◤◥◭◮", "triangle triangular geometric shape minimal pyramid"),
        ]
        var result: [String: String] = [:]
        for (glyphs, terms) in groups {
            for glyph in glyphs {
                result[String(glyph), default: ""] += " " + terms
            }
        }
        return result
    }()
}
