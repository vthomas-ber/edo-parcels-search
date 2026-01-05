require 'sinatra'
require 'google_search_results'
require 'down'
require 'fastimage'
require 'json'
require 'net/http'
require 'uri'

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
    
    # 1. VISUAL HUNT (Images)
    image_result = hunt_visuals(gtin, market, country_name, lang_code)
    
    # 2. DATA HUNT (Text/Ingredients)
    # We look for text specifically on barcodelookup or via Google Shopping
    data_result = hunt_data(gtin, market, lang_code)

    # 3. MERGE RESULTS
    final_result = image_result.merge(data_result)
    
    return final_result
  end

  # --- PART 1: VISUAL HUNTER ---
  def hunt_visuals(gtin, market, country_name, lang_code)
    # A. Check EAN-Search API first
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

    # B. Check Google Images (Targeted Sites)
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

  # --- PART 2: DATA HUNTER (The "Reader") ---
  def hunt_data(gtin, market, lang_code)
    return {} unless SERPAPI_KEY
    
    # Strategy: We ask Google specifically for the "Ingredients" text associated with this EAN
    # We prioritize 'barcodelookup.com' results because their text is clean.
    query = "site:barcodelookup.com #{gtin}"
    
    begin
      search = GoogleSearch.new(q: query, gl: "us", hl: "en", api_key: SERPAPI_KEY)
      res = search.get_hash
      
      # We look at the 'organic_results' (The normal search results)
      # The 'snippet' is the text Google previews (e.g., "Ingredients: Sugar, Water...")
      results = res[:organic_results] || []
      best_snippet = ""
      
      results.each do |item|
        snippet = item[:snippet] || ""
        # If this snippet has "Ingredients", it's the winner
        if snippet.downcase.include?("ingredients") || snippet.downcase.include?("nutrition")
          best_snippet = snippet
          break
        end
      end
      
      # If BarcodeLookup failed, try a broad Shopping search
      if best_snippet.empty?
         shopping_search = GoogleSearch.new(q: gtin, tbm: "shop", gl: market.downcase, hl: lang_code, api_key: SERPAPI_KEY)
         shop_res = shopping_search.get_hash
         item = (shop_res[:shopping_results] || []).first
         if item
           best_snippet = (item[:description] || "") + " " + (item[:snippet] || "")
         end
      end

      # EXTRACT DATA FROM TEXT
      # Regex looks for patterns like "Energy: 200kcal" or "Ingredients: ..."
      return {
        ingredients: extract_text(best_snippet, /(ingredients|zutaten|ingrédients|ingrediënten)[:\s]+(.*?)(?=\.|\n|Nutrition|$)/i),
        energy: extract_text(best_snippet, /(energy|energie)[:\s]+(.*?)(?=\.|,|$)/i),
        fat: extract_text(best_snippet, /(fat|fett|vet|matières grasses)[:\s]+(.*?)(?=\.|,|$)/i),
        sugars: extract_text(best_snippet, /(sugars|davon zucker|suikers)[:\s]+(.*?)(?=\.|,|$)/i),
        protein: extract_text(best_snippet, /(protein|eiweiß|eiwit)[:\s]+(.*?)(?=\.|,|$)/i)
      }
    rescue => e
      puts "Data Error: #{e.message}"
      return {}
    end
  end

  # --- HELPER FUNCTIONS ---
  
  def extract_text(text, regex)
    match = text.match(regex)
    return match ? match[2].strip : "-"
  end

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
  <title>TGTG Data Hunter</title>
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
    .data-cell { font-family: monospace; color: #555; max-width: 200px; white-space: pre-wrap; word-wrap: break-word; }
  </style>
</head>
<body>

<div class="container">
  <h1>🍏 TGTG Data Hunter</h1>
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
    </select>
  </div>

  <textarea id="inputList" placeholder="Paste GTINs here..."></textarea>
  <br><br>
  <button id="startBtn" onclick="startBatch()">🚀 Start Data Hunt</button>
  <button id="downloadBtn" onclick="downloadCSV()" style="background: #333; display: none;">⬇️ CSV</button>
  
  <p id="statusText">Ready.</p>

  <table id="resultsTable">
    <thead>
      <tr>
        <th>GTIN</th>
        <th>Status</th>
        <th>Image</th>
        <th>Ingredients</th>
        <th>Energy</th>
        <th>Fat</th>
        <th>Sugars</th>
        <th>Protein</th>
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
    
    if (lines.length === 0) { alert("Paste EANs first!"); return; }

    document.getElementById('startBtn').disabled = true;
    const tbody = document.querySelector('#resultsTable tbody');
    tbody.innerHTML = "";
    resultsData = [];
    
    let processed = 0;

    for (const gtin of lines) {
      document.getElementById('statusText').innerText = `Hunting ${gtin}...`;
      const tr = document.createElement('tr');
      tr.innerHTML = `<td>${gtin}</td><td style="color:orange">...</td><td></td><td></td><td></td><td></td><td></td><td></td><td></td>`;
      tbody.appendChild(tr);

      try {
        const response = await fetch(`/api/search?gtin=${gtin}&market=${market}`);
        const data = await response.json();
        
        tr.innerHTML = `
          <td>${gtin}</td>
          <td class="${data.found ? 'status-found' : 'status-missing'}">${data.found ? 'Found' : 'Missing'}</td>
          <td>${data.url ? `<img src="${data.url}" class="img-preview">` : '❌'}</td>
          <td class="data-cell">${data.ingredients || '-'}</td>
          <td class="data-cell">${data.energy || '-'}</td>
          <td class="data-cell">${data.fat || '-'}</td>
          <td class="data-cell">${data.sugars || '-'}</td>
          <td class="data-cell">${data.protein || '-'}</td>
          <td>${data.source ? `<a href="${data.source}" target="_blank" class="source-link">Link</a>` : '-'}</td>
        `;
        
        resultsData.push({ 
          gtin, market, 
          status: data.found ? 'Found' : 'Missing', 
          url: data.url, 
          source: data.source,
          ingredients: data.ingredients,
          energy: data.energy,
          fat: data.fat,
          sugars: data.sugars,
          protein: data.protein
        });

      } catch (e) { console.error(e); }
      
      processed++;
    }
    document.getElementById('startBtn').disabled = false;
    document.getElementById('downloadBtn').style.display = "inline-block";
    document.getElementById('statusText').innerText = "Done!";
  }

  function downloadCSV() {
    let csv = "GTIN,Market,Status,ImageURL,Ingredients,Energy,Fat,Sugars,Protein,SourceURL\n";
    resultsData.forEach(row => {
      const ing = (row.ingredients || "").replace(/,/g, " ");
      csv += `${row.gtin},${row.market},${row.status},${row.url},${ing},${row.energy},${row.fat},${row.sugars},${row.protein},${row.source}\n`;
    });
    const link = document.createElement("a");
    link.href = "data:text/csv;charset=utf-8," + encodeURI(csv);
    link.download = "tgtg_data_hunt.csv";
    link.click();
  }
</script>

</body>
</html>