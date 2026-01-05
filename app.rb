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
    
    @local_keywords = {
      "DE" => "Zutaten Nährwerte", "AT" => "Zutaten Nährwerte", "CH" => "Zutaten Nährwerte",
      "UK" => "Ingredients Nutrition", "GB" => "Ingredients Nutrition",
      "FR" => "Ingrédients Nutrition", "BE" => "Ingrédients Nutrition",
      "NL" => "Ingrediënten Voedingswaarden", 
      "IT" => "Ingredienti Nutrizionali",
      "ES" => "Ingredientes Nutrición",
      "DK" => "Ingredienser Næringsindhold",
      "SE" => "Ingredienser Näringsvärde",
      "NO" => "Ingredienser Næringsinnhold",
      "PL" => "Składniki Wartość odżywcza",
      "PT" => "Ingredientes Nutrição"
    }

    @data_sources = {
      "FR" => "site:carrefour.fr OR site:auchan.fr OR site:coursesu.com OR site:courses.monoprix.fr OR site:labellevie.com OR site:chronodrive.com OR site:intermarche.com OR site:houra.fr OR site:bamcourses.com OR site:franprix.fr OR site:clic-shopping.com OR site:willyantigaspi.fr OR site:beansclub.fr",
      "UK" => "site:tesco.com OR site:sainsburys.co.uk OR site:asda.com OR site:groceries.morrisons.com OR site:iceland.co.uk OR site:aldi.co.uk OR site:poundland.co.uk OR site:marksandspencer.com OR site:amazon.co.uk OR site:bmstores.co.uk OR site:heronfoods.com OR site:poundstretcher.co.uk OR site:home.bargains OR site:therange.co.uk OR site:lowpricefoods.com OR site:approvedfood.co.uk OR site:discountdragon.co.uk OR site:productlibrary.brandbank.com OR site:nutricircle.co.uk",
      "NL" => "site:ah.nl OR site:jumbo.com OR site:lidl.nl OR site:dirk.nl OR site:vomar.nl OR site:aldi.nl OR site:goflink.com OR site:picnic.app OR site:foodello.nl OR site:amazon.nl OR site:kruidvat.nl",
      "BE" => "site:delhaize.be OR site:colruyt.be OR site:carrefour.be OR site:ah.be OR site:foodello.be OR site:amazon.com.be OR site:bol.com OR site:psinfoodservice.com OR site:checker.thequestionmark.org",
      "DK" => "site:nemlig.com OR site:bilkatogo.dk OR site:netto.dk OR site:rema1000.dk OR site:lidl.dk OR site:365discount.coop.dk OR site:brugsen.coop.dk OR site:kvickly.coop.dk OR site:superbrugsen.coop.dk OR site:meny.dk OR site:dagrofa.dk OR site:motatos.dk OR site:normal.dk OR site:almamad.dk",
      "DE" => "site:rewe.de OR site:kaufland.de",
      "AT" => "site:rewe.de OR site:kaufland.de",
      "ES" => "site:carrefour.es OR site:alcampo.es OR site:hipercor.es",
      "IT" => "site:cosicomodo.it OR site:carrefour.it OR site:spesasicura.com OR site:conad.it OR site:esselunga.it"
    }
  end

  def find_image(gtin, market)
    return { found: false } if gtin.nil? || gtin.strip.empty?
    market = market.upcase
    country_name = @country_names[market] || ""
    lang_code = @country_langs[market] || "en"
    
    # 1. VISUAL HUNT
    image_result = hunt_visuals(gtin, market, country_name, lang_code)
    
    # 2. DATA HUNT
    data_result = hunt_data(gtin, market, lang_code, image_result[:product_name])

    # 3. MERGE
    final_result = image_result.merge(data_result)
    return final_result
  end

  # --- PART 1: VISUAL HUNTER ---
  def hunt_visuals(gtin, market, country_name, lang_code)
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

    site_res = search_google_images("site:barcodelookup.com \"#{gtin}\"", market, lang_code)
    return site_res if site_res

    strict_res = search_google_images("\"#{gtin}\" #{country_name}", market, lang_code)
    return strict_res if strict_res

    broad_res = search_google_images("\"#{gtin}\"", market, lang_code)
    return broad_res if broad_res

    return { found: false, url: "", source: "" }
  end

  # --- PART 2: DATA HUNTER ---
  def hunt_data(gtin, market, lang_code, product_name)
    return empty_data_set unless SERPAPI_KEY
    keywords = @local_keywords[market] || "Ingredients Nutrition"
    bans = "-site:openfoodfacts.org -site:world.openfoodfacts.org -site:wikipedia.org"

    # STRATEGY 1: GOOGLE SHOPPING (Best Data)
    shopping_data = run_shopping_search("#{gtin} #{bans}", market, lang_code)
    return shopping_data unless shopping_data[:ingredients] == "-"

    # STRATEGY 2: GOLDMINE SITES
    goldmine = @data_sources[market]
    if goldmine
      data = run_text_search("#{goldmine} #{gtin} #{keywords} #{bans}", market, lang_code)
      return data unless data[:ingredients] == "-"
    end
    
    # STRATEGY 3: BRAND SEARCH
    if product_name
      data = run_text_search("#{product_name} #{keywords} #{bans}", market, lang_code)
      return data unless data[:ingredients] == "-"
    end
    
    return empty_data_set
  end

  def run_shopping_search(query, market, lang_code)
    begin
      search = GoogleSearch.new(
        q: query, tbm: "shop", gl: market.downcase, hl: lang_code, lr: "lang_#{lang_code}", api_key: SERPAPI_KEY
      )
      res = search.get_hash
      big_text_blob = ""
      (res[:shopping_results] || []).first(3).each do |item|
        big_text_blob += " " + (item[:title] || "") + " " + (item[:snippet] || "") + " " + (item[:description] || "")
      end
      return extract_all_data(big_text_blob)
    rescue
      return empty_data_set
    end
  end

  def run_text_search(query, market, lang_code)
    begin
      search = GoogleSearch.new(
        q: query, gl: market.downcase, hl: lang_code, lr: "lang_#{lang_code}", api_key: SERPAPI_KEY
      )
      res = search.get_hash
      big_text_blob = ""
      (res[:organic_results] || []).first(6).each do |item|
        big_text_blob += " " + (item[:snippet] || "")
      end
      return extract_all_data(big_text_blob)
    rescue
      return empty_data_set
    end
  end

  # --- AGGRESSIVE PARSER ---
  def extract_all_data(text_blob)
    # 1. Normalize whitespace and remove common separators to make regex easier
    text_blob = text_blob.gsub(/\s+/, " ").gsub("|", " ")

    # 2. Flexible Ingredients Regex
    ing_regex = /(ingredients|zutaten|ingrédients|ingrediënten|samenstelling|ingredienser|ingredientes|ingredienti|składniki)\s*[:\.-]?\s*(.*?)(?=(nutrition|voedings|nährwerte|energy|energie|valeurs|valor|näring|næring|wartość|$))/i
    
    nutri_regex = /(per 100|pro 100|pour 100|por 100|pr\. 100|w 100)/i

    # 3. Aggressive Number Matcher
    # Looks for: KEYWORD -> (optional stuff) -> NUMBER -> UNIT
    # Example: "Fat < 0.5 g" or "Fat approx 10g"
    
    find_val = ->(keywords, units) {
       # Regex Explanation:
       # #{keywords} : The category name (e.g., Fat)
       # [^0-9]{0,20}: Ignore up to 20 non-number chars (colons, spaces, words like "approx")
       # ([<>]?\s*\d+[,\.]?\d*) : Capture the number (optional < > signs)
       # \s*#{units} : Ensure the correct unit follows (g, kcal, etc)
       regex = /#{keywords}[^0-9]{0,20}([<>]?\s*\d+[,\.]?\d*)\s*#{units}/i
       match = text_blob.match(regex)
       match ? "#{match[1]}#{units}" : "-"
    }

    data = {
      weight: find_val.call("(weight|gewicht|inhoud|netto|poids|size|peso|vikt|waga)", "(g|kg|ml|l|oz|cl)"),
      ingredients: extract_text(text_blob, ing_regex),
      allergens: extract_text(text_blob, /(allergens|allergene|allergie|bevat|contains|allergènes|allergenen|allergener|alérgenos|alergeny)\s*[:\.-]?\s*(.*?)(?=(\.|may contain|kann spuren|kan sporen|peut contenir|puede contener|kan indeholde|$))/i),
      may_contain: extract_text(text_blob, /(may contain|kann spuren|kan sporen|peut contenir|puede contener|kan indeholde|pode conter|può contenere)\s*[:\.-]?\s*(.*?)(?=(\.|nutrition|voedings|$))/i),
      nutrition_header: extract_text(text_blob, nutri_regex),
      
      energy: find_val.call("(energy|energie|valeur|valor|energi|energia)", "(kj|kcal)"),
      fat: find_val.call("(fat|fett|vet|matières grasses|grassi|grasas|fedt|tłuszcz)", "g"),
      saturates: find_val.call("(saturates|saturated|gesättigte|verzadigde|saturés|saturi|saturadas|mættede|nasycone)", "g"),
      carbs: find_val.call("(carbohydrate|kohlenhydrate|koolhydraten|glucides|carboidrati|hidratos|kulhydrat|węglowodany)", "g"),
      sugars: find_val.call("(sugars|zucker|suikers|sucres|zuccheri|azúcares|sukker|socker|cukry)", "g"),
      protein: find_val.call("(protein|eiweiß|eiwit|protéines|proteine|proteínas|białko)", "g"),
      fiber: find_val.call("(fiber|ballaststoffe|vezels|fibres|fibre|fibra|kostfibre|błonnik)", "g"),
      salt: find_val.call("(salt|salz|zout|sel|sale|sal|sól)", "g"),
      
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
          <th>Product Name</th>
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
      let emptyCells = ""; for(let i=0; i<17; i++) { emptyCells += "<td></td>"; }
      tr.innerHTML = `<td>${gtin}</td><td style="color:orange">Loading...</td>` + emptyCells;
      tbody.appendChild(tr);

      try {
        const response = await fetch(`/api/search?gtin=${gtin}&market=${market}`);
        const data = await response.json();
        
        tr.innerHTML = `
          <td>${gtin}</td>
          <td>${(data.product_name || '-').substring(0,30)}...</td>
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
    let csv = "GTIN,ProductName,Market,Status,ImageURL,SourceURL,Weight,Ingredients,Allergens,MayContain,NutritionHeader,Energy,Fat,Saturates,Carbohydrates,Sugars,Protein,Fiber,Salt,OrganicID\n";
    resultsData.forEach(row => {
      const clean = (txt) => (txt || "-").toString().replace(/,/g, " ").replace(/\n/g, " ").trim();
      csv += `${row.gtin},${clean(row.product_name)},${row.market},${row.status},${row.url},${row.source},${clean(row.weight)},${clean(row.ingredients)},${clean(row.allergens)},${clean(row.may_contain)},${clean(row.nutrition_header)},${clean(row.energy)},${clean(row.fat)},${clean(row.saturates)},${clean(row.carbs)},${clean(row.sugars)},${clean(row.protein)},${clean(row.fiber)},${clean(row.salt)},${clean(row.organic_cert)}\n`;
    });
    const link = document.createElement("a");
    link.href = "data:text/csv;charset=utf-8," + encodeURI(csv);
    link.download = "tgtg_master_data.csv";
    link.click();
  }
</script>

</body>
</html>