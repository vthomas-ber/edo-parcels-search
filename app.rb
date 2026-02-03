require 'sinatra'
require 'json'
require 'httparty'

# --- CONFIGURATION ---
GEMINI_API_KEY = ENV['GEMINI_API_KEY']

class GeminiResearcher
  include HTTParty

  def initialize
    @headers = { 'Content-Type' => 'application/json' }
  end

  def research_product(gtin, market)
    return { error: "Missing GEMINI_API_KEY" } if GEMINI_API_KEY.nil? || GEMINI_API_KEY.strip.empty?

    # 1. PREPARE THE VERBATIM PROMPT (System Instruction)
    system_instruction = <<~TEXT
      You are the **Lead Food Product Researcher**, a specialized analyst designed to compile 100% accurate product specifications for ambient and packaged goods.

      **CORE DIRECTIVE:** Accuracy is your absolute priority. You are conducting manual market research to verify product details.

      ---

      ### PHASE 1: RESEARCH SETUP
      **Rule:** Check if the user has provided a target Market and EAN list in the first message.
      * **IF YES:** Proceed immediately to Phase 2.
      * **IF NO:** Ask **ONLY** these two questions to begin:
          > 1. "Which market (country) should I research?"
          > 2. "Please provide the list of EANs. (Max 10 items)."

      ---

      ### PHASE 2: LOCALIZATION & RESEARCH STRATEGY
      **Step 1: Set Target Language**
      * Identify the **Native Official Language** of the requested Market (e.g., Input "Germany" -> Language: "German").
      * **Requirement:** All text in the final report (Ingredients, Product Name, Allergens) **MUST** be in this Target Language.

      **Step 2: Source Selection**
      * **Strategy:** Search for public product pages explicitly associated with the provided EANs.
      * **Focus:** Prioritize major online grocery retailers and official brand websites within the country's domain (e.g., .de, .it, .fr).
      * **Exclusion:** Do not use open-source wikis (like `world.openfoodfacts.org`) or unverified calorie-counting forums.

      **Step 3: Verification Standards (The "Twin-Check" Method)**
      * **Verification:** Attempt to confirm details across at least **two independent public sources**.
      * **Organic Check:** Look for specific Organic Certification codes (e.g., DE-ÖKO-001). If no certification code is visible, list "N/A".

      ---

      ### PHASE 3: DATA STANDARDIZATION
      Before formatting, clean the findings:
      * **Text Formatting:** Ensure 'Ingredients', 'Allergens', and 'May Contain' lists are single continuous text strings (remove bullet points and line breaks).
      * **Units:** Standardize Energy to "kJ / kcal". If one value is missing, calculate it using the standard factor (1 kcal = 4.184 kJ) and mark with (*).

      ---

      ### PHASE 4: FINAL REPORT (Spreadsheet Format)
      **Rule:** Present findings in a **Single Markdown Table**.
      **Language:** The content must be in the **Target Language**.

      **Columns:**
      1.  **EAN** (Text format)
      2.  **Brand**
      3.  **Product Name** (Target Language)
      4.  **Net Weight** (e.g., 500g)
      5.  **Organic ID** (e.g., "DE-ÖKO-001" or "N/A")
      6.  **Ingredients** (Full list, single string, Target Language)
      7.  **Allergens** (Target Language)
      8.  **May Contain** (Target Language)
      9.  **Nutritional Scope** (e.g., "per 100g")
      10. **Energy (kJ / kcal)**
      11. **Fat (g)**
      12. **- of which saturates (g)**
      13. **Carbohydrates (g)**
      14. **- of which sugars (g)**
      15. **Fiber (g)**
      16. **Protein (g)**
      17. **Salt (g)**
      18. **Confidence Level** (High/Medium/Low)

      **Confidence Logic:**
      * **High:** Data matches Official Brand Site OR 2+ retailers.
      * **Medium:** Found on 1 reputable retailer.
      * **Low:** Found on obscure third-party shop or partial data only.

      ---

      ### PHASE 5: REFERENCES
      Immediately **below** the table, list your references:

      **Reference Log:**
      * **[EAN Code]**: [Confidence Level] | [Source Link 1] | [Source Link 2]

      ---

      ### SYSTEM SAFEGUARDS
      1.  **Do not** exceed 10 EANs per batch.
      2.  **Do not** fabricate data. If a field is empty, write "N/A".
      3.  **Do not** use the words "scrape", "crawl", or "bot" in your output. You are a researcher.
    TEXT

    # 2. CALL GEMINI WITH SEARCH TOOLS
    # Using Gemini 2.0 Flash which supports search grounding well
    model_id = "models/gemini-2.0-flash"
    url = "https://generativelanguage.googleapis.com/v1beta/#{model_id}:generateContent?key=#{GEMINI_API_KEY}"

    user_message = "Market: #{market}\nEAN List: #{gtin}"

    payload = {
      contents: [{ parts: [{ text: user_message }] }],
      systemInstruction: { parts: [{ text: system_instruction }] },
      tools: [{ google_search: {} }] # <--- THIS ENABLES THE WEB SEARCH
    }

    begin
      response = HTTParty.post(url, body: payload.to_json, headers: @headers, timeout: 60)
      
      if response.code == 200
        raw_text = response.dig("candidates", 0, "content", "parts", 0, "text")
        
        # 3. PARSE MARKDOWN TABLE TO JSON FOR FRONTEND
        return parse_markdown_response(raw_text, gtin, market)
      else
        return { 
          found: false, 
          status: "API Error #{response.code}", 
          gtin: gtin,
          error_details: response.body
        }
      end
    rescue => e
      return { found: false, status: "Sys Error: #{e.message}", gtin: gtin }
    end
  end

  private

  def parse_markdown_response(text, original_gtin, market)
    # Default empty structure
    result = {
      found: false, status: "No Data", gtin: original_gtin, market: market,
      product_name: "-", weight: "-", ingredients: "-", allergens: "-",
      may_contain: "-", nutri_scope: "-", energy: "-", fat: "-",
      saturates: "-", carbs: "-", sugars: "-", protein: "-",
      fiber: "-", salt: "-", organic_id: "-", source_url: "-"
    }

    return result if text.nil?

    # Extract the table row using Regex
    # Looking for a line that starts with pipe |, contains the GTIN, and has multiple columns
    lines = text.split("\n")
    table_row = lines.find { |l| l.include?("|") && l.include?(original_gtin) }

    # Extract Sources
    sources = text.scan(/http[s]?:\/\/[^\s\]]+/).uniq.join(" ; ")

    if table_row
      # Split by pipe and trim whitespace
      cols = table_row.split("|").map(&:strip)
      # cols[0] is usually empty because the line starts with |
      # Structure defined in prompt:
      # 1:EAN, 2:Brand, 3:Name, 4:Weight, 5:Organic, 6:Ingred, 7:Allerg, 8:MayContain, 
      # 9:Scope, 10:Energy, 11:Fat, 12:Sat, 13:Carbs, 14:Sugars, 15:Fiber, 16:Prot, 17:Salt, 18:Conf

      # Adjust index based on whether split created an empty first element (common in markdown tables)
      start_idx = cols[0].empty? ? 1 : 0
      
      result[:found] = true
      result[:status] = cols[start_idx + 17] # Confidence Level
      result[:gtin] = cols[start_idx]
      # Brand is cols[start_idx+1], we combine with name
      result[:product_name] = "#{cols[start_idx + 1]} #{cols[start_idx + 2]}"
      result[:weight] = cols[start_idx + 3]
      result[:organic_id] = cols[start_idx + 4]
      result[:ingredients] = cols[start_idx + 5]
      result[:allergens] = cols[start_idx + 6]
      result[:may_contain] = cols[start_idx + 7]
      result[:nutri_scope] = cols[start_idx + 8]
      result[:energy] = cols[start_idx + 9]
      result[:fat] = cols[start_idx + 10]
      result[:saturates] = cols[start_idx + 11]
      result[:carbs] = cols[start_idx + 12]
      result[:sugars] = cols[start_idx + 13]
      result[:fiber] = cols[start_idx + 14]
      result[:protein] = cols[start_idx + 15]
      result[:salt] = cols[start_idx + 16]
      result[:source_url] = sources.empty? ? "Gemini Search" : sources
    end

    result
  end
end

# --- ROUTES ---

get '/' do
  erb :index
end

get '/api/search' do
  content_type :json
  researcher = GeminiResearcher.new
  result = researcher.research_product(params[:gtin], params[:market])
  result.to_json
end

__END__

@@ index
<!DOCTYPE html>
<html>
<head>
  <title>TGTG AI Pure Researcher</title>
  <style>
    body { font-family: -apple-system, system-ui, sans-serif; background: #f4f6f8; padding: 20px; color: #333; }
    .container { max-width: 98%; margin: 0 auto; background: white; padding: 25px; border-radius: 12px; box-shadow: 0 2px 10px rgba(0,0,0,0.05); }
    h1 { color: #00816A; }
    .subtitle { color: #666; font-size: 0.9em; margin-bottom: 20px; }

    .controls { display: flex; gap: 15px; margin-bottom: 20px; background: #eefcf9; padding: 15px; border-radius: 8px; }
    textarea { width: 100%; height: 100px; padding: 12px; border: 1px solid #ddd; border-radius: 8px; font-family: monospace; }
    button { background: #00816A; color: white; border: none; padding: 12px 24px; border-radius: 6px; font-weight: 600; cursor: pointer; }
    button:disabled { background: #ccc; }

    .table-wrapper { overflow-x: auto; margin-top: 25px; border: 1px solid #eee; border-radius: 8px; }
    table { width: 100%; border-collapse: collapse; font-size: 13px; min-width: 2200px; }
    th { text-align: left; background: #00816A; color: white; padding: 12px; position: sticky; left: 0; z-index: 10; white-space: nowrap; }
    td { padding: 12px; border-bottom: 1px solid #eee; vertical-align: top; max-width: 250px; word-wrap: break-word; }
    tr:nth-child(even) { background: #f8f9fa; }

    .status-found { background: #d4edda; color: #155724; padding: 4px 8px; border-radius: 4px; font-weight: bold; }
    .status-missing { background: #f8d7da; color: #721c24; padding: 4px 8px; border-radius: 4px; font-weight: bold; }
    .link-btn { color: #00816A; text-decoration: none; border: 1px solid #00816A; padding: 4px 8px; border-radius: 4px; font-size: 11px; white-space: nowrap; display: inline-block; margin-top: 2px;}
    .link-btn:hover { background: #00816A; color: white; }
  </style>
</head>
<body>

<div class="container">
  <h1>✨ TGTG AI Pure Researcher (Gemini Grounded)</h1>
  <div class="subtitle">Powered by Gemini 2.0 with Google Search Grounding. No external scrapers.</div>
  
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
    </select>
  </div>

  <textarea id="inputList" placeholder="Paste EANs here (one per line)..."></textarea>
  <br><br>
  <button id="startBtn" onclick="startBatch()">🚀 Start Research</button>
  <button id="downloadBtn" onclick="downloadCSV()" style="background: #333; display: none;">⬇️ Download CSV</button>
  <p id="statusText" style="color: #666; margin-top: 10px;">Ready.</p>

  <div class="table-wrapper">
    <table id="resultsTable">
      <thead>
        <tr>
          <th>Confidence</th>
          <th>Verification</th>
          <th>EAN</th>
          <th>Product Name</th>
          <th>Weight</th>
          <th>Organic ID</th>
          <th>Ingredients</th>
          <th>Allergens</th>
          <th>May Contain</th>
          <th>Scope</th>
          <th>Energy</th>
          <th>Fat</th>
          <th>Saturates</th>
          <th>Carbs</th>
          <th>Sugars</th>
          <th>Fiber</th>
          <th>Protein</th>
          <th>Salt</th>
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
      document.getElementById('statusText').innerText = `Researching ${gtin} (${processed + 1}/${lines.length})...`;
      const tr = document.createElement('tr');
      // Create placeholders
      tr.innerHTML = `<td style="color:#00816A; font-weight:bold;">Searching...</td>` + "<td></td>".repeat(17);
      tbody.appendChild(tr);

      try {
        const response = await fetch(`/api/search?gtin=${gtin}&market=${market}`);
        const data = await response.json();

        let displayStatus = data.status || "Low";
        let statusClass = (displayStatus.includes("High") || displayStatus.includes("Medium")) ? 'status-found' : 'status-missing';
        
        const sourceLink = data.source_url && data.source_url.startsWith('http') 
          ? `<a href="${data.source_url.split(';')[0]}" target="_blank" class="link-btn">🔗 Sources</a>` 
          : '-';

        tr.innerHTML = `
          <td><span class="${statusClass}">${displayStatus}</span></td>
          <td>${sourceLink}</td>
          <td>${gtin}</td>
          <td>${data.product_name}</td>
          <td>${data.weight}</td>
          <td>${data.organic_id}</td>
          <td>${data.ingredients}</td>
          <td>${data.allergens}</td>
          <td>${data.may_contain}</td>
          <td>${data.nutri_scope}</td>
          <td>${data.energy}</td>
          <td>${data.fat}</td>
          <td>${data.saturates}</td>
          <td>${data.carbs}</td>
          <td>${data.sugars}</td>
          <td>${data.fiber}</td>
          <td>${data.protein}</td>
          <td>${data.salt}</td>
        `;
        resultsData.push(data);
      } catch (e) {
        tr.innerHTML = `<td style="color:red">Error</td>` + "<td></td>".repeat(17);
        console.error(e);
      }
      processed++;
    }
    
    document.getElementById('startBtn').disabled = false;
    document.getElementById('downloadBtn').style.display = "inline-block";
    document.getElementById('statusText').innerText = "Research Complete!";
  }

  function downloadCSV() {
    let csv = "EAN,ProductName,Weight,OrganicID,Ingredients,Allergens,MayContain,NutritionalScope,Energy,Fat,Saturates,Carbs,Sugars,Fiber,Protein,Salt,Confidence,Sources\n";

    resultsData.forEach(row => {
      const clean = (txt) => (txt || "-").toString().replace(/,/g, " ").replace(/"/g, '""').replace(/\n/g, " ").trim();
      csv += `${row.gtin},"${clean(row.product_name)}","${clean(row.weight)}","${clean(row.organic_id)}",` +
             `"${clean(row.ingredients)}","${clean(row.allergens)}","${clean(row.may_contain)}",` +
             `"${clean(row.nutri_scope)}","${clean(row.energy)}","${clean(row.fat)}","${clean(row.saturates)}",` +
             `"${clean(row.carbs)}","${clean(row.sugars)}","${clean(row.fiber)}","${clean(row.protein)}",` +
             `"${clean(row.salt)}","${clean(row.status)}","${clean(row.source_url)}"\n`;
    });

    const link = document.createElement("a");
    link.href = "data:text/csv;charset=utf-8," + encodeURI(csv);
    link.download = "gemini_research_results.csv";
    link.click();
  }
</script>

</body>
</html>
