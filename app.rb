require 'sinatra'
require 'google_search_results'
require 'down'
require 'fastimage'
require 'json'
require 'base64'
require 'httparty'
require 'nokogiri'

# --- CONFIGURATION ---
GEMINI_API_KEY     = ENV['GEMINI_API_KEY']
SERPAPI_KEY        = ENV['SERPAPI_KEY']
EAN_SEARCH_TOKEN   = ENV['EAN_SEARCH_TOKEN']

class MasterDataHunter
  include HTTParty

  def initialize
    @headers = { 'Content-Type' => 'application/json' }

    # 1. MARKET DEFINITIONS
    @country_langs = {
      "DE" => "German", "AT" => "German", "CH" => "German",
      "UK" => "English", "GB" => "English", "FR" => "French",
      "BE" => "French", "IT" => "Italian", "ES" => "Spanish",
      "NL" => "Dutch", "DK" => "Danish", "SE" => "Swedish",
      "NO" => "Norwegian", "PL" => "Polish", "PT" => "Portuguese"
    }

    # 2. THE GOLDMINE (Trusted Retailers)
    @goldmine_sites = {
      "FR" => "site:carrefour.fr OR site:auchan.fr OR site:coursesu.com OR site:intermarche.com OR site:monoprix.fr OR site:franprix.fr",
      "UK" => "site:tesco.com OR site:sainsburys.co.uk OR site:asda.com OR site:morrisons.com OR site:iceland.co.uk OR site:waitrose.com",
      "NL" => "site:ah.nl OR site:jumbo.com OR site:plus.nl OR site:dirk.nl OR site:vomar.nl",
      "BE" => "site:delhaize.be OR site:colruyt.be OR site:carrefour.be OR site:ah.be",
      "DE" => "site:rewe.de OR site:edeka.de OR site:kaufland.de OR site:dm.de OR site:rossmann.de",
      "DK" => "site:nemlig.com OR site:bilkatogo.dk OR site:rema1000.dk OR site:netto.dk",
      "IT" => "site:carrefour.it OR site:conad.it OR site:esselunga.it OR site:coop.it",
      "ES" => "site:carrefour.es OR site:mercadona.es OR site:dia.es OR site:alcampo.es",
      "SE" => "site:ica.se OR site:coop.se OR site:willys.se OR site:hemkop.se",
      "NO" => "site:oda.com OR site:meny.no OR site:spar.no",
      "PL" => "site:carrefour.pl OR site:auchan.pl OR site:biedronka.pl",
      "PT" => "site:continente.pt OR site:auchan.pt OR site:pingo-doce.pt"
    }
  end

  def process_product(gtin, market)
    if GEMINI_API_KEY.nil? || GEMINI_API_KEY.strip.empty?
      return { found: false, status: "Missing GEMINI_API_KEY" }
    end

    # A. IMAGE HUNT
    image_data = find_best_image(gtin, market)

    # B. DATA HUNT
    text_source_url = image_data ? image_data[:source] : find_text_source(gtin, market)

    # C. FETCH CONTENT
    website_content = fetch_advanced_page_data(text_source_url)

    # D. ANALYZE
    ai_result = analyze_with_gemini(image_data ? image_data[:base64] : nil, website_content, gtin, market)

    # E. FALLBACK (if image causes 400)
    if ai_result.is_a?(Hash) && ai_result[:error] && ai_result[:error].include?("API 400")
      puts "⚠️ Image rejected or bad request. Retrying TEXT ONLY..."
      ai_result = analyze_with_gemini(nil, website_content, gtin, market)
    end

    if ai_result.is_a?(Hash) && ai_result[:error]
      return empty_result(
        gtin,
        market,
        ai_result[:error],
        image_data ? image_data[:url] : nil,
        text_source_url
      )
    end

    {
      found: true,
      gtin: gtin,
      status: "Found",
      market: market,
      image_url: image_data ? image_data[:url] : nil,
      source_url: text_source_url,
      **ai_result
    }
  end

  private

  def serp_gl_for_market(market)
    # SerpAPI expects gb, not uk
    return "gb" if market == "UK"
    market.to_s.downcase
  end

  def find_best_image(gtin, market)
    return nil if SERPAPI_KEY.nil? || SERPAPI_KEY.strip.empty?

    bans = "-site:openfoodfacts.org -site:world.openfoodfacts.org -site:myfitnesspal.com -site:pinterest.* -site:ebay.*"
    gl = serp_gl_for_market(market)

    query = "site:barcodelookup.com OR site:go-upc.com OR site:amazon.* \"#{gtin}\""
    res = GoogleSearch.new(q: query, tbm: "isch", gl: gl, api_key: SERPAPI_KEY).get_hash

    if (res[:images_results] || []).empty?
      res = GoogleSearch.new(q: "#{gtin} #{bans}", tbm: "isch", gl: gl, api_key: SERPAPI_KEY).get_hash
    end

    (res[:images_results] || []).first(5).each do |img|
      url = img[:original]
      next if url.nil? || url.include?("placeholder")

      begin
        tempfile = Down.download(url, max_size: 5 * 1024 * 1024)
        base64 = Base64.strict_encode64(File.read(tempfile.path))
        return { url: url, source: img[:link], base64: base64 }
      rescue
        next
      end
    end

    nil
  end

  def find_text_source(gtin, market)
    return nil if SERPAPI_KEY.nil? || SERPAPI_KEY.strip.empty?

    goldmine = @goldmine_sites[market]
    bans = "-site:openfoodfacts.org -site:wikipedia.org"
    gl = serp_gl_for_market(market)

    if goldmine
      res = GoogleSearch.new(q: "#{goldmine} #{gtin} #{bans}", gl: gl, api_key: SERPAPI_KEY).get_hash
      first_link = (res[:organic_results] || []).first
      return first_link[:link] if first_link
    end

    res = GoogleSearch.new(q: "#{gtin}", tbm: "shop", gl: gl, api_key: SERPAPI_KEY).get_hash
    first_shop = (res[:shopping_results] || []).first
    return first_shop[:link] if first_shop

    nil
  end

  def fetch_advanced_page_data(url)
    return "" if url.nil? || url.to_s.strip.empty?

    begin
      user_agent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
      response = HTTParty.get(url, headers: { "User-Agent" => user_agent }, timeout: 10)

      html = response.body.to_s
      doc = Nokogiri::HTML(html)

      doc.css('script, style, nav, footer, iframe').remove
      visual_text = doc.text.gsub(/\s+/, " ").strip[0..4000]

      json_ld_data = ""
      doc.css('script[type="application/ld+json"]').each do |script|
        json_ld_data += " " + script.content.to_s.gsub(/\s+/, " ").strip[0..2000]
      end

      "VISUAL TEXT: #{visual_text}\n\nHIDDEN JSON-LD: #{json_ld_data}"
    rescue
      ""
    end
  end

  def analyze_with_gemini(base64_image, page_content, gtin, market)
    target_lang = @country_langs[market] || "English"

    # Define models
    models_to_try = [
      "models/gemini-2.0-flash",
      "models/gemini-2.0-flash-lite",
      "models/gemini-1.5-flash"
    ]

    # --- UPDATED PROMPT FOR API USAGE (JSON) ---
    prompt_text = <<~TEXT
      You are the **Lead Food Product Researcher**, a specialized analyst designed to compile 100% accurate product specifications for ambient and packaged goods.

      CORE DIRECTIVE: Accuracy is your absolute priority. It is better to state "N/A" than to guess.

      INPUT CONTEXT:
      - Market: #{market} (Target Language: #{target_lang})
      - GTIN: #{gtin}
      - DATA SOURCE: The text below (scraped from retailers) and the attached image (if any).

      1. WEBSITE DATA (Text + Hidden JSON):
      """
      #{page_content}
      """
      #{base64_image ? "2. IMAGE: Attached" : "2. IMAGE: None"}

      ---
      
      ### PHASE 1: ANALYSIS & LOCALIZATION
      1. **Analyze** the provided text and image to extract product details.
      2. **Translate** ALL output (Ingredients, Product Name, Allergens) into **#{target_lang}**.
      3. **Verify** details. Look for Organic Codes (e.g., DE-ÖKO-001). If none, use "N/A".

      ### PHASE 2: DATA STANDARDIZATION rules
      - **Ingredients:** Must be a single continuous text string (remove bullet points/line breaks).
      - **Energy:** Standardize to "kJ / kcal". Calculate if missing (1 kcal = 4.184 kJ).
      - **Values:** Use "N/A" if data is missing. Do not fabricate.

      ### PHASE 3: OUTPUT FORMAT (STRICT JSON)
      You must output valid JSON. Do not generate a Markdown table. Use exactly these keys:

      {
        "product_name": "Brand + Product Name (#{target_lang})",
        "weight": "Net Weight (e.g. 500g)",
        "ingredients": "Full List (#{target_lang})",
        "allergens": "List (#{target_lang})",
        "may_contain": "List (#{target_lang})",
        "nutri_scope": "per 100g (or per serving if specified)",
        "energy": "0000 kJ / 000 kcal",
        "fat": "0g",
        "saturates": "0g",
        "carbs": "0g",
        "sugars": "0g",
        "protein": "0g",
        "fiber": "0g",
        "salt": "0g",
        "organic_id": "Code or N/A"
      }
    TEXT

    parts = [{ text: prompt_text }]
    if base64_image
      parts << { inline_data: { mime_type: "image/jpeg", data: base64_image } }
    end

    models_to_try.each do |model_id|
      model_path = model_id.start_with?("models/") ? model_id : "models/#{model_id}"
      url = "https://generativelanguage.googleapis.com/v1beta/#{model_path}:generateContent?key=#{GEMINI_API_KEY}"

      begin
        response = HTTParty.post(
          url,
          body: { contents: [{ parts: parts }] }.to_json,
          headers: @headers,
          timeout: 30
        )

        if response.code == 200
          raw_text = response.dig("candidates", 0, "content", "parts", 0, "text")
          if raw_text.nil? || raw_text.strip.empty?
            puts "⚠️ Gemini returned 200 but empty text for model=#{model_id}"
            next
          end

          # Clean Markdown code blocks to ensure valid JSON
          clean_json = raw_text.gsub(/```json/i, "").gsub(/```/, "").strip
          return JSON.parse(clean_json)
        end

        puts "❌ Gemini failed model=#{model_id} code=#{response.code}"
        
        if response.code == 400
          return { error: "API 400 (Bad request). Body: #{response.body.to_s[0..400]}" }
        end

        next if [403, 404, 429, 500, 502, 503].include?(response.code)

        return { error: "API #{response.code}: #{response.body.to_s[0..400]}" }
      rescue => e
        return { error: "#{e.class}: #{e.message}" }
      end
    end

    { error: "All models failed. Last error: 403/404/429 across ladder" }
  end

  def empty_result(gtin, market, status_msg, img_url = nil, src_url = nil)
    {
      found: false, status: status_msg, gtin: gtin, market: market,
      image_url: img_url, source_url: src_url,
      product_name: "-", weight: "-", ingredients: "-", allergens: "-",
      may_contain: "-", nutri_scope: "-", energy: "-", fat: "-",
      saturates: "-", carbs: "-", sugars: "-", protein: "-",
      fiber: "-", salt: "-", organic_id: "-"
    }
  end
end

# --- ROUTES ---

get '/' do
  erb :index
end

get '/api/search' do
  content_type :json
  hunter = MasterDataHunter.new
  result = hunter.process_product(params[:gtin], params[:market])
  result.to_json
end

__END__

@@ index
<!DOCTYPE html>
<html>
<head>
  <title>TGTG AI Data Hunter</title>
  <style>
    body { font-family: -apple-system, system-ui, sans-serif; background: #f4f6f8; padding: 20px; color: #333; }
    .container { max-width: 98%; margin: 0 auto; background: white; padding: 25px; border-radius: 12px; box-shadow: 0 2px 10px rgba(0,0,0,0.05); }
    h1 { color: #00816A; }

    .controls { display: flex; gap: 15px; margin-bottom: 20px; background: #eefcf9; padding: 15px; border-radius: 8px; }
    textarea { width: 100%; height: 100px; padding: 12px; border: 1px solid #ddd; border-radius: 8px; font-family: monospace; }
    button { background: #00816A; color: white; border: none; padding: 12px 24px; border-radius: 6px; font-weight: 600; cursor: pointer; }
    button:disabled { background: #ccc; }

    .table-wrapper { overflow-x: auto; margin-top: 25px; border: 1px solid #eee; border-radius: 8px; }
    table { width: 100%; border-collapse: collapse; font-size: 13px; min-width: 2600px; }
    th { text-align: left; background: #00816A; color: white; padding: 12px; position: sticky; left: 0; z-index: 10; white-space: nowrap; }
    td { padding: 12px; border-bottom: 1px solid #eee; vertical-align: top; max-width: 250px; word-wrap: break-word; }
    tr:nth-child(even) { background: #f8f9fa; }

    .status-found { background: #d4edda; color: #155724; padding: 4px 8px; border-radius: 4px; font-weight: bold; }
    .status-missing { background: #f8d7da; color: #721c24; padding: 4px 8px; border-radius: 4px; font-weight: bold; }
    .img-preview { width: 60px; height: 60px; object-fit: contain; border: 1px solid #ddd; border-radius: 4px; background: white; }
    .link-btn { color: #00816A; text-decoration: none; border: 1px solid #00816A; padding: 4px 8px; border-radius: 4px; font-size: 11px; white-space: nowrap; display: inline-block; margin-top: 2px;}
    .link-btn:hover { background: #00816A; color: white; }
    .dl-link { font-weight: bold; text-decoration: underline; color: #333; cursor: pointer; }
  </style>
</head>
<body>

<div class="container">
  <h1>✨ TGTG AI Master Data Hunter</h1>
  <div class="controls">
    <select id="marketSelect" style="padding: 8px; border-radius: 4px;">
      <option value="DE">Germany (DE)</option>
      <option value="UK">United Kingdom (UK)</option>
      <option value="FR">France (FR)</option>
      <option value="NL">Netherlands (NL)</option>
      <option value="BE">Belgium (BE)</option>
      <option value="IT">Italy (IT)</option>
      <option value="ES">Spain (ES)</option>
      <option value="DK">Denmark (DK)</option>
      <option value="PL">Poland (PL)</option>
      <option value="PT">Portugal (PT)</option>
    </select>
  </div>

  <textarea id="inputList" placeholder="Paste EANs here..."></textarea>
  


  <button id="startBtn" onclick="startBatch()">🚀 Start AI Analysis</button>
  <button id="downloadBtn" onclick="downloadCSV()" style="background: #333; display: none;">⬇️ Download CSV</button>
  <p id="statusText" style="color: #666; margin-top: 10px;">Ready.</p>

  <div class="table-wrapper">
    <table id="resultsTable">
      <thead>
        <tr>
          <th>Status</th>
          <th>Image Preview</th>
          <th>Download Image</th>
          <th>Source / Variants</th>
          <th>EAN</th>
          <th>Product Name</th>
          <th>Ingredients</th>
          <th>Allergens</th>
          <th>May Contain</th>
          <th>Nutritional Scope</th>
          <th>Energy</th>
          <th>Fat</th>
          <th>Saturates</th>
          <th>Carbs</th>
          <th>Sugars</th>
          <th>Protein</th>
          <th>Fiber</th>
          <th>Salt</th>
          <th>Organic ID</th>
          <th>Source (Food Info)</th>
        </tr>
      </thead>
      <tbody></tbody>
    </table>
  </div>
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
      document.getElementById('statusText').innerText = `Analyzing ${gtin} (${processed + 1}/${lines.length})...`;
      const tr = document.createElement('tr');
      let emptyCells = ""; for(let i=0; i<17; i++) { emptyCells += "<td></td>"; }
      tr.innerHTML = `<td style="color:#00816A; font-weight:bold;">Thinking...</td>` + emptyCells;
      tbody.appendChild(tr);

      try {
        const response = await fetch(`/api/search?gtin=${gtin}&market=${market}`);
        const data = await response.json();

        let displayStatus = data.status;
        let statusClass = 'status-found';
        if (String(data.status).includes("Error") || String(data.status).includes("Missing") || String(data.status).includes("429") || String(data.status).includes("403") || String(data.status).includes("404")) {
           statusClass = 'status-missing';
        }

        const imgHTML = data.image_url ? `<img src="${data.image_url}" class="img-preview">` : '❌';
        const dlLink = data.image_url ? `<a href="${data.image_url}" target="_blank" class="link-btn">⬇️ View Full</a>` : '-';
        const sourceLink = data.source_url ? `<a href="${data.source_url}" target="_blank" class="link-btn">🔗 Variants</a>` : '-';
        const infoLink = data.source_url ? `<a href="${data.source_url}" target="_blank" class="link-btn">✅ Verify Data</a>` : '-';

        tr.innerHTML = `<br>
          <td><span class="${statusClass}">${displayStatus}</span></td>
          <td>${imgHTML}</td>
          <td>${dlLink}</td>
          <td>${sourceLink}</td>
          <td>${gtin}</td>
          <td>${data.product_name}</td>
          <td>${data.ingredients}</td>
          <td>${data.allergens}</td>
          <td>${data.may_contain}</td>
          <td>${data.nutri_scope}</td>
          <td>${data.energy}</td>
          <td>${data.fat}</td>
          <td>${data.saturates}</td>
          <td>${data.carbs}</td>
          <td>${data.sugars}</td>
          <td>${data.protein}</td>
          <td>${data.fiber}</td>
          <td>${data.salt}</td>
          <td>${data.organic_id}</td>
          <td>${infoLink}</td>
        `;
        resultsData.push(data);
      } catch (e) {
        tr.innerHTML = `<td style="color:red">Error</td>` + emptyCells;
      }
      processed++;

      if (processed < lines.length) {
        document.getElementById('statusText').innerText = `Cooling down (10s)...`;
        await new Promise(r => setTimeout(r, 10000));
      }
    }
    document.getElementById('startBtn').disabled = false;
    document.getElementById('downloadBtn').style.display = "inline-block";
    document.getElementById('statusText').innerText = "Batch Complete!";
  }

  function downloadCSV() {
    let csv = "EAN,ProductName,Status,ImageURL,SourceVariants,Ingredients,Allergens,MayContain,NutritionalScope,Energy,Fat,Saturates,Carbs,Sugars,Protein,Fiber,Salt,OrganicID,FoodInfoSource\n";

    resultsData.forEach(row => {
      const clean = (txt) => (txt || "-").toString().replace(/,/g, " ").replace(/\n/g, " ").trim();
      csv += `${row.gtin},${clean(row.product_name)},${row.status},${row.image_url},${row.source_url},` +
             `${clean(row.ingredients)},${clean(row.allergens)},${clean(row.may_contain)},` +
             `${clean(row.nutri_scope)},${clean(row.energy)},${clean(row.fat)},${clean(row.saturates)},` +
             `${clean(row.carbs)},${clean(row.sugars)},${clean(row.protein)},${clean(row.fiber)},` +
             `${clean(row.salt)},${clean(row.organic_id)},${row.source_url}\n`;
    });

    const link = document.createElement("a");
    link.href = "data:text/csv;charset=utf-8," + encodeURI(csv);
    link.download = "tgtg_ai_results.csv";
    link.click();
  }
</script>

</body>
</html>
