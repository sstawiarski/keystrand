#!/usr/bin/env python3
"""Generates Keystrand's bundled sample data.

Writes the Browser "Load sample data" command files and the two Vector Search
sample datasets. The output is deterministic, so running the script again
produces byte-identical files.

Usage: python3 -I scripts/make-sample-data.py
"""

import hashlib
import json
import math
import random
import re
import struct
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BROWSER_DIR = ROOT / "Sources/Features/BrowserFeature/Resources/SampleData"
VECTOR_DIR = ROOT / "Sources/Features/VectorSearchFeature/Resources/SampleData"

EMBEDDING_DIM = 64


# MARK: - Helpers


class Rng:
    """Deterministic choices built only on random.random(), whose sequence Python keeps stable across versions."""

    def __init__(self, seed):
        self._random = random.Random(seed)

    def random(self):
        return self._random.random()

    def below(self, n):
        return min(int(self._random.random() * n), n - 1)

    def choice(self, seq):
        return seq[self.below(len(seq))]

    def between(self, lo, hi):
        return lo + self.below(hi - lo + 1)

    def uniform(self, lo, hi):
        return lo + (hi - lo) * self._random.random()

    def chance(self, p):
        return self._random.random() < p

    def sample(self, seq, k):
        pool = list(seq)
        out = []
        for _ in range(min(k, len(pool))):
            out.append(pool.pop(self.below(len(pool))))
        return out


def dq(value):
    """redis-cli double-quoted argument; bytes outside printable ASCII become \\xHH escapes."""
    data = value if isinstance(value, bytes) else str(value).encode("utf-8")
    out = []
    for byte in data:
        if byte == 0x22:
            out.append('\\"')
        elif byte == 0x5C:
            out.append("\\\\")
        elif 0x20 <= byte <= 0x7E:
            out.append(chr(byte))
        else:
            out.append(f"\\x{byte:02x}")
    return '"' + "".join(out) + '"'


def blob(value):
    """Double-quoted argument for binary data, with spaces escaped too."""
    out = []
    for byte in value:
        if 0x21 <= byte <= 0x7E and byte not in (0x22, 0x27, 0x5C):
            out.append(chr(byte))
        else:
            out.append(f"\\x{byte:02x}")
    return '"' + "".join(out) + '"'


def sq_json(document):
    """Single-quoted JSON argument (`\\'` is the only escape inside single quotes)."""
    text = json.dumps(document, ensure_ascii=True, separators=(",", ":"))
    return "'" + text.replace("'", "\\'") + "'"


def command(*args):
    return " ".join(args)


def write(path, lines):
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"wrote {path.relative_to(ROOT)} ({path.stat().st_size:,} bytes, {sum(1 for line in lines if line)} commands)")


# MARK: - Embeddings


STOPWORDS = set(
    """a an and are as at be but by for from has have in into is it its of on or so that the their them then there
    these this those to up was were with you your can will its it's than very also only most just about over after
    before through while where which when who what all any each every some more less few much many one two three
    out off down along way ready make makes made best good plenty like get keep keeps take takes""".split()
)


def concept_index(table):
    index = {}
    for concept, words in table.items():
        for word in words.split():
            index.setdefault(word, []).append(concept)
    return index


def basis(token):
    """Pseudo-random direction for a token, derived from SHA-256 so it is identical on every machine."""
    values = []
    block = 0
    while len(values) < EMBEDDING_DIM:
        digest = hashlib.sha256(f"{token}#{block}".encode()).digest()
        block += 1
        for i in range(0, len(digest), 2):
            values.append(int.from_bytes(digest[i : i + 2], "little") / 32767.5 - 1.0)
    return values[:EMBEDDING_DIM]


def tokens(text):
    out = []
    for word in re.findall(r"[a-z]+", text.lower()):
        if word in STOPWORDS or len(word) < 2:
            continue
        out.append(word)
    return out


def embed(text, tags, concepts):
    """Hashed bag of words and concepts, L2-normalised. Texts that share concepts point in similar directions."""
    vector = [0.0] * EMBEDDING_DIM

    def add(token, weight):
        for i, value in enumerate(basis(token)):
            vector[i] += weight * value

    for word in tokens(text):
        stem = word[:-1] if len(word) > 4 and word.endswith("s") and not word.endswith("ss") else word
        add("w:" + stem, 0.35)
        for concept in concepts.get(word, []):
            add("c:" + concept, 1.0)
    for tag in tags:
        for word in tag.lower().replace("_", " ").split():
            for concept in concepts.get(word, []):
                add("c:" + concept, 1.5)
        add("t:" + tag.lower(), 0.5)
    norm = math.sqrt(sum(v * v for v in vector)) or 1.0
    return [v / norm for v in vector]


def float32_bytes(vector):
    return struct.pack(f"<{len(vector)}f", *vector)


def cosine_distance(a, b):
    return 1.0 - sum(x * y for x, y in zip(a, b, strict=False))


# MARK: - Trail guides (hash documents, HNSW index)

TRAIL_CONCEPTS = concept_index(
    {
        "waterfall": "waterfall waterfalls falls cascade cascades spray plunge tiered ribbon",
        "lake": "lake lakes tarn tarns shore pond mirrors swim swimming",
        "water": "lake lakes tarn river creek stream swim swimming water meltwater waterfall falls cascade pools",
        "summit": "summit summits peak peaks ridge ridges ascent scramble cairn climb climbs climbing top mountain",
        "views": "views view panorama vistas vista viewpoint viewpoints sweeping overlook",
        "easy": "easy gentle level flat short stroll walk walks ramble unhurried wide anyone",
        "hard": "hard steep strenuous demanding grueling punishing experienced exposed sustained fitness",
        "family": "family families kids children child picnic young",
        "dog": "dog dogs leash owners",
        "forest": "forest forests woods trees canopy grove shade shady needles moss cool",
        "coast": "coast coastal ocean sea cliffs waves tide cove dunes salt beach headland offshore",
        "canyon": "canyon canyons gorge slot arches alcoves wash walls narrows desert",
        "flowers": "flowers wildflowers bloom blossoms meadow meadows",
        "wildlife": "wildlife animals birds graze watch",
        "camping": "camping campsites camp tent overnight backcountry backpacking starry",
        "history": "historic history mining mine ruins cabin lookout settlers mill",
        "glacier": "glacier glaciers ice icebergs moraine crevassed icefield retreating",
        "river": "river creek stream bank footbridges riverside gravel",
        "hotspring": "hot springs steaming soak thermal geothermal pools warm",
        "quiet": "quiet solitude peaceful calm few birdsong",
        "summer": "summer hot afternoon afternoons",
        "snow": "snow winter",
    }
)

REGIONS = {
    "Cascade Range": dict(
        primaries=["waterfall", "lake", "summit", "forest", "glacier", "meadow", "hot_springs", "river"],
        trees=["Douglas fir", "western red cedar", "mountain hemlock", "vine maple"],
        animals=["black-tailed deer", "pikas", "Steller's jays", "mountain goats"],
        flowers=["lupine", "beargrass", "avalanche lilies", "Indian paintbrush"],
        rock="volcanic basalt",
    ),
    "Sierra Nevada": dict(
        primaries=["lake", "summit", "meadow", "glacier", "waterfall", "canyon", "river"],
        trees=["Jeffrey pine", "red fir", "giant sequoia", "quaking aspen"],
        animals=["mule deer", "yellow-bellied marmots", "Clark's nutcrackers", "black bears"],
        flowers=["shooting stars", "corn lilies", "lupine", "mountain asters"],
        rock="pale granite",
    ),
    "Rocky Mountains": dict(
        primaries=["summit", "lake", "meadow", "glacier", "river", "historic", "waterfall"],
        trees=["Engelmann spruce", "lodgepole pine", "subalpine fir", "aspen"],
        animals=["elk", "bighorn sheep", "pikas", "marmots"],
        flowers=["columbine", "alpine sunflowers", "elephant's head", "paintbrush"],
        rock="weathered granite",
    ),
    "Appalachians": dict(
        primaries=["forest", "waterfall", "summit", "river", "historic", "meadow"],
        trees=["tulip poplar", "eastern hemlock", "rhododendron", "red oak"],
        animals=["white-tailed deer", "wild turkeys", "salamanders", "black bears"],
        flowers=["trillium", "flame azalea", "mountain laurel", "bloodroot"],
        rock="old, folded sandstone",
    ),
    "Colorado Plateau": dict(
        primaries=["canyon", "historic", "river", "summit"],
        trees=["pinyon pine", "Utah juniper", "cottonwood", "Gambel oak"],
        animals=["desert bighorn sheep", "ravens", "collared lizards", "canyon wrens"],
        flowers=["globemallow", "prickly pear blossoms", "evening primrose", "sego lilies"],
        rock="red sandstone",
    ),
    "Pacific Coast": dict(
        primaries=["coast", "forest", "river", "waterfall", "historic"],
        trees=["coast redwood", "Sitka spruce", "shore pine", "red alder"],
        animals=["harbor seals", "gray whales", "brown pelicans", "banana slugs"],
        flowers=["sea thrift", "beach strawberry", "Douglas iris", "salal"],
        rock="dark basalt",
    ),
    "Great Lakes": dict(
        primaries=["lake", "coast", "forest", "waterfall", "river", "historic"],
        trees=["white pine", "paper birch", "sugar maple", "northern white cedar"],
        animals=["loons", "beavers", "bald eagles", "white-tailed deer"],
        flowers=["blueberry blossoms", "wild lupine", "fireweed", "lady's slippers"],
        rock="ancient sandstone",
    ),
    "Scottish Highlands": dict(
        primaries=["summit", "lake", "coast", "historic", "river", "waterfall"],
        trees=["Scots pine", "birch", "rowan", "juniper"],
        animals=["red deer", "golden eagles", "ptarmigan", "otters"],
        flowers=["heather", "bog cotton", "sea pinks", "bluebells"],
        rock="grey schist",
    ),
    "Lake District": dict(
        primaries=["lake", "summit", "waterfall", "historic", "forest"],
        trees=["sessile oak", "larch", "birch", "hawthorn"],
        animals=["Herdwick sheep", "red squirrels", "buzzards", "peregrine falcons"],
        flowers=["foxgloves", "bluebells", "wild thyme", "heather"],
        rock="slate",
    ),
    "Dolomites": dict(
        primaries=["summit", "lake", "meadow", "historic", "glacier"],
        trees=["larch", "Swiss stone pine", "Norway spruce", "mountain pine"],
        animals=["chamois", "ibex", "alpine marmots", "golden eagles"],
        flowers=["edelweiss", "gentians", "alpine roses", "globeflowers"],
        rock="pale dolomite limestone",
    ),
    "Patagonia": dict(
        primaries=["glacier", "summit", "lake", "river", "forest"],
        trees=["lenga beech", "coihue", "nire", "calafate shrubs"],
        animals=["guanacos", "Andean condors", "huemul deer", "Magellanic woodpeckers"],
        flowers=["fire bush blossoms", "Patagonian orchids", "calafate flowers", "lupine"],
        rock="jagged granite",
    ),
    "Norwegian Fjords": dict(
        primaries=["coast", "waterfall", "summit", "glacier", "lake"],
        trees=["Norway spruce", "downy birch", "rowan", "Scots pine"],
        animals=["reindeer", "sea eagles", "puffins", "red foxes"],
        flowers=["globeflowers", "cloudberries", "saxifrage", "harebells"],
        rock="polished gneiss",
    ),
    "Southern Alps": dict(
        primaries=["glacier", "summit", "lake", "river", "hot_springs", "forest"],
        trees=["silver beech", "rimu", "mountain totara", "tree ferns"],
        animals=["keas", "tuis", "fantails", "rock wrens"],
        flowers=["Mount Cook buttercups", "mountain daisies", "flax flowers", "gentians"],
        rock="greywacke",
    ),
    "Ozarks": dict(
        primaries=["forest", "river", "waterfall", "canyon", "historic"],
        trees=["shortleaf pine", "white oak", "sycamore", "dogwood"],
        animals=["wild turkeys", "river otters", "box turtles", "pileated woodpeckers"],
        flowers=["redbud", "wild azalea", "coneflowers", "fire pinks"],
        rock="limestone",
    ),
}

NAME_WORDS = """Cedar Hidden Silver Eagle Bear Juniper Lonesome Raven Granite Willow Fern Copper Echo Larkspur Bramble
Osprey Heron Aspen Hemlock Marten Thistle Sparrow Quarry Misty Windy Sunset Moonrise Blackberry Kestrel Lupine Tamarack
Basalt Sandstone Foxglove Otter Elk Bluebell Shadow Lantern Pioneer Alder Birch Cinder Driftwood Ember Falcon Glacier
Harrier Ironwood Kingfisher Lichen Maple Nettle Obsidian Pika Quartz Rowan Saddle Timber Umber Vista Wren Yarrow""".split()

NAME_PATTERNS = {
    "waterfall": ["{w} Falls Trail", "{w} Cascades Loop", "{w} Falls Path", "Upper {w} Falls"],
    "lake": ["{w} Lake Trail", "{w} Tarn Loop", "{w} Lakes Basin", "{w} Lake Shore Path"],
    "summit": ["{w} Peak", "{w} Ridge Route", "Mount {w} Summit Trail", "{w} Knob"],
    "coast": ["{w} Headland Path", "{w} Cove Trail", "{w} Bluffs Walk", "{w} Point Loop"],
    "canyon": ["{w} Canyon Trail", "{w} Gorge Walk", "{w} Narrows", "{w} Wash Loop"],
    "forest": ["{w} Woods Loop", "{w} Grove Trail", "{w} Forest Path", "{w} Hollow Trail"],
    "meadow": ["{w} Meadows Trail", "{w} Flats Loop", "{w} Park Trail"],
    "river": ["{w} River Trail", "{w} Creek Path", "{w} Bend Loop"],
    "glacier": ["{w} Glacier Overlook", "{w} Icefield Trail", "{w} Moraine Route"],
    "hot_springs": ["{w} Hot Springs Trail", "{w} Springs Path"],
    "historic": ["{w} Mine Trail", "Old {w} Road", "{w} Lookout Trail", "{w} Mill Walk"],
}

TRAIL_OPENINGS = {
    "waterfall": [
        "{name} follows a path shaded by {tree} to a waterfall that drops in a long white ribbon over {rock}.",
        "This {route} in the {region} ends at a misty cascade where the spray keeps the rocks green all summer.",
        "The highlight of {name} is a tiered waterfall, best in spring when snowmelt turns the creek into a roar.",
    ],
    "lake": [
        "{name} climbs gently to a clear lake ringed by {tree}, with a pebbly shore made for a long lunch.",
        "This {route} visits a chain of small alpine lakes, each colder and bluer than the last and fine for a quick swim.",
        "A calm lake sits at the end of {name}, and on still mornings it mirrors the surrounding ridges perfectly.",
    ],
    "summit": [
        "{name} is a sustained climb to a rocky summit with a sweeping panorama across the {region}.",
        "This {route} follows an exposed ridge of {rock} to a peak where the views stretch for miles.",
        "Expect a steep, rewarding ascent: the final scramble on {name} leads to a windy summit cairn.",
    ],
    "coast": [
        "{name} traces the edge of high sea cliffs, with waves crashing below and {animal} often visible offshore.",
        "This {route} drops through windswept dunes to a quiet cove that is best explored at low tide.",
        "Salt air, tide pools and long ocean views make {name} one of the finest coastal walks in the {region}.",
    ],
    "canyon": [
        "{name} winds through a narrow canyon of {rock}, where the walls glow orange in the late afternoon light.",
        "This {route} follows a dry wash into a deep gorge, passing natural arches and sculpted alcoves.",
        "Shade is scarce on {name}, but the slot canyon at its heart is cool, quiet and remarkable.",
    ],
    "forest": [
        "{name} is a peaceful ramble under a tall canopy of {tree}, soft underfoot with needles and moss.",
        "This {route} wanders through old-growth forest, where the light is green and the only sound is birdsong.",
        "Dense woods keep {name} shady and cool even on hot afternoons, which makes it a dependable summer choice.",
    ],
    "meadow": [
        "{name} rises through open meadows that fill with {flower} in early summer.",
        "This {route} crosses a broad subalpine meadow where {animal} graze in the evening.",
        "Rolling meadows and wide skies define {name}, with gentle grades that suit an unhurried pace.",
    ],
    "river": [
        "{name} follows a clear river upstream, passing swimming holes and gravel bars along the way.",
        "This {route} hugs the bank of a lively creek and crosses it twice on sturdy wooden footbridges.",
        "The sound of moving water stays with you on {name}, a pleasant riverside walk among {tree}.",
    ],
    "glacier": [
        "{name} climbs over an old moraine to a viewpoint facing a blue, crevassed glacier.",
        "This {route} leads to the toe of a retreating glacier, where icebergs drift in a milky meltwater lake.",
        "Ice, rock and thundering meltwater surround the upper section of {name}, one of the wildest walks in the {region}.",
    ],
    "hot_springs": [
        "{name} ends at natural hot springs, where steaming pools invite a long soak after the hike.",
        "This {route} follows a warm creek to a cluster of rock-lined thermal pools tucked among {tree}.",
        "The reward for walking {name} is a soak in geothermal pools with a view of the valley below.",
    ],
    "historic": [
        "{name} follows an old mining road past rusting machinery and the stone ruins of a miners' cabin.",
        "This {route} climbs to a historic fire lookout that is still staffed during the dry season.",
        "Interpretive signs along {name} tell the story of the settlers who built the stone walls and the old mill.",
    ],
}

TRAIL_SECONDARY = {
    "waterfall": "A short side path leads to a small waterfall that is worth the detour.",
    "lake": "Halfway along, a small lake makes a good place to rest and cool your feet.",
    "summit": "An optional spur climbs to a rocky viewpoint on the ridge for a wider view.",
    "coast": "The last stretch opens onto a beach where you can watch the waves roll in.",
    "canyon": "A side canyon with smooth {rock} walls invites some exploring.",
    "forest": "The first stretch passes through cool forest of {tree}.",
    "meadow": "Near the top the trail crosses a meadow bright with {flower}.",
    "river": "Early on, the route follows a lively creek with a few easy crossings.",
    "glacier": "On clear days a distant glacier gleams above the valley.",
    "hot_springs": "A small warm spring beside the trail is a pleasant surprise in cold weather.",
    "historic": "Look for the remains of an old homestead and its stone chimney near the trailhead.",
}

TRAIL_DIFFICULTY = {
    "easy": [
        "The path is wide and nearly level, covering {dist} km with only {gain} m of climbing.",
        "At {dist} km with a gentle {gain} m of elevation gain, it is an easy outing for almost anyone.",
    ],
    "moderate": [
        "Plan on a moderate {dist} km with {gain} m of steady uphill, broken up by plenty of places to rest.",
        "The trail gains {gain} m over {dist} km, enough to get the heart pumping without wearing you out.",
    ],
    "hard": [
        "This is a hard day: {dist} km and {gain} m of climbing, with steep, rocky stretches near the top.",
        "Expect a demanding {dist} km with {gain} m of elevation gain; good boots and an early start are essential.",
    ],
    "strenuous": [
        "Only experienced hikers should attempt this strenuous {dist} km route, which gains a punishing {gain} m.",
        "With {gain} m of ascent packed into {dist} km, this is a long, grueling test of fitness and navigation.",
    ],
}

TRAIL_EXTRAS = {
    "dog_friendly": [
        "Dogs are welcome on a leash, and there is fresh water for them along the way.",
        "It is a favorite with dog owners, who appreciate the shade and the creek crossings.",
    ],
    "kid_friendly": [
        "Families with young children will find plenty to explore, from stepping stones to a picnic clearing.",
        "Kids love the short distance and the little bridges, so bring a picnic and take your time.",
    ],
    "camping": [
        "Backcountry campsites near the end make it a good first overnight trip.",
        "A few tent sites near the water allow a relaxed overnight under a starry sky.",
    ],
    "wildflowers": ["In early summer the slopes are bright with {flower}."],
    "wildlife": ["Watch for {animal}, especially early in the morning."],
    "views": ["Several viewpoints open up wide vistas over the surrounding valleys."],
    "quiet": ["Few people make it this far, so solitude is almost guaranteed on weekdays."],
}

TRAIL_SEASONS = [
    "It is at its best in late spring, when the creeks run high.",
    "Autumn brings golden {tree} and cool, clear hiking weather.",
    "Snow lingers on the upper section until early summer, so check conditions before you go.",
    "The trail is open year-round, though the lower section can be muddy after rain.",
]

TRAIL_RANGES = {
    "easy": ((1.5, 6.0), (30, 250)),
    "moderate": ((5.0, 12.0), (250, 700)),
    "hard": ((10.0, 20.0), (700, 1300)),
    "strenuous": ((15.0, 30.0), (1200, 2200)),
}


def make_trails(count=200):
    rng = Rng(1729)
    names = set()
    trails = []
    regions = list(REGIONS)
    while len(trails) < count:
        region_name = regions[len(trails) % len(regions)]
        region = REGIONS[region_name]
        primary = rng.choice(region["primaries"])
        if primary in ("summit", "glacier"):
            difficulty = rng.choice(["moderate", "hard", "hard", "strenuous"])
        elif primary in ("forest", "meadow", "river", "lake", "waterfall", "hot_springs"):
            difficulty = rng.choice(["easy", "easy", "moderate", "moderate", "hard"])
        else:
            difficulty = rng.choice(["easy", "moderate", "moderate", "hard"])
        name = rng.choice(NAME_PATTERNS[primary]).format(w=rng.choice(NAME_WORDS))
        if name in names:
            continue
        names.add(name)
        if "Loop" in name:
            route = "loop"
        else:
            route = rng.choice(["out-and-back trail", "out-and-back trail", "point-to-point route", "loop"])
        (dlo, dhi), (glo, ghi) = TRAIL_RANGES[difficulty]
        dist = round(rng.uniform(dlo, dhi), 1)
        gain = int(round(rng.uniform(glo, ghi) / 10.0) * 10)

        features = [primary]
        others = [p for p in region["primaries"] if p != primary]
        for secondary in rng.sample(others, rng.between(0, 2)):
            features.append(secondary)
        if primary == "summit" or rng.chance(0.3):
            features.append("views")
        if "meadow" in features or rng.chance(0.2):
            features.append("wildflowers")
        if rng.chance(0.25):
            features.append("wildlife")
        if difficulty in ("easy", "moderate") and rng.chance(0.55 if difficulty == "easy" else 0.25):
            features.append("kid_friendly")
        if difficulty != "strenuous" and rng.chance(0.4):
            features.append("dog_friendly")
        if rng.chance(0.45 if difficulty in ("hard", "strenuous") else 0.15):
            features.append("camping")
        if rng.chance(0.15):
            features.append("quiet")
        features = list(dict.fromkeys(features))

        fill = dict(
            name=name,
            region=region_name,
            route=route,
            tree=rng.choice(region["trees"]),
            animal=rng.choice(region["animals"]),
            flower=rng.choice(region["flowers"]),
            rock=region["rock"],
            dist=f"{dist:g}",
            gain=gain,
        )
        sentences = [rng.choice(TRAIL_OPENINGS[primary])]
        for secondary in features[1:]:
            if secondary in TRAIL_SECONDARY:
                sentences.append(TRAIL_SECONDARY[secondary])
        sentences.append(rng.choice(TRAIL_DIFFICULTY[difficulty]))
        for extra in features:
            if extra in TRAIL_EXTRAS:
                sentences.append(rng.choice(TRAIL_EXTRAS[extra]))
        if rng.chance(0.6):
            sentences.append(rng.choice(TRAIL_SEASONS))
        description = " ".join(s.format(**fill) for s in sentences)
        description = description[0].upper() + description[1:]

        text = f"{name}. {description}"
        embedding = embed(text, features + [difficulty], TRAIL_CONCEPTS)
        trails.append(
            dict(
                name=name,
                region=region_name,
                difficulty=difficulty,
                features=",".join(features),
                distance_km=dist,
                elevation_gain_m=gain,
                description=description,
                embedding=embedding,
            )
        )
    return trails


# MARK: - Recipe ideas (JSON documents, FLAT index)

RECIPE_CONCEPTS = concept_index(
    {
        "soup": "soup soups broth bowl bowls chowder pho ramen stew stews",
        "comfort": "warming warms comforting comfort hearty cozy cold chilly evening winter slow simmered",
        "spicy": "spicy heat chilies chili chile chiles curry gochujang gochugaru harissa jalapeno fiery doubanjiang hot",
        "fresh": "fresh bright crisp light herbs herby mint cilantro basil parsley dill summer",
        "zesty": "zesty lemon lemony lime citrus tangy vinegar sumac pickled",
        "crunchy": "crunchy crisp crispy toasted crunch",
        "pasta": "pasta spaghetti lasagna macaroni noodles",
        "noodle": "noodles noodle ramen pho vermicelli slurpable",
        "rice": "rice risotto biryani bowl",
        "quick": "quick weeknight fast minutes speedy",
        "sweet": "sweet dessert desserts chocolate sugar caramel maple syrup tart pudding brownies mousse treat",
        "chocolate": "chocolate cocoa brownies mousse",
        "breakfast": "breakfast morning brunch pancakes oats granola eggs frittata",
        "meat": "chicken beef pork lamb turkey bacon chorizo pancetta carnitas",
        "seafood": "fish prawns shrimp clams salmon tuna lobster seafood",
        "veg": "vegetable vegetables veggies spinach kale zucchini eggplant peppers cauliflower squash mushroom mushrooms",
        "plant": "vegan plant tofu chickpea chickpeas lentil lentils beans dal",
        "rich": "rich creamy cream cheese cheddar parmesan butter silky indulgent gruyere ricotta mozzarella",
        "smoky": "smoky charred grilled grill smoked chipotle",
        "salad": "salad salads crunchy greens",
        "baked": "baked bake oven golden bubbling roasted",
        "share": "share party crowd",
    }
)

# (title pattern, cuisine, course, method, base ingredients, gluten, dairy, egg, minutes, flavors, options)
# Each option is (label, extra ingredients, kinds) where kinds lists any of meat, fish, dairy, egg, gluten.
DISHES = [
    ("{opt} Green Curry", "Thai", "main", "curry",
     ["coconut milk", "green curry paste", "Thai basil", "makrut lime leaves", "jasmine rice"], False, False, False,
     (25, 40), ["spicy", "fragrant", "creamy"],
     [("Chicken", ["chicken thighs"], "meat"), ("Tofu", ["firm tofu"], ""), ("Prawn", ["prawns"], "fish"),
      ("Pumpkin", ["pumpkin", "green beans"], "")]),
    ("Thai Basil {opt} Stir-Fry", "Thai", "main", "stirfry",
     ["holy basil", "bird's eye chilies", "garlic", "soy sauce", "jasmine rice"], True, False, False,
     (15, 25), ["spicy", "savory", "fragrant"],
     [("Chicken", ["ground chicken"], "meat"), ("Pork", ["ground pork"], "meat"), ("Tofu", ["firm tofu"], ""),
      ("Mushroom", ["oyster mushrooms"], "")]),
    ("{opt} Tom Kha Soup", "Thai", "soup", "soup",
     ["coconut milk", "galangal", "lemongrass", "lime juice", "cilantro"], False, False, False,
     (25, 35), ["creamy", "tangy", "fragrant"],
     [("Chicken", ["chicken breast"], "meat"), ("Mushroom", ["straw mushrooms"], ""), ("Prawn", ["prawns"], "fish")]),
    ("{opt} Ramen", "Japanese", "main", "noodles",
     ["ramen noodles", "white miso", "soft-boiled eggs", "scallions", "nori"], True, False, True,
     (40, 90), ["savory", "rich", "hearty"],
     [("Pork Belly", ["pork belly"], "meat"), ("Miso Mushroom", ["shiitake mushrooms"], ""),
      ("Chicken", ["chicken thighs"], "meat")]),
    ("Teriyaki {opt} Rice Bowl", "Japanese", "main", "rice",
     ["short-grain rice", "teriyaki sauce", "pickled ginger", "sesame seeds", "cucumber"], True, False, False,
     (20, 30), ["sweet", "savory"],
     [("Salmon", ["salmon fillets"], "fish"), ("Chicken", ["chicken thighs"], "meat"), ("Tofu", ["firm tofu"], ""),
      ("Eggplant", ["Japanese eggplant"], "")]),
    ("{opt} Gyoza", "Japanese", "snack", "dumpling",
     ["dumpling wrappers", "napa cabbage", "ginger", "garlic chives", "rice vinegar"], True, False, False,
     (45, 60), ["savory", "crunchy"],
     [("Pork", ["ground pork"], "meat"), ("Shrimp", ["shrimp"], "fish"), ("Vegetable", ["shiitake mushrooms"], "")]),
    ("{opt} Bibimbap", "Korean", "main", "rice",
     ["steamed rice", "gochujang", "spinach", "bean sprouts", "fried egg"], False, False, True,
     (35, 50), ["spicy", "savory"],
     [("Beef", ["bulgogi beef"], "meat"), ("Tofu", ["crispy tofu"], ""), ("Mushroom", ["king oyster mushrooms"], "")]),
    ("{opt} Kimchi Stew", "Korean", "soup", "stew",
     ["aged kimchi", "gochugaru", "silken tofu", "onions", "scallions"], False, False, False,
     (30, 40), ["spicy", "tangy", "hearty"],
     [("Pork", ["pork shoulder"], "meat"), ("Tuna", ["canned tuna"], "fish"), ("Mushroom", ["enoki mushrooms"], "")]),
    ("{opt} Tikka Masala", "Indian", "main", "curry",
     ["tomatoes", "garam masala", "ginger", "yogurt", "cream"], False, True, False,
     (40, 60), ["creamy", "spicy", "rich"],
     [("Chicken", ["chicken thighs"], "meat"), ("Paneer", ["paneer"], ""), ("Chickpea", ["chickpeas"], "")]),
    ("{opt} Dal", "Indian", "main", "stew",
     ["red lentils", "turmeric", "cumin seeds", "garlic", "cilantro"], False, False, False,
     (30, 45), ["earthy", "hearty", "fragrant"],
     [("Spinach", ["spinach"], ""), ("Tomato", ["tomatoes"], ""), ("Coconut", ["coconut milk"], "")]),
    ("{opt} Biryani", "Indian", "main", "rice",
     ["basmati rice", "saffron", "fried onions", "mint", "whole spices"], False, False, False,
     (60, 90), ["fragrant", "rich"],
     [("Chicken", ["chicken thighs"], "meat"), ("Lamb", ["lamb shoulder"], "meat"),
      ("Vegetable", ["cauliflower", "peas"], "")]),
    ("{opt} Pakoras", "Indian", "snack", "fried",
     ["chickpea flour", "green chilies", "cumin", "cilantro chutney"], False, False, False,
     (25, 35), ["crunchy", "spicy"],
     [("Onion", ["onions"], ""), ("Spinach", ["spinach"], ""), ("Cauliflower", ["cauliflower"], "")]),
    ("Spaghetti with {opt}", "Italian", "main", "pasta",
     ["spaghetti", "garlic", "olive oil", "parmesan", "chili flakes"], True, True, False,
     (20, 30), ["zesty", "fresh"],
     [("Clams", ["clams", "white wine"], "fish"), ("Roasted Tomatoes", ["cherry tomatoes"], ""),
      ("Zucchini and Lemon", ["zucchini", "lemon"], "")]),
    ("{opt} Risotto", "Italian", "main", "rice",
     ["arborio rice", "white wine", "parmesan", "butter", "vegetable stock"], False, True, False,
     (35, 45), ["creamy", "rich", "earthy"],
     [("Mushroom", ["porcini mushrooms"], ""), ("Butternut Squash", ["butternut squash", "sage"], ""),
      ("Pea and Mint", ["peas", "mint"], "")]),
    ("{opt} Lasagna", "Italian", "main", "bake",
     ["lasagna sheets", "ricotta", "mozzarella", "tomato sauce", "basil"], True, True, False,
     (75, 100), ["rich", "hearty", "savory"],
     [("Beef", ["ground beef"], "meat"), ("Spinach", ["spinach"], ""),
      ("Roasted Vegetable", ["eggplant", "red peppers"], "")]),
    ("Minestrone with {opt}", "Italian", "soup", "soup",
     ["cannellini beans", "celery", "carrots", "small pasta", "tomatoes"], True, False, False,
     (40, 55), ["hearty", "herby"],
     [("Pesto", ["basil pesto"], "dairy"), ("Kale", ["kale"], ""), ("Pancetta", ["pancetta"], "meat")]),
    ("{opt} Panzanella", "Italian", "salad", "salad",
     ["day-old bread", "ripe tomatoes", "red onion", "basil", "red wine vinegar"], True, False, False,
     (15, 20), ["fresh", "tangy"],
     [("Summer", ["cucumber"], ""), ("Peach", ["peaches"], ""), ("Burrata", ["burrata"], "dairy")]),
    ("{opt} Frittata", "Italian", "breakfast", "skillet",
     ["eggs", "olive oil", "parmesan", "onions"], False, True, True,
     (25, 35), ["savory", "herby"],
     [("Spinach and Feta", ["spinach", "feta"], ""), ("Potato and Chorizo", ["potatoes", "chorizo"], "meat"),
      ("Asparagus", ["asparagus"], "")]),
    ("{opt} Tacos", "Mexican", "main", "grill",
     ["corn tortillas", "lime", "pickled red onion", "cilantro", "salsa verde"], False, False, False,
     (25, 45), ["spicy", "zesty", "fresh"],
     [("Fish", ["white fish"], "fish"), ("Carnitas", ["pork shoulder"], "meat"), ("Black Bean", ["black beans"], ""),
      ("Chipotle Mushroom", ["mushrooms", "chipotle peppers"], "")]),
    ("{opt} Enchiladas", "Mexican", "main", "bake",
     ["corn tortillas", "red chile sauce", "cheddar", "onions", "sour cream"], False, True, False,
     (45, 60), ["smoky", "rich", "hearty"],
     [("Chicken", ["shredded chicken"], "meat"), ("Cheese", ["Monterey Jack"], ""),
      ("Sweet Potato", ["sweet potatoes"], "")]),
    ("{opt} Pozole", "Mexican", "soup", "stew",
     ["hominy", "dried chiles", "oregano", "radishes", "cabbage"], False, False, False,
     (60, 120), ["hearty", "smoky", "spicy"],
     [("Pork", ["pork shoulder"], "meat"), ("Chicken", ["chicken thighs"], "meat"),
      ("Jackfruit", ["young jackfruit"], "")]),
    ("{opt} Chili", "American", "main", "stew",
     ["kidney beans", "tomatoes", "chili powder", "cumin", "onions"], False, False, False,
     (45, 90), ["smoky", "spicy", "hearty"],
     [("Beef", ["ground beef"], "meat"), ("Turkey", ["ground turkey"], "meat"),
      ("Three Bean", ["pinto beans", "black beans"], "")]),
    ("{opt} Mac and Cheese", "American", "main", "bake",
     ["elbow macaroni", "sharp cheddar", "milk", "butter", "breadcrumbs"], True, True, False,
     (30, 45), ["creamy", "rich"],
     [("Baked", ["mustard powder"], ""), ("Broccoli", ["broccoli"], ""), ("Lobster", ["lobster"], "fish"),
      ("Green Chile", ["roasted green chiles"], "")]),
    ("{opt} Burgers", "American", "main", "grill",
     ["brioche buns", "lettuce", "tomato", "pickles", "burger sauce"], True, False, True,
     (25, 35), ["smoky", "savory"],
     [("Beef", ["ground chuck"], "meat"), ("Black Bean", ["black beans"], ""), ("Turkey", ["ground turkey"], "meat")]),
    ("{opt} Pancakes", "American", "breakfast", "breakfast",
     ["flour", "buttermilk", "eggs", "butter", "maple syrup"], True, True, True,
     (20, 30), ["sweet"],
     [("Blueberry", ["blueberries"], ""), ("Banana", ["bananas"], ""), ("Lemon Ricotta", ["ricotta", "lemon"], "")]),
    ("{opt} Chowder", "American", "soup", "soup",
     ["potatoes", "milk", "celery", "onions", "thyme"], False, True, False,
     (35, 45), ["creamy", "hearty", "smoky"],
     [("Clam", ["clams", "bacon"], "fish meat"), ("Corn", ["sweet corn"], ""),
      ("Smoked Salmon", ["smoked salmon"], "fish")]),
    ("Roasted {opt} Soup", "American", "soup", "soup",
     ["onions", "vegetable stock", "olive oil", "thyme", "garlic"], False, False, False,
     (40, 55), ["hearty", "earthy"],
     [("Tomato", ["tomatoes"], ""), ("Butternut Squash", ["butternut squash"], ""),
      ("Cauliflower", ["cauliflower"], ""), ("Carrot and Ginger", ["carrots", "ginger"], ""),
      ("Red Pepper", ["red peppers"], "")]),
    ("{opt} Brownies", "American", "dessert", "dessert",
     ["flour", "dark chocolate", "butter", "eggs", "brown sugar"], True, True, True,
     (35, 45), ["sweet", "rich"],
     [("Fudgy", ["cocoa powder"], ""), ("Salted Caramel", ["caramel sauce", "sea salt"], ""),
      ("Walnut", ["walnuts"], "")]),
    ("{opt} Granola", "American", "breakfast", "breakfast",
     ["rolled oats", "maple syrup", "olive oil", "pumpkin seeds"], True, False, False,
     (40, 50), ["sweet", "crunchy"],
     [("Cherry Almond", ["dried cherries", "almonds"], ""), ("Coconut Cashew", ["coconut flakes", "cashews"], ""),
      ("Ginger Pecan", ["crystallized ginger", "pecans"], "")]),
    ("{opt} Overnight Oats", "American", "breakfast", "breakfast",
     ["rolled oats", "chia seeds", "almond milk", "maple syrup"], True, False, False,
     (5, 10), ["sweet", "creamy"],
     [("Berry", ["mixed berries"], ""), ("Peanut Butter Banana", ["peanut butter", "bananas"], ""),
      ("Apple Cinnamon", ["apples", "cinnamon"], "")]),
    ("{opt} Shakshuka", "Middle Eastern", "breakfast", "skillet",
     ["eggs", "tomatoes", "red peppers", "cumin", "paprika"], False, False, True,
     (25, 35), ["spicy", "savory"],
     [("Harissa", ["harissa"], ""), ("Green", ["spinach", "leeks"], ""), ("Feta", ["feta"], "dairy")]),
    ("{opt} Falafel Pitas", "Middle Eastern", "main", "fried",
     ["chickpeas", "parsley", "tahini sauce", "pita bread", "pickled turnips"], True, False, False,
     (40, 50), ["crunchy", "herby", "fresh"],
     [("Herb", ["dill", "cilantro"], ""), ("Sweet Potato", ["sweet potatoes"], ""), ("Spicy", ["green chilies"], "")]),
    ("{opt} Fattoush", "Middle Eastern", "salad", "salad",
     ["romaine", "toasted pita", "cucumber", "sumac", "pomegranate molasses"], True, False, False,
     (20, 25), ["fresh", "tangy", "crunchy"],
     [("Chicken", ["grilled chicken"], "meat"), ("Halloumi", ["halloumi"], "dairy"), ("Radish", ["radishes"], "")]),
    ("{opt} Lentil Soup", "Middle Eastern", "soup", "soup",
     ["red lentils", "cumin", "lemon", "onions", "carrots"], False, False, False,
     (30, 40), ["hearty", "zesty", "earthy"],
     [("Lemony", ["lemon zest"], ""), ("Spiced", ["Aleppo pepper"], ""), ("Spinach", ["spinach"], "")]),
    ("{opt} Tagine", "Moroccan", "main", "stew",
     ["preserved lemon", "green olives", "ras el hanout", "onions", "couscous"], True, False, False,
     (60, 120), ["fragrant", "sweet", "hearty"],
     [("Chicken", ["chicken thighs"], "meat"), ("Lamb", ["lamb shoulder"], "meat"),
      ("Chickpea and Apricot", ["chickpeas", "dried apricots"], "")]),
    ("{opt} Couscous Salad", "Moroccan", "salad", "salad",
     ["couscous", "mint", "parsley", "lemon", "toasted almonds"], True, False, False,
     (20, 30), ["fresh", "herby", "zesty"],
     [("Roasted Carrot", ["carrots"], ""), ("Chickpea", ["chickpeas"], ""),
      ("Grilled Halloumi", ["halloumi"], "dairy")]),
    ("{opt} Pho", "Vietnamese", "soup", "noodles",
     ["rice noodles", "star anise", "charred ginger", "bean sprouts", "Thai basil"], False, False, False,
     (45, 180), ["fragrant", "savory", "hearty"],
     [("Beef", ["beef brisket"], "meat"), ("Chicken", ["whole chicken"], "meat"),
      ("Mushroom", ["shiitake mushrooms"], "")]),
    ("{opt} Banh Mi", "Vietnamese", "main", "sandwich",
     ["baguette", "pickled carrots and daikon", "cilantro", "jalapeno", "mayonnaise"], True, False, True,
     (30, 40), ["fresh", "tangy", "crunchy"],
     [("Lemongrass Pork", ["pork shoulder", "lemongrass"], "meat"), ("Tofu", ["crispy tofu"], ""),
      ("Chicken", ["chicken thighs"], "meat")]),
    ("{opt} Summer Rolls", "Vietnamese", "snack", "rolls",
     ["rice paper", "vermicelli", "mint", "lettuce", "peanut sauce"], False, False, False,
     (25, 35), ["fresh", "herby"],
     [("Shrimp", ["shrimp"], "fish"), ("Tofu", ["tofu"], ""), ("Mango", ["mango"], "")]),
    ("{opt} Gratin", "French", "side", "bake",
     ["potatoes", "cream", "gruyere", "garlic", "thyme"], False, True, False,
     (60, 75), ["rich", "creamy"],
     [("Potato", ["nutmeg"], ""), ("Leek and Potato", ["leeks"], ""), ("Cauliflower", ["cauliflower"], "")]),
    ("Ratatouille with {opt}", "French", "main", "stew",
     ["eggplant", "zucchini", "red peppers", "tomatoes", "herbes de Provence"], False, False, False,
     (50, 70), ["herby", "fresh", "earthy"],
     [("Goat Cheese", ["goat cheese"], "dairy"), ("White Beans", ["white beans"], ""), ("Polenta", ["polenta"], "")]),
    ("{opt} French Onion Soup", "French", "soup", "soup",
     ["onions", "gruyere", "baguette", "thyme", "butter"], True, True, False,
     (75, 90), ["rich", "savory", "hearty"],
     [("Classic", ["beef stock"], "meat"), ("Mushroom", ["mushroom stock"], "")]),
    ("{opt} Tart", "French", "dessert", "dessert",
     ["pastry", "butter", "sugar", "eggs", "cream"], True, True, True,
     (60, 90), ["sweet", "rich"],
     [("Apple", ["apples"], ""), ("Lemon", ["lemons"], ""), ("Pear and Almond", ["pears", "ground almonds"], ""),
      ("Chocolate", ["dark chocolate"], "")]),
    ("{opt} Chocolate Mousse", "French", "dessert", "dessert",
     ["dark chocolate", "vanilla", "sea salt"], False, False, False,
     (20, 30), ["sweet", "rich", "creamy"],
     [("Classic", ["eggs", "cream"], "egg dairy"), ("Avocado", ["avocados", "maple syrup"], ""),
      ("Aquafaba", ["aquafaba"], "")]),
    ("{opt} Coconut Rice Pudding", "Thai", "dessert", "dessert",
     ["jasmine rice", "coconut milk", "palm sugar", "pandan leaves"], False, False, False,
     (35, 45), ["sweet", "creamy", "fragrant"],
     [("Mango", ["mango"], ""), ("Black Sesame", ["black sesame seeds"], ""), ("Banana", ["bananas"], "")]),
    ("{opt} Souvlaki", "Greek", "main", "grill",
     ["oregano", "lemon", "garlic", "pita bread", "tzatziki"], True, True, False,
     (30, 45), ["zesty", "smoky", "herby"],
     [("Chicken", ["chicken thighs"], "meat"), ("Pork", ["pork loin"], "meat"), ("Halloumi", ["halloumi"], "")]),
    ("{opt} Greek Salad", "Greek", "salad", "salad",
     ["tomatoes", "cucumber", "kalamata olives", "feta", "red onion"], False, True, False,
     (10, 15), ["fresh", "tangy"],
     [("Village", ["green peppers"], ""), ("Chickpea", ["chickpeas"], ""), ("Grilled Shrimp", ["shrimp"], "fish")]),
    ("{opt} Fried Rice", "Chinese", "main", "stirfry",
     ["day-old rice", "eggs", "scallions", "soy sauce", "sesame oil"], True, False, True,
     (15, 20), ["savory", "smoky"],
     [("Shrimp", ["shrimp"], "fish"), ("Chicken", ["chicken breast"], "meat"),
      ("Vegetable", ["peas", "carrots"], ""), ("Kimchi", ["kimchi"], "")]),
    ("{opt} Dan Dan Noodles", "Chinese", "main", "noodles",
     ["wheat noodles", "Sichuan peppercorns", "chili oil", "sesame paste", "bok choy"], True, False, False,
     (25, 35), ["spicy", "rich", "savory"],
     [("Pork", ["ground pork"], "meat"), ("Crispy Tofu", ["firm tofu"], ""), ("Mushroom", ["shiitake mushrooms"], "")]),
    ("{opt} Mapo Tofu", "Chinese", "main", "stirfry",
     ["silken tofu", "doubanjiang", "Sichuan peppercorns", "garlic", "scallions"], True, False, False,
     (20, 30), ["spicy", "savory"],
     [("Pork", ["ground pork"], "meat"), ("Mushroom", ["minced shiitake"], "")]),
    ("{opt} Hot and Sour Soup", "Chinese", "soup", "soup",
     ["tofu", "wood ear mushrooms", "rice vinegar", "white pepper", "eggs"], True, False, True,
     (30, 40), ["spicy", "tangy"],
     [("Pork", ["pork loin"], "meat"), ("Chicken", ["chicken breast"], "meat"), ("Vegetable", ["bamboo shoots"], "")]),
]

RECIPE_OPENINGS = {
    "curry": [
        "{title} is {a_f1} curry of {i1} simmered in {b0} with {i2} until the sauce coats a spoon.",
        "Fragrant with {i2} and {i3}, this {cuisine} curry is {f1} and deeply satisfying over rice.",
    ],
    "stew": [
        "{A_f1}, slow-simmered stew of {i1} and {i2} that tastes even better the next day.",
        "{I1}, {i2} and {i3} cook down into {a_f1} pot that warms you from the inside out on a cold evening.",
    ],
    "soup": [
        "{A_f1} soup of {i1} and {i2}, perfect for a chilly evening.",
        "This warming bowl brings together {i1}, {i2} and {i3} in {a_f1}, comforting broth.",
    ],
    "noodles": [
        "Slurpable {b0} meet {i1} and {i2} in {a_f1} bowl of noodles.",
        "{A_f1} noodle bowl layered with {i1}, {i2} and a generous handful of {i3}.",
    ],
    "pasta": [
        "Al dente {b0} tossed with {i1}, {i2} and a little {i3}.",
        "{A_f1} weeknight pasta of {i1} and {i2} that comes together while the water boils.",
    ],
    "rice": [
        "{A_f1} rice dish of {i1} with {i2} and {i3}.",
        "Tender {b0} soaks up {i1} and {i2} in this {f1} {cuisine} favorite.",
    ],
    "salad": [
        "{A_f1}, crunchy salad of {i1}, {i2} and {i3}.",
        "Bright and fresh, this salad of {i1} and {i2} is ideal for a hot summer lunch.",
    ],
    "grill": [
        "Charred over high heat, {i1} meet {i2}, {i3} and plenty of {b0}.",
        "{A_f1} grilled dish with {i1} and {i2}, made for long summer evenings outdoors.",
    ],
    "bake": [
        "Baked until bubbling and golden, this {f1} dish layers {i1}, {i2} and {i3}.",
        "{A_f1} oven bake of {i1} and {i2} that feeds a crowd with very little fuss.",
    ],
    "stirfry": [
        "A fast, {f1} stir-fry of {i1} with {i2} and {i3}.",
        "Into a smoking-hot wok go {i1}, {i2} and {i3} for {a_f1} dinner in minutes.",
    ],
    "dumpling": [
        "Crisp-bottomed dumplings filled with {i1} and {i2}, served with a tangy dipping sauce.",
        "Pleated by hand and pan-fried, these {f1} dumplings hide {i1} and {i2} inside.",
    ],
    "fried": [
        "Golden fritters of {i1} and {i2}, crisp outside and tender within.",
        "{A_f1} plate of {i1} and {i2}, fried until crunchy and served hot.",
    ],
    "breakfast": [
        "{A_f1} breakfast of {i1} and {i2} to start a slow weekend morning.",
        "{I1} and {i2} make this {f1} morning dish easy to love.",
    ],
    "skillet": [
        "{A_f1} skillet of {i1} and {i2}, served straight from the pan for brunch.",
        "Eggs gently set in {a_f1} base of {i1} and {i2}, finished with fresh herbs.",
    ],
    "sandwich": [
        "{A_f1} sandwich stacked with {i1}, {i2} and {i3}.",
        "Crusty {b0} filled with {i1}, {i2} and a little heat.",
    ],
    "rolls": [
        "Translucent {b0} wrapped around {i1}, {i2} and crisp {i3}.",
        "Light, {f1} rolls of {i1} and {i2}, served with a nutty dipping sauce.",
    ],
    "dessert": [
        "{A_f1} dessert of {i1} and {i2}, rich enough to share.",
        "{I1} and {i2} turn into {a_f1} treat that ends any meal on a high note.",
    ],
}

RECIPE_FLAVOR_NOTES = {
    "spicy": "It brings real heat, so adjust the chilies to taste.",
    "smoky": "A smoky depth makes it taste like it cooked all day.",
    "fresh": "Lots of fresh herbs keep it light and bright.",
    "creamy": "The texture is silky and creamy without being heavy.",
    "tangy": "A squeeze of citrus at the end adds a tangy lift.",
    "herby": "Plenty of chopped herbs go in right before serving.",
    "rich": "It is rich and indulgent, so a small portion goes a long way.",
    "crunchy": "Every bite has a satisfying crunch.",
    "fragrant": "Warm spices make the whole kitchen smell wonderful.",
    "earthy": "The flavor is earthy and mellow.",
    "hearty": "It is hearty enough to be a meal on its own.",
    "sweet": "It is gently sweet rather than sugary.",
    "savory": "It is deeply savory, the kind of dish you crave on a rainy night.",
    "zesty": "A bright, zesty finish keeps every mouthful lively.",
}

RECIPE_TIMING = {
    "quick": "Ready in {minutes} minutes, it is an easy weeknight dinner.",
    "quick_other": "It is ready in about {minutes} minutes.",
    "medium": "Allow about {minutes} minutes from start to finish.",
    "long": "It takes about {minutes} minutes, most of it hands-off, so it suits a lazy Sunday.",
}

RECIPE_DIET_NOTES = {
    "vegan": "Entirely plant-based.",
    "gluten_free": "Naturally gluten-free.",
    "make_ahead": "Leftovers keep well for lunches.",
}

MAKE_AHEAD_METHODS = {"stew", "soup", "bake", "curry"}
PROTEIN_WORDS = ("chicken", "beef", "pork", "lamb", "turkey", "tofu", "chickpea", "lentil", "salmon", "prawn",
                 "shrimp", "tuna", "paneer", "halloumi", "bean", "clam", "lobster", "fish", "eggs")


def make_recipes():
    rng = Rng(4211)
    recipes = []
    for (pattern, cuisine, course, method, base, gluten, dairy, egg, (mlo, mhi), flavors, options) in DISHES:
        for label, extra, kinds in options:
            kinds = set(kinds.split())
            title = pattern.format(opt=label)
            ingredients = extra + base
            meat = "meat" in kinds
            fish = "fish" in kinds
            has_dairy = dairy or "dairy" in kinds
            has_egg = egg or "egg" in kinds
            tags = []
            if not meat and not fish:
                tags.append("vegetarian")
                if not has_dairy and not has_egg:
                    tags.append("vegan")
            if not gluten:
                tags.append("gluten_free")
            if not has_dairy:
                tags.append("dairy_free")
            joined = " ".join(ingredients).lower()
            if course in ("main", "soup", "breakfast") and any(word in joined for word in PROTEIN_WORDS):
                tags.append("high_protein")
            minutes = int(round(rng.between(mlo, mhi) / 5.0) * 5) or 5
            if minutes <= 30:
                tags.append("quick")
            if "spicy" in flavors:
                tags.append("spicy")
            if method in MAKE_AHEAD_METHODS and course != "dessert":
                tags.append("make_ahead")

            others = [x for x in ingredients if x not in (extra[0], base[0])]
            picked = rng.sample(others, 3) + [base[0]] * 3
            f1 = rng.choice(flavors)
            fill = dict(title=title, cuisine=cuisine, f1=f1, b0=base[0], i1=extra[0], i2=picked[0], i3=picked[1])
            fill["I1"] = fill["i1"][0].upper() + fill["i1"][1:]
            fill["a_f1"] = ("an " if f1[0] in "aeiou" else "a ") + f1
            fill["A_f1"] = fill["a_f1"].capitalize()
            sentences = [rng.choice(RECIPE_OPENINGS[method]).format(**fill)]
            for flavor in [f for f in flavors if f != f1][:1] + ([f1] if rng.chance(0.3) else []):
                sentences.append(RECIPE_FLAVOR_NOTES[flavor])
            timing = "quick" if minutes <= 30 else ("medium" if minutes <= 60 else "long")
            if timing == "quick" and course not in ("main", "soup"):
                timing = "quick_other"
            sentences.append(RECIPE_TIMING[timing].format(minutes=minutes))
            for note in ("vegan", "gluten_free", "make_ahead"):
                if note in tags and rng.chance(0.5):
                    sentences.append(RECIPE_DIET_NOTES[note])
            summary = " ".join(dict.fromkeys(sentences))

            text = f"{title}. {summary} {cuisine} {course}. " + " ".join(ingredients)
            embedding = embed(text, tags + [course], RECIPE_CONCEPTS)
            recipes.append(
                dict(
                    title=title,
                    cuisine=cuisine,
                    course=course,
                    tags=tags,
                    ingredients=ingredients,
                    minutes=minutes,
                    servings=rng.choice([2, 4, 4, 4, 6, 8]) if course != "snack" else rng.choice([4, 6, 12]),
                    summary=summary,
                    embedding=[round(v, 5) for v in embedding],
                )
            )
    return recipes


# MARK: - Vector Search output

TRAIL_INDEX = "idx:trails_vss"
TRAIL_PREFIX = "trail:"
RECIPE_INDEX = "idx:recipes_vss"
RECIPE_PREFIX = "recipe:"


def query_blob(text, tags, concepts):
    return blob(float32_bytes(embed(text, tags, concepts)))


def trail_queries():
    def knn(filter_expr, k, text, tags, returns):
        return (f'FT.SEARCH {TRAIL_INDEX} "{filter_expr}=>[KNN {k} @description_embedding $query_vector AS score]" '
                f"RETURN {len(returns)} {' '.join(returns)} "
                f"PARAMS 2 query_vector {query_blob(text, tags, TRAIL_CONCEPTS)} SORTBY score DIALECT 2")

    return [
        dict(
            name="Basic semantic search",
            description="Finds the 3 trails whose descriptions are closest in meaning to \"An easy family walk to a "
            "waterfall.\" Returns the distance score with the name, difficulty, and description. A lower score means "
            "a closer match.",
            query=knn("*", 3, "An easy family walk to a waterfall", [], ["score", "name", "difficulty", "description"]),
        ),
        dict(
            name="Intent search",
            description="Searches for \"A long, steep climb to a summit with big views for experienced hikers.\" The "
            "query never says \"hard\" or \"strenuous\", yet the closest trails are demanding summit routes, because "
            "the embedding captures intent rather than exact keywords.",
            query=knn("*", 3, "A long, steep climb to a summit with big views for experienced hikers", [],
                      ["score", "name", "difficulty", "elevation_gain_m", "description"]),
        ),
        dict(
            name="Dog walk search",
            description="Finds trails similar to \"A shady forest loop where I can bring my dog.\" Shows how the "
            "embedding groups trails by what they offer, such as shade, forest, and dog-friendly paths.",
            query=knn("*", 5, "A shady forest loop where I can bring my dog", [],
                      ["score", "name", "region", "features"]),
        ),
        dict(
            name="Hybrid search (vector + filters)",
            description="Combines semantic search with attribute filters. Searches for \"A quiet lake for a swim on a "
            "summer afternoon\" but only among easy or moderate trails shorter than 10 km. The filters run before KNN "
            "and narrow the candidate set.",
            query=knn("(@difficulty:{easy|moderate} @distance_km:[0 10])", 3,
                      "A quiet lake for a swim on a summer afternoon", [],
                      ["score", "name", "difficulty", "distance_km", "description"]),
        ),
    ]


def recipe_queries(recipes):
    def knn(filter_expr, k, vector_arg, returns):
        return (f'FT.SEARCH {RECIPE_INDEX} "{filter_expr}=>[KNN {k} @embedding $vec AS score]" '
                f"PARAMS 2 vec {vector_arg} SORTBY score RETURN {len(returns)} {' '.join(returns)} DIALECT 2")

    def text_vector(text):
        return query_blob(text, [], RECIPE_CONCEPTS)

    seed_index = next(i for i, r in enumerate(recipes) if r["title"] == "Chicken Tikka Masala")
    seed = recipes[seed_index]
    seed_vector = blob(float32_bytes(seed["embedding"]))
    return [
        dict(
            name="Basic semantic search",
            description="Finds the 3 recipes closest in meaning to \"A warming bowl of soup for a cold evening.\" "
            "Returns the title, summary, and distance score. The matches are soups and stews even when their summaries "
            "use different words.",
            query=knn("*", 3, text_vector("A warming bowl of soup for a cold evening"), ["title", "summary", "score"]),
        ),
        dict(
            name="Cuisine-filtered semantic search",
            description="Restricts the search to Italian recipes with a tag filter, then ranks them by similarity to "
            "\"Quick weeknight pasta with lots of vegetables.\" Pre-filtering narrows the candidates before KNN runs.",
            query=knn("@cuisine:{Italian} ", 5, text_vector("Quick weeknight pasta with lots of vegetables"),
                      ["title", "cuisine", "minutes", "score"]),
        ),
        dict(
            name="More like this",
            description=f"Uses the stored embedding of {RECIPE_PREFIX}{seed_index + 1:03d} ({seed['title']}) as the "
            "query vector, so the results are the dishes most similar to it. This is how content-based "
            "recommendations work without generating new embeddings.",
            query=knn("*", 5, seed_vector, ["title", "cuisine", "score"]),
        ),
        dict(
            name="Multi-filter hybrid search",
            description="Combines a diet tag and a time range with vector search. Finds vegetarian recipes that take "
            "30 minutes or less and match \"Something fresh and crunchy for a hot summer day.\"",
            query=knn("(@tags:{vegetarian} @minutes:[0 30]) ", 5, text_vector("Something fresh and crunchy for a hot summer day"),
                      ["title", "tags", "minutes", "score"]),
        ),
        dict(
            name="Diet-aware search",
            description="Filters to recipes tagged vegan or gluten_free, then ranks them by similarity to \"A rich "
            "chocolate dessert.\" A tag filter with | matches any of the listed values.",
            query=knn("@tags:{vegan|gluten_free} ", 5, text_vector("A rich chocolate dessert"),
                      ["title", "tags", "score"]),
        ),
    ]


def write_vector_search():
    trails = make_trails()
    recipes = make_recipes()

    trail_lines = []
    for i, trail in enumerate(trails, start=1):
        trail_lines.append(command(
            "HSET", f"{TRAIL_PREFIX}{i:03d}",
            "name", dq(trail["name"]),
            "region", dq(trail["region"]),
            "difficulty", dq(trail["difficulty"]),
            "features", dq(trail["features"]),
            "distance_km", f"{trail['distance_km']:g}",
            "elevation_gain_m", str(trail["elevation_gain_m"]),
            "description", dq(trail["description"]),
            "description_embedding", blob(float32_bytes(trail["embedding"])),
        ))
    write(VECTOR_DIR / "trails", trail_lines)

    recipe_lines = []
    for i, recipe in enumerate(recipes, start=1):
        recipe_lines.append(command("JSON.SET", f"{RECIPE_PREFIX}{i:03d}", "$", sq_json(recipe)))
    write(VECTOR_DIR / "recipes", recipe_lines)

    first_trail = trails[0]
    first_recipe = recipes[0]
    datasets = {
        "datasets": [
            {
                "id": "trail-guides",
                "displayName": "Trail guides",
                "indexName": TRAIL_INDEX,
                "indexPrefix": TRAIL_PREFIX,
                "collectionName": "trails",
                "fields": [
                    {"id": "name", "name": "name", "value": first_trail["name"], "type": "LTEXT"},
                    {"id": "region", "name": "region", "value": first_trail["region"], "type": "LTAG"},
                    {"id": "difficulty", "name": "difficulty", "value": first_trail["difficulty"], "type": "LTAG"},
                    {"id": "features", "name": "features", "value": first_trail["features"], "type": "LTAG"},
                    {"id": "distance_km", "name": "distance_km", "value": first_trail["distance_km"],
                     "type": "LNUMERIC"},
                    {"id": "elevation_gain_m", "name": "elevation_gain_m", "value": first_trail["elevation_gain_m"],
                     "type": "LNUMERIC"},
                    {"id": "description", "name": "description", "value": first_trail["description"][:80],
                     "type": "LTEXT"},
                    {"id": "description_embedding", "name": "description_embedding",
                     "value": f"HNSW, FLOAT32, {EMBEDDING_DIM}, COSINE", "type": "LVECTOR"},
                ],
                "sampleQueries": trail_queries(),
            },
            {
                "id": "recipe-ideas",
                "displayName": "Recipe ideas",
                "indexName": RECIPE_INDEX,
                "indexPrefix": RECIPE_PREFIX,
                "collectionName": "recipes",
                "fields": [
                    {"id": "title", "name": "title", "value": first_recipe["title"], "type": "LTEXT"},
                    {"id": "cuisine", "name": "cuisine", "value": first_recipe["cuisine"], "type": "LTAG"},
                    {"id": "course", "name": "course", "value": first_recipe["course"], "type": "LTAG"},
                    {"id": "tags", "name": "tags", "value": ", ".join(first_recipe["tags"]), "type": "LTAG"},
                    {"id": "summary", "name": "summary", "value": first_recipe["summary"][:80], "type": "LTEXT"},
                    {"id": "minutes", "name": "minutes", "value": first_recipe["minutes"], "type": "LNUMERIC"},
                    {"id": "embedding", "name": "embedding", "value": f"FLAT, FLOAT32, {EMBEDDING_DIM}, COSINE",
                     "type": "LVECTOR"},
                ],
                "sampleQueries": recipe_queries(recipes),
            },
        ]
    }
    path = VECTOR_DIR / "vector-search-sample-data.json"
    path.write_text(json.dumps(datasets, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"wrote {path.relative_to(ROOT)} ({path.stat().st_size:,} bytes)")
    return trails, recipes


# MARK: - Browser sample data (Riverbend Public Library)

BOOKS = [
    ("Pride and Prejudice", "Jane Austen", 1813, "fiction,romance", 432),
    ("Moby-Dick", "Herman Melville", 1851, "fiction,adventure", 720),
    ("Frankenstein", "Mary Shelley", 1818, "fiction,horror,science_fiction", 280),
    ("Dracula", "Bram Stoker", 1897, "fiction,horror", 418),
    ("The Time Machine", "H. G. Wells", 1895, "fiction,science_fiction", 118),
    ("Middlemarch", "George Eliot", 1871, "fiction", 880),
    ("Jane Eyre", "Charlotte Bronte", 1847, "fiction,romance", 532),
    ("Great Expectations", "Charles Dickens", 1861, "fiction", 544),
    ("War and Peace", "Leo Tolstoy", 1869, "fiction,historical", 1296),
    ("Anna Karenina", "Leo Tolstoy", 1878, "fiction,romance", 864),
    ("The Count of Monte Cristo", "Alexandre Dumas", 1844, "fiction,adventure", 1276),
    ("Little Women", "Louisa May Alcott", 1868, "fiction,young_adult", 449),
    ("The Adventures of Sherlock Holmes", "Arthur Conan Doyle", 1892, "fiction,mystery", 307),
    ("Treasure Island", "Robert Louis Stevenson", 1883, "fiction,adventure,children", 292),
    ("The Picture of Dorian Gray", "Oscar Wilde", 1890, "fiction,horror", 254),
    ("Wuthering Heights", "Emily Bronte", 1847, "fiction,romance", 416),
    ("Crime and Punishment", "Fyodor Dostoevsky", 1866, "fiction", 671),
    ("Walden", "Henry David Thoreau", 1854, "nonfiction,nature", 352),
    ("Leaves of Grass", "Walt Whitman", 1855, "poetry", 464),
    ("The Call of the Wild", "Jack London", 1903, "fiction,adventure", 172),
    ("Alice's Adventures in Wonderland", "Lewis Carroll", 1865, "fiction,children,fantasy", 192),
    ("Twenty Thousand Leagues Under the Seas", "Jules Verne", 1870, "fiction,science_fiction,adventure", 448),
    ("The War of the Worlds", "H. G. Wells", 1898, "fiction,science_fiction", 287),
    ("Heart of Darkness", "Joseph Conrad", 1899, "fiction", 96),
    ("Emma", "Jane Austen", 1815, "fiction,romance", 474),
    ("Persuasion", "Jane Austen", 1817, "fiction,romance", 249),
    ("The Scarlet Letter", "Nathaniel Hawthorne", 1850, "fiction,historical", 238),
    ("Les Misérables", "Victor Hugo", 1862, "fiction,historical", 1463),
    ("Don Quixote", "Miguel de Cervantes", 1605, "fiction,adventure", 1072),
    ("A Tale of Two Cities", "Charles Dickens", 1859, "fiction,historical", 489),
    ("Strange Case of Dr Jekyll and Mr Hyde", "Robert Louis Stevenson", 1886, "fiction,horror", 139),
    ("Around the World in Eighty Days", "Jules Verne", 1872, "fiction,adventure", 256),
    ("The Jungle Book", "Rudyard Kipling", 1894, "fiction,children", 277),
    ("The Wind in the Willows", "Kenneth Grahame", 1908, "fiction,children", 302),
    ("Anne of Green Gables", "L. M. Montgomery", 1908, "fiction,young_adult", 429),
    ("The Secret Garden", "Frances Hodgson Burnett", 1911, "fiction,children", 331),
    ("Peter Pan", "J. M. Barrie", 1911, "fiction,children,fantasy", 267),
    ("The Wonderful Wizard of Oz", "L. Frank Baum", 1900, "fiction,children,fantasy", 259),
    ("Black Beauty", "Anna Sewell", 1877, "fiction,children", 255),
    ("The Hound of the Baskervilles", "Arthur Conan Doyle", 1902, "fiction,mystery", 256),
    ("The Brothers Karamazov", "Fyodor Dostoevsky", 1880, "fiction", 824),
    ("Madame Bovary", "Gustave Flaubert", 1857, "fiction", 368),
    ("Sense and Sensibility", "Jane Austen", 1811, "fiction,romance", 409),
    ("Oliver Twist", "Charles Dickens", 1838, "fiction", 608),
    ("David Copperfield", "Charles Dickens", 1850, "fiction", 882),
    ("The Adventures of Tom Sawyer", "Mark Twain", 1876, "fiction,adventure,young_adult", 274),
    ("Adventures of Huckleberry Finn", "Mark Twain", 1884, "fiction,adventure", 366),
    ("The Last of the Mohicans", "James Fenimore Cooper", 1826, "fiction,historical,adventure", 432),
    ("Ivanhoe", "Walter Scott", 1819, "fiction,historical", 528),
    ("The Three Musketeers", "Alexandre Dumas", 1844, "fiction,adventure,historical", 704),
    ("Journey to the Center of the Earth", "Jules Verne", 1864, "fiction,science_fiction,adventure", 240),
    ("The Invisible Man", "H. G. Wells", 1897, "fiction,science_fiction", 160),
    ("Kidnapped", "Robert Louis Stevenson", 1886, "fiction,adventure", 288),
    ("The Moonstone", "Wilkie Collins", 1868, "fiction,mystery", 528),
    ("The Woman in White", "Wilkie Collins", 1859, "fiction,mystery", 720),
    ("North and South", "Elizabeth Gaskell", 1854, "fiction,romance", 521),
    ("Silas Marner", "George Eliot", 1861, "fiction", 192),
    ("The Turn of the Screw", "Henry James", 1898, "fiction,horror", 128),
    ("The Awakening", "Kate Chopin", 1899, "fiction", 195),
    ("A Room with a View", "E. M. Forster", 1908, "fiction,romance", 256),
    ("On the Origin of Species", "Charles Darwin", 1859, "nonfiction,science", 502),
    ("The Souls of Black Folk", "W. E. B. Du Bois", 1903, "nonfiction,history", 265),
    ("Narrative of the Life of Frederick Douglass", "Frederick Douglass", 1845, "nonfiction,biography", 125),
    ("A Vindication of the Rights of Woman", "Mary Wollstonecraft", 1792, "nonfiction,history", 340),
]

BRANCHES = [
    ("central", "Central Library", "100 Main Street", -93.2650, 44.9778, "09:00", "20:00"),
    ("riverside", "Riverside Branch", "42 River Road", -93.2471, 44.9686, "10:00", "18:00"),
    ("hillcrest", "Hillcrest Branch", "7 Summit Avenue", -93.2902, 44.9855, "10:00", "18:00"),
    ("northgate", "Northgate Branch", "1550 Northgate Parkway", -93.2733, 45.0109, "09:30", "19:00"),
    ("lakeview", "Lakeview Branch", "318 Shoreline Drive", -93.3089, 44.9479, "10:00", "17:00"),
    ("eastfield", "Eastfield Bookmobile Depot", "9 Depot Lane", -93.2118, 44.9731, "08:00", "16:00"),
]

MEMBERS = [
    ("Ada Whitfield", "adult", "central"), ("Bram Okafor", "adult", "riverside"),
    ("Carmen Ruiz", "senior", "hillcrest"), ("Dev Patel", "student", "central"),
    ("Elin Sorensen", "adult", "lakeview"), ("Farah Haddad", "adult", "northgate"),
    ("Gus Lindqvist", "child", "riverside"), ("Hana Mori", "student", "central"),
    ("Ivo Novak", "senior", "eastfield"), ("June Abernathy", "adult", "hillcrest"),
    ("Kofi Mensah", "adult", "central"), ("Lena Petrova", "child", "lakeview"),
]

PROGRAMS = [
    ("Toddler Story Time", "children", "Songs, rhymes and picture books for children under three and their grown-ups."),
    ("Teen Graphic Novel Club", "teens", "Monthly discussion of a graphic novel chosen by the group, with snacks."),
    ("Classic Book Circle", "adults", "A relaxed discussion group reading one public-domain classic each month."),
    ("Seed Library Swap", "community", "Bring seeds saved from your garden and take home something new to plant."),
    ("Resume Workshop", "adults", "One-on-one help polishing a resume and practicing interview questions."),
    ("Beginner Coding Lab", "teens", "An introduction to programming with friendly puzzles; laptops provided."),
    ("Local History Walk", "community", "A guided walk past historic buildings with stories from the archive."),
    ("Bilingual Story Time", "children", "Stories and songs in English and Spanish for children ages three to six."),
    ("Tech Help Drop-In", "seniors", "Bring a phone, tablet or laptop and get patient help from volunteers."),
    ("Poetry Open Mic", "adults", "Share an original poem or a favorite by someone else; all voices welcome."),
    ("Lego Builders", "children", "Free building time with a new challenge every week."),
    ("Author Talk", "community", "A visiting author discusses their research and answers questions."),
]

def tiny_png(width, height, rgb):
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)

    raw = b"".join(b"\x00" + bytes(rgb) * width for _ in range(height))
    header = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b"")


def write_browser():
    rng = Rng(808)
    day_ms = 86_400_000
    base_ms = 1_760_918_400_000  # 2025-10-20T00:00:00Z
    lines = []

    lines += [
        command("SET", "library:config:name", dq("Riverbend Public Library")),
        command("SET", "library:config:opening_hours", dq("Mon-Thu 09:00-20:00; Fri-Sat 09:00-17:00; Sun 12:00-17:00")),
        command("SET", "library:config:loan_policy", sq_json(
            {"loan_days": 21, "renewals": 2, "max_items": 15, "daily_fine": 0.25, "fine_cap": 10.0,
             "holds": {"max_active": 10, "pickup_days": 7}})),
        command("SET", "library:announcement",
                dq("The Riverside branch is closed on Monday while new carpet is installed."), "EX", "604800"),
        command("SET", "library:cache:search:catalog:austen",
                dq('{"query":"austen","hits":[1,25,26,43],"took_ms":4}'), "EX", "3600"),
        command("SET", "library:locks:checkout:terminal-3", dq("member:1004"), "EX", "900"),
        command("SET", "library:covers:thumb:1", blob(tiny_png(6, 9, (138, 47, 53)))),
        command("SET", "library:covers:thumb:2", blob(tiny_png(6, 9, (31, 78, 121)))),
        command("SET", "library:shelves:café-corner", dq("Newspapers, magazines and the community notice board")),
        command("SET", dq(b"library:legacy:\xc0\xffrecord"),
                dq("Imported from the old catalogue system; the key name is not valid UTF-8")),
        command("SET", "library:legacy:barcode_scan", blob(b"\x02RB-0001-\x00\x1f\xfe\xff\x03")),
    ]
    for day in range(7):
        date = f"2025-10-{14 + day:02d}"
        lines.append(command("SET", f"library:stats:visits:{date}", str(rng.between(240, 520))))
    lines.append(command("SET", "library:stats:checkouts:total", "48213"))
    lines.append("")

    for i, (title, author, year, genres, pages) in enumerate(BOOKS[:30], start=1):
        copies = rng.between(1, 6)
        lines.append(command(
            "HSET", f"library:books:{i}", "title", dq(title), "author", dq(author), "year", str(year),
            "genre", dq(genres), "pages", str(pages), "copies", str(copies),
            "available", str(rng.between(0, copies)), "shelf", dq(f"{rng.choice('ABCDEFGH')}{rng.between(1, 24)}"),
            "branch", BRANCHES[rng.below(5)][0]))
    lines.append("")

    for i, (name, card, branch) in enumerate(MEMBERS, start=1001):
        first = name.split()[0].lower()
        lines.append(command(
            "HSET", f"library:members:{i}", "name", dq(name), "email", dq(f"{first}@example.org"),
            "card_type", card, "home_branch", branch, "joined", f"20{rng.between(12, 25):02d}-{rng.between(1, 12):02d}-"
            f"{rng.between(1, 28):02d}", "active_loans", str(rng.between(0, 9)), "fines_due", f"{rng.below(9) * 0.25:.2f}"))
    lines.append(command("HSET", dq(b"library:members:\xfe\xed-import"), "name", dq("Legacy Card"),
                         "note", dq("Binary key name from a migrated system")))
    lines.append("")

    for slug, name, address, _lon, _lat, opens, closes in BRANCHES:
        lines.append(command("HSET", f"library:branches:{slug}", "name", dq(name), "address", dq(address),
                             "phone", f"555-01{rng.between(10, 99)}", "opens", opens, "closes", closes))
    lines.append(command("GEOADD", "library:branches:locations",
                         *[f"{lon} {lat} {slug}" for slug, _, _, lon, lat, _, _ in BRANCHES]))
    lines.append("")

    for n in range(8):
        token = hashlib.sha1(f"session-{n}".encode()).hexdigest()[:12]
        member = 1001 + rng.below(len(MEMBERS))
        key = f"library:sessions:{token}"
        lines.append(command("HSET", key, "member_id", str(member), "device", dq(rng.choice(
            ["self-checkout kiosk", "iPhone app", "web catalogue", "Android app", "branch desktop"])),
            "started_at", f"2025-10-20T{9 + n:02d}:{rng.between(0, 59):02d}:00Z"))
        lines.append(command("EXPIRE", key, str([900, 1800, 3600, 7200, 86400, 172800, 604800, 2592000][n])))
    lines.append("")

    for book in (3, 12, 21):
        members = rng.sample([str(m) for m in range(1001, 1013)], rng.between(2, 5))
        lines.append(command("RPUSH", f"library:holds:books:{book}", *members))
    lines.append(command("LPUSH", "library:returns:dropbox", *[f"book:{rng.between(1, 30)}" for _ in range(9)]))
    lines.append(command("RPUSH", "library:activity:recent", *[dq(s) for s in [
        "Ada Whitfield renewed Middlemarch", "Hillcrest received 12 new large-print titles",
        "Dev Patel placed a hold on Frankenstein", "Story time moved to the community room",
        "Kofi Mensah returned The Time Machine", "Riverside self-checkout kiosk restarted"]]))
    lines.append("")

    lines.append(command("SADD", "library:genres", *sorted({g for _, _, _, genres, _ in BOOKS for g in genres.split(",")})))
    for member in (1001, 1004, 1008):
        lines.append(command("SADD", f"library:members:{member}:favorites",
                             *[str(b) for b in rng.sample(range(1, 31), rng.between(3, 6))]))
    for tag in ("staff_picks", "book_club", "large_print"):
        lines.append(command("SADD", f"library:collections:{tag}",
                             *[f"book:{b}" for b in rng.sample(range(1, 31), rng.between(4, 8))]))
    lines.append("")

    scores = []
    for i in range(1, 31):
        scores += [str(rng.between(3, 140)), f"book:{i}"]
    lines.append(command("ZADD", "library:rankings:checkouts:2025-10", *scores))
    due = []
    for loan in range(5001, 5016):
        due += [str(1_760_918_400 + rng.between(-5, 21) * 86_400), f"loan:{loan}"]
    lines.append(command("ZADD", "library:loans:due", *due))
    challenge = []
    for i, (_name, _, _) in enumerate(MEMBERS, start=1001):
        challenge += [str(rng.between(120, 4200)), str(i)]
    lines.append(command("ZADD", "library:challenges:summer_reading", *challenge))
    lines.append("")

    stream = "library:events:circulation"
    ids = []
    for n in range(20):
        entry_id = f"{base_ms + n * 1_800_000 + rng.between(0, 900_000)}-0"
        ids.append(entry_id)
        action = rng.choice(["checkout", "checkout", "return", "renew", "hold"])
        lines.append(command("XADD", stream, entry_id, "action", action, "member", str(1001 + rng.below(12)),
                             "book", str(rng.between(1, 30)), "branch", BRANCHES[rng.below(5)][0]))
    lines.append(command("XGROUP", "CREATE", stream, "notifications", "0"))
    lines.append(command("XGROUP", "CREATE", stream, "analytics", "$"))
    lines.append(command("XREADGROUP", "GROUP", "notifications", "email-worker", "COUNT", "6", "STREAMS", stream, ">"))
    lines.append(command("XREADGROUP", "GROUP", "notifications", "sms-worker", "COUNT", "3", "STREAMS", stream, ">"))
    lines.append(command("XACK", stream, "notifications", ids[0], ids[1], ids[2]))
    for n in range(8):
        lines.append(command("XADD", "library:events:door_counter", "*", "branch", BRANCHES[n % 5][0],
                             "entered", str(rng.between(5, 60)), "exited", str(rng.between(5, 60))))
    lines.append("")

    for day in range(3):
        visitors = [f"visitor:{rng.between(1, 900):04d}" for _ in range(60)]
        lines.append(command("PFADD", f"library:visitors:unique:2025-10-{18 + day:02d}", *visitors))
    lines.append("")

    for member in range(len(MEMBERS) * 3):
        if rng.chance(0.55):
            lines.append(command("SETBIT", "library:members:active:2025-10", str(member), "1"))
    for day in range(31):
        if day % 7 not in (5, 6) or rng.chance(0.3):
            lines.append(command("SETBIT", "library:branches:eastfield:open_days:2025-10", str(day), "1"))

    write(BROWSER_DIR / "common", lines)

    catalog = []
    for i, (title, author, year, genres, pages) in enumerate(BOOKS, start=1):
        formats = [{"type": "hardcover" if rng.chance(0.4) else "paperback", "copies": rng.between(1, 6)}]
        if rng.chance(0.7):
            formats.append({"type": "ebook", "licenses": rng.between(2, 20)})
        if rng.chance(0.4):
            formats.append({"type": "audiobook", "licenses": rng.between(1, 8),
                            "narrator": rng.choice(["M. Ellison", "R. Okoro", "S. Brandt", "T. Nakamura"])})
        availability = {slug: rng.between(0, 3) for slug, *_ in BRANCHES[:5] if rng.chance(0.6)}
        document = {
            "title": title,
            "authors": [author],
            "published": year,
            "language": "en" if i not in (9, 10, 11, 17, 28, 29, 41, 42, 50) else "en (translation)",
            "genres": genres.split(","),
            "pages": pages,
            "formats": formats,
            "availability": availability,
            "rating": {"average": round(rng.uniform(3.4, 4.9), 1), "count": rng.between(12, 900)},
            "public_domain": True,
            "added": f"20{rng.between(15, 25):02d}-{rng.between(1, 12):02d}-{rng.between(1, 28):02d}",
        }
        catalog.append(command("JSON.SET", f"library:catalog:{i}", "$", sq_json(document)))

    programs = []
    n = 1
    for week in range(2):
        for title, audience, description in PROGRAMS:
            slug, _, _, lon, lat, _, _ = BRANCHES[rng.below(5)]
            capacity = rng.choice([12, 20, 25, 30, 40, 60])
            document = {
                "title": title,
                "audience": audience,
                "branch": slug,
                "location": f"{lon},{lat}",
                "starts": f"2025-11-{3 + week * 7 + rng.below(5):02d}T{rng.choice(['10:30', '14:00', '16:00', '18:30'])}:00",
                "duration_min": rng.choice([45, 60, 90]),
                "capacity": capacity,
                "registered": rng.between(0, capacity),
                "free": True,
                "description": description,
            }
            programs.append(command("JSON.SET", f"library:programs:{n}", "$", sq_json(document)))
            n += 1

    reading_lists = []
    for i, (name, _, _) in enumerate(MEMBERS[:6], start=1001):
        items = [{"book": f"library:catalog:{b}", "status": rng.choice(["want", "reading", "finished"])}
                 for b in rng.sample(range(1, len(BOOKS) + 1), rng.between(3, 6))]
        reading_lists.append(command("JSON.SET", f"library:members:{i}:reading_list", "$",
                                     sq_json({"owner": name, "public": rng.chance(0.5), "items": items})))
    write(BROWSER_DIR / "json", catalog + [""] + programs + [""] + reading_lists)

    write(BROWSER_DIR / "search", [
        "FT.CREATE idx:library_books ON HASH PREFIX 1 library:books: SCHEMA title TEXT WEIGHT 2 SORTABLE "
        "author TEXT SORTABLE genre TAG SEPARATOR , year NUMERIC SORTABLE pages NUMERIC available NUMERIC "
        "branch TAG",
        "",
        "FT.CREATE idx:library_catalog ON JSON PREFIX 1 library:catalog: SCHEMA $.title AS title TEXT WEIGHT 2 "
        "$.authors[*] AS authors TAG $.genres[*] AS genres TAG $.published AS published NUMERIC SORTABLE "
        "$.pages AS pages NUMERIC $.rating.average AS rating NUMERIC SORTABLE $.formats[*].type AS formats TAG",
        "",
        'FT.CREATE "idx:library_programs" ON JSON PREFIX 1 "library:programs:" SCHEMA "$.title" AS "title" TEXT '
        '"$.audience" AS "audience" TAG "$.branch" AS "branch" TAG "$.location" AS "location" GEO '
        '"$.capacity" AS "capacity" NUMERIC "$.description" AS "description" TEXT',
    ])

    series = []
    for slug in ("central", "riverside"):
        for metric, unit in (("temperature", "celsius"), ("occupancy", "people")):
            key = f"library:sensors:{slug}:{metric}"
            series.append(command("TS.CREATE", key, "DUPLICATE_POLICY", "LAST", "LABELS", "branch", slug,
                                  "metric", metric, "unit", unit))
            daily = f"{key}:daily_avg"
            series.append(command("TS.CREATE", daily, "LABELS", "branch", slug, "metric", metric,
                                  "unit", unit, "aggregation", "avg_1d"))
            series.append(command("TS.CREATERULE", key, daily, "AGGREGATION", "avg", str(day_ms)))
    series.append("")
    for slug in ("central", "riverside"):
        for day in range(7):
            samples = []
            for hour in range(24):
                ts = base_ms - (7 - day) * day_ms + hour * 3_600_000
                open_hours = 9 <= hour < 20
                temperature = 19.5 + (1.5 if open_hours else -1.0) + round(rng.uniform(-0.6, 0.6), 1)
                people = (rng.between(15, 120) if slug == "central" else rng.between(4, 45)) if open_hours else 0
                samples += [f"library:sensors:{slug}:temperature", str(ts), f"{temperature:.1f}"]
                samples += [f"library:sensors:{slug}:occupancy", str(ts), str(people)]
            series.append(command("TS.MADD", *samples))
    write(BROWSER_DIR / "timeseries", series)

    write(BROWSER_DIR / "bloom", [
        command("BF.RESERVE", "library:filters:isbn_seen", "0.001", "10000"),
        command("BF.MADD", "library:filters:isbn_seen",
                *[f"978{hashlib.sha1(t.encode()).hexdigest()[:10]}" for t, *_ in BOOKS]),
        command("BF.ADD", "library:filters:newsletter_sent", "ada@example.org"),
        command("BF.MADD", "library:filters:newsletter_sent", *[f"{m[0].split()[0].lower()}@example.org"
                                                                for m in MEMBERS[1:8]]),
    ])

    vector_lines = []
    for i, (title, author, year, genres, _) in enumerate(BOOKS[:30], start=1):
        vector = [0.0] * 16
        for genre in genres.split(","):
            vector = [v + b for v, b in zip(vector, basis("g:" + genre), strict=False)]
        vector = [v + 0.3 * b for v, b in zip(vector, basis("a:" + author), strict=False)]
        norm = math.sqrt(sum(v * v for v in vector)) or 1.0
        values = [f"{v / norm:.4f}" for v in vector]
        vector_lines.append(command("VADD", "library:recommendations:books", "VALUES", "16", *values, f"book:{i}",
                                    "SETATTR", sq_json({"title": title, "author": author, "year": year})))
    write(BROWSER_DIR / "vectorset", vector_lines)

    manifest = {
        "files": [
            {"path": "common"},
            {"path": "json", "modules": ["rejson", "json"]},
            {"path": "search", "modules": ["search", "searchlight", "ft", "ftl"]},
            {"path": "timeseries", "modules": ["timeseries"]},
            {"path": "bloom", "modules": ["bf"]},
            {"path": "vectorset", "modules": ["vectorset"]},
        ]
    }
    (BROWSER_DIR / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")


# MARK: - Report


def report(trails, recipes):
    def nearest(items, vector, key, k=3):
        ranked = sorted(items, key=lambda item: cosine_distance(item["embedding"], vector))
        return [f"{item[key]} ({cosine_distance(item['embedding'], vector):.3f})" for item in ranked[:k]]

    print(f"\n{len(trails)} trails, {len(recipes)} recipes, {EMBEDDING_DIM} dimensions")
    for text in ("An easy family walk to a waterfall", "A shady forest loop where I can bring my dog"):
        print(f"  {text!r}: {nearest(trails, embed(text, [], TRAIL_CONCEPTS), 'name')}")
    for text in ("A warming bowl of soup for a cold evening", "A rich chocolate dessert"):
        print(f"  {text!r}: {nearest(recipes, embed(text, [], RECIPE_CONCEPTS), 'title')}")


if __name__ == "__main__":
    write_browser()
    report(*write_vector_search())
