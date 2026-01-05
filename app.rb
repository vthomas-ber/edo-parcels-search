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
    
    product_name = nil

    # --- ATTEMPT 1: CHECK DATABASE (EAN-Search) ---
    if EAN_SEARCH_TOKEN
      api_data = check_ean_api(gtin) 
      if api_data
        # If they have a good photo, use it!
        # EAN-Search is the source, so we link to their lookup page
        if is_good?(api_data[:image])
          return { found: true, url: api_data[:image], source: "https://www.ean-search.org/?q=#{gtin}" }
        end
        product_name = api_data[:name]
      end
    end

    # --- ATTEMPT 2: TARGETED SITE SEARCH (BarcodeLookup) ---
    site_res = search_google("site:barcodelookup.com \"#{gtin}\"", market, lang_code)
    return site_res if site_res

    # --- ATTEMPT 3: STRICT GOOGLE SEARCH ---
    strict_res = search_google("\"#{gtin}\" #{country_name}", market, lang_code)
    return strict_res if strict_res

    # --- ATTEMPT 4: BROAD GOOGLE SEARCH ---
    broad_res = search_google("\"#{gtin}\"", market, lang_code)
    return broad_res if broad_res

    # --- ATTEMPT 5: NAME SEARCH ---
    if product_name
      clean_name = product_name.gsub(/[^a-zA-Z0-9\s]/, '') 
      name_res = search_google(clean_name, market, lang_code)
      return name_res if name_res
    end

    return { found: false }
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

  def search_google(query, gl, hl)
    return nil unless SERPAPI_KEY
    
    res = GoogleSearch.new(q: query, tbm: "isch", gl: gl.downcase, hl: hl, api_key: SERPAPI_KEY).get_hash
    (res[:images_results] || []).first(10).each do |img|
      url = img[:original]
      source_page = img[:link] # This grabs the website URL where the image was found
      
      # --- BLOCK LIST ---
      next if url.include?("pinterest") || url.include?("ebay")
      next if url.include?("openfoodfacts") 
      
      if is_good?(url)
        return { found: true, url: url, source: source_page }
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

# --- WEB ROUTES ---

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
  <title>TGTG Bulk Hunter</title>
  <style>
    body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif; background: #f0f2f5; padding: 20px; color: #333; }
    .container { max-width: 1000px; margin: 0 auto; background: white; padding: 30px; border-radius: 12px; box-shadow: 0 4px 20px rgba(0,0,0,0.08); }
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

    .source-link { color: #00816A; text-decoration: none; font-size: 14px; border: 1px solid #00816A; padding: 4px 8px; border-radius: 4px; }
    .source-link:hover { background: #00816A; color: white; }
  </style>
</head>
<body>

<div class="container">
  <h1>🍏 TGTG Bulk Image Hunter</h1>
  <p>Paste a list of GTINs/EANs below to search for them automatically.</p>

  <div class="controls">
    <label><strong>Market:</strong></label>
    <select id="marketSelect">
      <option value="DE">Germany (DE)</option>
      <option value="UK">United Kingdom (UK)</option>
      <option value="FR">France (FR)</option>
      <option value="IT">Italy (IT)</option>
      <option value="ES">Spain (ES)</option>
      <option value="DK">Denmark (DK)</option>
      <option value="NL">Netherlands (NL)</option>
      <option value="BE">Belgium (BE)</option>
      <option value="AT">Austria (AT)</option>
      <option value="CH">Switzerland (CH)</option>
      <option value="PL">Poland (PL)</option>
      <option value="SE">Sweden (SE)</option>
      <option value="NO">Norway (NO)</option>
      <option value="PT">Portugal (PT)</option>
    </select>
  </div>

  <textarea id="inputList" placeholder="Paste your EANs here (one per line)&#10;4260407955266&#10;7610400081405&#10;..."></textarea>
  
  <button id="startBtn" onclick="startBatch()">🚀 Start Batch Search</button>
  <button id="downloadBtn" onclick="downloadCSV()" style="background: #333; display: none;">⬇️ Download Results</button>
  
  <div class="progress-bar"><div id="progressFill" class="progress-fill"></div></div>
  <p id="statusText" style="color: #666; font-size: 14px;">Ready to start.</p>

  <table id="resultsTable">
    <thead>
      <tr>
        <th>GTIN</th>
        <th>Status</th>
        <th>Image Preview</th>
        <th>Download Image</th>
        <th>Source / Variants</th>
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
      tr.innerHTML = `<td>${gtin}</td><td style="color:orange">Searching...</td><td>-</td><td>-</td><td>-</td>`;
      tbody.appendChild(tr);

      try {
        const response = await fetch(`/api/search?gtin=${gtin}&market=${market}`);
        const data = await response.json();
        
        if (data.found) {
          tr.innerHTML = `
            <td>${gtin}</td>
            <td class="status-found">Found</td>
            <td><img src="${data.url}" class="img-preview"></td>
            <td><a href="${data.url}" target="_blank">View Full</a></td>
            <td><a href="${data.source}" target="_blank" class="source-link">🔗 See Variants</a></td>
          `;
          resultsData.push({ gtin, market, status: 'Found', url: data.url, source: data.source });
        } else {
          tr.innerHTML = `
            <td>${gtin}</td>
            <td class="status-missing">Missing</td>
            <td>❌</td>
            <td>-</td>
            <td>-</td>
          `;
          resultsData.push({ gtin, market, status: 'Missing', url: '', source: '' });
        }
      } catch (e) {
        tr.innerHTML = `<td>${gtin}</td><td style="color:red">Error</td><td>-</td><td>-</td><td>-</td>`;
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
    let csvContent = "data:text/csv;charset=utf-8,GTIN,Market,Status,ImageURL,SourceURL\n";
    resultsData.forEach(row => {
      csvContent += `${row.gtin},${row.market},${row.status},${row.url},${row.source}\n`;
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