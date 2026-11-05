# Semantic Taxonomy Template

Use this as the structure for your `語意大表.xlsx`.

## Sheet 1: `SemanticTaxonomy`

| keyword | parent_category | level | keyword_zh | description | is_auto_classifiable | priority | status | notes |
|---|---|---:|---|---|---:|---:|---|---|

### Field rules

- `keyword`: English canonical label, e.g. `Pizza`
- `parent_category`: broad group, e.g. `Food`
- `level`: `1` for parent categories, `2` for leaf keywords
- `keyword_zh`: optional Chinese label, e.g. `披薩`
- `description`: short definition of the concept
- `is_auto_classifiable`: `1` if the class should be used for automatic classification, otherwise `0`
- `priority`: smaller number means higher importance
- `status`: `active`, `draft`, or `deprecated`
- `notes`: manual comments, edge cases, or merge hints

### Example rows

| keyword | parent_category | level | keyword_zh | description | is_auto_classifiable | priority | status | notes |
|---|---|---:|---|---|---:|---:|---|---|
| Food | Root | 1 | 食物 | Top-level food category | 1 | 1 | active | Parent node |
| Pizza | Food | 2 | 披薩 | A baked flatbread with toppings | 1 | 10 | active | High-frequency class |
| Passport | Travel | 2 | 護照 | A travel identity document | 1 | 30 | active | Often confused with document photo |
| Selfie | People | 2 | 自拍 | A photo taken by the subject themselves | 1 | 5 | active | Keep if you later add face-related logic |

## Sheet 2: `PromptBank`

| keyword | prompt_id | prompt_text | prompt_type | weight | status |
|---|---:|---|---|---:|---|

### Field rules

- `keyword`: must match `SemanticTaxonomy.keyword`
- `prompt_id`: unique within a keyword, start from `1`
- `prompt_text`: full prompt used for embedding
- `prompt_type`: e.g. `base`, `closeup`, `real_world`, `studio`
- `weight`: default `1.0`, higher weight means more influence
- `status`: `active` or `inactive`

### Example rows

| keyword | prompt_id | prompt_text | prompt_type | weight | status |
|---|---:|---|---|---:|---|
| Pizza | 1 | a photo of pizza | base | 1.0 | active |
| Pizza | 2 | a close-up photo of pizza | closeup | 1.2 | active |
| Pizza | 3 | a realistic photo of a pizza on a table | real_world | 1.0 | active |
| Passport | 1 | a photo of a passport | base | 1.0 | active |
| Passport | 2 | a close-up photo of a passport document | closeup | 1.1 | active |

## Sheet 3: `AliasMap`

| alias | keyword | alias_type | language | status |
|---|---|---|---|---|

### Field rules

- `alias`: alternate name users may type or the model may surface
- `keyword`: canonical keyword from `SemanticTaxonomy`
- `alias_type`: e.g. `synonym`, `nickname`, `abbreviation`
- `language`: e.g. `en`, `zh`, `mixed`
- `status`: `active` or `inactive`

### Example rows

| alias | keyword | alias_type | language | status |
|---|---|---|---|---|
| fries | French Fries | synonym | en | active |
| selfie | Selfie | synonym | en | active |
| passport photo | Passport | related | en | active |
| 披薩 | Pizza | synonym | zh | active |

## Recommended workflow

1. Fill `SemanticTaxonomy` first.
2. Add 3 to 5 prompts per keyword in `PromptBank`.
3. Add common synonyms into `AliasMap`.
4. Mark risky classes as `is_auto_classifiable = 0` until you verify them.
5. Keep `status` as `draft` while you are still cleaning the data.

