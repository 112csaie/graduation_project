// TaxonomyTuningData.swift
//
// ⚠️ 這個檔案由桌面「相簿主題設定」資料夾裡的「套用到App.py」自動產生，請不要手動修改。
// 內容是你在資料夾裡改過的地方（和內建設定不同的欄位）；{} 代表沒有任何調整。
// 說明見 TaxonomyTuning.swift。

enum TaxonomyTuningData {
    static let json = ##"""
{
  "nodes": {
    "airport": {
      "acceptScore": 0.21
    },
    "anime_art": {
      "acceptScore": 0.279,
      "prompts": [
        "an anime screenshot"
      ]
    },
    "aquarium": {
      "acceptScore": 0.23
    },
    "arcade": {
      "acceptScore": 0.22
    },
    "architecture": {
      "nameEn": "Building Exteriors",
      "nameZh": "建築外觀",
      "prompts": [
        "the facade of a building",
        "an interesting modern building exterior"
      ]
    },
    "autumn_leaves": {
      "acceptScore": 0.2
    },
    "baby": {
      "acceptScore": 0.21
    },
    "ball_sports": {
      "acceptScore": 0.248,
      "confusers": [],
      "prompts": [
        "volleyball players jumping at the net",
        "playing table tennis"
      ]
    },
    "bbq": {
      "acceptScore": 0.205
    },
    "beach": {
      "acceptScore": 0.215
    },
    "bento": {
      "acceptScore": 0.235
    },
    "bird": {
      "acceptScore": 0.23,
      "confusers": [
        "a stuffed animal toy or plush doll",
        "a cartoon animal character printed on a product or poster",
        "an animal-shaped figurine or keychain"
      ],
      "suppressedBy": [
        "stuffed_toy",
        "figure",
        "merch"
      ]
    },
    "board_game": {
      "acceptScore": 0.2
    },
    "bubble_tea": {
      "nameEn": "Bubble Tea",
      "nameZh": "手搖飲",
      "prompts": [
        "bubble tea in a plastic cup with a straw",
        "an iced milk tea in a takeaway cup with a sealed lid"
      ]
    },
    "cake": {
      "acceptScore": 0.205
    },
    "camera_gear": {
      "acceptScore": 0.2
    },
    "camping": {
      "acceptScore": 0.204
    },
    "cardio_machine": {
      "acceptScore": 0.246,
      "prompts": [
        "a treadmill display showing distance and time"
      ]
    },
    "castle": {
      "acceptScore": 0.22
    },
    "cat": {
      "acceptScore": 0.23,
      "confusers": [
        "a stuffed animal toy or plush doll",
        "a cartoon animal character printed on a product or poster",
        "an animal-shaped figurine or keychain"
      ],
      "suppressedBy": [
        "stuffed_toy",
        "figure",
        "merch"
      ]
    },
    "cheering_goods": {
      "acceptScore": 0.205
    },
    "christmas": {
      "acceptScore": 0.2
    },
    "city_street": {
      "acceptScore": 0.211,
      "prompts": [
        "a street in a city with cars and pedestrians"
      ]
    },
    "coffee": {
      "acceptScore": 0.209,
      "prompts": [
        "a cup of hot coffee on a cafe table",
        "latte art on a cup of coffee",
        "a cup of coffee"
      ]
    },
    "comic_convention": {
      "acceptScore": 0.244,
      "prompts": [
        "a crowded anime convention hall with booths"
      ]
    },
    "concert": {
      "prompts": [
        "a concert stage with bright lights and big screens",
        "a crowd holding light sticks at a concert",
        "a singer performing on stage at a concert",
        "a crowd in front of a big outdoor music festival stage",
        "a band playing on a small stage in a dark live music club"
      ]
    },
    "cosplay": {
      "acceptScore": 0.235
    },
    "cycling": {
      "acceptScore": 0.184,
      "confusers": [
        "a person riding a motor scooter"
      ],
      "prompts": [
        "a cyclist riding a bicycle"
      ]
    },
    "document": {
      "nameEn": "Printed Documents",
      "nameZh": "印刷文件",
      "prompts": [
        "a printed document or form on paper",
        "a printed notice or contract"
      ]
    },
    "dog": {
      "acceptScore": 0.23,
      "confusers": [
        "a stuffed animal toy or plush doll",
        "a cartoon animal character printed on a product or poster",
        "an animal-shaped figurine or keychain"
      ],
      "suppressedBy": [
        "stuffed_toy",
        "figure",
        "merch"
      ]
    },
    "exhibition": {
      "prompts": [
        "visitors looking at displays in an exhibition hall",
        "an exhibition booth at an expo"
      ]
    },
    "farm_animal": {
      "acceptScore": 0.23
    },
    "fireworks": {
      "acceptScore": 0.215
    },
    "flowers": {
      "acceptScore": 0.2
    },
    "forest": {
      "prompts": [
        "a dense forest with tall trees",
        "a trail through a forest"
      ]
    },
    "fried_chicken": {
      "acceptScore": 0.24
    },
    "furniture": {
      "acceptScore": 0.228,
      "prompts": [
        "a bed frame in a showroom"
      ],
      "suppressedBy": [
        "home_daily"
      ]
    },
    "gadgets": {
      "acceptScore": 0.236
    },
    "handcraft": {
      "nameEn": "Handmade Crafts",
      "nameZh": "手作作品",
      "prompts": [
        "handmade crafts like knitting, pottery or beadwork",
        "a handmade craft project on a table"
      ]
    },
    "handwritten_notes": {
      "acceptScore": 0.22
    },
    "hiking": {
      "acceptScore": 0.22
    },
    "home_daily": {
      "acceptScore": 0.192,
      "nameEn": "Home Interior",
      "nameZh": "居家空間",
      "prompts": [
        "a cozy living room at home"
      ],
      "suppressedBy": [
        "furniture"
      ]
    },
    "hotel_room": {
      "acceptScore": 0.2
    },
    "hotpot": {
      "acceptScore": 0.24
    },
    "houseplants": {
      "acceptScore": 0.196,
      "confusers": [
        "a garden outdoors"
      ],
      "prompts": [
        "potted plants indoors",
        "a small succulent in a pot"
      ]
    },
    "ice_cream": {
      "acceptScore": 0.22
    },
    "id_card": {
      "acceptScore": 0.24
    },
    "instrument": {
      "acceptScore": 0.239,
      "nameZh": "樂器",
      "prompts": [
        "a musical instrument",
        "a person playing the guitar",
        "a drum set",
        "a person playing the piano"
      ]
    },
    "journal": {
      "confusers": [
        "a binder page with many photo cards in a grid of clear plastic pockets"
      ],
      "prompts": [
        "a decorated notebook page with stickers, washi tape and handwriting",
        "an open planner with handwritten notes and colorful decorations"
      ]
    },
    "lego": {
      "acceptScore": 0.2
    },
    "menu": {
      "acceptScore": 0.245
    },
    "model_kit": {
      "acceptScore": 0.239,
      "prompts": [
        "a scale model car"
      ]
    },
    "mountain": {
      "acceptScore": 0.2
    },
    "movie": {
      "acceptScore": 0.225
    },
    "museum": {
      "acceptScore": 0.2
    },
    "nails": {
      "acceptScore": 0.2
    },
    "night_market": {
      "acceptScore": 0.22,
      "prompts": [
        "a crowded night market with food stalls and bright signs",
        "street food stalls at night in Asia"
      ]
    },
    "outfit": {
      "acceptScore": 0.255,
      "prompts": [
        "an outfit of the day photo"
      ]
    },
    "painting": {
      "acceptScore": 0.229,
      "prompts": [
        "a hand-drawn illustration",
        "a watercolor painting on paper"
      ]
    },
    "photo_sticker": {
      "acceptScore": 0.285,
      "confusers": [],
      "nameEn": "Photo Booth Stickers",
      "nameZh": "拍貼",
      "prompts": [
        "a strip of photo booth pictures"
      ]
    },
    "pizza_burger": {
      "acceptScore": 0.2
    },
    "portrait": {
      "acceptScore": 0.237,
      "confusers": [],
      "prompts": [
        "people smiling together for a photo"
      ]
    },
    "poster": {
      "nameEn": "Posters",
      "nameZh": "海報"
    },
    "product_photo": {
      "nameEn": "Products & Shelves",
      "nameZh": "商品與貨架",
      "prompts": [
        "products displayed on a store shelf",
        "an unboxed product on a table"
      ]
    },
    "rabbit": {
      "acceptScore": 0.23,
      "confusers": [
        "a stuffed animal toy or plush doll",
        "a cartoon animal character printed on a product or poster",
        "an animal-shaped figurine or keychain"
      ],
      "suppressedBy": [
        "stuffed_toy",
        "figure",
        "merch"
      ]
    },
    "receipt": {
      "acceptScore": 0.235
    },
    "reptile": {
      "acceptScore": 0.23,
      "confusers": [
        "a stuffed animal toy or plush doll",
        "a cartoon animal character printed on a product or poster",
        "an animal-shaped figurine or keychain"
      ],
      "suppressedBy": [
        "stuffed_toy",
        "figure",
        "merch"
      ]
    },
    "restaurant_meal": {
      "nameEn": "Table Spread",
      "nameZh": "整桌餐點",
      "prompts": [
        "many dishes of food on a dining table",
        "a table full of plated dishes at a restaurant"
      ]
    },
    "running": {
      "acceptScore": 0.205
    },
    "skiing": {
      "acceptScore": 0.2
    },
    "small_pet": {
      "acceptScore": 0.226,
      "confusers": [
        "a hamster plush toy"
      ],
      "nameEn": "Hamsters & Rodents",
      "nameZh": "倉鼠與鼠類",
      "prompts": [
        "a hamster",
        "a guinea pig eating vegetables"
      ],
      "suppressedBy": [
        "stuffed_toy",
        "figure",
        "merch"
      ]
    },
    "starry_sky": {
      "acceptScore": 0.185,
      "prompts": [
        "a starry night sky",
        "a night sky full of stars",
        "the milky way over a dark landscape"
      ]
    },
    "stationery": {
      "acceptScore": 0.24
    },
    "stuffed_toy": {
      "acceptScore": 0.22
    },
    "sunset": {
      "acceptScore": 0.2
    },
    "sushi": {
      "acceptScore": 0.245
    },
    "swimming": {
      "acceptScore": 0.226,
      "prompts": [
        "people swimming in a pool"
      ]
    },
    "temple": {
      "acceptScore": 0.2
    },
    "theater_show": {
      "acceptScore": 0.237,
      "confusers": [
        "a concert stage with a band"
      ],
      "prompts": [
        "a musical performance on a large theater stage with costumes"
      ]
    },
    "theme_park": {
      "acceptScore": 0.21
    },
    "transport_vehicle": {
      "prompts": [
        "a train",
        "an airplane",
        "a view from an airplane window",
        "a bus or metro train"
      ]
    },
    "video_game": {
      "acceptScore": 0.236,
      "confusers": [
        "an arcade claw machine"
      ],
      "prompts": [
        "a video game screenshot"
      ]
    },
    "weight_training": {
      "acceptScore": 0.21
    },
    "workout": {
      "acceptScore": 0.224,
      "confusers": [],
      "nameEn": "Gym",
      "nameZh": "健身房",
      "prompts": [
        "a fitness class in a studio",
        "a person working out at a gym",
        "inside a gym with fitness equipment",
        "a person exercising at a gym"
      ]
    },
    "zoo_animal": {
      "acceptScore": 0.235,
      "nameZh": "動物園動物",
      "prompts": [
        "wild animals like elephants, giraffes or lions in a zoo enclosure",
        "a zoo animal behind a fence"
      ]
    }
  }
}
"""##
}
