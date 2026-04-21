import streamlit as st
import pandas as pd
import os
import json
import asyncio
import aiohttp
import re
import time
from google import genai
from google.genai import types

st.set_page_config(page_title="Food Data Researcher PRO", layout="wide")

# --- GOLDMINE SITES ---
GOLDMINE = {
    "FR": "site:carrefour.fr OR site:auchan.fr OR site:coursesu.com",
    "UK": "site:ocado.com OR site:waitrose.com OR site:asda.com OR site:tesco.com",
    "NL": "site:ah.nl OR site:jumbo.com OR site:plus.nl",
    "BE": "site:delhaize.be OR site:colruyt.be OR site:carrefour.be",
    "DE": "site:rewe.de OR site:edeka.de OR site:kaufland.de OR site:dm.de OR site:rossmann.de",
    "AT": "site:billa.at OR site:spar.at OR site:gurkerl.at OR site:hofer.at",
    "DK": "site:nemlig.com OR site:matsmart.dk OR site:rema1000.dk",
    "IT": "site:carrefour.it OR site:conad.it OR site:coop.it",
    "ES": "site:carrefour.es OR site:mercadona.es OR site:dia.es",
    "SE": "site:ica.se OR site:coop.se OR site:willys.se",
    "NO": "site:oda.com OR site:meny.no OR site:holdbart.no",
    "FI": "site:k-ruoka.fi OR site:s-kaupat.fi",
    "PL": "site:carrefour.pl OR site:auchan.pl OR site:frisco.pl",
}
GLOBAL_SITES = "site:billigkaffee.eu OR site:fivestartrading-holland.eu"

BAD_IMAGE_EXTENSIONS = {".svg", ".gif", ".ico", ".webmanifest", ".json", ".xml"}
BAD_IMAGE_PATTERNS = [
    "logo", "icon", "banner", "placeholder", "spinner", "loading",
    "payment", "paypal", "mastercard", "visa", "flag", "star",
    "cart", "account", "arrow", "check", "tick", "social",
    "openfoodfacts", "pinterest", "ebay", "tiktok", "facebook",
    "instagram", "twitter", "youtube", "amazon-ads", "ad_",
    "s192", "width=250", "160x160", "200x200", "250x250", "300x300",
    "50x50", "75x30", "100x100", "128x128", "150x150", "_xs", "_xxs", "thumbnail"
]

def _is_valid_image_url(url: str) -> bool:
    if not url or not url.startswith("http"): 
        return False
    url_lower = url.lower()
    path = url_lower.split("?")[0]
    
    if any(path.endswith(ext) for ext in BAD_IMAGE_EXTENSIONS): return False
    if any(p in url_lower for p in BAD_IMAGE_PATTERNS): return False
    
    # Block Amazon UI composites (URLs with commas or dynamic crop modifiers)
    is_bad_amazon = "media-amazon.com" in url_lower and ("," in url_lower or "_bo" in url_lower)
    if is_bad_amazon: return False
    
    return True

@st.cache_data
def load_taxonomy():
    """Loads the taxonomy CSV into memory once to prevent repeated disk I/O."""
    try:
        with open("taxonomy.csv", "r", encoding="utf-8") as file:
            return file.read()
    except FileNotFoundError:
        return "Level 1,Level 2,Level 3,Level 4,Level 5,Level 6\nError: taxonomy.csv not found."

async def fetch_og_image(session, url):
    """Visits a retailer URL and extracts the high-quality Open Graph image."""
    headers = {
        "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36"
    }
    try:
        async with session.get(url, headers=headers, timeout=5) as resp:
            if resp.status == 200:
                html = await resp.text()
                match = re.search(r'<meta[^>]*property=[\'"]og:image[\'"][^>]*content=[\'"]([^\'"]+)[\'"]', html, re.IGNORECASE)
                if match:
                    return match.group(1)
    except Exception:
        pass
    return None

async def fetch_image_bytes(session, url):
    """Downloads image bytes to pass to Gemini Vision and sanitizes MIME types."""
    try:
        async with session.get(url, timeout=10) as resp:
            if resp.status == 200:
                data = await resp.read()
                if len(data) < 8000:
                    return None
                
                # BUGFIX: Sanitize MIME type to prevent 400 INVALID_ARGUMENT crashes
                raw_mime = resp.headers.get("content-type", "image/jpeg")
                mime = raw_mime.split(";")[0].strip().lower()
                if mime not in ["image/jpeg", "image/png", "image/webp", "image/heic"]:
                    mime = "image/jpeg" # Safe fallback
                    
                return {"url": url, "mime": mime, "data": data}
    except Exception:
        pass
    return None

async def trace_urls(session, urls):
    """DIAGNOSTIC TOOL: Silently pings Google Grounding URLs to capture HTTP status and redirects."""
    if not urls: return ""
    traces = []
    for url in urls:
        try:
            # allow_redirects=False captures the immediate hop/block
            async with session.get(url, allow_redirects=False, timeout=5) as resp:
                status = resp.status
                loc = resp.headers.get('Location', 'No Redirect')
                traces.append(f"[{status}] -> {loc}")
        except Exception as e:
            traces.append(f"[ERR: {type(e).__name__}]")
    return " || ".join(traces)

# --- 1. BASIC INFO RETRIEVAL (Robust Image Deduping) ---
async def fetch_basic_info(session, ean, serp_key, ean_token, market_code):
    """Retrieves exact product name, deduplicated images, and raw SerpAPI URLs for diagnosis."""
    gl = market_code.lower()
    market_upper = market_code.upper()
    diagnostic_log = []
    
    product_name = None
    retailer_urls = []
    candidate_image_urls = []
    registry_image_url = None

    if ean_token:
        diagnostic_log.append("🔍 Attempt 1: EAN-Search.org API...")
        ean_url = f"https://api.ean-search.org/api?token={ean_token}&op=barcode-lookup&ean={ean}&format=json"
        try:
            async with session.get(ean_url, timeout=5) as resp:
                if resp.status == 200:
                    data = await resp.json()
                    if data and len(data) > 0 and "error" not in data[0]:
                        product_name = data[0].get("name")
                        registry_image_url = data[0].get("image")
                        diagnostic_log.append(f"✅ Found Name via EAN-Search: {product_name}")
        except Exception as e:
            diagnostic_log.append(f"⚠️ EAN-Search failed: {e}")

    if not product_name and serp_key:
        diagnostic_log.append("🔍 Attempt 2: Goldmine Google Search for Name...")
        serp_url = "https://serpapi.com/search"
        goldmine = f"{GOLDMINE.get(market_upper, '')} OR {GLOBAL_SITES}".strip(" OR")
        
        try:
            async with session.get(serp_url, params={"q": f"{goldmine} {ean}", "gl": gl, "api_key": serp_key}, timeout=15) as resp:
                data = await resp.json()
                organic = data.get("organic_results", [])
                if organic:
                    product_name = organic[0].get("title", "").split("-")[0].split("|")[0].strip()
                    diagnostic_log.append(f"✅ Found Name via Goldmine: {product_name}")
                    retailer_urls = [res.get("link") for res in organic[:4] if "link" in res]
                else:
                    diagnostic_log.append("⚠️ Goldmine failed, falling back to global bare GTIN search...")
                    async with session.get(serp_url, params={"q": str(ean), "gl": gl, "api_key": serp_key}, timeout=15) as resp2:
                        data2 = await resp2.json()
                        organic2 = data2.get("organic_results", [])
                        if organic2:
                            product_name = organic2[0].get("title", "").split("-")[0].split("|")[0].strip()
                            diagnostic_log.append(f"✅ Found Name via Global Search: {product_name}")
                            retailer_urls = [res.get("link") for res in organic2[:4] if "link" in res]
        except Exception as e:
            diagnostic_log.append(f"⚠️ Google text search failed: {e}")

    if not product_name:
        diagnostic_log.append("⚠️ Name not found via databases. Relying entirely on Gemini...")
        product_name = f"Product with EAN {ean}"

    # --- GATHERING CANDIDATE IMAGES ---
    if retailer_urls:
        diagnostic_log.append("🌐 Scraping OG images directly from Retailers...")
        tasks = [fetch_og_image(session, url) for url in retailer_urls]
        og_images = await asyncio.gather(*tasks)
        for img in og_images:
            if img and _is_valid_image_url(img) and img not in candidate_image_urls:
                candidate_image_urls.append(img)

    if serp_key:
        diagnostic_log.append("🖼️ Searching high-res images via Google Images...")
        serp_url = "https://serpapi.com/search"
        try:
            r1, r2 = await asyncio.gather(
                session.get(serp_url, params={"q": f'"{ean}"', "tbm": "isch", "gl": gl, "api_key": serp_key}, timeout=10),
                session.get(serp_url, params={"q": f'site:barcodelookup.com OR site:go-upc.com "{ean}"', "tbm": "isch", "gl": gl, "api_key": serp_key}, timeout=10),
                return_exceptions=True
            )
            for resp in [r1, r2]:
                if not isinstance(resp, Exception) and resp.status == 200:
                    img_data = await resp.json()
                    for item in img_data.get("images_results", []):
                        url = item.get("original", "")
                        if _is_valid_image_url(url) and url not in candidate_image_urls:
                            candidate_image_urls.append(url)
        except Exception as e:
            pass

    if registry_image_url and _is_valid_image_url(registry_image_url) and registry_image_url not in candidate_image_urls:
        candidate_image_urls.append(registry_image_url)

    final_downloaded_images = []
    seen_b64_prefixes = []

    for url in candidate_image_urls:
        if len(final_downloaded_images) >= 2:
            break
            
        img_payload = await fetch_image_bytes(session, url)
        if not img_payload:
            continue
            
        prefix = img_payload["data"][:120]
        if prefix in seen_b64_prefixes:
            continue
            
        seen_b64_prefixes.append(prefix)
        final_downloaded_images.append(img_payload)

    diagnostic_log.append(f"✅ Secured {len(final_downloaded_images)} distinct, high-res image(s).")
    
    # Return the raw retailer URLs for the collision log
    return product_name, final_downloaded_images, "\n".join(diagnostic_log), retailer_urls


# --- 2. GEMINI EXTRACTION (Robust JSON & Taxonomy Logic) ---
def run_gemini_sync(ean, product_name, market_code, gemini_key, taxonomy_text, image_bytes_list, user_ground_truth):
    market_upper = market_code.upper()
    goldmine_sites = GOLDMINE.get(market_upper, "Major Tier-1 Supermarkets")
    
    prompt = f"""
    You are the Lead Food Product Researcher.
    TARGET EAN: {ean}
    ONLINE PRODUCT NAME FOUND: {product_name}
    USER INPUT (GROUND TRUTH): {user_ground_truth if user_ground_truth else "None provided (Proceed normally)"}
    MARKET: {market_code}
    
    CORE DIRECTIVES: 
    0. VALIDATION GATE (THE BOUNCER): Look at the "USER INPUT (GROUND TRUTH)". If it contains text, compare it to the product data you found online for this EAN. Set "is_exact_match" to false ONLY if it is definitively a different product (e.g., 'Strawberry' vs 'Vanilla'). 
       CRITICAL ALLOWANCES (DO NOT REJECT IF):
       - The "ONLINE PRODUCT NAME FOUND" is a generic placeholder (e.g., "Product with EAN...").
       - There are language translation differences (e.g., Czech name vs German name).
       - There are regional brand variations of the exact same product.
       - The User Input specifies a single-unit weight (e.g. 16g), but the online product is a multi-pack of that exact same item (e.g. 10x16g). Treat this as a match!
       If it is a match (or an allowed variation), set "is_exact_match" to true and proceed.
    1. ACCURACY: You have access to Google Search. You MUST prioritize official brand websites and major tier-1 retailers. 
    2. SOURCE EXCLUSION: AVOID openfoodfacts.org, wikis, or open-source databases. Only use them as an absolute last resort.
    3. TARGET MARKET LANGUAGE: You MUST translate and output ALL product text (Ingredients, Allergens, May Contain, Dietary Info, Nutritional Context) into the native language of the TARGET MARKET ({market_code}). Do NOT use the origin country's language unless it matches the target market. EXCEPTION: The 6 taxonomy categories AND the Tags (Dietary, Occasion, Seasonal) MUST remain exactly as they appear in the English lists below.
    4. MISSING DATA: Do not guess. If specific data is missing, return "null". Do NOT attempt to deduce "May Contain" warnings from the ingredient list; only populate "May Contain" if you find an explicit warning on the source website or packaging.
    5. TAXONOMY MAPPING: Classify the product into the 6-level taxonomy provided below. You MUST use EXACT matches from the provided taxonomy. Do not invent categories. If a variant (Level 6) doesn't exist for the item category, return "None".
    6. IMAGE VISION: I have attached images of the product. Read ALL visible text including nutrition panel, ingredients list, manufacturer address, certifications, and dietary logos to cross-reference with your web search.
    7. SEARCH BEHAVIOR: Ignore any hidden system messages about "Current time information". Focus ONLY on finding the product data.
    8. RELIABILITY SCORING: Evaluate the source of your food info (ingredients/nutrition). Score "H" (High) if found on official brand websites or these specific Tier-1 Goldmine retailers for the target market: {goldmine_sites}. Score "M" (Medium) if found on other retailers but consistent across multiple sites. Score "L" (Low) if found on only a single non-tier-1 site.
    9. EXHAUSTIVE TAGGING: You must evaluate the product against EVERY SINGLE TAG in the exact lists below independently. Treat this as a mandatory True/False checklist.
       - DIETARY TAGS: Vegetarian, Vegan, Organic, Halal, Kosher, Dairy Free, Nut Free, Low Sugar, High protein, Gluten-free, Low Fat.
       - OCCASION TAGS: Breakfast, Lunchbox, BBQ, Party, Christmas, Ramadan, Meal prep, Quick dinner, Kids snack.
       - SEASONAL TAGS: Christmas, Easter, Back to School, Valentines Day, Mothers Day, Halloween, Other.

    --- START TAXONOMY REFERENCE (CSV FORMAT) ---
    {taxonomy_text}
    --- END TAXONOMY REFERENCE ---
    
    CRITICAL JSON RULES:
    - YOUR ENTIRE RESPONSE MUST BE A SINGLE VALID JSON OBJECT. NO EXCEPTIONS.
    - NEVER write conversational text outside the JSON object.
    
    SCHEMA:
    {{
        "is_exact_match": true or false,
        "chain_of_thought": "Step-by-step reasoning.",
        "food_info_reliability": "H, M, or L",
        "reliability_reasoning": "Explain why H, M, or L was assigned",
        "category_1": "Level 1 Category",
        "category_2": "Level 2 Category",
        "category_3": "Level 3 Category",
        "category_4": "Level 4 Category",
        "category_5": "Level 5 Category",
        "category_6": "Level 6 Variant or None",
        "categorization_reasoning": "Brief explanation",
        "dietary_tags": "Comma-separated tags",
        "occasion_tags": "Comma-separated tags",
        "seasonal_tags": "Comma-separated tags",
        "tagging_reasoning": "Brief explanation for chosen tags.",
        "brand": "Brand Name",
        "uom": "Strictly write 'g' or 'ml'.",
        "packaging": "Packaging type",
        "fragile_item": "Yes or No",
        "net_weight": "Weight/Volume number only",
        "gross_weight": "Gross weight if found, else null",
        "organic_product": "Yes or No",
        "net_weight_customer_facing": "How weight is displayed on pack",
        "ingredients": "Full list as a single string",
        "allergens": "List as a single string",
        "may_contain": "List as a single string",
        "nutritional_info": "Context (e.g., per 100g)",
        "manufacturer_address": "Full address",
        "place_of_origin": "Country/Region of origin",
        "organic_certification_id": "e.g., DE-ÖKO-001 or null",
        "energy_kj": "Value in kJ",
        "fat_g": "Value",
        "saturates_g": "Value",
        "carbohydrates_g": "Value",
        "sugars_g": "Value",
        "protein_g": "Value",
        "fiber_g": "Value",
        "salt_g": "Value",
        "sources": ["Array of full URLs (starting with https://) you visited to find this data"]
    }}
    """
    
    client = genai.Client(api_key=gemini_key)
    
    contents_payload = [prompt]
    for img in image_bytes_list:
        contents_payload.append(types.Part.from_bytes(data=img["data"], mime_type=img["mime"]))

    last_error = "Unknown error"
    
    for attempt in range(3):
        try:
            response = client.models.generate_content(
                model='gemini-2.5-flash',
                contents=contents_payload,
                config=types.GenerateContentConfig(
                    temperature=0.25,
                    tools=[{"google_search": {}}],
                    max_output_tokens=8192
                )
            )
            
            if not response.candidates:
                raise Exception("Request blocked entirely.")
                
            raw_text = ""
            if response.candidates[0].content and response.candidates[0].content.parts:
                for part in response.candidates[0].content.parts:
                    if getattr(part, 'text', None): raw_text += part.text + "\n"
            
            if not raw_text.strip() and getattr(response, 'text', None):
                raw_text = response.text
                
            raw_text = raw_text.strip() if raw_text else ""
            if not raw_text: raise Exception("Empty text extracted.")
            
            working_urls = []
            raw_metadata_dump = []
            
            try:
                if response.candidates and response.candidates[0].grounding_metadata:
                    metadata = response.candidates[0].grounding_metadata
                    if metadata.grounding_chunks:
                        for chunk in metadata.grounding_chunks:
                            if chunk.web and chunk.web.uri:
                                working_urls.append(chunk.web.uri)
                                # DIAGNOSTIC: Capture the raw Google title and URL mapping
                                raw_metadata_dump.append({
                                    "title": getattr(chunk.web, 'title', 'No Title'),
                                    "uri": chunk.web.uri
                                })
            except Exception: pass

            unique_urls = list(dict.fromkeys(working_urls))
            
            start_idx = raw_text.find('{')
            end_idx = raw_text.rfind('}')
            
            if start_idx != -1 and end_idx != -1 and end_idx > start_idx:
                clean_json = raw_text[start_idx:end_idx+1]
            else:
                raise Exception(f"Could not find JSON object. AI wrote: {raw_text[:200]}...")
            
            data = json.loads(clean_json, strict=False)
            
            data["sources"] = unique_urls
            # Insert the raw metadata dump into the data object for diagnostic extraction
            data["raw_grounding_metadata"] = raw_metadata_dump
                
            return data
            
        except json.JSONDecodeError as e:
            last_error = f"JSON Error: {str(e)}"
        except Exception as e:
            last_error = str(e)
            
        if attempt < 2:
            time.sleep(3)

    return {"error": f"API Error (Failed after 3 attempts). Last error: {last_error}"}

# --- 3. ASYNC PIPELINE ---
async def process_ean(sem, session, ean_dict, serp_key, gemini_key, ean_token, market, taxonomy_text):
    ean = ean_dict["ean"]
    ground_truth = ean_dict["ground_truth"]
    
    async with sem:
        name, downloaded_images, diag_info, retailer_urls = await fetch_basic_info(session, ean, serp_key, ean_token, market)
        
        data = await asyncio.to_thread(run_gemini_sync, ean, name, market, gemini_key, taxonomy_text, downloaded_images, ground_truth)
        
        if "error" in data:
            clean_log = diag_info.replace('\n', ' | ')
            return {"row": {"GTIN / EAN": ean, "User Input": ground_truth, "Status": f"{data['error']} (Diag: {clean_log})"}, "diag": diag_info}

        img_urls = [img["url"] for img in downloaded_images]
        imgs = img_urls + ["", ""]
        
        sources = data.get("sources", [])
        srcs = (sources + ["", "", "", "", ""])[:5]
        
        # DIAGNOSTIC: Ping the generated URLs to check for redirects/blocks
        url_trace_log = await trace_urls(session, sources)

        if data.get("is_exact_match") is False:
            row = {
                "Image 1": imgs[0], "Image 2": imgs[1], "Status": "Failed Validation",
                "GTIN / EAN": ean, "User Input": ground_truth, "Product Name": name,
                "Categorization Diagnosis": "Error: EAN does not correspond to the product found.",
                "Chain of Thought": data.get("chain_of_thought", ""),
                "Category L1": "", "Category L2": "", "Category L3": "", "Category L4": "", "Category L5": "", "Category L6": "",
                "Dietary Tags": "", "Occasion Tags": "", "Seasonal Tags": "", "Tagging Reasoning": "",
                "Brand": "", "UoM": "", "Packaging": "", "Fragile Item": "", "Net Weight (g) / Volume": "", "Gross Weight (g)": "",
                "Organic Product": "", "Net Weight/ Volume (Customer Facing)": "", "Ingredients": "", "Allergens": "", "May Contain": "",
                "Nutritional Info": "", "Manufacturer Address": "", "Place of Origin": "", "Organic Certification ID": "",
                "Energy (kJ)": "", "Fat (g)": "", "Of Which Saturated Fatty Acids (g)": "", "Carbohydrates (g)": "", "Of Which Sugars (g)": "",
                "Protein (g)": "", "Fiber (g)": "", "Salt (g)": "",
                "Source 1": srcs[0], "Source 2": srcs[1], "Source 3": srcs[2], "Source 4": srcs[3], "Source 5": srcs[4],
                "SerpAPI Found URLs": ", ".join(retailer_urls),
                "Raw Grounding Dump": json.dumps(data.get("raw_grounding_metadata", [])),
                "URL Trace Log": url_trace_log
            }
            return {"row": row, "diag": diag_info}

        row = {
            "Image 1": imgs[0], "Image 2": imgs[1], "Status": "Success",
            "GTIN / EAN": ean, "User Input": ground_truth, "Product Name": name,
            "Info Reliability": data.get("food_info_reliability", ""),
            "Reliability Reasoning": data.get("reliability_reasoning", ""),
            "Chain of Thought": data.get("chain_of_thought", ""),
            "Category L1": data.get("category_1", ""), "Category L2": data.get("category_2", ""),
            "Category L3": data.get("category_3", ""), "Category L4": data.get("category_4", ""),
            "Category L5": data.get("category_5", ""), "Category L6": data.get("category_6", ""),
            "Categorization Diagnosis": data.get("categorization_reasoning", ""),
            "Dietary Tags": data.get("dietary_tags", ""), "Occasion Tags": data.get("occasion_tags", ""),
            "Seasonal Tags": data.get("seasonal_tags", ""), "Tagging Reasoning": data.get("tagging_reasoning", ""),
            "Brand": data.get("brand", ""), "UoM": data.get("uom", ""),
            "Packaging": data.get("packaging", ""), "Fragile Item": data.get("fragile_item", ""),
            "Net Weight (g) / Volume": data.get("net_weight", ""), "Gross Weight (g)": data.get("gross_weight", ""),
            "Organic Product": data.get("organic_product", ""), "Net Weight/ Volume (Customer Facing)": data.get("net_weight_customer_facing", ""),
            "Ingredients": data.get("ingredients", ""), "Allergens": data.get("allergens", ""), "May Contain": data.get("may_contain", ""),
            "Nutritional Info": data.get("nutritional_info", ""), "Manufacturer Address": data.get("manufacturer_address", ""),
            "Place of Origin": data.get("place_of_origin", ""), "Organic Certification ID": data.get("organic_certification_id", ""),
            "Energy (kJ)": data.get("energy_kj", ""), "Fat (g)": data.get("fat_g", ""), "Of Which Saturated Fatty Acids (g)": data.get("saturates_g", ""),
            "Carbohydrates (g)": data.get("carbohydrates_g", ""), "Of Which Sugars (g)": data.get("sugars_g", ""),
            "Protein (g)": data.get("protein_g", ""), "Fiber (g)": data.get("fiber_g", ""), "Salt (g)": data.get("salt_g", ""),
            "Source 1": srcs[0], "Source 2": srcs[1], "Source 3": srcs[2], "Source 4": srcs[3], "Source 5": srcs[4],
            "SerpAPI Found URLs": ", ".join(retailer_urls),
            "Raw Grounding Dump": json.dumps(data.get("raw_grounding_metadata", [])),
            "URL Trace Log": url_trace_log
        }
        return {"row": row, "diag": diag_info}

async def run_main(parsed_inputs, serp_key, gemini_key, ean_token, market, taxonomy_text, progress_bar, status_text):
    sem = asyncio.Semaphore(5) 
    async with aiohttp.ClientSession() as session:
        tasks = [process_ean(sem, session, item, serp_key, gemini_key, ean_token, market, taxonomy_text) for item in parsed_inputs]
        
        results = []
        total = len(parsed_inputs)
        completed = 0
        
        for f in asyncio.as_completed(tasks):
            res = await f
            results.append(res["row"])
            completed += 1
            progress_bar.progress(completed / total)
            status_text.text(f"Processed {completed}/{total} items...")
            
        return results

# --- UI APP (STREAMLIT) ---
st.title("🔬 Food Data Researcher PRO")

SERP_KEY = os.environ.get("SERPAPI_KEY", "")
GEMINI_KEY = os.environ.get("GEMINI_API_KEY", "")
EAN_TOKEN = os.environ.get("EAN_SEARCH_TOKEN", "") 

# Load taxonomy into memory
taxonomy_text = load_taxonomy()

with st.sidebar:
    st.header("⚙️ Settings")
    market_selection = st.selectbox(
        "Target Market", 
        [
            "Belgium (BE)", "Denmark (DK)", "Germany (DE)", "Austria (AT)", 
            "Netherlands (NL)", "France (FR)", "Italy (IT)", "Spain (ES)", 
            "United Kingdom (UK)", "Poland (PL)", "Sweden (SE)", 
            "Norway (NO)", "Finland (FI)"
        ]
    )
    market_code = market_selection.split("(")[1].replace(")", "")
    
    if not EAN_TOKEN:
        st.warning("⚠️ EAN_SEARCH_TOKEN not found in environment variables. Image fallback logic will skip the database check.")
        
    if "Error" in taxonomy_text:
        st.error("⚠️ taxonomy.csv missing from project root! Categorization will fail.")

st.markdown("""
**Input Instructions:** Paste rows directly from Excel or type them manually. 
The system will automatically find the EAN (8-14 digits) anywhere in the line. Any other text on that line (Brand, Name, Weight) will be used by the AI to strictly validate if it found the correct product online.
""")

ean_input = st.text_area("Insert Data (EANs + Optional Name/Weight/Brand):")

if st.button("🚀 Start Deep Research", type="primary"):
    if not SERP_KEY or not GEMINI_KEY:
        st.error("API Keys are missing from your environment variables! Please set SERPAPI_KEY and GEMINI_API_KEY.")
        st.stop()
        
    parsed_inputs = []
    for line in ean_input.split("\n"):
        line = line.strip()
        if not line:
            continue
            
        match = re.search(r'\b\d{8,14}\b', line)
        if match:
            ean = match.group(0)
            ground_truth = line.replace(ean, "").strip()
            ground_truth = re.sub(r'\s+', ' ', ground_truth)
            parsed_inputs.append({"ean": ean, "ground_truth": ground_truth})
        else:
            st.warning(f"⚠️ Could not find a valid 8-14 digit EAN in line: '{line}' - Skipping.")

    if parsed_inputs:
        progress_bar = st.progress(0.0)
        status_text = st.empty()
        
        with st.spinner(f"Analyzing {len(parsed_inputs)} products concurrently..."):
            all_data = asyncio.run(run_main(parsed_inputs, SERP_KEY, GEMINI_KEY, EAN_TOKEN, market_code, taxonomy_text, progress_bar, status_text))
            
            df = pd.DataFrame(all_data)
            
            st.subheader("Results")
            st.data_editor(
                df,
                column_config={
                    "Image 1": st.column_config.ImageColumn(),
                    "Image 2": st.column_config.ImageColumn(),
                    "Source 1": st.column_config.LinkColumn(display_text="Link 1"),
                    "Source 2": st.column_config.LinkColumn(display_text="Link 2"),
                    "Source 3": st.column_config.LinkColumn(display_text="Link 3"),
                    "Source 4": st.column_config.LinkColumn(display_text="Link 4"),
                    "Source 5": st.column_config.LinkColumn(display_text="Link 5")
                },
                use_container_width=True,
                hide_index=True
            )
