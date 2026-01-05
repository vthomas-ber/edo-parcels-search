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
    return nil if gtin.nil? || gtin.strip.empty?
    market = market.upcase
    country_name = @country_names[market] || ""
    lang_code = @country_langs[market] || "en"
    
    product_name = nil

    # --- ATTEMPT 1: CHECK DATABASE (EAN-Search) ---
    if EAN_SEARCH_TOKEN
      api_data = check_ean_api(gtin) 
      if api_data
        # If they have a good photo, use it!
        return api_data[:image] if is_good?(api_data[:image])
        # Save the name (e.g. "Olvarit Bio")
        product_name = api_data[:name]
      end
    end

    # --- ATTEMPT 2: TARGETED SITE SEARCH ---
    # We pass 'product_name' to verify the result matches the brand
    site_img = search_google("site:barcodelookup.com \"#{gtin}\"", market, lang_code, product_name)
    return site_img if site_img

    # --- ATTEMPT 3: STRICT GOOGLE SEARCH ---
    strict_img = search_google("\"#{gtin}\" #{country_name}", market, lang_code, product_name)
    return strict_img if strict_img

    # --- ATTEMPT 4: BROAD GOOGLE SEARCH ---
    broad_img = search_google("\"#{gtin}\"", market, lang_code, product_name)
    return broad_img if broad_img

    # --- ATTEMPT 5: NAME SEARCH ---
    if product_name
      # Remove weird symbols to clean up name
      clean_name = product_name.gsub(/[^a-zA-Z0-9\s]/, '') 
      # Don't pass product_name to filter here, because we ARE searching by name
      name_img = search_google(clean_name, market, lang_code, nil)
      return name_img if name_img
    end

    return nil
  end

  # --- HELPER: EAN API ---
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

  # --- HELPER: GOOGLE SEARCH ---
  # Now accepts 'must_match_name' to filter out wrong products
  def search_google(query, gl, hl, must_match_name=nil)
    return nil unless SERPAPI_KEY
    
    res = GoogleSearch.new(q: query, tbm: "isch", gl: gl.downcase, hl: hl, api_key: SERPAPI_KEY).get_hash
    results = res[:images_results] || []

    results.first(15).each do |img|
      url = img[:original]
      title = img[:title].to_s.downcase

      # 1. BLOCK BAD SOURCES (Updated)
      next if url.include?("pinterest") || url.include?("ebay") || url.include?("stock")
      next if url.include?("openfoodfacts") # <-- NEW: Block low quality user uploads
      
      # 2. BRAND VERIFICATION (The Fix for the "Wrong Image" bug)
      # If we know the name is "Olvarit", skip images that don't say "Olvarit" in the title
      if must_match_name
        # We check the first word of the product name (usually the Brand)
        brand_keyword = must_match_name.split(' ').first.to_s.downcase
        # If the brand is missing from the Google Title, it's likely a cross-sell/wrong item
        if brand_keyword.length > 2 && !title.include?(brand_keyword)
           next 
        end
      end

      return url if is_good?(url)
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
    # Allow slightly wider variations, but keep quality high
    return w > 300 && (w.to_f / h.to_f).between?(0.3, 2.5)
  rescue
    false
  end
end

# --- WEB ROUTES ---
get '/' do
  erb :index
end

get '/api/search' do
  content_type :json
  hunter = ImageHunter.new
  url = hunter.find_image(params[:gtin], params[:market])
  if url
    { found: true, url: url }.to_json
  else
    { found: false }.to_json
  end
end

__END__

@@ index
<!DOCTYPE html>
<html>
<head>
  <title>TGTG Bulk Hunter v3</title>
  <style>
    body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif; background: #f0f2f5; padding: 20px; color: #333; }
    .container { max-width: 900px; margin: 0 auto; background: white; padding: 30px; border-radius: 12px; box-shadow: 0 4px 20px rgba(0,0,0,0.08); }
    h1 { color: #00816A; margin-top: 0; }
    .controls { display: flex; gap: 10px; margin-bottom: 20px; align-items: center; background: #eefcf9; padding: 15px; border-radius: 8px; }
    textarea { width: 100%; height: 150px; padding: 10px; border: 1px solid #ccc; border-radius: 8px; font-family: monospace; font-size: 14px; margin-bottom: 10px; }
    button { background: #00816A; color: white; border: none; padding: 12px 24px; border-radius: 6px; font-weight: bold; cursor: pointer; font-size: 16px; transition: background 0.2s; }
    button:hover { background: #006653; }
    button:disabled { background: #ccc; cursor: not-allowed; }
    select, input { padding: 10px; border-radius: 6px; border: 1px solid #ccc; }
    table { width: 100%; border-collapse: collapse; margin-top: 20px; }
    th { text-align: left; background: #00816A; color: white; padding: 12px; }
    td { padding: 12px; border-bottom: 1px solid #eee; vertical-align: middle; }
    tr:nth-child(even) { background: #f9f9f9; }
    .status-found { color: #28a745; font-weight: bold; }
    .status-missing { color: #dc3545; font-weight: bold; }
    .img-preview { max-height: 80px; max-width: 80px; object-fit: contain; border: 1px solid #ddd; border-radius: 4px; }
    .progress-bar { height: 6px; background: #eee; border-radius: 3px; margin-top: 10px; overflow: hidden; }
    .progress-fill { height: 100%; background: #00816A; width: 0%; transition: width 0.3s; }
  </style>
</head>
<body>

<div class="container">
  <h1>🍏 TGTG Bulk Image Hunter</h1>
  <p>Paste a list of GTINs/EANs below.</p>

  <div class="controls">
    <label><strong>Market:</strong></label>
    <select id="marketSelect">
      <option value="AT">Austria (AT)</option>
      <option value="BE">Belgium (BE)</option>
      <option value="DK">Denmark (DK)</option>
      <option value="FR">France (FR)</option>
      <option value="DE">Germany (DE)</option>
      <option value="IT">Italy (IT)</option>
      <option value="NL">Netherlands (NL)</option>
      <option value="UK">United Kingdom (UK)</option>
      <option value="PL">Poland (PL)</option>
      <option value="ES">Spain (ES)</option>
    </select>
  </div>

  <textarea id="inputList" placeholder="Paste your EANs here (one per line)"></textarea>
  
  <button id="startBtn" onclick="startBatch()">🚀 Start Batch Search</button>
  <button id="downloadBtn" onclick="downloadCSV()" style="background: #333; display: none;">⬇️ Download Results</button>
  
  <div class="progress-bar"><div id="progressFill" class="progress-fill"></div></div>
  <p id="statusText" style="color: #666; font-size: 14px;">Ready.</p>

  <table id="resultsTable">
    <thead>
      <tr>
        <th>GTIN</th>
        <th>Status</th>
        <th>Image Preview</th>
        <th>Link</th>
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
    
    if (lines.length === 0) { alert("Please paste some EANs first!"); return; }

    document.getElementById('startBtn').disabled = true;
    const tbody = document.querySelector('#resultsTable tbody');
    tbody.innerHTML = "";
    resultsData = [];
    
    let processed = 0;

    for (const gtin of lines) {
      document.getElementById('statusText').innerText = `Processing ${processed + 1} of ${lines.length}: ${gtin}...`;
      
      const tr = document.createElement('tr');
      tr.id = 'row-' + gtin;
      tr.innerHTML = `<td>${gtin}</td><td style="color:orange">Searching...</td><td>-</td><td>-</td>`;
      tbody.appendChild(tr);

      try {
        const response = await fetch(`/api/search?gtin=${gtin}&market=${market}`);
        const data = await response.json();
        
        if (data.found) {
          tr.innerHTML = `
            <td>${gtin}</td>
            <td class="status-found">Found</td>
            <td><img src="${data.url}" class="img-preview"></td>
            <td><a href="${data.url}" target="_blank">View</a></td>
          `;
          resultsData.push({ gtin, market, status: 'Found', url: data.url });
        } else {
          tr.innerHTML = `
            <td>${gtin}</td>
            <td class="status-missing">Missing</td>
            <td>❌</td>
            <td>-</td>
          `;
          resultsData.push({ gtin, market, status: 'Missing', url: '' });
        }
      } catch (e) {
        tr.innerHTML = `<td>${gtin}</td><td style="color:red">Error</td><td>-</td><td>-</td>`;
      }

      processed++;
      const pct = (processed / lines.length) * 100;
      document.getElementById('progressFill').style.width = pct + "%";
    }

    document.getElementById('statusText').innerText = "Batch Complete!";
    document.getElementById('startBtn').disabled = false;
    document.getElementById('downloadBtn').style.display = "inline-block";
  }

  function downloadCSV() {
    let csvContent = "data:text/csv;charset=utf-8,GTIN,Market,Status,ImageURL\n";
    resultsData.forEach(row => {
      csvContent += `${row.gtin},${row.market},${row.status},${row.url}\n`;
    });
    const encodedUri = encodeURI(csvContent);
    const link = document.createElement("a");
    link.setAttribute("href", encodedUri);
    link.setAttribute("download", "tgtg_results.csv");
    document.body.appendChild(link);
    link.click();
  }
</script>

</body>
</html>