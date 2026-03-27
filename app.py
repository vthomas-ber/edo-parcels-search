import streamlit as st
import pandas as pd
import os
import json
import asyncio
import aiohttp
from google import genai
from google.genai import types

st.set_page_config(page_title="Food Data Researcher PRO", layout="wide")

# --- 1. BASIC INFO RETRIEVAL (Name + Image via SerpAPI) ---
async def fetch_basic_info(session, ean, serp_key, market_code):
    gl = market_code.lower()
    diagnostic_log = []
    
    if not serp_key:
        return None, None, "Error: Missing SerpAPI Key"
        
    serp_url = "https://serpapi.com/search"
    diagnostic_log.append(f"🔍 Searching EAN {ean} on Google ({market_code})...")
    
    try:
        async with session.get(serp_url, params={"q": str(ean), "gl": gl, "api_key": serp_key}, timeout=20) as resp:
            data = await resp.json()
            organic = data.get("organic_results", [])
            if not organic:
                return None, None, "❌ Product not found on Google."
            
            product_name = organic[0].get("title", "").split("-")[0].split("|")[0].strip()
            diagnostic_log.append(f"✅ Name found: {product_name}")

        diagnostic_log.append(f"🖼️ Searching high-res image for: {product_name}...")
        img_params = {"q": product_name, "tbm": "isch", "gl": gl, "api_key": serp_key}
        async with session.get(serp_url, params=img_params, timeout=20) as img_resp:
            img_data = await img_resp.json()
            img_url = None
            for image_res in img_data.get("images_results", []):
                url = image_res.get("original", "")
                if all(x not in url.lower() for x in ["pinterest", "placeholder", "logo"]):
                    img_url = url
                    break
            
            diagnostic_log.append("✅ Image found." if img_url else "⚠️ Image not found.")
            return product_name, img_url, "\n".join(diagnostic_log)
            
    except Exception as e:
        return None, None, f"❌ SerpAPI Connection Error: {str(e)}"

# --- 2. GEMINI EXTRACTION (Robust JSON & VertexAI Links) ---
def run_gemini_sync(ean, product_name, market_code, gemini_key):
    prompt = f"""
    You are the Lead Food Product Researcher.
    TARGET PRODUCT: {product_name} (EAN: {ean})
    MARKET: {market_code}
    
    CORE DIRECTIVES: 
    1. ACCURACY: You have access to Google Search. You MUST prioritize official brand websites and major tier-1 retailers. 
    2. SOURCE EXCLUSION: AVOID openfoodfacts.org, wikis, or open-source databases. Only use them as an absolute last resort.
    3. LANGUAGE: All output text MUST be in English for standardization, except the "Item Description" which should match the native market language.
    4. MISSING DATA: Do not guess. If specific data is completely missing from the web, return "null".
    
    CRITICAL JSON RULES:
    - You must respond with ONLY a raw JSON object. Do NOT wrap it in ```json blocks.
    - NEVER use double quotes (") inside your text strings. If you need to quote something, use single quotes ('). Using double quotes will break the system.
    
    SCHEMA:
    {{
        "key": "Leave empty or generate a unique ID if appropriate",
        "item_description": "Native language product name/description",
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
        "sources": "Leave completely blank."
    }}
    """
    
    client = genai.Client(api_key=gemini_key)
    try:
        response = client.models.generate_content(
            model='gemini-2.5-flash',
            contents=prompt,
            config=types.GenerateContentConfig(
                temperature=0.0,
                tools=[{"google_search": {}}]
            )
        )
        
        # Pull ONLY the guaranteed VertexAI links directly from Google's backend
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

        # Keep exactly the top 3 working links
        unique_urls = list(dict.fromkeys(working_urls))[:3]

        # Aggressive cleanup for JSON
        raw_text = response.text.strip()
        if raw_text.startswith("```json"):
            raw_text = raw_text[7:]
        elif raw_text.startswith("```"):
            raw_text = raw_text[3:]
        if raw_text.endswith("```"):
            raw_text = raw_text[:-3]
        
        raw_text = raw_text.strip()
        
        try:
            data = json.loads(raw_text)
            
            # Inject the working Vertex links into the JSON
            if unique_urls:
                data["sources"] = ", ".join(unique_urls)
            else:
                data["sources"] = "No Grounding links provided by Google"
                
            return data
            
        except json.JSONDecodeError as e:
            return {"error": f"JSON Parsing Error. The AI formatted the data incorrectly."}
            
    except Exception as e:
        return {"error": f"API Error: {str(e)}"}

# --- 3. ASYNC PIPELINE ---
async def process_ean(sem, session, ean, serp_key, gemini_key, market):
    async with sem:
        name, img, diag_info = await fetch_basic_info(session, ean, serp_key, market)
        if not name:
            return {"row": {"GTIN / EAN": ean, "Status": "Not Found"}, "diag": diag_info}
        
        data = await asyncio.to_thread(run_gemini_sync, ean, name, market, gemini_key)
        
        if "error" in data:
            return {"row": {"GTIN / EAN": ean, "Status": data["error"]}, "diag": diag_info}

        row = {
            "Image": img or "",
            "Status": "Success",
            "Key": data.get("key", ""),
            "Item Description": data.get("item_description", name),
            "GTIN / EAN": ean,
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

async def run_main(eans, serp_key, gemini_key, market, progress_bar, status_text):
    sem = asyncio.Semaphore(5) 
    async with aiohttp.ClientSession() as session:
        tasks = [process_ean(sem, session, ean, serp_key, gemini_key, market) for ean in eans]
        
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

ean_input = st.text_area("Insert EANs (one per line):")

if st.button("🚀 Start Deep Research", type="primary"):
    if not SERP_KEY or not GEMINI_KEY:
        st.error("API Keys are missing from your environment variables! Please set SERPAPI_KEY and GEMINI_API_KEY on Render.")
        st.stop()
        
    eans = [e.strip() for e in ean_input.split("\n") if e.strip()]
    if eans:
        progress_bar = st.progress(0.0)
        status_text = st.empty()
        
        with st.spinner(f"Analyzing {len(eans)} products concurrently..."):
            all_data = asyncio.run(run_main(eans, SERP_KEY, GEMINI_KEY, market_code, progress_bar, status_text))
            
            df = pd.DataFrame(all_data)
            
            st.subheader("Results")
            st.data_editor(
                df,
                column_config={"Image": st.column_config.ImageColumn()},
                use_container_width=True,
                hide_index=True
            )
