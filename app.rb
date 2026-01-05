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
    
    # 1. VISUAL HUNT
    image_result = hunt_visuals(gtin, market, country_name, lang_code)
    
    # 2. DATA HUNT (Using Google Snippets)
    data_result = hunt_data(gtin, market, lang_code, image_result[:product_name])

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

    # B. Google Images Strategies
    site_res = search_google_images("site:barcodelookup.com \"#{gtin}\"", market, lang_code)
    return site_res if site_res

    strict_res = search_google_images("\"#{gtin}\" #{country_name}", market, lang_code)
    return strict_res if strict_res

    broad_res = search_google_images("\"#{gtin}\"", market, lang_code)
    return broad_res if broad_res

    return { found: false, url: "", source: "" }
  end

  # --- PART 2: DATA HUNTER (Snippet Strategy) ---
  def hunt_data(gtin, market, lang_code, product_name)
    return empty_data_set unless SERPAPI_KEY

    # Strategy: Ask Google for the text directly
    # We search for the GTIN + "Ingredients" to force the text into the snippet
    query = "#{gtin} ingredients nutrition"
    
    # If we have a product name, use that too for better luck
    if product_name
      query = "#{product_name} ingredients nutrition"
    end
    
    puts "   👉 Hunting Data for: #{query}..."

    begin
      search = GoogleSearch.new(q: query, gl: market.downcase, hl: lang_code, api_key: SERPAPI_KEY)
      res = search.get_hash
      
      # We combine the snippets from the top 3 results into one big text block
      # This increases the chance we catch the ingredients list
      big_text_blob = ""
      (res[:organic_results] || []).first(3).each do |item|
        big_text_blob += " " + (item[:snippet] || "")
      end

      # Also check 'Shopping' results if available (they have good data)
      if res[:shopping_results]
        (res[:shopping_results] || []).first(1).each do |item|
           big_text_blob += " " + (item[:description] || "")
        end
      end
      
      # Now we search the Google Text for our data
      return extract_all_data(big_text_blob)
      
    rescue
      return empty_data_set
    end
  end

  def extract_all_data(text_blob)
    # Clean up text
    text_blob = text_blob.gsub(/\s+/, " ")

    data = {
      weight: extract_text(text_blob, /(weight|gewicht|inhoud|netto|poids|size)[:\s]+(\d+\s?(g|kg|ml|l|oz|cl))\b/i),
      ingredients: extract_text(text_blob, /(ingredients|zutaten|ingrédients|ingrediënten|samenstelling)\s*[:\.]\s*(.*?)(?=(nutrition|voedingswaarden|nährwerte|energy|energie|$))/i),
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
    return data
  end

  def extract_text(text, regex)
    match = text.match(regex)
    return "-" unless match
    value = match[2] || match[1]
    return "-" if value.nil? || value.strip.empty?
    return value[0..400].strip 
  end

  def empty_data_set
    { 
      weight: "-", ingredients: "-", allergens: "-", may_contain: "-", nutrition_header: "-",
      energy: "-", fat: "-", saturates: "-", carbs: "-", sugars: "-", protein: "-", fiber: "-", salt: "-", organic_cert: "-"
    }
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
  <title>TGTG Master Data Hunter</title>
  <style>
    body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif; background: #f0f2f5; padding: 20px; color: #333; }
    .container { max-width: 95%; margin: 0 auto; background: white; padding: 30px; border-radius: 12px; box-shadow: 0 4px 20px rgba(0,0,0,0.08); }
    h1 { color: #00816A; margin-top: 0; }
    .controls { display: flex; gap: 10px; margin-bottom: 20px; align-items: center; background: #eefcf9; padding: 15px; border-radius: 8px; }
    textarea { width: 100%; height: 100px; padding: 10px; border: 1px solid #ccc; border-radius: 8px; font-family: monospace; }
    button { background: #00816A; color: white; border: none; padding: 12px 24px; border-radius: 6px; font-weight: bold; cursor: pointer; }
    button:disabled { background: #ccc; }
    
    .table-wrapper { overflow-x: auto; margin-top: 20px; border: 1px solid #eee; border-radius: 8px; }
    table { width: 100%; border-collapse: collapse; font-size: 13px; min-width: 2000px; }
    th { text-align: left; background: #00816A; color: white; padding: 10px; white-space: nowrap; position: sticky; left: 0; }
    td { padding: 10px; border-bottom: 1px solid #eee; vertical-align: top; max-width: 300px; word-wrap: break-word; }
    tr:nth-child(even) { background: #f9f9f9; }
    
    .status-found { color: #28a745; font-weight: bold; }
    .status-missing { color: #dc3545; font-weight: bold; }
    .img-preview { max-height: 60px; max-width: 60px; object-fit: contain; }
    .source-link { color: #00816A; text-decoration: none; border: 1px solid #00816A; padding: 2px 6px; border-radius: 4px; font-size: 11px; }
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
  <button id="startBtn">🚀 Start Data Hunt</button>
  <button id="downloadBtn" onclick="downloadCSV()" style="background: #333; display: none;">⬇️ Download CSV</button>
  
  <p id="statusText">Ready.</p>

  <div class="table-wrapper">
    <table id="resultsTable">
      <thead>
        <tr>
          <th>GTIN</th>
          <th>Status</th>
          <th>Image</th>
          <th>Weight</th>
          <th>Ingredients</th>
          <th>Allergens</th>
          <th>May Contain</th>
          <th>Nutri Header</th>
          <th>Energy</th>
          <th>Fat</th>
          <th>Saturates</th>
          <th>Carbs</th>
          <th>Sugars</th>
          <th>Protein</th>
          <th>Fiber</th>
          <th>Salt</th>
          <th>Organic ID</th>
          <th>Source</th>
        </tr>
      </thead>
      <tbody></tbody>
    </table>
  </div>
</div>

<script>
  let resultsData = [];
  document.getElementById('startBtn').addEventListener('click', startBatch);

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
      document.getElementById('statusText').innerText = `Hunting ${gtin} (${processed + 1}/${lines.length})...`;
      const tr = document.createElement('tr');
      let emptyCells = ""; for(let i=0; i<16; i++) { emptyCells += "<td></td>"; }
      tr.innerHTML = `<td>${gtin}</td><td style="color:orange">Loading...</td>` + emptyCells;
      tbody.appendChild(tr);

      try {
        const response = await fetch(`/api/search?gtin=${gtin}&market=${market}`);
        const data = await response.json();
        
        tr.innerHTML = `
          <td>${gtin}</td>
          <td class="${data.found ? 'status-found' : 'status-missing'}">${data.found ? 'Found' : 'Missing'}</td>
          <td>${data.url ? `<img src="${data.url}" class="img-preview">` : '❌'}</td>
          <td>${data.weight}</td>
          <td>${(data.ingredients || '-').substring(0, 50)}...</td>
          <td>${data.allergens}</td>
          <td>${data.may_contain}</td>
          <td>${data.nutrition_header}</td>
          <td>${data.energy}</td>
          <td>${data.fat}</td>
          <td>${data.saturates}</td>
          <td>${data.carbs}</td>
          <td>${data.sugars}</td>
          <td>${data.protein}</td>
          <td>${data.fiber}</td>
          <td>${data.salt}</td>
          <td>${data.organic_cert}</td>
          <td>${data.source ? `<a href="${data.source}" target="_blank" class="source-link">Link</a>` : '-'}</td>
        `;
        resultsData.push({ ...data, gtin, market, status: data.found ? 'Found' : 'Missing' });
      } catch (e) { 
        tr.innerHTML = `<td>${gtin}</td><td style="color:red">Error</td>` + emptyCells;
      }
      processed++;
    }
    document.getElementById('startBtn').disabled = false;
    document.getElementById('downloadBtn').style.display = "inline-block";
    document.getElementById('statusText').innerText = "Batch Complete!";
  }

  function downloadCSV() {
    let csv = "GTIN,Market,Status,ImageURL,SourceURL,Weight,Ingredients,Allergens,MayContain,NutritionHeader,Energy,Fat,Saturates,Carbohydrates,Sugars,Protein,Fiber,Salt,OrganicID\n";
    resultsData.forEach(row => {
      const clean = (txt) => (txt || "-").toString().replace(/,/g, " ").replace(/\n/g, " ").trim();
      csv += `${row.gtin},${row.market},${row.status},${row.url},${row.source},${clean(row.weight)},${clean(row.ingredients)},${clean(row.allergens)},${clean(row.may_contain)},${clean(row.nutrition_header)},${clean(row.energy)},${clean(row.fat)},${clean(row.saturates)},${clean(row.carbs)},${clean(row.sugars)},${clean(row.protein)},${clean(row.fiber)},${clean(row.salt)},${clean(row.organic_cert)}\n`;
    });
    const link = document.createElement("a");
    link.href = "data:text/csv;charset=utf-8," + encodeURI(csv);
    link.download = "tgtg_master_data.csv";
    link.click();
  }
</script>

</body>
</html>