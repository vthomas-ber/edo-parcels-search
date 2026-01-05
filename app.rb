require 'sinatra'
require 'google_search_results'
require 'down'
require 'fastimage'
require 'json'
require 'net/http'
require 'uri'
require 'nokogiri'

# --- API KEYS ---
SERPAPI_KEY = ENV['SERPAPI_KEY'] 
EAN_SEARCH_TOKEN = ENV['EAN_SEARCH_TOKEN']

# --- THE LOGIC CLASS ---
class ImageHunter
  def initialize
    @country_names = {
      "DE" => "Deutschland Germany", "AT" => "Österreich Austria", "CH" => "Schweiz Switzerland",
      "UK" => "UK United Kingdom",   "GB" => "UK United Kingdom", "FR" => "France",
      "IT" => "Italia Italy", "ES" => "España Spain", "PL" => "Polska Poland",
      "DK" => "Danmark Denmark", "NL" => "Nederland Netherlands", "BE" => "Belgique België Belgium",
      "SE" => "Sverige Sweden", "NO" => "Norge Norway", "PT" => "Portugal"
    }
    @country_langs = {
      "DE" => "de", "AT" => "de", "CH" => "de", "UK" => "en", "GB" => "en",
      "FR" => "fr", "BE" => "fr", "IT" => "it", "ES" => "es", "PL" => "pl",
      "DK" => "da", "NL" => "nl", "SE" => "sv", "NO" => "no", "PT" => "pt"
    }
  end

  def find_image(gtin, market)
    return { found: false } if gtin.nil? || gtin.strip.empty?
    market = market.upcase
    country_name = @country_names[market] || ""
    lang_code = @country_langs[market] || "en"
    
    # 1. VISUAL HUNT
    image_result = hunt_visuals(gtin, market, country_name, lang_code)
    
    # 2. DATA HUNT (Deep Extract)
    data_result = hunt_data(gtin, market, lang_code, image_result[:source])

    # 3. MERGE
    final_result = image_result.merge(data_result)
    return final_result
  end

  # --- PART 1: VISUAL HUNTER ---
  def hunt_visuals(gtin, market, country_name, lang_code)
    # A. Check EAN-Search API
    if EAN_SEARCH_TOKEN
      api_data = check_ean_api(gtin) 
      if api_data && is_good?(api_data[:image])
        return { 
          found: true, 
          url: api_data[:image], 
          source: "https://www.ean-search.org/?q=#{gtin}",
          product_name: api_data[:name] 
        }
      end
    end

    # B. Check Google Images (Targeted)
    site_res = search_google_images("site:barcodelookup.com \"#{gtin}\"", market, lang_code)
    return site_res if site_res

    # C. Check Google Images (Strict)
    strict_res = search_google_images("\"#{gtin}\" #{country_name}", market, lang_code)
    return strict_res if strict_res

    # D. Check Google Images (Broad)
    broad_res = search_google_images("\"#{gtin}\"", market, lang_code)
    return broad_res if broad_res

    return { found: false, url: "", source: "" }
  end

  # --- PART 2: DATA HUNTER (Master Data Extraction) ---
  def hunt_data(gtin, market, lang_code, source_url)
    return empty_data_set unless SERPAPI_KEY

    # Strategy 1: Read the Source Page from the Image Hunt
    if source_url && source_url.start_with?("http")
      puts "   👉 Reading Source Page: #{source_url}..."
      page_data = scrape_page(source_url)
      return page_data unless page_data[:ingredients] == "-"
    end

    # Strategy 2: Search specifically for Data
    puts "   👉 Searching for Data Source..."
    query = "site:barcodelookup.com #{gtin}"
    search = GoogleSearch.new(q: query, gl: "us", hl: "en", api_key: SERPAPI_KEY)
    res = search.get_hash
    
    first_result = (res[:organic_results] || []).first
    if first_result
       data_link = first_result[:link]
       puts "   👉 Reading Backup Data Page: #{data_link}..."
       return scrape_page(data_link)
    end

    return empty_data_set
  end

  def scrape_page(url)
    begin
      html = Down.download(url, user_agent: "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/90.0.4430.212 Safari/537.36").read
    rescue
      return empty_data_set
    end

    doc = Nokogiri::HTML(html)
    # Get all text, clean up newlines/tabs
    text_blob = doc.text.gsub(/\s+/, " ")

    # Regex patterns for multiple languages
    stop_words = "(nutrition|voedingswaarden|nährwerte|energy|energie|fat|fett|vet|$)"
    
    data = {
      weight: extract_text(text_blob, /(weight|gewicht|inhoud|netto|poids)[:\s]+(\d+\s?(g|kg|ml|l|oz|cl))\b/i),
      ingredients: extract_text(text_blob, /(ingredients|zutaten|ingrédients|ingrediënten|samenstelling)\s*[:\.]\s*(.*?)(?=#{stop_words})/i).gsub("\n", " "),
      allergens: extract_text(text_blob, /(allergens|allergene|allergie|bevat|contains)\s*[:\.]\s*(.*?)(?=(\.|may contain|kann spuren|kan sporen|$))/i),
      may_contain: extract_text(text_blob, /(may contain|kann spuren|kan sporen)\s*[:\.]\s*(.*?)(?=(\.|nutrition|voedings|$))/i),
      nutrition_header: extract_text(text_blob, /(per 100\s?g|per 100\s?ml|per serving|pro 100\s?g|per portion|pour 100\s?g)/i),
      
      energy: extract_text(text_blob, /(energy|energie).*?(\d+\s?(kj|kcal).*?)(?=(fat|fett|vet|matières|$))/i),
      fat: extract_text(text_blob, /(fat|fett|vet|matières grasses)\s*(\d+[,\.]?\d*\s?g?)(?=(of which|saturates|davon|waarvan|$))/i),
      saturates: extract_text(text_blob, /(saturates|saturated|gesättigte|verzadigde|saturés).*?(\d+[,\.]?\d*\s?g?)/i),
      carbs: extract_text(text_blob, /(carbohydrate|kohlenhydrate|koolhydraten|glucides)\s*(\d+[,\.]?\d*\s?g?)(?=(of which|sugars|davon|waarvan|$))/i),
      sugars: extract_text(text_blob, /(sugars|zucker|suikers|sucres)\s*(\d+[,\.]?\d*\s?g?)/i),
      protein: extract_text(text_blob, /(protein|eiweiß|eiwit|protéines)\s*(\d+[,\.]?\d*\s?g?)/i),
      fiber: extract_text(text_blob, /(fiber|ballaststoffe|vezels|fibres)\s*(\d+[,\.]?\d*\s?g?)/i),
      salt: extract_text(text_blob, /(salt|salz|zout|sel)\s*(\d+[,\.]?\d*\s?g?)/i),
      organic_cert: extract_text(text_blob, /([A-Z]{2}-(BIO|ÖKO|ORG)-\d+)/i)
    }
    
    # Fallback: If weight isn't found in text, try looking in the title (often used in barcodes sites)
    if data[:weight] == "-"
      title_match = doc.title.match(/(\d+\s?(g|kg|ml|l|cl))/i)
      data[:weight] = title_match[1] if title_match
    end

    return data
  end

  def extract_text(text, regex)
    match = text.match(regex)
    return "-" unless match
    # Group 2 usually holds the value, but sometimes Group 1 if the regex is simple
    value = match[2] || match[1]
    return "-" if value.nil? || value.strip.empty?
    return value[0..400].strip # Safety limit
  end

  def empty_data_set
    { 
      weight: "-", ingredients: "-", allergens: "-", may_contain: "-", nutrition_header: "-",
      energy: "-", fat: "-", saturates: "-", carbs: "-", sugars: "-", protein: "-", fiber: "-", salt: "-", organic_cert: "-"
    }
  end

  # --- HELPER FUNCTIONS ---
  def check_ean_api(gtin)
    url = URI("https://api.ean-search.org/api?token=#{EAN_SEARCH_TOKEN}&op=barcode-lookup&ean=#{gtin}&format=json")
    response = Net::HTTP.get(url)
    data = JSON.parse(response) rescue []
    product = data.first
    return nil unless product
    { image: product["image"], name: product["name"] }
  rescue
    nil
  end

  def search_google_images(query, gl, hl)
    return nil unless SERPAPI_KEY
    res = GoogleSearch.new(q: query, tbm: "isch", gl: gl.downcase, hl: hl, api_key: SERPAPI_KEY).get_hash
    (res[:images_results] || []).first(10).each do |img|
      url = img[:original]
      source = img[:link]
      next if url.include?("pinterest") || url.include?("ebay") || url.include?("openfoodfacts")
      if is_good?(url)
        return { found: true, url: url, source: source, product_name: img[:title] }
      end
    end
    nil
  rescue
    nil
  end

  def is_good?(url)
    return false if url.nil? || url.empty?
    options = { timeout: 4, http_header: { 'User-Agent' => 'Chrome/90.0' } }
    size = FastImage.size(url, options)
    return false unless size
    w, h = size
    return w > 300 && (w.to_f / h.to_f).between?(0.3, 2.5)
  rescue
    false
  end
end

# --- ROUTES ---

get '/' do
  erb :index
end

get '/api/search' do
  content_type :json
  hunter = ImageHunter.new
  result = hunter.find_image(params[:gtin], params[:market])
  result.to_json
end

__END__

@@ index
<!DOCTYPE html>
<html>
<head>
  <title>TGTG Master Data Hunter</title>
  <style>
    body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif; background: #f0f2f5; padding: 20px; color: #333; }
    .container { max-width: 1400px; margin: 0 auto; background: white; padding: 30px; border-radius: 12px; box-shadow: 0 4px 20px rgba(0,0,0,0.08); overflow-x: auto; }
    h1 { color: #00816A; margin-top: 0; }
    .controls { display: flex; gap: 10px; margin-bottom: 20px; align-items: center; background: #eefcf9; padding: 15px; border-radius: 8px; }
    textarea { width: 100%; height: 100px; padding: 10px; border: 1px solid #ccc; border-radius: 8px; font-family: monospace; }
    button { background: #00816A; color: white; border: none; padding: 12px 24px; border-radius: 6px; font-weight: bold; cursor: pointer; }
    button:disabled { background: #ccc; }
    table { width: 100%; border-collapse: collapse; margin-top: 20px; font-size: 13px; }
    th { text-align: left; background: #00816A; color: white; padding: 10px; white-space: nowrap; }
    td { padding: 10px; border-bottom: 1px solid #eee; vertical-align: top; }
    tr:nth-child(even) { background: #f9f9f9; }
    .status-found { color: #28a745; font-weight: bold; }
    .status-missing { color: #dc3545; font-weight: bold; }
    .img-preview { max-height: 60px; max-width: 60px; object-fit: contain; }
    .source-link { color: #00816A; text-decoration: none; border: 1px solid #00816A; padding: 2px 6px; border-radius: 4px; font-size: 11px; }
    .data-cell { font-family: monospace; color: #555; max-width: 250px; white-space: pre-wrap; word-wrap: break-word; }
  </style>
</head>
<body>

<div class="container">
  <h1>🍏 TGTG Master Data Hunter</h1>
  <div class="controls">
    <label><strong>Market:</strong></label>
    <select id="marketSelect">
      <option value="DE">Germany (DE)</option>
      <option value="UK">United Kingdom (UK)</option>
      <option value="FR">France (FR)</option>
      <option value="NL">Netherlands (NL)</option>
      <option value="BE">Belgium (BE)</option>
      <option value="IT">Italy (IT)</option>
      <option value="ES">Spain (ES)</option>
      <option value="DK">Denmark (DK)</option>
      <option value="SE">Sweden (SE)</option>
      <option value="PL">Poland (PL)</option>
      <option value="AT">Austria (AT)</option>
    </select>
  </div>

  <textarea id="inputList" placeholder="Paste GTINs here..."></textarea>
  <br><br>
  <button id="startBtn" onclick="startBatch()">🚀 Start Data Hunt</button>
  <button id="downloadBtn" onclick="downloadCSV()" style="background: #333; display: none;">⬇️ Download CSV</button>
  
  <p id="statusText">Ready.</p>

  <table id="resultsTable">
    <thead>
      <tr>
        <th>GTIN</th>
        <th>Status</th>
        <th>Image</th>
        <th>Weight</th>
        <th>Ingredients</th>
        <th>Allergens</th>
        <th>Energy</th>
        <th>Sugars</th>
        <th>Source</th>
      </tr>
    </thead>
    <tbody></tbody>
  </table>
</div>

<script>
  let resultsData = [];

  async function startBatch() {
    const text = document.getElementById('inputList').value;
    const market = document.getElementById('marketSelect').value;
    const lines = text.split('\n').map(l => l.trim()).filter(l => l.length > 0);
    
    if (lines.