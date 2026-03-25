import streamlit as st
import pandas as pd
import os
import json
import asyncio
import aiohttp
from google import genai
from google.genai import types

st.set_page_config(page_title="Food Data Fast (Async)", layout="wide")

# --- 1. FAST ASYNC INFO RETRIEVAL (Name + Image) ---
async def fetch_basic_info(session, ean, serp_key, market_code):
    """Tries Open Food Facts first, falls back to SerpAPI text search, then SerpAPI image search if needed."""
    gl = market_code.lower()
    diagnostic_log = []
    
    # Attempt 1: Open Food Facts API (Instant, Free, usually has images)
    off_url = f"https://world.openfoodfacts.org/api/v0/product/{ean}.json"
    try:
        # OFF requires a short timeout so we don't waste time if it's slow
        timeout_config = aiohttp.ClientTimeout(total=5)
        async with session.get(off_url, timeout=timeout_config) as resp:
            if resp.status == 200:
                data = await resp.json()
                if data.get("status") == 1:
                    product = data.get("product", {})
                    name = product.get("product_name") or product.get("generic_name")
                    img = product.get("image_url")
                    if name:
                        diagnostic_log.append("✅ Found Name & Image via OpenFoodFacts (0 SerpAPI credits used).")
                        return name, img, "\n".join(diagnostic_log)
    except asyncio.TimeoutError:
        diagnostic_log.append("⚠️ OpenFoodFacts timed out.")
    except Exception as e:
        diagnostic_log.append(f"⚠️ OpenFoodFacts error: {type(e).__name__}")

    # Attempt 2: SerpAPI Text Search (Finds name, sometimes finds thumbnail)
    if not serp_key:
        diagnostic_log.append("❌ OpenFoodFacts failed and no SerpAPI key provided.")
        return None, None, "\n".join(diagnostic_log)
        
    diagnostic_log.append("🔍 Falling back to SerpAPI...")
    serp_url = "https://serpapi.com/search"
    params = {"q": str(ean), "gl": gl, "api_key": serp_key}
    timeout_config = aiohttp.ClientTimeout(total=15)
    
    try:
        async with session.get(serp_url, params=params, timeout=timeout_config) as resp:
            data = await resp.json()
            
            if "error" in data:
                diagnostic_log.append(f"❌ SerpAPI Error: {data['error']}")
                return None, None, "\n".join(diagnostic_log)
                
            organic = data.get("organic_results", [])
            if not organic:
                # Try global fallback if local market fails
                params.pop("gl", None)
                async with session.get(serp_url, params=params, timeout=timeout_config) as fallback_resp:
                    data = await fallback_resp.json()
                    organic = data.get("organic_results", [])
                    
            if not organic:
                diagnostic_log.append("❌ SerpAPI found no organic results for this EAN.")
                return None, None, "\n".join(diagnostic_log)
                
            # Extract Name
            raw_title = organic[0].get("title", "")
            name = raw_title.split("-")[0].split("|")[0].strip()
            diagnostic_log.append(f"✅ Name found via SerpAPI: {name}")
            
            # Extract Image from inline results
            img = None
            inline_images = data.get("inline_images", [])
            if inline_images:
                img = inline_images[0].get("original") or inline_images[0].get("thumbnail")
                diagnostic_log.append("✅ Image scavenged from SerpAPI inline_images.")
            elif organic[0].get("thumbnail"):
                img = organic[0].get("thumbnail")
                diagnostic_log.append("✅ Image scavenged from SerpAPI organic thumbnail.")
                
    except Exception as e:
        diagnostic_log.append(f"❌ SerpAPI Connection Failed: {e}")
        return None, None, "\n".join(diagnostic_log)

    # Attempt 3: Dedicated Image Search (ONLY if Attempt 2 missed the image)
    if not img and name:
        diagnostic_log.append("🔍 No image in main search. Running dedicated Image Search...")
        img_params = {"q": name, "tbm": "isch", "gl": gl, "api_key": serp_key}
        try:
            async with session.get(serp_url, params=img_params, timeout=timeout_config) as img_resp:
                img_data = await img_resp.json()
                for image_res in img_data.get("images_results", []):
                    if "pinterest" not in image_res.get("original", "") and "placeholder" not in image_res.get("original", ""):
                        img = image_res.get("original")
                        diagnostic_log.append("✅ Image found via dedicated SerpAPI Image search.")
                        break
        except Exception as e:
            diagnostic_log.append(f"⚠️ Dedicated Image Search failed: {e}")
            
    return name, img, "\n".join(diagnostic_log)

# --- 2. GEMINI EXTRACTION (WITH GROUNDING METADATA) ---
def run_gemini_sync(ean, product_name, market_code, gemini_key):
    """Synchronous Gemini call with Google Search Tool enabled."""
    prompt = f"""
    You are the Lead Food Product Researcher.
    TARGET PRODUCT: {product_name} (EAN: {ean})
    MARKET: {market_code}
    
    CORE DIRECTIVE: Accuracy is your absolute priority. You have access to Google Search. USE IT to search the internet for this specific product to find its exact nutritional values and ingredients. Check major online grocery retailers and official brand websites.
    
    TASK:
    1. Search the web for "{product_name} ingredients nutrition facts".
    2. Extract the data. All text MUST be translated to the native language of {market_code}.
    3. Ensure 'Ingredients' and 'Allergens' are single continuous text strings.
    4. Format the output STRICTLY as a valid JSON object. DO NOT wrap the output in markdown code blocks.
    
    OUTPUT SCHEMA:
    {{
        "diagnostic_log": "Short summary of what you found or why you set fields to null.",
        "brand": "Brand Name",
        "product_name": "Product Name (Target Language)",
        "net_weight": "Weight",
        "organic_id": "Code or N/A",
        "ingredients": "Full list",
        "allergens": "List",
        "may_contain": "List",
        "nutritional_scope": "e.g., per 100g",
        "energy": "kJ / kcal",
        "fat": "value",
        "saturates": "value",
        "carbs": "value",
        "sugars": "value",
        "fiber": "value",
        "protein": "value",
        "salt": "value",
        "confidence_level": "High/Medium/Low",
        "sources": "Will be overwritten by metadata"
    }}
    """
    
    client = genai.Client(api_key=gemini_key)
    try:
        response = client.models.generate_content(
            model='gemini-2.5-flash',
            contents=prompt,
            config=types.GenerateContentConfig(
                temperature=0.2,
                tools=[{"google_search": {}}] # ENABLES NATIVE GOOGLE SEARCH
            )
        )
        
        # 🌟 NEW: Extract the REAL clickable URLs from Google's Grounding Metadata!
        real_sources = []
        try:
            if response.candidates and response.candidates[0].grounding_metadata:
                chunks = response.candidates[0].grounding_metadata.grounding_chunks
                for chunk in chunks:
                    if chunk.web and chunk.web.uri:
                        real_sources.append(chunk.web.uri)
        except Exception:
            pass # If metadata fails, we just ignore it
        
        # Safely parse JSON avoiding markdown parser bugs
        raw_json = response.text.strip()
        raw_json = raw_json.replace("```json", "").replace("```", "").strip()
        data = json.loads(raw_json)
        
        # Overwrite the AI's hallucinated sources with the real Google metadata sources
        if real_sources:
            # Remove duplicates and join with commas
            unique_sources = list(set(real_sources))
            data["sources"] = ", ".join(unique_sources)
            
        return data
        
    except Exception as e:
        return {"error": str(e), "diagnostic_log": f"Gemini API Error: {str(e)}"}

async def fetch_nutrition_async(ean, product_name, market_code, gemini_key):
    """Wraps the synchronous Gemini call in an async thread with a strict timeout."""
    try:
        # Enforce an absolute 45-second limit to prevent infinite retries (Rate Limit Hangs)
        return await asyncio.wait_for(
            asyncio.to_thread(run_gemini_sync, ean, product_name, market_code, gemini_key),
            timeout=45.0
        )
    except asyncio.TimeoutError:
        return {
            "error": "Gemini Request Timed Out.",
            "diagnostic_log": "The AI took too long to respond. This usually happens when you hit the Gemini Free Tier limit (15 Requests Per Minute)."
        }

# --- 3. ASYNC WORKER PIPELINE ---
async def process_single_ean(sem, session, ean, serp_key, gemini_key, market):
    """Processes a single EAN from start to finish. Semaphore limits concurrency."""
    async with sem:
        # 1. Get Name and Image
        name, img, basic_log = await fetch_basic_info(session, ean, serp_key, market)
        
        if not name:
            return {
                "row": {"EAN": ean, "Status": "Name Not Found", "Image": ""},
                "diag": {"EAN": ean, "Basic Info Log": basic_log, "Gemini Log": "Skipped (No name found)"}
            }
            
        # 2. Get Nutrition Data via Gemini
        data = await fetch_nutrition_async(ean, name, market, gemini_key)
        
        # 3. Compile Results
        row = {
            "EAN": ean,
            "Image": img or "",
            "Status": "Error" if "error" in data else "Success",
            "Name": name
        }
        # Add all Gemini extracted fields to the row
        row.update({k: v for k, v in data.items() if k not in ["diagnostic_log", "error"]})
        
        diag = {
            "EAN": ean,
            "Basic Info Log": basic_log,
            "Gemini Log": data.get("diagnostic_log", data.get("error", "No log provided."))
        }
        
        return {"row": row, "diag": diag}

async def run_all_eans(eans, serp_key, gemini_key, market, progress_bar, status_text):
    """Main async loop to process all EANs concurrently."""
    # Reduced from 5 to 3 to prevent instantly blowing past the Gemini 15 RPM limit
    sem = asyncio.Semaphore(3) 
    
    # Adding a standard User-Agent prevents basic anti-bot blocks from APIs like OpenFoodFacts
    headers = {'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/120.0.0.0 Safari/537.36'}
    async with aiohttp.ClientSession(headers=headers) as session:
        tasks = [process_single_ean(sem, session, ean, serp_key, gemini_key, market) for ean in eans]
        
        results = []
        diagnostics = {}
        total = len(eans)
        
        completed = 0
        for f in asyncio.as_completed(tasks):
            res = await f
            results.append(res["row"])
            diagnostics[res["diag"]["EAN"]] = res["diag"]
            
            completed += 1
            progress_bar.progress(completed / total)
            status_text.text(f"Processed {completed}/{total} items...")
            
        return results, diagnostics

# --- UI APP (STREAMLIT) ---
st.title("⚡ Food Data Fast (Async Parallel Processing)")
st.markdown("This version runs EANs concurrently, utilizes the free OpenFoodFacts API to save credits, and scavenges images in a single step to maximize speed.")

with st.sidebar:
    st.header("🔑 API Setup")
    SERP_KEY = st.text_input("SerpAPI Key", value=os.environ.get("SERPAPI_KEY", ""), type="password")
    GEMINI_KEY = st.text_input("Gemini API Key", value=os.environ.get("GEMINI_API_KEY", ""), type="password")
    market = st.selectbox("Target Market", ["IT", "DE", "UK", "FR", "ES"])

ean_input = st.text_area("Paste EANs (one per line):", "4260725010067\n4002809025679")

if st.button("🚀 Start Fast Search", type="primary"):
    if not SERP_KEY or not GEMINI_KEY:
        st.error("Please provide both API Keys.")
        st.stop()
        
    eans = [e.strip() for e in ean_input.split("\n") if e.strip()]
    if not eans:
        st.warning("Please insert at least one EAN.")
        st.stop()
        
    progress_bar = st.progress(0.0)
    status_text = st.empty()
    
    # Execute the Async Loop
    with st.spinner("Firing parallel requests..."):
        results, diagnostics = asyncio.run(
            run_all_eans(eans, SERP_KEY, GEMINI_KEY, market, progress_bar, status_text)
        )
        
    status_text.text("✅ Processing Complete!")
    
    # Show Results
    st.subheader("📊 Results")
    df = pd.DataFrame(results)
    
    # Reorder columns slightly to make it readable
    cols = df.columns.tolist()
    if "EAN" in cols and "Status" in cols and "Image" in cols and "Name" in cols:
        cols.insert(0, cols.pop(cols.index("Status")))
        cols.insert(0, cols.pop(cols.index("Name")))
        cols.insert(0, cols.pop(cols.index("Image")))
        cols.insert(0, cols.pop(cols.index("EAN")))
        df = df[cols]
        
    st.data_editor(
        df, 
        column_config={"Image": st.column_config.ImageColumn("Image")}, 
        use_container_width=True, 
        hide_index=True
    )
    
    # Show Diagnostics
    st.divider()
    st.subheader("🔬 Diagnostic Center")
    st.markdown("Check exactly how the system found the Name/Image, and what the AI was thinking.")
    
    selected_ean_diag = st.selectbox("Select EAN to inspect:", list(diagnostics.keys()))
    
    if selected_ean_diag:
        diag = diagnostics.get(selected_ean_diag, {})
        
        col1, col2 = st.columns(2)
        with col1:
            st.info("**Step 1: Basic Info Fetcher (Name & Image)**")
            st.text(diag.get("Basic Info Log", "N/A"))
                
        with col2:
            st.warning("**Step 2: Gemini Thought Process**")
            st.write(diag.get("Gemini Log", "N/A"))
