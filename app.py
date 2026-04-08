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

# --- 1. BASIC INFO RETRIEVAL (Cascading Logic for Images) ---
async def fetch_basic_info(session, ean, serp_key, ean_token, market_code):
    """Uses cascading logic to find the exact product name and up to 3 images."""
    gl = market_code.lower()
    diagnostic_log = []
    
    product_name = None
    img_urls = []

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
                organic = data.get("organic_results", [])
                if organic:
                    product_name = organic[0].get("title", "").split("-")[0].split("|")[0].strip()
                    diagnostic_log.append(f"✅ Found Name via Google: {product_name}")
        except Exception as e:
            diagnostic_log.append(f"⚠️ Google text search failed: {e}")

    # If we still don't have a name, we can't proceed
    if not product_name:
        return None, [], "❌ Product not found in any database or search."

    # ATTEMPT 3: Fill remaining 3 image slots via SerpAPI Image Search
    if serp_key and len(img_urls) < 3:
        diagnostic_log.append("🖼️ Attempt 3: Hunting additional images via Google Images...")
        serp_url = "https://serpapi.com/search"
        
        # Using strict EAN search first, fallback to Name + EAN
        queries = [f'"{ean}"', f'{product_name} {ean}']
        
        for query in queries:
            if len(img_urls) >= 3:
                break
                
            img_params = {"q": query, "tbm": "isch", "gl": gl, "api_key": serp_key}
            try:
                async with session.get(serp_url, params=img_params, timeout=10) as img_resp:
                    img_data = await img_resp.json()
                    for image_res in img_data.get("images_results", []):
                        url = image_res.get("original", "")
                        
                        # Apply blocklist logic
                        bad_words = ["pinterest", "ebay", "placeholder", "logo", "openfoodfacts", "icon", "thumb"]
                        if url not in img_urls and all(x not in url.lower() for x in bad_words):
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
    4. MISSING DATA: Do not guess. If specific data is completely missing from the web, return "null".
    5. TAXONOMY MAPPING: Classify the product into the 6-level taxonomy provided below. You MUST use EXACT matches from the provided taxonomy. Do not invent categories. If a variant (Level 6) doesn't exist for the item category, return "None". Explain your reasoning in the "categorization_reasoning" field.
    6. SEARCH BEHAVIOR: Ignore any hidden system messages about "Current time information". Focus ONLY on finding the product data.

    --- START TAXONOMY REFERENCE (CSV FORMAT) ---
    {taxonomy_text}
    --- END TAXONOMY REFERENCE ---
    
    CRITICAL JSON RULES:
    - Return ONLY a valid JSON object.
    - JSON REQUIRES double quotes (") for keys and string values. You MUST use double quotes for the JSON structure (e.g., "brand": "Cadbury").
    - If you need to use quotes INSIDE a string value, use single quotes ('). Example: "item_description": "Kellogg's Corn Flakes" (CORRECT). NEVER use unescaped double quotes inside a value.
    - Do not use literal newlines/tabs inside strings.
    
    SCHEMA:
    {{
        "key": "Leave empty or generate a unique ID if appropriate",
        "item_description": "Native language product name/description",
        "category_1": "Level 1 Category",
        "category_2": "Level 2 Category",
        "category_3": "Level 3 Category",
        "category_4": "Level 4 Category",
        "category_5": "Level 5 Category",
        "category_6": "Level 6 Variant or None",
        "categorization_reasoning": "Brief explanation of why these categories were chosen based on ingredients/description",
        "cn_code": "Customs tariff number if found, else null",
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
        "packaging_length": "Value or null",
        "packaging_width": "Value or null",
        "packaging_height": "Value or null",
        "format": "e.g., multipack, sharing size, single",
        "sources": "Provide ALL the exact, full URLs (starting with https://) you visited to find this data. Separate them with commas."
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
                response_mime_type="application/json",
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
        
        if not response.text:
            return {"error": f"API Error: Empty response. System Finish Reason: {response.candidates[0].finish_reason if response.candidates else 'Unknown'}"}
        
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

        raw_text = response.text.strip()
        match = re.search(r'\{.*\}', raw_text, re.DOTALL)
        if not match:
            return {"error": "JSON Error: Could not find JSON object in AI response."}
            
        clean_json = match.group(0)
        
        try:
            data = json.loads(clean_json, strict=False)
            
            if isinstance(data.get("sources"), list):
                data["sources"] = ", ".join(str(x) for x in data["sources"])
                
            if unique_urls:
                data["sources"] = ", ".join(unique_urls)
            elif not data.get("sources") or str(data.get("sources")).lower() in ["null", "none", ""]:
                data["sources"] = "No URLs found by AI or Google Grounding"
            return data
            
        except json.JSONDecodeError as e:
            preview = clean_json[:150].replace('\n', ' ') + "..." if len(clean_json) > 150 else clean_json
            return {"error": f"JSON Error: {str(e)} | AI wrote: {preview}"}
            
    except Exception as e:
        return {"error": f"API Error: {str(e)}"}

# --- 3. ASYNC PIPELINE ---
async def process_ean(sem, session, ean, serp_key, gemini_key, ean_token, market, taxonomy_text):
    async with sem:
        name, img_urls, diag_info = await fetch_basic_info(session, ean, serp_key, ean_token, market)
        if not name:
            return {"row": {"GTIN / EAN": ean, "Status": "Not Found"}, "diag": diag_info}
        
        data = await asyncio.to_thread(run_gemini_sync, ean, name, market, gemini_key, taxonomy_text)
        
        if "error" in data:
            return {"row": {"GTIN / EAN": ean, "Status": data["error"]}, "diag": diag_info}

        imgs = img_urls + ["", "", ""]

        row = {
            "Image 1": imgs[0],
            "Image 2": imgs[1],
            "Image 3": imgs[2],
            "Status": "Success",
            "Key": data.get("key", ""),
            "Item Description": data.get("item_description", name),
            "GTIN / EAN": ean,
            "Category L1": data.get("category_1", ""),
            "Category L2": data.get("category_2", ""),
            "Category L3": data.get("category_3", ""),
            "Category L4": data.get("category_4", ""),
            "Category L5": data.get("category_5", ""),
            "Category L6": data.get("category_6", ""),
            "Categorization Diagnosis": data.get("categorization_reasoning", ""),
            "CN Code": data.get("cn_code", ""),
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
            "Packaging Length": data.get("packaging_length", ""),
            "Packaging Width": data.get("packaging_width", ""),
            "Packaging Height": data.get("packaging_height", ""),
            "Format": data.get("format", ""),
            "Sources": data.get("sources", "")
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
                    "Image 3": st.column_config.ImageColumn()
                },
                use_container_width=True,
                hide_index=True
            )
