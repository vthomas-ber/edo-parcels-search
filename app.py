import streamlit as st
import requests
import json
import pandas as pd
from bs4 import BeautifulSoup
import os
from google import genai
from google.genai import types

# --- CONFIGURAZIONI ---
st.set_page_config(page_title="Food Data Hunter (Diagnostic Ed.)", layout="wide")

# --- UTILITY: GOOGLE SEARCH (SERPAPI) ---
def google_search(query, api_key, gl="us", hl="en", search_type=None, num=3):
    """Esegue una ricerca Google usando SerpAPI."""
    if not api_key: return {}
    
    params = {
        "q": query,
        "gl": gl,
        "hl": hl,
        "api_key": api_key,
        "num": num
    }
    if search_type == "image":
        params["tbm"] = "isch"
        
    try:
        response = requests.get("https://serpapi.com/search", params=params, timeout=10)
        return response.json()
    except Exception as e:
        return {"error": str(e)}

# --- STEP 1: TROVA IDENTITÀ E IMMAGINE ---
def find_identity_and_image(ean, market_code, serp_key):
    """Trova il nome del prodotto e un'immagine di riferimento."""
    result = {"name": None, "image_url": None, "identity_log": ""}
    
    # Cerca il nome
    search_res = google_search(f'"{ean}"', api_key=serp_key, gl=market_code.lower(), num=2)
    organic = search_res.get("organic_results", [])
    
    if organic:
        # Prende il titolo del primo risultato
        raw_title = organic[0].get("title", "")
        result["name"] = raw_title.split("-")[0].split("|")[0].strip()
        result["identity_log"] = f"Nome trovato via EAN: {result['name']}"
    else:
        result["identity_log"] = "Nome NON trovato. SerpAPI non ha restituito risultati organici per questo EAN."
        return result

    # Cerca l'immagine (usando il nome appena trovato)
    img_res = google_search(result["name"], api_key=serp_key, gl=market_code.lower(), search_type="image", num=3)
    images = img_res.get("images_results", [])
    for img in images:
        url = img.get("original", "")
        if "pinterest" not in url and "placeholder" not in url:
            result["image_url"] = url
            break
            
    return result

# --- STEP 2: WEB HARVESTER (LO SCRAPER) ---
def harvest_web_text(product_name, market_code, serp_key):
    """Cerca gli ingredienti/valori e scarica il testo dalle pagine web."""
    if not product_name: return {"text": "", "urls": [], "log": "Nessun nome prodotto da cercare."}
    
    # Termini di ricerca localizzati
    terms = {
        "IT": "ingredienti valori nutrizionali",
        "DE": "zutaten nährwerte",
        "FR": "ingrédients valeurs nutritionnelles",
        "UK": "ingredients nutritional values",
        "ES": "ingredientes valores nutricionales"
    }
    search_term = terms.get(market_code, "ingredients nutrition")
    query = f'"{product_name}" {search_term} -site:openfoodfacts.org -site:pinterest.com'
    
    search_res = google_search(query, api_key=serp_key, gl=market_code.lower(), num=4)
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
            # Scarica la pagina web
            page = requests.get(url, headers=headers, timeout=6)
            if page.status_code == 200:
                urls_visited.append(url)
                soup = BeautifulSoup(page.text, "html.parser")
                
                # Rimuove spazzatura (menu, script, footer)
                for junk in soup(["script", "style", "nav", "footer", "header", "noscript"]):
                    junk.decompose()
                
                # TRUCCO SPECIALE: Preserva la struttura delle tabelle sostituendo i tag di chiusura colonna con " | "
                for td in soup.find_all('td'):
                    td.append(" | ")
                for th in soup.find_all('th'):
                    th.append(" | ")
                    
                # Estrae il testo pulito
                text = soup.get_text(separator=' ', strip=True)
                
                # Tiene solo i primi 4000 caratteri per sito per non ingolfare l'AI
                combined_text += f"\n\n--- FONTE: {url} ---\n{text[:4000]}\n"
        except Exception as e:
            pass # Salta al prossimo URL se il sito blocca la richiesta
            
    log_msg = f"Visitati {len(urls_visited)} URL. Estratti {len(combined_text)} caratteri."
    return {"text": combined_text, "urls": urls_visited, "log": log_msg}

# --- STEP 3: AI EXTRACTOR (ZERO CONSTRAINTS) ---
def extract_data_with_ai(product_name, scraped_text, market_code, gemini_key):
    """Usa Gemini per leggere il testo estratto e compilare i dati (Senza vincoli)."""
    if not scraped_text.strip():
        return {"error": "Nessun testo estratto dai siti.", "diagnostic_log": "Lo scraper è stato bloccato o non ha trovato nulla."}
        
    prompt = f"""
    Sei un esperto Estrattore di Dati Alimentari.
    PRODOTTO TARGET: {product_name}
    MERCATO: {market_code}
    
    Di seguito c'è del TESTO GREZZO estratto da vari siti web. È disordinato e le tabelle nutrizionali potrebbero essere state appiattite in singole righe.
    
    TESTO GREZZO:
    {scraped_text}
    
    LA TUA MISSIONE:
    Leggi il testo ed estrai le informazioni del prodotto.
    
    REGOLE (ZERO VINCOLI):
    1. MASSIMIZZA LA COMPLETEZZA. Se trovi qualsiasi traccia di valori nutrizionali, estraili.
    2. NON forzare i valori a 100g. Se il testo dice "per porzione (25g) contiene 50 kcal", scrivi "50 kcal (per porzione)".
    3. Se il testo è confuso (es. "Grassi Carboidrati 10g 20g"), usa il tuo cervello AI per dedurre quale numero appartiene a quale nutriente in base ai profili nutrizionali standard.
    4. Traduci Ingredienti e Allergeni nella lingua principale del mercato {market_code}.
    5. Scrivi "null" SOLO se non c'è assolutamente NESSUNA menzione di quel dato nel testo.
    
    SCHEMA DI OUTPUT:
    Rispondi SOLO con un JSON valido usando questa identica struttura:
    {{
        "diagnostic_log": "Scrivi un breve riassunto di COSA hai trovato nel testo. Se hai trovato dati confusi e li hai dedotti, spiega come. Se i dati nutrizionali mancano, scrivi chiaramente 'Dati nutrizionali mancanti nel testo sorgente'.",
        "brand": "Nome Brand",
        "product_name": "Nome Completo",
        "net_weight": "Peso/Volume",
        "ingredients": "Lista completa ingredienti",
        "allergens": "Lista allergeni",
        "nutritional_context": "I valori sono per 100g, per porzione, o misti?",
        "energy": "valore",
        "fat": "valore",
        "saturates": "valore",
        "carbs": "valore",
        "sugars": "valore",
        "fiber": "valore",
        "protein": "valore",
        "salt": "valore"
    }}
    """
    
    try:
        client = genai.Client(api_key=gemini_key)
        response = client.models.generate_content(
            model='gemini-2.5-flash',
            contents=prompt,
            config=types.GenerateContentConfig(
                response_mime_type="application/json",
                temperature=0.1 # Temperatura bassa per estrazione fattuale
            )
        )
        
        raw_json = response.text.strip()
        # Pulisce i blocchi markdown se generati da Gemini in modo sicuro
        if raw_json.startswith("```json"): 
            raw_json = raw_json[7:]
        elif raw_json.startswith("```"): 
            raw_json = raw_json[3:]
            
        if raw_json.endswith("```"): 
            raw_json = raw_json[:-3]
        
        data = json.loads(raw_json.strip())
        return data
        
    except Exception as e:
        return {"error": "Elaborazione AI Fallita o JSON non valido", "diagnostic_log": str(e)}

# --- UI APP (STREAMLIT) ---
st.title("🍔 Food Data Hunter (Diagnostic Edition)")
st.markdown("Questo strumento cerca sul web, scarica il testo delle pagine e usa l'AI per leggerlo. **Non usa l'elaborazione delle immagini per estrarre i dati.**")

# Sidebar per le impostazioni
with st.sidebar:
    st.header("🔑 Configurazione API")
    SERP_KEY = st.text_input("SerpAPI Key", value=os.environ.get("SERPAPI_KEY", ""), type="password")
    GEMINI_KEY = st.text_input("Gemini API Key", value=os.environ.get("GEMINI_API_KEY", ""), type="password")
    
    st.header("🌍 Mercato")
    market = st.selectbox("Mercato Target", ["IT", "DE", "UK", "FR", "ES"])

# Area Principale
ean_input = st.text_area("Incolla gli EAN (uno per riga):", "4018077669132\n4260725010074")

if st.button("🚀 Avvia Ricerca Profonda", type="primary"):
    if not SERP_KEY or not GEMINI_KEY:
        st.error("Per favore, inserisci le API Key nella barra laterale.")
        st.stop()
        
    eans = [e.strip() for e in ean_input.split("\n") if e.strip()]
    if not eans:
        st.warning("Inserisci almeno un EAN.")
        st.stop()
        
    # Prepara indicatori UI
    progress_bar = st.progress(0.0)
    status_text = st.empty()
    
    # Liste per salvare i risultati
    results = []
    diagnostics = {}
    
    for i, ean in enumerate(eans):
        status_text.text(f"Elaborazione EAN {ean} ({i+1}/{len(eans)})...")
        
        # 1. Identità e Immagine
        identity = find_identity_and_image(ean, market, SERP_KEY)
        product_name = identity.get("name")
        
        if not product_name:
            results.append({"EAN": ean, "Status": "Non Trovato", "Name": "Sconosciuto"})
            diagnostics[ean] = {"Log": identity.get("identity_log")}
            progress_bar.progress(min((i + 1) / len(eans), 1.0))
            continue
            
        # 2. Scraping Web
        web_data = harvest_web_text(product_name, market, SERP_KEY)
        
        # 3. Estrazione dati con AI
        ai_data = extract_data_with_ai(product_name, web_data["text"], market, GEMINI_KEY)
        
        # Combina i risultati per la tabella
        row = {
            "EAN": ean,
            "Status": "Errore" if "error" in ai_data else "Successo",
            "Immagine": identity.get("image_url") or "",
            "Brand": ai_data.get("brand", ""),
            "Nome": ai_data.get("product_name", product_name),
            "Peso": ai_data.get("net_weight", ""),
            "Contesto Dati": ai_data.get("nutritional_context", ""),
            "Energia": ai_data.get("energy", ""),
            "Grassi": ai_data.get("fat", ""),
            "Carbo": ai_data.get("carbs", ""),
            "Zuccheri": ai_data.get("sugars", ""),
            "Proteine": ai_data.get("protein", ""),
            "Sale": ai_data.get("salt", "")
        }
        results.append(row)
        
        # Salva la diagnostica completa in background
        diagnostics[ean] = {
            "Nome Prodotto Trovato": product_name,
            "URL Visitati": web_data["urls"],
            "Log Scraping": web_data["log"],
            "Lunghezza Testo": len(web_data["text"]),
            "Testo Grezzo (Snippet)": web_data["text"][:1500] + "...\n[TRONCATO]",
            "Pensiero di Gemini": ai_data.get("diagnostic_log", ai_data.get("error", "Nessun log disponibile."))
        }
        
        progress_bar.progress(min((i + 1) / len(eans), 1.0))
        
    status_text.text("✅ Elaborazione Completata!")
    
    # Mostra Tabella Risultati
    st.subheader("📊 Risultati Estrazione")
    df = pd.DataFrame(results)
    
    # Mostra immagini HTML nel dataframe nativo di Streamlit
    st.data_editor(
        df,
        column_config={
            "Immagine": st.column_config.ImageColumn("Immagine", help="Foto Prodotto")
        },
        use_container_width=True,
        hide_index=True
    )
    
    # Mostra Centro Diagnostico
    st.divider()
    st.subheader("🔬 Centro Diagnostico")
    st.markdown("Controlla qui per vedere **esattamente** cosa vede lo scraper e cosa pensa l'AI. Usa questo strumento per capire se i siti bloccano il bot o se l'AI si confonde.")
    
    selected_ean_diag = st.selectbox("Seleziona l'EAN da ispezionare:", list(diagnostics.keys()))
    
    if selected_ean_diag:
        diag = diagnostics.get(selected_ean_diag, {})
        
        col1, col2 = st.columns(2)
        with col1:
            st.info(f"**Stato Web Harvester**\n\n{diag.get('Log Scraping', 'N/A')}")
            st.write("**URL Analizzati con successo:**")
            for u in diag.get("URL Visitati", []):
                st.write(f"- {u}")
                
        with col2:
            st.warning("**Processo di Pensiero AI (Gemini)**")
            st.write(diag.get("Pensiero di Gemini", "N/A"))
            
        with st.expander("👀 Visualizza il Testo Grezzo inviato all'AI (Primi 1500 caratteri)"):
            st.text(diag.get("Testo Grezzo (Snippet)", "Nessun testo disponibile."))
