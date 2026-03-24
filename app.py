import streamlit as st
import requests
import json
import pandas as pd
import os
from google import genai
from google.genai import types

st.set_page_config(page_title="Food Data AI Search", layout="wide")

# --- 1. TROVA IDENTITÀ E IMMAGINE (Via SerpAPI) ---
def get_basic_info(ean, serp_key, market_code):
    if not serp_key: return None, None
    gl = market_code.lower()
    
    try:
        # Ricerca senza virgolette strette per massimizzare i risultati
        params = {"q": str(ean), "gl": gl, "api_key": serp_key}
        res_name = requests.get("https://serpapi.com/search", params=params, timeout=20).json()
        
        # CONTROLLO ERRORI SERPAPI (Es. Crediti Finiti)
        if "error" in res_name:
            return f"Errore API: {res_name['error']}", None
            
        organic = res_name.get("organic_results", [])
        
        # FALLBACK: Se non trova niente in quel mercato, cerca a livello globale
        if not organic:
            res_name = requests.get("https://serpapi.com/search", params={"q": str(ean), "api_key": serp_key}, timeout=20).json()
            organic = res_name.get("organic_results", [])
            
        if not organic: return None, None
        
        # Prendi il titolo e puliscilo
        product_name = organic[0].get("title", "").split("-")[0].split("|")[0].strip()
        
        # Trova la foto (aggiunto controllo errori anche qui)
        res_img = requests.get("https://serpapi.com/search", params={"q": product_name, "tbm": "isch", "gl": gl, "api_key": serp_key}, timeout=10).json()
        img_url = None
        for img in res_img.get("images_results", []):
            if "pinterest" not in img.get("original", ""):
                img_url = img.get("original")
                break
                
        return product_name, img_url
        
    except Exception as e:
        return f"Errore API: Connessione fallita ({str(e)})", None

# --- 2. IL TUO PROMPT PER GEMINI (Con Google Search Abilitato) ---
def get_nutrition_with_gemini_search(ean, product_name, market_code, gemini_key):
    # Questo è il TUO prompt, riadattato per restituire un JSON pulito per la nostra tabella
    prompt = f"""
    You are the Lead Food Product Researcher.
    TARGET PRODUCT: {product_name} (EAN: {ean})
    MARKET: {market_code}
    
    CORE DIRECTIVE: Accuracy is your absolute priority. You have access to Google Search. USE IT to search the internet for this specific product to find its exact nutritional values and ingredients. Check major online grocery retailers and official brand websites.
    
    TASK:
    1. Search the web for "{product_name} ingredients nutrition facts".
    2. Extract the data. All text MUST be translated to the native language of {market_code}.
    3. Ensure 'Ingredients' and 'Allergens' are single continuous text strings.
    4. Format the output STRICTLY as a valid JSON object. DO NOT wrap the output in markdown code blocks like ```json.
    
    OUTPUT SCHEMA:
    {{
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
        "sources": "URL 1, URL 2"
    }}
    """
    
    client = genai.Client(api_key=gemini_key)
    try:
        # La magia è qui: abilitiamo il tool "google_search" per permettere all'API di navigare
        response = client.models.generate_content(
            model='gemini-2.5-flash',
            contents=prompt,
            config=types.GenerateContentConfig(
                temperature=0.2,
                tools=[{"google_search": {}}] # <--- ABILITA LA RICERCA INTERNET NATIVA
            )
        )
        
        raw_json = response.text.strip()
        
        # Pulizia sicura dei tag markdown generati da Gemini nel caso non segua le istruzioni
        if raw_json.startswith("```json"): 
            raw_json = raw_json[7:]
        elif raw_json.startswith("```"): 
            raw_json = raw_json[3:]
            
        if raw_json.endswith("```"): 
            raw_json = raw_json[:-3]
            
        return json.loads(raw_json.strip())
        
    except Exception as e:
        return {"error": str(e)}

# --- UI APP ---
st.title("🍏 Food Data Simple (Gemini Web Search)")
st.markdown("Questa versione delega a Gemini l'intera navigazione web tramite il suo tool nativo **Google Search**.")

with st.sidebar:
    st.header("🔑 Configurazione API")
    SERP_KEY = st.text_input("SerpAPI Key", value=os.environ.get("SERPAPI_KEY", ""), type="password")
    GEMINI_KEY = st.text_input("Gemini API Key", value=os.environ.get("GEMINI_API_KEY", ""), type="password")
    market = st.selectbox("Mercato Target", ["IT", "DE", "UK", "FR", "ES"])

ean_input = st.text_area("Incolla gli EAN (uno per riga):", "4260725010067")

if st.button("🚀 Avvia Ricerca", type="primary"):
    if not SERP_KEY or not GEMINI_KEY:
        st.error("Inserisci le API Key nella barra laterale.")
        st.stop()
        
    eans = [e.strip() for e in ean_input.split("\n") if e.strip()]
    if not eans:
        st.warning("Inserisci almeno un EAN.")
        st.stop()
        
    results = []
    
    with st.spinner("Ricerca in corso (Gemini sta navigando su Google per te)..."):
        for ean in eans:
            # 1. Trova nome e foto
            name, img = get_basic_info(ean, SERP_KEY, market)
            
            # Controllo se SerpAPI ha restituito un errore esplicito
            if name and str(name).startswith("Errore API"):
                results.append({"EAN": ean, "Status": name, "Image": ""})
                st.error(f"Attenzione su EAN {ean}: {name}")
                continue
            
            # Controllo se non ha trovato nulla
            if not name:
                results.append({"EAN": ean, "Status": "Nome non trovato", "Image": ""})
                continue
                
            # 2. Lascia fare a Gemini con Google Search
            data = get_nutrition_with_gemini_search(ean, name, market, GEMINI_KEY)
            
            # Combina i dati
            row = {
                "EAN": ean,
                "Image": img or "",
                "Status": "Errore JSON" if "error" in data else "Successo"
            }
            # Aggiunge i dati estratti (se presenti)
            row.update(data)
            results.append(row)
            
    st.success("✅ Ricerca Completata!")
    
    # Mostra i risultati
    st.subheader("📊 Risultati")
    df = pd.DataFrame(results)
    
    st.data_editor(
        df, 
        column_config={"Image": st.column_config.ImageColumn("Immagine")}, 
        use_container_width=True, 
        hide_index=True
    )
