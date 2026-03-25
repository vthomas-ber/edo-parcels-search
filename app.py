import streamlit as st
import pandas as pd
import os
import json
import asyncio
import aiohttp
from google import genai
from google.genai import types

st.set_page_config(page_title="Food Data Researcher PRO", layout="wide")

# --- 1. RICERCA NOME E FOTO (Qualità Massima via SerpAPI) ---
async def fetch_basic_info(session, ean, serp_key, market_code):
    """Cerca il nome e la foto migliore possibile via SerpAPI."""
    gl = market_code.lower()
    diagnostic_log = []
    
    if not serp_key:
        return None, None, "Errore: Manca SerpAPI Key"
        
    serp_url = "https://serpapi.com/search"
    diagnostic_log.append(f"🔍 Ricerca EAN {ean} su Google ({market_code})...")
    
    try:
        # Step 1: Trova il nome del prodotto
        async with session.get(serp_url, params={"q": str(ean), "gl": gl, "api_key": serp_key}, timeout=20) as resp:
            data = await resp.json()
            organic = data.get("organic_results", [])
            if not organic:
                return None, None, "❌ Prodotto non trovato su Google."
            
            product_name = organic[0].get("title", "").split("-")[0].split("|")[0].strip()
            diagnostic_log.append(f"✅ Nome trovato: {product_name}")

        # Step 2: Ricerca Immagine Dedicata (Qualità Max)
        diagnostic_log.append(f"🖼️ Ricerca immagine alta qualità per: {product_name}...")
        img_params = {"q": product_name, "tbm": "isch", "gl": gl, "api_key": serp_key}
        async with session.get(serp_url, params=img_params, timeout=20) as img_resp:
            img_data = await img_resp.json()
            img_url = None
            for image_res in img_data.get("images_results", []):
                url = image_res.get("original", "")
                # Escludiamo siti spazzatura per le foto
                if all(x not in url.lower() for x in ["pinterest", "placeholder", "logo"]):
                    img_url = url
                    break
            
            diagnostic_log.append("✅ Immagine trovata." if img_url else "⚠️ Immagine non trovata.")
            return product_name, img_url, "\n".join(diagnostic_log)
            
    except Exception as e:
        return None, None, f"❌ Errore connessione SerpAPI: {str(e)}"

# --- 2. GEMINI CON CROSS-VERIFICA E METADATI ---
def run_gemini_sync(ean, product_name, market_code, gemini_key):
    """Chiama Gemini con l'ordine di incrociare le fonti e restituire i link reali."""
    prompt = f"""
    You are the Lead Food Product Researcher.
    TARGET PRODUCT: {product_name} (EAN: {ean})
    MARKET: {market_code}
    
    CORE DIRECTIVE: Accuracy and completeness are your absolute priorities. 
    You have access to Google Search. USE IT to search multiple sources (prioritize large retailers).
    
    RESEARCH RULES:
    1. CROSS-VERIFICATION: Do not rely on a single source. Verify nutritional values across at least two independent websites if possible.
    2. LANGUAGE: All output text (Ingredients, Allergens, Name) MUST be in the native language of {market_code}.
    3. FORMATTING: Ingredients and Allergens must be single continuous strings.
    
    OUTPUT: Respond ONLY with a valid JSON.
    SCHEMA:
    {{
        "brand": "Brand Name",
        "product_name": "Full Name",
        "net_weight": "Weight/Volume",
        "ingredients": "Full list",
        "allergens": "List",
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
        "sources": "This field will be populated with all URLs found"
    }}
    """
    
    client = genai.Client(api_key=gemini_key)
    try:
        response = client.models.generate_content(
            model='gemini-2.0-flash',
            contents=prompt,
            config=types.GenerateContentConfig(
                temperature=0.0, # Zero per massima precisione
                tools=[{"google_search": {}}]
            )
        )
        
        # Estrazione URL reali dai metadati di Grounding
        real_urls = []
        try:
            if response.candidates and response.candidates[0].grounding_metadata:
                metadata = response.candidates[0].grounding_metadata
                if metadata.grounding_chunks:
                    for chunk in metadata.grounding_chunks:
                        if chunk.web and chunk.web.uri:
                            real_urls.append(chunk.web.uri)
        except: pass

        # Pulizia JSON
        raw_text = response.text.strip().replace("```json", "").replace("```", "").strip()
        data = json.loads(raw_text)
        
        # Inseriamo i link reali trovati da Google Search
        if real_urls:
            data["sources"] = ", ".join(list(set(real_urls)))
        else:
            data["sources"] = "Nessuna fonte verificata trovata."
            
        return data
    except Exception as e:
        return {"error": str(e)}

async def process_ean(sem, session, ean, serp_key, gemini_key, market):
    """Processa un singolo EAN."""
    async with sem:
        name, img, diag_info = await fetch_basic_info(session, ean, serp_key, market)
        if not name:
            return {"row": {"EAN": ean, "Status": "Non trovato"}, "diag": diag_info}
        
        # Gemini in un thread separato per non bloccare l'async
        data = await asyncio.to_thread(run_gemini_sync, ean, name, market, gemini_key)
        
        row = {"EAN": ean, "Immagine": img or "", "Status": "Successo" if "error" not in data else "Errore AI"}
        row.update(data)
        return {"row": row, "diag": diag_info}

async def run_main(eans, serp_key, gemini_key, market):
    sem = asyncio.Semaphore(3) # Max 3 contemporaneamente per stabilità
    async with aiohttp.ClientSession() as session:
        tasks = [process_ean(sem, session, ean, serp_key, gemini_key, market) for ean in eans]
        results = await asyncio.gather(*tasks)
        return results

# --- INTERFACCIA ---
st.title("🔬 Food Data Researcher PRO")
st.markdown("Questa versione massimizza l'accuratezza incrociando più fonti web e recuperando i link originali.")

with st.sidebar:
    st.header("API Setup")
    serp_key = st.text_input("SerpAPI Key", type="password")
    gemini_key = st.text_input("Gemini API Key", type="password")
    market = st.selectbox("Mercato", ["IT", "DE", "UK", "FR", "ES"])

ean_input = st.text_area("Inserisci EAN (uno per riga):")

if st.button("🚀 Avvia Ricerca Alta Qualità", type="primary"):
    if not serp_key or not gemini_key:
        st.error("Inserisci le chiavi API.")
    else:
        eans = [e.strip() for e in ean_input.split("\n") if e.strip()]
        with st.spinner(f"Analisi di {len(eans)} prodotti in corso..."):
            all_data = asyncio.run(run_main(eans, serp_key, gemini_key, market))
            
            df_rows = [r["row"] for r in all_data]
            st.subheader("Risultati")
            st.data_editor(
                pd.DataFrame(df_rows),
                column_config={"Immagine": st.column_config.ImageColumn()},
                use_container_width=True
            )
