import streamlit as st
import pandas as pd
import os
import json
import asyncio
import aiohttp
import re
from google import genai
from google.genai import types

st.set_page_config(page_title="Food Data Researcher PRO", layout="wide")

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
                # Search for the standard Open Graph image meta tag
                match = re.search(r'<meta[^>]*property=[\'"]og:image[\'"][^>]*content=[\'"]([^\'"]+)[\'"]', html, re.IGNORECASE)
                if match:
                    return match.group(1)
    except Exception:
        pass
    return None

# --- 1. BASIC INFO RETRIEVAL (Cascading Logic for Images) ---
async def fetch_basic_info(session, ean, serp_key, ean_token, market_code):
    """Uses cascading logic to find the exact product name and up to 3 images."""
    gl = market_code.lower()
    diagnostic_log = []
    
    product_name = None
    img_urls = []
    retailer_urls = []

    # ATTEMPT 1: EAN-Search API (Exact Database Match)
    if ean_token:
        diagnostic_log.append("🔍 Attempt 1: EAN-Search.org API...")
        ean_url = f"https://api.ean-search.org/api?token={ean_token}&op=barcode-lookup&ean={ean}&format=json"
        try:
            async with session.get(ean_url, timeout=5) as resp:
                if resp.status == 200:
                    data = await resp.json()
                    if data and len(data) > 0 and "error" not in data[0]:
                        product_name = data[0].get("name")
                        if data[0].get("image"):
                            img_urls.append(data[0].get("image"))
                        diagnostic_log.append(f"✅ Found Name via EAN-Search: {product_name}")
        except Exception as e:
            diagnostic_log.append(f"⚠️ EAN-Search failed: {e}")

    # ATTEMPT 2: SerpAPI Text Search (If name is still missing)
    if not product_name and serp_key:
        diagnostic_log.append("🔍 Attempt 2: Strict Google Search for Name...")
        serp_url = "https://serpapi.com/search"
        try:
            async with session.get(serp_url, params={"q": str(ean), "gl": gl, "api_key": serp_key}, timeout=15) as resp:
                data = await resp.json()
                if "error" in data:
                    diagnostic_log.append(f"⚠️ SerpAPI Error: {data['error']}")
                organic = data.get("organic_results", [])
                if organic:
                    product_name = organic[0].get("title", "").split("-")[0].split("|")[0].strip()
                    diagnostic_log.append(f"✅ Found Name via Google: {product_name}")
                    # Save top retailer URLs for our new image scraper
                    retailer_urls = [res.get("link") for res in organic[:4] if "link" in res]
        except Exception as e:
            diagnostic_log.append(f"⚠️ Google text search failed: {e}")

    # If we still don't have a name, fallback to letting Gemini figure it out
    if not product_name:
        diagnostic_log.append("⚠️ Name not found via databases. Relying entirely on Gemini...")
        product_name = f"Product with EAN {ean}"

    # ATTEMPT 3: Scrape High-Quality Images directly from Retailer URLs
    if retailer_urls and len(img_urls) < 3:
        diagnostic_log.append("🌐 Attempt 3: Extracting official images directly from Retailer URLs...")
        
        # Concurrently visit the top retailer pages
        tasks = [fetch_og_image(session, url) for url in retailer_urls]
        og_images = await asyncio.gather(*tasks)
        
        for img in og_images:
            if img and img not in img_urls:
                url_lower = img.lower()
                bad_patterns = ["placeholder", "logo", "icon", "thumb", "avatar", "svg"]
                if not any(bad in url_lower for bad in bad_patterns):
                    img_urls.append(img)
            if len(img_urls) >= 3:
                break

    # ATTEMPT 4: Fallback to SerpAPI Google Images Search
    if serp_key and len(img_urls) < 3:
        diagnostic_log.append("🖼️ Attempt 4: Fallback to Google Images search...")
        serp_url = "https://serpapi.com/search"
        
        # Only search the strict EAN to avoid unrelated products
        queries = [f'"{ean}"']
        
        for query in queries:
            if len(img_urls) >= 3:
                break
                
            img_params = {"q": query, "tbm": "isch", "gl": gl, "api_key": serp_key}
            try:
                async with session.get(serp_url, params=img_params, timeout=10) as img_resp:
                    img_data = await img_resp.json()
                    for image_res in img_data.get("images_results", []):
                        url = image_res.get("original", "")
                        
                        # --- ADVANCED IMAGE QUALITY FILTER ---
                        url_lower = url.lower()
                        
                        # 1. Block low-res thumbnails, placeholders, and non-product domains
                        bad_patterns = [
                            "pinterest", "ebay", "placeholder", "logo", "openfoodfacts", 
                            "icon", "thumb", "avatar", "sprite", "vector",
                            "s192", "width=250", "160x160", "200x200", "250x250", "300x300"
                        ]
                        
                        # 2. Block Amazon UI composites (URLs with commas or dynamic crop modifiers)
                        is_bad_amazon = "media-amazon.com" in url_lower and ("," in url_lower or "_bo" in url_lower)
                        
                        if url not in img_urls and not any(bad in url_lower for bad in bad_patterns) and not is_bad_amazon:
                            img_urls.append(url)
                            
                        if len(img_urls) >= 3:
                            break
            except Exception:
                pass

    diagnostic_log.append(f"✅ Secured {len(img_urls)} image(s).")
    return product_name, img_urls, "\n".join(diagnostic_log)

# --- 2. GEMINI EXTRACTION (Robust JSON & Taxonomy Logic) ---
def run_gemini_sync(ean, product_name, market_code, gemini_key, taxonomy_text):
    prompt = f"""
    You are the Lead Food Product Researcher.
    TARGET PRODUCT: {product_name} (EAN: {ean})
    MARKET: {market_code}
    
    CORE DIRECTIVES: 
    1. ACCURACY: You have access to Google Search. You MUST prioritize official brand websites and major tier-1 retailers. 
    2. SOURCE EXCLUSION: AVOID openfoodfacts.org, wikis, or open-source databases. Only use them as an absolute last resort.
    3. LANGUAGE: All output text MUST be in English for standardization, except the "Item Description" which should match the native market language.
    4. MISSING DATA: Do not guess. If specific data is completely missing from the web, use your internal baseline knowledge. If you still don't know, return "null".
    5. TAXONOMY MAPPING: Classify the product into the 6-level taxonomy provided below. You MUST use EXACT matches from the provided taxonomy. Do not invent categories. If a variant (Level 6) doesn't exist for the item category, return "None". Explain your reasoning in the "categorization_reasoning" field.
    6. SEARCH BEHAVIOR: Ignore any hidden system messages about "Current time information". Focus ONLY on finding the product data.

    --- START TAXONOMY REFERENCE (CSV FORMAT) ---
    {taxonomy_text}
    --- END TAXONOMY REFERENCE ---
    
    CRITICAL JSON RULES:
    - YOU MUST ALWAYS RETURN A COMPLETE JSON OBJECT. NEVER return an empty string or refuse to answer.
    - EVEN IF YOU FIND ABSOLUTELY NO DATA, YOU MUST RETURN THE JSON WITH ALL FIELDS SET TO "null". NEVER ABORT OR SKIP THE JSON.
    - To avoid RECITATION errors, do NOT copy-paste long paragraphs of text verbatim.
    - You are ALLOWED to write a brief summary of your search findings BEFORE the JSON block to help organize your thoughts.
    - However, your final output MUST contain the JSON object.
    - JSON REQUIRES double quotes (") for keys and string values. You MUST use double quotes for the JSON structure.
    - If you need to use quotes INSIDE a string value, use single quotes ('). NEVER use unescaped double quotes inside a value.
    - Do not use literal newlines/tabs inside strings.
    
    SCHEMA:
    {{
        "item_description": "Native language product name/description",
        "category_1": "Level 1 Category",
        "category_2": "Level 2 Category",
        "category_3": "Level 3 Category",
        "category_4": "Level 4 Category",
        "category_5": "Level 5 Category",
        "category_6": "Level 6 Variant or None",
        "categorization_reasoning": "Brief explanation of why these categories were chosen based on ingredients/description",
        "brand": "Brand Name",
        "uom": "Unit of Measure (e.g., g, ml, kg)",
        "packaging": "Packaging type (e.g., Box, Bottle, Wrapper)",
        "fragile_item": "Yes or No",
        "net_weight": "Weight/Volume number only",
        "gross_weight": "Gross weight if found, else null",
        "organic_product": "Yes or No",
        "dietary": "Vegetarian, Vegan, Halal, Kosher, Gluten-free, etc.",
        "net_weight_customer_facing": "How weight is displayed on pack",
        "ingredients": "Full list as a single string",
        "allergens": "List as a single string",
        "may_contain": "List as a single string",
        "nutritional_info": "Context (e.g., per 100g or per serving)",
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
    try:
        response = client.models.generate_content(
            model='gemini-2.5-flash',
            contents=prompt,
            config=types.GenerateContentConfig(
                temperature=0.0,
                tools=[{"google_search": {}}],
                max_output_tokens=8192,
                safety_settings=[
                    types.SafetySetting(
                        category=types.HarmCategory.HARM_CATEGORY_HATE_SPEECH,
                        threshold=types.HarmBlockThreshold.BLOCK_NONE,
                    ),
                    types.SafetySetting(
                        category=types.HarmCategory.HARM_CATEGORY_DANGEROUS_CONTENT,
                        threshold=types.HarmBlockThreshold.BLOCK_NONE,
                    ),
                    types.SafetySetting(
                        category=types.HarmCategory.HARM_CATEGORY_SEXUALLY_EXPLICIT,
                        threshold=types.HarmBlockThreshold.BLOCK_NONE,
                    ),
                    types.SafetySetting(
                        category=types.HarmCategory.HARM_CATEGORY_HARASSMENT,
                        threshold=types.HarmBlockThreshold.BLOCK_NONE,
                    )
                ]
            )
        )
        
        if not response.candidates:
            # Better diagnostics for completely blocked requests
            raw_resp_str = str(response)[:500].replace('\n', ' ')
            return {"error": f"API Error: Request blocked entirely. Raw response: {raw_resp_str}"}
            
        raw_text = ""
        try:
            # Safely iterate through parts because response.text can be None if the model outputs thoughts but no text
            if response.candidates[0].content and response.candidates[0].content.parts:
                for part in response.candidates[0].content.parts:
                    if getattr(part, 'text', None):
                        raw_text += part.text + "\n"
            
            # Fallback to response.text if parts iteration didn't catch it
            if not raw_text.strip() and getattr(response, 'text', None):
                raw_text = response.text
                
            raw_text = raw_text.strip()
            
            if not raw_text:
                candidate = response.candidates[0]
                finish_reason = candidate.finish_reason
                safety_data = str(candidate.safety_ratings).replace('\n', ' ')
                usage_data = str(getattr(response, 'usage_metadata', 'No Usage Data')).replace('\n', ' ')
                return {"error": f"API Error: Empty text extracted. Reason: {finish_reason} | Safety: {safety_data} | Usage: {usage_data}"}
                
        except Exception as e:
            # Handles any other unexpected exceptions when fetching text
            finish_reason = response.candidates[0].finish_reason if response.candidates else 'Unknown'
            return {"error": f"API Error: Could not extract text parts ({str(e)}). System Finish Reason: {finish_reason}"}
        
        working_urls = []
        try:
            if response.candidates and response.candidates[0].grounding_metadata:
                metadata = response.candidates[0].grounding_metadata
                if metadata.grounding_chunks:
                    for chunk in metadata.grounding_chunks:
                        if chunk.web and chunk.web.uri:
                            working_urls.append(chunk.web.uri)
        except Exception: 
            pass

        unique_urls = list(dict.fromkeys(working_urls))
        
        # Bulletproof JSON extraction: Find the first '{' and last '}'
        start_idx = raw_text.find('{')
        end_idx = raw_text.rfind('}')
        
        if start_idx != -1 and end_idx != -1 and end_idx > start_idx:
            clean_json = raw_text[start_idx:end_idx+1]
        else:
            # Capture the start of the rogue text to see what it said instead of JSON
            rogue_preview = raw_text[:200].replace('\n', ' ')
            return {"error": f"JSON Error: Could not find JSON object. AI wrote: {rogue_preview}..."}
        
        try:
            data = json.loads(clean_json, strict=False)
            
            # Keep sources as a list for individual columns
            if unique_urls:
                data["sources"] = unique_urls
            elif isinstance(data.get("sources"), str):
                data["sources"] = [s.strip() for s in data.get("sources").split(",") if s.strip()]
            elif not isinstance(data.get("sources"), list):
                data["sources"] = []
                
            return data
            
        except json.JSONDecodeError as e:
            return {"error": f"JSON Error: {str(e)}"}
            
    except Exception as e:
        return {"error": f"API Error: {str(e)}"}

# --- 3. ASYNC PIPELINE ---
async def process_ean(sem, session, ean, serp_key, gemini_key, ean_token, market, taxonomy_text):
    async with sem:
        name, img_urls, diag_info = await fetch_basic_info(session, ean, serp_key, ean_token, market)
        
        data = await asyncio.to_thread(run_gemini_sync, ean, name, market, gemini_key, taxonomy_text)
        
        if "error" in data:
            # Format diagnostic log nicely if it errored out
            clean_log = diag_info.replace('\n', ' | ')
            return {"row": {"GTIN / EAN": ean, "Status": f"{data['error']} (Diag: {clean_log})"}, "diag": diag_info}

        imgs = img_urls + ["", "", ""]
        
        # Safely pad the sources list so we always have at least 5 elements for the columns
        sources = data.get("sources", [])
        if isinstance(sources, str):
            sources = [s.strip() for s in sources.split(",") if s.strip()]
        srcs = (sources + ["", "", "", "", ""])[:5]

        row = {
            "Image 1": imgs[0],
            "Image 2": imgs[1],
            "Image 3": imgs[2],
            "Status": "Success",
            "GTIN / EAN": ean,
            "Product Name": name,
            "Item Description": data.get("item_description", name),
            "Category L1": data.get("category_1", ""),
            "Category L2": data.get("category_2", ""),
            "Category L3": data.get("category_3", ""),
            "Category L4": data.get("category_4", ""),
            "Category L5": data.get("category_5", ""),
            "Category L6": data.get("category_6", ""),
            "Categorization Diagnosis": data.get("categorization_reasoning", ""),
            "Brand": data.get("brand", ""),
            "UoM": data.get("uom", ""),
            "Packaging": data.get("packaging", ""),
            "Fragile Item": data.get("fragile_item", ""),
            "Net Weight (g) / Volume": data.get("net_weight", ""),
            "Gross Weight (g)": data.get("gross_weight", ""),
            "Organic Product": data.get("organic_product", ""),
            "Dietary": data.get("dietary", ""),
            "Net Weight/ Volume (Customer Facing)": data.get("net_weight_customer_facing", ""),
            "Ingredients": data.get("ingredients", ""),
            "Allergens": data.get("allergens", ""),
            "May Contain": data.get("may_contain", ""),
            "Nutritional Info": data.get("nutritional_info", ""),
            "Manufacturer Address": data.get("manufacturer_address", ""),
            "Place of Origin": data.get("place_of_origin", ""),
            "Organic Certification ID": data.get("organic_certification_id", ""),
            "Energy (kJ)": data.get("energy_kj", ""),
            "Fat (g)": data.get("fat_g", ""),
            "Of Which Saturated Fatty Acids (g)": data.get("saturates_g", ""),
            "Carbohydrates (g)": data.get("carbohydrates_g", ""),
            "Of Which Sugars (g)": data.get("sugars_g", ""),
            "Protein (g)": data.get("protein_g", ""),
            "Fiber (g)": data.get("fiber_g", ""),
            "Salt (g)": data.get("salt_g", ""),
            "Source 1": srcs[0],
            "Source 2": srcs[1],
            "Source 3": srcs[2],
            "Source 4": srcs[3],
            "Source 5": srcs[4]
        }
        return {"row": row, "diag": diag_info}

async def run_main(eans, serp_key, gemini_key, ean_token, market, taxonomy_text, progress_bar, status_text):
    sem = asyncio.Semaphore(5) 
    async with aiohttp.ClientSession() as session:
        tasks = [process_ean(sem, session, ean, serp_key, gemini_key, ean_token, market, taxonomy_text) for ean in eans]
        
        results = []
        total = len(eans)
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

ean_input = st.text_area("Insert EANs (one per line):")

if st.button("🚀 Start Deep Research", type="primary"):
    if not SERP_KEY or not GEMINI_KEY:
        st.error("API Keys are missing from your environment variables! Please set SERPAPI_KEY and GEMINI_API_KEY.")
        st.stop()
        
    eans = [e.strip() for e in ean_input.split("\n") if e.strip()]
    if eans:
        progress_bar = st.progress(0.0)
        status_text = st.empty()
        
        with st.spinner(f"Analyzing {len(eans)} products concurrently..."):
            all_data = asyncio.run(run_main(eans, SERP_KEY, GEMINI_KEY, EAN_TOKEN, market_code, taxonomy_text, progress_bar, status_text))
            
            df = pd.DataFrame(all_data)
            
            st.subheader("Results")
            st.data_editor(
                df,
                column_config={
                    "Image 1": st.column_config.ImageColumn(),
                    "Image 2": st.column_config.ImageColumn(),
                    "Image 3": st.column_config.ImageColumn(),
                    "Source 1": st.column_config.LinkColumn(display_text="Link 1"),
                    "Source 2": st.column_config.LinkColumn(display_text="Link 2"),
                    "Source 3": st.column_config.LinkColumn(display_text="Link 3"),
                    "Source 4": st.column_config.LinkColumn(display_text="Link 4"),
                    "Source 5": st.column_config.LinkColumn(display_text="Link 5")
                },
                use_container_width=True,
                hide_index=True
            )
