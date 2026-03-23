import streamlit as st
import requests
import json
import pandas as pd
from bs4 import BeautifulSoup
import os
from google import genai
from google.genai import types

# --- CONFIGURATIONS ---
st.set_page_config(page_title="Food Data Hunter (Diagnostic Ed.)", layout="wide")

# Try to get keys from environment, otherwise allow user to input them
SERPAPI_KEY_ENV = os.environ.get("SERPAPI_KEY", "")
GEMINI_API_KEY_ENV = os.environ.get("GEMINI_API_KEY", "")

# --- UTILITY: GOOGLE SEARCH (SERPAPI) ---
def google_search(query, gl="us", hl="en", search_type=None, num=3):
    """Executes a Google Search using SerpAPI."""
    if not st.session_state.serpapi_key: return {}
    
    params = {
        "q": query,
        "gl": gl,
        "hl": hl,
        "api_key": st.session_state.serpapi_key,
        "num": num
    }
    if search_type == "image":
        params["tbm"] = "isch"
        
    try:
        response = requests.get("https://serpapi.com/search", params=params, timeout=10)
        return response.json()
    except Exception as e:
        return {"error": str(e)}

# --- STEP 1: FIND IDENTITY & IMAGE ---
def find_identity_and_image(ean, market_code):
    """Finds the product name and a reference image."""
    result = {"name": None, "image_url": None, "identity_log": ""}
    
    # Search name
    search_res = google_search(f'"{ean}"', gl=market_code.lower(), num=2)
    organic = search_res.get("organic_results", [])
    
    if organic:
        # Take the title of the first result, clean it up
        raw_title = organic[0].get("title", "")
        result["name"] = raw_title.split("-")[0].split("|")[0].strip()
        result["identity_log"] = f"Name found via EAN search: {result['name']}"
    else:
        result["identity_log"] = "Name NOT found. SerpAPI returned no organic results for this EAN."
        return result

    # Search image (using the name we just found)
    img_res = google_search(result["name"], gl=market_code.lower(), search_type="image", num=3)
    images = img_res.get("images_results", [])
    for img in images:
        url = img.get("original", "")
        if "pinterest" not in url and "placeholder" not in url:
            result["image_url"] = url
            break
            
    return result

# --- STEP 2: WEB HARVESTER (THE DUMB SCRAPER) ---
def harvest_web_text(product_name, market_code):
    """Searches for ingredients/nutrition and scrapes the actual webpage text."""
    if not product_name: return {"text": "", "urls": [], "log": "No product name to search."}
    
    # Localized search terms
    terms = {
        "IT": "ingredienti valori nutrizionali",
        "DE": "zutaten nährwerte",
        "FR": "ingrédients valeurs nutritionnelles",
        "UK": "ingredients nutritional values",
        "ES": "ingredientes valores nutricionales"
    }
    search_term = terms.get(market_code, "ingredients nutrition")
    query = f'"{product_name}" {search_term} -site:openfoodfacts.org -site:pinterest.com'
    
    search_res = google_search(query, gl=market_code.lower(), num=4)
    organic = search_res.get("organic_results", [])
    
    urls_visited = []
    combined_text = ""
    
    headers = {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/120.0.0.0 Safari/537.36'
    }
    
    for result in organic:
        url = result.get("link")
        if not url or url.endswith('.pdf'): continue
        
        try:
            # Fetch the webpage
            page = requests.get(url, headers=headers, timeout=6)
            if page.status_code == 200:
                urls_visited.append(url)
                soup = BeautifulSoup(page.text, "html.parser")
                
                # Remove junk
                for junk in soup(["script", "style", "nav", "footer", "header", "noscript"]):
                    junk.decompose()
                
                # SPECIAL TRICK: Preserve table structures by replacing </td> with " | "
                for td in soup.find_all('td'):
                    td.append(" | ")
                for th in soup.find_all('th'):
                    th.append(" | ")
                    
                # Extract text
                text = soup.get_text(separator=' ', strip=True)
                # Keep only first 4000 chars per site to avoid overloading the AI
                combined_text += f"\n\n--- SOURCE: {url} ---\n{text[:4000]}\n"
        except Exception as e:
            pass # Skip if site blocks or times out
            
    log_msg = f"Visited {len(urls_visited)} URLs. Extracted {len(combined_text)} characters."
    return {"text": combined_text, "urls": urls_visited, "log": log_msg}

# --- STEP 3: AI EXTRACTOR (SMART PARSER - ZERO CONSTRAINTS) ---
def extract_data_with_ai(product_name, scraped_text, market_code):
    """Uses Gemini to read the scraped text and extract data without strict constraints."""
    if not scraped_text.strip():
        return {"error": "No text extracted from websites.", "diagnostic_log": "Scraper was blocked or found nothing."}
        
    prompt = f"""
    You are an expert Food Data Extractor.
    TARGET PRODUCT: {product_name}
    MARKET: {market_code}
    
    Below is RAW TEXT scraped from various websites. It is messy, and nutritional tables might be flattened into single lines.
    
    RAW TEXT:
    {scraped_text}
    
    YOUR MISSION:
    Read the text and extract the product information.
    
    RULES (ZERO CONSTRAINTS):
    1. MAXIMIZE COMPLETENESS. If you find any trace of nutritional values, extract them.
    2. Do NOT force values to be 100g. If the text says "per serving (25g) contains 50 kcal", write "50 kcal (per serving)".
    3. If the text is messy (e.g. "Fat Carbohydrates 10g 20g"), use your AI brain to deduce which number belongs to which nutrient based on standard nutritional profiles.
    4. Translate Ingredients and Allergens to the primary language of the {market_code} market.
    5. Only write "null" if there is absolutely ZERO mention of that data in the text.
    
    OUTPUT SCHEMA:
    Respond ONLY with a valid JSON using this exact structure:
    {{
        "diagnostic_log": "Write a short summary of WHAT you found in the text. If you found messy nutrition data and deduced it, explain how. If nutrition data is completely missing from the raw text, state clearly: 'Nutrition data missing from source text'.",
        "brand": "Brand Name",
        "product_name": "Full Name",
        "net_weight": "Weight/Volume",
        "ingredients": "Full ingredients list",
        "allergens": "List of allergens",
        "nutritional_context": "Are the values per 100g, per serving, or mixed?",
        "energy": "value",
        "fat": "value",
        "saturates": "value",
        "carbs": "value",
        "sugars": "value",
        "fiber": "value",
        "protein": "value",
        "salt": "value"
    }}
    """
    
    try:
        client = genai.Client(api_key=st.session_state.gemini_key)
        response = client.models.generate_content(
            model='gemini-2.5-flash',
            contents=prompt,
            config=types.GenerateContentConfig(
                response_mime_type="application/json",
                temperature=0.1
            )
        )
        
        raw_json = response.text.strip()
        # Clean markdown if present
        if raw_json.startswith("
